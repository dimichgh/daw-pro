import Accelerate
import Foundation
import Testing

/// m23-nt NT-G — **THE CONSONANT / ALIGNMENT INSTRUMENT**, §2's meters
/// (design `docs/design/2026-09-25-natural-tuning.md` §2g). Two independent
/// jobs in one file, both needed before §2's consonant-mix code can be
/// measured or gated:
///
///  * band energy / centroid / log-spectral distance over 1-20 kHz, the
///    consonant fixture's own spectral instrument (§2's "'s' region's
///    centroid and 4 bands");
///  * `analyticLagRho`, the M-1 alignment instrument (R2): separates a REAL
///    integer delay from a pure PHASE ROTATION, which a plain cross-
///    correlation cannot — R1 shows the stretcher rotates a gap's phase
///    without delaying it, so M-1 needs an instrument that reads a rotation
///    as "no delay, low confidence" rather than as a fractional lag.
///
/// nonisolated, DSP only: no actor, no shared state.
enum ConsonantSpectrumMeter {
    /// §2g's four bands, Hz.
    static let bands: [ClosedRange<Double>] = [2000...4000, 4000...8000, 8000...16000, 16000...20000]
    static let lsdLowHz = 1000.0
    static let lsdHighHz = 20000.0

    static let fftLog2 = 12 // 4096 — bin spacing 11.7 Hz at 48 kHz, resolves the 2 kHz band

