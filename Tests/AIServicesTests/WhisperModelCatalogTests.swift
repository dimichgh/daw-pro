import Foundation
import Testing
@testable import AIServices

/// Builds WhisperKit-shaped model layouts in a temp directory, so the resolver
/// is exercised against REAL filesystem structure with EXACTLY KNOWN byte
/// counts — not against the 1.5 GB local copy (which exists on one machine and
/// would make every size assertion a `> 0` vibe).
///
/// Component files are given distinct, prime-ish sizes on purpose: a size
/// function that returned a constant, or that counted files instead of bytes,
/// or that walked only the top level, all produce a different total.
private struct ModelFixture {
    let root: URL

    // Byte sizes chosen so no two subsets sum alike.
    static let melBytes = 10
    static let encoderModelBytes = 100
    static let encoderWeightBytes = 1000
    static let decoderBytes = 200
    static let prefillBytes = 5
    static let configBytes = 2
    static let tokenizerBytes = 7

    /// Full variant: three required components (one of them nested two levels
    /// deep, so a top-level-only size walk is caught), the optional prefill,
    /// and a config file. 1317 bytes.
    static let fullVariantBytes = Int64(
        melBytes + encoderModelBytes + encoderWeightBytes + decoderBytes + prefillBytes + configBytes)
    /// Same minus the optional prefill. 1312 bytes.
    static let variantWithoutPrefillBytes = fullVariantBytes - Int64(prefillBytes)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func write(_ relativePath: String, text: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath), withIntermediateDirectories: true)
    }

    /// Compiled-model metadata in the EXACT shape coremltools writes and
    /// `WhisperModelCatalog.declaredOutputNames` parses — read off the real
    /// installed `TextDecoder.mlmodelc/metadata.json` on 2026-08-05, not
    /// imagined: a JSON **array** whose first element carries `inputSchema` and
    /// `outputSchema`, each an array of dicts with a `name`.
    ///
    /// `inputs` exists so a leg can put the alignment tensor's NAME somewhere
    /// other than the outputs — the discriminator against an implementation
    /// that just searches the file's text.
    static func decoderMetadataJSON(
        outputs: [String],
        inputs: [String] = ["encoder_output_embeds", "cache_length"]
    ) -> String {
        func schema(_ names: [String]) -> String {
            names.map {
                "{\"name\": \"\($0)\", \"type\": \"MultiArray\", \"dataType\": \"Float16\", "
                    + "\"shape\": \"[1, 1500]\", \"hasShapeFlexibility\": \"0\", "
                    + "\"isOptional\": \"0\", \"shortDescription\": \"\"}"
            }.joined(separator: ", ")
        }
        return "[{\"modelType\": \"MLProgram\", \"specificationVersion\": 7, "
            + "\"inputSchema\": [\(schema(inputs))], \"outputSchema\": [\(schema(outputs))]}]"
    }

    /// The four outputs the real `openai_whisper-large-v3-v20240930_turbo`
    /// decoder declares (measured 2026-08-05).
    static let realDecoderOutputs =
        ["logits", "key_cache_updates", "value_cache_updates", "alignment_heads_weights"]
    /// THE ABSENT CASE this item exists for: a decoder that declares everything
    /// EXCEPT the alignment tensor. Deliberately not an empty schema — an empty
    /// one would also satisfy a broken check, for the wrong reason.
    static let decoderOutputsWithoutAlignment =
        ["logits", "key_cache_updates", "value_cache_updates"]

    /// A model directory WhisperKit would load. `omitting` drops one required
    /// component (the discriminator legs); `includePrefill` controls the
    /// optional one.
    ///
    /// `decoderMetadata` writes `TextDecoder.mlmodelc/metadata.json` (m23-n3f).
    /// It defaults to **nil = no metadata file at all**, deliberately: every
    /// byte total above is pinned exactly, and writing an extra file by default
    /// would silently move all of them.
    func makeVariant(
        _ name: String,
        omitting: String? = nil,
        includePrefill: Bool = true,
        compiled: Bool = true,
        decoderMetadata: String? = nil
    ) throws {
        // `.mlmodelc` is a DIRECTORY on disk, so the fixture makes directories,
        // not empty marker files.
        func component(_ component: String, files: [(String, Int)]) throws {
            guard component != omitting else { return }
            let suffix = compiled ? "\(component).mlmodelc" : "\(component).mlpackage/Data/com.apple.CoreML"
            let leaf = compiled ? "" : "model.mlmodel"
            if compiled {
                for (file, bytes) in files {
                    try write("\(name)/\(suffix)/\(file)", bytes: bytes)
                }
            } else {
                // `.mlpackage` form: WhisperKit resolves the inner model.mlmodel.
                try write("\(name)/\(suffix)/\(leaf)", bytes: files.reduce(0) { $0 + $1.1 })
            }
        }
        try component("MelSpectrogram", files: [("model.mil", Self.melBytes)])
        try component(
            "AudioEncoder",
            files: [("model.mil", Self.encoderModelBytes), ("weights/weight.bin", Self.encoderWeightBytes)])
        try component("TextDecoder", files: [("model.mil", Self.decoderBytes)])
        if let decoderMetadata, omitting != "TextDecoder" {
            // Beside the compiled model, exactly where CoreML puts it. The
            // `.mlpackage` form has no such file — that layout's "unknown" is
            // the point of its own leg, so nothing is written for it.
            let suffix = compiled ? "TextDecoder.mlmodelc" : "TextDecoder.mlpackage/Data/com.apple.CoreML"
            try write(
                "\(name)/\(suffix)/\(WhisperModelCatalog.compiledModelMetadataFileName)",
                text: decoderMetadata)
        }
        if includePrefill {
            try component("TextDecoderContextPrefill", files: [("model.mil", Self.prefillBytes)])
        }
        try write("\(name)/config.json", bytes: Self.configBytes)
    }

    /// The shared sibling tokenizer folder, exactly as the real copy ships it.
    func makeSharedTokenizer() throws {
        try write("\(WhisperModelCatalog.tokenizerDirectoryName)/tokenizer.json", bytes: Self.tokenizerBytes)
    }

    func makeVariantTokenizer(_ variant: String, bytes: Int) throws {
        try write("\(variant)/\(WhisperModelCatalog.tokenizerDirectoryName)/tokenizer.json", bytes: bytes)
    }

    var catalog: WhisperModelCatalog { WhisperModelCatalog(searchRoot: root) }
}

