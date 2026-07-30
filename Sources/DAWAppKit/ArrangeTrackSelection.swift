import Foundation
import DAWCore

// TRACK multi-select in the arrange (m23-y) — the ONE home for what a click on a
// track HEADER does to the arrange selection. Headless (no SwiftUI, no AppKit) so
// every branch is unit-testable, in the `ArrangeNudge` / `ArrangeDropSnap` /
// `ArrangeMarquee` / `ArrangeGroupDrag` tradition. `DAWApp` has no test target, so
// a rule decided inside a SwiftUI `body` — or inside the `AppModel` handler —
// would be invisible to `Tests/`; everything decidable lives here and the handler
// owns only composition.
//
// ═══ THE SEMANTICS, DECIDED ON THE ROADMAP: SELECTING A TRACK SELECTS ITS CLIPS ═══
//
// A track is NOT a distinct selectable object. It has no selection domain of its
// own, no `isSelected` flag, and it is not a member of `ArrangeSelection.ids` —
// clicking a header simply resolves to that track's CLIP ids and runs them
// through the clip mutators m23-g1/g3 already built. Three consequences, and they
// are the reason the roadmap chose this reading:
//
//   • `ArrangeSelection` needs NO new state (only the `subtract` mutator below).
//   • Group delete needs NO new rule: it still deletes exactly `ids`, so it can
//     never be ambiguous about whether it removes clips or whole tracks. A
//     destructive verb behind a fresh ambiguity is what the alternative would
//     have bought.
//   • A mixed track+clip selection is just a bigger `ids` set. Shift-clicking a
//     header and then shift-clicking one more clip composes with no special case,
//     because after the header click there is nothing left that remembers a track
//     was involved.
//
// The ALTERNATIVE (a track as a distinct selectable object) ships only on the
// user's word. Do not add it on the way past.
//
// ═══ A HEADER CLICK NEVER ADOPTS A FOCUS ═══
//
// This falls out of the mutators reused below and is stated here because it is
// USER-VISIBLE and someone will otherwise "fix" it. Plain-clicking the header of
// a track holding exactly one MIDI clip selects that clip but does NOT open the
// piano roll on it — while clicking the CLIP does, because `ArrangeSelection`'s
// single-clip path (`selectOnly` / `toggle`) adopts a focus and the set paths
// (`replace(with:)` / `formUnion` / `subtract`) deliberately never do.
//
// That asymmetry is the honest one, in `replace(with:)`'s own words: a header,
// like a marquee, has NO anchor clip. Promoting "some member" to focus would open
// the note editor on a clip the user never clicked, purely because it happened to
// sort first or sit leftmost — the exact outcome `ArrangeSelection.toggle`'s focus
// rule refuses. SELECTING IS NOT OPENING.
//
// The focus is not DESTROYED either: `replace(with:)` keeps a focus that survives
// into the new set, so clicking the header of the track already holding the open
// editor clip leaves the roll open on it. That is a consequence worth knowing —
// it is what makes the roll-vs-arrange DELETE arbitration reachable from a header
// click at all (see `AppModel.clickTrack`).
//
// ═══ WHAT THIS IS NOT ═══
//
// NOT a second home for `AppModel.deleteArrangeSelection`'s `flatMap` over every
// track (`DAWProApp.swift:696`). That expression answers "which clip ids exist in
// the PROJECT" — the live set a stale selection is filtered against. This answers
// "which clip ids are on THIS ONE track". Same shape, different questions, and
// folding them together would make the delete path's stale-id filter depend on
// which track a header click last touched. Do not "fix" them into one.
public enum ArrangeTrackSelection {
    /// Every clip id on `track` — exactly the set a header click acts on.
    ///
    /// EXACTLY WHAT THE LANE RENDERS. `TimelineLanesView.swift:1058` is
    /// `ForEach(track.clips)`, so this set and the blocks the user can see are
    /// the same collection read twice, not two opinions about it. "Select every
    /// clip on this track" therefore cannot mean something different from "select
    /// every block drawn on this lane".
    ///
    /// TAKE-LANE CLIPS ARE STRUCTURALLY EXCLUDED, not filtered out. An
    /// un-flattened take lives at `TakeGroup.lanes[].clip` (`Sources/DAWCore/
    /// Takes.swift:71-74`) and is never a member of `track.clips`; only the
    /// COMPED result is materialized into `track.clips`, marked by
    /// `Clip.takeGroupID`. So there is no take-lane predicate here to get wrong,
    /// and none can be needed later without the take model itself changing.
    /// (What IS in scope: a flattened comp member is an ordinary member of this
    /// set, and `ProjectStore.removeClips` refuses the whole batch when one is
    /// present — see `AppModel.clickTrack` for why that is worth knowing.)
    public static func clipIDs(on track: Track) -> Set<UUID> {
        Set(track.clips.map(\.id))
    }

