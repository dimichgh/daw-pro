import Accelerate
import AVFAudio
import DAWCore
import Foundation

/// m39-w4-6 — measures each chopped slice's timbre (`SliceTimbre`) so DAWCore can sort a drum loop into a
/// kit. Design `docs/design/2026-10-07-loop-drum-depth.md` §5.2, step 1.
///
/// OFFLINE ONLY. `AudioEngine.analyzeSliceTimbres` runs it in a detached task, like `BoundarySnapper`; it
/// never touches the render thread or the live graph.
///
/// The file is read ONCE: the frames from the earliest slice start to the latest slice end, averaged across
/// channels (the `AudioContentAnalyzer.readMonoWindow` recipe, frame-exact here because the spans already are
/// frames). Each slice is then measured by the pure `timbre(of:sampleRate:)`:
///  - **spectral features** over the slice's first 80 ms (or the whole slice, if shorter): one FFT of the
///    next power of two, flat from the onset and tapered only over the last quarter of the window, because
///    a slice STARTS on its hit and a window that faded in would weigh the hit least;
///  - **decay** on a 10 ms RMS envelope hopped every 2 ms, from its loudest point to the first point 20 dB
///    below it;
///  - **peak** as the largest absolute sample.
public enum SliceTimbreAnalyzer {

