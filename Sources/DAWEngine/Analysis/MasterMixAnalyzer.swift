import Accelerate
import DAWCore
import Foundation

/// Master-mix analysis engine (M8 vm-a, "session vibe meter"): consumes
/// mono-mixed master-bus samples and maintains the running
/// `MasterAnalysisSnapshot` — 24 log-spaced spectral bands (40 Hz → 16 kHz,
/// dB, −80 floor), short-term RMS level, held peak, spectral centroid
/// ("brightness"), and normalized spectral flux 0–1 ("energy movement") —
/// that the UI's vibe meter (vm-b) and agents (`mixer.masterAnalysis`) poll.
///
/// GEOMETRY: 2048-sample Hann frames at 1024 hop (~46 analysis frames/s at
/// 48 kHz), vDSP packed real FFT. Bands are the 24 geometric subdivisions of
/// [40, 16000] Hz; FFT bins map to bands by center frequency, and a band too
/// narrow to own a bin (only the lowest few at 48 kHz) reads its nearest bin.
///
/// SMOOTHING: band/level powers run an asymmetric one-pole (fast attack,
/// ~60 ms-per-e-fold release) so values move like meters, not strobes; peak
/// holds with a −20 dB/s release; centroid runs a symmetric one-pole; flux is
/// instant-attack with a 0.75×/frame release. Silence therefore DECAYS to the
/// floors and a fresh/reset analyzer sits exactly on them.
///
/// REAL-TIME SAFETY: everything is preallocated in `init` — `process` and
/// `snapshot()` never allocate (snapshot's 24-element `bands` array is the
/// one deliberate exception, matching the existing meter tap's per-buffer
/// `MeterFrame`+`Task` publish idiom), never lock, never touch ObjC. All
/// numeric paths are NaN/denormal-guarded: a poisoned input frame is skipped
/// whole (state stays clean) and every published field is floor-clamped
/// finite, so the wire never carries NaN/Inf.
///
/// THREADING CONTRACT (`@unchecked Sendable`): `process*` and `snapshot()`
/// run on ONE thread at a time — in the engine that is AVFAudio's serial tap
/// queue (the produced snapshot value then hops to the main actor, exactly
/// like `MeterFrame`s do). `reset()` may only be called while no tap is
/// firing (engine stopped), or from tests' single thread.
public final class MasterMixAnalyzer: @unchecked Sendable {

    // MARK: - Tuning constants

    /// Analysis window (FFT size). 2048 @ 48 kHz ≈ 43 ms — enough for the
    /// 40 Hz bottom band to see a full cycle, short enough to feel live.
    public static let fftSize = 2048
    /// Hop between analysis frames (50% overlap → ~46 frames/s at 48 kHz).
    public static let hopSize = 1024
    /// Number of log-spaced spectral bands.
    public static let bandCount = MasterAnalysisSnapshot.bandCount
    /// Band range: 24 geometric steps from 40 Hz to 16 kHz.
    public static let lowestBandHz = 40.0
    public static let highestBandHz = 16_000.0

    /// dB floor for every level-like field (JSON has no −inf).
    static let floorDB = MasterAnalysisSnapshot.floorDB
    /// Power epsilon: 10·log10(1e-8) = −80 dB, the floor by construction.
    private static let powerEpsilon: Float = 1e-8
    /// Amplitude epsilon: 20·log10(1e-4) = −80 dB likewise.
    private static let amplitudeEpsilon: Float = 1e-4
    /// Anything below this flushes to exactly zero (denormal guard for the
    /// one-pole release tails).
    private static let denormalFloor: Float = 1e-12
    /// A held peak below −100 dB snaps to zero so the published `peakDB`
    /// lands EXACTLY on the −80 floor (the +1e-4 log epsilon would otherwise
    /// pin a decayed-but-nonzero peak a hair above it forever).
    private static let peakFloor: Float = 1e-5

