import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// W9-STACK — DRUM MACHINE HITS THAT STACK PAST FULL SCALE: THE MEASURE (no product change).
//
// W9-PAT measured a kick and a rim entered by hand on the same beat, at today's entry
// velocity (100), peaking +0.99 dBTP on a NEW drum machine at fader 1.0. This suite
// renders every drum alone, every pair of the eight drums and three common three-drum
// stacks on one beat, through the export path (`DrumDefStage`, the DRUMHEAD rig), on a
// new drum machine and on each factory preset, and writes the numbers and the renders
// (for an ffmpeg cross-check outside the test). It also costs the options: per-drum
// level trims (real renders) and a simulated output limiter (applied to the renders).
//
// ENV-GATED: runs only with `DRUMSTACK=1`.
//   - `DRUMSTACK_DIR`: the gate's folder. Everything goes to `<dir>/out/<DRUMSTACK_PHASE>/`.
//   - `DRUMSTACK_VARIANTS`: `;`-separated, default `base`. Forms:
//       `base`
//       `trim:<name>:<drum>=<dB>,<drum>=<dB>` — each named drum's `level` scaled by
//         10^(dB/20) on every kit (a new drum machine and every preset): real renders.
//       `lim:<name>:<ceilingDb>/<releaseMs>/<lookaheadMs>` — a linked stereo peak limiter
//         (instant attack, sample-peak detection, exponential release, optional linear
//         lookahead ramp) applied to the base renders.
//
// Deliberately NOT `@MainActor` (no new MainActor suite): store and render steps run
// inside the `@MainActor` helpers of `DrumDefStage`.

/// Where the stack gate writes.
struct DrumStackRig: Sendable {
    let out: URL
    let wavs: URL
    let phase: String

    static func make() throws -> DrumStackRig {
        let env = ProcessInfo.processInfo.environment
        let dir = try #require(env["DRUMSTACK_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                               "DRUMSTACK_DIR must name the gate's folder")
        let phase = try #require(env["DRUMSTACK_PHASE"].flatMap { $0.isEmpty ? nil : $0 },
                                 "DRUMSTACK_PHASE must name this run")
        let out = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("out/\(phase)", isDirectory: true)
        let wavs = out.appendingPathComponent("wav", isDirectory: true)
        try FileManager.default.createDirectory(at: wavs, withIntermediateDirectories: true)
        return DrumStackRig(out: out, wavs: wavs, phase: phase)
    }
}

/// One way of building the kit or treating its output.
enum DrumStackVariant: Sendable {
    case base
    case trim(name: String, db: [DrumVoice: Double])
    case limiter(name: String, ceilingDb: Double, releaseMs: Double, lookaheadMs: Double)
    /// The tree's OWN `limiter` insert (`LimiterEffect`, 5 ms lookahead, PDC-reported latency) on the drum
    /// track: real renders through the export path.
    case insertLimiter(name: String, ceilingDb: Double, releaseMs: Double, truePeak: Bool)

    var name: String {
        switch self {
        case .base: return "base"
        case .trim(let name, _): return "trim-\(name)"
        case .limiter(let name, _, _, _): return "lim-\(name)"
        case .insertLimiter(let name, _, _, _): return "fx-\(name)"
        }
    }

    var isTrim: Bool { if case .trim = self { return true } else { return false } }

    /// nil on a malformed spec (the test then fails by name).
    static func parse(_ text: String) -> [DrumStackVariant]? {
        var result: [DrumStackVariant] = []
        for raw in text.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            if raw == "base" { result.append(.base); continue }
            let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            switch parts[0] {
            case "trim":
                var db: [DrumVoice: Double] = [:]
                for item in parts[2].split(separator: ",") {
                    let kv = item.split(separator: "=").map(String.init)
                    guard kv.count == 2, let voice = DrumVoice(rawValue: kv[0]), let value = Double(kv[1]) else { return nil }
                    db[voice] = value
                }
                result.append(.trim(name: parts[1], db: db))
            case "lim":
                let numbers = parts[2].split(separator: "/").compactMap { Double(String($0)) }
                guard numbers.count == 3 else { return nil }
                result.append(.limiter(name: parts[1], ceilingDb: numbers[0], releaseMs: numbers[1],
                                       lookaheadMs: numbers[2]))
            case "fx":
                let numbers = parts[2].split(separator: "/").compactMap { Double(String($0)) }
                guard numbers.count == 3 else { return nil }
                result.append(.insertLimiter(name: parts[1], ceilingDb: numbers[0], releaseMs: numbers[1],
                                             truePeak: numbers[2] >= 0.5))
            default:
                return nil
            }
        }
        return result
    }

    /// `kit` with this variant's level trims (a trim variant), else unchanged.
    func applied(to kit: DrumKitParams) -> DrumKitParams {
        guard case .trim(_, let db) = self else { return kit }
        var result = kit
        for (voice, trim) in db {
            result[voice].level = kit[voice].level * pow(10.0, trim / 20.0)
        }
        return result
    }
}

/// Plain numbers about a render (the app's own meter, `Loudness.measure`), and the
/// offline operations the options need.
enum DrumStackMath {
    static func tp(_ audio: RenderedAudio) -> Double { Loudness.measure(audio).truePeakDbtp ?? -999 }

    static func tpChannel(_ audio: RenderedAudio, _ channel: Int) -> Double {
        guard channel < audio.channelData.count else { return -999 }
        return tp(RenderedAudio(sampleRate: audio.sampleRate, channelData: [audio.channelData[channel]]))
    }

    /// Sample peak in dBFS, where (frame, channel) and its sign.
    static func samplePeak(_ audio: RenderedAudio) -> (db: Double, frame: Int, channel: Int, sign: Int) {
        var best: Float = 0, frame = 0, channel = 0, sign = 0
        for (c, data) in audio.channelData.enumerated() {
            for (i, x) in data.enumerated() where abs(x) > best {
                best = abs(x); frame = i; channel = c; sign = x < 0 ? -1 : 1
            }
        }
        return (20 * log10(max(Double(best), 1e-30)), frame, channel, sign)
    }

    /// `ga·a + gb·b`, b shifted later by `shiftB` frames and a by `shiftA` (zero-filled).
    static func mix(_ a: RenderedAudio, _ b: RenderedAudio, gainA: Float = 1, gainB: Float = 1,
                    shiftA: Int = 0, shiftB: Int = 0) -> RenderedAudio {
        let frames = min(a.frameCount, b.frameCount)
        var out: [[Float]] = []
        for c in 0..<min(a.channelData.count, b.channelData.count) {
            var channel = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let ia = i - shiftA, ib = i - shiftB
                let va: Float = ia >= 0 ? a.channelData[c][ia] : 0
                let vb: Float = ib >= 0 ? b.channelData[c][ib] : 0
                channel[i] = gainA * va + gainB * vb
            }
            out.append(channel)
        }
        return RenderedAudio(sampleRate: a.sampleRate, channelData: out)
    }

    static func maxAbsDiff(_ a: RenderedAudio, _ b: RenderedAudio) -> Double {
        var worst = 0.0
        for c in 0..<min(a.channelData.count, b.channelData.count) {
            for i in 0..<min(a.channelData[c].count, b.channelData[c].count) {
                worst = max(worst, Double(abs(a.channelData[c][i] - b.channelData[c][i])))
            }
        }
        return worst
    }

    /// A linked stereo peak limiter: per frame the gain that holds the louder channel's
    /// SAMPLE at `ceilingDb`; with a lookahead, that gain is reached by a linear ramp
    /// over the lookahead (the output would be `lookaheadMs` late); exponential release.
    /// Returns the audio, the frames with more than 0.01 dB of reduction, and the
    /// deepest reduction in dB. A render that never reaches the ceiling comes back
    /// UNCHANGED, sample for sample.
    static func limit(_ audio: RenderedAudio, ceilingDb: Double, releaseMs: Double,
                      lookaheadMs: Double) -> (audio: RenderedAudio, engaged: Int, deepestDb: Double) {
        let frames = audio.frameCount
        let ceiling = pow(10.0, ceilingDb / 20.0)
        var target = [Double](repeating: 1, count: frames)
        var any = false
        for i in 0..<frames {
            var peak = 0.0
            for channel in audio.channelData { peak = max(peak, Double(abs(channel[i]))) }
            if peak > ceiling { target[i] = ceiling / peak; any = true }
        }
        guard any else { return (audio, 0, 0) }
        let look = Int((lookaheadMs / 1000 * audio.sampleRate).rounded())
        var attack = target
        if look > 0 {
            for i in 0..<frames where target[i] < 1 {
                // Ramp from 1 (look frames before) down to target[i] (at i).
                for k in 1...look where i - k >= 0 {
                    let ramped = target[i] + (1 - target[i]) * Double(k) / Double(look + 1)
                    attack[i - k] = min(attack[i - k], ramped)
                }
            }
        }
        let release = exp(-1.0 / (releaseMs / 1000 * audio.sampleRate))
        var gain = 1.0, engaged = 0, deepest = 1.0
        var out = audio.channelData
        for i in 0..<frames {
            let t = attack[i]
            gain = t < gain ? t : t + (gain - t) * release
            if gain < 0.998849 { engaged += 1 }  // more than 0.01 dB
            deepest = min(deepest, gain)
            for c in 0..<out.count { out[c][i] = Float(Double(audio.channelData[c][i]) * gain) }
        }
        return (RenderedAudio(sampleRate: audio.sampleRate, channelData: out), engaged, 20 * log10(deepest))
    }

    static func sine(frequency: Double, amplitude: Double, phase: Double, seconds: Double) -> RenderedAudio {
        let fs = DrumDefStage.sampleRate
        let frames = Int(seconds * fs)
        let channel = (0..<frames).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / fs + phase)) }
        return RenderedAudio(sampleRate: fs, channelData: [channel, channel])
    }
}

