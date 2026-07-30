import Foundation
import Testing
@testable import DAWCore

/// m23-aa: `./scripts/test.sh` used to write real `Untitled-<slug>.dawproj`
/// crash-recovery bundles into the USER'S REAL
/// `~/Library/Application Support/DAWPro/Autosave/` whenever a test constructed a
/// bare `ProjectStore()`, dirtied it, and reached `flushForTransition()` (a dirty
/// untitled `newProject()`/`openProject()`) or `autosaveIfNeeded()` WITHOUT
/// explicitly overriding `autosaveRecoveryDirectory` first. The four suites named
/// by the m23-r4 filing were not the whole story — ~25 more files across
/// DAWCoreTests (22) / DAWEngineTests (2) / DAWAppKitTests (1) call
/// `newProject()`/`openProject()`/`autosaveIfNeeded()` without ever mentioning
/// the property. They are CANDIDATES, not confirmed leakers — `flushForTransition`
/// only writes when the store is `isDirty || chatsDirty` AND untitled
/// (`projectPath == nil`) at the call, and each file was not individually traced
/// to that state. Enumerating and patching only the confirmed subset would still
/// leave the trap armed for the next author (and for any of these 25 whose dirty
/// state changes later); this suite pins the structural fix instead: the DEFAULT
/// is now safe in a detected Swift test process, regardless of which call sites
/// actually reach it today.
///
/// **Never touches the real profile.** Every assertion here works off the
/// redirected root's own shape (is it under a temp directory? does it differ from
/// the real path? does a write land inside it?) — proving the guard must never
/// require polluting the thing it protects.
@Suite("Autosave-recovery default redirection (m23-aa)")
struct AutosaveRecoveryRedirectionTests {

    // MARK: - 1. The pure detector, with injected process facts (no real process swap)