@Suite("WhisperModelCatalog — presence reporting (m23-n1)")
struct WhisperModelCatalogPresenceTests {
    /// POSITIVE, and the one that carries the item: a real WhisperKit-shaped
    /// layout is FOUND, NAMED, LOCATED and SIZED — exact byte totals, not `> 0`.
    @Test("Finds a valid model and reports name, location and exact size")
    func findsValidModel() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-large-v3-v20240930_turbo")
        try fixture.makeSharedTokenizer()

        let model = try fixture.catalog.resolveModel()

        #expect(model.variantDirectoryName == "openai_whisper-large-v3-v20240930_turbo")
        #expect(model.displayName == "large-v3-v20240930_turbo")
        #expect(model.modelFolder.lastPathComponent == "openai_whisper-large-v3-v20240930_turbo")
        #expect(
            model.modelFolder.deletingLastPathComponent().standardizedFileURL
                == fixture.root.standardizedFileURL)
        #expect(model.tokenizerFolder.lastPathComponent == "tokenizer")
        #expect(model.modelSizeBytes == ModelFixture.fullVariantBytes)
        #expect(model.tokenizerSizeBytes == Int64(ModelFixture.tokenizerBytes))
        #expect(model.totalSizeBytes == ModelFixture.fullVariantBytes + Int64(ModelFixture.tokenizerBytes))
        #expect(model.hasContextPrefill)
        #expect(!model.formattedTotalSize.isEmpty)
    }

    /// The size number must actually count BYTES from a nested walk. If it
    /// counted files, or stopped at the top level, this total changes.
    @Test("Directory size is the logical byte sum of every regular file, nested included")
    func sizeIsExactByteSum() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("m")

        let bytes = WhisperModelCatalog.directorySizeBytes(
            at: fixture.root.appendingPathComponent("m"))
        #expect(bytes == ModelFixture.fullVariantBytes)
        // Sanity: the deepest file alone is 1000 bytes, so a top-level-only walk
        // could not have produced the total above.
        #expect(bytes > Int64(ModelFixture.encoderWeightBytes))
    }

    @Test("The optional prefill component is reported, never required")
    func prefillIsOptional() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-tiny", includePrefill: false)
        try fixture.makeSharedTokenizer()

        let model = try fixture.catalog.resolveModel()
        #expect(!model.hasContextPrefill)
        #expect(model.modelSizeBytes == ModelFixture.variantWithoutPrefillBytes)
    }

    /// WhisperKit's `detectModelURL` accepts the `.mlpackage` form as well as
    /// `.mlmodelc`; our rule mirrors its rule, so it must too.
    @Test("An .mlpackage layout is accepted, like WhisperKit's own detection")
    func acceptsPackageForm() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-base", compiled: false)
        try fixture.makeSharedTokenizer()

        let model = try fixture.catalog.resolveModel()
        #expect(model.variantDirectoryName == "openai_whisper-base")
    }

    /// The shared `tokenizer/` folder sits right next to the variants. It must
    /// never be reported as a model — nor as a BROKEN model, which would put a
    /// bogus "missing AudioEncoder.mlmodelc" line in a teaching error.
    @Test("The sibling tokenizer folder is not a variant and not a near-miss")
    func tokenizerSiblingIsNotAVariant() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-large-v3-v20240930_turbo")
        try fixture.makeSharedTokenizer()

        let names = fixture.catalog.installedModels().map(\.variantDirectoryName)
        #expect(names == ["openai_whisper-large-v3-v20240930_turbo"])
        #expect(fixture.catalog.incompleteModels().isEmpty)
        #expect(
            fixture.catalog.inspect(
                variantDirectoryAt: fixture.root.appendingPathComponent("tokenizer"))
                == .notAModel)
    }

    /// PC7 shape check: a second variant is a COPY-IN, not a code change.
    @Test("A second variant is discovered by scanning, deterministically ordered")
    func secondVariantNeedsNoCodeChange() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-large-v3-v20240930_turbo")
        try fixture.makeVariant("openai_whisper-base")
        try fixture.makeSharedTokenizer()

        let names = fixture.catalog.installedModels().map(\.variantDirectoryName)
        #expect(names == ["openai_whisper-base", "openai_whisper-large-v3-v20240930_turbo"])
        let chosen = try fixture.catalog.resolveModel(named: "openai_whisper-large-v3-v20240930_turbo")
        #expect(chosen.variantDirectoryName == "openai_whisper-large-v3-v20240930_turbo")
    }

    /// Multilingual variants can share a tokenizer; an `.en` variant cannot.
    /// The per-variant folder must therefore WIN over the shared sibling.
    @Test("A variant's own tokenizer wins over the shared one")
    func perVariantTokenizerWins() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-small.en")
        try fixture.makeSharedTokenizer()
        try fixture.makeVariantTokenizer("openai_whisper-small.en", bytes: 33)

        let model = try fixture.catalog.resolveModel()
        #expect(model.tokenizerFolder.deletingLastPathComponent().lastPathComponent
            == "openai_whisper-small.en")
        #expect(model.tokenizerSizeBytes == 33)
    }

    /// WhisperKit searches the model folder itself for `tokenizer.json`.
    @Test("A bare tokenizer.json beside the components counts")
    func bareTokenizerJSONCounts() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-tiny")
        try fixture.write("openai_whisper-tiny/tokenizer.json", bytes: 7)

        let model = try fixture.catalog.resolveModel()
        #expect(model.tokenizerFolder.lastPathComponent == "openai_whisper-tiny")
    }

    @Test("Display name is cosmetic and falls back to the raw directory name")
    func displayNameFallsBack() {
        #expect(
            WhisperModelCatalog.displayName(forVariantDirectoryName: "openai_whisper-base.en")
                == "base.en")
        #expect(WhisperModelCatalog.displayName(forVariantDirectoryName: "my-own-model")
            == "my-own-model")
        // Degenerate: prefix and nothing else — must not become the empty string.
        #expect(WhisperModelCatalog.displayName(forVariantDirectoryName: "openai_whisper-")
            == "openai_whisper-")
    }
}

@Suite("WhisperModelCatalog — the validity rule discriminates (m23-n1)")
struct WhisperModelCatalogValidityTests {
    /// THE discriminator. Without these three legs, the positive test cannot
    /// tell "checks all three required components" from "checks the directory
    /// exists". Each run drops exactly ONE component.
    @Test(
        "A model missing any one required component is rejected and named",
        arguments: ["MelSpectrogram", "AudioEncoder", "TextDecoder"])
    func rejectsPartialModel(missingComponent: String) throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-large-v3-v20240930_turbo", omitting: missingComponent)
        try fixture.makeSharedTokenizer()

