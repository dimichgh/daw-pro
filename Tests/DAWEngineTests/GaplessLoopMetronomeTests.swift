import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m14-c (L-3) gates — gapless loop wrap: metronome + toggle
// (docs/research/design-m13f-gapless-loop.md §4-A "Metronome", §6 row 1,
// §9 L-3, §10 conditions C3/C4/C6/C8):
//
//  · Click-placement exactness (C3 discipline): under a MULTI-SEGMENT tempo
//    map with the loop spanning a tempo boundary, ≥ 3 unrolled cycles pin
//    EVERY click frame == the absolute integral from the plan constants,
//    exact == — including the BOUNDARY click EVERY cycle (the L-1 interim's
//    skip class is dead). The whole render reconstructs byte-exact from the
//    two click buffers (placement + downbeat choice + between-click silence
//    in one assertion).
//  · Short-loop torture (C6 law): a 0.25-beat loop at the 400 BPM cap
//    (1 800-frame cycles, shorter than a playhead tick) clicks EVERY cycle
//    for ≥ 25 cycles at the law-minimum horizon — the L-1 short-loop jitter
//    class is dead. §8 modes 8–9 apply to the click player too (it is an
//    AVAudioPlayerNode): the eager sounding+2 / horizon-coverage target
//    keeps its queue never-drained and every enqueue above the ~2.5k-frame
//    mid-flight lead cliff; starvation here fails these == pins.
//  · Meter-aware unroll: a mid-loop meter change (4/4 → 3/4) keeps the
//    downbeat pattern of every unrolled cycle byte-identical to the head
//    pass (downbeat selection uses ABSOLUTE transport beats).
//  · THE HEADLINE (design §9 L-3 gate): an offline-driven A/B toggling the
//    metronome OFF and back ON mid-play leaves CLIP output byte-identical —
//    every frame of the toggled run is pinned against a never-toggled
//    reference (the never-enabled run where the click is commanded off, the
//    always-on run where it is commanded on), and every A-vs-B difference
//    falls inside an expected click window (clicks step on/off exactly on
//    the commanded grid; queued clicks die with the disable).
//  · C8 — null cases: with the metronome OFF (no loop) and ON (no loop),
//    OfflineRenderer output is deterministic; SHAs printed for the cross-era
//    before/after comparison (the m14-c gate ran the SAME fixture on the
//    pre-change tree: OFF a3927faf…, ON 692e713d… — the SHAs must match).
//
// All offline: manual-rendering AVAudioEngine + the REAL Metronome loop
// machinery (scheduleLoopClicks → topUpLoopCycles), the L-1/L-2 rig idiom;
// the A/B rig adds the REAL PlaybackGraph so clip output is the production
// path. One live smoke rides the liveSmoke guard (headless machines return
// early). C4: everything here is control-thread scheduling onto the click
// player — zero render-thread surface was added by L-3.

private let l3Rate = 48_000.0
private let l3Quantum = 512
/// 30 ms click at 48 kHz (pinned by MetronomeTests.clickBufferSynthesis).
private let clickFrames = 1_440

// MARK: - Expected-signal synthesis (the production buffers, verbatim)

@MainActor
private func l3ClickBuffers() throws -> (downbeat: [Float], beat: [Float]) {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: l3Rate, channels: 2))
    // Constants pinned by MetronomeTests: downbeat 1600 Hz / 0.5, beat
    // 1000 Hz / 0.35.
    let down = try #require(Metronome.makeClickBuffer(
        format: format, frequency: 1_600, amplitude: 0.5))
    let beat = try #require(Metronome.makeClickBuffer(
        format: format, frequency: 1_000, amplitude: 0.35))
    func samples(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let channels = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channels[0],
                                         count: Int(buffer.frameLength)))
    }
    return (try samples(down), try samples(beat))
}

