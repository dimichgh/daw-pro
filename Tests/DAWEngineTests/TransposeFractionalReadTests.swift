import Accelerate
import CSignalsmithStretch
import CryptoKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

// ═══════════════════════════════════════════════════════════════════════════
// p2-acc / p2-acc-3 — THE TRANSPOSER'S THREE VENDORED LOCAL PATCHES
// ═══════════════════════════════════════════════════════════════════════════
//
// Upstream signalsmith-stretch v1.3.2 carried three defects that moved pitch
// (`Sources/CSignalsmithStretch/VENDORED.md` records each patch):
//  * 0001 — `prevInput` is interpolated at a FRACTIONAL input bin after every
//    bin was already rotated by its OWN centre advance: +100 c on a 220 Hz sine
//    rendered at +109.69 c, a −100 c move at 55 Hz landed at −58 c.
//  * 0002 — a spectral peak's position was an energy centroid (biased toward
//    bin centres by up to 0.076 bins), and the smoothstep toward the NEXT peak
//    bent the offset inside each peak's own main lobe: steady partials were
//    12 c off at ±12 st and 76 c off at ±24 st on 0001 alone.
//  * 0003 — the previous spectrum was reused on H±1 hops but turned by H, so a
//    near-unity time-stretch drifted up to 0.93 c, at 0 st too. 0002 without
//    0003 regresses near-unity ratios: they ship together or not at all.
//
// This suite is the patches' gate AND their tripwire: a re-vendor that drops
// one fails here loudly (0001: G2 ≈ +9.69 c; 0002: G3/G12/G13; 0003: G17/G18
// and G1+), which a source-marker grep would not.
//
//  * G0  every frequency instrument (and the noise-density meter),
//        positive-controlled on synthetic signals (no stretcher), so a reading
//        below is the render's, not the meter's.
//  * G1  0 st is BYTE-IDENTICAL to the pristine header outside 0003's window,
//        and — the controls — a transposed render is NOT; G1+ pins the
//        near-unity 0-st renders 0003 moved (and r = 1.003, which it did not).
//  * G2  accuracy for small moves (|shift| ≤ 3 st): |err| < 0.05 c.
//  * G3  large shifts (±5/±7/±12 st, 8 notes, both rates): |err| < 0.05 c.
//  * G4  the random-phase regime (ratio 2.5): |err| < 1.0 c.
//  * G9  the scoped cache re-key (`StretchRenderCache.transposeEngineVersion`,
//        and the near-unity band 0003 added to the `pv:` predicate).
//  * G12 ±19/±24 st on sines · G13 12-harmonic tones at ±5/±7/±12 st.
//  * G14/G15 the two tripwires that bracket 0002's flat-zone cap (V1): low
//        up-shifted harmonics must stay accurate (no flat zone → 3–17 c), and
//        inter-harmonic noise must not be carved out (no input-gap cap →
//        −22.8 dB at 55 Hz +12 st).
//  * G16 a vibrato CHARACTERISATION: a mean-pitch residual intrinsic to
//        shifting a moving partial, unmasked by 0002 (bounded, not zero).
//  * G17 0003's tripwire (0 st, near-unity) · G18 the 0002/0003 COUPLING
//        tripwire (transposed, near-unity).
//
// ⚠️ SwiftF0 (the product's detector) cannot see 5–10 c; no gate here uses it.
// Two instrument families, each a pair sharing no machinery:
//  * harness2's (the investigation's, `scratchpad/w3/cents/architect/
//    harness.cpp`): a 50 ms Hann phase-slope regression and interpolated
//    upward zero crossings — G2, G3, G4, G13, G18;
//  * harness3's (the acc2 architect review's, `scratchpad/w4/acc2-review/
//    harness3.cpp`): complex demodulation through a 0.25–0.5 s Blackman
//    windowed-sinc low-pass with a phase regression that removes the vibrato,
//    and a zero-crossing cycle-index regression — G12, G14, G16, G17.
// Each gate reads with the family its bound was measured with.
@Suite("p2-acc — transposer vendored local patches 0001-0003")
struct TransposeFractionalReadTests {

    // MARK: - Signals

    static func sine(sampleRate: Double, hz: Double, seconds: Double,
                     amplitude: Double = 0.5, phase: Double = 0) -> [Float] {
        let frames = Int((sampleRate * seconds).rounded())
        return (0..<frames).map {
            Float(amplitude * sin(2 * .pi * hz * Double($0) / sampleRate + phase))
        }
    }

    /// 12 harmonics at 0.3/h, plus a seeded LCG noise floor so the whole
    /// spectrum is exercised (the architect's `digestOnly` signal).
    static func harmonicNoise(sampleRate: Double, f0: Double, seconds: Double,
                              seed: UInt32) -> [Float] {
        let frames = Int((sampleRate * seconds).rounded())
        var out = [Float](repeating: 0, count: frames)
        for h in 1...12 where f0 * Double(h) <= sampleRate * 0.45 {
            let amp = 0.3 / Double(h)
            let w = 2 * Double.pi * f0 * Double(h) / sampleRate
            for i in 0..<frames {
                out[i] += Float(amp * sin(w * Double(i) + 0.7 * Double(h)))
            }
        }
        var state = seed
        for i in 0..<frames {
            state = state &* 1_664_525 &+ 1_013_904_223
            out[i] += 0.05 * (Float(state >> 8) / Float(1 << 24) - 0.5)
        }
        return out
    }

