import Foundation
// `AppDirectories` — the one home for the Application-Support path rule
// (m23-n1b). This file must never open-code that path.
import DAWCore
// `WhisperKit.download` + `ModelUtilities.loadTokenizer` + `ModelVariant`.
// `ModelUtilities` and `ModelVariant` live in the ArgmaxCore target, which
// `WhisperKit.swift:4` re-exports (`@_exported import ArgmaxCore`), so a plain
// `import WhisperKit` reaches them — verified by compiling a probe against the
// real module before this file was written. Do NOT route through the free
// `loadTokenizer(for:tokenizerFolder:)` at `ModelUtilities.swift:216`: it is
// `@available(*, deprecated)` and would put a warning into a build this project
// keeps at zero.
import WhisperKit

// MARK: - Progress

/// One progress tick from an install, in a form that can cross an isolation
/// boundary and go on the wire.
///
/// **Why not `Foundation.Progress`.** WhisperKit hands its callback a
/// `Progress`, which is a mutable reference type and is NOT `Sendable`. It is
/// read synchronously inside the callback and its numbers copied into this
/// struct; the `Progress` object itself never escapes. m23-n3b plumbs this to
/// the control protocol, which is why it is `Codable` here rather than there.
public struct WhisperModelInstallProgress: Sendable, Equatable, Codable {
    /// What the installer is doing. Ordered as they occur.
    public enum Phase: String, Sendable, Codable, CaseIterable {
        /// Making the hidden staging directory.
        case preparing
        /// `WhisperKit.download` — the multi-hundred-MB leg.
        case downloadingModel
        /// The tokenizer fetch, which is a SEPARATE repo (see
        /// `WhisperModelInstaller`'s notes) and a few MB.
        case downloadingTokenizer
        /// The relocation from Hub layout into catalog layout. Renames on the
        /// same volume, so this is fast even for a 1.5 GB variant.
        case installing
        /// Done; the model is where `WhisperModelCatalog` can see it.
        case finished
    }

    public var phase: Phase
    /// The on-disk directory name being installed, e.g.
    /// `openai_whisper-tiny.en`. Identity, matching
    /// `WhisperModelDescriptor.variantDirectoryName`.
    public var variantDirectoryName: String
    /// 0...1 **within `phase`**, not across the whole install. Phases with no
    /// measurable sub-work report 1. Deliberately not blended into a single
    /// overall number: the weights would be a guess (the model leg is hundreds
    /// of times the tokenizer leg, and varies per variant), and a guessed
    /// percentage that stalls at 3% is worse than an honest phase label.
    public var phaseFraction: Double
    /// The underlying `Progress` counters when the phase has them, else 0/0.
    public var completedUnitCount: Int64
    public var totalUnitCount: Int64

    public init(
        phase: Phase,
        variantDirectoryName: String,
        phaseFraction: Double,
        completedUnitCount: Int64 = 0,
        totalUnitCount: Int64 = 0
    ) {
        self.phase = phase
        self.variantDirectoryName = variantDirectoryName
        self.phaseFraction = phaseFraction
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

// MARK: - Errors

/// Teaching errors, same idiom as `WhisperModelError`: every case names the
/// path it acted on and the next action.
public enum WhisperModelInstallError: Error, LocalizedError, Equatable {
    /// The variant is already installed and `overwrite` was false. NOT a
    /// silent success — a caller that meant to upgrade has to say so, because
    /// the alternative is quietly deleting a 1.5 GB install.
    case alreadyInstalled(variantDirectoryName: String, path: String)
    /// The directory name does not contain any Whisper size WhisperKit knows
    /// about, so there is no way to work out which tokenizer repo goes with it.
    case unrecognisedVariant(requested: String, known: [String])
    /// The tokenizer fetch produced no `tokenizer.json` anywhere under the
    /// staging root. Installing anyway would leave a model that reaches for the
    /// network on its first transcription.
    case tokenizerUnavailable(variantDirectoryName: String, searchedPath: String)
    /// The staged model folder is not there (or is a file).
    case stagedModelMissing(path: String)
    /// The move succeeded but the result does not satisfy the catalog. Rolled
    /// back before this is thrown, so the previous state is intact.
    case installedButUnusable(variantDirectoryName: String, path: String, missing: [String])
    /// The model landed somewhere the catalog's SCAN cannot reach — i.e. not as
    /// an immediate child of the search root. This is the m23-n3a bug itself,
    /// caught rather than shipped. Rolled back before it is thrown.
    case notVisibleToCatalog(variantDirectoryName: String, installedPath: String, searchRoot: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let name, let path):
            return "Speech model \"\(name)\" is already installed at \(path). "
                + "Pass overwrite to replace it, or install a different variant."
        case .unrecognisedVariant(let requested, let known):
            return "Don't recognise \"\(requested)\" as a Whisper model. "
                + "The name has to contain one of: \(known.joined(separator: ", "))."
        case .tokenizerUnavailable(let name, let path):
            return "Downloaded \(name) but could not fetch its tokenizer (nothing under \(path)). "
                + "Nothing was installed. Check the network and try again — without a local "
                + "tokenizer the first transcription would go online."
        case .stagedModelMissing(let path):
            return "Expected a downloaded model folder at \(path) and found none. "
                + "The download did not produce what it said it did; try again."
        case .installedButUnusable(let name, let path, let missing):
            return "Installed \(name) to \(path) but it is missing \(missing.joined(separator: ", ")). "
                + "The previous state has been restored. Re-run the install."
        case .notVisibleToCatalog(let name, let installed, let root):
            return "Put \(name) at \(installed), which is not somewhere \(root) is searched — "
                + "only its immediate children are. Nothing was installed. "
                + "This is a bug in the installer, not something to retry."
        }
    }
}