    /// Asymmetric one-pole coefficients for band/level POWER smoothing, per
    /// analysis frame (~21 ms): attack reaches ~94% in 4 frames; release
    /// e-folds every ~2.9 frames (~61 ms) so a stopped transport decays to
    /// the −80 floor in about a second.
    private static let energyAttack: Float = 0.5
    private static let energyRelease: Float = 0.35
    /// Centroid one-pole (symmetric — brightness should glide both ways).
    private static let centroidSmoothing: Float = 0.4
    /// Flux release per frame (attack is instant).
    private static let fluxRelease: Float = 0.75
    /// Peak-hold release: −20 dB per second, converted per frame in `init`.
    private static let peakReleaseDBPerSecond: Float = 20

    /// The 25 geometric band edges in Hz (`bandEdges[k] ... bandEdges[k+1]`
    /// is band k). Public so vm-b can label its bars and tests can pin them.
    public static let bandEdges: [Double] = (0...bandCount).map { k in
        lowestBandHz * pow(highestBandHz / lowestBandHz,
                           Double(k) / Double(bandCount))
    }

    /// The band whose [edge, nextEdge) range contains `frequency`, clamped
    /// into 0..<bandCount (below 40 Hz → band 0, at/above 16 kHz → band 23).
    public static func bandIndex(containing frequency: Double) -> Int {
        guard frequency > lowestBandHz else { return 0 }
        let position = Double(bandCount)
            * log(frequency / lowestBandHz)
            / log(highestBandHz / lowestBandHz)
        return min(bandCount - 1, max(0, Int(position)))
    }

    // MARK: - Preallocated state (init-time only; fixed thereafter)

    private let sampleRate: Double
    private let half = MasterMixAnalyzer.fftSize / 2
    private let fft: vDSP.FFT<DSPSplitComplex>
    /// 1 / Σ(hann): raw packed-real-FFT magnitude × this ≈ tone amplitude
    /// (vDSP_fft_zrip's forward output is 2× the mathematical DFT, and a
    /// bin-centered tone of amplitude A has |DFT| = A·Σw/2 — the twos cancel).
    private let amplitudeScale: Float
    private let peakReleasePerFrame: Float

    private let hann: UnsafeMutablePointer<Float>
    private let fifo: UnsafeMutablePointer<Float>          // fftSize
    private let windowed: UnsafeMutablePointer<Float>      // fftSize
    private let realPart: UnsafeMutablePointer<Float>      // half
    private let imagPart: UnsafeMutablePointer<Float>      // half
    private let magnitudes: UnsafeMutablePointer<Float>    // half (raw scale)
    private let previousMagnitudes: UnsafeMutablePointer<Float>  // half
    private let scratch: UnsafeMutablePointer<Float>       // half (flux diff)
    private let power: UnsafeMutablePointer<Float>         // half (raw scale)
    private let binFrequencies: UnsafeMutablePointer<Float>  // half
    private let monoScratch: UnsafeMutablePointer<Float>   // monoScratchSize
    private let monoScratchSize = 4096

    /// Bin range per band, precomputed: bands are contiguous bin runs; a
    /// band with no bin center inside it reads its single nearest bin.
    private var bandBinStart = [Int](repeating: 1, count: MasterMixAnalyzer.bandCount)
    private var bandBinCount = [Int](repeating: 1, count: MasterMixAnalyzer.bandCount)

    private var fifoFill = 0
    private var hasPreviousSpectrum = false

    // Smoothed outputs (written by process*, read by snapshot()).
    private var smoothedBandPower = [Float](repeating: 0, count: MasterMixAnalyzer.bandCount)
    private var smoothedLevelPower: Float = 0
    private var heldPeak: Float = 0
    private var smoothedCentroidHz: Float = 0
    private var smoothedFlux: Float = 0

    // MARK: - Init / deinit

    /// `sampleRate` must be > 0 (anything else falls back to 48 kHz — the
    /// analyzer must never trap on a degenerate live format).
    public init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate

