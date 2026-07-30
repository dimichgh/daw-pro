import Foundation
import Testing
@testable import DAWCore

/// m23-n1b — the Application-Support path rule now has ONE home.
///
/// **What these tests may and may not assert.** The BASE is resolved by
/// `FileManager` and is environment-dependent: a sandboxed build is redirected to
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support`, the
/// SwiftPM test runner gets `~/Library/Application Support`. So every assertion
/// about the base goes through the SAME resolver the helper uses — a literal
/// `"/Users/…"` expectation would be wrong by construction.
///
/// The `DAWPro/<Category>` TAIL is the opposite: it is a fixed product decision
/// and existing installs have real files under those exact names, so the category
/// strings ARE pinned as literals. That pin is this suite's discriminator — the
/// base block was copied verbatim from nine byte-identical originals, so the only
/// realistic way this refactor can move a user's data is a mistyped category.
@Suite("AppDirectories — one home for the Application-Support rule")
struct AppDirectoriesTests {

    // MARK: - The category pin (the discriminator)

    @Test("Every category's on-disk name is pinned; the set is closed")
    func categoryNamesArePinned() {
        // Written out longhand, deliberately: this is the table an install's
        // existing directories are named after. A rename here orphans user data.
        let expected: [AppDirectories.Category: String] = [
            .recordings: "Recordings",
            .autosave: "Autosave",
            .generations: "Generations",
            .references: "References",
            .soundBanks: "SoundBanks",
            .feedback: "Feedback",
            .voiceDatasets: "VoiceDatasets",
            .models: "Models",
        ]
        // Closed set: a NEW category must be added to the pin above, so it can
        // never be introduced without someone reading this table.
        #expect(Set(AppDirectories.Category.allCases) == Set(expected.keys))
        for (category, name) in expected {
            #expect(category.directoryName == name)
            #expect(category.rawValue == name)
            #expect(
                AppDirectories.applicationSupport(category).lastPathComponent == name,
                "category \(category) must land in a directory named \(name)")
        }
    }

    @Test("Category directory names are distinct")
    func categoryNamesAreDistinct() {
        let names = AppDirectories.Category.allCases.map(\.directoryName)
        #expect(Set(names).count == names.count)
    }

    // MARK: - Structure, asserted against the resolver

    @Test("Each category is <resolved Application Support>/DAWPro/<Category>/")
    func resolvesUnderTheSystemApplicationSupportDirectory() throws {
        // The SAME resolver the helper uses — never a hardcoded absolute path.
        let systemBase = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory,
                                     in: .userDomainMask).first,
            "no Application Support directory on this machine")

        for category in AppDirectories.Category.allCases {
            let url = AppDirectories.applicationSupport(category)
            #expect(url.lastPathComponent == category.directoryName)
            let productDir = url.deletingLastPathComponent()
            #expect(productDir.lastPathComponent == "DAWPro")
            #expect(productDir.deletingLastPathComponent().standardizedFileURL
                == systemBase.standardizedFileURL)
            #expect(url.hasDirectoryPath, "must be minted as a directory URL")
        }
    }

    @Test("All categories are siblings under one product directory")
    func categoriesAreSiblings() {
        let parents = Set(
            AppDirectories.Category.allCases
                .map { AppDirectories.applicationSupport($0).deletingLastPathComponent() })
        #expect(parents.count == 1,
                "every category must hang off ONE DAWPro directory, not several")
    }

    @Test("Two different categories share a base and differ only in the tail")
    func twoCategoriesShareTheirBase() {
        let banks = AppDirectories.applicationSupport(.soundBanks)
        let feedback = AppDirectories.applicationSupport(.feedback)
        #expect(banks != feedback)
        #expect(banks.deletingLastPathComponent() == feedback.deletingLastPathComponent())
    }

    @Test("The resolver is stable across calls")
    func repeatedCallsAgree() {
        #expect(AppDirectories.applicationSupport(.autosave)
            == AppDirectories.applicationSupport(.autosave))
    }

    // MARK: - The fallback branch (the `??` precedence, preserved verbatim)

    @Test("A supplied base is used verbatim")
    func suppliedBaseIsUsedVerbatim() {
        let base = URL(fileURLWithPath: "/private/tmp/n1b-base", isDirectory: true)
        let url = AppDirectories.applicationSupport(.generations, systemBase: base)
        #expect(url.standardizedFileURL
            == base.appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("Generations", isDirectory: true)
                .standardizedFileURL)
    }

    /// The original nine copies all read
    /// `…urls(…).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")`,
    /// which binds as `first ?? (home + "Library/Application Support")` because
    /// member access binds tighter than `??`. A well-meant paren "fix" would make
    /// the fallback the bare HOME directory. This test fails if that happens.
    @Test("With no system Application Support dir, the fallback is HOME/Library/Application Support — not HOME")
    func fallbackKeepsTheLibraryApplicationSupportSuffix() {
        let url = AppDirectories.applicationSupport(.soundBanks, systemBase: nil)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let expected = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("SoundBanks", isDirectory: true)
        #expect(url.standardizedFileURL == expected.standardizedFileURL)
        // The load-bearing half, stated separately so a failure names the cause:
        // "Application Support" must still be in the path.
        #expect(url.path.contains("Library/Application Support/DAWPro/SoundBanks"))
        #expect(url.path != home.appendingPathComponent("DAWPro/SoundBanks").path)
    }

    // MARK: - The Autosave agreement (m23-n1b's second finding)

    /// `ProjectStore.defaultAutosaveDirectory()` and
    /// `AutosaveManager.defaultDirectory()` used to compute `DAWPro/Autosave`
    /// INDEPENDENTLY: the manager writes the rolling snapshot there and the store
    /// scans the same directory for legacy per-slug recovery bundles, so a
    /// divergence would silently mean "autosaves are written but never offered".
    /// They now agree by construction — the store delegates to the manager, which
    /// is the only producer. This test reddens if either is ever re-opened with
    /// its own computation that drifts.
    @Test("ProjectStore and AutosaveManager resolve the SAME autosave directory")
    @MainActor
    func autosaveDirectoriesAgree() {
        let fromStore = ProjectStore.defaultAutosaveDirectory()
        let fromManager = AutosaveManager.defaultDirectory()
        #expect(fromStore == fromManager)
        #expect(fromStore == AppDirectories.applicationSupport(.autosave))
        #expect(fromStore.lastPathComponent == "Autosave")
    }

    /// The manager's `public init` default argument is the same producer — this
    /// pins that the DEFAULT-constructed manager (what the app ships with) reads
    /// and writes the directory the store scans. Construction alone touches no
    /// disk, so this is safe to run against the real profile path.
    @Test("A default-constructed AutosaveManager lands in that same directory")
    @MainActor
    func autosaveManagerDefaultArgumentMatches() {
        let manager = AutosaveManager()
        #expect(manager.directory == AppDirectories.applicationSupport(.autosave))
    }

    // MARK: - The migrated call sites still name their own category

    @Test("Migrated DAWCore entry points resolve their documented categories")
    @MainActor
    func migratedEntryPointsResolveTheirCategories() {
        #expect(SoundBankLibrary.defaultLibraryDirectory()
            == AppDirectories.applicationSupport(.soundBanks))
        #expect(DiagnosticsReporter.defaultOutputDir()
            == AppDirectories.applicationSupport(.feedback))
        #expect(ProjectStore.defaultGenerationImportsDirectory()
            == AppDirectories.applicationSupport(.generations))
        #expect(ProjectStore.defaultReferenceImportsDirectory()
            == AppDirectories.applicationSupport(.references))
    }
}
