import Foundation
import DAWCore
import AIServices

/// Headless state machine for the clip vocal-fix panel (M6 v-b-2): the region +
/// prompt/lyrics composer and the submit → poll → import lifecycle of every
/// in-flight AI fix. No SwiftUI, no AVFoundation — the view is thin over this and
/// the tests drive it against injected fakes (the `SketchpadModel` precedent:
/// all logic here, capturable and testable without a window).
///
/// The model owns every state TRANSITION; the VIEW owns the poll TIMER — it calls
/// `refresh()` on a 1 s cadence while any job is still running and stops when
/// nothing is active (the Sketchpad rule). The store owns bounce/submit/import,
/// so the model reaches it only through injected closures (`submitter`/`importer`)
/// and polls the ordinary generation-status surface through `statusProvider` —
/// this keeps DAWAppKit off the store's engine bridge and lets tests script every
/// hop with fakes.
///
/// Violet is the whole point: a fix is AI-generated content, so the view paints
/// the panel and every job card in `DAWTheme.ai` ("violet always means
/// AI-generated", docs/DESIGN-LANGUAGE.md).
@MainActor
@Observable
public final class ClipFixModel {
    // MARK: - Composer inputs (bound by the panel, seeded from the selected clip)

    /// The track + clip the panel currently targets (seeded by `prepare`). Both
    /// nil until the panel opens on an audio clip; `canSubmit` gates on them.
    public private(set) var targetTrackID: UUID?
    public private(set) var targetClipID: UUID?
    /// The target clip's display name, shown in the composer header.
    public private(set) var targetClipName: String = ""

    /// Fix region in absolute timeline beats (the wire contract, D2). Pre-filled
    /// from the selected clip's span by `prepare`, then editable in the panel.
    public var regionStartBeat: Double = 0
    public var regionEndBeat: Double = 0

    /// Style/caption prompt handed to the repaint (optional).
    public var prompt: String = ""
    /// Section-labeled lyrics for the repaint (optional; blank = no lyric guide).
    public var lyrics: String = ""
    /// Regeneration intensity (default balanced, the settled middle ground).
    public var mode: ClipFixMode = .balanced

    /// The in-flight (and finished) fix jobs, oldest first. Each mirrors a store
    /// `PendingClipFix` and extends it with the UI lifecycle. Keyed by jobID
    /// (`ClipFixCard.id`); an array so SwiftUI rows keep identity while state
    /// transitions underneath (the `SketchpadModel.candidates` shape).
    public private(set) var cards: [ClipFixCard] = []

    /// Set when a `submit` throws before a card ever exists (bad region, sidecar
    /// unreachable) — the panel shows it inline by the GO button. Cleared on the
    /// next submit. A submit failure never manufactures a phantom card.
    public private(set) var submitError: String?

    /// True while a submit is in flight — the busy-guard so a double-tapped GO
    /// button can't fire two bounces for one region.
    public private(set) var isSubmitting = false

    // MARK: - Injected dependencies

    /// Bounce + submit, wired in the app to `ProjectStore.fixClipRegion`. `@MainActor`
    /// because the store is; a closure so DAWAppKit never imports the engine bridge.
    private let submitter: @MainActor (ClipFixSubmitRequest) async throws -> ClipFixSubmission
    /// One poll of the ordinary generation-status surface (the app wires it to the
    /// shared `SongGenerating.generationStatus`). `@Sendable` because the poll
    /// closure crosses isolation on each tick (the flagged v-b-2 poll-timer trap).
    private let statusProvider: @Sendable (String) async throws -> SongGenerationStatus
    /// Land the finished fix, wired to `ProjectStore.importClipFix`. Returns the
    /// created/updated lane's name for the imported badge.
    private let importer: @MainActor (String) async throws -> ClipFixImportResult

    /// Re-entrancy guard so an overlapping timer tick can't double-poll.
    private var isRefreshing = false