// MARK: - The installer

/// Downloads a WhisperKit model variant into `Application Support/DAWPro/Models`
/// **in the layout `WhisperModelCatalog` can actually see** (m23-n3a).
///
/// ## Why this type exists at all: the layout mismatch
///
/// `WhisperKit.download(variant:downloadBase:…)` (`WhisperKit.swift:244`) hands
/// its `downloadBase` to `HubApi`, whose `localRepoLocation` is
/// `downloadBase/models/<repo-id>/` (`swift-transformers/Sources/Hub/HubApi.swift:378`).
/// So pointing `downloadBase` straight at `Models/` lands the weights at
///
///     Models/models/argmaxinc/whisperkit-coreml/<variant>/
///
/// while `WhisperModelCatalog.candidateDirectories()` scans only the
/// **immediate children** of the search root. The app would see one child
/// called `models/`, inspect it as `.notAModel` (it has no components at its
/// own top level), and report "no speech model installed" **after a successful
/// multi-gigabyte download** — silent, and only a user ever hits it. So the
/// download is staged and then RELOCATED to `Models/<variant>/`.
///
/// ## Why the staging directory is `Models/.staging-<uuid>` and not a temp dir
///
/// Two reasons, both load-bearing:
///   * **Same volume.** The relocation is then a rename, not a second copy of
///     1.5 GB. `NSTemporaryDirectory()` is not guaranteed to be the same volume
///     as Application Support.
///   * **Invisible while it fills.** `candidateDirectories()` passes
///     `.skipsHiddenFiles` (`WhisperModelCatalog.swift:475-481`), so a
///     dot-prefixed directory cannot show up as a half-built model mid-download.
/// It is removed on failure, so an aborted install leaves no orphan.
///
/// ## What the completeness signal is — and what it is NOT
///
/// **`download()` returning without throwing is the completeness signal.**
/// `WhisperModelCatalog.inspect` CANNOT be that guard and must never be
/// "strengthened" into one: it bottoms out at `componentURL`, which is
/// `FileManager.fileExists` on `<name>.mlmodelc` (`:433-440`) — directory
/// EXISTENCE and nothing more. An interrupted download that created the
/// skeleton passes it. `inspect` is used here only as a post-move sanity
/// assertion: it proves the relocation put things where the catalog looks, not
/// that the bytes are whole.
///
/// ## The tokenizer is a SECOND download, from a different repo
///
/// Measured against the live Hub listing 2026-07-27:
/// `argmaxinc/whisperkit-coreml/openai_whisper-tiny.en/` contains only
/// `.mlmodelc`/`.mlpackage` component folders plus `config.json` and
/// `generation_config.json` — **no tokenizer at all**. So `WhisperKit.download`
/// alone leaves a model whose first transcription falls through to the network
/// (`ModelUtilities.loadTokenizer` ends at `AutoTokenizer.from(pretrained:)`).
/// The tokenizer is fetched separately, by WhisperKit's own
/// `ModelUtilities.loadTokenizer`, and lands **per variant** at
/// `Models/<variant>/tokenizer/`.
///
/// **One asymmetry worth knowing about, measured 2026-07-27.** `HubApi.snapshot`
/// writes its download metadata to `<repoDestination>/.cache/huggingface/download`
/// (`HubApi.swift:617-622`, written at `:564/:575/:607`). For the MODEL that
/// `repoDestination` is the REPO folder (`…/whisperkit-coreml/`) and the variant
/// sits one level below it, so the `.cache` subtree stays in staging and is
/// deleted with it. For the TOKENIZER `repoDestination` IS the folder holding
/// `tokenizer.json`, so `.cache/huggingface/` rides along into
/// `Models/<variant>/tokenizer/`. That is left in place on purpose: it is a few
/// KB of commit-hash/etag provenance, and deleting it would throw away the only
/// record of which revision was installed. It does mean a DOWNLOADED tokenizer
/// folder differs in shape from the hand-curated one already on disk, which
/// excluded it — that exclusion was about keeping the HF cache out of GIT
/// (m23-n1), a concern that does not apply under Application Support.
///
/// Per-variant, not the shared `Models/tokenizer/`, and that is deliberate:
/// `WhisperModelCatalog.tokenizerFolder(forVariantAt:)` (`:416-423`) checks the
/// per-variant folder FIRST precisely because an English-only (`.en`) variant
/// cannot share a multilingual tokenizer — and because writing into the shared
/// folder would overwrite the tokenizer the already-installed
/// `openai_whisper-large-v3-v20240930_turbo` depends on.
///
/// ## Headless
///
/// No control command and no MCP tool here — that lives one layer up, in
/// `WhisperModelInstallCoordinator` (m23-n3b), which is the ONLY caller of
/// `install(...)` reachable from the wire: it serialises installs (this type
/// has no isolation of its own) and exposes `ai.installSpeechModel` /
/// `ai.speechModelInstallStatus` (`Sources/DAWControl/Commands.swift`,
/// `mcp-server/src/server.ts`) as a start-then-poll pair.
public struct WhisperModelInstaller: Sendable {

