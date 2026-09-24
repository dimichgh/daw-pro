import DAWCore
import Foundation
import Observation

// m23-ap C-F3 (design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md`,
// finding F22) — THE PRESET DOORS ASK BEFORE THEY ERASE HAND EDITS.
//
// Both preset doors (the clip menu's Tune Vocal ▸ <preset> and the note
// editor's preset chips) reach one funnel, `AppModel.tuneVocalFromContextMenu`.
// The funnel asks this gate first. The gate answers from ONE signal,
// `PitchEditSet.hasHandEditsSinceAutoCorrect`, which DAWCore owns and tests.
// No second estimate of "was this edited" is made here.
//
// The gate is a headless model rather than a stored property on `AppModel`
// because `DAWApp` has no test target. Here, "Cancel applies nothing",
// "Replace applies the request that was held, once" and "a clip with no hand
// edits never asks" are SPY tests (`PitchTuneDoorSiteTests`), not greps.

/// A preset click that would replace hand edits, held while the card asks.
public struct PitchPresetReplaceRequest: Equatable, Sendable {
    public let clipID: UUID
    /// The clip's name AT THE CLICK. It is only for the card's sentence, and
    /// nothing is looked up by it.
    public let clipName: String
    public let preset: PitchCorrectionPreset

    public init(clipID: UUID, clipName: String, preset: PitchCorrectionPreset) {
        self.clipID = clipID
        self.clipName = clipName
        self.preset = preset
    }
}

/// The one question every preset door asks before calling
/// `ProjectStore.autoCorrectClipPitch`, and the request it holds while the
/// person answers.
@MainActor
@Observable
public final class PitchPresetReplaceGate {

    public enum Decision: Equatable, Sendable {
        /// Nothing irreplaceable would be lost. Call the store now, with no
        /// dialog. This is the preset-comparison path: a clip holding only a
        /// preset's own output switches presets freely.
        case applyNow
        /// The clip carries hand edits. The request is now `pending`, and the
        /// store must NOT be called until the person says so.
        case askFirst
    }

    /// The request the confirm card is showing, or nil when no card is up.
    public private(set) var pending: PitchPresetReplaceRequest?

    public init() {}

    /// Decide whether a preset click may apply now.
    ///
    /// `current` is the clip's stored set AT THE CLICK. A clip with no set
    /// (never tuned, or tuning removed) has nothing to lose.
    public func request(_ preset: PitchCorrectionPreset, clipID: UUID, clipName: String,
                        current: PitchEditSet?) -> Decision {
        guard current?.hasHandEditsSinceAutoCorrect == true else { return .applyNow }
        pending = PitchPresetReplaceRequest(clipID: clipID, clipName: clipName, preset: preset)
        return .askFirst
    }

    /// "Replace my edits": hands back the request the card was showing,
    /// EXACTLY ONCE. A second press, or a press after Cancel, returns nil, so
    /// it can never apply a preset nobody was asked about.
    public func confirm() -> PitchPresetReplaceRequest? {
        guard let held = pending else { return nil }
        pending = nil
        return held
    }

    /// "Cancel": drops the request. Nothing is applied.
    public func cancel() {
        pending = nil
    }
}

/// The card's words: one home, read by the view and pinned by tests.
///
/// Written for someone who is not a musician. It names the preset they
/// clicked, says what it does, names what they would lose in the note editor's
/// own verbs (its tools are labelled Move and Split), and says Undo brings it
/// back. `PitchCorrectionWriterTests` proves that last claim at the store
/// rather than taking it on trust.
///
/// ⚠️ **IT NAMES ONLY THE HAND EDITS THAT EXIST TODAY: moves and splits.**
/// The design's sentence also names timing and drawn shapes, and wobble
/// editing is on its way. None of those can be made by hand yet, and a warning
/// that lists losses the person cannot have made teaches them to stop reading
/// warnings. When one ships, `handEdits` below grows its words. The SIGNAL
/// needs no change, because any write through any path already reads as a
/// hand edit. `PitchTuneDoorSiteTests.replaceCopyNamesEveryEditorTool` trips
/// when the editor gains a tool, so this sentence cannot silently fall behind.
public struct PitchPresetReplaceCopy: Equatable, Sendable {
    public let title: String
    public let body: String
    public let undoNote: String
    public let confirmLabel: String
    public let cancelLabel: String

    /// What the person would lose, in the editor's own verbs.
    public static let handEdits = "the notes you moved or split by hand"

    public init(_ request: PitchPresetReplaceRequest) {
        let clip = request.clipName.isEmpty ? "this clip" : "“\(request.clipName)”"
        title = "Replace your hand edits?"
        body = "\(request.preset.displayName) tunes all of \(clip) from scratch. "
            + "This replaces the tuning already on this clip, including \(Self.handEdits)."
        undoNote = "Changed your mind afterwards? Undo (⌘Z) brings your edits back."
        confirmLabel = "Replace my edits"
        cancelLabel = "Cancel"
    }
}
