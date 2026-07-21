import AVFAudio
import Accelerate
import DAWCore
import Foundation

/// Errors from offline audio-content analysis (m21-e).
public enum AudioContentAnalyzerError: Error, Equatable, Sendable {
    /// The source file could not be opened, or the requested window holds
    /// no samples.
    case unreadable(String)
}

/// Offline imported-audio content analyzer (m21-e, design-clip-analyze-audio
/// §3): key (chroma + Krumhansl-Schmuckler), tempo (onset-envelope
/// autocorrelation over the REUSED `TransientAnalyzer.spectralFlux`
/// front-end), spectral balance (the `MasterMixAnalyzer.bandEdges` 24-band
/// geometry), and levels — one windowed mono read, fully deterministic.
///
/// One 16384-pt/8192-hop Hann STFT pass serves BOTH chroma and spectral
/// balance (at 48 kHz: bin width 2.93 Hz < the 3.27 Hz semitone spacing at
/// 55 Hz, so the 12-bin fold is resolved at the bottom without a
/// constant-Q transform); the tempo front-end is `spectralFlux`'s own
/// 1024/256 pass, reused verbatim (TransientAnalyzer stays byte-untouched).
///
/// REAL-TIME SAFETY: this type is never referenced from the render path. It
/// allocates and does file I/O freely because it only ever runs inside a
/// detached task (see `AudioAnalysisCache`).
public enum AudioContentAnalyzer {
    /// Bumped whenever any tuning constant here / in `KeyEstimator` /
    /// `TempoEstimator` changes — the cache key includes it, so a tuning
    /// change re-analyzes instead of mixing generations.
    public static let analyzerVersion = 1

    /// Chroma/balance STFT geometry (design §3a).
    static let fftSize = 16_384
    static let hopSize = 8_192

    /// Chroma fold range, half-open [55, 3520) Hz — A1 up to (not including)
    /// A7, so pitch-class A doesn't own a 7th octave the others lack.
    static let chromaLowHz = 55.0
    static let chromaHighHz = 3_520.0

    /// Frames with RMS below this don't feed the chroma profile (silence
    /// must not dilute it). Balance has NO gate — it describes the clip as
    /// it plays.
    static let chromaSilenceGateDb = -60.0

    /// dB floor for every level-like field (JSON has no −inf) — the
    /// `MasterAnalysisSnapshot.floorDB` convention.
    static let floorDb = -80.0

    /// Macro-band edges for `SpectralSummary`, Hz (design §3c).
    static let summaryEdgesHz: [(low: Double, high: Double)] = [
        (20, 60), (60, 250), (250, 500), (500, 2_000), (2_000, 6_000),
        (6_000, 16_000),
    ]

    // MARK: - File entry point

    /// Reads the source window, mixes to mono, analyzes. Blocking — call
    /// from a detached task only (the cache does).
    public static func analyze(
        fileAt url: URL, windowStartSeconds: Double, windowDurationSeconds: Double
    ) throws -> AudioContentAnalysis {
        let (samples, sampleRate) = try readMonoWindow(
            url: url, startSeconds: windowStartSeconds,
            durationSeconds: windowDurationSeconds)
        var analysis = analyze(monoSamples: samples, sampleRate: sampleRate)
        analysis.windowStartSeconds = windowStartSeconds
        return analysis
    }

    // MARK: - Pure core (testable without files)

    /// The deterministic core: mono samples in, one `AudioContentAnalysis`
    /// out (`windowStartSeconds` reads 0 — the file entry point overwrites
    /// it). Degenerate input (empty / bad rate) reads as honest silence:
    /// floors everywhere, `tonal: false`, `bpm: nil`.
    public static func analyze(monoSamples: [Float], sampleRate: Double) -> AudioContentAnalysis {
        let duration = sampleRate > 0 ? Double(monoSamples.count) / sampleRate : 0

        // Levels (design §3d): sample peak + whole-window RMS, dBFS.
        var peak: Float = 0
        var rms: Float = 0
        if !monoSamples.isEmpty {
            vDSP_maxmgv(monoSamples, 1, &peak, vDSP_Length(monoSamples.count))
            vDSP_rmsqv(monoSamples, 1, &rms, vDSP_Length(monoSamples.count))
        }

        // One 16384-pt STFT pass → chroma + mean power spectrum.
        let pass = spectralPass(monoSamples: monoSamples, sampleRate: sampleRate)

        // Tempo front-end: TransientAnalyzer's flux, reused verbatim.
        let flux = sampleRate > 0
            ? TransientAnalyzer.spectralFlux(monoSamples: monoSamples) : []
        let envelopeRate = sampleRate > 0
            ? sampleRate / Double(TransientAnalyzer.hopSize) : 0

        return AudioContentAnalysis(
            durationSeconds: duration,
            windowStartSeconds: 0,
            sampleRate: sampleRate,
            samplePeakDb: amplitudeDb(Double(peak)),
            rmsDb: amplitudeDb(Double(rms)),
            key: KeyEstimator.estimate(chroma: pass.chroma),
            tempo: TempoEstimator.estimate(
                fluxEnvelope: flux, envelopeRate: envelopeRate,
                windowSeconds: duration),
            spectral: spectralBalance(
                meanPower: pass.meanPower, sampleRate: sampleRate),
            analyzerVersion: analyzerVersion)
    }