    /// The `Models` root that variants are installed INTO — the same directory
    /// `WhisperModelCatalog` searches. Injected so tests never touch the real
    /// profile.
    public let modelsDirectory: URL

    /// The Hub repo the CoreML components come from. WhisperKit's own default.
    public static let whisperKitRepoID = "argmaxinc/whisperkit-coreml"

    /// Staging directories are named `<prefix><uuid>`. The leading dot is what
    /// keeps them out of `candidateDirectories()`.
    public static let stagingDirectoryPrefix = ".staging-"

    /// Defaults to the ONE home for the Application-Support rule
    /// (`AppDirectories.applicationSupport(.models)`, via the catalog). Never
    /// open-code that path here — consolidating the nine copies of it was an
    /// entire cycle (m23-n1b).
    public init(modelsDirectory: URL = WhisperModelCatalog.applicationSupportModelsDirectory()) {
        self.modelsDirectory = modelsDirectory.standardizedFileURL
    }

    /// The catalog that sees what this installer writes. Same root, by
    /// construction — that identity is the whole point of the type.
    public var catalog: WhisperModelCatalog { WhisperModelCatalog(searchRoot: modelsDirectory) }

    // MARK: Public entry point

    /// Download `variant` and install it where the catalog can see it.
    ///
    /// - Parameters:
    ///   - variant: A WhisperKit variant name — either the bare size
    ///     (`"tiny.en"`) or the full directory name
    ///     (`"openai_whisper-tiny.en"`). WhisperKit's own matcher accepts both.
    ///   - overwrite: Replace an existing install of the same variant. Defaults
    ///     to **false**: an accidental re-install must not delete weights that
    ///     are already there and working.
    ///   - repo: The Hub repo. Overridable for mirrors; defaults to WhisperKit's.
    ///   - token: Hugging Face token for gated repos. Nil for the public one.
    ///   - progress: Called on WhisperKit's own callback thread, repeatedly.
    ///
    /// - Returns: The descriptor the catalog now resolves for this variant.
    ///
    /// ## A trap this method deliberately does not hide (m23-n3c)
    ///
    /// `WhisperModelCatalog.resolveModel(nil)` takes `installedModels().first`,
    /// sorted by DIRECTORY NAME. `openai_whisper-base` sorts before
    /// `openai_whisper-large-v3-v20240930_turbo` ('b' < 'l'), so installing a
    /// second, smaller variant silently changes which model every transcription
    /// uses — no code change, nothing red. That behaviour is pinned by test
    /// (`WhisperModelInstallerTests`, "installing a second variant"). Making the
    /// default EXPLICIT rather than alphabetical is m23-n3c's call, not this
    /// item's, so nothing here quietly picks for the user.
    @discardableResult
    public func install(
        variant: String,
        overwrite: Bool = false,
        repo: String = WhisperModelInstaller.whisperKitRepoID,
        token: String? = nil,
        progress: (@Sendable (WhisperModelInstallProgress) -> Void)? = nil
    ) async throws -> WhisperModelDescriptor {
        // Fail on an unmappable name BEFORE downloading hundreds of megabytes:
        // without a `ModelVariant` there is no tokenizer repo, and a model
        // without a tokenizer is not an install.
        guard let modelVariant = Self.modelVariant(forVariantName: variant) else {
            throw WhisperModelInstallError.unrecognisedVariant(
                requested: variant,
                known: ModelVariant.allCases.map(\.description)
            )
        }

        progress?(WhisperModelInstallProgress(
            phase: .preparing, variantDirectoryName: variant, phaseFraction: 0))

        let staging = try makeStagingDirectory()
        // One cleanup path for every failure below: no orphan `.staging-*`
        // directories, ever.
        func cleanUpStaging() { try? FileManager.default.removeItem(at: staging) }

        do {
            let hubBase = staging.appendingPathComponent("hub", isDirectory: true)
            let tokenizerBase = staging.appendingPathComponent("tokenizer", isDirectory: true)
            try FileManager.default.createDirectory(at: hubBase, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: tokenizerBase, withIntermediateDirectories: true)

            // 1. The model. WhisperKit owns this download — we do not hand-roll
            //    an HTTP/Hub client (the m23-n2a lesson: we once wrote a 16 kHz
            //    resampler WhisperKit already had, and deleted it).
            //    The returned URL is AUTHORITATIVE for where the weights landed;
            //    `hubLayoutModelFolder` below states the same rule but is not
            //    used here, precisely so a Hub layout change cannot desync.
            let downloaded = try await WhisperKit.download(
                variant: variant,
                downloadBase: hubBase,
                useBackgroundSession: false,
                from: repo,
                token: token
            ) { raw in
                // `raw` is a non-Sendable `Progress`; read it here and let only
                // the copied numbers escape.
                progress?(WhisperModelInstallProgress(
                    phase: .downloadingModel,
                    variantDirectoryName: variant,
                    phaseFraction: raw.fractionCompleted,
                    completedUnitCount: raw.completedUnitCount,
                    totalUnitCount: raw.totalUnitCount))
            }

            // 2. The tokenizer, from `openai/whisper-<size>` — a DIFFERENT repo
            //    (see the type docs). WhisperKit computes the repo id itself
            //    from the `ModelVariant`, which is why nothing here restates
            //    the variant→repo table (`tokenizerNameForVariant` is internal
            //    to WhisperKit and must stay its business).
            progress?(WhisperModelInstallProgress(
                phase: .downloadingTokenizer,
                variantDirectoryName: downloaded.lastPathComponent,
                phaseFraction: 0))
            _ = try await ModelUtilities.loadTokenizer(
                for: modelVariant, tokenizerFolder: tokenizerBase)
            guard let stagedTokenizer = Self.findTokenizerFolder(under: tokenizerBase) else {
                throw WhisperModelInstallError.tokenizerUnavailable(
                    variantDirectoryName: downloaded.lastPathComponent,
                    searchedPath: tokenizerBase.path)
            }

            // 3. The relocation — the whole reason this type exists.
            progress?(WhisperModelInstallProgress(
                phase: .installing,
                variantDirectoryName: downloaded.lastPathComponent,
                phaseFraction: 0))
            let descriptor = try installStagedModel(
                stagedModelFolder: downloaded,
                stagedTokenizerFolder: stagedTokenizer,
                stagingRoot: staging,
                overwrite: overwrite)

            progress?(WhisperModelInstallProgress(
                phase: .finished,
                variantDirectoryName: descriptor.variantDirectoryName,
                phaseFraction: 1))
            return descriptor
        } catch {
            cleanUpStaging()
            throw error
        }
    }

