import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m14-a (L-1) gates — gapless loop wrap: transport core
// (docs/research/design-m13f-gapless-loop.md §9 L-1, §10 conditions):
//
//  · C3 — cycle-placement exactness: under a MULTI-SEGMENT tempo map with the
//    loop spanning a tempo boundary, ≥ 3 unrolled cycles pin EVERY audio
//    anchor frame == the absolute integral computed from the schedule start,
//    with exact == (the m12-c discipline). The expected values are computed
//    in-test with explicit per-segment arithmetic on exactly-representable
//    seconds-per-beat values, independent of TempoMap's own accumulation.
//  · C6 — horizon law: a 0.25-beat loop at the 400 BPM cap sustains ≥ 20
//    cycles with no starvation gap when topped up at the LAW's minimum
//    (2 playhead-tick periods of schedule-ahead), asserted as continuous
//    bit-exact scheduled coverage; the production constant is pinned ≥ law.
//
// MEASURED L-1 AMENDMENT (LoopPrimitiveProbe, 2026-07-12): the top-up ALSO
// enforces an eager ≥ 2-cycles-beyond-the-sounding-cycle invariant, because
// (a) a strip player whose queue fully drains freezes — later-queued anchors
// never sound at ANY lead, and (b) mid-flight enqueue needs ≥ ~2.5k frames of
// anchor lead for a bit-exact splice. Both facts live in the
// `topUpLoopCycles` doc; the C3/wrap/baked gates below fail without the
// eager rule (measured: silent unrolled cycles / partial-quantum seam drops).
//  · WRAP-DOES-NOT-RESTART: splice continuity of a deterministic signal
//    across ≥ 2 wraps — zero dropped / zero-run frames at every seam (the
//    old behavior's measured seam is 2880 frames of silence + 1680 frames of
//    overshoot, pinned forever by GaplessLoopSpikeTests' negative control).
//    Includes the loop-window truncation proof: file content past the loop
//    end (sentinel band) NEVER sounds.
//  · Baked-piece cycle reuse: fade and envelope pieces bake once and
//    re-enqueue every cycle — unrolled cycles render bit-identical to the
//    head cycle.
//
// All offline: manual-rendering AVAudioEngine + the REAL PlaybackGraph loop
// machinery (reconcile → scheduleAll(loop:) → topUpLoopCycles), the L-0 spike
// idiom promoted onto production code paths. One live smoke rides the
// PlaybackRenderTests liveSmoke guard (headless machines return early).

private let loopRate = 48_000.0
private let loopQuantum = 512

// MARK: - Analytic signals (unique value per frame at Float precision)

private func rampA(_ frame: Int) -> Float { 0.25 + Float(frame) * 1e-6 }
private func rampB(_ frame: Int) -> Float { -0.5 - Float(frame) * 1e-6 }
private let sentinelBase: Float = 0.9

/// Writes a stereo Float32 .caf whose first `contentFrames` carry
/// `value(frame)` on both channels and whose remaining `sentinelFrames` carry
/// the sentinel band (content that must NEVER sound under a loop window).
@MainActor
private func writeRampFile(
    contentFrames: Int, sentinelFrames: Int = 0, name: String,
    value: @escaping (Int) -> Float
) throws -> URL {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: loopRate, channels: 2))
    let total = contentFrames + sentinelFrames
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<total {
        let sample = frame < contentFrames
            ? value(frame)
            : sentinelBase + Float(frame - contentFrames) * 1e-6
        for channel in 0..<2 {
            channels[channel][frame] = sample
        }
    }
    buffer.frameLength = AVAudioFrameCount(total)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("m14a-\(name)-\(UUID().uuidString).caf")
    // AVAudioFile flushes its header on deinit — writer dies before readers open.
    try autoreleasepool {
        let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }
    return url
}

/// Frames in `range` (both channels) not bit-equal to `value(frame - range
/// .lowerBound)`.
private func loopMismatches(_ channels: [[Float]], range: Range<Int>,
                            against value: (Int) -> Float) -> (count: Int, first: String) {
    var count = 0
    var first = "none"
    for frame in range {
        let expected = value(frame - range.lowerBound)
        for channel in 0..<2 where channels[channel][frame] != expected {
            if count == 0 {
                first = "frame \(frame) ch \(channel): "
                    + "got \(channels[channel][frame]), want \(expected)"
            }
            count += 1
        }
    }
    return (count, first)
}

