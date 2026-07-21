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
    /// EBU Tech 3342 loudness range (LRA), LU (m22-c, additive): the spread
    /// (95th − 10th percentile) of the gated short-term loudness
    /// distribution — absolute gate −70 LUFS, then a relative gate 20 LU
    /// below the absolute-gated energy mean. nil = no short-term window
    /// survived the gates (program shorter than 3 s, or everything at/below
    /// −70 LUFS).
    public var loudnessRangeLu: Double?

    public init(integratedLufs: Double? = nil,
                truePeakDbtp: Double? = nil,
                maxMomentaryLufs: Double? = nil,
                maxShortTermLufs: Double? = nil,
                loudnessRangeLu: Double? = nil) {
        self.integratedLufs = integratedLufs
        self.truePeakDbtp = truePeakDbtp
        self.maxMomentaryLufs = maxMomentaryLufs
        self.maxShortTermLufs = maxShortTermLufs
        self.loudnessRangeLu = loudnessRangeLu
    }
}

/// One live master-bus loudness snapshot (m22-c): the streaming BS.1770-4 /
/// EBU 3341 + 3342 state of everything the master tap has fed the analyzer
/// since the last reset. Codable IS the wire shape (`mixer.liveLoudness`
/// carries it verbatim; wire-never-drifts; synthesized Codable omits nil
/// optionals). nil = NO EVIDENCE — never a fabricated 0 (JSON has no −inf):
/// momentary needs 400 ms of audio, short-term 3 s, integrated ≥ 1 block
/// above the −70 LUFS absolute gate, LRA ≥ 1 gated short-term window, and
/// the peak/crest/DC trio any non-silent signal. Signal below −200 dB
/// (beyond any audio path's physical floor) is float noise — a live
/// engine's decaying denormal tails, not program — and also reads as nil
/// rather than a "−3140 LUFS" absurdity. Agents must null-check.
///
/// RESET SEMANTICS (transport-independent by design): the running
/// integrated / LRA / maxima / true peak / DC / crest accumulate across
/// transport stop/start — pausing playback does NOT restart the program,
/// exactly like a hardware loudness meter left running (only fed samples
/// count; `secondsAnalyzed` is audio time, not wall clock). The program
/// starts over on `mixer.liveLoudness {reset:true}` or an engine
/// teardown/rebuild (project close, device change).
public struct LiveLoudnessSnapshot: Codable, Sendable, Equatable {
    /// EBU 3341 momentary loudness — the CURRENT (most recent) 400 ms
    /// block, LUFS, refreshed every 100 ms hop.
    public var momentaryLufs: Double?
    /// EBU 3341 short-term loudness — the CURRENT 3 s window, LUFS.
    public var shortTermLufs: Double?
    /// Loudest momentary block since reset, LUFS (ungated, the offline
    /// `maxMomentaryLufs` semantics).
    public var maxMomentaryLufs: Double?
    /// Loudest short-term window since reset, LUFS.
    public var maxShortTermLufs: Double?
    /// Running BS.1770-4 gated integrated loudness since reset, LUFS —
    /// re-gated over ALL blocks at every update, not an approximation.
    public var integratedLufs: Double?
    /// Running EBU 3342 loudness range since reset, LU. Statistically thin
    /// below ~1 min of program — read alongside `secondsAnalyzed`.
    public var loudnessRangeLu: Double?
    /// Running 4× oversampled true peak since reset, dBTP (BS.1770-4
    /// Annex 2, the same interpolator as the offline measurement).
    public var truePeakDbtp: Double?
    /// Mean sample value since reset of the channel with the largest DC
    /// magnitude, signed linear (−1…1). ≈ 0 for healthy audio; a sustained
    /// offset wastes headroom and thumps on edits.
    public var dcOffset: Double?
    /// Sample-peak-to-RMS crest factor since reset, dB (RAW sample peak
    /// over whole-program RMS — the conventional crest definition, NOT true
    /// peak). Low single digits = heavily limited; ~12–20 dB = dynamic.
    public var crestFactorDb: Double?
    /// Audio actually analyzed since reset, seconds (fed frames ÷ rate).
    public var secondsAnalyzed: Double

