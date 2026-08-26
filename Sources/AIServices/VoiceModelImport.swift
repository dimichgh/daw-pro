import Foundation
import DAWCore

/// Third-party RVC voice-model IMPORT (m23-di-2a) — puts a user-supplied
/// `model.pth` (optionally with its companion `model.index`) into this app's
/// OWN voice store, so the RVC facade's plain-directory `_scan_voices()`
/// (`scripts/rvc/server.py:177`) picks it up as a real voice, honestly in
/// `"needsConversion"` state (`server.py:159-165` — a folder with `model.pth`
/// but no `model.npz`). `scripts/rvc/server.py:141`'s own comment names this
/// exact case ("user dropping in a third-party model folder") — this type is
/// wiring up a case the facade already handles, not adding a new one to it.
///
/// **Why not `scripts/rvc/runtime/voices/`.** That tree is READ-ONLY for this
/// project — never written to, regardless of whether a write would be "code"
/// or "data". `VOICES_DIR` is environment-overridable at the facade
/// (`server.py:66`, `Path(os.environ.get("RVC_VOICES_DIR", RUNTIME_DIR /
/// "voices"))`) and nothing in `Sources/` set it before this landed (checked:
/// the sidecar's own `run.sh` exports `RVC_RUNTIME_DIR` but never
/// `RVC_VOICES_DIR`, so the facade fell back to its in-checkout default).
/// `VoiceConversionManager.spawnAndPoll` now sets `RVC_VOICES_DIR` to
/// `voicesDirectory` below at every sidecar launch, so an import here and the
/// running facade's own scan always agree, whether the import happens before
/// or after the sidecar's first boot. The store was empty at the time this
/// landed, so the redirect orphans no existing voice — but it DOES mean a
/// voice someone hand-drops into the sidecar's own default directory (running
/// `scripts/rvc/run.sh` directly, outside the app) will not be found here;
/// that is the accepted cost of not writing into the read-only tree.
///
/// **What this deliberately does NOT do.** Never converts `.pth` -> `.npz`
/// (m23-di-2b, blocked on the user — no sidecar route exists for it, and
/// adding one means editing `scripts/rvc/server.py`, which is forbidden). An
/// imported voice lands honestly `"needsConversion"` — the same state
/// `vc.listVoices`/the Voice panel's "NEEDS PREP" chip (`VoicePanel.swift:208`)
/// already render for a partially-prepared voice.
///
/// ⚠️ **m23-fn — WHEN THAT CONVERSION STEP LANDS, IT MUST NOT USE
/// `tools/convert_pth_to_mlx.py` UNGUARDED.** That converter emits raw
/// `flow.flows.{0,2,4,6}` keys and has no flow-index logic; the loader's
/// `remap_keys` (`rvc_mlx/infer/infer_mlx.py:66-80`) then renames them
/// VERBATIM into `flow_0/2/4/6`, so of the model's four normalising-flow
/// coupling layers **two receive nothing and keep a fresh random draw on
/// every load, one sits in the wrong slot, and 36 checkpoint tensors are
/// discarded** — measured 18/0/18/0 of 19 declared parameters per slot.
/// Every `.npz` this project produces must therefore pass through
/// ``flowMappingCorrectorPath`` (or be produced by the vendored tree's OTHER,
/// correct converter, `tools/convert_rvc_model.py`, which implements the
/// documented `i // 2` mapping). The corrector is a pure key rename — no
/// tensor byte changes — and its output loads through the COMPLETELY
/// UNMODIFIED sidecar, because `remap_keys` only rewrites keys beginning
/// `flow.flows.` (plural) and leaves corrected `flow.flow_N.…` names alone.
public enum VoiceModelImport {
    /// Repo-relative path to the m23-fn flow-slot corrector, the one place the
    /// checkpoint→slot mapping is written in code we own.
    ///
    /// Named here rather than invoked because the `.pth` -> `.npz` step it
    /// guards is **m23-di-2b, which is blocked on the user's decision** about
    /// reaching into the fenced `scripts/rvc/` tree. This constant is the
    /// seam: when di-2b unblocks, the conversion runs the vendored converter
    /// and then pipes its output through this tool (`correct`), or verifies it
    /// with this tool (`inspect`) if a correct converter was used directly.
    /// Positioning it here means the fix cannot be orphaned by an import path
    /// written later — `VoiceModelFlowMappingSeamTests` pins the file's
    /// existence, that it still computes `i // 2`, that it is outside the
    /// fence, and this doc's naming of it.
    public static let flowMappingCorrectorPath = "scripts/rvc-model/flow_remap.py"

    /// The ONE voice-store directory this app uses — `AppDirectories`'s
    /// `.voiceModels` category. Handed to the RVC sidecar as `RVC_VOICES_DIR`
    /// at spawn; an import lands exactly where the facade's `_scan_voices()`
    /// looks.
    public static var voicesDirectory: URL {
        AppDirectories.applicationSupport(.voiceModels)
    }

    /// Reserved — collides with the smoke-test target `vc.convertVocals`/
    /// `availableVoiceTargets()` always prepends (`VoiceConverting.swift`).
    /// Refusing it here is reserved-identifier hygiene, not provenance
    /// gatekeeping: a `base.pth` import would otherwise produce TWO
    /// `"base"`-id descriptors (the builtin smoke target and the imported
    /// voice) and make `voiceId: "base"` on `vc.convertVocals` ambiguous.
    public static let reservedVoiceId = "base"

