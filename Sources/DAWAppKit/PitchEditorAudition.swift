import Foundation
import DAWCore

// m23-ap I1 UI HOOKS — HEAR THE NOTE IN THE PITCH EDITOR: ON PRESS, ON EVERY
// DRAG STEP, AND AFTER THE RELEASE'S ONE COMMIT.
//
// The user's words (a non-musician; words describe, they do not diagnose):
// "when we move vocal segment, it should play it like we do notes", and "is it
// possible to just play segment and update segment when editing the note".
//
// Design `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §4 (the
// doors, the switch, the transport rule), extended by I1-F1: a drag step is
// HEARD through a span render of the draft (`previewClipNotePitchDraft`), with
// the exact pitch and level the commit would store, so the drag is no longer
// silent and needs no "let go to hear it" caveat.
//
// ═══ WHO DOES WHAT ═══
//
//   • `PitchEditorModel` decides WHEN — the press's first tick, each change of
//     the drag's offset, Escape, the pane going away — and emits a
//     `PitchEditorAuditionRequest` through its `onAudition` seam. It never
//     reads the switch and never reaches the store.
//   • `PitchEditorAuditionRouter` (this file, app-held) turns a request into
//     ONE store door call, with the switch as the door's `enabled:` (design §4:
//     "the UI doors check it at the CALL SITE; the wire ignores it"), and after
//     a commit LANDED maps it to the release door — or to nothing, for a split.
//     It owns the pane's audition LINE: the honest waiting words.
//   • The store's `ClipNoteAuditionController` (DAWCore) owns the policy:
//     latest wins, one span render in flight plus the newest free step, the 8 s
//     wait expiry, the transport refusal.
//
// Headless, so every rule here is tested in `PitchEditorModelTests` against a
// fake door (DAWApp has no test target).

/// What the pitch editor asks to hear. Emitted only by `PitchEditorModel`.
public enum PitchEditorAuditionRequest: Sendable, Equatable {
    /// A press on a note (the first tick of a `.noteDrag` press): hear it as
    /// it sounds NOW (`ProjectStore.auditionClipNotes`).
    ///
    /// `seedIfAbsent` is the editor's own note table, so a note of a take that
    /// was never edited can be heard; the store's table wins whenever there is
    /// one.
    case press(segmentIDs: [UUID], seedIfAbsent: PitchEditSet)
    /// The drag's OFFSET changed: hear every moving note as it WOULD sound,
    /// nothing written (`ProjectStore.previewClipNotePitchDraft`). Absolute
    /// cents, the pressed note first; `snapped` is false while ⌥ frees the
    /// drag from the scale.
    case dragStep(offsets: [NotePitchOffset], snapped: Bool, seedIfAbsent: PitchEditSet)
    /// Stop a sounding audition (`ProjectStore.stopClipNoteAudition`).
    case stop

    /// Stable machine tag for the `debug.pitchEditor` echo.
    public var key: String {
        switch self {
        case .press: return "press"
        case .dragStep: return "dragStep"
        case .stop: return "stop"
        }
    }
}

/// The store's audition doors, as the router calls them. `ProjectStore` IS
/// this shape (the conformance below adds nothing); the protocol exists so
/// the router's cadence and switch rules are testable against a fake that
/// counts every call.
@MainActor
public protocol PitchEditorAuditionDoors: AnyObject {
    func auditionClipNotes(clipId: UUID, segmentIds: [UUID], contextSeconds: Double,
                           enabled: Bool, seedIfAbsent: PitchEditSet?) throws -> ClipNoteAuditionResult
    func previewClipNotePitchDraft(clipId: UUID, offsets: [NotePitchOffset], snapped: Bool,
                                   enabled: Bool, seedIfAbsent: PitchEditSet?,
                                   contextSeconds: Double) throws -> ClipNoteAuditionResult
    func auditionClipNotesAfterEdit(_ edit: ClipNoteEdit, clipId: UUID, segmentIds: [UUID],
                                    enabled: Bool, contextSeconds: Double?) throws -> ClipNoteAuditionResult
    func stopClipNoteAudition()
    var clipNoteAuditionWaitSerial: UInt64 { get }
    func clipNoteAuditionWaitState(serial: UInt64) -> ClipNoteAuditionWaitState
}

extension ProjectStore: PitchEditorAuditionDoors {}

/// What a landed commit plays: the edit kind (its own context — 0.3 s for a
/// clear or a restore, 60 ms otherwise) and the notes it changed.
public struct PitchEditorReleaseAudition: Sendable, Equatable {
    public let edit: ClipNoteEdit
    public let segmentIDs: [UUID]

    public init(edit: ClipNoteEdit, segmentIDs: [UUID]) {
        self.edit = edit
        self.segmentIDs = segmentIDs
    }
}

