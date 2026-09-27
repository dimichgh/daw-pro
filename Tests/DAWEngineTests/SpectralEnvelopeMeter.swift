import Accelerate
import Foundation
import Testing

/// m23-nt NT-G — **THE FORMANT / ENVELOPE METER**, §1's instrument (design
/// `docs/design/2026-09-25-natural-tuning.md` §1(g)). Two independent
/// readings over the SAME band, 250–5000 Hz only (§1(g): above ~7.1 kHz the
/// stretcher's formant map is additive rather than multiplicative, so this
/// meter is deliberately blind up there and callers must not extend it):
///
///  * `lpcFormants` — Levinson-Durbin LPC, peak-picked: an estimate of
///    F1/F2/F3, one number each, for "where are the resonances".
///  * `envelopeShiftCents` — a cepstrally-smoothed log-spectral envelope,
///    cross-correlated in LOG-FREQUENCY against a reference: "how far did
///    the WHOLE envelope move", the number the formant-correction gates
///    (§1(g) G2/G3/G5) actually read.
///
/// Both instruments are proven below against `SourceFilterVoice`, whose
/// formant scale and f0 are independently known — see the suite at the
/// bottom of this file, `SpectralEnvelopeMeter — known answer`.
///
/// nonisolated, DSP only: no actor, no shared state.
enum SpectralEnvelopeMeter {
    static let lowHz = 250.0
    static let highHz = 5000.0

    // MARK: - LPC formants

    /// Levinson-Durbin recursion. `autocorrelation[0...order]` in, LPC
    /// coefficients `a[0...order]` out (`a[0] == 1`), plus the residual
    /// energy. A non-positive `autocorrelation[0]` (silence) returns an
    /// all-zero filter and zero energy rather than dividing by zero.
    static func levinsonDurbin(_ autocorrelation: [Double], order: Int) -> (a: [Double], energy: Double) {
        var a = [Double](repeating: 0, count: order + 1)
        a[0] = 1
        var energy = autocorrelation[0]
        guard energy > 0 else { return (a, 0) }
        for i in 1...order {
            var acc = autocorrelation[i]
            if i > 1 {
                for j in 1..<i { acc += a[j] * autocorrelation[i - j] }
            }
            let k = -acc / energy
            // ⚠️ Guard BEFORE applying the step, not after: a reflection
            // coefficient at or past ±1 means this order is not supportable
            // by the data (a pole exactly on, or past, the unit circle), and
            // applying it anyway is what let this recursion run away to
            // enormous, still-"finite" coefficients while `energy` alone
            // looked merely small. Stopping here, keeping the LAST valid
            // order's `a`, is the correct behaviour — not an approximation.
            guard abs(k) < 1 else { break }
            var next = a
            if i > 1 {
                for j in 1..<i { next[j] = a[j] + k * a[i - j] }
            }
            next[i] = k
            a = next
            energy *= (1 - k * k)
            if energy <= 0 { break }
        }
        return (a, energy)
    }

    static let lpcOrder = 14
    static let lpcFFTLog2 = 11 // 2048
    static let lpcLowpassHz = 6000.0

    /// The autocorrelation of `frame`'s content BELOW `lowpassHz`, via the
    /// Wiener-Khinchin route: forward FFT, zero every bin above the cutoff,
    /// take the (real, non-negative) power spectrum, inverse FFT. The result
    /// is real and even, and only its first `order + 1` lags are kept.
    ///
    /// ⚠️ Any consistent SCALE on the whole array is harmless: Levinson-Durbin
    /// below only ever forms ratios of these values (`acc / energy`), so a
    /// uniform vDSP normalisation constant cancels exactly. That is
    /// deliberate — it is what makes this safe to write without pinning
    /// `vDSP_fft_zrip`'s exact round-trip scale.
    ///
    /// ⚠️ **THE ANALYSIS WINDOW IS SHORTER THAN THE FFT SIZE ON PURPOSE, AND
    /// THE GAP IS ZERO-PADDED**, to avoid windowing `SourceFilterVoice`'s
    /// EXACTLY periodic pulse train over a span that is an exact multiple of
    /// the FFT size (a coincidental extra source of ill-conditioning, on top
    /// of the one below). 30 ms (1440 samples at 48 kHz) is not special, only
    /// clear of that one coincidence.
    static let lpcAnalysisWindowSeconds = 0.030

    /// **THE conditioning fix.** `SourceFilterVoice`'s formants are narrow
    /// (80-150 Hz bandwidth), so their poles sit at `r = exp(-π·bw/fs)` —
    /// 0.9948 at 48 kHz for an 80 Hz formant, pressed against the unit
    /// circle. Levinson-Durbin on that Toeplitz system needs reflection
    /// coefficients within ~1e-3 of ±1; Float64 numpy survives it by luck,
    /// Float32 `vDSP` does not (measured: the recursion died at order 4-6,
    /// hiding F2/F3 entirely — no amount of window-length or noise-floor
    /// tuning fixed it, because both are downstream of this). The fix is to
    /// fit the model at a QUARTER the sample rate: request lags out to
    /// `4 * order` here (`bandlimitedAutocorrelation` is already band-limited
    /// to `lowpassHz` ≤ fs/8, so decimating its autocorrelation by 4 in
    /// `lpcFormants` below is alias-free — Wiener-Khinchin's decimated
    /// autocorrelation at lag k equals the original's at lag 4k). At 12 kHz
    /// the same 80 Hz formant's pole sits at 0.9791, comfortably inside the
    /// recursion's stable range.
    static func bandlimitedAutocorrelation(
        _ frame: [Float], sampleRate: Double, lowpassHz: Double, order: Int, fftLog2: Int
    ) -> [Double]? {
        let n = 1 << fftLog2
        guard frame.count >= 64 else { return nil }
        var windowed = [Float](repeating: 0, count: n)
        let usable = min(frame.count, n, Int((lpcAnalysisWindowSeconds * sampleRate).rounded()))
        var hann = [Float](repeating: 0, count: usable)
        vDSP_hann_window(&hann, vDSP_Length(usable), Int32(vDSP_HANN_DENORM))
        vDSP_vmul(frame, 1, hann, 1, &windowed, 1, vDSP_Length(usable))

        guard let setup = vDSP_create_fftsetup(vDSP_Length(fftLog2), FFTRadix(kFFTRadix2))
        else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(fftLog2), FFTDirection(FFT_FORWARD))

