import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import os

/// On-disk cache + async job model for offline clip stretch renders (M5 ii-d,
/// seam spec §2–§5). @MainActor service owned by `AudioEngine`; DAWCore never
/// sees it. Entries live OUTSIDE the project package at
/// `~/Library/Caches/DAWPro/StretchRenders/<key>.caf` — Float32 CAF at the
/// SOURCE sample rate and channel count, covering the ENTIRE source file (so
/// split clips share one phase-coherent render and clip geometry never
/// invalidates; spec §3). Renders are regenerable by definition: an OS cache
/// purge or project move re-renders asynchronously and self-heals on the next
/// launch, and a save / Save As that repoints a clip re-renders it in-session.
/// ⚠️ NOT in-session: a committed CAF deleted under a RUNNING app is not
/// re-rendered for that clip until its render key changes — the engine's kick
/// dedupe (`AudioEngine.stretchDesired`) remembers that the key was asked
/// for, not that its file still exists, so the next re-resolve schedules the
/// clip as silence (measured 2026-09-24 with a move; `rebuildEngine`
/// re-resolves every clip into a fresh graph and keeps that dedupe, so a
/// rebuild takes the same path — read, not run).
///
/// Job model (the M3 vi-a async-prepare shape): a miss spawns one
/// `Task.detached` render per clip with per-clip latest-wins supersession and
/// a 250 ms debounce (drag contract — only the settled value renders), writes
/// a `.partial-…caf` sibling and atomically renames on success. Everything
/// here is main-actor / detached-task scheduling-time work — the render
/// thread is untouched by construction.
///
/// contour-to-render (2026-09-24): a render whose pitch edits shape against
/// the DETECTED contour (Hard Tune, any drift/vibrato scale ≠ 1) fetches or
/// detects it inside the same detached job through `PitchContourCache` — whose
/// entries live in a `PitchContours/` folder inside `directory` — and keys on
/// it. While that job runs the clip is `.rendering` and schedules as silence,
/// exactly like every other render in flight; the first render of a file pays
/// for one detection (~0.4–0.6 s per 33 s of audio, measured), later renders
/// read the cached contour. If detection is unavailable the job commits the
/// constant-offset render under the pre-contour key instead and says why
/// (`contourShortfall(source:params:)`).
@MainActor
public final class StretchRenderCache {
    /// The render-affecting clip parameters, as one hashable value — the
    /// cache-key payload. ⛔ **NOT a render's identity, and not the engine's
    /// latest-wins comparator any more** (2026-09-24): `Params ==` holds no
    /// source file and compares Doubles with `==` (+0.0 == −0.0), while the
    /// on-disk key starts with the source's identity and hashes bit patterns.
    /// The engine compared `Params` and so refused to render a clip whose
    /// SOURCE had changed under unchanged params — which every first save
    /// and Save As does (it repoints the clip at its bundle copy) — leaving
    /// the clip silent for the rest of the session with an idle status. The
    /// engine now compares the render KEY itself (`AudioEngine.stretchDesired`,
    /// via `keys(source:params:)`), so the two cannot disagree.
    ///
    /// ⚠️⚠️ **ADDING A FIELD HERE DOES NOT CHANGE THE ON-DISK KEY.** `Hashable`
    /// synthesis and `cacheKey(source:params:)` are two different derivations:
    /// the on-disk key is SHA256 over an EXPLICIT field list below, so a field
    /// added here and not added there changes what compares equal here while
    /// serving the previous render's audio from disk — stale audio that looks
    /// like a cache working perfectly. `pitchEditSetHash` is in BOTH, and
    /// `StretchEngineTests.editFreeClipKeyIsUnchanged` is the gate (its
    /// controls: an edited set must not share the edit-free key, and a
    /// one-cent edit must re-key).
    ///
    /// ⚠️ **THE DETECTED CONTOUR IS IN THE ON-DISK KEY AND DELIBERATELY NOT
    /// HERE** (contour-to-render). Its key's inputs are the SOURCE FILE's
    /// identity — never in `Params`; the source is passed beside it — and the
    /// cache instance's `contourDetector`, a per-process constant. WHETHER a
    /// render shapes against the contour is a function of `pitchEdits`,
    /// already here through its digest. (This paragraph used to add that the
    /// source "cannot change between two `Params` values of one clip". It
    /// can — a save repoints it — and that is the defect described above.)
    public struct Params: Hashable, Sendable {
        public let ratio: Double
        public let semitones: Double
        public let formantPreserve: Bool

        /// The clip's pitch edits, or nil when they bend nothing. The RENDER
        /// needs the set itself (it drives the transpose curve); the KEY needs
        /// only the digest, which is why both are here and why the digest is
        /// derived in `init` rather than passed in — a caller cannot hand over
        /// a digest that disagrees with the edits.
        public let pitchEdits: PitchEditSet?

        /// `PitchEditSetDigest.hex(pitchEdits)` — `""` when there are none.
        /// Deterministic across launches; see the digest's own warning about
        /// why `hashValue` would be a bug here.
        public let pitchEditSetHash: String

        /// True when this render is a structural identity: the clip plays its
        /// SOURCE FILE byte-for-byte and no render exists at all. An empty (or
        /// detected-but-unedited) edit set therefore still takes the identity
        /// bypass — design §6.4's "never bypass the identity path" rule,
        /// expressed where the bypass is actually decided.
        public var isIdentity: Bool {
            pitchEditSetHash.isEmpty
                && OfflineStretcher.isIdentity(ratio: ratio, semitones: semitones)
        }

        public init(ratio: Double, semitones: Double, formantPreserve: Bool,
                    pitchEdits: PitchEditSet? = nil) {
            self.ratio = ratio
            self.semitones = semitones
            self.formantPreserve = formantPreserve
            self.pitchEditSetHash = PitchEditSetDigest.hex(pitchEdits)
            // Normalise a bends-nothing set to nil so `Params` Equatable and
            // the digest agree: two clips that render identically must compare
            // equal, or the latest-wins comparator re-kicks renders forever.
            self.pitchEdits = self.pitchEditSetHash.isEmpty ? nil : pitchEdits
        }

        public init(clip: Clip) {
            self.init(ratio: clip.stretchRatio,
                      semitones: clip.pitchShiftSemitones,
                      formantPreserve: clip.formantPreserve,
                      pitchEdits: clip.pitchEdits)
        }

        /// Hand-written because `PitchEditSet` is Equatable but not Hashable.
        /// Hashing the DIGEST rather than the set keeps "equal values hash
        /// equally" (equal sets ⇒ equal digest) and costs nothing: the digest
        /// is already computed.
        public func hash(into hasher: inout Hasher) {
            hasher.combine(ratio)
            hasher.combine(semitones)
            hasher.combine(formantPreserve)
            hasher.combine(pitchEditSetHash)
        }

