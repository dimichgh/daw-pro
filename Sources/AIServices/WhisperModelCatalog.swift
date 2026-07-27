import Foundation
// THE ONE-WAY DOOR, WALKED THROUGH UNDER A GATE (m23-n1). This bare import is
// deliberate and load-bearing as EVIDENCE, not as code: attaching the product
// in `Package.swift` makes SwiftPM build and link WhisperKit whether or not any
// source imports it, so the build alone never exercises the import SITE. Under
// Swift 6 strict concurrency (the reference app that vendored these weights is
// tools-version 5.9 and has never compiled WhisperKit in this language mode)
// that site is exactly where friction would show up, and a warning here is OURS
// — the root package's — so it reddens the zero-warning gate instead of being
// suppressed the way warnings from dependency targets are. m23-n2 replaces this
// with the real transcriber call site; until then, keep it.
import WhisperKit

// MARK: - What a resolved model looks like

/// A speech-to-text model found on disk: which variant it is, where its pieces
/// live, and what it costs in bytes.
///
/// `variantDirectoryName` is the IDENTITY — the on-disk directory name, exactly
/// as WhisperKit's `modelFolder` wants it. `displayName` is cosmetic only and
/// must never be used to select a model (see `WhisperModelCatalog.displayName`).
public struct WhisperModelDescriptor: Sendable, Equatable, Codable {
    /// Identity. The directory name under the search root, e.g.
    /// `openai_whisper-large-v3-v20240930_turbo`.
    public var variantDirectoryName: String
    /// Human-facing label derived from `variantDirectoryName`. Cosmetic.
    public var displayName: String
    /// The directory holding the compiled CoreML components. Hand this to
    /// WhisperKit as `modelFolder`.
    public var modelFolder: URL
    /// The directory holding `tokenizer.json`. Hand this to WhisperKit as
    /// `tokenizerFolder`. May be SHARED between variants (see
    /// `WhisperModelCatalog.tokenizerFolder(forVariantAt:)`), which is why
    /// summing `totalSizeBytes` across several descriptors can double-count.
    public var tokenizerFolder: URL
    /// Logical byte total of every regular file under `modelFolder`.
    public var modelSizeBytes: Int64
    /// Logical byte total of every regular file under `tokenizerFolder`.
    public var tokenizerSizeBytes: Int64
    /// Whether the optional `TextDecoderContextPrefill` component is present.
    /// WhisperKit loads it when it exists and works without it, so its absence
    /// is NOT an incompleteness — it is reported, not enforced.
    public var hasContextPrefill: Bool

    public init(
        variantDirectoryName: String,
        displayName: String,
        modelFolder: URL,
        tokenizerFolder: URL,
        modelSizeBytes: Int64,
        tokenizerSizeBytes: Int64,
        hasContextPrefill: Bool
    ) {
        self.variantDirectoryName = variantDirectoryName
        self.displayName = displayName
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
        self.modelSizeBytes = modelSizeBytes
        self.tokenizerSizeBytes = tokenizerSizeBytes
        self.hasContextPrefill = hasContextPrefill
    }

    public var totalSizeBytes: Int64 { modelSizeBytes + tokenizerSizeBytes }

    /// Rounded, human-readable total ("1.64 GB") for teaching messages and UI.
    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }
}

/// Why a candidate directory is not a usable model — carried in the teaching
/// error so "nothing found" can say WHAT was wrong rather than only THAT it was.
public struct WhisperModelIncompleteVariant: Sendable, Equatable, Codable {
    public var variantDirectoryName: String
    /// Component/file names that had to be there and were not, in the order
    /// `WhisperModelCatalog.requiredComponents` lists them.
    public var missing: [String]

    public init(variantDirectoryName: String, missing: [String]) {
        self.variantDirectoryName = variantDirectoryName
        self.missing = missing
    }
}

// MARK: - Errors