/// Byte-exact reconstruction check: `output` must equal the sum of clicks at
/// `(frame, isDownbeat)` and silence everywhere else. Returns mismatch count
/// and a description of the first.
private func l3ReconstructionMismatches(
    _ output: [[Float]], frames: Int, clicks: [(frame: Int, downbeat: Bool)],
    buffers: (downbeat: [Float], beat: [Float])
) -> (count: Int, first: String) {
    var expected = [Float](repeating: 0, count: frames)
    for click in clicks {
        let buffer = click.downbeat ? buffers.downbeat : buffers.beat
        for i in 0..<buffer.count where click.frame + i < frames {
            expected[click.frame + i] += buffer[i]
        }
    }
    var count = 0
    var first = "none"
    for frame in 0..<frames {
        for channel in 0..<2 where output[channel][frame] != expected[frame] {
            if count == 0 {
                first = "frame \(frame) ch \(channel): got \(output[channel][frame]), "
                    + "want \(expected[frame])"
            }
            count += 1
        }
    }
    return (count, first)
}

private func l3NaNCount(_ channels: [[Float]]) -> Int {
    channels.reduce(0) { total, samples in
        total + samples.lazy.filter { $0.isNaN }.count
    }
}

// MARK: - Metronome-only offline rig (production scheduling code, no graph)

@MainActor
private struct MetronomeLoopRig {
    let engine: AVAudioEngine
    let metronome: Metronome

    init() throws {
        engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: l3Rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        metronome = Metronome()
        metronome.attach(to: engine)
        try engine.start()
    }

    /// Pulls `frames` total, invoking `tick(renderedSeconds)` after every
    /// third 512-frame quantum — the ~32 ms live playhead cadence that
    /// drives `Metronome.topUpLoopCycles` in `serviceLoop`.
    func render(frames: Int, into channelData: inout [[Float]],
                tick: (Double) -> Void) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        var pulls = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, l3Quantum))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
            pulls += 1
            if pulls % 3 == 0 {
                tick(Double(rendered) / l3Rate)
            }
        }
    }
}

// MARK: - Graph + metronome rig for the toggle A/B (the L-1 rig + click player)

@MainActor
private struct ToggleABRig {
    let engine: AVAudioEngine
    let graph: PlaybackGraph
    let metronome: Metronome

    init(tracks: [Track], tempoMap: TempoMap, fromBeat: Double,
         loop: PlaybackGraph.LoopWindow) throws {
        engine = AVAudioEngine()
        graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: l3Rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        metronome = Metronome()
        // Attached in EVERY run (the production shape: the player joins the
        // graph once, whether or not it clicks) so all runs share one
        // topology and byte comparisons are honest.
        metronome.attach(to: engine)
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap, loop: loop)
        graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
    }

    /// Pulls `frames` total, pausing EXACTLY at each event frame to run its
    /// action between pulls (the offline model of a main-actor toggle between
    /// render quanta), and ticking the graph + metronome top-ups every third
    /// pull. All runs of one A/B use the SAME event frames (no-op actions on
    /// the references) so the pull pattern is identical across runs.
    func render(frames: Int, events: [(frame: Int, action: () -> Void)],
                metronomeElapsedOffset: () -> Double,
                into channelData: inout [[Float]]) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        var pulls = 0
        var pending = events.sorted { $0.frame < $1.frame }
        while rendered < frames {
            while let next = pending.first, next.frame == rendered {
                next.action()
                pending.removeFirst()
            }
            var request = min(frames - rendered, l3Quantum)
            if let next = pending.first {
                request = min(request, next.frame - rendered)
            }
            let status = try engine.renderOffline(AVAudioFrameCount(request), to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
            pulls += 1
            if pulls % 3 == 0 {
                let elapsed = Double(rendered) / l3Rate
                graph.topUpLoopCycles(elapsedPlayerSeconds: elapsed,
                                      horizonSeconds: 0.2)
                metronome.topUpLoopCycles(
                    elapsedPlayerSeconds: elapsed - metronomeElapsedOffset(),
                    horizonSeconds: 0.2)
            }
        }
    }
}

