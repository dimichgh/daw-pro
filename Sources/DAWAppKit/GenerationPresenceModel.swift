import Foundation
import AIServices

/// Where a generation job entered the app (m17-h) — the tag the unified
/// progress card shows so a user can tell "the Sketchpad is working" from "an
/// AI agent kicked this off over the control wire".
public enum GenerationJobOrigin: String, Sendable, CaseIterable, Codable {
    /// Submitted by the in-app Sketchpad panel (or the ClipFix panel's own
    /// composer — anything a user pressed a violet button for).
    case sketchpad
    /// Submitted over the control WebSocket (`ai.generateSong`,
    /// `ai.extractStems`, `ai.repaintAudio`, …) — which is also every MCP
    /// tool's path (`generate_song` rides the same wire).
    case wire
    /// Submitted/polled through the store's `GenerationImporting` seam — the
    /// stems/full-song/clip-fix import pipeline (`importGeneration`,
    /// `fixClipRegion`, `importClipFix`).
    case `import`

    /// Beginner-readable chip text (SF Mono uppercase in the card). "AGENT"
    /// for the wire — a newcomer knows what an AI agent is, not a WebSocket.
    public var displayLabel: String {
        switch self {
        case .sketchpad: return "SKETCHPAD"
        case .wire: return "AGENT"
        case .import: return "IMPORT"
        }
    }
}

/// One generation job's lifecycle phase as the unified card presents it
/// (m17-h): the sidecar boot stages come BEFORE the upstream job states so an
/// auto-started generate reads honestly from "starting the AI generator" all
/// the way to done/failed — never a silent gap.
public enum GenerationPresencePhase: Equatable, Sendable {
    /// The sidecar isn't up yet — an auto-start is in flight. `detail` is the
    /// boot phase hint VERBATIM from `SidecarStatus.phase` ("preparing
    /// environment…" / "starting server…" / "loading models…"), nil when the
    /// log tail matched no known marker.
    case startingSidecar(detail: String?)
    /// The sidecar finished booting but this origin's submission hasn't been
    /// re-issued yet (the wire path: the agent got "it's starting — retry",
    /// the boot ran, and the card waits briefly for the resubmission before
    /// clearing itself — nothing is actually running upstream).
    case sidecarReady
    case queued
    case running(progress: Double?, stageText: String?)
    case succeeded
    case failed(reason: String)

    /// Whether this entry still needs polling / can still transition.
    public var isActive: Bool {
        switch self {
        case .startingSidecar, .sidecarReady, .queued, .running: return true
        case .succeeded, .failed: return false
        }
    }

    /// Wire/seam raw tag (`debug.generationCard` echoes it; tests read it).
    public var rawTag: String {
        switch self {
        case .startingSidecar: return "startingSidecar"
        case .sidecarReady: return "sidecarReady"
        case .queued: return "queued"
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }
}

/// One row of the unified generation-progress card: a job (or a pre-submit
/// sidecar boot standing in for one) tagged with its origin. `id` is local and
/// stable across polls (the `SketchpadCandidate` identity rule); `jobID` is
/// the upstream task id, nil while the sidecar is still booting pre-submit.
public struct GenerationPresenceJob: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var jobID: String?
    public var origin: GenerationJobOrigin
    /// Short human label — the prompt's first words, or a kind label
    /// ("Stems: vocals, drums").
    public var label: String
    public var phase: GenerationPresencePhase
    /// When this presence began (submission, or the auto-start that preceded
    /// it) — the card's elapsed readout counts from here.
    public var startedAt: Date
    /// Set when the phase goes terminal — freezes the elapsed readout and
    /// drives the succeeded linger.
    public var finishedAt: Date?
    /// A transient poll blip (sidecar reachable per its own status, one poll
    /// failed) — the row dims but survives, the Sketchpad stale rule.
    public var isStale: Bool
    /// When a pre-submit entry observed the sidecar healthy with no
    /// resubmission yet — drives the `sidecarReady` linger clear.
    public var readySince: Date?

    public init(
        id: UUID = UUID(),
        jobID: String? = nil,
        origin: GenerationJobOrigin,
        label: String,
        phase: GenerationPresencePhase,
        startedAt: Date,
        finishedAt: Date? = nil,
        isStale: Bool = false,
        readySince: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.origin = origin
        self.label = label
        self.phase = phase
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isStale = isStale
        self.readySince = readySince
    }
}

