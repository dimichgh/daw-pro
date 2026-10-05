import AVFAudio
import Accelerate
import Foundation

@testable import DAWEngine

// m23-q Phase 0 (E1) measurement harness — test-target only.
//
// This file is the INSTRUMENT, not the thing under test. Everything here is
// positive-controlled in `OfflineStretcherCurveTests` against synthetic signals
// with a known answer BEFORE it is pointed at the stretcher, because an
// estimator's own smearing and the stretcher's hop quantisation produce
// numerically identical-looking errors and there is no way to tell them apart
// after the fact.
//
// FFT choice, and a deliberate deviation from the E1 brief: the brief names
// `signalsmith-linear` (vendored, MIT, Accelerate-backed). It is reachable only
// as C++ headers through `CSignalsmithStretch`, so using it from Swift would
// mean a second C shim — more product surface than Phase 0 authorises (one
// accessor). Under `SIGNALSMITH_USE_ACCELERATE` signalsmith-linear IS vDSP,
// and five analyzers in this tree (`MasterMixAnalyzer`, `ReferenceAnalyzer`,
// `AudioContentAnalyzer`, `TransientAnalyzer`, `TempoEstimator`) already call
// `vDSP.FFT` directly. So the harness uses `vDSP.FFT` with the same idiom.
// Nothing new is vendored and no module is added.

// MARK: - Signal generation

enum M23QSignal {
    /// Phase-continuous sine at a constant frequency.
    static func sine(
        hz: Double, frames: Int, sampleRate: Double, amplitude: Float = 0.8
    ) -> [Float] {
        frequencyModulated(
            frames: frames, sampleRate: sampleRate, amplitude: amplitude
        ) { _ in hz }
    }

    /// Phase-continuous sine whose frequency STEPS from `fromHz` to `toHz` at
    /// `stepFrame`. Phase continuity matters: a phase discontinuity would be a
    /// click the click test would then blame on the stretcher.
    static func steppedSine(
        fromHz: Double, toHz: Double, stepFrame: Int, frames: Int,
        sampleRate: Double, amplitude: Float = 0.8
    ) -> [Float] {
        frequencyModulated(
            frames: frames, sampleRate: sampleRate, amplitude: amplitude
        ) { n in n < stepFrame ? fromHz : toHz }
    }

    /// Phase-continuous sine with a sinusoidal cents deviation —
    /// f(t) = baseHz · 2^(depthCents·sin(2π·rateHz·t) / 1200).
    static func vibratoSine(
        baseHz: Double, depthCents: Double, rateHz: Double, frames: Int,
        sampleRate: Double, amplitude: Float = 0.8
    ) -> [Float] {
        frequencyModulated(
            frames: frames, sampleRate: sampleRate, amplitude: amplitude
        ) { n in
            baseHz * pow(2, vibratoCents(
                depthCents: depthCents, rateHz: rateHz,
                frame: n, sampleRate: sampleRate) / 1200)
        }
    }

    /// The vibrato curve's cents deviation at an output frame — one definition
    /// shared by the generator, the requested transpose curve and the ideal
    /// the tracking error is measured against.
    static func vibratoCents(
        depthCents: Double, rateHz: Double, frame: Int, sampleRate: Double
    ) -> Double {
        depthCents * sin(2 * .pi * rateHz * Double(frame) / sampleRate)
    }

    /// Integrates an instantaneous-frequency function into a phase-continuous
    /// sine. `hzAt(n)` is the frequency in effect over sample n.
    static func frequencyModulated(
        frames: Int, sampleRate: Double, amplitude: Float = 0.8,
        hzAt: (Int) -> Double
    ) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        var phase = 0.0
        for n in 0..<frames {
            out[n] = amplitude * Float(sin(phase))
            phase += 2 * .pi * hzAt(n) / sampleRate
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        return out
    }
}

// MARK: - The instrument: instantaneous-frequency tracking