/// A new drum machine with the tree's own `limiter` insert on its track.
@MainActor
enum DrumStackStage {
    static func newDrumMachineWithLimiter(kit: DrumKitParams?, bpm: Double, notes: [MIDINote], seconds: Double,
                                          ceilingDb: Double, releaseMs: Double, truePeak: Bool) throws -> RenderedAudio {
        let store = ProjectStore(projectName: "DRUMSTACK new drum machine + limiter")
        try store.setTempo(bpm)
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        if let kit {
            _ = try store.setInstrument(id: id, kind: .drumSynth, drumKit: kit)
        } else {
            _ = try store.setInstrument(id: id, kind: .drumSynth)
        }
        let fx = try store.addEffect(toTrack: id, kind: .limiter)
        try store.setEffectParam(trackID: id, effectID: fx.id, name: "ceilingDb", value: ceilingDb)
        try store.setEffectParam(trackID: id, effectID: fx.id, name: "releaseMs", value: releaseMs)
        try store.setEffectParam(trackID: id, effectID: fx.id, name: "truePeak", value: truePeak ? 1 : 0)
        let length = (notes.map(\.endBeat).max() ?? 4).rounded(.up)
        _ = try store.addMIDIClip(toTrack: id, name: "Beat", atBeat: 0, lengthBeats: length, notes: notes)
        return try DrumDefStage.render(store, seconds: seconds)
    }
}

@Suite("W9-STACK drum machine stacks — measure + options (DRUMSTACK=1 only)")
struct DrumStackGateTests {
    static let enabled = ProcessInfo.processInfo.environment["DRUMSTACK"] == "1"
    /// `DRUMSTACK_SKIP`: comma-separated `sweep` (the offline trim sweep), `basewav` (no WAV for base rows),
    /// `spread` (no extra positions). A second run re-uses the first run's base WAVs.
    static let skip = Set((ProcessInfo.processInfo.environment["DRUMSTACK_SKIP"] ?? "").split(separator: ",").map(String.init))

    static let voices = DrumVoice.allCases
    static let triples: [[DrumVoice]] = [[.kick, .snare, .closedHat], [.kick, .clap, .closedHat], [.kick, .rim, .closedHat]]

    static var stacks: [[DrumVoice]] {
        var all = voices.map { [$0] }
        for i in 0..<voices.count { for j in (i + 1)..<voices.count { all.append([voices[i], voices[j]]) } }
        return all + triples
    }

    static func label(_ stack: [DrumVoice]) -> String { stack.map(\.rawValue).joined(separator: "+") }

    static func notes(_ stack: [DrumVoice], velocity: Int, beat: Double, delays: [DrumVoice: Double] = [:]) -> [MIDINote] {
        stack.map { MIDINote(pitch: Int($0.primaryNote(in: .gm)), velocity: velocity,
                             startBeat: beat + (delays[$0] ?? 0), lengthBeats: 0.25) }
    }

    /// A new drum machine (nil: born as the picker births one) and each factory preset
    /// loaded onto one, at their shipped gains.
    static var kits: [(name: String, kit: DrumKitParams?)] {
        var result: [(name: String, kit: DrumKitParams?)] = [(name: "new", kit: nil)]
        for preset in DrumKitParams.presets {
            result.append((name: "preset-\(preset.name)", kit: DrumKitParams.newDrumMachineKit.applyingPreset(preset)))
        }
        return result
    }

    static func kitInfo(_ kit: DrumKitParams) -> [String: Any] {
        var info: [String: Any] = ["gain": kit.gain, "accentThreshold": kit.accentThreshold,
                                   "accentDepth": kit.accentDepth, "velocityToTone": kit.velocityToTone,
                                   "hatsLevelDb": kit.hatsLevelDb, "cymbalsLevelDb": kit.cymbalsLevelDb,
                                   "noteLayout": kit.noteLayout.rawValue]
        for voice in voices {
            let p = kit[voice]
            info[voice.rawValue] = ["level": p.level, "pan": p.pan, "velocity": p.velocity, "drive": p.drive,
                                    "tone": p.tone, "snap": p.snap, "decay": p.decay, "tune": p.tune]
        }
        return info
    }

    @Test("DRUMSTACK: every drum alone, every pair, three stacks; spread, offsets, normal beats; the options",
          .enabled(if: DrumStackGateTests.enabled))
    func measureAndWrite() async throws {
        let rig = try DrumStackRig.make()
        let spec = ProcessInfo.processInfo.environment["DRUMSTACK_VARIANTS"].flatMap { $0.isEmpty ? nil : $0 } ?? "base"
        let variants = try #require(DrumStackVariant.parse(spec), "malformed DRUMSTACK_VARIANTS: \(spec)")
        var rows: [[String: Any]] = []
        var wavCount = 0
        let started = Date()

        func row(_ section: String, _ variant: String, _ kit: String, _ stack: String, velocity: Int, beat: Double,
                 _ audio: RenderedAudio, wav: Bool, extra: [String: Any] = [:]) async throws {
            let loud = Loudness.measure(audio)
            let peak = DrumStackMath.samplePeak(audio)
            var entry: [String: Any] = [
                "section": section, "variant": variant, "kit": kit, "stack": stack, "velocity": velocity, "beat": beat,
                "tp": loud.truePeakDbtp ?? -999, "lufs": loud.integratedLufs ?? -999,
                "tpL": Self.skip.contains("perchannel") ? -999 : DrumStackMath.tpChannel(audio, 0),
                "tpR": Self.skip.contains("perchannel") ? -999 : DrumStackMath.tpChannel(audio, 1),
                "sp": peak.db, "spFrame": peak.frame, "spChannel": peak.channel, "spSign": peak.sign,
                "frames": audio.frameCount, "digest": DrumDefMeasure.digest(audio),
            ]
            if wav && !(Self.skip.contains("basewav") && variant == "base") {
                wavCount += 1
                let name = String(format: "%05d", wavCount) + "-\(section)-\(variant)-\(kit)-\(stack)-v\(velocity)-b\(beat).wav"
                try await DrumDefStage.write(audio, to: rig.wavs.appendingPathComponent(name))
                entry["wav"] = name
            }
            for (key, value) in extra { entry[key] = value }
            rows.append(entry)
        }

        // ---- 0. METER POSITIVE CONTROLS (the same meter, the same WAV writer).
        let controls: [(String, RenderedAudio)] = [
            ("fs4-pi4-amp1", DrumStackMath.sine(frequency: 12_000, amplitude: 1, phase: .pi / 4, seconds: 1)),
            ("6k-pi8-amp1", DrumStackMath.sine(frequency: 6_000, amplitude: 1, phase: .pi / 8, seconds: 1)),
            ("997-amp0.5", DrumStackMath.sine(frequency: 997, amplitude: 0.5, phase: 0, seconds: 1)),
            ("997-amp1.5", DrumStackMath.sine(frequency: 997, amplitude: 1.5, phase: 0, seconds: 1)),
        ]
        for (name, audio) in controls {
            try await row("control", "base", "-", name, velocity: 0, beat: 0, audio, wav: true)
        }
        let fs4 = Loudness.measure(controls[0].1).truePeakDbtp ?? -999
        #expect(abs(DrumStackMath.samplePeak(controls[0].1).db - (-3.0103)) < 0.01, "control: fs/4 pi/4 samples at -3.01")
        #expect(fs4 > -0.5 && fs4 < 0.7, "control: the meter looks between samples (fs/4 pi/4 reads \(fs4))")
        #expect(abs((Loudness.measure(controls[2].1).truePeakDbtp ?? -999) - (-6.0206)) < 0.05, "control: 0.5 sine")
        #expect(abs((Loudness.measure(controls[3].1).truePeakDbtp ?? -999) - 3.5218) < 0.05, "control: 1.5 sine over 0")

        // ---- 1. W9-PAT's four numbers, reproduced (a NEW drum machine, single hits on beat 1, 120 BPM).
        let repro: [([DrumVoice], Int, Double)] = [([.kick], 112, -5.66), ([.rim], 112, -1.46),
                                                  ([.kick, .rim], 100, 0.99), ([.kick, .snare], 112, -0.37),
                                                  ([.kick, .rim], 112, 1.73)]
        for (stack, velocity, expected) in repro {
            let r = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 120, notes: Self.notes(stack, velocity: velocity, beat: 0),
                                                          seconds: 0.75)
            try await row("repro", "base", "new", Self.label(stack), velocity: velocity, beat: 0, r.1, wav: true,
                          extra: ["patValue": expected])
        }

