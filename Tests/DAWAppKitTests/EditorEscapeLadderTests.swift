import Testing
import Foundation
@testable import DAWAppKit

/// m23-ap I4 — Escape's ONE ladder, and the band rule's ONE home. Both are pure,
/// so this suite is NONISOLATED (the `@MainActor` suite census stands at its
/// cap; nothing here needs the main actor).
///
/// ⚠️ NO `@MainActor` ON ANY TEST HERE EITHER. A per-test `@MainActor` inside a
/// nonisolated suite is the census evasion `MainActorOccupancySiteTests` names,
/// so the one leg that drives a main-actor model (the roll's `applyMarquee`
/// through the hoist) lives in the EXISTING `@MainActor` `PianoRollMarqueeTests`.
///
/// What this suite CANNOT see: which editor a real Escape keystroke reaches, and
/// that each editor applies the rung it is handed. The pitch editor's half is
/// `PitchEditorModelTests` (its model is headless); the roll's is a source pin
/// in `EditorMaximizeSiteTests`, because `PianoRollView` lives in `DAWApp`,
/// which has no test target.
@Suite("Escape ladder and band rule — one home each, both editors (m23-ap I4)")
struct EditorEscapeLadderTests {

    // MARK: - The ladder

    @Test("the full truth table — one rung per press, nearest thing first")
    func truthTable() {
        var rows = 0
        for blocked in [true, false] {
            for gesture in [true, false] {
                for selected in [true, false] {
                    for maximized in [true, false] {
                        let rung = EditorEscapeLadder.resolve(
                            gestureLive: gesture, hasSelection: selected,
                            maximized: maximized, blocked: blocked)
                        let expected: EditorEscapeRung
                        if blocked { expected = .pass }
                        else if gesture { expected = .cancelGesture }
                        else if selected { expected = .clearSelection }
                        else if maximized { expected = .exitMaximize }
                        else { expected = .pass }
                        #expect(rung == expected,
                                "blocked=\(blocked) gesture=\(gesture) selected=\(selected) max=\(maximized)")
                        rows += 1
                    }
                }
            }
        }
        #expect(rows == 16)
    }

    @Test("a selection is cleared BEFORE the mode is left — the roll's named behaviour change")
    func selectionBeforeMaximize() {
        // ⚠️ THE SHIPPED ROLL WENT STRAIGHT TO EXIT-MAXIMIZE. Design §13 decided
        // the change; this is the row that changed, stated alone so a red names it.
        #expect(EditorEscapeLadder.resolve(gestureLive: false, hasSelection: true,
                                           maximized: true, blocked: false) == .clearSelection)
        // …and the SECOND press, with the selection gone, leaves the mode.
        #expect(EditorEscapeLadder.resolve(gestureLive: false, hasSelection: false,
                                           maximized: true, blocked: false) == .exitMaximize)
    }

    @Test("a live gesture is cancelled before the selection it is moving is touched")
    func gestureBeforeSelection() {
        #expect(EditorEscapeLadder.resolve(gestureLive: true, hasSelection: true,
                                           maximized: true, blocked: false) == .cancelGesture)
        // Three presses walk the whole ladder back to a normal window.
        var gesture = true, selected = true, maximized = true
        var walked: [EditorEscapeRung] = []
        for _ in 0..<4 {
            let rung = EditorEscapeLadder.resolve(gestureLive: gesture, hasSelection: selected,
                                                  maximized: maximized, blocked: false)
            walked.append(rung)
            switch rung {
            case .cancelGesture: gesture = false
            case .clearSelection: selected = false
            case .exitMaximize: maximized = false
            case .pass: break
            }
        }
        #expect(walked == [.cancelGesture, .clearSelection, .exitMaximize, .pass])
    }

    @Test("a modal or a rename field owns Escape outright — every rung passes")
    func blockedPassesEverything() {
        for gesture in [true, false] {
            for selected in [true, false] {
                for maximized in [true, false] {
                    #expect(EditorEscapeLadder.resolve(gestureLive: gesture, hasSelection: selected,
                                                       maximized: maximized, blocked: true) == .pass)
                }
            }
        }
    }

    @Test("only .pass lets the key propagate — outside every rung, nobody new claims Escape")
    func onlyPassPropagates() {
        #expect(EditorEscapeRung.allCases.filter { !$0.consumesKey } == [.pass])
        #expect(!EditorEscapeLadder.resolve(gestureLive: false, hasSelection: false,
                                            maximized: false, blocked: false).consumesKey)
    }

    @Test("EditorMaximize.escapeExits is the ladder's mode rung, asked alone — same truth table as before")
    func escapeExitsForwardsToTheLadder() {
        for maximized in [true, false] {
            for modal in [true, false] {
                for text in [true, false] {
                    #expect(EditorMaximize.escapeExits(maximized: maximized, modalPresented: modal,
                                                       textEditing: text)
                            == (maximized && !modal && !text))
                    #expect(EditorMaximize.escapeExits(maximized: maximized, modalPresented: modal,
                                                       textEditing: text)
                            == (EditorEscapeLadder.resolve(gestureLive: false, hasSelection: false,
                                                           maximized: maximized,
                                                           blocked: modal || text) == .exitMaximize))
                }
            }
        }
    }

    // MARK: - The band rule's one home

    @Test("PianoRollMarquee.selection: REPLACE without the chord, UNION onto the frozen base with it")
    func bandSelectionRule() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(PianoRollMarquee.selection(base: [a], hits: [b, c], additive: false) == [b, c])
        #expect(PianoRollMarquee.selection(base: [a], hits: [b, c], additive: true) == [a, b, c])
        // Shrinking the band gives notes back: the base is frozen, never the
        // live selection, so a hit that leaves the band leaves the selection.
        #expect(PianoRollMarquee.selection(base: [a], hits: [], additive: true) == [a])
        #expect(PianoRollMarquee.selection(base: [a], hits: [], additive: false) == [])
    }
}
