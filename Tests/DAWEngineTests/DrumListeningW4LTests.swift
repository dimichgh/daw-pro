import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// W8-W4L: the listening renders for design §10.2 L1 (how much louder an accented drum hit is) and L2 (how busy the
// hi-hats of the first "Start from a beat" pattern are), `docs/design/2026-10-07-loop-drum-depth.md:833-857`.
//
// ENV-GATED: runs only with `W4L_RENDER=1`; writes raw Float32 WAVs and `measure.json` to `W4L_OUT` (default: a
// folder in the temp dir). Loudness matching and the MP3 encode happen OUTSIDE the test (ffmpeg), on these files.
// Pre-registered in the lane's PREDICTIONS.md before the first render.
//
// Deliberately NOT `@MainActor` (no new MainActor suite): `OfflineRenderer` is `@MainActor`, so the render and the
// WAV write are the only hops, both in `W4LRig`.
//
// Every number here is MEASURED from the rendered samples, never derived from the kit's formula:
//   - method A: each drum hit ALONE in its own render, RMS of the first 100 ms (both channels);
//   - method B: the beat itself rendered one drum at a time (stems), RMS of the first 100 ms after every hit;
// and the gates assert PHYSICS (the accent switches on below velocity 100, velocity moves level, hat count doubles
// energy, an open hat rings where a closed hat has died), never mere distinctness.

/// One drum hit in beats (quarter notes from the start), at a MIDI velocity.
struct W4LHit: Sendable {
    let voice: DrumVoice
    let beat: Double
    let velocity: Int
}

enum W4LBeats {
    static let bpm = 120.0
    static let sampleRate = 48_000.0
    /// Two passes of the two-bar beat (16 beats = 8 s) plus a 1 s tail.
    static let patternBeats = 8.0
    static let passes = 2
    static let renderSeconds = 9.0
    static let accentVelocity = 127

    static func sample(atBeat beat: Double) -> Int { Int((beat * 60.0 / bpm * sampleRate).rounded()) }

    /// Beat 1 or beat 3 of a 4/4 bar.
    static func isAccentPosition(_ beat: Double) -> Bool {
        let inBar = beat.truncatingRemainder(dividingBy: 4)
        return inBar == 0 || inBar == 2
    }

    /// L1: kick 1, 3, 3-and | 1, 2-and, 3; snare 2 and 4; closed hats on every eighth. Hits on beats 1 and 3 at 127,
    /// every other hit at `plain`. The same beat for every option; only `plain` changes.
    static func l1(plain: Int) -> [W4LHit] {
        let kicks: [Double] = [0, 2, 2.5, 4, 5.5, 6]
        let snares: [Double] = [1, 3, 5, 7]
        let hats = Array(stride(from: 0.0, to: patternBeats, by: 0.5))
        var hits: [W4LHit] = []
        for pass in 0..<passes {
            let offset = Double(pass) * patternBeats
            let lanes: [(DrumVoice, [Double])] = [(.kick, kicks), (.snare, snares), (.closedHat, hats)]
            for (voice, beats) in lanes {
                for beat in beats {
                    hits.append(W4LHit(voice: voice, beat: offset + beat,
                                       velocity: isAccentPosition(beat) ? accentVelocity : plain))
                }
            }
        }
        return hits
    }

    /// L2: kick on 1 and 3, snare on 2 and 4, closed hats every `hatStep` beats, every hit at velocity 100 (today's
    /// entry velocity). With `lift`, the last off-beat of the two-bar pattern (beat 7.5) is the OPEN hat and the closed
    /// hat on the sixteenth after it (7.75) is left out, so the open hat rings until the next downbeat's closed hat
    /// cuts it (hat choke group 0).
    static func l2(hatStep: Double, lift: Bool) -> [W4LHit] {
        let velocity = 100
        var hits: [W4LHit] = []
        for pass in 0..<passes {
            let offset = Double(pass) * patternBeats
            for beat in [0.0, 2, 4, 6] { hits.append(W4LHit(voice: .kick, beat: offset + beat, velocity: velocity)) }
            for beat in [1.0, 3, 5, 7] { hits.append(W4LHit(voice: .snare, beat: offset + beat, velocity: velocity)) }
            for beat in stride(from: 0.0, to: patternBeats, by: hatStep) {
                if lift && beat == 7.75 { continue }
                let voice: DrumVoice = (lift && beat == 7.5) ? .openHat : .closedHat
                hits.append(W4LHit(voice: voice, beat: offset + beat, velocity: velocity))
            }
        }
        return hits
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5734C000-0000-4000-8000-%012X", n))!
    }