        // ---- 2. Rig controls: born == explicit new kit == 808 preset on a new kit; export == instrument alone.
        let kr = Self.notes([.kick, .rim], velocity: 100, beat: 0)
        let born = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 120, notes: kr, seconds: 0.75)
        let explicit = try await DrumDefStage.newDrumMachine(kit: DrumKitParams.newDrumMachineKit, bpm: 120, notes: kr, seconds: 0.75)
        let the808 = try #require(DrumKitParams.preset(named: "808"))
        let preset808 = try await DrumDefStage.newDrumMachine(
            kit: DrumKitParams.newDrumMachineKit.applyingPreset(the808), bpm: 120, notes: kr, seconds: 0.75)
        #expect(DrumDefMeasure.digest(born.1) == DrumDefMeasure.digest(explicit.1), "control: born == explicit new kit")
        #expect(DrumDefMeasure.digest(born.1) == DrumDefMeasure.digest(preset808.1), "control: born == 808 on a new kit")
        let raw = try DrumDefStage.renderInstrumentAlone(kit: DrumKitParams.newDrumMachineKit,
                                                         notes: [(36, 0, 100), (37, 0, 100)], bpm: 120, seconds: 0.75)
        let rawAudio = RenderedAudio(sampleRate: DrumDefStage.sampleRate,
                                     channelData: [stride(from: 0, to: raw.count, by: 2).map { raw[$0] },
                                                   stride(from: 1, to: raw.count, by: 2).map { raw[$0] }])
        let exportVsRaw = DrumStackMath.maxAbsDiff(born.1, rawAudio)
        rows.append(["section": "rigcheck", "bornDigest": DrumDefMeasure.digest(born.1),
                     "explicitDigest": DrumDefMeasure.digest(explicit.1), "preset808Digest": DrumDefMeasure.digest(preset808.1),
                     "exportVsInstrumentMaxAbs": exportVsRaw, "exportFrames": born.1.frameCount, "rawFrames": rawAudio.frameCount,
                     "tpExport": DrumStackMath.tp(born.1), "tpInstrument": DrumStackMath.tp(rawAudio)])

        // ---- 3. THE STACKS: every kit x every stack x velocity, beat 1. Base renders kept for the limiter variants
        //         and the linearity check; trim variants re-render.
        var kitRows: [[String: Any]] = []
        for (name, kit) in Self.kits {
            kitRows.append(["kit": name, "params": Self.kitInfo(kit ?? DrumKitParams.newDrumMachineKit)])
        }
        rows.append(["section": "kits", "kits": kitRows])

        var baseRenders: [String: RenderedAudio] = [:]  // "<kit>|<stack>|<velocity>|<beat>"
        func key(_ kit: String, _ stack: [DrumVoice], _ velocity: Int, _ beat: Double) -> String {
            "\(kit)|\(Self.label(stack))|\(velocity)|\(beat)"
        }
        for (kitName, kit) in Self.kits {
            let velocities = kitName == "new" ? [85, 100, 127] : [100, 127]
            for velocity in velocities {
                for stack in Self.stacks {
                    let notes = Self.notes(stack, velocity: velocity, beat: 0)
                    let rendered = try await DrumDefStage.newDrumMachine(kit: kit, bpm: 120, notes: notes, seconds: 0.75)
                    baseRenders[key(kitName, stack, velocity, 0)] = rendered.1
                    var extra: [String: Any] = [:]
                    if stack.count == 2, let a = baseRenders[key(kitName, [stack[0]], velocity, 0)],
                       let b = baseRenders[key(kitName, [stack[1]], velocity, 0)] {
                        let sum = DrumStackMath.mix(a, b)
                        extra["tpOfflineSum"] = DrumStackMath.tp(sum)
                        extra["tpOfflineDiff"] = DrumStackMath.tp(DrumStackMath.mix(a, b, gainB: -1))
                        extra["pairMinusSumMaxAbs"] = DrumStackMath.maxAbsDiff(rendered.1, sum)
                    }
                    if variants.contains(where: { $0.name == "base" }) {
                        try await row("stack", "base", kitName, Self.label(stack), velocity: velocity, beat: 0, rendered.1,
                                      wav: true, extra: extra)
                    }
                }
            }
        }

        // ---- 4. Position spread (the noise-seeded voices): a new drum machine, v100, three more positions.
        let spreadBeats = Self.skip.contains("spread") ? [] : [1.0, 2.5, 3.25]
        for beat in spreadBeats {
            for stack in Self.stacks {
                let rendered = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 120, notes: Self.notes(stack, velocity: 100, beat: beat),
                                                                     seconds: beat * 0.5 + 0.75)
                baseRenders[key("new", stack, 100, beat)] = rendered.1
                try await row("spread", "base", "new", Self.label(stack), velocity: 100, beat: beat, rendered.1, wav: true)
            }
        }

        // ---- 5. Coincidence: kick + rim (new kit, v100) with one of them moved by a few milliseconds.
        if let kick = baseRenders[key("new", [.kick], 100, 0)], let rim = baseRenders[key("new", [.rim], 100, 0)] {
            for shiftMs in [-10.0, -5, -2, -1, -0.5, 0, 0.25, 0.5, 1, 1.5, 2, 3, 5, 10, 20] {
                let frames = Int((abs(shiftMs) / 1000 * DrumDefStage.sampleRate).rounded())
                let mixed = shiftMs >= 0 ? DrumStackMath.mix(kick, rim, shiftB: frames) : DrumStackMath.mix(kick, rim, shiftA: frames)
                rows.append(["section": "offset-offline", "stack": "kick+rim", "velocity": 100, "rimLaterMs": shiftMs,
                             "tp": DrumStackMath.tp(mixed)])
            }
        }
        for delayMs in [2.0, 5.0] {
            let delay = delayMs / 1000 / 0.5  // beats at 120 BPM
            let rendered = try await DrumDefStage.newDrumMachine(
                kit: nil, bpm: 120, notes: Self.notes([.kick, .rim], velocity: 100, beat: 0, delays: [.rim: delay]), seconds: 0.75)
            try await row("offset-render", "base", "new", "kick+rim", velocity: 100, beat: 0, rendered.1, wav: true,
                          extra: ["rimLaterMs": delayMs])
        }

        // ---- 6. Offline trim sweep (a drum's `level` is a pure output multiplier, DrumSynthInstrument.swift:1020):
        //         the worst pair/triple on a new drum machine with ONE drum scaled.
        for velocity in Self.skip.contains("sweep") ? [] : [100, 127] {
            for voice in Self.voices {
                for trim in [-1.0, -2, -3, -4, -6, -8] {
                    var worst = -999.0, worstStack = ""
                    for stack in Self.stacks where stack.count >= 2 {
                        if stack.contains(.closedHat) && stack.contains(.openHat) { continue }  // the choke pair is not a sum
                        var mixed: RenderedAudio?
                        for member in stack {
                            guard let single = baseRenders[key("new", [member], velocity, 0)] else { continue }
                            let gain = Float(member == voice ? pow(10.0, trim / 20.0) : 1.0)
                            if let current = mixed {
                                mixed = DrumStackMath.mix(current, single, gainB: gain)
                            } else {
                                mixed = DrumStackMath.mix(single, single, gainA: gain, gainB: 0)
                            }
                        }
                        if let mixed {
                            let value = DrumStackMath.tp(mixed)
                            if value > worst { worst = value; worstStack = Self.label(stack) }
                        }
                    }
                    rows.append(["section": "trim-sweep-offline", "velocity": velocity, "voice": voice.rawValue,
                                 "trimDb": trim, "worstTp": worst, "worstStack": worstStack])
                }
            }
        }

        // ---- 7. Normal beats: the 808 audition beat (W9-HEAD's) and every shipped pattern, 4 bars, 120 BPM.
        var beats: [(String, [MIDINote], Double)] = [("audition808", DrumDefBeats.templateBeat(bars: 2), 6)]
        let gmNotes = Dictionary(uniqueKeysWithValues: Self.voices.map { ($0, Int($0.primaryNote(in: .gm))) })
        for pattern in DrumPatternLibrary.patterns {
            beats.append(("pattern-\(pattern.id)", DrumPatternLibrary.notes(for: pattern, bars: 4, roleNotes: gmNotes).notes, 9))
        }
        var baseBeats: [String: RenderedAudio] = [:]
        for (kitName, kit) in Self.kits {
            for (beatName, notes, seconds) in beats {
                let rendered = try await DrumDefStage.newDrumMachine(kit: kit, bpm: 120, notes: notes, seconds: seconds)
                baseBeats["\(kitName)|\(beatName)"] = rendered.1
                if variants.contains(where: { $0.name == "base" }) {
                    try await row("normal", "base", kitName, beatName, velocity: 0, beat: 0, rendered.1, wav: true)
                }
            }
        }

        // ---- 8. The variants.
        for variant in variants {
            switch variant {
            case .base:
                continue
            case .limiter(_, let ceilingDb, let releaseMs, let lookaheadMs):
                for (kitName, _) in Self.kits {
                    let velocities = kitName == "new" ? [85, 100, 127] : [100, 127]
                    for velocity in velocities {
                        for stack in Self.stacks {
                            guard let audio = baseRenders[key(kitName, stack, velocity, 0)] else { continue }
                            let limited = DrumStackMath.limit(audio, ceilingDb: ceilingDb, releaseMs: releaseMs, lookaheadMs: lookaheadMs)
                            try await row("stack", variant.name, kitName, Self.label(stack), velocity: velocity, beat: 0,
                                          limited.audio, wav: kitName == "new",
                                          extra: ["engagedFrames": limited.engaged, "deepestDb": limited.deepestDb])
                        }
                    }
                    for (beatName, _, _) in beats {
                        guard let audio = baseBeats["\(kitName)|\(beatName)"] else { continue }
                        let limited = DrumStackMath.limit(audio, ceilingDb: ceilingDb, releaseMs: releaseMs, lookaheadMs: lookaheadMs)
                        try await row("normal", variant.name, kitName, beatName, velocity: 0, beat: 0, limited.audio,
                                      wav: kitName == "new",
                                      extra: ["engagedFrames": limited.engaged, "deepestDb": limited.deepestDb,
                                              "identicalToBase": DrumDefMeasure.digest(limited.audio) == DrumDefMeasure.digest(audio)])
                    }
                }
                for beat in spreadBeats {
                    for stack in Self.stacks {
                        guard let audio = baseRenders[key("new", stack, 100, beat)] else { continue }
                        let limited = DrumStackMath.limit(audio, ceilingDb: ceilingDb, releaseMs: releaseMs, lookaheadMs: lookaheadMs)
                        try await row("spread", variant.name, "new", Self.label(stack), velocity: 100, beat: beat,
                                      limited.audio, wav: false, extra: ["engagedFrames": limited.engaged])
                    }
                }
            case .insertLimiter(_, let ceilingDb, let releaseMs, let truePeak):
                // The base renders shifted by the limiter's lookahead: what an untouched render must equal.
                let latency = LimiterParams.lookaheadSamples(sampleRate: DrumDefStage.sampleRate)
                for (kitName, kit) in Self.kits {
                    let velocities = kitName == "new" ? [85, 100, 127] : [100, 127]
                    for velocity in velocities {
                        for stack in Self.stacks {
                            let audio = try await DrumStackStage.newDrumMachineWithLimiter(
                                kit: kit, bpm: 120, notes: Self.notes(stack, velocity: velocity, beat: 0), seconds: 0.75,
                                ceilingDb: ceilingDb, releaseMs: releaseMs, truePeak: truePeak)
                            var extra: [String: Any] = ["latency": latency]
                            if let base = baseRenders[key(kitName, stack, velocity, 0)] {
                                let shifted = DrumStackMath.mix(base, base, gainB: 0, shiftA: latency)
                                extra["vsShiftedBaseMaxAbs"] = DrumStackMath.maxAbsDiff(audio, shifted)
                                extra["vsBaseMaxAbs"] = DrumStackMath.maxAbsDiff(audio, base)
                            }
                            try await row("stack", variant.name, kitName, Self.label(stack), velocity: velocity, beat: 0,
                                          audio, wav: kitName == "new", extra: extra)
                        }
                    }
                    for (beatName, notes, seconds) in beats {
                        let audio = try await DrumStackStage.newDrumMachineWithLimiter(
                            kit: kit, bpm: 120, notes: notes, seconds: seconds,
                            ceilingDb: ceilingDb, releaseMs: releaseMs, truePeak: truePeak)
                        var extra: [String: Any] = ["latency": latency]
                        if let base = baseBeats["\(kitName)|\(beatName)"] {
                            let shifted = DrumStackMath.mix(base, base, gainB: 0, shiftA: latency)
                            extra["vsShiftedBaseMaxAbs"] = DrumStackMath.maxAbsDiff(audio, shifted)
                            extra["vsBaseMaxAbs"] = DrumStackMath.maxAbsDiff(audio, base)
                        }
                        try await row("normal", variant.name, kitName, beatName, velocity: 0, beat: 0, audio,
                                      wav: kitName == "new", extra: extra)
                    }
                }
            case .trim(_, let db):
                // A new drum machine: REAL renders, checked against the offline prediction from the base singles
                // (the trim is a pure post-gain, DrumSynthInstrument.swift:1020, and a pair is an exact sum). The presets:
                // that prediction (exact, validated on the new kit), except the choke pair, which is rendered.
                for (kitName, kit) in Self.kits {
                    let trimmed = variant.applied(to: kit ?? DrumKitParams.newDrumMachineKit)
                    let velocities = kitName == "new" ? [85, 100, 127] : [100, 127]
                    for velocity in velocities {
                        for stack in Self.stacks {
                            var predicted: RenderedAudio?
                            for member in stack {
                                guard let single = baseRenders[key(kitName, [member], velocity, 0)] else { continue }
                                let gain = Float(pow(10.0, (db[member] ?? 0) / 20.0))
                                predicted = predicted.map { DrumStackMath.mix($0, single, gainB: gain) }
                                    ?? DrumStackMath.mix(single, single, gainA: gain, gainB: 0)
                            }
                            let choke = stack.contains(.closedHat) && stack.contains(.openHat)
                            if kitName == "new" || choke {
                                let rendered = try await DrumDefStage.newDrumMachine(
                                    kit: trimmed, bpm: 120, notes: Self.notes(stack, velocity: velocity, beat: 0), seconds: 0.75)
                                var extra: [String: Any] = ["predicted": false]
                                if let predicted, !choke {
                                    extra["predictedMaxAbs"] = DrumStackMath.maxAbsDiff(rendered.1, predicted)
                                }
                                try await row("stack", variant.name, kitName, Self.label(stack), velocity: velocity, beat: 0,
                                              rendered.1, wav: kitName == "new", extra: extra)
                            } else if let predicted {
                                try await row("stack", variant.name, kitName, Self.label(stack), velocity: velocity, beat: 0,
                                              predicted, wav: false, extra: ["predicted": true])
                            }
                        }
                    }
                    for (beatName, notes, seconds) in beats {
                        let touched = notes.contains { note in
                            guard let voice = DrumVoice.voice(forNote: UInt8(note.pitch), layout: .gm) else { return false }
                            return (db[voice] ?? 0) != 0
                        }
                        if touched {
                            let rendered = try await DrumDefStage.newDrumMachine(kit: trimmed, bpm: 120, notes: notes, seconds: seconds)
                            try await row("normal", variant.name, kitName, beatName, velocity: 0, beat: 0, rendered.1,
                                          wav: kitName == "new", extra: ["rendered": true])
                        } else if let audio = baseBeats["\(kitName)|\(beatName)"] {
                            // No trimmed drum plays in this beat: it is the base render, by construction.
                            try await row("normal", variant.name, kitName, beatName, velocity: 0, beat: 0, audio,
                                          wav: false, extra: ["rendered": false])
                        }
                    }
                }
                let trimmedNew = variant.applied(to: DrumKitParams.newDrumMachineKit)
                for beat in spreadBeats {
                    for stack in Self.stacks {
                        let rendered = try await DrumDefStage.newDrumMachine(
                            kit: trimmedNew, bpm: 120, notes: Self.notes(stack, velocity: 100, beat: beat), seconds: beat * 0.5 + 0.75)
                        try await row("spread", variant.name, "new", Self.label(stack), velocity: 100, beat: beat,
                                      rendered.1, wav: false)
                    }
                }
            }
        }

        let report: [String: Any] = ["phase": rig.phase, "variants": variants.map(\.name), "rows": rows,
                                     "wavCount": wavCount, "seconds": Date().timeIntervalSince(started)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: rig.out.appendingPathComponent("measure.json"))
        #expect(rows.count > 500, "the gate wrote \(rows.count) rows")
    }
}

