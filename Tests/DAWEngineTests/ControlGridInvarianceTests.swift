import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-d CR-0 (W8-CR0) — MEASURE BEFORE BUILDING THE EFFECT CONTROL CELL; extended by W9-CR12 (CR-1 + CR-2 landed).
// `docs/design/2026-10-07-effect-control-rate.md` §6 CR-0 items 1–3, plus the instrument-target measurement.
// Nothing here changes product code. ALWAYS ON: the fixture geometry, and since W9-CR12 (2026-10-11) the two byte
// gates G2's cheaper twin (`g2TwinGate`) and G4 (`g4Gate`) — about 40 s serialized on a quiet machine (137 s measured
// under a parallel filter run); they write their TSVs under CR0_OUT. Every other heavy part is env-gated and SKIPS
// without its variable.
//
//   CR0_CAPTURE=<dir>      G1 goldens. Renders the fixture set on THIS tree and writes <dir>/cr0-goldens.tsv
//                          (one SHA-256 per fixture). CR0_CAPTURE_RAW=1 also writes <dir>/raw/<id>.f32.
//   CR0_COMPARE=<file>     G1 gate. Renders the same set and asserts every SHA-256 equals <file>'s.
//                          CR0_COMPARE_RAW=<dir> (a capture's raw/ dir) adds the first differing frame per mismatch.
//                          Goldens: Fixtures/ControlGrid/cr0-goldens-2026-10-07.tsv (the 10-07 set) and
//                          cr12-off32-goldens-2026-10-11.tsv (the off-32 set, with CR0_SET=off32), both captured on
//                          the tree BEFORE CR-1 + CR-2 and both 73/73 equal after it (W9-CR12, 2026-10-11).
//   CR0_SET=off32          Selects the off-32 twin of the G1 set (partial last blocks that are not a multiple of 32).
//   CR0_PLANT_FRAMES=<N>   Test-side plant: render the G1 set with `OfflineRenderer(maximumFrameCount: N)` instead
//                          of the default. Before CR-1 + CR-2, N = 256 turned every AUTOMATED fixture red. MEASURED
//                          AFTER (W9-CR12, 2026-10-11): N = 256 is 73/73 EQUAL — the 256 offline render is now G2's
//                          cheaper twin. A green env plant is therefore NOT a dead gate: the design's source plant P1
//                          (G = 256) is what proves the gate live (it turned .a 25/25 and .b 25/25 red).
//   CR0_CENSUS=1           G0 static split-invariance census: 22 built-in kinds, static non-default params, no
//                          automation, N in 64/128/441/480/512/1024 against N = 512 (441 is an EXTRA column, not a
//                          multiple of 32, to expose call-anchored 32-frame strides).
//   CR0_INSTR=1            Instrument-target block-size measurement (drumSynth + polySynth routes; drift control).
//   CR12_LIVE=1            G2 MAIN: the live graph (`.realtime` manual rendering) at N in 64…2048 against the 512
//                          bounce over whole cells. CR12_LIVE_PACE_MS=<ms> (default 25) paces file-backed rows per
//                          100 ms of audio: an unpaced realtime file player starves (see the G2 MAIN section).
//   CR0_OUT=<dir>          Where the census/instrument/twin/G4 TSVs land (default: $TMPDIR/dawpro-cr0).
//
// HASH METHOD (the contract a re-capture must match): SHA-256 over the Float32 BIT PATTERNS of
// `RenderedAudio.channelData`, native byte order (little-endian on this Mac), channel 0's frames then channel 1's.
// Every UUID (tracks, clips, effects, lanes, sources, routes, notes) is derived from a fixed string, every effect param
// is written explicitly through `applySetting` (no decode default is measured), and the input is synthesized
// deterministically, so two captures in two processes must agree byte for byte.
//
// WHAT THE SET DOES NOT COVER (so nobody reads it as broader than it is): bus strips, the master chain, hosted AU
// inserts, the live host-time position path (W9-CR12: `ControlGridTests`' G3 covers it, white-box), a sidechain KEY on
// an automated strip (no G1 row splits a key buffer; since W9-CRFIX the always-on `keyedCompressorTwinGate` and G3's
// `keySegmentFollowsTheSplit` do), and `InstrumentSourceNode`'s stopped-transport idle path (its `schedule == nil`
// branch is never taken in an offline render).
//
// Nonisolated suite: the renders run in `@MainActor` helpers awaited one at a time, so the main actor is released
// between renders.

