import Foundation
import Testing
@testable import AIServices

// MARK: - Fixture

/// Builds a Hub-shaped download and a catalog-shaped `Models/` root in a temp
/// directory, with NO NETWORK ANYWHERE.
///
/// This is possible — and is the whole reason the m23-n3a gate can be offline —
/// because `WhisperModelCatalog.componentURL` bottoms out at
/// `FileManager.fileExists` on `<name>.mlmodelc`
/// (`WhisperModelCatalog.swift:433-440`), i.e. directory EXISTENCE only. So
/// EMPTY directories named for `requiredComponents`, plus a `tokenizer.json`,
/// make the catalog report a model "usable" without a single byte of real
/// weights.
///
/// That is also exactly why `inspect` cannot be the installer's atomicity guard,
/// and this fixture is the proof: it passes `inspect` while containing nothing.
///
/// Never points at the real profile path — the user's 1.5 GB
/// `openai_whisper-large-v3-v20240930_turbo` install must not be reachable from
/// a test run.
private struct InstallFixture {
    let root: URL
    /// The `Models` root — what both the installer and the catalog point at.
    let modelsDirectory: URL
    /// Where a `WhisperKit.download(downloadBase:)` would have written.
    let downloadBase: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-installer-\(UUID().uuidString)")
        modelsDirectory = root.appendingPathComponent("Models", isDirectory: true)
        downloadBase = root.appendingPathComponent("staged-hub", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }

    var installer: WhisperModelInstaller {
        WhisperModelInstaller(modelsDirectory: modelsDirectory)
    }

    var catalog: WhisperModelCatalog { WhisperModelCatalog(searchRoot: modelsDirectory) }

    /// The installed location of a variant, computed the way the installer
    /// computes it (from its own standardized root), so path comparisons are not
    /// at the mercy of `/private` symlink normalization under `/var/folders`.
    func installedFolder(_ variant: String) -> URL {
        installer.modelsDirectory.appendingPathComponent(variant, isDirectory: true)
    }

    @discardableResult
    func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ url: URL, bytes: Int) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A variant folder exactly where `HubApi.localRepoLocation` puts one:
    /// `<downloadBase>/models/<repo-id>/<variant>/`. Component directories are
    /// EMPTY — see the type note.
    @discardableResult
    func stageHubDownload(
        variant: String,
        base: URL? = nil,
        omitting: String? = nil
    ) throws -> URL {
        let folder = WhisperModelInstaller.hubLayoutModelFolder(
            downloadBase: base ?? downloadBase, variantDirectoryName: variant)
        for component in WhisperModelCatalog.requiredComponents where component != omitting {
            try makeDirectory(folder.appendingPathComponent("\(component).mlmodelc"))
        }
        try write(folder.appendingPathComponent("config.json"), bytes: 3)
        return folder
    }

    /// A tokenizer where `ModelUtilities.loadTokenizer(tokenizerFolder:)` leaves
    /// one: `<base>/models/<tokenizer-repo-id>/`.
    @discardableResult
    func stageTokenizer(repoID: String, base: URL? = nil) throws -> URL {
        var folder = (base ?? downloadBase).appendingPathComponent("models", isDirectory: true)
        for part in repoID.split(separator: "/") {
            folder = folder.appendingPathComponent(String(part), isDirectory: true)
        }
        try write(folder.appendingPathComponent(WhisperModelCatalog.tokenizerFileName), bytes: 11)
        try write(folder.appendingPathComponent("tokenizer_config.json"), bytes: 5)
        return folder
    }
}

/// Compares two URLs by their fully resolved paths.
///
/// Needed because `FileManager.contentsOfDirectory` and `FileManager.enumerator`
/// hand back `/private/var/folders/…` while a URL built up from
/// `FileManager.temporaryDirectory` reads `/var/folders/…` — the same directory
/// through a symlink. `standardizedFileURL` does NOT collapse that difference;
/// only `resolvingSymlinksInPath()` does.
private func samePath(_ lhs: URL?, _ rhs: URL?) -> Bool {
    lhs?.resolvingSymlinksInPath().path == rhs?.resolvingSymlinksInPath().path
}

