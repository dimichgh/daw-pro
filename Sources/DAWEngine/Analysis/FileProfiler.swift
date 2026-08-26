import AVFAudio
import Accelerate
import DAWCore
import Foundation

/// Offline windowed peak/RMS profile of an ARBITRARY file on disk (m25-z —
/// "what is the peak level between 53 s and 54 s of this WAV", the question
/// nothing on the wire answered until now, forcing a verification session
/// out to four external probes — `astats`, `silencedetect`, `ffprobe`, a
/// hand-written python profiler — to check ONE rendered file).
///
/// A DIFFERENT job from ``ReferenceAnalyzer``/``Loudness``: this is NOT a
/// second copy of the BS.1770 loudness path. m23-ch deliberately kept an
/// external `ebur128` cross-check because a single meter cannot detect its
/// own miscount — an in-app loudness reading can never validate an in-app
/// loudness reading, so that check stays external. This analyzer computes
/// plain sample peak/RMS per time window, which dodges that circularity
/// entirely (it is not measuring "how loud", it is measuring "what is here,
/// windowed") and must never grow LUFS math.
///
/// FILE OPEN: shares ``ReferenceAnalyzer/openValidatedFile(_:)`` rather than
/// re-deriving its own "is this a readable, non-empty audio file" check —
/// the m23-ch anti-fork reasoning applied to file I/O instead of DSP
/// coefficients (two file readers could disagree about what a file
/// contains).
///
/// CHANNEL COMBINATION — the one choice worth pinning explicitly, because
/// two homes in this package already disagree: ``AudioContentAnalyzer``
/// mixes to MONO before taking peak/RMS, which can CANCEL anti-phase
/// content and under-report a clip. This analyzer instead takes MAX-ABS
/// across channels for peak and combines every channel's samples into one
/// RMS — the SAME rule the LIVE meter tap uses (`AudioEngine.swift`'s
/// `installTap` meter closure, `MeterFrame(peak:rms:)`), because
/// under-reporting a peak on a "did this window clip" check is the
/// dangerous failure, and that question is exactly what a peak reading
/// here is for.
///
/// SAMPLE PEAK, NOT TRUE PEAK: `peakDb` is the raw inter-sample maximum —
/// NOT the 4x-oversampled BS.1770 Annex-2 true peak `Loudness`/
/// `ReferenceAnalyzer` report as `truePeakDbtp`. A window can read under
/// 0 dBFS sample peak here and still exceed 0 dBTP true peak between
/// samples. Use `render.measureLoudness`/`reference.analyze` for true-peak
/// questions.
///
/// HONEST ABSENCE: a window whose linear peak/RMS is exactly zero (digital
/// silence) or non-finite omits `peakDb`/`rmsDb` rather than reporting `0`
/// or a sentinel — the same nil convention `Loudness.swift` uses ("zero
/// energy has no dB value"). This is DELIBERATELY not `MeterLevel`'s
/// floor-at-−80 convention: that one is for an always-on live meter reading
/// something every 1024-sample tap; this is a diagnostic read of a file on
/// disk, and a digitally silent window truly has no dB value to report.
///
/// REAL-TIME SAFETY: never referenced from the render path — runs only
/// inside a detached task (`AudioEngine.profileFile`), same as
/// `ReferenceAnalyzer`/`AudioContentAnalyzer`. Read-only: never writes,
/// never copies, never touches the project's reference slot.
public enum FileProfiler {
    /// Bounded read chunk (the `ReferenceAnalyzer`/`AudioContentAnalyzer`
    /// convention) — a few hundred KB resident regardless of file length.
    public static let defaultChunkFrames: AVAudioFrameCount = 65_536