/// THE WORDS the pane's state line says about hearing a note — ONE home,
/// asserted by value (docs/DESIGN-LANGUAGE.md, the note editor's state line:
/// drawn prose in every state, never a spinner alone, never silence; amber
/// `PanelRefusalLine` only where the thing did not happen).
public enum PitchEditorAuditionWords {
    /// A release is waiting for its clip's render (an engine without span
    /// renders — on the live engine I1-F1 plays the span at once). PROGRESS:
    /// a mini spinner beside these words, never amber.
    public static let preparing = "Preparing your note…"
    /// The wait ran out (`ClipNoteAuditionPolicy.renderWaitSeconds`) and
    /// nothing will play. A SHORTFALL, and it names the fix: a click on the
    /// note is a press, which plays it as it sounds now.
    public static let dropped = "Couldn't play that note in time. Click it to hear it."
    /// The track is muted, or a solo elsewhere leaves it out.
    public static let muted = "Can't play that note: its track is muted, or another track is soloed."
    /// The audio engine is not running and would not start.
    public static let engineStopped = "Can't play that note: the audio engine isn't running."
    /// A press found the clip's render still in flight on an engine that
    /// cannot render a span on its own.
    public static let notReady = "That note isn't ready to play yet. Click it again in a moment."

    public static let preparingCaption = PitchEditorLineCaption(kind: .progress, text: preparing)
    public static let droppedCaption = PitchEditorLineCaption(kind: .shortfall, text: dropped)

    /// The line a door's answer puts on screen, or nil when there is nothing
    /// to say. Exhaustive over the store's reasons, so a new reason is a
    /// compile error here rather than a silent door.
    ///
    /// ⚠️ nil is deliberate for four of them: `transportRunning` (the brief's
    /// rule — the transport plays the edit in context, show nothing extra),
    /// `auditionOff` (the header's switch already says it), `previewQueued`
    /// (a free drag step that WILL play) and `unchanged` (a split, which the
    /// router never asks about). `noAudio` (a mid-rebuild gap) and
    /// `unsupported` (a headless engine) are not reachable in the live pane.
    public static func caption(for reason: ClipNoteAuditionResult.Reason?) -> PitchEditorLineCaption? {
        guard let reason else { return nil }
        switch reason {
        case .waitingForRender: return preparingCaption
        case .trackMuted: return PitchEditorLineCaption(kind: .shortfall, text: muted)
        case .engineStopped: return PitchEditorLineCaption(kind: .shortfall, text: engineStopped)
        case .stillRendering: return PitchEditorLineCaption(kind: .shortfall, text: notReady)
        case .transportRunning, .auditionOff, .previewQueued, .unchanged, .noAudio, .unsupported:
            return nil
        }
    }
}

/// The pitch editor header's audition switch — the faces it draws, tested by
/// value. It writes `PanelLayoutStore.auditionEnabled`: ONE switch for both
/// note editors (the piano roll's drag and gutter sounds read it too) and for
/// musical typing's preview, and its help says so.
///
/// ⚠️ The roll has NO visible toggle to copy (the switch was reachable only
/// through `debug.panelLayout`), so this is the switch's first face; its glyph
/// is the speaker, cyan when on — `playback`, the "you are hearing this" ink.
public enum PitchEditorAuditionToggle {
    public static let title = "HEAR"

    public static func symbol(on: Bool) -> String {
        on ? "speaker.wave.2.fill" : "speaker.slash.fill"
    }

    public static let oneSwitchSentence =
        "One switch for both note editors (the piano roll and this one) and for musical typing."

    public static func help(on: Bool) -> String {
        (on ? "Notes play as you click and drag them. Click to turn note sounds off. "
            : "Note sounds are off. Click to hear notes as you click and drag them. ")
            + oneSwitchSentence
    }

    public static func accessibilityLabel(on: Bool) -> String {
        on ? "Note sounds on" : "Note sounds off"
    }
}

/// Turns the pitch editor's audition requests into store door calls, and owns
/// the pane's audition line (m23-ap I1 UI hooks). App-held (`AppModel`), so
/// the line and the counts outlive the pane's `.id(clip.id)` rebuilds.
@MainActor
@Observable
public final class PitchEditorAuditionRouter {

    /// Requests routed, by kind. Diagnostics for the `debug.pitchEditor` echo:
    /// the staging look reads these beside the store's own
    /// `ClipNoteAuditionCounts`, two instruments that must agree.
    public struct Counts: Sendable, Equatable {
        public internal(set) var presses = 0
        public internal(set) var dragSteps = 0
        /// Release auditions asked for: commits that change the sound.
        public internal(set) var releases = 0
        /// Commits that play nothing (a split).
        public internal(set) var silentCommits = 0
        public internal(set) var stops = 0
        /// Door calls that threw (a caller mistake the store refused).
        public internal(set) var refusals = 0

        public init() {}
    }

    /// What the pane's state line says about hearing the note, or nil. The
    /// ONLY observable field: the pane draws it.
    public private(set) var line: PitchEditorLineCaption?

    @ObservationIgnored public private(set) var counts = Counts()
    /// The last door answer, verbatim, or nil after a refusal.
    @ObservationIgnored public private(set) var lastResult: ClipNoteAuditionResult?
    /// The last refusal's text, or nil.
    @ObservationIgnored public private(set) var lastError: String?
    /// The key of the last request routed ("press", "dragStep", "stop",
    /// "release", "silent"), or "".
    @ObservationIgnored public private(set) var lastRequestKey = ""
    /// The store's wait serial this router is watching, or nil when no
    /// release is waiting for its render.
    @ObservationIgnored public private(set) var waitingSerial: UInt64?