    public init(
        submitter: @escaping @MainActor (ClipFixSubmitRequest) async throws -> ClipFixSubmission,
        statusProvider: @escaping @Sendable (String) async throws -> SongGenerationStatus,
        importer: @escaping @MainActor (String) async throws -> ClipFixImportResult
    ) {
        self.submitter = submitter
        self.statusProvider = statusProvider
        self.importer = importer
    }

    // MARK: - Composer

    /// Points the composer at a freshly-selected audio clip. Re-seeds the region
    /// from the clip's span only when the TARGET clip changes (so an in-progress
    /// edit of the region survives a redraw of the same selection); always
    /// updates the target ids and clears a stale submit error.
    public func prepare(trackID: UUID, clipID: UUID, name: String,
                        startBeat: Double, endBeat: Double) {
        if targetClipID != clipID {
            regionStartBeat = startBeat
            regionEndBeat = endBeat
            prompt = ""
            lyrics = ""
        }
        targetTrackID = trackID
        targetClipID = clipID
        targetClipName = name
        submitError = nil
    }

    /// Clears the composer target (the selection is no longer a fixable audio
    /// clip). The jobs strip keeps rendering — only the composer collapses to its
    /// "select a clip" hint.
    public func clearTarget() {
        targetTrackID = nil
        targetClipID = nil
        targetClipName = ""
    }

    /// True when the composer has a target and a well-formed region — the GO
    /// button's armed gate.
    public var canSubmit: Bool {
        guard let _ = targetTrackID, let _ = targetClipID, !isSubmitting else { return false }
        return regionEndBeat > regionStartBeat
    }

    // MARK: - Submit

    /// Bounces + submits an AI repaint of `[startBeat, endBeat)` (absolute
    /// timeline beats) and appends a `.pending` card for the returned job. A
    /// submit failure surfaces in `submitError` (no card) — the region is invalid
    /// or the sidecar is unreachable, and there is no job to track. Busy-guarded:
    /// a second call while one is in flight is ignored.
    public func submit(
        trackId: UUID, clipId: UUID,
        startBeat: Double, endBeat: Double,
        prompt: String? = nil, lyrics: String? = nil,
        mode: ClipFixMode = .balanced, strength: Double? = nil,
        seed: Int? = nil, contextSeconds: Double = 10.0
    ) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        submitError = nil