    /// One drum-machine track on the 808 preset (pads layout), fixed ids so two renders see identical input.
    static func track(_ hits: [W4LHit], kit: DrumKitParams) -> Track {
        let notes = hits.enumerated().map { index, hit in
            MIDINote(id: uuid(10_000 + index), pitch: Int(hit.voice.note), velocity: hit.velocity,
                     startBeat: hit.beat, lengthBeats: 0.25)
        }
        let clip = Clip(id: uuid(2), name: "W4L beat", startBeat: 0,
                        lengthBeats: patternBeats * Double(passes), notes: notes)
        return Track(id: uuid(1), name: "Drums", kind: .instrument, clips: [clip],
                     instrument: InstrumentDescriptor(kind: .drumSynth, drumKit: kit))
    }
}

enum W4LMeasure {
    /// 100 ms: the window every hit is measured over. Hits of one voice are at least 250 ms apart in both beats.
    static let window = 4_800
    /// "Sounds" = peak above this floor. AMENDED after the first render: the pre-registered -30 dBFS was wrong for an
    /// isolated 808 closed hat, which peaks at -33.6 dBFS at velocity 127 (MEASURED 08:21).
    static let silenceFloorDb = -60.0

    /// Mean power over both channels of `[start, start + count)`, linear.
    static func power(_ audio: RenderedAudio, start: Int, count: Int) -> Double {
        var sum = 0.0
        var n = 0
        for channel in audio.channelData {
            let lo = max(0, start), hi = min(channel.count, start + count)
            guard lo < hi else { continue }
            for i in lo..<hi { let x = Double(channel[i]); sum += x * x }
            n += hi - lo
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    static func db(_ power: Double) -> Double { 10 * log10(max(power, 1e-30)) }

    static func peakDb(_ audio: RenderedAudio) -> Double {
        var peak: Float = 0
        for channel in audio.channelData { for x in channel { peak = max(peak, abs(x)) } }
        return 20 * log10(max(Double(peak), 1e-30))
    }

    static func allFinite(_ audio: RenderedAudio) -> Bool {
        audio.channelData.allSatisfy { channel in channel.allSatisfy { $0.isFinite } }
    }

    /// First frame where either channel exceeds 1e-6, or nil (silent).
    static func firstSound(_ audio: RenderedAudio) -> Int? {
        let frames = audio.frameCount
        for i in 0..<frames where audio.channelData.contains(where: { abs($0[i]) > 1e-6 }) { return i }
        return nil
    }

    /// FNV-1a 64 over the raw bit patterns of every sample, both channels.
    static func digest(_ audio: RenderedAudio) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for channel in audio.channelData {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    hash ^= UInt64(bits & 0xff)
                    hash = hash &* 0x0000_0100_0000_01b3
                    bits >>= 8
                }
            }
        }
        return String(hash, radix: 16)
    }

    static func bitIdentical(_ a: RenderedAudio, _ b: RenderedAudio) -> Bool {
        guard a.channelData.count == b.channelData.count else { return false }
        for (x, y) in zip(a.channelData, b.channelData) {
            guard x.count == y.count else { return false }
            for i in x.indices where x[i].bitPattern != y[i].bitPattern { return false }
        }
        return true
    }

    /// Energy-mean (dB) of the 100 ms after each hit's scheduled onset.
    static func hitsDb(_ audio: RenderedAudio, _ hits: [W4LHit]) -> Double {
        guard !hits.isEmpty else { return -300 }
        let total = hits.reduce(0.0) { $0 + power(audio, start: W4LBeats.sample(atBeat: $1.beat), count: window) }
        return db(total / Double(hits.count))
    }

    static func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

struct W4LRig {
    let out: URL

    static func make() throws -> W4LRig {
        let env = ProcessInfo.processInfo.environment
        let path = env["W4L_OUT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("w4l-render").path
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out.appendingPathComponent("raw"), withIntermediateDirectories: true)
        return W4LRig(out: out)
    }

    /// A FRESH `OfflineRenderer` every call: the export path, 48 kHz stereo, 120 BPM.
    @MainActor
    static func render(_ hits: [W4LHit], kit: DrumKitParams, seconds: Double) throws -> RenderedAudio {
        try OfflineRenderer().render(tracks: [W4LBeats.track(hits, kit: kit)],
                                     tempoMap: TempoMap(constantBPM: W4LBeats.bpm),
                                     fromBeat: 0, durationSeconds: seconds)
    }

