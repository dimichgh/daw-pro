import Foundation

/// BS.1770-4 loudness + true-peak measurement result (M5 iv-a, spec §3.4).
///
/// Codable IS the wire shape (wire-never-drifts): `render.measureLoudness`,
/// `render.bounce`, and `render.stems` reports all carry this verbatim.
/// `nil` fields mean "no signal above the gate / digital silence" — JSON has
/// no −inf, so nil is the honest encoding (synthesized Codable omits nil
/// optionals). Agents must null-check.
public struct LoudnessMeasurement: Codable, Sendable, Equatable {
    /// Gated integrated loudness, LUFS (−70 absolute gate → −10 LU relative
    /// gate). nil = every 400 ms block sits at/below −70 LUFS.
    public var integratedLufs: Double?
    /// 4× oversampled true peak per BS.1770-4 Annex 2, dBTP. nil = digital
    /// silence (zero energy has no dB value).
    public var truePeakDbtp: Double?
    /// Max UNGATED 400 ms block loudness (EBU 3341 momentary), LUFS.
    /// nil = shorter than 400 ms or zero-energy throughout.
    public var maxMomentaryLufs: Double?
    /// Max 3.0 s window loudness, hop 0.1 s (EBU 3341 short-term), LUFS.
    /// nil = shorter than 3 s or zero-energy throughout.
    public var maxShortTermLufs: Double?

    public init(integratedLufs: Double? = nil,
                truePeakDbtp: Double? = nil,
                maxMomentaryLufs: Double? = nil,
                maxShortTermLufs: Double? = nil) {
        self.integratedLufs = integratedLufs
        self.truePeakDbtp = truePeakDbtp
        self.maxMomentaryLufs = maxMomentaryLufs
        self.maxShortTermLufs = maxShortTermLufs
    }
}

/// The loudness story of one bounce (M5 iv-b, spec §4.2). Codable IS the wire
/// shape (`render.bounce` carries it verbatim; wire-never-drifts).
///
/// Honesty rules (spec §4.1): the gain is a single STATIC value —
/// `lufsTarget − input.integratedLufs`, CLAMPED so the true peak never
/// exceeds `truePeakCeilingDbtp` (no limiter in v0; `limitedByCeiling` says
/// when the clamp made target unreachable, and `output.integratedLufs` is the
/// loudness actually achieved). `output` is RE-MEASURED from the gained
/// buffer, never derived — the −70 absolute gate can flip near-gate blocks
/// under large gains.
public struct BounceLoudnessReport: Codable, Sendable, Equatable {
    /// Measurement of the raw render, pre-gain.
    public var input: LoudnessMeasurement
    /// Measurement of what was actually written to disk, post-gain
    /// (== `input` when no gain was applied).
    public var output: LoudnessMeasurement
    /// The static gain applied to the whole bounce, dB. 0 when no
    /// `lufsTarget` was requested.
    public var appliedGainDb: Double
    /// Echo of the request; nil = no normalization was asked for.
    public var lufsTarget: Double?
    /// Echo of the ceiling in force (default −1.0 dBTP).
    public var truePeakCeilingDbtp: Double
    /// True when the ceiling clamped the gain below what the target needed —
    /// the bounce landed `lufsTarget − output.integratedLufs` LU under target.
    public var limitedByCeiling: Bool

    public init(input: LoudnessMeasurement, output: LoudnessMeasurement,
                appliedGainDb: Double, lufsTarget: Double? = nil,
                truePeakCeilingDbtp: Double = -1.0, limitedByCeiling: Bool = false) {
        self.input = input
        self.output = output
        self.appliedGainDb = appliedGainDb
        self.lufsTarget = lufsTarget
        self.truePeakCeilingDbtp = truePeakCeilingDbtp
        self.limitedByCeiling = limitedByCeiling
    }
}

/// Result of `ProjectStore.renderBounce` (M5 iv-b, spec §4.2) — the written
/// file's facts plus the full loudness report. Codable = the `render.bounce`
/// wire response.
public struct BounceResult: Codable, Sendable, Equatable {
    /// Absolute filesystem path of the written WAV.
    public var path: String
    public var durationSeconds: Double
    public var sampleRate: Double
    public var channels: Int
    public var report: BounceLoudnessReport

    public init(path: String, durationSeconds: Double, sampleRate: Double,
                channels: Int, report: BounceLoudnessReport) {
        self.path = path
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.report = report
    }
}

