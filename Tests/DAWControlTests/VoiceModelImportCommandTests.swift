import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for m23-di-2a `vc.importVoiceModel` — the
/// third-party RVC voice-model IMPORT. A pure local filesystem copy (no
/// sidecar HTTP call, no `VoiceConverting` seam), so this suite only needs a
/// bare `CommandRouter` with `voiceModelImportDirectory` pointed at a SCRATCH
/// temp dir — never `VoiceModelImport.voicesDirectory` itself, so a test run
/// never writes into the real Application Support tree (the
/// `VoiceConversionConvertCommandTests.makeStore()`/`generationImportsDirectory`
/// precedent). The copy mechanics themselves (slugify, overwrite, refusals)
/// are proven by `AIServicesTests/VoiceModelImportTests`; this suite proves
/// routing, param shape, response encoding, and that the wire never converts
/// `.pth` -> `.npz` (m23-di-2b's scope boundary).
@MainActor
@Suite("Voice model import — control protocol (m23-di-2a)")
struct VoiceModelImportCommandTests {
    private func scratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-import-cmd-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFile(_ name: String, in dir: URL, bytes: [UInt8] = [0x50, 0x54, 0x48]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeRouter(voicesDirectory: URL) -> CommandRouter {
        CommandRouter(store: ProjectStore(), voiceModelImportDirectory: voicesDirectory)
    }

    // MARK: - Canonical list

    @Test("vc.importVoiceModel is in the canonical command list, additive at the end; count 173 -> 174")
    func commandIsCanonical() {
        #expect(CommandRouter.allCommands.contains("vc.importVoiceModel"))
        #expect(CommandRouter.allCommands.dropLast(6).last == "vc.importVoiceModel")
        // m25-d appended transport.setStopAtContentEnd at the END (same law).
        #expect(CommandRouter.allCommands.dropLast(5).last == "transport.setStopAtContentEnd")
        // m25-z appended audio.profileFile at the END (same law).
        #expect(CommandRouter.allCommands.dropLast(4).last == "audio.profileFile")
        // m23-ap-3 appended clip.detectPitch at the END (same law).
        #expect(CommandRouter.allCommands.dropLast(3).last == "clip.detectPitch")
        // m26-k appended edit.pasteClips at the END (same law).
        #expect(CommandRouter.allCommands.dropLast(2).last == "edit.pasteClips")
        // m24-n appended project.embeddedVoices then vc.installEmbeddedVoice
        // at the END (same law).
        #expect(CommandRouter.allCommands.dropLast().last == "project.embeddedVoices")
        #expect(CommandRouter.allCommands.last == "vc.installEmbeddedVoice")
        #expect(CommandRouter.allCommands.count == 231)   // 177 at m23-ap-3 -> 178 (clip.getNotes) -> 179 (m26-i instrument.describeSampler) -> 180 (edit.pasteClips) -> 181 (m27 leg D clip.applyBreathContour, placed next to its controller-lane siblings, NOT at the tail) -> 182 (breath pad P1 clip.applyEffortShape, placed next to clip.applyBreathContour, NOT at the tail) -> 183 (breath pad P6 pad.previewEffort, placed next to note.audition — the other 'sounds now, outside the timeline, not an edit' verb — NOT at the tail) -> 186 (m28-knob midi.getControlMap/setControlMap/learnControl, placed next to midi.listInputs — their only sibling on this surface — and BEFORE transport.record, NOT at the tail) -> 187 (m31-f instrument.probeLiveness) -> 188 (m31-c clip.repeatNotes, placed next to clip.setNotes/clip.getNotes, NOT at the tail) -> 189 (m26-a/m27-n clip.patchNotes, placed next to clip.repeatNotes, NOT at the tail) -> 190 (m32-b2 clip.sliceToSampler, placed next to clip.detectTransients/clip.quantizeAudio, NOT at the tail) -> 191 (m24-m leg A vc.convertClips, placed next to vc.convertVocals — its single-clip sibling — NOT at the tail) -> 193 (m24-n project.embeddedVoices next to project.snapshot/project.open, and vc.installEmbeddedVoice next to vc.importVoiceModel, both at the tail per the additive-at-end law) -> 194 (m23-ct note.play, placed next to note.audition/pad.previewEffort — the other 'sounds now, outside the timeline' verbs — NOT at the tail; a tail append reddened 19 end-relative assertions across 7 files on this item's first run) -> 195 (m23-cv chord.voice, a PURE read-only computation, placed next to note.play and NOT at the tail: LivePlayCommandTests pins note.play to pad.previewEffort + 1, so an insertion BEFORE it would redden that instead) -> 202 (m34-c instrument.listDownloadableSoundBanks/downloadSoundBank/soundBankDownloadStatus/cancelSoundBankDownload — the one-click SoundFont download, all four placed next to instrument.importSoundBank — their nearest sibling — and NOT at the tail, so every dropLast(N) window above stays true by construction; a tail placement was tried first and reddened 14 tests) -> 211 (m34-h-1 LIVE LOOPING looper.begin/armLayer/finishLayer/undoLayer/setLayerMuted/status/end, all seven placed immediately after transport.recordLayer/finishLayer — the verbs whose machinery the deck drives — and ~71 entries from the END, NOT at the tail, so every dropLast(N) window and suffix assertion above stays true by construction) -> 215 (M35 view.capture/view.selectClip/view.panelLayout/view.openEditor, the agent-facing VIEW surface, all four placed immediately after plugin.listOpenUIs and ~70 entries from the END, NOT at the tail) -> 218 (m39-f instrument.describeSynth, placed next to instrument.describeSampler, NOT at the tail) -> 231 at m39-dm (instrument.setDrumParam/describeDrumKit/listDrumPresets/loadDrumPreset — the drum machine's four verbs, placed next to instrument.describeSynth/describeSampler, their only siblings on this surface, and NOT at the tail, so every dropLast(N) window and suffix assertion stays true by construction)
        // -> 187 (m31-f instrument.probeLiveness, placed next to instrument.describeSampler — its read-only instrument.* sibling — NOT at the tail)
        // Additive: the rest of the vc.* family is untouched.
        for name in ["vc.sidecarStatus", "vc.sidecarStart", "vc.sidecarStop",
                     "vc.convertVocals", "vc.trainVoice", "vc.listVoices"] {
            #expect(CommandRouter.allCommands.contains(name), "\(name) missing")
        }
    }

    // MARK: - Happy path

    @Test("modelPath alone: copies model.pth, lands needsConversion, hasIndex false")
    func importsModelOnly() async throws {
        let sourceDir = try scratchDir("src")
        let voicesDir = try scratchDir("dst")
        let modelPath = try writeFile("my-voice.pth", in: sourceDir)
        let router = makeRouter(voicesDirectory: voicesDir)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: ["modelPath": .string(modelPath.path)]))

