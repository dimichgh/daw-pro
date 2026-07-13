import AVFAudio
import Foundation
import Testing

// THE m13-f (L-0) GATING SPIKE for gapless loop wrap
// (docs/research/design-m13f-gapless-loop.md §9 L-0; kept like the m12-a
// SidechainBusSpikeTests suite).
//
// Question under measurement — condition zero for the whole design:
// can ONE AVAudioPlayerNode, scheduled with explicit player-relative sample
// anchors (the production clip convention, PlaybackGraph.swift scheduleAll:
// "player sample time 0 ≡ transport position fromBeat"), splice two
// back-to-back segments SAMPLE-CONTINUOUSLY — no dropped, duplicated, or
// zero frames at the boundary — including when the second segment is queued
// WHILE the first is already rendering (the wrap top-up discipline)?
//
// The suite measures, with exact-value assertions:
//   1. pre-queued dual schedule: two analytic ramp buffers anchored at 0 and
//      L on one player — bit-exact continuity across a MID-QUANTUM boundary
//      (L = 6000 is not a multiple of the 512-frame pull);
//   2. the literal loop shape: the SAME AVAudioFile region [0, L) queued
//      twice via scheduleSegment (second pass re-reads from frame 0 while
//      the file also contains never-scheduled sentinel content past L);
//   3. queue-while-playing: segment 2 anchored at L is scheduled only after
//      ~half of segment 1 has rendered (the control-thread top-up the real
//      wrap would perform at wrap-minus-margin);
//   4. NEGATIVE CONTROL — today's restart discipline (AudioEngine.restart:
//      stop-all → reschedule → play with the 60 ms `startLeadSeconds`
//      anchor), emulated offline: post-loop overshoot content plays for the
//      playhead-tick detection latency, then stop() clears the queue, then
//      the next cycle lands `startLeadSeconds` late. The measured overshoot
//      and silence-gap frame counts are THE numbers the design note cites
//      for today's seam.
//
// TEST-ONLY: plain AVFoundation nodes, no production types touched.

// MARK: - Analytic test signals

private let spikeRate = 48_000.0
private let quantumFrames = 512
/// Loop-cycle length in frames. Deliberately NOT a multiple of 512: the
/// splice must land mid-quantum (6000 % 512 = 368) so quantum-boundary
/// quantization cannot masquerade as continuity.
private let cycleFrames = 6_000

/// Cycle-N content: strictly positive, unique per frame at Float precision
/// over the test lengths (ulp at 0.25 ≈ 3e-8 ≪ 1e-6 step).
private func cycleN(_ frame: Int) -> Float { 0.25 + Float(frame) * 1e-6 }

/// Cycle-N+1 content: strictly negative — silence, a stale cycle-N sample,
/// or an off-by-one splice cannot masquerade as delivery at ANY frame.
private func cycleN1(_ frame: Int) -> Float { -0.5 - Float(frame) * 1e-6 }

/// Post-loop-end content (what production's schedule-to-project-end keeps
/// playing during late wrap detection): a third distinguishable band.
private func postLoop(_ frame: Int) -> Float { 0.9 + Float(frame) * 1e-6 }

/// Stereo deinterleaved Float32 buffer with `value(frame)` on both channels.
/// Checkers call the SAME functions, so equality is bit-exact by construction.
private func makeRamp(format: AVAudioFormat, frames: Int,
                      value: (Int) -> Float) throws -> AVAudioPCMBuffer {
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<frames {
        let sample = value(frame)
        for channel in 0..<Int(format.channelCount) {
            channels[channel][frame] = sample
        }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    return buffer
}

// MARK: - Offline rig

/// Manual-rendering harness: one player → mainMixer, 48 kHz stereo,
/// 512-frame pulls (the existing DAWEngineTests offline shape; mixer unity
/// is bit-exact per the SidechainBusSpikeTests precedent).
@MainActor
private final class LoopSpikeRig {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format: AVAudioFormat
    private let renderBuffer: AVAudioPCMBuffer

    init() throws {
        format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: spikeRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        renderBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Player-relative sample anchor — the production clip convention
    /// (`AVAudioTime(sampleTime:atRate:)`, PlaybackGraph scheduleAll).
    func anchor(_ frame: Int) -> AVAudioTime {
        AVAudioTime(sampleTime: AVAudioFramePosition(frame), atRate: spikeRate)
    }

    /// Pulls `quanta` × 512 frames, appending both channels to `output`.
    func render(quanta: Int, into output: inout [[Float]]) throws {
        for _ in 0..<quanta {
            let status = try engine.renderOffline(
                AVAudioFrameCount(quantumFrames), to: renderBuffer)
            try #require(status == .success)
            let data = try #require(renderBuffer.floatChannelData)
            let count = Int(renderBuffer.frameLength)
            for channel in 0..<2 {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: count))
            }
        }
    }
}