        /// Does a render of these params shape against the detected contour
        /// under `detector`? THE question the key, the fallback and
        /// `performRender` all ask — answered here once.
        ///
        /// False for every set that needs no contour (the preset ladder,
        /// generator-only edits, plain offsets) — those key and render exactly
        /// as they did before the contour reached the render. Also false for a
        /// set from ANOTHER detector generation: it is never shaped against this
        /// build's contour (§7.2), so its render is the constant-offset render
        /// and keys like one.
        func shapesAgainstContour(_ detector: PitchContourCache.Detector) -> Bool {
            guard let set = pitchEdits else { return false }
            return set.needsDetectedContour && set.analysisVersion == detector.analysisVersion
        }
    }

    /// The two on-disk keys a render of (source, params) can live under.
    ///
    /// * `resolved` — where the render lives when it got what it asked for:
    ///   for a set that shapes against the contour, the legacy fields plus
    ///   `contour:<contour key>`; otherwise identical to `legacy`.
    /// * `legacy` — the key this cache derived before the contour reached the
    ///   render, byte for byte. For a contour-needing set it holds the
    ///   CONSTANT-OFFSET render, which is exactly what the pre-contour code
    ///   rendered for that set — so every such entry already on a user's disk
    ///   is not orphaned: it is this set's FALLBACK, reused verbatim when
    ///   detection is unavailable.
    struct RenderKeys: Equatable, Sendable {
        let resolved: String
        let legacy: String
    }

    /// Where an entry for `(source, params)` is COMMITTED right now, if
    /// anywhere: the resolved render, or — when this session's detection failed
    /// for that key — the constant-offset fallback it fell back to.
    ///
    /// ⭐ **THE ONE PLACE THE FALLBACK MEMO IS CONSULTED.** The engine's
    /// `resolveStretch` (with the keys it derived once for its kick dedupe),
    /// `cachedURL` (the bounce's `stretchedFileProvider`) and
    /// `renderIfNeeded`'s fast path all come through here, so the three can
    /// never disagree about which file a clip plays.
    func committedURL(for keys: RenderKeys) -> URL? {
        let resolved = directory.appendingPathComponent(keys.resolved + ".caf")
        if FileManager.default.fileExists(atPath: resolved.path) { return resolved }
        if let fallback = contourFallbacks[keys.resolved]?.url,
           FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    /// Does this clip need a render at all? The engine's reconcile-time
    /// predicate — a FORWARD to `Clip.rendersThroughStretchCache`, the one
    /// home of that rule in DAWCore (m23-ap-p2 p2-snapshot).
    ///
    /// It used to BE the rule (`!clip.isStretchIdentity || clip.hasPitchEdits`,
    /// a temporary second home while `Model.swift` was locked), and the
    /// snapshot gate in DAWControl meanwhile asked only `!isStretchIdentity`,
    /// so a tuned clip's render state never reached the wire. Do not restate
    /// the disjunction here again. `paramsIdentityAgreesWithNeedsRender` pins
    /// this against `Params.isIdentity`, the cache's OWN derivation, so the
    /// model and the cache cannot drift.
    nonisolated public static func needsRender(_ clip: Clip) -> Bool {
        clip.rendersThroughStretchCache
    }

    /// Bumped whenever the vendored signalsmith version or our preset/config
    /// changes — stale-quality renders must not survive an upgrade (spec §3).
    nonisolated public static let stretchEngineVersion = 1

    /// Quiet period before a render job starts real work: a newer request for
    /// the same clip lands inside this window and cancels the older job, so a
    /// dragged stretch handle renders only the settled value.
    nonisolated static let debounceMilliseconds = 250

    /// Where entries live. Injectable for tests; defaults to the per-user app
    /// cache dir (created lazily on the first render).
    public let directory: URL

    /// Fired on the main actor after a render COMMITS (atomic rename done), and
    /// only by the job that still owns the clip's slot. Its one consumer is
    /// I1's note audition: `AudioEngine.wireStretchCacheHooks` forwards it to
    /// the store's `clipRenderDidComplete`. It is NOT how rendered audio
    /// reaches playback: that restart seam is `AudioEngine.kickStretchRender`'s
    /// own continuation after `renderIfNeeded` returns (it invalidates the
    /// clip's schedule entry and re-enters `tracksDidChange`).
    public var onRenderComplete: (@MainActor (UUID) -> Void)?

    /// TEST SPY: number of renders that actually ran the stretcher (debounce
    /// survived, work started). Cache hits and superseded jobs don't count.
    private(set) var renderCount = 0

    /// TEST SEAM (I1-F2 follow-up, the repoint test's render-stall
    /// diagnosis), never bound in production. A task-local, so only a job
    /// started inside a test's `withValue` scope reports (the engine's kick
    /// task and the job task inherit it). Unbound, each call below is one
    /// task-local lookup that finds nil (three per render job, on the main
    /// actor, never on the render thread), and its arguments are never
    /// evaluated. Called on the main actor with the job task's own
    /// priority at `job-start` (the job task begins), `debounce-end` (its
    /// debounce sleep returned) and `render-returned` (the detached render
    /// handed back).
    @TaskLocal static var jobPhaseForTesting: (@Sendable (_ phase: String, _ priority: TaskPriority) -> Void)?

    private struct Job {
        let token: UUID
        let key: String
        let task: Task<URL, any Error>
        /// Read by the detached render between blocks (the facade's
        /// `isCancelled` closure); set alongside `task.cancel()` so an
        /// in-flight render aborts promptly, not just a sleeping debounce.
        let cancelled: OSAllocatedUnfairLock<Bool>

        func cancel() {
            cancelled.withLock { $0 = true }
            task.cancel()
        }
    }

    /// Per-clip latest-wins slot: at most one render job per clip; a newer
    /// request cancels and replaces the old one.
    private var jobs: [UUID: Job] = [:]
    /// Pull-based status per clip (spec §5): `.rendering` while a job is in
    /// flight, `.failed` after a non-cancellation error (sticky until the
    /// next job for that clip), absent = idle.
    private var statuses: [UUID: ClipStretchStatus] = [:]

    /// The detector whose contour renders shape against — `.product`
    /// everywhere but tests, which inject one to count detections or force a
    /// failure. Its fields are part of every contour-shaped render's key.
    let contourDetector: PitchContourCache.Detector

    /// THIS SESSION'S FALLBACKS: resolved render key → the constant-offset
    /// render committed at its `legacy` key because the contour was
    /// unavailable. In memory ON PURPOSE:
    ///  * a failed detection must not be pinned on disk under the key a
    ///    successful one would use — that would serve the degraded audio as
    ///    fresh forever;
    ///  * but the clip must not go silent either — the engine re-resolves
    ///    through `cachedURL` after the job and must find SOMETHING to play;
    ///  * so the fallback is remembered for the session and retried on the
    ///    next launch (or the next edit, which is a new key).
    ///
    /// The reason travels WITH the file, keyed the same way, so "which file
    /// plays" and "why it is the fallback" cannot come apart
    /// (`contourShortfall`).
    private var contourFallbacks: [String: (url: URL, reason: String)] = [:]

    public convenience init(directory: URL? = nil) {
        self.init(directory: directory, contourDetector: .product)
    }

    /// Test seam: inject the contour detector.
    init(directory: URL?, contourDetector: PitchContourCache.Detector) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("StretchRenders", isDirectory: true)
        self.contourDetector = contourDetector
    }