        let request = ClipFixSubmitRequest(
            trackId: trackId, clipId: clipId,
            startBeat: startBeat, endBeat: endBeat,
            prompt: Self.nilIfBlank(prompt), lyrics: Self.nilIfBlank(lyrics),
            mode: mode, strength: strength, seed: seed, contextSeconds: contextSeconds)
        do {
            let submission = try await submitter(request)
            cards.append(ClipFixCard(
                jobID: submission.jobID,
                trackID: trackId,
                regionStartBeat: submission.regionStartBeat,
                regionEndBeat: submission.regionEndBeat,
                promptSnippet: Self.snippet(request.prompt ?? request.lyrics ?? ""),
                state: .pending))
        } catch {
            submitError = Self.message(from: error)
        }
    }

    /// Submits the current composer inputs (the panel's GO button). A thin bridge
    /// onto `submit(...)` reading the bound region/prompt/lyrics/mode; a no-op
    /// when the composer isn't armed.
    public func submitCurrent() async {
        guard let trackId = targetTrackID, let clipId = targetClipID, canSubmit else { return }
        await submit(trackId: trackId, clipId: clipId,
                     startBeat: regionStartBeat, endBeat: regionEndBeat,
                     prompt: prompt, lyrics: lyrics, mode: mode)
    }

    // MARK: - Refresh (poll)

    /// Polls every still-active job (pending/running) once and applies the
    /// transition. The view drives this on a timer; the model just transitions. A
    /// poll that THROWS is treated as transient — the card is marked `isStale` and
    /// KEPT (polling continues next tick), never killed (the Sketchpad
    /// stale-tolerance rule). Only a returned `.failed` status fails a card.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Snapshot the active jobs first; look each card back up by id after the
        // await (the list can change mid-poll — an import, another submit) so we
        // never write through a stale index.
        let active = cards.filter { $0.state.isActive && !$0.jobID.isEmpty }
        for card in active {
            let jobID = card.jobID
            do {
                let status = try await statusProvider(jobID)
                guard let idx = cards.firstIndex(where: { $0.jobID == jobID }) else { continue }
                guard cards[idx].state.isActive else { continue }   // a late poll for a settled card is ignored
                cards[idx].isStale = false
                cards[idx].state = Self.state(forStatus: status)
            } catch {
                guard let idx = cards.firstIndex(where: { $0.jobID == jobID }) else { continue }
                guard cards[idx].state.isActive else { continue }
                cards[idx].isStale = true   // transient — keep the card, keep polling
            }
        }
    }

    /// True while any job still needs polling — the view uses this to run or pause
    /// its 1 s timer.
    public var hasActiveJobs: Bool {
        cards.contains { $0.state.isActive }
    }

    // MARK: - Import

    /// Lands a succeeded fix through the injected importer and flips the card to
    /// `.imported` with the created lane's name. A no-op for a card that isn't
    /// `.succeededAwaitingImport`. Error mapping:
    ///   - `clipFixStale` → a terminal `.stale(message)` card (amber; the target
    ///     drifted — the message says what changed and to re-submit).
    ///   - `clipFixJobNotFound` → a terminal `.failed(message)` card (red; the job
    ///     is gone — a re-submit is the only path).
    ///   - anything else (a fetch blip, audio not on disk yet) → `isStale`
    ///     transient, card KEPT importable for a retry (the Sketchpad rule).
    public func importFix(jobID: String) async {
        guard let idx = cards.firstIndex(where: { $0.jobID == jobID }),
              case .succeededAwaitingImport = cards[idx].state else { return }
        do {
            let result = try await importer(jobID)
            guard let i = cards.firstIndex(where: { $0.jobID == jobID }) else { return }
            cards[i].isStale = false
            cards[i].state = .imported(laneName: result.laneName)
        } catch let error as ProjectError {
            guard let i = cards.firstIndex(where: { $0.jobID == jobID }) else { return }
            switch error {
            case .clipFixStale(let message):
                cards[i].isStale = false
                cards[i].state = .stale(message: message)
            case .clipFixJobNotFound:
                cards[i].isStale = false
                cards[i].state = .failed(message: error.errorDescription ?? Self.message(from: error))
            default:
                cards[i].isStale = true   // transient — the audio is still there, keep it importable
            }
        } catch {
            guard let i = cards.firstIndex(where: { $0.jobID == jobID }) else { return }
            cards[i].isStale = true
        }
    }

    /// Removes a terminal card row (a dismissed failure/stale/imported). The store
    /// keeps its own pending record until a project switch; this only drops the
    /// local card.
    public func dismiss(jobID: String) {
        cards.removeAll { $0.jobID == jobID }
    }

    // MARK: - Capture seeding (debug support)

    /// Replaces the card list wholesale. Used only by the `debug.clipFixSeed`
    /// capture command to stage representative rows (running/succeeded/imported/
    /// failed) when that state can't be reached over the wire alone — the
    /// `SketchpadModel.setCandidatesForCapture` precedent.
    public func setCardsForCapture(_ seeded: [ClipFixCard]) {
        cards = seeded
    }

    /// Seeds the composer for a capture (target + region + prompt), so a shot can
    /// show the FIX panel filled on a selected clip without a live selection.
    public func setComposerForCapture(trackID: UUID, clipID: UUID, name: String,
                                      startBeat: Double, endBeat: Double,
                                      prompt: String, lyrics: String, mode: ClipFixMode) {
        targetTrackID = trackID
        targetClipID = clipID
        targetClipName = name
        regionStartBeat = startBeat
        regionEndBeat = endBeat
        self.prompt = prompt
        self.lyrics = lyrics
        self.mode = mode
        submitError = nil
    }

    // MARK: - Mapping helpers

    static func state(forStatus status: SongGenerationStatus) -> ClipFixCard.State {
        switch status.state {
        case .queued:
            return .pending
        case .running:
            return .running(progress: status.progress, statusText: status.statusText ?? status.stage)
        case .succeeded:
            // Succeeded but the audio isn't fetched yet reads as still working, so
            // import never sees an empty path (the Sketchpad guard).
            guard let path = status.audioPath, !path.isEmpty else {
                return .running(progress: 1, statusText: status.statusText ?? "finishing")
            }
            return .succeededAwaitingImport
        case .failed:
            return .failed(message: status.statusText ?? "Repaint failed")
        }
    }

    /// First few words of a prompt/lyric, for the card's descriptor label.
    static func snippet(_ text: String, wordLimit: Int = 5) -> String {
        let words = text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .prefix(wordLimit)
            .joined(separator: " ")
        return words
    }

    static func message(from error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    private static func nilIfBlank(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}

/// The bundle of arguments `ClipFixModel.submit` hands to its injected submitter
/// (which the app wires to `ProjectStore.fixClipRegion`). A value type so a test's
/// fake can record the EXACT submit it received.
public struct ClipFixSubmitRequest: Sendable, Equatable {
    public var trackId: UUID
    public var clipId: UUID
    public var startBeat: Double
    public var endBeat: Double
    public var prompt: String?
    public var lyrics: String?
    public var mode: ClipFixMode
    public var strength: Double?
    public var seed: Int?
    public var contextSeconds: Double

    public init(
        trackId: UUID, clipId: UUID,
        startBeat: Double, endBeat: Double,
        prompt: String? = nil, lyrics: String? = nil,
        mode: ClipFixMode = .balanced, strength: Double? = nil,
        seed: Int? = nil, contextSeconds: Double = 10.0
    ) {
        self.trackId = trackId
        self.clipId = clipId
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.prompt = prompt
        self.lyrics = lyrics
        self.mode = mode
        self.strength = strength
        self.seed = seed
        self.contextSeconds = contextSeconds
    }
}

/// One AI fix job and its UI lifecycle: a card mirroring a store `PendingClipFix`
/// (jobID + track + region) and extending it with the panel state. `id == jobID`
/// so SwiftUI rows keep identity while `state` transitions underneath.
public struct ClipFixCard: Identifiable, Equatable, Sendable {
    /// Per-job lifecycle. `pending`/`running` are the polling states;
    /// `succeededAwaitingImport` waits for the user's IMPORT; `imported`/`failed`/
    /// `stale` are terminal.
    public enum State: Equatable, Sendable {
        case pending
        case running(progress: Double?, statusText: String?)
        case succeededAwaitingImport
        case imported(laneName: String)
        case failed(message: String)
        case stale(message: String)

        /// Whether the poll loop should keep polling this job.
        public var isActive: Bool {
            switch self {
            case .pending, .running: return true
            case .succeededAwaitingImport, .imported, .failed, .stale: return false
            }
        }
    }

    public var id: String { jobID }
    public var jobID: String
    public var trackID: UUID
    public var regionStartBeat: Double
    public var regionEndBeat: Double
    /// Short prompt/lyric descriptor shown on the card (may be empty).
    public var promptSnippet: String
    public var state: State
    /// A transient poll/import blip happened — the card dims and shows a small
    /// "reconnecting" tag but survives and keeps polling; cleared on the next good
    /// poll (distinct from the terminal `.stale` STATE, which is a drifted target).
    public var isStale: Bool

    public init(
        jobID: String,
        trackID: UUID,
        regionStartBeat: Double,
        regionEndBeat: Double,
        promptSnippet: String = "",
        state: State,
        isStale: Bool = false
    ) {
        self.jobID = jobID
        self.trackID = trackID
        self.regionStartBeat = regionStartBeat
        self.regionEndBeat = regionEndBeat
        self.promptSnippet = promptSnippet
        self.state = state
        self.isStale = isStale
    }
}