        let n = MasterMixAnalyzer.fftSize
        let log2n = vDSP_Length(Int(log2(Double(n))))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2,
                                 ofType: DSPSplitComplex.self) else {
            preconditionFailure("vDSP.FFT setup must exist for 2^\(log2n)")
        }
        self.fft = fft

        hann = .allocate(capacity: n)
        fifo = .allocate(capacity: n)
        windowed = .allocate(capacity: n)
        realPart = .allocate(capacity: half)
        imagPart = .allocate(capacity: half)
        magnitudes = .allocate(capacity: half)
        previousMagnitudes = .allocate(capacity: half)
        scratch = .allocate(capacity: half)
        power = .allocate(capacity: half)
        binFrequencies = .allocate(capacity: half)
        monoScratch = .allocate(capacity: monoScratchSize)

        vDSP_hann_window(hann, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        var windowSum: Float = 0
        vDSP_sve(hann, 1, &windowSum, vDSP_Length(n))
        amplitudeScale = windowSum > 0 ? 1 / windowSum : 0

        fifo.initialize(repeating: 0, count: n)
        windowed.initialize(repeating: 0, count: n)
        realPart.initialize(repeating: 0, count: half)
        imagPart.initialize(repeating: 0, count: half)
        magnitudes.initialize(repeating: 0, count: half)
        previousMagnitudes.initialize(repeating: 0, count: half)
        scratch.initialize(repeating: 0, count: half)
        power.initialize(repeating: 0, count: half)
        monoScratch.initialize(repeating: 0, count: monoScratchSize)

        let binHz = rate / Double(n)
        for bin in 0..<half {
            binFrequencies[bin] = Float(Double(bin) * binHz)
        }

        // Band → contiguous bin run. Bins are assigned by center frequency;
        // an empty band (narrower than one bin) takes the bin nearest its
        // geometric center, clamped inside 1..<half (DC excluded).
        let edges = MasterMixAnalyzer.bandEdges
        var nextBin = 1
        for band in 0..<MasterMixAnalyzer.bandCount {
            let lower = edges[band]
            let upper = edges[band + 1]
            while nextBin < half, Double(nextBin) * binHz < lower { nextBin += 1 }
            var count = 0
            let start = nextBin
            while nextBin < half, Double(nextBin) * binHz < upper {
                count += 1
                nextBin += 1
            }
            if count > 0 {
                bandBinStart[band] = start
                bandBinCount[band] = count
            } else {
                let center = (lower * upper).squareRoot()
                let nearest = Int((center / binHz).rounded())
                bandBinStart[band] = min(half - 1, max(1, nearest))
                bandBinCount[band] = 1
            }
        }

        // Peak release −20 dB/s expressed per analysis frame.
        let framesPerSecond = rate / Double(MasterMixAnalyzer.hopSize)
        peakReleasePerFrame = pow(
            10, -MasterMixAnalyzer.peakReleaseDBPerSecond / (20 * Float(framesPerSecond)))
    }

    deinit {
        hann.deallocate()
        fifo.deallocate()
        windowed.deallocate()
        realPart.deallocate()
        imagPart.deallocate()
        magnitudes.deallocate()
        previousMagnitudes.deallocate()
        scratch.deallocate()
        power.deallocate()
        binFrequencies.deallocate()
        monoScratch.deallocate()
    }

    // MARK: - Feeding

    /// Feed mono samples (any count). Runs zero or more analysis frames as
    /// the internal FIFO fills. Never allocates.
    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard var cursor = samples.baseAddress else { return }
        var remaining = samples.count
        let n = MasterMixAnalyzer.fftSize
        let hop = MasterMixAnalyzer.hopSize
        while remaining > 0 {
            let take = min(n - fifoFill, remaining)
            (fifo + fifoFill).update(from: cursor, count: take)
            fifoFill += take
            cursor += take
            remaining -= take
            if fifoFill == n {
                analyzeFrame()
                // Slide the window left by one hop (memmove semantics).
                (fifo).update(from: fifo + hop, count: n - hop)
                fifoFill = n - hop
            }
        }
    }

    /// Array convenience for tests / offline callers.
    public func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// Mono-mixes a deinterleaved float buffer (the `floatChannelData`
    /// shape) into the preallocated scratch and feeds it, in bounded chunks.
    /// Never allocates — safe from the engine's tap callback.
    public func processMix(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) {
        guard channelCount > 0, frameCount > 0 else { return }
        if channelCount == 1 {
            process(UnsafeBufferPointer(start: channels[0], count: frameCount))
            return
        }
        var offset = 0
        var channelScale = 1 / Float(channelCount)
        while offset < frameCount {
            let chunk = min(monoScratchSize, frameCount - offset)
            monoScratch.update(from: channels[0] + offset, count: chunk)
            for channel in 1..<channelCount {
                vDSP_vadd(monoScratch, 1, channels[channel] + offset, 1,
                          monoScratch, 1, vDSP_Length(chunk))
            }
            vDSP_vsmul(monoScratch, 1, &channelScale,
                       monoScratch, 1, vDSP_Length(chunk))
            process(UnsafeBufferPointer(start: monoScratch, count: chunk))
            offset += chunk
        }
    }

    // MARK: - Snapshot

    /// The current smoothed analysis. Every field is finite and floor-
    /// clamped; a fresh (or fully decayed) analyzer returns `.floor` exactly.
    public func snapshot() -> MasterAnalysisSnapshot {
        var bands = [Float](repeating: MasterMixAnalyzer.floorDB,
                            count: MasterMixAnalyzer.bandCount)
        for band in 0..<MasterMixAnalyzer.bandCount {
            bands[band] = Self.powerDB(smoothedBandPower[band])
        }
        return MasterAnalysisSnapshot(
            bands: bands,
            levelDB: Self.powerDB(smoothedLevelPower),
            peakDB: Self.amplitudeDB(heldPeak),
            centroidHz: Self.finiteOrZero(max(0, smoothedCentroidHz)),
            flux: min(1, max(0, Self.finiteOrZero(smoothedFlux)))
        )
    }

    /// Back to the exact floor state. NOT safe against a concurrently firing
    /// tap — call only while the engine is stopped (or from tests).
    public func reset() {
        fifoFill = 0
        hasPreviousSpectrum = false
        fifo.update(repeating: 0, count: MasterMixAnalyzer.fftSize)
        previousMagnitudes.update(repeating: 0, count: half)
        for band in 0..<MasterMixAnalyzer.bandCount { smoothedBandPower[band] = 0 }
        smoothedLevelPower = 0
        heldPeak = 0
        smoothedCentroidHz = 0
        smoothedFlux = 0
    }

    // MARK: - One analysis frame (fifo holds fftSize samples)

    private func analyzeFrame() {
        let n = MasterMixAnalyzer.fftSize
        let vHalf = vDSP_Length(half)

        // Time-domain level/peak from the RAW window. A non-finite RMS means
        // the frame carries NaN/Inf — skip it whole; state stays clean.
        var rms: Float = 0
        vDSP_rmsqv(fifo, 1, &rms, vDSP_Length(n))
        guard rms.isFinite else { return }
        var framePeak: Float = 0
        vDSP_maxmgv(fifo, 1, &framePeak, vDSP_Length(n))

        // Windowed FFT → raw magnitude spectrum (packed real; Nyquist zeroed
        // so bin 0 is purely |DC|, the TransientAnalyzer convention).
        vDSP_vmul(fifo, 1, hann, 1, windowed, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: realPart, imagp: imagPart)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vHalf)
        }
        fft.forward(input: split, output: &split)
        imagPart[0] = 0
        vDSP_zvabs(&split, 1, magnitudes, 1, vHalf)

        // Spectral flux: half-wave-rectified magnitude increase, normalized
        // by the current frame's total magnitude (scale cancels) → 0…1.
        var fluxTarget: Float = 0
        var totalMagnitude: Float = 0
        vDSP_sve(magnitudes, 1, &totalMagnitude, vHalf)
        if hasPreviousSpectrum,
           totalMagnitude.isFinite,
           totalMagnitude * amplitudeScale > MasterMixAnalyzer.amplitudeEpsilon {
            vDSP_vsub(previousMagnitudes, 1, magnitudes, 1, scratch, 1, vHalf)
            var lower: Float = 0
            var upper = Float.greatestFiniteMagnitude
            vDSP_vclip(scratch, 1, &lower, &upper, scratch, 1, vHalf)
            var rawFlux: Float = 0
            vDSP_sve(scratch, 1, &rawFlux, vHalf)
            fluxTarget = min(1, max(0, Self.finiteOrZero(rawFlux / totalMagnitude)))
        }
        previousMagnitudes.update(from: magnitudes, count: half)
        hasPreviousSpectrum = true

        // Power spectrum (raw scale) → bands, centroid.
        vDSP_vsq(magnitudes, 1, power, 1, vHalf)
        let powerScale = amplitudeScale * amplitudeScale
        for band in 0..<MasterMixAnalyzer.bandCount {
            var sum: Float = 0
            vDSP_sve(power + bandBinStart[band], 1, &sum,
                     vDSP_Length(bandBinCount[band]))
            let mean = Self.finiteOrZero(sum / Float(bandBinCount[band]) * powerScale)
            smoothedBandPower[band] = Self.flushDenormal(
                Self.smoothEnergy(current: smoothedBandPower[band], target: mean))
        }

        var weighted: Float = 0
        var totalPower: Float = 0
        vDSP_dotpr(power + 1, 1, binFrequencies + 1, 1, &weighted, vDSP_Length(half - 1))
        vDSP_sve(power + 1, 1, &totalPower, vDSP_Length(half - 1))
        let centroidTarget: Float =
            (totalPower.isFinite && weighted.isFinite
             && totalPower * powerScale > MasterMixAnalyzer.powerEpsilon)
            ? weighted / totalPower : 0
        smoothedCentroidHz = Self.flushDenormal(
            smoothedCentroidHz
            + MasterMixAnalyzer.centroidSmoothing * (centroidTarget - smoothedCentroidHz))

        // Level (RMS power), peak hold, flux ballistics.
        let framePower = rms * rms
        smoothedLevelPower = Self.flushDenormal(
            Self.smoothEnergy(current: smoothedLevelPower, target: framePower))
        heldPeak = Self.flushDenormal(
            framePeak.isFinite
            ? max(framePeak, heldPeak * peakReleasePerFrame)
            : heldPeak * peakReleasePerFrame)
        if heldPeak < MasterMixAnalyzer.peakFloor { heldPeak = 0 }
        smoothedFlux = fluxTarget > smoothedFlux
            ? fluxTarget
            : Self.flushDenormal(smoothedFlux * MasterMixAnalyzer.fluxRelease)
    }

    // MARK: - Small numeric helpers

    private static func smoothEnergy(current: Float, target: Float) -> Float {
        let alpha = target > current ? energyAttack : energyRelease
        return current + alpha * (target - current)
    }

    private static func flushDenormal(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return value < denormalFloor ? 0 : value
    }

    private static func finiteOrZero(_ value: Float) -> Float {
        value.isFinite ? value : 0
    }

    /// Power → dB, epsilon-floored so exact silence reads exactly −80.
    private static func powerDB(_ power: Float) -> Float {
        guard power > 0, power.isFinite else { return floorDB }
        return max(floorDB, 10 * log10(power + powerEpsilon))
    }

    /// Amplitude → dB, same floor convention.
    private static func amplitudeDB(_ amplitude: Float) -> Float {
        guard amplitude > 0, amplitude.isFinite else { return floorDB }
        return max(floorDB, 20 * log10(amplitude + amplitudeEpsilon))
    }
}