/// Result of `ProjectStore.measureLoudness` (M5 iv-b, spec §4.2) — measurement
/// only, nothing written to disk. Codable = the `render.measureLoudness` wire
/// response.
public struct LoudnessMeasureResult: Codable, Sendable, Equatable {
    public var measurement: LoudnessMeasurement
    /// Ground-truth duration of the measured render (frames ÷ rate).
    public var durationSeconds: Double
    public var sampleRate: Double

    public init(measurement: LoudnessMeasurement, durationSeconds: Double,
                sampleRate: Double) {
        self.measurement = measurement
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
    }
}

/// BS.1770-4 loudness measurement, hand-rolled pure-Swift scalar DSP (M5 iv-a,
/// spec §3). No Accelerate, no libebur128 — DAWCore stays dependency-free, and
/// this is offline-only math (~milliseconds for a full song; never on the
/// render thread).
///
/// - K-weighting (§3.1): two cascaded biquads whose coefficients are
///   RE-DERIVED at any sample rate from the analog-prototype constants (the
///   exact inversion of the BS.1770-4 printed 48 kHz tables); a pin test
///   holds the 48 kHz derivation to the published tables within 1e-6.
/// - Gating (§3.2): 400 ms blocks, 75 % overlap (hop 100 ms), mean-square
///   channel sum with BS.1770 channel weights; absolute −70 LUFS gate, then
///   a single-pass relative gate at (absolute-gated mean − 10 LU).
/// - Momentary / short-term maxima: max ungated 400 ms block, and max 3.0 s
///   window (hop 0.1 s) built from the same 100 ms energy series.
/// - True peak (§3.3): 4× polyphase windowed-sinc interpolation per Annex 2;
///   max |sample| over the original samples + 3 interpolated phases, dBTP.
///
/// Deterministic: all state is Double, sequential, no threading — two runs on
/// the same buffer produce identical results (test-asserted).
public enum Loudness {

    // MARK: - Public API

    /// Measure a whole rendered buffer. Pure, synchronous, O(frames).
    /// Non-finite input samples (NaN/inf) poison only what they touch and are
    /// excluded by the final `isFinite` guards — fields degrade to nil rather
    /// than shipping NaN over the wire.
    public static func measure(_ audio: RenderedAudio) -> LoudnessMeasurement {
        var result = LoudnessMeasurement()
        let sampleRate = audio.sampleRate
        let channels = audio.channelData
        let frameCount = channels.map(\.count).min() ?? 0
        guard sampleRate > 0, !channels.isEmpty, frameCount > 0 else { return result }

        // True peak first — independent of the K-weighted path.
        let peak = truePeakLinear(channels)
        if peak > 0 {
            let dbtp = 20.0 * log10(peak)
            if dbtp.isFinite { result.truePeakDbtp = dbtp }
        }

        // K-weighted energy per 100 ms hop, per channel. Blocks (400 ms) and
        // short-term windows (3 s) are exact sums of 4 / 30 consecutive hops,
        // so one pass over the samples feeds every loudness series. The
        // trailing partial hop (hence partial block) is dropped, per spec.
        let hopFrames = Int((0.1 * sampleRate).rounded())
        guard hopFrames > 0 else { return result }
        let hopCount = frameCount / hopFrames
        guard hopCount > 0 else { return result }

        let stages = kWeightingStages(sampleRate: sampleRate)
        var hopEnergies: [[Double]] = []
        hopEnergies.reserveCapacity(channels.count)
        for channel in channels {
            hopEnergies.append(kWeightedHopEnergies(channel, hopFrames: hopFrames,
                                                    hopCount: hopCount, stages: stages))
        }

        // 400 ms blocks = 4 hops (75 % overlap). l_j = −0.691 + 10·log10(Σ G_i·z_ij).
        let hopsPerBlock = 4
        let blockCount = hopCount - (hopsPerBlock - 1)
        var blockWeightedMeanSquare: [Double] = []
        var blockLoudness: [Double] = []
        if blockCount > 0 {
            blockWeightedMeanSquare.reserveCapacity(blockCount)
            blockLoudness.reserveCapacity(blockCount)
            let blockFrames = Double(hopsPerBlock * hopFrames)
            for j in 0..<blockCount {
                var weightedSum = 0.0
                for (i, energies) in hopEnergies.enumerated() {
                    let energy = energies[j] + energies[j + 1] + energies[j + 2] + energies[j + 3]
                    weightedSum += channelWeight(i) * (energy / blockFrames)
                }
                blockWeightedMeanSquare.append(weightedSum)
                blockLoudness.append(loudness(fromWeightedMeanSquare: weightedSum))
            }
        }

        if let maxBlock = blockLoudness.max(), maxBlock.isFinite {
            result.maxMomentaryLufs = maxBlock
        }

        // Short-term: 3.0 s windows = 30 hops, hop 0.1 s, same energy math.
        let hopsPerShortTerm = 30
        if hopCount >= hopsPerShortTerm {
            let windowFrames = Double(hopsPerShortTerm * hopFrames)
            var channelWindowEnergies = [Double](repeating: 0, count: hopEnergies.count)
            // Sliding sum per channel: O(hopCount) instead of O(hopCount·30).
            for (i, energies) in hopEnergies.enumerated() {
                for h in 0..<hopsPerShortTerm { channelWindowEnergies[i] += energies[h] }
            }
            var maxShortTerm = windowLoudness(channelWindowEnergies, windowFrames: windowFrames)
            // `hopCount == hopsPerShortTerm` means exactly one window fits
            // (already computed above) and there is nothing left to slide —
            // `1...0` is an invalid Range and must not be constructed.
            if hopCount > hopsPerShortTerm {
                for k in 1...(hopCount - hopsPerShortTerm) {
                    for (i, energies) in hopEnergies.enumerated() {
                        channelWindowEnergies[i] += energies[k + hopsPerShortTerm - 1] - energies[k - 1]
                    }
                    let value = windowLoudness(channelWindowEnergies, windowFrames: windowFrames)
                    if value > maxShortTerm { maxShortTerm = value }
                }
            }
            if maxShortTerm.isFinite { result.maxShortTermLufs = maxShortTerm }
        }

        // Gating (§3.2): absolute −70 LUFS, then relative (mean − 10 LU),
        // integrated over blocks passing BOTH.
        let absoluteGateLufs = -70.0
        let absGated = blockLoudness.indices.filter { blockLoudness[$0] > absoluteGateLufs }
        if !absGated.isEmpty {
            let absMean = absGated.reduce(0.0) { $0 + blockWeightedMeanSquare[$1] }
                / Double(absGated.count)
            let relativeGateLufs = loudness(fromWeightedMeanSquare: absMean) - 10.0
            let gated = absGated.filter { blockLoudness[$0] > relativeGateLufs }
            if !gated.isEmpty {
                let mean = gated.reduce(0.0) { $0 + blockWeightedMeanSquare[$1] }
                    / Double(gated.count)
                let integrated = loudness(fromWeightedMeanSquare: mean)
                if integrated.isFinite { result.integratedLufs = integrated }
            }
        }

        return result
    }

