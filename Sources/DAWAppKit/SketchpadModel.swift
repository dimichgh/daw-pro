import Foundation
import DAWCore
import AIServices

/// Headless state machine for the AI Sketchpad panel (M6 iii-b): the
/// prompt/lyrics composer, the candidate list, and the poll → import lifecycle.
/// No SwiftUI, no AVFoundation — the view is thin over this and the tests drive
/// it against a fake `SongGenerating` (the `TakeLaneModel` / `MixerModel`
/// precedent: all logic here, capturable and testable without a window).
///
/// The model owns every state TRANSITION; the VIEW owns the poll TIMER — it
/// calls `refresh()` on a cadence while any candidate is still generating and
/// stops when nothing is active. Audio preview (an `AVAudioPlayer`) also stays
/// in the view layer, off the engine — this type never touches audio I/O.
///
/// Violet is the whole point: every candidate is AI-generated, so the view
/// paints the list in `DAWTheme.ai` throughout ("violet always means
/// AI-generated", docs/DESIGN-LANGUAGE.md).
@MainActor
@Observable
public final class SketchpadModel {
    // MARK: - Composer inputs

    /// Style/caption prompt (ACE-Step's `prompt`) — genre, mood, instrumentation.
    public var prompt: String = ""

    /// Section-labeled lyrics in the bracketed-structure format the section
    /// helper builds (`[verse]`/`[chorus]`/…). Blank requests an instrumental.
    public var lyrics: String = ""

    /// Caret index the section helper inserts a tag at (character offset into
    /// `lyrics`). The view keeps this at the editor's caret (or the end when it
    /// can't read one); clamped on every insert so a stale index is harmless.
    public var lyricsCursor: Int = 0

    /// Target length in seconds, always kept inside `durationRange`.
    public private(set) var durationSeconds: Double = 30

    /// The generation candidates, oldest first. Each is one submitted job with
    /// its own lifecycle (queued → running → succeeded → imported, or failed).
    public private(set) var candidates: [SketchpadCandidate] = []

    /// Latest sidecar health (drives the banner + `canGenerate`). Set by the
    /// view from `ai.sidecarStatus`; nil until the first probe lands.
    public private(set) var sidecarStatus: SidecarStatus?

    // MARK: - Configuration

    /// Accepted duration range for the stepper — ACE-Step's stable window.
    public static let durationRange: ClosedRange<Double> = 15...240
    /// Stepper increment.
    public static let durationStep: Double = 5

    private let generator: any SongGenerating
    /// Import wiring injected at init: hands a finished job's `jobID` to the
    /// store and returns the created track's id + name (for the imported badge).
    /// Kept as a closure so DAWAppKit never imports the store's engine bridge.
    /// `@MainActor` because the app's implementation reaches the `@MainActor`
    /// `ProjectStore`; the model is `@MainActor` too, so calling it is direct.
    private let importer: @MainActor (String) async throws -> SketchpadImportResult

    /// Re-entrancy guard so an overlapping timer tick can't double-poll.
    private var isRefreshing = false

    public init(
        generator: any SongGenerating,
        importer: @escaping @MainActor (String) async throws -> SketchpadImportResult
    ) {
        self.generator = generator
        self.importer = importer
    }

    // MARK: - Sidecar surface

    /// Feeds a fresh sidecar status in (from the view's `ai.sidecarStatus` poll).
    public func updateSidecar(_ status: SidecarStatus) {
        sidecarStatus = status
    }

    /// True when a generation can be submitted: the sidecar is healthy AND the
    /// prompt isn't blank. The banner explains any other case.
    public var canGenerate: Bool {
        sidecarStatus?.state == .healthy && !trimmedPrompt.isEmpty
    }

