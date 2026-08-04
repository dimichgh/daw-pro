import Foundation
import Testing
@testable import DAWCore

/// m23-aq: two MORE instance defaults resolved the user's REAL data directory,
/// armed only by call-site discipline — the exact shape m23-aa removed for
/// `ProjectStore.autosaveRecoveryDirectory` (see `AutosaveRecoveryRedirectionTests`).
///
/// (1) `ProjectStore.crashRecovery` (an `AutosaveManager`) used to
/// default-construct via `AutosaveManager()`'s OWN bare default
/// (`AutosaveManager.defaultDirectory()` — the real
/// `~/Library/Application Support/DAWPro/Autosave/`). It now constructs with
/// an explicit `directory: ProjectStore.autosaveRecoveryDefault()` — the SAME
/// per-process redirected root `autosaveRecoveryDirectory` already uses, since
/// in production both resolve to the identical directory (the rolling
/// `autosave.dawproject` snapshot and the legacy per-slug `Untitled-*.dawproj`
/// bundles cohabit one folder, per `AutosaveManager.swift`'s own layout doc).
/// Deliberately NOT fixed by touching `AutosaveManager.init`'s own default:
/// `AppDirectoriesTests.autosaveManagerDefaultArgumentMatches` pins a bare,
/// directly-constructed `AutosaveManager()` to the REAL directory even inside
/// this test process, so the redirection lives one level above that, at the
/// `ProjectStore.crashRecovery` call site only.
///
/// (2) `DiagnosticsReporter.outputDir` used to default via
/// `DiagnosticsReporter.defaultOutputDir()` (the real
/// `~/Library/Application Support/DAWPro/Feedback/`). It now defaults via a
/// NEW `DiagnosticsReporter.outputDirDefault()`, redirected under a detected
/// test process exactly like `autosaveRecoveryDefault()` — but to its OWN
/// per-process temp root, since `.feedback` does not cohabit with anything
/// else in production.
///
/// Every assertion here works off the redirected roots' own shape (are they
/// under a temp directory? do they differ from the real path? does a write
/// land inside them?) — never the real profile — proving the guard must never
/// require polluting the thing it protects.
@Suite("Crash-recovery + feedback default redirection (m23-aq)")
struct CrashRecoveryFeedbackRedirectionTests {

    // MARK: - 1. crashRecovery reuses autosaveRecoveryDefault()'s per-process root

    @Test("a bare store's crashRecovery.directory is redirected away from the real Autosave path")
    @MainActor
    func crashRecoveryDirectoryIsRedirected() {
        let store = ProjectStore()
        let real = ProjectStore.defaultAutosaveDirectory()

        #expect(store.crashRecovery.directory != real)
        // Structural, not coincidental: the real path must not even be a
        // PREFIX of the redirected one.
        #expect(!store.crashRecovery.directory.path.hasPrefix(real.path))
        #expect(store.crashRecovery.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test("crashRecovery.directory and autosaveRecoveryDirectory cohabit the SAME redirected root, mirroring production")
    @MainActor
    func crashRecoveryShareRootWithUntitledRecovery() {
        let store = ProjectStore()
        #expect(store.crashRecovery.directory == store.autosaveRecoveryDirectory)
        #expect(store.crashRecovery.directory == ProjectStore.autosaveRecoveryDefault())
    }

    @Test("a fresh store built in the same process agrees with an earlier one — one shared root")
    @MainActor
    func crashRecoveryRootIsStablePerProcess() {
        let a = ProjectStore()
        let b = ProjectStore()
        #expect(a.crashRecovery.directory == b.crashRecovery.directory)
    }

    /// Exercises the EXACT mechanism that used to leak (`autosaveTick()` after a
    /// journaled edit — `CrashRecoveryTests`' own `dirtyTrackingGatesTheWrite`
    /// shape) on a store that never once mentions `crashRecovery.directory`.
    @Test("a bare store's autosaveTick() after a journaled edit writes only into the redirected root")
    @MainActor
    func autosaveTickWritesOnlyIntoTheRedirectedRoot() async {
        let store = ProjectStore()          // no crashRecovery.directory override — the trap shape
        store.media = FakeMedia()
        let root = store.crashRecovery.directory
        #expect(root != ProjectStore.defaultAutosaveDirectory())   // still redirected

        store.addTrack(name: "Leaked")      // dirties + journals an edit
        await store.autosaveTick()

        let bundle = store.crashRecovery.autosaveBundleURL
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(bundle.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }

    // MARK: - 2. DiagnosticsReporter.outputDir gets its own redirected root

    @Test("a bare DiagnosticsReporter's outputDir is redirected away from the real Feedback path")
    @MainActor
    func diagnosticsOutputDirIsRedirected() {
        let reporter = DiagnosticsReporter()
        let real = DiagnosticsReporter.defaultOutputDir()

        #expect(reporter.outputDir != real)
        #expect(!reporter.outputDir.path.hasPrefix(real.path))
        #expect(reporter.outputDir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        // Same path math as production — `.../DAWPro/Feedback` tail — just
        // rooted elsewhere.
        #expect(reporter.outputDir.lastPathComponent == "Feedback")
        #expect(reporter.outputDir.deletingLastPathComponent().lastPathComponent == "DAWPro")
    }

    @Test("the redirected Feedback root is created eagerly, before any reporter writes into it")
    @MainActor
    func diagnosticsRedirectedRootExistsEagerly() {
        let root = DiagnosticsReporter.outputDirDefault()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test("repeated calls in this process agree — one shared Feedback root")
    @MainActor
    func diagnosticsRedirectedRootIsStablePerProcess() {
        #expect(DiagnosticsReporter.outputDirDefault() == DiagnosticsReporter.outputDirDefault())
    }

    @Test("the Feedback test root is DISTINCT from the Autosave test root — separate categories, separate roots")
    @MainActor
    func diagnosticsRootDoesNotCohabitWithAutosave() {
        #expect(DiagnosticsReporter.outputDirDefault() != ProjectStore.autosaveRecoveryDefault())
    }

    @Test("a bare, freshly constructed store picks up the redirected Feedback default with zero configuration")
    @MainActor
    func freshStoreDiagnosticsDefaultsToTheRedirectedRoot() {
        let store = ProjectStore()
        #expect(store.diagnostics.outputDir == DiagnosticsReporter.outputDirDefault())
        #expect(store.diagnostics.outputDir != DiagnosticsReporter.defaultOutputDir())
    }

    /// Exercises the EXACT mechanism that used to leak (`writeFeedbackBundle` via
    /// `app.feedbackBundle`) on a store that never once mentions
    /// `diagnostics.outputDir` — the shape `FeedbackBundleCommandTests.makeRouter()`
    /// currently avoids only by remembering to override it.
    @Test("a bare store's writeFeedbackBundle writes only into the redirected Feedback root")
    @MainActor
    func writeFeedbackBundleWritesOnlyIntoTheRedirectedRoot() throws {
        let store = ProjectStore()          // no diagnostics.outputDir override — the trap shape
        let root = store.diagnostics.outputDir
        #expect(root != DiagnosticsReporter.defaultOutputDir())   // still redirected

        let summary = try store.writeFeedbackBundle(includeProject: false)
        let bundleURL = URL(fileURLWithPath: summary.path)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(bundleURL.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }
}