    /// SHA-256 over the raw little-endian bit patterns of every channel, in
    /// order. Bit patterns: `-0.0 == 0.0` as Floats, and this gate is about bytes.
    static func digest(_ planar: [[Float]]) -> String {
        var hasher = SHA256()
        for channel in planar {
            channel.withUnsafeBufferPointer { buffer in
                var bytes = [UInt8]()
                bytes.reserveCapacity(buffer.count * 4)
                for sample in buffer {
                    withUnsafeBytes(of: sample.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
                }
                hasher.update(data: Data(bytes))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func log(_ leg: String, _ message: String) {
        print("p2-acc| \(leg) | \(message)")
    }

    // MARK: - Instruments (two, sharing no machinery)

    /// Instrument 1: demodulate at `target`, 50 ms Hann blocks every 25 ms,
    /// regress the unwrapped phase against time. Works on any partial the
    /// blocks resolve, not just a lone sine.
    static func phaseSlopeHz(_ y: [Float], sampleRate sr: Double, target ft: Double,
                             range: Range<Int>) -> Double {
        let blockLength = Int((0.05 * sr).rounded())
        let hop = blockLength / 2
        let window = (0..<blockLength).map {
            0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(blockLength))
        }
        var times: [Double] = [], phases: [Double] = []
        var previous = 0.0, unwrapped = 0.0
        y.withUnsafeBufferPointer { samples in
            var start = range.lowerBound
            while start + blockLength <= range.upperBound {
                var re = 0.0, im = 0.0
                for k in 0..<blockLength {
                    let n = Double(start + k)
                    let angle = -2 * Double.pi * ft * n / sr
                    let v = window[k] * Double(samples[start + k])
                    re += v * cos(angle)
                    im += v * sin(angle)
                }
                let a = atan2(im, re)
                if phases.isEmpty {
                    unwrapped = a
                } else {
                    var d = a - previous
                    while d > .pi { d -= 2 * .pi }
                    while d < -.pi { d += 2 * .pi }
                    unwrapped += d
                }
                previous = a
                times.append(Double(start) + Double(blockLength) / 2)
                phases.append(unwrapped)
                start += hop
            }
        }
        let meanT = times.reduce(0, +) / Double(times.count)
        let meanP = phases.reduce(0, +) / Double(phases.count)
        var sxy = 0.0, sxx = 0.0
        for (t, p) in zip(times, phases) {
            sxy += (t - meanT) * (p - meanP)
            sxx += (t - meanT) * (t - meanT)
        }
        return ft + (sxy / sxx) * sr / (2 * .pi)
    }

    /// Instrument 2: upward zero crossings, linearly interpolated. Pure tones only.
    static func zeroCrossHz(_ y: [Float], sampleRate sr: Double, range: Range<Int>) -> Double? {
        var firstT = -1.0, lastT = -1.0, count = 0
        for n in (range.lowerBound + 1)..<range.upperBound where y[n - 1] < 0 && y[n] >= 0 {
            let t = Double(n - 1) + Double(-y[n - 1]) / (Double(y[n]) - Double(y[n - 1]))
            if firstT < 0 { firstT = t }
            lastT = t
            count += 1
        }
        guard count >= 2 else { return nil }
        return Double(count - 1) * sr / (lastT - firstT)
    }

    /// Where the stretcher is ASKED to put a partial at `f0`: ×2^(st/12) below
    /// the tonality knee (`OfflineStretcher.tonalityLimitHz`, which upstream
    /// scales by 1/√r), a constant-Hz offset above it.
    static func expectedHz(f0: Double, sampleRate sr: Double, semitones: Double) -> Double {
        let r = pow(2, semitones / 12)
        let limit = (Double(OfflineStretcher.tonalityLimitHz) / sr) / r.squareRoot()
        let fn = f0 / sr
        return (fn > limit ? fn + (r - 1) * limit : fn * r) * sr
    }

    static func cents(_ hz: Double, above reference: Double) -> Double {
        1200 * log2(hz / reference)
    }

    // MARK: - harness3's instruments (the acc2 review's), vectorised

    /// Least squares of `y` on [1, t − t_mid, cos/sin(2π·k·rate·t), k = 1…3]
    /// (the vibrato terms only when `rate > 0`); returns the `t` coefficient.
    /// harness3 `regressSlope` + `solve` (partial-pivot elimination).
    static func regressSlope(_ t: [Double], _ y: [Double], vibratoRate rate: Double) -> Double {
        let harmonics = 3
        let p = 2 + (rate > 0 ? 2 * harmonics : 0)
        var a = [Double](repeating: 0, count: p * p)
        var b = [Double](repeating: 0, count: p)
        var row = [Double](repeating: 0, count: p)
        let t0 = t[t.count / 2]
        for i in t.indices {
            row[0] = 1
            row[1] = t[i] - t0
            if rate > 0 {
                for k in 1...harmonics {
                    row[2 * k] = cos(2 * .pi * Double(k) * rate * t[i])
                    row[2 * k + 1] = sin(2 * .pi * Double(k) * rate * t[i])
                }
            }
            for r in 0..<p {
                b[r] += row[r] * y[i]
                for c in 0..<p { a[r * p + c] += row[r] * row[c] }
            }
        }
        for i in 0..<p {
            var pivot = i
            for r in (i + 1)..<p where abs(a[r * p + i]) > abs(a[pivot * p + i]) { pivot = r }
            if pivot != i {
                for c in 0..<p { a.swapAt(i * p + c, pivot * p + c) }
                b.swapAt(i, pivot)
            }
            for r in (i + 1)..<p {
                let f = a[r * p + i] / a[i * p + i]
                for c in i..<p { a[r * p + c] -= f * a[i * p + c] }
                b[r] -= f * b[i]
            }
        }
        var x = [Double](repeating: 0, count: p)
        for i in stride(from: p - 1, through: 0, by: -1) {
            var s = b[i]
            for c in (i + 1)..<p { s -= a[i * p + c] * x[c] }
            x[i] = s / a[i * p + i]
        }
        return x[1]
    }

    /// Instrument A (harness3 `demodFreq`): demodulate at `fc`, low-pass
    /// through a Blackman windowed sinc (`cutoffHz`, `lpfSeconds` long, odd),
    /// decimate to ~1 kHz, unwrap the phase and regress it with the vibrato
    /// terms removed. Over whole vibrato periods this reads the MEAN pitch, and
    /// the long filter resolves a partial the 50 ms blocks cannot (27.5 Hz).
    static func demodHz(_ y: [Float], sampleRate sr: Double, target fc: Double, range: Range<Int>,
                        vibratoRate rate: Double = 0, cutoffHz: Double, lpfSeconds: Double) -> Double {
        let taps = Int((lpfSeconds * sr).rounded()) | 1
        let half = taps / 2
        let x = 2 * cutoffHz / sr
        var filter = (0..<taps).map { k -> Double in
            let m = Double(k - half)
            let sinc = m == 0 ? x : sin(.pi * x * m) / (.pi * m)
            let phase = Double(k) / Double(taps - 1)
            return sinc * (0.42 - 0.5 * cos(2 * .pi * phase) + 0.08 * cos(4 * .pi * phase))
        }
        filter = vDSP.divide(filter, vDSP.sum(filter))
        let count = range.count
        guard count > 2 * half else { return .nan }
        let angle = vDSP.multiply(-2 * .pi * fc / sr,
                                  vDSP.ramp(withInitialValue: Double(range.lowerBound), increment: 1,
                                            count: count))
        let samples = vDSP.floatToDouble(y[range])
        let re = vDSP.multiply(samples, vForce.cos(angle))
        let im = vDSP.multiply(samples, vForce.sin(angle))
        let decimation = max(1, Int((sr / 1000).rounded()))
        // Output j sits at n = n0 + half + j·D, for every n with n + half < n1.
        let outputs = (count - 2 * half - 1) / decimation + 1
        var zr = [Double](repeating: 0, count: outputs)
        var zi = [Double](repeating: 0, count: outputs)
        vDSP_desampD(re, vDSP_Stride(decimation), filter, &zr, vDSP_Length(outputs), vDSP_Length(taps))
        vDSP_desampD(im, vDSP_Stride(decimation), filter, &zi, vDSP_Length(outputs), vDSP_Length(taps))
        var times = [Double](), phases = [Double]()
        times.reserveCapacity(outputs)
        phases.reserveCapacity(outputs)
        var previous = 0.0, unwrapped = 0.0
        for j in 0..<outputs {
            let a = atan2(zi[j], zr[j])
            if j == 0 {
                unwrapped = a
            } else {
                var d = a - previous
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                unwrapped += d
            }
            previous = a
            times.append(Double(range.lowerBound + half + j * decimation) / sr)
            phases.append(unwrapped)
        }
        return fc + regressSlope(times, phases, vibratoRate: rate) / (2 * .pi)
    }

    /// Instrument B (harness3 `zcFreq`): upward zero crossings, interpolated,
    /// regressed as cycle index against time with the vibrato terms removed.
    /// Pure tones only.
    static func zeroCrossRegressHz(_ y: [Float], sampleRate sr: Double, range: Range<Int>,
                                   vibratoRate rate: Double = 0) -> Double? {
        var times = [Double](), cycles = [Double]()
        var index = 0.0
        for n in (range.lowerBound + 1)..<range.upperBound where y[n - 1] < 0 && y[n] >= 0 {
            let fraction = Double(-y[n - 1]) / (Double(y[n]) - Double(y[n - 1]))
            times.append((Double(n - 1) + fraction) / sr)
            cycles.append(2 * .pi * index)
            index += 1
        }
        guard times.count >= 8 else { return nil }
        return regressSlope(times, cycles, vibratoRate: rate) / (2 * .pi)
    }

    /// Hann-windowed power at exactly `hz` over `range` (harness3
    /// `goertzelPow`): |Σ w·y·e^(−iωn)|² / Σ w², a density estimate.
    struct HannMeter {
        let windowed: [Double]
        let indices: [Double]
        let sumSquares: Double
        let sampleRate: Double

        init(_ y: [Float], sampleRate: Double, range: Range<Int>) {
            let count = range.count
            let window = (0..<count).map { 0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(count)) }
            windowed = vDSP.multiply(window, vDSP.floatToDouble(y[range]))
            indices = vDSP.ramp(withInitialValue: Double(range.lowerBound), increment: 1, count: count)
            sumSquares = vDSP.sumOfSquares(window)
            self.sampleRate = sampleRate
        }

        func power(atHz hz: Double) -> Double {
            let angle = vDSP.multiply(-2 * .pi * hz / sampleRate, indices)
            let re = vDSP.dot(windowed, vForce.cos(angle))
            let im = vDSP.dot(windowed, vForce.sin(angle))
            return (re * re + im * im) / sumSquares
        }
    }

    /// harness3 `noiseFloor`: the mean density at the OUTPUT's inter-harmonic
    /// mid-points in 300…5000 Hz, relative to the INPUT's at its own, in dB.
    static func midpointDensityDb(output: [Float], outputF0: Double, input: [Float], inputF0: Double,
                                  sampleRate sr: Double, range: Range<Int>) -> Double {
        func meanMidpoint(_ y: [Float], _ f0: Double) -> Double {
            let meter = HannMeter(y, sampleRate: sr, range: range)
            var sum = 0.0, count = 0
            for h in 1..<200 {
                let base = f0 * Double(h)
                if base < 300 { continue }
                if base + f0 > 5000 { break }
                sum += meter.power(atHz: base + 0.5 * f0)
                count += 1
            }
            return sum / Double(count)
        }
        return 10 * log10(meanMidpoint(output, outputF0) / meanMidpoint(input, inputF0))
    }

    // MARK: - harness3's signals

    /// harness3 `vibTone`: `harmonics` partials at `amp0/h`, phase 0.7·h, each
    /// following f0·h·2^(depth/1200 · sin(2π·rate·(i + ½)/sr)); depth 0 is a
    /// steady tone. The phase is accumulated per sample, as in the harness.
    static func vibTone(sampleRate sr: Double, f0: Double, seconds: Double, depthCents: Double = 0,
                        rate: Double = 0, harmonics: Int = 1, amp0: Double = 0.5) -> [Float] {
        let n = Int((sr * seconds).rounded())
        var increment = [Double](repeating: 2 * .pi * f0 / sr, count: n)
        if depthCents != 0 && rate > 0 {
            let vibrato = vForce.sin(vDSP.ramp(withInitialValue: 2 * .pi * rate * 0.5 / sr,
                                               increment: 2 * .pi * rate / sr, count: n))
            increment = vDSP.multiply(2 * .pi * f0 / sr,
                                      vForce.exp2(vDSP.multiply(depthCents / 1200, vibrato)))
        }
        var phi = [Double](repeating: 0, count: n)
        var accumulated = 0.0
        for i in 0..<n {
            phi[i] = accumulated
            accumulated += increment[i]
        }
        var out = [Double](repeating: 0, count: n)
        for h in 1...harmonics {
            let phase = vDSP.add(0.7 * Double(h), vDSP.multiply(Double(h), phi))
            out = vDSP.add(multiplication: (vForce.sin(phase), amp0 / Double(h)), out)
        }
        return vDSP.doubleToFloat(out)
    }

    /// A steady harmonic tone, 0.3/h at phase 0.7·h, partials up to `maxHz`
    /// (harness2 `harmonic`, harness3 `lowHarm`/`noiseFloor`).
    static func harmonicTone(sampleRate sr: Double, f0: Double, seconds: Double, harmonics: Int,
                             maxHz: Double = .infinity) -> [Float] {
        let n = Int((sr * seconds).rounded())
        let index = vDSP.ramp(withInitialValue: 0.0, increment: 1, count: n)
        var out = [Double](repeating: 0, count: n)
        for h in 1...harmonics where f0 * Double(h) <= maxHz {
            let phase = vDSP.add(0.7 * Double(h), vDSP.multiply(2 * .pi * f0 * Double(h) / sr, index))
            out = vDSP.add(multiplication: (vForce.sin(phase), 0.3 / Double(h)), out)
        }
        return vDSP.doubleToFloat(out)
    }

    /// harness3 `noiseVec`: seeded LCG white noise, uniform, RMS `rms`.
    static func lcgNoise(count: Int, seed: UInt32, rms: Double) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(rms * (Double(state >> 8) / Double(1 << 24) - 0.5) * 12.0.squareRoot())
        }
    }