    // MARK: - K-weighting (§3.1)

    /// One biquad stage, difference equation
    /// `y = b0·x + b1·x₁ + b2·x₂ − a1·y₁ − a2·y₂` (coefficients used verbatim
    /// — stage 2's b side is deliberately UNNORMALIZED `[1, −2, 1]`, exactly
    /// as the ITU table prints it).
    struct Biquad: Sendable, Equatable {
        var b0: Double, b1: Double, b2: Double
        var a1: Double, a2: Double
    }

    /// K-weighting coefficients derived at ANY sample rate from the
    /// analog-prototype constants (the De Man / pyloudnorm exact inversion of
    /// the BS.1770-4 48 kHz tables). At fs = 48 000 the derivation reproduces
    /// Tables 1–2 within 1e-6 (pin test).
    static func kWeightingStages(sampleRate fs: Double) -> (shelf: Biquad, highPass: Biquad) {
        // Stage 1 — pre-filter high shelf (head-related response).
        let shelfF0 = 1681.9744509555319
        let shelfGainDb = 3.999843853973347
        let shelfQ = 0.7071752369554196
        let k1 = tan(.pi * shelfF0 / fs)
        let vh = pow(10.0, shelfGainDb / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let d1 = 1.0 + k1 / shelfQ + k1 * k1
        let shelf = Biquad(b0: (vh + vb * k1 / shelfQ + k1 * k1) / d1,
                           b1: 2.0 * (k1 * k1 - vh) / d1,
                           b2: (vh - vb * k1 / shelfQ + k1 * k1) / d1,
                           a1: 2.0 * (k1 * k1 - 1.0) / d1,
                           a2: (1.0 - k1 / shelfQ + k1 * k1) / d1)

        // Stage 2 — RLB high-pass. b = [1, −2, 1] EXACTLY (unnormalized).
        let hpF0 = 38.13547087602444
        let hpQ = 0.5003270373238773
        let k2 = tan(.pi * hpF0 / fs)
        let d2 = 1.0 + k2 / hpQ + k2 * k2
        let highPass = Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                              a1: 2.0 * (k2 * k2 - 1.0) / d2,
                              a2: (1.0 - k2 / hpQ + k2 * k2) / d2)
        return (shelf, highPass)
    }

