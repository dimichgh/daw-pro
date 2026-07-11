import Foundation
import Testing
@testable import DAWCore

/// Test double for the AI generation source seam (M6 iii-a). Returns a canned
/// `GeneratedSongResult` (or throws) so `importGeneration` is exercised without
/// a sidecar/network. Real HTTP behaviour lives in AIServicesTests; the
/// SongGenerating→seam adapter is covered in DAWControlTests.
struct FakeGenerationSource: GenerationImporting {
    var result: Result<GeneratedSongResult, Error>
    /// Defaults to a "not ready" empty-stems result so single-song tests
    /// (which never touch the stems path) don't need to supply one.
    var stemsResult: Result<GeneratedStemsResult, Error> = .success(GeneratedStemsResult(state: "running"))

    func fetchGeneration(jobID: String) async throws -> GeneratedSongResult { try result.get() }
    func fetchGenerationStems(jobID: String) async throws -> GeneratedStemsResult { try stemsResult.get() }
}

/// A generic provider error (stands in for the client's jobNotFound/jobFailed),
/// to prove the store surfaces the source's own message verbatim.
private struct FakeProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Suite("Generation import (M6 iii-a)")
struct GenerationImportTests {
    /// Writes a minimal valid PCM16 mono WAV to a fresh temp file (the "cached"
    /// download the sidecar client would produce). FakeMedia doesn't read it —
    /// the file only needs to EXIST and be copyable — but a real header keeps
    /// the fixture honest.
    private func writeTinyWAV(name: String = "gen.wav") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-import-src-\(UUID().uuidString)")
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