/// Writes a stereo Float32 .caf carrying `value(frame)` on both channels.
@MainActor
private func l3WriteRampFile(contentFrames: Int, name: String,
                             value: @escaping (Int) -> Float) throws -> URL {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: l3Rate, channels: 2))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format,
                         frameCapacity: AVAudioFrameCount(contentFrames)))
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<contentFrames {
        for channel in 0..<2 {
            channels[channel][frame] = value(frame)
        }
    }
    buffer.frameLength = AVAudioFrameCount(contentFrames)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("m14c-\(name)-\(UUID().uuidString).caf")
    try autoreleasepool {
        let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }
    return url
}

// MARK: - The gates

@MainActor
@Suite("Gapless loop metronome (m14-c L-3)", .serialized)
struct GaplessLoopMetronomeTests {
    /// Click-placement exactness under a multi-segment map. Map 120 → 96 @
    /// beat 4 → 150 @ beat 8; loop [2, 6) spans the 96 boundary; the 150
    /// segment sits PAST the loop end and must never leak into click timing
    /// (the timeline law). Clicks per cycle at beats 2/3/4/5; beat 4 is the
    /// 4/4 barline (downbeat buffer). Every click of cycles 0…3 is pinned by
    /// byte-exact whole-render reconstruction — placement (== the absolute
    /// integral), buffer choice, and between-click silence in one assertion.
    /// The boundary click (beat 2 at frame k·108000) fires EVERY cycle: the
    /// L-1 interim's skip class is dead.
    @Test("click placement: multi-segment map, loop over a tempo boundary — every click == the absolute integral, boundary click every cycle")
    func clickCyclePlacementExactness() throws {
        let spb120 = 60.0 / 120.0   // 0.5   — exactly representable
        let spb96 = 60.0 / 96.0     // 0.625 — exactly representable
        let cycleSec = 2 * spb120 + 2 * spb96   // loop [2,6): 2.25 s exact
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 4, bpm: 96),
            TempoMap.Segment(startBeat: 8, bpm: 150),
        ])
        let meter = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))

        let rig = try MetronomeLoopRig()
        rig.metronome.scheduleLoopClicks(
            fromBeat: 2, loopStartBeat: 2, loopEndBeat: 6,
            tempoMap: map, meterMap: meter, playerStartBeat: 2)
        rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        rig.metronome.start(at: nil)

        let cycleFrames = Int((cycleSec * l3Rate).rounded())  // 108_000
        let totalFrames = 4 * cycleFrames                     // cycles 0…3
        var output: [[Float]] = [[], []]
        try rig.render(frames: totalFrames, into: &output) { renderedSeconds in
            rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: renderedSeconds,
                                          horizonSeconds: 0.2)
        }
        rig.engine.stop()

        // THE ABSOLUTE INTEGRAL, independent per-segment arithmetic: within-
        // cycle offsets 0 / 0.5 / 1.0 / 1.625 s (beat 5 sits past the tempo
        // boundary: 2·spb120 + 1·spb96 — any 150-leak would shift it).
        var clicks: [(frame: Int, downbeat: Bool)] = []
        var boundaryClickFrames: [Int] = []
        for k in 0...3 {
            let cycleStart = Double(k) * cycleSec
            clicks.append((Int(((cycleStart) * l3Rate).rounded()), false))          // beat 2
            clicks.append((Int(((cycleStart + spb120) * l3Rate).rounded()), false)) // beat 3
            clicks.append((Int(((cycleStart + 2 * spb120) * l3Rate).rounded()), true)) // beat 4
            clicks.append((Int(((cycleStart + 2 * spb120 + spb96) * l3Rate).rounded()), false)) // beat 5
            if k > 0 { boundaryClickFrames.append(k * cycleFrames) }
        }
        #expect(boundaryClickFrames == [108_000, 216_000, 324_000])
        // The boundary click frame IS the wrap frame — present every cycle.
        for frame in boundaryClickFrames {
            #expect(clicks.contains { $0.frame == frame })
            #expect(output[0][frame + 1] != 0)  // audible right at the seam
        }

        let mismatch = l3ReconstructionMismatches(
            output, frames: totalFrames, clicks: clicks, buffers: try l3ClickBuffers())
        print("[measured] L-3 placement: \(clicks.count) clicks pinned "
              + "(cycle \(cycleFrames) frames), reconstruction mismatches \(mismatch.count) "
              + "(first \(mismatch.first)); boundary clicks \(boundaryClickFrames); "
              + "scheduledThroughCycle \(rig.metronome.loopScheduledThroughCycle ?? -1); "
              + "NaNs \(l3NaNCount(output))")
        #expect(mismatch.count == 0)
        #expect((rig.metronome.loopScheduledThroughCycle ?? -1) >= 3)
        #expect(l3NaNCount(output) == 0)
    }

    /// Short-loop torture (the C6 law on the click player): 0.25-beat loop at
    /// the 400 BPM cap = 1 800-frame cycles, one click per cycle (beat 0, the
    /// 4/4 downbeat), topped up at the LAW's minimum horizon. 25 cycles must
    /// each click at exactly k·1800 — byte-exact whole-render reconstruction,
    /// so a single starved/skipped/jittered cycle fails. This is the L-1
    /// interim's "<~100 ms loops jitter-class" retired.
    @Test("short-loop torture: 0.25-beat loop at 400 BPM clicks every cycle for 25 cycles")
    func shortLoopClickTorture() throws {
        let cycleSec = 0.25 * (60.0 / 400.0)                 // 0.0375 s
        let cycleFrames = Int((cycleSec * l3Rate).rounded()) // 1_800
        let lawMinimum = 2 * 0.033
        let map = TempoMap(constantBPM: 400)
        let meter = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))

        let rig = try MetronomeLoopRig()
        rig.metronome.scheduleLoopClicks(
            fromBeat: 0, loopStartBeat: 0, loopEndBeat: 0.25,
            tempoMap: map, meterMap: meter, playerStartBeat: 0)
        rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0,
                                      horizonSeconds: lawMinimum)
        rig.metronome.start(at: nil)

        let cycles = 25
        var output: [[Float]] = [[], []]
        try rig.render(frames: cycles * cycleFrames, into: &output) { renderedSeconds in
            rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: renderedSeconds,
                                          horizonSeconds: lawMinimum)
        }
        rig.engine.stop()

        // Every cycle's click at the absolute integral k·cycleSec — beat 0 is
        // the barline, so every click is the downbeat buffer.
        let clicks: [(frame: Int, downbeat: Bool)] = (0..<cycles).map {
            (Int((Double($0) * cycleSec * l3Rate).rounded()), true)
        }
        #expect(clicks.map(\.frame) == (0..<cycles).map { $0 * 1_800 })
        let mismatch = l3ReconstructionMismatches(
            output, frames: cycles * cycleFrames, clicks: clicks,
            buffers: try l3ClickBuffers())
        var presentCycles = 0
        for k in 0..<cycles where output[0][k * cycleFrames + 1] != 0 {
            presentCycles += 1
        }
        print("[measured] L-3 torture: \(cycles) cycles × \(cycleFrames) frames, "
              + "clicks present \(presentCycles)/\(cycles), reconstruction mismatches "
              + "\(mismatch.count) (first \(mismatch.first)); scheduledThroughCycle "
              + "\(rig.metronome.loopScheduledThroughCycle ?? -1); NaNs \(l3NaNCount(output))")
        #expect(presentCycles == cycles)
        #expect(mismatch.count == 0)
        #expect((rig.metronome.loopScheduledThroughCycle ?? -1) >= cycles)
        #expect(l3NaNCount(output) == 0)
    }

    /// Meter-aware unroll: a mid-loop meter change (4/4 from beat 0, 3/4 from
    /// beat 4) under loop [0, 7) puts downbeats at beats 0 and 4 and regular
    /// clicks at 1/2/3/5/6 — in EVERY cycle, because downbeat selection uses
    /// absolute transport beats. Byte-exact reconstruction over 3 cycles pins
    /// the pattern across both seams (a meter-blind unroll that restarted the
    /// bar count at the wrap would flip beat 4's buffer and fail).
    @Test("meter-aware unroll: mid-loop meter change keeps every cycle's downbeat pattern identical to the head pass")
    func meterAwareUnrollAcrossSeams() throws {
        let map = TempoMap(constantBPM: 120)
        let meter = try MeterMap(changes: [
            MeterMap.Change(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            MeterMap.Change(startBeat: 4, beatsPerBar: 3, beatUnit: 4),
        ])
        let rig = try MetronomeLoopRig()
        rig.metronome.scheduleLoopClicks(
            fromBeat: 0, loopStartBeat: 0, loopEndBeat: 7,
            tempoMap: map, meterMap: meter, playerStartBeat: 0)
        rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        rig.metronome.start(at: nil)

        let cycleFrames = Int((7 * 0.5 * l3Rate).rounded())  // 168_000
        let totalFrames = 3 * cycleFrames
        var output: [[Float]] = [[], []]
        try rig.render(frames: totalFrames, into: &output) { renderedSeconds in
            rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: renderedSeconds,
                                          horizonSeconds: 0.2)
        }
        rig.engine.stop()

        var clicks: [(frame: Int, downbeat: Bool)] = []
        for k in 0..<3 {
            for beat in 0..<7 {
                clicks.append((k * cycleFrames + beat * 24_000,
                               beat == 0 || beat == 4))
            }
        }
        let mismatch = l3ReconstructionMismatches(
            output, frames: totalFrames, clicks: clicks, buffers: try l3ClickBuffers())
        print("[measured] L-3 meter unroll: \(clicks.count) clicks (downbeats at "
              + "beats 0+4 every cycle), reconstruction mismatches \(mismatch.count) "
              + "(first \(mismatch.first)); NaNs \(l3NaNCount(output))")
        #expect(mismatch.count == 0)
        #expect(l3NaNCount(output) == 0)
    }

    /// THE HEADLINE GATE (design §9 L-3): toggling the metronome mid-play
    /// leaves clip output byte-identical. Run A starts with the click ON,
    /// toggles OFF at frame 132000, back ON at 228000 (re-anchored on the
    /// modular grid: beat 1.5 of cycle 2, the production `metronomeChanged`
    /// call sequence), OFF again at 396000. Run B never enables the click;
    /// run C never toggles. Every frame of A is pinned byte-identical to the
    /// matching never-toggled reference — B where the click is commanded off,
    /// C where it is commanded on — and every A-vs-B difference falls inside
    /// an expected click window: clicks step on/off exactly on the commanded
    /// grid, queued-but-cancelled clicks (144000/168000 after the first
    /// disable, 408000+ after the second) never sound.
    @Test("toggle byte-identity A/B: clip output byte-identical through OFF/ON/OFF; clicks step on the commanded grid")
    func toggleByteIdentityAB() throws {
        let cycleFrames = 96_000  // loop [0,4) at 120 BPM
        let ramp: (Int) -> Float = { 0.25 + Float($0) * 1e-6 }
        let url = try l3WriteRampFile(contentFrames: cycleFrames, name: "ab", value: ramp)
        defer { try? FileManager.default.removeItem(at: url) }
        let tracks = [
            Track(name: "Clip", kind: .audio, clips: [
                Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url),
            ]),
        ]
        let map = TempoMap(constantBPM: 120)
        let meter = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))
        let loop = PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 4)
        let totalFrames = 5 * cycleFrames
        let t1 = 132_000, t2 = 228_000, t3 = 396_000

        // The enable-at-t2 re-anchor, exact arithmetic: frame 228000 = cycle 2
        // + 36000 frames = beat 1.5 (the modular position `derivedBeats`
        // would hand `metronomeChanged`).
        let anchorBeat = 1.5

        func run(toggles: Bool, clickOnFromStart: Bool) throws -> [[Float]] {
            let rig = try ToggleABRig(tracks: tracks, tempoMap: map,
                                      fromBeat: 0, loop: loop)
            var elapsedOffset = 0.0
            if clickOnFromStart {
                // The production startMetronome loop branch.
                rig.metronome.scheduleLoopClicks(
                    fromBeat: 0, loopStartBeat: 0, loopEndBeat: 4,
                    tempoMap: map, meterMap: meter, playerStartBeat: 0)
                rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0,
                                              horizonSeconds: 0.2)
                rig.metronome.start(at: nil)
            }
            let events: [(frame: Int, action: () -> Void)] = [
                (t1, { if toggles { rig.metronome.stop() } }),
                (t2, {
                    guard toggles else { return }
                    // The production metronomeChanged ENABLE sequence under a
                    // loop: stop → scheduleLoopClicks from the modular beat →
                    // initial cycle coverage → start (player time 0 ≡ the
                    // next rendered sample here; live uses now + lead).
                    rig.metronome.stop()
                    rig.metronome.scheduleLoopClicks(
                        fromBeat: anchorBeat, loopStartBeat: 0, loopEndBeat: 4,
                        tempoMap: map, meterMap: meter, playerStartBeat: anchorBeat)
                    rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0,
                                                  horizonSeconds: 0.2)
                    rig.metronome.start(at: nil)
                    elapsedOffset = Double(t2) / l3Rate
                }),
                (t3, { if toggles { rig.metronome.stop() } }),
            ]
            var output: [[Float]] = [[], []]
            try rig.render(frames: totalFrames, events: events,
                           metronomeElapsedOffset: { elapsedOffset },
                           into: &output)
            rig.engine.stop()
            return output
        }

        let a = try run(toggles: true, clickOnFromStart: true)    // the toggled run
        let b = try run(toggles: false, clickOnFromStart: false)  // never enabled
        let c = try run(toggles: false, clickOnFromStart: true)   // never toggled

        func sha(_ output: [[Float]], _ range: Range<Int>) -> String {
            var hasher = SHA256()
            for channel in output {
                channel[range].withUnsafeBufferPointer { samples in
                    hasher.update(data: Data(buffer: samples))
                }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
                .prefix(16).description
        }
        func mismatches(_ x: [[Float]], _ y: [[Float]], _ range: Range<Int>) -> Int {
            var count = 0
            for frame in range {
                for channel in 0..<2 where x[channel][frame] != y[channel][frame] {
                    count += 1
                }
            }
            return count
        }

        // Full-timeline coverage against never-toggled references.
        let onVsC1 = mismatches(a, c, 0..<t1)
        let offVsB1 = mismatches(a, b, t1..<t2)
        let onVsC2 = mismatches(a, c, t2..<t3)
        let offVsB2 = mismatches(a, b, t3..<totalFrames)
        print("[measured] L-3 A/B: ON[0,\(t1)) vs C \(onVsC1) mismatches "
              + "(sha A \(sha(a, 0..<t1)) == C \(sha(c, 0..<t1))); "
              + "OFF[\(t1),\(t2)) vs B \(offVsB1) (sha A \(sha(a, t1..<t2)) "
              + "== B \(sha(b, t1..<t2))); ON[\(t2),\(t3)) vs C \(onVsC2) "
              + "(sha A \(sha(a, t2..<t3)) == C \(sha(c, t2..<t3))); "
              + "OFF[\(t3),\(totalFrames)) vs B \(offVsB2) "
              + "(sha A \(sha(a, t3..<totalFrames)) == B \(sha(b, t3..<totalFrames)))")
        #expect(onVsC1 == 0)
        #expect(offVsB1 == 0)
        #expect(onVsC2 == 0)
        #expect(offVsB2 == 0)
        #expect(sha(a, t1..<t2) == sha(b, t1..<t2))
        #expect(sha(a, t3..<totalFrames) == sha(b, t3..<totalFrames))

        // Converse: A-vs-B differences (the click content itself) fall ONLY
        // inside expected sounding click windows, and EVERY commanded click
        // sounds. Cycle 0: beats 0–3; cycle 1: only 96000/120000 precede the
        // disable (144000/168000 were queued and must die with it); re-enable:
        // 240000/264000 (head from beat 1.5), full cycles at 288000+ and the
        // 384000 boundary click before the final disable.
        let soundingClicks = [0, 24_000, 48_000, 72_000, 96_000, 120_000,
                              240_000, 264_000,
                              288_000, 312_000, 336_000, 360_000, 384_000]
        var diffOutsideWindows = 0
        var firstOutside = "none"
        var windowsHit = Set<Int>()
        for frame in 0..<totalFrames where a[0][frame] != b[0][frame]
            || a[1][frame] != b[1][frame] {
            if let click = soundingClicks.last(where: {
                $0 <= frame && frame < $0 + clickFrames
            }) {
                windowsHit.insert(click)
            } else {
                if diffOutsideWindows == 0 { firstOutside = "frame \(frame)" }
                diffOutsideWindows += 1
            }
        }
        // First re-enabled click steps in exactly on the commanded grid:
        // frame 240000 carries the click buffer's silent first sample, so the
        // first audible difference is 240001.
        var firstDiffAfterT2 = -1
        for frame in t2..<totalFrames where a[0][frame] != b[0][frame] {
            firstDiffAfterT2 = frame
            break
        }
        print("[measured] L-3 A/B converse: diffs outside click windows "
              + "\(diffOutsideWindows) (first \(firstOutside)); sounding windows hit "
              + "\(windowsHit.count)/\(soundingClicks.count); first diff after "
              + "re-enable \(firstDiffAfterT2) (expected \(240_001)); "
              + "NaNs A \(l3NaNCount(a)) B \(l3NaNCount(b)) C \(l3NaNCount(c))")
        #expect(diffOutsideWindows == 0)
        #expect(windowsHit == Set(soundingClicks))
        #expect(firstDiffAfterT2 == 240_001)
        #expect(l3NaNCount(a) == 0)
        #expect(l3NaNCount(b) == 0)
        #expect(l3NaNCount(c) == 0)
    }

    /// C8 — null cases: the L-3 machinery is provably invisible to
    /// non-looping renders, metronome OFF and ON alike (the ON case rides the
    /// LINEAR `scheduleClicks` path, refactored into `enqueueClicks` with
    /// arithmetic bit-identical by `0 + x == x`). Deterministic SHAs printed
    /// for the cross-era comparison — the m14-c gate ran this exact fixture
    /// on the pre-change tree: OFF a3927faf04f52758…, ON 692e713d009f0ffa….
    @Test("C8: non-looping renders (metronome OFF and ON) are deterministic — SHAs printed for the era gate")
    func c8NullCaseRenders() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: l3Rate, channels: 2))
        let frames = 96_000
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let sample = 0.25 + Float(frame) * 1e-6
            channels[0][frame] = sample
            channels[1][frame] = -sample
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14c-era-\(UUID().uuidString).caf")
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let tracks = [
            Track(name: "Faded", kind: .audio, clips: [
                Clip(name: "f", startBeat: 0, lengthBeats: 3, audioFileURL: url,
                     fadeInBeats: 0.5, fadeOutBeats: 0.5, fadeOutCurve: .equalPower),
            ]),
            Track(name: "Shaped", kind: .audio, clips: [
                Clip(name: "e", startBeat: 1, lengthBeats: 2, audioFileURL: url,
                     gainEnvelope: [ClipGainPoint(beat: 0.5, gainDb: -6),
                                    ClipGainPoint(beat: 1.5, gainDb: -2)]),
            ]),
            Track(name: "Keys", kind: .instrument, clips: [
                Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
                    MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
                    MIDINote(pitch: 67, velocity: 90, startBeat: 1.5, lengthBeats: 0.75),
                ]),
            ]),
        ]
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 4, bpm: 90),
        ])

        func sha(_ audio: RenderedAudio) -> String {
            var hasher = SHA256()
            for channel in audio.channelData {
                channel.withUnsafeBufferPointer { samples in
                    hasher.update(data: Data(buffer: samples))
                }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        let off = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0)
        let off2 = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0)
        // m15-a call-shape only (`beatsPerBar: 3` → the equivalent constant
        // map) — the rendered bytes are pinned unchanged by the era SHAs.
        let meter34 = MeterMap(constant: TimeSignature(beatsPerBar: 3, beatUnit: 4))
        let on = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0,
            metronomeEnabled: true, meterMap: meter34)
        let on2 = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0,
            metronomeEnabled: true, meterMap: meter34)
        print("[era] m14c null OFF SHA \(sha(off)) (repeat \(sha(off2)))")
        print("[era] m14c null ON  SHA \(sha(on)) (repeat \(sha(on2)))")
        #expect(sha(off) == sha(off2))
        #expect(sha(on) == sha(on2))
        #expect(sha(off) != sha(on))  // the ON render really carries clicks
    }

    /// Live smoke (liveSmoke guard idiom — headless machines return early):
    /// a mid-play metronome toggle through the REAL `metronomeChanged` intent
    /// leaves the transport rolling — the playhead keeps wrapping modularly
    /// and the graph's unroll NEVER rebuilds (`loopScheduledThroughCycle` is
    /// non-decreasing across both toggles; the retired seek fallback would
    /// reset it through stopAllPlayers).
    @Test("live smoke: metronomeChanged mid-play never restarts the transport")
    func liveToggleSmoke() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return  // headless machine without an output device
        }

        var pushes: [Double] = []
        engine.playheadHandler = { pushes.append($0) }

        var transport = TransportState()
        transport.isPlaying = true
        transport.isLoopEnabled = true
        transport.loopStartBeat = 0
        transport.loopEndBeat = 1   // 0.5 s per cycle at 120 BPM
        transport.isMetronomeEnabled = true
        engine.startPlayback(transport)
        try await Task.sleep(for: .milliseconds(600))
        let cyclesBeforeToggle = engine.graph.loopScheduledThroughCycle ?? -1

        transport.isMetronomeEnabled = false
        engine.metronomeChanged(transport)   // disable mid-play
        try await Task.sleep(for: .milliseconds(400))
        let cyclesAfterDisable = engine.graph.loopScheduledThroughCycle ?? -1

        transport.isMetronomeEnabled = true
        engine.metronomeChanged(transport)   // re-enable mid-play
        try await Task.sleep(for: .milliseconds(400))
        let cyclesAfterEnable = engine.graph.loopScheduledThroughCycle ?? -1
        let clickCycles = engine.metronomeLoopScheduledThroughCycle

        engine.stopPlayback()
        engine.shutdown()

        let maxPush = pushes.max() ?? 0
        print("[measured] L-3 live toggle smoke: \(pushes.count) pushes, max \(maxPush) "
              + "(loop end 1.0); graph cycles \(cyclesBeforeToggle) → \(cyclesAfterDisable) "
              + "→ \(cyclesAfterEnable) (non-decreasing = no restart); "
              + "click cycles after re-enable \(clickCycles ?? -1)")
        #expect(!pushes.isEmpty)
        #expect(maxPush <= 1.0)  // modular playhead held through both toggles
        #expect(cyclesBeforeToggle >= 1)
        #expect(cyclesAfterDisable >= cyclesBeforeToggle)
        #expect(cyclesAfterEnable >= cyclesAfterDisable)
        // The re-enabled click run is unrolling on its own player.
        #expect((clickCycles ?? -1) >= 0)
    }
}
