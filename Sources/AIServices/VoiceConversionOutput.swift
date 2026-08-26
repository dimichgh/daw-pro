import Foundation
import DAWCore

/// Where RVC voice-conversion audio lives, and the copy that makes a returned
/// path trustworthy (m23-fp).
///
/// ## The defect this exists for
///
/// `scripts/rvc/server.py:326` names every conversion's output like this:
///
/// ```python
/// out_path = OUT_DIR / f"convert-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{req.voiceId}-{os.getpid()}-{threading.get_ident() % 10000}.wav"
/// ```
///
/// A **one-second** timestamp, the voice id, the pid, and a thread id — and
/// because `_engine_lock` serialises conversions inside one long-lived process,
/// the pid and the thread id are CONSTANT. So within any given wall-clock
/// second every field is constant and the facade **overwrites its own previous
/// output**. Measured at m23-fo-1: 24 conversions returned **7 distinct
/// paths**. Worse than lost audio, it manufactures believable measurements —
/// a 12-rep timing run read as a flat, healthy curve because the later reps
/// were re-reading one overwritten file.
///
/// The fix cannot go in `server.py`: `scripts/rvc/` is a read-only fence. Nor
/// can the output path be requested — `ConvertRequest` has exactly three
/// fields (`inputPath`, `voiceId`, `pitchSemitones`) and `server.py` sets no
/// `model_config`/`extra="forbid"`, so pydantic v2 would silently IGNORE an
/// added `outputPath` and the collision would persist while the call looked
/// like it worked. What is left is to **copy the returned file immediately,
/// on our side, before the next conversion can be issued** —
/// ``VoiceConversionClient/convert(_:)`` does exactly that, under a gate that
/// admits one conversion at a time.
///
/// ## COPY, never move
///
/// ``capture(sidecarPath:voiceId:sequence:into:unique:fileManager:)`` never
/// deletes, renames or moves the source. That is not politeness: a sidecar
/// someone started by hand (`bash scripts/rvc/run.sh`, no `RVC_OUT_DIR`)
/// answers with a path INSIDE the read-only fence, and a move would be a
/// delete in there. Copying is correct no matter where the source lives, so
/// there is no branch to get wrong.
///
/// The cost is disclosed rather than optimised away: a conversion that reaches
/// the project now leaves three files — the facade's own write, the capture
/// here, and `Generations/gen-voice-<uuid>.wav` from
/// `ProjectStore.copyGeneratedAudioToStableLocation`. Nothing here prunes any
/// of them.
public enum VoiceConversionOutput {

    /// The app-owned home for conversion audio:
    /// `<Application Support>/DAWPro/VoiceConversions/`. Holds the captured
    /// copies this app hands downstream.
    ///
    /// Derived through `AppDirectories` — the ONE home for the
    /// Application-Support rule (m23-n1b) — exactly as
    /// `VoiceModelImport.voicesDirectory` is, so a staging launch's
    /// `DAWPRO_PROFILE_ROOT` relocates this with everything else instead of
    /// leaking into the user's real profile.
    public static var directory: URL {
        AppDirectories.applicationSupport(.voiceConversions)
    }

    /// `RVC_OUT_DIR` — where the FACADE writes, handed to it at every spawn
    /// (`VoiceConversionManager.Configuration.spawnEnvironment`).
    ///
    /// `server.py:67` reads `OUT_DIR = Path(os.environ.get("RVC_OUT_DIR",
    /// RUNTIME_DIR / "out"))` and nothing in `Sources/` set that variable
    /// before m23-fp, so every shipped conversion wrote into
    /// `scripts/rvc/runtime/out/` — inside the read-only fence. Pointing it
    /// here STOPS a write into `scripts/rvc/`; it never creates anything
    /// under it. The facade `mkdir`s this itself (`server.py:325`,
    /// `parents=True, exist_ok=True`), so nothing needs to pre-create it.
    ///
    /// A CHILD of ``directory`` rather than the same folder, so "what the
    /// facade wrote" and "what we captured" are never mixed up by eye — the
    /// colliding names all stay in one clearly-labelled place.
    public static var sidecarOutputDirectory: URL {
        directory.appendingPathComponent("sidecar-out", isDirectory: true)
    }

    // MARK: - Naming (pure)

