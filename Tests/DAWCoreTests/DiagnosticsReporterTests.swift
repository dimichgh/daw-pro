import Foundation
import Testing
@testable import DAWCore

/// M9 beta: the headless diagnostics-bundle writer (`DiagnosticsReporter`) +
/// `ProjectStore.writeFeedbackBundle`. Every test injects a temp `outputDir` and
/// `crashReportsDir` and a fixed `clock` so nothing touches the real profile,
/// nothing scans the real crash-report store, and manifest timestamps are
/// deterministic — the `CrashRecoveryTests` idiom.
@MainActor
@Suite("Diagnostics feedback bundle (M9 beta)")
struct DiagnosticsReporterTests {
    // MARK: - Helpers

    private func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("beta-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeReporter(out: URL, crashes: URL, at seconds: TimeInterval = 1_700_000_000)
        -> DiagnosticsReporter {
        DiagnosticsReporter(outputDir: out, crashReportsDir: crashes,
                            clock: { Date(timeIntervalSince1970: seconds) })
    }

    private func sampleHost() -> DiagnosticsHostInfo {
        DiagnosticsHostInfo(appVersion: "9.9.9", build: "42",
                            osVersion: "Version 14.5 (Build TEST)", hardwareModel: "TestMac1,1")
    }

    private func sampleEngine() -> EngineDiagnostics {
        EngineDiagnostics(
            watchdog: EngineWatchdogStatus(state: .ok, restartCount: 3, consecutiveFailures: 0,
                                           lastHeartbeat: 12_345, engineRunning: true),
            performance: EnginePerformanceStats(
                callbackCount: 100, renderedFrames: 51_200, renderTimeNs: 1_000, peakCallbackNs: 42,
                overrunCount: 0, averageLoad: 0.07, recentLoad: 0.06, sampleRate: 48_000,
                quantumFrames: 512, sinceResetSeconds: 2.0))
    }

    /// A one-track overview to embed (counts/ids only — the privacy-lean default).
    private func sampleOverview(trackName: String = "Bass") -> ProjectOverview {
        let store = ProjectStore()
        store.addTrack(name: trackName)
        return store.overview()
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func readManifest(atBundle path: String) -> FeedbackManifest? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FeedbackManifest.self, from: data)
    }

