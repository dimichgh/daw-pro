import CryptoKit
import Foundation
import Testing
@testable import DAWEngine

/// m23-ap-2a — the ONNX Runtime dependency proven IN THIS TREE.
///
/// m23-ap-1 established Route A in a throwaway two-file SwiftPM executable.
/// That proves the linker can fold `libonnxruntime.a` into *something*; it does
/// not prove it here, where the package has Swift 6 strict concurrency, an
/// `@MainActor` app, a C++ TU (`CSignalsmithStretch`), a second ML dependency
/// (WhisperKit), and a resource-bundle/strip/codesign pipeline. This suite is
/// the proof that matters: it drives a REAL `ORTSession` over the REAL vendored
/// weights inside this package's own build and asserts a known frequency.
///
/// ⚠️ §7.6: pitch DSP never reaches the render thread, and neither does this
/// suite — every leg runs on the test's own thread, off any audio callback.
///
/// ⚠️⚠️ EVERY NUMBER ASSERTED BELOW WAS MEASURED FIRST AND THEN PINNED, not
/// guessed and then loosened. The first draft of this file asserted "≥ 50 of 62
/// frames are voiced at confidence ≥ 0.9" on a clean 220 Hz sine — a threshold
/// lifted from the design's §5.6.6 policy — and it FAILED AT 3 FRAMES. That is
/// not a bug: SwiftF0 is trained on real audio, and a pure mathematical sine has
/// no harmonics, so the model reads the pitch essentially perfectly while
/// staying only ~0.48 confident about it. The design's 0.9 voicing threshold is
/// a policy for real vocal material and MUST NOT be applied to synthetic
/// fixtures. Recorded here because m23-ap-2b's §5.5 gate will hit exactly this.
struct PitchTrackerInferenceTests {

    // MARK: - Fixture

