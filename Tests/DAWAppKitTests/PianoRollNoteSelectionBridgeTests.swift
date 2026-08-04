import Foundation
import Testing
@testable import DAWAppKit

/// The headless half of the arrow-key nudge's FIFTH guard (m23-x, second pass).
///
/// WHAT IS REACHABLE HERE AND WHAT IS NOT. The bridge itself is a plain
/// `@Observable` in DAWAppKit, so its state machine — report, stage, clear, and
/// the nonce that makes a repeated stage still apply — is unit-testable. What is
/// NOT reachable: `PianoRollView`'s `.onChange` wiring that calls `report`, the
/// `.onDisappear` that calls `clear`, and `AppModel.handleArrangeNudgeKey`'s
/// `pianoRollEditorFocused && hasSelection` predicate all live in DAWApp, which
/// has no test target. Those are proven by the staging gate's N9 legs
/// (`scripts/gates/m23x-arrow-nudge.mjs`) against a real running app.
///
/// So: these tests pin the CONTRACT the view depends on. If one of them goes
/// red, the gate's N9 legs are the ones that will tell you what broke on screen.
@MainActor
@Suite("Piano-roll note-selection bridge (m23-x)")
struct PianoRollNoteSelectionBridgeTests {

    @Test("a fresh bridge claims nothing — the arrange owns the arrows until the roll says otherwise")
    func startsUnclaimed() {
        let bridge = PianoRollNoteSelectionBridge()
        #expect(bridge.hasSelection == false)
        #expect(bridge.stageNonce == 0)
    }

    @Test("report round-trips both ways")
    func reportRoundTrips() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.report(hasSelection: true)
        #expect(bridge.hasSelection == true)
        bridge.report(hasSelection: false)
        #expect(bridge.hasSelection == false)
    }

    @Test("report is idempotent — the view calls it with initial: true on every appear")
    func reportIsIdempotent() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.report(hasSelection: true)
        bridge.report(hasSelection: true)
        #expect(bridge.hasSelection == true)
        // And the nonce is untouched by reporting: a report must never look
        // like a staged request, or the roll would re-apply a selection every
        // time it told the app what it already had.
        #expect(bridge.stageNonce == 0)
    }

    @Test("clear() drops the claim — the anti-latch rule")
    func clearDropsTheClaim() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.report(hasSelection: true)
        bridge.clear()
        // This is the one that matters most: a bridge left claiming `true`
        // after the editor closed would kill the arrange's arrow keys for the
        // rest of the session, with nothing on screen to explain why.
        #expect(bridge.hasSelection == false)
    }

    @Test("staging bumps the nonce EVERY time, including for the same intent")
    func stagingAlwaysBumpsTheNonce() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        #expect(bridge.stageNonce == 1)
        #expect(bridge.stagedSelectAll == true)
        // The `follow.externalScrollNonce` rule: a gate must be able to ask for
        // the SAME state twice and still have the view apply it. If this only
        // bumped on a change, the second ask would be silently dropped and a
        // leg that re-staged after an intervening edit would test nothing.
        bridge.stage(selectAll: true)
        #expect(bridge.stageNonce == 2)
        #expect(bridge.stagedSelectAll == true)
        bridge.stage(selectAll: false)
        #expect(bridge.stageNonce == 3)
        #expect(bridge.stagedSelectAll == false)
    }

    @Test("staging does NOT itself set hasSelection — only the roll's report can")
    func stagingDoesNotForgeTheReport() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        // If `stage` set `hasSelection` directly, the gate's N9d leg would pass
        // against a bridge that never reached the roll at all — the guard would
        // be verified against the gate's own input instead of the app's state.
        // The value must come back FROM the view's `.onChange(of:)`.
        #expect(bridge.hasSelection == false)
        bridge.report(hasSelection: true)
        #expect(bridge.hasSelection == true)
    }

    @Test("clear() leaves the staging channel alone")
    func clearDoesNotDisturbStaging() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        let nonce = bridge.stageNonce
        bridge.clear()
        // `clear` means "the roll went away", not "cancel the request". Bumping
        // or resetting the nonce here would make an unmount look like a fresh
        // staged event to the next roll that appears.
        #expect(bridge.stageNonce == nonce)
        #expect(bridge.stagedSelectAll == true)
    }

    // MARK: - m23-ak: the widened-selection drop

    @Test("dropForWidenedArrangeSelection bumps the nonce and asks for the EMPTY state")
    func widenedDropStagesTheEmptyState() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        let nonce = bridge.stageNonce
        bridge.dropForWidenedArrangeSelection()
        // The nonce is the whole delivery mechanism — `PianoRollView` watches it
        // and routes `stagedSelectAll == false` to `model.clearSelection()`. A
        // verb that changed `stagedSelectAll` without bumping would be a silent
        // no-op on screen.
        #expect(bridge.stageNonce == nonce + 1)
        #expect(bridge.stagedSelectAll == false)
    }

    @Test("the drop repeats — a marquee fires it on every pointer update")
    func widenedDropIsRepeatable() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.dropForWidenedArrangeSelection()
        bridge.dropForWidenedArrangeSelection()
        // Same rule as `stage`: the nonce must advance even when the intent is
        // unchanged, or a second ask is dropped. A rubber-band drag re-decides
        // the whole selection on every update, so this genuinely repeats.
        #expect(bridge.stageNonce == 2)
        #expect(bridge.stagedSelectAll == false)
    }

    @Test("the drop does NOT forge the report — only the roll can say what it holds")
    func widenedDropDoesNotForgeTheReport() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.report(hasSelection: true)
        bridge.dropForWidenedArrangeSelection()
        // The same rule `stage` follows. `hasSelection` must come back FROM the
        // view's `.onChange(of: model.selection.isEmpty)`; writing it here would
        // make the app's own guard read a value the app invented, and the gate's
        // "provably cleared, not merely suppressed" leg would pass against a roll
        // that still had every note selected.
        #expect(bridge.hasSelection == true)
    }
}

