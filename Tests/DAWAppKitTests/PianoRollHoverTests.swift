import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// m25-g — the roll's ONE hover resolution. The point of testing this separately
/// from the geometry is that the PRECEDENCE is the thing three roadmap items
/// share ("build ONE, not three"), and precedence is exactly what rots when it
/// is spelled in more than one place.
@Suite("Piano roll hover target (m25-g)")
struct PianoRollHoverTests {

    private let selection = CGRect(x: 100, y: 50, width: 200, height: 42)
    private let noteID = UUID()

    // MARK: - Precedence

    @Test("a note outranks the group handle, so no shipped press changes hands")
    func notesOutrankTheHandle() {
        // ⭐ THE ZERO-REGRESSION RULE. The handle band is already outside the
        // selection's box, so the only contested points are where some OTHER
        // note is parked in the margin. Those stay with the note: every press
        // that started a move or a resize before m25-g still does.
        let inTheMargin = CGPoint(x: selection.maxX + 2, y: selection.midY)
        // Sanity: that point IS in the band, so the test is contested.
        #expect(PianoRollGroupScale.edge(at: inTheMargin, frame: selection) == .trailing)
        let target = PianoRollHover.target(
            at: inTheMargin, hit: (id: noteID, zone: .body),
            selectionFrame: selection, proDensity: true, modifiers: [], playheadX: nil)
        #expect(target == .note(id: noteID, zone: .body))
        // POSITIVE CONTROL: with nothing under the pointer, the SAME point is
        // the handle — so the assertion above is precedence, not a dead branch.
        #expect(PianoRollHover.target(at: inTheMargin, hit: nil,
                                      selectionFrame: selection, proDensity: true, modifiers: [], playheadX: nil)
                == .groupScaleHandle(.trailing))
    }

    @Test("empty grid away from the selection is empty")
    func emptyIsEmpty() {
        let far = CGPoint(x: 900, y: 900)
        #expect(PianoRollHover.target(at: far, hit: nil, selectionFrame: selection,
                                      proDensity: true, modifiers: [], playheadX: nil) == .empty)
        // ...and with no group selected at all, the margin is empty too.
        #expect(PianoRollHover.target(at: CGPoint(x: selection.maxX + 2, y: selection.midY),
                                      hit: nil, selectionFrame: nil, proDensity: true, modifiers: [], playheadX: nil) == .empty)
    }

    // MARK: - The density gate, in ONE place

    @Test("Simple density gets neither edge handle")
    func simpleDensityHasNoEdgeAffordances() {
        // The panel-density gate used to be spelled twice in `PianoRollView` —
        // once for the cursor, once for the press router. Both now read this.
        // A note's own resize zone degrades to a BODY (a Simple user can still
        // move the note), and the group handle disappears entirely.
        let onANote = PianoRollHover.target(
            at: CGPoint(x: 150, y: 60), hit: (id: noteID, zone: .resizeHandle),
            selectionFrame: selection, proDensity: false, modifiers: [], playheadX: nil)
        #expect(onANote == .note(id: noteID, zone: .body))
        let onTheHandle = PianoRollHover.target(
            at: CGPoint(x: selection.maxX + 2, y: selection.midY), hit: nil,
            selectionFrame: selection, proDensity: false, modifiers: [], playheadX: nil)
        #expect(onTheHandle == .empty)
        // POSITIVE CONTROL: the same two calls at Pro density DO produce the
        // affordances, so the negatives above are the gate.
        #expect(PianoRollHover.target(at: CGPoint(x: 150, y: 60),
                                      hit: (id: noteID, zone: .resizeHandle),
                                      selectionFrame: selection, proDensity: true, modifiers: [], playheadX: nil)
                == .note(id: noteID, zone: .resizeHandle))
        #expect(PianoRollHover.target(at: CGPoint(x: selection.maxX + 2, y: selection.midY),
                                      hit: nil, selectionFrame: selection, proDensity: true, modifiers: [], playheadX: nil)
                == .groupScaleHandle(.trailing))
    }

    // MARK: - The playhead grab band (m25-o-2)

    /// ⭐⭐ **THE LOAD-BEARING CLAUSE OF THE WHOLE ITEM, AND IT IS THE USER'S OWN
    /// WORDS: *"when a mouse hover over the playhead line and there is NO OTHER
    /// ELEMENTS UNDER THE MOUSE"*.** A note is an other element.
    ///
    /// ⚠️ This test exists because `PianoRollHover`'s own doc once argued the
    /// OPPOSITE — that the playhead must beat `.note` because the line crosses
    /// music. Ranking it that way makes NOTES ungrabbable wherever the transport
    /// sits, which is a worse bug than the one this item fixes: editing notes is
    /// this surface's whole job. MUTANT: move the `playheadX` check above the
    /// `if let hit` branch in `target` and this reddens.
    @Test("⚠️ a note under the pointer BEATS the playhead line crossing it")
    func notesOutrankThePlayhead() {
        let onTheLine = CGPoint(x: 400, y: 60)
        // The pointer is EXACTLY on the line — the contested case, not a near miss.
        let target = PianoRollHover.target(
            at: onTheLine, hit: (id: noteID, zone: .body),
            selectionFrame: nil, proDensity: true, modifiers: [], playheadX: 400)
        #expect(target == .note(id: noteID, zone: .body))
        // POSITIVE CONTROL: the SAME point with nothing under it IS the playhead,
        // so the assertion above is precedence and not a dead branch.
        #expect(PianoRollHover.target(at: onTheLine, hit: nil, selectionFrame: nil,
                                      proDensity: true, modifiers: [], playheadX: 400) == .playhead)
    }

    /// The group handle is an element too, so it wins for the same reason a note
    /// does. Contested only where the handle band and the line overlap.
    @Test("the group-scale handle also outranks the playhead")
    func handleOutranksThePlayhead() {
        let inTheMargin = CGPoint(x: selection.maxX + 2, y: selection.midY)
        #expect(PianoRollGroupScale.edge(at: inTheMargin, frame: selection) == .trailing,
                "fixture check — the point must be in the handle band for this to contest anything")
        #expect(PianoRollHover.target(at: inTheMargin, hit: nil, selectionFrame: selection,
                                      proDensity: true, modifiers: [], playheadX: inTheMargin.x)
                == .groupScaleHandle(.trailing))
        // POSITIVE CONTROL: with no selection there is no handle, and the same
        // point resolves to the playhead.
        #expect(PianoRollHover.target(at: inTheMargin, hit: nil, selectionFrame: nil,
                                      proDensity: true, modifiers: [], playheadX: inTheMargin.x) == .playhead)
    }

    /// The band is `±grabTolerance`, INCLUSIVE at the edge. MUTANT: widen
    /// `grabTolerance` and the "just outside" leg reddens.
    @Test("the grab band is ±grabTolerance around the line, and empty past it")
    func grabBandBoundary() {
        let lineX: CGFloat = 400
        let tol = PianoRollPlayhead.grabTolerance
        func target(atX x: CGFloat) -> PianoRollHoverTarget {
            PianoRollHover.target(at: CGPoint(x: x, y: 60), hit: nil, selectionFrame: nil,
                                  proDensity: true, modifiers: [], playheadX: lineX)
        }
        #expect(target(atX: lineX) == .playhead)
        // Inclusive at exactly the tolerance, both sides.
        #expect(target(atX: lineX + tol) == .playhead)
        #expect(target(atX: lineX - tol) == .playhead)
        // And empty just past it, both sides — the leg the tolerance mutant kills.
        #expect(target(atX: lineX + tol + 0.5) == .empty)
        #expect(target(atX: lineX - tol - 0.5) == .empty)
    }

    /// ⭐ **YOU CAN ONLY GRAB WHAT YOU CAN SEE.** `playheadX` is
    /// `PianoRollPlayhead.lineX`, which is nil whenever the transport is outside
    /// the edited clip — so the grab band inherits the honest-absence law
    /// (*"the LINE is never parked at an edge"*) instead of restating it.
    @Test("⚠️ an off-clip transport is ungrabbable — nil playheadX is empty at every x")
    func offClipPlayheadIsUngrabbable() {
        // Exactly the x a visible line would occupy: the ONLY difference from the
        // passing case above is that no line is drawn.
        #expect(PianoRollHover.target(at: CGPoint(x: 400, y: 60), hit: nil,
                                      selectionFrame: nil, proDensity: true,
                                      modifiers: [], playheadX: nil) == .empty)
        // And this is genuinely the off-clip condition, not a hand-made nil:
        // `lineX` returns nil for a transport before the clip.
        #expect(PianoRollPlayhead.lineX(position: 2, clipStartBeat: 8, lengthBeats: 16,
                                        pixelsPerBeat: 32) == nil)
    }

    /// The grab is geometry, not an edit affordance, so Simple density keeps it —
    /// unlike the two edge handles above. Positioning the transport is navigation,
    /// and the density gate exists to hide EDIT chrome from beginners.
    @Test("the playhead grab survives Simple density — it is navigation, not edit chrome")
    func playheadGrabIsNotDensityGated() {
        #expect(PianoRollHover.target(at: CGPoint(x: 400, y: 60), hit: nil,
                                      selectionFrame: nil, proDensity: false,
                                      modifiers: [], playheadX: 400) == .playhead)
    }

    // MARK: - The chord gate (m25-x)

    /// ⭐⭐ **THE CENTRAL CLAIM OF m25-x.** Before this the resolver took no
    /// modifier at all, so in Pro with 2+ notes selected a ⌘-hover over the
    /// 12-pt band drew the glowing accent bar and showed the edge-drag cursor,
    /// while the press fell through to `.click(nil)` and released into
    /// `.positionPlayhead`. One verb advertised, a different one performed.
    ///
    /// MUTANT: drop `!toggling,` from the `.groupScaleHandle` branch in
    /// `PianoRollHover.target` and every ⌘/⇧ leg below reddens while the
    /// positive control stays green.
    @Test("⚠️ a toggling chord RETRACTS the group-scale handle — the m25-x defect")
    func theTogglingChordRetractsTheHandle() {
        let inTheMargin = CGPoint(x: selection.maxX + 2, y: selection.midY)
        // Fixture check: the point IS in the band, so a negative below is the
        // chord and not a pointer parked somewhere there was never a handle.
        #expect(PianoRollGroupScale.edge(at: inTheMargin, frame: selection) == .trailing,
                "fixture check — the point must be in the handle band")
        func target(_ chord: ArrangeClickModifiers) -> PianoRollHoverTarget {
            PianoRollHover.target(at: inTheMargin, hit: nil, selectionFrame: selection,
                                  proDensity: true, modifiers: chord, playheadX: nil)
        }
        // ⭐ POSITIVE CONTROL FIRST, and it is what makes the three negatives
        // mean anything: the SAME point with no chord IS the handle. Without
        // this, "not a handle" is indistinguishable from "there was never a
        // handle here" — the vacuity this repo has shipped twice.
        #expect(target([]) == .groupScaleHandle(.trailing))
        // ⌘ — the reported defect.
        #expect(target([.command]) == .empty)
        // ⇧ — the SAME lie one degree quieter (the handle drew, ⇧-click was
        // inert), fixed by the same predicate because `ArrangeClickIntent` maps
        // both chords to `.toggle`.
        #expect(target([.shift]) == .empty)
        // ⇧⌘ — carries both; still toggling, still no handle.
        #expect(target([.shift, .command]) == .empty)
    }

    /// The retraction is a FALL-THROUGH, not a hole: the resolver keeps
    /// answering with whatever is genuinely under the pointer once the handle
    /// stops claiming the point.
    @Test("under the chord the band falls through to what is ACTUALLY there")
    func theBandFallsThroughRatherThanGoingBlank() {
        let inTheMargin = CGPoint(x: selection.maxX + 2, y: selection.midY)
        // The playhead line crosses the band: with the handle retracted, the
        // line is what is left, and the pointer should say so.
        #expect(PianoRollHover.target(at: inTheMargin, hit: nil, selectionFrame: selection,
                                      proDensity: true, modifiers: [.command],
                                      playheadX: inTheMargin.x) == .playhead)
        // POSITIVE CONTROL: with no chord the handle still outranks the line at
        // that very point, so the answer above is the chord and not a change to
        // the shipped ranking.
        #expect(PianoRollHover.target(at: inTheMargin, hit: nil, selectionFrame: selection,
                                      proDensity: true, modifiers: [],
                                      playheadX: inTheMargin.x)
                == .groupScaleHandle(.trailing))
    }

    /// ⭐ The gate is TARGETED, and this is the leg that stops a future "just
    /// return `.empty` under any modifier" simplification. A chord suppresses a
    /// target only when the chord's verb belongs to a DIFFERENT target.
    @Test("⚠️ the chord suppresses ONLY the handle — notes and the playhead survive it")
    func theChordSuppressesOnlyTheHandle() {
        // ⌘ over a note: the press still does a note-scoped thing (toggle), so
        // the pointer is honestly over a note.
        #expect(PianoRollHover.target(at: CGPoint(x: 150, y: 60),
                                      hit: (id: noteID, zone: .body),
                                      selectionFrame: selection, proDensity: true,
                                      modifiers: [.command], playheadX: nil)
                == .note(id: noteID, zone: .body))
        // ⌘ over a note's Pro resize zone: the density downgrade is the only
        // thing that may touch this, and the chord is not it.
        #expect(PianoRollHover.target(at: CGPoint(x: 150, y: 60),
                                      hit: (id: noteID, zone: .resizeHandle),
                                      selectionFrame: selection, proDensity: true,
                                      modifiers: [.shift], playheadX: nil)
                == .note(id: noteID, zone: .resizeHandle))
        // ⌘ over the playhead line on bare grid: ⌘-click still moves the
        // transport (`PianoRollGridRelease.positionPlayhead`) and advertises the
        // SAME `.verticalBar`, so nothing disagrees and the target stands.
        #expect(PianoRollHover.target(at: CGPoint(x: 400, y: 60), hit: nil,
                                      selectionFrame: nil, proDensity: true,
                                      modifiers: [.command], playheadX: 400) == .playhead)
    }

    /// The pixel the item is actually about: the bar and the cursor are both
    /// derived from this target, so retracting it retracts both.
    @Test("under ⌘ the band advertises no edge drag — cursor and bar together")
    func theBandAdvertisesNothingUnderTheChord() {
        let inTheMargin = CGPoint(x: selection.maxX + 2, y: selection.midY)
        let underCommand = PianoRollHover.target(
            at: inTheMargin, hit: nil, selectionFrame: selection,
            proDensity: true, modifiers: [.command], playheadX: nil)
        // `.resizeLeftRight` IS the group handle's cursor, so this is the exact
        // promise that used to be false.
        #expect(PianoRollHover.cursor(for: underCommand) != .resizeLeftRight)
        #expect(PianoRollHover.cursor(for: underCommand) == nil)
        // POSITIVE CONTROL: the same point with no chord DOES advertise the edge
        // drag, so the inequality above is the gate and not a dead branch.
        let plain = PianoRollHover.target(
            at: inTheMargin, hit: nil, selectionFrame: selection,
            proDensity: true, modifiers: [], playheadX: nil)
        #expect(PianoRollHover.cursor(for: plain) == .resizeLeftRight)
    }

    /// ⭐ The suppression predicate is `ArrangeClickIntent`'s, NOT a second
    /// reading of the flags — the reason `target` takes a chord rather than a
    /// `toggling: Bool`. If someone re-spells it as `contains(.command)` this
    /// reddens on the ⇧ leg; if they re-spell it as `contains(.shift)` it
    /// reddens on the ⌘ leg.
    @Test("the gate IS the shared click intent, chord for chord")
    func theGateAgreesWithTheSharedIntent() {
        let inTheMargin = CGPoint(x: selection.maxX + 2, y: selection.midY)
        for chord: ArrangeClickModifiers in [[], [.shift], [.command], [.shift, .command]] {
            let target = PianoRollHover.target(at: inTheMargin, hit: nil,
                                               selectionFrame: selection, proDensity: true,
                                               modifiers: chord, playheadX: nil)
            let toggling = ArrangeClickIntent.intent(for: chord) == .toggle
            let advertises = target == .groupScaleHandle(.trailing)
            #expect(advertises == !toggling,
                    "chord \(chord.rawValue): handle advertised=\(advertises), toggling=\(toggling)")
        }
    }

    // MARK: - Cursor

    @Test("every target advertises the cursor its gesture performs")
    func cursorsMatchTheGestures() {
        #expect(PianoRollHover.cursor(for: .note(id: noteID, zone: .body)) == .grab)
        #expect(PianoRollHover.cursor(for: .note(id: noteID, zone: .resizeHandle)) == .resizeLeftRight)
        // The group handle is an edge drag, exactly like a trim edge.
        #expect(PianoRollHover.cursor(for: .groupScaleHandle(.leading)) == .resizeLeftRight)
        #expect(PianoRollHover.cursor(for: .groupScaleHandle(.trailing)) == .resizeLeftRight)
        // m25-o-2 — the SAME cursor m25-o's ⌘ affordance shows. The user asked
        // for this shape in both breaths ("some vertical sign" / "the vertical
        // visual element"), and a second playhead cursor would be the third
        // silent convention `CursorKind.verticalBar`'s doc refuses.
        #expect(PianoRollHover.cursor(for: .playhead) == .verticalBar)
        // nil is "no special cursor" — the arrow — which is what
        // `hoverCursor(resolve:)` expects for empty space.
        #expect(PianoRollHover.cursor(for: .empty) == nil)
    }

    /// The two constants are ALIASED to the arrange's, so the same gesture feels
    /// the same in both surfaces. A local literal here would let them drift.
    @Test("grab geometry is shared with the arrange, not re-chosen")
    func grabGeometryIsSharedWithTheArrange() {
        #expect(PianoRollPlayhead.grabTolerance == ArrangePointer.playheadGrabTolerance)
        #expect(PianoRollPlayhead.scrubSlop == ArrangePointer.scrubSlop)
    }

    @Test("the Simple-density cursor never promises a resize Simple will refuse")
    func cursorAgreesWithTheGateAtSimpleDensity() {
        // The defect this pairing prevents: a cursor resolved without the gate
        // and a press routed with it means the pointer says "resize" and the
        // click moves the note.
        let target = PianoRollHover.target(
            at: CGPoint(x: 150, y: 60), hit: (id: noteID, zone: .resizeHandle),
            selectionFrame: selection, proDensity: false, modifiers: [], playheadX: nil)
        #expect(PianoRollHover.cursor(for: target) == .grab)
    }
}
