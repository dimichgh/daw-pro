import AVFAudio
import Accelerate
import DAWCore
import Foundation

/// Errors from offline transient analysis (M5 iii-e).
public enum TransientAnalyzerError: Error, Equatable, Sendable {
    /// The source file could not be opened or read.
    case unreadable(String)
}

/// Offline spectral-flux onset detector (M5 iii-e, comping/quantize spec §5a).
/// File in, `[TransientMarker]` out — pure math over Accelerate/vDSP, fully
/// deterministic (fixed window/hop/threshold constants; `analyzerVersion`
/// re-keys the sidecar cache whenever tuning changes, spec §8 risk 6).
///
/// Pipeline: mono mixdown → 1024-sample Hann frames at 256 hop → magnitude
/// spectra (vDSP real FFT) → half-wave-rectified positive spectral flux →
/// adaptive threshold (moving median over ~0.35 s × a sensitivity-mapped
/// multiplier) → local-max peak-pick with 30 ms minimum separation → each
/// onset refined to the nearest local energy rise in the sample domain
/// (64-sample blocks, so timing lands well inside ±5 ms).
///
/// REAL-TIME SAFETY: this type is never referenced from the render path. It
/// allocates and does file I/O freely because it only ever runs inside a
/// detached task (see `AudioEngine.detectTransients` / `TransientCache`).
public enum TransientAnalyzer {
    /// Bumped whenever any tuning constant below changes — the cache key
    /// includes it, so a tuning change re-analyzes instead of silently
    /// mixing maps produced by different detectors.
    public static let analyzerVersion = 1

    /// STFT geometry (spec §5a: 1024-sample Hann window, 256 hop).
    static let windowSize = 1024
    static let hopSize = 256

    /// Two picked onsets closer than this merge, keeping the stronger.
    static let minSeparationSeconds = 0.030

    /// Span of the moving-median flux window feeding the adaptive threshold.
    static let medianWindowSeconds = 0.35

    /// Sample-domain refinement granularity: onsets snap to the start of the
    /// 64-sample block with the steepest energy rise (~1.3 ms at 48 kHz).
    static let refineBlockSize = 64

    /// Absolute-floor fraction of the peak flux added to every threshold —
    /// keeps spectral-leakage jitter in steady/decaying material (measured
    /// ≤ 0.6% of the attack's flux on a decaying 220 Hz pad — window-phase
    /// beating, not onsets) from ever counting. 1% still admits onsets 40 dB
    /// quieter than the file's strongest; tuning it bumps `analyzerVersion`.
    static let thresholdFloorFraction: Double = 0.01

    /// Maps `sensitivity` 0...1 (clamped) to the median multiplier k:
    /// 0 → 3.0 (few, strong onsets only) down to 1 → 1.2 (many onsets),
    /// linearly (spec §5a).
    static func thresholdMultiplier(forSensitivity sensitivity: Double) -> Double {
        let s = min(max(sensitivity, 0), 1)
        return 3.0 - 1.8 * s
    }

    // MARK: - File entry point

    /// Reads the file, mixes to mono, analyzes. Blocking — call from a
    /// detached task only (the cache does).
    public static func analyze(fileAt url: URL, sensitivity: Double) throws -> [TransientMarker] {
        let (samples, sampleRate) = try readMono(url: url)
        return analyze(monoSamples: samples, sampleRate: sampleRate, sensitivity: sensitivity)
    }

    // MARK: - Pure core (testable without files)