    /// A sine at the model's own 16 kHz rate. `amplitude` is 0.5 by default and
    /// that is NOT cosmetic — see `octaveBimodalityIsPresentAndBounded`.
    /// Generated rather than committed: a closed-form sine is more auditable as
    /// a fixture than a wav blob, and there is nothing to rot.
    private static func sine(frequency: Double, sampleCount: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<sampleCount).map { n in
            amplitude * Float(sin(2.0 * Double.pi * frequency * Double(n) / PitchTracker.modelSampleRate))
        }
    }

    private static func median(_ values: [Double]) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : 0.5 * (sorted[mid - 1] + sorted[mid])
    }

    // MARK: - The weights are the weights

    /// The vendored artefact is pinned by SIZE AND HASH, not by presence.
    /// A truncated or silently-updated `model.onnx` would still "be there" and
    /// would still produce plausible-looking floats; only the hash catches it.
    /// (The upstream PyPI wheel ships a DIFFERENT build of this model — see
    /// `Sources/DAWEngine/Analysis/Resources/VENDORED.md` — so "some SwiftF0
    /// model" is not good enough to reproduce the spike's numbers.)
    @Test func vendoredWeightsMatchThePinnedArtefact() throws {
        let url = try #require(PitchTracker.weightsURL,
                               "swiftf0.onnx did not make it into the DAWEngine resource bundle")
        let data = try Data(contentsOf: url)
        #expect(data.count == 397_987)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "7e2390db8379cd9e1e2b22828e55b45b57c8559e4c8335678c717dc245c18176")
    }

    // MARK: - The negative control, first

    /// THE LEG THAT MAKES THE REST EVIDENCE. Without it, a `detect` that
    /// silently no-op'd and returned zeros would be indistinguishable from a
    /// real inference run. A model path that does not exist MUST throw. (This
    /// is the spike's own control: it verified the scratch binary failed with
    /// `Error Domain=onnxruntime Code=3 ... File doesn't exist`.)
    @Test func aMissingModelFileThrowsRatherThanSilentlySucceeding() {
        let bogus = URL(fileURLWithPath: "/nonexistent/definitely-not-a-model.onnx")
        #expect(throws: PitchTrackerError.self) {
            _ = try PitchTracker(weightsURL: bogus)
        }
    }

    // MARK: - Real inference

    /// THE HEADLINE: a real ORT session, over the real weights, reading the
    /// right frequency out of a known signal — reproducing m23-ap-1's fixture
    /// inside this package's own build.
    ///
    /// The spike recorded 220.8 Hz for this input. Measured here: median over
    /// all 62 frames = **220.830 Hz** (6.5 cents sharp), head frames
    /// 222.074 / 221.129 / 220.917 / 220.830 / 220.759 — the spike's head was
    /// 222.036 / 221.138 / 220.924 / 220.821 / 220.754.
    @Test func detectsTwoTwentyHertzFromARealOnnxRuntimeSession() throws {
        let tracker = try PitchTracker()
        let frames = try tracker.detect(samples: Self.sine(frequency: 220, sampleCount: 16_000))

        // 16000 samples at hop 256 => 62 frames (62.5 fps). This pins the
        // model's framing structure, not just its arithmetic.
        #expect(frames.count == 62)

        // Denormal / NaN guard: every value the model hands back must be a real
        // number before anything downstream reasons about it.
        #expect(frames.allSatisfy { $0.frequencyHz.isFinite && $0.confidence.isFinite })
        #expect(frames.allSatisfy { (0.0...1.0).contains($0.confidence) })
        #expect(frames.allSatisfy { $0.frequencyHz > 0 })

        // The known frequency, two independent ways.
        let overall = Self.median(frames.map(\.frequencyHz))
        #expect(abs(overall - 220.0) < 1.5, "median f0 over all frames was \(overall) Hz")

        let best = try #require(frames.max(by: { $0.confidence < $1.confidence }))
        #expect(abs(best.frequencyHz - 220.0) < 1.5,
                "highest-confidence frame read \(best.frequencyHz) Hz at confidence \(best.confidence)")
        #expect(best.confidence > 0.9)

        // Timestamps advance by exactly one hop.
        #expect(frames[0].timeSeconds == 0)
        #expect(abs(frames[1].timeSeconds - 256.0 / 16_000.0) < 1e-12)
    }

    /// A second, different frequency — so the suite cannot pass by a constant.
    /// A detector hard-wired to 220 Hz would sail through the leg above.
    ///
    /// It also documents a real accuracy fact rather than hiding it: at 440 Hz
    /// SwiftF0 is *extremely* confident (every frame ≥ 0.98) and yet reads
    /// **437.55 Hz — 9.7 cents FLAT**. High confidence is not high accuracy,
    /// and m23-ap-2b's correction UI must not present it as such.
    @Test func detectsADifferentFrequencyToo() throws {
        let tracker = try PitchTracker()
        let frames = try tracker.detect(samples: Self.sine(frequency: 440, sampleCount: 16_000))
        #expect(frames.count == 62)
        #expect(frames.allSatisfy { $0.frequencyHz.isFinite && $0.confidence.isFinite })

        let confident = frames.filter { $0.confidence >= 0.9 }
        #expect(confident.count == 62, "a 440 Hz sine is confidently voiced throughout")

        let detected = Self.median(confident.map(\.frequencyHz))
        #expect(abs(detected - 440.0) < 3.0, "median voiced f0 was \(detected) Hz")
        #expect(detected < 440.0, "the measured bias at 440 Hz is FLAT; if this flips, re-measure")
    }

    /// The spike's binding warning, turned into a standing measurement.
    ///
    /// §5.6.5 / the m23-ap-1 close: the ±9-bin argmax is BIMODAL AT
    /// OCTAVE-RELATED BINS even on a clean sine. Measured here at amplitude
    /// 0.5: **60 of 62 frames read ~220.8 Hz and 2 read ~110.87 Hz** — a real
    /// octave drop, on a signal with no ambiguity in it whatsoever.
    ///
    /// ⚠️ AND IT IS AMPLITUDE-SENSITIVE, which nobody had recorded: the SAME
    /// 220 Hz sine at amplitude 1.0 octave-drops on roughly HALF its frames
    /// (median f0 110.95 Hz). That is why this suite's fixtures fix amplitude
    /// explicitly. m23-ap-2b's octave-sanity leg is not optional and its
    /// fixtures must sweep level, not only frequency.
    ///
    /// ⚠️ READ A FAILURE HERE CORRECTLY: this leg asserts that a DEFECT IS
    /// PRESENT, so it goes red if the model gets BETTER as well as worse. That
    /// is the right shape for characterising a frozen artefact — the runtime is
    /// pinned `exact:` and the weights are pinned by SHA256, so neither can
    /// change without someone deliberately changing them. If it reddens, the
    /// first question is "what did we bump?", not "what did we break."
    @Test func octaveBimodalityIsPresentAndBounded() throws {
        let tracker = try PitchTracker()

        let quiet = try tracker.detect(samples: Self.sine(frequency: 220, sampleCount: 16_000, amplitude: 0.5))
        let quietOctaveDown = quiet.filter { abs($0.frequencyHz - 110.0) < 20 }
        let quietCorrect = quiet.filter { abs($0.frequencyHz - 220.0) < 20 }
        #expect(quietCorrect.count + quietOctaveDown.count == 62,
                "every frame should sit at 220 Hz or its lower octave, nowhere else")
        #expect(quietOctaveDown.count > 0, "the octave failure IS present at amplitude 0.5")
        #expect(quietOctaveDown.count <= 6, "…but bounded — \(quietOctaveDown.count) of 62 frames")

        let loud = try tracker.detect(samples: Self.sine(frequency: 220, sampleCount: 16_000, amplitude: 1.0))
        let loudOctaveDown = loud.filter { abs($0.frequencyHz - 110.0) < 20 }
        #expect(loudOctaveDown.count > quietOctaveDown.count,
                "octave confusion is amplitude-sensitive: \(loudOctaveDown.count) frames at 1.0 vs \(quietOctaveDown.count) at 0.5")
    }

    /// Silence must not produce NaN, Inf, or a denormal cascade. This is the
    /// guard every DSP unit in this package ships with, applied to the one
    /// input most likely to divide by zero somewhere inside the model's head.
    ///
    /// It is also the only thing that separates "voiced" from "not" on
    /// synthetic material, and the gap is NARROW — measured: silence peaks at
    /// confidence 0.384 while the sustained portion of a 220 Hz sine sits at
    /// 0.483. Both are far below the design's 0.9 policy threshold.
    @Test func silenceProducesFiniteValuesAndNoConfidentPitch() throws {
        let tracker = try PitchTracker()
        let frames = try tracker.detect(samples: [Float](repeating: 0, count: 16_000))
        #expect(frames.count == 62)
        #expect(frames.allSatisfy { $0.frequencyHz.isFinite && $0.confidence.isFinite })
        let peak = try #require(frames.map(\.confidence).max())
        #expect(peak < 0.45, "silence peaked at confidence \(peak)")
    }

    /// A buffer shorter than one hop is refused as a value, not by trapping
    /// inside ORT with a shape error the caller cannot act on.
    @Test func aBufferShorterThanOneFrameIsRefused() throws {
        let tracker = try PitchTracker()
        #expect(throws: PitchTrackerError.self) {
            _ = try tracker.detect(samples: [Float](repeating: 0, count: 8))
        }
    }

    /// Odd-length input — the spike's own framing/tail-bug fixture. 12,345
    /// samples is 48.2 hops, so the frame count must round DOWN consistently
    /// and nothing may read past the end of the buffer.
    @Test func anOddLengthBufferFramesCleanly() throws {
        let tracker = try PitchTracker()
        let frames = try tracker.detect(samples: Self.sine(frequency: 220, sampleCount: 12_345))
        #expect(frames.count == 12_345 / PitchTracker.hopLength)
        #expect(frames.allSatisfy { $0.frequencyHz.isFinite && $0.confidence.isFinite })
        let overall = Self.median(frames.map(\.frequencyHz))
        #expect(abs(overall - 220.0) < 1.5, "median f0 was \(overall) Hz on an odd-length buffer")
    }
}