    /// A store with a temp imports directory (hermetic — never litters the real
    /// profile) and a deterministic media stand-in.
    private func makeStore(
        source: GenerationImporting,
        mediaDurationSeconds: Double = 2.0
    ) -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: mediaDurationSeconds, sampleRate: 48000, channelCount: 2))
        store.generationSource = source
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-import-dest-\(UUID().uuidString)")
        return store
    }

    private func succeeded(audioPath: String, bpm: Double? = 92, prompt: String? = "lofi chillhop, mellow keys")
        -> GeneratedSongResult {
        GeneratedSongResult(
            state: "succeeded", audioPath: audioPath, prompt: prompt, bpm: bpm,
            durationSeconds: 30, genres: "lofi", keyScale: "C Major", timeSignature: "4/4")
    }

    // MARK: - Happy path

    @Test("import creates an AI-flagged audio track + clip and adopts tempo on an empty project")
    func happyPathEmptyProjectAdoptsTempo() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: wav.path, bpm: 92))))
        try store.setTempo(120)  // clearly different from the adopted 92

        let (trackID, clipID, adopted) = try await store.importGeneration(jobID: "job-1")

        #expect(adopted == 92)
        #expect(store.transport.tempoBPM == 92)

        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.kind == .audio)
        #expect(track.isAIGenerated)
        #expect(track.name == "AI: lofi chillhop mellow keys")  // first 4 words, comma stripped
        let clip = try #require(track.clips.first { $0.id == clipID })
        #expect(clip.isAIGenerated)
        #expect(clip.startBeat == 0)
        // 2.0 s at the ADOPTED 92 bpm.
        #expect(abs(clip.lengthBeats - 2.0 * 92.0 / 60.0) < 1e-9)

        // The clip references a STABLE copy in the imports dir, not the volatile
        // source cache, and that copy exists on disk.
        let clipURL = try #require(clip.audioFileURL)
        #expect(clipURL.path.hasPrefix(store.generationImportsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: clipURL.path))
    }

    @Test("supplied trackName and atBeat win; default length uses the current tempo when tempo not adopted")
    func suppliedNameAndBeat() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: wav.path, bpm: 92))))
        try store.setTempo(120)

        let (trackID, _, adopted) = try await store.importGeneration(
            jobID: "job-1", trackName: "My Vox", atBeat: 8, setProjectTempo: false)

        #expect(adopted == nil)
        #expect(store.transport.tempoBPM == 120)
        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.name == "My Vox")
        let clip = try #require(track.clips.first)
        #expect(clip.startBeat == 8)
        #expect(abs(clip.lengthBeats - 2.0 * 120.0 / 60.0) < 1e-9)  // not adopted → current tempo
    }

    // MARK: - Undo

    @Test("undo removes the imported track AND restores the previous tempo in one step")
    func undoRestoresTrackAndTempo() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: wav.path, bpm: 92))))
        try store.setTempo(120)
        let tempoBefore = store.transport.tempoBPM

        _ = try await store.importGeneration(jobID: "job-1")
        #expect(store.tracks.count == 1)
        #expect(store.transport.tempoBPM == 92)

        let label = try store.undo()
        #expect(label == "Import Generation")
        #expect(store.tracks.isEmpty)
        #expect(store.transport.tempoBPM == tempoBefore)
    }

    // MARK: - Tempo adoption matrix

    @Test("empty project, default setProjectTempo, bpm present → adopted")
    func matrixEmptyDefaultAdopts() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: wav.path, bpm: 92))))
        try store.setTempo(120)
        let (_, _, adopted) = try await store.importGeneration(jobID: "j")
        #expect(adopted == 92)
        #expect(store.transport.tempoBPM == 92)
    }

    @Test("non-empty project, default setProjectTempo → NOT adopted")
    func matrixNonEmptyDefaultDoesNotAdopt() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: wav.path, bpm: 92))))
        try store.setTempo(120)
        // Make the project non-empty first.
        let track = store.addTrack(kind: .audio)
        _ = try store.importAudio(url: URL(fileURLWithPath: "/tmp/existing.wav"), toTrack: track.id)

        let (_, _, adopted) = try await store.importGeneration(jobID: "j")
        #expect(adopted == nil)
        #expect(store.transport.tempoBPM == 120)
    }

    @Test("non-empty project, explicit setProjectTempo:true → adopted")
    func matrixNonEmptyExplicitTrueAdopts() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: wav.path, bpm: 92))))
        try store.setTempo(120)
        let track = store.addTrack(kind: .audio)
        _ = try store.importAudio(url: URL(fileURLWithPath: "/tmp/existing.wav"), toTrack: track.id)

        let (_, _, adopted) = try await store.importGeneration(jobID: "j", setProjectTempo: true)
        #expect(adopted == 92)
        #expect(store.transport.tempoBPM == 92)
    }

    @Test("adopt requested but no bpm in metas → tempo unchanged, adopted nil")
    func matrixAdoptRequestedButNoBPM() async throws {
        let wav = try writeTinyWAV()
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: wav.path, bpm: nil))))
        try store.setTempo(120)
        let (_, _, adopted) = try await store.importGeneration(jobID: "j", setProjectTempo: true)
        #expect(adopted == nil)
        #expect(store.transport.tempoBPM == 120)
    }

    // MARK: - Rejections

    @Test("still-running job (no audioPath) rejects, pointing at ai.generationStatus")
    func rejectsStillRunning() async throws {
        let store = makeStore(source: FakeGenerationSource(result: .success(
            GeneratedSongResult(state: "running", audioPath: nil))))
        await #expect(throws: ProjectError.self) {
            _ = try await store.importGeneration(jobID: "job-1")
        }
        do {
            _ = try await store.importGeneration(jobID: "job-1")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("ai.generationStatus") == true)
            #expect(error.errorDescription?.contains("running") == true)
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("unknown/expired job: the source's own error propagates verbatim")
    func rejectsUnknownJob() async throws {
        let store = makeStore(source: FakeGenerationSource(result: .failure(
            FakeProviderError(message: "no ACE-Step generation job with id 'nope' — it may have expired"))))
        do {
            _ = try await store.importGeneration(jobID: "nope")
            Issue.record("expected importGeneration to throw for an unknown job")
        } catch let error as LocalizedError {
            #expect(error.errorDescription?.contains("may have expired") == true)
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("succeeded but the cached audio file is gone → actionable missing-file error")
    func rejectsMissingFile() async throws {
        let store = makeStore(source: FakeGenerationSource(result: .success(
            succeeded(audioPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav"))))
        do {
            _ = try await store.importGeneration(jobID: "job-1")
            Issue.record("expected importGeneration to throw when the audio file is missing")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("no longer on disk") == true)
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("no generation source wired → generationSourceUnavailable")
    func rejectsNoSource() async throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        // generationSource intentionally nil.
        await #expect(throws: ProjectError.self) {
            _ = try await store.importGeneration(jobID: "job-1")
        }
    }
}

/// M6 (iii-c): multi-track import from a stems-extraction or Lego composite
/// job. Same store/seam plumbing as `GenerationImportTests` above (same
/// `FakeGenerationSource`, now scripting its `stemsResult`), proving the
/// N-tracks-in-one-edit / single-undo / all-or-nothing-on-missing-file
/// contract `importGeneratedStems` adds on top of the M6 iii-a shape.
@MainActor
@Suite("Generation import — stems / Lego (M6 iii-c)")
struct GenerationStemsImportTests {
    private func writeTinyWAV(name: String = "stem.wav") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-stems-src-\(UUID().uuidString)")
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

    private func makeStore(
        stemsResult: Result<GeneratedStemsResult, Error>,
        mediaDurationSeconds: Double = 3.0
    ) -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: mediaDurationSeconds, sampleRate: 48000, channelCount: 2))
        store.generationSource = FakeGenerationSource(
            result: .failure(CancellationError()),  // the single-song path is untouched here
            stemsResult: stemsResult)
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-stems-dest-\(UUID().uuidString)")
        return store
    }

    // MARK: - Happy path

    @Test("import lands N AI-flagged tracks + clips in ONE edit and adopts tempo from the first bpm-bearing stem")
    func happyPathMultipleStemsOneEdit() async throws {
        let vocals = try writeTinyWAV(name: "vocals.wav")
        let drums = try writeTinyWAV(name: "drums.wav")
        let stems = GeneratedStemsResult(state: "succeeded", stems: [
            GeneratedStem(trackName: "vocals", audioPath: vocals.path, bpm: nil),
            GeneratedStem(trackName: "drums", audioPath: drums.path, bpm: 96),
        ])
        let store = makeStore(stemsResult: .success(stems))
        try store.setTempo(120)

        let (imported, adopted) = try await store.importGeneratedStems(jobID: "stems:job-1")

        #expect(imported.count == 2)
        #expect(adopted == 96)  // first stem with a non-nil bpm (drums), empty project → adopted
        #expect(store.transport.tempoBPM == 96)
        #expect(store.tracks.count == 2)

        let vocalsEntry = try #require(imported.first { $0.trackName == "vocals" })
        let drumsEntry = try #require(imported.first { $0.trackName == "drums" })
        let vocalsTrack = try #require(store.tracks.first { $0.id == vocalsEntry.trackID })
        let drumsTrack = try #require(store.tracks.first { $0.id == drumsEntry.trackID })
        #expect(vocalsTrack.name == "AI: Vocals")
        #expect(drumsTrack.name == "AI: Drums")
        #expect(vocalsTrack.isAIGenerated)
        #expect(drumsTrack.isAIGenerated)
        let vocalsClip = try #require(vocalsTrack.clips.first { $0.id == vocalsEntry.clipID })
        #expect(vocalsClip.isAIGenerated)
        #expect(vocalsClip.startBeat == 0)
        // 3.0 s at the ADOPTED 96 bpm.
        #expect(abs(vocalsClip.lengthBeats - 3.0 * 96.0 / 60.0) < 1e-9)

        // Both clips reference STABLE copies in the imports dir.
        for entry in imported {
            let track = try #require(store.tracks.first { $0.id == entry.trackID })
            let clip = try #require(track.clips.first { $0.id == entry.clipID })
            let clipURL = try #require(clip.audioFileURL)
            #expect(clipURL.path.hasPrefix(store.generationImportsDirectory.path))
            #expect(FileManager.default.fileExists(atPath: clipURL.path))
        }
    }

    @Test("underscore track names title-case into readable track names")
    func titleCasesUnderscoreTrackNames() async throws {
        let backingVocals = try writeTinyWAV(name: "bv.wav")
        let stems = GeneratedStemsResult(state: "succeeded", stems: [
            GeneratedStem(trackName: "backing_vocals", audioPath: backingVocals.path),
        ])
        let store = makeStore(stemsResult: .success(stems))
        let (imported, _) = try await store.importGeneratedStems(jobID: "stems:job-1")
        let track = try #require(store.tracks.first { $0.id == imported[0].trackID })
        #expect(track.name == "AI: Backing Vocals")
    }

    @Test("supplied atBeat and setProjectTempo:false land every clip at that beat without adopting tempo")
    func suppliedAtBeatAndTempoOff() async throws {
        let vocals = try writeTinyWAV(name: "vocals.wav")
        let bass = try writeTinyWAV(name: "bass.wav")
        let stems = GeneratedStemsResult(state: "succeeded", stems: [
            GeneratedStem(trackName: "vocals", audioPath: vocals.path, bpm: 96),
            GeneratedStem(trackName: "bass", audioPath: bass.path, bpm: 96),
        ])
        let store = makeStore(stemsResult: .success(stems))
        try store.setTempo(120)

        let (imported, adopted) = try await store.importGeneratedStems(
            jobID: "stems:job-1", atBeat: 8, setProjectTempo: false)

        #expect(adopted == nil)
        #expect(store.transport.tempoBPM == 120)
        for entry in imported {
            let track = try #require(store.tracks.first { $0.id == entry.trackID })
            let clip = try #require(track.clips.first { $0.id == entry.clipID })
            #expect(clip.startBeat == 8)
            #expect(abs(clip.lengthBeats - 3.0 * 120.0 / 60.0) < 1e-9)  // not adopted → current tempo
        }
    }

    // MARK: - Undo

    @Test("undo removes ALL imported tracks AND restores the previous tempo in one step")
    func undoRestoresAllTracksAndTempo() async throws {
        let vocals = try writeTinyWAV(name: "vocals.wav")
        let drums = try writeTinyWAV(name: "drums.wav")
        let bass = try writeTinyWAV(name: "bass.wav")
        let stems = GeneratedStemsResult(state: "succeeded", stems: [
            GeneratedStem(trackName: "vocals", audioPath: vocals.path, bpm: 100),
            GeneratedStem(trackName: "drums", audioPath: drums.path),
            GeneratedStem(trackName: "bass", audioPath: bass.path),
        ])
        let store = makeStore(stemsResult: .success(stems))
        try store.setTempo(120)
        let tempoBefore = store.transport.tempoBPM

        _ = try await store.importGeneratedStems(jobID: "stems:job-1")
        #expect(store.tracks.count == 3)
        #expect(store.transport.tempoBPM == 100)

        let label = try store.undo()
        #expect(label == "Import Generated Stems")
        #expect(store.tracks.isEmpty)
        #expect(store.transport.tempoBPM == tempoBefore)
    }

    // MARK: - Rejections

    @Test("still-running job (empty stems) rejects, pointing at ai.generationStatus")
    func rejectsStillRunning() async throws {
        let store = makeStore(stemsResult: .success(GeneratedStemsResult(state: "running")))
        do {
            _ = try await store.importGeneratedStems(jobID: "stems:job-1")
            Issue.record("expected importGeneratedStems to throw for a still-running job")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("ai.generationStatus") == true)
            #expect(error.errorDescription?.contains("running") == true)
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("unknown/expired job: the source's own error propagates verbatim")
    func rejectsUnknownJob() async throws {
        struct FakeProviderError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        let store = makeStore(stemsResult: .failure(
            FakeProviderError(message: "no ACE-Step generation job with id 'stems:nope' — it may have expired")))
        do {
            _ = try await store.importGeneratedStems(jobID: "stems:nope")
            Issue.record("expected importGeneratedStems to throw for an unknown job")
        } catch let error as LocalizedError {
            #expect(error.errorDescription?.contains("may have expired") == true)
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("one missing stem file rejects the WHOLE import — all or nothing, no partial tracks")
    func rejectsWhenAnyStemFileIsMissing() async throws {
        let vocals = try writeTinyWAV(name: "vocals.wav")
        let stems = GeneratedStemsResult(state: "succeeded", stems: [
            GeneratedStem(trackName: "vocals", audioPath: vocals.path),
            GeneratedStem(trackName: "drums", audioPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav"),
        ])
        let store = makeStore(stemsResult: .success(stems))
        do {
            _ = try await store.importGeneratedStems(jobID: "stems:job-1")
            Issue.record("expected importGeneratedStems to throw when any stem file is missing")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("no longer on disk") == true)
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("no generation source wired → generationSourceUnavailable")
    func rejectsNoSource() async throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        await #expect(throws: ProjectError.self) {
            _ = try await store.importGeneratedStems(jobID: "stems:job-1")
        }
    }
}
