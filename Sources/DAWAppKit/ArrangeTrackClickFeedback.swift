import Foundation

// m23-an — the ONE home for "DOES THIS TRACK-HEADER CLICK OWE THE USER AN
// ACKNOWLEDGEMENT?". Headless (no SwiftUI, no AppKit) in the
// `ArrangeRefusalAnchor` / `ArrangeDropSnap` / `EditorSurfaceRouter` tradition,
// and headless HERE for the usual specific reason: `DAWApp` has no test target,
// so a predicate written inline in `AppModel.clickTrack` or inside a `TrackRow`
// body would be provable only by a live gate.
//
// IT ANSWERS EXACTLY ONE QUESTION AND RETURNS A VERDICT, NOT PROSE. No
// user-facing copy lives in DAWAppKit: the `ArrangeRefusalBubble` /
// `PianoRollView.deleteBarBlockedReason` convention is that DAWAppKit decides
// and the view owns the wording, the placement and the colour register. A
// predicate that also carried the sentence would put the design language's
// register decision behind a unit test that cannot see pixels.
//
// ═══ THE PREDICATE, AND THE SIX MEASURED ROWS IT WAS FITTED TO ═══════════════
//
// **Acknowledge iff the track has NO clips AND the selection did not change.**
//
// Two terms, total, and no invented tiebreak. Every row below was measured on a
// live staging binary BEFORE any of this code existed
// (`scripts/gates/_m23an-feedback-probe.mjs`); this table is the record, not a
// prediction:
//
//   D5  ⇧ on a 3-clip header, nothing selected      -> selection 0 -> 3   NO ack
//   D3  ⇧ on a 0-clip header                        -> effect "no-clips",
//                                                      selection identical  ACK
//   D4  the same ⇧ click, seen from the SIDE EFFECTS -> `keyFocusNonce` 1->2 and
//       `activeEditorSurface` pianoRoll -> arrange. The click is NOT inert: it
//       silently retargets ⌘+/⌘−/⌘0 (m23-al-1) and moves DELETE's key focus.
//       This row is WHY feedback is owed at all, and why the side effects must
//       NOT be suppressed to "fix" the silence — see `AppModel.clickTrack`.
//   D1  PLAIN on a 0-clip header while a clip is focused -> n 1 -> 0, focus and
//       the open editor both -> null. **LOUD.**                          NO ack
//   D2  PLAIN on a 0-clip header, selection ALREADY empty -> effect "replace",
//       nothing changes. **Equally silent, and NOT `.noClips`** — the item as
//       filed named one branch; the defect spans two.               ACK
//   D6  PLAIN repeated on the SAME 3-clip header -> nothing changes, but three
//       blocks are visibly selected and the state MATCHES the intent.    NO ack
//
// D2 is why the predicate cannot be `effect == .noClips`. D6 is why it cannot be
// `!changedSelection` alone — that single-term reading fires an acknowledgement
// on a click whose result is fully visible on screen. D1 is the row a careless
// widening breaks worst: it would put "nothing to select" on top of the largest
// visible change this surface has (a cleared selection and a closed piano roll).
//
// ═══ WHAT m25-l-1 DEFECT ② DID TO THAT TABLE (2026-08-13) — READ, DO NOT REDO ══
//
// A plain header click now CLEARS the clip selection instead of selecting the
// track's clips (USER RULING; the argument is in `ArrangeTrackSelection`'s
// banner). **THE PREDICATE IS UNCHANGED AND NEEDED NO CHANGE, and that is a
// derived result rather than an assumption:**
//
//   • On a ZERO-clip track the plain branch's old `replace(with: [])` and its new
//     `clear()` are the same mutation on both fields. D1 and D2 — the only plain
//     rows in the table — are therefore untouched, byte for byte.
//   • On a POPULATED track `clipIDs` is non-empty, so the first term is false and
//     the verdict is `.notNeeded` whatever `changedSelection` says. It was
//     `.notNeeded` before for the same reason.
//
// So every plain click's acknowledgement is BIT-IDENTICAL across the ruling. (The
// rejected alternative — leaving the existing selection standing — was NOT: it
// would have flipped D1 to `.noClipsToSelect`, i.e. announced "No clips to
// select" over the loudest row in the table.)
//
// ⚠️ ONE ROW IS NO LONGER REACHABLE AS WRITTEN: **D6**. "PLAIN repeated on the
// SAME 3-clip header" needed the FIRST plain click to select those three, which
// it no longer does. Its JOB — a silent click on a track that HAS clips, killing
// the one-term `!changedSelection` predicate — survives and is in fact easier to
// reach: ONE plain click on a populated header with nothing selected is now
// silent, with `clipIDs.count == 3`. What changed is only the REASON the verdict
// is right. It used to be "three blocks are visibly selected, so the state
// matches the intent"; it is now "the track HAS clips, so the sentence *No clips
// to select* would simply be false". The table above is a record of a live
// measurement and is deliberately NOT rewritten; `ArrangeTrackClickFeedbackTests`
// carries the restated D6 and the newly-reachable case beside it.
//
// 📌 AN OBSERVATION, NOT A DEFECT AND NOT ADDRESSED HERE: since m25-l-1 shipped
// the active-track cursor, a plain click on an EMPTY header is the canonical way
// to aim a paste at an empty track — and it still draws "No clips to select"
// (D2). The click is no longer silent (the active-track rail moves), so the
// premise that owed the acknowledgement has weakened. That is a pre-existing
// consequence of m25-l-1, NOT of defect ②, and re-deciding it needs the table
// re-measured on a live binary rather than reasoned about here.
//
// ═══ WHY BOTH TERMS ARE ON THE OUTCOME, AND NOTHING ELSE IS THREADED IN ══════
//
// "An editor is open" is NOT independent state that would need passing in.
// `ArrangeSelection` holds INV1 (`focusID != nil => ids.contains(focusID!)`) and
// INV2 (`ids.isEmpty => focusID == nil`), and the piano roll resolves against
// `focusID` — so whether an editor closed is a CONSEQUENCE of the id set moving,
// already inside `changedSelection`. `ArrangeTrackSelection.apply` owns both
// terms, which is what keeps this file free of a second reading of the model.
public enum ArrangeTrackClickFeedback {
    /// The verdict for one header click.
    ///
    /// - Parameter outcome: exactly what `ArrangeTrackSelection.apply` returned.
    ///   Both terms are read off it — `clipIDs.isEmpty` IS "the track has no
    ///   clips" (`clipIDs(on:)` returns `Set(track.clips.map(\.id))`, empty iff
    ///   `track.clips` is), and `changedSelection` is the mutators' own before/
    ///   after comparison. Taking the outcome rather than the `Track` is the
    ///   point: re-deriving the clip count from a `Track` here would be a second
    ///   answer to a question `apply` already answered, free to disagree with it
    ///   the moment a header click stops meaning "every clip on the lane".
    public static func acknowledgement(
        for outcome: ArrangeTrackClickOutcome
    ) -> ArrangeTrackClickAcknowledgement {
        (outcome.clipIDs.isEmpty && !outcome.changedSelection) ? .noClipsToSelect : .notNeeded
    }
}