    // MARK: The relocation (network-free, and therefore the real gate)

    /// Move a staged model folder — and its tokenizer — from Hub layout into
    /// the layout `WhisperModelCatalog` scans, then prove the catalog sees it.
    ///
    /// Deliberately takes URLs rather than doing its own downloading, so the
    /// suite exercises **this exact code** against a synthesized fixture with no
    /// network at all. That offline test is the gate for m23-n3a; the real
    /// `tiny.en` fetch is confirmation only.
    ///
    /// - Parameter stagingRoot: Removed on success (taking any displaced
    ///   previous install with it) and used to park the previous install during
    ///   an overwrite so a failure can roll back. Nil is allowed for callers
    ///   that staged elsewhere.
    @discardableResult
    func installStagedModel(
        stagedModelFolder: URL,
        stagedTokenizerFolder: URL?,
        stagingRoot: URL?,
        overwrite: Bool
    ) throws -> WhisperModelDescriptor {
        let fm = FileManager.default
        guard Self.directoryExists(stagedModelFolder) else {
            throw WhisperModelInstallError.stagedModelMissing(path: stagedModelFolder.path)
        }
        let name = stagedModelFolder.lastPathComponent
        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = modelsDirectory.appendingPathComponent(name, isDirectory: true)

        // Displace, don't delete. If anything below fails, the previous install
        // goes back exactly where it was.
        var displaced: URL?
        if Self.directoryExists(destination) {
            guard overwrite else {
                throw WhisperModelInstallError.alreadyInstalled(
                    variantDirectoryName: name, path: destination.path)
            }
            let parkRoot = stagingRoot ?? modelsDirectory
                .appendingPathComponent("\(Self.stagingDirectoryPrefix)\(UUID().uuidString)",
                                        isDirectory: true)
            try fm.createDirectory(at: parkRoot, withIntermediateDirectories: true)
            let park = parkRoot.appendingPathComponent("previous-\(name)", isDirectory: true)
            try fm.moveItem(at: destination, to: park)
            displaced = park
        }

        func rollBack() {
            try? fm.removeItem(at: destination)
            if let displaced { try? fm.moveItem(at: displaced, to: destination) }
        }

        do {
            // Same volume as `modelsDirectory` when staged the way `install`
            // stages it, so this is a rename — not a second 1.5 GB copy.
            try fm.moveItem(at: stagedModelFolder, to: destination)

            // Tokenizer goes INSIDE the variant, per
            // `tokenizerFolder(forVariantAt:)`'s first leg. Skipped when the
            // downloaded folder already carried one (no WhisperKit variant does
            // today, but a future one might, and its own copy wins).
            if let stagedTokenizerFolder,
               !WhisperModelCatalog.isTokenizerFolder(destination) {
                let installedTokenizer = destination.appendingPathComponent(
                    WhisperModelCatalog.tokenizerDirectoryName, isDirectory: true)
                if !WhisperModelCatalog.isTokenizerFolder(installedTokenizer) {
                    try? fm.removeItem(at: installedTokenizer)
                    try fm.moveItem(at: stagedTokenizerFolder, to: installedTokenizer)
                }
            }

            // POST-MOVE SANITY ASSERTION, NOT AN ATOMICITY GUARD. See the type
            // docs: `inspect` only checks that the component directories EXIST.
            // It cannot tell a whole download from an interrupted one, and it
            // must not be "strengthened" into something that claims it can —
            // `download()` returning is the completeness signal. What this DOES
            // catch is the failure this whole item is about: weights sitting in
            // a shape the catalog cannot see.
            switch catalog.inspect(variantDirectoryAt: destination) {
            case .usable(let descriptor):
                // `inspect` was HANDED the path. The question this whole type
                // exists to answer is a different one: does the catalog's own
                // SCAN reach it? `candidateDirectories()` walks only the
                // immediate children of the search root, so resolving BY NAME
                // (which runs that scan) is what proves the relocation worked.
                //
                // Unreachable by construction today — `destination` is built as
                // an immediate child two lines up. Kept because a refactor that
                // reintroduced the Hub layout would otherwise be completely
                // silent, which is precisely the bug m23-n3a exists to prevent.
                // Verified to discriminate: the destination computation was
                // deliberately changed to `hubLayoutModelFolder(...)` and
                // `WhisperModelInstallerTests` went red on
                // `.noModelInstalled`, then restored.
                guard let scanned = try? catalog
                    .resolveModel(named: descriptor.variantDirectoryName)
                else {
                    rollBack()
                    throw WhisperModelInstallError.notVisibleToCatalog(
                        variantDirectoryName: name,
                        installedPath: destination.path,
                        searchRoot: modelsDirectory.path)
                }
                if let stagingRoot { try? fm.removeItem(at: stagingRoot) }
                return scanned
            case .incomplete(let broken):
                rollBack()
                throw WhisperModelInstallError.installedButUnusable(
                    variantDirectoryName: name, path: destination.path, missing: broken.missing)
            case .notAModel:
                rollBack()
                throw WhisperModelInstallError.installedButUnusable(
                    variantDirectoryName: name,
                    path: destination.path,
                    missing: WhisperModelCatalog.requiredComponents.map { "\($0).mlmodelc" })
            }
        } catch {
            if !(error is WhisperModelInstallError) { rollBack() }
            throw error
        }
    }