    /// The mean frequency of f0·2^(depth/1200 · sin) over one period (the
    /// vibrato tone's true mean pitch, harness3 `vibMeanFreq`).
    static func vibratoMeanHz(f0: Double, depthCents: Double) -> Double {
        let steps = 200_000
        var sum = 0.0
        for i in 0..<steps {
            sum += pow(2, depthCents / 1200 * sin(2 * .pi * (Double(i) + 0.5) / Double(steps)))
        }
        return f0 * sum / Double(steps)
    }

    // MARK: - Rendering and reading

    /// The two shipping entries into the stretcher. `.curve` is the note
    /// editor's loop handed a FLAT curve (one value every hop).
    enum Path: String, CaseIterable, Sendable { case constant, curve }

    static func render(_ input: [[Float]], sampleRate: Double, ratio: Double,
                       semitones: Double, formant: Bool, path: Path) throws -> [[Float]] {
        switch path {
        case .constant:
            return try OfflineStretcher.stretch(
                input: input, sampleRate: sampleRate, ratio: ratio,
                semitones: semitones, formantPreserve: formant)
        case .curve:
            return try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: sampleRate, ratio: ratio,
                semitonesAtOutputFrame: { _ in semitones }, formantPreserve: formant)
        }
    }

    struct Reading: CustomStringConvertible {
        let label: String
        let channel: Int
        let expectedHz: Double
        let slopeCents: Double
        let zeroCents: Double?
        var deltaHz: Double { expectedHz * (pow(2, slopeCents / 1200) - 1) }
        var description: String {
            let zero = zeroCents.map { String(format: "%+.3f", $0) } ?? "n/a"
            return String(format: "%@ ch%d want %.3f Hz: slope %+.3f c, zero-x %@ c (%+.3f Hz)",
                          label, channel, expectedHz, slopeCents, zero, deltaHz)
        }
    }

    /// Pure tones (one per channel), `seconds` long, transposed by `semitones`
    /// at `ratio`, read over input seconds 1…(seconds − 1) — the middle, away
    /// from both edges — scaled into output frames. The architect's harness,
    /// same window, same signal, so its numbers are comparable.
    static func readTones(_ label: String, sampleRate sr: Double, f0s: [Double],
                          semitones: Double, ratio: Double = 1, formant: Bool = false,
                          path: Path = .constant, seconds: Double = 4) throws -> [Reading] {
        let input = f0s.enumerated().map { c, f0 in
            sine(sampleRate: sr, hz: f0, seconds: seconds,
                 amplitude: c == 0 ? 0.5 : 0.4, phase: c == 0 ? 0 : 0.3)
        }
        let output = try render(input, sampleRate: sr, ratio: ratio, semitones: semitones,
                                formant: formant, path: path)
        let range = Int(1.0 * ratio * sr)..<Int((seconds - 1) * ratio * sr)
        let tag = String(format: "%@ %@ sr=%.0f st=%+.3f r=%.7g fmt=%d",
                         label, path.rawValue, sr, semitones, ratio, formant ? 1 : 0)
        return f0s.enumerated().map { c, f0 in
            let want = expectedHz(f0: f0, sampleRate: sr, semitones: semitones)
            let slope = phaseSlopeHz(output[c], sampleRate: sr, target: want, range: range)
            let zero = zeroCrossHz(output[c], sampleRate: sr, range: range)
            return Reading(label: "\(tag) f0=\(f0)", channel: c, expectedHz: want,
                           slopeCents: cents(slope, above: want),
                           zeroCents: zero.map { cents($0, above: want) })
        }
    }

    /// |err| < `limit` on BOTH instruments, and the two agree within `agree`.
    static func expectAccurate(_ readings: [Reading], limit: Double, agree: Double = 0.05,
                               leg: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for reading in readings {
            log(leg, reading.description)
            #expect(abs(reading.slopeCents) < limit,
                    "\(reading): off by more than \(limit) c", sourceLocation: sourceLocation)
            guard let zero = reading.zeroCents else {
                Issue.record("\(reading): zero-crossing instrument read nothing",
                             sourceLocation: sourceLocation)
                continue
            }
            #expect(abs(zero) < limit, "\(reading): zero-x off by more than \(limit) c",
                    sourceLocation: sourceLocation)
            #expect(abs(zero - reading.slopeCents) < agree,
                    "\(reading): the two instruments disagree — neither is evidence",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - G0 the instruments' positive controls

    /// Synthetic tones at KNOWN offsets from 233.08 Hz, no stretcher anywhere.
    /// Both instruments must read them within 0.01 c, and instrument 1 must
    /// still do so with a −20 dB interferer at 1.5×. Without this, a "0.1 c"
    /// below could be the meter's floor rather than the render's accuracy.
    @Test("G0 both instruments read known offsets (0, +5, +9.69, −3, +0.3 c) within 0.01 c")
    func instrumentsReadKnownOffsets() {
        let sr = 48_000.0, base = 233.08
        let range = 48_000..<143_999
        for offset in [0.0, 5.0, 9.69, -3.0, 0.3] {
            let hz = base * pow(2, offset / 1200)
            let tone = Self.sine(sampleRate: sr, hz: hz, seconds: 3)
            let interferer = Self.sine(sampleRate: sr, hz: hz * 1.5, seconds: 3, amplitude: 0.05)
            let mixed = zip(tone, interferer).map { $0 + $1 }
            let slope = Self.cents(Self.phaseSlopeHz(tone, sampleRate: sr, target: base, range: range),
                                   above: base)
            let slopeMixed = Self.cents(Self.phaseSlopeHz(mixed, sampleRate: sr, target: base,
                                                          range: range), above: base)
            let zero = Self.zeroCrossHz(tone, sampleRate: sr, range: range).map {
                Self.cents($0, above: base)
            }
            Self.log("G0", "planted \(offset) c: slope \(slope), slope+interferer \(slopeMixed), zero-x \(zero ?? .nan)")
            #expect(abs(slope - offset) < 0.01, "instrument 1 misreads a \(offset) c tone as \(slope)")
            #expect(abs(slopeMixed - offset) < 0.01,
                    "instrument 1 misreads a \(offset) c tone under a −20 dB interferer as \(slopeMixed)")
            #expect(abs((zero ?? .nan) - offset) < 0.01,
                    "instrument 2 misreads a \(offset) c tone as \(String(describing: zero))")
        }
    }

    /// harness3's pair on a 30 c / 5.5 Hz VIBRATO tone (1 and 8 harmonics) at
    /// planted mean offsets, against the analytic mean pitch: G16 reads mean
    /// pitch under vibrato, so its meter must read a known one to 0.01 c.
    @Test("G0 vibrato: harness3's pair reads planted 0/+1/−0.5/+5 c on a 30 c / 5.5 Hz vibrato (1 and 8 harmonics) within 0.01 c")
    func vibratoInstrumentsReadKnownOffsets() {
        let sr = 48_000.0, depth = 30.0, rate = 5.5
        let range = 48_000..<144_000
        for harmonics in [1, 8] {
            for f0 in [110.0, 220.0] {
                let truth = Self.vibratoMeanHz(f0: f0, depthCents: depth)
                for offset in [0.0, 1, -0.5, 5] {
                    let tone = Self.vibTone(sampleRate: sr, f0: f0 * pow(2, offset / 1200), seconds: 4,
                                            depthCents: depth, rate: rate, harmonics: harmonics)
                    let a = Self.cents(Self.demodHz(tone, sampleRate: sr, target: f0, range: range,
                                                    vibratoRate: rate, cutoffHz: 30, lpfSeconds: 0.25),
                                       above: truth)
                    let b = harmonics == 1
                        ? Self.zeroCrossRegressHz(tone, sampleRate: sr, range: range, vibratoRate: rate)
                            .map { Self.cents($0, above: truth) }
                        : nil
                    Self.log("G0-vib", "h=\(harmonics) f0=\(f0) planted \(offset) c: A \(a), B \(b.map { "\($0)" } ?? "n/a")")
                    #expect(abs(a - offset) < 0.01, "instrument A misreads a planted \(offset) c vibrato mean as \(a)")
                    if harmonics == 1 {
                        #expect(abs((b ?? .nan) - offset) < 0.01,
                                "instrument B misreads a planted \(offset) c vibrato mean as \(String(describing: b))")
                    }
                }
            }
        }
    }

    /// The extremes the new gates read: a 27.5 Hz sine (G12's lowest output,
    /// where a 50 ms block cannot separate the partial from its own negative-
    /// frequency image) with instrument A at G12's settings; h1…h6 of a
    /// 41.2 Hz 12-harmonic tone at G14's settings; and the noise-density meter
    /// (G15) on a known −20 dB scale and a known −6 dB re-grid.
    @Test("G0 extremes: instrument A reads planted 0/+5 c at 27.5 Hz and on h1…h6 of a 41.2 Hz tone within 0.01 c; the density meter reads a planted −20 dB and −6 dB")
    func extremeInstrumentsReadKnownValues() {
        let sr = 48_000.0
        let range = 48_000..<144_000
        for offset in [0.0, 5] {
            let hz = 27.5 * pow(2, offset / 1200)
            let tone = Self.vibTone(sampleRate: sr, f0: hz, seconds: 4)
            let a = Self.cents(Self.demodHz(tone, sampleRate: sr, target: 27.5, range: range,
                                            cutoffHz: 20, lpfSeconds: 0.25), above: 27.5)
            let b = Self.zeroCrossRegressHz(tone, sampleRate: sr, range: range).map { Self.cents($0, above: 27.5) }
            Self.log("G0-low", "27.5 Hz planted \(offset) c: A \(a), B \(b.map { "\($0)" } ?? "n/a")")
            #expect(abs(a - offset) < 0.01, "instrument A misreads 27.5 Hz +\(offset) c as \(a)")
            #expect(abs((b ?? .nan) - offset) < 0.01, "instrument B misreads 27.5 Hz +\(offset) c as \(String(describing: b))")

            let f0 = 41.2 * pow(2, offset / 1200)
            let low = Self.harmonicTone(sampleRate: sr, f0: f0, seconds: 4, harmonics: 12)
            for h in 1...6 {
                let want = 41.2 * Double(h)
                let e = Self.cents(Self.demodHz(low, sampleRate: sr, target: want, range: range,
                                                cutoffHz: 0.3 * 41.2, lpfSeconds: 0.5), above: want)
                Self.log("G0-low", "41.2 Hz h\(h) planted \(offset) c: A \(e)")
                #expect(abs(e - offset) < 0.01, "instrument A misreads 41.2 Hz h\(h) +\(offset) c as \(e)")
            }
        }

        // The density meter. (a) The same tone with its noise scaled by 0.1 must
        // read −20 dB on the same grid (identical noise, so exactly). (b) An
        // "ideal +12 st output" — the tone an octave up, with the same noise
        // −6 dB — must read −6 dB on the octave's grid (different noise bins,
        // so within the estimate's spread).
        let n = Int(6 * sr)
        let window = Int(1.5 * sr)..<Int(5.5 * sr)
        let noise = Self.lcgNoise(count: n, seed: 4242, rms: 0.01)
        let tone55 = Self.harmonicTone(sampleRate: sr, f0: 55, seconds: 6, harmonics: 60, maxHz: 3500)
        let input = zip(tone55, noise).map { $0 + $1 }
        let quieter = zip(tone55, noise).map { $0 + 0.1 * $1 }
        let scaled = Self.midpointDensityDb(output: quieter, outputF0: 55, input: input, inputF0: 55,
                                            sampleRate: sr, range: window)
        let tone110 = Self.harmonicTone(sampleRate: sr, f0: 110, seconds: 6, harmonics: 60, maxHz: 7000)
        let ideal = zip(tone110, noise).map { $0 + Float(pow(10, -6.0 / 20)) * $1 }
        let regrid = Self.midpointDensityDb(output: ideal, outputF0: 110, input: input, inputF0: 55,
                                            sampleRate: sr, range: window)
        Self.log("G0-density", "planted −20 dB reads \(scaled) dB; planted −6 dB on the octave grid reads \(regrid) dB")
        #expect(abs(scaled + 20) < 0.05, "the density meter misreads a planted −20 dB as \(scaled)")
        #expect(abs(regrid + 6) < 2, "the density meter misreads a planted −6 dB on the octave grid as \(regrid)")
    }

    // MARK: - G1 0 st is byte-identical to the pristine header

    /// Digests CAPTURED ON THE PRISTINE HEADER (sha256 `1188667959ac…`,
    /// 2026-09-25, debug configuration — the configuration `./scripts/test.sh`
    /// builds; -O2 renders are different, equally valid bytes). The 0-st
    /// entries must never move: at 0 st `mappedFrequencies` is false, every
    /// output bin reads an integer input bin, and 0001's `fracIndex == 0`
    /// branch runs the upstream expression verbatim; 0002 runs only when
    /// frequencies are mapped; and ratios 1.5, 0.8 and exactly 1 are outside
    /// 0003's near-unity window (G1+ covers the inside). The two `control-` entries
    /// are the PRISTINE digests of transposed renders and must DIFFER now —
    /// proof that the patched header is the one compiled into this binary.
    ///
    /// Captured, not chosen: at 0 st formant-preserve is a no-op (the `-fmt`
    /// twins share a digest), and the curve loop at ratio 1.5 renders the
    /// constant loop's bytes. Both are pristine facts, pinned as found.
    static let g1Pristine: [String: String] = [
        "const-sine-r1.5": "418fb20a95c9959f67754422aa1a7fae567f9e0106db910b365bbbce2a29d089",
        "const-sine-r1.5-fmt": "418fb20a95c9959f67754422aa1a7fae567f9e0106db910b365bbbce2a29d089",
        "const-sine-r0.8": "1bdc072104e19c30e80ba1a9e68fbb6f93274022c1b65b436cee4327a8252aa2",
        "const-sine-r0.8-fmt": "1bdc072104e19c30e80ba1a9e68fbb6f93274022c1b65b436cee4327a8252aa2",
        "const-stereo-r1.5": "b362baaca4ace6d8b9535b1aae75dd0f2a02717725a1be5680c1d549c9f008a9",
        "const-stereo-r1.5-fmt": "b362baaca4ace6d8b9535b1aae75dd0f2a02717725a1be5680c1d549c9f008a9",
        "const-stereo-r0.8": "5f505d7f0a072b96ae7d0abc603df3373f6058247348fd03d60f1414eb8ff5d8",
        "const-stereo-r0.8-fmt": "5f505d7f0a072b96ae7d0abc603df3373f6058247348fd03d60f1414eb8ff5d8",
        "const-stereo44-r1.5": "4935ed8226e2c3e1fcd23d68b1484d4ee13236422863e7c68e608d03ca608400",
        "const-stereo44-r0.8-fmt": "33dc70f1e0714cf30628461510baeee8d7c461ce50efb8b693fe326abd843f21",
        "curve-sine-r1.0": "1c42ca342a3f559fca7652e3f4d7d698bf6883a2e222602a864168aaa17edb4b",
        "curve-sine-r1.5": "418fb20a95c9959f67754422aa1a7fae567f9e0106db910b365bbbce2a29d089",
        "curve-stereo-r1.0": "d9ede9e75844f103c79c15101eedb5e336fd39eac8afaac998cd2d4615880188",
        "curve-stereo-r1.5": "b362baaca4ace6d8b9535b1aae75dd0f2a02717725a1be5680c1d549c9f008a9",
        "curve-stereo-r1.5-fmt": "b362baaca4ace6d8b9535b1aae75dd0f2a02717725a1be5680c1d549c9f008a9",
        // PRISTINE digests of transposed renders: these must now DIFFER.
        "control-const-sine-+1st": "d494bfcd683d02aa0684990c633a277a06994fc450e70473e3b37387ab9d0174",
        "control-curve-sine--0.25st": "43c5081aa893bc8706bd6dede45c30cf219939fb1229ac15cd687097e65cc020",
    ]

    struct G1Case {
        let name: String
        let input: [[Float]]
        let sampleRate: Double
        let ratio: Double
        let semitones: Double
        let formant: Bool
        let path: Path
        var isControl: Bool { name.hasPrefix("control-") }
    }

    static func g1Cases() -> [G1Case] {
        let sine48 = [sine(sampleRate: 48_000, hz: 220, seconds: 2)]
        let stereo48 = [harmonicNoise(sampleRate: 48_000, f0: 165, seconds: 2, seed: 12_345),
                        harmonicNoise(sampleRate: 48_000, f0: 220, seconds: 2, seed: 12_346)]
        let stereo44 = [harmonicNoise(sampleRate: 44_100, f0: 165, seconds: 2, seed: 12_345),
                        harmonicNoise(sampleRate: 44_100, f0: 220, seconds: 2, seed: 12_346)]
        var cases: [G1Case] = []
        for (label, input) in [("sine", sine48), ("stereo", stereo48)] {
            for ratio in [1.5, 0.8] {
                for formant in [false, true] {
                    cases.append(G1Case(name: "const-\(label)-r\(ratio)\(formant ? "-fmt" : "")",
                                        input: input, sampleRate: 48_000, ratio: ratio,
                                        semitones: 0, formant: formant, path: .constant))
                }
            }
            for ratio in [1.0, 1.5] {
                cases.append(G1Case(name: "curve-\(label)-r\(ratio)", input: input,
                                    sampleRate: 48_000, ratio: ratio, semitones: 0,
                                    formant: false, path: .curve))
            }
        }
        cases.append(G1Case(name: "curve-stereo-r1.5-fmt", input: stereo48, sampleRate: 48_000,
                            ratio: 1.5, semitones: 0, formant: true, path: .curve))
        cases.append(G1Case(name: "const-stereo44-r1.5", input: stereo44, sampleRate: 44_100,
                            ratio: 1.5, semitones: 0, formant: false, path: .constant))
        cases.append(G1Case(name: "const-stereo44-r0.8-fmt", input: stereo44, sampleRate: 44_100,
                            ratio: 0.8, semitones: 0, formant: true, path: .constant))
        cases.append(G1Case(name: "control-const-sine-+1st", input: sine48, sampleRate: 48_000,
                            ratio: 1, semitones: 1, formant: false, path: .constant))
        cases.append(G1Case(name: "control-curve-sine--0.25st", input: sine48, sampleRate: 48_000,
                            ratio: 1, semitones: -0.25, formant: false, path: .curve))
        return cases
    }

    @Test("G1 0 st renders the pristine header's exact bytes; a transposed render does not (control)")
    func zeroSemitonesIsByteIdenticalToPristine() throws {
        let cases = Self.g1Cases()
        #expect(cases.filter(\.isControl).count == 2, "the positive controls are in the list")
        for item in cases {
            let rendered = try Self.render(item.input, sampleRate: item.sampleRate,
                                           ratio: item.ratio, semitones: item.semitones,
                                           formant: item.formant, path: item.path)
            let frames = Int((Double(item.input[0].count) * item.ratio).rounded())
            #expect(rendered.count == item.input.count && rendered.allSatisfy { $0.count == frames })
            #expect(rendered.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(item.name): NaN/Inf in the render")
            let hex = Self.digest(rendered)
            Self.log("G1", "\"\(item.name)\": \"\(hex)\",")
            guard let pristine = Self.g1Pristine[item.name] else {
                Issue.record("\(item.name): no pristine digest pinned")
                continue
            }
            if item.isControl {
                #expect(hex != pristine,
                        "\(item.name) still renders the PRISTINE header's bytes: the patch is not in this binary")
            } else {
                #expect(hex == pristine,
                        "\(item.name): a 0 st render moved (\(hex)) — the patch leaked into the integer-bin path")
            }
        }
    }

    // MARK: - G1+ 0 st at near-unity ratios: what 0003 moved, and what it did not

    /// Patch 0003 re-analyses the previous spectrum whenever a hop's input
    /// interval is not exactly H, so it moves 0-st bytes ONLY where some hop is
    /// H±1: ratios within ~2.6/H of 1 (H = 1440 at 48 kHz, 1323 at 44.1 kHz).
    ///
    /// * `control-nearunity-*` — CAPTURED ON THE 0001-ONLY HEADER (sha256
    ///   `2de8f20b…`, `transposeEngineVersion` 3), 2026-09-25, debug. These
    ///   must now DIFFER: proof that 0003 is in this binary.
    /// * `zero-nearunity-*` — the same renders captured AFTER 0002+0003
    ///   (header `80d11216…`). Must not move.
    /// * `zero-outside-*` — r = 1.003 at 48 kHz (|1 − r|·H = 4.3, outside the
    ///   window): captured on the 0001-only header and must STILL match — 0003
    ///   changes nothing outside its window, and 0002 nothing at 0 st.
    ///
    /// 64.0625/64 is a 64-beat clip dragged by one 1/16 (`stretchClip`).
    static let g1NearUnity: [String: String] = [
        // Step 0, the 0001-only header: 0003 must have MOVED these.
        "control-nearunity-constant-sine44-r1.0005": "e5ca9f664dd8c9a3190981e6bf2b983feae4271e5383ae0c8eac47a9953e8e4e",
        "control-nearunity-constant-sine48-r1.0009766": "7d5723b49a8b6581255139c128fd1d174cbd609120767f8e2b3ad4bccfb39f86",
        "control-nearunity-constant-stereo44-r1.0005": "bf0daf2f44897e7b769ae7e115338b6dd021299d6fadc22208238eac2467a8cd",
        "control-nearunity-constant-stereo48-r1.0009766": "c427f9dfc0db5974a1ad730ed1d2488a0b406720dc8a26e06850b94ff1682afd",
        "control-nearunity-curve-sine44-r1.0005": "f51efe7ee287cb7374f7e3653dc53221da7d9925f989836456a14e7054084d75",
        "control-nearunity-curve-sine48-r1.0009766": "a24ddf0033b87f953fb9a760ae76fa20bec247516a08be374335c4caacc61fae",
        "control-nearunity-curve-stereo44-r1.0005": "2cefe3352fa02cb708b14bfbaea92259511d82c007aec586cda901a56fa5de2c",
        "control-nearunity-curve-stereo48-r1.0009766": "913ee95ef249d42303943d1f93120f2d9ce66249ff4d6992333323e4a5ff3d35",
        // After 0002+0003 (header 80d11216…): must not move.
        "zero-nearunity-constant-sine44-r1.0005": "ba8c6acd09fd22135acb4bb5a7159a5813a4a5a9686d2a1d5cbf61c33bd91de3",
        "zero-nearunity-constant-sine48-r1.0009766": "82a4579bacdeed5a844f241959a9f377aaed271a415753e8847933df6562d94b",
        "zero-nearunity-constant-stereo44-r1.0005": "5bb643034f7e9de975471b0a7b9fe43d8fd83bc76977800579013fda3b3567d5",
        "zero-nearunity-constant-stereo48-r1.0009766": "5cb6e6c325bbc8a462a54fd4cb7b3814c01dfc09ecda59a3cb1391d51cd03b46",
        "zero-nearunity-curve-sine44-r1.0005": "e7d13d31210ecf8dcaaeeff03349f6cb9635fea22194f8623c7922d0488ae7ef",
        "zero-nearunity-curve-sine48-r1.0009766": "99602e8f45f50bd233934741c0662e2646d59ef154b4ed22737ce501e2ef447f",
        "zero-nearunity-curve-stereo44-r1.0005": "d9ce236ca72b2a94dd10456168c161b7ff5bfd405ef3171d600fc75ca2672ab9",
        "zero-nearunity-curve-stereo48-r1.0009766": "9866bccdb0c221079077acc38e12c95ef0c17b2a4f7a29edfd3446fc7260e353",
        // Step 0, the 0001-only header, OUTSIDE the window: must NOT have moved.
        "zero-outside-constant-sine48-r1.003": "5aec0c18cb2b915aa4fe498b9b9ecc8242999becf3d8444e26bb99143603bea5",
        "zero-outside-constant-stereo48-r1.003": "25af4b85056044fe292ef3c5a023a4a95feaed8af9df044be9a2d0d70dd4e69c",
        "zero-outside-curve-sine48-r1.003": "e089a611052b6df7efecba81eee0eded154d5051193448ed5f7577c31aa3483b",
        "zero-outside-curve-stereo48-r1.003": "f57a283971db0f7c2d6934cb33b7cef511173dce398e32689098d03704ff706d",
    ]

    struct G1NearUnityCase {
        let name: String
        let input: [[Float]]
        let sampleRate: Double
        let ratio: Double
        let path: Path
        let insideWindow: Bool
    }

    static func g1NearUnityCases() -> [G1NearUnityCase] {
        let sine48 = [sine(sampleRate: 48_000, hz: 220, seconds: 2)]
        let sine44 = [sine(sampleRate: 44_100, hz: 220, seconds: 2)]
        let stereo48 = [harmonicNoise(sampleRate: 48_000, f0: 165, seconds: 2, seed: 12_345),
                        harmonicNoise(sampleRate: 48_000, f0: 220, seconds: 2, seed: 12_346)]
        let stereo44 = [harmonicNoise(sampleRate: 44_100, f0: 165, seconds: 2, seed: 12_345),
                        harmonicNoise(sampleRate: 44_100, f0: 220, seconds: 2, seed: 12_346)]
        var cases: [G1NearUnityCase] = []
        let legs: [(tag: String, input: [[Float]], sr: Double, ratio: Double, label: String, inside: Bool)] = [
            ("sine48", sine48, 48_000, 64.0625 / 64, "r1.0009766", true),
            ("stereo48", stereo48, 48_000, 64.0625 / 64, "r1.0009766", true),
            ("sine44", sine44, 44_100, 1.0005, "r1.0005", true),
            ("stereo44", stereo44, 44_100, 1.0005, "r1.0005", true),
            ("sine48", sine48, 48_000, 1.003, "r1.003", false),
            ("stereo48", stereo48, 48_000, 1.003, "r1.003", false),
        ]
        for leg in legs {
            for path in Path.allCases {
                cases.append(G1NearUnityCase(name: "\(path.rawValue)-\(leg.tag)-\(leg.label)",
                                             input: leg.input, sampleRate: leg.sr, ratio: leg.ratio,
                                             path: path, insideWindow: leg.inside))
            }
        }
        return cases
    }

    @Test("G1+ 0 st inside 0003's window MOVED from the 0001-only bytes and is pinned; outside it (r = 1.003) nothing moved")
    func nearUnityZeroSemitonesArePinned() throws {
        let cases = Self.g1NearUnityCases()
        #expect(cases.filter(\.insideWindow).count == 8 && cases.filter { !$0.insideWindow }.count == 4)
        for item in cases {
            let rendered = try Self.render(item.input, sampleRate: item.sampleRate, ratio: item.ratio,
                                           semitones: 0, formant: false, path: item.path)
            let frames = Int((Double(item.input[0].count) * item.ratio).rounded())
            #expect(rendered.count == item.input.count && rendered.allSatisfy { $0.count == frames })
            #expect(rendered.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(item.name): NaN/Inf in the render")
            let hex = Self.digest(rendered)
            Self.log("G1+", "\"\(item.insideWindow ? "zero-nearunity" : "zero-outside")-\(item.name)\": \"\(hex)\",")
            if item.insideWindow {
                guard let before = Self.g1NearUnity["control-nearunity-\(item.name)"],
                      let after = Self.g1NearUnity["zero-nearunity-\(item.name)"] else {
                    Issue.record("\(item.name): no near-unity digests pinned")
                    continue
                }
                #expect(hex != before,
                        "\(item.name) still renders the 0001-only bytes: patch 0003 is not in this binary")
                #expect(hex == after, "\(item.name): a near-unity 0 st render moved (\(hex))")
            } else {
                guard let pinned = Self.g1NearUnity["zero-outside-\(item.name)"] else {
                    Issue.record("\(item.name): no digest pinned")
                    continue
                }
                #expect(hex == pinned,
                        "\(item.name): a 0 st render OUTSIDE 0003's window moved (\(hex)) — the patch leaked")
            }
        }
    }

    // MARK: - G2 accuracy, small moves (|shift| ≤ 3 st): |err| < 0.05 c

    // The bound was 0.5 c, sized for 0001 alone (worst 0.42 c, the centroid
    // and lobe-curvature errors 0002 removed). With 0002+0003 harness2 reads
    // ≤ 0.009 c on every G2 leg (-O2), so 0.05 c.

    /// The shifts the review's G2 names, in cents, on a 220 Hz sine.
    static let g2TableCents: [Double] = [25, -25, 50, -50, 60, -60, 85, -85, 100, -100,
                                        125, -125, 150, -150, 200, -200, 300]

    /// ⭐ 0001'S TRIPWIRE. Pristine: +100 c renders +9.69 c sharp at 48 kHz;
    /// a re-vendor that drops 0001 fails here first. 0001 alone read ≤ 0.42 c
    /// here (+300 c at 48 kHz the worst); 0002 took that to ≤ 0.01 c.
    @Test("G2a 220 Hz × ±25…±200, +300 c at 48 and 44.1 kHz lands within 0.05 c",
          arguments: [48_000.0, 44_100.0])
    func smallMovesLandAt220(sr: Double) throws {
        for c in Self.g2TableCents {
            Self.expectAccurate(try Self.readTones("G2a", sampleRate: sr, f0s: [220],
                                                   semitones: c / 100),
                                limit: 0.05, leg: "G2a")
        }
    }

    /// The error was periodic in frac(shift in bins), so a fixed note hides
    /// most of it: sweep f0 at +100 c across the vocal range.
    @Test("G2b f0 150…400 Hz at +100 c lands within 0.05 c",
          arguments: [48_000.0, 44_100.0])
    func sweepAtPlus100(sr: Double) throws {
        for f0 in stride(from: 150.0, through: 400.0, by: 12.5) {
            Self.expectAccurate(try Self.readTones("G2b", sampleRate: sr, f0s: [f0],
                                                   semitones: 1),
                                limit: 0.05, leg: "G2b")
        }
    }

    /// The error was ~constant in Hz, so in cents it grew as 1/f: pristine read
    /// +42.1 c at 55 Hz −1 st (a −100 c move landing at −58 c).
    @Test("G2c low f0 (55, 65.41, 82.41, 110 Hz) × ±25, ±100 c lands within 0.05 c",
          arguments: [48_000.0, 44_100.0])
    func lowNotesLand(sr: Double) throws {
        for f0 in [55.0, 65.41, 82.41, 110.0] {
            for c in [25.0, -25, 100, -100] {
                Self.expectAccurate(try Self.readTones("G2c", sampleRate: sr, f0s: [f0],
                                                       semitones: c / 100),
                                    limit: 0.05, leg: "G2c")
            }
        }
    }

    /// Stretch + transpose. The fix turns by the SYNTHESIS hop (the hop the
    /// `rot` pass used, because the previous spectrum is always re-analysed
    /// that far back); the input hop would read up to −8.1 c at ratio 0.5.
    @Test("G2d ratio 0.5/0.8/1.25/1.5 × +100, −50, +25, +150 c lands within 0.05 c",
          arguments: [48_000.0, 44_100.0])
    func stretchedMovesLand(sr: Double) throws {
        for ratio in [0.5, 0.8, 1.25, 1.5] {
            for c in [100.0, -50, 25, 150] {
                Self.expectAccurate(try Self.readTones("G2d", sampleRate: sr, f0s: [220],
                                                       semitones: c / 100, ratio: ratio),
                                    limit: 0.05, leg: "G2d")
            }
        }
    }

    /// Two channels with different partials share one output map; and
    /// formant-preserve rescales energy only (it never touches phase).
    @Test("G2e stereo L 220 / R 330 and formant-preserve ON land within 0.05 c")
    func stereoAndFormantLand() throws {
        for ratio in [1.0, 1.5] {
            for c in [100.0, -50] {
                Self.expectAccurate(try Self.readTones("G2e-stereo", sampleRate: 48_000,
                                                       f0s: [220, 330], semitones: c / 100,
                                                       ratio: ratio),
                                    limit: 0.05, leg: "G2e")
            }
            for c in [100.0, -50, 25] {
                Self.expectAccurate(try Self.readTones("G2e-formant", sampleRate: 48_000,
                                                       f0s: [220], semitones: c / 100,
                                                       ratio: ratio, formant: true),
                                    limit: 0.05, leg: "G2e")
            }
        }
    }

    /// The note editor's path: the curve loop handed one flat value every hop.
    /// It ran the same bytes as the constant path under the pristine header
    /// (measured, investigation L3), so a representative subset of the legs
    /// above is enough — the full table runs through the constant entry.
    @Test("G2f the curve loop (flat curve) lands within 0.05 c on a subset of every leg")
    func curvePathLands() throws {
        let subset: [(sr: Double, f0: Double, cents: Double, ratio: Double, formant: Bool)] = [
            (48_000, 220, 100, 1, false), (48_000, 220, -25, 1, false),
            (48_000, 220, -150, 1, false), (48_000, 220, 300, 1, false),
            (44_100, 220, 100, 1, false), (48_000, 55, -100, 1, false),
            (48_000, 220, 100, 1.5, false), (48_000, 220, -50, 0.5, false),
            (48_000, 220, 100, 1, true),
        ]
        for leg in subset {
            Self.expectAccurate(try Self.readTones("G2f", sampleRate: leg.sr, f0s: [leg.f0],
                                                   semitones: leg.cents / 100, ratio: leg.ratio,
                                                   formant: leg.formant, path: .curve),
                                limit: 0.05, leg: "G2f")
        }
    }

    // MARK: - G3 large shifts: an accuracy gate

    /// ±5/±7/±12 st on the 8 notes of harness2's `large` table, both rates.
    /// Before 0002 this was a CHARACTERISATION (|Δf| < 0.75 Hz): 0001 alone
    /// left an energy-centroid peak position (biased toward bin centres) and a
    /// smoothstep that bent the offset inside each peak's own main lobe —
    /// up to 12.2 c (mean 1.62 c), worst on octave-down low notes. 0002 fixes
    /// both; harness2 reads ≤ 0.007 c on all 96 cases (-O2). 0002's tripwire:
    /// a re-vendor that drops it fails here at several cents.
    @Test("G3 ±5/±7/±12 st × 82…440 Hz (8 notes) at 48 and 44.1 kHz lands within 0.05 c",
          arguments: [48_000.0, 44_100.0], [5.0, -5, 7, -7, 12, -12])
    func largeShiftsLand(sr: Double, st: Double) throws {
        for f0 in [82.41, 110, 146.83, 196, 220, 261.63, 329.63, 440] {
            Self.expectAccurate(try Self.readTones("G3", sampleRate: sr, f0s: [f0], semitones: st),
                                limit: 0.05, leg: "G3")
        }
    }

    // MARK: - G4 the random-phase regime (timeFactor > 2)

    /// At ratio 2.5 upstream randomises phase; the two instruments may differ
    /// by a few tenths there (measured 0.27 c), so only the bound is asserted.
    /// Worst case +1.5 st at 48 kHz: 0.799 c with 0001 alone, 0.862 c with
    /// 0002+0003 (debug and -O2 agree to 0.001 c). The review's rule — raise
    /// to 1.25 c only if debug reads over 0.9 — does not trigger.
    @Test("G4 ratio 2.5 × +100, −50, +25, +150 c at 48 and 44.1 kHz lands within 1.0 c",
          arguments: [48_000.0, 44_100.0])
    func randomPhaseRegimeLands(sr: Double) throws {
        for c in [100.0, -50, 25, 150] {
            Self.expectAccurate(try Self.readTones("G4", sampleRate: sr, f0s: [220],
                                                   semitones: c / 100, ratio: 2.5),
                                limit: 1.0, agree: 0.5, leg: "G4")
        }
    }

    // MARK: - G9 the scoped cache re-key

    /// Cached renders made by an older transposer are off pitch. The re-key
    /// retires exactly the keys whose AUDIO the patches can change — a
    /// transpose, any pitch-edit set (an over-approximation: a timing-only set
    /// renders at 0 st and re-renders needlessly, once), and, since 0003, a
    /// 0-st edit-free render within ±`nearUnityRatioBand` of ratio 1 — and
    /// leaves every other 0-st, edit-free key alone, because those bytes are
    /// proven unchanged (G1/G1+) and a moved key would silence and re-render
    /// every time-stretched clip.
    ///
    /// ⚠️ The review's brief said "0.97 must NOT re-key". Under its own band
    /// (|1 − r| < 0.05) 0.97 is INSIDE and must re-key; 0.94 is the outside
    /// leg symmetric with 1.06. The edges are pinned at 1.049/1.051 and
    /// 0.951/0.949 and against the band constant, never at a literal 1.05:
    /// `1.05 - 1.0` is 0.050000000000000044, a floating-point accident.
    @Test("G9 0 st without edits keeps its key outside ±5 % of ratio 1; a transpose, an edit set, or a near-unity 0 st render re-keys by exactly `pv:`")
    func scopedRekey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2-acc-g9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        // The key reads only the file's identity (path, size, mtime).
        try Data(repeating: 7, count: 256).write(to: source)

        /// The field list as it stood BEFORE p2-acc (no `pv:` field), restated.
        func prePatchFields(_ params: StretchRenderCache.Params) throws -> [String] {
            var fields = try StretchRenderCache.sourceIdentityFields(source: source)
            fields += [String(params.ratio.bitPattern), String(params.semitones.bitPattern),
                       params.formantPreserve ? "1" : "0",
                       String(StretchRenderCache.stretchEngineVersion)]
            if !params.pitchEditSetHash.isEmpty { fields.append("pitch:" + params.pitchEditSetHash) }
            return fields
        }
        func keys(_ params: StretchRenderCache.Params) throws -> StretchRenderCache.RenderKeys {
            try StretchRenderCache.renderKeys(source: source, params: params, detector: .product)
        }

        let detectedOnly = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.4, detectedHz: 220, detectedConfidence: 0.9)])
        let edited = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.4, detectedHz: 220, detectedConfidence: 0.9,
                        pitchOffsetCents: 25)])
        let timingOnly = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.4, detectedHz: 220, detectedConfidence: 0.9,
                        timeEndDeltaSeconds: 0.05)])
        #expect(PitchEditSetDigest.hex(detectedOnly).isEmpty, "fixture: a detected-only set bends nothing")
        #expect(!PitchEditSetDigest.hex(timingOnly).isEmpty, "fixture: a timing-only set has a digest")

        let unchanged: [(String, StretchRenderCache.Params)] = [
            ("time-stretch only r1.5", .init(ratio: 1.5, semitones: 0, formantPreserve: false)),
            ("time-stretch only r0.8 + formant", .init(ratio: 0.8, semitones: 0, formantPreserve: true)),
            ("detected-only notes r1.25", .init(ratio: 1.25, semitones: 0, formantPreserve: false,
                                                pitchEdits: detectedOnly)),
            // Outside the near-unity band: 0003 cannot reach these bytes.
            ("time-stretch only r1.06", .init(ratio: 1.06, semitones: 0, formantPreserve: false)),
            ("time-stretch only r0.94", .init(ratio: 0.94, semitones: 0, formantPreserve: false)),
            ("band edge r1.051", .init(ratio: 1.051, semitones: 0, formantPreserve: false)),
            ("band edge r0.949 + formant", .init(ratio: 0.949, semitones: 0, formantPreserve: true)),
        ]
        for (label, params) in unchanged {
            let key = try keys(params)
            let golden = StretchRenderCache.keyDigest(try prePatchFields(params))
            #expect(key.resolved == golden && key.legacy == golden,
                    "\(label): a 0 st edit-free key moved — every cached time-stretch is orphaned for unchanged bytes")
        }

        // 0-st, edit-free, inside the band: 0003 moved these bytes (G1+), so
        // they re-key — and the key the p2-acc predicate made for them
        // (`semitones != 0 || digest`, no `pv:` at 0 st) must NOT be it.
        let nearUnity: [(String, StretchRenderCache.Params)] = [
            ("0 st r64.0625/64 (a 64-beat clip dragged one 1/16)",
             .init(ratio: 64.0625 / 64, semitones: 0, formantPreserve: false)),
            ("0 st r1.0005 + formant", .init(ratio: 1.0005, semitones: 0, formantPreserve: true)),
            ("0 st r0.9995", .init(ratio: 0.9995, semitones: 0, formantPreserve: false)),
            ("0 st r0.97 (inside the band)", .init(ratio: 0.97, semitones: 0, formantPreserve: false)),
            ("band edge r1.049", .init(ratio: 1.049, semitones: 0, formantPreserve: false)),
            ("band edge r0.951", .init(ratio: 0.951, semitones: 0, formantPreserve: false)),
            ("detected-only notes r1.0005", .init(ratio: 1.0005, semitones: 0, formantPreserve: false,
                                                  pitchEdits: detectedOnly)),
        ]
        /// The p2-acc key (transposeEngineVersion 2/3): `pv:` only for a
        /// transpose or an edit set. The near-unity legs must FAIL against it.
        func oldPredicateKey(_ params: StretchRenderCache.Params) throws -> String {
            var fields = try prePatchFields(params)
            if params.semitones != 0 || !params.pitchEditSetHash.isEmpty {
                fields.append("pv:\(StretchRenderCache.transposeEngineVersion)")
            }
            return StretchRenderCache.keyDigest(fields)
        }
        for (label, params) in nearUnity {
            #expect(StretchRenderCache.phaseVocoderNearUnity(params.ratio), "\(label): outside the band")
            #expect(try keys(params).legacy != oldPredicateKey(params),
                    "\(label): a near-unity 0 st render keeps the key the p2-acc predicate gave it — the pre-0003 bytes would keep playing")
        }

        // The band, pinned against its own constant on both sides.
        let band = StretchRenderCache.nearUnityRatioBand
        #expect(!StretchRenderCache.phaseVocoderNearUnity(1), "ratio 1 is identity, never a near-unity render")
        #expect(StretchRenderCache.phaseVocoderNearUnity(1 + 0.98 * band)
                && StretchRenderCache.phaseVocoderNearUnity(1 - 0.98 * band))
        #expect(!StretchRenderCache.phaseVocoderNearUnity(1 + 1.02 * band)
                && !StretchRenderCache.phaseVocoderNearUnity(1 - 1.02 * band))
        // …and against the window it must cover: 0003 changes bytes only
        // within |1 − r|·H ≤ 2.58 (measured, constant loop, 60 s files), with
        // H READ from the stretcher. The band must cover that twice over at
        // every rate down to 4 kHz, or a changed render keeps a stale key.
        for sr in [4_000.0, 8_000, 22_050, 44_100, 48_000, 96_000] {
            let handle = try #require(css_create(1, Float(sr), 1))
            defer { css_destroy(handle) }
            let hop = Double(css_interval_samples(handle))
            #expect(band * hop > 2 * 2.58,
                    "at \(sr) Hz (H = \(hop)) the band covers |1 − r|·H ≤ \(band * hop), under 2× 0003's measured window")
        }

        let rekeyed: [(String, StretchRenderCache.Params)] = [
            ("+1 st", .init(ratio: 1, semitones: 1, formantPreserve: false)),
            ("−0.25 st r1.5 + formant", .init(ratio: 1.5, semitones: -0.25, formantPreserve: true)),
            ("edited +25 c", .init(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: edited)),
            ("timing-only set", .init(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: timingOnly)),
        ] + nearUnity
        #expect(StretchRenderCache.transposeEngineVersion >= 4,
                "1 was the implicit pristine engine; 4 is the first with 0002+0003")
        for (label, params) in rekeyed {
            let key = try keys(params)
            let fields = try prePatchFields(params)
            #expect(key.legacy != StretchRenderCache.keyDigest(fields),
                    "\(label): a transposed/edited render kept its pre-patch key — the sharp cached audio would keep playing")
            #expect(key.legacy == StretchRenderCache.keyDigest(
                fields + ["pv:\(StretchRenderCache.transposeEngineVersion)"]),
                    "\(label): the re-key is not exactly the `pv:` field after the edit digest")
        }
    }

    // MARK: - G12 ±19/±24 st on sines

    /// The far end of the clip-transpose range. 0001 alone read up to 76 c
    /// here: the centroid and lobe-curvature errors are near-constant in Hz,
    /// so they are huge in cents at a low output. 0002 reads 0.000 c (harness3,
    /// -O2). harness3's instruments at G0's 27.5 Hz settings: 110 Hz −24 st
    /// is a 27.5 Hz output, which a 50 ms block cannot separate from its own
    /// negative-frequency image.
    @Test("G12 ±19/±24 st on 110/220 Hz sines lands within 0.05 c on both of harness3's instruments",
          arguments: [48_000.0, 44_100.0])
    func extraLargeShiftsLand(sr: Double) throws {
        let range = Int(sr)..<Int(3 * sr)
        for f0 in [110.0, 220] {
            let tone = Self.vibTone(sampleRate: sr, f0: f0, seconds: 4)
            for st in [19.0, 24, -19, -24] {
                let want = Self.expectedHz(f0: f0, sampleRate: sr, semitones: st)
                let out = try Self.render([tone], sampleRate: sr, ratio: 1, semitones: st,
                                          formant: false, path: .constant)[0]
                let a = Self.cents(Self.demodHz(out, sampleRate: sr, target: want, range: range,
                                                cutoffHz: 20, lpfSeconds: 0.25), above: want)
                let b = Self.zeroCrossRegressHz(out, sampleRate: sr, range: range).map { Self.cents($0, above: want) }
                Self.log("G12", String(format: "sr=%.0f f0=%.0f st=%+.0f want %.3f Hz: A %+.4f c, B %+.4f c",
                                       sr, f0, st, want, a, b ?? .nan))
                #expect(abs(a) < 0.05, "G12 sr=\(sr) f0=\(f0) st=\(st): instrument A reads \(a) c")
                #expect(abs(b ?? .nan) < 0.05, "G12 sr=\(sr) f0=\(f0) st=\(st): instrument B reads \(String(describing: b)) c")
            }
        }
    }

    // MARK: - G13 12-harmonic tones at ±5/±7/±12 st

    /// harness2's `hlarge`: every harmonic of a dense tone must move with the
    /// fundamental. 0001 alone read up to 9.10 c; 0002 reads 0.001 c (-O2).
    @Test("G13 12-harmonic tones at 165/220/330 Hz × ±5/±7/±12 st: h1…h6 land within 0.05 c",
          arguments: [48_000.0, 44_100.0], [5.0, -5, 7, -7, 12, -12])
    func harmonicTonesLand(sr: Double, st: Double) throws {
        let range = Int(sr)..<Int(3 * sr)
        for f0 in [165.0, 220, 330] {
            let tone = Self.harmonicTone(sampleRate: sr, f0: f0, seconds: 4, harmonics: 12, maxHz: 0.45 * sr)
            let out = try Self.render([tone], sampleRate: sr, ratio: 1, semitones: st,
                                      formant: false, path: .constant)[0]
            var line = ""
            for h in 1...6 {
                let want = Self.expectedHz(f0: f0 * Double(h), sampleRate: sr, semitones: st)
                let e = Self.cents(Self.phaseSlopeHz(out, sampleRate: sr, target: want, range: range), above: want)
                line += String(format: " h%d %+.4f", h, e)
                #expect(abs(e) < 0.05, "G13 sr=\(sr) f0=\(f0) st=\(st) h\(h): \(e) c")
            }
            Self.log("G13", String(format: "sr=%.0f f0=%.0f st=%+.0f |%@ c", sr, f0, st, line))
        }
    }

    // MARK: - G14 / G15 the two tripwires that bracket 0002's flat-zone cap

    /// V1 TRIPWIRE A — the flat zone must exist on up-shifts. Low harmonic
    /// tones shifted up read ≤ 0.27 c with 0002 as shipped (V1; 41.2 Hz +7 st
    /// is the worst, where the input-gap cap binds). 0001 alone read 7–13 c,
    /// and a flat zone on down-shift pairs only (the review's V4) 3–17 c.
    /// harness3 `lowHarm` settings: cutoff 0.3·f0, a 0.5 s filter.
    /// (The un-capped form — the investigation's 0002 as written — is MORE
    /// accurate here, ≤ 0.024 c at -O2, and PASSES: this gate cannot see the
    /// cap's absence. G15 can.)
    @Test("G14 V1 tripwire A: low harmonic tones 41.2…82.41 Hz × +7/+9/+12 st, h1…h6 within 0.5 c",
          arguments: [48_000.0, 44_100.0])
    func lowUpShiftedHarmonicsLand(sr: Double) throws {
        let range = Int(sr)..<Int(3 * sr)
        for f0 in [41.2, 55, 65.41, 82.41] {
            let tone = Self.harmonicTone(sampleRate: sr, f0: f0, seconds: 4, harmonics: 12)
            for st in [7.0, 9, 12] {
                let rho = pow(2, st / 12)
                let out = try Self.render([tone], sampleRate: sr, ratio: 1, semitones: st,
                                          formant: false, path: .constant)[0]
                var line = "", worst = 0.0
                for h in 1...6 {
                    let want = f0 * Double(h) * rho
                    let e = Self.cents(Self.demodHz(out, sampleRate: sr, target: want, range: range,
                                                    cutoffHz: 0.3 * f0 * min(1, rho), lpfSeconds: 0.5),
                                       above: want)
                    line += String(format: " h%d %+.4f", h, e)
                    worst = max(worst, abs(e))
                    #expect(abs(e) < 0.5, "G14 sr=\(sr) f0=\(f0) st=+\(st) h\(h): \(e) c")
                }
                Self.log("G14", String(format: "sr=%.0f f0=%.2f st=%+.0f |%@ | max %.4f c", sr, f0, st, line, worst))
            }
        }
    }

    /// V1 TRIPWIRE B — the flat zone must be capped by the INPUT gap too. Without
    /// that cap (the investigation's 0002 as written) the flat zones eat the
    /// input bins between dense low harmonics at a large up-shift and the
    /// inter-harmonic noise is carved out: −22.8 dB at the mid-points, against
    /// −5.9 dB as shipped and −3.9 dB for 0001 alone (harness3 `noiseFloor`,
    /// -O2). Energy is conserved; its SHAPE is what this pins.
    @Test("G15 V1 tripwire B: a 55 Hz 60-harmonic tone + −40 dBFS noise at +12 st keeps its inter-harmonic noise (≥ −10 dB)")
    func interHarmonicNoiseSurvives() throws {
        let sr = 48_000.0, f0 = 55.0, st = 12.0
        let rho = pow(2, st / 12)
        let n = Int(6 * sr)
        let tone = Self.harmonicTone(sampleRate: sr, f0: f0, seconds: 6, harmonics: 60, maxHz: 7000 / max(1, rho))
        let noise = Self.lcgNoise(count: n, seed: 4242, rms: 0.01)
        let input = zip(tone, noise).map { $0 + $1 }
        let out = try Self.render([input], sampleRate: sr, ratio: 1, semitones: st,
                                  formant: false, path: .constant)[0]
        let db = Self.midpointDensityDb(output: out, outputF0: f0 * rho, input: input, inputF0: f0,
                                        sampleRate: sr, range: Int(1.5 * sr)..<Int(5.5 * sr))
        Self.log("G15", String(format: "55 Hz +12 st: inter-harmonic mid-point density %+.2f dB relative to the input", db))
        #expect(db >= -10, "G15: the inter-harmonic noise is carved out to \(db) dB (the un-capped flat zone read −22.8)")
    }

    // MARK: - G16 vibrato: a characterisation

    /// With the peak position and the map exact, what remains on a vibrato
    /// tone is intrinsic to shifting a MOVING partial: the output's mean pitch
    /// is pulled toward the input's (sign opposite to the shift), growing
    /// roughly as depth² and with rate, the same for 1 and 8 harmonics. 0001
    /// alone partly cancelled it with the (opposite-signed) centroid and
    /// curvature errors, so 0002 is WORSE on 5 of these 48 rows and in the
    /// deep-vibrato octave-down corner (60 c, −12 st, 48 kHz: −1.36 → +4.08 c
    /// at 5.5 Hz), and better on the mean. Measured (harness3, -O2): every
    /// row ≤ 1.21 c, ±1 st rows ≤ 0.066 c. The reference is ρ × the input's
    /// MEASURED mean pitch (harness3 `vibGrid`). The 60 c rows are logged only.
    @Test("G16 vibrato characterisation: 30 c / 5.5 Hz at ±1/±7/±12 st on 110/220 Hz, every row < 1.5 c and ±1 st rows < 0.1 c",
          arguments: [48_000.0, 44_100.0], [1, 8])
    func vibratoMeanPitchResidual(sr: Double, harmonics: Int) throws {
        let depth = 30.0, rate = 5.5
        let range = Int(sr)..<Int(3 * sr)
        for f0 in [110.0, 220] {
            let input = Self.vibTone(sampleRate: sr, f0: f0, seconds: 4, depthCents: depth, rate: rate,
                                     harmonics: harmonics)
            let inA = Self.demodHz(input, sampleRate: sr, target: f0, range: range, vibratoRate: rate,
                                   cutoffHz: 30, lpfSeconds: 0.25)
            let inB = harmonics == 1
                ? Self.zeroCrossRegressHz(input, sampleRate: sr, range: range, vibratoRate: rate) : nil
            for st in [1.0, -1, 7, -7, 12, -12] {
                let rho = pow(2, st / 12)
                let out = try Self.render([input], sampleRate: sr, ratio: 1, semitones: st,
                                          formant: false, path: .constant)[0]
                let a = Self.cents(Self.demodHz(out, sampleRate: sr, target: f0 * rho, range: range,
                                                vibratoRate: rate, cutoffHz: 30 * min(1, rho), lpfSeconds: 0.25),
                                   above: rho * inA)
                let b = inB.flatMap { reference in
                    Self.zeroCrossRegressHz(out, sampleRate: sr, range: range, vibratoRate: rate)
                        .map { Self.cents($0, above: rho * reference) }
                }
                let bound = abs(st) == 1 ? 0.1 : 1.5
                Self.log("G16", String(format: "sr=%.0f h=%d f0=%.0f st=%+.0f 30c@5.5: A %+.4f c, B %@",
                                       sr, harmonics, f0, st, a, b.map { String(format: "%+.4f c", $0) } ?? "n/a"))
                #expect(abs(a) < bound, "G16 sr=\(sr) h=\(harmonics) f0=\(f0) st=\(st): A \(a) c")
                if harmonics == 1 {
                    #expect(abs(b ?? .nan) < bound, "G16 sr=\(sr) f0=\(f0) st=\(st): B \(String(describing: b)) c")
                    #expect(abs(a - (b ?? .nan)) < 0.05, "G16 sr=\(sr) f0=\(f0) st=\(st): the instruments disagree")
                }
            }
        }
        // The deep-vibrato corner, logged with no bound (harness3 `vibScale`
        // settings: a 40 Hz filter on both sides): the octave-down 60 c rows
        // are where 0002 costs ~3 c against 0001.
        guard sr == 48_000 && harmonics == 1 else { return }
        for vibratoRate in [5.5, 8] {
            let input = Self.vibTone(sampleRate: sr, f0: 220, seconds: 4, depthCents: 60, rate: vibratoRate)
            let inA = Self.demodHz(input, sampleRate: sr, target: 220, range: range, vibratoRate: vibratoRate,
                                   cutoffHz: 40, lpfSeconds: 0.25)
            for st in [12.0, -12] {
                let rho = pow(2, st / 12)
                let out = try Self.render([input], sampleRate: sr, ratio: 1, semitones: st,
                                          formant: false, path: .constant)[0]
                let a = Self.cents(Self.demodHz(out, sampleRate: sr, target: 220 * rho, range: range,
                                                vibratoRate: vibratoRate, cutoffHz: 40, lpfSeconds: 0.25),
                                   above: rho * inA)
                Self.log("G16-60c", String(format: "sr=48000 f0=220 st=%+.0f 60c@%.1f: A %+.4f c (logged, no bound)",
                                           st, vibratoRate, a))
                #expect(a.isFinite)
            }
        }
    }

    // MARK: - G17 / G18 near-unity ratios: 0003, and the 0002/0003 coupling

    /// 0003'S TRIPWIRE. A pure time-stretch at a ratio within ~2.6/H of 1 runs
    /// hops whose input interval is H±1; upstream reused the previous spectrum
    /// on those hops but the `rot` pass turned it by H, so the output advanced
    /// at ω(H±1)/H: 0001 alone read −0.93…+0.86 c here (harness3 `htz`,
    /// product loop). 0003 re-analyses whenever interval ≠ H: 0.000 c. Both
    /// rates, because the window (and so which hops are H±1) differs by rate.
    @Test("G17 0003 tripwire: 0 st, 220 Hz sine at r = 1.0005 / 0.9995 / 64.0625/64 lands within 0.05 c",
          arguments: [48_000.0, 44_100.0])
    func nearUnityTimeStretchIsExact(sr: Double) throws {
        let tone = Self.vibTone(sampleRate: sr, f0: 220, seconds: 4)
        for ratio in [1.0005, 0.9995, 64.0625 / 64] {
            let out = try Self.render([tone], sampleRate: sr, ratio: ratio, semitones: 0,
                                      formant: false, path: .constant)[0]
            let range = Int(1.0 * sr * ratio)..<Int(3.0 * sr * ratio)
            let a = Self.cents(Self.demodHz(out, sampleRate: sr, target: 220, range: range,
                                            cutoffHz: 20, lpfSeconds: 0.25), above: 220)
            let b = Self.zeroCrossRegressHz(out, sampleRate: sr, range: range).map { Self.cents($0, above: 220) }
            Self.log("G17", String(format: "sr=%.0f r=%.7f: A %+.4f c, B %+.4f c", sr, ratio, a, b ?? .nan))
            #expect(abs(a) < 0.05, "G17 sr=\(sr) r=\(ratio): instrument A reads \(a) c")
            #expect(abs(b ?? .nan) < 0.05, "G17 sr=\(sr) r=\(ratio): instrument B reads \(String(describing: b)) c")
        }
    }

    /// THE COUPLING TRIPWIRE. 0002 reads the peak position from the phase
    /// advance between this spectrum and the previous one, divided by the H
    /// turn; without 0003 the previous spectrum is H±1 back on some hops near
    /// ratio 1, and a transposed near-unity render regresses (0002 alone: up
    /// to 1.13 c, every one of these rows over 0.05 c; 0001 alone 1.73 c).
    /// 0002+0003: 0.002 c (harness2 `hoptol`, -O2).
    @Test("G18 coupling tripwire: +1/−0.5/+7 st × r = 1 ± {1, 3, 5, 6.5, 9}·10⁻⁴ lands within 0.05 c",
          arguments: [48_000.0, 44_100.0], [1.0, -0.5, 7])
    func nearUnityTransposeIsExact(sr: Double, st: Double) throws {
        for dr in [1e-4, -1e-4, 3e-4, -3e-4, 5e-4, -5e-4, 6.5e-4, -6.5e-4, 9e-4, -9e-4] {
            Self.expectAccurate(try Self.readTones("G18", sampleRate: sr, f0s: [220], semitones: st,
                                                   ratio: 1 + dr),
                                limit: 0.05, leg: "G18")
        }
    }
}
