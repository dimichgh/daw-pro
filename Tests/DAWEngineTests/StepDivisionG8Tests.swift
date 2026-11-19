import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-w4-4 G8 (W9-UNLOCK, 2026-10-11) — THE UNLOCK'S MERGE GATE: a TEMPO-SYNCED step source sounds the same live as in
// the bounce, at the buffer sizes an audio interface really runs, across a tempo change AND a mid-song meter change.
//
// THE TWO RENDERS
// - BOUNCE: `AudioEngine.renderOffline(tracks:tempoMap:meterMap:…)`, the production entry every store bounce, mixdown
//   and stem goes through (512-frame blocks). NOT `OfflineRenderer` directly: W8-W44R N1 was a production entry that
//   silently dropped the meter map, and a gate on the renderer underneath it could never have seen that.
// - LIVE: the device-free live graph, W9-CR12's G2 MAIN harness (`ControlGridInvarianceTests.swift`): a
//   `PlaybackGraph` on an `AVAudioEngine` in `.realtime` manual rendering, `scheduleAll(…, meterMap:)` then
//   `startAllPlayers(at: nil)`, pulled at 64 and 1024 frames (512 is the null column). Compared over WHOLE 512-frame
//   cells: a live roll has no render end, and the bounce caps its last partial cell (cr12 design §5.5).
//
// THE SONG: 120 BPM, then 90 from beat 8 (bar 3); 4/4, then 3/4 from beat 16 (bar 5); beat 0 to beat 21.
//
// THE ROWS. Every source is built through `ModulationSourceParams.apply`, the applier `mod.addSource` and
// `mod.setSource` call, never by writing `StepSequencerSourceParams(stepDivision:)` by hand: a restored refusal
// (plant a) must reach this gate.
// - vol.dc            the fader over a DC clip, 1/4 [1,0,0]. The PHYSICS row: every level edge on the MIDI schedule's
//                     frame (±1), the pattern starting again at the 3/4 change, T-N1b's mid-beat probes.
// - fx.gain.dc        an EFFECT parameter (a gain insert's gainLinear) over the DC clip, 1/4 [1,0,0]: mid-beat probes.
// - fx.djFilter.poly  an EFFECT parameter on a polySynth strip, 1/16 (no file, so nothing can starve).
// - inst.poly.cutoff  an INSTRUMENT parameter on the polySynth's per-call 32-frame stride (m39-d-cr4), 1/16.
// - inst.drum.decay   an INSTRUMENT parameter the drum machine latches at note-on (snare.decay), 1/16.
// - inst.drum.level   an INSTRUMENT parameter on the drum machine's output stride (closedHat.level), 1/16.
// Each row also runs FREE-RUNNING (`rateHz`, no division): the CONTROL. Whatever a free source does at 64/1024 is the
// floor (m39-d-cr4: the instrument stride is counted per render call), and the synced source must add nothing to it.
//
// THE ASSERTIONS, and the plant each one answers
// 1. LIVE == BOUNCE at 64/512/1024 on every row, synced and control: 0 differing samples over whole cells.
// 2. ACTIVITY: every row's bounce differs from the same strip with its routes removed (a blind row proves nothing).
// 3. METER AXIS: every SYNCED row's bounce differs from the same bounce with the meter held at 4/4, and not before the
//    3/4 change; every CONTROL row's two bounces are bit-identical (the meter reaches nothing but a synced clock). A
//    clock that ignores the meter (plant b) turns this red while 1 stays green, because both renders then read the
//    same wrong clock. That is why 1 alone is not a gate.
// 4. PHYSICS (vol.dc, the bounce and every live pull): every step edge within ±1 frame of the MIDI schedule's frame for
//    that boundary, the pattern starting again at the 3/4 change; the mid-beat probes read closed/open as written.
//
// Nonisolated suite (the @MainActor suite cap is spent): the renders run in `@MainActor` helpers awaited one at a
// time. `UL_DECODE_OUT=<dir>` makes the old-project test write its render's raw Float32 for a before/after `cmp`.

private enum G8Error: Error {
    case setup(String)
}

private enum G8 {
    static let sampleRate = 48_000.0
    static let grid = 512
    static let pulls = [64, 512, 1_024]
    static let throughBeat = 21.0
    static let meterBeat = 16.0
    static let freeRateHz = 5.3
    static let dcLevel: Float = 0.5

