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
// ⚠️ **AMENDED 2026-08-13 BY USER RULING — read "m25-l-1 DEFECT ②" below before
// this section.** What follows is still exactly right for a ⇧/⌘ click, and all
// three consequences it names are unchanged. It is no longer true of a PLAIN
// click, which is now a pure cursor move that selects nothing.
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
//     because nothing in the SELECTION remembers a track was involved.
//
// ═══ m25-l-1: THE ACTIVE TRACK — A CURSOR, WHICH IS NOT A SELECTION ═══
//
// This banner used to end: *"The ALTERNATIVE (a track as a distinct selectable
// object) ships only on the user's word. Do not add it on the way past."* That
// prohibition was CONDITIONAL, and **the user has now given the word** (m25-l,
// 2026-08-13): *"missing feature is user should be able to select a track which
// becomes active for any implicit or explicit actions."* So a header click now
// also names an ACTIVE TRACK, carried out on the outcome below as
// `activeTrackID` and resolved by `ArrangeActiveTrack.resolve`.
//
// ⚠️ **READ THE DISTINCTION BEFORE CHANGING ANYTHING HERE, because it is what
// keeps every consequence above true.** A SELECTION is *what a verb acts on*;
// the active track is *where the next thing goes* — an insertion point, the text
// caret's analogue, not a member of any acted-on set. Concretely:
//
//   • The active track is NOT in `ArrangeSelection.ids`, and nothing on this
//     path writes one into it.
//   • Group delete STILL removes exactly `ids`. The destructive-verb ambiguity
//     the old prohibition guarded against is still structurally impossible —
//     no verb in this app reads `activeTrackID`.
//   • `ArrangeSelection` still needs no new state; the active track is stored
//     beside it (`AppModel.explicitActiveTrackID`), never inside it.
//
// **The still-forbidden thing is a track-valued SELECTION** — a track that
// DELETE, nudge or drag would act on as a member. That has not shipped and still
// needs the user's word.
//
// ═══ m25-l-1 DEFECT ②: A PLAIN HEADER CLICK SELECTS NOTHING (USER RULING) ═══
//
//   **PLAIN click  → names the ACTIVE TRACK and CLEARS the clip selection.**
//   **⇧/⌘  click   → the set behaviour above, unchanged and undiminished.**
//
// ⚠️ **THIS IS A DESIGN CHANGE ON THE USER'S WORD, NOT A REPAIR — the previous
// behaviour was deliberate, documented here, and correct for what it knew.** The
// user, hands-on 2026-08-13: *"when I click on track with clips, all clips got
// selected which is not expected."*
//
// WHAT CHANGED IS NOT THE ARGUMENT, IT IS THE WORLD. Select-all-on-header was
// decided when a header click had no other job — Logic Pro behaves the same way,
// and nothing else about the gesture was load-bearing. Then m25-l-3 made a header
// click **THE way to choose a paste destination**, so the same gesture that names
// where the next ⌘V lands also armed the next ⌫ with every clip on that track. A
// NAVIGATIONAL ACT HAD ACQUIRED A DESTRUCTIVE CONSEQUENCE. That is new
// information the original decision did not have, and it is the whole reason to
// revisit it.
//
// The capability is PRESERVED, not deleted: ⇧/⌘ still selects a whole track, and
// "select exactly this track's clips and nothing else" is still reachable in two
// clicks — plain (clears, activates) then ⇧ (adds them all).
//
// ─── WHY THE PLAIN CLICK **CLEARS** RATHER THAN LEAVING THE SELECTION ALONE ───
//
// The question the change forced, and it was genuinely open. Four reasons for
// clearing, in the order they decided it:
//
//   1. **The caret analogy is this module's own.** `ArrangeActiveTrack` calls the
//      active track "the text caret's analogue". Clicking in a text view sets the
//      caret AND collapses the selection; it does not leave a highlighted run
//      standing somewhere off screen. Leaving it would take the analogy's name
//      without its behaviour.
//   2. **It is the only reading that actually closes the defect's CLASS.** The
//      complaint's symptom is "everything went blue"; the hazard is that the next
//      ⌫ deletes it. Leaving a prior selection standing fixes the symptom and
//      keeps the hazard — the click still arms a destructive key with clips the
//      user is no longer looking at, just a different set of them.
//   3. **It is a STRICT GENERALISATION of behaviour that already shipped.** A
//      plain click on a ZERO-clip track already cleared (`replace(with: [])`),
//      and the roadmap called that "a track with zero clips selects cleanly".
//      Clearing makes the plain branch that one rule at every clip count instead
//      of two rules that agree only at zero.
//   4. **`ArrangeTrackClickFeedback` needs NO change, provably.** Its verdict is
//      `clipIDs.isEmpty && !changedSelection`. On an empty track `clear()` and
//      `replace(with: [])` are the same mutation, so D1/D2 are untouched; on a
//      populated track `clipIDs` is non-empty, so the verdict is `.notNeeded`
//      before and after whatever `changedSelection` does. The plain click's
//      acknowledgement is therefore BIT-IDENTICAL across this change. The
//      alternative is not: leaving the selection alone would flip D1 (plain click
//      on an empty header while a clip is focused) from `.notNeeded` to
//      `.noClipsToSelect`, putting "No clips to select" on top of a *measured*
//      loud row.
//
// AND IT COMPOSES WITH m25-m rather than fighting it: clicking empty LANE space
// deselects clips and leaves the cursor standing; a plain header click now does
// the same thing from the header column. One deselect rule, two surfaces —
// against which "the header column is the one place a click preserves your
// selection" would have been a special case to memorise.
//
// ═══ A HEADER CLICK NEVER ADOPTS A FOCUS ═══
//
// This falls out of the mutators reused below and is stated here because it is
// USER-VISIBLE and someone will otherwise "fix" it. ⇧-clicking the header of a
// track holding exactly one MIDI clip selects that clip but does NOT open the
// piano roll on it — while clicking the CLIP does, because `ArrangeSelection`'s
// single-clip path (`selectOnly` / `toggle`) adopts a focus and the set paths
// (`replace(with:)` / `formUnion` / `subtract`) deliberately never do.
//
// (Stated with ⇧ since the defect-② ruling. It used to read "plain-clicking",
// which no longer selects anything at all — but the RULE is unchanged and the
// argument below is untouched, so this is a restatement, not a retreat.)
//
// That asymmetry is the honest one, in `replace(with:)`'s own words: a header,
// like a marquee, has NO anchor clip. Promoting "some member" to focus would open
// the note editor on a clip the user never clicked, purely because it happened to
// sort first or sit leftmost — the exact outcome `ArrangeSelection.toggle`'s focus
// rule refuses. SELECTING IS NOT OPENING.
//
// ⚠️ **WHAT THE DEFECT-② RULING DID CHANGE: a PLAIN click now CLOSES an open
// piano roll.** This paragraph used to say the opposite — "the focus is not
// DESTROYED either: `replace(with:)` keeps a focus that survives into the new
// set" — and that was true while the plain branch replaced with the track's own
// clips. The plain branch now empties the selection, so INV2 drops the focus and
// the editor closes, exactly as a plain click on a zero-clip track has always
// done. It is the same event a click on empty lane space produces (m25-m), so it
// is not a new kind of surprise.
//
// **THE ROLL-VS-ARRANGE DELETE ARBITRATION SURVIVES, BEHIND THE MODIFIER.** It
// needs a header click that leaves the roll OPEN while bumping the arrange's key
// focus, and ⇧/⌘ is exactly that: `formUnion` touches no focus, `subtract` drops
// it only when the focused clip leaves, and `AppModel.clickTrack` bumps the nonce
// on every chord. So the two-candidate-consumer case documented at
// `AppModel.clickTrack` is reached by ⇧-clicking the header of the track the roll
// is open on — the same shape as the selection capability itself: preserved under
// a modifier, gone from the plain click.
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
    /// Every clip id on `track` — exactly the set a ⇧/⌘ header click acts on.
    ///
    /// ⚠️ IT IS STILL COMPUTED FOR A PLAIN CLICK, WHICH NO LONGER ACTS ON IT
    /// (defect ②), and that is deliberate rather than left over. The outcome's
    /// `clipIDs` is `ArrangeTrackClickFeedback`'s first term — `clipIDs.isEmpty`
    /// IS "this track has no clips" — and that predicate has to answer on the
    /// plain branch too. `ArrangeTrackClickFeedback`'s own doc predicted exactly
    /// this moment ("free to disagree with it the moment a header click stops
    /// meaning 'every clip on the lane'") and named the resolution: the term is a
    /// CLIP-COUNT PROXY read off the one place that computes it, not a claim
    /// about what the click did. **Do not "tidy" this to the empty set on the
    /// plain branch** — it would fire "No clips to select" on every plain click
    /// on a populated track whose selection did not move.
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
    /// ═══ THE PLAIN BRANCH CLEARS (m25-l-1 defect ②, USER RULING 2026-08-13) ═══
    ///
    /// `.replace` runs `selection.clear()`, NOT `replace(with: ids)`. A plain
    /// header click is a CURSOR MOVE: it names `activeTrackID` and takes the clip
    /// selection down to nothing. The banner carries the full argument — including
    /// why clearing beat leaving the selection standing — and the four-point case
    /// there is what a reviewer should read before changing this line back.
    ///
    /// ⚠️ IT IS STILL SPELLED `.replace`, and the raw value is still `"replace"`.
    /// The intent case comes from the SHARED chord table (`ArrangeClickIntent`),
    /// where `.replace` means "this click re-decides the whole selection rather
    /// than adding to it" — which is exactly what clearing does, at cardinality
    /// zero. Renaming the effect to `.clear` was considered and rejected: nothing
    /// in shipped code branches on it (the seam echoes `rawValue`, the view
    /// switches on the ACKNOWLEDGEMENT), so a rename buys no behaviour, and it
    /// would give every stale gate a second failure axis — a reader could no
    /// longer tell "the behaviour changed" from "the string changed".
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
    /// A PLAIN click needs no empty-track guard AT ANY CLIP COUNT since defect ②:
    /// it clears the selection and closes the note editor (INV2) whatever the
    /// track holds. That USED to be a property of the zero-clip case alone — the
    /// roadmap's "a track with zero clips selects cleanly" — and is now the plain
    /// branch's whole behaviour. Clicking in the header column deselects, exactly
    /// as clicking empty space in the lanes does (m25-m).
    ///
    /// ═══ WHY THE OUTCOME ALSO CARRIES `changedSelection` (m23-an) ═══
    ///
    /// Selection in the arrange is rendered ENTIRELY as clip blocks going
    /// selected, so "the selection did not move" is exactly "the click drew
    /// nothing". That is a different question from WHICH BRANCH ran — the two
    /// disagree in both directions, which is why it is measured here rather than
    /// inferred downstream from `effect`:
    ///
    ///   • `.replace` over an ALREADY-EMPTY selection is a no-op the effect
    ///     string calls `replace`. Silent, and not `.noClips`.
    ///   • A plain click that CLEARS a real selection is also `.replace`, and is
    ///     the loudest thing on this surface (it closes the note editor).
    ///
    /// Measured on a live staging binary before this field existed
    /// (`scripts/gates/_m23an-feedback-probe.mjs`, legs D1/D2/D3/D6).
    ///
    /// IT IS `true` IN BOTH CHORD BRANCHES UNCONDITIONALLY, and a future reader
    /// will want to know whether that makes it dead weight. It does not, and the
    /// reason is structural rather than incidental: `.add` is reached only when
    /// `ids` is NOT a subset of the selection, so `formUnion` must insert at least
    /// one id; `.remove` is reached only when `ids` is non-empty AND a subset, so
    /// `subtract` must remove at least one. **Neither branch can produce
    /// `changedSelection == false`.** So `false` is reachable from exactly two
    /// branches — `.noClips`, which mutates nothing at all, and `.replace` over an
    /// already-empty selection. Both are pinned in
    /// `ArrangeTrackClickFeedbackTests`, including the impossibility, so an edit
    /// to `formUnion`/`subtract` that made a mutator silently no-op fails a test
    /// instead of quietly widening the acknowledgement.
    ///
    /// ⚠️ **DEFECT ② WIDENED THE `.replace` HALF OF THAT, and the new case is the
    /// one the change's safety argument rests on.** It used to require a ZERO-CLIP
    /// track (`replace(with: [])` over an empty selection); the plain branch now
    /// clears at every clip count, so a plain click on a POPULATED track with
    /// nothing selected is silent too — `changedSelection == false` with a
    /// NON-EMPTY `clipIDs`. That combination was previously unreachable, and it is
    /// exactly the one that keeps the acknowledgement `.notNeeded` (first term
    /// false) rather than announcing "No clips to select" on a track full of them.
    /// Pinned by name in `ArrangeTrackClickFeedbackTests`.
    ///
    /// Computed by VALUE COMPARISON (`ArrangeSelection` is `Equatable`), never by
    /// a per-branch literal: a hand-written `true` beside each mutator would be a
    /// second opinion about what the mutator did, free to agree with a broken one.
    ///
    /// ═══ m25-l-1: EVERY HEADER CLICK MAKES ITS TRACK ACTIVE ═══
    ///
    /// `activeTrackID` on the outcome is `track.id`, UNCONDITIONALLY — every
    /// chord, every branch, and a zero-clip track too. The rule lives here rather
    /// than in `AppModel.clickTrack` for this file's stated reason (a rule decided
    /// in the handler is invisible to `Tests/`), and it is total on purpose:
    ///
    ///   • **⇧/⌘ counts.** A chord extends the CLIP selection, but the click is
    ///     still an unambiguous statement of where the user is. A rule that moved
    ///     the cursor only on a plain click would make "where I am" depend on
    ///     which modifier happened to be down.
    ///   • **`.noClips` counts, and it is the case the item exists for.** An empty
    ///     track can never be reached by the focus term of
    ///     `ArrangeActiveTrack.resolve` — it owns no clip for a focus to resolve
    ///     through — so if a click on it did not set the cursor, nothing ever
    ///     could, and "you cannot paste onto an empty track" would stand.
    ///   • **A click that changes NOTHING counts** (`changedSelection == false`).
    ///     Same argument as the `arrangeKeyFocusNonce` bump on `AppModel.
    ///     clickTrack`: this is a cursor move, not an edit, and gating it on a
    ///     selection delta would silently make re-clicking a track a no-op.
    ///
    /// It is NOT `Optional`: `apply` is only reachable with a `Track` in hand, so
    /// "a header click with no active track" is unrepresentable rather than a
    /// state a caller has to handle. The unknown-id case is the CALLER's
    /// (`AppModel.clickTrack` guards before it ever gets here).
    @discardableResult
    public static func apply(
        click track: Track,
        modifiers: ArrangeClickModifiers,
        to selection: inout ArrangeSelection
    ) -> ArrangeTrackClickOutcome {
        let ids = clipIDs(on: track)
        let intent = ArrangeClickIntent.intent(for: modifiers)
        let before = selection
        let effect: ArrangeTrackClickEffect
        switch intent {
        case .replace:
            // m25-l-1 defect ②, USER RULING 2026-08-13: a PLAIN header click is a
            // CURSOR MOVE — it names `activeTrackID` (below, unconditionally) and
            // selects NOTHING. `clear()` rather than `replace(with: ids)`; it is
            // `replace(with: [])`'s degenerate case, spelled directly. The full
            // argument, including why clearing beat leaving the selection alone,
            // is in this file's banner.
            selection.clear()
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
        return ArrangeTrackClickOutcome(intent: intent, effect: effect, clipIDs: ids,
                                        changedSelection: selection != before,
                                        activeTrackID: track.id)
    }
}

