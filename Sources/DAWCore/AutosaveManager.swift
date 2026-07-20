import Foundation

/// Manifest sitting beside the rolling autosave bundle (M9 crash-b). Records the
/// facts a recovery offer needs WITHOUT re-opening the (larger) project bundle:
/// when the snapshot was taken, which file the open project was backed by (nil
/// for an untitled session — a recovered untitled project stays untitled), and
/// the journaled-edit high-water mark at autosave time. A value type,
/// `Codable`/`Sendable`; its JSON is the on-disk `manifest.json`.
public struct AutosaveManifest: Codable, Sendable, Equatable {
    /// Wall-clock time the autosave fired (the manager's injected clock).
    public var savedAt: Date
    /// The open project's file path when it had one; nil for an untitled session.
    public var sourcePath: String?
    /// Journaled-edit sequence at autosave time (the `lastEditEvent.seq` machinery).
    public var editCount: Int

    public init(savedAt: Date, sourcePath: String?, editCount: Int) {
        self.savedAt = savedAt
        self.sourcePath = sourcePath
        self.editCount = editCount
    }
}

/// Wire-facing recovery status (M9 crash-b) — the payload of `project.recoveryStatus`.
/// `available` is true only when a crash was detected at launch AND a readable
/// autosave + manifest are present; the optional fields echo the manifest so a
/// client (the launch sheet, an agent) can describe the offer. Headless-safe: a
/// store that never began a session, or a missing Autosave dir, reports
/// `.unavailable`.
public struct AutosaveRecoveryStatus: Codable, Sendable, Equatable {
    public var available: Bool
    public var savedAt: Date?
    public var sourcePath: String?
    public var editCount: Int?

    public init(available: Bool, savedAt: Date? = nil, sourcePath: String? = nil, editCount: Int? = nil) {
        self.available = available
        self.savedAt = savedAt
        self.sourcePath = sourcePath
        self.editCount = editCount
    }

    /// No recovery on offer — nothing to restore.
    public static let unavailable = AutosaveRecoveryStatus(available: false)
}

/// The crash-detection sentinel written into the Autosave dir at launch and
/// removed on a clean exit. Presence at the NEXT launch means the prior session
/// did not exit cleanly (a real crash, or a SIGKILL). Value type; its JSON is the
/// on-disk `session.lock`.
struct SessionLock: Codable, Sendable, Equatable {
    var pid: Int
    var startedAt: Date
}

/// Headless crash-recovery autosave engine (M9 crash-b). Owns the file layout and
/// the crash-detection lock — the "how it lands on disk" half of the feature;
/// `ProjectStore` owns the "what to snapshot / how to reload" half and drives this
/// manager. Deliberately SEPARATE from `ProjectStore.startAutosave`/
/// `autosaveIfNeeded` (the in-place / per-slug-recovery autosave): this manager
/// never touches the user's project file — it keeps ONE rolling snapshot in a
/// known location so a relaunch after a crash can offer to restore it.
///
/// Layout (all under `directory`, default
/// `~/Library/Application Support/DAWPro/Autosave/`):
///  - `autosave.dawproject` — the rolling snapshot bundle, overwritten each fire.
///  - `manifest.json` — `{savedAt, sourcePath?, editCount}` for the offer.
///  - `session.lock` — `{pid, startedAt}`, written at launch, removed on clean exit.
///
/// Threading: `directory`/`clock` are injected so tests never write into the real
/// profile and never wait on wall clock. Snapshot ENCODE happens on the main actor
/// (the caller hands over a `Sendable` `ProjectDocument`); the file WRITE runs off
/// the main actor via a detached task, so autosave never adds latency to the edit
/// path. Reads (status / recovered document / lock) are tiny and stay synchronous
/// on the main actor, matching `ProjectStore.openProject`.
@MainActor
public final class AutosaveManager {
    /// Base dir for the autosave bundle, manifest, and lock. Injected in tests
    /// (temp dir) so autosave never writes into the user's real profile.
    public var directory: URL
    /// Time source for `savedAt`/`startedAt`. Injected in tests so a manifest's
    /// timestamp is deterministic; `Sendable` so it can cross into the write task.
    public var clock: @Sendable () -> Date

