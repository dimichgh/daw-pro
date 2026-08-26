import DAWCore
import Foundation
@preconcurrency import AVFAudio

/// m30-d — "the spectrogram as a DIAGNOSTIC, never a gate."
///
/// THE FINDING THIS IS BUILT ON (2026-08-23, docs/dogfood/2026-08-23-session-1.md):
/// a spectrogram of a real render was read by eye as "bass-heavy"; direct
/// measurement refuted that outright (below-60 Hz at -39.6 dB against -27.6 dB
/// full-band, DC offset 0.000039). The picture was misleading for two
/// compounding reasons: `fscale=log` gives the bottom octaves most of the
/// vertical area of the image, and an operator-chosen `gain` amplified the
/// misread on top of that.
///
/// The conclusion, enforced structurally here: **numbers stay the gate. This
/// type produces a picture for a human, and only when a numeric assertion
/// has already failed.** Nothing in this file inspects pixel content, and
/// nothing here returns a value a caller could use to decide pass/fail —
/// `emit` is `Void`. Callers invoke it from inside their own failure branch,
/// after a real numeric check has already determined failure; it never
/// participates in that determination.
///
/// `nonisolated` throughout (no shared mutable state) so it is reachable
/// from both `@MainActor` suites and the free suites the 330-suite
/// `@MainActor @Suite` cap pushes new work toward.
enum SpectrogramDiagnostic {

    /// Every render parameter that shapes what the image LOOKS like, pinned
    /// in one place. An unstated `fscale`/`gain` is not evidence — that is
    /// exactly how the finding above happened. These are printed into the
    /// sidecar file next to every artifact and are never varied per call.
    enum Parameters {
        static let size = "1024x512"
        static let windowFunction = "hann"
        /// Frequency-axis scale. `log` — matches what produced the original
        /// misread, so the diagnostic reproduces the SAME distortion a human
        /// engineer historically hit here, rather than a friendlier one that
        /// would never train anyone to distrust the picture.
        static let frequencyScale = "log"
        /// Deliberately 1, not the 3 that amplified the original misread.
        static let gain = "1"
        static let colorMap = "intensity"
        static let legend = true

        static var ffmpegFilter: String {
            "showspectrumpic=s=\(size):legend=\(legend ? 1 : 0):" +
            "fscale=\(frequencyScale):gain=\(gain):win_func=\(windowFunction):color=\(colorMap)"
        }
    }