    @Test("the exact argv this project's ./scripts/test.sh launches under is detected as a test process")
    func detectsThisProjectsActualTestHarnessShape() {
        // Captured verbatim from a live `swift test --disable-xctest` run
        // (`swiftpm-testing-helper`), so this is not a guess at the shape.
        let arguments = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper",
            "--test-bundle-path",
            "/Users/dev/daw-pro/.build/arm64-apple-macosx/debug/daw-proPackageTests.xctest/Contents/MacOS/daw-proPackageTests",
            "--disable-xctest",
            "--filter", "SomeSuite",
            "/Users/dev/daw-pro/.build/arm64-apple-macosx/debug/daw-proPackageTests.xctest/Contents/MacOS/daw-proPackageTests",
            "--testing-library", "swift-testing",
        ]
        #expect(TestEnvironment.isSwiftTestProcess(
            processName: "swiftpm-testing-helper", arguments: arguments))
    }

    @Test("the shipped app's process shape is NOT detected as a test process")
    func doesNotFlagTheShippedApp() {
        #expect(!TestEnvironment.isSwiftTestProcess(
            processName: "DAWApp",
            arguments: ["/Applications/DAW Pro.app/Contents/MacOS/DAWApp"]))
    }

    @Test("an unrelated process (e.g. the shell) is NOT detected as a test process")
    func doesNotFlagAnUnrelatedProcess() {
        #expect(!TestEnvironment.isSwiftTestProcess(processName: "zsh", arguments: ["-zsh"]))
    }

    @Test("an .xctest bundle path anywhere in argv is sufficient (the Xcode/plain-XCTest shape)")
    func detectsAnXCTestBundlePath() {
        #expect(TestEnvironment.isSwiftTestProcess(
            processName: "xctest",
            arguments: ["/usr/bin/xctest", "SomePackageTests.xctest"]))
    }

    @Test("the --testing-library flag alone is sufficient")
    func detectsTheTestingLibraryFlag() {
        #expect(TestEnvironment.isSwiftTestProcess(
            processName: "some-other-runner",
            arguments: ["run", "--testing-library", "swift-testing"]))
    }

    @Test("neither signal present, and the process name doesn't match, is NOT a test process")
    func requiresAtLeastOneSignal() {
        #expect(!TestEnvironment.isSwiftTestProcess(
            processName: "DAWApp", arguments: ["--verbose", "--headless"]))
    }

    // MARK: - 2. The redirected default, observed from inside THIS actual test process

    @Test("this test process is itself detected, so the default is redirected away from the real profile")
    @MainActor
    func defaultIsRedirectedInThisProcess() {
        let redirected = ProjectStore.autosaveRecoveryDefault()
        let real = ProjectStore.defaultAutosaveDirectory()

        #expect(redirected != real)
        // Structural, not coincidental: the real Application Support path must
        // not even be a PREFIX of the redirected one.
        #expect(!redirected.path.hasPrefix(real.path))
        #expect(redirected.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        // Still the SAME path math as production — `.../DAWPro/Autosave` tail —
        // just rooted elsewhere, proving this is `applicationSupport(_:systemBase:)`
        // reused, not a second hand-rolled computation.
        #expect(redirected.lastPathComponent == "Autosave")
        #expect(redirected.deletingLastPathComponent().lastPathComponent == "DAWPro")
    }

    @Test("the redirected root is created eagerly, before any store writes into it")
    @MainActor
    func redirectedRootExistsEagerly() {
        let redirected = ProjectStore.autosaveRecoveryDefault()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: redirected.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test("repeated calls in this process agree — one shared root, matching production's sharing shape")
    @MainActor
    func redirectedRootIsStablePerProcess() {
        #expect(ProjectStore.autosaveRecoveryDefault() == ProjectStore.autosaveRecoveryDefault())
    }

    @Test("a bare, freshly constructed store picks up the redirected default with zero configuration")
    @MainActor
    func freshStoreDefaultsToTheRedirectedRoot() {
        let store = ProjectStore()
        #expect(store.autosaveRecoveryDirectory == ProjectStore.autosaveRecoveryDefault())
        #expect(store.autosaveRecoveryDirectory != ProjectStore.defaultAutosaveDirectory())
    }

    // MARK: - 3. Guard-proving: the actual leak mechanism, run only against the redirected root

    /// Exercises the EXACT mechanism that used to leak (`flushForTransition` via a
    /// dirty untitled `newProject()`) on a store that never once mentions
    /// `autosaveRecoveryDirectory` — i.e. reproduces the shape of every one of the
    /// ~25 additional candidate call sites found beyond the four named by the
    /// filing. Never inspects or depends on the real directory: only the
    /// redirected root, which this process's own default already points at.
    @Test("a bare store that dirties and calls newProject() writes its recovery bundle into the redirected root only")
    @MainActor
    func dirtyUntitledTransitionWritesOnlyIntoTheRedirectedRoot() throws {
        let store = ProjectStore()          // no autosaveRecoveryDirectory override — the trap shape
        store.media = FakeMedia()
        let root = store.autosaveRecoveryDirectory
        #expect(root != ProjectStore.defaultAutosaveDirectory())   // still redirected

        store.addTrack(name: "Leaked")      // dirties the untitled session
        try store.newProject()              // flushForTransition → writeRecoveryBundle()

        // The root is shared per-process (mirroring production — see
        // `testAutosaveRoot`), so other tests' bundles may cohabit it when
        // swift-testing parallelizes; identify THIS store's own by session,
        // not by counting the whole directory.
        let own = store.untitledRecoveryBundles().first { $0.isCurrentSession }
        #expect(own != nil, "the flushed recovery bundle must land in the redirected root")
        #expect(own.map {
            URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL
        } == true)
    }

    /// Same shape via `autosaveIfNeeded()` — the OTHER writer named by the
    /// defect (`ProjectStore.swift`'s untitled-recovery path), reached by the
    /// background autosave tick rather than a project transition.
    @Test("a bare store's autosaveIfNeeded() also writes only into the redirected root")
    @MainActor
    func autosaveIfNeededWritesOnlyIntoTheRedirectedRoot() {
        let store = ProjectStore()
        store.media = FakeMedia()
        let root = store.autosaveRecoveryDirectory
        #expect(root != ProjectStore.defaultAutosaveDirectory())

        store.addTrack(name: "Ticked")
        store.autosaveIfNeeded()

        let own = store.untitledRecoveryBundles().first { $0.isCurrentSession }
        #expect(own != nil)
        #expect(own.map {
            URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL
        } == true)
    }
}