    // MARK: - The shared STFT pass (chroma + mean power)

    struct SpectralPass {
        /// Summed spectral magnitude per pitch class (silence-gated frames
        /// excluded). Scale-free for the consumers (correlation/flatness).
        var chroma: [Double]
        /// Mean power spectrum over ALL frames, amplitude-normalized
        /// (a bin-centered full-scale tone reads ≈ 1.0 at its bin).
        var meanPower: [Double]
    }

    /// 16384-pt Hann frames at 8192 hop, vDSP packed real FFT (the
    /// Nyquist-zero bin-0 convention). Input shorter than one frame is
    /// zero-padded to exactly one frame.
    static func spectralPass(monoSamples: [Float], sampleRate: Double) -> SpectralPass {
        let n = fftSize
        let half = n / 2
        var chroma = [Double](repeating: 0, count: 12)
        var meanPower = [Double](repeating: 0, count: half)
        guard sampleRate > 0, !monoSamples.isEmpty else {
            return SpectralPass(chroma: chroma, meanPower: meanPower)
        }
        let log2n = vDSP_Length(Int(log2(Double(n))))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2,
                                 ofType: DSPSplitComplex.self) else {
            return SpectralPass(chroma: chroma, meanPower: meanPower)
        }

        var samples = monoSamples
        if samples.count < n {
            samples.append(contentsOf: [Float](repeating: 0, count: n - samples.count))
        }
        let frameCount = (samples.count - n) / hopSize + 1

        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var windowSum: Float = 0
        vDSP_sve(hann, 1, &windowSum, vDSP_Length(n))
        // Raw packed-real-FFT magnitude × this ≈ tone amplitude (the
        // MasterMixAnalyzer scale: vDSP forward output is 2× the DFT, and a
        // bin-centered tone of amplitude A has |DFT| = A·Σw/2 — twos cancel).
        var amplitudeScale = windowSum > 0 ? 1 / windowSum : 0

        // Bin → pitch class for the chroma fold: nearest equal-tempered
        // semitone, A440, over [55, 3520) Hz.
        let binHz = sampleRate / Double(n)
        var chromaBins: [(bin: Int, pitchClass: Int)] = []
        for bin in 1..<half {
            let frequency = Double(bin) * binHz
            guard frequency >= chromaLowHz, frequency < chromaHighHz else { continue }
            let midi = 69.0 + 12.0 * log2(frequency / 440.0)
            let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
            chromaBins.append((bin, pitchClass))
        }