/// WHICH branch a header click took. Raw values are stable strings so the
/// `debug.arrangeSelection {act:"clickTrack"}` seam can echo the decision verbatim
/// (the `ArrangeNudgeStepSource` / `TransportKeyDecision` convention) — a gate
/// that reads back only the resulting id set cannot tell "⇧ added 3" from
/// "⇧ found them already there and removed nothing".
public enum ArrangeTrackClickEffect: String, Equatable, Sendable {
    /// Plain click: the selection was RE-DECIDED wholesale rather than added to.
    ///
    /// ⚠️ Since m25-l-1 defect ② (USER RULING 2026-08-13) that re-decision is
    /// always **the empty set** — a plain header click is a cursor move and
    /// selects nothing. It used to mean "the selection became exactly this
    /// track's clips"; that behaviour now needs ⇧/⌘ and reports `.add`.
    ///
    /// **The case and its raw value `"replace"` are DELIBERATELY UNCHANGED.** The
    /// name comes from the shared chord table (`ArrangeClickIntent.replace` =
    /// "re-decide the whole selection"), which still describes it exactly; and the
    /// raw value is echoed verbatim by `debug.arrangeSelection`, where a rename
    /// would give every stale gate a second failure axis. See
    /// `ArrangeTrackSelection.apply`.
    case replace
    /// ⇧/⌘ and at least one of this track's clips was not selected: all added.
    case add
    /// ⇧/⌘ and every one of this track's clips was already selected: all removed.
    case remove
    /// ⇧/⌘ on a track with NO clips: nothing to add, nothing to remove. Distinct
    /// from `.remove` on purpose (see `ArrangeTrackSelection.apply`).
    case noClips = "no-clips"
}

