import AVFAudio
import Accelerate
import DAWCore
import Foundation

/// Offline whole-file REFERENCE analyzer (m22-g, design-m22g-reference-tracks
/// §4): one streaming pass over the file feeding three homes —
///
///  1. **Loudness** — `Loudness.Stream` (DAWCore), the SAME K-weighting /
///     block / gating / LRA / 4× true-peak math as `Loudness.measure` (the
///     m22-c fp-identical family): the reference's LUFS and
///     `render.measureLoudness`'s LUFS are the same math by construction.
///     After EOF the interpolator tail is flushed with 31 zero frames
///     (taps − 1), reproducing `measure()`'s zero-padded edge exactly.
///  2. **Spectrum** — a 2048-pt Hann / 1024-hop STFT (the LIVE
///     `MasterMixAnalyzer` geometry) on the mono mix, mean power DENSITY
///     accumulated in Double over the whole file, folded into the 24
///     `MasterMixAnalyzer.bandEdges` bands through the SHARED
///     `SpectrumBandFold` home (the anti-fork extraction — the same fold
///     `AudioContentAnalyzer` uses).
///  3. **Stereo** — `StereoImage.Accumulator` (DAWCore) whole-file running
///     sums on ch0/ch1 (mono reads L = R → correlation +1 by definition).
///
/// STREAMING, never a full-file buffer: bounded 64 k-frame chunks (a few
/// hundred KB resident vs ~230 MB for a 10-minute file whole). Chunk-size
/// invariant by construction — the loudness stream is per-sample, the STFT
/// runs off a rolling FIFO, the stereo sums are order-preserving.
///
/// NaN/Inf handling: the loudness stream sanitizes at its own door; the
/// STFT skips a poisoned 2048-frame WHOLE (the MasterMixAnalyzer frame-skip
/// idiom); the stereo accumulator skips a poisoned chunk whole.
///
/// REAL-TIME SAFETY: never referenced from the render path — allocates and
/// does file I/O freely because it only runs inside a detached task
/// (`AudioEngine.analyzeReferenceFile`). No cache: the result persists in
/// the project's reference slot; re-analysis is a rare explicit verb
/// (deliberately NOT `AudioAnalysisCache`, design §4.2).
public enum ReferenceAnalyzer {
    /// Bumped whenever any tuning constant here (or in the shared fold /
    /// loudness homes) changes — persisted as
    /// `ReferenceAnalysis.analyzerVersion` so a stale analysis is
    /// re-runnable knowledge, not silent drift.
    public static let version = 1

    /// STFT geometry: the live `MasterMixAnalyzer` 2048/1024 (design §4.2).
    static let fftSize = MasterMixAnalyzer.fftSize
    static let hopSize = MasterMixAnalyzer.hopSize
    /// dB floor for the band spectrum (the house convention).
    static let floorDb = -80.0
    /// Bounded read chunk (design §4.2). Public only because it is a
    /// default-argument value of the public `analyze` (a Swift access rule,
    /// not a surface invitation).
    public static let defaultChunkFrames: AVAudioFrameCount = 65_536
    /// Loudness true-peak interpolator tail: taps − 1 zero frames after EOF
    /// (the m22-c convergence-gate edge).
    static let truePeakTailFrames = 31

