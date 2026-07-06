import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (viii-b) — PDC compensation-ring proof (spec §8.2–8.3), rendered
/// offline through the same `PlaybackGraph`/`ChainHostAU` render code the
/// live engine runs. Targets are set through the `OfflineRenderer`
/// `compensationTargets` seam (one atomic store per strip — the viii-c
/// recompute wiring will drive the same `setCompensationTarget` surface).
/// Ring-internal semantics (retarget crossfade, reset) are pinned directly
/// against `CompensationDelayState.process`, which IS the render-thread code
/// object both strip kinds execute.
@MainActor
@Suite("Latency compensation — offline render", .serialized)
struct LatencyCompensationRenderTests {
    private static let sampleRate = 48_000.0
    /// The built-in limiter's fixed lookahead at 48 kHz.
    private static let limiterLatency = 240
    /// Impulse position in the fixture (0.1 s).
    private static let impulseFrame = 4_800

    // MARK: - Fixtures

    private struct Fixtures {
        let impulse: URL   // single-sample impulse, amp 0.25, at frame 4800
        let cos500: URL    // 500 Hz cosine, amp 0.25
        let cos500Inv: URL // exact sample-wise negation of cos500
    }

    private static var cached: Fixtures?

    private func fixtures() throws -> Fixtures {
        if let cached = Self.cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-pdc-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let frames = Int(Self.sampleRate)  // 1.0 s
        var impulse = [Float](repeating: 0, count: frames)
        impulse[Self.impulseFrame] = 0.25
        var cos500 = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            cos500[frame] = 0.25 * Float(cos(2.0 * Double.pi * 500.0 * Double(frame) / Self.sampleRate))
        }
        let cos500Inv = cos500.map { -$0 }  // exact IEEE negation