    /// Profiles `[fromSeconds, fromSeconds + durationSeconds)` of the file
    /// at `url` (or `[fromSeconds, EOF)` when `durationSeconds` is nil) into
    /// consecutive `windowSeconds`-wide windows, streamed in bounded chunks
    /// — never a full-file buffer. Blocking — call from a detached task
    /// only. `chunkFrames` is a test seam (chunk-size invariance pin);
    /// production uses the 64k default.
    public static func profile(
        fileAt url: URL, windowSeconds: Double,
        fromSeconds: Double = 0, durationSeconds: Double? = nil,
        chunkFrames: AVAudioFrameCount = defaultChunkFrames
    ) throws -> FileProfile {
        guard windowSeconds > 0 else {
            throw AudioContentAnalyzerError.unreadable("windowSeconds must be > 0")
        }
        let reader = try ReferenceAnalyzer.openValidatedFile(url)
        let format = reader.processingFormat
        let channelCount = Int(format.channelCount)
        let rate = format.sampleRate
        let fileDurationSeconds = Double(reader.length) / rate

        // On-disk bit depth / float-ness (the `ffprobe` readback) — absent
        // for formats with no fixed PCM bit depth (compressed codecs),
        // where these settings keys simply don't exist. Never fabricated.
        let fileSettings = reader.fileFormat.settings
        let bitDepth = fileSettings[AVLinearPCMBitDepthKey] as? Int
        let isFloat = fileSettings[AVLinearPCMIsFloatKey] as? Bool

        let clampedFrom = max(0, fromSeconds)
        let startFrame = AVAudioFramePosition((clampedFrom * rate).rounded())
        guard startFrame < reader.length else {
            throw AudioContentAnalyzerError.unreadable(
                "profile window starts past the end of \(url.path)")
        }
        let requestedFrames: AVAudioFramePosition
        if let durationSeconds {
            guard durationSeconds > 0 else {
                throw AudioContentAnalyzerError.unreadable("durationSeconds must be > 0")
            }
            requestedFrames = AVAudioFramePosition((durationSeconds * rate).rounded())
        } else {
            requestedFrames = reader.length - startFrame
        }
        var remaining = min(reader.length - startFrame, requestedFrames)
        guard remaining > 0 else {
            throw AudioContentAnalyzerError.unreadable("empty profile window in \(url.path)")
        }
        reader.framePosition = startFrame

        let windowFrameCount = max(1, Int((windowSeconds * rate).rounded()))
        guard let chunk = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: max(1, chunkFrames)) else {
            throw AudioContentAnalyzerError.unreadable("buffer allocation failed")
        }

        var windows: [FileProfileWindow] = []
        var windowStartFrame = startFrame
        var framesInWindow = 0
        var windowPeak: Float = 0
        var windowSumSquares: Double = 0
        var windowSampleCount = 0

        func flushWindow() {
            guard framesInWindow > 0 else { return }
            windows.append(FileProfileWindow(
                startSeconds: Double(windowStartFrame) / rate,
                durationSeconds: Double(framesInWindow) / rate,
                peakDb: decibels(windowPeak),
                rmsDb: decibels(windowSampleCount > 0
                    ? Float((windowSumSquares / Double(windowSampleCount)).squareRoot())
                    : 0)))
            windowStartFrame += AVAudioFramePosition(framesInWindow)
            framesInWindow = 0
            windowPeak = 0
            windowSumSquares = 0
            windowSampleCount = 0
        }

        while remaining > 0 {
            let toRead = AVAudioFrameCount(
                min(remaining, AVAudioFramePosition(chunk.frameCapacity)))
            try reader.read(into: chunk, frameCount: toRead)
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            let available = Int(chunk.frameLength)
            var offset = 0
            while offset < available {
                let take = min(windowFrameCount - framesInWindow, available - offset)
                guard take > 0 else { break }
                // Max-abs across channels (peak) + combined sum-of-squares
                // (RMS) — the live-meter convention, deliberately NOT a
                // mono downmix first (see the type header).
                var slicePeak: Float = 0
                var sliceSumSquares: Double = 0
                for channel in 0..<channelCount {
                    let base = data[channel] + offset
                    var channelPeak: Float = 0
                    vDSP_maxmgv(base, 1, &channelPeak, vDSP_Length(take))
                    if channelPeak.isFinite { slicePeak = max(slicePeak, channelPeak) }
                    var channelSumSquares: Float = 0
                    vDSP_svesq(base, 1, &channelSumSquares, vDSP_Length(take))
                    if channelSumSquares.isFinite {
                        sliceSumSquares += Double(channelSumSquares)
                    }
                }
                windowPeak = max(windowPeak, slicePeak)
                windowSumSquares += sliceSumSquares
                windowSampleCount += take * channelCount
                framesInWindow += take
                offset += take
                if framesInWindow == windowFrameCount { flushWindow() }
            }
            remaining -= AVAudioFramePosition(available)
        }
        flushWindow()  // trailing partial window at EOF / the requested end

        return FileProfile(
            durationSeconds: fileDurationSeconds, sampleRateHz: rate,
            channelCount: channelCount, bitDepth: bitDepth, isFloat: isFloat,
            windows: windows)
    }

    /// Linear amplitude → dBFS, OMITTED (nil) for zero/non-finite input —
    /// the honest-absence convention (see the type header); never
    /// `MeterLevel`'s floor-at-−80 convention.
    private static func decibels(_ amplitude: Float) -> Double? {
        guard amplitude > 0, amplitude.isFinite else { return nil }
        let value = 20.0 * log10(Double(amplitude))
        return value.isFinite ? value : nil
    }
}
