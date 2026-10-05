import DAWCore
import Darwin
import Foundation
import os

/// p2-ren Stage B (design §6 step 7, §11 step 11): **THE PROVISIONAL SLOT.**
/// Builds provisional renders (`ProvisionalRender.build`) per clip, latest
/// wins, and remembers what it built, keyed by (new render key, base name).
/// Separate from `StretchRenderCache`, which stays the committed-only store:
/// nothing here is ever returned by `committedURL`/`cachedURL`, so a bounce
/// never sees a provisional (design §10 failure mode 3).
///
/// ⭐ **ITS OWN SERIAL QUEUE, NOT THE COOPERATIVE POOL.** Builds run one at a
/// time, machine-wide, on a dedicated `DispatchQueue`: the whole-file renders
/// (`Task.detached` in `StretchRenderCache`) keep every cooperative thread
/// they had, and at most ONE provisional runs beside them (the concurrency
/// answer the brief asked for: +1 concurrent render at most). Two clips'
/// builds queue behind each other.
///
/// Per clip: one build in flight and one queued. A newer request cancels the
/// in-flight build (a flag its loops poll) and replaces the queued one. NO
/// debounce (design §6 step 7): a pitch edit is already one commit per
/// gesture, and the whole-file job's 250 ms would eat most of the 400 ms
/// budget by itself.
///
/// Files live in `<cache>/Provisional/<pid>-<uuid>/`, one folder per
/// session. A session's first build wipes the folders of sessions whose
/// process is gone (design §6 "the session folder is wiped at launch"; by
/// PID, because the user's live app and a staging instance share the cache).
/// Superseded files are deleted (`collectGarbage`).
@MainActor
final class ProvisionalRenderStore {
    /// A provisional's identity: its content is a pure function of these (and
    /// the builder's version and tuning), so two clips asking for one pair
    /// share one file (design §10 failure mode 15).
    struct Pair: Hashable, Sendable {
        let newKey: String
        let baseName: String
        var fileName: String { "\(newKey)~\(baseName).caf" }
    }

    let root: URL
    private let sessionName: String
    private var sessionDirectory: URL?
    var tuning = ProvisionalRender.Tuning.product
    /// Patches this session built, reused where a region's inputs are
    /// unchanged (`ProvisionalRender.PatchMemo`; 64 MB, least recently used out).
    let memo = ProvisionalRender.PatchMemo()

    private var built: [Pair: URL] = [:]
    private var declined: [Pair: String] = [:]
    private struct InFlight {
        let pair: Pair
        let token: UUID
        let flag: CancelFlag
    }
    private struct Pending {
        let pair: Pair
        let job: ProvisionalRender.Job
    }
    private struct Slot {
        var inFlight: InFlight?
        var queued: Pending?
        /// The pairs this clip's builds produced, oldest first.
        var owned: [Pair] = []
    }
    private var slots: [UUID: Slot] = [:]
    private let queue = DispatchQueue(label: "com.dawpro.provisional-render", qos: .userInitiated)

    /// Fired on the main actor when a build lands a file (or serves its base)
    /// for a clip whose slot it still owns.
    var onBuilt: ((UUID, Pair, URL) -> Void)?

    /// TEST INSTRUMENTATION: builds started (not cache hits), and the last
    /// outcome per clip. Production never reads them.
    private(set) var buildCountForTesting = 0
    private(set) var lastOutcomeForTesting: [UUID: ProvisionalRender.Outcome] = [:]

    init(root: URL) {
        self.root = root
        sessionName = "\(getpid())-\(UUID().uuidString)"
    }