    /// 120 BPM, 90 from bar 3 (beat 8): every 1/16 edge is a whole sample at 48 kHz (6 000 / 8 000 frames).
    static func tempoMap() throws -> TempoMap {
        try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 8, bpm: 90)])
    }

    /// 4/4, then 3/4 from bar 5 (beat 16).
    static func meterMap() throws -> MeterMap {
        try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                               .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])
    }

    /// The meter held at 4/4: what a render that dropped the meter would compile.
    static let heldMeter = MeterMap(constant: TimeSignature())

    static func frame(atBeat beat: Double, _ tempo: TempoMap) -> Int {
        Int((tempo.seconds(from: 0, to: beat) * sampleRate).rounded())
    }

    static func totalFrames(_ tempo: TempoMap) -> Int { frame(atBeat: throughBeat, tempo) }

    /// A fixed UUID per name, so every render is reproducible across processes.
    static func id(_ key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("dawpro-g8/\(key)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    enum Clock: Sendable {
        case synced(String)
        case free
    }

    /// A step source through `ModulationSourceParams.apply`, the wire's applier.
    static func stepSource(_ key: String, steps: [Double], clock: Clock, edgeMs: Double) throws -> ModulationSource {
        var values: [String: ModulationParamValue] = ["steps": .numbers(steps), "edgeMs": .number(edgeMs)]
        switch clock {
        case .synced(let division): values["stepDivision"] = .string(division)
        case .free: values["rateHz"] = .number(freeRateHz)
        }
        let params = try ModulationSourceParams.apply(values, to: .defaults(for: .stepSequencer)).params
        return ModulationSource(id: id("\(key).step"), kind: .stepSequencer, params: params)
    }

    // MARK: Tracks

    static func dcTrack(key: String, dc: URL, effects: [EffectDescriptor], sources: [ModulationSource],
                        routes: [ModulationRoute]) -> Track {
        Track(id: id("\(key).track"), name: "G8 \(key)", kind: .audio,
              clips: [Clip(id: id("\(key).clip"), name: "dc", startBeat: 0, lengthBeats: 24, audioFileURL: dc)],
              effects: effects, modulationSources: sources, modulationRoutes: routes)
    }

    static func synthNotes(key: String) -> [MIDINote] {
        let pitches = [48, 55, 60, 64, 67, 72, 62, 57]
        var notes: [MIDINote] = []
        var beat = 0.0
        var index = 0
        while beat < throughBeat {
            notes.append(MIDINote(id: id("\(key).note\(index)"), pitch: pitches[index % pitches.count],
                                  velocity: 96, startBeat: beat, lengthBeats: 0.4))
            beat += 0.5
            index += 1
        }
        return notes
    }

    static func polySynthTrack(key: String, effects: [EffectDescriptor], sources: [ModulationSource],
                               routes: [ModulationRoute]) -> Track {
        Track(id: id("\(key).track"), name: "G8 \(key)", kind: .instrument,
              clips: [Clip(id: id("\(key).clip"), name: "notes", startBeat: 0, lengthBeats: 24,
                           notes: synthNotes(key: key))],
              instrument: InstrumentDescriptor(kind: .polySynth, polySynth: PolySynthParams()),
              effects: effects, modulationSources: sources, modulationRoutes: routes)
    }

    static func drumTrack(key: String, sources: [ModulationSource], routes: [ModulationRoute]) -> Track {
        let layout = DrumKitParams().noteLayout
        let kick = Int(DrumVoice.kick.primaryNote(in: layout))
        let snare = Int(DrumVoice.snare.primaryNote(in: layout))
        let hat = Int(DrumVoice.closedHat.primaryNote(in: layout))
        var notes: [MIDINote] = []
        var index = 0
        while Double(index) * 0.25 < throughBeat {
            let beat = Double(index) * 0.25
            if index % 4 == 0 {
                notes.append(MIDINote(id: id("\(key).k\(index)"), pitch: kick, velocity: 110, startBeat: beat,
                                      lengthBeats: 0.2))
            }
            if index % 4 == 2 {
                notes.append(MIDINote(id: id("\(key).s\(index)"), pitch: snare, velocity: 100, startBeat: beat,
                                      lengthBeats: 0.2))
            }
            notes.append(MIDINote(id: id("\(key).h\(index)"), pitch: hat, velocity: 80 + (index % 3) * 10,
                                  startBeat: beat, lengthBeats: 0.1))
            index += 1
        }
        return Track(id: id("\(key).track"), name: "G8 \(key)", kind: .instrument,
                     clips: [Clip(id: id("\(key).clip"), name: "drums", startBeat: 0, lengthBeats: 24,
                                  notes: notes)],
                     instrument: InstrumentDescriptor(kind: .drumSynth),
                     modulationSources: sources, modulationRoutes: routes)
    }

    /// A stereo Float32 WAV of the constant `dcLevel`, long enough for the clip (beat 24 is 14.67 s on this map).
    static func writeDC() throws -> URL {
        let frames = Int(16 * sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-g8-dc-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { throw G8Error.setup("dc buffer") }
        buffer.frameLength = AVAudioFrameCount(frames)
        var channel = 0
        while channel < 2 {
            data[channel].update(repeating: dcLevel, count: frames)
            channel += 1
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    // MARK: Comparison

    struct Diff {
        var count: Int
        var firstFrame: Int
    }

    /// Samples whose bit patterns differ over the first `frames` of every channel.
    static func diff(_ a: [[Float]], _ b: [[Float]], frames: Int) -> Diff {
        var count = 0
        var first = -1
        var channel = 0
        while channel < min(a.count, b.count) {
            let x = a[channel]
            let y = b[channel]
            let n = min(frames, min(x.count, y.count))
            var i = 0
            while i < n {
                if x[i].bitPattern != y[i].bitPattern {
                    count += 1
                    if first < 0 || i < first { first = i }
                }
                i += 1
            }
            if x.count < frames || y.count < frames { count += 1 }
            channel += 1
        }
        return Diff(count: count, firstFrame: first)
    }

    /// Live samples that are exactly 0 where the bounce is not: a realtime file player that STARVED (CR12's
    /// `starvedSamples`). Printed beside every non-zero live≠bounce cell, so a starvation red can never pass for a
    /// clock or grid red.
    static func starved(_ live: [[Float]], _ reference: [[Float]], frames: Int) -> Int {
        var count = 0
        var channel = 0
        while channel < min(live.count, reference.count) {
            let x = live[channel]
            let y = reference[channel]
            let n = min(frames, min(x.count, y.count))
            var i = 0
            while i < n {
                if x[i] == 0, y[i] != 0 { count += 1 }
                i += 1
            }
            channel += 1
        }
        return count
    }

    static func peak(_ x: [Float]) -> Float { x.reduce(Float(0)) { max($0, abs($1)) } }

    static func nonFinite(_ channels: [[Float]]) -> Int {
        channels.reduce(0) { $0 + $1.filter { !$0.isFinite }.count }
    }

    /// Frames where the level jumps by more than `threshold` (n ≥ 1).
    static func edges(_ x: [Float], threshold: Float = 0.02) -> [Int] {
        var result: [Int] = []
        var n = 1
        while n < x.count {
            if abs(x[n] - x[n - 1]) > threshold { result.append(n) }
            n += 1
        }
        return result
    }

    /// Every step boundary in (0, throughBeat) where the written value changes, at the MIDI schedule's frame for a note
    /// on that beat. The pattern starts again at every meter change (`changes.last { start <= beat }`, spelled here
    /// independently of `MeterMap.patternOriginBeat` so a broken home cannot agree with itself).
    static func expectedEdges(steps: [Double], stepBeats: Double, tempo: TempoMap,
                              meter: MeterMap) -> [(beat: Double, frame: Int)] {
        func index(_ beat: Double) -> Int {
            let origin = meter.changes.last { $0.startBeat <= beat }?.startBeat ?? 0
            let k = Int(((beat - origin) / stepBeats).rounded())
            return ((k % steps.count) + steps.count) % steps.count
        }
        var result: [(beat: Double, frame: Int)] = []
        var beat = stepBeats
        while beat < throughBeat {
            if steps[index(beat)] != steps[index(beat - stepBeats)] {
                result.append((beat, frame(atBeat: beat, tempo)))
            }
            beat += stepBeats
        }
        return result
    }

    /// Matches every expected edge to a measured one within ±`tolerance` frames.
    static func match(expected: [(beat: Double, frame: Int)], measured: [Int],
                      tolerance: Int = 1) -> (worst: Int, missing: [Double], spurious: [Int]) {
        var unused = Set(measured)
        var worst = 0
        var missing: [Double] = []
        for edge in expected {
            var hit: Int?
            var offset = 0
            while hit == nil, offset <= tolerance {
                if unused.contains(edge.frame + offset) {
                    hit = edge.frame + offset
                } else if offset > 0, unused.contains(edge.frame - offset) {
                    hit = edge.frame - offset
                }
                offset += 1
            }
            if let hit {
                unused.remove(hit)
                worst = max(worst, abs(hit - edge.frame))
            } else {
                missing.append(edge.beat)
            }
        }
        return (worst, missing, unused.sorted())
    }

    /// T-N1b's probes: mid-beat, closed (step value 1) or open (0), for [1, 0, 0] at 1/4 with the restart at beat 16.
    static let probes: [(beat: Double, closed: Bool)] = [
        (2.5, false), (3.5, true), (9.5, true), (10.5, false),
        (14.5, false), (15.5, true), (16.5, true), (17.5, false), (18.5, false), (19.5, true),
    ]
}

/// One G8 row: a strip, synced or free-running, and how much of the physics it can be held to.
private struct G8Row: Sendable {
    var id: String
    var synced: Bool
    var tracks: [Track]
    /// The same strip with its routes removed (the activity reference), shared by a row's synced and control twins.
    var unroutedKey: String
    var unrouted: [Track]
    /// A file-backed strip: pace the live pull so the realtime file player cannot starve (CR12's measurement).
    var paced: Bool
    /// vol.dc: exact edges (assertion 4).
    var edges: Bool
    /// Below this fraction of the peak a probe reads CLOSED; nil = no probes.
    var probeThreshold: Float?
    /// How far BEFORE the 3/4 change the meter-held bounce may start to differ: an effect parameter's 512-frame cell,
    /// an edge ramp that trails the boundary. 1 for the stage's per-sample fader.
    var meterLead: Int
}

@MainActor
private enum G8Render {
    static let maximumFrames = 1_024

    /// The production bounce: `AudioEngine.renderOffline` with the meter.
    static func bounce(_ engine: AudioEngine, _ tracks: [Track], tempo: TempoMap, meter: MeterMap) async throws
        -> [[Float]] {
        let seconds = Double(G8.totalFrames(tempo)) / G8.sampleRate
        return try await engine.renderOffline(
            tracks: tracks, tempoMap: tempo, meterMap: meter, masterVolume: 1,
            masterEffects: [], masterAutomation: [],
            masterModulationSources: [], masterModulationRoutes: [],
            fromBeat: 0, durationSeconds: seconds, forcedCompensationTargets: nil).channelData
    }

    /// The live graph at `pull` frames per render call (W9-CR12's `CR12Live.render`, plus the tempo and meter maps).
    static func live(_ tracks: [Track], tempo: TempoMap, meter: MeterMap, pull: Int,
                     paceMs: Int) async throws -> (channels: [[Float]], retries: Int) {
        let total = G8.totalFrames(tempo)
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: G8.sampleRate, channels: 2) else {
            throw G8Error.setup("format")
        }
        try engine.enableManualRenderingMode(.realtime, format: format,
                                             maximumFrameCount: AVAudioFrameCount(maximumFrames))
        _ = engine.mainMixerNode
        _ = graph.reconcile(tracks: tracks)
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        try engine.start()
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        graph.scheduleAll(fromBeat: 0, tempoMap: tempo, meterMap: meter)
        graph.startAllPlayers(at: nil)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maximumFrames)),
              let data = buffer.floatChannelData else { throw G8Error.setup("pull buffer") }
        let render = engine.manualRenderingBlock
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(total)
        right.reserveCapacity(total)
        var retries = 0
        var sincePace = 0
        let paceFrames = Int(0.1 * G8.sampleRate)
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
                throw G8Error.setup("manual render status \(status.rawValue) error \(error) at \(left.count)")
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
        return ([left, right], retries)
    }
}

