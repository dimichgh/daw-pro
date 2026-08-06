import Foundation
// `AppDirectories` — the one home for the Application-Support path rule (m23-n1b).
import DAWCore
// THE ONE-WAY DOOR, WALKED THROUGH UNDER A GATE (m23-n1) — and now walked
// through for real. m23-n1 carried a bare `import WhisperKit` here purely as
// EVIDENCE that the import SITE compiles under Swift 6 strict concurrency
// (attaching the product in `Package.swift` makes SwiftPM build and link
// WhisperKit whether or not any source imports it, so the build alone never
// exercises it, and the reference app that vendored these weights is
// tools-version 5.9 and has never compiled WhisperKit in this language mode).
// m23-n2a replaced that placeholder with the real call sites —
// `WhisperTranscriber.swift` and `TranscriptionBeats.swift` — which import and
// USE the dependency, so the evidence is now load-bearing code and the bare
// import is gone. This file itself needs no WhisperKit symbol: it mirrors
// WhisperKit's load rules (see the citations on `WhisperModelCatalog`) rather
// than calling them, which is what keeps it testable against a synthesized
// fixture instead of the 1.5 GB copy.

// MARK: - The three answers to "can this variant do word timings"

/// Whether a variant can emit **word-level** timings, with the third answer
/// kept distinct instead of collapsed (m23-ef).
///
/// m23-n3f established the capability check and resolved the unknown case
/// optimistically — `supportsWordTimestamps` reads `true` when nothing on disk
/// could be asked, because `nil → false` would fire a warning at every
/// `.mlpackage`-form variant, capable ones included, and teach users to ignore
/// it. That trade STANDS and this type does not touch it.
///
/// What this type adds is that the optimism is now VISIBLE rather than
/// swallowed: `.supported` and `.unknown` both read `true` through
/// `supportsWordTimestamps`, but a caller that wants to distinguish "the model
/// said yes" from "the model could not be asked" finally can. That is the one
/// residue m23-n3f could not close — a `.mlpackage` variant that genuinely
/// lacks the alignment output produces a silent empty word list, and nothing on
/// disk can contradict it.
public enum WordTimestampSupport: String, Codable, Sendable, Equatable {
    /// The decoder ITSELF declared the alignment output. A positive answer from
    /// the model, not an assumption.
    case supported
    /// The decoder ITSELF declared its outputs and the alignment one was not
    /// among them. **The only state that warns** — the rule stays "only ever
    /// say NO when the model itself said no".
    case unsupported
    /// Nothing on disk could be asked: no `metadata.json` (the `.mlpackage`
    /// layout has none at all), or one that would not parse. Reads as capable
    /// through `supportsWordTimestamps` — see the type note.
    case unknown
}

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
    /// Whether this variant can produce **word-level** timings (m23-n3f).
    ///
    /// Same shape and same contract as `hasContextPrefill` immediately above:
    /// REPORTED, never enforced. A variant without it still transcribes and
    /// still places SEGMENTS on the grid — only the per-word beats are missing,
    /// which is exactly the failure that used to be invisible.
    ///
    /// Why it can be false at all: WhisperKit derives word timings by DTW over
    /// a cross-attention tensor the compiled decoder has to EXPOSE as an output
    /// (`alignment_heads_weights`). `TranscribeTask.swift:198-200` guards the
    /// whole word-timing branch behind `if let alignmentWeights =
    /// decodingResult.cache?.alignmentWeights` — an `if let` with **no else**,
    /// so a variant compiled without that output returns `words: []` and never
    /// an error. `WhisperTranscriber` asks for `wordTimestamps: true`
    /// unconditionally, so for this app — whose whole point is lyrics on the
    /// beat grid — such a variant is a silent total failure. This flag is what
    /// makes it speak.
    ///
    /// **UNKNOWN READS AS `true`.** See
    /// `WhisperModelCatalog.declaredWordTimestampSupport(inFolder:)` for the
    /// three-state read this is derived from, and for why the unknown case
    /// resolves optimistically.
    ///
    /// m23-ef: **COMPUTED from `wordTimestampSupport` below**, no longer stored.
    /// The name, the type and the meaning are unchanged — `false` still means
    /// and only means "the model itself said no" — but the two can no longer
    /// drift apart, because there is only one value. Still ENCODED (see
    /// `encode(to:)`): it is a live wire field on `ai.installSpeechModel` /
    /// `ai.speechModelInstallStatus` and Swift's synthesized `Codable` would
    /// have dropped it the moment it stopped being stored.
    public var supportsWordTimestamps: Bool { wordTimestampSupport != .unsupported }

    /// The three-state capability (m23-ef): the model said yes, the model said
    /// no, or nothing could be asked. THE stored source of truth —
    /// `supportsWordTimestamps` and both explanations are derived from it.
    public var wordTimestampSupport: WordTimestampSupport

    public init(
        variantDirectoryName: String,
        displayName: String,
        modelFolder: URL,
        tokenizerFolder: URL,
        modelSizeBytes: Int64,
        tokenizerSizeBytes: Int64,
        hasContextPrefill: Bool,
        wordTimestampSupport: WordTimestampSupport
    ) {
        self.variantDirectoryName = variantDirectoryName
        self.displayName = displayName
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
        self.modelSizeBytes = modelSizeBytes
        self.tokenizerSizeBytes = tokenizerSizeBytes
        self.hasContextPrefill = hasContextPrefill
        self.wordTimestampSupport = wordTimestampSupport
    }

    /// The two-state construction m23-n3f shipped, kept so every existing call
    /// site and test reads exactly as before (m23-ef).
    ///
    /// It cannot express `.unknown`, and that is correct: a caller who states a
    /// `Bool` has, by stating it, said which way the model answered. Only the
    /// catalog — which is the thing that can fail to find out — reaches for the
    /// three-state initializer above.
    public init(
        variantDirectoryName: String,
        displayName: String,
        modelFolder: URL,
        tokenizerFolder: URL,
        modelSizeBytes: Int64,
        tokenizerSizeBytes: Int64,
        hasContextPrefill: Bool,
        supportsWordTimestamps: Bool
    ) {
        self.init(
            variantDirectoryName: variantDirectoryName,
            displayName: displayName,
            modelFolder: modelFolder,
            tokenizerFolder: tokenizerFolder,
            modelSizeBytes: modelSizeBytes,
            tokenizerSizeBytes: tokenizerSizeBytes,
            hasContextPrefill: hasContextPrefill,
            wordTimestampSupport: supportsWordTimestamps ? .supported : .unsupported)
    }

    public var totalSizeBytes: Int64 { modelSizeBytes + tokenizerSizeBytes }

    /// Rounded, human-readable total ("1.64 GB") for teaching messages and UI.
    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    /// THE teaching message for a variant that cannot do word timings — the one
    /// home for that wording, and `nil` for every variant that can (m23-n3f).
    ///
    /// Written in `WhisperModelError.errorDescription`'s voice: what is wrong,
    /// the exact path that was inspected, and the next action. It is carried in
    /// `clip.transcribe`'s response rather than thrown, because the transcript
    /// is still real and useful — segment text and segment timings come from
    /// timestamp TOKENS, not from the alignment tensor, so refusing the whole
    /// job would throw away a correct answer to punish a missing extra.
    ///
    /// Not a `WhisperModelError` case: every case in that enum means "this
    /// directory is not a usable model", and this one IS usable.
    public var wordTimestampsUnavailableExplanation: String? {
        guard wordTimestampSupport == .unsupported else { return nil }
        return "Speech model \"\(variantDirectoryName)\" produces no word timings, so per-word "
            + "beats will be empty. Its "
            + "\(WhisperModelCatalog.textDecoderComponentName).mlmodelc in \(modelFolder.path) "
            + "declares no \(WhisperModelCatalog.wordTimestampAlignmentOutputName) output, and that "
            + "tensor is where word-level alignment comes from — the text and the SEGMENT timings "
            + "below are still correct. Install a variant compiled with it "
            + "(openai_whisper-large-v3-v20240930_turbo has it) via ai.installSpeechModel and "
            + "transcribe again, or work from the segment beats."
    }

    /// THE wording for the UNKNOWN case (m23-ef) — the one home for it, exactly
    /// as `wordTimestampsUnavailableExplanation` above is the one home for the
    /// `.unsupported` wording. `nil` for `.supported` and `.unsupported`.
    ///
    /// **Non-nil whenever the state is `.unknown`, unconditionally — this
    /// property is the WORDING, not the decision to show it.** Emitting a
    /// caveat at every `.mlpackage` variant regardless of outcome is precisely
    /// the alarm fatigue m23-n3f refused, so the gate lives one layer up, on
    /// `Transcription.wordTimestampsUnverified`, which can see whether the run
    /// actually came back wordless. Keeping the two apart is deliberate: a
    /// wording that decided its own visibility could not be reused by a caller
    /// with a different question (an installer, say, listing what it just put
    /// on disk).
    ///
    /// Hedged on purpose. Unlike the `.unsupported` message this one asserts
    /// nothing about the model — it says what could not be determined, where
    /// the answer would have been, and what to do about it.
    ///
    /// **It names the decoder component that was ACTUALLY RESOLVED, which is
    /// why it reads the disk.** The sibling message above can hard-code
    /// `TextDecoder.mlmodelc` because reaching `.unsupported` requires a
    /// `metadata.json` that was read and parsed — in practice the compiled
    /// form. `.unknown` is the opposite case and is dominated by the
    /// `.mlpackage` form, whose on-disk name is NOT `…​.mlmodelc`; printing the
    /// compiled name there would send the reader looking in the right folder
    /// for a directory that does not exist. The lookup is the same
    /// `componentURL` rule `inspect` used, so the two can't disagree.
    ///
    /// The `nil` fallback is unreachable for a descriptor the catalog produced
    /// — `TextDecoder` is a REQUIRED component, so a variant missing it is
    /// reported `.incomplete` and never becomes a descriptor at all — but this
    /// is a public value type anyone can construct, so it degrades to naming
    /// the folder rather than trapping.
    public var wordTimestampsUnverifiedExplanation: String? {
        guard wordTimestampSupport == .unknown else { return nil }
        let decoderDescription = resolvedTextDecoderEntryName
            .map { "\($0) in \(modelFolder.path)" }
            ?? "\(WhisperModelCatalog.textDecoderComponentName) component in \(modelFolder.path)"
        return "Speech model \"\(variantDirectoryName)\" did not say whether it can produce word "
            + "timings, so this is a caution rather than a verdict. Its "
            + "\(decoderDescription) has no readable "
            + "\(WhisperModelCatalog.compiledModelMetadataFileName) — the .mlpackage "
            + "layout carries none at all — and that file is where the "
            + "\(WhisperModelCatalog.wordTimestampAlignmentOutputName) output would have been "
            + "listed. Most variants do have it, so this model was used as if it does. If word "
            + "beats are missing and the audio really does contain singing or speech, install a "
            + "compiled variant whose capability CAN be read "
            + "(openai_whisper-large-v3-v20240930_turbo) via ai.installSpeechModel and transcribe "
            + "again; the text and the SEGMENT timings below are correct either way."
    }

    /// The decoder entry a reader would actually FIND inside `modelFolder` —
    /// `TextDecoder.mlmodelc` or `TextDecoder.mlpackage` — or `nil` when neither
    /// form is on disk.
    ///
    /// ⚠️ Not `componentURL(…)?.lastPathComponent`, and a test proves why:
    /// `componentURL` mirrors WhisperKit's `detectModelURL`, which for the
    /// `.mlpackage` form resolves all the way to the INNER
    /// `…/Data/com.apple.CoreML/model.mlmodel`. Its last component is therefore
    /// `model.mlmodel` for every variant in that layout — a name that is both
    /// wrong to look for and identical across components. What a message wants
    /// is the first path component BELOW the model folder, which is the bundle
    /// directory in either layout.
    private var resolvedTextDecoderEntryName: String? {
        guard let resolved = WhisperModelCatalog.componentURL(
            inFolder: modelFolder, named: WhisperModelCatalog.textDecoderComponentName)
        else { return nil }
        let folderParts = modelFolder.standardizedFileURL.pathComponents
        let resolvedParts = resolved.standardizedFileURL.pathComponents
        guard resolvedParts.count > folderParts.count,
              Array(resolvedParts.prefix(folderParts.count)) == folderParts
        else { return resolved.lastPathComponent }
        return resolvedParts[folderParts.count]
    }

    // MARK: Codable — hand-written, and the reason is specific (m23-ef)

    /// `supportsWordTimestamps` is a LIVE field of the `descriptor` payload on
    /// `ai.installSpeechModel` / `ai.speechModelInstallStatus`, and m23-ef made
    /// it computed. Swift synthesizes `Codable` over STORED properties only, so
    /// synthesis would have silently REMOVED it from the wire — the one thing
    /// the additive-only rule forbids. It is therefore encoded explicitly, as a
    /// derived mirror of `wordTimestampSupport`.
    ///
    /// ⚠️ The price of hand-writing this is that a new stored property will NOT
    /// reach the wire by itself. `WhisperModelCatalogEncodingTests` asserts the
    /// exact key SET for that reason — add the property here and the test tells
    /// you so.
    private enum CodingKeys: String, CodingKey {
        case variantDirectoryName
        case displayName
        case modelFolder
        case tokenizerFolder
        case modelSizeBytes
        case tokenizerSizeBytes
        case hasContextPrefill
        case supportsWordTimestamps
        case wordTimestampSupport
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(variantDirectoryName, forKey: .variantDirectoryName)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(modelFolder, forKey: .modelFolder)
        try container.encode(tokenizerFolder, forKey: .tokenizerFolder)
        try container.encode(modelSizeBytes, forKey: .modelSizeBytes)
        try container.encode(tokenizerSizeBytes, forKey: .tokenizerSizeBytes)
        try container.encode(hasContextPrefill, forKey: .hasContextPrefill)
        // Derived, never stored — see the note above for why it is here at all.
        try container.encode(supportsWordTimestamps, forKey: .supportsWordTimestamps)
        try container.encode(wordTimestampSupport, forKey: .wordTimestampSupport)
    }

    /// Prefers the three-state field; falls back to the m23-n3f `Bool` when only
    /// that is present; treats "neither" as `.unknown` — which is what neither
    /// literally means, and matches the optimistic reading (`.unknown` still
    /// reports `supportsWordTimestamps == true`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variantDirectoryName = try container.decode(String.self, forKey: .variantDirectoryName)
        displayName = try container.decode(String.self, forKey: .displayName)
        modelFolder = try container.decode(URL.self, forKey: .modelFolder)
        tokenizerFolder = try container.decode(URL.self, forKey: .tokenizerFolder)
        modelSizeBytes = try container.decode(Int64.self, forKey: .modelSizeBytes)
        tokenizerSizeBytes = try container.decode(Int64.self, forKey: .tokenizerSizeBytes)
        hasContextPrefill = try container.decode(Bool.self, forKey: .hasContextPrefill)
        if let support = try container.decodeIfPresent(
            WordTimestampSupport.self, forKey: .wordTimestampSupport) {
            wordTimestampSupport = support
        } else if let legacy = try container.decodeIfPresent(
            Bool.self, forKey: .supportsWordTimestamps) {
            wordTimestampSupport = legacy ? .supported : .unsupported
        } else {
            wordTimestampSupport = .unknown
        }
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
    /// The component whose DECLARED OUTPUTS decide word-timestamp support.
    /// Named once so `requiredComponents` and the m23-n3f capability check can
    /// never drift apart about which component that is.
    public static let textDecoderComponentName = "TextDecoder"
    /// CoreML components WhisperKit refuses to load without.
    public static let requiredComponents = ["MelSpectrogram", "AudioEncoder", textDecoderComponentName]
    /// Loaded when present, skipped when absent.
    public static let optionalComponentName = "TextDecoderContextPrefill"
    /// The decoder output WhisperKit's word-timing DTW needs (m23-n3f). Baked
    /// into some compiled variants and not others; when it is missing the word
    /// branch is skipped silently.
    public static let wordTimestampAlignmentOutputName = "alignment_heads_weights"
    /// The interface description coremltools writes INSIDE a compiled
    /// `.mlmodelc` directory. Nothing else in this repo reads it; the shape is
    /// documented on `declaredOutputNames(ofCompiledModelAt:)`.
    public static let compiledModelMetadataFileName = "metadata.json"

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

    /// `~/Library/Application Support/DAWPro/Models` — where the weights live
    /// once installed, alongside `SoundBanks`/`Autosave`/`VoiceDatasets`
    /// (m23-n1, 2026-07-27). The Application-Support rule itself was open-coded
    /// here until m23-n1b consolidated all nine copies into
    /// `DAWCore.AppDirectories`; `relativeModelsPath` deliberately stays local
    /// because it also names the BUNDLE and REPO model dirs, which have nothing
    /// to do with Application Support.
    public static func applicationSupportModelsDirectory() -> URL {
        AppDirectories.applicationSupport(.models)
    }

    /// `<App>.app/Contents/Resources/Models` when the weights were sealed into
    /// the bundle by `scripts/bundle.sh --with-weights`. Nil outside a bundle
    /// (SwiftPM executables, the test runner).
    public static func bundledModelsDirectory(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?
            .appendingPathComponent(relativeModelsPath, isDirectory: true)
            .standardizedFileURL
    }

    /// Every location consulted, HIGHEST PRIORITY FIRST — the one home for
    /// "where can weights be". Order and its reasoning:
    ///   1. **Application Support** — user-installed weights beat shipped ones,
    ///      so a small bundled default can be upgraded to large-v3-turbo by
    ///      downloading, without reinstalling the app (the m23-n3 story).
    ///   2. **The bundle** — a sealed, signed, tested copy; the offline case.
    ///   3. **`<repo>/Models`** — dev-only walk-up anchored on `Package.swift`,
    ///      kept so a checkout that still has weights in-tree keeps working.
    /// The `DAWPRO_WHISPER_MODELS_DIR` override is NOT in this list: it wins
    /// outright in `defaultSearchRoot`, ahead of the whole chain.
    public static func searchRootCandidates(bundle: Bundle = .main) -> [URL] {
        var out: [URL] = [applicationSupportModelsDirectory()]
        if let bundled = bundledModelsDirectory(bundle: bundle) { out.append(bundled) }
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
            if let found = walkUpForModelsDir(from: anchor) {
                if !out.contains(found) { out.append(found) }
                break
            }
        }
        return out
    }

    /// `DAWPRO_WHISPER_MODELS_DIR` wins OUTRIGHT if set — even if it holds
    /// nothing, so pointing the knob at a deliberate place yields that place's
    /// teaching error rather than silently resolving somewhere else.
    ///
    /// Otherwise walk `searchRootCandidates` and take **the first that actually
    /// HAS a usable model**, not merely the first that exists — an empty
    /// `Application Support/DAWPro/Models` must not shadow a good bundled copy.
    /// Falling back: the first that exists (so the error names a directory that
    /// was really inspected), then the primary (so it names where to put them).
    public static func defaultSearchRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let override = environment[searchRootEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        let candidates = searchRootCandidates(bundle: bundle)
        if let stocked = candidates.first(where: {
            !WhisperModelCatalog(searchRoot: $0).installedModels().isEmpty
        }) { return stocked }
        if let existing = candidates.first(where: {
            var isDir: ObjCBool = false
            let there = FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
            return there && isDir.boolValue
        }) { return existing }
        return candidates.first
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
                    inFolder: directory, named: Self.optionalComponentName) != nil,
                // m23-n3f. Computed HERE and nowhere else, for the same reason
                // the validity rule is: `WhisperModelInstaller` gets its
                // descriptor back from this very call, so a second derivation
                // would silently disagree for freshly installed models.
                // m23-ef: the THREE-state value, not the collapsed `Bool`. The
                // descriptor computes `supportsWordTimestamps` back out of it,
                // so what reaches the wire is unchanged and one field more.
                wordTimestampSupport: Self.wordTimestampSupport(inFolder: directory)
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

    // MARK: The word-timestamp capability (m23-n3f)

    /// Output names a COMPILED CoreML model declares, or `nil` when that could
    /// not be determined at all.
    ///
    /// **Shape, read off the real installed decoder (2026-08-05) rather than
    /// assumed:** `<component>.mlmodelc/metadata.json` is a JSON **array** whose
    /// first element is the model description; that element's `outputSchema` is
    /// an array of dictionaries each carrying a `name`. For
    /// `openai_whisper-large-v3-v20240930_turbo` those names are exactly
    /// `logits`, `key_cache_updates`, `value_cache_updates`,
    /// `alignment_heads_weights`. Parsed with `JSONSerialization` and plucked,
    /// deliberately: a `Codable` model of coremltools' metadata would be a
    /// second thing to keep in sync with a format we do not own.
    ///
    /// **Every failure is `nil`, never a crash and never a guess** — absent
    /// file, unreadable file, invalid JSON, an unexpected top-level type, no
    /// `outputSchema`, or a schema that parsed to zero names (no CoreML model
    /// has zero outputs, so that is shape drift, not a model without outputs).
    /// `nil` means "did not determine", which is a different thing from "has no
    /// such output" and must stay distinguishable from it.
    public static func declaredOutputNames(ofCompiledModelAt url: URL) -> [String]? {
        let metadata = url.appendingPathComponent(compiledModelMetadataFileName)
        guard let data = try? Data(contentsOf: metadata),
              let top = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        // The array form is what CoreML writes. The bare-object form is accepted
        // too so a future single-object metadata file degrades to a correct read
        // rather than to "unknown".
        let description: [String: Any]?
        if let array = top as? [Any] {
            description = array.first as? [String: Any]
        } else {
            description = top as? [String: Any]
        }
        guard let schema = description?["outputSchema"] as? [Any] else { return nil }
        let names = schema.compactMap { ($0 as? [String: Any])?["name"] as? String }
        return names.isEmpty ? nil : names
    }

    /// Three-state read of whether a variant's decoder declares the alignment
    /// output: `true`/`false` when the decoder SAID, `nil` when we could not
    /// tell (m23-n3f).
    ///
    /// `nil` is a real answer here, not a placeholder: the `.mlpackage` form
    /// `componentURL` also accepts carries no `metadata.json` at all, so an
    /// otherwise perfectly good model can be unknowable. Keeping that distinct
    /// from `false` is what stops a tool that never looked and a tool that
    /// looked and saw nothing from producing the same output.
    public static func declaredWordTimestampSupport(inFolder folder: URL) -> Bool? {
        guard let decoder = componentURL(inFolder: folder, named: textDecoderComponentName),
              let outputs = declaredOutputNames(ofCompiledModelAt: decoder)
        else { return nil }
        // EXACT name match. A substring/prefix test would call a decoder that
        // merely mentions the tensor elsewhere (an input, a description) capable.
        return outputs.contains(wordTimestampAlignmentOutputName)
    }

    /// The `Bool` that lands on `WhisperModelDescriptor.supportsWordTimestamps`.
    ///
    /// **UNKNOWN RESOLVES TO `true`, and that direction is deliberate.** The
    /// flag drives a WARNING, so the cost of each mistake is asymmetric:
    ///
    /// * `nil → false` would fire the warning at models that are FINE — every
    ///   `.mlpackage`-form variant (no `metadata.json` exists in that layout at
    ///   all) and every variant whose metadata we simply failed to parse. The
    ///   user would read "no word timings" next to a transcript full of word
    ///   timings, which teaches them to ignore the warning.
    /// * `nil → true` leaves those variants exactly where they were before this
    ///   check existed — no worse than the status quo, and no false alarm.
    ///
    /// So the rule is: **only ever say NO when the model itself said no.** The
    /// honest limit that buys is stated rather than hidden — a `.mlpackage`
    /// variant lacking the output is still a silent empty word list, because
    /// nothing on disk can be asked.
    ///
    /// A missing/unreadable/malformed `metadata.json` therefore also cannot make
    /// an otherwise-usable model unusable: `inspect` does not consult this at
    /// all when deciding usability.
    public static func supportsWordTimestamps(inFolder folder: URL) -> Bool {
        declaredWordTimestampSupport(inFolder: folder) ?? true
    }

    /// The same read as `declaredWordTimestampSupport`, in the shape that
    /// travels: `true → .supported`, `false → .unsupported`, `nil → .unknown`
    /// (m23-ef).
    ///
    /// **This is a rename of the answer, not a change to it.** Nothing here
    /// decides anything `declaredWordTimestampSupport` did not already decide;
    /// what changes is that the third answer survives the trip to the caller
    /// instead of being collapsed into `true` by
    /// `supportsWordTimestamps(inFolder:)` above — which keeps its exact
    /// behaviour, unknown included, because a warning that cries wolf at every
    /// `.mlpackage` is worse than the residue it would close.
    public static func wordTimestampSupport(inFolder folder: URL) -> WordTimestampSupport {
        switch declaredWordTimestampSupport(inFolder: folder) {
        case .some(true): return .supported
        case .some(false): return .unsupported
        case .none: return .unknown
        }
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
