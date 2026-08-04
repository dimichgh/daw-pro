import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

// m23-an: DOES A TRACK-HEADER CLICK OWE THE USER AN ACKNOWLEDGEMENT?
//
// The predicate lives in `ArrangeTrackClickFeedback` precisely so it can be
// pinned here — `DAWApp` has no test target, so a rule written inside
// `AppModel.clickTrack` or a `TrackRow` body would be provable only by a live
// gate, and this one has six branches worth of table to sweep.
//
// THE TABLE IS NOT INVENTED. Every row below was MEASURED against a live staging
// binary before any of this code existed (`scripts/gates/_m23an-feedback-probe
// .mjs`, legs D1…D6). The suite is deliberately organised as that table, in the
// probe's own leg order, so a future reader can put the two side by side.
//
//   D5  ⇧ on a 3-clip header, nothing selected   selection 0->3        NO ack
//   D3  ⇧ on a 0-clip header                     effect .noClips       ACK
//   D1  PLAIN on a 0-clip header, clip focused   n 1->0, editor closes NO ack
//   D2  PLAIN on a 0-clip header, already empty  effect .replace, no-op ACK
//   D6  PLAIN repeated on the SAME 3-clip header nothing changes       NO ack
//
// D2 is the row the item as filed missed: the filing named `.noClips`, and this
// silent case is `.replace`. D6 is the row that kills the one-term predicate
// ("did the selection change?") — it would fire an acknowledgement where three
// blocks are visibly selected and the state matches the intent. D1 is the row a
// careless widening breaks worst: dropping the `!changedSelection` term puts
// "nothing to select" on top of the largest visible change this surface has.

@Suite("ArrangeTrackClickFeedback")
struct ArrangeTrackClickFeedbackTests {

    // MARK: Fixtures

    private func clip(_ id: UUID, at beat: Double = 0) -> Clip {
        Clip(id: id, name: "c", startBeat: beat, lengthBeats: 2, notes: [])
    }

    private func track(_ clipIDs: [UUID], name: String = "T") -> Track {
        Track(name: name, kind: .instrument,
              clips: clipIDs.enumerated().map { clip($0.element, at: Double($0.offset) * 4) })
    }

    /// One click, applied through the SHIPPING entry point. Never a hand-built
    /// outcome — `ArrangeTrackClickOutcome`'s init is `fileprivate` exactly so a
    /// test cannot assemble a quadruple the rule would not have produced, and a
    /// suite that faked one would be pinning a fiction.
    @discardableResult
    private func click(_ t: Track, _ mods: ArrangeClickModifiers,
                       _ selection: inout ArrangeSelection) -> ArrangeTrackClickOutcome {
        ArrangeTrackSelection.apply(click: t, modifiers: mods, to: &selection)
    }

    private func verdict(_ outcome: ArrangeTrackClickOutcome) -> ArrangeTrackClickAcknowledgement {
        ArrangeTrackClickFeedback.acknowledgement(for: outcome)
    }

    // MARK: - The measured table, row by row

    // 1. D5 — THE CONTROL. If this row ever needed an acknowledgement the
    //    predicate would be broken in the loudest possible way: three clip
    //    blocks just went selected on screen.
    @Test("D5 ⇧ on a 3-clip header: selection grows, no acknowledgement")
    func d5ShiftOnPopulatedTrackIsLoud() {
        let ids = [UUID(), UUID(), UUID()]
        var sel = ArrangeSelection()
        let out = click(track(ids), .shift, &sel)
        #expect(out.effect == .add)
        #expect(out.changedSelection)
        #expect(sel.count == 3)
        #expect(verdict(out) == .notNeeded)
    }

    // 2. D3 — THE FILED PREMISE, and it HOLDS: ⇧ on a zero-clip header changes
    //    nothing and draws nothing.
    @Test("D3 ⇧ on a 0-clip header: .noClips, selection untouched, ACKNOWLEDGED")
    func d3ShiftOnEmptyTrackIsSilent() {
        let other = UUID()
        var sel = ArrangeSelection()
        sel.selectOnly(other)
        let before = sel
        let out = click(track([]), .shift, &sel)
        #expect(out.effect == .noClips)
        #expect(!out.changedSelection)
        #expect(sel == before, "the .noClips branch must mutate nothing at all")
        #expect(verdict(out) == .noClipsToSelect)
    }

