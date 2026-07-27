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

    func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath), withIntermediateDirectories: true)
    }

    /// A model directory WhisperKit would load. `omitting` drops one required
    /// component (the discriminator legs); `includePrefill` controls the
    /// optional one.
    func makeVariant(
        _ name: String,
        omitting: String? = nil,
        includePrefill: Bool = true,
        compiled: Bool = true
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

    /// The walk-up anchors on `Package.swift`, so under the test runner (cwd =
    /// package root) it must land on `<repo>/Models`. Asserted structurally, so
    /// it holds on any checkout and does not depend on the weights being there.
    @Test("With no override the location is <repo>/Models, found by Package.swift")
    func walkUpFindsRepoModels() throws {
        let root = try #require(WhisperModelCatalog.defaultSearchRoot(environment: [:]))
        #expect(root.lastPathComponent == WhisperModelCatalog.relativeModelsPath)
        let repo = root.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(
            atPath: repo.appendingPathComponent("Package.swift").path))
    }
}