    /// The chord half of a header click, applied to `selection`.
    ///
    /// THE CHORD TABLE IS NOT DUPLICATED. The mapping from modifiers to intent is
    /// `ArrangeClickIntent.intent(for:)`, the same one a clip click and a marquee
    /// drag use, so ⇧/⌘ mean the same thing on all three surfaces and a future
    /// chord change lands in one place.
    ///
    /// ═══ THE TOGGLE BRANCH IS AN ALL-OR-NONE SET TOGGLE ═══
    ///
    /// ⇧/⌘ on a header whose clips are ALL already selected REMOVES them all;
    /// otherwise it ADDS them all. This is a total function with no invented
    /// tiebreak for the partially-selected case, and it is a TRUE toggle — the
    /// precedent for a DISCRETE click is `ArrangeSelection.toggle`, not the
    /// marquee.
    ///
    /// WHY NOT "ADDITIVE, MATCHING THE MARQUEE": the marquee is additive as a
    /// CONSEQUENCE OF BEING CONTINUOUS. `AppModel.applyArrangeMarquee`'s own doc
    /// says why it restores a base first — "a marquee re-decides on every pointer
    /// move: without the restore, shrinking a shift-band could never give a clip
    /// back". A header click is DISCRETE: one click, one decision, no base, no
    /// re-decide. Nothing in that argument transfers, so copying its outcome
    /// would leave a user who shift-clicked a header by mistake with no way to
    /// take it back except rebuilding the whole selection.
    ///
    /// THE EMPTY TRACK IS GUARDED EXPLICITLY, before the subset test, because
    /// `Set().isSubset(of:)` is vacuously TRUE — a zero-clip track would
    /// otherwise read as "all already selected" and report `.remove`. Both
    /// branches are no-ops on the selection, so this changes no behaviour; it
    /// changes what the outcome SAYS, and a vacuous subset result is exactly the
    /// invented tiebreak the all-or-none rule exists to avoid.
    ///
    /// A PLAIN click on an empty track is NOT guarded and must not be: it
    /// `replace`s with the empty set, i.e. it clears the selection and closes the
    /// note editor (INV2). That is the roadmap's "a track with zero clips selects
    /// cleanly" — clicking empty space in the header column deselects, exactly as
    /// clicking empty space in the lanes does.
    @discardableResult
    public static func apply(
        click track: Track,
        modifiers: ArrangeClickModifiers,
        to selection: inout ArrangeSelection
    ) -> ArrangeTrackClickOutcome {
        let ids = clipIDs(on: track)
        let intent = ArrangeClickIntent.intent(for: modifiers)
        let effect: ArrangeTrackClickEffect
        switch intent {
        case .replace:
            selection.replace(with: ids)
            effect = .replace
        case .toggle:
            if ids.isEmpty {
                effect = .noClips
            } else if ids.isSubset(of: selection.ids) {
                selection.subtract(ids)
                effect = .remove
            } else {
                selection.formUnion(ids)
                effect = .add
            }
        }
        return ArrangeTrackClickOutcome(intent: intent, effect: effect, clipIDs: ids)
    }
}

/// WHICH branch a header click took. Raw values are stable strings so the
/// `debug.arrangeSelection {act:"clickTrack"}` seam can echo the decision verbatim
/// (the `ArrangeNudgeStepSource` / `TransportKeyDecision` convention) — a gate
/// that reads back only the resulting id set cannot tell "⇧ added 3" from
/// "⇧ found them already there and removed nothing".
public enum ArrangeTrackClickEffect: String, Equatable, Sendable {
    /// Plain click: the selection became exactly this track's clips.
    case replace
    /// ⇧/⌘ and at least one of this track's clips was not selected: all added.
    case add
    /// ⇧/⌘ and every one of this track's clips was already selected: all removed.
    case remove
    /// ⇧/⌘ on a track with NO clips: nothing to add, nothing to remove. Distinct
    /// from `.remove` on purpose (see `ArrangeTrackSelection.apply`).
    case noClips = "no-clips"
}

/// One header click's answer: which chord rule fired, which branch it took, and
/// the exact id set it acted on.
///
/// `fileprivate init` (the `ArrangeDropSnap` / `ArrangeNudgeStep` model):
/// `ArrangeTrackSelection.apply` is the only producer in this file, so an
/// intent/effect/ids triple the rule would not have produced is UNREPRESENTABLE —
/// no caller, and no test, can assemble one.
public struct ArrangeTrackClickOutcome: Equatable, Sendable {
    /// From `ArrangeClickIntent.intent(for:)` — the shared chord table.
    public let intent: ArrangeClickIntent
    /// Which branch of `apply` ran.
    public let effect: ArrangeTrackClickEffect
    /// EXACTLY what `clipIDs(on:)` returned. Echoed by the seam rather than
    /// recomputed there, so the seam and the gesture can never disagree about
    /// what "this track's clips" means.
    public let clipIDs: Set<UUID>

    fileprivate init(intent: ArrangeClickIntent,
                     effect: ArrangeTrackClickEffect,
                     clipIDs: Set<UUID>) {
        self.intent = intent
        self.effect = effect
        self.clipIDs = clipIDs
    }
}