        var windowed = [Float](repeating: 0, count: n)
        var realPart = [Float](repeating: 0, count: half)
        var imagPart = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var powerScratch = [Float](repeating: 0, count: half)

        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                let start = frame * hopSize
                var frameRMS: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + start, 1, &frameRMS, vDSP_Length(n))
                let silent = !(frameRMS > 0)
                    || 20 * log10(Double(frameRMS)) < chromaSilenceGateDb

                vDSP_vmul(buffer.baseAddress! + start, 1, hann, 1,
                          &windowed, 1, vDSP_Length(n))
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
                        // Packed real FFT: imagp[0] holds Nyquist — zero it
                        // (the TransientAnalyzer bin-0 convention).
                        imagBuffer[0] = 0
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
                vDSP_vsmul(magnitudes, 1, &amplitudeScale, &magnitudes, 1,
                           vDSP_Length(half))
                // Power accumulates over ALL frames (no gate — balance
                // describes the clip as it plays). Double accumulation so
                // long files don't drift in Float.
                vDSP_vsq(magnitudes, 1, &powerScratch, 1, vDSP_Length(half))
                for bin in 0..<half {
                    let value = Double(powerScratch[bin])
                    if value.isFinite { meanPower[bin] += value }
                }
                if !silent {
                    for entry in chromaBins {
                        let value = Double(magnitudes[entry.bin])
                        if value.isFinite { chroma[entry.pitchClass] += value }
                    }
                }
            }
        }
        if frameCount > 0 {
            let scale = 1.0 / Double(frameCount)
            for bin in 0..<half { meanPower[bin] *= scale }
        }
        return SpectralPass(chroma: chroma, meanPower: meanPower)
    }

    // MARK: - Spectral balance (design §3c)

    /// The 24 `MasterMixAnalyzer.bandEdges` bands + centroid + macro
    /// summary from a mean power spectrum. Mean power DENSITY per band
    /// (per-bin average) so wide bands don't read hot for owning more bins.
    /// The fold itself lives in the SHARED `SpectrumBandFold` home (m22-g
    /// extraction — `ReferenceAnalyzer` consumes the same math; this
    /// function's output is bit-identical to the pre-extraction inline
    /// closure, pinned by this suite's existing band fixtures).
    static func spectralBalance(meanPower: [Double], sampleRate: Double) -> SpectralBalance {
        let half = meanPower.count
        let floorBands = SpectralBalance(
            bands: [Double](repeating: floorDb, count: MasterMixAnalyzer.bandCount),
            centroidHz: 0,
            summary: SpectralSummary(subDb: floorDb, bassDb: floorDb,
                                     lowMidDb: floorDb, midDb: floorDb,
                                     highMidDb: floorDb, airDb: floorDb))
        guard half > 1, sampleRate > 0 else { return floorBands }
        let binHz = sampleRate / Double(fftSize)

        /// The shared fold at THIS analyzer's 16384-pt geometry and −80 floor.
        func bandDb(low: Double, high: Double) -> Double {
            SpectrumBandFold.bandDb(meanPower: meanPower, sampleRate: sampleRate,
                                    fftSize: fftSize, low: low, high: high,
                                    floorDb: floorDb)
        }

        let bands = SpectrumBandFold.bandsDb(
            meanPower: meanPower, sampleRate: sampleRate, fftSize: fftSize,
            floorDb: floorDb)

        var weightedSum = 0.0
        var totalPower = 0.0
        for bin in 1..<half {
            let power = meanPower[bin]
            guard power > 0, power.isFinite else { continue }
            weightedSum += power * Double(bin) * binHz
            totalPower += power
        }
        let centroid = totalPower > 0 ? weightedSum / totalPower : 0

        let macro = summaryEdgesHz.map { bandDb(low: $0.low, high: $0.high) }
        return SpectralBalance(
            bands: bands,
            centroidHz: centroid.isFinite ? centroid : 0,
            summary: SpectralSummary(subDb: macro[0], bassDb: macro[1],
                                     lowMidDb: macro[2], midDb: macro[3],
                                     highMidDb: macro[4], airDb: macro[5]))
    }

    // MARK: - Windowed mono read

    /// Windowed mono mixdown (channel average) at the source rate — the
    /// `TransientAnalyzer.readMono` loop-read recipe with a `framePosition`
    /// seek and a frame cap (that analyzer is deliberately NOT refactored;
    /// keeping it byte-untouched outweighs the duplicated 30 lines —
    /// design §4).
    static func readMonoWindow(
        url: URL, startSeconds: Double, durationSeconds: Double
    ) throws -> (samples: [Float], sampleRate: Double) {
        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: url)
        } catch {
            throw AudioContentAnalyzerError.unreadable(
                "\(url.path): \(error.localizedDescription)")
        }
        let format = reader.processingFormat  // deinterleaved float32
        let channelCount = Int(format.channelCount)
        guard reader.length > 0, channelCount > 0, format.sampleRate > 0 else {
            throw AudioContentAnalyzerError.unreadable("empty source \(url.path)")
        }
        let rate = format.sampleRate
        let startFrame = AVAudioFramePosition((max(0, startSeconds) * rate).rounded())
        guard startFrame < reader.length else {
            throw AudioContentAnalyzerError.unreadable(
                "analysis window starts past the end of \(url.path)")
        }
        let requested = AVAudioFramePosition((max(0, durationSeconds) * rate).rounded())
        var remaining = min(reader.length - startFrame, requested)
        guard remaining > 0 else {
            throw AudioContentAnalyzerError.unreadable(
                "empty analysis window in \(url.path)")
        }
        reader.framePosition = startFrame

        var mono = [Float]()
        mono.reserveCapacity(Int(remaining))
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw AudioContentAnalyzerError.unreadable("buffer allocation failed")
        }
        let scale = 1 / Float(channelCount)
        var mixed = [Float](repeating: 0, count: Int(chunk.frameCapacity))
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(remaining,
                                               AVAudioFramePosition(chunk.frameCapacity)))
            try reader.read(into: chunk, frameCount: toRead)
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
            remaining -= AVAudioFramePosition(frames)
        }
        guard !mono.isEmpty else {
            throw AudioContentAnalyzerError.unreadable(
                "empty analysis window in \(url.path)")
        }
        return (mono, rate)
    }

    // MARK: - dB helpers (−80 floor; zero reads EXACTLY −80)

    static func amplitudeDb(_ amplitude: Double) -> Double {
        guard amplitude > 0, amplitude.isFinite else { return floorDb }
        return max(20 * log10(amplitude), floorDb)
    }

    /// Delegates to the shared fold home (m22-g extraction) — one copy of
    /// the flooring convention, never two that can drift.
    static func powerDb(_ power: Double) -> Double {
        SpectrumBandFold.powerDb(power, floorDb: floorDb)
    }
}