    /// The power spectrum of `x` (Hann-windowed, zero-padded to `1 << fftLog2`),
    /// bins `0..<n/2` at `i * sampleRate / n` Hz, plus the Nyquist bin's own
    /// power appended at index `n/2` so callers never special-case it.
    static func powerSpectrum(_ x: [Float], sampleRate: Double) -> (bins: [Double], binHz: Double)? {
        let n = 1 << fftLog2
        guard x.count >= 64 else { return nil }
        var windowed = [Float](repeating: 0, count: n)
        let usable = min(x.count, n)
        var hann = [Float](repeating: 0, count: usable)
        vDSP_hann_window(&hann, vDSP_Length(usable), Int32(vDSP_HANN_DENORM))
        vDSP_vmul(x, 1, hann, 1, &windowed, 1, vDSP_Length(usable))

        guard let setup = vDSP_create_fftsetup(vDSP_Length(fftLog2), FFTRadix(kFFTRadix2))
        else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Double](repeating: 0, count: n / 2 + 1)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(fftLog2), FFTDirection(FFT_FORWARD))
                power[0] = Double(rp[0] * rp[0])
                for i in 1..<(n / 2) { power[i] = Double(rp[i] * rp[i] + ip[i] * ip[i]) }
                power[n / 2] = Double(ip[0] * ip[0]) // Nyquist, packed-real convention
            }
        }
        return (power, sampleRate / Double(n))
    }

    /// Total power in `band`, dB (10·log10, floored at 1e-18 so silence
    /// reads a large negative number rather than -inf).
    static func bandEnergyDb(_ x: [Float], sampleRate: Double, band: ClosedRange<Double>) -> Double? {
        guard let (bins, binHz) = powerSpectrum(x, sampleRate: sampleRate) else { return nil }
        let lo = max(0, Int((band.lowerBound / binHz).rounded()))
        let hi = min(bins.count - 1, Int((band.upperBound / binHz).rounded()))
        guard hi >= lo else { return nil }
        let sum = bins[lo...hi].reduce(0, +)
        return 10 * log10(max(sum, 1e-18))
    }

    /// Magnitude-weighted spectral centroid, Hz, over `[lowHz, highHz]`.
    static func spectralCentroidHz(
        _ x: [Float], sampleRate: Double, lowHz: Double = lsdLowHz, highHz: Double = lsdHighHz
    ) -> Double? {
        guard let (bins, binHz) = powerSpectrum(x, sampleRate: sampleRate) else { return nil }
        let lo = max(0, Int((lowHz / binHz).rounded()))
        let hi = min(bins.count - 1, Int((highHz / binHz).rounded()))
        guard hi > lo else { return nil }
        var weighted = 0.0, total = 0.0
        for i in lo...hi {
            let mag = bins[i].squareRoot()
            weighted += mag * Double(i) * binHz
            total += mag
        }
        guard total > 0 else { return nil }
        return weighted / total
    }

    /// Cents between two spectral centroids (positive = `shifted` is higher).
    static func centroidShiftCents(
        reference: [Float], shifted: [Float], sampleRate: Double,
        lowHz: Double = lsdLowHz, highHz: Double = lsdHighHz
    ) -> Double? {
        guard let a = spectralCentroidHz(reference, sampleRate: sampleRate, lowHz: lowHz, highHz: highHz),
              let b = spectralCentroidHz(shifted, sampleRate: sampleRate, lowHz: lowHz, highHz: highHz),
              a > 0, b > 0
        else { return nil }
        return 1200 * log2(b / a)
    }

    /// RMS of the per-bin log-magnitude difference over `[lowHz, highHz]` —
    /// a direct similarity metric (no shift search): 0 for identical spectra,
    /// growing with any spectral change, shift or otherwise.
    static func logSpectralDistance(
        reference: [Float], shifted: [Float], sampleRate: Double,
        lowHz: Double = lsdLowHz, highHz: Double = lsdHighHz
    ) -> Double? {
        guard let (a, binHz) = powerSpectrum(reference, sampleRate: sampleRate),
              let (b, _) = powerSpectrum(shifted, sampleRate: sampleRate)
        else { return nil }
        let lo = max(0, Int((lowHz / binHz).rounded()))
        let hi = min(a.count - 1, b.count - 1, Int((highHz / binHz).rounded()))
        guard hi > lo else { return nil }
        let floor = 1e-12
        var sumSquares = 0.0
        var count = 0
        for i in lo...hi {
            let la = log10(a[i] + floor), lb = log10(b[i] + floor)
            sumSquares += (la - lb) * (la - lb)
            count += 1
        }
        guard count > 0 else { return nil }
        return (10 * (sumSquares / Double(count)).squareRoot())
    }

    // MARK: - M-1: the analytic-envelope lag/ρ instrument (R2)

    /// **Separates a real DELAY from a pure PHASE ROTATION.** R1 shows the
    /// stretcher carries a gap's phase forward without delaying it
    /// (`prevOutput × input × conj(prevInput)`), so a plain real cross-
    /// correlation argmax can drift toward a fraction of the dominant period
    /// after a moved note — its value at lag 0 scales with `cos(rotation)`,
    /// which looks exactly like "a small delay" to a peak-picker. The fix:
    /// build the ANALYTIC cross-correlation (its envelope is insensitive to
    /// a constant phase rotation, only to genuine time shift — the standard
    /// reason a matched filter is built from an analytic signal), and
    /// SEPARATELY read `ρ`, the REAL normalised correlation AT the lag the
    /// envelope found. A rotation then reads lag 0 with LOW ρ; a real delay
    /// reads the true lag with HIGH ρ.
    ///
    /// Construction: `C[k] = FFT(wet)[k] · conj(FFT(dry)[k])` is Hermitian
    /// (`dry`/`wet` are both real), so a plain inverse FFT of `C` would give
    /// the ordinary real cross-correlation. The analytic version instead
    /// keeps `C[0]` and the Nyquist bin, DOUBLES every positive-frequency
    /// bin, and ZEROES every negative-frequency bin before the inverse
    /// transform — the textbook analytic-signal recipe, applied to the
    /// cross-spectrum instead of to a single signal's spectrum. That is no
    /// longer Hermitian, so this needs a genuine complex-to-complex FFT
    /// (`vDSP_fft_zip`), not the packed-real `vDSP_fft_zrip` this file's
    /// other functions use.
    ///
    /// - Returns: `lag` (signed frames, `wet` relative to `dry`: positive
    ///   means `wet` lags `dry`) and `rho`, the real normalised correlation
    ///   at that lag, in `[-1, 1]` (0 when there are not enough samples to
    ///   compare at that lag).
    static func analyticLagRho(dry: [Float], wet: [Float], maxLag: Int) -> (lag: Int, rho: Double) {
        let minLen = min(dry.count, wet.count)
        guard minLen > 2 * maxLag, maxLag > 0 else { return (0, 0) }
        var nfft = 1
        while nfft < dry.count + wet.count { nfft <<= 1 }
        let log2n = Int(log2(Double(nfft)).rounded())

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))
        else { return (0, 0) }
        defer { vDSP_destroy_fftsetup(setup) }

        var dryReal = [Float](repeating: 0, count: nfft)
        var dryImag = [Float](repeating: 0, count: nfft)
        var wetReal = [Float](repeating: 0, count: nfft)
        var wetImag = [Float](repeating: 0, count: nfft)
        for i in 0..<dry.count { dryReal[i] = dry[i] }
        for i in 0..<wet.count { wetReal[i] = wet[i] }

        var envelope = [Double](repeating: 0, count: nfft)
        dryReal.withUnsafeMutableBufferPointer { drp in
            dryImag.withUnsafeMutableBufferPointer { dip in
                wetReal.withUnsafeMutableBufferPointer { wrp in
                    wetImag.withUnsafeMutableBufferPointer { wip in
                        var dsplit = DSPSplitComplex(realp: drp.baseAddress!, imagp: dip.baseAddress!)
                        var wsplit = DSPSplitComplex(realp: wrp.baseAddress!, imagp: wip.baseAddress!)
                        vDSP_fft_zip(setup, &dsplit, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                        vDSP_fft_zip(setup, &wsplit, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))

                        // Cross-spectrum W · conj(D), then the analytic mask.
                        var crossReal = [Float](repeating: 0, count: nfft)
                        var crossImag = [Float](repeating: 0, count: nfft)
                        for k in 0..<nfft {
                            let wr = wrp[k], wi = wip[k], dr = drp[k], di = dip[k]
                            crossReal[k] = wr * dr + wi * di // W · conj(D), real part
                            crossImag[k] = wi * dr - wr * di // W · conj(D), imag part
                        }
                        let half = nfft / 2
                        for k in 1..<half { crossReal[k] *= 2; crossImag[k] *= 2 }
                        for k in (half + 1)..<nfft { crossReal[k] = 0; crossImag[k] = 0 }

                        crossReal.withUnsafeMutableBufferPointer { crp in
                            crossImag.withUnsafeMutableBufferPointer { cip in
                                var csplit = DSPSplitComplex(realp: crp.baseAddress!, imagp: cip.baseAddress!)
                                vDSP_fft_zip(setup, &csplit, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                                for n in 0..<nfft {
                                    envelope[n] = (Double(crp[n]) * Double(crp[n])
                                        + Double(cip[n]) * Double(cip[n])).squareRoot()
                                }
                            }
                        }
                    }
                }
            }
        }

        // Circular index: lag L in [-maxLag, maxLag] maps to L mod nfft.
        var bestLag = 0
        var bestEnvelope = -Double.infinity
        for lag in -maxLag...maxLag {
            let idx = lag >= 0 ? lag : lag + nfft
            if envelope[idx] > bestEnvelope { bestEnvelope = envelope[idx]; bestLag = lag }
        }

        // ρ: the REAL (non-analytic) normalised correlation at `bestLag`,
        // computed directly in the time domain — a genuine Pearson
        // correlation, not read off the FFT.
        let rho = pearsonAtLag(dry: dry, wet: wet, lag: bestLag)
        return (bestLag, rho)
    }

    /// Pearson correlation between `dry` and `wet` shifted by `lag` frames
    /// (`wet[i + lag]` paired with `dry[i]`), over their common overlap. `0`
    /// when fewer than 16 samples overlap.
    static func pearsonAtLag(dry: [Float], wet: [Float], lag: Int) -> Double {
        let loI = max(0, -lag), hiI = min(dry.count, wet.count - lag)
        guard hiI - loI >= 16 else { return 0 }
        var sumA = 0.0, sumB = 0.0
        for i in loI..<hiI { sumA += Double(dry[i]); sumB += Double(wet[i + lag]) }
        let count = Double(hiI - loI)
        let meanA = sumA / count, meanB = sumB / count
        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in loI..<hiI {
            let da = Double(dry[i]) - meanA, db = Double(wet[i + lag]) - meanB
            cov += da * db; varA += da * da; varB += db * db
        }
        guard varA > 1e-18, varB > 1e-18 else { return 0 }
        return cov / (varA.squareRoot() * varB.squareRoot())
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Known-answer suite (every meter needs one)
// ═══════════════════════════════════════════════════════════════════════════

@Suite("ConsonantSpectrumMeter — known answer", .serialized)
struct ConsonantSpectrumMeterKnownAnswerTests {
    static let sampleRate = 48_000.0

    /// A crude one-pole RC lowpass, cutoff `~sampleRate / (2π · rc)` — a
    /// deliberately DIFFERENT filter shape than `SourceFilterVoice`'s own
    /// resonators, so this test is not just re-measuring that fixture.
    static func lowpassed(_ x: [Float], rc: Float = 60) -> [Float] {
        let a = 1 / (rc + 1)
        var y: Float = 0
        return x.map { sample in
            y += a * (sample - y)
            return y
        }
    }

    // MARK: Band energy, centroid, log-spectral distance

    /// **POSITIVE CONTROL for `bandEnergyDb`.** `SourceFilterVoice.fricativeBurst`
    /// is deliberately shaped bright (a one-pole highpass); a heavily
    /// lowpassed copy must read far LOWER in the 8-16 kHz band, and far
    /// HIGHER nowhere in this pair (asymmetry is itself part of the control).
    @Test("bandEnergyDb separates a bright burst from a darkened copy")
    func bandEnergySeparatesBrightFromDark() throws {
        let bright = SourceFilterVoice.fricativeBurst(durationSeconds: 0.15, sampleRate: Self.sampleRate)
        let dark = Self.lowpassed(bright)
        let brightHigh = try #require(ConsonantSpectrumMeter.bandEnergyDb(
            bright, sampleRate: Self.sampleRate, band: ConsonantSpectrumMeter.bands[2]))
        let darkHigh = try #require(ConsonantSpectrumMeter.bandEnergyDb(
            dark, sampleRate: Self.sampleRate, band: ConsonantSpectrumMeter.bands[2]))
        #expect(brightHigh > darkHigh + 20,
                "bright 8-16kHz \(brightHigh) dB should exceed the lowpassed copy's \(darkHigh) dB by >20 dB")
    }

    /// **NEGATIVE CONTROL for `bandEnergyDb`** — the same comparison in the
    /// LOW band must not show the same gap (both signals carry low-frequency
    /// content; the lowpass does not remove what was barely there to begin
    /// with in the highpassed source, so this margin is much smaller).
    @Test("bandEnergyDb does not manufacture a gap in a band neither signal was shaped in")
    func bandEnergyNegativeControl() throws {
        let bright = SourceFilterVoice.fricativeBurst(durationSeconds: 0.15, sampleRate: Self.sampleRate)
        let dark = Self.lowpassed(bright)
        let brightHigh = try #require(ConsonantSpectrumMeter.bandEnergyDb(
            bright, sampleRate: Self.sampleRate, band: ConsonantSpectrumMeter.bands[2]))
        let darkHigh = try #require(ConsonantSpectrumMeter.bandEnergyDb(
            dark, sampleRate: Self.sampleRate, band: ConsonantSpectrumMeter.bands[2]))
        let brightLow = try #require(ConsonantSpectrumMeter.bandEnergyDb(
            bright, sampleRate: Self.sampleRate, band: 20...200))
        let darkLow = try #require(ConsonantSpectrumMeter.bandEnergyDb(
            dark, sampleRate: Self.sampleRate, band: 20...200))
        #expect(brightHigh - darkHigh > (brightLow - darkLow) + 15,
                "the bright/dark gap should be much bigger in the shaped (high) band than in the low band")
    }

    /// **KNOWN ANSWER for `centroidShiftCents`.** Two pure tones a known
    /// interval apart are the only signal whose true centroid is exactly
    /// known in closed form.
    @Test("centroidShiftCents reads a known interval between two tones")
    func centroidReadsKnownTones() throws {
        let frames = Int(0.1 * Self.sampleRate)
        let low = M23QSignal.sine(hz: 5000, frames: frames, sampleRate: Self.sampleRate)
        let high = M23QSignal.sine(hz: 5000 * pow(2, 300.0 / 1200), frames: frames, sampleRate: Self.sampleRate)
        let shift = try #require(ConsonantSpectrumMeter.centroidShiftCents(
            reference: low, shifted: high, sampleRate: Self.sampleRate))
        #expect(abs(shift - 300) < 30, "planted +300c tone interval read \(shift)c")
        // Negative control: comparing the tone against itself reads 0.
        let zero = try #require(ConsonantSpectrumMeter.centroidShiftCents(
            reference: low, shifted: low, sampleRate: Self.sampleRate))
        #expect(abs(zero) < 1, "identical tone pair should read 0c, read \(zero)")
    }

    /// **KNOWN ANSWER for `logSpectralDistance`**: 0 for an identical pair
    /// (negative control — proves the metric CAN read 0, not just CAN read
    /// nonzero), clearly positive for the bright/dark pair (positive control).
    @Test("logSpectralDistance reads 0 for an identical pair and a clear positive number for a changed one")
    func logSpectralDistanceKnownAnswer() throws {
        let bright = SourceFilterVoice.fricativeBurst(durationSeconds: 0.15, sampleRate: Self.sampleRate)
        let dark = Self.lowpassed(bright)
        let same = try #require(ConsonantSpectrumMeter.logSpectralDistance(
            reference: bright, shifted: bright, sampleRate: Self.sampleRate))
        let changed = try #require(ConsonantSpectrumMeter.logSpectralDistance(
            reference: bright, shifted: dark, sampleRate: Self.sampleRate))
        #expect(same == 0, "identical spectra must read exactly 0 LSD, read \(same)")
        #expect(changed > same + 3, "bright vs darkened should read a clear positive LSD, read \(changed)")
    }
}

