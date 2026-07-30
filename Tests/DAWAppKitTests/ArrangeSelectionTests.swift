import Foundation
import Testing
@testable import DAWAppKit

// m23-g1: the arrange's clip selection — the set, the focus, and the invariants
// that keep the two coherent. Headless, so every branch of the focus rule is
// pinned without a window.

@Suite("ArrangeSelection")
struct ArrangeSelectionTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    /// INV1: a non-nil focus is always a member. INV2: an empty set has no focus.
    /// Checked after every mutation in every test below.
    private func expectInvariants(_ s: ArrangeSelection, _ where_: String = #function) {
        if let focus = s.focusID {
            #expect(s.contains(focus), "INV1 violated in \(where_)")
        }
        if s.isEmpty {
            #expect(s.focusID == nil, "INV2 violated in \(where_)")
        }
    }

    // 1.
    @Test("a fresh selection is empty and unfocused")
    func empty() {
        let s = ArrangeSelection()
        #expect(s.isEmpty)
        #expect(s.count == 0)
        #expect(s.focusID == nil)
        #expect(!s.contains(a))
        expectInvariants(s)
    }

    // 2. THE PRE-g1 BEHAVIOUR, pinned: a plain click is a fresh single selection.
    @Test("selectOnly replaces the whole selection and takes focus")
    func selectOnly() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.toggle(b)
        #expect(s.count == 2)

        s.selectOnly(c)
        #expect(s.ids == [c])
        #expect(s.focusID == c)
        expectInvariants(s)
    }

    // 3. The `selectedClipID` mirror's two writes, which is the whole
    //    compatibility argument for ~19 pre-g1 call sites.
    @Test("focus(id) is selectOnly and focus(nil) clears everything")
    func focusMirror() {
        var s = ArrangeSelection()
        s.focus(a)
        #expect(s.ids == [a])
        #expect(s.focusID == a)

        s.toggle(b)
        s.focus(nil)
        #expect(s.isEmpty)
        #expect(s.focusID == nil)
        expectInvariants(s)
    }

    // 4. TOGGLE, BOTH DIRECTIONS — the shift/⌘-click contract.
    @Test("toggle adds then removes the same clip")
    func toggleRoundTrip() {
        var s = ArrangeSelection()
        s.selectOnly(a)

        s.toggle(b)
        #expect(s.ids == [a, b])
        expectInvariants(s)

        s.toggle(b)
        #expect(s.ids == [a])
        expectInvariants(s)
    }

    // 5. FOCUS RULE branch 1: adopted when there is none.
    @Test("toggling into an EMPTY selection adopts the focus")
    func toggleAdopts() {
        var s = ArrangeSelection()
        s.toggle(a)
        #expect(s.ids == [a])
        #expect(s.focusID == a)
        expectInvariants(s)
    }

    // 6. FOCUS RULE branch 2: never stolen — this is what stops the note editor
    //    flickering from clip to clip while a group is built.
    @Test("toggling into a selection that HAS a focus does not move it")
    func toggleNeverSteals() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.toggle(b)
        s.toggle(c)
        #expect(s.ids == [a, b, c])
        #expect(s.focusID == a)
        expectInvariants(s)
    }

    // 7. FOCUS RULE branch 3: removing the FOCUS drops the focus but keeps the
    //    rest selected — the deliberate INV2-converse violation.
    @Test("toggling the focused clip OUT clears focus and keeps the others")
    func toggleOutTheFocus() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.toggle(b)
        s.toggle(c)

        s.toggle(a)
        #expect(s.ids == [b, c])
        #expect(s.focusID == nil, "the editor must close, not jump to a clip nobody clicked")
        #expect(!s.isEmpty)
        expectInvariants(s)

        // And a later add adopts focus again, since there is none.
        s.toggle(a)
        #expect(s.focusID == a)
        expectInvariants(s)
    }

    // 8. FOCUS RULE branch 4: removing a NON-focused clip leaves focus alone.
    @Test("toggling a non-focused clip out leaves the focus untouched")
    func toggleOutNonFocus() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.toggle(b)
        s.toggle(b)
        #expect(s.focusID == a)
        #expect(s.ids == [a])
        expectInvariants(s)
    }

    // 9. Emptying by toggling everything out lands back on INV2.
    @Test("toggling the last clip out empties the selection entirely")
    func toggleToEmpty() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.toggle(a)
        #expect(s.isEmpty)
        #expect(s.focusID == nil)
        expectInvariants(s)
    }

    // 10. THE CHORD MAPPING — shift and ⌘ both toggle; everything else replaces.
    @Test("intent: plain click replaces, shift/command toggle")
    func intents() {
        #expect(ArrangeClickIntent.intent(for: []) == .replace)
        #expect(ArrangeClickIntent.intent(for: .shift) == .toggle)
        #expect(ArrangeClickIntent.intent(for: .command) == .toggle)
        #expect(ArrangeClickIntent.intent(for: [.shift, .command]) == .toggle)
        #expect(ArrangeClickIntent.intent(for: .none) == .replace)
    }

    // 11. `apply` is the ONE entry point the tap and the seam share, so its two
    //     branches are pinned against the mutators they claim to route to.
    @Test("apply(click:) routes plain to selectOnly and modified to toggle")
    func apply() {
        var s = ArrangeSelection()
        #expect(s.apply(click: a, modifiers: []) == .replace)
        #expect(s.ids == [a])

        #expect(s.apply(click: b, modifiers: .shift) == .toggle)
        #expect(s.ids == [a, b])
        #expect(s.focusID == a)

        #expect(s.apply(click: c, modifiers: .command) == .toggle)
        #expect(s.ids == [a, b, c])

        // A plain click COLLAPSES a group back to one clip — the behaviour a user
        // relies on to escape a selection they didn't mean to build.
        #expect(s.apply(click: b, modifiers: []) == .replace)
        #expect(s.ids == [b])
        #expect(s.focusID == b)
        expectInvariants(s)
    }

    // 12. STALE-ID POLICY: membership of a vanished clip is harmless, and
    //     `resolved(in:)` is the filter every consumer goes through.
    @Test("resolved(in:) drops ids that no longer exist")
    func resolved() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.toggle(b)
        s.toggle(c)

        #expect(s.resolved(in: [a, c]) == [a, c])
        #expect(s.resolved(in: []).isEmpty)
        // The selection itself is NOT mutated by a read.
        #expect(s.ids == [a, b, c])
    }

    // 13. Equatable — the view's `.onChange(of: selection)` render report depends
    //     on it, and a focus-only move must count as a change.
    @Test("selections compare on both the set AND the focus")
    func equality() {
        var x = ArrangeSelection()
        var y = ArrangeSelection()
        #expect(x == y)

        x.selectOnly(a)
        y.selectOnly(a)
        #expect(x == y)

        // Same ids, different focus: x = {a,b} focus a; y = {a,b} focus nil.
        x.toggle(b)
        y.toggle(b)
        y.toggle(a)
        y.toggle(a)   // a re-added, but focus was cleared and is now a again…
        #expect(x == y)

        var z = ArrangeSelection()
        z.toggle(a)
        z.toggle(b)
        z.toggle(a)   // {b}, focus nil (a was the adopted focus)
        #expect(z.ids == [b])
        #expect(z.focusID == nil)
        #expect(z != x)
    }

    // MARK: - The rubber band's set mutators (m23-g3)

    // 14. `replace(with:)` — the focus SURVIVES when it is still a member.
    @Test("replace keeps a focus that is still selected")
    func replaceKeepsSurvivingFocus() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.toggle(b)            // {a,b}, focus a
        s.replace(with: [a, c])
        #expect(s.ids == [a, c])
        #expect(s.focusID == a, "a is still a member, so the focus must not move")
    }

    // 15. …and is DROPPED, not re-pointed, when it is not (INV1).
    @Test("replace drops a focus the new set does not contain")
    func replaceDropsVanishedFocus() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.replace(with: [b, c])
        #expect(s.ids == [b, c])
        #expect(s.focusID == nil)
    }

    // 16. NEVER ADOPTS — the decision the doc comment argues for, pinned. A band
    //     has no anchor clip, so promoting an arbitrary member to focus would
    //     open the piano roll on a clip the user never clicked (and, since a
    //     marquee applies live, would flicker it clip to clip mid-drag).
    @Test("replace never invents a focus, even from a single-element set")
    func replaceNeverAdopts() {
        var s = ArrangeSelection()
        s.replace(with: [a])
        #expect(s.ids == [a])
        #expect(s.focusID == nil, "selecting is not opening")

        // Nor after the focus was legitimately dropped.
        s.replace(with: [a, b])
        #expect(s.focusID == nil)
    }

    // 17. INV2 holds through replace: an empty set clears the focus.
    @Test("replace with the empty set clears everything")
    func replaceEmpty() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.replace(with: [])
        #expect(s.isEmpty)
        #expect(s.focusID == nil)
    }

    // 18. `formUnion` — additive, and the focus is untouched in every direction
    //     (ids only grow, so INV1 is preserved for free).
    @Test("formUnion adds without disturbing the focus")
    func formUnionKeepsFocus() {
        var s = ArrangeSelection()
        s.selectOnly(a)        // {a}, focus a
        s.formUnion([b, c])
        #expect(s.ids == [a, b, c])
        #expect(s.focusID == a)

        // Re-adding a member is a no-op, focus included.
        s.formUnion([a])
        #expect(s.ids == [a, b, c])
        #expect(s.focusID == a)
    }

    // 19. …and it does not adopt one either, for the same reason as replace.
    @Test("formUnion never invents a focus")
    func formUnionNeverAdopts() {
        var s = ArrangeSelection()
        s.formUnion([a, b])
        #expect(s.ids == [a, b])
        #expect(s.focusID == nil)

        // Including onto a focus-less multi-selection produced by toggle.
        var t = ArrangeSelection()
        t.toggle(a)
        t.toggle(b)
        t.toggle(a)            // {b}, focus nil
        t.formUnion([c])
        #expect(t.ids == [b, c])
        #expect(t.focusID == nil)
    }

    // 20. Both mutators preserve INV1 under composition — the exact sequence
    //     `AppModel.applyArrangeMarquee` runs for a shift-band.
    @Test("replace-then-union (the shift band's composition) keeps the invariants")
    func replaceThenUnion() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        let base = s.ids

        s.replace(with: base)
        s.formUnion([b, c])
        #expect(s.ids == [a, b, c])
        #expect(s.focusID == a)
        #expect(s.focusID.map { s.contains($0) } ?? true, "INV1")

        // A second update from the SAME base gives the un-touched clip back.
        s.replace(with: base)
        s.formUnion([b])
        #expect(s.ids == [a, b])
        #expect(s.focusID == a)
    }

    // MARK: - The track header's set mutator (m23-y)

    // 21. `subtract` — the focused clip leaving CLOSES the editor and leaves the
    //     rest of the selection standing. `toggle`'s removal rule, one
    //     cardinality up.
    @Test("subtract drops the focus when the focused clip leaves, keeping the rest")
    func subtractDropsDepartedFocus() {
        var s = ArrangeSelection()
        s.selectOnly(a)        // focus a
        s.toggle(b)
        s.toggle(c)            // {a,b,c}, focus a
        s.subtract([a, b])
        #expect(s.ids == [c])
        #expect(s.focusID == nil, "the focused clip left — nothing else is promoted")
    }

    // 22. …and a focus that stays is untouched — the third of `toggle`'s four
    //     focus rules, which is the one that keeps the note editor from
    //     flickering while a selection is torn down around it.
    @Test("subtract leaves an unrelated focus alone")
    func subtractKeepsSurvivingFocus() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.formUnion([b, c])
        s.subtract([b, c])
        #expect(s.ids == [a])
        #expect(s.focusID == a)
    }

    // 23. Ids that were never selected are simply absent — no throw, no
    //     spurious focus change. (A header click can pass such a set whenever a
    //     track is only partly selected.)
    @Test("subtract ignores ids that were not selected")
    func subtractIgnoresUnknownIDs() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.subtract([b, c])
        #expect(s.ids == [a])
        #expect(s.focusID == a)
    }

    // 24. INV2 through subtract: emptying `ids` necessarily removed the focus.
    @Test("subtracting everything clears the focus too")
    func subtractEverything() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.formUnion([b])
        s.subtract([a, b])
        #expect(s.isEmpty)
        #expect(s.focusID == nil, "INV2")
    }

    // 25. The empty argument is a no-op in BOTH fields — the case a zero-clip
    //     track would reach if `ArrangeTrackSelection` did not guard it first.
    @Test("subtracting the empty set changes nothing")
    func subtractEmpty() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        s.formUnion([b])
        let before = s
        s.subtract([])
        #expect(s == before)
    }

    // 26. union-then-subtract of the SAME set round-trips exactly — the property
    //     that makes the m23-y header chord a TRUE toggle rather than an
    //     additive one, checked on the mutators themselves.
    @Test("formUnion then subtract of the same set is the identity")
    func unionSubtractRoundTrip() {
        var s = ArrangeSelection()
        s.selectOnly(a)
        let before = s
        s.formUnion([b, c])
        s.subtract([b, c])
        #expect(s == before)
    }
}