// MARK: - W10-STACKL — the safety limiter on every NEW drum machine (m39-dm-stack b2, the user's pick)
//
// A BEFORE/AFTER file gate for the default `DrumSafetyLimiter` (a drum machine BORN on a fresh track gets the
// tree's own `limiter` insert, true peak). The same code runs on the tree without the default (`before`) and
// with it (`after`); the after phase reads the before phase's renders back and compares them sample for sample.
// It does not name `DrumSafetyLimiter`, so it compiles on both trees.
//
// ENV-GATED: runs only with `DRUMSTACKL=1`.
//   - `DRUMSTACKL_DIR`: the gate's folder. Writes `<dir>/out/<DRUMSTACKL_PHASE>/` (raw renders + measure.json).
//   - `DRUMSTACKL_PHASE`: `before` or `after` (any name; `DRUMSTACKL_BEFORE` names the phase to compare with).
//   - `DRUMSTACKL_BEFORE`: the before phase's name. When set, every render is compared with its before render.
//   - `DRUMSTACKL_CEILINGS`: `;`-separated ceilings (dBTP) to try on the born limiter (after phase).
//   - `DRUMSTACKL_FIXTURES`: a folder with `saved-nil-kit.dawproj` + `saved-old-kit.dawproj` (songs saved before).
//   - `DRUMSTACKL_LISTEN`: where the A/B listening WAVs go.
//
// Sections: 1 ordinary beats (gate 1, ceilings) · 2 overshoot stacks (gate 2) · 3 a full song: mix, stems, the
// uncompensated control, the live graph's plan, bounce in place (gate 3) · 4 saved songs (gate 5) ·
// 5 the factory templates' drum tracks (out of scope: what a limiter WOULD change) · 6 listening files (gate 6).

