import Foundation

/// Where a converted vocal track's audio came from (m24-n).
///
/// ⭐ **A FACT, NOT A BINDING.** The user ruled twice, in one conversation, and
/// the two rulings pull against each other: *"Embed a copy of the voice"* (so a
/// project is self-contained and re-convertible elsewhere) and *"no need to
/// bind anything" / "we do not need to cache anything, just whenever we convert
/// we would just create a new track with newly generated vocals."* The
/// resolution this type implements: the generated track records WHICH VOICE
/// MADE IT, and embedding reads that record to know which voices to carry.
///
/// Everything this is NOT, spelled out because each would be a different
/// feature wearing the same field's clothes:
///  - **Not a live binding.** Nothing re-converts, re-renders or re-links when
///    the named voice changes, is deleted, or is replaced. The clips on the
///    track are ordinary audio clips; the user may edit, split, or delete them
///    and the provenance keeps describing where the audio originally came from.
///  - **Not a cache key.** No output is memoized against it and no comparison
///    of it ever invalidates anything. Converting again makes a NEW track (the
///    user's rule), which carries its own provenance.
///  - **Not a permission or rights record.** Rights are the user's
///    responsibility (policy reversed 2026-07-27); this names a voice id, not a
///    claim about it.
///  - **Not required.** A track with no provenance is an ordinary track. A
///    track WITH provenance naming a voice that no longer exists anywhere is a
///    normal state too: the audio still plays, and only RE-conversion is
///    unavailable.
///
/// `voiceName` is stored ALONGSIDE `voiceId` on purpose. The id is the store
/// key; the name is what the user recognises ("Kermit (Steve Whitmire)"), and
/// it must survive the voice's deletion — otherwise the one moment the record
/// matters most (the voice is gone; what WAS it?) is the one moment it can only
/// say `kermit`.
public struct VoiceProvenance: Codable, Sendable, Equatable {
    /// The voice-store id the conversion ran against (`vc.listVoices`'s `id`).
    public var voiceId: String
    /// The voice's display name AT CONVERSION TIME — a snapshot, deliberately
    /// not re-resolved on load (see the type doc).
    public var voiceName: String
    /// The pitch shift the conversion was run with, in semitones. Recorded
    /// because it is the other half of "how would I make this again"; it drives
    /// nothing.
    public var pitchSemitones: Int
    /// When the conversion ran.
    public var convertedAt: Date

    public init(voiceId: String, voiceName: String,
                pitchSemitones: Int = 0, convertedAt: Date = Date()) {
        self.voiceId = voiceId
        self.voiceName = voiceName
        self.pitchSemitones = pitchSemitones
        self.convertedAt = convertedAt
    }
}

/// ⭐ **THE ONE HOME** for "where voice models live and which of their files
/// travel with a project" (m24-n).
///
/// Two callers must never disagree about the store's location:
/// `AIServices.VoiceModelImport.voicesDirectory` (which writes imports into it
/// and hands it to the RVC sidecar as `RVC_VOICES_DIR`) and `ProjectStore`'s
/// save-time embedding (which reads out of it). The directory computation lives
/// HERE, in DAWCore, and `VoiceModelImport` delegates — DAWCore cannot import
/// AIServices, and a second copy of the expression is exactly the shape that
/// produces a project embedding voices from a directory the sidecar never
/// scans.
public enum VoiceStore {
    /// `<Application Support>/DAWPro/VoiceModels/` — see
    /// `AppDirectories.Category.voiceModels`.
    public static var directory: URL {
        AppDirectories.applicationSupport(.voiceModels)
    }

    /// Bundle-relative parent of every embedded voice: `voices/`, a sibling of
    /// `media/` inside the `.dawproj` package.
    public static let bundleFolderName = "voices"

    /// The file a voice CANNOT be embedded without: the MLX weights the
    /// converter actually loads (`scripts/rvc/server.py:282` refuses
    /// `voiceNotReady` without it).
    public static let requiredFileName = "model.npz"