        #expect(fixture.catalog.installedModels().isEmpty)
        #expect(
            fixture.catalog.incompleteModels()
                == [WhisperModelIncompleteVariant(
                    variantDirectoryName: "openai_whisper-large-v3-v20240930_turbo",
                    missing: ["\(missingComponent).mlmodelc"])])

        let error = #expect(throws: WhisperModelError.self) {
            try fixture.catalog.resolveModel()
        }
        let message = try #require(error?.errorDescription)
        #expect(message.contains(missingComponent))
        #expect(message.contains(fixture.root.path))
    }

    /// A model with every component but no tokenizer cannot load offline —
    /// WhisperKit would go to the network, which this feature never does.
    @Test("A model with no reachable tokenizer is incomplete")
    func rejectsTokenizerlessModel() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-large-v3-v20240930_turbo")
        // deliberately no shared tokenizer

        #expect(fixture.catalog.installedModels().isEmpty)
        let incomplete = fixture.catalog.incompleteModels()
        #expect(incomplete.count == 1)
        #expect(incomplete.first?.missing == ["tokenizer/tokenizer.json"])
    }

    /// An `.mlmodelc` name that exists but as an EMPTY directory still resolves
    /// — mirroring WhisperKit, which only does a `fileExists` check. Pinning
    /// this stops a later "make it stricter" change from silently diverging from
    /// the runtime it is supposed to mirror.
    @Test("Validity mirrors WhisperKit's own existence check, no deeper")
    func mirrorsWhisperKitDepth() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        for component in WhisperModelCatalog.requiredComponents {
            try fixture.makeDirectory("openai_whisper-tiny/\(component).mlmodelc")
        }
        try fixture.makeSharedTokenizer()

        let model = try fixture.catalog.resolveModel()
        #expect(model.variantDirectoryName == "openai_whisper-tiny")
        #expect(model.modelSizeBytes == 0)
        #expect(!model.hasContextPrefill)
    }
}

@Suite("WhisperModelCatalog — teaching errors (m23-n1)")
struct WhisperModelCatalogErrorTests {
    /// NEGATIVE: the path does not exist at all.
    @Test("An absent search root teaches, naming the path")
    func absentRootTeaches() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-absent-\(UUID().uuidString)")
        let catalog = WhisperModelCatalog(searchRoot: missing)

        let error = #expect(throws: WhisperModelError.self) { try catalog.resolveModel() }
        #expect(error == .searchRootMissing(searchRoot: missing.standardizedFileURL.path))
        let message = try #require(error?.errorDescription)
        #expect(message.contains(missing.standardizedFileURL.path))
        #expect(message.contains("AudioEncoder.mlmodelc"))
        #expect(message.contains(WhisperModelCatalog.searchRootEnvironmentKey))
    }

    /// NEGATIVE: the path exists and is empty — a different, more actionable
    /// message than "not there at all".
    @Test("An empty search root teaches, naming the path")
    func emptyRootTeaches() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        let catalog = fixture.catalog

        let error = #expect(throws: WhisperModelError.self) { try catalog.resolveModel() }
        #expect(error == .noModelInstalled(searchRoot: fixture.root.standardizedFileURL.path, incomplete: []))
        let message = try #require(error?.errorDescription)
        #expect(message.contains(fixture.root.standardizedFileURL.path))
        #expect(message.lowercased().contains("copy"))
    }

    @Test("Asking for a model that is not installed lists what is")
    func unknownVariantListsAvailable() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-base")
        try fixture.makeSharedTokenizer()

        let error = #expect(throws: WhisperModelError.self) {
            try fixture.catalog.resolveModel(named: "openai_whisper-large-v3")
        }
        let message = try #require(error?.errorDescription)
        #expect(message.contains("openai_whisper-large-v3"))
        #expect(message.contains("openai_whisper-base"))
    }

    @Test("An unresolvable location teaches how to set the knob")
    func unresolvableRootTeaches() throws {
        let message = try #require(WhisperModelError.searchRootUnresolvable.errorDescription)
        #expect(message.contains(WhisperModelCatalog.searchRootEnvironmentKey))
        #expect(message.contains(WhisperModelCatalog.relativeModelsPath))
    }
}

@Suite("WhisperModelCatalog — where the weights live (m23-n1)")
struct WhisperModelCatalogLocationTests {
    @Test("The environment override wins outright")
    func environmentOverrideWins() throws {
        let root = try #require(
            WhisperModelCatalog.defaultSearchRoot(
                environment: [WhisperModelCatalog.searchRootEnvironmentKey: "/opt/whisper-models"]))
        #expect(root.path == "/opt/whisper-models")