/// Headless registry + state machine behind the unified generation-progress
/// card (m17-h): EVERY generation job — Sketchpad, wire `ai.generateSong` /
/// MCP `generate_song`, stems / repaint / import paths — lands here regardless
/// of origin, so the app always has ONE in-app progress presence (the user
/// complaint: "ACE generation feels disconnected… user does not know if it
/// failed or still doing the work").
///
/// The model owns every state TRANSITION; the card VIEW owns the 1 s poll
/// cadence (a `.task` loop while the card is visible — the `SketchpadModel`
/// polling split). Jobs are fed in by `GenerationObservingGenerator` (the
/// decorator each origin's `SongGenerating` is wrapped in) and advanced by
/// `poll()` against the injected status/sidecar closures.
///
/// Honesty rules (the roadmap's law):
/// - a FAILED job shows the reason VERBATIM from the sidecar/client error;
/// - sidecar death mid-job flips the row to failed within one poll AND fires
///   `notify` (the app posts an engine notice) — never silent;
/// - a transient blip (sidecar still healthy/starting per its own status)
///   only dims the row (`isStale`) and keeps polling;
/// - succeeded rows clear themselves after a short linger; failed rows stay
///   until dismissed.
///
/// No cancel affordance: ACE-Step's upstream job-queue API has no abort route
/// (verified against `scripts/ace-step/runtime/src/acestep/api/http/` — no
/// cancel/abort endpoint exists), so offering one would be a lie.
@MainActor
@Observable
public final class GenerationPresenceModel {
    public private(set) var jobs: [GenerationPresenceJob] = []

    /// How long a succeeded row lingers (reads "DONE") before clearing itself.
    public static let succeededLingerSeconds: TimeInterval = 6
    /// How long a pre-submit entry lingers in `sidecarReady` (boot finished,
    /// no resubmission arrived) before clearing — long enough for a polling
    /// agent's retry to consume it.
    public static let sidecarReadyLingerSeconds: TimeInterval = 20

    private let status: @Sendable (String) async throws -> SongGenerationStatus
    private let sidecarStatus: @Sendable () async -> SidecarStatus
    /// Fired ONCE per sidecar-death failure with a beginner-readable message —
    /// the app posts it as an engine notice (the "failed card + notice, never
    /// silent" rule). Called on the main actor.
    private let notify: ((String) -> Void)?
    /// Injected clock so linger/elapsed logic is deterministic in tests.
    private let now: @Sendable () -> Date

    /// Re-entrancy guard so an overlapping poll tick can't double-poll.
    private var isPolling = false

