import Foundation
import AVFoundation
import Testing
import DAWCore
@testable import DAWControl

// The real end-to-end leg of m23-n2b `clip.transcribe`: a genuine on-device
// WhisperKit transcription, driven entirely through the CONTROL WIRE (not
// `WhisperTranscriber` directly — that's `AIServicesTests/
// WhisperTranscriberTests.swift`'s job), proving the clip -> request mapping
// (`ProjectStore.transcriptionSource`, `Clip.sourceWindowSeconds(tempoMap:)`)
// is wired correctly end to end: a real clip at a NON-default tempo and a
// NON-zero start beat comes back with words on the RIGHT project beats.
//
// Deliberately NOT skipped when weights are absent (the m23-n2a fixture
// suite's own rule): a skip guard here would make the headline "control
// round-trip returns words on the right beats" gate a no-op that reports
// green having proven nothing. `.serialized` + a 5-minute limit budget the
// ~90 s one-time CoreML compile a fresh machine pays on its first call
// (`WhisperTranscriber`'s own doc comment).
@MainActor
@Suite("clip.transcribe — real fixture, control wire (m23-n2b)", .serialized, .timeLimit(.minutes(5)))
struct ClipTranscribeRealFixtureTests {

    private let fixturePhrase = "The quick brown fox jumps over the lazy dog"
    private let fixtureWords = ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"]

    /// Lowercased alphanumeric tokens — strips the leading space and
    /// trailing punctuation the recogniser attaches (`" dog."` -> `["dog"]`).
    /// Local copy of `AIServicesTests`' own helper — different test target,
    /// nothing importable across it.
    private func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// `say` with no voice argument writes 22050 Hz mono AIFF — a REAL audio
    /// file WhisperKit actually decodes (unlike `FakeMedia`'s stub duration,
    /// which never touches disk on the `clip.addAudio` path itself).
    private func makeSayFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-clip-transcribe-wire-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fox.aiff")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, fixturePhrase]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "ClipTranscribeRealFixtureTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "`say -o \(url.path)` failed with status \(process.terminationStatus)"
            ])
        }
        return url
    }

    /// The headline gate: a real clip, at 100 BPM (never 60 or 120 — a
    /// hardcoded /1.0 or a seconds-as-beats bug cannot pass by coincidence)
    /// and anchored at a NON-zero beat 4 (an anchor bug cannot hide behind a
    /// zero default), transcribes to the exact words with monotonic
    /// non-overlapping timings that land on the hand-derived project beats.
    @Test("a real clip's words land on the right project beats, through the control wire")
    func realClipTranscribesOnTheRightBeats() async throws {
        let audio = try makeSayFixture()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }

        let file = try AVAudioFile(forReading: audio)
        let fixtureDurationSeconds = Double(file.length) / file.fileFormat.sampleRate

        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: fixtureDurationSeconds,
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount)))
        let router = CommandRouter(store: store)

        // Non-default tempo, set BEFORE the clip is added — clip.addAudio
        // derives lengthBeats from the CURRENT tempo map.
        let setTempo = await router.handle(ControlRequest(
            id: "tempo", command: "transport.setTempo", params: ["bpm": .number(100)]))
        #expect(setTempo.ok)

        let anchorBeat = 4.0
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string(audio.path),
                     "atBeat": .number(anchorBeat)]))
        #expect(addClip.ok, "clip.addAudio failed: \(addClip.error ?? "?")")
        let clipID = try #require(addClip.result?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "x", command: "clip.transcribe",
            params: ["clipId": .string(clipID), "language": .string("en")]))
        #expect(response.ok, "clip.transcribe failed: \(response.error ?? "?")")

        let result = try #require(response.result)
        #expect(result["language"]?.stringValue == "en")
        #expect((result["modelVariantDirectoryName"]?.stringValue?.isEmpty ?? true) == false)
        #expect(result["rangeStartSeconds"]?.doubleValue == 0)
        #expect(result["anchorBeat"]?.doubleValue == anchorBeat)

        let text = try #require(result["text"]?.stringValue)
        #expect(normalizedTokens(text) == fixtureWords)
        // skipSpecialTokens must be on (m23-n2a) — verified again here since
        // this is a NEW code path (the wire), not a re-check of n2a's own test.
        #expect(!text.contains("<|"))

        let segments = try #require(result["segments"]?.arrayValue)
        #expect(!segments.isEmpty)
        var allWords: [JSONValue] = []
        for segment in segments {
            let words = try #require(segment["words"]?.arrayValue)
            allWords.append(contentsOf: words)
        }
        #expect(allWords.map { normalizedTokens($0["text"]?.stringValue ?? "") .joined() } == fixtureWords)

        // 100 BPM = 5/3 beats per second: hand-derived, independent of the
        // engine's own tempoMap.beat(from:elapsedSeconds:) call.
        let beatsPerSecond = 100.0 / 60.0
        for word in allWords {
            let startSeconds = try #require(word["startSeconds"]?.doubleValue)
            let endSeconds = try #require(word["endSeconds"]?.doubleValue)
            let startBeat = try #require(word["startBeat"]?.doubleValue)
            let endBeat = try #require(word["endBeat"]?.doubleValue)
            #expect(startSeconds <= endSeconds)
            #expect(startBeat <= endBeat)
            #expect(abs(startBeat - (anchorBeat + startSeconds * beatsPerSecond)) < 1e-6)
            #expect(abs(endBeat - (anchorBeat + endSeconds * beatsPerSecond)) < 1e-6)
        }
        for (a, b) in zip(allWords, allWords.dropFirst()) {
            let aEndSeconds = try #require(a["endSeconds"]?.doubleValue)
            let bStartSeconds = try #require(b["startSeconds"]?.doubleValue)
            let aEndBeat = try #require(a["endBeat"]?.doubleValue)
            let bStartBeat = try #require(b["startBeat"]?.doubleValue)
            #expect(aEndSeconds <= bStartSeconds + 1e-6)
            #expect(aEndBeat <= bStartBeat + 1e-6)
        }

        let firstStart = try #require(allWords.first?["startSeconds"]?.doubleValue)
        let lastEnd = try #require(allWords.last?["endSeconds"]?.doubleValue)
        #expect(firstStart >= 0)
        #expect(lastEnd <= fixtureDurationSeconds + 0.5)
    }
}