/// Teaching errors: every case names the exact path that was inspected and the
/// next action, per the house idiom (`SidecarError.notInstalled` at
/// `SidecarStatus.swift:90`).
public enum WhisperModelError: Error, LocalizedError, Equatable {
    /// We could not even work out WHERE to look (no environment override and no
    /// repo checkout above us — a packaged `.app` that forgot to set the knob).
    case searchRootUnresolvable
    /// We know where to look and there is nothing there.
    case searchRootMissing(searchRoot: String)
    /// The search root exists but holds no usable model. `incomplete` lists the
    /// near-misses so the message can say which piece is absent.
    case noModelInstalled(searchRoot: String, incomplete: [WhisperModelIncompleteVariant])
    /// A specific variant was asked for by name and is not among the usable ones.
    case variantNotFound(requested: String, searchRoot: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .searchRootUnresolvable:
            return "Could not work out where the speech models live. "
                + "Set \(WhisperModelCatalog.searchRootEnvironmentKey) to the folder that holds "
                + "them, or run the app from inside the daw-pro checkout "
                + "(expects <repo>/\(WhisperModelCatalog.relativeModelsPath))."
        case .searchRootMissing(let root):
            return "No speech models folder at \(root). "
                + "Copy a WhisperKit model folder there (it needs "
                + "\(WhisperModelCatalog.requiredComponents.map { "\($0).mlmodelc" }.joined(separator: ", "))"
                + " plus a \(WhisperModelCatalog.tokenizerDirectoryName)/ folder containing "
                + "\(WhisperModelCatalog.tokenizerFileName)), or point "
                + "\(WhisperModelCatalog.searchRootEnvironmentKey) at a folder that already has one."
        case .noModelInstalled(let root, let incomplete):
            var message = "No usable speech model in \(root). "
            if incomplete.isEmpty {
                message += "The folder is empty — copy a WhisperKit model folder into it "
                    + "(e.g. openai_whisper-large-v3-v20240930_turbo) alongside a "
                    + "\(WhisperModelCatalog.tokenizerDirectoryName)/ folder."
            } else {
                let details = incomplete
                    .map { "\($0.variantDirectoryName) (missing \($0.missing.joined(separator: ", ")))" }
                    .joined(separator: "; ")
                message += "Found but could not use: \(details). "
                    + "Re-copy the model folder — a partial copy is the usual cause."
            }
            return message
        case .variantNotFound(let requested, let root, let available):
            if available.isEmpty {
                return "Speech model \"\(requested)\" is not installed in \(root), and no other "
                    + "model is either. Copy one in first."
            }
            return "Speech model \"\(requested)\" is not installed in \(root). "
                + "Available: \(available.joined(separator: ", "))."
        }
    }
}

// MARK: - The catalog

/// THE one home for two rules that nothing else in the codebase may restate:
///
///   1. **Where the speech-model weights live.** `relativeModelsPath` plus
///      `defaultSearchRoot(environment:)`. `scripts/bundle.sh` (m23-n3) copies
///      that same directory into the `.app`; the `.gitignore` entry is
///      root-anchored to it. If this constant moves, those two move with it.
///   2. **Whether a directory is a usable model.** `inspect(variantDirectoryAt:)`
///      and nothing else. m23-n2 (transcription) and m23-n3 (packaging) both
///      read these; neither may recompute them.
///
/// The validity rule is not invented here — it MIRRORS WhisperKit's own load
/// path, so "usable" means "WhisperKit will load this offline". Citations, all
/// against the pinned 0.18.0 checkout, for whoever revisits this:
///   * `WhisperKit.swift:372-381` — `MelSpectrogram`, `AudioEncoder`,
///     `TextDecoder` are required (it throws `modelsUnavailable` otherwise);
///     `:393` guards `TextDecoderContextPrefill` behind a `fileExists`, so that
///     one is optional.
///   * `ArgmaxCore/ModelUtilities.swift:69-80` — a component resolves as
///     `<name>.mlmodelc`, falling back to `<name>.mlpackage/Data/…/model.mlmodel`.
///   * `WhisperKit/Utilities/ModelUtilities.swift:31-36` — a tokenizer folder is
///     one containing `tokenizer.json`.
///   * `WhisperKit.swift:476-482` — the model folder ITSELF is searched for the
///     tokenizer, which is why a bare `tokenizer.json` beside the components
///     counts.
///
/// Headless and injectable: every method works against any `searchRoot`, so the
/// suite exercises the real logic against a synthesized fixture instead of the
/// 1.5 GB copy.
public struct WhisperModelCatalog: Sendable {
    /// Path of the models folder relative to the repo/app root. THE one home —
    /// `.gitignore`'s `/Models/` and m23-n3's `bundle.sh` both name this
    /// directory and must change with it.
    public static let relativeModelsPath = "Models"
    /// Environment override, following the `DAWPRO_ACESTEP_DIR` precedent.
    public static let searchRootEnvironmentKey = "DAWPRO_WHISPER_MODELS_DIR"
    /// Conventional shared-tokenizer directory name, as WhisperKit's own model
    /// snapshots ship it.
    public static let tokenizerDirectoryName = "tokenizer"
    /// The file whose presence defines a tokenizer folder (WhisperKit's rule).
    public static let tokenizerFileName = "tokenizer.json"
    /// CoreML components WhisperKit refuses to load without.
    public static let requiredComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
    /// Loaded when present, skipped when absent.
    public static let optionalComponentName = "TextDecoderContextPrefill"