    /// BS.1770-4 channel weights G_i by channel index: L/R (and a future C)
    /// 1.0; surround Ls/Rs 1.41. v0 renders are stereo-only, so only the
    /// first branch is exercised; the 1.41 branch is documented future-proofing
    /// (no LFE concept exists in the model — nothing to exclude yet).
    static func channelWeight(_ index: Int) -> Double {
        index < 3 ? 1.0 : 1.41
    }

    /// Cascade both K-weighting stages over one channel (zero initial state,
    /// Double throughout) and integrate y² per 100 ms hop.
    private static func kWeightedHopEnergies(_ samples: [Float], hopFrames: Int,
                                             hopCount: Int,
                                             stages: (shelf: Biquad, highPass: Biquad)) -> [Double] {
        let s = stages.shelf
        let h = stages.highPass
        var sx1 = 0.0, sx2 = 0.0, sy1 = 0.0, sy2 = 0.0
        var hx1 = 0.0, hx2 = 0.0, hy1 = 0.0, hy2 = 0.0
        var energies = [Double]()
        energies.reserveCapacity(hopCount)
        samples.withUnsafeBufferPointer { buffer in
            var index = 0
            for _ in 0..<hopCount {
                var acc = 0.0
                for _ in 0..<hopFrames {
                    let x = Double(buffer[index]); index += 1
                    let y = s.b0 * x + s.b1 * sx1 + s.b2 * sx2 - s.a1 * sy1 - s.a2 * sy2
                    sx2 = sx1; sx1 = x
                    sy2 = sy1; sy1 = y
                    let z = h.b0 * y + h.b1 * hx1 + h.b2 * hx2 - h.a1 * hy1 - h.a2 * hy2
                    hx2 = hx1; hx1 = y
                    hy2 = hy1; hy1 = z
                    acc += z * z
                }
                energies.append(acc)
            }
        }
        return energies
    }

    /// `−0.691 + 10·log10(Σ G_i·z_i)`; −inf for zero energy (fails every gate
    /// naturally, and the final `isFinite` guards keep it off the wire).
    private static func loudness(fromWeightedMeanSquare z: Double) -> Double {
        z > 0 ? -0.691 + 10.0 * log10(z) : -.infinity
    }

    private static func windowLoudness(_ channelEnergies: [Double], windowFrames: Double) -> Double {
        var weightedSum = 0.0
        for (i, energy) in channelEnergies.enumerated() {
            weightedSum += channelWeight(i) * (energy / windowFrames)
        }
        return loudness(fromWeightedMeanSquare: weightedSum)
    }

    // MARK: - True peak (§3.3, Annex 2)

    /// 4× interpolator, phases 1–3 (phase 0 is the original samples — the
    /// prototype is an ODD-length windowed sinc whose center falls on a
    /// multiple of 4, so the zero-phase branch is exactly identity and "max
    /// over original + 3 interpolated phases" is literal).
    ///
    /// Design (coefficients are implementer's choice per spec; the EBU 3341
    /// acceptance case is the normative check): prototype
    /// `sinc((n−64)/4) · Kaiser(β = 6)`, length 129 → 3 interpolation phases
    /// × 32 taps (≥ the spec's 12/phase floor), cutoff at the original
    /// Nyquist, each phase normalized to exact unity DC gain. Passband is
    /// flat to 20 kHz within 0.1 dB at fs ≥ 48 k (the project's delivery
    /// rate; measured worst deviation 0.0093 dB); at 44.1 k flatness holds to
    /// ≈ 19.5 kHz (−0.35 dB at 20 kHz) — immaterial for peak estimation and
    /// documented here.
    static let interpolatorPhases: [[Double]] = makeInterpolatorPhases()

    private static func makeInterpolatorPhases() -> [[Double]] {
        let tapsPerPhase = 32
        let length = 4 * tapsPerPhase + 1          // 129, odd
        let center = 2 * tapsPerPhase              // 64 ≡ 0 (mod 4) → identity phase 0
        let beta = 6.0
        let i0Beta = besselI0(beta)

        var prototype = [Double](repeating: 0, count: length)
        for n in 0..<length {
            let x = Double(n - center) / 4.0
            let sinc = x == 0 ? 1.0 : sin(.pi * x) / (.pi * x)
            let r = Double(n - center) / Double(center)
            let window = besselI0(beta * (1.0 - r * r).squareRoot()) / i0Beta
            prototype[n] = sinc * window
        }

        var phases: [[Double]] = []
        for p in 1...3 {
            var taps: [Double] = []
            taps.reserveCapacity(tapsPerPhase)
            var k = 0
            while 4 * k + p < length {
                taps.append(prototype[4 * k + p])
                k += 1
            }
            let sum = taps.reduce(0, +)
            phases.append(taps.map { $0 / sum })    // exact DC unity per phase
        }
        return phases
    }