    /// The deterministic core: mono samples in, sorted markers out.
    /// Times are seconds from the start of `monoSamples` (== source-file
    /// seconds when fed a whole file). Strengths are each onset's flux
    /// normalized by the strongest picked onset (the strongest is 1.0).
    public static func analyze(
        monoSamples: [Float], sampleRate: Double, sensitivity: Double
    ) -> [TransientMarker] {
        guard sampleRate > 0, monoSamples.count >= windowSize else { return [] }

        let flux = spectralFlux(monoSamples: monoSamples)
        guard let peakFlux = flux.max(), peakFlux > 0 else { return [] }

        // Adaptive threshold: moving median × k + tiny absolute floor.
        let k = thresholdMultiplier(forSensitivity: sensitivity)
        let floor = thresholdFloorFraction * Double(peakFlux)
        let halfWindow = max(1, Int((medianWindowSeconds / 2) * sampleRate
                                    / Double(hopSize) + 0.5))
        var candidates: [(frame: Int, flux: Double)] = []
        for f in flux.indices {
            let lo = max(0, f - halfWindow)
            let hi = min(flux.count - 1, f + halfWindow)
            let median = Double(median(of: Array(flux[lo...hi])))
            let threshold = median * k + floor
            let value = Double(flux[f])
            // Strict local maximum on the right, ties allowed on the left —
            // a flat-topped peak yields exactly one candidate.
            let risingIn = f == 0 || flux[f] >= flux[f - 1]
            let fallingOut = f == flux.count - 1 || flux[f] > flux[f + 1]
            if value > threshold, risingIn, fallingOut {
                candidates.append((frame: f, flux: value))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Peak-pick with minimum inter-onset gap (greedy, stronger wins).
        let minGapFrames = minSeparationSeconds * sampleRate / Double(hopSize)
        var picked: [(frame: Int, flux: Double)] = []
        for candidate in candidates {
            if let last = picked.last,
               Double(candidate.frame - last.frame) < minGapFrames {
                if candidate.flux > last.flux {
                    picked[picked.count - 1] = candidate
                }
            } else {
                picked.append(candidate)
            }
        }

        // Refine each picked frame to the nearest local energy rise, then
        // re-apply the minimum gap in the (finer) time domain.
        let minGapSeconds = minSeparationSeconds
        var markers: [(time: Double, flux: Double)] = []
        for pick in picked {
            let sample = refineOnsetSample(monoSamples: monoSamples, frame: pick.frame)
            let time = Double(sample) / sampleRate
            if let last = markers.last, time - last.time < minGapSeconds {
                if pick.flux > last.flux {
                    markers[markers.count - 1] = (time: time, flux: pick.flux)
                }
            } else {
                markers.append((time: time, flux: pick.flux))
            }
        }

        let maxPickedFlux = markers.map(\.flux).max() ?? 1
        return markers.map { marker in
            TransientMarker(
                timeSeconds: marker.time,
                strength: maxPickedFlux > 0
                    ? min(max(marker.flux / maxPickedFlux, 0), 1) : 1)
        }
    }

    // MARK: - Spectral flux (vDSP)

    /// Half-wave-rectified positive spectral flux per STFT frame. Index f
    /// compares the magnitude spectrum of the frame starting at f·hop with
    /// its predecessor; flux[0] == 0 by definition.
    static func spectralFlux(monoSamples: [Float]) -> [Float] {
        let n = monoSamples.count
        let frameCount = (n - windowSize) / hopSize + 1
        guard frameCount > 1 else { return [] }

        let log2n = vDSP_Length(Int(log2(Double(windowSize))))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2,
                                 ofType: DSPSplitComplex.self) else { return [] }

        var hann = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&hann, vDSP_Length(windowSize), Int32(vDSP_HANN_DENORM))

        let half = windowSize / 2
        var windowed = [Float](repeating: 0, count: windowSize)
        var realPart = [Float](repeating: 0, count: half)
        var imagPart = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var previousMagnitudes = [Float](repeating: 0, count: half)
        var difference = [Float](repeating: 0, count: half)
        var flux = [Float](repeating: 0, count: frameCount)

        monoSamples.withUnsafeBufferPointer { samples in
            for frame in 0..<frameCount {
                let start = frame * hopSize
                // windowed = samples[start ..< start+window] * hann
                vDSP_vmul(samples.baseAddress! + start, 1, hann, 1,
                          &windowed, 1, vDSP_Length(windowSize))

                realPart.withUnsafeMutableBufferPointer { realBuffer in
                    imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!,
                            imagp: imagBuffer.baseAddress!)
                        windowed.withUnsafeBufferPointer { windowedBuffer in
                            windowedBuffer.baseAddress!.withMemoryRebound(
                                to: DSPComplex.self, capacity: half
                            ) { complexPointer in
                                vDSP_ctoz(complexPointer, 2, &split, 1,
                                          vDSP_Length(half))
                            }
                        }
                        fft.forward(input: split, output: &split)
                        // Packed real FFT: imagp[0] holds Nyquist — zero it so
                        // bin 0 is purely |DC| (consistent, deterministic).
                        imagBuffer[0] = 0
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }

                if frame > 0 {
                    // difference = magnitudes - previous, clamped at 0
                    // (half-wave rectification), then summed.
                    vDSP_vsub(previousMagnitudes, 1, magnitudes, 1,
                              &difference, 1, vDSP_Length(half))
                    var lowerBound: Float = 0
                    var upperBound = Float.greatestFiniteMagnitude
                    vDSP_vclip(difference, 1, &lowerBound, &upperBound,
                               &difference, 1, vDSP_Length(half))
                    var sum: Float = 0
                    vDSP_sve(difference, 1, &sum, vDSP_Length(half))
                    // NaN/denormal guard: a poisoned frame contributes zero
                    // flux rather than poisoning the peak-pick.
                    flux[frame] = sum.isFinite ? sum : 0
                }
                swap(&previousMagnitudes, &magnitudes)
            }
        }
        return flux
    }

    // MARK: - Refinement

    /// The flux at `frame` compares spectra of the frames starting at
    /// (frame−1)·hop and frame·hop, so the true energy rise lies inside
    /// [(frame−1)·hop, frame·hop + window). Scan that span in 64-sample
    /// blocks and return the start of the block after the steepest energy
    /// rise — sample-domain accuracy independent of the 256-sample hop.
    static func refineOnsetSample(monoSamples: [Float], frame: Int) -> Int {
        let searchStart = max(0, (frame - 1) * hopSize)
        let searchEnd = min(monoSamples.count, frame * hopSize + windowSize)
        let blockCount = (searchEnd - searchStart) / refineBlockSize
        guard blockCount > 1 else { return frame * hopSize }

        var energies = [Float](repeating: 0, count: blockCount)
        monoSamples.withUnsafeBufferPointer { samples in
            for block in 0..<blockCount {
                var energy: Float = 0
                vDSP_svesq(samples.baseAddress! + searchStart + block * refineBlockSize,
                           1, &energy, vDSP_Length(refineBlockSize))
                energies[block] = energy.isFinite ? energy : 0
            }
        }
        var bestBlock = 1
        var bestRise: Float = -.greatestFiniteMagnitude
        for block in 1..<blockCount {
            let rise = energies[block] - energies[block - 1]
            if rise > bestRise {
                bestRise = rise
                bestBlock = block
            }
        }
        return searchStart + bestBlock * refineBlockSize
    }

    // MARK: - Helpers

    static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// Whole-file mono mixdown (channel average) at the source sample rate.
    /// Loop-read because `AVAudioFile.read(into:)` can return short.
    static func readMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: url)
        } catch {
            throw TransientAnalyzerError.unreadable(
                "\(url.path): \(error.localizedDescription)")
        }
        let format = reader.processingFormat  // deinterleaved float32
        let channelCount = Int(format.channelCount)
        guard reader.length > 0, channelCount > 0 else {
            throw TransientAnalyzerError.unreadable("empty source \(url.path)")
        }
        var mono = [Float]()
        mono.reserveCapacity(Int(reader.length))
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw TransientAnalyzerError.unreadable("buffer allocation failed")
        }
        let scale = 1 / Float(channelCount)
        var mixed = [Float](repeating: 0, count: Int(chunk.frameCapacity))
        while reader.framePosition < reader.length {
            try reader.read(into: chunk)
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            let frames = Int(chunk.frameLength)
            if channelCount == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                mixed.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.update(from: data[0], count: frames)
                    for channel in 1..<channelCount {
                        vDSP_vadd(out.baseAddress!, 1, data[channel], 1,
                                  out.baseAddress!, 1, vDSP_Length(frames))
                    }
                    var channelScale = scale
                    vDSP_vsmul(out.baseAddress!, 1, &channelScale,
                               out.baseAddress!, 1, vDSP_Length(frames))
                }
                mono.append(contentsOf: mixed[0..<frames])
            }
        }
        return (mono, format.sampleRate)
    }
}