    /// ⭐ **The whitelist, and `model.pth`'s absence from it is the whole
    /// point.** MEASURED against the running sidecar, not assumed:
    ///
    ///  - `model.npz` — the weights `_load_engine` loads (`server.py:282`).
    ///  - `model.json` — the hyperparameter config, read by the MLX loader as
    ///    `splitext(model_path)[0] + ".json"`
    ///    (`rvc_mlx/infer/infer_mlx.py:153,172`). Small, and a voice loaded
    ///    without it falls back to inferring shapes from the weights — carry it.
    ///  - `model.index` — the optional FAISS index; present ⇒ the sidecar uses
    ///    it at `index_rate` 0.75 (`server.py:291`). Quality, not viability.
    ///  - `voice.json` — display metadata (`_voice_descriptor`), so an
    ///    installed-from-project voice keeps its human name.
    ///
    /// ⛔ **`model.pth` is DELIBERATELY EXCLUDED.** It is the imported PyTorch
    /// original that `model.npz` was derived from; nothing in the conversion
    /// path opens it. Measured on this machine it is ~55 MB of the ~121–133 MB
    /// a voice folder occupies — carrying it would inflate every project by
    /// ~45 % to ship bytes no converter reads.
    public static let embeddableFileNames = [
        requiredFileName, "model.json", "model.index", "voice.json",
    ]

    /// The reserved id of the sidecar's built-in, UNTRAINED smoke target
    /// (`scripts/rvc/server.py`'s `_base_descriptor`). It is not a voice and
    /// does not live in this store at all — the facade resolves it from its own
    /// checkout — so it can be named by provenance (a conversion against it is
    /// a real fact) but can never be embedded.
    ///
    /// `AIServices.VoiceModelImport.reservedVoiceId` delegates to this constant
    /// so the import refusal and the embed skip can never name different ids.
    public static let reservedVoiceId = "base"

    /// A voice id that can be a directory name. Mirrors
    /// `VoiceModelImport`'s sanitiser domain (`[A-Za-z0-9-_]`) and additionally
    /// refuses the path-traversal shapes, because unlike an import — where the
    /// id is DERIVED — an embedded voice's id arrives from a project file that
    /// may have been hand-edited or written by another machine.
    public static func isSafeVoiceId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        guard id != ".", id != ".." else { return false }
        return id.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
        }
    }

    /// `<bundle>/voices/<voiceId>/`, or nil for an id that cannot name a
    /// directory (see `isSafeVoiceId` — the ref never escapes the bundle).
    public static func embeddedDirectory(voiceId: String, bundleURL: URL) -> URL? {
        guard isSafeVoiceId(voiceId) else { return nil }
        return bundleURL
            .appendingPathComponent(bundleFolderName, isDirectory: true)
            .appendingPathComponent(voiceId, isDirectory: true)
    }

    /// The whitelisted files that actually exist in `directory`, in whitelist
    /// order, with their byte counts. An empty result means "nothing to embed
    /// here" — either the folder is absent or it holds only files we do not
    /// carry.
    public static func embeddableFiles(
        in directory: URL, fileManager: FileManager = .default
    ) -> [(name: String, url: URL, byteCount: Int)] {
        var found: [(name: String, url: URL, byteCount: Int)] = []
        for name in embeddableFileNames {
            let url = directory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int)
                .flatMap { $0 } ?? 0
            found.append((name, url, size))
        }
        return found
    }

    /// Whether `directory` holds enough to convert with — i.e. `model.npz`.
    public static func isUsableVoiceDirectory(
        _ directory: URL, fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(
            atPath: directory.appendingPathComponent(requiredFileName).path)
    }
}

