import Foundation
import Testing
@testable import DAWCore

/// `./scripts/test.sh` used to write real audio into the USER'S REAL
/// `~/Library/Application Support/DAWPro/Generations/` — 2751 `bounce-<hex>.wav`
/// files, 1.8 GB, growing by ~3 per full-suite run — and real copies into their
/// `References/` (`orch-clicks.wav`, `orch-sine-2.wav`, no longer accruing).
///
/// Both directories were already reachable through a documented public seam
/// ("tests point it at temp dirs"), and 13 test files DO set it. The defect was
/// that the seam was **opt-IN**: any test that forgot wrote to the user's disk.
/// The two writers — `bounceInPlace` (`ProjectStore+Bounce.swift`) and
/// `copyGeneratedAudioToStableLocation` / `importReference`
/// (`ProjectStore+Generation.swift`, `+Reference.swift`) — all read the
/// PROPERTY, so making the DEFAULT safe fixes every writer at once. Enumerating
/// and patching only today's forgetful call sites would leave the trap armed for
/// the next author, exactly as the m23-aa autosave filing found.
///
/// This is the third instance of one shape: `ProjectStore.autosaveRecoveryDefault()`
/// (m23-aa, Autosave) and `DiagnosticsReporter.outputDirDefault()` (m23-aq,
/// Feedback). Section 2 pins the property this one does NOT share with them —
/// Generations and References stay SIBLINGS under one redirected `DAWPro/`.
///
/// **Never touches the real profile.** Every assertion works off the redirected
/// root's own shape, or off pure URL math that reads no disk. Proving the guard
/// must not require polluting the thing it protects.
@MainActor
@Suite("Media-import default redirection — Generations + References")
struct MediaImportsRedirectionTests {

    // MARK: - 1. The redirected defaults, observed from inside THIS test process

    @Test("this process is detected, so the Generations default is redirected away from the real profile")
    func generationsDefaultIsRedirected() {
        let redirected = ProjectStore.generationImportsDefault()
        let real = ProjectStore.defaultGenerationImportsDirectory()

        #expect(redirected != real)
        // Structural, not coincidental: the real Application Support path must
        // not even be a PREFIX of the redirected one.
        #expect(!redirected.path.hasPrefix(real.path))
        #expect(redirected.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        // Still the SAME path math as production — `.../DAWPro/Generations` tail
        // — just rooted elsewhere, proving this reuses
        // `AppDirectories.applicationSupport(_:systemBase:)` rather than
        // hand-rolling a second computation.
        #expect(redirected.lastPathComponent == "Generations")
        #expect(redirected.deletingLastPathComponent().lastPathComponent == "DAWPro")
    }

    @Test("the References default is redirected the same way")
    func referencesDefaultIsRedirected() {
        let redirected = ProjectStore.referenceImportsDefault()
        let real = ProjectStore.defaultReferenceImportsDirectory()

        #expect(redirected != real)
        #expect(!redirected.path.hasPrefix(real.path))
        #expect(redirected.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(redirected.lastPathComponent == "References")
        #expect(redirected.deletingLastPathComponent().lastPathComponent == "DAWPro")
    }

