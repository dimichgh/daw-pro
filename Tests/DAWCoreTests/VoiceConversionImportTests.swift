import Foundation
import Testing
@testable import DAWCore

/// `importConvertedVoice` / `voiceConversionSource` coverage (m10-p-4) — the
/// `GenerationImportTests` sibling for the voice-conversion pipeline glue.
/// `CommandRouter` (DAWControl) is the only caller in production — these
/// tests exercise the store methods directly (the DAWCore layer must stay
/// AI-free, so there is no client/sidecar involved here at all, just plain
/// local files).
@MainActor
@Suite("Voice-conversion import (m10-p-4)")
struct VoiceConversionImportTests {
    /// Writes a minimal valid PCM16 mono WAV to a fresh temp file (stands in
    /// for the RVC facade's `outputPath` — a real header keeps the fixture
    /// honest, though `FakeMedia` never actually reads it).
    private func writeTinyWAV(name: String = "converted.wav") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-import-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var data = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        data.append(Data("RIFF".utf8)); data.append(le32(36 + 16)); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); data.append(le32(16)); data.append(le16(1)); data.append(le16(1))
        data.append(le32(48000)); data.append(le32(96000)); data.append(le16(2)); data.append(le16(16))
        data.append(Data("data".utf8)); data.append(le32(16))
        data.append(Data(repeating: 0, count: 16))
        try data.write(to: url)
        return url
    }

    /// A store with a temp imports directory (hermetic — never litters the
    /// real profile) and a deterministic media stand-in.
    private func makeStore(mediaDurationSeconds: Double = 2.0) -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: mediaDurationSeconds, sampleRate: 48000, channelCount: 2))
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-import-dest-\(UUID().uuidString)")
        return store
    }

    // MARK: - importConvertedVoice: happy path

    @Test("import creates an AI-flagged audio track + clip, tempo untouched")
    func happyPathCreatesTrackAndClip() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(mediaDurationSeconds: 2.5)
        try store.setTempo(120)
        let tempoBefore = store.transport.tempoBPM

        let (trackID, clipID) = try store.importConvertedVoice(
            fileURL: wav, trackName: "Voice: base", atBeat: 0)

        // No tempo adoption exists for this pipeline at all (m10-p-4 design
        // point 3) — unlike importGeneration, there is no bpm meta to adopt.
        #expect(store.transport.tempoBPM == tempoBefore)

        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.kind == .audio)
        #expect(track.isAIGenerated)
        #expect(track.name == "Voice: base")
        let clip = try #require(track.clips.first { $0.id == clipID })
        #expect(clip.isAIGenerated)
        #expect(clip.startBeat == 0)
        #expect(abs(clip.lengthBeats - 2.5 * 120.0 / 60.0) < 1e-9)

        // The clip references a STABLE copy in the imports dir (the
        // recording-take model), not the volatile facade output path.
        let clipURL = try #require(clip.audioFileURL)
        #expect(clipURL.path.hasPrefix(store.generationImportsDirectory.path))
        #expect(clipURL != wav)
        #expect(FileManager.default.fileExists(atPath: clipURL.path))
    }

    @Test("atBeat places the clip; negative atBeat clamps to 0")
    func atBeatPlacement() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(mediaDurationSeconds: 1.0)
        try store.setTempo(120)

        let (trackID, _) = try store.importConvertedVoice(
            fileURL: wav, trackName: "Voice: my-voice", atBeat: 8)
        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.clips.first?.startBeat == 8)

        let wav2 = try writeTinyWAV(name: "converted2.wav")
        let (trackID2, _) = try store.importConvertedVoice(
            fileURL: wav2, trackName: "Voice: my-voice", atBeat: -5)
        let track2 = try #require(store.tracks.first { $0.id == trackID2 })
        #expect(track2.clips.first?.startBeat == 0)
    }

    @Test("an empty trackName lands verbatim — the caller resolves the default, not this method")
    func emptyTrackNameNotSubstituted() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore()
        let (trackID, _) = try store.importConvertedVoice(fileURL: wav, trackName: "", atBeat: 0)
        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.name.isEmpty)
    }

    // MARK: - importConvertedVoice: undo

    @Test("undo removes the imported track in one step, tempo untouched")
    func undoRemovesTrack() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore()
        try store.setTempo(120)

        _ = try store.importConvertedVoice(fileURL: wav, trackName: "Voice: base", atBeat: 0)
        #expect(store.tracks.count == 1)

        let label = try store.undo()
        #expect(label == "Import Converted Voice")
        #expect(store.tracks.isEmpty)
        #expect(store.transport.tempoBPM == 120)
    }

    // MARK: - importConvertedVoice: rejections

    @Test("missing output file → actionable missing-file error")
    func rejectsMissingFile() async throws {
        let store = makeStore()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).wav")
        do {
            _ = try store.importConvertedVoice(fileURL: missing, trackName: "Voice: base", atBeat: 0)
            Issue.record("expected importConvertedVoice to throw when the output file is missing")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("no longer on disk") == true)
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("no media service wired → mediaServiceUnavailable")
    func rejectsNoMedia() async throws {
        let wav = try writeTinyWAV()
        let store = ProjectStore()
        // store.media intentionally nil.
        #expect(throws: ProjectError.self) {
            try store.importConvertedVoice(fileURL: wav, trackName: "Voice: base", atBeat: 0)
        }
    }

    // MARK: - voiceConversionSource(clipId:)

    @Test("resolves an existing audio clip to its backing file + start beat")
    func resolvesAudioClip() async throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let sourceURL = URL(fileURLWithPath: "/tmp/some-vocal-stem.wav")
        let clip = try store.importAudio(url: sourceURL, toTrack: track.id, atBeat: 16)

        let resolved = try store.voiceConversionSource(clipId: clip.id)
        #expect(resolved.url == sourceURL)
        #expect(resolved.startBeat == 16)
    }

    @Test("a MIDI clip is rejected with a teaching error naming vc.convertVocals")
    func rejectsMIDIClip() async throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id)

        do {
            _ = try store.voiceConversionSource(clipId: clip.id)
            Issue.record("expected voiceConversionSource to throw for a MIDI clip")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("vc.convertVocals") == true)
            #expect(error.errorDescription?.contains("MIDI clip") == true)
        }
    }

    @Test("an unknown clip id throws clipNotFound")
    func rejectsUnknownClip() async throws {
        let store = makeStore()
        do {
            _ = try store.voiceConversionSource(clipId: UUID())
            Issue.record("expected voiceConversionSource to throw for an unknown clip id")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("project.snapshot") == true)
        }
    }
}