    /// An actionable banner when generation isn't currently possible, or nil
    /// when the sidecar is healthy (the panel is ready). `canStartSidecar` is
    /// set only for `installedNotRunning`, where a Start button is the fix.
    public var banner: SketchpadBanner? {
        guard let status = sidecarStatus else {
            return SketchpadBanner(message: "Checking the AI generator…",
                                   canStartSidecar: false, tone: .neutral)
        }
        switch status.state {
        case .healthy:
            return nil
        case .installedNotRunning:
            // status.message is wire-speak ("call ai.sidecarStart") — right for
            // agents reading command errors, wrong register for this user-facing
            // banner. The Start button below IS the fix, so the copy points there.
            return SketchpadBanner(
                message: "The AI generator is installed but not running — press Start to launch it.",
                canStartSidecar: true, tone: .warning)
        case .starting:
            // M10-b: a first-class in-progress banner — `.progress` tone (the
            // view shows a spinner for it) and `canStartSidecar: false` always
            // (never offer a Start button for a boot that's already running).
            // The message composes status.message's base sentence with the
            // phase hint + elapsed seconds when the sidecar has reported them
            // (`SidecarManager` only populates those once a boot is actually
            // tracked — see its own doc comment), so the panel reads "Starting
            // — loading models… (42s)" instead of a generic, non-advancing
            // line the whole time the beta bug used to show.
            return SketchpadBanner(message: Self.startingBannerMessage(status),
                                   canStartSidecar: false, tone: .progress)
        case .notInstalled:
            return SketchpadBanner(message: status.message, canStartSidecar: false, tone: .warning)
        case .error:
            return SketchpadBanner(message: status.message, canStartSidecar: false, tone: .error)
        }
    }

    /// Composes the `.starting` banner line from `status.message` (the base
    /// sentence, and the fallback when `startingForSeconds` isn't populated —
    /// e.g. a dry-run status) plus the optional phase + elapsed seconds.
    static func startingBannerMessage(_ status: SidecarStatus) -> String {
        guard let elapsed = status.startingForSeconds else {
            return status.message.isEmpty ? "The AI generator is starting…" : status.message
        }
        if let phase = status.phase {
            return "Starting — \(phase) (\(elapsed)s)"
        }
        return "Starting… (\(elapsed)s)"
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Duration stepper

    /// Sets the duration, clamped into `durationRange`.
    public func setDurationSeconds(_ seconds: Double) {
        durationSeconds = seconds.clamped(to: Self.durationRange)
    }

    /// Nudges the duration by `delta` (typically ±`durationStep`), clamped.
    public func nudgeDuration(by delta: Double) {
        setDurationSeconds(durationSeconds + delta)
    }

    // MARK: - Lyrics section helper

    /// Inserts a bracketed structure tag (`[verse]` etc.) at `lyricsCursor`,
    /// on its own line (a leading newline is added when the caret isn't already
    /// at the start of a line), and advances the cursor past the insertion.
    public func insertSection(_ section: SketchpadSection) {
        let clamped = min(max(0, lyricsCursor), lyrics.count)
        let index = lyrics.index(lyrics.startIndex, offsetBy: clamped)
        var insertion = section.tag + "\n"
        if clamped > 0 {
            let preceding = lyrics[lyrics.index(before: index)]
            if preceding != "\n" { insertion = "\n" + insertion }
        }
        lyrics.insert(contentsOf: insertion, at: index)
        lyricsCursor = clamped + insertion.count
    }

    // MARK: - Generate

    /// Submits a generation job with the current composer inputs and appends a
    /// candidate for it. A submit failure appends a `.failed` candidate (so the
    /// error is visible in the list) rather than throwing to the view.
    public func generate() async {
        let snapshotPrompt = trimmedPrompt
        var request = SongGenerationRequest(prompt: snapshotPrompt)
        let trimmedLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        request.lyrics = trimmedLyrics.isEmpty ? nil : lyrics
        request.durationSeconds = durationSeconds

        do {
            let submission = try await generator.generateSong(request)
            candidates.append(SketchpadCandidate(
                jobID: submission.jobID,
                promptSnippet: Self.snippet(snapshotPrompt),
                state: Self.state(forSubmission: submission)
            ))
        } catch {
            candidates.append(SketchpadCandidate(
                jobID: "",
                promptSnippet: Self.snippet(snapshotPrompt),
                state: .failed(message: Self.message(from: error))
            ))
        }
    }

    // MARK: - Refresh (poll)

    /// Polls every still-active candidate (queued/running) once and applies the
    /// resulting transition. The view drives this on a timer; the model just
    /// transitions. A poll that THROWS is treated as transient — the candidate
    /// is marked `isStale` and KEPT (polling continues next tick), never killed
    /// (docs: "a transient poll error must not kill the candidate"). A returned
    /// status whose state is `.failed` is the one path to `.failed`.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Snapshot the active jobs first; look each candidate back up by id
        // after the await (the list can change mid-poll — an import, another
        // generate) so we never write through a stale index.
        let active = candidates.filter { $0.state.isActive && !$0.jobID.isEmpty }
        for candidate in active {
            let id = candidate.id
            do {
                let status = try await generator.generationStatus(jobID: candidate.jobID)
                guard let idx = candidates.firstIndex(where: { $0.id == id }) else { continue }
                // A late poll for a candidate already imported/failed is ignored.
                guard candidates[idx].state.isActive else { continue }
                candidates[idx].isStale = false
                candidates[idx].state = Self.state(forStatus: status)
            } catch {
                guard let idx = candidates.firstIndex(where: { $0.id == id }) else { continue }
                guard candidates[idx].state.isActive else { continue }
                candidates[idx].isStale = true    // transient — keep the candidate, keep polling
            }
        }
    }

