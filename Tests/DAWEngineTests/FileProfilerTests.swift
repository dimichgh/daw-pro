import AVFAudio
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

// m25-z: windowed peak/RMS file profiling — the missing "what is the peak
// level between 53s and 54s of this WAV" surface. These tests exercise the
// REAL DSP (no fake engine, no wire) against synthesized files with KNOWN
// content, per the roadmap item's own bar: "a test that only checks
// 'returns some numbers' is worthless here".

// MARK: - Fixtures

private let sampleRate = 48_000.0

/// A steady cosine at `amplitude`, `frequency` Hz, for `seconds` — chosen so
/// an integer number of full periods fit in `seconds` at `sampleRate`
/// (`frequency * seconds` is an integer), which makes both the analytic
/// peak (exactly `amplitude`, hit at frame 0 where cos(0) = 1) and the
/// analytic RMS (amplitude / sqrt(2), the continuous-tone identity) land
/// almost exactly on the discretely-sampled result — an INDEPENDENTLY
/// computable positive control, not just "some plausible number".
private func cosineTone(amplitude: Float, frequency: Double, seconds: Double) -> [Float] {
    let count = Int((seconds * sampleRate).rounded())
    var out = [Float](repeating: 0, count: count)
    for n in 0..<count {
        out[n] = amplitude * Float(cos(2.0 * .pi * frequency * Double(n) / sampleRate))
    }
    return out
}

private func silence(seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int((seconds * sampleRate).rounded()))
}

/// Writes MONO samples as a 32-bit float WAV (bit-exact read-back — the
/// ReferenceAnalyzerTests recipe).
private func writeMonoFloat32Wav(_ samples: [Float]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("file-profiler-\(UUID().uuidString.prefix(8)).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                     channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(samples.count)) else {
        throw AudioContentAnalyzerError.unreadable("fixture buffer allocation failed")
    }
    samples.withUnsafeBufferPointer {
        buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
    return url
}

/// Writes a STEREO 32-bit float WAV from two independent channel arrays
/// (the channel-discrimination fixture — L and R deliberately differ).
private func writeStereoFloat32Wav(left: [Float], right: [Float]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("file-profiler-stereo-\(UUID().uuidString.prefix(8)).wav")
    let frames = min(left.count, right.count)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                     channels: 2, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(frames)) else {
        throw AudioContentAnalyzerError.unreadable("fixture buffer allocation failed")
    }
    left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }
    right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: frames) }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
    return url
}

