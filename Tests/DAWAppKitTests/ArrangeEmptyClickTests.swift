import Foundation
import Testing
@testable import DAWAppKit

/// m25-m — clicking empty space deselects.
///
/// ⚠️ WHY THE "OBVIOUS" TEST IS THE USELESS ONE. *"Click empty ⇒ selection
/// empty"* passes against an implementation that clears on MOUSE-DOWN, that
/// clears on a right-click, that clears on the start of a rubber band, and that
/// clears the clip a double-click just created. Every one of those is a shipped
/// behaviour destroyed by the fix, and every one of them fails SILENTLY. So the
/// cases below are the negatives, and the positive is one line at the end.
///
/// TWO OF THE FOUR REQUIRED CASES ARE STRUCTURAL AND CANNOT BE UNIT-TESTED HERE,
/// which is stated rather than quietly skipped:
///   - **A drag never reaches the rule.** `handleEmptyClick` runs from
///     `.onTapGesture`, and SwiftUI delivers that only for a press+release that
///     never travelled; the band's own `minimumDistance: ArrangeMarquee.dragSlop`
///     is what separates the two. `dragSlopIsNonZero` below pins the one part of
///     that argument this target can see.
///   - **A right-click never reaches it either.** `.onTapGesture` recognises the
///     primary button only, and the empty-lane surface carries no `.contextMenu`.
/// Both are reproducible end-to-end through `debug.arrangePointer`.
@Suite("Empty-space deselect (m25-m)")
struct ArrangeEmptyClickTests {

    // 1. THE POSITIVE.
    @Test("a plain click on empty space DESELECTS")
    func plainClickDeselects() {
        #expect(ArrangeEmptyClick.outcome(modifiers: [], followsClipCreate: false)
                == .deselect)
    }

    // 2.
    @Test("a SHIFT-click leaves the selection alone — shift is additive, not abandonment")
    func shiftClickKeepsSelection() {
        #expect(ArrangeEmptyClick.outcome(modifiers: .shift, followsClipCreate: false)
                == .keepSelection)
    }

    // 3.
    @Test("a ⌘-click leaves the selection alone")
    func commandClickKeepsSelection() {
        #expect(ArrangeEmptyClick.outcome(modifiers: .command, followsClipCreate: false)
                == .keepSelection)
    }

    // 4.
    @Test("⇧⌘ together still leaves it alone — the chord table has ONE reading")
    func bothModifiersKeepSelection() {
        #expect(ArrangeEmptyClick.outcome(modifiers: [.shift, .command],
                                          followsClipCreate: false) == .keepSelection)
    }

    // 5.
    @Test("the single-tap half of a create double-click does NOT undo that create's selection")
    func createDoubleClickSurvivesItsOwnSingleTap() {
        // The m23-e beginner path: double-click empty space → a MIDI clip is
        // created, selected, and the editor opens on it. If the stray single tap
        // deselected, the editor would close in the same frame it opened.
        #expect(ArrangeEmptyClick.outcome(modifiers: [], followsClipCreate: true)
                == .keepSelection)
    }

    // 6.
    @Test("the rule reads the app's ONE chord table, not a private copy of it")
    func routesThroughTheSharedChordMapping() {
        // If `ArrangeClickIntent` ever changes what a chord means, this rule must
        // change with it. Comparing against the mapping (rather than restating
        // "shift or command") is what makes that true by construction — the same
        // argument `ArrangeMarquee` makes for reusing it on a band.
        for mods: ArrangeClickModifiers in [[], .shift, .command, [.shift, .command]] {
            let expected: ArrangeEmptyClick.Outcome =
                ArrangeClickIntent.intent(for: mods) == .replace ? .deselect : .keepSelection
            #expect(ArrangeEmptyClick.outcome(modifiers: mods, followsClipCreate: false)
                    == expected)
        }
    }

    // 7. The structural argument's one testable half.
    @Test("the marquee's drag slop is NON-ZERO — which is what keeps a drag out of this rule")
    func dragSlopIsNonZero() {
        // A press that travels past this arms a rubber band and SwiftUI never
        // delivers the tap, so "the start of a drag must not deselect" holds
        // without the rule knowing anything about drags. A zero slop would route
        // every band's press through the tap handler and clear the base
        // selection the band was meant to extend.
        #expect(ArrangeMarquee.dragSlop > 0)
    }
}