    public init(
        status: @escaping @Sendable (String) async throws -> SongGenerationStatus,
        sidecarStatus: @escaping @Sendable () async -> SidecarStatus,
        notify: ((String) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.status = status
        self.sidecarStatus = sidecarStatus
        self.notify = notify
        self.now = now
    }

    /// The card shows while anything is present (active, lingering done, or a
    /// sticky failure).
    public var isVisible: Bool { !jobs.isEmpty }

    /// True while any entry can still transition — the view's poll gate.
    public var needsPolling: Bool { jobs.contains { $0.phase.isActive } }

    // MARK: - Feeds (from the observing decorators)

    /// Registers a pre-submit presence for an auto-started sidecar boot: the
    /// submit hit an unreachable sidecar, a start was kicked, and the card
    /// must show the boot ("starting sidecar" → "loading models…") before any
    /// queued/running phase exists upstream. Returns the entry's local id.
    @discardableResult
    public func beginStartingSidecar(origin: GenerationJobOrigin, label: String) -> UUID {
        let job = GenerationPresenceJob(
            origin: origin, label: label,
            phase: .startingSidecar(detail: nil), startedAt: now())
        jobs.append(job)
        return job.id
    }

    /// Registers a fresh submission. When a pre-submit boot entry of the same
    /// origin is still open it BECOMES this job (keeping its `startedAt`, so
    /// elapsed spans the whole boot) instead of appending a second row.
    public func registerSubmission(
        jobID: String,
        origin: GenerationJobOrigin,
        label: String,
        state: SongGenerationState = .queued
    ) {
        let phase: GenerationPresencePhase = (state == .running)
            ? .running(progress: nil, stageText: nil) : .queued
        if let idx = pendingIndex(origin: origin) {
            jobs[idx].jobID = jobID
            jobs[idx].label = label
            jobs[idx].phase = phase
            jobs[idx].readySince = nil
            return
        }
        jobs.append(GenerationPresenceJob(
            jobID: jobID, origin: origin, label: label, phase: phase, startedAt: now()))
    }

    /// Registers a submission that FAILED (the sidecar refused it, or the
    /// auto-start never reached healthy). Consumes an open pre-submit entry of
    /// the same origin, like `registerSubmission`. `reason` is verbatim.
    public func registerSubmissionFailure(
        origin: GenerationJobOrigin, label: String, reason: String
    ) {
        if let idx = pendingIndex(origin: origin) {
            jobs[idx].label = label
            fail(index: idx, reason: reason)
            return
        }
        var job = GenerationPresenceJob(
            origin: origin, label: label, phase: .failed(reason: reason), startedAt: now())
        job.finishedAt = now()
        jobs.append(job)
    }

    /// Applies an observed status (a decorator saw a poll go through, or this
    /// model's own `poll()` fetched one). An unknown-but-ACTIVE jobID is
    /// REGISTERED — an agent polling a job this session never saw submitted
    /// (e.g. submitted before an app relaunch) still earns a presence. Unknown
    /// terminal statuses pass through silently (nothing is in flight — e.g. an
    /// import re-polling a long-finished job must not resurrect a DONE card).
    public func apply(
        _ generationStatus: SongGenerationStatus,
        origin: GenerationJobOrigin = .wire,
        label: String? = nil
    ) {
        let phase = Self.phase(forStatus: generationStatus)
        if let idx = jobs.firstIndex(where: { $0.jobID == generationStatus.jobID }) {
            guard jobs[idx].phase.isActive else { return }   // late poll after terminal — ignore
            jobs[idx].isStale = false
            jobs[idx].phase = phase
            if !phase.isActive, jobs[idx].finishedAt == nil { jobs[idx].finishedAt = now() }
            return
        }
        guard phase.isActive else { return }
        jobs.append(GenerationPresenceJob(
            jobID: generationStatus.jobID, origin: origin,
            label: label ?? generationStatus.prompt.map { Self.promptSnippet($0) } ?? "AI generation",
            phase: phase, startedAt: now()))
    }

    /// Applies an observed TERMINAL failure for a job (a decorator's poll
    /// threw `jobFailed`/`jobNotFound`). Unknown jobIDs register a failed row
    /// — a failure is exactly what must never be silent.
    public func applyFailure(
        jobID: String, reason: String,
        origin: GenerationJobOrigin = .wire, label: String? = nil
    ) {
        if let idx = jobs.firstIndex(where: { $0.jobID == jobID }) {
            guard jobs[idx].phase.isActive else { return }
            fail(index: idx, reason: reason)
            return
        }
        var job = GenerationPresenceJob(
            jobID: jobID, origin: origin, label: label ?? "AI generation",
            phase: .failed(reason: reason), startedAt: now())
        job.finishedAt = now()
        jobs.append(job)
    }

    /// Removes a terminal row (the failed card's ✕, or a lingering DONE).
    /// Active rows are not dismissable — there is no upstream abort, so hiding
    /// a running job would just make the app dishonest again.
    public func dismiss(_ id: UUID) {
        jobs.removeAll { $0.id == id && !$0.phase.isActive }
    }

    // MARK: - Poll (driven by the card view's 1 s task)

    /// One poll pass: advances pre-submit boot entries from the sidecar's own
    /// status, polls every active submitted job, overlays the boot phase on
    /// queued jobs while the sidecar is still loading, and clears expired
    /// lingers.
    public func poll() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        await pollPendingBootEntries()
        await pollActiveJobs()
        await overlayBootPhaseOnQueuedJobs()
        clearExpired()
    }

    /// A pre-submit boot entry: no upstream job yet AND a boot-narration phase.
    /// (Phase-restricted so a CAPTURE-SEEDED row — which may carry an active
    /// queued/running phase with no jobID on purpose, to keep the real poll off
    /// it — is never mistaken for a boot entry and overwritten.)
    private static func isBootEntry(_ job: GenerationPresenceJob) -> Bool {
        guard job.jobID == nil else { return false }
        switch job.phase {
        case .startingSidecar, .sidecarReady: return true
        default: return false
        }
    }