/// Runs `body` and hands back the error it threw, so a test can pattern-match a
/// case without pinning a whole associated-value payload (paths under
/// `/var/folders` are symlinked through `/private` and comparing them literally
/// is a flake waiting to happen).
private func captureError<T>(_ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

// MARK: - The gate

/// m23-n3a. The relocation from Hub layout into catalog layout, and the traps
/// around it. Every test here is network-free.
@Suite("Whisper model installer")
struct WhisperModelInstallerTests {

    // MARK: The layout mismatch — the whole item

    @Test("A Hub-layout download is invisible to the catalog until it is relocated")
    func hubLayoutIsInvisibleBeforeRelocation() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        // Simulate the mistake this installer exists to prevent: point the
        // download base straight at `Models/`, so the weights land at
        // `Models/models/argmaxinc/whisperkit-coreml/<variant>/`.
        let staged = try fixture.stageHubDownload(
            variant: "openai_whisper-tiny.en", base: fixture.modelsDirectory)
        try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en", base: fixture.modelsDirectory)
        #expect(FileManager.default.fileExists(atPath: staged.path))

        // A successful multi-gigabyte download that the app reports as
        // "no model installed" — silent, and only a user hits it.
        #expect(fixture.catalog.installedModels().isEmpty)
        #expect(fixture.catalog.incompleteModels().isEmpty)

        // The ONE child the scan does see is the Hub's `models/` wrapper, which
        // has no components at its own top level.
        let wrapper = fixture.modelsDirectory.appendingPathComponent("models")
        #expect(fixture.catalog.inspect(variantDirectoryAt: wrapper) == .notAModel)

        // So the teaching error says "the folder is empty" about a folder that
        // holds a whole model. That is the failure mode, stated.
        let thrown = captureError { try fixture.catalog.resolveModel() }
        guard case .noModelInstalled(_, let incomplete) = thrown as? WhisperModelError else {
            Issue.record("expected .noModelInstalled, got \(String(describing: thrown))")
            return
        }
        #expect(incomplete.isEmpty)
    }

    @Test("Relocating a Hub-layout download makes the catalog resolve it")
    func relocationMakesCatalogSeeTheModel() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let staged = try fixture.stageHubDownload(variant: "openai_whisper-tiny.en")
        let tokenizer = try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en")
        // Before: nothing.
        #expect(fixture.catalog.installedModels().isEmpty)

        let descriptor = try fixture.installer.installStagedModel(
            stagedModelFolder: staged,
            stagedTokenizerFolder: tokenizer,
            stagingRoot: fixture.downloadBase,
            overwrite: false)

        // After: an immediate child of the search root, which is the only shape
        // `candidateDirectories()` scans.
        #expect(descriptor.variantDirectoryName == "openai_whisper-tiny.en")
        #expect(descriptor.displayName == "tiny.en")
        #expect(samePath(descriptor.modelFolder, fixture.installedFolder("openai_whisper-tiny.en")))
        #expect(samePath(
            descriptor.modelFolder.deletingLastPathComponent(),
            fixture.installer.modelsDirectory))
        // The Hub wrapper is gone with the staging root — no `models/` sibling
        // left behind to be inspected as a broken variant.
        #expect(!FileManager.default.fileExists(atPath: fixture.downloadBase.path))

        let resolved = try fixture.catalog.resolveModel()
        #expect(resolved.variantDirectoryName == "openai_whisper-tiny.en")
        #expect(fixture.catalog.installedModels().count == 1)
    }

    @Test("The tokenizer lands per-variant, where WhisperKit looks first")
    func tokenizerLandsInsideTheVariant() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let staged = try fixture.stageHubDownload(variant: "openai_whisper-tiny.en")
        let tokenizer = try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en")
        let descriptor = try fixture.installer.installStagedModel(
            stagedModelFolder: staged,
            stagedTokenizerFolder: tokenizer,
            stagingRoot: fixture.downloadBase,
            overwrite: false)

        // `<variant>/tokenizer/` — the FIRST leg of
        // `tokenizerFolder(forVariantAt:)`, not the shared `Models/tokenizer/`.
        // An English-only variant cannot share a multilingual tokenizer, and
        // writing to the shared folder would clobber another variant's.
        let expected = descriptor.modelFolder.appendingPathComponent(
            WhisperModelCatalog.tokenizerDirectoryName)
        #expect(descriptor.tokenizerFolder == expected)
        #expect(WhisperModelCatalog.isTokenizerFolder(expected))
        // Nothing was written to the shared location.
        #expect(!WhisperModelCatalog.isTokenizerFolder(
            fixture.modelsDirectory.appendingPathComponent(
                WhisperModelCatalog.tokenizerDirectoryName)))
        // `tokenizer_config.json` came along too: without it
        // `LanguageModelConfigurationFromHub` yields a nil tokenizer config and
        // `ModelUtilities.loadTokenizer` falls through to the network.
        #expect(FileManager.default.fileExists(
            atPath: expected.appendingPathComponent("tokenizer_config.json").path))
    }

    @Test("A variant that brings its own tokenizer keeps it")
    func variantOwnTokenizerWins() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let staged = try fixture.stageHubDownload(variant: "openai_whisper-base")
        // A bare `tokenizer.json` beside the components — the SECOND leg of
        // `tokenizerFolder(forVariantAt:)`.
        try fixture.write(
            staged.appendingPathComponent(WhisperModelCatalog.tokenizerFileName), bytes: 2)
        let separate = try fixture.stageTokenizer(repoID: "openai/whisper-base")

        let descriptor = try fixture.installer.installStagedModel(
            stagedModelFolder: staged,
            stagedTokenizerFolder: separate,
            stagingRoot: fixture.downloadBase,
            overwrite: false)

        #expect(descriptor.tokenizerFolder == descriptor.modelFolder)
        #expect(!FileManager.default.fileExists(
            atPath: descriptor.modelFolder
                .appendingPathComponent(WhisperModelCatalog.tokenizerDirectoryName).path))
    }

    // MARK: The sort-order trap (m23-n3c will decide what to do about it)

    @Test("Installing a second variant silently changes which model transcription uses")
    func installingASecondVariantChangesTheDefault() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        // Start where the user's machine actually is today.
        let large = try fixture.stageHubDownload(
            variant: "openai_whisper-large-v3-v20240930_turbo")
        let largeTokenizer = try fixture.stageTokenizer(repoID: "openai/whisper-large-v3")
        try fixture.installer.installStagedModel(
            stagedModelFolder: large,
            stagedTokenizerFolder: largeTokenizer,
            stagingRoot: nil,
            overwrite: false)
        let firstDefault = try fixture.catalog.resolveModel()
        #expect(firstDefault.variantDirectoryName == "openai_whisper-large-v3-v20240930_turbo")

        // Add a SMALLER, alphabetically earlier variant.
        let secondBase = fixture.root.appendingPathComponent("second-download", isDirectory: true)
        let base = try fixture.stageHubDownload(
            variant: "openai_whisper-base", base: secondBase)
        let baseTokenizer = try fixture.stageTokenizer(
            repoID: "openai/whisper-base", base: secondBase)
        try fixture.installer.installStagedModel(
            stagedModelFolder: base,
            stagedTokenizerFolder: baseTokenizer,
            stagingRoot: nil,
            overwrite: false)

        // THE TRAP, PINNED. `resolveModel(nil)` is `installedModels().first`,
        // sorted by directory name, and 'b' < 'l'. So every transcription that
        // does not name a variant just switched from large-v3-turbo to base —
        // no code change, nothing red, no message. m23-n3c owns the decision to
        // make the default EXPLICIT; this test exists so that decision cannot be
        // made by accident in the meantime.
        #expect(fixture.catalog.installedModels().map(\.variantDirectoryName)
            == ["openai_whisper-base", "openai_whisper-large-v3-v20240930_turbo"])
        let secondDefault = try fixture.catalog.resolveModel()
        #expect(secondDefault.variantDirectoryName == "openai_whisper-base")
        // Naming the variant explicitly is unaffected — that is the escape hatch.
        let explicit = try fixture.catalog
            .resolveModel(named: "openai_whisper-large-v3-v20240930_turbo")
        #expect(explicit.variantDirectoryName == "openai_whisper-large-v3-v20240930_turbo")
    }

    // MARK: Staging

    @Test("A staging directory is invisible to the catalog while it fills")
    func stagingDirectoryIsHiddenFromTheScan() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let staging = try fixture.installer.makeStagingDirectory()
        #expect(staging.lastPathComponent.hasPrefix(WhisperModelInstaller.stagingDirectoryPrefix))
        #expect(staging.deletingLastPathComponent().standardizedFileURL
            == fixture.installer.modelsDirectory)

        // The DOT, pinned as a literal rather than through the constant.
        //
        // Asserting `hasPrefix(stagingDirectoryPrefix)` above is tautological —
        // it compares the name against the very constant that produced it, so it
        // stays true no matter what that constant becomes. The hidden-ness is a
        // property of the leading `.`, and `.skipsHiddenFiles` is what the whole
        // "invisible while it fills" claim rests on, so the dot is pinned here
        // directly. Verified to discriminate (m23-n3a close-out): dropping the
        // dot from `stagingDirectoryPrefix` left all 18 tests GREEN before this
        // line existed, and reddens exactly this one after.
        #expect(WhisperModelInstaller.stagingDirectoryPrefix.hasPrefix("."),
                "staging directories must be dot-prefixed or .skipsHiddenFiles cannot hide them")

        // Fill it with a complete, catalog-satisfying model — and prove the scan
        // STILL reports nothing.
        //
        // Honest note on what this leg does and does not prove: the staged model
        // lands NESTED (`<staging>/hub/models/<repo-id>/<variant>/`), so the
        // staging directory itself is `.notAModel` and would be absent from both
        // lists even if it were visible. These two expectations are therefore
        // insensitive to the dot — the assertion above is what guards it.
        let inFlight = try fixture.stageHubDownload(variant: "openai_whisper-tiny.en", base: staging)
        try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en", base: staging)
        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(fixture.catalog.installedModels().isEmpty)
        #expect(fixture.catalog.incompleteModels().isEmpty)
        let orphans = fixture.installer.orphanedStagingDirectories()
        #expect(orphans.count == 1)
        #expect(samePath(orphans.first, staging))
    }

    @Test("Staging works on a fresh machine that has no Models directory yet")
    func stagingCreatesModelsDirectory() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        #expect(!FileManager.default.fileExists(atPath: fixture.modelsDirectory.path))
        let staging = try fixture.installer.makeStagingDirectory()
        #expect(FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: fixture.modelsDirectory.path))
    }

    @Test("A successful install removes its staging directory")
    func successfulInstallSweepsStaging() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let staging = try fixture.installer.makeStagingDirectory()
        let staged = try fixture.stageHubDownload(variant: "openai_whisper-tiny.en", base: staging)
        let tokenizer = try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en", base: staging)

        try fixture.installer.installStagedModel(
            stagedModelFolder: staged,
            stagedTokenizerFolder: tokenizer,
            stagingRoot: staging,
            overwrite: false)

        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(fixture.installer.orphanedStagingDirectories().isEmpty)
        #expect(fixture.catalog.installedModels().count == 1)
    }

    @Test("An unrecognised variant name fails before anything is downloaded")
    func unrecognisedVariantFailsEarly() async throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        // No network is touched by this test because the name check happens
        // FIRST — the point of ordering it that way is not to pay for hundreds
        // of megabytes before discovering there is no tokenizer repo to match.
        await #expect(throws: WhisperModelInstallError.self) {
            _ = try await fixture.installer.install(variant: "openai_whisper-enormous")
        }
        #expect(fixture.installer.orphanedStagingDirectories().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.modelsDirectory.path))
    }

    // MARK: Overwrite

    @Test("Re-installing an existing variant refuses by default")
    func reinstallRefusesByDefault() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let first = try fixture.stageHubDownload(variant: "openai_whisper-tiny.en")
        let firstTokenizer = try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en")
        try fixture.installer.installStagedModel(
            stagedModelFolder: first,
            stagedTokenizerFolder: firstTokenizer,
            stagingRoot: nil,
            overwrite: false)
        let marker = fixture.installedFolder("openai_whisper-tiny.en")
            .appendingPathComponent("keep-me.txt")
        try fixture.write(marker, bytes: 4)

        let againBase = fixture.root.appendingPathComponent("again", isDirectory: true)
        let second = try fixture.stageHubDownload(
            variant: "openai_whisper-tiny.en", base: againBase)
        let thrown = captureError {
            try fixture.installer.installStagedModel(
                stagedModelFolder: second,
                stagedTokenizerFolder: nil,
                stagingRoot: nil,
                overwrite: false)
        }
        guard case .alreadyInstalled(let name, _) = thrown as? WhisperModelInstallError else {
            Issue.record("expected .alreadyInstalled, got \(String(describing: thrown))")
            return
        }
        #expect(name == "openai_whisper-tiny.en")
        // The refusal is a REFUSAL: the existing install is untouched, and so is
        // the staged replacement.
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("Overwrite replaces the previous install")
    func overwriteReplaces() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let first = try fixture.stageHubDownload(variant: "openai_whisper-tiny.en")
        let firstTokenizer = try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en")
        try fixture.installer.installStagedModel(
            stagedModelFolder: first,
            stagedTokenizerFolder: firstTokenizer,
            stagingRoot: nil,
            overwrite: false)
        let stale = fixture.installedFolder("openai_whisper-tiny.en")
            .appendingPathComponent("stale.txt")
        try fixture.write(stale, bytes: 4)

        let againBase = fixture.root.appendingPathComponent("again", isDirectory: true)
        let second = try fixture.stageHubDownload(
            variant: "openai_whisper-tiny.en", base: againBase)
        let secondTokenizer = try fixture.stageTokenizer(
            repoID: "openai/whisper-tiny.en", base: againBase)
        let staging = try fixture.installer.makeStagingDirectory()
        try fixture.installer.installStagedModel(
            stagedModelFolder: second,
            stagedTokenizerFolder: secondTokenizer,
            stagingRoot: staging,
            overwrite: true)

        #expect(fixture.catalog.installedModels().count == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // The displaced copy went into staging and left with it.
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(fixture.installer.orphanedStagingDirectories().isEmpty)
    }

    // MARK: Rejection + rollback

    @Test("An incomplete staged model is rejected and the previous install restored")
    func incompleteStagedModelRollsBack() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let good = try fixture.stageHubDownload(variant: "openai_whisper-tiny.en")
        let goodTokenizer = try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en")
        try fixture.installer.installStagedModel(
            stagedModelFolder: good,
            stagedTokenizerFolder: goodTokenizer,
            stagingRoot: nil,
            overwrite: false)
        let keep = fixture.installedFolder("openai_whisper-tiny.en")
            .appendingPathComponent("keep-me.txt")
        try fixture.write(keep, bytes: 4)

        // A download that made the skeleton but not the decoder.
        let brokenBase = fixture.root.appendingPathComponent("broken", isDirectory: true)
        let broken = try fixture.stageHubDownload(
            variant: "openai_whisper-tiny.en", base: brokenBase, omitting: "TextDecoder")
        let brokenTokenizer = try fixture.stageTokenizer(
            repoID: "openai/whisper-tiny.en", base: brokenBase)
        let staging = try fixture.installer.makeStagingDirectory()
        let thrown = captureError {
            try fixture.installer.installStagedModel(
                stagedModelFolder: broken,
                stagedTokenizerFolder: brokenTokenizer,
                stagingRoot: staging,
                overwrite: true)
        }
        guard case .installedButUnusable(let name, _, let missing)
            = thrown as? WhisperModelInstallError
        else {
            Issue.record("expected .installedButUnusable, got \(String(describing: thrown))")
            return
        }
        #expect(name == "openai_whisper-tiny.en")
        #expect(missing == ["TextDecoder.mlmodelc"])

        // Rolled back: the good install, marker file and all, is exactly where
        // it was.
        #expect(FileManager.default.fileExists(atPath: keep.path))
        let resolved = try fixture.catalog.resolveModel()
        #expect(resolved.variantDirectoryName == "openai_whisper-tiny.en")
    }

    @Test("A staged folder that is not there is named in the error")
    func missingStagedFolderIsNamed() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        let absent = fixture.downloadBase.appendingPathComponent("nope")
        let thrown = captureError {
            try fixture.installer.installStagedModel(
                stagedModelFolder: absent,
                stagedTokenizerFolder: nil,
                stagingRoot: nil,
                overwrite: false)
        }
        guard case .stagedModelMissing(let path) = thrown as? WhisperModelInstallError else {
            Issue.record("expected .stagedModelMissing, got \(String(describing: thrown))")
            return
        }
        #expect(path == absent.path)
        #expect(thrown?.localizedDescription.contains(absent.path) == true)
    }

    // MARK: Layout arithmetic + variant mapping

    @Test("Hub layout is downloadBase/models/<repo-id>/<variant>")
    func hubLayoutArithmetic() {
        let base = URL(fileURLWithPath: "/tmp/base")
        let folder = WhisperModelInstaller.hubLayoutModelFolder(
            downloadBase: base, variantDirectoryName: "openai_whisper-tiny.en")
        #expect(folder.path
            == "/tmp/base/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en")
        // The repo id's slash becomes a path separator — two components, not one
        // directory literally called "argmaxinc/whisperkit-coreml".
        #expect(folder.pathComponents.contains("argmaxinc"))
        #expect(folder.pathComponents.contains("whisperkit-coreml"))
    }

    @Test(
        "Variant names map to the Whisper size whose tokenizer repo is the right one",
        arguments: [
            // The live install on the user's machine. `large` is a substring of
            // this too — longest match must win.
            ("openai_whisper-large-v3-v20240930_turbo", "large-v3"),
            ("openai_whisper-large-v3_turbo", "large-v3"),
            ("openai_whisper-large-v2", "large-v2"),
            ("openai_whisper-large", "large"),
            // The trap: `tiny` is a prefix of `tiny.en`, and picking `tiny`
            // would fetch the MULTILINGUAL tokenizer for an English-only model.
            ("openai_whisper-tiny.en", "tiny.en"),
            ("openai_whisper-tiny", "tiny"),
            ("openai_whisper-base.en", "base.en"),
            ("openai_whisper-base", "base"),
            ("openai_whisper-small.en", "small.en"),
            ("openai_whisper-small", "small"),
            ("openai_whisper-medium.en", "medium.en"),
            ("openai_whisper-medium", "medium"),
            // Bare sizes, which is what a caller is likely to type.
            ("tiny.en", "tiny.en"),
            ("large-v3", "large-v3"),
            // A distil build still uses the large-v3 tokenizer.
            ("distil-whisper_distil-large-v3_turbo_600MB", "large-v3"),
        ])
    func variantMapping(name: String, expectedSize: String) {
        #expect(WhisperModelInstaller.modelVariant(forVariantName: name)?.description
            == expectedSize)
    }

    @Test("A name with no Whisper size in it maps to nothing")
    func unmappableVariantName() {
        #expect(WhisperModelInstaller.modelVariant(forVariantName: "openai_whisper-enormous") == nil)
        #expect(WhisperModelInstaller.modelVariant(forVariantName: "") == nil)
    }

    @Test("The tokenizer search finds the folder loadTokenizer wrote, wherever it put it")
    func tokenizerSearch() throws {
        let fixture = try InstallFixture()
        defer { fixture.destroy() }

        // Nothing yet.
        try fixture.makeDirectory(fixture.downloadBase)
        #expect(WhisperModelInstaller.findTokenizerFolder(under: fixture.downloadBase) == nil)

        // `loadTokenizer(tokenizerFolder:)` treats its argument as a Hub
        // downloadBase, so the files land at `<base>/models/<repo-id>/`. The
        // repo id comes from WhisperKit's `internal tokenizerNameForVariant`,
        // which is why this is a SEARCH and not a computed path.
        let written = try fixture.stageTokenizer(repoID: "openai/whisper-tiny.en")
        #expect(samePath(
            WhisperModelInstaller.findTokenizerFolder(under: fixture.downloadBase), written))

        // A base that IS the tokenizer folder is accepted directly (the second
        // search leg of `loadTokenizer`).
        let flat = fixture.root.appendingPathComponent("flat", isDirectory: true)
        try fixture.write(
            flat.appendingPathComponent(WhisperModelCatalog.tokenizerFileName), bytes: 3)
        #expect(samePath(WhisperModelInstaller.findTokenizerFolder(under: flat), flat))
    }

    // MARK: The one home

    @Test("The default models directory is the one Application Support home")
    func defaultDirectoryIsTheOneHome() {
        // Not open-coded here and not open-coded in the installer: both go
        // through `DAWCore.AppDirectories` via the catalog (m23-n1b). This test
        // only reads a URL — it never touches the real directory.
        #expect(WhisperModelInstaller().modelsDirectory
            == WhisperModelCatalog.applicationSupportModelsDirectory().standardizedFileURL)
        #expect(WhisperModelInstaller().modelsDirectory.lastPathComponent
            == WhisperModelCatalog.relativeModelsPath)
    }
}