/// The m23-ak PREDICATE — deliberately in its own, NON-`@MainActor` suite.
///
/// That is a structural claim, not a style choice: `shouldDropNotes` is
/// `nonisolated` and takes both endpoints by value, so it is decidable with no
/// app, no view and no actor. If someone later reaches for `AppModel` inside it
/// (say, to ask whether a roll is really open), this suite stops compiling —
/// which is the point.
@Suite("Widened-arrange-selection note drop (m23-ak)")
struct WidenedArrangeSelectionDropTests {

    /// One clip, focused — the shape the roll is actually open on.
    private func single(_ id: UUID = UUID()) -> ArrangeSelection {
        var s = ArrangeSelection()
        s.selectOnly(id)
        return s
    }

    /// `n` clips WITH a focus, built the way the app builds one: a plain click
    /// then shift-clicks. INV1 holds, so this is the state the predicate's
    /// "count > 1 means ids ⊋ {focusID}" argument is about.
    private func group(_ n: Int) -> ArrangeSelection {
        var s = ArrangeSelection()
        s.selectOnly(UUID())
        for _ in 1..<max(n, 1) { s.toggle(UUID()) }
        return s
    }

    /// `n` clips with NO focus — what `replace(with:)` leaves behind when the old
    /// focus is not in the new set (a rubber band has no anchor clip).
    ///
    /// Both fixtures matter and neither is redundant: the predicate is pure
    /// cardinality, so it must answer the same for both. That is also the thing
    /// to revisit first if anyone ever tightens it to name the focus — these
    /// focus-less cases would need a decision, and today they do not.
    private func bandOf(_ n: Int) -> ArrangeSelection {
        var s = ArrangeSelection()
        s.replace(with: Set((0..<n).map { _ in UUID() }))
        return s
    }