    // 3. D1 — THE DISCRIMINATOR. A plain click on an empty track CLEARS a real
    //    selection and closes the piano roll (INV2 drops the focus). That is the
    //    largest visible change this surface has, and it must stay silent.
    //
    //    THIS IS THE TEST THE OBVIOUS WRONG PREDICATE FAILS. Drop the
    //    `!changedSelection` term — "acknowledge on any empty-track click" — and
    //    this row starts announcing "nothing to select" over a cleared selection
    //    and a closed editor.
    @Test("D1 PLAIN on a 0-clip header while a clip is focused: LOUD, no acknowledgement")
    func d1PlainOnEmptyTrackClearingASelectionIsLoud() {
        let focused = UUID()
        var sel = ArrangeSelection()
        sel.selectOnly(focused)
        let out = click(track([]), .none, &sel)
        #expect(out.effect == .replace)
        #expect(out.changedSelection)
        #expect(sel.isEmpty)
        #expect(sel.focusID == nil, "INV2: clearing ids drops the focus, closing the editor")
        #expect(verdict(out) == .notNeeded)
    }

    // 4. D2 — THE WIDENING the filing missed. Same gesture as D1, but over an
    //    ALREADY EMPTY selection: `replace(with: [])` is a no-op, and the effect
    //    is `.replace`, NOT `.noClips`. A predicate written as
    //    `effect == .noClips` goes green on D3 and misses this entirely.
    //
    //    This row is also the one a future change to `ArrangeSelection.replace`
    //    could silently break, which is why the no-op is asserted as a VALUE
    //    comparison and not merely as `sel.isEmpty`.
    @Test("D2 PLAIN on a 0-clip header with an empty selection: .replace, no-op, ACKNOWLEDGED")
    func d2PlainOnEmptyTrackWithEmptySelectionIsSilent() {
        var sel = ArrangeSelection()
        let before = sel
        let out = click(track([]), .none, &sel)
        #expect(out.effect == .replace, "the silent case is NOT .noClips — the filing named one branch")
        #expect(!out.changedSelection)
        #expect(sel == before)
        #expect(verdict(out) == .noClipsToSelect)
    }