@Suite("m39-w4-4 G8 — a synced step source: live equals the bounce across a tempo and a meter change", .serialized)
struct StepDivisionG8Tests {

    /// Builds the rows. A synced row whose source the applier REFUSES is recorded as an issue and left out (plant a,
    /// and the pre-unlock tree): its absence must be loud, never a silently shorter table.
    private static func rows(dc: URL) -> [G8Row] {
        var rows: [G8Row] = []
        for clock in [G8.Clock.synced(""), .free] {
            let synced: Bool
            if case .synced = clock { synced = true } else { synced = false }
            let tag = synced ? "synced" : "free"
            func source(_ key: String, _ steps: [Double], _ division: String, edgeMs: Double) -> ModulationSource? {
                do {
                    return try G8.stepSource("\(key).\(tag)", steps: steps,
                                             clock: synced ? .synced(division) : .free, edgeMs: edgeMs)
                } catch {
                    Issue.record("G8 \(key) [\(tag)]: the applier REFUSED the step source: \(error)")
                    return nil
                }
            }
            // vol.dc
            if let s = source("vol.dc", [1, 0, 0], "1/4", edgeMs: 0) {
                let route = ModulationRoute(id: G8.id("vol.dc.\(tag).route"), sourceID: s.id, target: .volume,
                                            depth: -0.5)
                rows.append(G8Row(
                    id: "vol.dc[\(tag)]", synced: synced,
                    tracks: [G8.dcTrack(key: "vol.dc", dc: dc, effects: [], sources: [s], routes: [route])],
                    unroutedKey: "vol.dc",
                    unrouted: [G8.dcTrack(key: "vol.dc", dc: dc, effects: [], sources: [], routes: [])],
                    paced: true, edges: synced, probeThreshold: synced ? 0.25 : nil, meterLead: 1))
            }
            // fx.gain.dc
            if let s = source("fx.gain.dc", [1, 0, 0], "1/4", edgeMs: 0) {
                let gain = EffectDescriptor(id: G8.id("fx.gain.dc.effect"), kind: .gain)
                let route = ModulationRoute(id: G8.id("fx.gain.dc.\(tag).route"), sourceID: s.id,
                                            target: .effectParam(effectID: gain.id, paramName: "gainLinear"),
                                            depth: -0.031_25)
                rows.append(G8Row(
                    id: "fx.gain.dc[\(tag)]", synced: synced,
                    tracks: [G8.dcTrack(key: "fx.gain.dc", dc: dc, effects: [gain], sources: [s], routes: [route])],
                    unroutedKey: "fx.gain.dc",
                    unrouted: [G8.dcTrack(key: "fx.gain.dc", dc: dc, effects: [gain], sources: [], routes: [])],
                    paced: true, edges: false, probeThreshold: synced ? 0.75 : nil, meterLead: G8.grid))
            }
            // fx.djFilter.poly
            if let s = source("fx.djFilter.poly", [1, 0, 0], "1/16", edgeMs: 2) {
                let filter = EffectDescriptor(id: G8.id("fx.djFilter.poly.effect"), kind: .djFilter)
                let route = ModulationRoute(id: G8.id("fx.djFilter.poly.\(tag).route"), sourceID: s.id,
                                            target: .effectParam(effectID: filter.id, paramName: "position"),
                                            depth: 0.5)
                rows.append(G8Row(
                    id: "fx.djFilter.poly[\(tag)]", synced: synced,
                    tracks: [G8.polySynthTrack(key: "fx.djFilter.poly", effects: [filter], sources: [s],
                                               routes: [route])],
                    unroutedKey: "fx.djFilter.poly",
                    unrouted: [G8.polySynthTrack(key: "fx.djFilter.poly", effects: [filter], sources: [],
                                                 routes: [])],
                    paced: false, edges: false, probeThreshold: nil, meterLead: G8.grid))
            }
            // inst.poly.cutoff
            if let s = source("inst.poly.cutoff", [1, 0, 0], "1/16", edgeMs: 2) {
                let route = ModulationRoute(id: G8.id("inst.poly.cutoff.\(tag).route"), sourceID: s.id,
                                            target: .instrumentParam(paramName: "cutoffHz"), depth: 0.3)
                rows.append(G8Row(
                    id: "inst.poly.cutoff[\(tag)]", synced: synced,
                    tracks: [G8.polySynthTrack(key: "inst.poly.cutoff", effects: [], sources: [s], routes: [route])],
                    unroutedKey: "inst.poly.cutoff",
                    unrouted: [G8.polySynthTrack(key: "inst.poly.cutoff", effects: [], sources: [], routes: [])],
                    paced: false, edges: false, probeThreshold: nil, meterLead: 128))
            }
            // inst.drum.decay
            if let s = source("inst.drum.decay", [1, 0, 0], "1/16", edgeMs: 2) {
                let route = ModulationRoute(id: G8.id("inst.drum.decay.\(tag).route"), sourceID: s.id,
                                            target: .instrumentParam(paramName: "snare.decay"), depth: 0.5)
                rows.append(G8Row(
                    id: "inst.drum.decay[\(tag)]", synced: synced,
                    tracks: [G8.drumTrack(key: "inst.drum.decay", sources: [s], routes: [route])],
                    unroutedKey: "inst.drum.decay",
                    unrouted: [G8.drumTrack(key: "inst.drum.decay", sources: [], routes: [])],
                    paced: false, edges: false, probeThreshold: nil, meterLead: 128))
            }
            // inst.drum.level
            if let s = source("inst.drum.level", [1, 0, 0], "1/16", edgeMs: 2) {
                let route = ModulationRoute(id: G8.id("inst.drum.level.\(tag).route"), sourceID: s.id,
                                            target: .instrumentParam(paramName: "closedHat.level"), depth: 0.5)
                rows.append(G8Row(
                    id: "inst.drum.level[\(tag)]", synced: synced,
                    tracks: [G8.drumTrack(key: "inst.drum.level", sources: [s], routes: [route])],
                    unroutedKey: "inst.drum.level",
                    unrouted: [G8.drumTrack(key: "inst.drum.level", sources: [], routes: [])],
                    paced: false, edges: false, probeThreshold: nil, meterLead: 128))
            }
        }
        return rows
    }