/// One header click's answer: which chord rule fired, which branch it took, the
/// exact id set it acted on, and whether the selection actually moved.
///
/// `fileprivate init` (the `ArrangeDropSnap` / `ArrangeNudgeStep` model):
/// `ArrangeTrackSelection.apply` is the only producer in this file, so an
/// intent/effect/ids/changed QUADRUPLE the rule would not have produced is
/// UNREPRESENTABLE — no caller, and no test, can assemble one. That mattered
/// more once `changedSelection` joined (m23-an): a caller free to hand-build an
/// outcome could assert `changed: false` on a `.add`, which is a state the rule
/// cannot reach, and `ArrangeTrackClickFeedback` would then be documented
/// against a fiction.
public struct ArrangeTrackClickOutcome: Equatable, Sendable {
    /// From `ArrangeClickIntent.intent(for:)` — the shared chord table.
    public let intent: ArrangeClickIntent
    /// Which branch of `apply` ran.
    public let effect: ArrangeTrackClickEffect
    /// EXACTLY what `clipIDs(on:)` returned. Echoed by the seam rather than
    /// recomputed there, so the seam and the gesture can never disagree about
    /// what "this track's clips" means.
    ///
    /// ⚠️ IT IS "WHAT IS ON THE TRACK", NOT "WHAT THE CLICK ACTED ON" — the two
    /// were the same thing until m25-l-1 defect ②, and are not on the plain
    /// branch, which acts on nothing. `ArrangeTrackClickFeedback` reads it as a
    /// CLIP-COUNT PROXY (`isEmpty` == "this track has no clips"), which is why it
    /// is still populated for a plain click; `clipIDs(on:)`'s doc has the full
    /// note and the warning against emptying it.
    public let clipIDs: Set<UUID>
    /// Whether `apply` left the selection in a DIFFERENT state than it found it
    /// (m23-an). Measured by comparing the whole `ArrangeSelection` value before
    /// and after — so it covers the focus as well as the id set, which matters
    /// because a plain click can drop a focus (closing the piano roll) without
    /// changing `ids`… except it cannot: INV1 makes the focus a member of `ids`,
    /// so a focus change without an id change is unreachable. Comparing the whole
    /// value costs nothing and does not rely on that invariant holding forever.
    ///
    /// The full argument for why this is not the same question as `effect`, and
    /// why it is `true` unconditionally in three of four branches, is on
    /// `ArrangeTrackSelection.apply`.
    public let changedSelection: Bool

    /// The track this click makes ACTIVE — always the clicked track's id
    /// (m25-l-1). The full argument for why it is unconditional, non-optional,
    /// and set even on a chord / an empty track / a no-op click is on
    /// `ArrangeTrackSelection.apply`.
    ///
    /// It is a CURSOR, not a member of the selection: `clipIDs` above is what the
    /// click acts on, this is where the user now is. The two are deliberately
    /// separate fields because a zero-clip track has an empty `clipIDs` and a
    /// perfectly good `activeTrackID` — which is the entire m25-l-1 case.
    public let activeTrackID: UUID

    fileprivate init(intent: ArrangeClickIntent,
                     effect: ArrangeTrackClickEffect,
                     clipIDs: Set<UUID>,
                     changedSelection: Bool,
                     activeTrackID: UUID) {
        self.intent = intent
        self.effect = effect
        self.clipIDs = clipIDs
        self.changedSelection = changedSelection
        self.activeTrackID = activeTrackID
    }
}