/// Where the STACKL gate reads and writes.
struct DrumSafetyRig: Sendable {
    let out: URL
    let raw: URL
    let before: URL?
    let phase: String
    let ceilings: [Double]
    let fixtures: URL?
    let listen: URL?

    static func make() throws -> DrumSafetyRig {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        let dir = try #require(value("DRUMSTACKL_DIR"), "DRUMSTACKL_DIR must name the gate's folder")
        let phase = try #require(value("DRUMSTACKL_PHASE"), "DRUMSTACKL_PHASE must name this run")
        let root = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("out", isDirectory: true)
        let out = root.appendingPathComponent(phase, isDirectory: true)
        let raw = out.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let before = value("DRUMSTACKL_BEFORE").map { root.appendingPathComponent($0, isDirectory: true) }
        let ceilings = (value("DRUMSTACKL_CEILINGS") ?? "").split(separator: ";").compactMap { Double(String($0)) }
        let listen = value("DRUMSTACKL_LISTEN").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let listen { try FileManager.default.createDirectory(at: listen, withIntermediateDirectories: true) }
        return DrumSafetyRig(out: out, raw: raw, before: before, phase: phase, ceilings: ceilings,
                             fixtures: value("DRUMSTACKL_FIXTURES").map { URL(fileURLWithPath: $0, isDirectory: true) },
                             listen: listen)
    }

    /// The before phase's render of `name`, nil in a before phase or when it was not written.
    func beforeRender(_ name: String) throws -> RenderedAudio? {
        guard let before else { return nil }
        let url = before.appendingPathComponent("raw/\(name).f32")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try DrumSafetyIO.read(url)
    }
}

/// Planar stereo float files: every left sample, then every right sample.
enum DrumSafetyIO {
    static func write(_ audio: RenderedAudio, to url: URL) throws {
        var all: [Float] = []
        all.reserveCapacity(audio.frameCount * audio.channelData.count)
        for channel in audio.channelData { all.append(contentsOf: channel) }
        try all.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
    }

    static func read(_ url: URL) throws -> RenderedAudio {
        let data = try Data(contentsOf: url)
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = floats.count / 2
        return RenderedAudio(sampleRate: DrumDefStage.sampleRate,
                             channelData: [Array(floats[0..<frames]), Array(floats[frames..<(2 * frames)])])
    }
}

/// Comparisons a delayed copy needs.
enum DrumSafetyMath {
    /// `out[n] == ref[n - shift]` for every frame of `out` (zero before `shift`), BIT FOR BIT.
    static func isShifted(_ out: RenderedAudio, _ ref: RenderedAudio, by shift: Int) -> Bool {
        guard out.channelData.count == ref.channelData.count, out.frameCount == ref.frameCount else { return false }
        for c in 0..<out.channelData.count {
            let o = out.channelData[c], r = ref.channelData[c]
            for i in 0..<o.count {
                let expected: Float = i - shift >= 0 && i - shift < r.count ? r[i - shift] : 0
                if o[i].bitPattern != expected.bitPattern { return false }
            }
        }
        return true
    }

    /// max |out[n] - ref[n - shift]|.
    static func maxDiffShifted(_ out: RenderedAudio, _ ref: RenderedAudio, by shift: Int) -> Double {
        var worst = 0.0
        for c in 0..<min(out.channelData.count, ref.channelData.count) {
            let o = out.channelData[c], r = ref.channelData[c]
            for i in 0..<o.count {
                let expected: Float = i - shift >= 0 && i - shift < r.count ? r[i - shift] : 0
                worst = max(worst, Double(abs(o[i] - expected)))
            }
        }
        return worst
    }

    /// The limiter's gain reduction read off the audio: per frame, the output over the input delayed by `shift`
    /// (the louder channel of the input, where it is above -60 dBFS). Returns the deepest reduction in dB (a
    /// POSITIVE number, 0 = untouched), how many frames were reduced by more than 0.001 dB, and how many frames
    /// are NOT a gain of at most 1 on the input (a sign flip or a rise: then `out` is not this input limited, and
    /// the reduction figure is meaningless — another source is in the render).
    static func gainReduction(_ out: RenderedAudio, _ ref: RenderedAudio, shift: Int)
        -> (db: Double, frames: Int, mismatched: Int) {
        var deepest = 1.0, frames = 0, mismatched = 0
        let n = out.frameCount
        for i in 0..<n {
            let j = i - shift
            guard j >= 0, j < ref.frameCount else { continue }
            var best = 0, loud: Float = 0
            for c in 0..<min(out.channelData.count, ref.channelData.count) where abs(ref.channelData[c][j]) > loud {
                loud = abs(ref.channelData[c][j]); best = c
            }
            guard loud > 0.001 else { continue }
            let g = Double(out.channelData[best][i]) / Double(ref.channelData[best][j])
            if g < 0 || g > 1.000001 { mismatched += 1; continue }
            if g < 0.999885 { frames += 1 }  // more than 0.001 dB
            deepest = min(deepest, g)
        }
        return (-20 * log10(max(deepest, 1e-12)), frames, mismatched)
    }

    /// The first frame where either channel is louder than `threshold`, nil for silence.
    static func onset(_ audio: RenderedAudio, threshold: Float = 0.01) -> Int? {
        for i in 0..<audio.frameCount where audio.channelData.contains(where: { abs($0[i]) > threshold }) {
            return i
        }
        return nil
    }

    /// The lag (frames, `out` later = positive) in `-maxLag...maxLag` with the largest cross-correlation of the
    /// two mono sums, over `window` frames from `start`.
    static func bestLag(_ out: RenderedAudio, _ ref: RenderedAudio, maxLag: Int, start: Int, window: Int) -> Int {
        func mono(_ a: RenderedAudio) -> [Double] {
            (0..<a.frameCount).map { i in a.channelData.reduce(0.0) { $0 + Double($1[i]) } }
        }
        let o = mono(out), r = mono(ref)
        var bestLag = 0, best = -Double.infinity
        for lag in -maxLag...maxLag {
            var sum = 0.0
            let lo = max(start, lag), hi = min(start + window, o.count, r.count + lag)
            if lo >= hi { continue }
            for i in lo..<hi { sum += o[i] * r[i - lag] }
            if sum > best { best = sum; bestLag = lag }
        }
        return bestLag
    }
}

/// The store side of the gate: a drum machine born the way the picker and `track.setInstrument {kind:
/// "drumSynth"}` birth one, and a small song.
@MainActor
enum DrumSafetyStage {
    enum Edit { case none, removeLimiter, ceiling(Double) }

    struct Born {
        let effects: [EffectDescriptor]
        let audio: RenderedAudio
        let edited: Bool
    }

    static func limiterIDs(_ track: Track?) -> [UUID] {
        (track?.effects ?? []).filter { $0.kind == .limiter }.map(\.id)
    }

    /// A drum machine born on a fresh instrument track (with `kit` spelled out, or the picker's new kit), its
    /// chain then edited by `edit`, `notes` written, rendered through the export path.
    static func born(kit: DrumKitParams?, notes: [MIDINote], seconds: Double, edit: Edit = .none) throws -> Born {
        let store = ProjectStore(projectName: "STACKL born drum machine")
        try store.setTempo(120)
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        if let kit {
            _ = try store.setInstrument(id: id, kind: .drumSynth, drumKit: kit)
        } else {
            _ = try store.setInstrument(id: id, kind: .drumSynth)
        }
        let effects = store.tracks.first { $0.id == id }?.effects ?? []
        var edited = false
        if let limiter = limiterIDs(store.tracks.first { $0.id == id }).first {
            switch edit {
            case .none: break
            case .removeLimiter:
                try store.removeEffect(trackID: id, effectID: limiter); edited = true
            case .ceiling(let db):
                try store.setEffectParam(trackID: id, effectID: limiter, name: "ceilingDb", value: db); edited = true
            }
        }
        let length = (notes.map(\.endBeat).max() ?? 4).rounded(.up)
        _ = try store.addMIDIClip(toTrack: id, name: "Beat", atBeat: 0, lengthBeats: length, notes: notes)
        return Born(effects: effects, audio: try DrumDefStage.render(store, seconds: seconds), edited: edited)
    }

    // MARK: The full song (gate 3)

    nonisolated static let songSeconds = 10.0

    /// A one-beat "pluck" every beat for 8 s: the audio clip's file (identical in every phase).
    nonisolated static func pluckLoop() -> RenderedAudio {
        let fs = DrumDefStage.sampleRate
        let frames = Int(8 * fs)
        var channel = [Float](repeating: 0, count: frames)
        for beat in 0..<16 {
            let start = beat * Int(0.5 * fs)
            for k in 0..<Int(0.12 * fs) where start + k < frames {
                let t = Double(k) / fs
                channel[start + k] = Float(0.3 * exp(-t * 30) * sin(2 * .pi * 880 * t))
            }
        }
        return RenderedAudio(sampleRate: fs, channelData: [channel, channel])
    }

    struct Song {
        let store: ProjectStore
        let drums: UUID
        let bass: UUID
        let keys: UUID
        let loop: UUID
    }