        let catalog = try WhisperModelCatalog.resolved(
            environment: [WhisperModelCatalog.searchRootEnvironmentKey: "/opt/whisper-models"])
        #expect(catalog.searchRoot.path == "/opt/whisper-models")
    }

    /// An empty value must NOT be treated as an override — it falls through to
    /// the walk-up, which is what an unset-but-exported shell variable looks
    /// like.
    @Test("An empty override falls through to the repo walk-up")
    func emptyOverrideFallsThrough() throws {
        let root = try #require(
            WhisperModelCatalog.defaultSearchRoot(
                environment: [WhisperModelCatalog.searchRootEnvironmentKey: ""]))
        #expect(root.lastPathComponent == WhisperModelCatalog.relativeModelsPath)
    }

    /// SUPERSEDED 2026-07-27 (m23-n1): the weights moved out of `<repo>/Models`
    /// to Application Support, so "the location IS `<repo>/Models`" is no longer
    /// true — it is now the LAST candidate, not the only one. The walk-up itself
    /// still works and is asserted below; what changed is its priority.
    @Test("Application Support is the highest-priority candidate")
    func applicationSupportLeadsTheChain() throws {
        let candidates = WhisperModelCatalog.searchRootCandidates()
        let first = try #require(candidates.first)
        #expect(first == WhisperModelCatalog.applicationSupportModelsDirectory())
        #expect(first.lastPathComponent == WhisperModelCatalog.relativeModelsPath)
        // ...and it is under Application Support/DAWPro, not the repo.
        #expect(first.deletingLastPathComponent().lastPathComponent == "DAWPro")
    }

    /// The walk-up still anchors on `Package.swift` (cwd = package root under
    /// the test runner), so `<repo>/Models` must still be REACHABLE — just no
    /// longer first. Structural: does not require the weights to be there.
    @Test("The repo walk-up still contributes <repo>/Models, at lower priority")
    func walkUpStillContributesRepoModels() throws {
        let candidates = WhisperModelCatalog.searchRootCandidates()
        let repoModels = try #require(candidates.first {
            FileManager.default.fileExists(
                atPath: $0.deletingLastPathComponent()
                    .appendingPathComponent("Package.swift").path)
        })
        #expect(repoModels.lastPathComponent == WhisperModelCatalog.relativeModelsPath)
        #expect(candidates.firstIndex(of: repoModels) != 0)
    }

    /// The picking rule, asserted as an invariant rather than against a fixed
    /// machine state: whichever candidate is the FIRST to hold a usable model is
    /// the one `defaultSearchRoot` returns. Holds on a machine with weights
    /// installed and on a bare checkout alike.
    @Test("The first candidate holding a usable model is the one chosen")
    func firstStockedCandidateWins() throws {
        let candidates = WhisperModelCatalog.searchRootCandidates()
        let stocked = candidates.first {
            !WhisperModelCatalog(searchRoot: $0).installedModels().isEmpty
        }
        let resolved = WhisperModelCatalog.defaultSearchRoot(environment: [:])
        if let stocked {
            #expect(resolved == stocked)
        } else {
            // Nothing installed anywhere: it still resolves to a real candidate
            // so the teaching error can name a directory, never to nil.
            #expect(resolved != nil)
            #expect(candidates.contains(try #require(resolved)))
        }
    }

    /// m23-n3d: the BUNDLED candidate — the one `scripts/bundle.sh
    /// --with-weights` exists to populate. NOTHING covered it before this item:
    /// the three tests above pin Application Support, the repo walk-up, and the
    /// picking rule, so a bundle-relative candidate that quietly went missing
    /// would leave all of them green while every `--with-weights` build shipped
    /// ~1.5 GB of weights the app then ignored — a silent, expensive no-op.
    ///
    /// Asserted against a REAL .app directory laid out exactly as bundle.sh
    /// lays one out (`Contents/Resources/Models/<variant>/…`), so the script's
    /// destination and the resolver's expectation are pinned against each
    /// other rather than each against itself. The fixture is kilobytes: the
    /// recognition rule is purely structural — `componentURL` only checks that
    /// the `.mlmodelc` EXISTS, nothing reads model bytes.
    @Test("Weights sealed into a bundle are found there: candidate present, SECOND, and recognized")
    func bundledWeightsAreResolvedInsideTheApp() throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("n3d-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let app = tmp.appendingPathComponent("DAWPro.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        // Exactly bundle.sh's `cp -R` destination.
        let models = resources.appendingPathComponent(
            WhisperModelCatalog.relativeModelsPath, isDirectory: true)
        let variantName = "openai_whisper-tiny.en"
        let variant = models.appendingPathComponent(variantName, isDirectory: true)
        try fm.createDirectory(at: variant, withIntermediateDirectories: true)
        for component in WhisperModelCatalog.requiredComponents {
            try fm.createDirectory(
                at: variant.appendingPathComponent("\(component).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true)
        }
        let tokenizer = models.appendingPathComponent(
            WhisperModelCatalog.tokenizerDirectoryName, isDirectory: true)
        try fm.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: tokenizer.appendingPathComponent(WhisperModelCatalog.tokenizerFileName))
        // Minimal Info.plist so CFBundle accepts the directory as a bundle.
        try PropertyListSerialization
            .data(fromPropertyList: ["CFBundleIdentifier": "com.dawpro.n3d-fixture"],
                  format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let bundle = try #require(Bundle(url: app), "the fixture is a real bundle")

        // 1. The bundled candidate exists and lands where bundle.sh copies to.
        let bundled = try #require(WhisperModelCatalog.bundledModelsDirectory(bundle: bundle))
        #expect(bundled.lastPathComponent == WhisperModelCatalog.relativeModelsPath)
        #expect(bundled.resolvingSymlinksInPath() == models.resolvingSymlinksInPath())

        // 2. It sits SECOND — behind Application Support, so a user download
        //    can upgrade a shipped default without reinstalling the app, and
        //    ahead of the dev-only repo walk-up.
        let candidates = WhisperModelCatalog.searchRootCandidates(bundle: bundle)
        #expect(candidates.count >= 2)
        #expect(candidates[0] == WhisperModelCatalog.applicationSupportModelsDirectory())
        #expect(candidates[1] == bundled)

        // 3. The sealed copy is actually RECOGNIZED, not merely pointed at —
        //    the difference between a path that resolves and weights that load.
        let installed = WhisperModelCatalog(searchRoot: bundled).installedModels()
        #expect(installed.map(\.variantDirectoryName) == [variantName])
    }

    /// An empty higher-priority directory must NOT shadow a stocked lower one —
    /// the rule is "first STOCKED", not "first that exists". This pins the exact
    /// predicate `defaultSearchRoot` walks the chain with: an existing but empty
    /// directory reports no installed models, so the walk continues past it.
    @Test("An existing but empty directory reports nothing, so the chain walks on")
    func emptyDirectoryDoesNotShadow() throws {
        let empty = try ModelFixture()
        defer { empty.destroy() }
        // Exists, but holds no variant.
        #expect(WhisperModelCatalog(searchRoot: empty.root).installedModels().isEmpty)

        let stocked = try ModelFixture()
        defer { stocked.destroy() }
        try stocked.makeVariant("openai_whisper-tiny")
        try stocked.makeSharedTokenizer()
        #expect(!WhisperModelCatalog(searchRoot: stocked.root).installedModels().isEmpty)
    }
}

// MARK: - m23-n3f: can this variant produce WORD timings at all?

/// THE ABSENT CASE, exercised (the m23-n3b law).
///
/// WhisperKit's word timings come from DTW over a cross-attention tensor the
/// compiled decoder has to declare as an output; `TranscribeTask.swift:198-200`
/// guards that whole branch behind `if let alignmentWeights = …` with **no
/// else**, so a variant compiled without it returns `words: []` and never an
/// error. The one variant installed on this machine HAS the output — so a test
/// written against the real model could only ever prove the TRUE direction and
/// would pass while proving nothing. Every leg below is a synthesized fixture
/// for that reason, and the one leg that does read the real install is guarded
/// and read-only, there to defend the FIXTURE SHAPE against drift rather than
/// to carry the item.
@Suite("WhisperModelCatalog — word-timestamp capability (m23-n3f)")
struct WhisperModelCatalogWordTimestampTests {

    // MARK: The two directions

    @Test("A decoder that declares the alignment output reports true, all three ways")
    func capabilityPresentIsReported() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant(
            "openai_whisper-large-v3-v20240930_turbo",
            decoderMetadata: ModelFixture.decoderMetadataJSON(
                outputs: ModelFixture.realDecoderOutputs))
        try fixture.makeSharedTokenizer()
        let folder = fixture.root.appendingPathComponent("openai_whisper-large-v3-v20240930_turbo")

        // The raw read parsed — not "unknown", which would make the next two
        // assertions pass for the wrong reason.
        #expect(WhisperModelCatalog.declaredOutputNames(
            ofCompiledModelAt: folder.appendingPathComponent("TextDecoder.mlmodelc"))
            == ModelFixture.realDecoderOutputs)
        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == true)

        let model = try fixture.catalog.resolveModel()
        #expect(model.supportsWordTimestamps)
        #expect(model.wordTimestampsUnavailableExplanation == nil)
    }

    /// **THE GATE.** A decoder metadata WITHOUT `alignment_heads_weights` — but
    /// WITH the other three real outputs, so an implementation that reports
    /// false for an empty/unparsed schema cannot pass this by accident.
    @Test("A decoder that declares everything EXCEPT the alignment output reports false")
    func capabilityAbsentIsReported() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant(
            "openai_whisper-base",
            decoderMetadata: ModelFixture.decoderMetadataJSON(
                outputs: ModelFixture.decoderOutputsWithoutAlignment))
        try fixture.makeSharedTokenizer()
        let folder = fixture.root.appendingPathComponent("openai_whisper-base")

        // The read SUCCEEDED and the answer is no — the distinction the whole
        // three-state design exists to keep.
        #expect(WhisperModelCatalog.declaredOutputNames(
            ofCompiledModelAt: folder.appendingPathComponent("TextDecoder.mlmodelc"))
            == ModelFixture.decoderOutputsWithoutAlignment)
        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == false)
        #expect(WhisperModelCatalog.supportsWordTimestamps(inFolder: folder) == false)

        let model = try fixture.catalog.resolveModel()
        #expect(!model.supportsWordTimestamps)

        // ...and the model is still USABLE. A missing capability is reported,
        // never enforced — the `hasContextPrefill` contract exactly.
        #expect(fixture.catalog.installedModels().map(\.variantDirectoryName) == ["openai_whisper-base"])
        #expect(fixture.catalog.incompleteModels().isEmpty)
    }

    /// The teaching message, not merely a `false`: what is wrong, WHERE it was
    /// inspected, and what to do — `WhisperModelError.errorDescription`'s voice.
    @Test("The false case carries a teaching message naming the variant, the path and the fix")
    func absenceTeaches() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant(
            "openai_whisper-base",
            decoderMetadata: ModelFixture.decoderMetadataJSON(
                outputs: ModelFixture.decoderOutputsWithoutAlignment))
        try fixture.makeSharedTokenizer()

        let model = try fixture.catalog.resolveModel()
        let message = try #require(model.wordTimestampsUnavailableExplanation)
        #expect(message.contains("openai_whisper-base"))
        #expect(message.contains(model.modelFolder.path))
        #expect(message.contains(WhisperModelCatalog.wordTimestampAlignmentOutputName))
        #expect(message.contains(WhisperModelCatalog.textDecoderComponentName))
        // It must say what to DO, and it must not imply the whole transcript is
        // worthless — segment timings survive, and a beginner needs to know.
        #expect(message.contains("ai.installSpeechModel"))
        #expect(message.contains("SEGMENT"))
    }

    // MARK: Discriminators against a cheaper implementation

    /// Kills "search the file's text for the tensor name": here the name appears
    /// in the metadata, but as an INPUT. Declaring it as an input is not
    /// declaring it as an output, and only an output feeds the DTW.
    @Test("The name appearing only in the INPUT schema still reports false")
    func namePresentOnlyAsAnInputIsStillFalse() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant(
            "openai_whisper-tiny",
            decoderMetadata: ModelFixture.decoderMetadataJSON(
                outputs: ModelFixture.decoderOutputsWithoutAlignment,
                inputs: ["encoder_output_embeds", WhisperModelCatalog.wordTimestampAlignmentOutputName]))
        try fixture.makeSharedTokenizer()
        let folder = fixture.root.appendingPathComponent("openai_whisper-tiny")

        // Proof the fixture really does mention it, so a false read here means
        // the check ignored the input schema rather than that nothing was there.
        let raw = try String(
            contentsOf: folder.appendingPathComponent(
                "TextDecoder.mlmodelc/\(WhisperModelCatalog.compiledModelMetadataFileName)"),
            encoding: .utf8)
        #expect(raw.contains(WhisperModelCatalog.wordTimestampAlignmentOutputName))
        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == false)
    }

    /// Kills a prefix/substring name test: `alignment_heads` is not
    /// `alignment_heads_weights`, and a decoder declaring only the former cannot
    /// produce word timings.
    @Test("A near-miss output name reports false — exact match, not a prefix")
    func nearMissOutputNameIsFalse() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant(
            "openai_whisper-tiny",
            decoderMetadata: ModelFixture.decoderMetadataJSON(
                outputs: ModelFixture.decoderOutputsWithoutAlignment + ["alignment_heads"]))
        try fixture.makeSharedTokenizer()
        let folder = fixture.root.appendingPathComponent("openai_whisper-tiny")

        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == false)
    }

    // MARK: Resilience — unknown is UNKNOWN, and never fatal

    /// The default-direction pin. A model with no `metadata.json` at all is the
    /// COMMON case in this suite's own fixtures and, more importantly, the case
    /// for anything not shipped as a compiled `.mlmodelc`. It must read as
    /// "did not determine" (`nil`) and resolve optimistically — asserting `nil`
    /// and not merely `true`, because a parser that always answered `true` would
    /// satisfy a `true`-only assertion here AND in the present-capability leg.
    @Test("No metadata.json: unknown, optimistic, and still perfectly usable")
    func missingMetadataIsUnknownNotFalse() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-tiny")   // no decoderMetadata
        try fixture.makeSharedTokenizer()
        let folder = fixture.root.appendingPathComponent("openai_whisper-tiny")

        #expect(WhisperModelCatalog.declaredOutputNames(
            ofCompiledModelAt: folder.appendingPathComponent("TextDecoder.mlmodelc")) == nil)
        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == nil)
        #expect(WhisperModelCatalog.supportsWordTimestamps(inFolder: folder))

        let model = try fixture.catalog.resolveModel()
        #expect(model.supportsWordTimestamps)
        #expect(model.wordTimestampsUnavailableExplanation == nil)
        #expect(model.modelSizeBytes == ModelFixture.fullVariantBytes)
    }

    /// Every way the file can be there and useless. None of them may crash, and
    /// none of them may cost the model its usability — the resilience rule
    /// stated on `supportsWordTimestamps(inFolder:)`.
    @Test(
        "Unreadable or unrecognized metadata is unknown, never fatal",
        arguments: [
            "{not json at all",                                  // invalid JSON
            "",                                                  // empty file
            "[]",                                                // array, no element
            "[{}]",                                              // element, no schema
            "[{\"outputSchema\": \"not-an-array\"}]",            // schema of the wrong type
            "[{\"outputSchema\": []}]",                          // no outputs at all
            "[{\"outputSchema\": [{\"type\": \"MultiArray\"}]}]", // entries with no name
            "\"just a string\"",                                 // valid JSON, wrong everything
        ])
    func malformedMetadataIsUnknownAndHarmless(rawMetadata: String) throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-tiny", decoderMetadata: rawMetadata)
        try fixture.makeSharedTokenizer()
        let folder = fixture.root.appendingPathComponent("openai_whisper-tiny")

        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == nil)
        #expect(WhisperModelCatalog.supportsWordTimestamps(inFolder: folder))

        // Still a model, still resolvable, no teaching noise.
        let model = try fixture.catalog.resolveModel()
        #expect(model.variantDirectoryName == "openai_whisper-tiny")
        #expect(model.supportsWordTimestamps)
        #expect(model.wordTimestampsUnavailableExplanation == nil)
        #expect(fixture.catalog.incompleteModels().isEmpty)
    }

    /// The `.mlpackage` form `componentURL` also accepts carries no
    /// `metadata.json` anywhere — so it is UNKNOWABLE by construction, and the
    /// honest answer is `nil`. This is the concrete reason unknown must not read
    /// as `false`: it would fire the warning at every `.mlpackage` variant,
    /// including ones that do have the output.
    @Test("An .mlpackage variant is unknowable, so it is unknown — not incapable")
    func packageFormIsUnknown() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        try fixture.makeVariant("openai_whisper-base", compiled: false)
        try fixture.makeSharedTokenizer()
        let folder = fixture.root.appendingPathComponent("openai_whisper-base")

        // Sanity: it IS a resolvable model in that form (acceptsPackageForm).
        let model = try fixture.catalog.resolveModel()
        #expect(model.variantDirectoryName == "openai_whisper-base")
        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == nil)
        #expect(model.supportsWordTimestamps)
        #expect(model.wordTimestampsUnavailableExplanation == nil)
    }

    // MARK: The premise, against the real install

    /// GUARDED and READ-ONLY. Every other leg here is shaped by MY reading of
    /// coremltools' metadata format; if that reading is wrong, they would all
    /// agree with each other and be wrong together. This one leg parses the real
    /// installed decoder, so fixture-shape drift shows up as a failure instead
    /// of as unanimous fiction. Skipped (not failed) when that variant is not
    /// installed: it pins a premise about a specific measured artifact, and a
    /// machine without it is a legitimate state, not a regression.
    @Test("PREMISE: the real installed turbo decoder declares the alignment output")
    func realInstalledDecoderDeclaresTheAlignmentOutput() throws {
        let variantName = "openai_whisper-large-v3-v20240930_turbo"
        let folder = WhisperModelCatalog.applicationSupportModelsDirectory()
            .appendingPathComponent(variantName, isDirectory: true)
        guard let decoder = WhisperModelCatalog.componentURL(
                inFolder: folder, named: WhisperModelCatalog.textDecoderComponentName),
              FileManager.default.fileExists(
                atPath: decoder
                    .appendingPathComponent(WhisperModelCatalog.compiledModelMetadataFileName).path)
        else { return }

        let names = try #require(
            WhisperModelCatalog.declaredOutputNames(ofCompiledModelAt: decoder),
            "the real metadata.json must parse in the shape the fixtures imitate")
        #expect(names.contains("logits"))
        #expect(names.contains(WhisperModelCatalog.wordTimestampAlignmentOutputName))
        #expect(WhisperModelCatalog.declaredWordTimestampSupport(inFolder: folder) == true)
    }
}

