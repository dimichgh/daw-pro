import Foundation

// Staging + report plumbing for the arrange marker-lane inline rename (m23-ba-1).
//
// The seam's OPEN half has existed since m11-c (`stageRenameMarkerID`). What was
// missing — and what m23-ba-1 adds — is a way to FINISH a rename the way a user
// finishes one. `debug.markerRename {clear:true}` unmounts the field, and that
// MEASURABLY discards the draft (the measurement is written out in
// `DAWAppKit.MarkerRenameStaging`), so it can stand in for "the field went away"
// and for nothing else. `commit` and `cancel` run the flag's OWN handlers — the
// same `commit()` that `.onSubmit` and the focus-loss `.onChange` call, and the
// same `onCancelRename` that `.onKeyPress(.escape)` calls — following the
// `arrangePointerStage` / `arrangeMarqueeStage` precedent: stage a value, let the
// view run its real handler, and report the OUTCOME back up.
//
// Real keystrokes are not injectable on the unbundled staging binary (no
// Accessibility grant — the m17-b −1712 measurement), which is why a seam is
// needed at all rather than "just press Return".

/// A staged marker-rename resolution (debug tier only; nil in normal use).
struct MarkerRenameStage: Equatable {
    enum Action: String {
        /// The flag's own `commit()` — `onCommitRename(draft)` with the LIVE
        /// draft, through `TrackRename.committedName`: the body Return AND
        /// click-away both reach. ⚠️ The BODY, not the trigger — the
        /// `fieldFocused` transition is never driven, so focus-loss detection
        /// itself is out of reach from here.
        case commit
        /// `onCancelRename(draft)` — the Escape path. Reverts.
        case cancel
    }

    var action: Action
    /// Bumped per request so a repeat of the same action still fires `.onChange`.
    var nonce: Int
}

/// What a rename resolution ACTUALLY did, reported UP by the flag that ran it.
///
/// Real gestures and staged actions feed the same callback (the `onPointerState`
/// honesty rule), so this is ground truth about the handler that ran — never the
/// seam's own input. `committedName` is the value `TrackRename.committedName`
/// returned, so a gate can tell "committed 'Verse'" from "commit ran and the
/// trim/empty-cancel/unchanged rule dropped it", which are two very different
/// outcomes that both leave the marker's name unchanged in the second case.
struct MarkerRenameOutcome: Equatable {
    var action: MarkerRenameStage.Action
    var markerID: UUID
    /// The field's draft at the moment the handler ran.
    var draft: String
    /// The name that reached `ProjectStore.renameMarker`, or nil when the commit
    /// rule dropped it (empty / unchanged) — always nil for `.cancel`.
    var committedName: String?
}