    /// Drum machine (born, `pattern` for 4 bars) + a Poly Synth bass + a Poly Synth keys part + one audio clip.
    static func song(pattern: String, audioFile: URL, engine: AudioEngine?) throws -> Song {
        let store = ProjectStore(projectName: "STACKL full song")
        if let engine { store.engine = engine }
        try store.setTempo(120)
        let drums = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: drums, kind: .drumSynth)
        let gm = Dictionary(uniqueKeysWithValues: DrumVoice.allCases.map { ($0, Int($0.primaryNote(in: .gm))) })
        let beat = try #require(DrumPatternLibrary.pattern(named: pattern))
        _ = try store.addMIDIClip(toTrack: drums, name: "Beat", atBeat: 0, lengthBeats: 16,
                                  notes: DrumPatternLibrary.notes(for: beat, bars: 4, roleNotes: gm).notes)

        let bass = store.addTrack(name: "Bass", kind: .instrument).id
        _ = try store.setInstrument(id: bass, kind: .polySynth, waveform: .saw)
        let roots = [36, 36, 41, 43]
        let bassNotes = (0..<16).map { MIDINote(pitch: roots[($0 / 4) % 4], velocity: 100, startBeat: Double($0),
                                                lengthBeats: 0.45) }
        _ = try store.addMIDIClip(toTrack: bass, name: "Bass", atBeat: 0, lengthBeats: 16, notes: bassNotes)

        let keys = store.addTrack(name: "Keys", kind: .instrument).id
        _ = try store.setInstrument(id: keys, kind: .polySynth, waveform: .triangle)
        var keyNotes: [MIDINote] = []
        for bar in 0..<4 {
            for pitch in [60, 64, 67].map({ $0 + roots[bar] - 36 }) {
                keyNotes.append(MIDINote(pitch: pitch, velocity: 90, startBeat: Double(bar * 4) + 1, lengthBeats: 1))
                keyNotes.append(MIDINote(pitch: pitch, velocity: 90, startBeat: Double(bar * 4) + 3, lengthBeats: 1))
            }
        }
        _ = try store.addMIDIClip(toTrack: keys, name: "Keys", atBeat: 0, lengthBeats: 16, notes: keyNotes)

        let loop = store.addTrack(name: "Loop", kind: .audio).id
        _ = store.updateTrack(id: loop) {
            $0.clips = [Clip(name: "Pluck", startBeat: 0, lengthBeats: 16, audioFileURL: audioFile)]
        }
        return Song(store: store, drums: drums, bass: bass, keys: keys, loop: loop)
    }

    /// The export path over `tracks` (default: the song's), with the plan's compensation (`targets` nil) or
    /// forced targets (`[:]` = every strip uncompensated: the control).
    static func render(_ store: ProjectStore, tracks: [Track]? = nil, targets: [UUID: Int]? = nil,
                       seconds: Double = songSeconds) throws -> RenderedAudio {
        let renderer = OfflineRenderer()
        renderer.compensationTargets = targets
        return try renderer.render(tracks: tracks ?? store.tracks, tempoMap: store.transport.tempoMap,
                                   fromBeat: 0, durationSeconds: seconds,
                                   masterVolume: store.masterVolume, masterEffects: store.masterEffects,
                                   meterMap: store.transport.meterMap)
    }

    /// The full-session plan, as `render.stems` forces it.
    static func plan(_ tracks: [Track]) -> [UUID: Int] {
        OfflineRenderer().compensationPlanTargets(tracks: tracks)
    }

    /// `tracks` with every track but `keep` muted (a stem pass's shape, under the forced full-session plan).
    static func solo(_ tracks: [Track], _ keep: UUID) -> [Track] {
        tracks.map { track in
            var copy = track
            if copy.id != keep { copy.isMuted = true }
            return copy
        }
    }
}

@Suite("W10-STACKL the safety limiter on every new drum machine — before/after gate (DRUMSTACKL=1 only)")
struct DrumSafetyLimiterGateTests {
    static let enabled = ProcessInfo.processInfo.environment["DRUMSTACKL"] == "1"