private func loopNaNCount(_ channels: [[Float]]) -> Int {
    channels.reduce(0) { total, samples in
        total + samples.lazy.filter { $0.isNaN }.count
    }
}

// MARK: - Offline rig driving the REAL graph loop machinery

@MainActor
private struct LoopGraphRig {
    let engine: AVAudioEngine
    let graph: PlaybackGraph

    init(tracks: [Track], tempoMap: TempoMap, fromBeat: Double,
         loop: PlaybackGraph.LoopWindow, initialHorizonSeconds: Double) throws {
        engine = AVAudioEngine()
        graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: loopRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap, loop: loop)
        // The engine's start-time horizon call (AudioEngine.startPlayers).
        graph.topUpLoopCycles(elapsedPlayerSeconds: 0,
                              horizonSeconds: initialHorizonSeconds)
        graph.startAllPlayers(at: nil)
    }

    /// Pulls `frames` total, invoking `tick(renderedSeconds)` after every
    /// third 512-frame quantum — the ~32 ms cadence of the live playhead
    /// task, driving `topUpLoopCycles` mid-render exactly as `serviceLoop`
    /// does (the L-0 queue-while-playing shape).
    func render(frames: Int, into channelData: inout [[Float]],
                tick: (Double) -> Void) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        var pulls = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, loopQuantum))
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
                tick(Double(rendered) / loopRate)
            }
        }
    }
}

// MARK: - The gates

