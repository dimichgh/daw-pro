import Foundation
import Testing
@testable import DAWCore

/// Minimal engine stand-in for the persistence tests: grants record permission,
/// captures the take URL + completion (so scratch-reset can be observed), and
/// counts tracksDidChange (so save's ~60 ms URL-rewrite seam can be asserted).
/// Mirrors the FakeRecordingEngine pattern from RecordingStoreTests.
@MainActor
private final class TinyEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    private(set) var tracksDidChangeCount = 0
    private(set) var lastStartURL: URL?
    private var completion: (@MainActor (Result<RecordingResult, Error>) -> Void)?

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) { tracksDidChangeCount += 1 }
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        lastStartURL = url
        self.completion = completion
    }
    func stopRecording() {}

    /// Simulates the engine finalizing the take.
    func finish(_ result: Result<RecordingResult, Error>) { completion?(result) }
}

@MainActor
@Suite("Project persistence — .dawproj bundle")
struct PersistenceTests {
    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFakeWav(_ url: URL, bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x00]) {
        try? Data(bytes).write(to: url)
    }

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func take(_ url: URL, durationSeconds: Double = 2) -> RecordingResult {
        RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: 0
        )
    }

    private func normalizedPath(_ path: String) -> String {
        ProjectBundle.normalizedBundleURL(fromPath: path).path
    }

    private func names(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(files.map(\.lastPathComponent))
    }

    // MARK: - 1. Round-trip persisted state

    @Test("save then open restores every persisted field; transient state stays out")
    func roundTripRestoresPersistedState() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTempo(140)
        try store.setLoop(enabled: true, startBeat: 2, endBeat: 10)
        try store.setPunch(enabled: true, inBeat: 1, outBeat: 5)
        try store.setMetronome(enabled: true, countInBars: 2)
        try store.seek(toBeats: 6)
        store.setMasterVolume(0.5)
        store.updateTrack(id: track.id) { $0.pan = -0.5; $0.isMuted = true }

        let path = dir.appendingPathComponent("My Song").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        try reopened.openProject(at: path)

        #expect(reopened.projectName == "My Song")
        #expect(reopened.transport.tempoBPM == 140)
        #expect(reopened.transport.isLoopEnabled)
        #expect(reopened.transport.loopStartBeat == 2)
        #expect(reopened.transport.loopEndBeat == 10)
        #expect(reopened.transport.isPunchEnabled)
        #expect(reopened.transport.punchInBeat == 1)
        #expect(reopened.transport.punchOutBeat == 5)
        #expect(reopened.transport.isMetronomeEnabled)
        #expect(reopened.transport.countInBars == 2)
        #expect(reopened.transport.positionBeats == 6)
        #expect(reopened.masterVolume == 0.5)
        #expect(reopened.tracks.count == 1)
        #expect(reopened.tracks[0].name == "Gtr")
        #expect(reopened.tracks[0].pan == -0.5)
        #expect(reopened.tracks[0].isMuted)
        #expect(reopened.projectPath == normalizedPath(path))
        #expect(!reopened.isDirty)
        // Transient flags are never modeled → always restore stopped.
        #expect(!reopened.transport.isPlaying && !reopened.transport.isRecording)
    }

    // MARK: - 2. Never persists transient state

    @Test("project.json omits transient fields and carries the schema header")
    func neverPersistsTransientState() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        store.addTrack()
        let path = dir.appendingPathComponent("X").path
        try store.saveProject(to: path)

        let jsonURL = URL(fileURLWithPath: store.projectPath!)
            .appendingPathComponent("project.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)

        #expect(!json.contains("isPlaying"))
        #expect(!json.contains("isRecording"))
        #expect(!json.contains("meters"))
        #expect(!json.contains("lastRecordingError"))
        #expect(!json.contains("selectedInputDeviceUID"))
        // Persisted header + a couple of persisted fields are present.
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("\"savedAt\""))
        #expect(json.contains("\"positionBeats\""))
    }

    // MARK: - 3. Save-as path normalization + adoption

    @Test("save-as expands, appends .dawproj (case-insensitive), and adopts the basename")
    func saveAsNormalizesAndAdoptsPath() throws {
        let dir = tempDir()

        let store = ProjectStore()
        let raw = dir.appendingPathComponent("Tune").path  // no extension
        try store.saveProject(to: raw)
        #expect(store.projectName == "Tune")
        #expect(store.projectPath == normalizedPath(raw))
        #expect(store.projectPath!.hasSuffix("Tune.dawproj"))
        #expect(FileManager.default.fileExists(atPath: store.projectPath!))

        // An existing extension (any case) is not doubled; basename drops it.
        let store2 = ProjectStore()
        let upper = dir.appendingPathComponent("Loud.DAWPROJ").path
        try store2.saveProject(to: upper)
        #expect(store2.projectName == "Loud")
        #expect(store2.projectPath!.hasSuffix("Loud.DAWPROJ"))
    }

    // MARK: - 4. Save in place on an untitled session

    @Test("saveProject(to: nil) on an untitled session throws projectPathRequired")
    func saveInPlaceUntitledThrows() throws {
        let store = ProjectStore()
        let error = projectError { try store.saveProject(to: nil) }
        guard case .projectPathRequired = try #require(error) else {
            Issue.record("expected projectPathRequired, got \(String(describing: error))")
            return
        }
        #expect(error?.errorDescription
                == "project has no file yet — pass a path to project.save (e.g. ~/Documents/DAW Pro/My Song.dawproj)")
        #expect(store.projectPath == nil)
    }

    // MARK: - 5. Media copied in; clip URL rewritten

    @Test("save copies media into the bundle and rewrites the in-memory clip URL")
    func saveCopiesMediaSelfContained() throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("Kick.wav")
        writeFakeWav(src)

        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        try store.importAudio(url: src, toTrack: track.id)

        let path = dir.appendingPathComponent("Song").path
        let result = try store.saveProject(to: path)
        #expect(result.mediaFilesCopied == 1)
        #expect(result.warnings.isEmpty)

        let clipURL = try #require(store.tracks[0].clips[0].audioFileURL)
        #expect(clipURL.lastPathComponent == "Kick.wav")
        #expect(clipURL.deletingLastPathComponent().lastPathComponent == "media")
        #expect(FileManager.default.fileExists(atPath: clipURL.path))
    }

    // MARK: - 6. Dedupe shared source

    @Test("a source shared across tracks is copied once")
    func saveDedupesSharedSource() throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("Take.wav")
        writeFakeWav(src)

        let store = ProjectStore()
        store.media = FakeMedia()
        let t1 = store.addTrack(kind: .audio)
        let t2 = store.addTrack(kind: .audio)
        try store.importAudio(url: src, toTrack: t1.id)
        try store.importAudio(url: src, toTrack: t2.id)

        let path = dir.appendingPathComponent("Shared").path
        let result = try store.saveProject(to: path)
        #expect(result.mediaFilesCopied == 1)

        let mediaDir = URL(fileURLWithPath: store.projectPath!).appendingPathComponent("media")
        #expect(names(in: mediaDir) == ["Take.wav"])
        #expect(store.tracks[0].clips[0].audioFileURL?.path == store.tracks[1].clips[0].audioFileURL?.path)
    }

    // MARK: - 7. Collision suffixes

    @Test("different sources with the same basename get -2 suffixes deterministically")
    func saveCollisionSuffixes() throws {
        let dirA = tempDir()
        let dirB = tempDir()
        let a = dirA.appendingPathComponent("Loop.wav")
        let b = dirB.appendingPathComponent("Loop.wav")
        writeFakeWav(a, bytes: [1, 2, 3])
        writeFakeWav(b, bytes: [4, 5, 6])

        let store = ProjectStore()
        store.media = FakeMedia()
        let t1 = store.addTrack(kind: .audio)
        let t2 = store.addTrack(kind: .audio)
        try store.importAudio(url: a, toTrack: t1.id)
        try store.importAudio(url: b, toTrack: t2.id)

        let path = tempDir().appendingPathComponent("Collide").path
        let result = try store.saveProject(to: path)
        #expect(result.mediaFilesCopied == 2)

        let mediaDir = URL(fileURLWithPath: store.projectPath!).appendingPathComponent("media")
        #expect(names(in: mediaDir) == ["Loop.wav", "Loop-2.wav"])
        // Deterministic track/clip order: first clip keeps the plain name.
        #expect(store.tracks[0].clips[0].audioFileURL?.lastPathComponent == "Loop.wav")
        #expect(store.tracks[1].clips[0].audioFileURL?.lastPathComponent == "Loop-2.wav")
    }

    // MARK: - 8. Idempotent re-save + tracksDidChange only on URL change

    @Test("re-save doesn't re-copy media and fires tracksDidChange only when a URL changes")
    func reSaveIdempotent() throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("Kick.wav")
        writeFakeWav(src)

        let engine = TinyEngine()
        let store = ProjectStore()
        store.engine = engine
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        try store.importAudio(url: src, toTrack: track.id)

        let path = dir.appendingPathComponent("Song").path
        let beforeFirst = engine.tracksDidChangeCount
        let first = try store.saveProject(to: path)
        #expect(first.mediaFilesCopied == 1)
        // First save rewrote the clip URL into media/ → engine notified once.
        #expect(engine.tracksDidChangeCount == beforeFirst + 1)

        let beforeSecond = engine.tracksDidChangeCount
        let second = try store.saveProject(to: nil)  // re-save in place
        #expect(second.mediaFilesCopied == 0)  // already inside media/
        #expect(engine.tracksDidChangeCount == beforeSecond)  // no URL change → no notify

        let mediaDir = URL(fileURLWithPath: store.projectPath!).appendingPathComponent("media")
        #expect(names(in: mediaDir) == ["Kick.wav"])
    }

    // MARK: - 9. Missing external source at save

    @Test("a missing source is saved without media plus a warning; the save still succeeds")
    func saveMissingExternalMediaWarns() throws {
        let dir = tempDir()
        let ghost = dir.appendingPathComponent("Ghost.wav")  // never written

        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: ghost, toTrack: track.id)

        let path = dir.appendingPathComponent("Song").path
        let result = try store.saveProject(to: path)
        #expect(result.mediaFilesCopied == 0)
        #expect(result.warnings == [
            "missing source file \(ghost.standardizedFileURL.path) — clip '\(clip.name)' saved without media"
        ])
        #expect(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: store.projectPath!).appendingPathComponent("project.json").path))

        // Reopen: the clip survives with no media (no warning — null ref).
        let reopened = ProjectStore()
        let warnings = try reopened.openProject(at: path)
        #expect(reopened.tracks[0].clips.count == 1)
        #expect(reopened.tracks[0].clips[0].audioFileURL == nil)
        #expect(warnings.isEmpty)
    }

    // MARK: - 10. Missing media at open

    @Test("a missing media file on open keeps the clip and its URL, plus a warning")
    func openMissingMediaKeepsClip() throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("Snare.wav")
        writeFakeWav(src)

        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        try store.importAudio(url: src, toTrack: track.id)
        let path = dir.appendingPathComponent("Song").path
        try store.saveProject(to: path)

        // Delete the copied media out from under the bundle.
        let bundleURL = URL(fileURLWithPath: store.projectPath!)
        try FileManager.default.removeItem(at: bundleURL.appendingPathComponent("media/Snare.wav"))

        let reopened = ProjectStore()
        let warnings = try reopened.openProject(at: path)
        #expect(reopened.tracks[0].clips.count == 1)
        let url = try #require(reopened.tracks[0].clips[0].audioFileURL)
        #expect(url.lastPathComponent == "Snare.wav")  // resolved (nonexistent) URL kept
        #expect(warnings.contains("missing media: media/Snare.wav — clip 'Snare' will be silent"))
    }

    // MARK: - 11. Invalid + absolute references at open

    @Test("escaping/non-media refs are dropped with a warning; absolute refs are accepted")
    func openInvalidAndAbsoluteRefs() throws {
        let dir = tempDir()
        let absSource = dir.appendingPathComponent("Recovered.wav")
        writeFakeWav(absSource)

        let escape = Clip(name: "Escape")
        let elsewhere = Clip(name: "Elsewhere")
        let recovered = Clip(name: "Recovered")
        let track = Track(name: "T", clips: [escape, elsewhere, recovered])
        let refs: [UUID: String?] = [
            escape.id: "media/../evil.wav",
            elsewhere.id: "sounds/x.wav",
            recovered.id: absSource.standardizedFileURL.path,
        ]
        let document = ProjectDocument(
            name: "Refs", transport: TransportState(), tracks: [track],
            masterVolume: 1, mediaRefs: refs
        )
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Refs").path)
        try ProjectBundle.write(
            document: document,
            plan: ProjectBundle.MediaPlan(copies: [], refs: refs, warnings: []),
            to: bundleURL
        )

        let store = ProjectStore()
        let warnings = try store.openProject(at: bundleURL.path)
        #expect(store.tracks[0].clips.count == 3)
        #expect(store.tracks[0].clips[0].audioFileURL == nil)
        #expect(warnings.contains("invalid media reference 'media/../evil.wav' for clip 'Escape' — ignored"))
        #expect(store.tracks[0].clips[1].audioFileURL == nil)
        #expect(warnings.contains("invalid media reference 'sounds/x.wav' for clip 'Elsewhere' — ignored"))
        #expect(store.tracks[0].clips[2].audioFileURL?.path == absSource.standardizedFileURL.path)
    }

    // MARK: - 12. Version guard + malformed detection

    @Test("open guards on schema version and reports damaged/missing bundles")
    func versionGuardAndMalformed() throws {
        let dir = tempDir()

        func writeBundle(_ name: String, json: String) -> URL {
            let bundleURL = ProjectBundle.normalizedBundleURL(
                fromPath: dir.appendingPathComponent(name).path)
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try? Data(json.utf8).write(to: bundleURL.appendingPathComponent("project.json"))
            return bundleURL
        }

        // Newer schema → refuse readable.
        let newer = writeBundle("Newer", json: #"{"schemaVersion": 99}"#)
        var error = projectError { try ProjectStore().openProject(at: newer.path) }
        guard case .newerProjectVersion(let found, let supported) = try #require(error) else {
            Issue.record("expected newerProjectVersion, got \(String(describing: error))"); return
        }
        #expect(found == 99 && supported == 1)
        #expect(error?.errorDescription
                == "this project was saved by a newer version of DAW Pro (schema v99; this build reads up to v1) — update the app to open it")

        // Sub-1 version → malformed.
        let zero = writeBundle("Zero", json: #"{"schemaVersion": 0}"#)
        error = projectError { try ProjectStore().openProject(at: zero.path) }
        guard case .malformedProject = try #require(error) else {
            Issue.record("expected malformedProject for v0, got \(String(describing: error))"); return
        }

        // Invalid JSON → malformed.
        let garbage = writeBundle("Garbage", json: "{ this is not json")
        error = projectError { try ProjectStore().openProject(at: garbage.path) }
        guard case .malformedProject = try #require(error) else {
            Issue.record("expected malformedProject for garbage, got \(String(describing: error))"); return
        }

        // Bundle dir without project.json → openFailed.
        let empty = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Empty").path)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        error = projectError { try ProjectStore().openProject(at: empty.path) }
        guard case .openFailed(let r1) = try #require(error) else {
            Issue.record("expected openFailed for empty bundle, got \(String(describing: error))"); return
        }
        #expect(r1 == "\(empty.path) has no project.json — not a DAW Pro project bundle")

        // No bundle at all → openFailed.
        let missing = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Gone").path)
        error = projectError { try ProjectStore().openProject(at: missing.path) }
        guard case .openFailed(let r2) = try #require(error) else {
            Issue.record("expected openFailed for missing bundle, got \(String(describing: error))"); return
        }
        #expect(r2 == "no project bundle at \(missing.path)")
    }

    // MARK: - 13. Refused while recording

    @Test("save/open/new are refused while recording with the exact messages")
    func persistenceRefusedWhileRecording() throws {
        let dir = tempDir()
        let engine = TinyEngine()
        let store = ProjectStore()
        store.engine = engine
        store.media = FakeMedia()
        store.autosaveRecoveryDirectory = dir  // keep any recovery in temp
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        var error = projectError { try store.saveProject(to: dir.appendingPathComponent("A").path) }
        guard case .transportBusy(let m1) = try #require(error) else {
            Issue.record("expected transportBusy from save"); return
        }
        #expect(m1 == "cannot save while recording — stop first")

        error = projectError { try store.openProject(at: dir.appendingPathComponent("B").path) }
        guard case .transportBusy(let m2) = try #require(error) else {
            Issue.record("expected transportBusy from open"); return
        }
        #expect(m2 == "cannot open a project while recording — stop first")

        error = projectError { try store.newProject() }
        guard case .transportBusy(let m3) = try #require(error) else {
            Issue.record("expected transportBusy from new"); return
        }
        #expect(m3 == "cannot start a new project while recording — stop first")

        // Autosave is a no-op while recording (never writes a recovery bundle).
        store.autosaveIfNeeded()
        #expect(names(in: dir).isEmpty)
    }

    // MARK: - 14. markDirty funnel

    @Test("session mutations dirty the store; transport moves do not")
    func markDirtyFunnel() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        #expect(!store.isDirty)

        // Transport moves never dirty.
        store.play()
        try store.seek(toBeats: 4)
        store.stop()
        #expect(!store.isDirty)

        let path = dir.appendingPathComponent("Dirt").path
        func expectDirties(_ label: String, _ mutate: () throws -> Void) throws {
            try store.saveProject(to: store.projectPath == nil ? path : nil)
            #expect(!store.isDirty, "\(label): save should clear dirty")
            try mutate()
            #expect(store.isDirty, "\(label) should dirty the store")
        }

        let track = store.addTrack()
        #expect(store.isDirty)  // addTrack dirtied
        try expectDirties("setTempo") { try store.setTempo(100) }
        try expectDirties("setMasterVolume") { store.setMasterVolume(0.5) }
        try expectDirties("setLoop") { try store.setLoop(enabled: true, startBeat: 0, endBeat: 4) }
        try expectDirties("setPunch") { try store.setPunch(enabled: true, inBeat: 0, outBeat: 4) }
        try expectDirties("setMetronome") { try store.setMetronome(enabled: true) }
        try expectDirties("updateTrack") { store.setTrackMute(id: track.id, muted: true) }
        let src = dir.appendingPathComponent("m.wav"); writeFakeWav(src)
        try expectDirties("importAudio") { try store.importAudio(url: src, toTrack: track.id) }
    }

    // MARK: - 15. Open flushes a dirty titled project + resets recording scratch

    @Test("open flushes a dirty titled project in place, swaps state, and resets scratch")
    func openFlushesDirtyTitledAndResetsScratch() throws {
        let dir = tempDir()
        let engine = TinyEngine()

        // Project B on disk to open into.
        let pathB = dir.appendingPathComponent("B").path
        let storeB = ProjectStore()
        storeB.media = FakeMedia()
        storeB.addTrack(name: "FromB")
        try storeB.saveProject(to: pathB)

        // Project A: titled, then a recorded take + another edit → dirty.
        let pathA = dir.appendingPathComponent("A").path
        let store = ProjectStore()
        store.engine = engine
        store.media = FakeMedia()
        let trackA = store.addTrack(name: "FromA", kind: .audio)
        try store.saveProject(to: pathA)

        try store.setTrackArm(id: trackA.id, armed: true)
        try store.record()
        let firstURL = try #require(engine.lastStartURL)
        #expect(firstURL.lastPathComponent == "take-1.wav")
        let sessionA = firstURL.deletingLastPathComponent()
        store.stop()
        engine.finish(.success(take(firstURL)))
        store.addTrack(name: "Extra")
        #expect(store.isDirty)

        // Open B → A is flushed in place, then B is swapped in.
        try store.openProject(at: pathB)
        #expect(store.projectName == "B")
        #expect(store.tracks.count == 1 && store.tracks[0].name == "FromB")
        #expect(store.projectPath == normalizedPath(pathB))
        #expect(!store.isDirty)

        // A was saved during the flush: the take clip + Extra track persisted.
        let checkA = ProjectStore()
        checkA.media = FakeMedia()
        try checkA.openProject(at: pathA)
        #expect(checkA.tracks.contains { $0.name == "Extra" })
        let fromA = try #require(checkA.tracks.first { $0.name == "FromA" })
        #expect(fromA.clips.count == 1)

        // Scratch reset: recording again restarts at take-1 in a NEW session dir.
        try store.setTrackArm(id: store.tracks[0].id, armed: true)
        try store.record()
        let secondURL = try #require(engine.lastStartURL)
        #expect(secondURL.lastPathComponent == "take-1.wav")
        #expect(secondURL.deletingLastPathComponent().path != sessionA.path)
        store.stop()
    }

    // MARK: - 16. Flush failure aborts the transition; discardChanges skips it

    @Test("a failed flush throws unsavedChanges and changes nothing; discardChanges skips it")
    func flushFailureThrowsUnsavedChanges() throws {
        let dir = tempDir()

        // Project B on disk to open into.
        let pathB = dir.appendingPathComponent("B").path
        let storeB = ProjectStore()
        storeB.media = FakeMedia()
        storeB.addTrack(name: "FromB")
        try storeB.saveProject(to: pathB)

        // Untitled + dirty, with an unwritable recovery dir → flush fails.
        let store = ProjectStore()
        store.media = FakeMedia()
        store.autosaveRecoveryDirectory = URL(fileURLWithPath: "/dev/null/nope")
        store.addTrack(name: "Unsaved")
        #expect(store.isDirty && store.projectPath == nil)

        let error = projectError { try store.openProject(at: pathB) }
        guard case .unsavedChanges = try #require(error) else {
            Issue.record("expected unsavedChanges, got \(String(describing: error))"); return
        }
        #expect(error?.errorDescription?.hasPrefix("unsaved changes could not be saved first") == true)
        // Nothing changed.
        #expect(store.tracks.count == 1 && store.tracks[0].name == "Unsaved")
        #expect(store.projectPath == nil)
        #expect(store.isDirty)

        // discardChanges skips the flush and opens B.
        try store.openProject(at: pathB, discardChanges: true)
        #expect(store.tracks.count == 1 && store.tracks[0].name == "FromB")
        #expect(store.projectPath == normalizedPath(pathB))
        #expect(!store.isDirty)
    }

    // MARK: - 17. newProject resets to a clean untitled session

    @Test("newProject resets to an empty, untitled, clean session")
    func newProjectResets() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        store.addTrack(name: "Old")
        try store.setTempo(150)
        store.setMasterVolume(0.3)
        try store.saveProject(to: dir.appendingPathComponent("Old").path)
        #expect(store.projectPath != nil)

        try store.newProject()
        #expect(store.projectName == "Untitled Session")
        #expect(store.tracks.isEmpty)
        #expect(store.transport.tempoBPM == 120)
        #expect(store.masterVolume == 1)
        #expect(store.projectPath == nil)
        #expect(!store.isDirty)
    }

    // MARK: - 18. Autosave: titled in place, untitled recovery bundle

    @Test("autosave saves titled in place and writes an untitled recovery bundle")
    func autosaveTitledAndUntitledRecovery() throws {
        let dir = tempDir()
        let recoveryDir = tempDir()

        let store = ProjectStore()
        store.media = FakeMedia()
        store.autosaveRecoveryDirectory = recoveryDir

        // Not dirty → no-op.
        store.autosaveIfNeeded()
        #expect(names(in: recoveryDir).isEmpty)

        // Untitled + dirty → recovery bundle; projectPath/isDirty untouched.
        let src = dir.appendingPathComponent("K.wav"); writeFakeWav(src)
        let track = store.addTrack(kind: .audio)
        try store.importAudio(url: src, toTrack: track.id)
        #expect(store.isDirty && store.projectPath == nil)

        store.autosaveIfNeeded()
        #expect(store.projectPath == nil)  // untouched
        #expect(store.isDirty)              // still dirty

        let recoveryNames = names(in: recoveryDir)
        #expect(recoveryNames.count == 1)
        let recoveryName = try #require(recoveryNames.first)
        #expect(recoveryName.hasPrefix("Untitled-") && recoveryName.hasSuffix(".dawproj"))
        let recoveryBundle = recoveryDir.appendingPathComponent(recoveryName)
        // Zero copies: media/ exists but is empty; the media ref is absolute, so
        // re-opening the recovery bundle resolves the clip to its ORIGINAL file.
        #expect(names(in: recoveryBundle.appendingPathComponent("media")).isEmpty)
        let recovered = ProjectStore()
        try recovered.openProject(at: recoveryBundle.path)
        #expect(recovered.tracks[0].clips[0].audioFileURL?.path == src.standardizedFileURL.path)

        // A titled save supersedes and deletes the recovery bundle.
        try store.saveProject(to: dir.appendingPathComponent("Titled").path)
        #expect(!FileManager.default.fileExists(atPath: recoveryBundle.path))
        #expect(!store.isDirty)

        // Autosave on a titled + dirty session saves in place and clears dirty.
        store.setMasterVolume(0.4)
        #expect(store.isDirty)
        store.autosaveIfNeeded()
        #expect(!store.isDirty)
    }

    // MARK: - 19 (MIDI 13). MIDI notes round-trip through save/open

    @Test("a MIDI clip's notes survive save then open, canonically ordered")
    func midiNotesRoundTrip() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let inst = store.addTrack(name: "Keys", kind: .instrument)
        let clip = try store.addMIDIClip(
            toTrack: inst.id, name: "Riff", atBeat: 2, lengthBeats: 8,
            notes: [
                MIDINote(pitch: 72, velocity: 90, startBeat: 4, lengthBeats: 1),
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
            ]
        )
        _ = clip

        let path = dir.appendingPathComponent("MIDI Song").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        #expect(reopened.tracks.count == 1)
        let reclip = try #require(reopened.tracks[0].clips.first)
        #expect(reclip.isMIDI)
        #expect(reclip.name == "Riff")
        #expect(reclip.startBeat == 2)
        #expect(reclip.lengthBeats == 8)
        #expect(reclip.audioFileURL == nil)
        // Canonical order preserved: onset 0 (pitch 60) before onset 4 (pitch 72).
        #expect(reclip.notes?.map(\.pitch) == [60, 72])
        #expect(reclip.notes?.map(\.startBeat) == [0, 4])
        #expect(reclip.notes?[0].velocity == 100)
    }

    // MARK: - 20 (MIDI 14). Empty MIDI clip persists as MIDI; audio omits notes

    @Test("an empty MIDI clip stays MIDI on reopen; audio clips omit the notes key")
    func emptyMIDIPersistsAudioOmits() throws {
        let dir = tempDir()
        let src = dir.appendingPathComponent("Kick.wav"); writeFakeWav(src)
        let store = ProjectStore()
        store.media = FakeMedia()
        let inst = store.addTrack(name: "Synth", kind: .instrument)
        let audio = store.addTrack(name: "Drums", kind: .audio)
        _ = try store.addMIDIClip(toTrack: inst.id)  // empty MIDI clip
        try store.importAudio(url: src, toTrack: audio.id)

        let path = dir.appendingPathComponent("Mixed").path
        try store.saveProject(to: path)

        // The empty MIDI clip persists its `notes: []`; the audio clip omits it.
        let jsonURL = URL(fileURLWithPath: store.projectPath!).appendingPathComponent("project.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(json.contains("\"notes\""))            // MIDI clip carries the key
        #expect(json.range(of: "\"notes\"") != nil)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let synth = try #require(reopened.tracks.first { $0.name == "Synth" })
        let drums = try #require(reopened.tracks.first { $0.name == "Drums" })
        #expect(synth.clips[0].isMIDI)            // empty array kept it MIDI
        #expect(synth.clips[0].notes == [])
        #expect(!drums.clips[0].isMIDI)           // audio clip decoded without notes
        #expect(drums.clips[0].notes == nil)
    }

    // MARK: - 21 (MIDI 15). A v1 fixture without any notes key decodes as audio

    @Test("a pre-MIDI (v1) project.json without notes keys opens with audio clips")
    func v1FixtureWithoutNotesDecodesAudio() throws {
        let dir = tempDir()
        let trackID = UUID().uuidString
        let clipID = UUID().uuidString
        let json = """
        {
          "schemaVersion": 1,
          "name": "Legacy",
          "masterVolume": 1,
          "tracks": [
            {
              "id": "\(trackID)",
              "name": "Old Track",
              "kind": "audio",
              "clips": [
                { "id": "\(clipID)", "name": "Old Clip", "startBeat": 0, "lengthBeats": 4, "media": null }
              ]
            }
          ]
        }
        """
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Legacy").path)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("project.json"))

        let store = ProjectStore()
        try store.openProject(at: bundleURL.path)
        #expect(store.tracks.count == 1)
        let clip = try #require(store.tracks[0].clips.first)
        #expect(clip.name == "Old Clip")
        #expect(!clip.isMIDI)         // no notes key → audio clip
        #expect(clip.notes == nil)
    }

    // MARK: - 22 (MIDI 16). Mutual exclusion persists (media null, notes array)

    @Test("a MIDI clip persists with null media and a notes array, and reopens as MIDI")
    func midiMutualExclusionPersists() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        _ = try store.addMIDIClip(
            toTrack: inst.id,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)]
        )
        let path = dir.appendingPathComponent("Excl").path
        try store.saveProject(to: path)

        // Decode the persisted ClipDocument (through the bundle reader, which
        // applies the .iso8601 date strategy) to prove the on-disk shape:
        // media == null, notes present.
        let document = try ProjectBundle.read(from: URL(fileURLWithPath: store.projectPath!))
        let clipDoc = try #require(document.tracks.first?.clips.first)
        #expect(clipDoc.media == nil)
        #expect(clipDoc.notes?.count == 1)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        #expect(reopened.tracks[0].clips[0].isMIDI)
        #expect(reopened.tracks[0].clips[0].audioFileURL == nil)
    }
}