/// WHETHER a header click owes the user a word, and which one.
///
/// AN ENUM RATHER THAN A `Bool`, deliberately, though today it carries exactly
/// two cases and is isomorphic to one. Two reasons, both about the next edit:
///
///   • The view `switch`es over it EXHAUSTIVELY, so a third silent situation
///     (should one ever be measured) cannot be added here and quietly ignored
///     at the only place that can draw it — it fails to compile instead.
///   • The case NAMES the measured condition, so a call site reads as a verdict
///     ("this click had no clips to select") rather than as a flag whose meaning
///     lives somewhere else. `.notNeeded` over `.none` on purpose: `.none` in an
///     `Optional` context is a different value, and this type is deliberately
///     returned non-optionally.
///
/// Raw values are stable strings so the `debug.arrangeSelection` seam can echo
/// the verdict verbatim — the `ArrangeTrackClickEffect` / `ArrangeNudgeStepSource`
/// convention. They are wire-adjacent identifiers, NOT copy: the sentence the
/// user reads lives in `TrackListView`.
public enum ArrangeTrackClickAcknowledgement: String, Equatable, Sendable {
    /// The click explained itself — either it moved the selection (the blocks
    /// visibly changed) or the track had clips, so what the user sees already
    /// matches what they asked for. Nothing is drawn.
    case notNeeded = "none"
    /// The track has no clips AND the selection did not move: the click landed,
    /// changed the key-focus target and the active editor surface, and drew
    /// NOTHING. This is the state that reads as a click that never registered.
    case noClipsToSelect = "no-clips-to-select"
}
