import Foundation
import DAWCore

/// The ONE home for the question "would an AUTOMATION LANE EDITOR have consumed
/// this keystroke?", plus the debug-tier seam that lets a gate put a lane into
/// the state where it would.
///
/// WHY THIS EXISTS (m23-ai). The arrange's arrow-key nudge (m23-x) moves the
/// selected CLIPS, and nothing anywhere in the app consumes ← / → except that
/// one ancestor mount in `ContentView`'s `ArrangeDeleteKey`. So with an
/// automation lane open and a breakpoint selected, pressing ← meaning "nudge
/// this point" slides the whole clip underneath the user instead — the exact
/// surprise m23-x's fifth guard removed for the piano roll. The roll's half was
/// closed then; this lane's half was deliberately scoped out and is closed here.
///
/// THE RULE THIS ENCODES IS THE EDITOR'S OWN, NOT A NEW ONE.
/// `AutomationLaneEditor`'s DELETE handler already reads:
///
///     private func deleteSelection() -> KeyPress.Result {
///         guard let index = selection, draft.indices.contains(index) else { return .ignored }
///
/// — it consumes the key only when it HAS A LIVE BREAKPOINT SELECTION, and
/// otherwise lets it fall through so the arrange acts on the clip. The faithful
/// mirror of that for arrows is "refuse when the editor would have consumed it",
/// i.e. some lane holds a selection — not "refuse while a lane is focused". That
/// is the lesson m23-x paid for twice (see `PianoRollNoteSelectionBridge`, whose
/// doc comment records the measurements): a raw SwiftUI focus flag is not a
/// function of what the user is doing. It reads 6 true / 6 false over 12
/// consecutive selections of DIFFERENT clips, so a guard carrying it would let
/// the clip slide every OTHER time — an intermittent version of the bug being
/// fixed. ⚠️ CORRECTED AT m23-al-1 (2026-08-03): this comment used to attribute
/// that to `.id()`-keyed REBUILDS, and that attribution was FALSIFIED by
/// measurement. The flag also flips on REPEAT clicks, where the `.id()` is
/// unchanged and neither `.onAppear` nor `.onDisappear` runs at all; over 12
/// clicks on ONE clip it reads `true` exactly ONCE and `false` eleven times.
/// So the guard-carrying failure is worse than "every other time": after a
/// repeat click it would slide EVERY time. The conclusion here is unchanged and
/// strengthened — focus is not a term.
/// `AutomationLaneEditor` has its own `@FocusState private var focused`; it is
/// deliberately still private and still unreported. Focus is not a term here.
///
/// WHY A SET OF LANE IDS AND NOT A `Bool` — THE DESIGN-DECIDING DIFFERENCE FROM
/// THE ROLL. The piano roll has exactly ONE editor instance on screen, which is
/// why `PianoRollNoteSelectionBridge.hasSelection` can be a plain `Bool`. This
/// editor is mounted N TIMES: `TimelineLanesView.automationLanes` mounts one per
/// EXPANDED TRACK inside a `ForEach`, and `MixerStripView` mounts one more for
/// the master lane. A `Bool` would be last-writer-wins and broken by
/// construction. Two concrete failures it would have shipped:
///
///  1. TWO EXPANDED TRACKS. Lane A holds a selected breakpoint and reports
///     `true`; lane B, which the user never touched, reports `false` on its own
///     `initial: true` pass. The flag lands on `false`, the guard goes dead, and
///     ← slides the clip out from under the point the user is editing — the
///     original bug, now with a guard in the way that looks like it works.
///  2. A LANE-TARGET SWITCH. Both mounts carry `.id(lane.id)`, so changing a
///     track's automation target TEARS DOWN one instance and builds another.
///     The incoming instance's `.onChange(…, initial: true)` and the outgoing
///     instance's `.onDisappear` then race, and the loser is whichever SwiftUI
///     runs second — structurally the SAME race that makes
///     `pianoRollEditorFocused` alternate. Keyed by lane id there is no race to
///     lose: incoming B writes B's key, outgoing A removes A's key.
///
/// So the state is a SET and every mutation names its lane. `clear(lane:)`
/// likewise removes one key: a bare `clear()` would let one closing lane cancel
/// a different lane's live claim, which is failure (1) again by another route.
///
/// WHAT THIS SHAPE COSTS, HONESTLY. The guard reads only "is the set empty", so
/// a lane whose `.onDisappear` never runs latches its id forever and the arrange
/// arrow keys die for the rest of the session with nothing on screen to explain
/// why — strictly worse than the bug this exists to fix. A second guard term
/// ("…and that lane still exists in the store") would blunt it, and is
/// deliberately NOT added: m23-x shipped exactly such a belt-and-braces term
/// (`openEditorClip != nil`) and had to document that deleting it reddens
/// nothing, which is how an untested term hides inside a tested guard. The
/// exposure is written down here instead so a future bug report has somewhere to
/// land.
///
/// WHY A BRIDGE OBJECT rather than flags on `AppModel`: the state has to be
/// REPORTED OUT of a view whose `selection`/`draft` are `@State private` (so
/// nothing outside can read them), and the staging seam has to reach INTO those
/// same private fields. Both directions, one subject, one file — the
/// `FollowPlayheadModel.externalScrollNonce` pattern, copied through
/// `PianoRollNoteSelectionBridge`.
@MainActor
@Observable
public final class AutomationPointSelectionBridge {

    /// REPORTED BY THE EDITORS. The ids of every mounted automation lane that
    /// currently holds a live breakpoint selection — i.e. every lane whose own
    /// `.onKeyPress` would claim a keystroke rather than let it fall through to
    /// the arrange. Empty means the arrange owns ← / →.
    ///
    /// Reported from `.onChange(of:initial:)`, never from `body`: this gates a
    /// keyboard path, so it must be an observable transition (the same reason
    /// `PianoRollView` reports its note selection that way).
    public private(set) var lanesWithSelection: Set<AutomationLane.ID> = []

    /// STAGED FOR THE EDITORS by `debug.arrangeSelection {act:"automationPoints"}`.
    /// The views watch the nonce, so re-staging the same intent still applies
    /// (the `externalScrollNonce` reason: a gate must be able to ask twice).
    public private(set) var stageNonce = 0
    /// What the staged event asks for: select a breakpoint, or none. Applied by
    /// EVERY mounted editor watching the nonce — there is no per-lane staging,
    /// because the guard asks "is any lane claiming", not "which one".
    @ObservationIgnored public private(set) var stagedSelect = false

    public init() {}

    /// One lane's report. Idempotent — the views call it with `initial: true`,
    /// and only ever about themselves.
    public func report(lane: AutomationLane.ID, hasSelection: Bool) {
        if hasSelection {
            lanesWithSelection.insert(lane)
        } else {
            lanesWithSelection.remove(lane)
        }
    }

    /// Stage a breakpoint selection into every automation lane editor on screen.
    public func stage(select: Bool) {
        stagedSelect = select
        stageNonce += 1
    }

    /// THIS LANE'S EDITOR WENT AWAY. Called from `.onDisappear`, and
    /// load-bearing: an id left latched after its editor closed would kill the
    /// arrange's arrow keys with nothing on screen to explain why.
    ///
    /// ONE KEY, NEVER THE WHOLE SET. A lane closing says nothing about the
    /// lanes still on screen, and a `removeAll()` here would silently cancel
    /// another lane's live claim — the clobber this type exists to prevent.
    public func clear(lane: AutomationLane.ID) {
        lanesWithSelection.remove(lane)
    }
}
