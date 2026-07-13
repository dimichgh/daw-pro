import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m14-d (L-4) — C7, the loop-edit fallback gate
// (docs/research/design-m13f-gapless-loop.md §4-A "Fallback", §8.5, §10 C7):
// a loop-bounds edit mid-loop produces exactly ONE restart seam and NO stale
// queued segments from the old bounds.
//
// This offline gate drives the EXACT restart-primitive sequence the engine's
// `loopChanged` path performs (`restart(fromBeat: derivedBeats())` =
// stopAllPlayers → scheduleAll(fromBeat: currentModularBeat, loop: NEW window)
// → start-time topUpLoopCycles → startAllPlayers) against the real
// PlaybackGraph, mid-render, with old-bounds cycles PROVABLY queued ahead
// (the eager +2 law) at the moment of the edit. Sample-exact pins:
//
//  (a) STALE NEVER SOUNDS — post-edit output is bit-exact against the
//      NEW-bounds unroll; the first frame where the new content diverges
//      from the OLD bounds' continuation is exactly the old boundary frame
//      (the frame where a stale queued cycle would have wrapped), and the
//      value there is the new window's — the old cycle's content (a
//      distinguishable ramp band) appears nowhere after the edit.
//  (b) ONE seam — offline, the restart re-derives content from the CURRENT
//      beat, so the sample stream is value-continuous through the edit and
//      the single seam is STRUCTURAL (the cycle-pattern change at (a)); the
//      live gap class of the seam (~60 ms lead-in, exactly once, none at
//      wraps) is pinned by the C5 live-session gate over the real wire —
//      offline manual rendering has no start lead to measure.
//  (c) NEW-BOUNDS INTEGRALS — every post-edit anchor (head onset + each
//      unrolled cycle start) is pinned == the absolute integral computed
//      with independent exact arithmetic.

private let editRate = 48_000.0
private let editQuantum = 512

/// Analytic counting ramp: unique value per frame at Float precision.
private func editRamp(_ frame: Int) -> Float { 0.25 + Float(frame) * 1e-6 }

@MainActor
private func writeEditRampFile(contentFrames: Int, name: String) throws -> URL {
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: editRate, channels: 2))
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format,
                         frameCapacity: AVAudioFrameCount(contentFrames)))
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<contentFrames {
        for channel in 0..<2 {
            channels[channel][frame] = editRamp(frame)
        }
    }
    buffer.frameLength = AVAudioFrameCount(contentFrames)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("m14d-\(name)-\(UUID().uuidString).caf")
    // AVAudioFile flushes its header on deinit — writer dies before readers open.
    try autoreleasepool {
        let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }
    return url
}