    @Test("⭐ m39-w4-4 G8: a SYNCED step source on the fader, an effect and an instrument renders live at 64/512/1024 exactly as AudioEngine.renderOffline bounces it, across 120→90 and a 3/4 change; the free-running control first")
    func g8LiveEqualsBounceForSyncedSteps() async throws {
        let tempo = try G8.tempoMap()
        let meter = try G8.meterMap()
        let total = G8.totalFrames(tempo)
        let whole = (total / G8.grid) * G8.grid
        let meterFrame = G8.frame(atBeat: G8.meterBeat, tempo)
        let pace = Int(ProcessInfo.processInfo.environment["UL_G8_PACE_MS"] ?? "") ?? 25
        // The starvation diagnostic only prints on a red cell, so hold the counter to a known answer here: one starved
        // sample (live 0, bounce 0.5), one ordinary difference (0.2 vs 0.3), one shared silence (0 vs 0).
        #expect(G8.starved([[0, 0.2, 0]], [[0.5, 0.3, 0]], frames: 3) == 1, "the starved-sample counter itself")
        let dc = try G8.writeDC()
        defer { try? FileManager.default.removeItem(at: dc) }
        let engine = await AudioEngine()
        // CONTROL FIRST: the free-running rows render before the synced ones, so the floor is on the log first.
        let allRows = Self.rows(dc: dc)
        let ordered = allRows.filter { !$0.synced } + allRows.filter(\.synced)
        #expect(ordered.filter(\.synced).count == 6, "every synced row must be built (the applier accepts stepDivision)")
        #expect(ordered.filter { !$0.synced }.count == 6)

        var unroutedCache: [String: [[Float]]] = [:]
        var failures: [String] = []
        var controlDiffers: [String: String] = [:]
        for row in ordered {
            let bounce = try await G8Render.bounce(engine, row.tracks, tempo: tempo, meter: meter)
            #expect(G8.nonFinite(bounce) == 0, "\(row.id): non-finite bounce")
            #expect(bounce.count == 2 && bounce[0].count == total, "\(row.id): bounce frame count \(bounce.first?.count ?? -1)")
            let peak = G8.peak(bounce[0])
            #expect(peak > 0.01, "\(row.id): silent bounce (peak \(peak))")

            // 2. ACTIVITY.
            let unrouted: [[Float]]
            if let cached = unroutedCache[row.unroutedKey] {
                unrouted = cached
            } else {
                unrouted = try await G8Render.bounce(engine, row.unrouted, tempo: tempo, meter: meter)
                unroutedCache[row.unroutedKey] = unrouted
            }
            let activity = G8.diff(bounce, unrouted, frames: total)
            if activity.count == 0 { failures.append("\(row.id): BLIND (the route never reaches the output)") }

            // 3. METER AXIS.
            let held = try await G8Render.bounce(engine, row.tracks, tempo: tempo, meter: G8.heldMeter)
            let meterAxis = G8.diff(bounce, held, frames: total)
            var meterText = "meter axis \(meterAxis.count) from \(meterAxis.firstFrame)"
            if row.synced {
                if meterAxis.count == 0 {
                    failures.append("\(row.id): the 3/4 change does not reach the render (meter-held bounce identical)")
                } else if meterAxis.firstFrame < meterFrame - row.meterLead {
                    failures.append("\(row.id): the meter-held bounce differs at \(meterAxis.firstFrame), BEFORE the "
                                    + "3/4 change at \(meterFrame) − \(row.meterLead)")
                }
                meterText += " (change at \(meterFrame), lead ≤ \(row.meterLead))"
            } else if meterAxis.count != 0 {
                failures.append("\(row.id): a FREE-RUNNING source moved with the meter (\(meterAxis.count) samples from "
                                + "\(meterAxis.firstFrame))")
            }

            // 4. PHYSICS on the bounce.
            var physics = ""
            func physicsCheck(_ label: String, _ x: [Float]) {
                if row.edges {
                    let expected = G8.expectedEdges(steps: [1, 0, 0], stepBeats: 1, tempo: tempo, meter: meter)
                    let measured = G8.edges(Array(x.prefix(whole)))
                    let inRange = expected.filter { $0.frame < whole - 1 }
                    let m = G8.match(expected: inRange, measured: measured)
                    physics += " \(label) edges \(inRange.count) worst \(m.worst) missing \(m.missing.prefix(4)) "
                        + "spurious \(m.spurious.prefix(4))"
                    if !(m.missing.isEmpty && m.spurious.isEmpty && m.worst <= 1) {
                        failures.append("\(row.id) \(label): edges off the map (missing \(m.missing.prefix(6)), "
                                        + "spurious \(m.spurious.prefix(6)), worst \(m.worst))")
                    }
                    if inRange.filter({ $0.beat > G8.meterBeat }).count < 3 {
                        failures.append("\(row.id): the physics row has too few edges after the 3/4 change")
                    }
                }
                if let threshold = row.probeThreshold {
                    let p = G8.peak(x)
                    let read = G8.probes.map { x[G8.frame(atBeat: $0.beat, tempo)] < threshold * p }
                    physics += " \(label) probes \(read == G8.probes.map(\.closed) ? "ok" : "\(read)")"
                    if read != G8.probes.map(\.closed) {
                        failures.append("\(row.id) \(label): probes \(read), written \(G8.probes.map(\.closed))")
                    }
                }
            }
            physicsCheck("bounce", bounce[0])

            // 1. LIVE == BOUNCE.
            let reference = bounce.map { Array($0.prefix(whole)) }
            var cells: [String] = []
            for pull in G8.pulls {
                var live = try await G8Render.live(row.tracks, tempo: tempo, meter: meter, pull: pull,
                                                   paceMs: row.paced ? pace : 0)
                var d = G8.diff(live.channels, reference, frames: whole)
                var note = ""
                if d.count > 0, row.paced {
                    let starvedFirst = G8.starved(live.channels, reference, frames: whole)
                    note = "[paced \(pace) ms: \(d.count) from \(d.firstFrame), starved \(starvedFirst); "
                        + "real-time re-render]"
                    live = try await G8Render.live(row.tracks, tempo: tempo, meter: meter, pull: pull, paceMs: 100)
                    d = G8.diff(live.channels, reference, frames: whole)
                }
                let starved = d.count > 0 ? G8.starved(live.channels, reference, frames: whole) : 0
                #expect(G8.nonFinite(live.channels) == 0, "\(row.id) N=\(pull): non-finite live render")
                cells.append("N\(pull)=\(d.count)" + (d.count > 0 ? "@\(d.firstFrame) starved \(starved)" : "")
                             + note)
                if d.count > 0 {
                    if row.synced {
                        failures.append("\(row.id) N\(pull): live differs from the bounce, \(d.count) samples from "
                                        + "\(d.firstFrame) (starved \(starved): live exactly 0 where the bounce is "
                                        + "not, the realtime file player's signature, not the clock's)")
                    } else {
                        controlDiffers["\(row.id)@N\(pull)"] = "\(d.count) (starved \(starved))"
                    }
                }
                if pull != G8.grid { physicsCheck("N\(pull)", live.channels[0]) }
            }
            print("[G8] \(row.id.padding(toLength: 26, withPad: " ", startingAt: 0)) peak \(String(format: "%.3f", peak)) "
                  + "activity \(activity.count) | \(meterText) | live \(cells.joined(separator: " "))\(physics)")
        }
        print("[G8] whole cells \(whole) of \(total) frames; 3/4 change at frame \(meterFrame); pace \(pace) ms")
        print("[G8] CONTROL (free-running) live≠bounce cells: "
              + (controlDiffers.isEmpty ? "none" : controlDiffers.map { "\($0.key)=\($0.value)" }.sorted()
                  .joined(separator: " ")))
        print("[G8] failures: \(failures.isEmpty ? "none" : failures.joined(separator: " | "))")
        // The control is a floor, not a pass: a free-running row that differs live is m39-d-cr4's per-call stride,
        // and it is REPORTED, with the synced rows held to plain equality regardless.
        #expect(controlDiffers.isEmpty, "the FREE-RUNNING control differs live vs bounce: \(controlDiffers)")
        #expect(failures.isEmpty, "G8: \(failures.joined(separator: " | "))")
    }

