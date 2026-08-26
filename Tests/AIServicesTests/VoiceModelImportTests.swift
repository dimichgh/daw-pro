import Foundation
import Testing
@testable import AIServices

/// `VoiceModelImport` coverage (m23-di-2a) — the third-party RVC voice-model
/// import that lands a user-supplied `model.pth` (+ optional `model.index`)
/// into an app-owned voice store, honestly `needsConversion`. Every test uses
/// a SCRATCH temp `voicesDirectory` (never `VoiceModelImport.voicesDirectory`
/// itself), so this suite never touches the real Application Support tree —
/// the `WhisperModelInstallerTests` precedent.
@Suite("VoiceModelImport (m23-di-2a)")
struct VoiceModelImportTests {
    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-model-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A tiny fake "checkpoint" file — its bytes are never inspected, only
    /// its existence/location, since `_voice_descriptor` (server.py) decides
    /// `needsConversion` purely from `model.pth`'s PRESENCE.
    @discardableResult
    private func writeFile(_ name: String, in dir: URL, bytes: [UInt8] = [0x50, 0x54, 0x48]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Happy path

    @Test("imports model.pth alone: creates <voicesDir>/<id>/model.pth + voice.json, hasIndex false")
    func importsModelOnly() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("my-cool-voice.pth", in: sourceDir)

        let result = try VoiceModelImport.importModel(
            modelPath: modelPath.path, voicesDirectory: voicesDir)

        #expect(result.voiceId == "my-cool-voice")
        #expect(result.name == "my-cool-voice")
        #expect(result.hasIndex == false)

        let voiceDir = voicesDir.appendingPathComponent("my-cool-voice")
        #expect(result.directoryPath == voiceDir.path)
        #expect(FileManager.default.fileExists(atPath: voiceDir.appendingPathComponent("model.pth").path))
        #expect(!FileManager.default.fileExists(atPath: voiceDir.appendingPathComponent("model.index").path))
        // Never writes model.npz — the scope boundary (m23-di-2b is a
        // separate, user-blocked item): this import must never convert.
        #expect(!FileManager.default.fileExists(atPath: voiceDir.appendingPathComponent("model.npz").path))

        let metaData = try Data(contentsOf: voiceDir.appendingPathComponent("voice.json"))
        let meta = try JSONDecoder().decode([String: String].self, from: metaData)
        #expect(meta["name"] == "my-cool-voice")
        #expect(meta["createdAt"] != nil)
    }

    @Test("imports model.pth + model.index together: hasIndex true, both files copied verbatim")
    func importsModelAndIndex() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("singer.pth", in: sourceDir, bytes: [1, 2, 3])
        let indexPath = try writeFile("singer.index", in: sourceDir, bytes: [4, 5, 6, 7])

        let result = try VoiceModelImport.importModel(
            modelPath: modelPath.path, indexPath: indexPath.path, voicesDirectory: voicesDir)