    /// True while any candidate still needs polling — the view uses this to run
    /// or pause its timer.
    public var hasActiveCandidates: Bool {
        candidates.contains { $0.state.isActive }
    }

    // MARK: - Import

    /// Imports a succeeded candidate into the project via the injected importer
    /// and flips the row to `.imported` with the created track's name. A no-op
    /// for a candidate that isn't currently `.succeeded`. An import failure marks
    /// the candidate `isStale` (the audio is still there — the user can retry).
    public func importCandidate(_ candidateID: UUID) async {
        guard let idx = candidates.firstIndex(where: { $0.id == candidateID }),
              case .succeeded = candidates[idx].state else { return }
        let jobID = candidates[idx].jobID
        do {
            let result = try await importer(jobID)
            guard let i = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
            candidates[i].isStale = false
            candidates[i].state = .imported(trackID: result.trackID, trackName: result.trackName)
        } catch {
            guard let i = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
            candidates[i].isStale = true
        }
    }

    /// Removes a candidate row (a dismissed failure or an unwanted take). The
    /// job stays on the sidecar; this only drops the local row.
    public func dismissCandidate(_ candidateID: UUID) {
        candidates.removeAll { $0.id == candidateID }
    }

    // MARK: - Demo seeding (capture support)

    /// Replaces the candidate list wholesale. Used only by the debug capture
    /// seed command to stage representative rows (generating/succeeded/failed/
    /// imported) when that state can't be reached over the wire alone — the
    /// established capture-seeding approach (`ui.showTakes` precedent).
    public func setCandidatesForCapture(_ seeded: [SketchpadCandidate]) {
        candidates = seeded
    }

    // MARK: - Mapping helpers

    /// First few words of a prompt, for the candidate row's snippet label.
    static func snippet(_ prompt: String, wordLimit: Int = 6) -> String {
        let words = prompt
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .prefix(wordLimit)
            .joined(separator: " ")
        return words.isEmpty ? "Untitled" : words
    }

    static func state(forSubmission submission: SongGenerationSubmission) -> SketchpadCandidate.State {
        switch submission.state {
        case .queued: return .queued
        case .running: return .running(progress: nil, statusText: nil)
        case .succeeded: return .succeeded(audioPath: "", bpm: nil, durationSeconds: nil)
        case .failed: return .failed(message: "Generation failed")
        }
    }

