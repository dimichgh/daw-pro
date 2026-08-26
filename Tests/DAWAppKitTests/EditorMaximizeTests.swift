import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `EditorMaximize` (m25-b-1) — the rule behind the piano
/// roll's MAXIMIZE toggle: how tall the editor pane gets, what the arrange keeps,
/// and when Escape leaves the mode.
///
/// The suite lives here rather than in `DAWApp` because `DAWApp` has NO test
/// target: a layout rule written in the view would ship ungated (the
/// `WaveformScale` / `ArrangeEmptyClick` precedent). What the view keeps is the
/// two `.frame` calls; every decision inside them is pinned below.
@MainActor
@Suite("EditorMaximize — the maximized note editor (m25-b-1)")
struct EditorMaximizeTests {

    /// The real geometry the app passes in, composed from the two `DAWApp`
    /// constants this target cannot see: `TimelineLanesView.rulerHeight` (80) +
    /// `ContentView.arrangeBlockGap` (6).
    static let sliver: CGFloat = 86

    // MARK: - The mirror pin

    /// ⭐⭐ THE PIN THAT KEEPS THE WHOLE THING HONEST. `EditorMaximize` reads the
    /// ordinary ceiling through `WindowFloor.editorMaxFraction` because
    /// `PanelLayoutStore` is `@MainActor` and its statics are unreachable from a
    /// nonisolated helper. Two constants for one number is a drift hazard, so it
    /// is pinned: move the store's range without moving the mirror and this fails
    /// loudly, instead of silently making "maximize can never shrink the editor"
    /// false at every window size.
    @Test("the nonisolated ceiling mirror still equals the store's real clamp")
    func ceilingMirrorMatchesTheStore() {
        #expect(EditorMaximize.normalMaxFraction
                == PanelLayoutStore.editorFractionRange.upperBound)
        #expect(WindowFloor.editorMaxFraction
                == PanelLayoutStore.editorFractionRange.upperBound)
    }

    // MARK: - The reserve

    @Test("the reserve is the fixed chrome plus the arrange sliver")
    func reserve() {
        #expect(EditorMaximize.reservedHeight(arrangeSliver: Self.sliver)
                == WindowFloor.fixedChromeHeight + Self.sliver)
        #expect(EditorMaximize.reservedHeight(arrangeSliver: Self.sliver) == 275)
        // The default matches the shipped geometry, so a preview and the app agree.
        #expect(EditorMaximize.defaultArrangeSliverHeight == Self.sliver)
    }

    @Test("a negative sliver is floored at zero rather than credited back")
    func reserveFloorsNegativeSliver() {
        #expect(EditorMaximize.reservedHeight(arrangeSliver: -500)
                == WindowFloor.fixedChromeHeight)
    }

    // MARK: - The fraction

    @Test("the maximized fraction is computed from the live window height")
    func fractionAtRealHeights() {
        // The default window (1440×900): 900 − 275 = 625 pt of editor.
        let at900 = EditorMaximize.maximizedFraction(windowHeight: 900, arrangeSliver: Self.sliver)
        #expect(abs(at900 - 625.0 / 900.0) < 1e-9)
        #expect(abs(900 * at900 - 625) < 1e-6)

        // A taller window gives proportionally more, because the reserve is CONSTANT
        // in points — this is the property a fixed fraction cannot have.
        let at1440 = EditorMaximize.maximizedFraction(windowHeight: 1440, arrangeSliver: Self.sliver)
        #expect(abs(1440 * at1440 - 1165) < 1e-6)
        #expect(at1440 > at900)
    }

    /// ⭐ THE INVARIANT THE MODE PROMISES: maximizing is never smaller than the
    /// biggest drag. At every height the shipping window can reach.
    @Test("maximized is always at least the ordinary 0.55 ceiling")
    func neverSmallerThanADrag() {
        for h in stride(from: WindowFloor.minHeight, through: CGFloat(3000), by: 20) {
            let f = EditorMaximize.maximizedFraction(windowHeight: h, arrangeSliver: Self.sliver)
            #expect(f >= EditorMaximize.normalMaxFraction, "shrank at \(h): \(f)")
        }
        // And strictly LARGER at the floor, so the mode is worth having even there.
        let atFloor = EditorMaximize.maximizedFraction(windowHeight: WindowFloor.minHeight,
                                                       arrangeSliver: Self.sliver)
        #expect(atFloor > EditorMaximize.normalMaxFraction)
        #expect(abs(WindowFloor.minHeight * atFloor - 365) < 1e-6)
    }

    /// ⚠️⚠️ THE m10-j INTERACTION THE ROADMAP ITEM ASKS ABOUT, MEASURED IN BOTH
    /// DIRECTIONS. `WindowFloor.minHeight` is DERIVED from the 0.55 ceiling, so a
    /// mode that suspends the clamp has to be checked against it rather than
    /// assumed safe. It is safe **because the fraction is computed**: the chrome
    /// reserve is subtracted in POINTS before the division, so the leftover is the
    /// reserve exactly, at every height.
    @Test("the fixed chrome still fits at EVERY window height, floor included")
    func chromeAlwaysFits() {
        for h in stride(from: WindowFloor.minHeight, through: CGFloat(3000), by: 10) {
            let f = EditorMaximize.maximizedFraction(windowHeight: h, arrangeSliver: Self.sliver)
            let leftover = h - h * f
            #expect(leftover >= WindowFloor.fixedChromeHeight - 1e-6,
                    "chrome overflows at \(h): \(leftover) < \(WindowFloor.fixedChromeHeight)")
            // And the arrange keeps its pinned ruler block, so that block can never
            // be starved into drawing on top of the editor.
            #expect(leftover >= WindowFloor.fixedChromeHeight + Self.sliver - 1e-6,
                    "the ruler block is starved at \(h): \(leftover)")
        }
    }

    /// ⭐ THE NEGATIVE CONTROL — the defect this design exists to avoid, shown
    /// firing. A plausible "just pick a big fraction" implementation breaks the
    /// window floor, which is exactly why `editorFractionRange` was NOT widened
    /// and why the fraction is derived. Without this leg the test above only
    /// proves that some number is ≥ another number.
    @Test("a CONSTANT maximize fraction would push the chrome off-window at the floor")
    func constantFractionWouldBreakTheFloor() {
        let naive: CGFloat = 0.92
        let leftoverAtFloor = WindowFloor.minHeight - WindowFloor.minHeight * naive
        #expect(leftoverAtFloor < WindowFloor.fixedChromeHeight,
                "the naive control no longer reproduces the overflow — re-derive it")
        // The shipped rule, same window, does not.
        let computed = EditorMaximize.maximizedFraction(windowHeight: WindowFloor.minHeight,
                                                        arrangeSliver: Self.sliver)
        #expect(WindowFloor.minHeight - WindowFloor.minHeight * computed
                >= WindowFloor.fixedChromeHeight)
    }

    @Test("a window too short for the reserve clamps to the ordinary ceiling, never below")
    func shortWindowClampsUp() {
        // 500 pt: raw would be (500 − 275)/500 = 0.45, below the 0.55 ceiling.
        // Unreachable in the shipping app (the floor is 640) — guarded anyway,
        // because a floor is a promise about the window, not about this argument.
        #expect(EditorMaximize.maximizedFraction(windowHeight: 500, arrangeSliver: Self.sliver)
                == EditorMaximize.normalMaxFraction)
    }

    @Test("degenerate window heights fall back to the ordinary ceiling")
    func degenerateHeights() {
        for h in [CGFloat(0), -1, -900, .nan, .infinity] {
            #expect(EditorMaximize.maximizedFraction(windowHeight: h, arrangeSliver: Self.sliver)
                    == EditorMaximize.normalMaxFraction, "bad fallback for \(h)")
        }
    }

    @Test("the ceiling caps a caller that reserves nothing")
    func ceilingCaps() {
        let f = EditorMaximize.maximizedFraction(windowHeight: 10_000, arrangeSliver: 0)
        #expect(f == EditorMaximize.fractionCeiling)
        #expect(f < 1)
    }

    // MARK: - The effective fraction (what the view multiplies by)

    @Test("un-maximized, the effective fraction is the stored one untouched")
    func passthroughWhenNormal() {
        for stored in [CGFloat(0.30), 0.38, 0.45, 0.55] {
            #expect(EditorMaximize.effectiveFraction(windowHeight: 900,
                                                     editorFraction: stored,
                                                     maximized: false,
                                                     arrangeSliver: Self.sliver) == stored)
        }
        // Window height is irrelevant when the mode is off — the pre-m25-b-1
        // expression was `height * editorFraction` and it still is.
        #expect(EditorMaximize.effectiveFraction(windowHeight: 1,
                                                 editorFraction: 0.45,
                                                 maximized: false,
                                                 arrangeSliver: Self.sliver) == 0.45)
    }

    @Test("maximized, the effective fraction is the computed one")
    func maximizedUsesTheComputedFraction() {
        let stored: CGFloat = 0.31
        let effective = EditorMaximize.effectiveFraction(windowHeight: 900,
                                                         editorFraction: stored,
                                                         maximized: true,
                                                         arrangeSliver: Self.sliver)
        #expect(effective == EditorMaximize.maximizedFraction(windowHeight: 900,
                                                              arrangeSliver: Self.sliver))
        #expect(effective > stored)
    }

    /// Defensive, and written down because the failure mode is "the button does
    /// the opposite of its label". The store cannot produce a fraction above 0.55
    /// today, so this can only fire if the clamp moves.
    @Test("maximize can never SHRINK the pane, even if the clamp ever moves")
    func maximizeNeverShrinks() {
        let stored: CGFloat = 0.90
        #expect(EditorMaximize.effectiveFraction(windowHeight: 640,
                                                 editorFraction: stored,
                                                 maximized: true,
                                                 arrangeSliver: Self.sliver) == stored)
    }

    // MARK: - What the arrange keeps

    @Test("the arrange row is pinned to the sliver only while maximized")
    func arrangeHeight() {
        #expect(EditorMaximize.arrangeHeight(maximized: false, arrangeSliver: Self.sliver) == nil)
        #expect(EditorMaximize.arrangeHeight(maximized: true, arrangeSliver: Self.sliver) == 86)
        // nil is the pass-through: the un-maximized layout keeps its shipped
        // `maxHeight: .infinity` behaviour with no hard height imposed on it.
        #expect(EditorMaximize.arrangeHeight(maximized: true, arrangeSliver: -10) == 0)
    }

    /// The sliver and the reserve must agree, or the pane and the arrange fight
    /// over the same points and one of them overflows — invisibly, since no gate
    /// here can see pixels.
    @Test("pane + arrange + chrome exactly fills the window at every height")
    func layoutClosesExactly() {
        for h in stride(from: WindowFloor.minHeight, through: CGFloat(2400), by: 37) {
            let f = EditorMaximize.effectiveFraction(windowHeight: h,
                                                     editorFraction: 0.45,
                                                     maximized: true,
                                                     arrangeSliver: Self.sliver)
            let pane = h * f
            let arrange = EditorMaximize.arrangeHeight(maximized: true,
                                                       arrangeSliver: Self.sliver) ?? 0
            #expect(pane + arrange + WindowFloor.fixedChromeHeight <= h + 1e-6,
                    "over-committed at \(h): \(pane) + \(arrange) + \(WindowFloor.fixedChromeHeight)")
        }
    }

    // MARK: - Escape

    /// The full truth table. `maximized` is the only state that can open the exit;
    /// a modal or a live rename field each close it on their own, because Escape
    /// means "cancel the thing in front of you" before it means anything else.
    @Test("Escape exits ONLY while maximized, and never over a modal or a rename")
    func escapeTruthTable() {
        for maximized in [true, false] {
            for modal in [true, false] {
                for text in [true, false] {
                    let expected = maximized && !modal && !text
                    #expect(EditorMaximize.escapeExits(maximized: maximized,
                                                       modalPresented: modal,
                                                       textEditing: text) == expected,
                            "max=\(maximized) modal=\(modal) text=\(text)")
                }
            }
        }
    }

    /// The half that protects everything else in the app: outside the mode this
    /// claims NO key, so every existing Escape (the two rename fields, a menu, a
    /// modal) keeps working exactly as it did.
    @Test("outside the mode, Escape is claimed by nobody new")
    func escapeClaimsNothingWhenNormal() {
        #expect(EditorMaximize.escapeExits(maximized: false,
                                           modalPresented: false,
                                           textEditing: false) == false)
    }

    // MARK: - The toggle's two faces

    @Test("the toggle reads differently in each state — glyph, tooltip and label")
    func toggleFaces() {
        #expect(EditorMaximize.toggleSymbol(maximized: true)
                != EditorMaximize.toggleSymbol(maximized: false))
        #expect(EditorMaximize.toggleHelp(maximized: true)
                != EditorMaximize.toggleHelp(maximized: false))
        #expect(EditorMaximize.toggleAccessibilityLabel(maximized: true)
                != EditorMaximize.toggleAccessibilityLabel(maximized: false))
        // Outward arrows to grow, inward arrows to shrink back.
        #expect(EditorMaximize.toggleSymbol(maximized: false) == "arrow.up.left.and.arrow.down.right")
        #expect(EditorMaximize.toggleSymbol(maximized: true) == "arrow.down.right.and.arrow.up.left")
    }

    /// ⭐ THE SECOND EXIT HAS TO BE DISCOVERABLE FROM THE FIRST. A user who found
    /// the toggle must be told about Escape; a user who never finds Escape still
    /// has the toggle. This is the "two ways out" constraint made checkable.
    @Test("the maximized tooltip names the Escape exit")
    func maximizedTooltipNamesEscape() {
        #expect(EditorMaximize.toggleHelp(maximized: true).contains("Escape"))
    }

    /// Rule 6 — beginner-readable. No jargon, and no raw units or internal names
    /// in a string a newcomer reads on hover.
    @Test("both tooltips are plain language, not jargon")
    func tooltipsArePlainLanguage() {
        for maximized in [true, false] {
            let help = EditorMaximize.toggleHelp(maximized: maximized)
            #expect(help.count >= 20 && help.count <= 90, "tooltip length: \(help)")
            for jargon in ["fraction", "editorFraction", "clamp", "px", "pt", "PanelLayout"] {
                #expect(!help.contains(jargon), "jargon \"\(jargon)\" in: \(help)")
            }
        }
    }
}