// MARK: - Checkers

/// Frames in `range` (both channels) not bit-equal to `value(frame - range
/// .lowerBound)`. Returns (mismatchCount, firstMismatchDescription).
private func mismatches(_ channels: [[Float]], range: Range<Int>,
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

/// NaN guard (house rule: every DSP spike checks for NaN escapes).
private func nanCount(_ channels: [[Float]]) -> Int {
    channels.reduce(0) { total, samples in
        total + samples.lazy.filter { $0.isNaN }.count
    }
}

// MARK: - The spike suite

@MainActor
@Suite("Gapless loop spike — dual-schedule wrap continuity (m13-f L-0)", .serialized)
struct GaplessLoopSpikeTests {
    @Test("pre-queued anchored segments splice sample-continuously mid-quantum")
    func preQueuedDualScheduleIsSampleContinuous() throws {
        let rig = try LoopSpikeRig()
        let bufferA = try makeRamp(format: rig.format, frames: cycleFrames, value: cycleN)
        let bufferB = try makeRamp(format: rig.format, frames: cycleFrames, value: cycleN1)
        // Both cycles queued up front with explicit player-relative anchors:
        // cycle N at 0, cycle N+1 at exactly L — the wrap splice.
        rig.player.scheduleBuffer(bufferA, at: rig.anchor(0),
                                  options: [], completionHandler: nil)
        rig.player.scheduleBuffer(bufferB, at: rig.anchor(cycleFrames),
                                  options: [], completionHandler: nil)
        try rig.engine.start()
        rig.player.play()  // nil-anchor manual rendering: player t0 ≡ first pulled sample

        var output: [[Float]] = [[], []]
        try rig.render(quanta: 24, into: &output)  // 12 288 ≥ 2 L frames
        rig.engine.stop()

        let first = mismatches(output, range: 0..<cycleFrames, against: cycleN)
        let second = mismatches(output, range: cycleFrames..<2 * cycleFrames,
                                against: cycleN1)
        print("[measured] L-0 pre-queued splice at frame \(cycleFrames) "
              + "(mid-quantum offset \(cycleFrames % quantumFrames)): "
              + "cycle-N mismatches \(first.count) (first \(first.first)); "
              + "cycle-N+1 mismatches \(second.count) (first \(second.first)); "
              + "boundary samples \(output[0][cycleFrames - 1]) → \(output[0][cycleFrames]); "
              + "NaNs \(nanCount(output))")
        #expect(first.count == 0)
        #expect(second.count == 0)
        // The splice frames themselves, stated explicitly: last frame of N is
        // N's final ramp value, first frame of N+1 is N+1's frame 0 — no gap,
        // no duplicate, no zero.
        #expect(output[0][cycleFrames - 1] == cycleN(cycleFrames - 1))
        #expect(output[0][cycleFrames] == cycleN1(0))
        #expect(nanCount(output) == 0)
    }

    @Test("the same AVAudioFile region re-queued twice splices sample-continuously")
    func sameFileRegionRequeuedIsSampleContinuous() throws {
        let rig = try LoopSpikeRig()
        // File = loop region [0, L) + 1000 sentinel frames past L that must
        // NEVER sound (scheduleSegment windows the read; production clips
        // window into longer files the same way).
        let fileFrames = cycleFrames + 1_000
        let content = try makeRamp(format: rig.format, frames: fileFrames) { frame in
            frame < cycleFrames ? cycleN(frame) : postLoop(frame - cycleFrames)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m13f-loop-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        // AVAudioFile flushes its header on deinit — the writer must die
        // before the reader opens (no close() below macOS 15).
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: url, settings: rig.format.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: content)
        }
        let file = try AVAudioFile(forReading: url,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try #require(file.length == AVAudioFramePosition(fileFrames))

        // The literal wrap shape: ONE file object, the SAME region, queued
        // twice — the second pass must rewind and re-read from frame 0.
        rig.player.scheduleSegment(file, startingFrame: 0,
                                   frameCount: AVAudioFrameCount(cycleFrames),
                                   at: rig.anchor(0), completionHandler: nil)
        rig.player.scheduleSegment(file, startingFrame: 0,
                                   frameCount: AVAudioFrameCount(cycleFrames),
                                   at: rig.anchor(cycleFrames), completionHandler: nil)
        try rig.engine.start()
        rig.player.play()

        var output: [[Float]] = [[], []]
        try rig.render(quanta: 24, into: &output)
        rig.engine.stop()

        let first = mismatches(output, range: 0..<cycleFrames, against: cycleN)
        let second = mismatches(output, range: cycleFrames..<2 * cycleFrames,
                                against: cycleN)  // same region again
        // Sentinel probe: no frame anywhere may carry post-loop content.
        var sentinelLeaks = 0
        for frame in 0..<output[0].count where output[0][frame] >= 0.9 {
            sentinelLeaks += 1
        }
        print("[measured] L-0 same-file requeue: pass-1 mismatches \(first.count) "
              + "(first \(first.first)); pass-2 mismatches \(second.count) "
              + "(first \(second.first)); sentinel leaks \(sentinelLeaks); "
              + "splice \(output[0][cycleFrames - 1]) → \(output[0][cycleFrames]); "
              + "NaNs \(nanCount(output))")
        #expect(first.count == 0)
        #expect(second.count == 0)
        #expect(sentinelLeaks == 0)
        #expect(output[0][cycleFrames] == cycleN(0))  // re-read restarted at frame 0
        #expect(nanCount(output) == 0)
    }

    @Test("segment queued while the player is already rendering splices continuously")
    func queueWhilePlayingSplicesContinuously() throws {
        let rig = try LoopSpikeRig()
        let bufferA = try makeRamp(format: rig.format, frames: cycleFrames, value: cycleN)
        let bufferB = try makeRamp(format: rig.format, frames: cycleFrames, value: cycleN1)
        rig.player.scheduleBuffer(bufferA, at: rig.anchor(0),
                                  options: [], completionHandler: nil)
        try rig.engine.start()
        rig.player.play()

        var output: [[Float]] = [[], []]
        try rig.render(quanta: 6, into: &output)  // 3072 of 6000 frames rendered

        // The top-up: cycle N+1 queued on the CONTROL thread while cycle N is
        // mid-flight — margin 6000 − 3072 = 2928 frames (61 ms at 48 kHz),
        // the wrap-minus-margin discipline. (Production precedent for
        // enqueue-while-rolling: Metronome.topUp from the playhead task.)
        rig.player.scheduleBuffer(bufferB, at: rig.anchor(cycleFrames),
                                  options: [], completionHandler: nil)
        try rig.render(quanta: 18, into: &output)  // through 12 288
        rig.engine.stop()

        let first = mismatches(output, range: 0..<cycleFrames, against: cycleN)
        let second = mismatches(output, range: cycleFrames..<2 * cycleFrames,
                                against: cycleN1)
        print("[measured] L-0 queue-while-playing (queued at frame 3072, "
              + "margin 2928): cycle-N mismatches \(first.count) "
              + "(first \(first.first)); cycle-N+1 mismatches \(second.count) "
              + "(first \(second.first)); "
              + "splice \(output[0][cycleFrames - 1]) → \(output[0][cycleFrames]); "
              + "NaNs \(nanCount(output))")
        #expect(first.count == 0)
        #expect(second.count == 0)
        #expect(output[0][cycleFrames] == cycleN1(0))
        #expect(nanCount(output) == 0)
    }

    @Test("negative control — today's restart discipline measured: overshoot + lead-in gap")
    func restartDisciplineGapMeasured() throws {
        let rig = try LoopSpikeRig()
        // Production scheduleAll schedules content to project end, so the
        // player holds post-loop-end material; the playhead task detects the
        // wrap up to one 33 ms tick late (AudioEngine.startPlayheadTask).
        // Emulated: render 15 quanta = 7680 frames against a 6000-frame loop
        // → 1680 frames (35 ms) of post-loop overshoot content sound.
        let detectionFrames = 15 * quantumFrames  // 7680
        let overshootFrames = detectionFrames - cycleFrames  // 1680
        // startLeadSeconds = 0.06 (AudioEngine.swift) → 2880 frames at 48 kHz.
        let leadFrames = Int((0.06 * spikeRate).rounded())  // 2880

        let bufferLong = try makeRamp(
            format: rig.format, frames: cycleFrames + 4_096
        ) { frame in
            frame < cycleFrames ? cycleN(frame) : postLoop(frame - cycleFrames)
        }
        let bufferB = try makeRamp(format: rig.format, frames: cycleFrames, value: cycleN1)
        rig.player.scheduleBuffer(bufferLong, at: rig.anchor(0),
                                  options: [], completionHandler: nil)
        try rig.engine.start()
        rig.player.play()

        var output: [[Float]] = [[], []]
        try rig.render(quanta: 15, into: &output)  // through frame 7680

        // THE RESTART PRIMITIVE, emulated between pulls: stop-all (clears the
        // queue, resets player time to 0), reschedule from the loop start,
        // resume with the production lead-in (content anchored `leadFrames`
        // into the fresh player timeline ≡ play(at: now + startLeadSeconds)).
        rig.player.stop()
        rig.player.scheduleBuffer(bufferB, at: rig.anchor(leadFrames),
                                  options: [], completionHandler: nil)
        rig.player.play()
        try rig.render(quanta: 12, into: &output)  // through frame 13 824
        rig.engine.stop()

        // Overshoot: post-loop content audibly played after the loop end.
        let overshoot = mismatches(
            output, range: cycleFrames..<detectionFrames, against: postLoop)
        // Gap: zero frames between the stop point and cycle N+1's onset.
        var gapFrames = 0
        var scan = detectionFrames
        while scan < output[0].count, output[0][scan] == 0, output[1][scan] == 0 {
            gapFrames += 1
            scan += 1
        }
        let onsetFrame = scan
        let resumed = mismatches(
            output, range: onsetFrame..<min(onsetFrame + cycleFrames, output[0].count),
            against: cycleN1)
        let overshootMs = 1_000.0 * Double(overshootFrames) / spikeRate
        let gapMs = 1_000.0 * Double(gapFrames) / spikeRate
        print("[measured] L-0 NEGATIVE CONTROL (today's wrap): "
              + "overshoot \(overshootFrames) frames (\(overshootMs) ms) of "
              + "post-loop content, mismatches \(overshoot.count); "
              + "silence gap \(gapFrames) frames (\(gapMs) ms); "
              + "cycle-N+1 onset at frame \(onsetFrame) "
              + "(expected \(detectionFrames + leadFrames)); "
              + "resumed-content mismatches \(resumed.count) (first \(resumed.first)); "
              + "NaNs \(nanCount(output))")
        // The overshoot region really is post-loop content (wrong audio, not
        // silence): the seam is overshoot THEN silence THEN the next cycle.
        #expect(overshoot.count == 0)
        // Measured 2026-07-12 (macOS 26 / Darwin 25.4): the emulated restart
        // seam is exactly the lead-in — 2880 frames (60.0 ms) of silence,
        // preceded by 1680 frames (35 ms) of overshoot at the modeled
        // detection latency. This is the number the design note cites.
        #expect(gapFrames == leadFrames)
        #expect(onsetFrame == detectionFrames + leadFrames)
        #expect(resumed.count == 0)
        #expect(nanCount(output) == 0)
    }
}