    private func pollPendingBootEntries() async {
        guard jobs.contains(where: { Self.isBootEntry($0) }) else { return }
        let sidecar = await sidecarStatus()
        for idx in jobs.indices where Self.isBootEntry(jobs[idx]) {
            switch sidecar.state {
            case .starting, .installedNotRunning:
                // installedNotRunning can flash between the start being kicked
                // and the pidfile appearing — still an in-flight boot here.
                jobs[idx].phase = .startingSidecar(detail: sidecar.phase)
                jobs[idx].readySince = nil
            case .healthy:
                jobs[idx].phase = .sidecarReady
                if jobs[idx].readySince == nil { jobs[idx].readySince = now() }
            case .error, .notInstalled:
                // The boot cannot succeed — surface the manager's own
                // actionable message verbatim.
                fail(index: idx, reason: sidecar.message)
            }
        }
    }

    private func pollActiveJobs() async {
        let active = jobs.filter { $0.jobID != nil && $0.phase.isActive }
        for job in active {
            guard let jobID = job.jobID else { continue }
            do {
                let polled = try await status(jobID)
                guard let idx = jobs.firstIndex(where: { $0.id == job.id }),
                      jobs[idx].phase.isActive else { continue }
                jobs[idx].isStale = false
                jobs[idx].phase = Self.phase(forStatus: polled)
                if !jobs[idx].phase.isActive, jobs[idx].finishedAt == nil {
                    jobs[idx].finishedAt = now()
                }
            } catch {
                await handlePollError(error, jobLocalID: job.id)
            }
        }
    }

    /// The poll-error split (the honesty core): a TERMINAL error fails the row
    /// with the verbatim reason; anything else asks the sidecar's own status —
    /// still healthy/starting means a transient blip (dim + keep polling), but
    /// a sidecar that is genuinely gone mid-job means the job died with it:
    /// failed row (reason verbatim) + the notice. Never silent.
    private func handlePollError(_ error: Error, jobLocalID: UUID) async {
        if let terminal = Self.terminalFailureReason(error) {
            guard let idx = jobs.firstIndex(where: { $0.id == jobLocalID }),
                  jobs[idx].phase.isActive else { return }
            fail(index: idx, reason: terminal)
            return
        }
        let sidecar = await sidecarStatus()
        guard let idx = jobs.firstIndex(where: { $0.id == jobLocalID }),
              jobs[idx].phase.isActive else { return }
        switch sidecar.state {
        case .healthy, .starting:
            jobs[idx].isStale = true      // transient — keep the row, keep polling
        case .installedNotRunning, .notInstalled, .error:
            let label = jobs[idx].label
            fail(index: idx, reason: Self.verbatimReason(error))
            notify?("AI generation '\(label)' was interrupted — the AI generator stopped mid-job.")
        }
    }

    /// The measured ACE-Step boot order (m17-h live gate): `/health` flips
    /// healthy SECONDS into a cold boot, while the 8–20 GB model load runs for
    /// minutes afterward — so an auto-started submit lands "queued" almost
    /// immediately and then sits there (or its polls fail) while the REAL work
    /// is the model load. A bare QUEUED (or a dimmed RECONNECTING) there is
    /// dishonest; the sidecar's own log phase names the truth. This pass
    /// overlays `.startingSidecar(detail:)` ("LOADING THE MODEL…") onto
    /// SUBMITTED-but-queued rows while the manager reports `.starting`, and
    /// flips them back to `.queued` once it stops.
    private func overlayBootPhaseOnQueuedJobs() async {
        let overlayable = jobs.contains { job in
            guard job.jobID != nil else { return false }
            switch job.phase {
            case .queued, .startingSidecar: return true
            default: return false
            }
        }
        guard overlayable else { return }
        let sidecar = await sidecarStatus()
        for idx in jobs.indices where jobs[idx].jobID != nil {
            switch (jobs[idx].phase, sidecar.state) {
            case (.queued, .starting), (.startingSidecar, .starting):
                // Overlay (or refresh) the boot phase hint.
                jobs[idx].phase = .startingSidecar(detail: sidecar.phase)
                jobs[idx].isStale = false   // the boot narration IS the honest story
            case (.startingSidecar, _):
                // The boot is over; the job is back to plain upstream-queued
                // until the next poll reports otherwise.
                jobs[idx].phase = .queued
            default:
                break
            }
        }
    }

