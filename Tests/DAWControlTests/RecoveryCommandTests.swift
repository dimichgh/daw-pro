import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M9 (crash-b) `project.recoveryStatus` /
/// `project.recover`: the crash-recovery offer read + accept/decline action. The
/// autosave/lock mechanics themselves are pinned in DAWCore's
/// `CrashRecoveryTests`; here we pin the wire shape, both status states, the
/// accept/decline/none-available branches, and house-style param tolerance.
@MainActor
@Suite("Crash recovery — control protocol")
struct RecoveryCommandTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-b-wire-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A router whose store autosaves into a temp dir with a fixed clock.
    private func makeRouter(dir: URL) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.crashRecovery.directory = dir
        store.crashRecovery.clock = { Date(timeIntervalSince1970: 1000) }
        return (CommandRouter(store: store), store)
    }

    /// Drives a store to "a crash left a restorable autosave": begin (writes the
    /// lock), edit, autosave, then a relaunch-shaped begin so the stale lock reads
    /// as a crash.
    private func stageAvailableOffer(_ store: ProjectStore) async {
        _ = store.beginCrashDetection()
        store.addTrack(name: "Recovered")
        try? store.setTempo(128)
        await store.autosaveTick()
        _ = store.beginCrashDetection()
    }

    @Test("allCommands advertises both recovery commands")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("project.recoveryStatus"))
        #expect(CommandRouter.allCommands.contains("project.recover"))
    }

    @Test("recoveryStatus reports {available:false} when the last session exited cleanly")
    func statusUnavailable() async throws {
        let (router, _) = makeRouter(dir: tempDir())
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.recoveryStatus"))
        #expect(response.ok)
        #expect(response.result?["available"]?.boolValue == false)
    }

    @Test("recoveryStatus surfaces the offer facts when a crash left a snapshot")
    func statusAvailable() async throws {
        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.recoveryStatus"))
        #expect(response.ok)
        #expect(response.result?["available"]?.boolValue == true)
        #expect(response.result?["editCount"]?.doubleValue ?? 0 > 0)
        // Untitled session → no source path (the optional key is omitted).
        #expect(response.result?["sourcePath"]?.stringValue == nil)
        #expect(response.result?["savedAt"] != nil)
    }

    @Test("recover accept:true loads the snapshot and returns the post-recover snapshot")
    func recoverAccept() async throws {
        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.recover", params: ["accept": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["recovered"]?.boolValue == true)
        #expect(response.result?["warnings"]?.arrayValue?.isEmpty == true)
        // The recovered content is now live and dirty.
        #expect(store.tracks.contains { $0.name == "Recovered" })
        #expect(store.isDirty)
        let snapshot = response.result?["snapshot"]
        #expect(snapshot?["isDirty"]?.boolValue == true)
        // Offer consumed.
        let after = await router.handle(ControlRequest(id: "2", command: "project.recoveryStatus"))
        #expect(after.result?["available"]?.boolValue == false)
    }

    @Test("recover accept:false discards the snapshot without changing the session")
    func recoverDecline() async throws {
        let dir = tempDir()
        let (router, store) = makeRouter(dir: dir)
        await stageAvailableOffer(store)
        let nameBefore = store.projectName

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.recover", params: ["accept": .bool(false)]))
        #expect(response.ok)
        #expect(response.result?["discarded"]?.boolValue == true)
        #expect(store.projectName == nameBefore)
        let after = await router.handle(ControlRequest(id: "2", command: "project.recoveryStatus"))
        #expect(after.result?["available"]?.boolValue == false)
    }

    @Test("recover accept:true with no offer fails with the mapped noRecoveryAvailable message")
    func recoverNoneAvailable() async throws {
        let (router, _) = makeRouter(dir: tempDir())
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.recover", params: ["accept": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.hasPrefix("no recovered work to restore") == true)
    }

    @Test("recover requires the accept param (house style: a missing required param errors)")
    func recoverRequiresAccept() async throws {
        let (router, _) = makeRouter(dir: tempDir())
        let response = await router.handle(ControlRequest(
            id: "1", command: "project.recover"))
        #expect(!response.ok)
        #expect(response.error != nil)
    }
}
