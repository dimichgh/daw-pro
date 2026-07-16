import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M9 (beta) `app.feedbackBundle`: the local
/// diagnostics-bundle write. The bundle mechanics (manifest fields, crash-report
/// filter, includeProject toggle) are pinned in DAWCore's
/// `DiagnosticsReporterTests`; here we pin the wire shape, the includeProject
/// param, house-style param tolerance, and the headless-safe contract. Every
/// test injects a temp `outputDir` + `crashReportsDir` so no bundle lands in the
/// real profile and no real crash-report store is scanned.
@MainActor
@Suite("Feedback bundle — control protocol")
struct FeedbackBundleCommandTests {
    private func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("beta-wire-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A router whose store writes feedback bundles into temp dirs with a fixed clock.
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.diagnostics.outputDir = tempDir("out")
        store.diagnostics.crashReportsDir = tempDir("crashes")
        store.diagnostics.clock = { Date(timeIntervalSince1970: 1_700_000_000) }
        return (CommandRouter(store: store), store)
    }

    @Test("allCommands advertises app.feedbackBundle")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("app.feedbackBundle"))
    }

    @Test("no params: writes a lean bundle and returns the summary shape")
    func defaultShape() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "app.feedbackBundle"))
        #expect(response.ok)
        let path = try #require(response.result?["path"]?.stringValue)
        #expect(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("feedback-"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(response.result?["includesProject"]?.boolValue == false)
        #expect(response.result?["crashReportCount"]?.doubleValue == 0)
        // manifest + engine + overview = 3 files, some bytes.
        #expect(response.result?["fileCount"]?.doubleValue == 3)
        #expect((response.result?["byteCount"]?.doubleValue ?? 0) > 0)
    }

    @Test("includeProject:true folds in the full project snapshot")
    func includeProject() async throws {
        let (router, store) = makeRouter()
        _ = store.addTrack(name: "Bass")

        let response = await router.handle(ControlRequest(
            id: "1", command: "app.feedbackBundle", params: ["includeProject": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["includesProject"]?.boolValue == true)
        let path = try #require(response.result?["path"]?.stringValue)
        let projJSON = URL(fileURLWithPath: path)
            .appendingPathComponent("project.dawproject").appendingPathComponent("project.json")
        #expect(FileManager.default.fileExists(atPath: projJSON.path))
    }

    @Test("headless (no engine): the engine snapshots read idle and the write still succeeds")
    func headlessSafe() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "app.feedbackBundle"))
        #expect(response.ok)
        let path = try #require(response.result?["path"]?.stringValue)
        let engineURL = URL(fileURLWithPath: path).appendingPathComponent("engine.json")
        let engine = try JSONDecoder().decode(
            EngineDiagnostics.self, from: Data(contentsOf: engineURL))
        #expect(engine.watchdog == .idle)
        #expect(engine.performance == .idle)
    }

    @Test("unknown extras are rejected with a teaching error (m16-e, audit F5 — house style widened)")
    func paramTolerance() async throws {
        let (router, _) = makeRouter()
        let sloppy = await router.handle(ControlRequest(
            id: "1", command: "app.feedbackBundle",
            params: ["bogus": .number(7), "reset": .bool(true)]))
        #expect(!sloppy.ok)
        let error = sloppy.error ?? ""
        #expect(error.contains("app.feedbackBundle"))
        #expect(error.contains("'bogus'"))
        #expect(error.contains("'reset'"))
        #expect(error.contains("'includeProject'"))
    }
}