    private func fail(index: Int, reason: String) {
        jobs[index].isStale = false
        jobs[index].phase = .failed(reason: reason)
        if jobs[index].finishedAt == nil { jobs[index].finishedAt = now() }
    }

    /// Clears rows whose linger expired: succeeded rows after
    /// `succeededLingerSeconds` ("completion clears honestly" — visible long
    /// enough to read, never parked forever), and `sidecarReady` pre-submit
    /// entries after `sidecarReadyLingerSeconds` (the boot they narrated is
    /// over; nothing is running upstream). Failed rows never auto-clear.
    private func clearExpired() {
        let currentTime = now()
        jobs.removeAll { job in
            if case .succeeded = job.phase, let finished = job.finishedAt {
                return currentTime.timeIntervalSince(finished) >= Self.succeededLingerSeconds
            }
            if case .sidecarReady = job.phase, let ready = job.readySince {
                return currentTime.timeIntervalSince(ready) >= Self.sidecarReadyLingerSeconds
            }
            return false
        }
    }

    // MARK: - Capture seeding (`debug.generationCard`)

    /// Appends a staged row for captures/E2E (the `setCandidatesForCapture`
    /// precedent) — the seam can stage any card state without a live sidecar.
    public func seedJobForCapture(_ job: GenerationPresenceJob) {
        jobs.append(job)
    }

    /// Drops every row (capture teardown).
    public func clearForCapture() {
        jobs = []
    }

    // MARK: - Derivations (the card's readouts)

    /// The row's stage line, uppercase (the card's SF Mono status register).
    public nonisolated static func stageLabel(for phase: GenerationPresencePhase) -> String {
        switch phase {
        case .startingSidecar(let detail):
            guard let detail, !detail.isEmpty else { return "STARTING THE AI GENERATOR…" }
            // The one boot phase a user actually waits on gets its own honest
            // name; other phase hints surface verbatim (uppercased).
            if detail.localizedCaseInsensitiveContains("loading model") {
                return "LOADING THE MODEL…"
            }
            return detail.uppercased()
        case .sidecarReady:
            return "GENERATOR READY — WAITING FOR THE JOB…"
        case .queued:
            return "QUEUED"
        case .running(_, let stageText):
            guard let stageText, !stageText.isEmpty else { return "GENERATING" }
            return stageText.uppercased()
        case .succeeded:
            return "DONE"
        case .failed:
            return "FAILED"
        }
    }

    /// "42%" while the provider reports progress; nil otherwise (the card
    /// shows an em dash — coarse but honest).
    public nonisolated static func percentText(for phase: GenerationPresencePhase) -> String? {
        if case .running(let progress?, _) = phase {
            return "\(Int((progress * 100).rounded()))%"
        }
        return nil
    }

    /// The row's progress fraction for the bar (nil = indeterminate).
    public nonisolated static func progressFraction(for phase: GenerationPresencePhase) -> Double? {
        switch phase {
        case .running(let progress, _): return progress
        case .succeeded: return 1
        default: return nil
        }
    }

    /// Elapsed readout for a row, frozen at `finishedAt` once terminal.
    public func elapsedText(for job: GenerationPresenceJob) -> String {
        Self.elapsedText(from: job.startedAt, to: job.finishedAt ?? now())
    }

    /// "m:ss" — SF Mono in the card (every numeric readout is mono).
    public nonisolated static func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Newest-first rows for the card (the Sketchpad candidates order).
    public var rows: [GenerationPresenceJob] { jobs.reversed() }

    // MARK: - Error classification (shared with SketchpadModel)

    /// A TERMINAL generation failure's verbatim reason, or nil for a
    /// transient/ambiguous error. `jobFailed` carries the worker's own message
    /// verbatim; `jobNotFound` means the job is gone upstream (expired, or the
    /// sidecar restarted and lost it) — also terminal. Everything else
    /// (unreachable, HTTP failures, malformed responses) is not proof the job
    /// died, so it stays transient here; `poll()` escalates unreachable to
    /// failed only when the sidecar itself is confirmed gone.
    public nonisolated static func terminalFailureReason(_ error: Error) -> String? {
        switch error {
        case ACEStepError.jobFailed(_, let message):
            return message
        case ACEStepError.jobNotFound:
            return (error as? LocalizedError)?.errorDescription ?? "the generation job was not found"
        default:
            return nil
        }
    }