        #expect(response.ok, "vc.importVoiceModel failed: \(response.error ?? "?")")
        #expect(response.result?["voiceId"]?.stringValue == "my-voice")
        #expect(response.result?["name"]?.stringValue == "my-voice")
        #expect(response.result?["hasIndex"]?.boolValue == false)
        #expect(response.result?["state"]?.stringValue == "needsConversion")
        let directoryPath = try #require(response.result?["directoryPath"]?.stringValue)
        #expect(directoryPath == voicesDir.appendingPathComponent("my-voice").path)
        #expect(FileManager.default.fileExists(
            atPath: voicesDir.appendingPathComponent("my-voice/model.pth").path))
        // Never writes model.npz — the wire must not silently convert.
        #expect(!FileManager.default.fileExists(
            atPath: voicesDir.appendingPathComponent("my-voice/model.npz").path))
    }

    @Test("modelPath + indexPath + explicit voiceId/name: both files copied, hasIndex true")
    func importsModelAndIndexWithExplicitIds() async throws {
        let sourceDir = try scratchDir("src")
        let voicesDir = try scratchDir("dst")
        let modelPath = try writeFile("checkpoint.pth", in: sourceDir)
        let indexPath = try writeFile("checkpoint.index", in: sourceDir)
        let router = makeRouter(voicesDirectory: voicesDir)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: [
                "modelPath": .string(modelPath.path),
                "indexPath": .string(indexPath.path),
                "voiceId": .string("narrator"),
                "name": .string("Narrator"),
            ]))

        #expect(response.ok, "vc.importVoiceModel failed: \(response.error ?? "?")")
        #expect(response.result?["voiceId"]?.stringValue == "narrator")
        #expect(response.result?["name"]?.stringValue == "Narrator")
        #expect(response.result?["hasIndex"]?.boolValue == true)
        #expect(FileManager.default.fileExists(
            atPath: voicesDir.appendingPathComponent("narrator/model.index").path))
    }

    @Test("~-expansion applies to modelPath the same way vc.trainVoice's datasetDir does")
    func tildeExpansion() async throws {
        let voicesDir = try scratchDir("dst")
        let router = makeRouter(voicesDirectory: voicesDir)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: ["modelPath": .string("~/no-such-daw-pro-fixture-xyz.pth")]))
        // Expands to an absolute path under HOME, then fails honestly on
        // sourceNotFound (proves expansion happened rather than a bare
        // "must be absolute" refusal).
        #expect(!response.ok)
        #expect(response.error?.contains("no-such-daw-pro-fixture-xyz.pth") == true)
        #expect(response.error?.contains("must be an absolute path") != true)
    }

    // MARK: - Refusals

    @Test("relative modelPath is refused, naming the param")
    func relativeModelPathRefused() async throws {
        let voicesDir = try scratchDir("dst")
        let router = makeRouter(voicesDirectory: voicesDir)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: ["modelPath": .string("relative/path.pth")]))
        #expect(!response.ok)
        #expect(response.error == "'modelPath' must be an absolute path")
    }

    @Test("relative indexPath is refused, naming the param, even with a valid modelPath")
    func relativeIndexPathRefused() async throws {
        let sourceDir = try scratchDir("src")
        let voicesDir = try scratchDir("dst")
        let modelPath = try writeFile("v.pth", in: sourceDir)
        let router = makeRouter(voicesDirectory: voicesDir)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: [
                "modelPath": .string(modelPath.path),
                "indexPath": .string("relative.index"),
            ]))
        #expect(!response.ok)
        #expect(response.error == "'indexPath' must be an absolute path")
    }

    @Test("missing modelPath is a teaching error naming the param")
    func missingModelPathRefused() async throws {
        let voicesDir = try scratchDir("dst")
        let router = makeRouter(voicesDirectory: voicesDir)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel", params: [:]))
        #expect(!response.ok)
        #expect(response.error?.contains("modelPath") == true)
    }

    @Test("a modelPath that doesn't exist on disk fails with an actionable message, not a bare internal error")
    func sourceNotFoundSurfacesActionably() async throws {
        let voicesDir = try scratchDir("dst")
        let router = makeRouter(voicesDirectory: voicesDir)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: ["modelPath": .string("/no/such/model.pth")]))
        #expect(!response.ok)
        #expect(response.error?.contains("/no/such/model.pth") == true)
        #expect(response.error?.hasPrefix("internal error") != true)
    }

    @Test("the reserved 'base' id is refused at the wire, never silently imported")
    func reservedBaseRefusedAtWire() async throws {
        let sourceDir = try scratchDir("src")
        let voicesDir = try scratchDir("dst")
        let modelPath = try writeFile("v.pth", in: sourceDir)
        let router = makeRouter(voicesDirectory: voicesDir)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: ["modelPath": .string(modelPath.path), "voiceId": .string("base")]))
        #expect(!response.ok)
        #expect(response.error?.contains("base") == true)
        #expect(!FileManager.default.fileExists(atPath: voicesDir.appendingPathComponent("base").path))
    }

    @Test("re-importing the same voiceId without overwrite is refused; overwrite:true replaces it")
    func duplicateThenOverwrite() async throws {
        let sourceDir = try scratchDir("src")
        let voicesDir = try scratchDir("dst")
        let firstModel = try writeFile("v1.pth", in: sourceDir, bytes: [1])
        let router = makeRouter(voicesDirectory: voicesDir)

        let first = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: ["modelPath": .string(firstModel.path), "voiceId": .string("dup")]))
        #expect(first.ok)

        let second = await router.handle(ControlRequest(
            id: "2", command: "vc.importVoiceModel",
            params: ["modelPath": .string(firstModel.path), "voiceId": .string("dup")]))
        #expect(!second.ok)
        #expect(second.error?.contains("overwrite") == true)

        let secondModel = try writeFile("v2.pth", in: sourceDir, bytes: [2])
        let third = await router.handle(ControlRequest(
            id: "3", command: "vc.importVoiceModel",
            params: [
                "modelPath": .string(secondModel.path), "voiceId": .string("dup"),
                "overwrite": .bool(true),
            ]))
        #expect(third.ok, "overwrite failed: \(third.error ?? "?")")
        let copied = try Data(contentsOf: voicesDir.appendingPathComponent("dup/model.pth"))
        #expect(copied == Data([2]))
    }

    @Test("unknown parameter keys are rejected, naming the bad key and the valid ones")
    func unknownKeysRejected() async throws {
        let voicesDir = try scratchDir("dst")
        let router = makeRouter(voicesDirectory: voicesDir)
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.importVoiceModel",
            params: ["modelPath": .string("/tmp/x.pth"), "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
        #expect(response.error?.contains("vc.importVoiceModel") == true)
    }
}