    /// The capture file name. PURE — no I/O, no clock, no filesystem probe.
    ///
    /// `convert-<sequence>-<voiceId>-<unique>.<ext>`, e.g.
    /// `convert-000007-my-voice-3F9C1AB2-1A5E-4C0D-9B77-6E2A11D4C8F0.wav`.
    ///
    /// **Uniqueness comes from `unique` alone** — a FULL UUID at the real call
    /// site, never a truncated one, so the "cannot collide" claim needs no
    /// birthday argument. `sequence` and `voiceId` are for a human reading
    /// `ls`; neither
    /// is load-bearing, and a caller may reuse both without risking a
    /// collision. That split is the lesson of the defect: the facade's name
    /// LOOKED unique because it carried a timestamp, and every part of it was
    /// in fact constant.
    ///
    /// ⚠️ **There is deliberately no timestamp.** A one-second timestamp is
    /// what created this bug, and any timestamp invites the same mistake of
    /// reading it as an identity. The file's mtime already carries when it was
    /// written, exactly, and cannot be mistaken for a uniqueness guarantee.
    ///
    /// `sequence` is zero-padded to six digits so a directory listing sorts in
    /// conversion order within one process run (it restarts at 1 in the next
    /// process — again: readability, not identity).
    ///
    /// `voiceId` arrives from the wire UNVALIDATED (`vc.convertVocals` passes
    /// it through so the facade's own teaching errors reach the caller
    /// verbatim), so it is reduced to the same allowlist
    /// `ProjectStore.copyGeneratedAudioToStableLocation` uses — letters,
    /// digits, `-`, `_`; everything else becomes `-`. A `voiceId` of
    /// `../../escape` therefore cannot walk out of the capture directory. It
    /// is also truncated, and an id that sanitises away to nothing becomes
    /// `voice`, so the name can never collapse to a leading/trailing dash soup.
    static func captureFileName(
        voiceId: String,
        sequence: Int,
        unique: String,
        pathExtension: String
    ) -> String {
        let voice = sanitizedComponent(voiceId, fallback: "voice")
        let ext = sanitizedComponent(pathExtension, fallback: "wav")
        let uniquePart = sanitizedComponent(unique, fallback: "x")
        let paddedSequence = String(format: "%06d", max(0, sequence))
        return "convert-\(paddedSequence)-\(voice)-\(uniquePart).\(ext)"
    }

    /// The allowlist reduction shared by every component of the name. Anything
    /// outside `[A-Za-z0-9_-]` becomes `-`; the result is truncated to 40
    /// characters and falls back to `fallback` when nothing survives.
    ///
    /// Truncation happens AFTER substitution so a long unicode id can never
    /// produce a path component past the filesystem's limit, and the fallback
    /// covers the "every character was replaced away" case (e.g. `"///"`,
    /// which would otherwise leave `---`; that is still safe, just unreadable).
    static func sanitizedComponent(_ raw: String, fallback: String) -> String {
        let mapped = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        let trimmed = String(mapped.prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Capture

    /// Copies the facade's output to a path this app owns and returns it.
    ///
    /// Called by ``VoiceConversionClient/convert(_:)`` the moment the response
    /// is parsed and BEFORE the next conversion may be issued, which is what
    /// makes the copy safe: `_engine_lock` serialises the facade, so while we
    /// hold the client's convert gate no second conversion exists to overwrite
    /// the file underneath us.
    ///
    /// - Parameters:
    ///   - sidecarPath: the facade's own `outputPath`, verbatim.
    ///   - voiceId: for the human-readable part of the name only.
    ///   - sequence: for the human-readable part of the name only.
    ///   - directory: the capture home (injected so tests never write into the
    ///     real profile).
    ///   - unique: the ONLY thing uniqueness depends on. Defaulted to a fresh
    ///     UUID; injectable so the naming rule can be asserted exactly.
    /// - Returns: the URL of OUR copy. Everything downstream must use this and
    ///   never `sidecarPath`.
    /// - Throws: `VoiceConversionError.outputCaptureFailed` — the source is
    ///   missing (the facade reported a file it did not write), the directory
    ///   could not be created, or the copy failed. Never a silent fallback to
    ///   `sidecarPath`: handing back a path we know may be overwritten is the
    ///   exact failure this item exists to end.
    static func capture(
        sidecarPath: String,
        voiceId: String,
        sequence: Int,
        into directory: URL,
        unique: String = UUID().uuidString,
        fileManager: FileManager = .default
    ) throws -> URL {
        let source = URL(fileURLWithPath: sidecarPath)
        guard fileManager.fileExists(atPath: source.path) else {
            throw VoiceConversionError.outputCaptureFailed(
                "the sidecar reported outputPath '\(sidecarPath)' but no file exists there — "
                    + "it may already have been overwritten or removed")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw VoiceConversionError.outputCaptureFailed(
                "could not create the voice-conversion output directory at \(directory.path): "
                    + error.localizedDescription)
        }
        let name = captureFileName(
            voiceId: voiceId,
            sequence: sequence,
            unique: unique,
            pathExtension: source.pathExtension)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        guard !fileManager.fileExists(atPath: destination.path) else {
            // Structurally unreachable (the name carries a fresh UUID), and
            // therefore worth failing loudly rather than overwriting: if this
            // ever fires, uniqueness is broken and silently clobbering would
            // reproduce the very defect being fixed.
            throw VoiceConversionError.outputCaptureFailed(
                "refusing to overwrite an existing capture at \(destination.path)")
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw VoiceConversionError.outputCaptureFailed(
                "could not copy \(sidecarPath) to \(destination.path): "
                    + error.localizedDescription)
        }
        return destination
    }
}