    /// True for the client's "could not reach the sidecar at all" case — the
    /// trigger for auto-start and for the death check.
    public nonisolated static func isUnreachable(_ error: Error) -> Bool {
        if case ACEStepError.sidecarUnreachable = error { return true }
        return false
    }

    /// The error's message verbatim (LocalizedError description preferred).
    public nonisolated static func verbatimReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// First few words of a prompt — the row label (the SketchpadModel rule).
    public nonisolated static func promptSnippet(_ prompt: String, wordLimit: Int = 6) -> String {
        let words = prompt
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .prefix(wordLimit)
            .joined(separator: " ")
        return words.isEmpty ? "AI generation" : words
    }

    /// The display stage line for a running job. Measured live (m17-h): the
    /// sidecar's `stage` carries clean pipeline text ("Generating music (batch
    /// size: 2)...") while `statusText`/`progress_text` is the worker's raw
    /// last LOG LINE ("MLX DiT diffusion:  25%|##5 | 2/8 [...]") — prefer the
    /// clean stage when it is a real description, falling back to the log line
    /// (and finally the bare stage) so something honest always shows.
    public nonisolated static func preferredStageText(stage: String?, statusText: String?) -> String? {
        if let stage, !stage.isEmpty, stage != "queued", stage != "running" {
            return stage
        }
        return statusText ?? stage
    }

    // MARK: - Status → phase mapping

    nonisolated static func phase(forStatus generationStatus: SongGenerationStatus) -> GenerationPresencePhase {
        switch generationStatus.state {
        case .queued:
            return .queued
        case .running:
            return .running(
                progress: generationStatus.progress,
                stageText: Self.preferredStageText(
                    stage: generationStatus.stage, statusText: generationStatus.statusText))
        case .succeeded:
            // Succeeded upstream but the audio isn't fetched/present yet reads
            // as still finishing (the SketchpadModel rule) — a stems composite
            // reports its results via `stems` instead of `audioPath`.
            let hasAudio = (generationStatus.audioPath?.isEmpty == false)
                || (generationStatus.stems?.isEmpty == false)
            guard hasAudio else {
                return .running(progress: 1, stageText: generationStatus.statusText ?? "finishing")
            }
            return .succeeded
        case .failed:
            return .failed(reason: generationStatus.statusText ?? "Generation failed")
        }
    }

    private func pendingIndex(origin: GenerationJobOrigin) -> Int? {
        jobs.lastIndex { Self.isBootEntry($0) && $0.origin == origin }
    }
}

// MARK: - Observing decorator

/// `SongGenerating` decorator that reports every submission/poll into the
/// shared `GenerationPresenceModel`, tagged with ONE origin (m17-h). The app
/// wraps the ONE real `ACEStepClient` three times — sketchpad / wire / import
/// — all sharing the same underlying client (job state + audio caching stay
/// unified), so every origin's generation lands on the same card.
///
/// It also owns AUTO-START ("sidecar lifecycle invisible-but-honest"): a
/// submit that finds the sidecar unreachable kicks `ensureSidecar` and
/// registers a pre-submit boot presence.
/// - `awaitsBoot == true` (the Sketchpad): the submit WAITS for the boot and
///   then submits for real — one card entry rides starting → loading model →
///   queued → running with no user action.
/// - `awaitsBoot == false` (the wire/import): the boot is kicked
///   fire-and-forget and the original error is rethrown — the router's
///   `translateSongGeneratorError` re-probes the manager and now reports
///   "starting — …" to the agent (whose retry consumes the boot entry). A
///   wire call must not block for a multi-minute model load.
public final class GenerationObservingGenerator: SongGenerating, Sendable {
    /// Boots the sidecar and waits until it is healthy (or gives up). Returns
    /// true when healthy. The app implements this over `SidecarManager`;
    /// tests inject a fake.
    public typealias EnsureSidecar = @Sendable () async -> Bool

    private let wrapped: any SongGenerating
    private let origin: GenerationJobOrigin
    private let presence: GenerationPresenceModel
    private let ensureSidecar: EnsureSidecar?
    private let awaitsBoot: Bool

