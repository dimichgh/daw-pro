import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-ap-3 — `ClipPitchAnalyzer`, the bridge from m23-ap-2b's
/// `PitchTracker` seam onto the DAWCore wire types
/// (`PitchDetectionResult`/`ClipPitchFrame`). Runs REAL SwiftF0 inference
/// (no fake/mock tracker — the fake-engine coverage for the wire/store
/// layers lives in `ClipDetectPitchCommandTests`, DAWControlTests).
///
/// ⚠️ Reuses `PitchTrackerAccuracyTests.Fixture` (same test target,
/// `internal` by default) for tone generation rather than a second copy —
/// the harmonic-not-sine lesson from that suite applies here too.
@Suite("Clip pitch analyzer — DAWEngine bridge (m23-ap-3)", .serialized)
struct ClipPitchAnalyzerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-clip-pitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes MONO samples as a Float32 WAV (the `AudioContentAnalyzerTests`
    /// recipe).
    private func writeWAV(_ samples: [Float], to url: URL, sampleRate: Double) throws {
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
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for (i, sample) in samples.enumerated() { channels[0][i] = sample }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    /// A voiced harmonic tone followed by true digital silence — gives
    /// every test in this file BOTH a voiced and an unvoiced frame from one
    /// fixture, which is the shape the honest-absence check needs (a fixture
    /// that happens to be all-voiced would pass that check trivially).
    private func voicedThenSilentFixture(sampleRate: Double) -> [Float] {
        let voiced = PitchTrackerAccuracyTests.Fixture.tone(
            seconds: 1.0, amplitude: 0.5, partials: 12, sampleRate: sampleRate) { _ in 220.0 }
        let silence = PitchTrackerAccuracyTests.Fixture.silence(seconds: 0.5, sampleRate: sampleRate)
        return voiced + silence
    }

    @Test("honest absence survives the JSON boundary: an unvoiced frame OMITS frequencyHz and CARRIES absence; no frame anywhere has frequencyHz <= 0")
    func honestAbsenceAcrossJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.wav")
        let rate = 48_000.0
        try writeWAV(voicedThenSilentFixture(sampleRate: rate), to: url, sampleRate: rate)

        let result = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: 1.5,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)

        // The fixture must actually exercise BOTH branches, or this test
        // would pass trivially without ever reaching the honest-absence
        // code path.
        let voicedFrames = result.frames.filter { $0.frequencyHz != nil }
        let unvoicedFrames = result.frames.filter { $0.frequencyHz == nil }
        #expect(!voicedFrames.isEmpty, "fixture must produce at least one voiced frame")
        #expect(!unvoicedFrames.isEmpty, "fixture must produce at least one unvoiced frame (the silence tail)")

        // Every unvoiced frame carries a reason; every voiced frame carries none.
        for frame in result.frames {
            #expect((frame.frequencyHz == nil) == (frame.absence != nil))
            if let hz = frame.frequencyHz {
                #expect(hz > 0, "no frame may carry a zero or negative frequency")
            }
        }

        // The JSON boundary itself: encode, then inspect the RAW structure
        // (not a round-trip through Decodable, which could silently accept
        // a `"frequencyHz": null` a careless encoder might have written).
        let data = try JSONEncoder().encode(result)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let framesJSON = try #require(parsed["frames"] as? [[String: Any]])
        #expect(framesJSON.count == result.frames.count)

        let unvoicedIndex = try #require(result.frames.firstIndex { $0.frequencyHz == nil })
        let unvoicedJSON = framesJSON[unvoicedIndex]
        #expect(!unvoicedJSON.keys.contains("frequencyHz"),
                "an unvoiced frame must OMIT frequencyHz entirely — never null, never 0")
        #expect(unvoicedJSON.keys.contains("absence"),
                "an unvoiced frame must carry its absence reason")
        #expect(unvoicedJSON["confidence"] != nil,
                "confidence is reported for EVERY frame, including unvoiced ones")

        let voicedIndex = try #require(result.frames.firstIndex { $0.frequencyHz != nil })
        let voicedJSON = framesJSON[voicedIndex]
        #expect(voicedJSON.keys.contains("frequencyHz"))
        #expect(!voicedJSON.keys.contains("absence"),
                "a voiced frame must OMIT absence — nil, not a redundant reason")
    }

    @Test("output times are SOURCE-FILE-absolute: fromSeconds is added back, not left buffer-relative")
    func sourceFileAbsoluteTimes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.wav")
        let rate = 48_000.0
        // 3 s of tone so a 2 s-in request still has material to analyze.
        let samples = PitchTrackerAccuracyTests.Fixture.tone(
            seconds: 3.0, amplitude: 0.5, partials: 12, sampleRate: rate) { _ in 220.0 }
        try writeWAV(samples, to: url, sampleRate: rate)

        let fromSeconds = 2.0
        let result = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: fromSeconds, durationSeconds: 0.5,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)

        #expect(result.windowStartSeconds == fromSeconds)
        let firstFrameTime = try #require(result.frames.first?.timeSeconds)
        // Buffer-relative would read ~0; source-file-absolute reads ~2.0.
        #expect(firstFrameTime >= fromSeconds)
        #expect(firstFrameTime < fromSeconds + 0.1)
        // Monotonically increasing, all >= fromSeconds.
        for frame in result.frames {
            #expect(frame.timeSeconds >= fromSeconds)
        }
    }

    @Test("durationSeconds past the file's end is CLAMPED, not rejected — windowDurationSeconds reports what was actually read")
    func clampsAtFileEnd() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.wav")
        let rate = 48_000.0
        let samples = PitchTrackerAccuracyTests.Fixture.tone(
            seconds: 1.0, amplitude: 0.5, partials: 12, sampleRate: rate) { _ in 220.0 }
        try writeWAV(samples, to: url, sampleRate: rate)

        let result = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: 100.0,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)

        #expect(result.windowDurationSeconds < 100.0)
        #expect(abs(result.windowDurationSeconds - 1.0) < 0.05)
    }

    @Test("minFrequencyHz/maxFrequencyHz echo the tracker's OWN detectableRange, not a hardcoded literal")
    func echoesDetectableRange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.wav")
        let rate = 48_000.0
        let samples = PitchTrackerAccuracyTests.Fixture.tone(
            seconds: 0.5, amplitude: 0.5, partials: 12, sampleRate: rate) { _ in 220.0 }
        try writeWAV(samples, to: url, sampleRate: rate)

        let result = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: 0.5,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)

        let tracker = try SwiftF0PitchTracker()
        #expect(result.minFrequencyHz == tracker.detectableRange.lowerBound)
        #expect(result.maxFrequencyHz == tracker.detectableRange.upperBound)
        #expect(result.frameRateHz == tracker.frameRate)
        #expect(result.analysisSampleRateHz == tracker.analysisSampleRate)
        #expect(result.sourceSampleRateHz == rate)
    }

    @Test("confidenceThreshold/silenceFloorDbfs actually used are echoed back verbatim")
    func echoesTuningKnobsUsed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.wav")
        let rate = 48_000.0
        let samples = PitchTrackerAccuracyTests.Fixture.tone(
            seconds: 0.5, amplitude: 0.5, partials: 12, sampleRate: rate) { _ in 220.0 }
        try writeWAV(samples, to: url, sampleRate: rate)

        let result = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: 0.5,
            confidenceThreshold: 0.42, silenceFloorDbfs: -60)

        #expect(result.confidenceThreshold == 0.42)
        #expect(result.silenceFloorDbfs == -60)
    }
}

/// m23-ap-3 — `DAWCore.PitchDetectionDefaults` is a HAND-DUPLICATED copy of
/// `PitchAnalysisOptions`'s two default constants (DAWCore cannot import
/// DAWEngine, so it cannot reference the originals directly). This suite is
/// the lockstep guard `PitchDetectionDefaults`'s own doc comment promises —
/// a value edited on one side without the other fails HERE, not silently in
/// production.
@Suite("Pitch detection defaults stay in lockstep across the DAWCore/DAWEngine boundary (m23-ap-3)")
struct PitchDetectionDefaultsMatchTrackerTests {
    @Test("DAWCore.PitchDetectionDefaults mirrors DAWEngine.PitchAnalysisOptions exactly")
    func defaultsMatch() {
        #expect(PitchDetectionDefaults.defaultConfidenceThreshold
                == PitchAnalysisOptions.defaultConfidenceThreshold)
        #expect(PitchDetectionDefaults.defaultSilenceFloorDbfs
                == PitchAnalysisOptions.defaultSilenceFloorDbfs)
    }
}