    // MARK: - Status (pull-based, spec §5)

    public func status(forClip clipID: UUID) -> ClipStretchStatus {
        statuses[clipID] ?? .idle
    }

    /// Why a clip rendering `(source, params)` plays — or, once rendered, will
    /// play — its CONSTANT-OFFSET fallback instead of the contour-shaped render
    /// its edits ask for; `nil` when it does not. The engine turns this into a
    /// visible notice (design §7.2: never a silent substitution); the curve
    /// also names the affected segments in
    /// `PitchCorrectionCurve.unresolvedShapingSegmentIDs`.
    ///
    /// ⭐ **ANSWERED FROM WHAT IS COMMITTED, NOT FROM WHETHER A JOB RAN.** A
    /// fallback can be served from disk with no render at all — edits from
    /// another detector generation sit under their (unchanged) legacy key
    /// across launches — and a notice that only a completed job could raise
    /// would go quiet exactly then. So:
    ///  * edits from ANOTHER detector generation → never shaped (§7.2), so
    ///    always short, whatever is on disk;
    ///  * this session's detection failed for the render's key → that
    ///    failure's reason, until the resolved render exists;
    ///  * anything else → `nil` (including a later session, which retries).
    public func contourShortfall(source: URL, params: Params) -> String? {
        guard let set = params.pitchEdits, set.needsDetectedContour else { return nil }
        if set.analysisVersion != contourDetector.analysisVersion {
            return Self.shortfallReason(.analysisVersionMismatch(
                editSet: set.analysisVersion, detector: contourDetector.analysisVersion))
        }
        guard !contourFallbacks.isEmpty,
              let keys = try? Self.renderKeys(source: source, params: params,
                                              detector: contourDetector),
              !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(keys.resolved + ".caf").path)
        else { return nil }
        return contourFallbacks[keys.resolved]?.reason
    }

    /// THE one wording of a contour shortfall — a clause that completes
    /// "…the wobble inside each note is kept, because ___". Shared by the
    /// render (which knows what the seam answered) and `contourShortfall`
    /// (which re-derives the version rule without running anything), so the
    /// two can never describe one fallback in two ways.
    nonisolated static func shortfallReason(_ contour: PitchRenderContour?) -> String? {
        switch contour {
        case nil, .detected?:
            return nil
        case .analysisVersionMismatch(let editSet, let detector)?:
            return "the tuning was made with a different version of the pitch analysis "
                + "(v\(editSet); this build runs v\(detector)) — apply the tuning again "
                + "to hear it flattened"
        case .unavailable(let reason)?:
            return "the singing's pitch could not be analysed (\(reason))"
        }
    }

    /// Cancels and clears any in-flight job for a clip that left the model.
    public func cancelJob(forClip clipID: UUID) {
        jobs.removeValue(forKey: clipID)?.cancel()
        statuses[clipID] = nil
    }

    // MARK: - Key derivation (spec §3)

    /// A source file's identity as every content-keyed entry here sees it:
    /// standardized path ‖ size ‖ mtime bit pattern. Cheap, standard
    /// waveform-cache practice; a moved project re-renders once and
    /// self-heals — across launches AND within a session (a save or Save As
    /// that repoints a clip at its bundle copy), the latter only because the
    /// engine's kick dedupe compares the key derived from these fields rather
    /// than `Params` (2026-09-24; before that, a repointed clip went silent
    /// until the next launch). Throws when the source file is unreadable.
    ///
    /// ONE derivation (design §7.8): the render key and the detected-contour
    /// key (`PitchContourCache.key`) both start from exactly these strings.
    nonisolated static func sourceIdentityFields(source: URL) throws -> [String] {
        let path = source.standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        return [path, String(size), String(mtime.bitPattern)]
    }

    /// SHA256 over the fields, each followed by a 0 separator; first 16 hex
    /// chars. The one hashing step every key here goes through.
    nonisolated static func keyDigest(_ fields: [String]) -> String {
        var hasher = SHA256()
        for field in fields {
            hasher.update(data: Data(field.utf8))
            hasher.update(data: Data([0]))  // field separator
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// SHA256 over (standardized source path ‖ file size ‖ mtime ‖ ratio bit
    /// pattern ‖ semitones bit pattern ‖ formant flag ‖ engine version
    /// [‖ `pitch:<edit digest>`] [‖ `contour:<contour key>`]); first 16 hex
    /// chars = filename. See `RenderKeys` for which of the two keys a render
    /// commits under. Throws when the source file is unreadable.
    nonisolated static func renderKeys(source: URL, params: Params,
                                       detector: PitchContourCache.Detector) throws -> RenderKeys {
        var fields = try sourceIdentityFields(source: source)
        fields += [
            String(params.ratio.bitPattern),
            String(params.semitones.bitPattern),
            params.formantPreserve ? "1" : "0",
            String(stretchEngineVersion),
        ]
        // APPENDED ONLY WHEN THERE ARE EDITS, so every key derived before
        // m23-q is still the same 16 hex chars and no existing cache entry is
        // orphaned by a feature that did not change its audio. A field that
        // was always appended — even as an empty string — would silently
        // re-render every stretched clip in every project on this machine.
        if !params.pitchEditSetHash.isEmpty {
            fields.append("pitch:" + params.pitchEditSetHash)
        }
        let legacy = keyDigest(fields)
        // contour-to-render — THE SAME RULE, ONE LEVEL DOWN. Appended only
        // when the render actually shapes against the contour, so every set
        // that does not (the preset ladder, generator-only edits, plain
        // offsets) keeps its key byte for byte. A set that DOES now renders
        // different audio than it did before the contour reached the render
        // (flattened, not a constant offset), so it MUST re-key — keeping the
        // old key would serve the old constant-offset render as if it were
        // the fix. Embedding the contour's own key means anything that
        // re-keys the contour (the file, the detector generation, its
        // thresholds, the model) re-keys every render shaped against it.
        guard params.shapesAgainstContour(detector) else {
            return RenderKeys(resolved: legacy, legacy: legacy)
        }
        fields.append("contour:" + (try PitchContourCache.key(source: source, detector: detector)))
        // …and the version of the arithmetic that turns (edits, contour) into
        // a curve, which neither key above can see — see
        // `PitchRenderContour.shapingVersion`.
        fields.append("shaping:\(PitchRenderContour.shapingVersion)")
        return RenderKeys(resolved: keyDigest(fields), legacy: legacy)
    }

    /// The key a render of (source, params) is looked up and committed under
    /// when it gets what it asked for (`RenderKeys.resolved`).
    nonisolated static func cacheKey(
        source: URL, params: Params,
        detector: PitchContourCache.Detector = .product
    ) throws -> String {
        try renderKeys(source: source, params: params, detector: detector).resolved
    }

    /// The keys a render of (source, params) lives under with THIS cache's
    /// detector — the one derivation the engine's resolve path, `cachedURL`
    /// and `renderIfNeeded` all use. The engine derives it ONCE per resolve
    /// and uses `resolved` both for the committed lookup and as its kick
    /// dedupe, so "which render does this clip need" and "has that render
    /// been asked for" are answered from the same string. Throws when the
    /// source file is unreadable (the stat in `sourceIdentityFields`).
    func keys(source: URL, params: Params) throws -> RenderKeys {
        try Self.renderKeys(source: source, params: params, detector: contourDetector)
    }

    /// The committed cache entry for (source, params), or nil when absent /
    /// key underivable. Pure lookup — never starts a job (OfflineRenderer's
    /// provider uses it after the mixdown wait). Includes this session's
    /// contour fallback — see `committedURL(for:)`.
    public func cachedURL(source: URL, params: Params) -> URL? {
        guard let keys = try? self.keys(source: source, params: params) else { return nil }
        return committedURL(for: keys)
    }

    /// The display's door to THE seam: the contour the render uses for a clip
    /// whose source is `source` and whose edits carry `analysisVersion`,
    /// computed off the main actor. Same function, same cache directory, same
    /// detector as `performRender` — see `PitchContourCache.renderContour`.
    public func renderContour(source: URL, analysisVersion: Int) async -> PitchRenderContour {
        let directory = self.directory
        let detector = contourDetector
        return await Task.detached(priority: .userInitiated) {
            PitchContourCache.renderContour(
                source: source, analysisVersion: analysisVersion,
                renderCacheDirectory: directory, detector: detector)
        }.value
    }

    // MARK: - renderIfNeeded (the one async entry point)

    /// Returns the stretched CAF for (source, params): cache hit → immediate;
    /// miss → a debounced detached render job (per-clip latest-wins — a newer
    /// request for the same clip cancels an in-flight older one; same-key
    /// requests coalesce onto the running job). Identity params return the
    /// source unchanged (callers shouldn't ask, but the answer is honest).
    /// Throws `CancellationError`/`.cancelled` when superseded, or the render
    /// error (also recorded in `status(forClip:)` as `.failed`).
    public func renderIfNeeded(clipID: UUID, source: URL, params: Params) async throws -> URL {
        if params.isIdentity {
            return source
        }
        let keys = try Self.renderKeys(source: source, params: params, detector: contourDetector)
        if let committed = committedURL(for: keys) {
            return committed
        }
        let key = keys.resolved
        let destination = directory.appendingPathComponent(key + ".caf")
        let fallbackDestination = directory.appendingPathComponent(keys.legacy + ".caf")
        if let job = jobs[clipID], job.key == key {
            return try await job.task.value  // single-flight: coalesce onto it
        }
        // Latest-wins: a newer request supersedes the in-flight job.
        jobs.removeValue(forKey: clipID)?.cancel()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        // Unique partial per job: two clips sharing one (source, params) key
        // may race — each writes its own partial; the rename commits once.
        let partial = directory.appendingPathComponent("\(key).partial-\(token.uuidString).caf")
        let renderCacheDirectory = directory
        let detector = contourDetector
        statuses[clipID] = .rendering
        let task = Task { @MainActor [weak self] () throws -> URL in
            Self.jobPhaseForTesting?("job-start", Task.currentPriority)
            do {
                // Debounce: cancellation during this sleep throws — the job
                // dies before any file I/O happens.
                try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
                Self.jobPhaseForTesting?("debounce-end", Task.currentPriority)
                self?.renderCount += 1
                // The blocking render runs detached — fetches-or-detects the
                // contour when the edits need one, reads the FULL source,
                // pumps the facade, writes the partial, atomically renames.
                // Result-boxed so the detached task never throws into the
                // structured tree before we re-check cancellation.
                let outcome = await Task.detached(priority: .userInitiated) {
                    Result {
                        try Self.performRender(
                            source: source, partial: partial, destination: destination,
                            fallbackDestination: fallbackDestination, params: params,
                            renderCacheDirectory: renderCacheDirectory, detector: detector,
                            isCancelled: { cancelled.withLock { $0 } })
                    }
                }.value
                Self.jobPhaseForTesting?("render-returned", Task.currentPriority)
                try Task.checkCancellation()
                let rendered = try outcome.get()
                let committed: URL
                switch rendered {
                case .rendered(let url):
                    committed = url
                case .fellBack(let url, let reason):
                    committed = url
                    // Keyed by the RESOLVED key, not by the clip: the memo
                    // says "this session could not resolve this render", which
                    // is true for any clip asking for it. When resolved ==
                    // legacy (another detector generation) the file already
                    // sits under the resolved key and needs no memo — and
                    // `contourShortfall` re-derives that reason from the
                    // version rule alone, on every launch.
                    if keys.resolved != keys.legacy {
                        self?.contourFallbacks[keys.resolved] = (url, reason)
                    }
                }
                // Bookkeeping only if this job still owns the clip's slot
                // (a superseding job may have replaced it mid-render).
                if let self, self.jobs[clipID]?.token == token {
                    self.jobs[clipID] = nil
                    self.statuses[clipID] = nil
                    self.onRenderComplete?(clipID)
                }
                return committed
            } catch {
                if let self, self.jobs[clipID]?.token == token {
                    self.jobs[clipID] = nil
                    let wasCancelled = error is CancellationError
                        || (error as? OfflineStretcherError) == .cancelled
                    self.statuses[clipID] = wasCancelled
                        ? nil : .failed(String(describing: error))
                }
                throw error
            }
        }
        jobs[clipID] = Job(token: token, key: key, task: task, cancelled: cancelled)
        return try await task.value
    }

    // MARK: - The blocking render (detached-task body; never on the main actor)

    /// What one render committed, and where.
    enum RenderOutcome: Equatable, Sendable {
        /// The render the params asked for, at the resolved key.
        case rendered(URL)
        /// The contour was unavailable, so the CONSTANT-OFFSET render — the
        /// exact audio this cache produced for these edits before the contour
        /// reached the render — was committed (or found already committed) at
        /// the LEGACY key instead. `reason` is for the engine's notice.
        case fellBack(URL, reason: String)
    }

    /// Reads the whole source file, stretches it through the `OfflineStretcher`
    /// facade (deterministic fixed-seed output — cache entries are
    /// reproducible), writes a Float32 CAF partial and renames it into place.
    /// The partial is cleaned up on every exit path; a lost rename race
    /// against a same-key sibling job counts as success (identical bytes by
    /// determinism).
    ///
    /// **contour-to-render.** When the edits need the detected contour, it is
    /// fetched-or-detected FIRST, through THE seam
    /// (`PitchContourCache.renderContour`), here, inside this already-detached
    /// task — never on the main actor, never on the render thread. Then:
    ///  * `.detected` → the curve is built from it and the render commits at
    ///    `destination` (the resolved key, which names the contour).
    ///  * anything else → the render is EXACTLY the pre-contour render (the
    ///    curve with no contour: constant per-note offsets, the shaping
    ///    segments named in `unresolvedShapingSegmentIDs`) and commits at
    ///    `fallbackDestination` (the legacy key) — reusing the entry already
    ///    there if one exists, since it is byte-identical by construction.
    ///    Never silence, and never the fallback under the resolved key, where
    ///    it would be served as the fix.
    ///
    /// **I7a/U-C, the level mask.** When a note is cleared or levelled
    /// (`PitchEditSet.hasLevelEdits`), every delivered output frame inside
    /// that note is multiplied by `PitchEditSet.gain(atSourceSecond:)`, on
    /// every branch (`StretchCurvePlan.applyLevelMask`). A set whose only
    /// edits are levels, on a clip that is neither stretched nor transposed,
    /// takes the LEVEL-ONLY path: the stretcher never runs, and the output is
    /// the source times the mask, bit-exact outside the level-edited notes.
    nonisolated static func performRender(
        source: URL, partial: URL, destination: URL, fallbackDestination: URL,
        params: Params, renderCacheDirectory: URL, detector: PitchContourCache.Detector,
        isCancelled: @Sendable () -> Bool
    ) throws -> RenderOutcome {
        defer { try? FileManager.default.removeItem(at: partial) }  // no-op after rename

        // (1) The contour, when these edits shape against one. Detection is
        //     the slow part, and it runs before the source is even read so a
        //     fallback that is already on disk costs nothing further.
        let contour = try resolveRenderContour(
            params: params, source: source, renderCacheDirectory: renderCacheDirectory,
            detector: detector, isCancelled: isCancelled)
        let fallbackReason = contour.fallbackReason
        let target = fallbackReason == nil ? destination : fallbackDestination
        if let fallbackReason, FileManager.default.fileExists(atPath: target.path) {
            return .fellBack(target, reason: fallbackReason)
        }

        let reader = try AVAudioFile(forReading: source)
        let format = reader.processingFormat  // deinterleaved float32, source rate
        let channelCount = Int(format.channelCount)
        guard reader.length > 0, channelCount > 0 else {
            throw OfflineStretcherError.invalidInput("empty source \(source.path)")
        }
        var planar = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            planar[channel].reserveCapacity(Int(reader.length))
        }
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw OfflineStretcherError.allocationFailed
        }
        // Loop read: AVAudioFile.read(into:) can return short (measured
        // elsewhere in this codebase) — a single call would truncate.
        while reader.framePosition < reader.length {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            try reader.read(into: chunk)
            guard chunk.frameLength > 0, let data = chunk.floatChannelData else { break }
            for channel in 0..<channelCount {
                planar[channel].append(contentsOf: UnsafeBufferPointer(
                    start: data[channel], count: Int(chunk.frameLength)))
            }
        }

        // (2) THE ONE RENDER LOOP'S BODY, over the whole source.
        let stretched = try renderAudio(
            whole: &planar, window: nil, sampleRate: format.sampleRate, params: params,
            curveContour: contour.curveContour, isCancelled: isCancelled).output.planar

        let outFrames = stretched[0].count
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(outFrames)),
            let outData = outBuffer.floatChannelData
        else {
            throw OfflineStretcherError.allocationFailed
        }
        for channel in 0..<channelCount {
            stretched[channel].withUnsafeBufferPointer { src in
                outData[channel].update(from: src.baseAddress!, count: outFrames)
            }
        }
        outBuffer.frameLength = AVAudioFrameCount(outFrames)

        // Float32 CAF at the source rate/channels (interleaved on disk, like
        // the WAV bounce path). Scoped so the file closes before the rename.
        var settings: [String: Any] = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do {
            let writer = try AVAudioFile(forWriting: partial, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: outBuffer)
        }
        // A render cancelled after the last block must not commit.
        if isCancelled() { throw OfflineStretcherError.cancelled }
        do {
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            // Same-key sibling won the rename — identical bytes, so ours is
            // redundant, not failed.
            guard FileManager.default.fileExists(atPath: target.path) else { throw error }
        }
        if let fallbackReason {
            return .fellBack(target, reason: fallbackReason)
        }
        return .rendered(target)
    }

    // MARK: - THE ONE RENDER LOOP'S BODY, and its second entry (I1-F1)

    /// The contour a render of `params` shapes against, resolved through THE
    /// seam (`PitchContourCache.renderContour`), and why it falls back when it
    /// does. `performRender` and `renderSpan` both ask here, so a span can
    /// never be shaped against a contour the whole-file render would not use.
    ///
    /// I1-F2 (RT re-review NH-A): `isCancelled` also reaches the seam, where a
    /// caller WAITING for another caller's detection (the single flight) gives
    /// up as soon as it is cancelled; it throws `.cancelled` on the poll just
    /// below, so the seam's answer to a cancelled wait is never used.
    ///
    /// ⭐ **A DRAFT SPAN RENDER MAY START A DETECTION, not only wait for one**
    /// (the re-review suggested never starting one). Decided, because:
    ///  1. with the single flight, starting one costs at most ONE detection per
    ///     entry however many drafts ask, and the leader always commits: the
    ///     release's span render and the whole-file render need that same
    ///     contour moments later, so the work is never wasted;
    ///  2. not starting one would render the pre-contour curve: a drag would
    ///     play one sound (the notes held at a constant offset) and the release
    ///     and playback another (flattened). That is "the preview would be one
    ///     shifter and the result another", which the design forbids, and it
    ///     breaks R7 above (the span shaped against what the whole-file render
    ///     uses);
    ///  3. the display warms the entry when the editor opens, so a drag
    ///     normally finds it hot, or waits for the display's detection as a
    ///     follower anyway. "May start" matters only when nothing is in flight:
    ///     a purged or re-keyed sidecar, or the wire's draft door on a clip no
    ///     display has opened. There "never start" would leave every drag step
    ///     playing the wrong curve until a press or a release came along.
    /// The cost: on a cold entry, the first draft step plays once the
    /// detection lands (0.5–0.6 s per 33 s of take, measured), once per entry.
    nonisolated static func resolveRenderContour(
        params: Params, source: URL, renderCacheDirectory: URL,
        detector: PitchContourCache.Detector, isCancelled: () -> Bool
    ) throws -> (curveContour: PitchRenderContour?, fallbackReason: String?) {
        var contour: PitchRenderContour?
        if let set = params.pitchEdits, set.needsDetectedContour {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            contour = PitchContourCache.renderContour(
                source: source, analysisVersion: set.analysisVersion,
                renderCacheDirectory: renderCacheDirectory, detector: detector,
                isCancelled: isCancelled)
            if isCancelled() { throw OfflineStretcherError.cancelled }
        }
        let fallbackReason = shortfallReason(contour)
        // contour-to-render: the contour goes in ONLY when it was detected.
        // A fallback passes `nil`, which is the pre-contour curve bit for bit
        // — the audio the legacy key has always held for these edits.
        return (fallbackReason == nil ? contour : nil, fallbackReason)
    }

    /// Which branch of the one loop rendered something.
    enum RenderPath: String, Sendable, Equatable {
        /// The time-varying transpose loop (the clip's edits bend pitch).
        case curve
        /// Source × level mask; the stretcher never ran.
        case levelOnly = "level-only"
        /// The constant stretch/transpose loop.
        case constant
        /// No render at all: the clip plays its source file (identity params).
        case sourceFile = "source-file"
    }

    /// **THE ONE RENDER LOOP'S BODY: the curve, the branch, the stretcher
    /// configuration and the level mask**, for the whole source
    /// (`performRender`, `window == nil`, reading `whole`) or for one WINDOW of
    /// the whole-file render (`renderSpan`, I1-F1). Extracted from
    /// `performRender` verbatim so the span render is a second ENTRY into it,
    /// never a copy; `wholeFileGoldenCapture` diffs the whole-file bytes across
    /// the extraction.
    ///
    /// m23-q Phase 1: a clip carrying pitch edits renders through the
    /// TIME-VARYING transpose path, latency-compensated. Everything else takes
    /// the constant call it always took, unchanged — an edit-free render is
    /// byte-identical to the one this cache produced before pitch correction
    /// existed, which `editFreeRenderIsByteIdenticalToTheConstantCall` pins
    /// rather than assumes.
    ///
    /// The curve SUBSUMES `params.semitones` (design §6.4/§7.8), so the
    /// constant is NOT also passed on that branch — doing both would transpose
    /// twice.
    ///
    /// `whole` is consumed on the level-only path (the render becomes its sole
    /// owner, so the mask pass never copies the take); pass `[]` with a window.
    nonisolated static func renderAudio(
        whole: inout [[Float]], window: StretchWindow?, sampleRate: Double, params: Params,
        curveContour: PitchRenderContour?, isCancelled: () -> Bool
    ) throws -> (output: StretchWindowOutput, path: RenderPath) {
        let plan = StretchCurvePlan.make(
            editSet: params.pitchEdits,
            clipPitchShiftSemitones: params.semitones,
            sampleRate: sampleRate,
            ratio: params.ratio,
            contour: curveContour)
        // I7a/U-C (interaction-batch design §10/§17): cleared notes and per-note
        // levels. `nil` when no note is cleared or levelled, and then nothing
        // below differs from the render this cache made before the mask existed.
        let levelEdits = params.pitchEdits.flatMap { $0.hasLevelEdits ? $0 : nil }
        var rendered: StretchWindowOutput
        let path: RenderPath
        if let plan {
            path = .curve
            let semitones: (Int) -> Double = { plan.semitones(atOutputFrame: $0) }
            let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
            if let window {
                rendered = try OfflineStretcher.stretchTransposeCurve(
                    window: window, sampleRate: sampleRate, ratio: params.ratio,
                    semitonesAtOutputFrame: semitones,
                    formantPreserve: params.formantPreserve,
                    compensation: compensation, isCancelled: isCancelled)
            } else {
                rendered = StretchWindowOutput(
                    planar: try OfflineStretcher.stretchTransposeCurve(
                        input: whole, sampleRate: sampleRate, ratio: params.ratio,
                        semitonesAtOutputFrame: semitones,
                        formantPreserve: params.formantPreserve,
                        compensation: compensation, isCancelled: isCancelled),
                    firstOutputFrame: 0)
            }
        } else if levelEdits != nil,
                  OfflineStretcher.isIdentity(ratio: params.ratio, semitones: params.semitones) {
            // ⭐ THE LEVEL-ONLY PATH. Every note is pitch-identity (`make`
            // returned nil) and the clip is neither stretched nor transposed,
            // so the stretcher NEVER runs. A ratio-1 stretch is not its own
            // input, and clearing one breath must not recolour the take. The
            // output is the source times the mask, so every sample outside a
            // level-edited note keeps the source's own bytes. At ratio 1 an
            // output frame IS its source frame, so a window reads exactly its
            // own frames and is exact by construction.
            path = .levelOnly
            if let window {
                let start = min(window.startOutputFrame, window.sourceFrames)
                let end = min(window.endOutputFrame, window.sourceFrames)
                guard end > start else {
                    throw OfflineStretcherError.invalidInput("empty window \(start)..<\(end)")
                }
                rendered = StretchWindowOutput(planar: try window.readSource(start..<end),
                                               firstOutputFrame: start)
            } else {
                rendered = StretchWindowOutput(planar: whole, firstOutputFrame: 0)
                whole = []  // sole owner, so the mask pass does not copy the take
            }
        } else {
            path = .constant
            if let window {
                rendered = try OfflineStretcher.stretch(
                    window: window, sampleRate: sampleRate, ratio: params.ratio,
                    semitones: params.semitones, formantPreserve: params.formantPreserve,
                    isCancelled: isCancelled)
            } else {
                rendered = StretchWindowOutput(
                    planar: try OfflineStretcher.stretch(
                        input: whole, sampleRate: sampleRate, ratio: params.ratio,
                        semitones: params.semitones, formantPreserve: params.formantPreserve,
                        isCancelled: isCancelled),
                    firstOutputFrame: 0)
            }
        }
        // The ONE mask, applied one way on every branch (design §17.5): each
        // delivered output frame times `PitchEditSet.gain(atSourceSecond:)`
        // at the source second the one mapping says it plays — for a window,
        // at its WHOLE-FILE frames.
        if let levelEdits {
            try StretchCurvePlan.applyLevelMask(
                levelEdits, to: &rendered.planar, sampleRate: sampleRate,
                ratio: params.ratio, outputFrameOffset: rendered.firstOutputFrame,
                isCancelled: isCancelled)
        }
        return (rendered, path)
    }

    /// **I1-F1's pick: how far before the first requested frame a span render
    /// starts**, so its fresh stretcher has settled by then. MEASURED
    /// 2026-09-25 with THIS window code on a synthetic voice at ratio 1
    /// (`ClipSpanRenderTests.preRollConvergenceCurve`), a window starting in
    /// untransposed audio: no pre-roll leaves the stretcher's warm-up in the
    /// span (−79 dB over 0.5 s, −57 dB over its first 30 ms); 30 ms (one
    /// block) and every longer pre-roll up to 2 s converge at −124 to −128 dB.
    /// The pick is four blocks, and costs a few ms of render per request.
    /// On the user's take (`spanRenderMeasurementsOnTheUsersTake`, same day),
    /// from a gap: no pre-roll −88 dB, 0.1 s −137 dB. (An earlier probe of a
    /// cruder slice construction, `phaseMemoryProbe`, needed 60 ms; the pick
    /// covers every case measured.)
    ///
    /// ⚠️ It buys convergence only where the whole-file render arrives at the
    /// window with untransposed history at ratio 1. A window that starts
    /// INSIDE an edited note converges only once the pre-roll reaches back
    /// before that note's start (on the take, a window 0.15 s into the note:
    /// +4 dB at 0.1 s of pre-roll, −127 dB at 0.25 s), and transposed history
    /// or a ratio ≠ 1 never converges at any pre-roll up to 2 s (−7 to +6 dB on
    /// the take, −1 to +5 dB with transposed history at ratio 1: same pitch
    /// and level, other partial phases). See `StretchWindow.swift`.
    nonisolated static let spanPreRollSeconds = 0.12

    /// R3 (incremental-note-render design §1): the pre-roll, in output frames,
    /// that `renderOutputFrames` uses by default. THE one home of the number;
    /// the playback lane reads it here rather than copying it.
    nonisolated static func minimumPreRollFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Int((spanPreRollSeconds * sampleRate).rounded())
    }

    /// R3: the post-roll a window needs past its last requested frame: NONE.
    /// A window runs the whole-file schedule, so its last block reads the input
    /// the whole-file render reads for that block (up to one seek length plus
    /// one block beyond the requested end, from the real source, never
    /// silence), and every frame it delivers is final when delivered. Named so
    /// no lane invents one.
    nonisolated static func minimumPostRollFrames(sampleRate: Double) -> Int { 0 }

    /// The source a span render reads: its identity (the contour seam keys on
    /// the URL), its shape, and a caller-supplied reader (R10: the primitive
    /// writes no audio and opens no source itself; `open(_:)` is the stock
    /// `AVAudioFile` reader).
    struct SpanSource {
        let url: URL
        let channels: Int
        let sampleRate: Double
        /// The whole source's length in frames.
        let frames: Int
        /// Source frames `range`, one array per channel of exactly
        /// `range.count` frames; polls the given `isCancelled` between chunks.
        let read: (Range<Int>, () -> Bool) throws -> [[Float]]

        /// The source file, read through `AVAudioFile`. Not thread-safe: use one
        /// instance per render, on one thread.
        static func open(_ url: URL) throws -> SpanSource {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat  // deinterleaved float32, source rate
            let channels = Int(format.channelCount)
            let frames = Int(file.length)
            guard frames > 0, channels > 0 else {
                throw OfflineStretcherError.invalidInput("empty source \(url.path)")
            }
            return SpanSource(url: url, channels: channels, sampleRate: format.sampleRate,
                              frames: frames,
                              read: { range, isCancelled in
                                  try readFrames(of: file, range: range, isCancelled: isCancelled)
                              })
        }
    }

    /// One span render: planar samples for WHOLE-FILE output frames
    /// `firstOutputFrame ..< firstOutputFrame + planar[0].count` of the render
    /// playback plays for `params` (for `.sourceFile`: of the source itself),
    /// at the source's own rate and channel count.
    struct SpanRender: Sendable {
        let planar: [[Float]]
        let sampleRate: Double
        let firstOutputFrame: Int
        /// The output-duration multiplier the frames are at (1 for the source).
        let ratio: Double
        let path: RenderPath
        /// I1-F2: why these frames play the CONSTANT-OFFSET curve instead of the
        /// contour-shaped one their edits ask for, or nil when they do not.
        /// It is `resolveRenderContour`'s own reason, in the one wording
        /// (`shortfallReason`) the whole-file render memos and
        /// `contourShortfall` reports; it used to be dropped here. The engine
        /// posts it through the notice the whole-file path posts
        /// (`AudioEngine.postContourShortfallNotice`), so a span and the final
        /// render of the same edit say the same thing.
        var contourFallbackReason: String? = nil
    }

    /// **I1-F1: THE SECOND ENTRY INTO THE ONE RENDER LOOP, in frames (R1).**
    /// Returns EXACTLY `frames.count` frames per channel, planar Float32 at the
    /// source's rate and channel count, where result frame `i` IS frame
    /// `frames.lowerBound + i` of the file the whole-file render writes for
    /// `params` (of the source itself when `params` is identity).
    ///
    /// - The same `Params` (ratio, transpose, formant flag, the STORED or a
    ///   DRAFT edit set), the same contour decision (`resolveRenderContour`,
    ///   R7), the same curve, branch, stretcher configuration and level mask at
    ///   GLOBAL frames (`renderAudio`, R6), on the same schedule
    ///   (`StretchSchedule`: the whole file's input targets, the whole file's
    ///   block grid, the curve read at the same lookup frames; R2), starting at
    ///   a block boundary `preRollFrames` or more before `frames`.
    /// - A plain function (R8): no main-actor hop, no state shared with the
    ///   whole-file job (`jobs`, `statuses` are never touched), cancellation
    ///   polled per block and per read chunk. Callers own their own
    ///   latest-wins.
    /// - Reads only the frames the window needs, so its cost follows the span,
    ///   not the take. Writes no audio (R10). ⚠️ One exception, and it is R7's:
    ///   a COLD contour-shaped render (`needsDetectedContour`) runs detection
    ///   over the whole source through the one contour seam, which commits the
    ///   contour sidecar into `renderCacheDirectory` (first writer wins): the
    ///   very file the whole-file render writes, and whose cost follows the
    ///   take (MEASURED on the 33 s take: 474 ms cold, 33 ms hot). The pitch
    ///   editor's display reaches the same seam, so a drag normally finds it
    ///   hot. I1-F2: ONE detection per entry runs at a time however many
    ///   renders ask (the seam's single flight); a render waiting for another
    ///   one's detection gives up as soon as it is cancelled.
    /// - Deterministic (R9): the same inputs give bit-identical output.
    ///
    /// ⚠️ Exact (to float noise) only where the whole-file render arrives at the
    /// window with an untransposed, ratio-1 history; otherwise same pitch and
    /// level, different partial phases (`StretchWindow.swift`'s banner). The
    /// level-only path is bit-exact always.
    ///
    /// BLOCKING, and allocating: call it from a detached task, never the main
    /// actor, never the render thread.
    nonisolated static func renderOutputFrames(
        _ frames: Range<Int>, of source: SpanSource, params: Params,
        preRollFrames: Int? = nil, renderCacheDirectory: URL,
        detector: PitchContourCache.Detector, isCancelled: () -> Bool
    ) throws -> SpanRender {
        let identity = params.isIdentity
        let ratio = identity ? 1 : params.ratio
        let outputFrames = identity ? source.frames
            : Int((Double(source.frames) * params.ratio).rounded())
        guard frames.lowerBound >= 0, !frames.isEmpty, frames.upperBound <= outputFrames else {
            throw OfflineStretcherError.invalidInput(
                "frames \(frames) are not inside the render's 0..<\(outputFrames)")
        }
        if isCancelled() { throw OfflineStretcherError.cancelled }
        // A clip that plays its source: its "render" is the source itself.
        if identity {
            return SpanRender(planar: try source.read(frames, isCancelled),
                              sampleRate: source.sampleRate, firstOutputFrame: frames.lowerBound,
                              ratio: 1, path: .sourceFile)
        }
        let contour = try resolveRenderContour(
            params: params, source: source.url, renderCacheDirectory: renderCacheDirectory,
            detector: detector, isCancelled: isCancelled)
        let preRoll = max(0, preRollFrames ?? minimumPreRollFrames(sampleRate: source.sampleRate))
        // The window's reader is stored, so it needs an escapable view of
        // `isCancelled`; it never outlives this call (the render runs
        // synchronously inside it).
        let (rendered, path) = try withoutActuallyEscaping(isCancelled) { isCancelled in
            let window = StretchWindow(
                channels: source.channels, sourceFrames: source.frames,
                startOutputFrame: max(0, frames.lowerBound - preRoll),
                endOutputFrame: frames.upperBound,
                readSource: { range in try source.read(range, isCancelled) })
            var unused: [[Float]] = []
            return try renderAudio(
                whole: &unused, window: window, sampleRate: source.sampleRate, params: params,
                curveContour: contour.curveContour, isCancelled: isCancelled)
        }
        // Drop the pre-roll: exactly the requested frames.
        let skip = frames.lowerBound - rendered.firstOutputFrame
        guard skip >= 0, let produced = rendered.planar.first?.count,
              skip + frames.count <= produced else {
            throw OfflineStretcherError.invalidInput(
                "window \(rendered.firstOutputFrame)+\(rendered.planar.first?.count ?? 0) "
                    + "does not cover \(frames)")
        }
        return SpanRender(
            planar: rendered.planar.map { Array($0[skip..<(skip + frames.count)]) },
            sampleRate: source.sampleRate, firstOutputFrame: frames.lowerBound, ratio: ratio,
            path: path, contourFallbackReason: contour.fallbackReason)
    }

    /// The SOURCE-second form (the audition's): the frames of the render
    /// playback plays for `params` that play source seconds
    /// `startSourceSeconds ..< endSourceSeconds`, mapped through
    /// `StretchCurvePlan.outputFrame(forSourceSecond:…)` (the one mapping) and
    /// clipped to the render. A thin wrapper; the frames come from
    /// `renderOutputFrames`.
    nonisolated static func renderSpan(
        source url: URL, params: Params, startSourceSeconds: Double, endSourceSeconds: Double,
        preRollFrames: Int? = nil, renderCacheDirectory: URL,
        detector: PitchContourCache.Detector, isCancelled: () -> Bool
    ) throws -> SpanRender {
        guard startSourceSeconds.isFinite, endSourceSeconds.isFinite,
              endSourceSeconds > startSourceSeconds else {
            throw OfflineStretcherError.invalidInput(
                "span \(startSourceSeconds)…\(endSourceSeconds) s is empty")
        }
        if isCancelled() { throw OfflineStretcherError.cancelled }
        let source = try SpanSource.open(url)
        let ratio = params.isIdentity ? 1 : params.ratio
        let outputFrames = params.isIdentity ? source.frames
            : Int((Double(source.frames) * params.ratio).rounded())
        let start = min(outputFrames, StretchCurvePlan.outputFrame(
            forSourceSecond: startSourceSeconds, ratio: ratio, sampleRate: source.sampleRate))
        let end = min(outputFrames, StretchCurvePlan.outputFrame(
            forSourceSecond: endSourceSeconds, ratio: ratio, sampleRate: source.sampleRate))
        guard end > start else {
            throw OfflineStretcherError.invalidInput("span lies past the render's end")
        }
        return try renderOutputFrames(
            start..<end, of: source, params: params, preRollFrames: preRollFrames,
            renderCacheDirectory: renderCacheDirectory, detector: detector,
            isCancelled: isCancelled)
    }

    /// R2/R4: the whole-file CURVE loop's schedule for a source of this shape:
    /// the block grid (`blockFrames` is the stretcher's own hop, read from it,
    /// never derived), the input targets, and where the flush starts. Chunk
    /// `k` starts at output frame `k × blockFrames`, and the curve is read for
    /// it at `OfflineStretcher.curveLookupFrame(outputFrame:compensation:
    /// intervalSamples:)` with `OfflineStretcher.curveLatencyCompensation(
    /// sampleRate:)`. The one grid, for any lane that must agree with it.
    nonisolated static func curveSchedule(sourceFrames: Int, channels: Int, sampleRate: Double,
                                          ratio: Double) throws -> StretchSchedule {
        try OfflineStretcher.curveSchedule(sourceFrames: sourceFrames, channels: channels,
                                           sampleRate: sampleRate, ratio: ratio)
    }

    /// Source frames `range` of `file`, planar. Loop read:
    /// `AVAudioFile.read(into:)` can return short (measured elsewhere in this
    /// codebase); a short file reads as silence past its end. Checks
    /// `isCancelled` between chunks.
    nonisolated static func readFrames(of file: AVAudioFile, range: Range<Int>,
                                       isCancelled: () -> Bool) throws -> [[Float]] {
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        var planar = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount { planar[channel].reserveCapacity(range.count) }
        guard !range.isEmpty else { return planar }
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw OfflineStretcherError.allocationFailed
        }
        file.framePosition = AVAudioFramePosition(range.lowerBound)
        var remaining = range.count
        while remaining > 0 {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            try file.read(into: chunk, frameCount: AVAudioFrameCount(min(remaining, 16_384)))
            let got = Int(chunk.frameLength)
            guard got > 0, let data = chunk.floatChannelData else { break }
            for channel in 0..<channelCount {
                planar[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel],
                                                                       count: got))
            }
            remaining -= got
        }
        if remaining > 0 {
            for channel in 0..<channelCount {
                planar[channel].append(contentsOf: repeatElement(0, count: remaining))
            }
        }
        return planar
    }
}