    /// The file built for `pair`, when it is still on disk.
    func url(for pair: Pair) -> URL? {
        guard let url = built[pair] else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            built[pair] = nil
            return nil
        }
        return url
    }

    /// True when a build of `pair` declined (the cap, a non-local change):
    /// the bridge plays on and nothing re-asks.
    func isDeclined(_ pair: Pair) -> Bool { declined[pair] != nil }

    /// Asks for `pair` for `clipID`, latest wins. Nothing happens when it is
    /// built, declined, or already in flight for this clip.
    func request(clipID: UUID, pair: Pair, source: URL, base: ProvisionalRender.Base,
                 params: StretchRenderCache.Params, renderCacheDirectory: URL,
                 detector: PitchContourCache.Detector) {
        guard built[pair] == nil, declined[pair] == nil else { return }
        var slot = slots[clipID] ?? Slot()
        if slot.inFlight?.pair == pair {
            slot.queued = nil
            slots[clipID] = slot
            return
        }
        guard let directory = try? ensureSessionDirectory() else { return }
        let job = ProvisionalRender.Job(
            source: source, base: base, params: params, newKey: pair.newKey,
            destination: directory.appendingPathComponent(pair.fileName),
            renderCacheDirectory: renderCacheDirectory, detector: detector, memo: memo)
        if let inFlight = slot.inFlight {
            inFlight.flag.cancel()
            slot.queued = Pending(pair: pair, job: job)
            slots[clipID] = slot
            return
        }
        slots[clipID] = slot
        start(clipID: clipID, pair: pair, job: job)
    }

    /// Cancels a clip's builds and forgets its queue (the clip left, or its
    /// final landed).
    func cancel(clipID: UUID) {
        slots[clipID]?.inFlight?.flag.cancel()
        slots[clipID]?.queued = nil
    }

    private func start(clipID: UUID, pair: Pair, job: ProvisionalRender.Job) {
        let flag = CancelFlag()
        let token = UUID()
        slots[clipID, default: Slot()].inFlight = InFlight(pair: pair, token: token, flag: flag)
        buildCountForTesting += 1
        let tuning = self.tuning
        queue.async { [weak self] in
            let outcome: ProvisionalRender.Outcome?
            do {
                outcome = try ProvisionalRender.build(job, tuning: tuning,
                                                      isCancelled: { flag.isCancelled })
            } catch OfflineStretcherError.cancelled {
                outcome = nil
            } catch {
                outcome = .declined("the build failed: \(error)")
            }
            Task { @MainActor [weak self] in
                self?.finish(clipID: clipID, token: token, pair: pair, outcome: outcome)
            }
        }
    }

    private func finish(clipID: UUID, token: UUID, pair: Pair,
                        outcome: ProvisionalRender.Outcome?) {
        guard var slot = slots[clipID], slot.inFlight?.token == token else { return }
        slot.inFlight = nil
        var landed: URL?
        switch outcome {
        case .built(let result)?:
            built[pair] = result.url
            if result.url.deletingLastPathComponent().standardizedFileURL
                == sessionDirectory?.standardizedFileURL {
                slot.owned.removeAll { $0 == pair }
                slot.owned.append(pair)
            }
            landed = result.url
            lastOutcomeForTesting[clipID] = outcome
        case .declined(let reason)?:
            declined[pair] = reason
            lastOutcomeForTesting[clipID] = outcome
        case nil:
            break  // cancelled: whatever superseded it is queued
        }
        let next = slot.queued
        slot.queued = nil
        slots[clipID] = slot
        if let next { start(clipID: clipID, pair: next.pair, job: next.job) }
        if let landed { onBuilt?(clipID, pair, landed) }
    }

    /// Deletes every file this store built for `clipID` except the ones in
    /// `keep` and the ones another clip still owns or plays (`inUse`). The
    /// engine calls it when a clip's provisional is superseded: by a newer
    /// one, or by its final.
    func collectGarbage(clipID: UUID, keep: Set<Pair>, inUse: Set<URL>) {
        guard var slot = slots[clipID] else { return }
        let ownedElsewhere = Set(slots.filter { $0.key != clipID }.flatMap { $0.value.owned })
        var kept: [Pair] = []
        for pair in slot.owned {
            guard let url = built[pair] else { continue }
            if keep.contains(pair) || ownedElsewhere.contains(pair)
                || inUse.contains(url.standardizedFileURL) {
                kept.append(pair)
                continue
            }
            try? FileManager.default.removeItem(at: url)
            built[pair] = nil
        }
        slot.owned = kept
        slots[clipID] = slot
    }

    /// Forgets clips that left the model (their files go too, unless in use).
    func prune(keeping clips: Set<UUID>, inUse: Set<URL>) {
        for clipID in slots.keys where !clips.contains(clipID) {
            cancel(clipID: clipID)
            collectGarbage(clipID: clipID, keep: [], inUse: inUse)
            slots[clipID] = nil
        }
    }

    /// The files this store holds on disk for `clipID` (test seam).
    func ownedFilesForTesting(clipID: UUID) -> [URL] {
        (slots[clipID]?.owned ?? []).compactMap { built[$0] }
    }

    /// This session's folder, created on first use; the first call also wipes
    /// the folders of sessions whose process has exited.
    func ensureSessionDirectory() throws -> URL {
        if let sessionDirectory { return sessionDirectory }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.wipeDeadSessions(in: root, except: sessionName)
        let directory = root.appendingPathComponent(sessionName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionDirectory = directory
        return directory
    }

    /// Removes `<pid>-<uuid>` folders under `root` whose pid names no running
    /// process. A folder whose pid is alive (another instance: the user's app,
    /// a staging copy, a test process) is left alone.
    nonisolated static func wipeDeadSessions(in root: URL, except current: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return
        }
        for name in names where name != current {
            guard let dash = name.firstIndex(of: "-"),
                  let pid = pid_t(name[name.startIndex..<dash]), pid > 0 else { continue }
            if kill(pid, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }
}

/// A cancellation flag a build's loops poll (never on the render thread).
final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func cancel() { state.withLock { $0 = true } }
    var isCancelled: Bool { state.withLock { $0 } }
}