// MARK: - m23-ef: unknown survives as a THIRD STATE instead of collapsing

/// m23-n3f resolved unknown → `true` and said so out loud; m23-ef's whole job is
/// that the collapse is no longer LOSSY. Two claims, and the second is the one
/// that can silently rot:
///
///   1. `.unknown` is reachable, distinct, and carries its own wording;
///   2. **`supportsWordTimestamps` still reads `true` for it.** The item
///      explicitly forbids flipping that default, so every leg below that
///      exercises `.unknown` also asserts the `Bool`. A change of policy would
///      then have to walk past a test that names the policy, not merely past a
///      test that happened to depend on it.
@Suite("WhisperModelCatalog — unknown is a third state, not a `true` (m23-ef)")
struct WhisperModelCatalogUnknownStateTests {

    /// One fixture per state, resolved through the real `inspect` path so the
    /// descriptor's value is the catalog's, not a value a test handed itself.
    private func resolved(
        _ metadata: String?,
        compiled: Bool = true,
        variant: String = "openai_whisper-tiny",
        fixture: ModelFixture
    ) throws -> WhisperModelDescriptor {
        try fixture.makeVariant(variant, compiled: compiled, decoderMetadata: metadata)
        try fixture.makeSharedTokenizer()
        return try fixture.catalog.resolveModel()
    }

