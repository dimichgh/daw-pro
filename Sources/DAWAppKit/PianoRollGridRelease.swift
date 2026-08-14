import Foundation

/// What releasing a no-travel press on the piano-roll note grid DOES (m25-o).
///
/// ═══════════════ WHY AN ENUM AND NOT A `Bool` ═══════════════
///
/// m25-o adds ONE arm to a surface that already had four, and the user who asked
/// for it named the hazard themselves: *"To avoid conflicts, we should position
/// playhead when user preses command button."* They were right, and the guard
/// they proposed needs one more term — **⌘-click already means "add/remove from
/// selection" here** (`ArrangeClickIntent.intent(for:) == .toggle`), so a bare
/// "⌘ ⇒ playhead" rule would silently destroy additive selection.
///
/// The resolution gates on the HIT TEST as well as the chord. Expressed as a
/// predicate (`placesPlayhead(...) -> Bool`) only the NEW arm would be testable,
/// and the three shipped arms would be pinned — if at all — by source-text site
/// tests, which is the vacuity trap this repo has already been bitten by twice.
/// Expressed as an exhaustive enum, all five arms are one behavioural truth
/// table, a mutation to any one of them reddens a real test, and `endGesture`'s
/// `switch` cannot double-fire two arms or silently drop one the way a chain of
/// `if` / `else if` can.
///
/// ⚠️ **THE CHORD IS READ AT RELEASE, NOT AT PRESS, AND THAT IS A DECISION.**
/// `gridDrag.onEnded` passes `.current`, so `modifiers` here is the chord at
/// mouse-UP. The alternative — the chord at press, which is what the CURSOR made
/// its promise with — was rejected because it cannot be adopted for the new arm
/// alone: with a press-time arm 1 and a release-time `deselect`, a press begun
/// without ⌘ and released with it matches NEITHER, and empty-grid deselect
/// (m25-m, a fix a human confirmed by hand days ago) silently disappears for
/// that chord. Adopting press-time for the WHOLE branch would change two shipped
/// arms, which is out of scope for this item. So: ONE chord source for all five
/// arms, exclusivity guaranteed by the `switch`. The cost, stated rather than
/// hidden — press on empty grid, then press ⌘ before lifting, and the transport
/// moves where a deselect was begun. It is narrow, it is recoverable (undo does
/// not even apply: a seek is not an edit), and it is the price of not
/// reintroducing m25-m's bug in a chord.
public enum PianoRollGridRelease: Equatable, Sendable {
    /// Plain click on a note: it becomes the whole selection.
    case selectOnly(UUID)
    /// ⇧/⌘ click on a note: add/remove it, leaving the rest alone. **This is the
    /// arm the user's anticipated conflict is about, and it is UNCHANGED** — ⌘
    /// over a note still toggles, and never places the playhead.
    case toggle(UUID)
    /// Plain click on empty grid: clear the selection (m25-m — the fix a human
    /// confirmed by hand, which this item must not break).
    case deselect
    /// ⌘ click on empty grid: seek the transport to the pointer's beat (m25-o).
    /// The one NEW arm, and it lands in a branch that did nothing at all before.
    case positionPlayhead
    /// ⇧ click on empty grid, with no ⌘: nothing, exactly as it has always done.
    ///
    /// ⚠️ **AN EXPLICIT CASE RATHER THAN A `default`, because it is the arm that
    /// documents what this item deliberately did NOT change.** `ArrangeClickIntent`
    /// maps ⇧ and ⌘ both to `.toggle`, so keying the new arm on the INTENT would
    /// have given ⇧-click-on-empty a transport jump too — a chord the user never
    /// asked about, held constantly for other reasons, and one where an
    /// accidental seek is pure surprise. So this is the ONE place the roll reads
    /// `.command` specifically rather than routing through the shared intent, and
    /// this case is why: the ⇧ half of that intent keeps the behaviour it shipped
    /// with. (⇧⌘ carries `.command` and therefore DOES place the playhead — the
    /// rule is "⌘ is present", not "⌘ alone".)
    case doNothing
}

/// The ONE mapping from *what was under the press* + *the chord* to what the
/// release does on the note grid.
///
/// Pure, headless, and in DAWAppKit for the `PianoRollHover` /
/// `PianoRollAutoScroll` reason: the roll's gesture POLICY has to be testable
/// without a pointer, because m23-g1 established that nothing in this tree can
/// produce a real one (an unbundled staging binary does not route pointer
/// events, so no `.mjs` gate can see this gesture at all).
public enum PianoRollGridPress {

    /// - Parameters:
    ///   - noteID: the note under the PRESS, or nil for empty grid. This is
    ///     exactly `activeDrag`'s `.click(UUID?)` payload, which is exactly
    ///     `model.hitTest(start)?.id` — so the predicate and the state machine
    ///     agree by construction rather than by two call sites matching.
    ///   - modifiers: the chord (see the release-time note on
    ///     `PianoRollGridRelease`).
    ///
    /// ⚠️ **`noteID == nil` COVERS THE GROUP-SCALE HANDLE BAND, DELIBERATELY.**
    /// A ⌘ press over the 12-pt band falls through to `.click(nil)`, so it
    /// arrives here with no note. Keying this on the hover TARGET (`== .empty`)
    /// instead would carve a dead stripe out of the grid — running the full
    /// height of the selection's bounding box — where the cursor promises a
    /// playhead and the click does nothing. "No note under the press" is the
    /// honest predicate, and it is the one the state machine already computes.
    ///
    /// ⭐ **m25-x MOVED THE GATE THAT MAKES THAT FALL-THROUGH HAPPEN, AND THE
    /// CONCLUSION SURVIVES THE MOVE.** This paragraph used to say `beginGesture`
    /// gates the handle on `!toggling`; it no longer does — `PianoRollHover.target`
    /// now refuses to RETURN `.groupScaleHandle` under a toggling chord, which is
    /// what stopped the glowing bar from advertising a scale this release would
    /// never perform. The routing is unchanged (a ⌘ press over the band still
    /// reaches `.click(nil)` and still returns `.positionPlayhead`), and target
    /// and `noteID` now actually AGREE there. They still disagree for a PLAIN
    /// press over the band — `noteID` is nil while the target is the handle — but
    /// that press becomes `activeDrag = .groupScale` and never reaches this
    /// function at all, so the divergence is unreachable rather than tolerated.
    public static func release(noteID: UUID?,
                               modifiers: ArrangeClickModifiers) -> PianoRollGridRelease {
        let toggling = ArrangeClickIntent.intent(for: modifiers) == .toggle
        if let noteID {
            return toggling ? .toggle(noteID) : .selectOnly(noteID)
        }
        if modifiers.contains(.command) { return .positionPlayhead }
        return toggling ? .doNothing : .deselect
    }

    /// Whether a press with this chord, over this hit, would place the playhead.
    ///
    /// ⭐ **DERIVED FROM `release`, never a second condition.** This is what the
    /// CURSOR asks, and the roll's standing rule is that "the affordance the
    /// surface ADVERTISES and the gesture it PERFORMS cannot disagree, because
    /// they are the same answer" (`PianoRollHover`'s one-resolver argument). Two
    /// independently-written conditions is how a surface ends up promising a
    /// playhead and delivering a deselect.
    public static func placesPlayhead(noteID: UUID?,
                                      modifiers: ArrangeClickModifiers) -> Bool {
        release(noteID: noteID, modifiers: modifiers) == .positionPlayhead
    }
}