    public enum Failure: Error, LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "could not read the audio to sort its hits: \(detail)"
            }
        }
    }

    /// The envelope's RMS window and hop (decay timing).
    static let envelopeWindowSeconds = 0.010
    static let envelopeHopSeconds = 0.002

    /// Reads `url` once and measures every span. Spans are clamped into the file; a span that ends up empty
    /// measures as silence (all zeros), never as an error, so the result is always index-aligned.
    public static func analyze(fileAt url: URL, frameRanges: [SliceFrameSpan]) throws -> [SliceTimbre] {
        guard !frameRanges.isEmpty else { return [] }
        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable("\(url.path): \(error.localizedDescription)")
        }
        let format = reader.processingFormat
        let channelCount = Int(format.channelCount)
        let rate = format.sampleRate
        let length = Int(reader.length)
        guard length > 0, channelCount > 0, rate > 0 else {
            throw Failure.unreadable("\(url.path) is empty")
        }
        let spans = frameRanges.map { span -> Range<Int> in
            let start = min(max(0, span.start), length)
            let end = min(max(start, span.end ?? length), length)
            return start..<end
        }
        let low = spans.map(\.lowerBound).min() ?? 0
        let high = spans.map(\.upperBound).max() ?? 0
        let mono = try readMono(reader, format: format, from: low, count: high - low)
        return mono.withUnsafeBufferPointer { all in
            spans.map { span in
                let lo = min(span.lowerBound - low, all.count)
                let hi = min(span.upperBound - low, all.count)
                return timbre(of: UnsafeBufferPointer(rebasing: all[lo..<max(lo, hi)]), sampleRate: rate)
            }
        }
    }

    /// The pure per-slice measurement (mono samples at `sampleRate`).
    public static func timbre(of samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> SliceTimbre {
        let count = samples.count
        let duration = sampleRate > 0 ? Double(count) / sampleRate : 0
        guard count > 0, sampleRate > 0 else {
            return SliceTimbre(lowEnergyShare: 0, highEnergyShare: 0, attackCentroidHz: 0, decaySeconds: 0,
                               decayReachedFloor: true, spectralFlatness: 0, peak: 0, durationSeconds: 0)
        }
        var peak: Float = 0
        vDSP_maxmgv(samples.baseAddress!, 1, &peak, vDSP_Length(count))
        let spectral = attackSpectrum(samples, sampleRate: sampleRate)
        let decay = decayTime(samples, sampleRate: sampleRate)
        return SliceTimbre(
            lowEnergyShare: spectral.low, highEnergyShare: spectral.high,
            attackCentroidHz: spectral.centroid, decaySeconds: decay.seconds,
            decayReachedFloor: decay.reached, spectralFlatness: spectral.flatness,
            peak: peak.isFinite ? Double(peak) : 0, durationSeconds: duration)
    }

    // MARK: - Spectral features of the attack window

    static func attackSpectrum(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double)
        -> (low: Double, high: Double, centroid: Double, flatness: Double) {
        let attackFrames = max(1, Int((SliceTimbre.attackWindowSeconds * sampleRate).rounded()))
        let used = min(samples.count, attackFrames)
        var size = 64
        while size < attackFrames { size *= 2 }
        let half = size / 2
        var windowed = [Float](repeating: 0, count: size)
        // Flat from the onset, a half-Hann over the last quarter of what is used.
        let taperStart = used - max(1, used / 4)
        for i in 0..<used {
            var w: Float = 1
            if i >= taperStart {
                let x = Double(i - taperStart) / Double(max(1, used - taperStart))
                w = Float(0.5 * (1 + cos(Double.pi * x)))
            }
            let value = samples[i]
            windowed[i] = value.isFinite ? value * w : 0
        }
        let log2n = vDSP_Length(Int(log2(Double(size))))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return (0, 0, 0, 0)
        }
        var realPart = [Float](repeating: 0, count: half)
        var imagPart = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        realPart.withUnsafeMutableBufferPointer { realBuffer in
            imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                // Packed real FFT: imagp[0] holds Nyquist; drop it (the TransientAnalyzer convention).
                imagBuffer[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        let binHz = sampleRate / Double(size)
        var total = 0.0, low = 0.0, high = 0.0, weighted = 0.0, maxPower = 0.0
        // Bin 0 (DC) is left out of every sum: an offset is not a sound.
        for bin in 1..<half {
            let p = Double(power[bin])
            guard p.isFinite, p > 0 else { continue }
            let hz = Double(bin) * binHz
            total += p
            weighted += p * hz
            if hz < SliceTimbre.lowBandHz { low += p }
            if hz > SliceTimbre.highBandHz { high += p }
            maxPower = max(maxPower, p)
        }
        guard total > 0 else { return (0, 0, 0, 0) }
        // Flatness over every bin but DC, with a floor 120 dB under the strongest bin so an exactly empty bin
        // reads as "very quiet", not as minus infinity.
        let floor = maxPower * 1e-12
        var logSum = 0.0
        var linearSum = 0.0
        for bin in 1..<half {
            let p = max(Double(power[bin]).isFinite ? Double(power[bin]) : 0, floor)
            logSum += log(p)
            linearSum += p
        }
        let bins = Double(half - 1)
        let flatness = linearSum > 0 ? exp(logSum / bins) / (linearSum / bins) : 0
        return (low / total, high / total, weighted / total, min(1, max(0, flatness)))
    }

    // MARK: - Decay

    static func decayTime(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double)
        -> (seconds: Double, reached: Bool) {
        let window = max(1, Int((envelopeWindowSeconds * sampleRate).rounded()))
        let hop = max(1, Int((envelopeHopSeconds * sampleRate).rounded()))
        let count = samples.count
        guard count > 0 else { return (0, true) }
        var envelope: [Float] = []
        envelope.reserveCapacity(count / hop + 1)
        var start = 0
        repeat {
            let length = min(window, count - start)
            var rms: Float = 0
            vDSP_rmsqv(samples.baseAddress! + start, 1, &rms, vDSP_Length(length))
            envelope.append(rms.isFinite ? rms : 0)
            start += hop
        } while start + window <= count
        guard let loudest = envelope.indices.max(by: { envelope[$0] < envelope[$1] }),
              envelope[loudest] > 0 else { return (0, true) }
        let floor = envelope[loudest] * Float(pow(10, -SliceTimbre.decayDropDb / 20))
        if let below = envelope[(loudest + 1)...].firstIndex(where: { $0 < floor }) {
            return (Double((below - loudest) * hop) / sampleRate, true)
        }
        return (Double(count - loudest * hop) / sampleRate, false)
    }

    // MARK: - The one read

    static func readMono(_ reader: AVAudioFile, format: AVAudioFormat, from start: Int, count: Int) throws -> [Float] {
        guard count > 0 else { return [] }
        let channelCount = Int(format.channelCount)
        reader.framePosition = AVAudioFramePosition(start)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw Failure.unreadable("buffer allocation failed")
        }
        var mono = [Float]()
        mono.reserveCapacity(count)
        var remaining = count
        var mixed = [Float](repeating: 0, count: Int(chunk.frameCapacity))
        var scale = 1 / Float(channelCount)
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(remaining, Int(chunk.frameCapacity)))
            try reader.read(into: chunk, frameCount: toRead)
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            let frames = Int(chunk.frameLength)
            mixed.withUnsafeMutableBufferPointer { out in
                out.baseAddress!.update(from: data[0], count: frames)
                for channel in 1..<max(1, channelCount) {
                    vDSP_vadd(out.baseAddress!, 1, data[channel], 1, out.baseAddress!, 1, vDSP_Length(frames))
                }
                vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(frames))
            }
            mono.append(contentsOf: mixed[0..<frames])
            remaining -= frames
        }
        // A short read leaves the tail silent rather than shifting every later slice.
        if mono.count < count { mono.append(contentsOf: [Float](repeating: 0, count: count - mono.count)) }
        return mono
    }
}