@MainActor
@Suite("Gapless loop transport (m14-a L-1)", .serialized)
struct GaplessLoopTransportTests {
    /// C3 — cycle-placement exactness. Map 120 → 96 @ beat 4 → 150 @ beat 8;
    /// loop [2, 6) spans the 96 boundary; the 150 segment sits PAST the loop
    /// end and must never leak into cycle timing (the timeline law — any leak
    /// shifts an anchor and fails an == below). Two clips:
    ///  · A at beat 3, 2 beats long (crosses the tempo boundary mid-clip),
    ///  · B at beat 1.5, 1 beat long (begins BEFORE the loop start → enters
    ///    every cycle mid-file at its loop-start read position).
    /// Every onset of every cycle 0...3 is pinned == the absolute integral
    /// computed from the schedule start with independent exact arithmetic.
    @Test("C3: multi-segment map, loop over a tempo boundary — every cycle anchor == the absolute integral")
    func cyclePlacementExactness() throws {
        let spb120 = 60.0 / 120.0   // 0.5   — exactly representable
        let spb96 = 60.0 / 96.0     // 0.625 — exactly representable
        let cycleSec = 2 * spb120 + 2 * spb96   // loop [2,6): 2.25 s exact
        let aLenFrames = Int(((1 * spb120 + 1 * spb96) * loopRate).rounded()) // 54_000
        let bWindowFrames = Int((0.5 * spb120 * loopRate).rounded())          // 12_000
        let bFileOffset = Int((0.5 * spb120 * loopRate).rounded())            // 12_000
        let aOffsetSec = 1 * spb120   // beat 2 → 3 inside the cycle

        let aURL = try writeRampFile(contentFrames: aLenFrames, name: "c3a", value: rampA)
        let bURL = try writeRampFile(contentFrames: 24_000, name: "c3b", value: rampB)
        defer {
            try? FileManager.default.removeItem(at: aURL)
            try? FileManager.default.removeItem(at: bURL)
        }
        let tracks = [
            Track(name: "A", kind: .audio, clips: [
                Clip(name: "a", startBeat: 3, lengthBeats: 2, audioFileURL: aURL),
            ]),
            Track(name: "B", kind: .audio, clips: [
                Clip(name: "b", startBeat: 1.5, lengthBeats: 1, audioFileURL: bURL),
            ]),
        ]
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 4, bpm: 96),
            TempoMap.Segment(startBeat: 8, bpm: 150),
        ])
        let rig = try LoopGraphRig(
            tracks: tracks, tempoMap: map, fromBeat: 2,
            loop: PlaybackGraph.LoopWindow(startBeat: 2, endBeat: 6),
            initialHorizonSeconds: 0.2)

        let cycleFrames = Int((cycleSec * loopRate).rounded())  // 108_000
        let totalFrames = 4 * cycleFrames                       // cycles 0…3
        var output: [[Float]] = [[], []]
        try rig.render(frames: totalFrames, into: &output) { renderedSeconds in
            rig.graph.topUpLoopCycles(elapsedPlayerSeconds: renderedSeconds,
                                      horizonSeconds: 0.2)
        }
        rig.engine.stop()

        var totalMismatches = 0
        var pinnedAnchors: [Int] = []
        for k in 0...3 {
            // THE ABSOLUTE INTEGRAL from the schedule start, independent
            // arithmetic: cycle start = k · cycleSec, never previous + frames.
            let cycleStart = Int((Double(k) * cycleSec * loopRate).rounded())
            let bAnchor = cycleStart
            let aAnchor = Int(((Double(k) * cycleSec + aOffsetSec) * loopRate).rounded())
            pinnedAnchors.append(contentsOf: [bAnchor, aAnchor])

            // B: mid-file entry at its loop-start read position, exact onset.
            #expect(output[0][bAnchor] == rampB(bFileOffset))
            let b = loopMismatches(output, range: bAnchor..<bAnchor + bWindowFrames) {
                rampB(bFileOffset + $0)
            }
            // Silence between B's clip end and A's onset, then A bit-exact.
            let gap = loopMismatches(
                output, range: bAnchor + bWindowFrames..<aAnchor) { _ in 0 }
            #expect(output[0][aAnchor] == rampA(0))
            let a = loopMismatches(output, range: aAnchor..<aAnchor + aLenFrames, against: rampA)
            // Silence from A's end to the cycle boundary.
            let tail = loopMismatches(
                output, range: aAnchor + aLenFrames..<cycleStart + cycleFrames) { _ in 0 }
            totalMismatches += b.count + gap.count + a.count + tail.count
            if b.count + gap.count + a.count + tail.count > 0 {
                print("[measured] C3 cycle \(k): B \(b.count) (\(b.first)); gap \(gap.count) "
                      + "(\(gap.first)); A \(a.count) (\(a.first)); tail \(tail.count) (\(tail.first))")
            }
        }
        print("[measured] C3: anchors pinned == \(pinnedAnchors) "
              + "(cycle \(cycleFrames) frames, 3 unrolled cycles + head), "
              + "total mismatches \(totalMismatches), "
              + "scheduledThroughCycle \(rig.graph.loopScheduledThroughCycle ?? -1), "
              + "NaNs \(loopNaNCount(output))")
        #expect(totalMismatches == 0)
        #expect((rig.graph.loopScheduledThroughCycle ?? -1) >= 3)
        #expect(loopNaNCount(output) == 0)
    }

    /// C6 — horizon law: minLoopLengthBeats (0.25) at the 400 BPM tempo cap
    /// = 37.5 ms per cycle (1800 frames), shorter than the 33 ms playhead
    /// tick. Topped up at the LAW's minimum (coverage = elapsed + 2 tick
    /// periods — deliberately NOT the production 200 ms, so the law itself is
    /// what's pinned) on the live tick cadence, ≥ 25 cycles must render with
    /// CONTINUOUS coverage — every frame bit-exact, no starvation gap. The
    /// production constant is pinned ≥ the law by `horizonConstantHoldsTheLaw`.
    @Test("C6: 0.25-beat loop at 400 BPM sustains 25 cycles with no starvation gap")
    func shortLoopHorizonLaw() throws {
        let cycleFrames = Int((0.25 * (60.0 / 400.0) * loopRate).rounded())  // 1_800
        let url = try writeRampFile(contentFrames: cycleFrames, name: "c6", value: rampA)
        defer { try? FileManager.default.removeItem(at: url) }
        let tracks = [
            Track(name: "S", kind: .audio, clips: [
                Clip(name: "s", startBeat: 0, lengthBeats: 0.25, audioFileURL: url),
            ]),
        ]
        let lawMinimum = 2 * 0.033
        let rig = try LoopGraphRig(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 400), fromBeat: 0,
            loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 0.25),
            initialHorizonSeconds: lawMinimum)

        let cycles = 25
        var output: [[Float]] = [[], []]
        try rig.render(frames: cycles * cycleFrames, into: &output) { renderedSeconds in
            rig.graph.topUpLoopCycles(elapsedPlayerSeconds: renderedSeconds,
                                      horizonSeconds: lawMinimum)
        }
        rig.engine.stop()

        let mismatch = loopMismatches(output, range: 0..<cycles * cycleFrames) {
            rampA($0 % cycleFrames)
        }
        var zeroRuns = 0
        for frame in 0..<cycles * cycleFrames where output[0][frame] == 0 {
            zeroRuns += 1
        }
        print("[measured] C6: \(cycles) cycles × \(cycleFrames) frames, "
              + "mismatches \(mismatch.count) (first \(mismatch.first)); zero frames \(zeroRuns); "
              + "scheduledThroughCycle \(rig.graph.loopScheduledThroughCycle ?? -1); "
              + "NaNs \(loopNaNCount(output))")
        #expect(mismatch.count == 0)
        #expect(zeroRuns == 0)
        #expect((rig.graph.loopScheduledThroughCycle ?? -1) >= cycles)
        #expect(loopNaNCount(output) == 0)
    }

    /// The production schedule-ahead constant must satisfy the C6 law
    /// (≥ 2 playhead-tick periods of the 33 ms playhead task).
    @Test("C6: the production loop horizon holds the ≥ 2-tick law")
    func horizonConstantHoldsTheLaw() {
        #expect(AudioEngine.loopHorizonSeconds >= 2 * 0.033)
    }

    /// WRAP-DOES-NOT-RESTART: a clip LONGER than the loop (5 beats against a
    /// 4-beat window, with a sentinel band past the window) splices across
    /// two wraps with zero dropped/duplicated/zero frames at either seam —
    /// the old restart wrap's measured shape (1680 frames of overshoot, then
    /// 2880 frames of silence; GaplessLoopSpikeTests negative control) is
    /// structurally impossible: content is bit-exact THROUGH both boundaries
    /// and the sentinel (post-loop-end file content) never sounds.
    @Test("wrap does not restart: bit-exact splice across 2 wraps, no zero-run, no overshoot leak")
    func wrapSpliceContinuity() throws {
        let cycleFrames = Int((4 * 0.5 * loopRate).rounded())  // loop [0,4) at 120 → 96_000
        // File: 5 beats of content; frames past the window are the sentinel.
        let url = try writeRampFile(contentFrames: cycleFrames,
                                    sentinelFrames: 24_000, name: "wrap", value: rampA)
        defer { try? FileManager.default.removeItem(at: url) }
        let tracks = [
            Track(name: "W", kind: .audio, clips: [
                Clip(name: "w", startBeat: 0, lengthBeats: 5, audioFileURL: url),
            ]),
        ]
        let rig = try LoopGraphRig(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 4),
            initialHorizonSeconds: 0.2)

        let totalFrames = 3 * cycleFrames
        var output: [[Float]] = [[], []]
        try rig.render(frames: totalFrames, into: &output) { renderedSeconds in
            rig.graph.topUpLoopCycles(elapsedPlayerSeconds: renderedSeconds,
                                      horizonSeconds: 0.2)
        }
        rig.engine.stop()

        let mismatch = loopMismatches(output, range: 0..<totalFrames) {
            rampA($0 % cycleFrames)
        }
        var zeroFrames = 0
        var sentinelLeaks = 0
        for frame in 0..<totalFrames {
            if output[0][frame] == 0 { zeroFrames += 1 }
            if output[0][frame] >= sentinelBase { sentinelLeaks += 1 }
        }
        print("[measured] wrap-no-restart: mismatches \(mismatch.count) (first \(mismatch.first)); "
              + "zero frames \(zeroFrames) (old seam: 2880/wrap); sentinel leaks \(sentinelLeaks) "
              + "(old overshoot: 1680/wrap); seam 1 \(output[0][cycleFrames - 1]) → \(output[0][cycleFrames]); "
              + "seam 2 \(output[0][2 * cycleFrames - 1]) → \(output[0][2 * cycleFrames]); "
              + "NaNs \(loopNaNCount(output))")
        #expect(mismatch.count == 0)
        #expect(zeroFrames == 0)
        #expect(sentinelLeaks == 0)
        // The two splices, stated explicitly: last frame of each cycle is the
        // window's final ramp value, the next frame is ramp(0) again.
        #expect(output[0][cycleFrames - 1] == rampA(cycleFrames - 1))
        #expect(output[0][cycleFrames] == rampA(0))
        #expect(output[0][2 * cycleFrames - 1] == rampA(cycleFrames - 1))
        #expect(output[0][2 * cycleFrames] == rampA(0))
        #expect(loopNaNCount(output) == 0)
    }

    /// Baked-buffer cache: fade pieces and envelope pieces bake ONCE at
    /// schedule time and re-enqueue every cycle (the Metronome buffer-reuse
    /// precedent) — so every unrolled cycle renders BIT-IDENTICAL to the
    /// head cycle, which the linear path scheduled with fresh bakes.
    @Test("fade + envelope cycle plans: unrolled cycles render bit-identical to the head cycle")
    func bakedPieceCycleReuse() throws {
        let cycleFrames = Int((2 * 0.5 * loopRate).rounded())  // loop [0,2) at 120 → 48_000
        let fadeURL = try writeRampFile(contentFrames: cycleFrames, name: "fade", value: rampA)
        let envURL = try writeRampFile(contentFrames: cycleFrames, name: "env", value: rampB)
        defer {
            try? FileManager.default.removeItem(at: fadeURL)
            try? FileManager.default.removeItem(at: envURL)
        }
        let tracks = [
            Track(name: "F", kind: .audio, clips: [
                Clip(name: "f", startBeat: 0, lengthBeats: 2, audioFileURL: fadeURL,
                     fadeInBeats: 0.5, fadeOutBeats: 0.5, fadeOutCurve: .equalPower),
            ]),
            Track(name: "E", kind: .audio, clips: [
                Clip(name: "e", startBeat: 0, lengthBeats: 2, audioFileURL: envURL,
                     gainEnvelope: [ClipGainPoint(beat: 0.5, gainDb: -6),
                                    ClipGainPoint(beat: 1.5, gainDb: -3)]),
            ]),
        ]
        let rig = try LoopGraphRig(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2),
            initialHorizonSeconds: 0.2)

        var output: [[Float]] = [[], []]
        try rig.render(frames: 3 * cycleFrames, into: &output) { renderedSeconds in
            rig.graph.topUpLoopCycles(elapsedPlayerSeconds: renderedSeconds,
                                      horizonSeconds: 0.2)
        }
        rig.engine.stop()

        var diffs = [0, 0]
        for k in 1...2 {
            for frame in 0..<cycleFrames {
                for channel in 0..<2
                where output[channel][k * cycleFrames + frame] != output[channel][frame] {
                    diffs[k - 1] += 1
                }
            }
        }
        var peak: Float = 0
        for frame in 0..<cycleFrames {
            peak = max(peak, abs(output[0][frame]))
        }
        print("[measured] baked-piece reuse: cycle-1 diffs \(diffs[0]), cycle-2 diffs \(diffs[1]) "
              + "vs head cycle; head-cycle peak \(peak); NaNs \(loopNaNCount(output))")
        #expect(diffs[0] == 0)
        #expect(diffs[1] == 0)
        #expect(peak > 0.1)  // the null only means something over real signal
        #expect(loopNaNCount(output) == 0)
    }

    /// Live smoke (liveSmoke guard idiom — headless machines return early):
    /// with a loop active from the start, the engine playhead wraps MODULARLY
    /// — pushes stay inside [0, loopEnd] across multiple cycles (the anchor
    /// never moves; the old behavior restarted the transport at every wrap).
    @Test("live smoke: looped playback wraps the playhead modularly, never past the loop end")
    func liveLoopedPlayheadSmoke() async throws {
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
        engine.startPlayback(transport)
        // A fixed 1.7 s observation starves under parallel suite load: the
        // tick task shares the cooperative pool with dozens of offline
        // renders, and a fully descheduled tick loop collects too few pushes
        // to catch a wrap (m15-c: measured 4 pushes/1.7 s vs 44 isolated).
        // Poll to a generous deadline instead, exiting as soon as one wrap
        // is OBSERVED — isolation still exits after the first cycle, and
        // every assertion below is unchanged.
        func observedWraps() -> Int {
            zip(pushes, pushes.dropFirst()).filter { $1 < $0 }.count
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while observedWraps() < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        engine.stopPlayback()
        engine.shutdown()

        let wraps = observedWraps()
        let maxPush = pushes.max() ?? 0
        print("[measured] live loop smoke: \(pushes.count) pushes, \(wraps) wraps, "
              + "max \(maxPush) (loop end 1.0)")
        #expect(!pushes.isEmpty)
        // Modular playhead: the anchor never moves, derivedBeats wraps inside
        // the window — a push can NEVER read past the loop end.
        #expect(maxPush <= 1.0)
        // ≥ 1 observed wrap-back. ~3 wraps are expected in 1.7 s, but a
        // starved tick task under parallel suite load can merge consecutive
        // wraps into one observed decrease — the OFFLINE gates above are the
        // wrap-continuity evidence; this smoke pins live modular wrapping.
        #expect(wraps >= 1)
    }
}
