import Foundation
import Testing
@testable import DAWCore

/// M9 crash-b: the rolling autosave manager (`AutosaveManager`) + `ProjectStore`
/// crash-recovery integration. Every test injects a temp `directory` and a fixed
/// `clock` so nothing touches the real profile and manifest timestamps are
/// deterministic; the manager is driven by `autosaveTick()`/lock-seam calls so no
/// test waits on wall clock.
@MainActor
@Suite("Crash-recovery autosave (M9 crash-b)")
struct CrashRecoveryTests {
    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-b-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store wired for crash-recovery testing: temp autosave dir + a fixed clock.
    private func makeStore(dir: URL, at seconds: TimeInterval = 1000) -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.crashRecovery.directory = dir
        store.crashRecovery.clock = { Date(timeIntervalSince1970: seconds) }
        return store
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func readManifest(in dir: URL) -> AutosaveManifest? {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AutosaveManifest.self, from: data)
    }

    // MARK: - 1. Dirty tracking: quiet tick writes nothing, a journaled edit writes

    @Test("a tick on a clean store writes nothing; a tick after an edit writes the snapshot")
    func dirtyTrackingGatesTheWrite() async {
        let dir = tempDir()
        let store = makeStore(dir: dir)
        let bundle = store.crashRecovery.autosaveBundleURL

        // Fresh, clean store → tick is a no-op (no snapshot, no manifest).
        await store.autosaveTick()
        #expect(!exists(bundle))
        #expect(readManifest(in: dir) == nil)

        // A journaled edit dirties the session → the next tick snapshots it.
        store.addTrack(name: "Bass")
        await store.autosaveTick()
        #expect(exists(bundle))
        #expect(readManifest(in: dir) != nil)
    }

    // MARK: - 2. Rolling overwrite: quiet re-tick doesn't rewrite; a new edit does

    @Test("two ticks keep ONE autosave bundle; a quiet re-tick never rewrites, a new edit does")
    func rollingOverwriteKeepsOneFile() async {
        let dir = tempDir()
        let store = makeStore(dir: dir, at: 1000)

        store.addTrack(name: "A")
        await store.autosaveTick()
        #expect(readManifest(in: dir)?.savedAt == Date(timeIntervalSince1970: 1000))

        // Advance the clock, then re-tick with NO new edit → no rewrite (savedAt stays).
        store.crashRecovery.clock = { Date(timeIntervalSince1970: 2000) }
        await store.autosaveTick()
        #expect(readManifest(in: dir)?.savedAt == Date(timeIntervalSince1970: 1000))

        // A genuine edit → the SAME bundle is overwritten with the newer stamp.
        store.addTrack(name: "B")
        await store.autosaveTick()
        #expect(readManifest(in: dir)?.savedAt == Date(timeIntervalSince1970: 2000))

        // Still exactly one rolling bundle in the dir.
        let bundles = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent == "autosave.dawproject" } ?? []
        #expect(bundles.count == 1)
    }

    // MARK: - 3. Manifest fields (savedAt, sourcePath, editCount)

    @Test("the manifest records savedAt, the source path, and the journaled-edit count")
    func manifestRecordsTheOfferFacts() async throws {
        let dir = tempDir()
        let projectDir = tempDir()
        let store = makeStore(dir: dir, at: 4242)

        // Titled session so sourcePath is populated; save clears the autosave, so
        // edit AFTER the save to produce a fresh snapshot with a source path.
        store.addTrack(name: "Keys")
        let savedPath = projectDir.appendingPathComponent("Song").path
        _ = try store.saveProject(to: savedPath)
        store.setMasterVolume(0.5)          // one journaled edit after the save
        try store.setTempo(90)              // a second
        await store.autosaveTick()

        let manifest = try #require(readManifest(in: dir))
        #expect(manifest.savedAt == Date(timeIntervalSince1970: 4242))
        #expect(manifest.sourcePath == ProjectBundle.normalizedBundleURL(fromPath: savedPath).path)
        #expect(manifest.editCount == (store.lastEditEvent?.seq ?? -1))
        #expect(manifest.editCount > 0)
    }

    // MARK: - 4. Manual save / new / open all invalidate the snapshot

    @Test("a manual save deletes the crash-recovery snapshot")
    func manualSaveInvalidates() async throws {
        let dir = tempDir()
        let projectDir = tempDir()
        let store = makeStore(dir: dir)
        store.addTrack(name: "T")
        await store.autosaveTick()
        #expect(exists(store.crashRecovery.autosaveBundleURL))

        _ = try store.saveProject(to: projectDir.appendingPathComponent("S").path)
        #expect(!exists(store.crashRecovery.autosaveBundleURL))
        #expect(readManifest(in: dir) == nil)
    }

    @Test("a new project deletes the crash-recovery snapshot")
    func newProjectInvalidates() async throws {
        let dir = tempDir()
        let store = makeStore(dir: dir)
        store.addTrack(name: "T")
        await store.autosaveTick()
        #expect(exists(store.crashRecovery.autosaveBundleURL))

        try store.newProject()
        #expect(!exists(store.crashRecovery.autosaveBundleURL))
    }

    @Test("opening another project deletes the crash-recovery snapshot")
    func openProjectInvalidates() async throws {
        let dir = tempDir()
        let projectDir = tempDir()

        // A project on disk to open into.
        let other = ProjectStore(); other.media = FakeMedia()
        other.addTrack(name: "Other")
        let otherPath = projectDir.appendingPathComponent("Other").path
        _ = try other.saveProject(to: otherPath)

        let store = makeStore(dir: dir)
        store.addTrack(name: "T")
        await store.autosaveTick()
        #expect(exists(store.crashRecovery.autosaveBundleURL))

        _ = try store.openProject(at: otherPath)
        #expect(!exists(store.crashRecovery.autosaveBundleURL))
    }

    // MARK: - 5. Recover round-trip — untitled: content matches, dirty, no source

    @Test("recover loads the snapshot into a fresh store: content matches, stays dirty, offer consumed")
    func recoverRoundTripUntitled() async throws {
        let dir = tempDir()

        // Session 1 begins (writes the lock), edits, autosaves, then "crashes"
        // (no endCrashDetection — the lock survives).
        let s1 = makeStore(dir: dir)
        _ = s1.beginCrashDetection()
        s1.addTrack(name: "Recovered")
        try s1.setTempo(133)
        await s1.autosaveTick()

        // Session 2 relaunches on the same dir → the stale lock is a crash.
        let s2 = makeStore(dir: dir)
        #expect(s2.beginCrashDetection())            // prior lock → crash detected
        #expect(s2.recoveryStatus().available)

        let outcome = try s2.recoverFromAutosave(accept: true)
        #expect(outcome == .recovered(warnings: []))
        #expect(s2.tracks.contains { $0.name == "Recovered" })
        #expect(s2.transport.tempoBPM == 133)
        #expect(s2.isDirty)                          // recovered work is unsaved
        #expect(s2.projectPath == nil)               // was untitled → stays untitled
        #expect(s2.projectName == "Untitled Session")
        // The offer is consumed: the autosave is gone and status flips to false.
        #expect(!s2.recoveryStatus().available)
        #expect(!exists(s2.crashRecovery.autosaveBundleURL))
    }

    // MARK: - 6. Recover round-trip — titled: sourcePath is preserved

    @Test("recover preserves the source path so a later save lands on the original file")
    func recoverPreservesSourcePath() async throws {
        let dir = tempDir()
        let projectDir = tempDir()
        let savedPath = projectDir.appendingPathComponent("MySong").path
        let normalized = ProjectBundle.normalizedBundleURL(fromPath: savedPath).path

        let s1 = makeStore(dir: dir)
        _ = s1.beginCrashDetection()
        s1.addTrack(name: "Vox")
        _ = try s1.saveProject(to: savedPath)        // titled; invalidates the autosave
        s1.setMasterVolume(0.3)                      // unsaved edit after the save
        await s1.autosaveTick()

        let s2 = makeStore(dir: dir)
        #expect(s2.beginCrashDetection())
        _ = try s2.recoverFromAutosave(accept: true)
        #expect(s2.projectPath == normalized)        // restored from the manifest
        #expect(s2.masterVolume == 0.3)              // the unsaved edit came back
        #expect(s2.isDirty)
    }

    // MARK: - 7. Discard deletes the snapshot without touching the session

    @Test("discard drops the snapshot and leaves the session untouched")
    func discardDeletes() async throws {
        let dir = tempDir()
        let store = makeStore(dir: dir)
        _ = store.beginCrashDetection()
        store.addTrack(name: "Scratch")
        await store.autosaveTick()
        _ = store.beginCrashDetection()              // relaunch shape → crash detected
        #expect(store.recoveryStatus().available)

        let before = store.projectName
        let outcome = try store.recoverFromAutosave(accept: false)
        #expect(outcome == .discarded)
        #expect(!exists(store.crashRecovery.autosaveBundleURL))
        #expect(readManifest(in: dir) == nil)
        #expect(!store.recoveryStatus().available)
        #expect(store.projectName == before)         // session untouched
    }

    // MARK: - 7b. A resolved offer never re-arms mid-session (wire-gate regression)

    @Test("a resolved offer never re-arms: after discard, fresh autosaves don't resurrect the crash offer")
    func resolvedOfferDoesNotReArm() async throws {
        let dir = tempDir()
        let s1 = makeStore(dir: dir)
        _ = s1.beginCrashDetection()
        s1.addTrack(name: "Lost")
        await s1.autosaveTick()

        // Relaunch after the "crash", resolve the offer by declining it.
        let s2 = makeStore(dir: dir)
        #expect(s2.beginCrashDetection())
        _ = try s2.recoverFromAutosave(accept: false)
        #expect(!s2.recoveryStatus().available)

        // The live session keeps working; a fresh snapshot lands — and must NOT
        // be offered back as crash recovery (the latch is spent, not just the files).
        s2.addTrack(name: "NewWork")
        await s2.autosaveTick()
        #expect(exists(s2.crashRecovery.autosaveBundleURL))
        #expect(!s2.recoveryStatus().available)
    }

    // MARK: - 7c. An unresolved offer parks the writer (wire-gate regression)

    @Test("an unresolved offer parks autosave: ticks never overwrite the crashed session's snapshot")
    func pendingOfferParksAutosave() async throws {
        let dir = tempDir()
        let s1 = makeStore(dir: dir)
        _ = s1.beginCrashDetection()
        s1.addTrack(name: "CrashedWork")
        await s1.autosaveTick()

        // Relaunch after the "crash". Wire edits bypass the launch sheet, so the
        // session can dirty itself while the offer is still pending — the tick
        // must refuse to overwrite the crashed session's only copy.
        let s2 = makeStore(dir: dir)
        #expect(s2.beginCrashDetection())
        s2.addTrack(name: "Bystander")
        await s2.autosaveTick()
        #expect(s2.recoveryStatus().available)

        // Accepting still restores the CRASHED content, not the bystander edit.
        let outcome = try s2.recoverFromAutosave(accept: true)
        #expect(outcome == .recovered(warnings: []))
        #expect(s2.tracks.contains { $0.name == "CrashedWork" })
        #expect(!s2.tracks.contains { $0.name == "Bystander" })
    }

    // MARK: - 8. Recover with nothing available throws the mapped error

    @Test("recover(accept:true) with no offer throws noRecoveryAvailable")
    func recoverNoneAvailableThrows() {
        let dir = tempDir()
        let store = makeStore(dir: dir)
        var caught: ProjectError?
        do { _ = try store.recoverFromAutosave(accept: true) }
        catch let error as ProjectError { caught = error }
        catch { Issue.record("unexpected error \(error)") }
        guard case .noRecoveryAvailable = caught else {
            Issue.record("expected noRecoveryAvailable, got \(String(describing: caught))"); return
        }
        #expect(caught?.errorDescription?.hasPrefix("no recovered work to restore") == true)
    }

    // MARK: - 9. Lock lifecycle: launch writes it, clean exit removes it, no false crash

    @Test("the session lock is written at launch and removed on clean exit — no false positive")
    func lockLifecycle() {
        let dir = tempDir()
        let store = makeStore(dir: dir)
        let lock = store.crashRecovery.lockURL

        // First launch: no prior lock → no crash; the lock is written.
        #expect(!store.beginCrashDetection())
        #expect(exists(lock))

        // Clean exit removes it → the next launch sees no crash.
        store.endCrashDetection()
        #expect(!exists(lock))
        #expect(!store.beginCrashDetection())

        // Crash shape: a launch wrote the lock and never cleaned up → the NEXT
        // launch sees it and flags a crash.
        store.endCrashDetection()
        _ = store.beginCrashDetection()              // writes the lock
        #expect(store.beginCrashDetection())         // sees the stale lock → crash
    }

    // MARK: - 10. Headless safety: no session begun → never an offer

    @Test("a store that never began a session reports no recovery, even with files present")
    func headlessNeverOffers() async {
        let dir = tempDir()
        let store = makeStore(dir: dir)
        store.addTrack(name: "T")
        await store.autosaveTick()                   // an autosave exists on disk...
        // ...but no beginCrashDetection() ran, so no crash was detected → no offer.
        #expect(!store.recoveryStatus().available)
        #expect(store.recoveryStatus() == .unavailable)
    }

    // MARK: - 11. Untitled-recovery bundle retention (launch hygiene)

    /// `flushForTransition` mints one `Untitled-<slug>.dawproj` per abandoned
    /// dirty untitled session and nothing else ever deletes foreign slugs — the
    /// launch prune keeps the newest `keep` and removes the rest, touching
    /// nothing that isn't an untitled-recovery bundle.
    @Test("prune keeps the newest bundles and ignores non-matching entries")
    func pruneKeepsNewestOnly() throws {
        let dir = tempDir()
        let fm = FileManager.default
        // Eight fake bundles with strictly increasing mtimes (older → newer).
        for i in 0..<8 {
            let bundle = dir.appendingPathComponent("Untitled-AAAA000\(i).dawproj",
                                                    isDirectory: true)
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(i) * 60)],
                ofItemAtPath: bundle.path)
        }
        // Decoys the prune must never touch: wrong prefix, wrong extension.
        let wrongPrefix = dir.appendingPathComponent("Song.dawproj", isDirectory: true)
        try fm.createDirectory(at: wrongPrefix, withIntermediateDirectories: true)
        let wrongExt = dir.appendingPathComponent("Untitled-notes.txt")
        try Data("x".utf8).write(to: wrongExt)

        let store = ProjectStore()
        store.autosaveRecoveryDirectory = dir
        #expect(store.pruneUntitledRecoveryBundles(keep: 5) == 3)

        let remaining = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("Untitled-") && $0.hasSuffix(".dawproj") }
            .sorted()
        // The three OLDEST (indices 0–2) are gone; the newest five remain.
        #expect(remaining == (3..<8).map { "Untitled-AAAA000\($0).dawproj" })
        #expect(fm.fileExists(atPath: wrongPrefix.path))
        #expect(fm.fileExists(atPath: wrongExt.path))
        // Idempotent: a second pass finds nothing over the cap.
        #expect(store.pruneUntitledRecoveryBundles(keep: 5) == 0)
    }

    @Test("prune tolerates a missing directory and an under-cap population")
    func pruneTolerantEdges() throws {
        let store = ProjectStore()
        store.autosaveRecoveryDirectory = URL(fileURLWithPath: "/dev/null/nope")
        #expect(store.pruneUntitledRecoveryBundles() == 0)

        let dir = tempDir()
        let one = dir.appendingPathComponent("Untitled-BBBB0001.dawproj", isDirectory: true)
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        store.autosaveRecoveryDirectory = dir
        #expect(store.pruneUntitledRecoveryBundles(keep: 5) == 0)
        #expect(FileManager.default.fileExists(atPath: one.path))
    }
}