        #expect(result.hasIndex)
        let voiceDir = URL(fileURLWithPath: result.directoryPath)
        #expect(try Data(contentsOf: voiceDir.appendingPathComponent("model.pth")) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: voiceDir.appendingPathComponent("model.index")) == Data([4, 5, 6, 7]))
    }

    @Test("explicit voiceId and name win over derivation from the file stem")
    func explicitVoiceIdAndName() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("checkpoint_epoch_500.pth", in: sourceDir)

        let result = try VoiceModelImport.importModel(
            modelPath: modelPath.path, voiceId: "narrator-1", name: "Narrator One",
            voicesDirectory: voicesDir)

        #expect(result.voiceId == "narrator-1")
        #expect(result.name == "Narrator One")
        #expect(FileManager.default.fileExists(
            atPath: voicesDir.appendingPathComponent("narrator-1/model.pth").path))
    }

    @Test("a display name with spaces/punctuation slugifies to a filesystem-safe id")
    func slugifiesDisplayName() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("model.pth", in: sourceDir)

        let result = try VoiceModelImport.importModel(
            modelPath: modelPath.path, name: "My Cool Voice!!", voicesDirectory: voicesDir)

        #expect(result.voiceId == "my-cool-voice")
    }

    // MARK: - Refusals

    @Test("a missing source file is refused, naming the path")
    func missingSourceRefused() throws {
        let voicesDir = try scratchDir()
        #expect(throws: VoiceModelImport.ImportError.self) {
            try VoiceModelImport.importModel(
                modelPath: "/no/such/file.pth", voicesDirectory: voicesDir)
        }
    }

    @Test("a directory passed as modelPath is refused, not silently treated as a file")
    func directorySourceRefused() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        do {
            try VoiceModelImport.importModel(modelPath: sourceDir.path, voicesDirectory: voicesDir)
            Issue.record("expected sourceNotAFile")
        } catch VoiceModelImport.ImportError.sourceNotAFile(let path) {
            #expect(path == sourceDir.path)
        }
    }

    @Test("a missing index file is refused even when modelPath is valid")
    func missingIndexRefused() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("v.pth", in: sourceDir)
        #expect(throws: VoiceModelImport.ImportError.self) {
            try VoiceModelImport.importModel(
                modelPath: modelPath.path, indexPath: "/no/such/file.index",
                voicesDirectory: voicesDir)
        }
        // Refusing the index must not have left a half-written voice dir.
        #expect(!FileManager.default.fileExists(atPath: voicesDir.appendingPathComponent("v").path))
    }

    @Test("the reserved smoke-test id 'base' is refused — not provenance gatekeeping, collision hygiene")
    func reservedBaseIdRefused() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("base.pth", in: sourceDir)
        do {
            try VoiceModelImport.importModel(modelPath: modelPath.path, voicesDirectory: voicesDir)
            Issue.record("expected reservedVoiceId when the derived id is 'base'")
        } catch VoiceModelImport.ImportError.reservedVoiceId(let id) {
            #expect(id == "base")
        }
        // Also refused when passed explicitly.
        #expect(throws: VoiceModelImport.ImportError.self) {
            try VoiceModelImport.importModel(
                modelPath: modelPath.path, voiceId: "base", voicesDirectory: voicesDir)
        }
    }

    @Test("an empty/unusable voiceId (all punctuation) is refused as invalid, not silently emptied")
    func invalidVoiceIdRefused() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("model.pth", in: sourceDir)
        #expect(throws: VoiceModelImport.ImportError.self) {
            try VoiceModelImport.importModel(
                modelPath: modelPath.path, voiceId: "!!!", voicesDirectory: voicesDir)
        }
    }

    @Test("importing into an id that already exists is refused without 'overwrite'")
    func existingVoiceRefusedWithoutOverwrite() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let modelPath = try writeFile("v.pth", in: sourceDir)
        try VoiceModelImport.importModel(
            modelPath: modelPath.path, voiceId: "dup", voicesDirectory: voicesDir)
        #expect(throws: VoiceModelImport.ImportError.self) {
            try VoiceModelImport.importModel(
                modelPath: modelPath.path, voiceId: "dup", voicesDirectory: voicesDir)
        }
    }

    @Test("overwrite:true replaces an existing voice, including dropping a stale model.index")
    func overwriteReplacesExisting() throws {
        let sourceDir = try scratchDir()
        let voicesDir = try scratchDir()
        let firstModel = try writeFile("v1.pth", in: sourceDir, bytes: [1])
        let firstIndex = try writeFile("v1.index", in: sourceDir, bytes: [9])
        try VoiceModelImport.importModel(
            modelPath: firstModel.path, indexPath: firstIndex.path, voiceId: "dup",
            voicesDirectory: voicesDir)

        let secondModel = try writeFile("v2.pth", in: sourceDir, bytes: [2])
        let result = try VoiceModelImport.importModel(
            modelPath: secondModel.path, voiceId: "dup", overwrite: true,
            voicesDirectory: voicesDir)

        let voiceDir = URL(fileURLWithPath: result.directoryPath)
        #expect(try Data(contentsOf: voiceDir.appendingPathComponent("model.pth")) == Data([2]))
        // The stale index from the FIRST import must not survive a
        // model-only overwrite.
        #expect(!FileManager.default.fileExists(atPath: voiceDir.appendingPathComponent("model.index").path))
        #expect(result.hasIndex == false)
    }

    // MARK: - Default destination

    @Test("voicesDirectory resolves to <Application Support>/DAWPro/VoiceModels, computed not hardcoded")
    func voicesDirectoryShape() {
        // Pure path computation (AppDirectories.applicationSupport never
        // touches disk on the .absent DAWPRO_PROFILE_ROOT path this test
        // process runs on) — safe to assert without writing anywhere.
        #expect(VoiceModelImport.voicesDirectory.path.hasSuffix("DAWPro/VoiceModels"))
    }

    // MARK: - Slug helper (unit-level, no filesystem)

    @Test("slugify: lowercases, collapses runs of non-alphanumerics to one dash, trims edges")
    func slugifyBehavior() {
        #expect(VoiceModelImport.slugify("My Cool Voice!!") == "my-cool-voice")
        #expect(VoiceModelImport.slugify("  leading/trailing  ") == "leading-trailing")
        #expect(VoiceModelImport.slugify("already-valid_id123") == "already-valid_id123")
    }

    @Test("isValidVoiceId: accepts [A-Za-z0-9-_], rejects empty and dot-prefixed")
    func isValidVoiceIdBehavior() {
        #expect(VoiceModelImport.isValidVoiceId("abc-123_XYZ"))
        #expect(!VoiceModelImport.isValidVoiceId(""))
        #expect(!VoiceModelImport.isValidVoiceId(".hidden"))
        #expect(!VoiceModelImport.isValidVoiceId("has space"))
    }
}