    // MARK: Staging

    /// A fresh `Models/.staging-<uuid>/`, creating `Models/` if this is a fresh
    /// machine that has never installed anything.
    func makeStagingDirectory(uuid: UUID = UUID()) throws -> URL {
        let url = modelsDirectory.appendingPathComponent(
            "\(Self.stagingDirectoryPrefix)\(uuid.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every staging directory currently sitting under `modelsDirectory`.
    /// Exists so a failed-hard run (process killed mid-download) can be swept;
    /// the normal failure path already removes its own.
    public func orphanedStagingDirectories() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil, options: [])) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix(Self.stagingDirectoryPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Layout arithmetic

    /// The folder `HubApi` downloads a repo into:
    /// `<downloadBase>/models/<repo-id>/`, per
    /// `swift-transformers/Sources/Hub/HubApi.swift:378`
    /// (`downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)`).
    /// A variant lands one level below that.
    ///
    /// **Production code does not use this** — `WhisperKit.download` RETURNS the
    /// folder, and the returned URL is authoritative, so a future Hub layout
    /// change cannot desync the installer. It is stated here because it is the
    /// exact mismatch this type exists to correct, and because the offline test
    /// builds its fixture from it.
    static func hubLayoutModelFolder(
        downloadBase: URL,
        repoID: String = whisperKitRepoID,
        variantDirectoryName: String
    ) -> URL {
        var url = downloadBase.appendingPathComponent("models", isDirectory: true)
        for component in repoID.split(separator: "/") {
            url = url.appendingPathComponent(String(component), isDirectory: true)
        }
        return url.appendingPathComponent(variantDirectoryName, isDirectory: true)
    }

    /// The first folder under `root` that is a tokenizer folder by
    /// `WhisperModelCatalog`'s rule (it contains `tokenizer.json`).
    ///
    /// A SEARCH rather than a computed path on purpose: `loadTokenizer` writes
    /// to `<base>/models/<tokenizer-repo-id>/`, and the repo id comes from
    /// WhisperKit's `tokenizerNameForVariant`, which is `internal`. Restating
    /// that table here would be a second home for it — and a wrong one the day
    /// WhisperKit adds a variant. Only one repo is ever fetched into a staging
    /// tokenizer base, so the search is unambiguous.
    static func findTokenizerFolder(under root: URL) -> URL? {
        if WhisperModelCatalog.isTokenizerFolder(root) { return root }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return nil }
        var found: [URL] = []
        for case let item as URL in enumerator {
            guard directoryExists(item) else { continue }
            if WhisperModelCatalog.isTokenizerFolder(item) { found.append(item) }
        }
        // Deterministic when (never, today) more than one matches.
        return found.sorted { $0.path < $1.path }.first
    }

    /// Which `ModelVariant` an on-disk directory name (or a bare size like
    /// `"tiny.en"`) denotes. `ModelUtilities.loadTokenizer(for:)` needs this to
    /// know which `openai/whisper-*` repo carries the matching tokenizer.
    ///
    /// Derived from WhisperKit's OWN enum (`ModelVariant.allCases` +
    /// `description`) rather than a copied table, so a variant added in a future
    /// WhisperKit is picked up by rebuilding rather than by editing a list here.
    ///
    /// **Longest description wins, and that is load-bearing.**
    /// `openai_whisper-tiny.en` contains both `tiny` and `tiny.en`; picking
    /// `tiny` would install the MULTILINGUAL tokenizer for an English-only
    /// model. Likewise `openai_whisper-large-v3-v20240930_turbo` contains both
    /// `large` and `large-v3`.
    static func modelVariant(forVariantName name: String) -> ModelVariant? {
        ModelVariant.allCases
            .filter { name.contains($0.description) }
            .max { $0.description.count < $1.description.count }
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