struct M23QToneEstimate {
    /// Frame this estimate is CENTRED on, in the same index space as the
    /// signal. Assigning a windowed estimate to the window's start instead of
    /// its centre would bake a +windowSize/2 bias into every alignment number;
    /// the positive control in the suite is what proves this is right.
    let centreFrame: Double
    let hz: Double
}

enum M23QToneTracker {
    /// Phase-difference (phase-vocoder) instantaneous-frequency estimator for a
    /// single dominant tone. Two Hann-windowed FFT frames `phaseHop` apart; the
    /// peak bin inside `band` picks the partial; the bin's phase advance over
    /// `phaseHop`, unwrapped against the bin's own expected advance, gives the
    /// frequency. Unambiguous while |f − binCentre| < sampleRate/(2·phaseHop) —
    /// 750 Hz at the defaults, versus a 46.9 Hz bin, so there is no wrapping
    /// risk at all here.
    ///
    /// Resolution/smearing: each estimate averages over `windowSize` samples
    /// (21.3 ms at 1024 / 48 k). Against a 5 Hz vibrato that costs a small,
    /// MEASURED depth attenuation — see the suite's instrument-floor test.
    static func track(
        _ x: [Float], sampleRate: Double, windowSize: Int = 1024,
        phaseHop: Int = 32, estimateHop: Int = 64,
        band: ClosedRange<Double> = 150...400
    ) -> [M23QToneEstimate] {
        let n = windowSize
        let half = n / 2
        guard n >= 64, x.count >= n + phaseHop, phaseHop >= 1, estimateHop >= 1,
            sampleRate > 0,
            let fft = vDSP.FFT(
                log2n: vDSP_Length(Int(log2(Double(n)))), radix: .radix2,
                ofType: DSPSplitComplex.self)
        else { return [] }

        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_DENORM))

        let binHz = sampleRate / Double(n)
        let lowBin = max(1, Int((band.lowerBound / binHz).rounded(.down)))
        let highBin = min(half - 1, Int((band.upperBound / binHz).rounded(.up)))
        guard lowBin <= highBin else { return [] }

        var windowed = [Float](repeating: 0, count: n)
        var realA = [Float](repeating: 0, count: half)
        var imagA = [Float](repeating: 0, count: half)
        var realB = [Float](repeating: 0, count: half)
        var imagB = [Float](repeating: 0, count: half)

        func spectrum(
            at start: Int, into real: inout [Float], _ imag: inout [Float]
        ) {
            x.withUnsafeBufferPointer { buffer in
                vDSP_vmul(
                    buffer.baseAddress! + start, 1, hann, 1, &windowed, 1,
                    vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imagBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { windowedBuffer in
                        windowedBuffer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: half
                        ) { complexPointer in
                            vDSP_ctoz(
                                complexPointer, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    imagBuffer[0] = 0 // packed real FFT: imagp[0] is Nyquist
                }
            }
        }

        var out: [M23QToneEstimate] = []
        var start = 0
        let twoPi = 2 * Double.pi
        while start + phaseHop + n <= x.count {
            spectrum(at: start, into: &realA, &imagA)
            spectrum(at: start + phaseHop, into: &realB, &imagB)

            var peakBin = lowBin
            var peakPower = -1.0
            for bin in lowBin...highBin {
                let power = Double(realA[bin]) * Double(realA[bin])
                    + Double(imagA[bin]) * Double(imagA[bin])
                if power > peakPower {
                    peakPower = power
                    peakBin = bin
                }
            }

            let phaseA = atan2(Double(imagA[peakBin]), Double(realA[peakBin]))
            let phaseB = atan2(Double(imagB[peakBin]), Double(realB[peakBin]))
            let expected = twoPi * Double(peakBin) * Double(phaseHop) / Double(n)
            let deviation = (phaseB - phaseA - expected).remainder(dividingBy: twoPi)
            let advance = expected + deviation
            let hz = advance * sampleRate / (twoPi * Double(phaseHop))

            out.append(
                M23QToneEstimate(
                    centreFrame: Double(start) + Double(n - 1) / 2
                        + Double(phaseHop) / 2,
                    hz: hz))
            start += estimateHop
        }
        return out
    }

    /// Interval in cents between two frequencies (positive = `hz` above `ref`).
    static func cents(_ hz: Double, above ref: Double) -> Double {
        1200 * log2(hz / ref)
    }

    /// Median of the estimates whose centre lies inside `range` — the plateau
    /// reader. Median, not mean, so a single transition-region outlier cannot
    /// move a plateau value.
    static func medianHz(
        _ estimates: [M23QToneEstimate], centreIn range: Range<Double>
    ) -> Double? {
        let values = estimates.filter { range.contains($0.centreFrame) }
            .map(\.hz).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    /// Least-squares fit of a single sinusoid at exactly `rateHz` to a tracked
    /// series, by projection onto sin/cos (a one-bin DFT). Returns the
    /// amplitude, the LAG in frames (how far the series trails an ideal
    /// `sin(2π·rate·t)`), and the RMS of everything that is not that sinusoid.
    ///
    /// The lag is a second, independent measurement of the curve's application
    /// latency — derived from a 5 Hz modulation rather than from a step, so it
    /// shares no machinery with leg (a) beyond the tracker itself. Two
    /// instruments agreeing is the signal; two disagreeing is a finding.
    static func fitSinusoid(
        _ series: [(frame: Double, value: Double)], rateHz: Double,
        sampleRate: Double
    ) -> (amplitude: Double, lagFrames: Double, residualRMS: Double)? {
        guard series.count > 8, rateHz > 0, sampleRate > 0 else { return nil }
        var cosSum = 0.0
        var sinSum = 0.0
        var mean = 0.0
        for point in series { mean += point.value }
        mean /= Double(series.count)
        for point in series {
            let angle = 2 * .pi * rateHz * point.frame / sampleRate
            cosSum += (point.value - mean) * cos(angle)
            sinSum += (point.value - mean) * sin(angle)
        }
        let a = 2 * sinSum / Double(series.count) // coefficient of sin
        let b = 2 * cosSum / Double(series.count) // coefficient of cos
        let amplitude = (a * a + b * b).squareRoot()
        // value ≈ amplitude·sin(θ + φ) with φ = atan2(b, a); a positive lag
        // means the series trails the ideal, so lag = −φ / (2π·rate).
        let phase = atan2(b, a)
        var lagFrames = -phase / (2 * .pi * rateHz) * sampleRate
        let period = sampleRate / rateHz
        while lagFrames < 0 { lagFrames += period }
        while lagFrames >= period { lagFrames -= period }
        var residual = 0.0
        for point in series {
            let angle = 2 * .pi * rateHz * point.frame / sampleRate
            let model = mean + a * sin(angle) + b * cos(angle)
            residual += (point.value - model) * (point.value - model)
        }
        return (
            amplitude, lagFrames, (residual / Double(series.count)).squareRoot()
        )
    }

    /// First frame at which the tracked frequency crosses `threshold` upward
    /// and STAYS above it for `holdEstimates` consecutive estimates (so a
    /// single noisy estimate cannot define the step). Linearly interpolated
    /// between the bracketing estimates.
    static func upwardCrossingFrame(
        _ estimates: [M23QToneEstimate], threshold: Double, holdEstimates: Int = 4
    ) -> Double? {
        guard estimates.count > holdEstimates else { return nil }
        for index in 1..<(estimates.count - holdEstimates) {
            let previous = estimates[index - 1]
            let current = estimates[index]
            guard previous.hz < threshold, current.hz >= threshold else { continue }
            let held = (index..<(index + holdEstimates)).allSatisfy {
                estimates[$0].hz >= threshold
            }
            guard held else { continue }
            let span = current.hz - previous.hz
            let fraction = span > 0 ? (threshold - previous.hz) / span : 0
            return previous.centreFrame
                + fraction * (current.centreFrame - previous.centreFrame)
        }
        return nil
    }
}

// MARK: - Waveform statistics (the click test)

enum M23QWaveform {
    /// Peak |x[n+1] − x[n]| over `range`, and the frame where it occurs.
    static func peakStepDifference(
        _ x: [Float], in range: Range<Int>
    ) -> (peak: Double, frame: Int) {
        let low = max(0, range.lowerBound)
        let high = min(x.count - 1, range.upperBound)
        guard low < high else { return (0, low) }
        var peak = 0.0
        var frame = low
        for n in low..<high {
            let d = abs(Double(x[n + 1]) - Double(x[n]))
            if d > peak {
                peak = d
                frame = n
            }
        }
        return (peak, frame)
    }

    /// The frames in `range` whose first difference exceeds `baseline` — the
    /// kill criterion is a DURATION question ("can a ≤30 ms crossfade hide
    /// it"), which a peak magnitude alone cannot answer. Returns the count and
    /// the span from first to last offending frame.
    static func excursions(
        _ x: [Float], in range: Range<Int>, above baseline: Double
    ) -> (count: Int, spanFrames: Int, firstFrame: Int?, lastFrame: Int?) {
        let low = max(0, range.lowerBound)
        let high = min(x.count - 1, range.upperBound)
        guard low < high else { return (0, 0, nil, nil) }
        var count = 0
        var first: Int?
        var last: Int?
        for n in low..<high where abs(Double(x[n + 1]) - Double(x[n])) > baseline {
            count += 1
            if first == nil { first = n }
            last = n
        }
        guard let f = first, let l = last else { return (0, 0, nil, nil) }
        return (count, l - f + 1, f, l)
    }

    /// Peak |x| over `range` — the local envelope.
    static func peakAmplitude(_ x: [Float], in range: Range<Int>) -> Double {
        let low = max(0, range.lowerBound)
        let high = min(x.count, range.upperBound)
        guard low < high else { return 0 }
        var peak = 0.0
        for n in low..<high { peak = max(peak, abs(Double(x[n]))) }
        return peak
    }

    /// **The metric that separates a click from a drift.** A raw peak |Δ| rises
    /// whenever the tone gets louder OR higher, so "excess first difference"
    /// alone cannot distinguish a discontinuity from the pitch legitimately
    /// moving up. This divides the local peak |Δ| by what a pure sine of the
    /// LOCALLY MEASURED frequency and amplitude would produce (2π·f·A/fs).
    ///
    /// A clean sine gives ≈1 whatever its pitch or level. A genuine
    /// sample-to-sample discontinuity gives a number well above 1, localised to
    /// a handful of samples. Reported for the curve render AND for both
    /// constant renders, so the reading is relative as the kill criterion
    /// demands.
    static func sinusoidalityRatios(
        _ x: [Float], sampleRate: Double, estimates: [M23QToneEstimate],
        halfWindow: Int = 128
    ) -> [(frame: Int, ratio: Double, amplitude: Double, hz: Double)] {
        var out: [(frame: Int, ratio: Double, amplitude: Double, hz: Double)] = []
        for estimate in estimates {
            let centre = Int(estimate.centreFrame.rounded())
            let range = (centre - halfWindow)..<(centre + halfWindow)
            guard range.lowerBound >= 0, range.upperBound <= x.count else { continue }
            let amplitude = peakAmplitude(x, in: range)
            guard amplitude > 1e-6, estimate.hz > 1 else { continue }
            let expected = theoreticalPeakStep(
                hz: estimate.hz, amplitude: amplitude, sampleRate: sampleRate)
            guard expected > 0 else { continue }
            let observed = peakStepDifference(x, in: range).peak
            out.append(
                (frame: centre, ratio: observed / expected, amplitude: amplitude,
                 hz: estimate.hz))
        }
        return out
    }

    /// Theoretical peak first difference of a pure sine — 2π·f·A/fs. The click
    /// test's numbers are meaningless without it: a +2-semitone render has an
    /// intrinsically larger sample-to-sample step than the unshifted one
    /// purely because the tone is higher.
    static func theoreticalPeakStep(
        hz: Double, amplitude: Double, sampleRate: Double
    ) -> Double {
        2 * .pi * hz * amplitude / sampleRate
    }

    /// Local peak envelope, sampled every `hop` frames over a `window`-frame
    /// box. Cheap, and enough to see a level dip during a pitch transition —
    /// which is a real artefact of overlap-adding frames at two different
    /// pitches, and is NOT a click.
    static func envelope(
        _ x: [Float], window: Int = 512, hop: Int = 128
    ) -> [(frame: Int, amplitude: Double)] {
        var out: [(frame: Int, amplitude: Double)] = []
        var start = 0
        while start + window <= x.count {
            out.append(
                (frame: start + window / 2,
                 amplitude: peakAmplitude(x, in: start..<(start + window))))
            start += hop
        }
        return out
    }

    /// **The click detector proper.** A click is broadband: it puts energy
    /// where a 220 Hz sine has none. This reports, per window, the fraction of
    /// energy above `cutoffHz` in dB. Immune to the tone getting louder or
    /// higher — both of which a peak-|Δ| test mistakes for a discontinuity.
    ///
    /// The phase vocoder has its own broadband floor, so the number is only
    /// meaningful beside the same measurement on the constant renders.
    static func highFrequencyEnergy(
        _ x: [Float], sampleRate: Double, cutoffHz: Double = 2000,
        windowSize: Int = 1024, hop: Int = 256
    ) -> [(frame: Int, hfDb: Double)] {
        let n = windowSize
        let half = n / 2
        guard let fft = vDSP.FFT(
            log2n: vDSP_Length(Int(log2(Double(n)))), radix: .radix2,
            ofType: DSPSplitComplex.self)
        else { return [] }
        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        let cutoffBin = max(1, Int(cutoffHz * Double(n) / sampleRate))
        var windowed = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var out: [(frame: Int, hfDb: Double)] = []
        var start = 0
        while start + n <= x.count {
            x.withUnsafeBufferPointer { buffer in
                vDSP_vmul(
                    buffer.baseAddress! + start, 1, hann, 1, &windowed, 1,
                    vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imagBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { windowedBuffer in
                        windowedBuffer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: half
                        ) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    imagBuffer[0] = 0
                }
            }
            var total = 0.0
            var high = 0.0
            for bin in 1..<half {
                let power = Double(real[bin]) * Double(real[bin])
                    + Double(imag[bin]) * Double(imag[bin])
                total += power
                if bin >= cutoffBin { high += power }
            }
            let ratio = total > 0 ? high / total : 0
            out.append(
                (frame: start + n / 2,
                 hfDb: ratio > 0 ? 10 * log10(ratio) : -200))
            start += hop
        }
        return out
    }

    static func isAllFinite(_ x: [Float]) -> Bool {
        x.allSatisfy { $0.isFinite }
    }

    static func peakMagnitude(_ x: [Float]) -> Double {
        x.reduce(0.0) { max($0, abs(Double($1))) }
    }
}

// MARK: - E2 by-product: the comparison-pair renderer

/// Renders the SAME source twice — once with the whole-clip constant shift we
/// ship today, once with a time-varying curve — so that E2 (the human listening
/// leg, which needs a real dry vocal this tree does not contain) is a render
/// away rather than a rebuild.
///
/// Test-target only, on purpose: Phase 0 ships no wire verb and no MCP tool
/// (design §11.2). It is exercised by a synthetic round-trip test so it cannot
/// rot silently before the user supplies a recording.
enum M23QComparisonPair {
    struct Rendered {
        let constantURL: URL
        let curveURL: URL
        let constant: [[Float]]
        let curve: [[Float]]
        let sampleRate: Double
    }

    /// Reads a mono/stereo float32 source file, renders both versions, writes
    /// both as WAVs into `outputDirectory` and returns the planar audio too.
    ///
    /// ⚠️ **`latencyCompensated` DEFAULTS TO WHAT SHIPS (m23-q Phase 1).** When
    /// this renderer was written the curve path had no compensation and the
    /// pair a listener judged was ~50 ms late against its own request; the
    /// shipping render now pre-shifts the curve, so a listening pass made with
    /// `false` would be judging audio the product no longer produces. Pass
    /// `false` only to reproduce a phase-0 measurement.
    static func render(
        sourceURL: URL,
        outputDirectory: URL,
        constantSemitones: Double,
        curve: [(outputFrame: Int, semitones: Double)],
        formantPreserve: Bool,
        latencyCompensated: Bool = true,
        namePrefix: String = "m23q-e2"
    ) throws -> Rendered {
        let file = try AVAudioFile(forReading: sourceURL)
        let sampleRate = file.processingFormat.sampleRate
        let frames = Int(file.length)
        guard frames > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(frames)),
            let channelData = buffer.floatChannelData
        else { throw OfflineStretcherError.invalidInput("unreadable source") }
        // AVAudioFile.read(into:) is free to return a SHORT read (it returned
        // 95232 of 96000 here the first time). Loop to the file's length or a
        // zero-progress read, or the "pair" silently loses its tail.
        var accumulated: [[Float]] = Array(
            repeating: [], count: Int(file.processingFormat.channelCount))
        while Int(file.framePosition) < frames {
            buffer.frameLength = 0
            try file.read(into: buffer)
            let got = Int(buffer.frameLength)
            if got == 0 { break }
            for c in 0..<accumulated.count {
                accumulated[c].append(
                    contentsOf: UnsafeBufferPointer(
                        start: channelData[c], count: got))
            }
        }
        let channels = Int(file.processingFormat.channelCount)
        let read = accumulated.first?.count ?? 0
        guard read > 0 else {
            throw OfflineStretcherError.invalidInput("source read returned nothing")
        }
        let planar = accumulated
        _ = channels

        let constant = try OfflineStretcher.stretch(
            input: planar, sampleRate: sampleRate, ratio: 1,
            semitones: constantSemitones, formantPreserve: formantPreserve)
        let curved = try OfflineStretcher.stretchTransposeCurve(
            input: planar, sampleRate: sampleRate, ratio: 1, curve: curve,
            formantPreserve: formantPreserve,
            compensation: latencyCompensated
                ? OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
                : .none)

        let constantURL = outputDirectory
            .appendingPathComponent("\(namePrefix)-constant.wav")
        let curveURL = outputDirectory
            .appendingPathComponent("\(namePrefix)-curve.wav")
        try writeWAV(constant, sampleRate: sampleRate, to: constantURL)
        try writeWAV(curved, sampleRate: sampleRate, to: curveURL)
        return Rendered(
            constantURL: constantURL, curveURL: curveURL, constant: constant,
            curve: curved, sampleRate: sampleRate)
    }

    /// Planar float32 → 32-bit float WAV. Used by the pair renderer and by the
    /// suite when it wants a rendered artefact on disk to assert against.
    static func writeWAV(
        _ planar: [[Float]], sampleRate: Double, to url: URL
    ) throws {
        let channels = planar.count
        let frames = planar.first?.count ?? 0
        guard channels >= 1, frames >= 1,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels), interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let data = buffer.floatChannelData
        else { throw OfflineStretcherError.invalidInput("bad planar audio") }
        for c in 0..<channels {
            planar[c].withUnsafeBufferPointer { src in
                data[c].update(from: src.baseAddress!, count: frames)
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: buffer)
    }
}