    @MainActor
    static func write(_ audio: RenderedAudio, to url: URL) throws {
        _ = try OfflineRenderer.writeAudioFile(audio, to: url)
    }

    func raw(_ name: String) -> URL { out.appendingPathComponent("raw/\(name).wav") }
}

@Suite("W8-W4L drum listening renders, L1 and L2 (W4L_RENDER=1 only)")
struct DrumListeningW4LTests {
    static let enabled = ProcessInfo.processInfo.environment["W4L_RENDER"] == "1"
    /// ROUND 2 (orchestrator, 2026-10-07 09:0x): 100 (today) / 85 / 60 / 40, the spacing round 1's ladder measured
    /// to clear 1 dB per step on kick, snare and closed hat. Round 1 was 100 / 90 / 80 / 70 and was refused.
    static let l1Options = [100, 85, 60, 40]
    /// ROUND 2: the hi-hats raised to the Mac drum kit's level in EVERY file of both questions, so the asked axis stays
    /// the only thing that changes. READ, not derived: W8-HAT `renders/set/spec.json`, every `2-at-mac-kit-level`
    /// variant sets `kit.hatsLevelDb` 23.4 and `kit.cymbalsLevelDb` 5.7 (`meta.DH` 23.4). No cymbal plays here.
    static let hatsLevelDb = 23.4
    static let cymbalsLevelDb = 5.7
    static let ladder = [100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50, 45, 40, 35, 30]
    static let isolatedVoices: [DrumVoice] = [.kick, .snare, .closedHat]
    static let l2Options: [(id: String, file: String, step: Double, lift: Bool)] = [
        ("quarters", "l2-4", 1.0, false), ("eighths", "l2-8", 0.5, false),
        ("sixteenths", "l2-16", 0.25, false), ("sixteenths-lift", "l2-16-lift", 0.25, true),
    ]