    static func state(forStatus status: SongGenerationStatus) -> SketchpadCandidate.State {
        switch status.state {
        case .queued:
            return .queued
        case .running:
            return .running(progress: status.progress, statusText: status.statusText ?? status.stage)
        case .succeeded:
            // Succeeded but the audio isn't fetched yet reads as still working,
            // so import never sees an empty path.
            guard let path = status.audioPath, !path.isEmpty else {
                return .running(progress: 1, statusText: status.statusText ?? "finishing")
            }
            return .succeeded(audioPath: path, bpm: status.bpm, durationSeconds: status.durationSeconds)
        case .failed:
            return .failed(message: status.statusText ?? "Generation failed")
        }
    }

    static func message(from error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }
}

/// One bracketed-structure section tag the lyrics helper inserts.
public enum SketchpadSection: String, CaseIterable, Sendable {
    case verse, chorus, bridge, outro
    /// The bracketed tag as ACE-Step expects it, e.g. `"[chorus]"`.
    public var tag: String { "[\(rawValue)]" }
    /// Capitalized button label.
    public var label: String { rawValue.capitalized }
}

/// The actionable banner shown when generation isn't currently possible.
public struct SketchpadBanner: Equatable, Sendable {
    /// `.progress` (M10-b) is the first-class in-progress tone for `.starting`
    /// — the view renders it with a cyan spinner instead of the static
    /// info/warning/error glyphs, per DESIGN-LANGUAGE (cyan = active accent;
    /// this banner is infrastructure status, not an AI-identity surface, so
    /// it stays off violet).
    public enum Tone: Sendable { case neutral, warning, error, progress }
    public var message: String
    /// True only for `installedNotRunning` — the view shows a Start button.
    /// Always false for `.starting` (a boot already in flight is never
    /// re-offered a Start button).
    public var canStartSidecar: Bool
    public var tone: Tone

    public init(message: String, canStartSidecar: Bool, tone: Tone) {
        self.message = message
        self.canStartSidecar = canStartSidecar
        self.tone = tone
    }

    /// Spinner-worthiness for the view — true only for the `.progress` tone
    /// (currently just `.starting`). A named convenience so the view doesn't
    /// re-derive "is this the starting banner" from `tone` itself.
    public var isInProgress: Bool { tone == .progress }
}

/// The result an importer hands back so the row's imported badge can name the
/// created track.
public struct SketchpadImportResult: Equatable, Sendable {
    public var trackID: UUID
    public var trackName: String
    public init(trackID: UUID, trackName: String) {
        self.trackID = trackID
        self.trackName = trackName
    }
}

/// A single generation candidate: one submitted job and its lifecycle. Local
/// `id` is stable across polls so SwiftUI rows keep identity while the `state`
/// transitions underneath.
public struct SketchpadCandidate: Identifiable, Equatable, Sendable {
    /// Per-candidate lifecycle. `queued`/`running` are the polling states;
    /// `succeeded`/`failed`/`imported` are terminal (no more polls).
    public enum State: Equatable, Sendable {
        case queued
        case running(progress: Double?, statusText: String?)
        case succeeded(audioPath: String, bpm: Double?, durationSeconds: Double?)
        case failed(message: String)
        case imported(trackID: UUID, trackName: String)

        /// Whether the poll loop should keep polling this candidate.
        public var isActive: Bool {
            switch self {
            case .queued, .running: return true
            case .succeeded, .failed, .imported: return false
            }
        }
    }

    public let id: UUID
    /// The provider's job id (empty only for a submit-failure row).
    public var jobID: String
    /// Short prompt label shown on the row.
    public var promptSnippet: String
    public var state: State
    /// A transient poll/import error happened — the row dims but survives and
    /// keeps polling; cleared on the next good poll.
    public var isStale: Bool

    public init(
        id: UUID = UUID(),
        jobID: String,
        promptSnippet: String,
        state: State,
        isStale: Bool = false
    ) {
        self.id = id
        self.jobID = jobID
        self.promptSnippet = promptSnippet
        self.state = state
        self.isStale = isStale
    }
}
