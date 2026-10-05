import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m38-a — the DSP half of the gain insert's polarity (phase) invert, rendered
/// offline through the same `PlaybackGraph` the live engine uses.
///
/// THE GATE IS A NULL TEST, AND IT IS SHOWN TO FAIL AS WELL AS PASS. Two audio
/// tracks play the SAME transient-rich fixture through identical unity-gain
/// inserts; one has `invertPolarity` armed. The sum must be silence. The
/// control — the leg that makes the null mean anything — renders the identical
/// graph with the flag OFF and shows the sum is about +6 dB, not silence. A
/// null test that has never been shown to fail is not a test.
///
/// The fixture is deliberately NOT a sine: a sine can null by accident at the
/// wrong offset, and would prove the transport aligned rather than the
/// polarity flipped. It is a deterministic LCG-noise burst train with hard
/// onsets, so a one-sample misalignment could not null.
///
/// The schema half lives in `DAWCoreTests/GainPolarityParamsTests`.
@MainActor
@Suite("m38-a gain polarity — offline render null test", .serialized)
struct GainPolarityRenderTests {

    // MARK: - Fixture

    /// Deterministic transient-rich stereo fixture, 2 s @ 48 kHz: an LCG
    /// noise burst with a hard onset every 6000 frames, exponentially decayed,
    /// peak <= 0.4 so the +6 dB control leg still has headroom to be measured
    /// rather than clipped. Same bytes on every machine and every run.
    private func transientFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m36a-polarity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transients.wav")

        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func nextUniform() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
        }
        let samples: [Float] = (0..<96_000).map { frame in
            let sinceOnset = frame % 6_000
            let envelope = Float(exp(-Double(sinceOnset) / 700.0))
            return 0.4 * envelope * nextUniform()
        }
        try writeStereoWAV(samples, to: url)
        return url
    }

    /// Writes a stereo Float32 WAV with identical channels (the
    /// `ClipEnvelopeRenderTests` writer, copied because it is private there).
    private func writeStereoWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for (index, value) in samples.enumerated() {
            channels[0][index] = value
            channels[1][index] = value
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    // MARK: - Helpers

    private func gainFX(_ gain: Double = 1, invert: Bool = false) -> EffectDescriptor {
        EffectDescriptor(kind: .gain,
                         gain: GainParams(gainLinear: gain, invertPolarity: invert))
    }

    private func track(_ name: String, clip url: URL,
                       effects: [EffectDescriptor]) -> Track {
        Track(name: name, kind: .audio,
              clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4, audioFileURL: url)],
              effects: effects)
    }

    private func render(_ tracks: [Track], seconds: Double = 1.5) throws -> RenderedAudio {
        try OfflineRenderer().render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                     fromBeat: 0, durationSeconds: seconds)
    }

    private func peak(_ audio: RenderedAudio) -> Float {
        var peak: Float = 0
        for channel in audio.channelData {
            for sample in channel { peak = max(peak, abs(sample)) }
        }
        return peak
    }

    /// Peak as dBFS; `-.infinity` for an exact zero (the honest reading of a
    /// perfect null — this file reports residuals in dB, never as a bare word).
    private func peakDBFS(_ audio: RenderedAudio) -> Double {
        let value = Double(peak(audio))
        return value > 0 ? 20 * log10(value) : -.infinity
    }

    private func maxDifference(_ a: RenderedAudio, _ b: RenderedAudio) -> Float {
        var maxDiff: Float = 0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            let lhs = a.channelData[channel], rhs = b.channelData[channel]
            for frame in 0..<min(lhs.count, rhs.count) {
                maxDiff = max(maxDiff, abs(lhs[frame] - rhs[frame]))
            }
        }
        return maxDiff
    }

    // MARK: - The null test, and its failure control

    @Test("THE NULL: a track summed with its polarity-inverted twin is silence")
    func polarityInvertNullsAgainstItself() throws {
        let url = try transientFixture()
        // Same clip, same unity gain, same graph shape — ONE boolean differs.
        let nulled = try render([
            track("A", clip: url, effects: [gainFX(1, invert: false)]),
            track("B", clip: url, effects: [gainFX(1, invert: true)]),
        ])

        // x + (-x) is EXACT in IEEE-754, so the residual is not "small", it is
        // zero. Assert it as zero — this tree's bit-exact culture — and report
        // the measured dBFS figure in the failure message either way.
        let residual = peak(nulled)
        #expect(residual == 0,
                "null residual \(peakDBFS(nulled)) dBFS — expected -inf (exactly 0)")
        // Nothing non-finite crept in on the inverted path.
        for channel in nulled.channelData {
            #expect(channel.allSatisfy { $0.isFinite })
        }
        // And the render was not silent for the trivial reason: the SAME
        // fixture through the SAME graph with one track alone is loud.
        let solo = try render([track("A", clip: url, effects: [gainFX(1)])])
        #expect(peak(solo) > 0.1,
                "positive control: the fixture must be audible, peak \(peakDBFS(solo)) dBFS")
    }

    @Test("THE CONTROL: with invertPolarity OFF the same sum does NOT null (~+6 dB)")
    func withoutInvertTheSumDoublesInstead() throws {
        let url = try transientFixture()
        let summed = try render([
            track("A", clip: url, effects: [gainFX(1, invert: false)]),
            track("B", clip: url, effects: [gainFX(1, invert: false)]),
        ])
        let solo = try render([track("A", clip: url, effects: [gainFX(1)])])

        // Emphatically NOT silence.
        #expect(peak(summed) > 0.1,
                "the un-inverted sum must not null; peak \(peakDBFS(summed)) dBFS")
        // Two identical copies sum to exactly double: +6.02 dB.
        let deltaDb = peakDBFS(summed) - peakDBFS(solo)
        #expect(abs(deltaDb - 6.0206) < 0.05,
                "expected about +6.02 dB, measured \(deltaDb) dB")
    }

    // MARK: - Nothing existing moved

    @Test("invertPolarity false is bit-identical to a gain insert's old behaviour")
    func offIsBitIdenticalToUnityPassthrough() throws {
        let url = try transientFixture()
        // A unity gain insert has always been a bit-exact passthrough (the
        // engine's unity skip). With the flag OFF it still is — same Float
        // coefficient, same skip, same bytes.
        let withInsert = try render([track("A", clip: url, effects: [gainFX(1, invert: false)])])
        let noInsert = try render([track("A", clip: url, effects: [])])
        #expect(maxDifference(withInsert, noInsert) == 0)

        // …and a NON-unity gain still multiplies exactly as before.
        let half = try render([track("A", clip: url, effects: [gainFX(0.5, invert: false)])])
        var maxDiff: Float = 0
        for channel in 0..<min(half.channelData.count, noInsert.channelData.count) {
            let lhs = half.channelData[channel], rhs = noInsert.channelData[channel]
            for frame in 0..<min(lhs.count, rhs.count) {
                maxDiff = max(maxDiff, abs(lhs[frame] - 0.5 * rhs[frame]))
            }
        }
        #expect(maxDiff == 0)
    }

    @Test("inverting is exactly negation — sample-for-sample, no level or tone change")
    func invertIsExactNegation() throws {
        let url = try transientFixture()
        let plain = try render([track("A", clip: url, effects: [gainFX(1, invert: false)])])
        let flipped = try render([track("A", clip: url, effects: [gainFX(1, invert: true)])])
        var maxDiff: Float = 0
        for channel in 0..<min(plain.channelData.count, flipped.channelData.count) {
            let lhs = plain.channelData[channel], rhs = flipped.channelData[channel]
            for frame in 0..<min(lhs.count, rhs.count) {
                maxDiff = max(maxDiff, abs(lhs[frame] + rhs[frame]))
            }
        }
        #expect(maxDiff == 0, "flipped must be the exact negative of plain")
        // The unity SKIP must not swallow an inverted unity: -1 is not 1.
        #expect(peak(flipped) > 0.1)
    }

    @Test("polarity composes with gain: invert at 0.5 is exactly -0.5x")
    func polarityFoldsIntoTheGainCoefficient() throws {
        let url = try transientFixture()
        let dry = try render([track("A", clip: url, effects: [])])
        let scaledFlip = try render([track("A", clip: url, effects: [gainFX(0.5, invert: true)])])
        var maxDiff: Float = 0
        for channel in 0..<min(dry.channelData.count, scaledFlip.channelData.count) {
            let lhs = dry.channelData[channel], rhs = scaledFlip.channelData[channel]
            for frame in 0..<min(lhs.count, rhs.count) {
                maxDiff = max(maxDiff, abs(rhs[frame] + 0.5 * lhs[frame]))
            }
        }
        #expect(maxDiff == 0)
    }

    // MARK: - The transition (the RT-safety judgement)

    @Test("a live flip RAMPS through zero on the existing declick, never steps")
    func liveFlipRampsThroughZeroInsteadOfClicking() throws {
        let effect = GainEffect(params: GainParams(gainLinear: 1))
        effect.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 1)

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        let data = try #require(buffer.floatChannelData)[0]
        func processDC() -> [Float] {
            for frame in 0..<512 { data[frame] = 1 }
            effect.process(buffers: list, frameCount: 512)
            return (0..<512).map { data[$0] }
        }

        // First quantum adopts EXACTLY (no ramp) — DC in, DC out.
        #expect(processDC().allSatisfy { $0 == 1 })

        // Arm the flip and collect the ~5 ms (240 frame) transition.
        effect.apply(params: GainParams(gainLinear: 1, invertPolarity: true))
        var transition: [Float] = []
        while transition.count < 512 { transition += processDC() }

        // It ENDS inverted…
        #expect(transition[400] == -1)
        // …it PASSES THROUGH ZERO rather than stepping…
        let crossings = transition.indices.dropFirst().filter {
            transition[$0].sign != transition[$0 - 1].sign
        }
        #expect(crossings.count == 1, "exactly one sign change: a ramp, not a step")
        #expect(transition.contains { abs($0) < 0.05 },
                "the ramp must actually visit near-zero")
        // …and NO single-sample step exceeds the declick's own slope. A raw
        // flip would be a 2.0 discontinuity; the ramp's step is 2/240 ≈ 0.0084.
        let maxStep = transition.indices.dropFirst()
            .map { abs(transition[$0] - transition[$0 - 1]) }.max() ?? 0
        #expect(maxStep < 0.01, "max per-sample step \(maxStep) — a click would be ~2.0")
        #expect(transition.allSatisfy { $0.isFinite })
    }

    @Test("the polarity automation slot (1) flips without touching the gain slot (0)")
    func automationSlotOneFlipsPolarity() throws {
        // Slot order is the spec table's order, and lanes address by INDEX.
        #expect(EffectParamSpec.specs(for: .gain).map(\.name)
            == ["gainLinear", "invertPolarity"])

        let effect = GainEffect(params: GainParams(gainLinear: 0.5))
        effect.prepare(sampleRate: 48_000, maxFramesPerQuantum: 256, channelCount: 1)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let data = try #require(buffer.floatChannelData)[0]

        func quantum(store: (slot: Int, value: Double)?) -> Float {
            for frame in 0..<256 { data[frame] = 1 }
            if let store { effect.storeAutomatedParam(slot: store.slot, value: store.value) }
            effect.process(buffers: list, frameCount: 256)
            return data[255]  // settled end of the quantum
        }

        #expect(quantum(store: nil) == 0.5)
        // Slot 1 on: the coefficient goes negative, keeping the 0.5 magnitude.
        _ = quantum(store: (1, 1))
        #expect(quantum(store: (1, 1)) == -0.5)
        // Slot 1 off again restores the knob's own sign, gain untouched.
        _ = quantum(store: (1, 0))
        #expect(quantum(store: (1, 0)) == 0.5)
        // An out-of-range slot stays inert.
        #expect(quantum(store: (9, 1)) == 0.5)
    }
}
