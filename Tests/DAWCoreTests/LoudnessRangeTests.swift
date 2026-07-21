import Foundation
import Testing
@testable import DAWCore

// m22-c: EBU Tech 3342 loudness range (LRA) fixtures — synthetic programs
// whose short-term distribution (and therefore whose percentiles) are
// computable by hand. The 997 Hz calibration identity (K-gain at 997 Hz
// cancels the −0.691 offset) makes plateau loudness ≈ the dBFS level, and —
// crucially for LRA — the SAME calibration offset rides every plateau, so
// it cancels exactly in the 95th−10th percentile DIFFERENCE.

// MARK: - Fixtures (the LoudnessTests helpers, file-private per house style)

private func sine(frequency: Double, dbfs: Double, seconds: Double,
                  sampleRate: Double, phaseRadians: Double = 0) -> [Float] {
    let amplitude = pow(10.0, dbfs / 20.0)
    let count = Int((seconds * sampleRate).rounded())
    var out = [Float](repeating: 0, count: count)
    for n in 0..<count {
        out[n] = Float(amplitude * sin(2.0 * .pi * frequency * Double(n) / sampleRate + phaseRadians))
    }
    return out
}

private func stereo(_ channel: [Float], sampleRate: Double) -> RenderedAudio {
    RenderedAudio(sampleRate: sampleRate, channelData: [channel, channel])
}

/// LUFS → the weighted-mean-square domain `loudnessRange` consumes
/// (inverse of `loudness(fromWeightedMeanSquare:)`), for direct estimator
/// pins on hand-built series.
private func meanSquare(lufs: Double) -> Double {
    pow(10.0, (lufs + 0.691) / 10.0)
}

@Suite("Loudness range — EBU 3342 fixtures (m22-c)")
struct LoudnessRangeTests {

    // 1. Constant level: every gated short-term window sits at one value, so
    //    the 95th and 10th percentiles coincide. Tolerance 0.01 LU — the only
    //    spread is fp drift in the sliding window sums (identical windows
    //    differ by ~1e-13 LU); anything larger means the estimator is wrong.
    @Test("constant −23 dBFS tone, 60 s → LRA 0 ± 0.01 LU")
    func constantToneIsZeroRange() throws {
        let audio = stereo(sine(frequency: 997, dbfs: -23, seconds: 60, sampleRate: 48_000),
                           sampleRate: 48_000)
        let lra = try #require(Loudness.measure(audio).loudnessRangeLu)
        #expect(abs(lra) <= 0.01)
    }

    // 2. The EBU 3342 alternating-plateau shape (its Table 1 idiom at −33/−23):
    //    20 s + 20 s → 371 short-term windows = 171 flat at −33, 29 transition
    //    (rising −31.9 → −23.1), 171 flat at −23. Relative gate ≈ −45.6 keeps
    //    everything, so the survivors ARE that distribution; the 10th
    //    percentile index round(0.10·370)=37 lands deep in the −33 plateau and
    //    the 95th round(0.95·370)=352 deep in the −23 plateau → LRA = 10 LU
    //    by hand. Tolerance 0.05 LU: both percentiles sit on flat plateaus
    //    (identical windows), the shared 997 Hz calibration offset cancels in
    //    the difference, and the transition windows sit ≥ 5 indices from
    //    either percentile — only fp noise remains.
    @Test("20 s at −33 then 20 s at −23 → LRA 10.0 ± 0.05 LU (hand-derived percentiles)")
    func alternatingPlateausReadTenLU() throws {
        var samples = sine(frequency: 997, dbfs: -33, seconds: 20, sampleRate: 48_000)
        samples += sine(frequency: 997, dbfs: -23, seconds: 20, sampleRate: 48_000)
        let lra = try #require(Loudness.measure(stereo(samples, sampleRate: 48_000)).loudnessRangeLu)
        #expect(abs(lra - 10.0) <= 0.05)
    }