    @Test("DRUMSTACKL: ordinary beats, overshoot stacks, a full song, saved songs, templates, listening files",
          .enabled(if: DrumSafetyLimiterGateTests.enabled))
    func measureAndWrite() async throws {
        let rig = try DrumSafetyRig.make()
        let latency = LimiterParams.lookaheadSamples(sampleRate: DrumDefStage.sampleRate)
        var rows: [[String: Any]] = []
        let started = Date()
        print("[STACKL] phase \(rig.phase), before \(rig.before?.lastPathComponent ?? "-"), latency \(latency)")

        func describe(_ effects: [EffectDescriptor]) -> [[String: Any]] {
            effects.map { effect in
                var entry: [String: Any] = ["kind": effect.kind.rawValue, "bypassed": effect.isBypassed]
                if let l = effect.limiter {
                    entry["ceilingDb"] = l.ceilingDb; entry["releaseMs"] = l.releaseMs; entry["truePeak"] = l.truePeak
                }
                return entry
            }
        }

        /// Measures `audio`, writes it, and (after) compares it with the before render of the same name.
        func measure(_ name: String, _ audio: RenderedAudio, shift: Int, extra: [String: Any] = [:],
                     write: Bool = true) throws -> [String: Any] {
            let loud = Loudness.measure(audio)
            var row: [String: Any] = [
                "name": name, "tp": loud.truePeakDbtp ?? -999, "lufs": loud.integratedLufs ?? -999,
                "sp": DrumStackMath.samplePeak(audio).db, "frames": audio.frameCount,
                "digest": DrumDefMeasure.digest(audio),
            ]
            if write { try DrumSafetyIO.write(audio, to: rig.raw.appendingPathComponent("\(name).f32")) }
            if let before = try rig.beforeRender(name) {
                let gr = DrumSafetyMath.gainReduction(audio, before, shift: shift)
                row["beforeTp"] = Loudness.measure(before).truePeakDbtp ?? -999
                row["shiftedEqual"] = DrumSafetyMath.isShifted(audio, before, by: shift)
                row["maxDiffShifted"] = DrumSafetyMath.maxDiffShifted(audio, before, by: shift)
                row["equalUnshifted"] = DrumSafetyMath.isShifted(audio, before, by: 0)
                row["grDb"] = gr.db
                row["grFrames"] = gr.frames
                row["grMismatched"] = gr.mismatched
                row["onset"] = DrumSafetyMath.onset(audio) ?? -1
                row["beforeOnset"] = DrumSafetyMath.onset(before) ?? -1
            }
            for (k, v) in extra { row[k] = v }
            return row
        }

        // ---- 1. ORDINARY BEATS (gate 1): every shipped pattern + the 808 audition beat x every kit.
        var beats: [(String, [MIDINote], Double)] = [("audition808", DrumDefBeats.templateBeat(bars: 2), 6)]
        let gmNotes = Dictionary(uniqueKeysWithValues: DrumVoice.allCases.map { ($0, Int($0.primaryNote(in: .gm))) })
        for pattern in DrumPatternLibrary.patterns {
            beats.append(("pattern-\(pattern.id)", DrumPatternLibrary.notes(for: pattern, bars: 4, roleNotes: gmNotes).notes, 9))
        }
        for (kitName, kit) in DrumStackGateTests.kits {
            for (beatName, notes, seconds) in beats {
                let name = "beat-\(kitName)-\(beatName)"
                let born = try await DrumSafetyStage.born(kit: kit, notes: notes, seconds: seconds)
                var row = try measure(name, born.audio, shift: latency, extra: ["section": "beat", "kit": kitName,
                                                                            "beat": beatName, "effects": describe(born.effects)])
                if rig.before != nil {
                    // Removing the limiter gives back the before render EXACTLY (no shift): the delay is the insert's.
                    let removed = try await DrumSafetyStage.born(kit: kit, notes: notes, seconds: seconds, edit: .removeLimiter)
                    if removed.edited, let before = try rig.beforeRender(name) {
                        row["removedEqualsBefore"] = DrumSafetyMath.isShifted(removed.audio, before, by: 0)
                    }
                    for ceiling in rig.ceilings {
                        let tried = try await DrumSafetyStage.born(kit: kit, notes: notes, seconds: seconds, edit: .ceiling(ceiling))
                        if tried.edited, let before = try rig.beforeRender(name) {
                            let gr = DrumSafetyMath.gainReduction(tried.audio, before, shift: latency)
                            row["ceiling\(ceiling)"] = ["shiftedEqual": DrumSafetyMath.isShifted(tried.audio, before, by: latency),
                                                        "grDb": gr.db, "grFrames": gr.frames,
                                                        "tp": Loudness.measure(tried.audio).truePeakDbtp ?? -999]
                        }
                    }
                }
                rows.append(row)
            }
        }
        print("[STACKL] 1 beats done \(Int(Date().timeIntervalSince(started))) s")

        // ---- 2. OVERSHOOT STACKS (gate 2): the named stacks on every kit, every stack on a new drum machine; v100/v127.
        let named: [[DrumVoice]] = [[.kick, .rim], [.kick, .rim, .closedHat], [.kick, .tom]]
        var stackJobs: [(String, DrumKitParams?, [DrumVoice], Int)] = []
        for (kitName, kit) in DrumStackGateTests.kits {
            for stack in (kitName == "new" ? DrumStackGateTests.stacks : named) {
                for velocity in [100, 127] { stackJobs.append((kitName, kit, stack, velocity)) }
            }
        }
        for (kitName, kit, stack, velocity) in stackJobs {
            let label = DrumStackGateTests.label(stack)
            let name = "stack-\(kitName)-\(label)-v\(velocity)"
            let born = try await DrumSafetyStage.born(kit: kit, notes: DrumStackGateTests.notes(stack, velocity: velocity, beat: 0),
                                                      seconds: 0.75)
            let isNamed = named.contains(stack)
            if isNamed || kitName == "new" {
                try await DrumDefStage.write(born.audio, to: rig.raw.appendingPathComponent("\(name).wav"))
            }
            rows.append(try measure(name, born.audio, shift: latency,
                                    extra: ["section": "stack", "kit": kitName, "stack": label, "velocity": velocity,
                                            "named": isNamed, "limited": born.effects.contains { $0.kind == .limiter }]))
        }
        print("[STACKL] 2 stacks done \(Int(Date().timeIntervalSince(started))) s")

        // ---- 3. A FULL SONG (gate 3): drums + Poly Synth bass + Poly Synth keys + an audio clip.
        let audioFile = rig.out.appendingPathComponent("song-pluck.wav")
        try await DrumDefStage.write(DrumSafetyStage.pluckLoop(), to: audioFile)
        for pattern in ["basicRock", "oneDrop"] {
            let engine = await AudioEngine()
            let song = try await DrumSafetyStage.song(pattern: pattern, audioFile: audioFile, engine: engine)
            let store = song.store
            let tracks = await store.tracks
            let names: [(String, UUID)] = [("drums", song.drums), ("bass", song.bass), ("keys", song.keys), ("loop", song.loop)]
            var songRow: [String: Any] = ["section": "song", "pattern": pattern,
                                          "drumEffects": describe(tracks.first { $0.id == song.drums }?.effects ?? [])]
            // a. The mix, through the plan's compensation.
            let mix = try await DrumSafetyStage.render(store)
            songRow["mix"] = try measure("song-\(pattern)-mix", mix, shift: latency)
            // b. Stems as `render.stems` makes them: each track alone under the forced FULL-session plan.
            let plan = await DrumSafetyStage.plan(tracks)
            songRow["plan"] = Dictionary(uniqueKeysWithValues: names.map { ($0.0, plan[$0.1] ?? -1) })
            var stems: [String: RenderedAudio] = [:]
            for (label, id) in names {
                let stem = try await DrumSafetyStage.render(store, tracks: DrumSafetyStage.solo(tracks, id), targets: plan)
                stems[label] = stem
                var row = try measure("song-\(pattern)-stem-\(label)", stem, shift: latency)
                if let before = try rig.beforeRender("song-\(pattern)-stem-\(label)") {
                    let start = max(0, (DrumSafetyMath.onset(before) ?? 0) - 1_000)
                    row["xcorrLag"] = DrumSafetyMath.bestLag(stem, before, maxLag: 600, start: start, window: 48_000)
                }
                songRow["stem-\(label)"] = row
            }
            // The real export (`render.stems` + "00 Mixdown") through the engine, read back from its files.
            let stemDir = rig.out.appendingPathComponent("song-\(pattern)-export", isDirectory: true)
            try? FileManager.default.removeItem(at: stemDir)
            let exported = try await store.renderStems(toDirectory: stemDir.path, durationSeconds: DrumSafetyStage.songSeconds,
                                                       includeMixdown: true)
            var exportRows: [String: Any] = [:]
            for stem in exported.stems {
                let label = names.first { $0.1 == stem.trackId }?.0 ?? stem.name
                let channels = try await TestSignals.readFile(URL(fileURLWithPath: stem.path))
                let audio = RenderedAudio(sampleRate: DrumDefStage.sampleRate, channelData: channels)
                var row = try measure("song-\(pattern)-export-\(label)", audio, shift: latency)
                if let mine = stems[label] { row["equalsForcedStem"] = DrumSafetyMath.isShifted(audio, mine, by: 0) }
                exportRows[label] = row
            }
            if let mixdown = exported.mixdown {
                let channels = try await TestSignals.readFile(URL(fileURLWithPath: mixdown.path))
                let audio = RenderedAudio(sampleRate: DrumDefStage.sampleRate, channelData: channels)
                var row = try measure("song-\(pattern)-export-mixdown", audio, shift: latency)
                row["equalsMix"] = DrumSafetyMath.isShifted(audio, mix, by: 0)
                exportRows["mixdown"] = row
            }
            songRow["export"] = exportRows
            // c. THE CONTROL: every strip uncompensated. The drums alone keep the limiter's delay.
            let ctrlMix = try await DrumSafetyStage.render(store, targets: [:])
            var ctrl: [String: Any] = ["mix": try measure("song-\(pattern)-ctrl-mix", ctrlMix, shift: latency, write: false)]
            if let beforeMix = try rig.beforeRender("song-\(pattern)-mix") {
                ctrl["mixShiftedEqual"] = DrumSafetyMath.isShifted(ctrlMix, beforeMix, by: latency)
            }
            for (label, id) in names {
                let stem = try await DrumSafetyStage.render(store, tracks: DrumSafetyStage.solo(tracks, id), targets: [:])
                var row: [String: Any] = ["onset": DrumSafetyMath.onset(stem) ?? -1]
                if let before = try rig.beforeRender("song-\(pattern)-stem-\(label)") {
                    row["equalShifted0"] = DrumSafetyMath.isShifted(stem, before, by: 0)
                    row["equalShiftedLatency"] = DrumSafetyMath.isShifted(stem, before, by: latency)
                    let start = max(0, (DrumSafetyMath.onset(before) ?? 0) - 1_000)
                    row["xcorrLag"] = DrumSafetyMath.bestLag(stem, before, maxLag: 600, start: start, window: 48_000)
                }
                ctrl[label] = row
            }
            songRow["control"] = ctrl
            // d. The LIVE graph's plan: the engine was never started; the store's edits reconciled its graph.
            if let report = await engine.pdcReport() {
                var strips: [String: Any] = [:]
                for (label, id) in names {
                    if let s = report.strips[id] {
                        strips[label] = ["chain": s.chainLatencySamples, "compensation": s.compensationSamples,
                                         "clamped": s.clamped]
                    }
                }
                songRow["live"] = ["trackStage": report.trackStageSamples, "busStage": report.busStageSamples,
                                   "output": report.outputLatencySamples, "strips": strips]
            } else {
                songRow["live"] = "no report"
            }
            // e. Bounce in place of the drums, then the song as it now plays (drums muted, the bounce playing).
            let bounced = try await store.bounceTrackInPlace(trackId: song.drums, durationSeconds: DrumSafetyStage.songSeconds)
            let after = await store.tracks
            let bouncedPlan = await DrumSafetyStage.plan(after)
            let bouncedOnly = try await DrumSafetyStage.render(store, tracks: DrumSafetyStage.solo(after, bounced.track.id),
                                                               targets: bouncedPlan)
            var bounceRow: [String: Any] = ["planBounced": bouncedPlan[bounced.track.id] ?? -1,
                                            "planDrums": bouncedPlan[song.drums] ?? -1,
                                            "onset": DrumSafetyMath.onset(bouncedOnly) ?? -1]
            if let drumStem = stems["drums"] {
                bounceRow["drumStemOnset"] = DrumSafetyMath.onset(drumStem) ?? -1
                bounceRow["equalsDrumStem"] = DrumSafetyMath.isShifted(bouncedOnly, drumStem, by: 0)
                bounceRow["equalsDrumStemPlusLatency"] = DrumSafetyMath.isShifted(bouncedOnly, drumStem, by: latency)
                let start = max(0, (DrumSafetyMath.onset(drumStem) ?? 0) - 1_000)
                bounceRow["xcorrLagVsDrumStem"] = DrumSafetyMath.bestLag(bouncedOnly, drumStem, maxLag: 600, start: start,
                                                                         window: 48_000)
                bounceRow["maxDiffVsDrumStem"] = DrumSafetyMath.maxDiffShifted(bouncedOnly, drumStem, by: 0)
            }
            bounceRow["bouncedOnly"] = try measure("song-\(pattern)-bounced-only", bouncedOnly, shift: latency)
            songRow["bounce"] = bounceRow
            withExtendedLifetime(engine) {}
            rows.append(songRow)
        }
        print("[STACKL] 3 song done \(Int(Date().timeIntervalSince(started))) s")

        // ---- 4. SAVED SONGS (gate 5): opened through the real open path, rendered, saved again.
        if let fixtures = rig.fixtures {
            for name in ["saved-nil-kit", "saved-old-kit"] {
                let source = fixtures.appendingPathComponent("\(name).dawproj")
                let copy = rig.out.appendingPathComponent("open-\(name).dawproj")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: source, to: copy)
                let store = await ProjectStore()
                _ = try await store.openProject(at: copy.path)
                let tracks = await store.tracks
                let audio = try await DrumDefStage.render(store, seconds: 5)
                var row = try measure("saved-\(name)", audio, shift: 0,
                                      extra: ["section": "saved", "effects": tracks.map { describe($0.effects) },
                                              "kinds": tracks.map { $0.instrument?.kind.rawValue ?? "nil" }])
                var resaved: [String] = []
                for round in 1...2 {
                    let out = rig.out.appendingPathComponent("resaved-\(name)-\(round).dawproj")
                    try? FileManager.default.removeItem(at: out)
                    _ = try await store.saveProject(to: out.path)
                    let text = try String(contentsOf: out.appendingPathComponent("project.json"), encoding: .utf8)
                    let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .filter { !$0.contains("\"savedAt\"") }.joined(separator: "\n")
                    resaved.append(DrumDefMeasure.digest(Array(kept.utf8).map { Float($0) }))
                    try kept.write(to: rig.raw.appendingPathComponent("resaved-\(name)-\(round).json"), atomically: true,
                                   encoding: .utf8)
                }
                row["resavedDigests"] = resaved
                if let before = rig.before {
                    let theirs = before.appendingPathComponent("raw/resaved-\(name)-1.json")
                    if let old = try? String(contentsOf: theirs, encoding: .utf8) {
                        let mine = try String(contentsOf: rig.raw.appendingPathComponent("resaved-\(name)-1.json"),
                                              encoding: .utf8)
                        row["resavedEqualsBefore"] = old == mine
                    }
                }
                rows.append(row)
            }
        }
        print("[STACKL] 4 saved done \(Int(Date().timeIntervalSince(started))) s")