    /// Journaled-edit sequence of the LAST successful autosave, so a tick that
    /// sees no new journaled edit re-writes nothing (the "2 ticks = 1 file" rule).
    /// The sentinel means "nothing autosaved yet / just invalidated" — so the next
    /// dirty tick always writes (this is what re-protects freshly recovered work).
    private(set) var lastAutosavedEditSeq: Int = AutosaveManager.noAutosaveSeq
    /// Chat-revision high-water mark of the LAST successful autosave — the
    /// chat twin of `lastAutosavedEditSeq` (chat-persist design §4.4), so a
    /// chat-only session still crash-autosaves while a quiet tick still
    /// rewrites nothing. Same sentinel semantics; sentinel-reset in
    /// `invalidate()`. In-memory only — `manifest.json` is untouched.
    private(set) var lastAutosavedChatRevision: UInt64 = AutosaveManager.noAutosaveChatRevision
    /// Whether a prior session's lock was present at `beginSession` — latched so
    /// `recoveryStatus` can gate on "a crash happened" the whole session.
    private(set) var crashDetectedAtLaunch = false

    /// Sentinel high-water mark: no autosave has landed since the last invalidate.
    static let noAutosaveSeq = Int.min
    /// Chat-revision sentinel (`.max`, since revisions start at 0 and only
    /// climb — the UInt64 twin of `noAutosaveSeq`).
    static let noAutosaveChatRevision = UInt64.max

    /// The rolling snapshot bundle.
    var autosaveBundleURL: URL {
        directory.appendingPathComponent("autosave.dawproject", isDirectory: true)
    }
    /// The manifest beside it.
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    /// The crash-detection lock.
    var lockURL: URL { directory.appendingPathComponent("session.lock") }

    public init(
        directory: URL = AutosaveManager.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.clock = clock
    }