    // MARK: - m39-w4-4e: the old-project decode fixture

    /// A step source exactly as a build BEFORE the unlock saved it: `encodeIfPresent` wrote no `stepDivision` key.
    private static let oldProjectStepSourceJSON = """
        {"id":"6A0B2E1C-3F4D-4E5A-9B6C-7D8E9F0A1B2C","kind":"stepSequencer","name":"Step",\
        "params":{"kind":"stepSequencer","steps":[1,0,0.5,-0.5],"rateHz":5.3,"edgeMs":2}}
        """

    @Test("m39-w4-4e: an OLD project's step source (saved with no stepDivision key) decodes free-running, compiles no clock, and its bounce is bit-identical to a free source built in code; the same JSON with a division syncs and differs")
    func oldProjectStepSourcePlaysAsBefore() async throws {
        let decoded = try JSONDecoder().decode(ModulationSource.self, from: Data(Self.oldProjectStepSourceJSON.utf8))
        guard case .stepSequencer(let params) = decoded.params else {
            Issue.record("the fixture did not decode as a step source")
            return
        }
        #expect(params.stepDivision == nil)
        #expect(params.syncedDivision == nil)
        #expect(params.steps == [1, 0, 0.5, -0.5] && params.rateHz == 5.3 && params.edgeMs == 2)
        // Persistence unchanged: re-encoding writes no stepDivision key.
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reencoded.contains("stepDivision"), "re-encoded: \(reencoded)")