    @Test("THE TRANSITION MATRIX")
    func transitionMatrix() {
        let a = UUID(), b = UUID()
        // 0 -> 1: the ordinary "click one clip". The roll OPENS here; dropping
        // anything would be dropping a selection the user never made.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: ArrangeSelection(), to: single(a)) == false)
        // 1 -> 1: clicking a DIFFERENT single clip. The roll is rebuilt on the
        // new id with a fresh model, so there is nothing to drop.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: single(a), to: single(b)) == false)
        // 1 -> 3: THE BUG. Notes selected, then two more clips shift-clicked.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: single(a), to: group(3)) == true)
        // 3 -> 3: a group that changes membership without changing size — e.g.
        // a marquee sweeping off one clip and onto another in the same update.
        // No crossing, so no drop: see 0 -> 2 below for why this is a transition.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: group(3), to: group(3)) == false)
        // 3 -> 1: NARROWING. Nothing to drop, and this is the direction the
        // gate's "provably cleared, not suppressed" leg runs: the notes must
        // stay gone because the MODEL was cleared, not because this said so.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: group(3), to: single(a)) == false)
        // 0 -> 2: a bare marquee sweeping two clips from nothing. `<=`, not
        // `==`, so the rule is stated once. No roll is open at 0, so the drop it
        // triggers is inert — the cost of one nonce bump for one stated rule.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: ArrangeSelection(), to: group(2)) == true)
    }

    @Test("the crossing is 1 -> 2, not 2 -> 3 — a group already wide does not re-drop")
    func firesOnceOnTheCrossing() {
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: single(), to: group(2)) == true)
        // THE DOCUMENTED CONSEQUENCE, pinned: with the selection already wide, a
        // user who DELIBERATELY selects notes again keeps them, and the nudge
        // refuses again. Their intent is plainly the notes at that point — they
        // asked for them with the wide selection already on screen. If this ever
        // becomes `true`, the roll would be arguing with the user on every
        // further shift-click.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: group(2), to: group(3)) == false)
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: group(3), to: group(4)) == false)
    }

    @Test("cardinality alone decides it — a focus-less band answers identically")
    func focusIsNotATerm() {
        // `replace(with:)` drops the focus when it is not in the new set, so a
        // rubber band routinely produces a multi-selection with `focusID == nil`.
        // The predicate must not care: under INV1, `count > 1` with a roll open
        // ALREADY means "a selected clip that is not the one being edited", and
        // naming the focus could only restate the invariant or disagree with it.
        #expect(bandOf(3).focusID == nil)
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: single(), to: bandOf(3)) == true)
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: bandOf(3), to: bandOf(2)) == false)
        // And an EMPTY selection is never a growth target, however it was reached
        // (`clear`, or a band that swept nothing). The roll unmounts there and
        // `.onDisappear` already drops the claim — this must not double up.
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: group(3), to: ArrangeSelection()) == false)
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(
            from: single(), to: ArrangeSelection()) == false)
    }

    @Test("every growth MUTATOR crosses it — toggle, replace and formUnion")
    func allThreeGrowthPathsCross() {
        // The predicate reads the RESULTING STATE, which is what makes it
        // gesture-agnostic. Driving each mutator here is what proves that claim
        // rather than asserting it: a "did ids gain a member" reading would miss
        // `replace`, and a shift-click-only reading would miss both bands.
        let anchor = UUID()
        let before = single(anchor)

        var byToggle = before                       // shift/⌘-click
        byToggle.toggle(UUID())
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(from: before, to: byToggle) == true)

        var byReplace = before                      // plain marquee, and the
        byReplace.replace(with: [UUID(), UUID()])   // track-header click
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(from: before, to: byReplace) == true)

        var byUnion = before                        // additive marquee
        byUnion.formUnion([UUID(), UUID()])
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(from: before, to: byUnion) == true)

        // `apply(click:modifiers:)` is the entry point the tap handler AND the
        // debug seam share, so the shipped shift-click really does route here.
        var byApply = before
        byApply.apply(click: UUID(), modifiers: .shift)
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(from: before, to: byApply) == true)
        // ...and a plain click does not: it REPLACES with one clip, which is a
        // clip switch, not a widening.
        var plain = before
        plain.apply(click: UUID(), modifiers: .none)
        #expect(PianoRollNoteSelectionBridge.shouldDropNotes(from: before, to: plain) == false)
    }
}