    /// Default autosave directory: `~/Library/Application Support/DAWPro/Autosave/`
    /// (the same home `ProjectStore.defaultAutosaveDirectory` resolves — the
    /// rolling snapshot and the legacy per-slug recovery bundles cohabit there
    /// under distinct names). A `public static` so it can back the `public init`'s
    /// default argument.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("Autosave", isDirectory: true)
    }

    // MARK: - Writing

    /// Serializes one rolling autosave: encodes the manifest on the main actor,
    /// then writes both the (already-built, `Sendable`) document bundle and the
    /// manifest OFF the main actor, and advances the high-water mark. `document`
    /// must carry ABSOLUTE media refs (zero copies) — the recovery-bundle contract
    /// — so a restore resolves media from the original files. Best-effort: a write
    /// failure leaves the high-water marks UNCHANGED so the next tick retries.
    /// `chatRevision` is additive/defaulted (chat-persist §4.4) — existing
    /// callers advance only the edit-seq mark, exactly as before.
    func recordAutosave(document: ProjectDocument, sourcePath: String?, editSeq: Int, chatRevision: UInt64 = 0) async {
        let manifest = AutosaveManifest(savedAt: clock(), sourcePath: sourcePath, editCount: editSeq)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let manifestData = try? encoder.encode(manifest) else { return }
        let bundleURL = autosaveBundleURL
        let manifestURL = self.manifestURL
        let dir = directory
        let ok = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // plan.copies is empty (absolute refs, zero copies); write() only
                // consumes plan.copies, so an empty plan is exactly right here.
                try ProjectBundle.write(
                    document: document,
                    plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []),
                    to: bundleURL
                )
                try manifestData.write(to: manifestURL, options: .atomic)
                return true
            } catch {
                FileHandle.standardError.write(Data("autosave (crash-recovery) failed: \(error)\n".utf8))
                return false
            }
        }.value
        if ok {
            lastAutosavedEditSeq = editSeq
            lastAutosavedChatRevision = chatRevision
        }
    }

    // MARK: - Status / recovery reads

    /// The current recovery offer. `available` requires a crash detected at launch
    /// AND a readable manifest AND a present autosave bundle; otherwise
    /// `.unavailable`. Never throws — a missing/corrupt manifest reads as no offer.
    func recoveryStatus() -> AutosaveRecoveryStatus {
        guard crashDetectedAtLaunch,
              let manifest = readManifest(),
              FileManager.default.fileExists(atPath: autosaveBundleURL.path)
        else { return .unavailable }
        return AutosaveRecoveryStatus(
            available: true,
            savedAt: manifest.savedAt,
            sourcePath: manifest.sourcePath,
            editCount: manifest.editCount
        )
    }

    /// Reads the autosave bundle and its manifest's `sourcePath`. Throws the same
    /// `ProjectError`s as `openProject` if the bundle is damaged/absent.
    func readRecoveredDocument() throws -> (document: ProjectDocument, sourcePath: String?) {
        let document = try ProjectBundle.read(from: autosaveBundleURL)
        return (document, readManifest()?.sourcePath)
    }

    private func readManifest() -> AutosaveManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AutosaveManifest.self, from: data)
    }

    /// Drops the rolling autosave + manifest and resets the high-water mark so the
    /// next dirty tick writes a fresh snapshot. Called when the offer is consumed
    /// (recover/discard) and when a manual save / new / open supersedes it — a
    /// recovered offer must never resurrect a project the user replaced or saved.
    ///
    /// A no-op unless this manager has actually ENGAGED — written an autosave this
    /// session, or detected a prior crash at launch. That keeps a store which never
    /// autosaved and never began a session (the headless persistence tests, which
    /// don't inject a temp `directory`) from ever touching the real profile's
    /// Autosave dir when they save/open/new.
    func invalidate() {
        defer {
            lastAutosavedEditSeq = Self.noAutosaveSeq
            lastAutosavedChatRevision = Self.noAutosaveChatRevision
        }
        guard lastAutosavedEditSeq != Self.noAutosaveSeq || crashDetectedAtLaunch else { return }
        // The offer is resolved (recover/discard) or superseded (save/new/open):
        // drop the latch too, or the NEXT autosave write this session would
        // re-arm `recoveryStatus().available` and offer the live session's own
        // snapshot back as "crashed work" (found live in the crash-b wire gate).
        crashDetectedAtLaunch = false
        try? FileManager.default.removeItem(at: autosaveBundleURL)
        try? FileManager.default.removeItem(at: manifestURL)
    }

    // MARK: - Crash-detection lock lifecycle

    /// Launch-time crash detection: latches whether a prior session's lock is still
    /// present (a session that didn't exit cleanly), then writes THIS session's
    /// lock. Returns the latched flag. Idempotent per launch — a second call sees
    /// the lock this call wrote (which is exactly the crash-relaunch shape a test
    /// drives by calling begin twice without an `endSession` between).
    @discardableResult
    func beginSession() -> Bool {
        crashDetectedAtLaunch = FileManager.default.fileExists(atPath: lockURL.path)
        writeLock()
        return crashDetectedAtLaunch
    }

    /// Clean-exit path: removes this session's lock so the NEXT launch sees no
    /// crash. Fires only on an in-app quit (Cmd-Q / the quit Apple event →
    /// `applicationWillTerminate`). SIGTERM/pkill does NOT route through AppKit
    /// termination for this process (verified live) — like SIGKILL it skips this,
    /// and correctly so: nothing saves on the way down, so work since the last
    /// autosave is genuinely lost and the next launch SHOULD offer recovery.
    func endSession() {
        try? FileManager.default.removeItem(at: lockURL)
    }

    private func writeLock() {
        let lock = SessionLock(pid: Int(ProcessInfo.processInfo.processIdentifier), startedAt: clock())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(lock) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: lockURL, options: .atomic)
    }
}