    /// Analyzes the whole file at `url`. Blocking — call from a detached
    /// task only. `chunkFrames` is a test seam (chunk-size invariance pin);
    /// production uses the 64 k default.
    public static func analyze(
        fileAt url: URL, chunkFrames: AVAudioFrameCount = defaultChunkFrames
    ) throws -> ReferenceAnalysis {
        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: url)
        } catch {
            throw AudioContentAnalyzerError.unreadable(
                "\(url.path): \(error.localizedDescription)")
        }
        let format = reader.processingFormat  // deinterleaved float32
        let channelCount = Int(format.channelCount)
        let rate = format.sampleRate
        guard reader.length > 0, channelCount > 0, rate > 0 else {
            throw AudioContentAnalyzerError.unreadable("empty source \(url.path)")
        }
        guard let chunk = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: max(1, chunkFrames)) else {
            throw AudioContentAnalyzerError.unreadable("buffer allocation failed")
        }

        let loudness = Loudness.Stream(sampleRate: rate, channelCount: channelCount)
        var stereo = StereoImage.Accumulator()
        var spectrum = SpectrumAccumulator(sampleRate: rate)

        var monoScratch = [Float](repeating: 0, count: Int(chunk.frameCapacity))
        let monoScale = 1 / Float(channelCount)

        var remaining = reader.length
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunk.frameCapacity)))
            try reader.read(into: chunk, frameCount: toRead)
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            let frames = Int(chunk.frameLength)

            // (1) Loudness: the deinterleaved buffer feeds the stream directly.
            loudness.process(channels: data, channelCount: channelCount, frameCount: frames)

            // (3) Stereo: ch0/ch1 (the L/R convention); mono reads L = R.
            let left = UnsafeBufferPointer(start: data[0], count: frames)
            let right = UnsafeBufferPointer(
                start: data[channelCount >= 2 ? 1 : 0], count: frames)
            stereo.process(left: left, right: right)

            // (2) Spectrum: mono mix (channel average — the
            // AudioContentAnalyzer/MasterMixAnalyzer convention) into the
            // rolling STFT.
            if channelCount == 1 {
                spectrum.process(UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                monoScratch.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.update(from: data[0], count: frames)
                    for channel in 1..<channelCount {
                        vDSP_vadd(out.baseAddress!, 1, data[channel], 1,
                                  out.baseAddress!, 1, vDSP_Length(frames))
                    }
                    var scale = monoScale
                    vDSP_vsmul(out.baseAddress!, 1, &scale,
                               out.baseAddress!, 1, vDSP_Length(frames))
                    spectrum.process(UnsafeBufferPointer(
                        start: out.baseAddress!, count: frames))
                }
            }
            remaining -= AVAudioFramePosition(frames)
        }

        // Interpolator tail (loudness only): 31 zero frames reproduce the
        // offline zero-padded true-peak edge. The spectrum/stereo homes
        // deliberately see NOTHING here — zeros are not program.
        let tail = [[Float]](
            repeating: [Float](repeating: 0, count: truePeakTailFrames),
            count: channelCount)
        loudness.process(tail)

        let snapshot = loudness.snapshot()
        let aggregate = stereo.aggregate()
        return ReferenceAnalysis(
            integratedLufs: snapshot.integratedLufs,
            maxMomentaryLufs: snapshot.maxMomentaryLufs,
            maxShortTermLufs: snapshot.maxShortTermLufs,
            truePeakDbtp: snapshot.truePeakDbtp,
            loudnessRangeLu: snapshot.loudnessRangeLu,
            bandsDb: spectrum.bandsDb(),
            correlation: aggregate.correlation,
            width: aggregate.width,
            balance: aggregate.balance,
            durationSeconds: Double(reader.length) / rate,
            sampleRateHz: rate,
            analyzerVersion: version)
    }

    // MARK: - Whole-file mean-power STFT accumulator (2048/1024)

    /// Rolling-FIFO Hann STFT accumulating per-bin mean power in Double —
    /// chunk-size invariant by construction (frames land on the same
    /// 1024-hop boundaries however the input is sliced). A frame whose RMS
    /// is non-finite is skipped WHOLE (the MasterMixAnalyzer poison rule).
    /// Offline-only: allocates in init, runs on the caller's detached task.
    struct SpectrumAccumulator {
        private let sampleRate: Double
        private let half = ReferenceAnalyzer.fftSize / 2
        private let fft: vDSP.FFT<DSPSplitComplex>?
        private let hann: [Float]
        private let amplitudeScale: Float
        private var fifo: [Float]
        private var fifoFill = 0
        private var powerSums: [Double]
        private var frameCount = 0
        private var windowed: [Float]
        private var realPart: [Float]
        private var imagPart: [Float]
        private var magnitudes: [Float]
        private var powerScratch: [Float]

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            let n = ReferenceAnalyzer.fftSize
            let log2n = vDSP_Length(Int(log2(Double(n))))
            fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
            var window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
            hann = window
            var windowSum: Float = 0
            vDSP_sve(window, 1, &windowSum, vDSP_Length(n))
            // The shared amplitude normalization (1/Σhann): a bin-centered
            // tone of amplitude A reads |bin| ≈ A — the scale BOTH other
            // spectrum homes use, so the fold's density is comparable.
            amplitudeScale = windowSum > 0 ? 1 / windowSum : 0
            fifo = [Float](repeating: 0, count: n)
            powerSums = [Double](repeating: 0, count: half)
            windowed = [Float](repeating: 0, count: n)
            realPart = [Float](repeating: 0, count: half)
            imagPart = [Float](repeating: 0, count: half)
            magnitudes = [Float](repeating: 0, count: half)
            powerScratch = [Float](repeating: 0, count: half)
        }

        mutating func process(_ samples: UnsafeBufferPointer<Float>) {
            guard var cursor = samples.baseAddress else { return }
            var remaining = samples.count
            let n = ReferenceAnalyzer.fftSize
            let hop = ReferenceAnalyzer.hopSize
            while remaining > 0 {
                let take = min(n - fifoFill, remaining)
                fifo.withUnsafeMutableBufferPointer {
                    ($0.baseAddress! + fifoFill).update(from: cursor, count: take)
                }
                fifoFill += take
                cursor += take
                remaining -= take
                if fifoFill == n {
                    accumulateFrame()
                    // Slide the window left by one hop (memmove semantics).
                    fifo.withUnsafeMutableBufferPointer {
                        $0.baseAddress!.update(from: $0.baseAddress! + hop, count: n - hop)
                    }
                    fifoFill = n - hop
                }
            }
        }

        private mutating func accumulateFrame() {
            guard let fft else { return }
            let n = ReferenceAnalyzer.fftSize
            let vHalf = vDSP_Length(half)
            // Poison guard: a frame carrying NaN/Inf is skipped whole.
            var rms: Float = 0
            vDSP_rmsqv(fifo, 1, &rms, vDSP_Length(n))
            guard rms.isFinite else { return }

            vDSP_vmul(fifo, 1, hann, 1, &windowed, 1, vDSP_Length(n))
            realPart.withUnsafeMutableBufferPointer { realBuffer in
                imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imagBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { windowedBuffer in
                        windowedBuffer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: half
                        ) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &split, 1, vHalf)
                        }
                    }
                    fft.forward(input: split, output: &split)
                    // Packed real FFT: imagp[0] holds Nyquist — zero it (the
                    // house bin-0 convention).
                    imagBuffer[0] = 0
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vHalf)
                }
            }
            var scale = amplitudeScale
            vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vHalf)
            vDSP_vsq(magnitudes, 1, &powerScratch, 1, vHalf)
            for bin in 0..<half {
                let value = Double(powerScratch[bin])
                if value.isFinite { powerSums[bin] += value }
            }
            frameCount += 1
        }

        /// The 24-band mean power density in dB through the SHARED fold,
        /// with the LIVE home's nearest-bin rule for too-narrow bands (the
        /// reference curve overlays the live mix spectrum — same geometry,
        /// same conventions). Zero analyzed frames reads the floors.
        func bandsDb() -> [Double] {
            var meanPower = powerSums
            if frameCount > 0 {
                let scale = 1.0 / Double(frameCount)
                for bin in 0..<half { meanPower[bin] *= scale }
            }
            return SpectrumBandFold.bandsDb(
                meanPower: meanPower, sampleRate: sampleRate,
                fftSize: ReferenceAnalyzer.fftSize,
                floorDb: ReferenceAnalyzer.floorDb,
                emptyBandReadsNearestBin: true)
        }
    }
}