    /// Where artifacts land: under `.build/`, which `.gitignore` already
    /// excludes wholesale (verified: `git check-ignore -v .build/...`) —
    /// never the repo, never `/tmp`. Derived from this file's own path so it
    /// is correct regardless of the test runner's working directory.
    static func artifactsDirectory() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // SpectrogramDiagnostic.swift -> Support -> DAWEngineTests -> Tests -> repo root
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(".build/test-artifacts/spectrograms", isDirectory: true)
    }

    /// Locates a usable `ffmpeg`. Returns `nil` (never throws) if none is
    /// found, so callers can degrade gracefully — see `emit`.
    static func locateFFmpeg() -> String? {
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Emit a spectrogram artifact for a FAILED audio assertion. Call this
    /// ONLY from inside the branch where you have already determined the
    /// real assertion failed — never unconditionally, and never on a
    /// passing path. This function's return is `Void`: it cannot become
    /// part of a test's pass/fail decision.
    ///
    /// - Parameters:
    ///   - testName: identifies the artifact on disk; sanitized for the filesystem.
    ///   - reason: the real failure — the numbers that actually gate the test.
    ///   - audio: the render under test.
    ///   - reference: an optional expected/reference render. When present, a
    ///     DIFFERENCE spectrogram is produced instead of an absolute one —
    ///     "what changed" reads far more reliably than "what is."
    ///   - ffmpegPath: overridable for tests exercising the ffmpeg-absent path.
    static func emit(testName: String, reason: String, audio: RenderedAudio,
                     reference: RenderedAudio? = nil,
                     ffmpegPath: String? = SpectrogramDiagnostic.locateFFmpeg()) {
        guard let ffmpegPath else {
            print("[spectrogram-diagnostic] SKIPPED (ffmpeg not found) — the real failure stands " +
                  "on its own: \(reason)")
            return
        }
        do {
            let dir = artifactsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let base = "\(sanitize(testName))-\(stamp)"

            let kind: String
            let sourceForSpectrum: URL
            if let reference {
                let diff = difference(audio, reference)
                let diffURL = dir.appendingPathComponent("\(base)-diff.wav")
                try writeWAV(diff, to: diffURL)
                sourceForSpectrum = diffURL
                kind = "difference"
            } else {
                let absoluteURL = dir.appendingPathComponent("\(base)-source.wav")
                try writeWAV(audio, to: absoluteURL)
                sourceForSpectrum = absoluteURL
                kind = "absolute"
            }

            let pngURL = dir.appendingPathComponent("\(base)-\(kind).png")
            try runFFmpeg(ffmpegPath: ffmpegPath, input: sourceForSpectrum, output: pngURL)

            let durationSeconds = Double(audio.frameCount) / max(audio.sampleRate, 1)
            let sidecarURL = dir.appendingPathComponent("\(base).txt")
            let sidecar = """
            spectrogram diagnostic — m30-d
            test: \(testName)
            failure reason (THIS is the gate, not the image below): \(reason)
            kind: \(kind)\(reference != nil ? " (reference-relative — reads as \"what changed\")" : " (absolute)")
            spectrum source wav: \(sourceForSpectrum.path)
            image: \(pngURL.path)
            source sampleRate: \(audio.sampleRate) Hz
            source duration: \(durationSeconds) s
            source channels: \(audio.channelData.count)
            ffmpeg: \(ffmpegPath)
            ffmpeg filter (PINNED — do not read this image without these): \(Parameters.ffmpegFilter)
            size=\(Parameters.size) window=\(Parameters.windowFunction) fscale=\(Parameters.frequencyScale) \
            gain=\(Parameters.gain) color=\(Parameters.colorMap)

            NOTE: numbers are the gate for this test, not this picture. A prior read of an
            unpinned spectrogram (fscale=log, gain=3) was read as "bass-heavy" and was WRONG —
            refuted by direct RMS measurement. See docs/dogfood/2026-08-23-session-1.md.
            """
            try sidecar.write(to: sidecarURL, atomically: true, encoding: .utf8)
            print("[spectrogram-diagnostic] wrote \(pngURL.path) — parameters in \(sidecarURL.path)")
        } catch {
            print("[spectrogram-diagnostic] FAILED to produce an artifact (\(error)) — " +
                  "the real failure stands on its own: \(reason)")
        }
    }

    // MARK: - Internals

    private static func sanitize(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    /// Channel-wise `reference - audio`, min length/channel-count. A
    /// difference render has no log-scale area bias against either input
    /// alone, because both sides carry the same distortion equally.
    private static func difference(_ audio: RenderedAudio, _ reference: RenderedAudio) -> RenderedAudio {
        let channelCount = min(audio.channelData.count, reference.channelData.count)
        var out: [[Float]] = []
        out.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let a = audio.channelData[channel]
            let b = reference.channelData[channel]
            let frameCount = min(a.count, b.count)
            var samples = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                samples[frame] = b[frame] - a[frame]
            }
            out.append(samples)
        }
        return RenderedAudio(sampleRate: audio.sampleRate, channelData: out)
    }

    private static func writeWAV(_ audio: RenderedAudio, to url: URL) throws {
        let channelCount = max(audio.channelData.count, 1)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: audio.sampleRate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: false) else {
            throw SpectrogramDiagnosticError.bufferAllocationFailed
        }
        let frameCount = audio.frameCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(max(frameCount, 1))),
              let channels = buffer.floatChannelData else {
            throw SpectrogramDiagnosticError.bufferAllocationFailed
        }
        for channel in 0..<channelCount {
            let samples = channel < audio.channelData.count ? audio.channelData[channel] : []
            for frame in 0..<frameCount {
                channels[channel][frame] = frame < samples.count ? samples[frame] : 0
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        try file.write(from: buffer)
    }

    private static func runFFmpeg(ffmpegPath: String, input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-hide_banner", "-y",
            "-i", input.path,
            "-lavfi", Parameters.ffmpegFilter,
            output.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Drain stderr BEFORE waiting on exit: ffmpeg can write more than a
        // pipe's buffer (~64 KiB) to stderr, and reading only after
        // `waitUntilExit()` deadlocks in that case — ffmpeg blocks on a full
        // pipe, we block on its exit. A diagnostic that only ever runs on a
        // FAILED test must never turn that red into a hung suite, especially
        // on a machine with no `timeout(1)` to rescue it.
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8) ?? "<no stderr>"
            throw SpectrogramDiagnosticError.ffmpegFailed(status: process.terminationStatus, stderr: errText)
        }
    }
}

enum SpectrogramDiagnosticError: Error, CustomStringConvertible {
    case bufferAllocationFailed
    case ffmpegFailed(status: Int32, stderr: String)

    var description: String {
        switch self {
        case .bufferAllocationFailed:
            return "buffer allocation failed"
        case .ffmpegFailed(let status, let stderr):
            return "ffmpeg exited \(status): \(stderr.prefix(500))"
        }
    }
}