        // ---- 5. THE FACTORY TEMPLATES (out of scope): their drum tracks as shipped, and with a limiter added.
        for entry in BuiltInTemplateCatalog.load().templates {
            let plan = try TemplateBuilder.plan(entry.template)
            guard let drumTrack = plan.tracks.first(where: { $0.instrument?.kind == .drumSynth }),
                  let key = plan.keyToTrackID.first(where: { $0.value == drumTrack.id })?.key else { continue }
            for pattern in DrumPatternLibrary.patterns {
                for addLimiter in [false, true] {
                    let store = await ProjectStore(projectName: "STACKL template \(entry.id)")
                    try await store.setTempo(120)
                    let result = try await store.applyTemplate(entry.template)
                    let id = try #require(result.tracks.first { $0.key == key }?.id)
                    let applied = await store.tracks
                    let track = try #require(applied.first { $0.id == id })
                    let layout = (track.instrument ?? .default).resolvedDrumKit.noteLayout
                    let roles = Dictionary(uniqueKeysWithValues: DrumVoice.allCases.map {
                        ($0, Int($0.primaryNote(in: layout)))
                    })
                    let chain = describe(track.effects)
                    if addLimiter {
                        let fx = try await store.addEffect(toTrack: id, kind: .limiter)
                        try await store.setEffectParam(trackID: id, effectID: fx.id, name: "ceilingDb", value: -1)
                        try await store.setEffectParam(trackID: id, effectID: fx.id, name: "truePeak", value: 1)
                    }
                    _ = try await store.addMIDIClip(toTrack: id, name: "Beat", atBeat: 0, lengthBeats: 16,
                                                    notes: DrumPatternLibrary.notes(for: pattern, bars: 4, roleNotes: roles).notes)
                    let audio = try await DrumSafetyStage.render(store, seconds: 9)
                    // The drum track's OWN path: every other non-bus track muted and its sends cleared, so the
                    // reduction read off it is the limiter's alone (a send's reverb return is not a gain of the
                    // input). The insert sits BEFORE the fader, so the template's own fader level matters.
                    let all = await store.tracks
                    let drumOnlyTracks = all.map { t -> Track in
                        var copy = t
                        if copy.id == id { copy.sends = [] } else if copy.kind != .bus { copy.isMuted = true }
                        return copy
                    }
                    let drumOnly = try await DrumSafetyStage.render(store, tracks: drumOnlyTracks, seconds: 9)
                    let name = "template-\(entry.id)-\(pattern.id)-\(addLimiter ? "lim" : "asis")"
                    let loud = Loudness.measure(audio)
                    var row: [String: Any] = ["section": "template", "template": entry.id, "pattern": pattern.id,
                                              "addLimiter": addLimiter, "drumKey": key, "chainAsApplied": chain,
                                              "drumVolume": track.volume, "drumSends": track.sends.count,
                                              "drumToBus": track.outputBusID != nil,
                                              "tp": loud.truePeakDbtp ?? -999, "lufs": loud.integratedLufs ?? -999,
                                              "drumOnlyTp": Loudness.measure(drumOnly).truePeakDbtp ?? -999,
                                              "digest": DrumDefMeasure.digest(audio)]
                    try DrumSafetyIO.write(audio, to: rig.raw.appendingPathComponent("\(name).f32"))
                    try DrumSafetyIO.write(drumOnly, to: rig.raw.appendingPathComponent("\(name)-drumonly.f32"))
                    if addLimiter {
                        let asIs = try DrumSafetyIO.read(rig.raw.appendingPathComponent(
                            "template-\(entry.id)-\(pattern.id)-asis.f32"))
                        let asIsDrums = try DrumSafetyIO.read(rig.raw.appendingPathComponent(
                            "template-\(entry.id)-\(pattern.id)-asis-drumonly.f32"))
                        let gr = DrumSafetyMath.gainReduction(drumOnly, asIsDrums, shift: latency)
                        let asIsLoud = Loudness.measure(asIs)
                        row["shiftedEqual"] = DrumSafetyMath.isShifted(audio, asIs, by: latency)
                        row["drumOnlyShiftedEqual"] = DrumSafetyMath.isShifted(drumOnly, asIsDrums, by: latency)
                        row["grDb"] = gr.db
                        row["grFrames"] = gr.frames
                        row["grMismatched"] = gr.mismatched
                        row["asIsTp"] = asIsLoud.truePeakDbtp ?? -999
                        row["asIsLufs"] = asIsLoud.integratedLufs ?? -999
                        row["asIsDrumOnlyTp"] = Loudness.measure(asIsDrums).truePeakDbtp ?? -999
                    }
                    if let before = try rig.beforeRender(name) {
                        row["equalsBefore"] = DrumSafetyMath.isShifted(audio, before, by: 0)
                    }
                    rows.append(row)
                }
            }
        }
        print("[STACKL] 5 templates done \(Int(Date().timeIntervalSince(started))) s")

        // ---- 6. LISTENING FILES (gate 6), written only with DRUMSTACKL_LISTEN.
        if let listen = rig.listen {
            let worst = DrumStackGateTests.notes([.kick, .rim, .closedHat], velocity: 127, beat: 0)
                + DrumStackGateTests.notes([.kick, .rim, .closedHat], velocity: 127, beat: 1)
                + DrumStackGateTests.notes([.kick, .rim, .closedHat], velocity: 127, beat: 2)
                + DrumStackGateTests.notes([.kick, .rim, .closedHat], velocity: 127, beat: 3)
            let acoustic = try #require(DrumKitParams.preset(named: "acoustic"))
            let jobs: [(String, DrumKitParams?, [MIDINote], Double)] = [
                ("stack-kick+rim+closedHat-v127-new", nil, worst, 2.5),
                ("beat-oneDrop-acoustic", DrumKitParams.newDrumMachineKit.applyingPreset(acoustic),
                 beats.first { $0.0 == "pattern-oneDrop" }?.1 ?? [], 9),
                ("beat-basicRock-new", nil, beats.first { $0.0 == "pattern-basicRock" }?.1 ?? [], 9),
            ]
            for (name, kit, notes, seconds) in jobs {
                let with = try await DrumSafetyStage.born(kit: kit, notes: notes, seconds: seconds)
                let without = try await DrumSafetyStage.born(kit: kit, notes: notes, seconds: seconds, edit: .removeLimiter)
                try await DrumDefStage.write(with.audio, to: listen.appendingPathComponent("\(name)-WITH-limiter.wav"))
                try await DrumDefStage.write(without.audio, to: listen.appendingPathComponent("\(name)-WITHOUT.wav"))
                let gr = DrumSafetyMath.gainReduction(with.audio, without.audio, shift: latency)
                rows.append(["section": "listen", "name": name, "limited": with.effects.contains { $0.kind == .limiter },
                             "tpWith": Loudness.measure(with.audio).truePeakDbtp ?? -999,
                             "tpWithout": Loudness.measure(without.audio).truePeakDbtp ?? -999,
                             "lufsWith": Loudness.measure(with.audio).integratedLufs ?? -999,
                             "lufsWithout": Loudness.measure(without.audio).integratedLufs ?? -999,
                             "grDb": gr.db, "grFrames": gr.frames,
                             "shiftedEqual": DrumSafetyMath.isShifted(with.audio, without.audio, by: latency)])
            }
        }

        let report: [String: Any] = ["phase": rig.phase, "latency": latency, "rows": rows,
                                     "seconds": Date().timeIntervalSince(started)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: rig.out.appendingPathComponent("measure.json"))
        print("[STACKL] wrote \(rows.count) rows in \(Int(Date().timeIntervalSince(started))) s")
        #expect(rows.count > 150, "the gate wrote \(rows.count) rows")
    }
}