    @Test("both redirected roots are created eagerly, before anything imports into them")
    func redirectedRootsExistEagerly() {
        for root in [ProjectStore.generationImportsDefault(),
                     ProjectStore.referenceImportsDefault()] {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.path,
                                                        isDirectory: &isDirectory)
            #expect(exists, "\(root.lastPathComponent) root must exist before first write")
            #expect(isDirectory.boolValue)
        }
    }

    @Test("repeated calls in this process agree — one shared root each, matching production's sharing shape")
    func redirectedRootsAreStablePerProcess() {
        #expect(ProjectStore.generationImportsDefault() == ProjectStore.generationImportsDefault())
        #expect(ProjectStore.referenceImportsDefault() == ProjectStore.referenceImportsDefault())
    }

    // MARK: - 2. The pair stays a PAIR (the one departure from the Feedback precedent)

    /// In production these two are siblings under one `DAWPro/` parent — the
    /// reference home is documented as "the Generations sibling" (m22-g design
    /// §3.3). Two independent UUID temp bases would silently break that under
    /// test while leaving it true in the shipped app, so the redirection shares
    /// ONE base. (`DiagnosticsReporter.testOutputDirRoot` gets its own root on
    /// purpose — in production Feedback cohabits with nothing.)
    @Test("redirected Generations and References remain siblings, exactly as in production")
    func redirectedRootsAreSiblings() {
        let generations = ProjectStore.generationImportsDefault()
        let references = ProjectStore.referenceImportsDefault()
        #expect(generations != references)
        #expect(generations.deletingLastPathComponent()
            == references.deletingLastPathComponent())

        // The relationship being mirrored, computed on the real (unredirected)
        // producers — pure URL math, no disk access.
        #expect(ProjectStore.defaultGenerationImportsDirectory().deletingLastPathComponent()
            == ProjectStore.defaultReferenceImportsDirectory().deletingLastPathComponent())
    }

    // MARK: - 3. A bare store — the trap shape — picks the redirection up

    @Test("a freshly constructed store lands both import homes outside the real profile, zero configuration")
    func freshStoreDefaultsToTheRedirectedRoots() {
        let store = ProjectStore()      // no seam override: the shape that leaked

        #expect(store.generationImportsDirectory == ProjectStore.generationImportsDefault())
        #expect(store.referenceImportsDirectory == ProjectStore.referenceImportsDefault())

        // The acceptance criterion, restated as an assertion: nothing this store
        // writes can land under the user's real Application Support tree. Checked
        // against the PARENT (`.../DAWPro`), so a future category added under it
        // cannot slip through by not being one of these two.
        let realProfileRoot = ProjectStore.defaultGenerationImportsDirectory()
            .deletingLastPathComponent().path
        #expect(!store.generationImportsDirectory.path.hasPrefix(realProfileRoot))
        #expect(!store.referenceImportsDirectory.path.hasPrefix(realProfileRoot))
    }

    // MARK: - 4. Production path math is UNCHANGED

    /// The always-real producers must still resolve to EXACTLY today's URL.
    /// Rebuilt here from Foundation's own resolver rather than compared against
    /// `AppDirectories` — `AppDirectoriesTests.migratedEntryPointsResolveTheirCategories`
    /// already pins them equal to `AppDirectories.applicationSupport(.generations/.references)`,
    /// which is the same computation on both sides of the `==`. This leg is the
    /// independent one: if the redirection had been folded INTO these producers
    /// (the tempting one-line "fix"), this test would fail here.
    @Test("the unredirected producers still resolve to today's real Application Support URLs")
    func productionProducersAreUntouched() throws {
        let base = try #require(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first)
        let expectedGenerations = base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("Generations", isDirectory: true)
        let expectedReferences = base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("References", isDirectory: true)

        #expect(ProjectStore.defaultGenerationImportsDirectory() == expectedGenerations)
        #expect(ProjectStore.defaultReferenceImportsDirectory() == expectedReferences)
    }

    /// The layering argument, completed. `generationImportsDefault()` is
    /// `testRoot ?? defaultGenerationImportsDirectory()`, and the ONLY thing that
    /// decides which side runs is `TestEnvironment.isRunningTests`. This leg pins
    /// that it is true HERE; that it is false for the shipped app's process shape
    /// is pinned by `AutosaveRecoveryRedirectionTests.doesNotFlagTheShippedApp`.
    /// Together: production takes the `??` right-hand side, which the test above
    /// shows is today's real URL.
    @Test("the redirection is gated on the test-process predicate, which is true here and false for the app")
    func redirectionIsGatedOnTheTestPredicate() {
        #expect(TestEnvironment.isRunningTests)
        #expect(!TestEnvironment.isSwiftTestProcess(
            processName: "DAWApp",
            arguments: ["/Applications/DAW Pro.app/Contents/MacOS/DAWApp"]))
    }

    // MARK: - 5. Guard-proving: the real writers, on stores that never mention the seam

    /// `copyGeneratedAudioToStableLocation` is the shared landing helper behind
    /// `importGeneration` and `importClipFix`. Exercised on a store that never
    /// touches `generationImportsDirectory` — i.e. the exact shape of every test
    /// that forgot. `bounceInPlace`, the writer that produced the 2751
    /// `bounce-<hex>.wav` files, writes through the SAME property (it reads
    /// `generationImportsDirectory` directly), so the bare-store default pinned
    /// in section 3 covers it without standing up an offline-render fake here.
    @Test("a bare store's generated-audio copy lands in the redirected root, never in the real Generations")
    func generatedAudioCopyLandsInTheRedirectedRoot() throws {
        let store = ProjectStore()              // no seam override
        let source = try Self.makeThrowawayFile(named: "source.wav")
        defer { try? FileManager.default.removeItem(at: source) }

        let landed = try store.copyGeneratedAudioToStableLocation(
            from: source, jobID: "redirect-probe-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: landed) }

        #expect(landed.deletingLastPathComponent().standardizedFileURL
            == store.generationImportsDirectory.standardizedFileURL)
        #expect(!landed.path.hasPrefix(ProjectStore.defaultGenerationImportsDirectory().path))
        #expect(FileManager.default.fileExists(atPath: landed.path))
    }

    /// The other confirmed spiller: `reference.import` COPIES its source into the
    /// References home. Same trap shape — a store that never sets the seam.
    @Test("a bare store's reference import lands in the redirected root, never in the real References")
    func referenceImportLandsInTheRedirectedRoot() async throws {
        let store = ProjectStore()              // no seam override
        store.media = FakeMedia()               // engine stays nil: analysis is skipped with a warning
        let source = try Self.makeThrowawayFile(named: "Redirect Probe.wav")
        defer { try? FileManager.default.removeItem(at: source) }

        let outcome = try await store.importReference(path: source.path)
        let landed = URL(fileURLWithPath: outcome.slot.sourcePath)
        defer { try? FileManager.default.removeItem(at: landed) }

        #expect(landed.deletingLastPathComponent().standardizedFileURL
            == store.referenceImportsDirectory.standardizedFileURL)
        #expect(!landed.path.hasPrefix(ProjectStore.defaultReferenceImportsDirectory().path))
        #expect(FileManager.default.fileExists(atPath: landed.path))
        // Copied, never moved — the original survives (m22-g import law).
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    /// A throwaway "audio" file in the system temp dir — bytes only; `FakeMedia`
    /// never reads them. Deliberately NOT in either redirected root, so the
    /// assertions above distinguish "the importer copied it there" from "it was
    /// already there".
    private static func makeThrowawayFile(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-imports-redirect-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01]).write(to: url)
        return url
    }
}