    /// Zeroth-order modified Bessel function of the first kind (power series;
    /// converges in < 30 terms for the β values used here).
    private static func besselI0(_ x: Double) -> Double {
        let half = x / 2.0
        var term = 1.0
        var sum = 1.0
        var k = 1.0
        while k < 64 {
            term *= (half / k) * (half / k)
            sum += term
            if term < sum * 1e-16 { break }
            k += 1
        }
        return sum
    }

    /// Max |value| over original samples + the 3 interpolated phases, all
    /// channels, linear. Signal outside the buffer is taken as zero (edge
    /// taps see silence — exact for rendered material, which starts and ends
    /// at rest).
    static func truePeakLinear(_ channels: [[Float]]) -> Double {
        var maxAbs = 0.0
        for channel in channels {
            channel.withUnsafeBufferPointer { x in
                let count = x.count
                for f in 0..<count {
                    let v = abs(Double(x[f]))
                    if v > maxAbs { maxAbs = v }
                }
                for phase in interpolatorPhases {
                    phase.withUnsafeBufferPointer { g in
                        let taps = g.count
                        for m in 0..<(count + taps - 1) {
                            var acc = 0.0
                            var k = max(0, m - count + 1)
                            let kMax = min(taps - 1, m)
                            while k <= kMax {
                                acc += g[k] * Double(x[m - k])
                                k += 1
                            }
                            let v = abs(acc)
                            if v > maxAbs { maxAbs = v }
                        }
                    }
                }
            }
        }
        return maxAbs
    }
}

extension Loudness {
    /// `measure(_:)` off the caller's actor: identical result (pure function,
    /// determinism test-pinned), but the O(frames) work runs on the global
    /// concurrent executor so a long program never wedges the main actor
    /// (the m19-j residual). Explicit Task.detached — NOT a nonisolated async
    /// function — so the executor is pinned regardless of SE-0338 vs SE-0461
    /// (NonisolatedNonsendingByDefault) language-mode semantics.
    public static func measureDetached(_ audio: RenderedAudio) async -> LoudnessMeasurement {
        await Task.detached(priority: .userInitiated) { measure(audio) }.value
    }

    /// `applyGain(linear:)` + the mandatory re-measure fused into ONE unit off
    /// the caller's actor (m20-h): the in-place gain loop alone held the main
    /// actor ~1.1 s on a 162 s program (m20-f measurement), and fusing the
    /// re-measure avoids a second detached round-trip. Results are identical
    /// to the synchronous sequence (both deterministic; test-pinned exact).
    /// Explicit Task.detached — NOT a nonisolated async function — so the
    /// executor is pinned regardless of SE-0338 vs SE-0461
    /// (NonisolatedNonsendingByDefault) language-mode semantics.
    ///
    /// Ownership (SE-0377): the parameter is `consuming` and rides a
    /// single-owner handoff cell, so the buffer's ONLY reference crosses the
    /// hop and `applyGain`'s in-place no-copy contract survives — an ordinary
    /// escaping-closure capture would pin a second reference for the
    /// closure's whole run and force a full copy-on-write duplication of what
    /// may be a multi-hundred-MB buffer at the first mutated sample. Peak
    /// memory stays 1×; storage identity is test-pinned. Call it with
    /// `consume audio` and reassign the caller's binding from the returned
    /// pair.
    public static func applyGainAndMeasureDetached(
        _ audio: consuming RenderedAudio, linear gain: Float
    ) async -> (audio: RenderedAudio, measurement: LoudnessMeasurement) {
        let cell = GainHopCell(consume audio)
        let measurement = await Task.detached(priority: .userInitiated) {
            cell.audio.applyGain(linear: gain)
            return measure(cell.audio)
        }.value
        return (cell.audio, measurement)
    }

    /// Single-owner handoff cell for `applyGainAndMeasureDetached`: moves the
    /// one buffer reference into the detached task (class capture = pointer,
    /// not a value copy) and hands it back after the await.
    ///
    /// `@unchecked Sendable` justification: access is temporally exclusive by
    /// construction — the creating frame writes only in `init`, then never
    /// touches the cell again until `Task.detached`'s value has been awaited;
    /// task creation and task completion are the happens-before edges either
    /// side of the detached mutation. The type is private to this file so no
    /// other access pattern can exist.
    private final class GainHopCell: @unchecked Sendable {
        var audio: RenderedAudio
        init(_ audio: consuming RenderedAudio) { self.audio = audio }
    }
}