    public init(momentaryLufs: Double? = nil,
                shortTermLufs: Double? = nil,
                maxMomentaryLufs: Double? = nil,
                maxShortTermLufs: Double? = nil,
                integratedLufs: Double? = nil,
                loudnessRangeLu: Double? = nil,
                truePeakDbtp: Double? = nil,
                dcOffset: Double? = nil,
                crestFactorDb: Double? = nil,
                secondsAnalyzed: Double = 0) {
        self.momentaryLufs = momentaryLufs
        self.shortTermLufs = shortTermLufs
        self.maxMomentaryLufs = maxMomentaryLufs
        self.maxShortTermLufs = maxShortTermLufs
        self.integratedLufs = integratedLufs
        self.loudnessRangeLu = loudnessRangeLu
        self.truePeakDbtp = truePeakDbtp
        self.dcOffset = dcOffset
        self.crestFactorDb = crestFactorDb
        self.secondsAnalyzed = secondsAnalyzed
    }

    /// The no-evidence snapshot: fresh analyzer, just-reset, or an engine
    /// whose tap has not delivered yet.
    public static let empty = LiveLoudnessSnapshot()
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
/// spec §3). No Accelerate, no libebur128 — DAWCore stays dependency-free.
/// This enum is the ONE DSP home: the offline `measure(_:)` (~milliseconds
/// for a full song) and the live `Loudness.Stream` (m22-c, fed from the
/// master tap queue) share every formula below — neither ever touches the
/// render thread.
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
        // The per-window weighted mean squares are collected so LRA (EBU
        // 3342, m22-c) reads the SAME series the short-term maximum does.
        let hopsPerShortTerm = 30
        if hopCount >= hopsPerShortTerm {
            let windowFrames = Double(hopsPerShortTerm * hopFrames)
            var channelWindowEnergies = [Double](repeating: 0, count: hopEnergies.count)
            // Sliding sum per channel: O(hopCount) instead of O(hopCount·30).
            for (i, energies) in hopEnergies.enumerated() {
                for h in 0..<hopsPerShortTerm { channelWindowEnergies[i] += energies[h] }
            }
            var shortTermSeries: [Double] = []
            shortTermSeries.reserveCapacity(hopCount - hopsPerShortTerm + 1)
            var windowMeanSquare = windowWeightedMeanSquare(channelWindowEnergies,
                                                            windowFrames: windowFrames)
            shortTermSeries.append(windowMeanSquare)
            var maxShortTerm = loudness(fromWeightedMeanSquare: windowMeanSquare)
            // `hopCount == hopsPerShortTerm` means exactly one window fits
            // (already computed above) and there is nothing left to slide —
            // `1...0` is an invalid Range and must not be constructed.
            if hopCount > hopsPerShortTerm {
                for k in 1...(hopCount - hopsPerShortTerm) {
                    for (i, energies) in hopEnergies.enumerated() {
                        channelWindowEnergies[i] += energies[k + hopsPerShortTerm - 1] - energies[k - 1]
                    }
                    windowMeanSquare = windowWeightedMeanSquare(channelWindowEnergies,
                                                                windowFrames: windowFrames)
                    shortTermSeries.append(windowMeanSquare)
                    let value = loudness(fromWeightedMeanSquare: windowMeanSquare)
                    if value > maxShortTerm { maxShortTerm = value }
                }
            }
            if maxShortTerm.isFinite { result.maxShortTermLufs = maxShortTerm }
            if let range = loudnessRange(fromShortTermWeightedMeanSquares: shortTermSeries),
               range.isFinite {
                result.loudnessRangeLu = range
            }
        }

        // Gating (§3.2): absolute −70 LUFS, then relative (mean − 10 LU),
        // integrated over blocks passing BOTH — the ONE shared gating
        // implementation (`gatedIntegrated`, also driven live by `Stream`).
        if let integrated = gatedIntegrated(blockLoudness: blockLoudness,
                                            blockWeightedMeanSquares: blockWeightedMeanSquare) {
            result.integratedLufs = integrated
        }

