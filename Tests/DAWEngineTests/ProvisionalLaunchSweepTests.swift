import Darwin
import Foundation
import Testing
@testable import DAWEngine

/// p2-ren Stage B″ (design `docs/design/2026-09-25-incremental-note-render.md`
/// §17, erratum E9) — the LAUNCH sweep of dead provisional-render sessions.
///
/// ⛔ **NEVER THE USER'S CACHE.** Every root here is a fresh temp folder; the
/// engine test points `stretchCache` at one BEFORE it sweeps.
///
/// ⚠️ NOT `@MainActor`: the static seam is `nonisolated`, and the one test that
/// needs the engine hops to the main actor for its body instead of spending a
/// suite slot `MainActorOccupancySiteTests` bounds. The wiring half (the app
/// calls it at launch) is pinned in `PitchEditorInteractionSiteTests`.
@Suite("Provisional launch sweep (p2-ren B″, erratum E9)")
struct ProvisionalLaunchSweepTests {

    /// A pid no process is running: counted down from well above the range in
    /// use, the `sessionWipeKeepsLiveSessions` idiom.
    private static func deadPid() -> pid_t {
        var dead: pid_t = 99_990
        while kill(dead, 0) == 0 || errno != ESRCH { dead -= 1 }
        return dead
    }

    private static func tempRoot(_ tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func make(_ names: [String], in root: URL) throws {
        for name in names {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
    }

    private static func names(in root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    @Test("the static seam removes a dead session's folder and keeps a live one (pid 1), this process's, and a folder that is not a session")
    func staticSeamKeepsLiveSessions() throws {
        let root = try Self.tempRoot("launch-sweep")
        defer { try? FileManager.default.removeItem(at: root) }
        let dead = "\(Self.deadPid())-DEAD"
        let ours = "\(getpid())-OURS"
        try Self.make([dead, "1-LIVE", ours, "notes"], in: root)
        // Control: the dead folder is THERE before the sweep, so its absence
        // after is the sweep's doing and not the fixture's.
        #expect(try Self.names(in: root).contains(dead))

        AudioEngine.wipeDeadProvisionalSessions(provisionalRoot: root)

        let left = try Self.names(in: root)
        #expect(left == ["1-LIVE", ours, "notes"], "left: \(left.sorted())")
    }

    @Test("the engine's launch call sweeps the Provisional folder of ITS OWN cache and nothing else in it")
    func engineCallSweepsItsOwnCache() async throws {
        let cache = try Self.tempRoot("launch-sweep-cache")
        defer { try? FileManager.default.removeItem(at: cache) }
        let provisional = cache.appendingPathComponent("Provisional", isDirectory: true)
        let dead = "\(Self.deadPid())-DEAD"
        try Self.make([dead, "1-LIVE"], in: provisional)
        // A dead-pid-shaped folder BESIDE Provisional: the sweep is scoped to
        // the provisional root, so this one must stay.
        try Self.make([dead], in: cache)
        #expect(try Self.names(in: provisional) == [dead, "1-LIVE"])

        await MainActor.run {
            let engine = AudioEngine()
            engine.stretchCache = StretchRenderCache(directory: cache)
            engine.wipeDeadProvisionalSessions()
        }

        #expect(try Self.names(in: provisional) == ["1-LIVE"])
        #expect(try Self.names(in: cache) == [dead, "Provisional"])
    }
}