        let set = Fixtures(
            impulse: dir.appendingPathComponent("impulse.wav"),
            cos500: dir.appendingPathComponent("cos500.wav"),
            cos500Inv: dir.appendingPathComponent("cos500inv.wav")
        )
        try writeStereoWAV(impulse, to: set.impulse)
        try writeStereoWAV(cos500, to: set.cos500)
        try writeStereoWAV(cos500Inv, to: set.cos500Inv)
        Self.cached = set
        return set
    }

    /// Stereo Float32 WAV, identical channels (TestSignals convention).
    private func writeStereoWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 2,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for frame in 0..<samples.count {
            channels[0][frame] = samples[frame]
            channels[1][frame] = samples[frame]
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    // MARK: - Helpers

    private func audioTrack(id: UUID = UUID(), clip url: URL,
                            effects: [EffectDescriptor] = []) -> Track {
        Track(id: id, name: "SRC", kind: .audio,
              clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4,
                           audioFileURL: url)],
              effects: effects)
    }

    /// Passthrough-apart-from-lookahead limiter: ceiling 0 dBFS, far above
    /// the 0.25/0.5 test levels, so envelope stays 1 and the only effect is
    /// the fixed 240-sample delay.
    private func passthroughLimiter() -> EffectDescriptor {
        EffectDescriptor(kind: .limiter, limiter: LimiterParams(ceilingDb: 0))
    }

    /// `targets` non-nil forces exactly those ring targets (absent strips get
    /// 0 — the uncompensated baseline); nil = always-on plan-driven PDC, the
    /// viii-c wiring the live engine runs.
    private func render(_ tracks: [Track], targets: [UUID: Int]?,
                        seconds: Double = 0.5) throws -> RenderedAudio {
        let renderer = OfflineRenderer()
        renderer.compensationTargets = targets
        return try renderer.render(tracks: tracks, tempoBPM: 120,
                                   fromBeat: 0, durationSeconds: seconds)
    }

    /// Frame indices whose |sample| exceeds `threshold`.
    private func hits(_ channel: [Float], above threshold: Float) -> [Int] {
        channel.indices.filter { abs(channel[$0]) > threshold }
    }

    /// Mono render buffer + direct handle for unit-level ring tests.
    private func makeMonoBuffer(frames: Int) throws -> (AVAudioPCMBuffer, UnsafeMutablePointer<Float>) {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)[0]
        return (buffer, data)
    }

    private func sine100(_ globalFrame: Int) -> Float {
        0.5 * Float(sin(2.0 * Double.pi * 100.0 * Double(globalFrame) / Self.sampleRate))
    }

    // MARK: - §8.2 Impulse alignment

    @Test("dry strip + limiter strip: compensated impulses land on the same output sample")
    func impulseAlignmentAcrossLatentAndDryStrips() throws {
        let fixtures = try fixtures()
        let trackA = UUID()  // dry
        let trackB = UUID()  // limiter (lookahead 240)
        let tracks = [
            audioTrack(id: trackA, clip: fixtures.impulse),
            audioTrack(id: trackB, clip: fixtures.impulse,
                       effects: [passthroughLimiter()]),
        ]

        // Without PDC: two distinct impulse peaks exactly 240 samples apart
        // (the misalignment the ring exists to remove).
        let uncompensated = try render(tracks, targets: [:])
        let rawHits = hits(uncompensated.channelData[0], above: 0.15)
        try #require(rawHits.count == 2)
        #expect(rawHits[1] - rawHits[0] == Self.limiterLatency)
        #expect(rawHits[0] == Self.impulseFrame)

        // Hand-computed plan for this project (spec §2 worked example):
        // T = max(0, 240) = 240 → comp(A) = 240, comp(B) = 0.
        let compensated = try render(
            tracks, targets: [trackA: Self.limiterLatency, trackB: 0])
        let alignedHits = hits(compensated.channelData[0], above: 0.15)
        // ONE above-threshold sample: both impulses on the SAME output frame.
        #expect(alignedHits == [Self.impulseFrame + Self.limiterLatency])
        // Coherent sum: 0.25 + 0.25 at the aligned frame.
        let peak = compensated.channelData[0][Self.impulseFrame + Self.limiterLatency]
        #expect(abs(peak - 0.5) < 0.01)
        // A's old (uncompensated) position is now empty.
        #expect(abs(compensated.channelData[0][Self.impulseFrame]) < 1e-6)
    }

    // MARK: - §8.2 Null test

    @Test("equal comp targets, inverted content: renders to exact silence")
    func equalTargetsNullToExactSilence() throws {
        let fixtures = try fixtures()
        let trackA = UUID()
        let trackB = UUID()
        let tracks = [
            audioTrack(id: trackA, clip: fixtures.cos500),
            audioTrack(id: trackB, clip: fixtures.cos500Inv),
        ]

        let nulled = try render(tracks, targets: [trackA: 240, trackB: 240])
        for channel in nulled.channelData {
            let nonZero = channel.filter { $0 != 0 }.count
            #expect(nonZero == 0)  // exact: zero differing bit patterns
        }

        // Teeth: UNEQUAL targets must NOT null (240 samples shifts 500 Hz by
        // 2.5 periods → the pair sums to −2× instead of 0).
        let skewed = try render(tracks, targets: [trackA: 240, trackB: 0])
        let peak = skewed.channelData[0][300...].map { abs($0) }.max() ?? 0
        #expect(peak > 0.4)
    }

    // MARK: - §8.2 Zero-target inertness

    @Test("target 0 with clean history never touches the buffer (bit-exact passthrough)")
    func zeroTargetIsBitExactPassthrough() throws {
        let state = CompensationDelayState()
        state.allocate(channelCount: 1)
        state.setTarget(0)
        state.armReset()

        let frames = 512
        let (buffer, data) = try makeMonoBuffer(frames: frames)
        // Awkward bit patterns (subnormals, negative zero, odd mantissas)
        // so "untouched" is provable at the bit level.
        var expected = [UInt32](repeating: 0, count: frames)
        for frame in 0..<frames {
            let pattern = UInt32(truncatingIfNeeded: frame &* 2_654_435_761) | 0x0040_0001
            data[frame] = Float(bitPattern: pattern & 0x3FFF_FFFF)
            expected[frame] = data[frame].bitPattern
        }
        for _ in 0..<8 {
            state.process(bufferList: buffer.mutableAudioBufferList, frameCount: frames)
        }
        for frame in 0..<frames {
            #expect(data[frame].bitPattern == expected[frame])
        }

        // Engine-level: a latency-free project with zero targets renders
        // bit-identically on repeat (the ring adds no state, no noise).
        let fixtures = try fixtures()
        let track = audioTrack(clip: fixtures.cos500)
        let first = try render([track], targets: [:])
        let second = try render([track], targets: [track.id: 0])
        #expect(first.channelData == second.channelData)
    }

    // MARK: - §8.3 Retarget declick

    @Test("retarget crossfades over 128 samples, then equals the steady-state signal exactly")
    func retargetDeclickCrossfade() throws {
        let state = CompensationDelayState()
        state.allocate(channelCount: 1)
        state.setTarget(240)
        state.armReset()

        let quantum = 512
        let (buffer, data) = try makeMonoBuffer(frames: quantum)
        var previousSample: Float = 0
        var maxStep: Float = 0

        // 10 quanta at target 240: output is the input delayed 240 exactly.
        for quantumIndex in 0..<10 {
            let base = quantumIndex * quantum
            for frame in 0..<quantum { data[frame] = sine100(base + frame) }
            state.process(bufferList: buffer.mutableAudioBufferList, frameCount: quantum)
            for frame in 0..<quantum {
                let global = base + frame
                let expected: Float = global < 240 ? 0 : sine100(global - 240)
                #expect(data[frame] == expected)  // bit-exact delayed read
                maxStep = max(maxStep, abs(data[frame] - previousSample))
                previousSample = data[frame]
            }
        }
        let steadyStep = maxStep  // natural sample-to-sample motion of the sine

        // Retarget 240 → 0 mid-render.
        state.setTarget(0)
        let base = 10 * quantum
        for frame in 0..<quantum { data[frame] = sine100(base + frame) }
        state.process(bufferList: buffer.mutableAudioBufferList, frameCount: quantum)

        // Fade region: output must equal the dual-read linear crossfade
        // exactly (same Float expression the render path computes).
        var maxTapDelta: Float = 0
        let step = 1.0 / Float(128)
        for frame in 0..<128 {
            let old = sine100(base + frame - 240)
            let new = sine100(base + frame)
            maxTapDelta = max(maxTapDelta, abs(new - old))
            let mix = Float(frame + 1) * step
            let expected = old + (new - old) * mix
            #expect(data[frame] == expected)
        }
        // The fade did real work: a hard swap would have stepped by up to
        // maxTapDelta (measured > 0.05 for this phase), far above the
        // steady-state motion.
        #expect(maxTapDelta > 0.05)

        // Post-fade: bit-exact steady-state at the NEW target (0 = input).
        for frame in 128..<quantum {
            #expect(data[frame] == sine100(base + frame))
        }

        // Declick: no sample-to-sample step beyond the crossfade envelope's
        // worst case (natural motion + tap delta spread over 128 samples).
        var maxRetargetStep: Float = 0
        for frame in 0..<quantum {
            maxRetargetStep = max(maxRetargetStep, abs(data[frame] - previousSample))
            previousSample = data[frame]
        }
        let clickBound = steadyStep + maxTapDelta / 128 + 0.002
        #expect(maxRetargetStep < clickBound)
        #expect(maxRetargetStep < 0.012)  // absolute click threshold
    }

    // MARK: - §8.3 Reset

    @Test("armed reset zeroes the ring: no stale tail leaks into the next pass")
    func resetClearsStaleTail() throws {
        let state = CompensationDelayState()
        state.allocate(channelCount: 1)
        state.setTarget(240)
        state.armReset()

        let quantum = 512
        let (buffer, data) = try makeMonoBuffer(frames: quantum)
        // Two loud quanta: the ring now holds a 240-sample pending tail.
        for quantumIndex in 0..<2 {
            for frame in 0..<quantum { data[frame] = sine100(quantumIndex * quantum + frame) }
            state.process(bufferList: buffer.mutableAudioBufferList, frameCount: quantum)
        }

        // Seek/restart: reset armed. Silence in → EXACT silence out; the
        // pre-reset tail (which an un-reset ring WOULD emit for the first
        // 240 samples) must be gone.
        state.armReset()
        for frame in 0..<quantum { data[frame] = 0 }
        state.process(bufferList: buffer.mutableAudioBufferList, frameCount: quantum)
        for frame in 0..<quantum {
            #expect(data[frame] == 0)
        }

        // First signal quantum after reset behaves like a fresh zeroed ring:
        // 240 zeros, then the delayed signal.
        for frame in 0..<quantum { data[frame] = sine100(frame) }
        state.process(bufferList: buffer.mutableAudioBufferList, frameCount: quantum)
        for frame in 0..<quantum {
            let expected: Float = frame < 240 ? 0 : sine100(frame - 240)
            #expect(data[frame] == expected)
        }
    }

    // MARK: - §8.3 Determinism + instrument path

    @Test("two identical compensated renders are bit-identical")
    func compensatedRenderIsDeterministic() throws {
        let fixtures = try fixtures()
        let trackA = UUID()
        let trackB = UUID()
        let tracks = [
            audioTrack(id: trackA, clip: fixtures.impulse),
            audioTrack(id: trackB, clip: fixtures.impulse,
                       effects: [passthroughLimiter()]),
        ]
        let targets = [trackA: Self.limiterLatency, trackB: 0]
        let first = try render(tracks, targets: targets)
        let second = try render(tracks, targets: targets)
        #expect(first.channelData == second.channelData)
    }

    // MARK: - §8.5 Always-on wiring parity (viii-c/-d)

    @Test("always-on PDC (no seam): dry + limiter strips auto-align from the plan")
    func alwaysOnPlanAlignsWithoutSeam() throws {
        let fixtures = try fixtures()
        let tracks = [
            audioTrack(clip: fixtures.impulse),
            audioTrack(clip: fixtures.impulse, effects: [passthroughLimiter()]),
        ]
        // targets nil → the graph recomputes from PDCPlan in applyParameters,
        // exactly the live engine's path. Same alignment as the hand-fed run.
        let compensated = try render(tracks, targets: nil)
        let alignedHits = hits(compensated.channelData[0], above: 0.15)
        #expect(alignedHits == [Self.impulseFrame + Self.limiterLatency])
        let peak = compensated.channelData[0][Self.impulseFrame + Self.limiterLatency]
        #expect(abs(peak - 0.5) < 0.01)
    }

    @Test("cross-diff 0.0: limiter + dry + shared send bus renders bit-identically twice under the always-on plan")
    func latentSendBusProjectCrossDiffIsZero() throws {
        // The spec §8.5 harness project: dry track + limiter track, both
        // direct to master AND post-fader sends into one shared bus. Offline
        // rendering shares the live render code objects (ChainHostAU render
        // block, ring, chain walk) and the SAME automatic recompute wiring,
        // so two runs must cross-diff to exactly 0.0 — bit level, no epsilon.
        let fixtures = try fixtures()
        let busID = UUID()
        var dry = audioTrack(clip: fixtures.impulse)
        dry.sends = [Send(destinationBusID: busID, level: 1)]
        var latent = audioTrack(clip: fixtures.impulse, effects: [passthroughLimiter()])
        latent.sends = [Send(destinationBusID: busID, level: 1)]
        let bus = Track(id: busID, name: "Bus", kind: .bus)
        let tracks = [dry, latent, bus]

        let first = try render(tracks, targets: nil)
        let second = try render(tracks, targets: nil)
        var maxDiffBits = 0
        for channel in 0..<first.channelData.count {
            let a = first.channelData[channel]
            let b = second.channelData[channel]
            try #require(a.count == b.count)
            for frame in 0..<a.count where a[frame].bitPattern != b[frame].bitPattern {
                maxDiffBits += 1
            }
        }
        #expect(maxDiffBits == 0)  // cross-diff exactly 0.0
        #expect(first.channelData == second.channelData)

        // And the render is plan-correct: every path (2 dry feeds + 2 send
        // returns through the 0-latency bus) lands on ONE output sample —
        // coherent 4 × 0.25 = 1.0 at impulseFrame + T.
        let aligned = hits(first.channelData[0], above: 0.15)
        #expect(aligned == [Self.impulseFrame + Self.limiterLatency])
        let peak = first.channelData[0][Self.impulseFrame + Self.limiterLatency]
        #expect(abs(peak - 1.0) < 0.02)
    }

    @Test("instrument strips compensate identically: target delays the strip output sample-exactly")
    func instrumentStripHonorsCompensationTarget() throws {
        let trackID = UUID()
        let track = Track(
            id: trackID, name: "Keys", kind: .instrument,
            clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 2,
                         notes: [MIDINote(pitch: 60, velocity: 100,
                                          startBeat: 0, lengthBeats: 2)])])
        let delay = 480
        let reference = try render([track], targets: [:], seconds: 0.6)
        let delayed = try render([track], targets: [trackID: delay], seconds: 0.6)

        // The ring starts zeroed (reset at render start): leading silence.
        let lead = delayed.channelData[0][0..<delay].map { abs($0) }.max() ?? 0
        #expect(lead == 0)
        // Beyond it, the delayed render is the reference shifted by exactly
        // `delay` samples (same synth, same chain position, pre-fader).
        var maxDiff: Float = 0
        let frames = min(reference.frameCount, delayed.frameCount)
        for channel in 0..<delayed.channelData.count {
            let ref = reference.channelData[channel]
            let del = delayed.channelData[channel]
            for frame in delay..<frames {
                maxDiff = max(maxDiff, abs(del[frame] - ref[frame - delay]))
            }
        }
        #expect(maxDiff < 1e-6)
        // And the reference actually has signal in the compared window.
        let refPeak = reference.channelData[0][0..<(frames - delay)].map { abs($0) }.max() ?? 0
        #expect(refPeak > 0.05)
    }
}