    /// The folder searched for variant directories. Injected, so tests never
    /// touch the real copy.
    public let searchRoot: URL

    public init(searchRoot: URL) {
        self.searchRoot = searchRoot.standardizedFileURL
    }

    /// The catalog the running app uses. Throws (never crashes, never guesses)
    /// when the location cannot be worked out at all.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> WhisperModelCatalog {
        guard let root = defaultSearchRoot(environment: environment) else {
            throw WhisperModelError.searchRootUnresolvable
        }
        return WhisperModelCatalog(searchRoot: root)
    }

    /// `DAWPRO_WHISPER_MODELS_DIR` wins if set (also how a packaged `.app`
    /// points at its bundled copy, and how a download-mode install points at
    /// Application Support — m23-n3). Otherwise walk up from a repo-relative
    /// anchor looking for `Package.swift` and use `<repo>/Models`. That walk-up
    /// is a dev-only heuristic, exactly as `SidecarManager` does it: a packaged
    /// `.app` has no `Package.swift` anywhere near it and MUST set the knob.
    public static func defaultSearchRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment[searchRootEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        // Two anchors, tried in order: the process's current directory (SwiftPM
        // runs `swift run`/`swift test` with cwd = package root, so this is the
        // reliable one under the test runner) and argv[0] (correct for a plain
        // built executable launched directly, but NOT under `swift test`, whose
        // argv[0] is a toolchain-internal helper far from the repo).
        let anchors: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            CommandLine.arguments.first.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent()
            },
        ].compactMap { $0 }
        for anchor in anchors {
            if let found = walkUpForModelsDir(from: anchor) { return found }
        }
        return nil
    }

    private static func walkUpForModelsDir(from start: URL) -> URL? {
        var dir = start
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path
            ) {
                return dir.appendingPathComponent(relativeModelsPath).standardizedFileURL
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    // MARK: Presence reporting

    /// What a candidate directory turned out to be.
    public enum Inspection: Sendable, Equatable {
        case usable(WhisperModelDescriptor)
        /// Looks like an attempt at a model but is missing required pieces.
        case incomplete(WhisperModelIncompleteVariant)
        /// Not a model directory at all (e.g. the shared `tokenizer/` sibling)
        /// — reported separately from `.incomplete` so a plain sibling folder
        /// never shows up in a teaching error as a broken model.
        case notAModel
    }

    /// Every usable model under `searchRoot`, sorted by directory name so the
    /// order is deterministic and "the first one" means something stable.
    ///
    /// Deliberately discovers by SCANNING rather than by knowing a name: only
    /// one variant exists locally today, and a second (base/small/distil) must
    /// be a copy-in, not a code change.
    public func installedModels() -> [WhisperModelDescriptor] {
        candidateDirectories().compactMap {
            if case .usable(let descriptor) = inspect(variantDirectoryAt: $0) { return descriptor }
            return nil
        }
        .sorted { $0.variantDirectoryName < $1.variantDirectoryName }
    }

    /// Near-misses under `searchRoot`: directories that look like a model
    /// attempt but are missing pieces. Feeds the teaching error.
    public func incompleteModels() -> [WhisperModelIncompleteVariant] {
        candidateDirectories().compactMap {
            if case .incomplete(let broken) = inspect(variantDirectoryAt: $0) { return broken }
            return nil
        }
        .sorted { $0.variantDirectoryName < $1.variantDirectoryName }
    }

    /// Resolve one model, or throw the teaching error. Pass `named:` to select a
    /// specific variant by its DIRECTORY NAME (identity); pass nil to take the
    /// first installed one.
    public func resolveModel(named requested: String? = nil) throws -> WhisperModelDescriptor {
        guard directoryExists(searchRoot) else {
            throw WhisperModelError.searchRootMissing(searchRoot: searchRoot.path)
        }
        let installed = installedModels()
        if let requested {
            guard let match = installed.first(where: { $0.variantDirectoryName == requested }) else {
                throw WhisperModelError.variantNotFound(
                    requested: requested,
                    searchRoot: searchRoot.path,
                    available: installed.map(\.variantDirectoryName)
                )
            }
            return match
        }
        guard let first = installed.first else {
            throw WhisperModelError.noModelInstalled(
                searchRoot: searchRoot.path,
                incomplete: incompleteModels()
            )
        }
        return first
    }

    // MARK: The validity rule (one home)

    /// THE definition of "is this directory a usable WhisperKit model".
    /// Mirrors WhisperKit's own load path — see the citations on the type.
    public func inspect(variantDirectoryAt directory: URL) -> Inspection {
        guard directoryExists(directory) else { return .notAModel }
        let name = directory.lastPathComponent

        var missing: [String] = []
        for component in Self.requiredComponents where Self.componentURL(inFolder: directory, named: component) == nil {
            missing.append("\(component).mlmodelc")
        }
        // A directory with NONE of the components is a plain sibling (the shared
        // `tokenizer/` folder is the live example), not a broken model. Only
        // partial ones are worth teaching about.
        if missing.count == Self.requiredComponents.count { return .notAModel }

        let tokenizer = tokenizerFolder(forVariantAt: directory)
        if tokenizer == nil { missing.append("\(Self.tokenizerDirectoryName)/\(Self.tokenizerFileName)") }

        guard missing.isEmpty, let tokenizer else {
            return .incomplete(WhisperModelIncompleteVariant(variantDirectoryName: name, missing: missing))
        }
        return .usable(
            WhisperModelDescriptor(
                variantDirectoryName: name,
                displayName: Self.displayName(forVariantDirectoryName: name),
                modelFolder: directory,
                tokenizerFolder: tokenizer,
                modelSizeBytes: Self.directorySizeBytes(at: directory),
                tokenizerSizeBytes: Self.directorySizeBytes(at: tokenizer),
                hasContextPrefill: Self.componentURL(
                    inFolder: directory, named: Self.optionalComponentName) != nil
            )
        )
    }

    /// Where a variant's tokenizer lives, in WhisperKit's own priority order:
    /// the variant's private `tokenizer/`, then a bare `tokenizer.json` beside
    /// the components, then the search root's shared `tokenizer/`.
    ///
    /// The per-variant legs come first on purpose: multilingual variants can
    /// share one tokenizer, but an English-only (`.en`) variant cannot, so a
    /// second model must be able to bring its own without disturbing the first.
    public func tokenizerFolder(forVariantAt directory: URL) -> URL? {
        let candidates = [
            directory.appendingPathComponent(Self.tokenizerDirectoryName),
            directory,
            searchRoot.appendingPathComponent(Self.tokenizerDirectoryName),
        ]
        return candidates.first { Self.isTokenizerFolder($0) }
    }

    /// WhisperKit's `hasTokenizer`: a folder containing `tokenizer.json`.
    public static func isTokenizerFolder(_ folder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(tokenizerFileName).path)
    }

    /// WhisperKit's `detectModelURL`: `<name>.mlmodelc`, else the `.mlpackage`
    /// form. nil when neither exists.
    public static func componentURL(inFolder folder: URL, named component: String) -> URL? {
        let compiled = folder.appendingPathComponent("\(component).mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let package = folder.appendingPathComponent(
            "\(component).mlpackage/Data/com.apple.CoreML/model.mlmodel")
        if FileManager.default.fileExists(atPath: package.path) { return package }
        return nil
    }

    // MARK: Helpers

    /// Cosmetic ONLY. Strips the vendor prefix WhisperKit's snapshots carry;
    /// falls back to the raw directory name when that leaves nothing. Never
    /// used to select a model — identity is `variantDirectoryName`.
    public static func displayName(forVariantDirectoryName name: String) -> String {
        let prefix = "openai_whisper-"
        guard name.hasPrefix(prefix) else { return name }
        let stripped = String(name.dropFirst(prefix.count))
        return stripped.isEmpty ? name : stripped
    }

    /// LOGICAL byte total (`URLResourceValues.fileSize`) of every regular file
    /// underneath `url`, hidden files included. This is the sum a
    /// `find … | stat -f %z` would give — NOT what `du` reports, which counts
    /// allocated blocks and will read larger.
    public static func directorySizeBytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    private func candidateDirectories() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter { directoryExists($0) }
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