    /// Writes a file with `name` into `dir` and stamps its modification date.
    @discardableResult
    private func writeFile(_ name: String, in dir: URL, mtime: Date, body: String = "x") -> URL {
        let url = dir.appendingPathComponent(name)
        try? body.data(using: .utf8)!.write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    // MARK: - 1. Manifest fields (injected clock + dirs)

    @Test("manifest carries the injected host facts + clock timestamp; engine.json round-trips")
    func manifestFieldsAndEngineSnapshot() throws {
        let out = tempDir("out"); let crashes = tempDir("crashes")
        let at: TimeInterval = 1_700_000_000
        let reporter = makeReporter(out: out, crashes: crashes, at: at)

        let engine = sampleEngine()
        let summary = try reporter.writeBundle(
            host: sampleHost(), engine: engine, overview: sampleOverview(), projectDocument: nil)

        #expect(exists(URL(fileURLWithPath: summary.path)))
        #expect(URL(fileURLWithPath: summary.path).lastPathComponent.hasPrefix("feedback-"))
        #expect(summary.includesProject == false)
        #expect(summary.crashReportCount == 0)
        // manifest + engine + overview = 3 files (crashes empty, no project).
        #expect(summary.fileCount == 3)
        #expect(summary.byteCount > 0)

        let manifest = try #require(readManifest(atBundle: summary.path))
        #expect(manifest.appVersion == "9.9.9")
        #expect(manifest.build == "42")
        #expect(manifest.osVersion == "Version 14.5 (Build TEST)")
        #expect(manifest.hardwareModel == "TestMac1,1")
        #expect(manifest.createdAt == Date(timeIntervalSince1970: at))
        #expect(manifest.includesProject == false)
        #expect(manifest.crashReportCount == 0)
        #expect(manifest.hasEngine)
        #expect(manifest.hasOverview)

        // engine.json is the CURRENT watchdog + performance snapshots, verbatim.
        let engineURL = URL(fileURLWithPath: summary.path).appendingPathComponent("engine.json")
        let decoded = try JSONDecoder().decode(EngineDiagnostics.self, from: Data(contentsOf: engineURL))
        #expect(decoded == engine)
    }

    // MARK: - 2. Overview present + parses

    @Test("overview.json is the counts-only projection and parses back")
    func overviewPresentAndParses() throws {
        let out = tempDir("out"); let crashes = tempDir("crashes")
        let reporter = makeReporter(out: out, crashes: crashes)
        let overview = sampleOverview(trackName: "Lead")

        let summary = try reporter.writeBundle(
            host: sampleHost(), engine: sampleEngine(), overview: overview, projectDocument: nil)

        let overviewURL = URL(fileURLWithPath: summary.path).appendingPathComponent("overview.json")
        #expect(exists(overviewURL))
        let decoded = try JSONDecoder().decode(ProjectOverview.self, from: Data(contentsOf: overviewURL))
        #expect(decoded == overview)
        #expect(decoded.tracks.count == 1)
        #expect(decoded.tracks.first?.name == "Lead")
    }

    // MARK: - 3. includeProject toggle (folder present / absent)

    @Test("no project snapshot by default; the opt-in writes project.dawproject/")
    func includeProjectToggle() throws {
        let out = tempDir("out"); let crashes = tempDir("crashes")

        // Default (nil project) — no snapshot folder.
        let r1 = makeReporter(out: out, crashes: crashes, at: 1_700_000_000)
        let noProject = try r1.writeBundle(
            host: sampleHost(), engine: sampleEngine(), overview: sampleOverview(), projectDocument: nil)
        let projURL1 = URL(fileURLWithPath: noProject.path).appendingPathComponent("project.dawproject")
        #expect(!exists(projURL1))
        #expect(noProject.includesProject == false)

        // Opt-in — the full snapshot lands via the SAME bundle serialization.
        let store = ProjectStore()
        store.addTrack(name: "Keys")
        let doc = store.buildAutosaveDocument()
        let r2 = makeReporter(out: out, crashes: crashes, at: 1_700_000_100)
        let withProject = try r2.writeBundle(
            host: sampleHost(), engine: sampleEngine(), overview: store.overview(), projectDocument: doc)
        let projJSON = URL(fileURLWithPath: withProject.path)
            .appendingPathComponent("project.dawproject").appendingPathComponent("project.json")
        #expect(exists(projJSON))
        #expect(withProject.includesProject == true)
        // manifest + engine + overview + project.json = 4 files.
        #expect(withProject.fileCount == 4)
        let manifest = try #require(readManifest(atBundle: withProject.path))
        #expect(manifest.includesProject == true)
    }

    // MARK: - 4. Crash-report filter (recent copied, old/foreign/wrong-ext ignored)

    @Test("only recent DAWApp*.ips are copied — old, foreign-process, and wrong-ext files are ignored")
    func crashReportFilter() throws {
        let out = tempDir("out"); let crashes = tempDir("crashes")
        let at: TimeInterval = 1_700_000_000
        let now = Date(timeIntervalSince1970: at)

        let recent = writeFile("DAWApp-2026-07-10-120000.ips", in: crashes,
                               mtime: now.addingTimeInterval(-24 * 60 * 60))          // 1 day → in
        writeFile("DAWApp-2026-06-01-120000.ips", in: crashes,
                  mtime: now.addingTimeInterval(-20 * 24 * 60 * 60))                   // 20 days → out
        writeFile("Finder-2026-07-10-120000.ips", in: crashes,
                  mtime: now.addingTimeInterval(-24 * 60 * 60))                        // foreign → out
        writeFile("DAWApp-2026-07-10-120000.txt", in: crashes,
                  mtime: now.addingTimeInterval(-24 * 60 * 60))                        // wrong ext → out

        let reporter = makeReporter(out: out, crashes: crashes, at: at)
        let summary = try reporter.writeBundle(
            host: sampleHost(), engine: sampleEngine(), overview: sampleOverview(), projectDocument: nil)

        #expect(summary.crashReportCount == 1)
        let crashesDir = URL(fileURLWithPath: summary.path).appendingPathComponent("crashes")
        let copied = try FileManager.default.contentsOfDirectory(
            at: crashesDir, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        #expect(copied == [recent.lastPathComponent])

        let manifest = try #require(readManifest(atBundle: summary.path))
        #expect(manifest.crashReportCount == 1)
    }

    @Test("the crash-report copy is capped at the 10 newest reports")
    func crashReportCap() throws {
        let out = tempDir("out"); let crashes = tempDir("crashes")
        let at: TimeInterval = 1_700_000_000
        let now = Date(timeIntervalSince1970: at)

        // 12 recent reports, distinct mtimes (i hours ago) — newest = i == 1.
        for i in 1...12 {
            writeFile("DAWApp-report-\(String(format: "%02d", i)).ips", in: crashes,
                      mtime: now.addingTimeInterval(-Double(i) * 60 * 60))
        }

        let reporter = makeReporter(out: out, crashes: crashes, at: at)
        let summary = try reporter.writeBundle(
            host: sampleHost(), engine: sampleEngine(), overview: sampleOverview(), projectDocument: nil)

        #expect(summary.crashReportCount == 10)
        let crashesDir = URL(fileURLWithPath: summary.path).appendingPathComponent("crashes")
        let copied = Set(try FileManager.default.contentsOfDirectory(
            at: crashesDir, includingPropertiesForKeys: nil).map(\.lastPathComponent))
        #expect(copied.count == 10)
        // The two OLDEST (i == 11, 12) are the ones dropped by the cap.
        #expect(!copied.contains("DAWApp-report-11.ips"))
        #expect(!copied.contains("DAWApp-report-12.ips"))
        #expect(copied.contains("DAWApp-report-01.ips"))
    }

    // MARK: - 5. No-crash-dir tolerance

    @Test("a missing crash-report dir copies zero and never throws")
    func missingCrashDirTolerated() throws {
        let out = tempDir("out")
        // A crashReportsDir that does not exist.
        let crashes = FileManager.default.temporaryDirectory
            .appendingPathComponent("beta-nonexistent-\(UUID().uuidString)", isDirectory: true)
        let reporter = makeReporter(out: out, crashes: crashes)

        let summary = try reporter.writeBundle(
            host: sampleHost(), engine: sampleEngine(), overview: sampleOverview(), projectDocument: nil)
        #expect(summary.crashReportCount == 0)
        // crashes/ still exists in the bundle (empty), so the layout is predictable.
        #expect(exists(URL(fileURLWithPath: summary.path).appendingPathComponent("crashes")))
    }

    // MARK: - 6. Real IO failure maps to a readable DiagnosticsError

    @Test("a write failure surfaces DiagnosticsError.writeFailed, not a raw dump")
    func writeFailureMapsToDiagnosticsError() throws {
        let crashes = tempDir("crashes")
        // Point outputDir UNDER a regular file so createDirectory can't succeed.
        let blocker = tempDir("blocker").appendingPathComponent("afile")
        try Data("x".utf8).write(to: blocker)
        let out = blocker.appendingPathComponent("feedback-out", isDirectory: true)
        let reporter = makeReporter(out: out, crashes: crashes)

        #expect(throws: DiagnosticsError.self) {
            _ = try reporter.writeBundle(
                host: sampleHost(), engine: sampleEngine(),
                overview: sampleOverview(), projectDocument: nil)
        }
    }

    // MARK: - 7. Store-level round trip

    @Test("ProjectStore.writeFeedbackBundle drives the reporter end to end")
    func storeRoundTrip() throws {
        let out = tempDir("out"); let crashes = tempDir("crashes")
        let store = ProjectStore()
        store.diagnostics.outputDir = out
        store.diagnostics.crashReportsDir = crashes
        store.diagnostics.clock = { Date(timeIntervalSince1970: 1_700_000_000) }
        store.addTrack(name: "Drums")

        // Default: no project snapshot, headless engine reads idle/zero.
        let lean = try store.writeFeedbackBundle(includeProject: false)
        #expect(lean.includesProject == false)
        #expect(exists(URL(fileURLWithPath: lean.path)))
        let leanEngineURL = URL(fileURLWithPath: lean.path).appendingPathComponent("engine.json")
        let engine = try JSONDecoder().decode(EngineDiagnostics.self, from: Data(contentsOf: leanEngineURL))
        #expect(engine.watchdog == .idle)
        #expect(engine.performance == .idle)

        // Opt-in: the full snapshot lands and round-trips the added track.
        let full = try store.writeFeedbackBundle(includeProject: true)
        #expect(full.includesProject == true)
        let projJSON = URL(fileURLWithPath: full.path)
            .appendingPathComponent("project.dawproject").appendingPathComponent("project.json")
        #expect(exists(projJSON))
        let overviewURL = URL(fileURLWithPath: full.path).appendingPathComponent("overview.json")
        let overview = try JSONDecoder().decode(ProjectOverview.self, from: Data(contentsOf: overviewURL))
        #expect(overview.tracks.contains { $0.name == "Drums" })
    }
}