        let tempo = try G8.tempoMap()
        let meter = try G8.meterMap()
        let route = ModulationRoute(id: G8.id("decode.route"), sourceID: decoded.id, target: .volume, depth: -0.5)
        // The builder: free-running (divisionBeats 0), and the strip compiles no clock.
        let strip = ModulationSnapshotBuilder.Strip(sources: [decoded], routes: [route], baseVolume: 1)
        #expect(!ModulationSnapshotBuilder.hasSyncedSource(strip))
        let snapshot = try #require(ModulationSnapshotBuilder.build(
            strip: strip, generation: 1, timelineID: 1, sampleRate: G8.sampleRate, originSample: 0,
            positionValid: true))
        #expect(snapshot.sources.count == 1)
        #expect(snapshot.sources[0].divisionBeats == 0)
        #expect(snapshot.sources[0].samplesPerStep == G8.sampleRate / 5.3)
        #expect(snapshot.clock.count == 0)

        let dc = try G8.writeDC()
        defer { try? FileManager.default.removeItem(at: dc) }
        func track(_ source: ModulationSource) -> Track {
            G8.dcTrack(key: "decode", dc: dc, effects: [], sources: [source],
                       routes: [ModulationRoute(id: G8.id("decode.route"), sourceID: source.id, target: .volume,
                                                depth: -0.5)])
        }
        let inCode = ModulationSource(id: decoded.id, kind: .stepSequencer, name: "Step", params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, 0, 0.5, -0.5], rateHz: 5.3, edgeMs: 2)))
        var synced = decoded
        synced.params = .stepSequencer(StepSequencerSourceParams(steps: [1, 0, 0.5, -0.5], stepDivision: "1/16",
                                                                 rateHz: 5.3, edgeMs: 2))
        let engine = await AudioEngine()
        let decodedRender = try await G8Render.bounce(engine, [track(decoded)], tempo: tempo, meter: meter)
        let inCodeRender = try await G8Render.bounce(engine, [track(inCode)], tempo: tempo, meter: meter)
        let heldRender = try await G8Render.bounce(engine, [track(decoded)], tempo: tempo, meter: G8.heldMeter)
        let syncedRender = try await G8Render.bounce(engine, [track(synced)], tempo: tempo, meter: meter)
        let total = G8.totalFrames(tempo)
        let twin = G8.diff(decodedRender, inCodeRender, frames: total)
        let meterAxis = G8.diff(decodedRender, heldRender, frames: total)
        let positive = G8.diff(decodedRender, syncedRender, frames: total)
        let edges = G8.edges(decodedRender[0])
        // A free 5.3 steps/s pattern steps every 48000 / 5.3 = 9 056.6 frames: its edges sit on round(k · that).
        let freeStep = G8.sampleRate / 5.3
        let offGrid = edges.filter { edge in
            let k = (Double(edge) / freeStep).rounded()
            return abs(Double(edge) - k * freeStep) > 200
        }
        print("[UL] decode fixture: decoded vs in-code \(twin.count), decoded vs meter-held \(meterAxis.count), "
              + "decoded vs synced 1/16 \(positive.count) from \(positive.firstFrame); \(edges.count) level edges, "
              + "\(offGrid.count) off the free 5.3 steps/s grid; peak \(G8.peak(decodedRender[0]))")
        #expect(twin.count == 0, "the decoded old source must render bit-identically to a free source built in code")
        #expect(meterAxis.count == 0, "a free-running source must not move with the meter")
        #expect(positive.count > 0, "POSITIVE CONTROL: a synced source over the same fixture must sound different")
        #expect(!edges.isEmpty && offGrid.isEmpty, "the decoded source must step on the free-running grid")
        if let out = ProcessInfo.processInfo.environment["UL_DECODE_OUT"], !out.isEmpty {
            let directory = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var bytes = Data()
            for channel in decodedRender {
                channel.withUnsafeBufferPointer { bytes.append(Data(buffer: $0)) }
            }
            try bytes.write(to: directory.appendingPathComponent("decoded-old-step.f32"))
            print("[UL] decode fixture raw -> \(directory.appendingPathComponent("decoded-old-step.f32").path) "
                  + "(\(bytes.count) bytes)")
        }
    }
}