    public init(
        wrapping wrapped: any SongGenerating,
        origin: GenerationJobOrigin,
        presence: GenerationPresenceModel,
        ensureSidecar: EnsureSidecar? = nil,
        awaitsBoot: Bool = false
    ) {
        self.wrapped = wrapped
        self.origin = origin
        self.presence = presence
        self.ensureSidecar = ensureSidecar
        self.awaitsBoot = awaitsBoot
    }

    // MARK: SongGenerating

    public func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
        let label = GenerationPresenceModel.promptSnippet(request.prompt)
        return try await submitObserved(label: label) {
            try await self.wrapped.generateSong(request)
        }
    }

    public func generationStatus(jobID: String) async throws -> SongGenerationStatus {
        do {
            let polled = try await wrapped.generationStatus(jobID: jobID)
            await presence.apply(polled, origin: origin)
            return polled
        } catch {
            if let reason = GenerationPresenceModel.terminalFailureReason(error) {
                await presence.applyFailure(jobID: jobID, reason: reason, origin: origin)
            }
            throw error
        }
    }

    public func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
        let label = "Stems: " + request.trackNames.joined(separator: ", ")
        return try await submitStemObserved(label: label) {
            try await self.wrapped.extractStems(request)
        }
    }

    public func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
        let label = "Layers: " + request.tracks.map(\.trackName).joined(separator: ", ")
        return try await submitStemObserved(label: label) {
            try await self.wrapped.generateLegoTracks(request)
        }
    }

    public func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission {
        let label = request.prompt.map { "Fix: " + GenerationPresenceModel.promptSnippet($0) }
            ?? "Region repaint"
        return try await submitObserved(label: label) {
            try await self.wrapped.repaintAudio(request)
        }
    }

    // MARK: - Shared submit path

    private func submitObserved(
        label: String,
        submit: @Sendable () async throws -> SongGenerationSubmission
    ) async throws -> SongGenerationSubmission {
        do {
            let submission = try await submit()
            await presence.registerSubmission(
                jobID: submission.jobID, origin: origin, label: label, state: submission.state)
            return submission
        } catch {
            // Either throws (presence already updated) or returns meaning
            // "the awaited auto-start reached healthy — retry the submit".
            try await handleSubmitError(error, label: label)
            do {
                let submission = try await submit()
                await presence.registerSubmission(
                    jobID: submission.jobID, origin: origin, label: label, state: submission.state)
                return submission
            } catch {
                await presence.registerSubmissionFailure(
                    origin: origin, label: label,
                    reason: GenerationPresenceModel.verbatimReason(error))
                throw error
            }
        }
    }

    private func submitStemObserved(
        label: String,
        submit: @Sendable () async throws -> StemGenerationSubmission
    ) async throws -> StemGenerationSubmission {
        do {
            let submission = try await submit()
            await presence.registerSubmission(
                jobID: submission.jobID, origin: origin, label: label, state: submission.state)
            return submission
        } catch {
            try await handleSubmitError(error, label: label)
            do {
                let submission = try await submit()
                await presence.registerSubmission(
                    jobID: submission.jobID, origin: origin, label: label, state: submission.state)
                return submission
            } catch {
                await presence.registerSubmissionFailure(
                    origin: origin, label: label,
                    reason: GenerationPresenceModel.verbatimReason(error))
                throw error
            }
        }
    }

    /// Central submit-error policy. RETURNS (instead of throwing) exactly when
    /// the caller should retry the submit — the awaited auto-start reached a
    /// healthy sidecar. Every other outcome registers the appropriate presence
    /// and rethrows.
    private func handleSubmitError(_ error: Error, label: String) async throws {
        guard GenerationPresenceModel.isUnreachable(error), let ensureSidecar else {
            // A real refusal (or no auto-start wired): a failed card, verbatim.
            await presence.registerSubmissionFailure(
                origin: origin, label: label,
                reason: GenerationPresenceModel.verbatimReason(error))
            throw error
        }
        await presence.beginStartingSidecar(origin: origin, label: label)
        if awaitsBoot {
            if await ensureSidecar() {
                return   // caller retries the submit; success consumes the boot entry
            }
            await presence.registerSubmissionFailure(
                origin: origin, label: label,
                reason: GenerationPresenceModel.verbatimReason(error))
            throw error
        }
        // Wire/import: kick the boot and hand the actionable error back — the
        // agent's retry (post-boot) consumes the pre-submit entry.
        Task { _ = await ensureSidecar() }
        throw error
    }
}