/// Writes MONO samples as a 16-bit INTEGER PCM WAV — deliberately a
/// DIFFERENT on-disk shape from the float32 fixtures above, so the header
/// block's bitDepth/isFloat readback has something real to distinguish.
private func writeMonoInt16Wav(_ samples: [Float]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("file-profiler-int16-\(UUID().uuidString.prefix(8)).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    guard let engineFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                           channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: engineFormat,
                                        frameCapacity: AVAudioFrameCount(samples.count)) else {
        throw AudioContentAnalyzerError.unreadable("fixture buffer allocation failed")
    }
    samples.withUnsafeBufferPointer {
        buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    // AVAudioFile with int16 `settings` but a float32 `commonFormat` writer
    // converts on write (the standard AVFoundation recipe for producing a
    // non-float file from float32 in-memory samples).
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    return url
}

private func dbFromLinear(_ amplitude: Double) -> Double { 20.0 * log10(amplitude) }

@Suite("FileProfiler — windowed peak/RMS (m25-z)")
struct FileProfilerTests {

    // MARK: - A: boundary + peak-vs-RMS discrimination (the positive control)

    @Test("two 1.0 s windows at different amplitudes read the ANALYTIC peak and RMS independently — a boundary or peak/RMS-swap bug would miss both")
    func boundaryAndAmplitudeDiscrimination() throws {
        var samples = cosineTone(amplitude: 0.5, frequency: 1_000, seconds: 1.0)
        samples += cosineTone(amplitude: 0.05, frequency: 1_000, seconds: 1.0)
        let url = try writeMonoFloat32Wav(samples)

        let profile = try FileProfiler.profile(fileAt: url, windowSeconds: 1.0)
        #expect(profile.windows.count == 2)

        let w0 = profile.windows[0]
        #expect(w0.startSeconds == 0)
        #expect(abs(w0.durationSeconds - 1.0) < 1e-9)
        let peak0 = try #require(w0.peakDb)
        let rms0 = try #require(w0.rmsDb)
        #expect(abs(peak0 - dbFromLinear(0.5)) < 0.01, "peak0 = \(peak0), expected ~\(dbFromLinear(0.5))")
        #expect(abs(rms0 - dbFromLinear(0.5 / 2.0.squareRoot())) < 0.05,
                "rms0 = \(rms0), expected ~\(dbFromLinear(0.5 / 2.0.squareRoot()))")
        // Peak and RMS must differ (~3 dB for a sine) — catches a swap.
        #expect(peak0 - rms0 > 2.5 && peak0 - rms0 < 3.5)

        let w1 = profile.windows[1]
        #expect(abs(w1.startSeconds - 1.0) < 1e-9)
        #expect(abs(w1.durationSeconds - 1.0) < 1e-9)
        let peak1 = try #require(w1.peakDb)
        let rms1 = try #require(w1.rmsDb)
        #expect(abs(peak1 - dbFromLinear(0.05)) < 0.01, "peak1 = \(peak1), expected ~\(dbFromLinear(0.05))")
        #expect(abs(rms1 - dbFromLinear(0.05 / 2.0.squareRoot())) < 0.05,
                "rms1 = \(rms1), expected ~\(dbFromLinear(0.05 / 2.0.squareRoot()))")
        // The two windows must be clearly distinguishable (~20 dB apart) —
        // this is the m25-z evidence shape: a decayed tail must NOT read
        // as a truncation, and a truncation must NOT read as a decayed tail.
        #expect(peak0 - peak1 > 15)
    }

    // MARK: - B: channel-combination discrimination

    @Test("stereo peak/RMS combine channels the LIVE-METER way (max-abs peak, combined RMS) — NOT a mono downmix, which would under-report")
    func channelCombinationDiscrimination() throws {
        let left = cosineTone(amplitude: 0.8, frequency: 1_000, seconds: 1.0)
        let right = silence(seconds: 1.0)  // exactly zero — the R channel carries nothing
        let url = try writeStereoFloat32Wav(left: left, right: right)

        let profile = try FileProfiler.profile(fileAt: url, windowSeconds: 1.0)
        #expect(profile.channelCount == 2)
        #expect(profile.windows.count == 1)
        let window = profile.windows[0]
        let peak = try #require(window.peakDb)
        let rms = try #require(window.rmsDb)

        // Max-abs across channels: peak == L's own peak, ~-1.94 dB.
        #expect(abs(peak - dbFromLinear(0.8)) < 0.01, "peak = \(peak), expected ~\(dbFromLinear(0.8))")
        // A mono downmix (L+R)/2 would read amplitude ~0.4 -> ~-7.96 dB —
        // 6 dB lower. Assert we are nowhere near that wrong answer.
        #expect(peak > dbFromLinear(0.7), "peak looks mono-downmixed (under-reported): \(peak)")

        // Combined-channel RMS (the live-meter convention, MeterFrame's own
        // formula): mean of squares across BOTH channels' samples together —
        // sum-of-squares = (A^2/2)*N [cosine] + 0 [silent R], divided by the
        // TOTAL sample count 2N (both channels): sqrt((A^2/2)/2) = A/2 = 0.4.
        // Two OTHER plausible-but-wrong conventions this discriminates against:
        // a mono downmix first (cosine at A/2, RMS (A/2)/sqrt(2) = 0.283,
        // -10.97 dB) and a combined sum-of-squares divided by N instead of
        // 2N (A/sqrt(2) = 0.566, -4.95 dB) — both would fail this assertion.
        let expectedRms = dbFromLinear(0.8 / 2.0)
        #expect(abs(rms - expectedRms) < 0.05, "rms = \(rms), expected ~\(expectedRms)")
        let monoDownmixWrongAnswer = dbFromLinear(0.4 / 2.0.squareRoot())
        #expect(abs(rms - monoDownmixWrongAnswer) > 1,
                "rms (\(rms)) looks mono-downmixed — should be \(expectedRms)")
    }

    // MARK: - C: honest absence (digital silence omits, never zero)

    @Test("a digitally-silent window OMITS peakDb/rmsDb — never 0 — while its non-silent neighbor reports real numbers")
    func silentWindowOmitsNeverZero() throws {
        var samples = cosineTone(amplitude: 0.3, frequency: 1_000, seconds: 1.0)
        samples += silence(seconds: 1.0)
        let url = try writeMonoFloat32Wav(samples)

        let profile = try FileProfiler.profile(fileAt: url, windowSeconds: 1.0)
        #expect(profile.windows.count == 2)
        #expect(profile.windows[0].peakDb != nil)
        #expect(profile.windows[0].rmsDb != nil)
        #expect(profile.windows[1].peakDb == nil, "silent window must OMIT peakDb, not read 0")
        #expect(profile.windows[1].rmsDb == nil, "silent window must OMIT rmsDb, not read 0")
    }

    // MARK: - D: window count / fencepost — a length NOT a multiple of windowSeconds

    @Test("a file whose length is NOT a multiple of windowSeconds emits a truncated FINAL window with its own shorter durationSeconds")
    func trailingPartialWindow() throws {
        // 2.3 s at windowSeconds 1.0 -> three windows: [0,1), [1,2), [2,2.3).
        let samples = cosineTone(amplitude: 0.4, frequency: 500, seconds: 2.3)
        let url = try writeMonoFloat32Wav(samples)

        let profile = try FileProfiler.profile(fileAt: url, windowSeconds: 1.0)
        #expect(profile.windows.count == 3, "expected 3 windows (fencepost check), got \(profile.windows.count)")
        #expect(abs(profile.windows[0].durationSeconds - 1.0) < 1e-9)
        #expect(abs(profile.windows[1].durationSeconds - 1.0) < 1e-9)
        #expect(abs(profile.windows[2].durationSeconds - 0.3) < 1e-6,
                "trailing window should read ~0.3 s, got \(profile.windows[2].durationSeconds)")
        #expect(abs(profile.windows[2].startSeconds - 2.0) < 1e-9)
        // The trailing window still carries real content (not silence).
        #expect(profile.windows[2].peakDb != nil)
    }

    // MARK: - E: fromSeconds/durationSeconds sub-range — ABSOLUTE window positions

    @Test("fromSeconds/durationSeconds profile only the requested sub-range, and startSeconds stays an ABSOLUTE file position")
    func subRangeAbsolutePositions() throws {
        var samples = cosineTone(amplitude: 0.6, frequency: 1_000, seconds: 1.0)   // [0, 1)
        samples += cosineTone(amplitude: 0.2, frequency: 1_000, seconds: 1.0)      // [1, 2)
        samples += cosineTone(amplitude: 0.9, frequency: 1_000, seconds: 1.0)      // [2, 3)
        let url = try writeMonoFloat32Wav(samples)

        let profile = try FileProfiler.profile(
            fileAt: url, windowSeconds: 0.5, fromSeconds: 1.5, durationSeconds: 1.5)
        // fromSeconds 1.5 + durationSeconds 1.5 = [1.5, 3.0) -> three 0.5 s windows:
        // [1.5,2), [2,2.5), [2.5,3).
        #expect(profile.windows.count == 3)
        #expect(abs(profile.windows[0].startSeconds - 1.5) < 1e-9)
        #expect(abs(profile.windows[1].startSeconds - 2.0) < 1e-9)
        #expect(abs(profile.windows[2].startSeconds - 2.5) < 1e-9)
        // Header duration is the WHOLE file (3.0 s), independent of the sub-range.
        #expect(abs(profile.durationSeconds - 3.0) < 1e-9)
        // The window straddling the 1->2 amplitude change (0.2) and the
        // window fully inside the 2->3 segment (0.9) must read differently —
        // proves the sub-range is actually reading the requested slice, not
        // e.g. silently re-basing to the start of the file.
        let secondWindowPeak = try #require(profile.windows[1].peakDb)
        #expect(abs(secondWindowPeak - dbFromLinear(0.9)) < 0.01)
    }

    // MARK: - F: header block — the ffprobe readback

    @Test("header block reports the on-disk bit depth/float-ness and duration for a 16-bit integer PCM file")
    func headerBlockInt16() throws {
        let samples = cosineTone(amplitude: 0.5, frequency: 1_000, seconds: 1.5)
        let url = try writeMonoInt16Wav(samples)

        let profile = try FileProfiler.profile(fileAt: url, windowSeconds: 1.0)
        #expect(profile.channelCount == 1)
        #expect(profile.sampleRateHz == sampleRate)
        #expect(abs(profile.durationSeconds - 1.5) < 1e-6)
        #expect(profile.bitDepth == 16)
        #expect(profile.isFloat == false)
    }

    @Test("header block reports float32 for a float WAV")
    func headerBlockFloat32() throws {
        let samples = cosineTone(amplitude: 0.5, frequency: 1_000, seconds: 1.0)
        let url = try writeMonoFloat32Wav(samples)

        let profile = try FileProfiler.profile(fileAt: url, windowSeconds: 1.0)
        #expect(profile.bitDepth == 32)
        #expect(profile.isFloat == true)
    }

    // MARK: - G: chunk-size invariance (the ReferenceAnalyzer precedent)

    @Test("chunk-size invariance: a 512-frame chunk and the 64 k default produce the SAME windows")
    func chunkSizeInvariance() throws {
        var samples = cosineTone(amplitude: 0.7, frequency: 1_000, seconds: 1.0)
        samples += silence(seconds: 0.5)
        samples += cosineTone(amplitude: 0.15, frequency: 1_000, seconds: 0.8)
        let url = try writeMonoFloat32Wav(samples)

        let small = try FileProfiler.profile(
            fileAt: url, windowSeconds: 0.25, chunkFrames: 512)
        let large = try FileProfiler.profile(
            fileAt: url, windowSeconds: 0.25, chunkFrames: FileProfiler.defaultChunkFrames)
        #expect(small.windows.count == large.windows.count)
        for (a, b) in zip(small.windows, large.windows) {
            #expect(a.startSeconds == b.startSeconds)
            #expect(abs(a.durationSeconds - b.durationSeconds) < 1e-12)
            // peakDb is bit-exact across chunkings: vDSP_maxmgv + a running
            // max() is order-independent regardless of how many pieces a
            // window is split into. rmsDb is NOT bit-exact (unlike
            // ReferenceAnalyzer's Loudness.Stream, which accumulates
            // per-sample IIR state): a smaller chunkFrames forces more,
            // smaller vDSP_svesq(Float) sub-reductions per window, summed in
            // Double between them — mathematically the same total, but
            // Float32 summation is not associative, so the last few bits
            // differ. The tolerance (1e-4 dB) is ~1000x tighter than
            // anything audible or UI-relevant, so this pins "agrees",
            // not "returns something".
            #expect(a.peakDb == b.peakDb)
            let (rmsA, rmsB) = (a.rmsDb, b.rmsDb)
            #expect((rmsA == nil) == (rmsB == nil))
            if let rmsA, let rmsB {
                #expect(abs(rmsA - rmsB) < 1e-4, "rmsA=\(rmsA) rmsB=\(rmsB)")
            }
        }
    }

    // MARK: - H: validation / error paths

    @Test("windowSeconds <= 0 throws before touching the file")
    func rejectsNonPositiveWindow() throws {
        let url = try writeMonoFloat32Wav(cosineTone(amplitude: 0.3, frequency: 440, seconds: 1.0))
        #expect(throws: (any Error).self) {
            _ = try FileProfiler.profile(fileAt: url, windowSeconds: 0)
        }
    }

    @Test("durationSeconds <= 0 throws")
    func rejectsNonPositiveDuration() throws {
        let url = try writeMonoFloat32Wav(cosineTone(amplitude: 0.3, frequency: 440, seconds: 1.0))
        #expect(throws: (any Error).self) {
            _ = try FileProfiler.profile(fileAt: url, windowSeconds: 0.5, durationSeconds: 0)
        }
    }

    @Test("fromSeconds past EOF throws")
    func rejectsFromSecondsPastEOF() throws {
        let url = try writeMonoFloat32Wav(cosineTone(amplitude: 0.3, frequency: 440, seconds: 1.0))
        #expect(throws: (any Error).self) {
            _ = try FileProfiler.profile(fileAt: url, windowSeconds: 0.5, fromSeconds: 5.0)
        }
    }

    @Test("an unreadable/missing file throws — never a fabricated profile")
    func rejectsMissingFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")
        #expect(throws: (any Error).self) {
            _ = try FileProfiler.profile(fileAt: url, windowSeconds: 1.0)
        }
    }
}