    public enum ImportError: LocalizedError, Equatable {
        case sourceNotFound(String)
        case sourceNotAFile(String)
        case invalidVoiceId(String)
        case reservedVoiceId(String)
        case alreadyExists(String)
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceNotFound(let path):
                return "no file found at '\(path)' — pass an absolute path to a real "
                    + "model (or index) file"
            case .sourceNotAFile(let path):
                return "'\(path)' is a directory, not a file — pass the model FILE itself"
            case .invalidVoiceId(let id):
                return "'\(id)' is not usable as a voice id — use letters, digits, '-' or "
                    + "'_' only (derive one from 'name', or pass 'voiceId' explicitly)"
            case .reservedVoiceId(let id):
                return "'\(id)' is the reserved smoke-test voice id — pass a different "
                    + "'voiceId' or 'name' for this import"
            case .alreadyExists(let id):
                return "a voice named '\(id)' already exists in the voice store — pass a "
                    + "different 'voiceId', or 'overwrite: true' to replace it"
            case .copyFailed(let detail):
                return "could not copy the model into the voice store: \(detail)"
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public let voiceId: String
        public let name: String
        public let hasIndex: Bool
        public let directoryPath: String
    }

    /// Copies `modelPath` (and, when given, `indexPath`) into
    /// `<voicesDirectory>/<voiceId>/model.pth` (`model.index`), plus a small
    /// `voice.json` (`{name, createdAt}` — the facade's own optional metadata
    /// shape, `server.py`'s `_voice_descriptor`) so the voice carries a
    /// friendly display name instead of just its id. Never writes
    /// `model.npz` — see the type doc's scope note.
    ///
    /// - Parameters:
    ///   - modelPath: absolute path to the source `.pth` file. Must exist and
    ///     be a regular file — the caller (the wire handler) is responsible
    ///     for tilde-expansion and the absolute-path check, the same split
    ///     `vc.trainVoice`'s `datasetDir` uses.
    ///   - indexPath: absolute path to a companion FAISS index, optional.
    ///   - voiceId: the store id this voice is listed under. Omit to derive
    ///     one from `name` (or, absent that, the model file's own stem),
    ///     sanitised to `[A-Za-z0-9-_]`.
    ///   - name: display name written into `voice.json`. Omit to use the same
    ///     stem `voiceId` derives from.
    ///   - overwrite: replace an existing voice at the resolved id instead of
    ///     refusing (the `ai.installSpeechModel` `overwrite` precedent).
    ///   - voicesDirectory: injectable for tests; defaults to the real store.
    @discardableResult
    public static func importModel(
        modelPath: String,
        indexPath: String? = nil,
        voiceId explicitVoiceId: String? = nil,
        name explicitName: String? = nil,
        overwrite: Bool = false,
        voicesDirectory: URL = VoiceModelImport.voicesDirectory,
        fileManager: FileManager = .default
    ) throws -> Result {
        try requireRegularFile(at: modelPath, fileManager: fileManager)
        if let indexPath {
            try requireRegularFile(at: indexPath, fileManager: fileManager)
        }

        let baseName = (modelPath as NSString).lastPathComponent
        let stem = (baseName as NSString).deletingPathExtension
        let displayName = (explicitName?.isEmpty == false) ? explicitName! : stem
        let resolvedVoiceId: String
        if let explicitVoiceId, !explicitVoiceId.isEmpty {
            resolvedVoiceId = explicitVoiceId
        } else {
            resolvedVoiceId = slugify(displayName)
        }
        guard isValidVoiceId(resolvedVoiceId) else {
            throw ImportError.invalidVoiceId(explicitVoiceId ?? resolvedVoiceId)
        }
        guard resolvedVoiceId != reservedVoiceId else {
            throw ImportError.reservedVoiceId(resolvedVoiceId)
        }

        let voiceDir = voicesDirectory.appendingPathComponent(resolvedVoiceId, isDirectory: true)
        if fileManager.fileExists(atPath: voiceDir.path) {
            guard overwrite else { throw ImportError.alreadyExists(resolvedVoiceId) }
            do {
                try fileManager.removeItem(at: voiceDir)
            } catch {
                throw ImportError.copyFailed(
                    "could not remove the existing voice at '\(voiceDir.path)' before "
                        + "overwriting it: \(error.localizedDescription)")
            }
        }

        do {
            try fileManager.createDirectory(at: voiceDir, withIntermediateDirectories: true)
            try fileManager.copyItem(
                atPath: modelPath, toPath: voiceDir.appendingPathComponent("model.pth").path)
            if let indexPath {
                try fileManager.copyItem(
                    atPath: indexPath, toPath: voiceDir.appendingPathComponent("model.index").path)
            }
            let metadata = VoiceMetadata(
                name: displayName, createdAt: ISO8601DateFormatter().string(from: Date()))
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: voiceDir.appendingPathComponent("voice.json"))
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        return Result(
            voiceId: resolvedVoiceId, name: displayName, hasIndex: indexPath != nil,
            directoryPath: voiceDir.path)
    }

    private static func requireRegularFile(at path: String, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ImportError.sourceNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw ImportError.sourceNotAFile(path)
        }
    }

    static func isValidVoiceId(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Lowercases, maps every non-`[a-z0-9-_]` run to a single `-`, and trims
    /// leading/trailing `-` — so a human display name like "My Cool Voice!"
    /// derives the id "my-cool-voice" rather than being rejected outright.
    static func slugify(_ raw: String) -> String {
        var result = ""
        var lastWasDash = false
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") {
                result.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct VoiceMetadata: Codable {
    let name: String
    let createdAt: String
}
