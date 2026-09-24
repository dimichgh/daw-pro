import Foundation
import Testing

@testable import DAWEngine

/// **m23-q E2 — the HUMAN listening leg.** Not an assertion suite: it renders the
/// comparison pair a person has to judge, because the question ("does the curve
/// path sound natural on a real voice?") has no deterministic answer. E1 already
/// showed the curve path is clean on a SINE; a sine has no formants, no breath
/// and no consonants, which is exactly why E2 exists and why synthetic material
/// cannot substitute for it.
///
/// Gated on an env var so it never runs in the normal suite: it needs a real
/// vocal file the repo does not (and must not) contain.
///
///     M23Q_E2_SOURCE=/path/to/dry.wav M23Q_E2_OUT=/path/to/outdir ./scripts/test.sh
@Suite("m23-q E2 comparison render")
struct M23QE2RenderTests {
    // ⭐ `.enabled(if:)` rather than an early `return`: a guard that returns makes
    // this pass as a SILENT NO-OP in the normal suite, so the run reports one
    // more passing test than it actually exercised. A skip says so out loud.
    @Test("renders constant-vs-curve pairs for a human to listen to",
          .enabled(if: ProcessInfo.processInfo.environment["M23Q_E2_SOURCE"] != nil
                    && ProcessInfo.processInfo.environment["M23Q_E2_OUT"] != nil))
    func renderPairs() throws {
        let env = ProcessInfo.processInfo.environment
        let src = try #require(env["M23Q_E2_SOURCE"])
        let out = try #require(env["M23Q_E2_OUT"])

        let sourceURL = URL(fileURLWithPath: src)
        let outDir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let sr = 48000.0
        let frames = Int(sr * 33.0)

        // (a) THE STEP — the dramatic case. A 0 -> +2 st move mid-file against
        //     the same source held constantly at +2 st. E1 measured +0.17 dB of
        //     broadband excess here on a sine; the ear decides on a voice.
        let stepAt = frames / 2
        let step: [(outputFrame: Int, semitones: Double)] =
            [(0, 0.0), (stepAt, 2.0)]

        // (b) THE REALISTIC CASE — what a corrector actually asks for: small
        //     continuous moves, tens of cents, never whole semitones. If THIS
        //     is audible as processing, the feature is not viable however
        //     clean the step is.
        var gentle: [(outputFrame: Int, semitones: Double)] = []
        var f = 0
        while f < frames {
            let t = Double(f) / sr
            gentle.append((f, 0.35 * sin(2 * .pi * 0.25 * t)))  // +/- 35 cents
            f += 1440                                            // one hop
        }

        // (c) THE PROBE'S OWN CONTROL — the same sine, delayed half a second
        //     INSIDE the curve. Measuring lag by post-hoc delaying a rendered
        //     file does not work: it shifts the VOICE as well as the
        //     modulation, and the misaligned f0 contour wrecks the fit (tried
        //     it; planting +50 ms moved the reading +120 ms). Shifting the
        //     REQUEST leaves the audio and the processing identical and moves
        //     only the thing being measured, so a probe that reads lag
        //     correctly must report exactly 500 ms more than for (b).
        var shifted: [(outputFrame: Int, semitones: Double)] = []
        f = 0
        while f < frames {
            let t = Double(f) / sr - 0.5
            shifted.append((f, 0.35 * sin(2 * .pi * 0.25 * t)))
            f += 1440
        }

        for (name, curve, constant) in [
            ("step", step, 2.0),
            ("gentle", gentle, 0.0),
            ("shift", shifted, 0.0),
        ] {
            for formant in [true, false] {
                let tag = "\(name)-\(formant ? "formant" : "plain")"
                let r = try M23QComparisonPair.render(
                    sourceURL: sourceURL,
                    outputDirectory: outDir,
                    constantSemitones: constant,
                    curve: curve,
                    formantPreserve: formant,
                    namePrefix: "e2-\(tag)")
                print("E2 \(tag): constant=\(r.constantURL.lastPathComponent) "
                    + "curve=\(r.curveURL.lastPathComponent) sr=\(r.sampleRate) "
                    + "compensation=\(OfflineStretcher.curveLatencyCompensation(sampleRate: r.sampleRate))")
            }
        }
    }
}