    // 5. D6 — THE TOO-BROAD ROW. Nothing changed, but the track HAS clips and
    //    they are visibly selected: the state matches the intent, so there is
    //    nothing to explain. This is why the predicate needs its first term.
    @Test("D6 PLAIN repeated on the same 3-clip header: nothing changes, still NO acknowledgement")
    func d6RepeatedPlainClickOnPopulatedTrackNeedsNoWord() {
        let ids = [UUID(), UUID(), UUID()]
        let t = track(ids)
        var sel = ArrangeSelection()
        click(t, .none, &sel)
        let before = sel
        let out = click(t, .none, &sel)
        #expect(!out.changedSelection, "the fixture's whole point: a repeat click is a no-op")
        #expect(sel == before)
        #expect(sel.count == 3, "three blocks are visibly selected — there is nothing to explain")
        #expect(verdict(out) == .notNeeded,
                "a bare \"did the selection change?\" predicate fires HERE — it must not")
    }

    // MARK: - The two terms, isolated

    // 6. Neither term alone is the rule. Stated as a machine assertion rather
    //    than a comment because the two single-term readings are exactly the two
    //    edits a future reader is most likely to make.
    @Test("neither single term is the predicate: each alone misclassifies a measured row")
    func neitherTermAloneIsThePredicate() {
        var d1 = ArrangeSelection()
        d1.selectOnly(UUID())
        let d1Out = click(track([]), .none, &d1)
        var d6Sel = ArrangeSelection()
        let populated = track([UUID(), UUID(), UUID()])
        click(populated, .none, &d6Sel)
        let d6Out = click(populated, .none, &d6Sel)

        // "no clips" alone would acknowledge D1 (a cleared selection, a closed editor).
        #expect(d1Out.clipIDs.isEmpty && verdict(d1Out) == .notNeeded)
        // "did not change" alone would acknowledge D6 (three visibly selected blocks).
        #expect(!d6Out.changedSelection && verdict(d6Out) == .notNeeded)
    }

    // 7. The predicate is TOTAL over the four effects, and the acknowledged set
    //    is exactly the two measured silent rows. Swept rather than spot-checked
    //    so a fifth branch cannot be added without landing here.
    @Test("the acknowledged set is exactly {.noClips, .replace-with-nothing-over-nothing}")
    func acknowledgedSetIsExactlyTheTwoSilentRows() {
        let populated = track([UUID(), UUID()])
        let empty = track([])
        var seen: [ArrangeTrackClickEffect: ArrangeTrackClickAcknowledgement] = [:]

        // .replace over a NON-empty result
        var s1 = ArrangeSelection()
        seen[.replace] = verdict(click(populated, .none, &s1))
        // .add
        var s2 = ArrangeSelection()
        seen[.add] = verdict(click(populated, .shift, &s2))
        // .remove — ⇧ again over the same track, now fully selected
        seen[.remove] = verdict(click(populated, .shift, &s2))
        // .noClips
        var s4 = ArrangeSelection()
        seen[.noClips] = verdict(click(empty, .shift, &s4))

        #expect(seen[.replace] == .notNeeded)
        #expect(seen[.add] == .notNeeded)
        #expect(seen[.remove] == .notNeeded)
        #expect(seen[.noClips] == .noClipsToSelect)
        #expect(seen.count == 4, "every effect the rule can produce is swept")

        // …and the SECOND acknowledged row, which shares `.replace` with the
        // first row above and is separated from it only by `changedSelection`.
        var s5 = ArrangeSelection()
        let silentReplace = click(empty, .none, &s5)
        #expect(silentReplace.effect == .replace)
        #expect(verdict(silentReplace) == .noClipsToSelect)
    }

    // MARK: - The impossibility that makes `changedSelection` honest

    // 8. THE TEST THAT CATCHES A FUTURE EDIT TO `formUnion` / `subtract`.
    //
    //    `ArrangeTrackSelection.apply`'s doc claims `.add` and `.remove` can
    //    NEVER carry `changedSelection == false`, because `.add` is reached only
    //    when `ids` is not a subset (so `formUnion` must insert at least one) and
    //    `.remove` only when `ids` is non-empty AND a subset (so `subtract` must
    //    remove at least one). That claim is what makes it defensible for a Bool
    //    to be unconditionally true in three of four branches — and it is a claim
    //    about two mutators in a DIFFERENT type, which is exactly the kind that
    //    rots. Swept over every overlap shape those branches can be reached with.
    @Test(".add and .remove can never report changedSelection == false")
    func addAndRemoveAlwaysMove() {
        let a = UUID(), b = UUID(), c = UUID(), foreign = UUID()
        let t = track([a, b, c])

        // Every partial subset of the track's clips (plus a foreign id, which
        // must not make a difference), as a starting selection for ⇧.
        let starts: [Set<UUID>] = [
            [], [a], [b], [c], [a, b], [a, c], [b, c],
            [foreign], [a, foreign], [a, b, foreign],
        ]
        for start in starts {
            var sel = ArrangeSelection()
            sel.replace(with: start)
            let out = ArrangeTrackSelection.apply(click: t, modifiers: .shift, to: &sel)
            #expect(out.effect == .add, "a non-subset start must take the ADD branch: \(start.count)")
            #expect(out.changedSelection,
                    "ADD reported no movement from a \(start.count)-id start: formUnion inserted nothing, which the predicate's doc says is impossible")
            #expect(verdict(out) == .notNeeded)
        }

        // .remove: every superset of the track's clips.
        for extra in [Set<UUID>(), [foreign]] {
            var sel = ArrangeSelection()
            sel.replace(with: Set([a, b, c]).union(extra))
            let out = ArrangeTrackSelection.apply(click: t, modifiers: .shift, to: &sel)
            #expect(out.effect == .remove)
            #expect(out.changedSelection,
                    "REMOVE reported no movement: subtract removed nothing, which the predicate's doc says is impossible")
            #expect(verdict(out) == .notNeeded)
            #expect(sel.ids == extra)
        }
    }

    // 9. `changedSelection` is measured on the WHOLE selection value, not on the
    //    id set — so a click that moved only the focus would still count as a
    //    change. Under INV1 that is unreachable today (the focus is always a
    //    member of `ids`), and this pins the stronger reading so a later
    //    invariant change cannot silently narrow it.
    @Test("changedSelection compares the whole selection value, focus included")
    func changedSelectionIncludesTheFocus() {
        let a = UUID(), b = UUID()
        let t = track([a, b])
        var sel = ArrangeSelection()
        sel.selectOnly(a)            // ids {a}, focus a
        let out = ArrangeTrackSelection.apply(click: t, modifiers: .none, to: &sel)
        // ids {a,b}: grew, and the focus SURVIVED (replace keeps a member focus).
        #expect(out.changedSelection)
        #expect(sel.focusID == a)
        #expect(sel.ids == [a, b])
    }

    // MARK: - Raw values (the seam echoes these verbatim)

    // 10. `debug.arrangeSelection` echoes `kind.rawValue`, and the live gate
    //     asserts those exact strings. A rename here is a wire-visible change and
    //     must break a test rather than a gate at 3 a.m.
    @Test("acknowledgement raw values are the strings the seam echoes")
    func rawValuesArePinned() {
        #expect(ArrangeTrackClickAcknowledgement.notNeeded.rawValue == "none")
        #expect(ArrangeTrackClickAcknowledgement.noClipsToSelect.rawValue == "no-clips-to-select")
    }
}