/// What one voice named by some track's provenance costs and where it can be
/// found (m24-n) — the per-voice row of `ProjectStore.embeddedVoicesReport()`.
///
/// ⭐ **DERIVED, NEVER RECORDED.** There is deliberately no embedded-voice
/// manifest in `project.json`. Every field below is read from the live model
/// plus the filesystem at the moment it is asked for, so this cannot become a
/// record that disagrees with the directory it describes.
public struct EmbeddedVoiceStatus: Codable, Sendable, Equatable {
    public var voiceId: String
    /// Display name — from the newest provenance that names this voice.
    public var voiceName: String
    /// Names of the tracks whose provenance names this voice, in session order.
    public var tracks: [String]
    /// Whether `<project>/voices/<voiceId>/model.npz` is present in the SAVED
    /// bundle. False for an unsaved project, or one saved before the voice was
    /// available to embed.
    public var embeddedInProject: Bool
    /// Bytes the embedded copy occupies inside the bundle (0 when not embedded).
    public var embeddedBytes: Int
    /// Whether this machine's voice store holds a usable copy — i.e. whether
    /// converting with this voice would work RIGHT NOW.
    public var installedLocally: Bool
    /// One plain sentence explaining the combination above. Never an error:
    /// "the voice is gone" is information, and the converted audio is unaffected.
    public var note: String

    public init(voiceId: String, voiceName: String, tracks: [String],
                embeddedInProject: Bool, embeddedBytes: Int,
                installedLocally: Bool, note: String) {
        self.voiceId = voiceId
        self.voiceName = voiceName
        self.tracks = tracks
        self.embeddedInProject = embeddedInProject
        self.embeddedBytes = embeddedBytes
        self.installedLocally = installedLocally
        self.note = note
    }
}

/// "What is this project carrying, and why" (m24-n) — the answer to the
/// support question a silent 240 MB would otherwise become.
public struct EmbeddedVoicesReport: Codable, Sendable, Equatable {
    /// The saved bundle this report describes, or nil for an unsaved project
    /// (in which case nothing is embedded yet — `embeddedBytes` is 0 and the
    /// notes say a save will embed).
    public var projectPath: String?
    /// One row per DISTINCT voice named by any track's provenance, plus any
    /// voice embedded in the bundle that no track names any more (an orphan —
    /// see `orphanedVoiceIds`).
    public var voices: [EmbeddedVoiceStatus]
    /// Total bytes the bundle's `voices/` folder occupies.
    public var embeddedBytes: Int
    /// Voices embedded in the bundle that NO track's provenance names. A save
    /// never deletes media (the undo-resurrection rule — `ProjectBundle.write`),
    /// and that rule holds for voices too, so deleting a converted track leaves
    /// its voice behind. Named here so the cost is explainable rather than
    /// mysterious.
    public var orphanedVoiceIds: [String]

    public init(projectPath: String?, voices: [EmbeddedVoiceStatus],
                embeddedBytes: Int, orphanedVoiceIds: [String]) {
        self.projectPath = projectPath
        self.voices = voices
        self.embeddedBytes = embeddedBytes
        self.orphanedVoiceIds = orphanedVoiceIds
    }
}

/// Outcome of `ProjectStore.installEmbeddedVoice` — a project's embedded copy
/// promoted into this machine's voice store, where the RVC sidecar can find it.
public struct EmbeddedVoiceInstallResult: Codable, Sendable, Equatable {
    public var voiceId: String
    public var voiceName: String
    /// The voice-store directory the files landed in.
    public var directoryPath: String
    /// File names copied, in whitelist order.
    public var files: [String]
    public var byteCount: Int
    /// True when an existing voice of the same id was replaced.
    public var replacedExisting: Bool

    public init(voiceId: String, voiceName: String, directoryPath: String,
                files: [String], byteCount: Int, replacedExisting: Bool) {
        self.voiceId = voiceId
        self.voiceName = voiceName
        self.directoryPath = directoryPath
        self.files = files
        self.byteCount = byteCount
        self.replacedExisting = replacedExisting
    }
}