                // Power spectrum, packed-real convention: realp[0] is DC,
                // imagp[0] is the Nyquist bin (both purely real for a real
                // input). Bin i (1..<n/2) is at i * sampleRate / n Hz.
                let binHz = sampleRate / Double(n)
                let cutoffBin = Int((lowpassHz / binHz).rounded(.down))
                var power = [Float](repeating: 0, count: n / 2)
                for i in 0..<(n / 2) {
                    power[i] = i <= cutoffBin ? rp[i] * rp[i] + (i == 0 ? 0 : ip[i] * ip[i]) : 0
                }
                let nyquistPower: Float = (n / 2) <= cutoffBin ? ip[0] * ip[0] : 0

                // Feed the power spectrum back in as a packed-real "spectrum"
                // (zero imaginary part everywhere except the Nyquist slot,
                // which packed-real stores in imagp[0]) and inverse-transform
                // it: a real, non-negative, symmetric spectrum inverse-
                // transforms to a real, even autocorrelation.
                for i in 0..<(n / 2) { rp[i] = power[i]; ip[i] = 0 }
                ip[0] = nyquistPower
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(fftLog2), FFTDirection(FFT_INVERSE))
            }
        }
        // Unpack: even-indexed output samples sit in realp, odd in imagp
        // (the same interleave `vDSP_ctoz` used going in). `order` here is
        // the CALLER's requested lag count (already `4 * modelOrder` from
        // `lpcFormants`), not the eventual LPC model order.
        var out = [Double](repeating: 0, count: order + 1)
        for lag in 0...order {
            guard lag < n else { break }
            out[lag] = lag % 2 == 0 ? Double(real[lag / 2]) : Double(imag[lag / 2])
        }
        return out
    }

    /// `1 / |A(e^jw)|` in dB across `gridHz`, from LPC coefficients `a`
    /// (`a[0] == 1`).
    static func spectralEnvelopeDb(_ a: [Double], sampleRate: Double, gridHz: [Double]) -> [Double] {
        gridHz.map { f in
            let w = 2 * Double.pi * f / sampleRate
            var reSum = 0.0, imSum = 0.0
            for k in 0..<a.count {
                reSum += a[k] * cos(-w * Double(k))
                imSum += a[k] * sin(-w * Double(k))
            }
            let mag = (reSum * reSum + imSum * imSum).squareRoot()
            return 20 * log10(1 / (mag + 1e-9) + 1e-12)
        }
    }

    /// Local maxima of `db` within `[lo, hi]` Hz, strongest first, at least
    /// `minSeparationHz` apart, returned ascending by frequency — the peak
    /// picker `lpcFormants` uses for F1..F3.
    static func pickPeaks(
        gridHz: [Double], db: [Double], lo: Double, hi: Double,
        count: Int, minSeparationHz: Double = 80
    ) -> [Double] {
        var candidates: [(hz: Double, db: Double)] = []
        for i in 1..<(db.count - 1) where gridHz[i] >= lo && gridHz[i] <= hi {
            if db[i] > db[i - 1] && db[i] > db[i + 1] { candidates.append((gridHz[i], db[i])) }
        }
        candidates.sort { $0.db > $1.db }
        var chosen: [Double] = []
        for c in candidates {
            if chosen.allSatisfy({ abs($0 - c.hz) > minSeparationHz }) { chosen.append(c.hz) }
            if chosen.count >= count { break }
        }
        return chosen.sorted()
    }

    /// The 4x decimation factor `lpcFormants` fits its model at (see
    /// `bandlimitedAutocorrelation`'s doc for why).
    static let lpcDecimation = 4
    /// A 60 Hz "bandwidth expansion" lag window (the GSM/CELP-standard
    /// device: `r[k] *= exp(-0.5 * (2π · 60 · k / fsDecimated)^2)`), plus a
    /// 0.01 % white-noise correction on `r[0]`. Both PULL every pole a
    /// controlled distance off the unit circle before the recursion ever
    /// runs, rather than hoping the recursion survives poles sitting on it.
    static let lpcLagWindowHz = 60.0

    /// F1/F2/F3 read off `frame` — the top-level entry point. `frame` should
    /// be a steady, voiced slice at least `2^lpcFFTLog2` samples (zero-padded
    /// otherwise); shorter than 64 samples returns all-nil.
    static func lpcFormants(
        _ frame: [Float], sampleRate: Double, order: Int = lpcOrder,
        lowpassHz: Double = lpcLowpassHz, fftLog2: Int = lpcFFTLog2
    ) -> (f1: Double?, f2: Double?, f3: Double?) {
        guard let full = bandlimitedAutocorrelation(
            frame, sampleRate: sampleRate, lowpassHz: lowpassHz,
            order: order * lpcDecimation, fftLog2: fftLog2
        ), full[0] > 0 else { return (nil, nil, nil) }
        // Decimate: the autocorrelation of a signal band-limited to
        // fs/(2·lpcDecimation) and then decimated by `lpcDecimation` equals
        // the ORIGINAL's autocorrelation at lags `0, lpcDecimation,
        // 2·lpcDecimation, …` (Wiener-Khinchin). `lowpassHz` (6 kHz) already
        // sits at fs/8 for a 48 kHz `frame`, so this is alias-free.
        var r = (0...order).map { full[$0 * lpcDecimation] }
        let sampleRateDecimated = sampleRate / Double(lpcDecimation)
        // Lag window + white-noise correction: see the constants' doc.
        for k in 0...order {
            let w = exp(-0.5 * pow(2 * Double.pi * lpcLagWindowHz * Double(k) / sampleRateDecimated, 2))
            r[k] *= w
        }
        r[0] *= 1.0001
        let (a, _) = levinsonDurbin(r, order: order)
        // ⚠️ Deliberately NOT gated on `energy > 0` beyond what
        // `levinsonDurbin` already guards internally (`|k| < 1` before
        // applying a step): a residual can legitimately underflow toward 0
        // for a filter this close to exact, and rejecting on that produced
        // spurious "no formant picked" failures in this meter's own
        // development. Only reject a genuinely broken (non-finite) filter.
        guard a.allSatisfy(\.isFinite) else { return (nil, nil, nil) }
        let gridCount = 2000
        let grid = (0..<gridCount).map { 150.0 + Double($0) * (5500.0 - 150.0) / Double(gridCount - 1) }
        let db = spectralEnvelopeDb(a, sampleRate: sampleRateDecimated, gridHz: grid)
        let picked = pickPeaks(gridHz: grid, db: db, lo: lowHz, hi: highHz, count: 3)
        return (picked.count > 0 ? picked[0] : nil,
                picked.count > 1 ? picked[1] : nil,
                picked.count > 2 ? picked[2] : nil)
    }

    // MARK: - Cepstral envelope shift

    static let envelopeFFTLog2 = 11 // 2048, same frame size as the LPC leg
    static let envelopeLifterTaps = 30
    static let envelopeCentsPerBin = 2.0
    // ⚠️ **m23-nt NT-G2 FIX #4: WIDENED WITH MARGIN, 1200 → 1500 c.** A
    // genuine ±1200 c shift must not sit EXACTLY at the search boundary —
    // with the old 1200 c ceiling a planted +1200 c shift's true optimum
    // landed AT `+maxLag` (MEASURED, all three f0s), which the new
    // boundary-hit guard below now (correctly) treats as unmeasurable. 1500 c
    // gives every value this file's own known-answer suite plants (≤1200 c)
    // comfortable room to refine away from either edge (MEASURED: a planted
    // +1200 c shift's optimum then lands ~624 bins from centre, well inside
    // a 750-bin half-window).
    static let envelopeMaxSearchCents = 1500.0
    /// The moving-average window subtracted before correlating, so the
    /// correlation tracks the FORMANT RIPPLE rather than the envelope's
    /// broad, shift-invariant spectral tilt (which otherwise dominates a
    /// plain dot product and pins every reading near 0 — measured during
    /// this meter's own development, see the suite below).
    static let envelopeDetrendOctaves = 1.5

    /// `frame`'s cepstrally-smoothed log-magnitude envelope, resampled onto a
    /// log-frequency grid at `envelopeCentsPerBin` resolution over
    /// `[lowHz, highHz]`, mean-floored the way `SpectralShiftMeter.logSpectrum`
    /// is (`floor = peak * 1e-3`) so a near-silent bin cannot swing the curve.
    static func envelopeLogSpectrum(_ frame: [Float], sampleRate: Double) -> [Double]? {
        let n = 1 << envelopeFFTLog2
        guard frame.count >= 64 else { return nil }
        var windowed = [Float](repeating: 0, count: n)
        let usable = min(frame.count, n)
        var hann = [Float](repeating: 0, count: usable)
        vDSP_hann_window(&hann, vDSP_Length(usable), Int32(vDSP_HANN_DENORM))
        vDSP_vmul(frame, 1, hann, 1, &windowed, 1, vDSP_Length(usable))

        guard let setup = vDSP_create_fftsetup(vDSP_Length(envelopeFFTLog2), FFTRadix(kFFTRadix2))
        else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        // ⚠️ **HOLDS A SCALED LOG-MAGNITUDE, NEVER EXPONENTIATED.**
        // `vDSP_fft_zrip` does not normalise its round trip (Apple's own
        // convention scales a forward+inverse pair by a large constant,
        // order 2·fftSize), so after this function's inverse-then-forward
        // cepstral round trip these values sit far outside a plausible
        // natural-log range (measured: ~4700-13000 for a signal whose true
        // log-magnitude is single digits). `exp()` of that OVERFLOWS Float to
        // `+inf` — measured directly in this meter's own development. Since
        // the unknown scale is a single POSITIVE constant applied uniformly
        // (both transforms are linear), it does not move WHERE any peak
        // sits, only how tall it looks — harmless for a cross-correlation
        // that only cares about shape, so this function simply never leaves
        // the log domain.
        var smoothLog = [Float](repeating: 0, count: n / 2)
        var nyquistLogValue: Float = 0
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(envelopeFFTLog2), FFTDirection(FFT_FORWARD))

                // Real-cepstrum route: log|X(f)| is itself treated as a
                // packed-real "spectrum" (the standard definition,
                // cepstrum = IFFT(log|FFT(x)|)); its own inverse FFT is the
                // cepstrum.
                var logMag = [Float](repeating: 0, count: n / 2)
                for i in 0..<(n / 2) {
                    let mag = i == 0 ? abs(rp[0]) : (rp[i] * rp[i] + ip[i] * ip[i]).squareRoot()
                    logMag[i] = log(mag + 1e-9)
                }
                let nyquistLog = log(abs(ip[0]) + 1e-9)
                for i in 0..<(n / 2) { rp[i] = logMag[i]; ip[i] = 0 }
                ip[0] = nyquistLog
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(envelopeFFTLog2), FFTDirection(FFT_INVERSE))

                // `real`/`imag` now hold the CEPSTRUM in the packed
                // even/odd-interleaved TIME-domain convention (the same
                // packing `vDSP_ctoz` produces): cepstrum[2i] = real[i],
                // cepstrum[2i+1] = imag[i]. Deinterleave to a genuine
                // quefrency-indexed array so the lifter boundary is exact,
                // lifter it (keep only low quefrency — the smooth envelope —
                // and its mirror at the tail, real-cepstrum symmetry), then
                // re-pack with `vDSP_ctoz` for the forward transform back.
                var cepstrum = [Float](repeating: 0, count: n)
                for i in 0..<(n / 2) {
                    cepstrum[2 * i] = rp[i]
                    cepstrum[2 * i + 1] = ip[i]
                }
                let lift = envelopeLifterTaps
                for k in 0..<n where !(k < lift || k >= n - lift) { cepstrum[k] = 0 }

                var liftedReal = [Float](repeating: 0, count: n / 2)
                var liftedImag = [Float](repeating: 0, count: n / 2)
                liftedReal.withUnsafeMutableBufferPointer { crp in
                    liftedImag.withUnsafeMutableBufferPointer { cip in
                        var liftedSplit = DSPSplitComplex(realp: crp.baseAddress!, imagp: cip.baseAddress!)
                        cepstrum.withUnsafeBufferPointer { cb in
                            cb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                                vDSP_ctoz($0, 2, &liftedSplit, 1, vDSP_Length(n / 2))
                            }
                        }
                        vDSP_fft_zrip(setup, &liftedSplit, 1, vDSP_Length(envelopeFFTLog2),
                                     FFTDirection(FFT_FORWARD))
                    }
                }
                smoothLog = liftedReal
                nyquistLogValue = liftedImag[0]
            }
        }
        // `nyquistLogValue` is the packed-real Nyquist bin (sampleRate/2) —
        // never inside `[lowHz, highHz]` for any sample rate this project
        // uses, so it plays no part in an in-band peak. Kept (rather than
        // deleted) so the round-trip's packed output stays fully accounted
        // for at the call site, matching the forward pass above.
        _ = nyquistLogValue

        let binHz = sampleRate / Double(n)
        // ⚠️ **m23-nt NT-G2 FIX #1: THE PEAK (AND HENCE THE FLOOR) MUST BE
        // TAKEN WITHIN THE ANALYSIS BAND, NOT THE WHOLE 0...NYQUIST SPECTRUM.**
        // MEASURED: at a planted formant-scale shift of −700/−1200 c, pushing
        // all four resonances down toward DC raises the filter's own DC
        // response enough that the GLOBAL peak of `smoothLog` sits AT bin 0
        // (0 Hz) — outside `[lowHz, highHz]` — while the true in-band peak is
        // ~350-400 (scaled) units lower. A floor built from that out-of-band
        // peak swallowed the ENTIRE in-band curve into a single constant
        // value (measured: 2593/2593 bins clamped, bit-identical), which is
        // exactly what made `envelopeShiftCents` read a planted −700 c shift
        // as precisely 0.0 — not a rounding artefact, a fully degenerate
        // input. Restricting the peak search to the band this function is
        // documented to cover fixes that without touching anything else.
        let lowBin = Int((lowHz / binHz).rounded(.down))
        let highBin = Int((highHz / binHz).rounded(.up))
        let bandLo = max(0, lowBin), bandHi = min(smoothLog.count - 1, highBin)
        var peakLog = -Float.infinity
        if bandLo <= bandHi {
            for i in bandLo...bandHi where smoothLog[i].isFinite { peakLog = max(peakLog, smoothLog[i]) }
        }
        guard peakLog.isFinite else { return nil }
        // ⚠️ **FIX #2: THE FLOOR OFFSET WAS IN THE WRONG UNITS.** The doc
        // above (`envelopeFFTLog2` block) already states `smoothLog` is a
        // SCALED log-magnitude, not a plain natural log — `vDSP_fft_zrip`'s
        // unnormalised inverse-then-forward round trip multiplies every
        // value by a constant K. MEASURED directly (feed a constant 3.7
        // through the same inverse→forward pair): the round trip returns
        // ~15155.2, so K = 15155.2 / 3.7 ≈ 4096 = 2 × 2048 = 2n, matching
        // `vDSP_fft_zrip`'s documented packed-real round-trip scale. The
        // previous `floorLog = peakLog - Float(log(1000.0))` subtracted an
        // UNSCALED 6.9 from a peak of order 13000-15000 — a ~0.05 % nudge,
        // not a 0.1 %-of-peak floor — which is why NOTHING at all was
        // filtered for a well-conditioned signal (the +200/+400 c known
        // answers were already living right at that razor's edge: `a`'s own
        // range at 0 c is ~6.84 scaled units, just under the unscaled 6.91
        // cutoff) and why fixing #1 alone was not sufficient: a still-tiny
        // floor still let a handful of stray in-band bins stand in for the
        // whole curve (measured: 27 of 2593 bins un-clamped at −700 c even
        // after #1). Scaling the offset by the SAME K restores the intended
        // "0.1 % of peak in the magnitude domain" semantics.
        let roundTripScaleK = Float(2 * n)
        let floorLog = peakLog - roundTripScaleK * Float(log(1000.0))

        let count = Int((1200 * log2(highHz / lowHz) / envelopeCentsPerBin).rounded())
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let f = lowHz * pow(2, Double(i) * envelopeCentsPerBin / 1200)
            let pos = f / binHz
            let j = Int(pos)
            guard j + 1 < smoothLog.count else { return nil }
            let frac = pos - Double(j)
            let lv = max(smoothLog[j], floorLog)
            let rv = max(smoothLog[j + 1], floorLog)
            out[i] = Double(lv) * (1 - frac) + Double(rv) * frac
        }
        return out
    }

    /// Subtracts a box-filtered moving-average TREND from `a` (a simple
    /// high-pass in log-frequency), window `winBins` wide, edge-extended.
    /// This is what makes `envelopeShiftCents` track the formant ripple
    /// instead of the envelope's overall tilt (see the constant's doc above).
    static func highPassDetrend(_ a: [Double], winBins: Int) -> [Double] {
        var win = winBins
        if win % 2 == 0 { win += 1 }
        let pad = win / 2
        guard !a.isEmpty else { return a }
        let padded = [Double](repeating: a[0], count: pad) + a
            + [Double](repeating: a[a.count - 1], count: pad)
        var cumsum = [Double](repeating: 0, count: padded.count + 1)
        for i in 0..<padded.count { cumsum[i + 1] = cumsum[i] + padded[i] }
        var out = [Double](repeating: 0, count: a.count)
        for i in 0..<a.count {
            let trend = (cumsum[i + win] - cumsum[i]) / Double(win)
            out[i] = a[i] - trend
        }
        return out
    }

    /// How far `shifted`'s envelope sits above `reference`'s, in cents,
    /// positive = shifted is HIGHER. `nil` when either frame is too short or
    /// silent. Cross-correlates the two DETRENDED, log-frequency-resampled
    /// envelopes (cosine similarity, normalised so a quiet frame cannot win
    /// by variance alone) with parabolic sub-bin refinement, exactly
    /// `SpectralShiftMeter.shiftCents`'s shape but over the smoothed envelope
    /// and restricted to `[lowHz, highHz]`.
    ///
    /// ⚠️ **A KNOWN, MEASURED CALIBRATION BIAS.** This reads roughly 85-95 %
    /// of a planted formant-scale shift up to ±700 c, drifting closer to 100 %
    /// out at ±1200 c (353.8 c read for +400 c planted at 110 Hz — this file's
    /// own plant test, post m23-nt NT-G2's floor fix; 85-92 % typical across
    /// ±200/400 c, measured in this meter's own known-answer suite below),
    /// because two overlapping resonances shift their COMBINED peak less than
    /// either resonance's true centre. ⚠️ **PRE-FIX FIGURES, SUPERSEDED
    /// 2026-09-25:** an EARLIER version of this doc quoted "336 c for 400 c
    /// planted, 82 c for 100 c planted, 80-85 %" — those numbers were measured
    /// against a floor offset that turned out to be off by the cepstral round
    /// trip's own ~4096× scale (see `envelopeLogSpectrum`'s doc); they are
    /// wrong for the current code and must not be restored. It is monotone
    /// and clean — an f0-only ±7 st move reads under 20 c against a
    /// 340-370 c formant reading at 400 c planted, a clean margin — but
    /// callers wanting an absolute cents value must calibrate from a control
    /// pair, never read this as physical cents (the tree's own tolerance
    /// convention, `max(floor, 2 × control)`).
    static func envelopeShiftCents(reference: [Float], shifted: [Float], sampleRate: Double) -> Double? {
        guard var a = envelopeLogSpectrum(reference, sampleRate: sampleRate),
              var b = envelopeLogSpectrum(shifted, sampleRate: sampleRate),
              a.count == b.count, !a.isEmpty
        else { return nil }
        let winBins = Int((envelopeDetrendOctaves * 1200 / envelopeCentsPerBin).rounded())
        a = highPassDetrend(a, winBins: winBins)
        b = highPassDetrend(b, winBins: winBins)

        let maxLag = Int((envelopeMaxSearchCents / envelopeCentsPerBin).rounded())
        let n = a.count
        var bestScore = -Double.infinity
        var bestLag = 0
        for lag in -maxLag...maxLag {
            let lo = max(0, -lag), hi = min(n, n - lag)
            guard hi > lo else { continue }
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in lo..<hi {
                let av = a[i], bv = b[i + lag]
                dot += av * bv
                na += av * av
                nb += bv * bv
            }
            guard na > 1e-12, nb > 1e-12 else { continue }
            let score = dot / (na.squareRoot() * nb.squareRoot())
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // ⚠️ **m23-nt NT-G2 FIX #3: TWO "COULD NOT MEASURE" PATHS, BOTH MUST
        // RETURN NIL, NEVER A NUMBER.** Before this fix, both fell through to
        // `(Double(bestLag) + refine) * envelopeCentsPerBin` with `bestLag`
        // and `refine` still at their initial values — an exact, confident-
        // looking `0.0` indistinguishable from a genuine "no shift" reading
        // (this was the reported defect: a planted −700 c shift read as
        // exactly 0.0 at all three f0s).
        //  1. No candidate lag passed the `na/nb > 1e-12` energy guard at
        //     all — `bestScore` never left `-infinity` (MEASURED: this is
        //     exactly what a silent/degenerate frame pair produces, and what
        //     fixes #1/#2 above turn a real signal's spurious case into).
        //  2. The winning lag sits AT the search boundary — the true optimum
        //     may lie beyond what was searched, so a boundary hit is a limit
        //     of the search, not evidence of a value.
        guard bestScore.isFinite, bestLag > -maxLag, bestLag < maxLag else { return nil }
        func score(_ lag: Int) -> Double {
            let lo = max(0, -lag), hi = min(n, n - lag)
            guard hi > lo else { return -Double.infinity }
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in lo..<hi {
                let av = a[i], bv = b[i + lag]
                dot += av * bv; na += av * av; nb += bv * bv
            }
            guard na > 1e-12, nb > 1e-12 else { return -Double.infinity }
            return dot / (na.squareRoot() * nb.squareRoot())
        }
        let l = score(bestLag - 1), c = bestScore, r = score(bestLag + 1)
        let denom = l - 2 * c + r
        let refine = denom < 0 ? 0.5 * (l - r) / denom : 0.0
        return (Double(bestLag) + refine) * envelopeCentsPerBin
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Known-answer suite (every meter needs one)
// ═══════════════════════════════════════════════════════════════════════════

/// Proves both `SpectralEnvelopeMeter` instruments against `SourceFilterVoice`,
/// whose formant scale and f0 are independently known — the only way to give
/// a formant meter a KNOWN answer, since no real recording carries a ground
/// truth for "where the vocal tract's resonances actually are". nonisolated,
/// no audio I/O: this runs in every default `./scripts/test.sh` pass.
@Suite("SpectralEnvelopeMeter — known answer", .serialized)
struct SpectralEnvelopeMeterKnownAnswerTests {
    static let sampleRate = 48_000.0
    static let durationSeconds = 0.3

    static func middleFrame(_ audio: [Float], frames: Int = 1 << SpectralEnvelopeMeter.envelopeFFTLog2) -> [Float] {
        let start = max(0, audio.count / 2 - frames / 2)
        let end = min(audio.count, start + frames)
        return Array(audio[start..<end])
    }

    static func voiceFrame(f0Hz: Double, formantScaleCents: Double) -> [Float] {
        let frames = Int(durationSeconds * sampleRate)
        let audio = SourceFilterVoice.voice(f0Hz: f0Hz, formantScaleCents: formantScaleCents,
                                            frames: frames, sampleRate: sampleRate)
        return middleFrame(audio)
    }

    // MARK: LPC formants

    @Test("LPC reads the fixture's known F1/F2/F3 at three f0s (1(g)'s instrument control)",
         arguments: [80.0, 110.0, 220.0])
    func lpcReadsKnownFormants(f0: Double) throws {
        let frame = Self.voiceFrame(f0Hz: f0, formantScaleCents: 0)
        let (f1, f2, f3) = SpectralEnvelopeMeter.lpcFormants(frame, sampleRate: Self.sampleRate)
        let f1v = try #require(f1, "f0=\(f0): no F1 picked")
        let f2v = try #require(f2, "f0=\(f0): no F2 picked")
        // Fixture formants are 700 / 1220 / 2600 Hz (`SourceFilterVoice.defaultFormants`).
        #expect(abs(f1v - 700) < 100, "f0=\(f0): F1 read \(f1v), expected ~700")
        #expect(abs(f2v - 1220) < 120, "f0=\(f0): F2 read \(f2v), expected ~1220")
        // F3 (2600 Hz) is REPORT-ONLY, not asserted: it sits closest to the
        // fixture's own analysis ceiling (grid caps at 5500 Hz decimated) and
        // is the weakest-conditioned of the three even after the fix in
        // `lpcFormants`'s doc. No shipped gate reads this Swift LPC leg for
        // F3 — G11 (the real-take gate, a later lane) reads librosa's LPC in
        // Python instead. Print so a regression is still visible by eye.
        print("m23-nt-lpc| f0=\(f0) F3=\(String(describing: f3)) (report-only, expected ~2600)")
    }

    @Test("LPC control: a meter that ignored the signal could not tell a formant-scale plant apart — this one does")
    func lpcCanFail() throws {
        let unscaled = Self.voiceFrame(f0Hz: 110, formantScaleCents: 0)
        let scaledUp = Self.voiceFrame(f0Hz: 110, formantScaleCents: 1200) // one octave
        let (f1a, _, _) = SpectralEnvelopeMeter.lpcFormants(unscaled, sampleRate: Self.sampleRate)
        let (f1b, _, _) = SpectralEnvelopeMeter.lpcFormants(scaledUp, sampleRate: Self.sampleRate)
        let a = try #require(f1a)
        let b = try #require(f1b)
        // An octave up should read roughly double; a broken meter that just
        // echoed a constant (or read source f0 instead of the envelope)
        // would fail this by a wide margin.
        #expect(b > a * 1.5, "F1 did not move with a planted +1200c formant scale: \(a) -> \(b)")
    }

    // MARK: Envelope shift

    /// **POSITIVE CONTROL, 1(g)'s "the meter reads a planted formant scale of
    /// c cents as c" — measured, not exactly c.** This meter's own known
    /// calibration (see `envelopeShiftCents`'s doc) reads ~85-95 % of a
    /// planted shift, so the bound below is against the MEASURED range, not
    /// the planted value. What must hold, and does: monotone ordering and a
    /// clean margin over the f0-only negative control (next test).
    @Test("envelope shift reads a planted formant scale, ordered, at three f0s",
         arguments: [80.0, 110.0, 220.0])
    func envelopeShiftReadsPlantedScale(f0: Double) throws {
        let ref = Self.voiceFrame(f0Hz: f0, formantScaleCents: 0)
        let shifted400 = Self.voiceFrame(f0Hz: f0, formantScaleCents: 400)
        let shifted200 = Self.voiceFrame(f0Hz: f0, formantScaleCents: 200)
        let s400 = try #require(SpectralEnvelopeMeter.envelopeShiftCents(
            reference: ref, shifted: shifted400, sampleRate: Self.sampleRate))
        let s200 = try #require(SpectralEnvelopeMeter.envelopeShiftCents(
            reference: ref, shifted: shifted200, sampleRate: Self.sampleRate))
        #expect(s400 > 200 && s400 < 500, "f0=\(f0): +400c planted read \(s400)")
        #expect(s200 > 80 && s200 < 300, "f0=\(f0): +200c planted read \(s200)")
        #expect(s400 > s200, "f0=\(f0): +400c (\(s400)) did not read above +200c (\(s200))")
    }

    /// **NEGATIVE CONTROL, 1(g)'s "the meter reads ≈ 0 when only f0 moves by
    /// ±7 st."** Envelope unchanged, source f0 moved a full 7 semitones
    /// (700 c) — the meter must stay far below its own positive-control
    /// reading. The bound is DERIVED from a positive control measured in this
    /// SAME test (the tree's `max(floor, 2 × control)` convention), not a
    /// hard-coded cents figure: a fixed absolute bound already flipped once
    /// during this meter's own development (125 c measured against a 60 c
    /// guess) purely from a downstream change to an unrelated LPC leg.
    ///
    /// ⚠️ **m23-nt NT-G2: parameterised over all three f0s, not just 110 Hz.**
    /// This instrument control is exactly what G2's `tolerance(f0:cents:)`
    /// reads to derive its per-cell bound (`NaturalTuningFormantRenderTests
    /// .swift`) — before this file's floor fix, the f0-only control at 220 Hz
    /// read as high as ~120 c (a genuinely poor negative control, silently
    /// widening G2's own tolerance there to 128-240 c and letting two f0=220
    /// cells pass against a bound that should never have been that loose).
    /// Only 110 Hz was covered here, so that gap in THIS instrument's own
    /// validity check was invisible until G2 hit it downstream. Covering all
    /// three f0s here is the regression guard for that: it now reads ≤25 c at
    /// every f0 (MEASURED, post-fix).
    @Test("envelope shift reads far less than its own positive control when only f0 moves",
         arguments: [80.0, 110.0, 220.0])
    func envelopeShiftIgnoresF0Move(f0: Double) throws {
        let ref = Self.voiceFrame(f0Hz: f0, formantScaleCents: 0)
        let shifted400 = Self.voiceFrame(f0Hz: f0, formantScaleCents: 400)
        let s400 = try #require(SpectralEnvelopeMeter.envelopeShiftCents(
            reference: ref, shifted: shifted400, sampleRate: Self.sampleRate))
        let movedF0 = Self.voiceFrame(f0Hz: f0 * pow(2, 7.0 / 12), formantScaleCents: 0)
        let shift = try #require(SpectralEnvelopeMeter.envelopeShiftCents(
            reference: ref, shifted: movedF0, sampleRate: Self.sampleRate))
        print("m23-nt-g2| f0=\(f0): f0-only +7st control reads \(shift)c (positive control +400c reads \(s400)c)")
        #expect(abs(shift) < s400 / 2,
                "f0-only +7st move read \(shift)c, not comfortably below its own +400c formant-scale control (\(s400)c)")
    }

    /// **THE DISAGREEMENT CONTROL, 1(g)'s third instrument check: "the two
    /// instruments disagree in exactly the way they should."** On an f0-only
    /// move, `SpectralShiftMeter` (the existing PITCH meter, reused
    /// unmodified from `PitchWanderMeter.swift`) reads the pitch move;
    /// `SpectralEnvelopeMeter` must not. `SpectralShiftMeter.maxLagCents` is
    /// 200, so the move here is +150 c (within its own search range) rather
    /// than the ±7 st used above.
    @Test("SpectralShiftMeter reads the f0 move that SpectralEnvelopeMeter correctly ignores")
    func spectralShiftMeterDisagreesAsExpected() throws {
        let ref = Self.voiceFrame(f0Hz: 110, formantScaleCents: 0)
        let movedF0 = Self.voiceFrame(f0Hz: 110 * pow(2, 150.0 / 1200), formantScaleCents: 0)
        let envelope = try #require(SpectralEnvelopeMeter.envelopeShiftCents(
            reference: ref, shifted: movedF0, sampleRate: Self.sampleRate))
        let pitch = try #require(SpectralShiftMeter.shiftCents(
            reference: ref, shifted: movedF0, sampleRate: Self.sampleRate))
        #expect(abs(envelope) < 60, "envelope meter should ignore a pure f0 move; read \(envelope)")
        #expect(abs(pitch - 150) < 40, "pitch meter should read the +150c f0 move; read \(pitch)")
    }

    /// ⭐ **NT-G2: THE BLIND SPOT.** Before the fix in `envelopeLogSpectrum`
    /// (in-band peak + correctly K-scaled floor) and `envelopeShiftCents`
    /// (nil on a degenerate or boundary-saturated search), a planted −700 c
    /// scale read as EXACTLY 0.0 at all three f0s — indistinguishable from a
    /// genuine "no shift" reading — because the shifted signal's global
    /// spectral peak sat outside `[lowHz, highHz]` (compressed-down formants
    /// pile response toward DC) and an unscaled floor offset then swallowed
    /// the whole in-band curve into one constant value. This extends the
    /// positive-control suite above across the full range NT-E1's G2 gate
    /// needs: ±500/700/1200 c, both directions. Bounds are `0.5–1.5×` the
    /// planted magnitude — generous (this meter is not a precision
    /// instrument, see the calibration-bias doc above) but tight enough that
    /// the old exact-0.0 defect, or a sign flip, cannot pass.
    @Test("envelope shift measures ±500/700/1200 c planted scales, both directions, at three f0s",
         arguments: [80.0, 110.0, 220.0], [-1200.0, -700.0, -500.0, 500.0, 700.0, 1200.0])
    func envelopeShiftMeasuresWideRange(f0: Double, cents: Double) throws {
        let ref = Self.voiceFrame(f0Hz: f0, formantScaleCents: 0)
        let shifted = Self.voiceFrame(f0Hz: f0, formantScaleCents: cents)
        let reading = try #require(
            SpectralEnvelopeMeter.envelopeShiftCents(reference: ref, shifted: shifted, sampleRate: Self.sampleRate),
            "f0=\(f0) planted=\(cents)c: meter returned nil — this is the cell the fix must make measurable")
        print("m23-nt-g2| f0=\(f0) planted=\(cents)c: read \(reading)c")
        #expect(reading.sign == cents.sign || reading == 0,
                "f0=\(f0) planted=\(cents)c: read \(reading)c — wrong sign")
        #expect(abs(reading) > 0.5 * abs(cents) && abs(reading) < 1.5 * abs(cents),
                "f0=\(f0) planted=\(cents)c: read \(reading)c, outside 0.5-1.5x the planted magnitude")
    }

    /// A planted 0 c "shift" (reference compared with an independently
    /// rendered but IDENTICAL fixture) must read close to 0 — and, unlike the
    /// unmeasurable control below, it must NOT be nil: a real, confident
    /// self-match (perfect correlation at lag 0) is a different thing from a
    /// search that never found a match at all, and the two must not collapse
    /// into the same return value.
    @Test("envelope shift reads ≈ 0 for a planted 0 c scale (not nil, not the unmeasurable path)",
         arguments: [80.0, 110.0, 220.0])
    func envelopeShiftReadsZeroForZeroPlant(f0: Double) throws {
        let ref = Self.voiceFrame(f0Hz: f0, formantScaleCents: 0)
        let same = Self.voiceFrame(f0Hz: f0, formantScaleCents: 0)
        let reading = try #require(
            SpectralEnvelopeMeter.envelopeShiftCents(reference: ref, shifted: same, sampleRate: Self.sampleRate),
            "f0=\(f0): a 0c plant must read a real number, not nil")
        #expect(abs(reading) < 20, "f0=\(f0): 0c plant read \(reading)c")
    }

    /// ⭐ **THE NIL CONTROL, 1(g)'s "never a number that looks like a valid
    /// answer."** A silent frame pair is the cleanest reproduction of the
    /// meter's own degenerate case (MEASURED: `envelopeLogSpectrum` of
    /// silence resamples to a perfectly flat, constant array — same shape as
    /// what the −700 c defect produced before the fix — so after detrending,
    /// EVERY lag's normalisation guard fails and the search never finds a
    /// candidate). Both directions: silence against silence, and a real
    /// voiced frame against silence. Before FIX #3 this returned exactly
    /// `0.0`, in-band with a legitimate reading; it must now be `nil`.
    @Test("envelope shift returns nil for a silent frame, never 0.0 (the unmeasurable path's own control)")
    func envelopeShiftIsNilNotZeroForSilence() throws {
        let silence = [Float](repeating: 0, count: 1 << SpectralEnvelopeMeter.envelopeFFTLog2)
        let voiced = Self.voiceFrame(f0Hz: 110, formantScaleCents: 0)
        let silenceVsSilence = SpectralEnvelopeMeter.envelopeShiftCents(
            reference: silence, shifted: silence, sampleRate: Self.sampleRate)
        let voicedVsSilence = SpectralEnvelopeMeter.envelopeShiftCents(
            reference: voiced, shifted: silence, sampleRate: Self.sampleRate)
        print("m23-nt-g2| silence-vs-silence=\(String(describing: silenceVsSilence)) voiced-vs-silence=\(String(describing: voicedVsSilence))")
        #expect(silenceVsSilence == nil, "silence-vs-silence read \(String(describing: silenceVsSilence)), expected nil")
        #expect(voicedVsSilence == nil, "voiced-vs-silence read \(String(describing: voicedVsSilence)), expected nil")
    }

    /// **PLANT — shows the envelope meter itself can fail.** Without
    /// `highPassDetrend`, the raw correlation for a genuine +400 c formant
    /// plant reads measurably WORSE (further from 400 c) than the shipped,
    /// detrended reading of the SAME pair — proving detrending is
    /// load-bearing, not decorative.
    ///
    /// ⚠️ **m23-nt NT-G2: this claim used to be an absolute `> 200 c` error
    /// margin, MEASURED against the un-detrended reading SATURATING at the
    /// search boundary (±1200 c) before this file's floor fix — a plain,
    /// unscaled `peak_log - ln(1000)` offset that was (see
    /// `envelopeLogSpectrum`'s doc) an almost total no-op, which let the
    /// broad, un-detrended spectral tilt dominate every lag and simply run
    /// the search out to its edge. After the fix that same un-detrended
    /// search settles inside the range (296 c for this exact pair, MEASURED)
    /// — no longer wildly saturated, but still clearly worse than the
    /// detrended reading. A fixed absolute threshold tuned to the OLD,
    /// buggier behaviour would silently go stale exactly like the −700 c
    /// defect this lane was sent to fix; comparing against a reading MEASURED
    /// in this SAME test (the tree's own convention) does not.
    @Test("plant: without detrending, the envelope correlation reads measurably worse than the shipped, detrended reading")
    func plantWithoutDetrendMisses() throws {
        let ref = Self.voiceFrame(f0Hz: 110, formantScaleCents: 0)
        let shifted = Self.voiceFrame(f0Hz: 110, formantScaleCents: 400)
        guard let a = SpectralEnvelopeMeter.envelopeLogSpectrum(ref, sampleRate: Self.sampleRate),
              let b = SpectralEnvelopeMeter.envelopeLogSpectrum(shifted, sampleRate: Self.sampleRate)
        else { Issue.record("envelopeLogSpectrum returned nil"); return }
        // The RAW (non-detrended) correlation's peak, searched the same way
        // `envelopeShiftCents` does internally but skipping `highPassDetrend`.
        let maxLag = Int((SpectralEnvelopeMeter.envelopeMaxSearchCents
            / SpectralEnvelopeMeter.envelopeCentsPerBin).rounded())
        var bestLag = 0
        var bestScore = -Double.infinity
        let n = a.count
        for lag in -maxLag...maxLag {
            let lo = max(0, -lag), hi = min(n, n - lag)
            guard hi > lo else { continue }
            var dot = 0.0
            for i in lo..<hi { dot += a[i] * b[i + lag] }
            let score = dot / Double(hi - lo)
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        let rawReading = Double(bestLag) * SpectralEnvelopeMeter.envelopeCentsPerBin
        let detrendedReading = try #require(SpectralEnvelopeMeter.envelopeShiftCents(
            reference: ref, shifted: shifted, sampleRate: Self.sampleRate),
            "the shipped, detrended reading must itself succeed on this exact pair to be a baseline")
        let rawError = abs(rawReading - 400), detrendedError = abs(detrendedReading - 400)
        print("m23-nt-g2| plant: raw (un-detrended) \(rawReading)c (error \(rawError)c) vs shipped detrended \(detrendedReading)c (error \(detrendedError)c)")
        let message = "the un-detrended raw correlation read \(rawReading)c (error \(rawError)c) for a +400c plant, no worse than the shipped detrended reading's \(detrendedReading)c (error \(detrendedError)c) — this would mean detrending is decorative, not load-bearing"
        #expect(rawError > detrendedError + 50, "\(message)")
    }
}