    @Test("The three reads agree, state for state — supported / unsupported / unknown")
    func allThreeStatesRoundTripFromDisk() throws {
        // .supported — the decoder said yes.
        let a = try ModelFixture()
        defer { a.destroy() }
        let capable = try resolved(
            ModelFixture.decoderMetadataJSON(outputs: ModelFixture.realDecoderOutputs), fixture: a)
        #expect(WhisperModelCatalog.wordTimestampSupport(
            inFolder: capable.modelFolder) == .supported)
        #expect(capable.wordTimestampSupport == .supported)
        #expect(capable.supportsWordTimestamps)
        #expect(capable.wordTimestampsUnavailableExplanation == nil)
        #expect(capable.wordTimestampsUnverifiedExplanation == nil)

        // .unsupported — the decoder said no. The ONLY warning state.
        let b = try ModelFixture()
        defer { b.destroy() }
        let incapable = try resolved(
            ModelFixture.decoderMetadataJSON(outputs: ModelFixture.decoderOutputsWithoutAlignment),
            fixture: b)
        #expect(WhisperModelCatalog.wordTimestampSupport(
            inFolder: incapable.modelFolder) == .unsupported)
        #expect(incapable.wordTimestampSupport == .unsupported)
        #expect(!incapable.supportsWordTimestamps)
        #expect(incapable.wordTimestampsUnavailableExplanation != nil)
        // Not BOTH messages — an unsupported model is not also unverified.
        #expect(incapable.wordTimestampsUnverifiedExplanation == nil)

        // .unknown — nothing on disk to ask. Reads capable, says so hedged.
        let c = try ModelFixture()
        defer { c.destroy() }
        let unknown = try resolved(nil, fixture: c)
        #expect(WhisperModelCatalog.wordTimestampSupport(
            inFolder: unknown.modelFolder) == .unknown)
        #expect(unknown.wordTimestampSupport == .unknown)
        // ⚠️ THE FORBIDDEN FLIP. m23-ef must not turn unknown into a warning.
        #expect(unknown.supportsWordTimestamps)
        #expect(WhisperModelCatalog.supportsWordTimestamps(inFolder: unknown.modelFolder))
        #expect(unknown.wordTimestampsUnavailableExplanation == nil)
        #expect(unknown.wordTimestampsUnverifiedExplanation != nil)
    }

    /// The `.mlpackage` shape is the concrete case m23-ef was filed for: the
    /// residue m23-n3f could not close. It must reach `.unknown` through the
    /// real resolution path, not merely through the static helper.
    @Test("An .mlpackage variant resolves to .unknown, still usable, still optimistic")
    func packageFormResolvesToUnknown() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        let model = try resolved(
            nil, compiled: false, variant: "openai_whisper-base", fixture: fixture)

        #expect(model.wordTimestampSupport == .unknown)
        #expect(model.supportsWordTimestamps)
        #expect(fixture.catalog.incompleteModels().isEmpty)
        #expect(fixture.catalog.installedModels().count == 1)
    }

    /// Malformed metadata is unknown too — same state, a different route in.
    /// (Kept minimal: m23-n3f's own suite already enumerates every malformed
    /// shape against `declaredWordTimestampSupport`; this pins that the NEW
    /// mapping does not special-case any of them.)
    @Test(
        "Every malformed-metadata shape maps to .unknown as well",
        arguments: ["{not json at all", "", "[]", "[{}]", "[{\"outputSchema\": []}]"])
    func malformedMetadataMapsToUnknown(rawMetadata: String) throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        let model = try resolved(rawMetadata, fixture: fixture)

        #expect(model.wordTimestampSupport == .unknown)
        #expect(model.supportsWordTimestamps)
    }

    /// The wording, and its voice. It must NOT read as a verdict — the whole
    /// point of the third state is that the model never answered.
    @Test("The unknown wording names the variant, the path and the next action, and hedges")
    func unknownWordingTeachesWithoutAccusing() throws {
        let fixture = try ModelFixture()
        defer { fixture.destroy() }
        let model = try resolved(nil, variant: "openai_whisper-base", fixture: fixture)

        let message = try #require(model.wordTimestampsUnverifiedExplanation)
        #expect(message.contains("openai_whisper-base"))
        #expect(message.contains(model.modelFolder.path))
        #expect(message.contains(WhisperModelCatalog.wordTimestampAlignmentOutputName))
        #expect(message.contains(WhisperModelCatalog.compiledModelMetadataFileName))
        #expect(message.contains("ai.installSpeechModel"))
        // Hedged, not accusing: the `.unsupported` message asserts the model
        // "produces no word timings"; this one may not, because nobody asked it.
        #expect(!message.contains("produces no word timings"))
        #expect(message.contains("did not say"))
        // And it still promises the transcript is worth having.
        #expect(message.contains("SEGMENT"))
    }

    /// The wording must name the component that is REALLY on disk. `.unknown`
    /// is dominated by the `.mlpackage` layout — that is the whole reason the
    /// state exists — and that layout's directory is NOT `TextDecoder.mlmodelc`,
    /// so a hard-coded compiled name would point a reader at the right folder
    /// and the wrong directory. The two legs differ ONLY in `compiled:`, which
    /// is what makes this a discriminating test rather than a spelling check.
    @Test("The unknown wording names the decoder actually on disk, .mlmodelc or .mlpackage")
    func unknownWordingNamesTheResolvedDecoder() throws {
        let packageFixture = try ModelFixture()
        defer { packageFixture.destroy() }
        let packageForm = try resolved(nil, compiled: false, fixture: packageFixture)
        let packageMessage = try #require(packageForm.wordTimestampsUnverifiedExplanation)
        #expect(packageMessage.contains("TextDecoder.mlpackage"))
        #expect(!packageMessage.contains("TextDecoder.mlmodelc"))

        // The compiled form reaches `.unknown` too — a metadata.json that is
        // absent or unparseable — and there the compiled name is the right one.
        let compiledFixture = try ModelFixture()
        defer { compiledFixture.destroy() }
        let compiledForm = try resolved(nil, compiled: true, fixture: compiledFixture)
        let compiledMessage = try #require(compiledForm.wordTimestampsUnverifiedExplanation)
        #expect(compiledMessage.contains("TextDecoder.mlmodelc"))
        #expect(!compiledMessage.contains("TextDecoder.mlpackage"))
    }

    /// The structural claim: `supportsWordTimestamps` is DERIVED, so no
    /// construction can make the two disagree. Exercised through the
    /// convenience `Bool` initializer that m23-n3f's call sites still use.
    @Test("The Bool and the state cannot disagree, whichever initializer is used")
    func boolAndStateAreOneValue() {
        let base = URL(fileURLWithPath: "/private/tmp/m23ef-\(UUID().uuidString)")
        func make(_ support: WordTimestampSupport) -> WhisperModelDescriptor {
            WhisperModelDescriptor(
                variantDirectoryName: "v", displayName: "v",
                modelFolder: base, tokenizerFolder: base,
                modelSizeBytes: 1, tokenizerSizeBytes: 1,
                hasContextPrefill: false, wordTimestampSupport: support)
        }
        func makeLegacy(_ flag: Bool) -> WhisperModelDescriptor {
            WhisperModelDescriptor(
                variantDirectoryName: "v", displayName: "v",
                modelFolder: base, tokenizerFolder: base,
                modelSizeBytes: 1, tokenizerSizeBytes: 1,
                hasContextPrefill: false, supportsWordTimestamps: flag)
        }
        #expect(make(.supported).supportsWordTimestamps)
        #expect(make(.unknown).supportsWordTimestamps)
        #expect(!make(.unsupported).supportsWordTimestamps)
        // The m23-n3f initializer still means exactly what it meant, and lands
        // on the two states a Bool can honestly express — never `.unknown`.
        #expect(makeLegacy(true).wordTimestampSupport == .supported)
        #expect(makeLegacy(false).wordTimestampSupport == .unsupported)
        #expect(makeLegacy(true) == make(.supported))
        #expect(makeLegacy(false) == make(.unsupported))
    }
}