        return result
    }

    // MARK: - Gating (§3.2) + loudness range (EBU 3342)

    /// BS.1770-4 §3.2 gated integration over a 400 ms block series: absolute
    /// −70 LUFS gate, then a single-pass relative gate 10 LU below the
    /// absolute-gated ENERGY mean. THE one gating implementation —
    /// `measure(_:)` (offline) and `Stream` (live, m22-c) both call it, so
    /// the two can never drift (live-vs-offline convergence is test-pinned
    /// bit-exact). nil when no block passes both gates.
    static func gatedIntegrated(blockLoudness: [Double],
                                blockWeightedMeanSquares: [Double]) -> Double? {
        let absoluteGateLufs = -70.0
        let absGated = blockLoudness.indices.filter { blockLoudness[$0] > absoluteGateLufs }
        guard !absGated.isEmpty else { return nil }
        let absMean = absGated.reduce(0.0) { $0 + blockWeightedMeanSquares[$1] }
            / Double(absGated.count)
        let relativeGateLufs = loudness(fromWeightedMeanSquare: absMean) - 10.0
        let gated = absGated.filter { blockLoudness[$0] > relativeGateLufs }
        guard !gated.isEmpty else { return nil }
        let mean = gated.reduce(0.0) { $0 + blockWeightedMeanSquares[$1] }
            / Double(gated.count)
        let integrated = loudness(fromWeightedMeanSquare: mean)
        return integrated.isFinite ? integrated : nil
    }

    /// EBU Tech 3342 loudness range from a chronological series of
    /// short-term (3 s) window weighted mean squares — the
    /// `windowWeightedMeanSquare` output, the SAME series the short-term
    /// maximum reads (offline and live feed identical series, so LRA
    /// converges bit-exactly). Gating per the spec: absolute −70 LUFS on
    /// the short-term loudness, then a relative gate 20 LU below the
    /// absolute-gated ENERGY mean; LRA = 95th − 10th percentile of the
    /// survivors. Percentile estimator: nearest rank on the sorted
    /// survivors, index = round(p·(n−1)) — the libebur128 convention, exact
    /// on the flat-plateau fixtures that pin this function. nil when
    /// nothing survives the gates.
    static func loudnessRange(fromShortTermWeightedMeanSquares series: [Double]) -> Double? {
        guard !series.isEmpty else { return nil }
        let absoluteGateLufs = -70.0
        var shortTermLoudness: [Double] = []
        shortTermLoudness.reserveCapacity(series.count)
        var absSum = 0.0
        var absCount = 0
        for meanSquare in series {
            let value = loudness(fromWeightedMeanSquare: meanSquare)
            shortTermLoudness.append(value)
            if value > absoluteGateLufs {
                absSum += meanSquare
                absCount += 1
            }
        }
        guard absCount > 0 else { return nil }
        let relativeGateLufs = loudness(fromWeightedMeanSquare: absSum / Double(absCount)) - 20.0
        var survivors: [Double] = []
        survivors.reserveCapacity(absCount)
        for value in shortTermLoudness
        where value > absoluteGateLufs && value > relativeGateLufs {
            survivors.append(value)
        }
        guard !survivors.isEmpty else { return nil }
        survivors.sort()
        let lastIndex = Double(survivors.count - 1)
        let low = survivors[Int((0.10 * lastIndex).rounded())]
        let high = survivors[Int((0.95 * lastIndex).rounded())]
        let range = high - low
        return range.isFinite ? range : nil
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

    /// Weighted mean square of one 3 s window from per-channel energy sums
    /// (`loudness(fromWeightedMeanSquare:)` of this IS the old
    /// `windowLoudness` — split so the LRA series can reuse the identical
    /// arithmetic; the composition is byte-identical to the pre-split code).
    private static func windowWeightedMeanSquare(_ channelEnergies: [Double],
                                                 windowFrames: Double) -> Double {
        var weightedSum = 0.0
        for (i, energy) in channelEnergies.enumerated() {
            weightedSum += channelWeight(i) * (energy / windowFrames)
        }
        return weightedSum
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

// MARK: - Live streaming analyzer (m22-c)

extension Loudness {
    /// Streaming BS.1770-4 / EBU 3341 + 3342 loudness engine: the SAME
    /// K-weighting, block/window, gating, LRA, and true-peak math as
    /// `measure(_:)` — literally the same helpers in this file
    /// (`kWeightingStages`, `channelWeight`, `loudness(fromWeightedMeanSquare:)`,
    /// `gatedIntegrated`, `loudnessRange`, `interpolatorPhases`) —
    /// restructured for chunked feeding. Convergence is test-pinned: fed the
    /// same program (chunked arbitrarily, plus ≥ 31 trailing zero frames so
    /// the 4× interpolator's tail matches the offline zero-padded edge, on a
    /// hop-aligned program), integrated / maxima / LRA / true peak equal the
    /// offline `measure(_:)` to fp-identity.
    ///
    /// THREADING (`@unchecked Sendable`): `process*`, `snapshot()`, and
    /// `reset()` must run on ONE thread at a time — in the engine that is
    /// AVFAudio's serial tap queue (the MasterMixAnalyzer contract; the
    /// engine's `LiveLoudnessAnalyzer` wrapper adds the atomic reset
    /// handshake for the main actor).
    ///
    /// MEMORY: the per-sample and per-hop paths touch only preallocated
    /// state. The block/window history arrays grow by 10 elements/second
    /// (amortized append, ~1 MB/hour, capacity pre-reserved for an hour) and
    /// the gating + LRA recompute — the only allocating work — runs at most
    /// once per 100 ms hop, never per buffer, so the tap queue's ~21 ms
    /// cadence is never back-pressured. Denormals are left alone on purpose:
    /// `measure(_:)` does not flush them either (bit-exactness) and Double
    /// denormal arithmetic carries no penalty on Apple Silicon.
    ///
    /// NaN/Inf inputs are sanitized to 0 at the door (a live tap must never
    /// poison hours of running state); published fields additionally pass
    /// `isFinite` guards, so the wire never carries NaN/Inf.
    public final class Stream: @unchecked Sendable {

        /// EBU 3341 geometry, shared with `measure(_:)`: 100 ms hops,
        /// 4 hops per 400 ms momentary block, 30 per 3 s short-term window.
        static let hopsPerBlock = 4
        static let hopsPerShortTerm = 30
        /// Hop-energy ring capacity per channel: must exceed
        /// `hopsPerShortTerm` (the sliding window subtracts e[h−30] while
        /// h is newest). 32 = the next power of two, cheap masking.
        private static let ringSize = 32
        /// One hour of 10 Hz history pre-reserved so steady-state appends
        /// never reallocate inside a session of ordinary length.
        private static let reservedHistory = 36_000

        public let sampleRate: Double
        public let channelCount: Int

        private let hopFrames: Int
        private let blockFrames: Double
        private let windowFrames: Double
        private let shelf: Biquad
        private let highPass: Biquad

        /// Per-channel filter + accumulator state (fixed size, value types).
        private struct ChannelState {
            var sx1 = 0.0, sx2 = 0.0, sy1 = 0.0, sy2 = 0.0
            var hx1 = 0.0, hx2 = 0.0, hy1 = 0.0, hy2 = 0.0
            var hopAccumulator = 0.0
            var shortTermWindowSum = 0.0
            var dcSum = 0.0
            /// Per-channel so the accumulation order is the channel's own
            /// sample order regardless of chunking (chunking invariance is
            /// test-pinned exact); combined across channels only in
            /// `snapshot()`, in fixed channel order.
            var sumSquares = 0.0
        }
        private var channelStates: [ChannelState]
        /// Hop-energy history, `channel * ringSize + (hopIndex & 31)`.
        private var hopEnergyRing: [Double]
        /// True-peak delay line per channel, DOUBLE-WRITTEN (`2 * ringSize`
        /// per channel): each sample is stored at `slot` and `slot +
        /// ringSize`, so `history[slot + k]` for k = 0..<taps is ALWAYS one
        /// contiguous newest-to-oldest walk — each phase's dot product is a
        /// sequential ascending-k loop (the exact `truePeakLinear` order)
        /// with no per-tap wrap math.
        private var truePeakHistory: [Double]
        /// Newest-sample slot per channel (0..<ringSize, decrementing).
        private var truePeakSlot: [Int]
        /// `interpolatorPhases` flattened to 3 × 32 for the hot loop; tap
        /// ORDER per phase is preserved so sums match `truePeakLinear`.
        private let flatPhases: [Double]
        private let tapsPerPhase: Int

        private var hopFill = 0
        private var completedHops = 0
        private var framesSeen = 0

        // Growing 10 Hz history (chronological, exactly measure()'s series).
        private var blockWeightedMeanSquares: [Double] = []
        private var blockLoudnessValues: [Double] = []
        private var shortTermWeightedMeanSquares: [Double] = []

        // Running outputs.
        private var currentMomentary = -Double.infinity
        private var currentShortTerm = -Double.infinity
        private var maxMomentary = -Double.infinity
        private var maxShortTerm = -Double.infinity
        private var truePeakAbs = 0.0
        private var rawPeakAbs = 0.0

        /// Gating + LRA memoization: recomputed in `snapshot()` only when a
        /// new block/window landed since the last recompute (≤ 10 Hz).
        private var gatedDirty = false
        private var cachedIntegrated: Double?
        private var cachedRange: Double?

        /// `sampleRate`/`channelCount` degenerate inputs fall back to
        /// 48 kHz stereo — a live analyzer must never trap on a broken
        /// format (the MasterMixAnalyzer convention).
        public init(sampleRate: Double, channelCount: Int) {
            let rate = sampleRate > 0 ? sampleRate : 48_000
            self.sampleRate = rate
            self.channelCount = max(1, channelCount)
            self.hopFrames = max(1, Int((0.1 * rate).rounded()))
            self.blockFrames = Double(Stream.hopsPerBlock * hopFrames)
            self.windowFrames = Double(Stream.hopsPerShortTerm * hopFrames)
            let stages = Loudness.kWeightingStages(sampleRate: rate)
            self.shelf = stages.shelf
            self.highPass = stages.highPass
            self.channelStates = [ChannelState](repeating: ChannelState(),
                                                count: self.channelCount)
            self.hopEnergyRing = [Double](repeating: 0,
                                          count: self.channelCount * Stream.ringSize)
            self.truePeakHistory = [Double](repeating: 0,
                                            count: self.channelCount * 2 * Stream.ringSize)
            self.truePeakSlot = [Int](repeating: 0, count: self.channelCount)
            let phases = Loudness.interpolatorPhases
            self.tapsPerPhase = phases[0].count
            self.flatPhases = phases.flatMap { $0 }
            blockWeightedMeanSquares.reserveCapacity(Stream.reservedHistory)
            blockLoudnessValues.reserveCapacity(Stream.reservedHistory)
            shortTermWeightedMeanSquares.reserveCapacity(Stream.reservedHistory)
        }

        // MARK: Feeding

        /// Feed a deinterleaved float buffer (the `floatChannelData` shape).
        /// Channels beyond `channelCount` are ignored; missing channels read
        /// as silence. Splits at hop boundaries so block/window/gating
        /// updates land once per completed 100 ms hop.
        public func process(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                            channelCount bufferChannels: Int,
                            frameCount: Int) {
            guard frameCount > 0, bufferChannels > 0 else { return }
            var offset = 0
            var remaining = frameCount
            while remaining > 0 {
                let take = min(hopFrames - hopFill, remaining)
                for channel in 0..<channelCount {
                    if channel < bufferChannels {
                        processRun(channel: channel,
                                   samples: channels[channel] + offset,
                                   count: take)
                    } else {
                        processSilentRun(channel: channel, count: take)
                    }
                }
                hopFill += take
                offset += take
                remaining -= take
                framesSeen += take
                if hopFill == hopFrames {
                    completeHop()
                    hopFill = 0
                }
            }
        }

        /// Array convenience for tests / offline feeding. Copies into
        /// temporary contiguous buffers (allocates — never used on the tap
        /// path). Frames beyond the shortest channel are dropped.
        public func process(_ chunk: [[Float]]) {
            guard !chunk.isEmpty else { return }
            let frames = chunk.map(\.count).min() ?? 0
            guard frames > 0 else { return }
            let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
                .allocate(capacity: chunk.count)
            defer { pointers.deallocate() }
            for (index, channel) in chunk.enumerated() {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                channel.withUnsafeBufferPointer {
                    buffer.update(from: $0.baseAddress!, count: frames)
                }
                pointers[index] = buffer
            }
            defer { for index in 0..<chunk.count { pointers[index].deallocate() } }
            process(channels: pointers, channelCount: chunk.count, frameCount: frames)
        }

        /// One channel's samples through K-weighting (hop energy), the 4×
        /// true-peak interpolator, and the DC/crest accumulators. The exact
        /// per-sample expressions of `kWeightedHopEnergies` and
        /// `truePeakLinear`, state carried across chunks.
        ///
        /// HOT-LOOP SHAPE IS LOAD-BEARING: raw `UnsafeMutablePointer`
        /// arithmetic and `while` loops ONLY — no Range iteration, no Array
        /// subscripts, no per-sample closures. The tap queue runs this in
        /// DEBUG builds too (the test suite), where `for k in 0..<n` costs
        /// generic-metadata lookups PER ITERATION; at ~100 ops/sample that
        /// saturated AVFAudio's RealtimeMessenger queue and deadlocked
        /// `AVAudioNode` teardown (`sample(1)`-diagnosed). Pointer loads/
        /// stores and Double arithmetic compile to direct instructions even
        /// at -Onone. Summation orders are unchanged (bit-exactness with
        /// `measure(_:)` stays test-pinned).
        private func processRun(channel: Int, samples: UnsafePointer<Float>, count: Int) {
            guard count > 0 else { return }
            var state = channelStates[channel]
            let historyBase = channel * 2 * Stream.ringSize
            var slot = truePeakSlot[channel]
            var localRawPeak = rawPeakAbs
            var localTruePeak = truePeakAbs
            let taps = tapsPerPhase
            let s = shelf
            let h = highPass
            flatPhases.withUnsafeBufferPointer { phaseTaps in
                truePeakHistory.withUnsafeMutableBufferPointer { historyBuffer in
                    let g = phaseTaps.baseAddress!
                    let history = historyBuffer.baseAddress! + historyBase
                    // Filter/accumulator state in locals for the whole run.
                    var sx1 = state.sx1, sx2 = state.sx2, sy1 = state.sy1, sy2 = state.sy2
                    var hx1 = state.hx1, hx2 = state.hx2, hy1 = state.hy1, hy2 = state.hy2
                    var hopAccumulator = state.hopAccumulator
                    var dcSum = state.dcSum
                    var sumSquares = state.sumSquares
                    var frame = 0
                    while frame < count {
                        let raw = Double(samples[frame])
                        let x = raw.isFinite ? raw : 0

                        // K-weighting cascade (kWeightedHopEnergies verbatim).
                        let y = s.b0 * x + s.b1 * sx1 + s.b2 * sx2
                            - s.a1 * sy1 - s.a2 * sy2
                        sx2 = sx1; sx1 = x
                        sy2 = sy1; sy1 = y
                        let z = h.b0 * y + h.b1 * hx1 + h.b2 * hx2
                            - h.a1 * hy1 - h.a2 * hy2
                        hx2 = hx1; hx1 = y
                        hy2 = hy1; hy1 = z
                        hopAccumulator += z * z

                        // DC + crest accumulators (raw domain).
                        dcSum += x
                        sumSquares += x * x
                        let magnitude = abs(x)
                        if magnitude > localRawPeak { localRawPeak = magnitude }
                        if magnitude > localTruePeak { localTruePeak = magnitude }

                        // 4× true peak: newest sample into the double-write
                        // delay line, then each phase's 32-tap dot product as
                        // ONE contiguous ascending-k walk — the SAME
                        // newest-to-oldest order truePeakLinear uses (history
                        // zeros reproduce the offline zero-padded edge).
                        slot = slot == 0 ? Stream.ringSize - 1 : slot - 1
                        history[slot] = x
                        history[slot + Stream.ringSize] = x
                        let window = history + slot
                        var phase = 0
                        while phase < 3 {
                            var acc = 0.0
                            let phaseBase = g + phase * taps
                            var k = 0
                            while k < taps {
                                acc += phaseBase[k] * window[k]
                                k += 1
                            }
                            let interpolated = abs(acc)
                            if interpolated > localTruePeak { localTruePeak = interpolated }
                            phase += 1
                        }
                        frame += 1
                    }
                    state.sx1 = sx1; state.sx2 = sx2; state.sy1 = sy1; state.sy2 = sy2
                    state.hx1 = hx1; state.hx2 = hx2; state.hy1 = hy1; state.hy2 = hy2
                    state.hopAccumulator = hopAccumulator
                    state.dcSum = dcSum
                    state.sumSquares = sumSquares
                }
            }
            channelStates[channel] = state
            truePeakSlot[channel] = slot
            rawPeakAbs = localRawPeak
            truePeakAbs = localTruePeak
        }

        /// A missing channel reads as digital silence — same state advance
        /// (filter/interpolator tails ring out), zero input.
        private func processSilentRun(channel: Int, count: Int) {
            var zeros = [Float](repeating: 0, count: count)
            zeros.withUnsafeMutableBufferPointer { buffer in
                processRun(channel: channel, samples: buffer.baseAddress!, count: count)
            }
        }

        /// A 100 ms hop just completed on every channel: push energies into
        /// the ring, slide the short-term window, and land the new momentary
        /// block / short-term window exactly as `measure(_:)` does.
        private func completeHop() {
            let hopIndex = completedHops
            completedHops += 1
            let hops = completedHops
            let mask = Stream.ringSize - 1

            for channel in 0..<channelCount {
                let energy = channelStates[channel].hopAccumulator
                channelStates[channel].hopAccumulator = 0
                let ringBase = channel * Stream.ringSize
                hopEnergyRing[ringBase + (hopIndex & mask)] = energy
                if hops <= Stream.hopsPerShortTerm {
                    // measure()'s initial window: += e[h] in hop order.
                    channelStates[channel].shortTermWindowSum += energy
                } else {
                    // measure()'s slide: += (e[k+29] − e[k−1]), one expression.
                    channelStates[channel].shortTermWindowSum += energy
                        - hopEnergyRing[ringBase + ((hopIndex - Stream.hopsPerShortTerm) & mask)]
                }
            }

            if hops >= Stream.hopsPerBlock {
                let blockStart = hops - Stream.hopsPerBlock
                var weightedSum = 0.0
                for channel in 0..<channelCount {
                    let ringBase = channel * Stream.ringSize
                    // Left-to-right sum of 4 hops — measure()'s expression.
                    let energy = hopEnergyRing[ringBase + (blockStart & mask)]
                        + hopEnergyRing[ringBase + ((blockStart + 1) & mask)]
                        + hopEnergyRing[ringBase + ((blockStart + 2) & mask)]
                        + hopEnergyRing[ringBase + ((blockStart + 3) & mask)]
                    weightedSum += Loudness.channelWeight(channel) * (energy / blockFrames)
                }
                let blockValue = Loudness.loudness(fromWeightedMeanSquare: weightedSum)
                blockWeightedMeanSquares.append(weightedSum)
                blockLoudnessValues.append(blockValue)
                currentMomentary = blockValue
                if blockValue > maxMomentary { maxMomentary = blockValue }
                gatedDirty = true
            }

            if hops >= Stream.hopsPerShortTerm {
                var weightedSum = 0.0
                for channel in 0..<channelCount {
                    // windowWeightedMeanSquare's expression, channel order.
                    weightedSum += Loudness.channelWeight(channel)
                        * (channelStates[channel].shortTermWindowSum / windowFrames)
                }
                let windowValue = Loudness.loudness(fromWeightedMeanSquare: weightedSum)
                shortTermWeightedMeanSquares.append(weightedSum)
                currentShortTerm = windowValue
                if windowValue > maxShortTerm { maxShortTerm = windowValue }
                gatedDirty = true
            }
        }

        // MARK: Snapshot / reset

        /// Wire floor for the ungated EBU 3341 fields + true peak: below
        /// −200 dB nothing is audio — real paths bottom out ≈ −150 dB
        /// (24-bit dither ≈ −147 LUFS), while a live engine's decaying
        /// denormal tails land around −600…−3000 dB and would otherwise
        /// ride the wire as finite "−3140 LUFS" absurdities (the offline
        /// gates at −70 LUFS already stop them for integrated/LRA). Below
        /// the floor = float noise = no evidence = nil.
        private static let noiseFloorDb = -200.0
        /// `10^(noiseFloorDb / 20)` — the same floor as an amplitude.
        private static let noiseFloorAmplitude = 1e-10

        /// The current running measurement. Recomputes gated integrated +
        /// LRA only when a new block/window landed (≤ 10 Hz); every field
        /// passes an `isFinite` guard AND the −200 dB float-noise floor —
        /// nil means no evidence, never NaN, never a denormal-tail reading.
        public func snapshot() -> LiveLoudnessSnapshot {
            if gatedDirty {
                cachedIntegrated = Loudness.gatedIntegrated(
                    blockLoudness: blockLoudnessValues,
                    blockWeightedMeanSquares: blockWeightedMeanSquares)
                cachedRange = Loudness.loudnessRange(
                    fromShortTermWeightedMeanSquares: shortTermWeightedMeanSquares)
                gatedDirty = false
            }
            var snap = LiveLoudnessSnapshot(secondsAnalyzed: Double(framesSeen) / sampleRate)
            if currentMomentary.isFinite, currentMomentary > Stream.noiseFloorDb {
                snap.momentaryLufs = currentMomentary
            }
            if currentShortTerm.isFinite, currentShortTerm > Stream.noiseFloorDb {
                snap.shortTermLufs = currentShortTerm
            }
            if maxMomentary.isFinite, maxMomentary > Stream.noiseFloorDb {
                snap.maxMomentaryLufs = maxMomentary
            }
            if maxShortTerm.isFinite, maxShortTerm > Stream.noiseFloorDb {
                snap.maxShortTermLufs = maxShortTerm
            }
            if let integrated = cachedIntegrated, integrated.isFinite {
                snap.integratedLufs = integrated
            }
            if let range = cachedRange, range.isFinite {
                snap.loudnessRangeLu = range
            }
            if truePeakAbs > Stream.noiseFloorAmplitude {
                let dbtp = 20.0 * log10(truePeakAbs)
                if dbtp.isFinite { snap.truePeakDbtp = dbtp }
            }
            if framesSeen > 0 {
                var worstDC = 0.0
                for channel in 0..<channelCount {
                    let mean = channelStates[channel].dcSum / Double(framesSeen)
                    if abs(mean) > abs(worstDC) { worstDC = mean }
                }
                if worstDC.isFinite { snap.dcOffset = worstDC }
                var sumSquares = 0.0
                for channel in 0..<channelCount {
                    sumSquares += channelStates[channel].sumSquares
                }
                if rawPeakAbs > Stream.noiseFloorAmplitude, sumSquares > 0 {
                    let rms = (sumSquares / Double(framesSeen * channelCount)).squareRoot()
                    if rms > 0 {
                        let crest = 20.0 * log10(rawPeakAbs / rms)
                        if crest.isFinite { snap.crestFactorDb = crest }
                    }
                }
            }
            return snap
        }

        /// Back to the fresh state: the next snapshot is `.empty` until new
        /// audio lands. Same single-thread contract as `process`.
        public func reset() {
            for channel in 0..<channelCount { channelStates[channel] = ChannelState() }
            for index in hopEnergyRing.indices { hopEnergyRing[index] = 0 }
            for index in truePeakHistory.indices { truePeakHistory[index] = 0 }
            for channel in 0..<channelCount { truePeakSlot[channel] = 0 }
            hopFill = 0
            completedHops = 0
            framesSeen = 0
            blockWeightedMeanSquares.removeAll(keepingCapacity: true)
            blockLoudnessValues.removeAll(keepingCapacity: true)
            shortTermWeightedMeanSquares.removeAll(keepingCapacity: true)
            currentMomentary = -.infinity
            currentShortTerm = -.infinity
            maxMomentary = -.infinity
            maxShortTerm = -.infinity
            truePeakAbs = 0
            rawPeakAbs = 0
            gatedDirty = false
            cachedIntegrated = nil
            cachedRange = nil
        }
    }
}