@MainActor
@Suite("Gapless loop edit fallback (m14-d L-4, C7)", .serialized)
struct GaplessLoopEditFallbackTests {
    /// 240 BPM (beat = 12 000 frames, exact). One 8-beat ramp clip. Old loop
    /// [0, 2) plays ramp[0, 24 000) per cycle; the edit at 2.5 old cycles
    /// (frame 60 000, modular beat 1.0) moves the loop to [2, 4) — the
    /// restart's head plays beats [1, 4) = ramp[12 000, 48 000), then cycles
    /// play ramp[24 000, 48 000). The two windows' ramp bands are disjoint
    /// below ramp(12 000), so one stale old-window frame is detectable.
    @Test("C7: loop-bounds edit mid-loop — one restart seam, zero stale old-bounds frames, new-bounds integrals")
    func loopEditFallback() throws {
        let beatFrames = 12_000                       // 60/240 s at 48 kHz, exact
        let oldCycleFrames = 2 * beatFrames           // loop [0,2)
        let newCycleFrames = 2 * beatFrames           // loop [2,4)
        let editFrame = 60_000                        // 2.5 old cycles
        let newHeadFrames = 3 * beatFrames            // restart beat 1 → loop end 4
        let url = try writeEditRampFile(contentFrames: 8 * beatFrames, name: "c7")
        defer { try? FileManager.default.removeItem(at: url) }
        let tracks = [
            Track(name: "E", kind: .audio, clips: [
                Clip(name: "e", startBeat: 0, lengthBeats: 8, audioFileURL: url),
            ]),
        ]
        let map = TempoMap(constantBPM: 240)

        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: editRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: 0, tempoMap: map,
                          loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2))
        graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)

        var output: [[Float]] = [[], []]
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var pulls = 0
        func pull(through frames: Int) throws {
            while output[0].count < frames {
                let request = AVAudioFrameCount(min(frames - output[0].count, editQuantum))
                let status = try engine.renderOffline(request, to: buffer)
                try #require(status == .success)
                let source = try #require(buffer.floatChannelData)
                for channel in 0..<2 {
                    output[channel].append(contentsOf: UnsafeBufferPointer(
                        start: source[channel], count: Int(buffer.frameLength)))
                }
                pulls += 1
                if pulls % 3 == 0 {
                    graph.topUpLoopCycles(
                        elapsedPlayerSeconds: Double(output[0].count) / editRate,
                        horizonSeconds: 0.2)
                }
            }
        }

        // Old bounds: 2.5 cycles, bit-exact — and old cycles ARE queued past
        // the edit point (the eager +2 law), so the edit has real stale
        // segments to clear.
        try pull(through: editFrame)
        let queuedBeforeEdit = try #require(graph.loopScheduledThroughCycle)
        #expect(queuedBeforeEdit >= 3)  // cycles beyond the edit point queued
        var preMismatches = 0
        for frame in 0..<editFrame
        where output[0][frame] != editRamp(frame % oldCycleFrames) {
            preMismatches += 1
        }
        #expect(preMismatches == 0)

        // THE EDIT (the engine's loopChanged → restart sequence, verbatim
        // shape): current modular beat at frame 60 000 = 1.0; new bounds
        // [2, 4). stopAllPlayers = the flush family (queues cleared — this
        // is what kills the stale cycles); reschedule WITH the new window;
        // start-time coverage top-up; players restart (offline: player time
        // 0 ≡ the next pulled sample, so the restart lands at editFrame).
        graph.stopAllPlayers()
        graph.scheduleAll(fromBeat: 1.0, tempoMap: map,
                          loop: PlaybackGraph.LoopWindow(startBeat: 2, endBeat: 4))
        graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        graph.startAllPlayers(at: nil)

        // Post-edit: the head [beat 1, 4) then two full new-bounds cycles.
        let totalFrames = editFrame + newHeadFrames + 2 * newCycleFrames
        try pull(through: totalFrames)
        engine.stop()

        // (c) bit-exact against the NEW-bounds unroll, anchors == integrals.
        func newExpected(_ i: Int) -> Float {
            i < newHeadFrames
                ? editRamp(beatFrames + i)                                  // head: beats [1,4)
                : editRamp(2 * beatFrames + (i - newHeadFrames) % newCycleFrames)
        }
        var postMismatches = 0
        var staleFrames = 0
        var zeroFrames = 0
        let staleCeiling = editRamp(beatFrames)  // ramp band only the OLD window plays post-edit
        for i in 0..<(totalFrames - editFrame) {
            let got = output[0][editFrame + i]
            if got != newExpected(i) { postMismatches += 1 }
            if got < staleCeiling { staleFrames += 1 }   // (a) old-cycle band
            if got == 0 { zeroFrames += 1 }              // stale hole / silence
        }
        // Independent-arithmetic anchor pins: head onset at the edit frame,
        // then each unrolled cycle start at editFrame + head + k·cycle.
        #expect(output[0][editFrame] == editRamp(beatFrames))
        #expect(output[0][editFrame + newHeadFrames] == editRamp(2 * beatFrames))
        #expect(output[0][editFrame + newHeadFrames + newCycleFrames]
                == editRamp(2 * beatFrames))

        // (a)+(b): first divergence from the OLD bounds' continuation is
        // exactly the old boundary frame — where a stale queued old cycle
        // would have wrapped to ramp(0) — and it diverges INTO the new
        // window's content: ONE structural seam, zero stale frames.
        var firstDivergence = -1
        for i in editFrame..<totalFrames
        where output[0][i] != editRamp(i % oldCycleFrames) {
            firstDivergence = i
            break
        }
        let oldBoundary = 3 * oldCycleFrames  // 72 000: the old wrap after the edit
        print("[measured] C7: queued through cycle \(queuedBeforeEdit) at the edit; "
              + "pre-edit mismatches \(preMismatches); post-edit mismatches \(postMismatches), "
              + "stale-band frames \(staleFrames), zero frames \(zeroFrames); "
              + "first divergence from old-bounds continuation @ \(firstDivergence) "
              + "(old boundary \(oldBoundary)); post-edit through cycle "
              + "\(graph.loopScheduledThroughCycle ?? -1)")
        #expect(postMismatches == 0)
        #expect(staleFrames == 0)
        #expect(zeroFrames == 0)
        #expect(firstDivergence == oldBoundary)
        #expect(output[0][oldBoundary] == editRamp(2 * beatFrames))  // new content, not ramp(0)
        #expect((graph.loopScheduledThroughCycle ?? -1) >= 2)        // new unroll armed
    }
}