    // 3. The relative gate at work: a −60 dBFS plateau sits 37 LU under the
    //    −23 program, far below the (gated-mean − 20 LU) ≈ −46 relative gate,
    //    so its windows are EXCLUDED — LRA stays ≈ 0 instead of ballooning to
    //    ~37. The 29 partially-quiet transition windows DO survive (their
    //    energy is −23-dominated, ≥ −37.8) but land between the percentile
    //    indices (10th = sorted[30], 95th = sorted[284], both on the 271-wide
    //    −23 plateau — hand count). Tolerance 0.01 LU: both percentiles read
    //    identical plateau windows, fp drift only.
    @Test("30 s at −23 then 30 s at −60 → LRA 0 ± 0.01 LU (relative gate drops the quiet span)")
    func relativeGateExcludesQuietSpan() throws {
        var samples = sine(frequency: 997, dbfs: -23, seconds: 30, sampleRate: 48_000)
        samples += sine(frequency: 997, dbfs: -60, seconds: 30, sampleRate: 48_000)
        let lra = try #require(Loudness.measure(stereo(samples, sampleRate: 48_000)).loudnessRangeLu)
        #expect(abs(lra) <= 0.01)
    }

    // 4. Absolute gate honesty: a −80 dBFS program's short-term windows all
    //    sit below the −70 LUFS absolute gate → nothing survives → nil (no
    //    evidence), never 0.
    @Test("−80 dBFS program → LRA nil (below the −70 absolute gate)")
    func absoluteGateYieldsNil() {
        let audio = stereo(sine(frequency: 997, dbfs: -80, seconds: 5, sampleRate: 48_000),
                           sampleRate: 48_000)
        #expect(Loudness.measure(audio).loudnessRangeLu == nil)
    }

    // 5. Shorter than one 3 s window → no short-term series at all → nil
    //    (and the existing maxShortTermLufs nil pin already covers the same
    //    boundary).
    @Test("2 s program → LRA nil (no short-term window fits)")
    func tooShortYieldsNil() {
        let audio = stereo(sine(frequency: 997, dbfs: -23, seconds: 2, sampleRate: 48_000),
                           sampleRate: 48_000)
        #expect(Loudness.measure(audio).loudnessRangeLu == nil)
    }

    // 6. Direct estimator pin on an exactly-constructed series (no audio, no
    //    filters): 100 windows at −30 and 100 at −20 (energies exact via the
    //    inverse loudness map). Relative gate = energy-mean loudness − 20 ≈
    //    −42.6 keeps all 200; sorted, the 10th percentile index
    //    round(0.10·199)=20 reads −30 and the 95th round(0.95·199)=189 reads
    //    −20 → LRA exactly 10. Tolerance 1e-9: pure arithmetic on exact
    //    inputs — this pins the percentile estimator itself.
    @Test("estimator pin: 100×−30 + 100×−20 series → LRA 10 exactly")
    func estimatorPinOnExactSeries() throws {
        let series = [Double](repeating: meanSquare(lufs: -30), count: 100)
            + [Double](repeating: meanSquare(lufs: -20), count: 100)
        let lra = try #require(Loudness.loudnessRange(fromShortTermWeightedMeanSquares: series))
        #expect(abs(lra - 10.0) <= 1e-9)
    }

    // 7. Direct relative-gate pin: 10 windows at −10 dominate the energy mean
    //    (relative gate ≈ −37.8), so 50 windows at −40 are dropped and the
    //    survivors are one flat plateau → LRA exactly 0. Tolerance 1e-9
    //    (exact inputs). A −20 LU gate that was actually −10 or −30 moves
    //    this fixture off 0 — it pins the gate depth.
    @Test("estimator pin: 10×−10 + 50×−40 series → gate drops −40, LRA 0 exactly")
    func relativeGateDepthPin() throws {
        let series = [Double](repeating: meanSquare(lufs: -10), count: 10)
            + [Double](repeating: meanSquare(lufs: -40), count: 50)
        let lra = try #require(Loudness.loudnessRange(fromShortTermWeightedMeanSquares: series))
        #expect(abs(lra) <= 1e-9)
    }

    // 8. Wire shape: the new field is additive — it round-trips through
    //    JSON, and an all-nil measurement still encodes as {} (the existing
    //    digital-silence pin guards the same downward).
    @Test("loudnessRangeLu rides the LoudnessMeasurement wire shape")
    func wireShape() throws {
        let m = LoudnessMeasurement(integratedLufs: -23, truePeakDbtp: -1,
                                    maxMomentaryLufs: -20, maxShortTermLufs: -21,
                                    loudnessRangeLu: 6.25)
        let decoded = try JSONDecoder().decode(LoudnessMeasurement.self,
                                               from: JSONEncoder().encode(m))
        #expect(decoded == m)
        #expect(decoded.loudnessRangeLu == 6.25)
        let empty = String(decoding: try JSONEncoder().encode(LoudnessMeasurement()),
                           as: UTF8.self)
        #expect(empty == "{}")
    }
}