    @Test("W4L: L1 accent contrast and L2 hat busyness on the 808, rendered offline and measured",
          .enabled(if: DrumListeningW4LTests.enabled))
    func renderAndMeasure() async throws {
        let rig = try W4LRig.make()
        var kit = try #require(DrumKitParams.preset(named: "808")).params
        // W9-DRUMDEF: every factory preset now carries the picked hat/cymbal levels; the 808 is the
        // factory SOUND with those two levels set (the two lines below then set them to the same values).
        var sound = kit
        sound.hatsLevelDb = 0
        sound.cymbalsLevelDb = 0
        #expect(sound == DrumKitParams(), "the 808 preset is the factory sound (DrumKit.swift presets)")
        kit.hatsLevelDb = Self.hatsLevelDb
        kit.cymbalsLevelDb = Self.cymbalsLevelDb
        #expect(kit.hatsLevelDb == 23.4 && kit.cymbalsLevelDb == 5.7, "the Mac-kit-level hat raise took")
        var report: [String: Any] = [:]
        var gates: [[String: Any]] = []
        func gate(_ name: String, _ ok: Bool, _ detail: String) {
            gates.append(["name": name, "pass": ok, "detail": detail])
            #expect(ok, "\(name): \(detail)")
        }

        // ---- D: determinism first. One render twice, two FRESH renderers: bit-identical samples, byte-equal WAVs.
        let detHits = W4LBeats.l1(plain: 100)
        let detA = try await W4LRig.render(detHits, kit: kit, seconds: W4LBeats.renderSeconds)
        let detB = try await W4LRig.render(detHits, kit: kit, seconds: W4LBeats.renderSeconds)
        try await W4LRig.write(detA, to: rig.raw("det-a"))
        try await W4LRig.write(detB, to: rig.raw("det-b"))
        let filesEqual = try Data(contentsOf: rig.raw("det-a")) == Data(contentsOf: rig.raw("det-b"))
        gate("D: one render twice is bit-identical, and the two WAV files are byte-equal",
             W4LMeasure.bitIdentical(detA, detB) && filesEqual,
             "digest \(W4LMeasure.digest(detA)) vs \(W4LMeasure.digest(detB)); files equal \(filesEqual); "
             + "frames \(detA.frameCount)")
        report["determinism"] = ["digestA": W4LMeasure.digest(detA), "digestB": W4LMeasure.digest(detB),
                                 "filesEqual": filesEqual, "frames": detA.frameCount] as [String: Any]

        // ---- Method A: every voice of the beat, ALONE, at 127 and down the velocity ladder. First 100 ms, dB.
        var isolated: [String: [String: Double]] = [:]
        var lags: [String: Int] = [:]
        for voice in Self.isolatedVoices {
            var row: [String: Double] = [:]
            for velocity in [W4LBeats.accentVelocity] + Self.ladder {
                let audio = try await W4LRig.render([W4LHit(voice: voice, beat: 0, velocity: velocity)],
                                                    kit: kit, seconds: 1.0)
                gate("F: isolated \(voice.rawValue) v\(velocity) is finite and sounds",
                     W4LMeasure.allFinite(audio) && W4LMeasure.peakDb(audio) >= W4LMeasure.silenceFloorDb,
                     "peak \(W4LMeasure.r2(W4LMeasure.peakDb(audio))) dBFS")
                if velocity == W4LBeats.accentVelocity { lags[voice.rawValue] = W4LMeasure.firstSound(audio) ?? -1 }
                row["v\(velocity)"] = W4LMeasure.db(W4LMeasure.power(audio, start: 0, count: W4LMeasure.window))
            }
            isolated[voice.rawValue] = row
        }
        func contrastA(_ voice: DrumVoice, _ velocity: Int) -> Double {
            let row = isolated[voice.rawValue] ?? [:]
            return (row["v127"] ?? 0) - (row["v\(velocity)"] ?? 0)
        }
        var ladderOut: [String: [String: Double]] = [:]
        for voice in Self.isolatedVoices {
            var row: [String: Double] = [:]
            for velocity in Self.ladder { row["v\(velocity)"] = W4LMeasure.r2(contrastA(voice, velocity)) }
            ladderOut[voice.rawValue] = row
        }
        report["isolatedContrastDb"] = ladderOut
        report["isolatedOnsetFrame"] = lags
        for voice in Self.isolatedVoices {
            let c100 = contrastA(voice, 100), c90 = contrastA(voice, 90), c70 = contrastA(voice, 70)
            // PL1's catch: at 100 BOTH hits get the kit's accent (+25 % level, +1.94 dB; threshold 100, `>=`);
            // at 90 only the 127 hit keeps it, so the 100 -> 90 step carries it.
            gate("ACC: \(voice.rawValue) 100->90 contrast step carries the accent (>= 1.5 dB)", c90 - c100 >= 1.5,
                 "c100 \(W4LMeasure.r2(c100)) dB, c90 \(W4LMeasure.r2(c90)) dB")
            // PL2's catch: velocity itself moves level (both 127 and 100 are accented, so only velocity separates them).
            // AMENDED after the first render: the c100 clause binds the kick and the snare only. On the hats velocity
            // also raises `tone`, which moves the hat band UP (`DrumSynthInstrument.swift:737`) and costs energy, so
            // 127 vs 100 measured +0.23 dB on the closed hat (amplitude term alone: +1.51). c70 - c90 binds all three.
            let levelVoice = voice != .closedHat
            let velRule = levelVoice ? "c100 >= 0.7 dB, c70 - c90 >= 0.6 dB" : "c70 - c90 >= 0.6 dB"
            gate("VEL: \(voice.rawValue) velocity moves level (\(velRule))",
                 (!levelVoice || c100 >= 0.7) && c70 - c90 >= 0.6,
                 "c100 \(W4LMeasure.r2(c100)), c90 \(W4LMeasure.r2(c90)), c70 \(W4LMeasure.r2(c70))")
        }

        // ---- L1: the four beats (written for the page) and the per-voice stems (method B).
        var l1Rows: [[String: Any]] = []
        var seriesB: [String: [Double]] = ["kick": [], "closedHat": []]
        for plain in Self.l1Options {
            let hits = W4LBeats.l1(plain: plain)
            let mix = try await W4LRig.render(hits, kit: kit, seconds: W4LBeats.renderSeconds)
            try await W4LRig.write(mix, to: rig.raw("l1-v\(plain)"))
            gate("F: l1-v\(plain) is finite and sounds",
                 W4LMeasure.allFinite(mix) && W4LMeasure.peakDb(mix) >= W4LMeasure.silenceFloorDb,
                 "peak \(W4LMeasure.r2(W4LMeasure.peakDb(mix))) dBFS")
            var row: [String: Any] = ["option": "v\(plain)", "file": "l1-v\(plain)", "plainVelocity": plain,
                                      "rawPeakDb": W4LMeasure.r2(W4LMeasure.peakDb(mix)),
                                      "notes": hits.count,
                                      "accentedNotes": hits.filter { $0.velocity == W4LBeats.accentVelocity }.count]
            for voice in [DrumVoice.kick, .closedHat] {
                let stemHits = hits.filter { $0.voice == voice }
                let stem = try await W4LRig.render(stemHits, kit: kit, seconds: W4LBeats.renderSeconds)
                if voice == .closedHat { try await W4LRig.write(stem, to: rig.raw("stem-l1-v\(plain)-hats")) }
                let accented = stemHits.filter { $0.velocity == W4LBeats.accentVelocity }
                let plainHits = stemHits.filter { $0.velocity != W4LBeats.accentVelocity }
                let b = W4LMeasure.hitsDb(stem, accented) - W4LMeasure.hitsDb(stem, plainHits)
                let a = contrastA(voice, plain)
                seriesB[voice.rawValue, default: []].append(b)
                row["contrastB_\(voice.rawValue)"] = W4LMeasure.r2(b)
                row["contrastA_\(voice.rawValue)"] = W4LMeasure.r2(a)
                row["hits_\(voice.rawValue)"] = "\(accented.count) accented, \(plainHits.count) plain"
                gate("AGREE: \(voice.rawValue) v\(plain), isolated and in-beat contrast agree within 1 dB",
                     abs(a - b) <= 1.0, "A \(W4LMeasure.r2(a)) dB, B \(W4LMeasure.r2(b)) dB")
            }
            row["contrastA_snare"] = W4LMeasure.r2(contrastA(.snare, plain))
            l1Rows.append(row)
        }
        report["l1"] = l1Rows
        // The brief's refusal rule is a VERDICT for publishing, not a test failure: recorded, never asserted.
        var refusal: [String: Any] = [:]
        var refused = false
        for (voice, series) in seriesB.sorted(by: { $0.key < $1.key }) {
            let steps = zip(series.dropFirst(), series).map { W4LMeasure.r2($0 - $1) }
            let short = steps.filter { $0 < 1.0 }.count
            if short > 0 { refused = true }
            refusal[voice] = ["contrastB": series.map(W4LMeasure.r2), "steps": steps,
                              "stepsUnder1dB": short] as [String: Any]
        }
        var isolatedSteps: [String: [Double]] = [:]
        for voice in Self.isolatedVoices {
            let series = Self.l1Options.map { contrastA(voice, $0) }
            isolatedSteps[voice.rawValue] = zip(series.dropFirst(), series).map { W4LMeasure.r2($0 - $1) }
        }
        refusal["isolatedSteps"] = isolatedSteps
        refusal["refused"] = refused
        refusal["rule"] = "refuse L1 if the in-beat (method B) contrast of the closed hat or the kick moves by less "
            + "than 1.0 dB between two adjacent options"
        report["l1Refusal"] = refusal
        print("W4L-L1 refused=\(refused) \(refusal)")

        // ---- L2: the four beats, the hat stems, the lift windows.
        var l2Rows: [[String: Any]] = []
        var hatStemDb: [Double] = []
        var mixes: [String: RenderedAudio] = [:]
        var stems: [String: RenderedAudio] = [:]
        for option in Self.l2Options {
            let hits = W4LBeats.l2(hatStep: option.step, lift: option.lift)
            let mix = try await W4LRig.render(hits, kit: kit, seconds: W4LBeats.renderSeconds)
            try await W4LRig.write(mix, to: rig.raw(option.file))
            gate("F: \(option.file) is finite and sounds",
                 W4LMeasure.allFinite(mix) && W4LMeasure.peakDb(mix) >= W4LMeasure.silenceFloorDb,
                 "peak \(W4LMeasure.r2(W4LMeasure.peakDb(mix))) dBFS")
            let hatHits = hits.filter { $0.voice == .closedHat || $0.voice == .openHat }
            let stem = try await W4LRig.render(hatHits, kit: kit, seconds: W4LBeats.renderSeconds)
            try await W4LRig.write(stem, to: rig.raw("stem-\(option.file)-hats"))
            let patternFrames = W4LBeats.sample(atBeat: W4LBeats.patternBeats * Double(W4LBeats.passes))
            let stemDb = W4LMeasure.db(W4LMeasure.power(stem, start: 0, count: patternFrames))
            hatStemDb.append(stemDb)
            mixes[option.id] = mix
            stems[option.id] = stem
            l2Rows.append(["option": option.id, "file": option.file, "notes": hits.count,
                           "hatHits": hatHits.count, "openHatHits": hatHits.filter { $0.voice == .openHat }.count,
                           "hatStemDb": W4LMeasure.r2(stemDb), "rawPeakDb": W4LMeasure.r2(W4LMeasure.peakDb(mix))])
        }
        for i in 1..<3 {
            let step = hatStemDb[i] - hatStemDb[i - 1]
            gate("DOUBLE: \(Self.l2Options[i - 1].id) -> \(Self.l2Options[i].id) hat energy +3 dB per doubling",
                 abs(step - 3.0103) <= 0.5, "step \(W4LMeasure.r2(step)) dB")
        }
        // The lift: both occurrences (beat 7.5 and 15.5), energy-mean.
        func liftWindowDb(_ audio: RenderedAudio, fromMs: Double, toMs: Double) -> Double {
            let starts = [7.5, 15.5].map { W4LBeats.sample(atBeat: $0) }
            let lo = Int(fromMs * 48), count = Int((toMs - fromMs) * 48)
            let total = starts.reduce(0.0) { $0 + W4LMeasure.power(audio, start: $1 + lo, count: count) }
            return W4LMeasure.db(total / 2)
        }
        let plain16 = try #require(stems["sixteenths"]), lift16 = try #require(stems["sixteenths-lift"])
        let ring = liftWindowDb(lift16, fromMs: 60, toMs: 125) - liftWindowDb(plain16, fromMs: 60, toMs: 125)
        let whole = liftWindowDb(lift16, fromMs: 0, toMs: 250) - liftWindowDb(plain16, fromMs: 0, toMs: 250)
        let mixPlain = try #require(mixes["sixteenths"]), mixLift = try #require(mixes["sixteenths-lift"])
        let inMix = liftWindowDb(mixLift, fromMs: 0, toMs: 250) - liftWindowDb(mixPlain, fromMs: 0, toMs: 250)
        gate("LIFT: the open hat rings where the closed hat has died (60-125 ms after the lift, >= 10 dB)",
             ring >= 10, "hat stem \(W4LMeasure.r2(ring)) dB")
        gate("LIFT: the lift window is louder in the full mix (>= 1 dB)", inMix >= 1,
             "mix \(W4LMeasure.r2(inMix)) dB, hat stem whole window \(W4LMeasure.r2(whole)) dB")
        // Outside the lift the two files are the same notes, so the same samples up to beat 7.5.
        let before = W4LBeats.sample(atBeat: 7.5)
        var identicalBefore = true
        for (x, y) in zip(mixPlain.channelData, mixLift.channelData) {
            for i in 0..<before where x[i].bitPattern != y[i].bitPattern { identicalBefore = false; break }
        }
        gate("LIFT: sixteenths and sixteenths-lift are bit-identical before the first lift", identicalBefore,
             "first \(before) frames")
        report["l2"] = l2Rows
        report["l2Lift"] = ["ringWindowDb": W4LMeasure.r2(ring), "wholeWindowHatDb": W4LMeasure.r2(whole),
                            "wholeWindowMixDb": W4LMeasure.r2(inMix),
                            "definition": "beat 7.5 (bar 2, the and of 4) on the open hat; the closed hat at 7.75 "
                                + "left out; twice per file (beats 7.5 and 15.5)"] as [String: Any]

        report["material"] = ["kit": "808 preset (DrumKitParams()) with the hat/cymbal trims above", "layout": "pads", "bpm": W4LBeats.bpm,
                              "sampleRate": W4LBeats.sampleRate, "renderSeconds": W4LBeats.renderSeconds,
                              "passes": W4LBeats.passes, "windowMs": 100,
                              "accentThreshold": kit.accentThreshold,
                              "hatsLevelDb": kit.hatsLevelDb, "cymbalsLevelDb": kit.cymbalsLevelDb,
                              "l1Options": Self.l1Options,
                              "accentDepth": kit.accentDepth] as [String: Any]
        report["gates"] = gates
        report["allGatesPass"] = gates.allSatisfy { ($0["pass"] as? Bool) == true }
        report["writtenAt"] = ISO8601DateFormatter().string(from: Date())
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: rig.out.appendingPathComponent("measure.json"))
        print("W4L-DONE gates \(gates.count) pass \(gates.filter { ($0["pass"] as? Bool) == true }.count) "
              + "out \(rig.out.path)")
    }
}