/// m23-nt NT-G — the M-1 instrument's own known-answer suite, per R2's two
/// named plants: a real delay must read as a delay (high ρ), and a pure phase
/// rotation must NOT (lag 0, low ρ) — the exact confusion R1/R2 exist to rule
/// out. `.serialized`: FFT setup churn is cheap but there is no reason to run
/// these concurrently with the meter's other suite.
@Suite("ConsonantSpectrumMeter — M-1 analytic lag/ρ instrument (R2)", .serialized)
struct ConsonantLagRhoKnownAnswerTests {
    static let sampleRate = 48_000.0

    /// A "consonant-like" broadband signal: `SourceFilterVoice.fricativeBurst`
    /// reused as the M-1 instrument's own test material — a real DSP signal,
    /// not a single sinusoid, so the correlation is genuinely broadband.
    static func material() -> [Float] {
        SourceFilterVoice.fricativeBurst(durationSeconds: 0.2, sampleRate: sampleRate, seed: 0x51)
    }

    /// Rotates every frequency component of `x` by +90° (the quadrature /
    /// Hilbert-transform construction): FFT, multiply positive-frequency
    /// bins by `+i`, negative-frequency bins by `-i` (DC and Nyquist, having
    /// no phase to rotate, are zeroed — both are already `~0` in a windowed
    /// broadband burst), inverse FFT. This is R2's NEW plant: "the tuned
    /// audio phase-rotated by π/2 per bin reads lag 0 with LOW ρ".
    static func phaseRotatedQuarterTurn(_ x: [Float]) -> [Float] {
        var nfft = 1
        while nfft < x.count { nfft <<= 1 }
        let log2n = Int(log2(Double(nfft)).rounded())
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))
        else { return x }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: nfft)
        var imag = [Float](repeating: 0, count: nfft)
        for i in 0..<x.count { real[i] = x[i] }
        var out = [Float](repeating: 0, count: x.count)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                let half = nfft / 2
                rp[0] = 0; ip[0] = 0
                if half < nfft { rp[half] = 0; ip[half] = 0 }
                for k in 1..<half {
                    let re = rp[k], im = ip[k]
                    rp[k] = -im; ip[k] = re // × (+i)
                }
                for k in (half + 1)..<nfft {
                    let re = rp[k], im = ip[k]
                    rp[k] = im; ip[k] = -re // × (-i), the mirror for a real output
                }
                vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                for i in 0..<x.count { out[i] = rp[i] }
            }
        }
        return out
    }

    /// **PLANT 1 (R2, kept from the original M-1): a real 3-frame delay reads
    /// 3, with high ρ.**
    @Test("analyticLagRho reads a real 3-frame delay, with high rho")
    func delayPlantReadsTheDelay() throws {
        let dry = Self.material()
        let wet = [Float](repeating: 0, count: 3) + dry
        let (lag, rho) = ConsonantSpectrumMeter.analyticLagRho(dry: dry, wet: Array(wet.prefix(dry.count)), maxLag: 64)
        #expect(lag == 3, "expected lag 3, read \(lag)")
        #expect(rho > 0.9, "expected high rho for a genuine delay, read \(rho)")
    }

    /// **PLANT 2 (R2, new): a phase-rotated (not delayed) signal reads lag 0,
    /// with LOW ρ.** This is the case a plain (non-analytic) cross-
    /// correlation gets wrong (R1) — the instrument must not report a
    /// fractional delay for what is actually a rotation.
    @Test("analyticLagRho reads lag 0 with LOW rho for a pure phase rotation, not a delay")
    func rotationPlantReadsNoDelayLowRho() throws {
        let dry = Self.material()
        let rotated = Self.phaseRotatedQuarterTurn(dry)
        let (lag, rho) = ConsonantSpectrumMeter.analyticLagRho(dry: dry, wet: rotated, maxLag: 64)
        #expect(lag == 0, "a pure phase rotation carries no delay; read lag \(lag)")
        #expect(abs(rho) < 0.3, "a pure phase rotation should read LOW rho (it is not really aligned in phase at lag 0 either); read \(rho)")
    }

    /// **NEGATIVE CONTROL: identical signal reads lag 0, ρ ≈ 1.**
    @Test("analyticLagRho reads lag 0, rho near 1, for an identical pair")
    func identicalPairReadsPerfectAlignment() throws {
        let dry = Self.material()
        let (lag, rho) = ConsonantSpectrumMeter.analyticLagRho(dry: dry, wet: dry, maxLag: 64)
        #expect(lag == 0)
        #expect(rho > 0.999, "identical signal should read rho ~1, read \(rho)")
    }
}
