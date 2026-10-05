import Foundation

// m23-ap interaction batch, item I4 — ESCAPE's ONE LADDER, for BOTH note editors.
//
// Design record: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §7
// ("Esc"), decided in §13 rather than asked.
//
// Escape means "cancel the thing in front of you" before it means anything
// else, and in a note editor there are up to three such things, nearest first:
// a gesture the pointer is still holding, a selection, and the maximized mode
// the whole window is in. The ladder answers which ONE a press takes down —
// one rung per press, so a user who pressed Escape during a drag with notes
// selected in a maximized editor gets back to the normal window in three
// presses, each of which undid exactly one thing they could see.
//
// ⭐⭐ ONE PURE RULE, ASKED BY EVERY MOUNT. `AppModel.handleEditorEscape` is the
// app's one Escape decision (m25-b-1, three mounts since I6a); it feeds this
// ladder the two facts only the focused editor has (is a gesture live, is
// anything selected) and the two only the app has (is the mode on, does a modal
// or a rename field own the key). Each rung's EFFECT is applied by its owner —
// the editor cancels its own gesture and clears its own selection (its model is
// `@State private`), the app leaves the mode — but WHICH rung fires is decided
// here, once, for both editors.
//
// ⚠️ THE ROLL'S ESCAPE CHANGED WHEN THIS LANDED, ON PURPOSE (§13). Before I4 the
// roll's Escape went straight to exit-maximize and left a selection alone; it
// now clears the selection first. That is a named behaviour change on a
// shipped surface, recorded here so nobody "restores" the old order as a fix.

/// What ONE Escape press does.
public enum EditorEscapeRung: String, Sendable, Equatable, CaseIterable {
    /// Abandon the gesture the pointer is still holding — nothing it did so far
    /// is kept, and its release commits nothing.
    case cancelGesture = "cancel-gesture"
    /// Clear the editor's selection. Selecting is not editing: nothing is
    /// journalled.
    case clearSelection = "clear-selection"
    /// Leave the maximized editor mode (`EditorMaximize`). Set, never toggled.
    case exitMaximize = "exit-maximize"
    /// Nothing here claims the key: it keeps propagating exactly as it did
    /// before any of this existed (a modal, a rename field, AppKit).
    case pass

    /// Whether the mount that asked answers `.handled`. A `switch`, so a new
    /// rung must answer the question rather than inherit one in silence.
    public var consumesKey: Bool {
        switch self {
        case .cancelGesture, .clearSelection, .exitMaximize: return true
        case .pass: return false
        }
    }
}

/// THE rule. Pure, total, and the only place its order is written.
public enum EditorEscapeLadder {

    /// Which rung an Escape press takes.
    ///
    /// ORDER, nearest thing first:
    ///  1. `blocked` — a MODAL is on screen or a RENAME FIELD owns the key
    ///     (`AppModel.isModalPresented` / `isArrangeTextEditingFocused`), or —
    ///     since m34-k — the explain mode, whose exit is a key equivalent; all
    ///     three are `AppModel.escapeIsOwnedElsewhere`. They own
    ///     Escape outright: cancelling the panel the user is looking at, or
    ///     reverting the edit they are typing, is what they meant. Checked FIRST,
    ///     for `EditorMaximize.escapeExits`'s reason: both are reachable on the
    ///     retained-focus path, where focus stays on an editor while an inline
    ///     overlay opens.
    ///  2. `gestureLive` — the pointer is holding a gesture that changes
    ///     something (a pitch drag, a band, a move). Cancelled before anything
    ///     else, so Escape never clears a selection out from under a drag that is
    ///     still moving it.
    ///  3. `hasSelection` — clear it (the ⚠️ roll behaviour change, above).
    ///  4. `maximized` — leave the mode.
    ///  5. Otherwise `.pass`.
    public static func resolve(gestureLive: Bool, hasSelection: Bool,
                               maximized: Bool, blocked: Bool) -> EditorEscapeRung {
        guard !blocked else { return .pass }
        if gestureLive { return .cancelGesture }
        if hasSelection { return .clearSelection }
        if maximized { return .exitMaximize }
        return .pass
    }
}