private enum CR0 {
    static let sampleRate = 48_000.0
    static let tempoMap = TempoMap(constantBPM: 120)
    static let grid = 512
    static let inputSeconds = 8.0
    static let clipBeats = 16.0
    /// G1 (a): 3.0 s = 144 000 frames, 144 000 mod 512 = 128 — a partial last block.
    static let fullSeconds = 3.0
    /// G1 (b): fromBeat 3.37 (originSample 80 880, mod 512 = 496), 2.0 s = 96 000 frames (mod 512 = 256).
    static let windowFromBeat = 3.37
    static let windowSeconds = 2.0
    static let censusSeconds = 2.0
    static let censusFrames = [64, 128, 441, 480, 512, 1_024]
    static let instrumentFrames = [64, 441, 480, 512, 1_024]
    /// Lane breakpoints: beats (none on the 512 grid at 120 BPM / 48 kHz: 1 beat = 24 000 frames) and the fraction of
    /// the target's travel (in its declared curve) at each.
    static let lanePoints: [(beat: Double, fraction: Double)] = [
        (0.37, 0.2), (1.13, 0.8), (2.71, 0.35), (4.29, 0.9), (5.83, 0.15), (7.21, 0.7), (7.9, 0.3),
    ]
    static let lfoRateHz = 5.0
    static let lfoDepth = 0.25
    static let stepRateHz = 8.0
    static let stepDepth = 0.15
    static let stepEdgeMs = 2.0
    /// Static setting: 30 % of the way from the default toward the farther end of the range.
    static let nudge = 0.3

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func nonEmpty(_ key: String) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    static var outputDirectory: URL {
        let path = nonEmpty("CR0_OUT")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("dawpro-cr0", isDirectory: true).path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The 22 built-in kinds — every case except the hosted `.audioUnit`.
    static var builtInKinds: [EffectDescriptor.Kind] {
        EffectDescriptor.Kind.allCases.filter { $0 != .audioUnit }
    }

    /// A fixed UUID per name (RFC 4122 v4 layout over a SHA-256 of the name), so every render is reproducible.
    static func id(_ key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("dawpro-cr0/\(key)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func originSample(fromBeat beat: Double) -> Int64 {
        Int64((tempoMap.seconds(from: 0, to: beat) * sampleRate).rounded())
    }

    static func frames(seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    // MARK: Static params

    /// Params a lane or a route may move (modulation refuses a SUPERSET of what automation refuses).
    static func movableSpecs(_ kind: EffectDescriptor.Kind) -> [EffectParamSpec] {
        EffectParamSpec.specs(for: kind).filter { $0.modulatable != .refused }
    }

    /// Refused params held at a fixed value instead of flipped, because the flip would BLIND the fixture: a band
    /// switched off cannot show its lane, a tank frozen from silence never fills, a synced delay ignores `timeMs`.
    static let heldRefusedParams: [String: Double] = ["freeze": 0, "sync": 0]

    /// The static, NON-default value written for one param. Continuous params move 30 % of the way toward the farther
    /// range end (geometrically on a `.logarithmic` curve); refused (discrete/topology) params flip to the other end,
    /// except `*Enabled` (held ON), `freeze`/`sync` (held at 0) and `division` (default; only read when synced).
    static func staticValue(_ spec: EffectParamSpec) -> Double {
        let lo = spec.range.lowerBound
        let hi = spec.range.upperBound
        let d = spec.defaultValue
        if spec.modulatable == .refused {
            if spec.name.hasSuffix("Enabled") { return hi }
            if let held = heldRefusedParams[spec.name] { return held }
            if spec.name == "division" { return d }
            return d != hi ? hi : lo
        }
        let far = (hi - d) >= (d - lo) ? hi : lo
        if spec.curve == .logarithmic, lo > 0, d > 0 {
            return exp(log(d) + nudge * (log(far) - log(d)))
        }
        return d + nudge * (far - d)
    }

    static func travel(_ spec: EffectParamSpec, _ fraction: Double) -> Double {
        let lo = spec.range.lowerBound
        let hi = spec.range.upperBound
        if spec.curve == .logarithmic, lo > 0 {
            return lo * pow(hi / lo, fraction)
        }
        return lo + fraction * (hi - lo)
    }

    /// Per-kind values written AFTER the generic rule, because the generic rule leaves these two kinds' dynamic path
    /// idle against this input. MEASURED on the first capture: the limiter's ceiling (-7.9 dB) sat above the input's
    /// -9.6 dBFS peak, so it never limited; the gate (-28 dB, hold 185 ms, release 670 ms) differed from dry at only
    /// 1 506 of 192 000 samples. Here the limiter limits every burst and the gate closes in every burst's tail.
    static let staticOverrides: [EffectDescriptor.Kind: [String: Double]] = [
        .limiter: ["ceilingDb": -14],
        .gate: ["thresholdDb": -17, "holdMs": 10, "releaseMs": 30],
    ]

    /// The full static setting of `kind`, in spec order (the overrides replace their param's generic value).
    static func staticSettings(_ kind: EffectDescriptor.Kind) -> [(name: String, value: Double)] {
        let overrides = staticOverrides[kind] ?? [:]
        return EffectParamSpec.specs(for: kind).map { spec in
            (spec.name, overrides[spec.name] ?? staticValue(spec))
        }
    }

    /// One effect of `kind` with EVERY param written explicitly.
    static func staticEffect(_ kind: EffectDescriptor.Kind, key: String) -> EffectDescriptor {
        var effect = EffectDescriptor(id: id(key), kind: kind)
        for setting in staticSettings(kind) {
            effect.applySetting(setting.name, setting.value)
        }
        return effect
    }

    static func settingsText(_ kind: EffectDescriptor.Kind) -> String {
        staticSettings(kind)
            .map { "\($0.name)=\(String(format: "%.6g", $0.value))" }
            .joined(separator: ",")
    }

    // MARK: Automation and modulation

    struct Motion: Sendable {
        var lanes: [AutomationLane]
        var sources: [ModulationSource]
        var routes: [ModulationRoute]
        var note: String
    }

    /// Lane on `a` (off-grid breakpoints); a 5 Hz LFO and an 8 Hz step gate routed to `b`.
    static func effectMotion(effectID: UUID, kind: EffectDescriptor.Kind, key: String) -> Motion? {
        let movable = movableSpecs(kind)
        guard let a = movable.first else { return nil }
        let b = movable.count > 1 ? movable[1] : a
        let lane = AutomationLane(
            id: id("\(key).lane"),
            target: .effectParam(effectID: effectID, paramName: a.name),
            points: lanePoints.map { AutomationPoint(beat: $0.beat, value: travel(a, $0.fraction)) })
        let lfo = ModulationSource(
            id: id("\(key).lfo"), kind: .lfo,
            params: .lfo(LFOSourceParams(waveform: .sine, rateHz: lfoRateHz, bipolar: true)))
        let step = ModulationSource(
            id: id("\(key).step"), kind: .stepSequencer,
            params: .stepSequencer(StepSequencerSourceParams(steps: [0, 1], rateHz: stepRateHz, edgeMs: stepEdgeMs)))
        let routes = [
            ModulationRoute(id: id("\(key).route.lfo"), sourceID: lfo.id,
                            target: .effectParam(effectID: effectID, paramName: b.name), depth: lfoDepth),
            ModulationRoute(id: id("\(key).route.step"), sourceID: step.id,
                            target: .effectParam(effectID: effectID, paramName: b.name), depth: stepDepth),
        ]
        return Motion(lanes: [lane], sources: [lfo, step], routes: routes,
                      note: "lane \(a.name); lfo5Hz+step8Hz \(b.name)")
    }

    // MARK: Tracks

    static func audioTrack(key: String, input: URL, effects: [EffectDescriptor], motion: Motion?) -> Track {
        Track(id: id("\(key).track"), name: "CR0 \(key)", kind: .audio,
              clips: [Clip(id: id("\(key).clip"), name: "cr0-input", startBeat: 0, lengthBeats: clipBeats,
                           audioFileURL: input)],
              effects: effects,
              automation: motion?.lanes ?? [],
              modulationSources: motion?.sources ?? [],
              modulationRoutes: motion?.routes ?? [])
    }

    static func synthNotes(key: String, untilBeat: Double) -> [MIDINote] {
        let pitches = [48, 55, 60, 64, 67, 72, 62, 57]
        var notes: [MIDINote] = []
        var beat = 0.0
        var index = 0
        while beat < untilBeat {
            notes.append(MIDINote(id: id("\(key).note\(index)"), pitch: pitches[index % pitches.count],
                                  velocity: 96, startBeat: beat, lengthBeats: 0.4))
            beat += 0.5
            index += 1
        }
        return notes
    }

    static func polySynthTrack(key: String, polySynth: PolySynthParams = PolySynthParams(),
                               effects: [EffectDescriptor], motion: Motion?, notesUntilBeat: Double) -> Track {
        Track(id: id("\(key).track"), name: "CR0 \(key)", kind: .instrument,
              clips: [Clip(id: id("\(key).clip"), name: "cr0-notes", startBeat: 0, lengthBeats: clipBeats,
                           notes: synthNotes(key: key, untilBeat: notesUntilBeat))],
              instrument: InstrumentDescriptor(kind: .polySynth, polySynth: polySynth),
              effects: effects,
              automation: motion?.lanes ?? [],
              modulationSources: motion?.sources ?? [],
              modulationRoutes: motion?.routes ?? [])
    }

    static func drumTrack(key: String, sources: [ModulationSource], routes: [ModulationRoute]) -> Track {
        let layout = DrumKitParams().noteLayout
        let kick = Int(DrumVoice.kick.primaryNote(in: layout))
        let snare = Int(DrumVoice.snare.primaryNote(in: layout))
        let hat = Int(DrumVoice.closedHat.primaryNote(in: layout))
        var notes: [MIDINote] = []
        var index = 0
        var beat = 0.0
        while beat < 4.0 {
            let sixteenth = Int((beat * 4).rounded())
            if sixteenth % 4 == 0 {
                notes.append(MIDINote(id: id("\(key).k\(index)"), pitch: kick, velocity: 110, startBeat: beat,
                                      lengthBeats: 0.2))
            }
            if sixteenth % 4 == 2 {
                notes.append(MIDINote(id: id("\(key).s\(index)"), pitch: snare, velocity: 100, startBeat: beat,
                                      lengthBeats: 0.2))
            }
            notes.append(MIDINote(id: id("\(key).h\(index)"), pitch: hat, velocity: 80 + (index % 3) * 10,
                                  startBeat: beat, lengthBeats: 0.1))
            index += 1
            beat += 0.25
        }
        return Track(id: id("\(key).track"), name: "CR0 \(key)", kind: .instrument,
                     clips: [Clip(id: id("\(key).clip"), name: "cr0-drums", startBeat: 0, lengthBeats: clipBeats,
                                  notes: notes)],
                     instrument: InstrumentDescriptor(kind: .drumSynth),
                     modulationSources: sources, modulationRoutes: routes)
    }

    // MARK: Input

    /// Deterministic stereo programme: tones in four bands plus seeded noise, under a burst envelope every 0.25 s.
    static func inputChannels() -> [[Float]] {
        let count = frames(seconds: inputSeconds)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        var stateL: UInt64 = 0x243F_6A88_85A3_08D3
        var stateR: UInt64 = 0x1319_8A2E_0370_7344
        func noise(_ s: inout UInt64) -> Double {
            s ^= s << 13
            s ^= s >> 7
            s ^= s << 17
            return Double(s >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
        let twoPi = 2.0 * Double.pi
        var n = 0
        while n < count {
            let t = Double(n) / sampleRate
            let env = 0.35 + 0.65 * exp(-t.truncatingRemainder(dividingBy: 0.25) / 0.04)
            let l = 0.16 * sin(twoPi * 110 * t) + 0.09 * sin(twoPi * 440 * t + 0.3)
                + 0.05 * sin(twoPi * 2_500 * t + 1.1) + 0.03 * sin(twoPi * 7_000 * t + 2.0) + 0.03 * noise(&stateL)
            let r = 0.16 * sin(twoPi * 165 * t + 0.7) + 0.09 * sin(twoPi * 550 * t + 1.9)
                + 0.05 * sin(twoPi * 3_300 * t + 0.4) + 0.03 * sin(twoPi * 6_000 * t + 2.6) + 0.03 * noise(&stateR)
            left[n] = Float(l * env)
            right[n] = Float(r * env)
            n += 1
        }
        return [left, right]
    }

    static func writeInputFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-cr0-input", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cr0-input-v1-\(ProcessInfo.processInfo.processIdentifier).wav")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let channels = inputChannels()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = channels[0].count
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { throw CR0Error.setup("input buffer") }
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
            channels[channel].withUnsafeBufferPointer { source in
                data[channel].update(from: source.baseAddress!, count: count)
            }
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: Digest and comparison

    static func sha256(_ audio: RenderedAudio) -> String {
        var hasher = SHA256()
        for channel in audio.channelData {
            channel.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    struct Stats: Sendable {
        var peak: Float
        var rms: Double
        var nonFinite: Int
    }

    static func stats(_ audio: RenderedAudio) -> Stats {
        var peak: Float = 0
        var sum = 0.0
        var count = 0
        var nonFinite = 0
        for channel in audio.channelData {
            channel.withUnsafeBufferPointer { samples in
                for sample in samples {
                    if !sample.isFinite { nonFinite += 1; continue }
                    let magnitude = abs(sample)
                    if magnitude > peak { peak = magnitude }
                    sum += Double(sample) * Double(sample)
                }
                count += samples.count
            }
        }
        return Stats(peak: peak, rms: count > 0 ? (sum / Double(count)).squareRoot() : 0, nonFinite: nonFinite)
    }

    struct Diff: Sendable {
        var count: Int
        var maxAbs: Float
        var firstFrame: Int
    }

    /// Differing samples by BIT PATTERN over every channel (a length mismatch counts every missing sample).
    static func diff(_ a: [[Float]], _ b: [[Float]]) -> Diff {
        var count = 0
        var maxAbs: Float = 0
        var first = -1
        let channels = max(a.count, b.count)
        var channel = 0
        while channel < channels {
            let x = channel < a.count ? a[channel] : []
            let y = channel < b.count ? b[channel] : []
            let shared = min(x.count, y.count)
            x.withUnsafeBufferPointer { xs in
                y.withUnsafeBufferPointer { ys in
                    var i = 0
                    while i < shared {
                        if xs[i].bitPattern != ys[i].bitPattern {
                            count += 1
                            if first < 0 || i < first { first = i }
                            let d = abs(xs[i] - ys[i])
                            if d.isFinite, d > maxAbs { maxAbs = d }
                        }
                        i += 1
                    }
                }
            }
            let extra = max(x.count, y.count) - shared
            if extra > 0 {
                count += extra
                if first < 0 || shared < first { first = shared }
            }
            channel += 1
        }
        return Diff(count: count, maxAbs: maxAbs, firstFrame: first)
    }

    static func diff(_ a: RenderedAudio, _ b: RenderedAudio) -> Diff { diff(a.channelData, b.channelData) }

    static func dbText(_ value: Float) -> String {
        value > 0 ? String(format: "%.1f", 20 * log10(Double(value))) : "-inf"
    }

    static func sourceFileSHA256(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "unreadable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum CR0Error: Error {
    case setup(String)
}

/// One G1 fixture: a track list rendered from `fromBeat` for `seconds`.
private struct CR0Fixture: Sendable {
    var id: String
    var tracks: [Track]
    var fromBeat: Double
    var seconds: Double
    var note: String
}

/// The G1 set, in a fixed order. Per built-in kind: (a) beat 0, 3.0 s; (b) fromBeat 3.37, 2.0 s; (c) the same static
/// effect with no lanes or routes. Then the instrument-strip fixtures (the `InstrumentSourceNode` call site).
private func cr0FixtureSet(input: URL) -> [CR0Fixture] {
    cr0FixtureSet(input: input, suffix: "", fullSeconds: CR0.fullSeconds, windowSeconds: CR0.windowSeconds)
}

/// m39-d-cr12 (W9-CR12): `CR0_SET=off32` selects the OFF-32 twin of the G1 set. Same tracks, same order, but every
/// render length leaves a final partial block whose length is NOT a multiple of 32 — (a) 143 972 frames (mod 512 =
/// 100, mod 32 = 4), (b) 96 037 frames (mod 512 = 293, mod 32 = 5) — so the last 32-frame coefficient block of
/// Phaser / DJFilter / RingMod is short. The 10-07 goldens (128 and 256 leftover frames) cannot see a change in how
/// that block is planned; this set can. Captured on the UNTOUCHED tree before CR-1 + CR-2 (W9-CR12 STATUS.md).
private func cr0SelectedFixtureSet(input: URL) -> [CR0Fixture] {
    guard CR0.setName == "off32" else { return cr0FixtureSet(input: input) }
    return cr0FixtureSet(input: input, suffix: "32",
                         fullSeconds: Double(CR0.off32FullFrames) / CR0.sampleRate,
                         windowSeconds: Double(CR0.off32WindowFrames) / CR0.sampleRate)
}

private func cr0FixtureSet(input: URL, suffix: String, fullSeconds: Double,
                           windowSeconds: Double) -> [CR0Fixture] {
    var fixtures: [CR0Fixture] = []
    for kind in CR0.builtInKinds {
        let name = kind.rawValue
        let key = "fx.\(name)"
        let effect = CR0.staticEffect(kind, key: "\(key).effect")
        guard let motion = CR0.effectMotion(effectID: effect.id, kind: kind, key: key) else { continue }
        let automated = CR0.audioTrack(key: key, input: input, effects: [effect], motion: motion)
        let plain = CR0.audioTrack(key: key, input: input, effects: [effect], motion: nil)
        fixtures.append(CR0Fixture(id: "\(key).a\(suffix)", tracks: [automated], fromBeat: 0, seconds: fullSeconds,
                                   note: "audio strip; \(motion.note); beat 0, \(fullSeconds) s"))
        fixtures.append(CR0Fixture(id: "\(key).b\(suffix)", tracks: [automated], fromBeat: CR0.windowFromBeat,
                                   seconds: windowSeconds,
                                   note: "audio strip; \(motion.note); fromBeat \(CR0.windowFromBeat), \(windowSeconds) s"))
        fixtures.append(CR0Fixture(id: "\(key).c\(suffix)", tracks: [plain], fromBeat: 0, seconds: fullSeconds,
                                   note: "audio strip; static params, no lanes/routes; beat 0, \(fullSeconds) s"))
    }
    for kind in [EffectDescriptor.Kind.gain, .flanger, .djFilter] {
        let key = "inst.\(kind.rawValue)"
        let effect = CR0.staticEffect(kind, key: "\(key).effect")
        guard let motion = CR0.effectMotion(effectID: effect.id, kind: kind, key: key) else { continue }
        let track = CR0.polySynthTrack(key: key, effects: [effect], motion: motion, notesUntilBeat: 7)
        fixtures.append(CR0Fixture(id: "\(key).a\(suffix)", tracks: [track], fromBeat: 0, seconds: fullSeconds,
                                   note: "polySynth strip; \(motion.note); beat 0, \(fullSeconds) s"))
        fixtures.append(CR0Fixture(id: "\(key).b\(suffix)", tracks: [track], fromBeat: CR0.windowFromBeat,
                                   seconds: windowSeconds,
                                   note: "polySynth strip; \(motion.note); fromBeat \(CR0.windowFromBeat), \(windowSeconds) s"))
    }
    let bare = CR0.polySynthTrack(key: "inst.none", effects: [], motion: nil, notesUntilBeat: 7)
    fixtures.append(CR0Fixture(id: "inst.none.c\(suffix)", tracks: [bare], fromBeat: 0, seconds: fullSeconds,
                               note: "polySynth strip; no effects; beat 0, \(fullSeconds) s"))
    return fixtures
}

@MainActor
private enum CR0Harness {
    /// `frames == nil` is the production constructor (`maximumFrameCount` = `RenderBlockSize.offlineFrames`).
    static func render(_ tracks: [Track], frames: Int?, fromBeat: Double, seconds: Double) throws -> RenderedAudio {
        let renderer: OfflineRenderer
        if let frames {
            renderer = OfflineRenderer(sampleRate: CR0.sampleRate, maximumFrameCount: frames)
        } else {
            renderer = OfflineRenderer(sampleRate: CR0.sampleRate)
        }
        return try renderer.render(tracks: tracks, tempoMap: CR0.tempoMap, fromBeat: fromBeat,
                                   durationSeconds: seconds)
    }
}

@Suite("m39-d CR-0: control-grid goldens, static split-invariance census, instrument block-size targets",
       .serialized)
struct ControlGridInvarianceTests {

    // MARK: Always on: the fixture geometry the gates depend on

    @Test("CR-0 geometry: partial last blocks, an off-grid window origin, 22 kinds with a movable param, real targets")
    func fixtureGeometry() {
        #expect(RenderBlockSize.offlineFrames == CR0.grid)
        #expect(CR0.builtInKinds.count == 22)
        for kind in CR0.builtInKinds {
            #expect(!CR0.movableSpecs(kind).isEmpty, "\(kind.rawValue) has no param a lane or route may move")
        }
        #expect(CR0.frames(seconds: CR0.fullSeconds) % CR0.grid != 0)
        #expect(CR0.frames(seconds: CR0.windowSeconds) % CR0.grid != 0)
        #expect(CR0.originSample(fromBeat: CR0.windowFromBeat) % Int64(CR0.grid) != 0)
        for point in CR0.lanePoints {
            #expect(CR0.originSample(fromBeat: point.beat) % Int64(CR0.grid) != 0)
        }
        let poly = InstrumentParamSpec.specs(for: .polySynth).map(\.name)
        let drum = InstrumentParamSpec.specs(for: .drumSynth).map(\.name)
        #expect(poly.contains("cutoffHz"))
        #expect(drum.contains("snare.decay"))
        #expect(drum.contains("closedHat.level"))
    }

    // MARK: G1 — capture

    @Test("CR-0 G1 capture: SHA-256 per fixture on this tree (CR0_CAPTURE=<dir>)",
          .enabled(if: !(ProcessInfo.processInfo.environment["CR0_CAPTURE"] ?? "").isEmpty))
    func g1Capture() async throws {
        let directory = URL(fileURLWithPath: try #require(CR0.nonEmpty("CR0_CAPTURE")), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawDirectory = directory.appendingPathComponent("raw", isDirectory: true)
        if CR0.environment["CR0_CAPTURE_RAW"] == "1" {
            try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        }
        let input = try CR0.writeInputFile()
        let fixtures = cr0SelectedFixtureSet(input: input)
        #expect(fixtures.count == CR0.builtInKinds.count * 3 + 7)
        let plant = CR0.plantFrames
        var rows: [String] = []
        var renders: [String: [[Float]]] = [:]
        for fixture in fixtures {
            let audio = try await CR0Harness.render(fixture.tracks, frames: plant, fromBeat: fixture.fromBeat,
                                                    seconds: fixture.seconds)
            let stats = CR0.stats(audio)
            #expect(stats.nonFinite == 0, "\(fixture.id): non-finite samples")
            #expect(stats.peak > 0, "\(fixture.id): silent render")
            #expect(audio.frameCount == CR0.frames(seconds: fixture.seconds), "\(fixture.id): frame count")
            let digest = CR0.sha256(audio)
            rows.append([fixture.id, digest, "\(audio.frameCount)", "\(audio.channelData.count)",
                         String(format: "%.6f", stats.peak), String(format: "%.6f", stats.rms),
                         "\(stats.nonFinite)", fixture.note].joined(separator: "\t"))
            if fixture.id.hasSuffix(".a\(CR0.setSuffix)") || fixture.id.hasSuffix(".c\(CR0.setSuffix)") {
                renders[fixture.id] = audio.channelData
            }
            if CR0.environment["CR0_CAPTURE_RAW"] == "1" {
                var data = Data()
                for channel in audio.channelData { channel.withUnsafeBytes { data.append(contentsOf: $0) } }
                try data.write(to: rawDirectory.appendingPathComponent("\(fixture.id).f32"))
            }
        }
        // Liveness: every kind's lane + routes must reach its output, or its (a)/(b) rows are blind.
        var activity: [String] = []
        for kind in CR0.builtInKinds {
            let key = "fx.\(kind.rawValue)"
            guard let a = renders["\(key).a\(CR0.setSuffix)"], let c = renders["\(key).c\(CR0.setSuffix)"] else {
                continue
            }
            let d = CR0.diff(a, c)
            activity.append("\(kind.rawValue)=\(d.count)")
            #expect(d.count > 0, "\(key): the automated render equals the static one — the fixture is blind")
        }
        let plantText: String
        if let plant {
            plantText = "CR0_PLANT_FRAMES=\(plant) (NOT A GOLDEN)"
        } else {
            plantText = "none (OfflineRenderer default constructor)"
        }
        let header: [String] = [
            "# W8-CR0 control-grid goldens (m39-d CR-0, docs/design/2026-10-07-effect-control-rate.md §6 G1)",
            "# captured: \(ISO8601DateFormatter().string(from: Date()))",
            "# plant: \(plantText)",
            "# set: \(CR0.setName)",
            "# hash: SHA-256 over Float32 bit patterns of RenderedAudio.channelData, native byte order, ch0 frames then ch1",
            "# renderer: OfflineRenderer(sampleRate: 48000[, maximumFrameCount: plant]).render(tracks:tempoMap:fromBeat:durationSeconds:)",
            "# tempo: 120 BPM constant; input: synthesized 8 s stereo float WAV (CR0.inputChannels), clip beats 0-16",
            "# lane points (beat:fraction): \(CR0.lanePoints.map { "\($0.beat):\($0.fraction)" }.joined(separator: " "))",
            "# routes: LFO sine \(CR0.lfoRateHz) Hz bipolar depth \(CR0.lfoDepth); step [0,1] \(CR0.stepRateHz) Hz edge \(CR0.stepEdgeMs) ms depth \(CR0.stepDepth)",
            "# static params: continuous 30% toward the farther range end (geometric on log curves); refused params flipped, except *Enabled=on, freeze=0, sync=0, division=default; overrides limiter.ceilingDb=-14, gate.thresholdDb=-17/holdMs=10/releaseMs=30 (see '# settings' lines)",
            "# activity (a vs c differing samples): \(activity.joined(separator: " "))",
            "# test file sha256: \(CR0.sourceFileSHA256(#filePath))",
            "# columns: id\tsha256\tframes\tchannels\tpeak\trms\tnonFinite\tnote",
        ]
        let static22 = CR0.builtInKinds.map { "# settings \($0.rawValue): \(CR0.settingsText($0))" }
        let text = (header + static22 + rows).joined(separator: "\n") + "\n"
        let out = directory.appendingPathComponent("cr0-goldens.tsv")
        try text.write(to: out, atomically: true, encoding: .utf8)
        print("[CR0] G1 capture: \(rows.count) fixtures -> \(out.path) (plant: \(plant.map { String($0) } ?? "none"))")
        try? FileManager.default.removeItem(at: input)
    }

    // MARK: G1 — compare

    @Test("CR-0 G1 compare: every fixture's SHA-256 equals the golden file's (CR0_COMPARE=<file>)",
          .enabled(if: !(ProcessInfo.processInfo.environment["CR0_COMPARE"] ?? "").isEmpty))
    func g1Compare() async throws {
        let path = try #require(CR0.nonEmpty("CR0_COMPARE"))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var golden: [String: String] = [:]
        var goldenOrder: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") {
                if line.hasPrefix("# plant") || line.hasPrefix("# captured") || line.hasPrefix("# test file") {
                    print("[CR0] golden \(line)")
                }
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2 else { continue }
            golden[String(columns[0])] = String(columns[1])
            goldenOrder.append(String(columns[0]))
        }
        #expect(!golden.isEmpty, "the golden file has no rows: \(path)")
        let input = try CR0.writeInputFile()
        let fixtures = cr0SelectedFixtureSet(input: input)
        let plant = CR0.plantFrames
        print("[CR0] compare against \(path): \(golden.count) golden rows, \(fixtures.count) fixtures, plant: \(plant.map { String($0) } ?? "none")")
        var equal = 0
        var differ: [String] = []
        var missing: [String] = []
        for fixture in fixtures {
            let audio = try await CR0Harness.render(fixture.tracks, frames: plant, fromBeat: fixture.fromBeat,
                                                    seconds: fixture.seconds)
            let digest = CR0.sha256(audio)
            guard let expected = golden[fixture.id] else {
                missing.append(fixture.id)
                print("[CR0] MISSING \(fixture.id): no golden row")
                continue
            }
            if digest == expected {
                equal += 1
                print("[CR0] EQUAL  \(fixture.id)")
            } else {
                differ.append(fixture.id)
                var detail = ""
                if let rawDirectory = CR0.nonEmpty("CR0_COMPARE_RAW"),
                   let data = FileManager.default.contents(
                    atPath: URL(fileURLWithPath: rawDirectory).appendingPathComponent("\(fixture.id).f32").path) {
                    let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    let perChannel = floats.count / max(1, audio.channelData.count)
                    var reference: [[Float]] = []
                    var start = 0
                    for _ in audio.channelData {
                        reference.append(Array(floats[start..<min(floats.count, start + perChannel)]))
                        start += perChannel
                    }
                    let d = CR0.diff(reference, audio.channelData)
                    detail = " differing=\(d.count) firstFrame=\(d.firstFrame) (block \(d.firstFrame / CR0.grid)) maxAbs=\(CR0.dbText(d.maxAbs)) dBFS"
                }
                print("[CR0] DIFFER \(fixture.id): golden \(expected.prefix(12)) now \(digest.prefix(12))\(detail)")
            }
        }
        let rendered = Set(fixtures.map(\.id))
        let stale = goldenOrder.filter { !rendered.contains($0) }
        print("[CR0] G1 compare summary: \(equal) equal, \(differ.count) differ, \(missing.count) missing, \(stale.count) golden rows not rendered")
        for suffix in [".a", ".b", ".c"].map({ $0 + CR0.setSuffix }) {
            print("[CR0]   \(suffix): differ \(differ.filter { $0.hasSuffix(suffix) }.count) of \(fixtures.filter { $0.id.hasSuffix(suffix) }.count)")
        }
        #expect(differ.isEmpty, "G1 differs: \(differ.joined(separator: ", "))")
        #expect(missing.isEmpty, "fixtures with no golden row: \(missing.joined(separator: ", "))")
        #expect(stale.isEmpty, "golden rows this tree no longer renders: \(stale.joined(separator: ", "))")
        try? FileManager.default.removeItem(at: input)
    }

    // MARK: G0 — static split-invariance census

    @Test("CR-0 G0 census: 22 kinds, static params, no automation, N in 64/128/441/480/512/1024 vs 512 (CR0_CENSUS=1)",
          .enabled(if: ProcessInfo.processInfo.environment["CR0_CENSUS"] == "1"))
    func g0StaticSplitInvarianceCensus() async throws {
        let input = try CR0.writeInputFile()
        var rows: [(id: String, tracks: [Track])] = []
        rows.append(("dry", [CR0.audioTrack(key: "g0.dry", input: input, effects: [], motion: nil)]))
        // Positive control: an AUTOMATED gain (lane only, off-grid breakpoints, 0.4…2.0 linear).
        let gain = EffectDescriptor(id: CR0.id("g0.pc.effect"), kind: .gain)
        let gainValues = [0.5, 2.0, 0.7, 1.8, 0.4, 1.5, 0.9]
        let pcLane = AutomationLane(
            id: CR0.id("g0.pc.lane"), target: .effectParam(effectID: gain.id, paramName: "gainLinear"),
            points: zip(CR0.lanePoints, gainValues).map { AutomationPoint(beat: $0.0.beat, value: $0.1) })
        rows.append(("PC.gain-lane", [CR0.audioTrack(
            key: "g0.pc", input: input, effects: [gain],
            motion: CR0.Motion(lanes: [pcLane], sources: [], routes: [], note: "pc"))]))
        for kind in CR0.builtInKinds {
            let key = "g0.\(kind.rawValue)"
            let effect = CR0.staticEffect(kind, key: "\(key).effect")
            rows.append((kind.rawValue, [CR0.audioTrack(key: key, input: input, effects: [effect], motion: nil)]))
        }
        let columns = CR0.censusFrames
        var tsv = [CR0.tableHeader(first: "activity_vs_dry", columns: columns)]
        var dryReference: [[Float]] = []
        var dryPeak: Float = 0
        var findings: [String] = []
        for row in rows {
            let reference = try await CR0Harness.render(row.tracks, frames: CR0.grid, fromBeat: 0,
                                                        seconds: CR0.censusSeconds)
            let referenceStats = CR0.stats(reference)
            #expect(referenceStats.nonFinite == 0, "\(row.id): non-finite at 512")
            if row.id == "dry" {
                dryReference = reference.channelData
                dryPeak = referenceStats.peak
            }
            let activity = row.id == "dry" ? 0 : CR0.diff(reference.channelData, dryReference).count
            var counts: [Int] = []
            var maxima: [String] = []
            var firstFrames: [String] = []
            for n in columns {
                let audio = try await CR0Harness.render(row.tracks, frames: n, fromBeat: 0, seconds: CR0.censusSeconds)
                #expect(CR0.stats(audio).nonFinite == 0, "\(row.id) N=\(n): non-finite")
                let d = CR0.diff(audio, reference)
                counts.append(d.count)
                maxima.append(CR0.dbText(d.maxAbs))
                if d.count > 0 { firstFrames.append("N\(n)@\(d.firstFrame)") }
                switch row.id {
                case "dry":
                    #expect(d.count == 0, "NULL CONTROL: the dry path differs at N=\(n) — every effect row is uninterpretable")
                case "PC.gain-lane":
                    if n == CR0.grid {
                        #expect(d.count == 0, "PC at the 512 repeat must be 0 (determinism)")
                    } else {
                        #expect(d.count > 0, "POSITIVE CONTROL: an automated gain at N=\(n) must differ from 512 — this column is blind")
                    }
                default:
                    if n == CR0.grid { #expect(d.count == 0, "\(row.id): the 512 repeat differs — nondeterministic") }
                    if n != CR0.grid, d.count > 0 { findings.append("\(row.id)@N\(n)=\(d.count)") }
                }
            }
            if row.id != "dry" && row.id != "PC.gain-lane" {
                #expect(activity > 0, "\(row.id): static render equals dry — this row is blind")
            }
            // The two overrides must keep doing their job (CR0.staticOverrides): the limiter limits, the gate gates.
            if row.id == "limiter" {
                #expect(referenceStats.peak < dryPeak, "limiter row never limits — its gain-reduction path is idle")
            }
            if row.id == "gate" {
                #expect(activity > reference.frameCount / 4, "gate row barely gates — its dynamic path is thin")
            }
            print(CR0.rowLine(prefix: "G0", id: row.id, width: 16, activity: activity, columns: columns,
                              counts: counts, firstFrames: firstFrames))
            tsv.append(CR0.tableRow(id: row.id, activity: activity, peak: referenceStats.peak, counts: counts,
                                    maxima: maxima, firstFrames: firstFrames))
        }
        print("[CR0] G0 FINDINGS (kinds that differ at STATIC params): \(findings.isEmpty ? "none" : findings.joined(separator: " "))")
        let directory = CR0.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = CR0.builtInKinds.map { "# settings \($0.rawValue): \(CR0.settingsText($0))" }
        try ((settings + tsv).joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("cr0-g0-census.tsv"), atomically: true, encoding: .utf8)
        print("[CR0] G0 table -> \(directory.appendingPathComponent("cr0-g0-census.tsv").path)")
        try? FileManager.default.removeItem(at: input)
    }

    // MARK: Instrument targets

    @Test("CR-0 instruments: drumSynth + polySynth modulation routes, N in 64/441/480/512/1024 vs 512 (CR0_INSTR=1)",
          .enabled(if: ProcessInfo.processInfo.environment["CR0_INSTR"] == "1"))
    func instrumentTargetsAcrossBlockSizes() async throws {
        func lfo(_ key: String) -> ModulationSource {
            ModulationSource(id: CR0.id("\(key).lfo"), kind: .lfo,
                             params: .lfo(LFOSourceParams(waveform: .sine, rateHz: CR0.lfoRateHz, bipolar: true)))
        }
        // Free-running (no stepDivision), the W44 shape. Synced sources are covered by StepDivisionG8Tests.
        let step = ModulationSource(id: CR0.id("i1.step"), kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, -1, 0.5], rateHz: 5.3, edgeMs: 2)))
        let levelLFO = lfo("i2")
        let cutoffLFO = lfo("i4")
        var drift = PolySynthParams()
        drift.drift = 0.5
        let rows: [(id: String, track: Track)] = [
            ("I0.drum-null", CR0.drumTrack(key: "i0", sources: [], routes: [])),
            ("I1.drum-step-snare.decay", CR0.drumTrack(key: "i1", sources: [step], routes: [ModulationRoute(
                id: CR0.id("i1.route"), sourceID: step.id, target: .instrumentParam(paramName: "snare.decay"),
                depth: 0.5)])),
            ("I2.drum-lfo-closedHat.level", CR0.drumTrack(key: "i2", sources: [levelLFO], routes: [ModulationRoute(
                id: CR0.id("i2.route"), sourceID: levelLFO.id, target: .instrumentParam(paramName: "closedHat.level"),
                depth: 0.5)])),
            ("I3.poly-null", CR0.polySynthTrack(key: "i3", effects: [], motion: nil, notesUntilBeat: 4)),
            ("I4.poly-lfo-cutoffHz", CR0.polySynthTrack(key: "i4", effects: [], motion: CR0.Motion(
                lanes: [], sources: [cutoffLFO], routes: [ModulationRoute(
                    id: CR0.id("i4.route"), sourceID: cutoffLFO.id, target: .instrumentParam(paramName: "cutoffHz"),
                    depth: 0.3)], note: "i4"), notesUntilBeat: 4)),
            ("I5.poly-drift0.5(PC)", CR0.polySynthTrack(key: "i5", polySynth: drift, effects: [], motion: nil,
                                                        notesUntilBeat: 4)),
        ]
        let columns = CR0.instrumentFrames
        var references: [String: [[Float]]] = [:]
        var tsv = [CR0.tableHeader(first: "activity_vs_null", columns: columns)]
        for row in rows {
            let reference = try await CR0Harness.render([row.track], frames: CR0.grid, fromBeat: 0,
                                                        seconds: CR0.censusSeconds)
            let referenceStats = CR0.stats(reference)
            #expect(referenceStats.nonFinite == 0, "\(row.id): non-finite")
            #expect(referenceStats.peak > 0, "\(row.id): silent")
            references[row.id] = reference.channelData
            let baseline = row.id.hasPrefix("I1") || row.id.hasPrefix("I2") ? references["I0.drum-null"]
                : (row.id.hasPrefix("I4") || row.id.hasPrefix("I5") ? references["I3.poly-null"] : nil)
            let activity = baseline.map { CR0.diff(reference.channelData, $0).count } ?? -1
            if baseline != nil {
                #expect(activity > 0, "\(row.id): the route/drift does not reach the output — this row is blind")
            }
            var counts: [Int] = []
            var maxima: [String] = []
            var firstFrames: [String] = []
            for n in columns {
                let audio = try await CR0Harness.render([row.track], frames: n, fromBeat: 0,
                                                        seconds: CR0.censusSeconds)
                let d = CR0.diff(audio, reference)
                counts.append(d.count)
                maxima.append(CR0.dbText(d.maxAbs))
                if d.count > 0 { firstFrames.append("N\(n)@\(d.firstFrame)") }
                if n == CR0.grid { #expect(d.count == 0, "\(row.id): the 512 repeat differs — nondeterministic") }
                if row.id.hasPrefix("I0") || row.id.hasPrefix("I3") {
                    #expect(d.count == 0, "NULL CONTROL \(row.id) differs at N=\(n)")
                }
                if row.id.hasPrefix("I5"), n != CR0.grid {
                    #expect(d.count > 0, "POSITIVE CONTROL: per-call drift must differ at N=\(n) — this column is blind")
                }
            }
            print(CR0.rowLine(prefix: "INSTR", id: row.id, width: 30, activity: activity, columns: columns,
                              counts: counts, firstFrames: firstFrames))
            tsv.append(CR0.tableRow(id: row.id, activity: activity, peak: referenceStats.peak, counts: counts,
                                    maxima: maxima, firstFrames: firstFrames))
        }
        let directory = CR0.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (tsv.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("cr0-instruments.tsv"), atomically: true, encoding: .utf8)
        print("[CR0] INSTR table -> \(directory.appendingPathComponent("cr0-instruments.tsv").path)")
    }
}

extension CR0 {
    static var plantFrames: Int? { nonEmpty("CR0_PLANT_FRAMES").flatMap { Int($0) } }

    static func tableHeader(first: String, columns: [Int]) -> String {
        var cells = ["id", first, "peak_dBFS"]
        cells += columns.map { "N\($0)" }
        cells += columns.map { "N\($0)_maxAbs_dB" }
        cells.append("firstFrame")
        return cells.joined(separator: "\t")
    }

    static func tableRow(id: String, activity: Int, peak: Float, counts: [Int], maxima: [String],
                         firstFrames: [String]) -> String {
        var cells = [id, "\(activity)", dbText(peak)]
        cells += counts.map { String($0) }
        cells += maxima
        cells.append(firstFrames.joined(separator: ","))
        return cells.joined(separator: "\t")
    }

    static func rowLine(prefix: String, id: String, width: Int, activity: Int, columns: [Int], counts: [Int],
                        firstFrames: [String]) -> String {
        let label = id.padding(toLength: width, withPad: " ", startingAt: 0)
        let cells = zip(columns, counts).map { "N\($0.0)=\($0.1)" }.joined(separator: " ")
        let first = firstFrames.isEmpty ? "" : " first: \(firstFrames.joined(separator: ","))"
        return "[CR0] \(prefix) \(label) activity=\(activity) \(cells)\(first)"
    }
}

// MARK: - m39-d-cr12 (W9-CR12): the off-32 G1 set, the G2 cheaper twin, G4 (every kind holds)
//
// `docs/design/2026-10-07-effect-control-rate.md` §6. `CR12.measure` renders the rows, prints one line per row,
// writes a TSV under `CR0_OUT` and returns the gated rows that differ; the always-on GATE tests below assert that
// list is empty. The "before" tables were taken with the same body, env-gated, on the untouched tree (W9-CR12
// STATUS.md): every gated twin row differed at every N, and G4's held gain lane differed at 64.

extension CR0 {
    /// `CR0_SET=off32` selects `cr0SelectedFixtureSet`'s off-32 twin of the G1 set; anything else is the 10-07 set.
    static var setName: String { nonEmpty("CR0_SET") ?? "g1" }
    /// The id suffix of the selected set ("" for the 10-07 set, "32" for off32).
    static var setSuffix: String { setName == "off32" ? "32" : "" }
    /// 281 · 512 + 100: the final partial block is 100 frames, 100 mod 32 = 4.
    static let off32FullFrames = 143_972
    /// 187 · 512 + 293: the final partial block is 293 frames, 293 mod 32 = 5.
    static let off32WindowFrames = 96_037

    /// G2 twin columns. 441 is NOT a multiple of 32: it is the column that can see a call-anchored 32-frame
    /// coefficient stride (the design's own set is all multiples of 32, 480 = 15 · 32 included).
    static let twinFrames = [64, 128, 256, 441, 480, 1_024, 2_048]
    /// 140 · 512 + 357 (357 mod 32 = 5) from beat 0, and 93 · 512 + 421 (421 mod 32 = 5) from fromBeat 3.37: both
    /// end in a partial cell that is off the 32 grid, so the render end (§5.5) is exercised in every twin row.
    static let twinFullFrames = 72_037
    static let twinWindowFrames = 48_037
    static let g4Frames = 96_000
    static let g4Columns = [64, 441]
    /// G2 MAIN pull sizes: the design's set plus 441 (the stride column).
    static let livePulls = [64, 128, 256, 441, 480, 1_024, 2_048]
}

private struct CR12Row: Sendable {
    var id: String
    var tracks: [Track]
    var fromBeat: Double
    var frames: Int
    /// false = reported, never asserted (a static strip has no effect track, so it never reaches the grid; G0's
    /// call-anchored Phaser stride at 441 is outside CR-1 + CR-2 by design §5.8 F5).
    var gated: Bool
}

private enum CR12 {
    /// G2 twin rows: every kind's lane + routes on an audio strip, from beat 0 and windowed; five kinds on a
    /// polySynth strip (the `InstrumentSourceNode` call site); and three STATIC stride kinds, reported only.
    static func twinRows(input: URL) -> [CR12Row] {
        var rows: [CR12Row] = []
        for kind in CR0.builtInKinds {
            let key = "fx.\(kind.rawValue)"
            let effect = CR0.staticEffect(kind, key: "\(key).effect")
            guard let motion = CR0.effectMotion(effectID: effect.id, kind: kind, key: key) else { continue }
            let track = CR0.audioTrack(key: key, input: input, effects: [effect], motion: motion)
            rows.append(CR12Row(id: "\(key).a", tracks: [track], fromBeat: 0, frames: CR0.twinFullFrames, gated: true))
            rows.append(CR12Row(id: "\(key).b", tracks: [track], fromBeat: CR0.windowFromBeat,
                                frames: CR0.twinWindowFrames, gated: true))
        }
        for kind in [EffectDescriptor.Kind.gain, .flanger, .djFilter, .phaser, .ringMod] {
            let key = "inst.\(kind.rawValue)"
            let effect = CR0.staticEffect(kind, key: "\(key).effect")
            guard let motion = CR0.effectMotion(effectID: effect.id, kind: kind, key: key) else { continue }
            let track = CR0.polySynthTrack(key: key, effects: [effect], motion: motion, notesUntilBeat: 4)
            rows.append(CR12Row(id: "\(key).a", tracks: [track], fromBeat: 0, frames: CR0.twinFullFrames, gated: true))
        }
        for kind in [EffectDescriptor.Kind.phaser, .ringMod, .djFilter] {
            let key = "fx.\(kind.rawValue)"
            let effect = CR0.staticEffect(kind, key: "\(key).effect")
            let track = CR0.audioTrack(key: key, input: input, effects: [effect], motion: nil)
            rows.append(CR12Row(id: "\(key).c-static", tracks: [track], fromBeat: 0, frames: CR0.twinFullFrames,
                                gated: false))
        }
        return rows
    }

    /// G4 rows: per kind, a lane on its first movable param that (1) HOLDS one value away from the knob for the
    /// whole render, and (2) STEPS (`.hold` segments, 0.21-beat = 5 040-frame steps, never on the 512 grid).
    static func g4Rows(input: URL) -> [CR12Row] {
        var rows: [CR12Row] = []
        for kind in CR0.builtInKinds {
            guard let a = CR0.movableSpecs(kind).first else { continue }
            for shape in ["const", "step"] {
                let key = "g4.\(kind.rawValue).\(shape)"
                let effect = CR0.staticEffect(kind, key: "\(key).effect")
                var points: [AutomationPoint] = []
                if shape == "const" {
                    points = [AutomationPoint(beat: 0, value: CR0.travel(a, 0.85))]
                } else {
                    var beat = 0.0
                    var index = 0
                    while beat < 4.2 {
                        points.append(AutomationPoint(beat: beat, value: CR0.travel(a, index % 2 == 0 ? 0.15 : 0.85),
                                                      curve: .hold))
                        beat += 0.21
                        index += 1
                    }
                }
                let lane = AutomationLane(id: CR0.id("\(key).lane"),
                                          target: .effectParam(effectID: effect.id, paramName: a.name),
                                          points: points)
                let track = CR0.audioTrack(key: key, input: input, effects: [effect],
                                           motion: CR0.Motion(lanes: [lane], sources: [], routes: [], note: shape))
                rows.append(CR12Row(id: key, tracks: [track], fromBeat: 0, frames: CR0.g4Frames, gated: true))
            }
        }
        return rows
    }

    /// Renders every row at the default constructor and at each column; prints one line per row and writes a TSV.
    /// Returns the gated rows that differed (`id@N=count`).
    static func measure(label: String, rows: [CR12Row], columns: [Int]) async throws -> [String] {
        var tsv = [CR0.tableHeader(first: "gated", columns: columns)]
        var failures: [String] = []
        for row in rows {
            let seconds = Double(row.frames) / CR0.sampleRate
            let reference = try await CR0Harness.render(row.tracks, frames: nil, fromBeat: row.fromBeat,
                                                        seconds: seconds)
            let referenceStats = CR0.stats(reference)
            #expect(referenceStats.nonFinite == 0, "\(row.id): non-finite at the default block")
            #expect(referenceStats.peak > 0, "\(row.id): silent")
            #expect(reference.frameCount == row.frames, "\(row.id): frame count \(reference.frameCount)")
            var counts: [Int] = []
            var maxima: [String] = []
            var firstFrames: [String] = []
            for n in columns {
                let audio = try await CR0Harness.render(row.tracks, frames: n, fromBeat: row.fromBeat,
                                                        seconds: seconds)
                #expect(CR0.stats(audio).nonFinite == 0, "\(row.id) N=\(n): non-finite")
                let d = CR0.diff(audio, reference)
                counts.append(d.count)
                maxima.append(CR0.dbText(d.maxAbs))
                if d.count > 0 {
                    firstFrames.append("N\(n)@\(d.firstFrame)")
                    if row.gated { failures.append("\(row.id)@N\(n)=\(d.count)") }
                }
            }
            print(CR0.rowLine(prefix: label, id: row.id, width: 30, activity: row.gated ? 1 : 0, columns: columns,
                              counts: counts, firstFrames: firstFrames))
            tsv.append(CR0.tableRow(id: row.id, activity: row.gated ? 1 : 0, peak: referenceStats.peak,
                                    counts: counts, maxima: maxima, firstFrames: firstFrames))
        }
        let directory = CR0.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent("cr12-\(label.lowercased()).tsv")
        try (tsv.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("[CR0] \(label) gated rows that differ: \(failures.isEmpty ? "none" : failures.joined(separator: " "))")
        print("[CR0] \(label) table -> \(out.path)")
        return failures
    }
}

extension ControlGridInvarianceTests {
    /// G2's cheaper twin (design §6): `OfflineRenderer(maximumFrameCount: N)` against the default constructor, every
    /// kind's lane + routes from beat 0 and windowed, five kinds on a polySynth strip, 0 differing samples on every
    /// gated row — 441 included (the column that sees a 32-frame coefficient stride). Before CR-1 + CR-2 every gated
    /// row differed at every N (W9-CR12 STATUS.md, `out-before/cr12-twin.tsv`). Plant P3 (split disabled) reddens it.
    @Test("CR-12 G2 twin GATE: lane + routes at N in 64/128/256/441/480/1024/2048 equal the default, every gated row")
    func g2TwinGate() async throws {
        let input = try CR0.writeInputFile()
        let failures = try await CR12.measure(label: "TWIN", rows: CR12.twinRows(input: input),
                                              columns: CR0.twinFrames)
        #expect(failures.isEmpty, "G2 twin differs: \(failures.joined(separator: " "))")
        try? FileManager.default.removeItem(at: input)
    }

    /// G4 (design §6): every built-in kind HOLDS. A lane that holds one value away from the knob for the whole
    /// render, and one that steps off the grid, rendered at 64 and 441 against the default: bit-identical. Before
    /// CR-1 the held gain lane differed at 64 (its 240-frame declick restarted on every re-store) and the phaser at
    /// 441 (the call-anchored stride). Plant P2 (one kind's hold skips `overlay.hold()`) reddens it at 64.
    @Test("CR-12 G4 GATE: a held lane and a stepping lane per kind at N 64/441 equal the default, every kind")
    func g4Gate() async throws {
        let input = try CR0.writeInputFile()
        let failures = try await CR12.measure(label: "G4", rows: CR12.g4Rows(input: input), columns: CR0.g4Columns)
        #expect(failures.isEmpty, "G4 differs: \(failures.joined(separator: " "))")
        try? FileManager.default.removeItem(at: input)
    }
}

// MARK: - m39-d-cr12-keygate (W9-CRFIX): the sidechain KEY on an automated strip, system level
//
// RT2 REVIEW Q4: no G1 or twin row split a KEY buffer. This one does. A compressor on an audio strip is keyed from a
// drum machine on a second track and carries a lane on its threshold, so the strip runs on the grid; at 441, 480,
// 1 024 and 2 048 every call that crosses a cell line is split, and the key must be cut exactly where the main
// buffers are (`AutomationRenderer.renderChain`'s `segmentKey`). A control row (the same two tracks, the compressor
// NOT keyed) attributes a red to the key rather than to the drum track; the liveness renders prove the key reaches the
// detector and that the keyed compressor really changes the audio.

extension CR12 {
    /// The keyed row's tracks, its unkeyed control, and the same keyed strip with the compressor fully dry
    /// (`mix` 0 is a bit-exact bypass of the whole unit).
    static func keygateTracks(input: URL) throws -> (keyed: [Track], unkeyed: [Track], dry: [Track]) {
        let drums = CR0.drumTrack(key: "kg.drums", sources: [], routes: [])
        var compressor = EffectDescriptor(id: CR0.id("kg.comp.effect"), kind: .compressor)
        // A fast, hard duck: every kick and snare in the key should pull the strip down.
        for (name, value) in [("ratio", 8.0), ("attackMs", 0.5), ("releaseMs", 40.0), ("kneeDb", 0.0),
                              ("makeupDb", 0.0), ("mix", 1.0)] {
            compressor.applySetting(name, value)
        }
        guard let threshold = EffectParamSpec.specs(for: .compressor).first(where: { $0.name == "thresholdDb" }) else {
            throw CR0Error.setup("compressor thresholdDb spec")
        }
        let lane = AutomationLane(
            id: CR0.id("kg.comp.lane"),
            target: .effectParam(effectID: compressor.id, paramName: threshold.name),
            points: CR0.lanePoints.map { AutomationPoint(beat: $0.beat, value: CR0.travel(threshold, $0.fraction)) })
        let motion = CR0.Motion(lanes: [lane], sources: [], routes: [], note: "keyed; lane thresholdDb")
        var keyed = compressor
        keyed.sidechainSourceTrackID = drums.id
        var dry = keyed
        dry.applySetting("mix", 0)
        return ([drums, CR0.audioTrack(key: "kg.comp", input: input, effects: [keyed], motion: motion)],
                [drums, CR0.audioTrack(key: "kg.comp", input: input, effects: [compressor], motion: motion)],
                [drums, CR0.audioTrack(key: "kg.comp", input: input, effects: [dry], motion: motion)])
    }
}

extension ControlGridInvarianceTests {
    /// m39-d-cr12-keygate (RT2 REVIEW Q4, the system-level gate): the keyed row at every twin column against the
    /// default constructor, 0 differing samples; 480 is the ROADMAP's named column (calls split 32 + 448 frames, and
    /// so on). The plant that hands the walk `key` instead of `segmentKey` turns it red.
    @Test("CR-12 keygate twin: a compressor keyed from a drum track, a lane on its threshold, at N 64…2048 (480 named) equals the default")
    func keyedCompressorTwinGate() async throws {
        let input = try CR0.writeInputFile()
        let tracks = try CR12.keygateTracks(input: input)
        let rows = [
            CR12Row(id: "kg.compressor.keyed", tracks: tracks.keyed, fromBeat: 0, frames: CR0.twinFullFrames,
                    gated: true),
            CR12Row(id: "kg.compressor.unkeyed", tracks: tracks.unkeyed, fromBeat: 0, frames: CR0.twinFullFrames,
                    gated: true),
        ]
        let failures = try await CR12.measure(label: "KEYGATE", rows: rows, columns: CR0.twinFrames)
        // Liveness, at the default block: the key reaches the detector, and the keyed compressor changes the audio.
        let seconds = Double(CR0.twinFullFrames) / CR0.sampleRate
        let keyed = try await CR0Harness.render(tracks.keyed, frames: nil, fromBeat: 0, seconds: seconds)
        let unkeyed = try await CR0Harness.render(tracks.unkeyed, frames: nil, fromBeat: 0, seconds: seconds)
        let dry = try await CR0Harness.render(tracks.dry, frames: nil, fromBeat: 0, seconds: seconds)
        let keyLive = CR0.diff(keyed, unkeyed)
        let compressing = CR0.diff(keyed, dry)
        print("[CR0] KEYGATE liveness: keyed vs unkeyed differ at \(keyLive.count) samples (max "
              + "\(CR0.dbText(keyLive.maxAbs)) dBFS); keyed vs dry (mix 0) differ at \(compressing.count) samples (max "
              + "\(CR0.dbText(compressing.maxAbs)) dBFS); keyed peak \(CR0.dbText(CR0.stats(keyed).peak)) dBFS")
        #expect(keyLive.count > 0, "the key never reached the detector: the row is blind")
        #expect(compressing.count > 0, "the keyed compressor never changed the audio: the row is blind")
        #expect(failures.isEmpty, "keygate twin differs: \(failures.joined(separator: " "))")
        try? FileManager.default.removeItem(at: input)
    }
}

// MARK: - m39-d-cr12 (W9-CR12): G2 MAIN — the live graph, device-free (CR12_LIVE=1)
//
// Design §6 G2's main check: the M39D harness (`LiveBlockSizeModulationTests.swift`, `M39DHarness.realtime`) —
// `.realtime` manual rendering, `startAllPlayers(at: nil)` — at N in 64/128/256/441/480/1024/2048 against the 512
// bounce, 0 differing samples OVER WHOLE CELLS (a live roll has no render end, so its last partial cell is not
// capped the way the bounce's is, §5.5). Same rows as the twin's (a) rows: every kind's lane + routes on an audio
// strip (the `ChainHostAU` call site) and five kinds on a polySynth strip (the `InstrumentSourceNode` call site).
// `at: nil` rolls with SAMPLE-time positions; the host-time path is `ControlGridTests`' G3.
//
// ⚠️ Env-gated because a realtime FILE PLAYER STARVES when the pull loop outruns its disk reader. MEASURED
// 2026-10-11 (W9-CR12): unpaced, audio rows went to exact zeros from frame 55 296 onward while the polySynth rows (no
// file) were bit-identical at every N. Audio rows are therefore PACED (`paceMs` per 100 ms of audio), and a row that
// still differs is re-rendered once at real time; both results print, so a starvation red can never pass for a grid
// red and a grid red must survive a fully paced re-render.

private enum CR12LiveError: Error {
    case setup(String)
}

private struct CR12LiveRender: Sendable {
    var channels: [[Float]]
    var retries: Int
}

private struct CR12LiveRow: Sendable {
    var id: String
    var tracks: [Track]
    var paced: Bool
}

@MainActor
private enum CR12Live {
    static let maximumFrames = 2_048

    /// `M39DHarness.realtime`'s roll, both channels, any tracks, a 2048 maximum (the design's largest N); sleeps
    /// `paceMs` after every 100 ms of rendered audio.
    static func render(_ tracks: [Track], pull: Int, frames total: Int, paceMs: Int) async throws -> CR12LiveRender {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: CR0.sampleRate, channels: 2) else {
            throw CR12LiveError.setup("format")
        }
        try engine.enableManualRenderingMode(.realtime, format: format,
                                             maximumFrameCount: AVAudioFrameCount(maximumFrames))
        _ = engine.mainMixerNode
        _ = graph.reconcile(tracks: tracks)
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        try engine.start()
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        graph.scheduleAll(fromBeat: 0, tempoMap: CR0.tempoMap)
        graph.startAllPlayers(at: nil)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maximumFrames)),
              let data = buffer.floatChannelData else { throw CR12LiveError.setup("pull buffer") }
        let render = engine.manualRenderingBlock
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(total)
        right.reserveCapacity(total)
        var retries = 0
        var sincePace = 0
        let paceFrames = Int(0.1 * CR0.sampleRate)
        while left.count < total {
            let frames = min(pull, total - left.count)
            buffer.frameLength = AVAudioFrameCount(frames)
            var error: OSStatus = noErr
            let status = render(AVAudioFrameCount(frames), buffer.mutableAudioBufferList, &error)
            if status == .cannotDoInCurrentContext, retries < 1_000 {
                retries += 1
                await Task.yield()
                continue
            }
            guard status == .success else {
                throw CR12LiveError.setup("manual render status \(status.rawValue) error \(error) at \(left.count)")
            }
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: frames))
            sincePace += frames
            if paceMs > 0, sincePace >= paceFrames {
                sincePace = 0
                try await Task.sleep(for: .milliseconds(paceMs))
            }
        }
        graph.stopAllPlayers()
        engine.stop()
        return CR12LiveRender(channels: [left, right], retries: retries)
    }
}

extension CR0 {
    /// Live samples that are exactly 0 where the bounce is not: the file-player starvation signature.
    static func starvedSamples(_ live: [[Float]], _ reference: [[Float]]) -> Int {
        var starved = 0
        for (x, y) in zip(live, reference) {
            var i = 0
            while i < min(x.count, y.count) {
                if x[i] == 0, y[i] != 0 { starved += 1 }
                i += 1
            }
        }
        return starved
    }
}

extension ControlGridInvarianceTests {
    @Test("CR-12 G2 MAIN: the live graph (.realtime, at: nil) at N in 64…2048 equals the 512 bounce over whole cells (CR12_LIVE=1)",
          .enabled(if: ProcessInfo.processInfo.environment["CR12_LIVE"] == "1"))
    func g2LiveMain() async throws {
        let input = try CR0.writeInputFile()
        let pace = Int(CR0.environment["CR12_LIVE_PACE_MS"] ?? "") ?? 25
        var liveRows: [CR12LiveRow] = []
        for kind in CR0.builtInKinds {
            let key = "fx.\(kind.rawValue)"
            let effect = CR0.staticEffect(kind, key: "\(key).effect")
            guard let motion = CR0.effectMotion(effectID: effect.id, kind: kind, key: key) else { continue }
            liveRows.append(CR12LiveRow(id: "\(key).a", tracks: [CR0.audioTrack(key: key, input: input,
                                                                                  effects: [effect], motion: motion)],
                                        paced: true))
        }
        for kind in [EffectDescriptor.Kind.gain, .flanger, .djFilter, .phaser, .ringMod] {
            let key = "inst.\(kind.rawValue)"
            let effect = CR0.staticEffect(kind, key: "\(key).effect")
            guard let motion = CR0.effectMotion(effectID: effect.id, kind: kind, key: key) else { continue }
            liveRows.append(CR12LiveRow(id: "\(key).a", tracks: [CR0.polySynthTrack(key: key, effects: [effect],
                                                                                      motion: motion,
                                                                                      notesUntilBeat: 4)],
                                        paced: false))
        }
        let total = CR0.twinFullFrames
        let whole = (total / CR0.grid) * CR0.grid
        var failures: [String] = []
        var rerendered = 0
        for row in liveRows {
            let bounce = try await CR0Harness.render(row.tracks, frames: nil, fromBeat: 0,
                                                     seconds: Double(total) / CR0.sampleRate)
            let reference = bounce.channelData.map { Array($0.prefix(whole)) }
            #expect(CR0.stats(bounce).peak > 0, "\(row.id): silent bounce")
            var cells: [String] = []
            for pull in CR0.livePulls {
                var live = try await CR12Live.render(row.tracks, pull: pull, frames: total,
                                                     paceMs: row.paced ? pace : 0)
                var trimmed = live.channels.map { Array($0.prefix(whole)) }
                var d = CR0.diff(trimmed, reference)
                var note = ""
                if d.count > 0, row.paced {
                    rerendered += 1
                    note = "[paced \(pace) ms: \(d.count) from \(d.firstFrame), starved "
                        + "\(CR0.starvedSamples(trimmed, reference)); real-time re-render]"
                    live = try await CR12Live.render(row.tracks, pull: pull, frames: total, paceMs: 100)
                    trimmed = live.channels.map { Array($0.prefix(whole)) }
                    d = CR0.diff(trimmed, reference)
                }
                let starved = CR0.starvedSamples(trimmed, reference)
                cells.append("N\(pull)=\(d.count)" + (starved > 0 ? "(starved \(starved))" : "")
                             + (live.retries > 0 ? "(retries \(live.retries))" : "") + note)
                if d.count > 0 {
                    failures.append("\(row.id)@N\(pull)=\(d.count) first \(d.firstFrame) starved \(starved)")
                }
            }
            print("[CR0] LIVE \(row.id.padding(toLength: 24, withPad: " ", startingAt: 0)) whole cells \(whole) of "
                  + "\(total): \(cells.joined(separator: " "))")
        }
        print("[CR0] LIVE pace \(pace) ms per 100 ms of audio on file rows; \(rerendered) real-time re-render(s)")
        print("[CR0] LIVE rows that differ over whole cells: "
              + "\(failures.isEmpty ? "none" : failures.joined(separator: " "))")
        #expect(failures.isEmpty, "G2 main differs: \(failures.joined(separator: " "))")
        try? FileManager.default.removeItem(at: input)
    }
}