// MARK: - m23-ef: the descriptor's encoded shape, key by key

/// `WhisperModelDescriptor` is hand-`Codable` since m23-ef, because
/// `supportsWordTimestamps` became computed and synthesis encodes STORED
/// properties only — which would have deleted a live field from
/// `ai.installSpeechModel` / `ai.speechModelInstallStatus`.
///
/// **Asserting the exact key SET, not just presence, is the point.** Hand-written
/// `encode(to:)` trades one silent-rot vector for another: the next stored
/// property added to the descriptor would simply not appear on the wire and
/// nothing would notice. A set comparison notices.
@Suite("WhisperModelDescriptor — encoded wire shape (m23-ef)")
struct WhisperModelCatalogEncodingTests {

    private func descriptor(_ support: WordTimestampSupport) -> WhisperModelDescriptor {
        WhisperModelDescriptor(
            variantDirectoryName: "openai_whisper-base",
            displayName: "base",
            modelFolder: URL(fileURLWithPath: "/private/tmp/m23ef/openai_whisper-base"),
            tokenizerFolder: URL(fileURLWithPath: "/private/tmp/m23ef/tokenizer"),
            modelSizeBytes: 1024,
            tokenizerSizeBytes: 128,
            hasContextPrefill: true,
            wordTimestampSupport: support)
    }