    @ObservationIgnored private let doors: any PitchEditorAuditionDoors
    @ObservationIgnored private let pollInterval: Duration?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// `pollInterval` nil turns the automatic wait poll off, so a test drives
    /// `pollWait()` by hand and nothing runs behind it.
    public init(doors: any PitchEditorAuditionDoors,
                pollInterval: Duration? = .milliseconds(200)) {
        self.doors = doors
        self.pollInterval = pollInterval
    }

    /// One request from the pane's model, for `clipID`. `enabled` is the
    /// switch (`PanelLayoutStore.auditionEnabled`), passed to the door — the
    /// store refuses with `audition-off` and nothing reaches the engine.
    public func route(_ request: PitchEditorAuditionRequest, clipID: UUID, enabled: Bool) {
        lastRequestKey = request.key
        switch request {
        case .press(let ids, let seed):
            counts.presses += 1
            answer {
                try doors.auditionClipNotes(clipId: clipID, segmentIds: ids,
                                            contextSeconds: ClipNoteAuditionPolicy.contextSeconds,
                                            enabled: enabled, seedIfAbsent: seed)
            }
        case .dragStep(let offsets, let snapped, let seed):
            counts.dragSteps += 1
            answer {
                try doors.previewClipNotePitchDraft(clipId: clipID, offsets: offsets, snapped: snapped,
                                                    enabled: enabled, seedIfAbsent: seed,
                                                    contextSeconds: ClipNoteAuditionPolicy.contextSeconds)
            }
        case .stop:
            counts.stops += 1
            doors.stopClipNoteAudition()
            endWait()
            line = nil
        }
    }

    /// A commit from the pane LANDED (the app's funnel read it back). If it
    /// changed the sound, its notes play once (`auditionClipNotesAfterEdit`,
    /// with `enabled` = the switch); a split plays nothing and asks nothing.
    /// Call it after the write, never before: the store resolves the clip it
    /// has now.
    public func commitLanded(_ commit: PitchEditorCommit, clipID: UUID, enabled: Bool) {
        guard let release = Self.releaseAudition(for: commit.kind) else {
            lastRequestKey = "silent"
            counts.silentCommits += 1
            return
        }
        lastRequestKey = "release"
        counts.releases += 1
        answer {
            try doors.auditionClipNotesAfterEdit(release.edit, clipId: clipID,
                                                 segmentIds: release.segmentIDs,
                                                 enabled: enabled, contextSeconds: nil)
        }
    }

    /// What a commit plays after it lands, or nil for one that changes nothing
    /// audible. ⭐ EXHAUSTIVE, NO `default`: a new commit kind (a level edit
    /// from the pane, say — U-D's level has no pane door today) is a compile
    /// error here until someone decides what it plays.
    public nonisolated static func releaseAudition(for kind: PitchEditorCommit.Kind) -> PitchEditorReleaseAudition? {
        switch kind {
        case .notePitch(let id, _):
            return PitchEditorReleaseAudition(edit: .pitch, segmentIDs: [id])
        case .notePitches(let offsets, _):
            return PitchEditorReleaseAudition(edit: .pitch, segmentIDs: offsets.map(\.segmentId))
        case .notesCleared(let ids, _):
            // A clear AND a restore: `ClipNoteEdit.clear` covers both, heard
            // with its own 0.3 s of context (the gap only reads against the
            // singing around it).
            return PitchEditorReleaseAudition(edit: .clear, segmentIDs: ids)
        case .splitNote:
            return nil
        }
    }

    /// One look at the release wait this router is watching: still waiting
    /// (true), or over — played or replaced (the line goes), or EXPIRED (the
    /// line says so, and stays until the next request). Reading NOTICES an
    /// expiry (`ClipNoteAuditionController.waitState`), so a render that never
    /// lands cannot leave "Preparing your note…" up forever.
    @discardableResult
    public func pollWait() -> Bool {
        guard let serial = waitingSerial else { return false }
        switch doors.clipNoteAuditionWaitState(serial: serial) {
        case .waiting:
            return true
        case .expired:
            endWait()
            line = PitchEditorAuditionWords.droppedCaption
            return false
        case .played, .cancelled:
            endWait()
            line = nil
            return false
        }
    }

    // MARK: Private

    private func answer(_ ask: () throws -> ClipNoteAuditionResult) {
        do {
            let result = try ask()
            lastResult = result
            lastError = nil
            if result.reason == .waitingForRender {
                waitingSerial = doors.clipNoteAuditionWaitSerial
                line = PitchEditorAuditionWords.preparingCaption
                startPolling()
            } else {
                endWait()
                line = PitchEditorAuditionWords.caption(for: result.reason)
            }
        } catch {
            counts.refusals += 1
            lastResult = nil
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            endWait()
            line = nil
        }
    }

    private func endWait() {
        waitingSerial = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        guard let pollInterval, pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                if !self.pollWait() { return }
            }
        }
    }
}