    private func encodedObject(_ model: WhisperModelDescriptor) throws -> [String: Any] {
        let data = try JSONEncoder().encode(model)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Exactly these keys — the m23-n3f set plus wordTimestampSupport, nothing dropped")
    func encodedKeySetIsExact() throws {
        let object = try encodedObject(descriptor(.unknown))
        #expect(Set(object.keys) == [
            "variantDirectoryName",
            "displayName",
            "modelFolder",
            "tokenizerFolder",
            "modelSizeBytes",
            "tokenizerSizeBytes",
            "hasContextPrefill",
            "supportsWordTimestamps",
            "wordTimestampSupport",
        ])
        // MEASURED, not assumed: `totalSizeBytes` / `formattedTotalSize` are
        // computed and have NEVER been encoded — before m23-ef or after. The
        // control-protocol and MCP docs that listed them were wrong, and were
        // corrected at m23-ef rather than the payload being grown.
        #expect(object["totalSizeBytes"] == nil)
        #expect(object["formattedTotalSize"] == nil)
    }

    @Test("The live Bool still ships, and still reads `true` for unknown")
    func liveBooleanSurvivesTheThirdState() throws {
        #expect(try encodedObject(descriptor(.supported))["supportsWordTimestamps"] as? Bool == true)
        #expect(try encodedObject(descriptor(.unsupported))["supportsWordTimestamps"] as? Bool == false)
        // The additive promise AND the forbidden-flip guard in one place.
        #expect(try encodedObject(descriptor(.unknown))["supportsWordTimestamps"] as? Bool == true)
        #expect(try encodedObject(descriptor(.unknown))["wordTimestampSupport"] as? String == "unknown")
        #expect(try encodedObject(descriptor(.supported))["wordTimestampSupport"] as? String == "supported")
        #expect(try encodedObject(descriptor(.unsupported))["wordTimestampSupport"] as? String == "unsupported")
    }

    /// All three decode branches, because an unpinned branch is dead code.
    @Test("Decoding prefers the state, falls back to the legacy Bool, and calls neither unknown")
    func decodePrefersTheStateAndFallsBack() throws {
        func decode(_ tail: String) throws -> WhisperModelDescriptor {
            let json = """
                {"variantDirectoryName": "v", "displayName": "v", \
                "modelFolder": "file:///private/tmp/m23ef/v", \
                "tokenizerFolder": "file:///private/tmp/m23ef/tokenizer", \
                "modelSizeBytes": 1, "tokenizerSizeBytes": 2, "hasContextPrefill": false\(tail)}
                """
            return try JSONDecoder().decode(WhisperModelDescriptor.self, from: Data(json.utf8))
        }

        // 1. Both present and DISAGREEING: the three-state field wins, because
        //    it is the one that can express what the Bool cannot.
        let both = try decode(", \"supportsWordTimestamps\": true, \"wordTimestampSupport\": \"unsupported\"")
        #expect(both.wordTimestampSupport == .unsupported)
        #expect(!both.supportsWordTimestamps)

        // 2. m23-n3f-era payload: only the Bool.
        #expect(try decode(", \"supportsWordTimestamps\": false").wordTimestampSupport == .unsupported)
        #expect(try decode(", \"supportsWordTimestamps\": true").wordTimestampSupport == .supported)

        // 3. Pre-n3f payload: neither field. "Nobody said" IS unknown.
        let ancient = try decode("")
        #expect(ancient.wordTimestampSupport == .unknown)
        #expect(ancient.supportsWordTimestamps)
    }

    @Test("Round-trips through JSON unchanged, all three states")
    func roundTrips() throws {
        for support in [WordTimestampSupport.supported, .unsupported, .unknown] {
            let original = descriptor(support)
            let restored = try JSONDecoder().decode(
                WhisperModelDescriptor.self, from: JSONEncoder().encode(original))
            #expect(restored == original)
        }
    }

    /// The descriptor never travels alone: `ai.installSpeechModel` and
    /// `ai.speechModelInstallStatus` return it NESTED inside
    /// `WhisperModelInstallStatus`, and that is the object their documented
    /// response shape actually describes. Pinned separately because the
    /// enclosing type uses SYNTHESIZED `Codable` while the descriptor's is
    /// hand-written — a combination whose result is worth measuring rather than
    /// reasoning about, and the thing the control-protocol and MCP prose claim.
    @Test("Nested in the install status, the descriptor keeps exactly its own keys")
    func nestedInInstallStatusKeepsTheSameKeys() throws {
        let status = WhisperModelInstallStatus(
            state: .succeeded, variantDirectoryNameRequested: "base",
            descriptor: descriptor(.unknown))
        let object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(status)) as? [String: Any])
        let nested = try #require(object["descriptor"] as? [String: Any])

        #expect(Set(nested.keys) == [
            "variantDirectoryName",
            "displayName",
            "modelFolder",
            "tokenizerFolder",
            "modelSizeBytes",
            "tokenizerSizeBytes",
            "hasContextPrefill",
            "supportsWordTimestamps",
            "wordTimestampSupport",
        ])
        // The doc correction m23-ef made, MEASURED at the level the docs
        // describe: the enclosing synthesized encoder adds nothing, so these two
        // computed properties are absent from the wire here too.
        #expect(nested["totalSizeBytes"] == nil)
        #expect(nested["formattedTotalSize"] == nil)
        #expect(nested["wordTimestampSupport"] as? String == "unknown")
        #expect(nested["supportsWordTimestamps"] as? Bool == true)
    }
}
