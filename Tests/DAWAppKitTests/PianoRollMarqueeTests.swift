import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// The piano roll's RUBBER-BAND geometry (m23-ek-1) — the headless half.
///
/// The band's whole correctness claim is **"a band and a click agree about
/// which notes are under the pointer"**, so most of this file is about the
/// *rect*, not about rect intersection. `PianoRollMarquee.hits` contains no beat
/// math and no pitch math at all; what it can get wrong is the overlap rule, and
/// what its CALLER can get wrong is which rectangle it is handed. Both are
/// pinned here, the second with a validity leg that runs the rejected rect and
/// asserts a DIFFERENT answer (the `ArrangeMarqueeTests` discriminator idiom —
/// a test that cannot tell the two apart proves nothing when it passes).
@MainActor
@Suite("PianoRollMarquee — the roll's rubber band (m23-ek-1)")
struct PianoRollMarqueeTests {

    private func makeModel(notes: [MIDINote] = [], length: Double = 8,
                           ppb: CGFloat = PianoRollModel.defaultPixelsPerBeat)
        -> PianoRollModel {
        PianoRollModel(notes: notes, clipLengthBeats: length, pixelsPerBeat: ppb)
    }

    // MARK: - Normalization

    @Test("band(from:to:) normalizes all four drag directions to the same rect")
    func bandNormalizes() {
        let a = CGPoint(x: 10, y: 20), b = CGPoint(x: 60, y: 90)
        let want = CGRect(x: 10, y: 20, width: 50, height: 70)
        #expect(PianoRollMarquee.band(from: a, to: b) == want)
        #expect(PianoRollMarquee.band(from: b, to: a) == want)
        #expect(PianoRollMarquee.band(from: CGPoint(x: 60, y: 20), to: CGPoint(x: 10, y: 90)) == want)
        #expect(PianoRollMarquee.band(from: CGPoint(x: 10, y: 90), to: CGPoint(x: 60, y: 20)) == want)
        // Negative extents cannot exist downstream — that is the point of
        // normalizing HERE rather than asking every consumer to remember.
        let band = PianoRollMarquee.band(from: b, to: a)
        #expect(band.width > 0 && band.height > 0)
    }

    // MARK: - Degenerate bands select nothing

    @Test("a degenerate band selects nothing — zero width, zero height, and both")
    func degenerateSelectsNothing() {
        let note = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 4)
        let m = makeModel(notes: [note])
        let rects = m.noteRects()
        let inside = CGPoint(x: m.x(forBeat: 2), y: m.y(forPitch: 60) + 5)

        // A press that never swept AREA — the important case, because it is what
        // a click is, and a band that selected on it would silently replace the
        // user's selection with a lucky hit.
        #expect(PianoRollMarquee.hits(
            band: PianoRollMarquee.band(from: inside, to: inside), rects: rects).isEmpty)
        // Zero width (a straight vertical drag) and zero height (a straight
        // horizontal one), both starting INSIDE the note.
        let vertical = CGPoint(x: inside.x, y: inside.y + 40)
        let horizontal = CGPoint(x: inside.x + 40, y: inside.y)
        #expect(PianoRollMarquee.hits(
            band: PianoRollMarquee.band(from: inside, to: vertical), rects: rects).isEmpty)
        #expect(PianoRollMarquee.hits(
            band: PianoRollMarquee.band(from: inside, to: horizontal), rects: rects).isEmpty)
        // VALIDITY: the same sweep with area DOES select it, so the three
        // assertions above are about degeneracy and not about a broken fixture.
        let real = CGPoint(x: inside.x + 40, y: inside.y + 5)
        #expect(PianoRollMarquee.hits(
            band: PianoRollMarquee.band(from: inside, to: real), rects: rects) == [note.id])
    }

    // MARK: - Touch, not containment

    @Test("TOUCH not containment: a note far wider than the band is still selected")
    func touchNotContainment() {
        // A 64-beat note at the default zoom is 2048 pt wide — no plausible
        // viewport contains it. Requiring containment would make it unselectable.
        let long = MIDINote(pitch: 72, startBeat: 0, lengthBeats: 64)
        let m = makeModel(notes: [long], length: 64)
        let band = CGRect(x: m.x(forBeat: 30), y: m.y(forPitch: 72) + 2, width: 4, height: 4)
        #expect(PianoRollMarquee.hits(band: band, rects: m.noteRects()) == [long.id])
    }

    @Test("STRICT overlap: a band whose edge exactly meets a note's edge selects nothing")
    func edgeExactIsStrict() {
        let note = MIDINote(pitch: 60, startBeat: 4, lengthBeats: 2)
        let m = makeModel(notes: [note], length: 16)
        let r = m.rect(for: note)

        // band.maxY == note.minY — the band stops exactly ON the row's top edge.
        let above = CGRect(x: r.minX + 1, y: r.minY - 10, width: 20, height: 10)
        #expect(above.maxY == r.minY)
        #expect(PianoRollMarquee.hits(band: above, rects: m.noteRects()).isEmpty)
        // band.maxX == note.minX — likewise on the left edge.
        let left = CGRect(x: r.minX - 20, y: r.minY + 2, width: 20, height: 4)
        #expect(left.maxX == r.minX)
        #expect(PianoRollMarquee.hits(band: left, rects: m.noteRects()).isEmpty)
        // VALIDITY: one point of overlap on each axis flips both to a hit.
        #expect(PianoRollMarquee.hits(
            band: above.insetBy(dx: 0, dy: -0.5), rects: m.noteRects()) == [note.id])
        #expect(PianoRollMarquee.hits(
            band: left.insetBy(dx: -0.5, dy: 0), rects: m.noteRects()) == [note.id])
    }

    // MARK: - THE F2 LEG: a band and a click agree on a very short note

    @Test("a 1/64 note at a low zoom: the band's x-range is EXACTLY the range a click accepts")
    func bandAgreesWithClickOnAVeryShortNote() {
        // 0.0625 beats at 8 px/beat is 0.5 px of real extent, floored to 3 by
        // `noteRect`'s minimum HIT width. Every candidate rect disagrees here,
        // which is what makes this the leg that matters.
        let ppb: CGFloat = 8
        let short = MIDINote(pitch: 64, startBeat: 2, lengthBeats: 0.0625)
        let m = makeModel(notes: [short], length: 8, ppb: ppb)
        let r = m.rect(for: short)
        #expect(r.width == 3)                       // the floor is really in play
        #expect(CGFloat(short.lengthBeats) * ppb < 3)

        let y = r.midY
        let rects = m.noteRects()
        // ⚠️ FIXTURE LAW — the sweep step must divide the rect's edges, and this
        // is asserted rather than assumed. A band [x, x+ε) is an OPEN interval,
        // so it and a point click legitimately disagree for x in
        // (minX − ε, minX): the band clips the note's left edge while the click
        // point has not reached it. Sampling on a grid that LANDS on both edges
        // keeps every sample outside that window, so any disagreement the loop
        // finds is the app's and never the fixture's.
        let step: CGFloat = 0.25
        #expect(r.minX.truncatingRemainder(dividingBy: step) == 0
                && r.maxX.truncatingRemainder(dividingBy: step) == 0,
                "sweep step \(step) must divide the hit rect's edges (\(r.minX)…\(r.maxX))")
        // Sweep a thin band across the whole neighbourhood and compare, point by
        // point, against what `hitTest` accepts.
        var disagreements: [CGFloat] = []
        var bandHits = 0, clickHits = 0
        var x = r.minX - 4
        while x <= r.maxX + 4 {
            let band = CGRect(x: x, y: y - 1, width: step, height: 2)
            let banded = !PianoRollMarquee.hits(band: band, rects: rects).isEmpty
            let clicked = m.hitTest(CGPoint(x: x + step / 2, y: y)) != nil
            if banded { bandHits += 1 }
            if clicked { clickHits += 1 }
            if banded != clicked { disagreements.append(x) }
            x += step
        }
        let note = "band and click disagree at x = \(disagreements) — the band is not using "
            + "`PianoRollModel.noteRect`"
        #expect(disagreements.isEmpty, "\(note)")
        // ANTI-VACUITY: both sides actually fired. A sweep that hit nothing
        // would agree perfectly and prove nothing.
        #expect(bandHits > 0 && clickHits > 0, "band=\(bandHits) click=\(clickHits)")
        // And the range is the floored one, not the note's real 0.5 pt extent.
        #expect(m.hitTest(CGPoint(x: r.minX + 2.9, y: y))?.id == short.id)
        #expect(m.hitTest(CGPoint(x: r.minX + 3.1, y: y)) == nil)
    }

    @Test("VALIDITY: the DRAWN (inset) rect gives a different answer — the test can tell them apart")
    func drawnRectIsADistinctAnswer() {
        // The discriminator leg. Without it, "the band agrees with the click"
        // could be passing because the fixture cannot see the difference.
        let ppb: CGFloat = 8
        let short = MIDINote(pitch: 64, startBeat: 2, lengthBeats: 0.0625)
        let m = makeModel(notes: [short], length: 8, ppb: ppb)
        let hit = m.rect(for: short)
        let drawn = hit.insetBy(dx: 0.5, dy: 1.5)           // PianoRollGrid's pill
        let drawnRects = [(id: short.id, rect: drawn)]

        // A 1 pt column at the note's right edge: inside the HIT rect, outside
        // the DRAWN one.
        let band = CGRect(x: hit.maxX - 0.5, y: hit.midY - 1, width: 0.4, height: 2)
        #expect(PianoRollMarquee.hits(band: band, rects: m.noteRects()) == [short.id])
        #expect(PianoRollMarquee.hits(band: band, rects: drawnRects).isEmpty)
        // …and the click agrees with the HIT rect, which is the whole point.
        #expect(m.hitTest(CGPoint(x: band.minX + 0.2, y: hit.midY))?.id == short.id)
    }

    @Test("a re-derived start·ppb…end·ppb rect ALSO disagrees — candidate #3, named and rejected")
    func reDerivedRectIsADistinctAnswer() {
        let ppb: CGFloat = 8
        let short = MIDINote(pitch: 64, startBeat: 2, lengthBeats: 0.0625)
        let m = makeModel(notes: [short], length: 8, ppb: ppb)
        let naive = CGRect(x: CGFloat(short.startBeat) * ppb,
                           y: CGFloat(127 - short.pitch) * m.rowHeight,
                           width: CGFloat(short.lengthBeats) * ppb,   // 0.5 pt — no floor
                           height: m.rowHeight)
        let band = CGRect(x: naive.maxX + 0.25, y: naive.midY - 1, width: 0.5, height: 2)
        #expect(PianoRollMarquee.hits(band: band, rects: m.noteRects()) == [short.id])
        #expect(PianoRollMarquee.hits(band: band, rects: [(id: short.id, rect: naive)]).isEmpty)
    }

    // MARK: - The uniform ladder, at several row heights and zooms

    @Test(arguments: [CGFloat(8), 32, 96])
    func bandPicksExactlyTheNotesItSweeps(ppb: CGFloat) {
        // Four notes: two inside the swept box, one a row above it, one a beat
        // past its right edge.
        let inA = MIDINote(pitch: 60, startBeat: 1, lengthBeats: 1)
        let inB = MIDINote(pitch: 62, startBeat: 2, lengthBeats: 1)
        let above = MIDINote(pitch: 64, startBeat: 1, lengthBeats: 1)
        let after = MIDINote(pitch: 61, startBeat: 6, lengthBeats: 1)
        let m = makeModel(notes: [inA, inB, above, after], length: 8, ppb: ppb)

        // Top of pitch 62's row to the bottom of pitch 60's; beats 0.5 … 3.5.
        let band = PianoRollMarquee.band(
            from: CGPoint(x: m.x(forBeat: 0.5), y: m.y(forPitch: 62) + 1),
            to: CGPoint(x: m.x(forBeat: 3.5), y: m.y(forPitch: 60) + m.rowHeight - 1))
        #expect(PianoRollMarquee.hits(band: band, rects: m.noteRects()) == [inA.id, inB.id])
    }

    @Test("the band follows a changed rowHeight — nothing here hardcodes 14")
    func bandFollowsRowHeight() {
        let note = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)
        let m = makeModel(notes: [note])
        m.rowHeight = 40
        // A band over the row pitch 60 occupies AT 40 pt/row. Under the old 14 pt
        // ladder this y is pitch 71's row and would select nothing.
        let y = m.y(forPitch: 60)
        #expect(y == CGFloat(127 - 60) * 40)
        let band = CGRect(x: 0, y: y + 2, width: 20, height: 4)
        #expect(PianoRollMarquee.hits(band: band, rects: m.noteRects()) == [note.id])
        #expect(PianoRollMarquee.hits(
            band: CGRect(x: 0, y: CGFloat(127 - 60) * 14 + 2, width: 20, height: 4),
            rects: m.noteRects()).isEmpty)
    }

    // MARK: - Selection policy (replace vs union onto a frozen base)

    @Test("a plain band REPLACES; an additive band UNIONS onto the frozen base")
    func replaceVersusUnion() {
        let a = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let b = MIDINote(pitch: 62, startBeat: 2, lengthBeats: 1)
        let m = makeModel(notes: [a, b])
        m.selectOnly(a.id)
        let base = m.selection

        m.applyMarquee(hits: [b.id], base: base, additive: false)
        #expect(m.selection == [b.id])

        m.applyMarquee(hits: [b.id], base: base, additive: true)
        #expect(m.selection == [a.id, b.id])

        // SHRINKING GIVES BACK: the same frozen base with an empty hit set
        // returns the selection to what it was at press, which is only possible
        // because the base is frozen rather than read live.
        m.applyMarquee(hits: [], base: base, additive: true)
        #expect(m.selection == [a.id])
        m.applyMarquee(hits: [], base: base, additive: false)
        #expect(m.selection.isEmpty)
    }

    // MARK: - The two travel thresholds are DIFFERENT decisions

    @Test("dragSlop and moveCommitSlop are separate constants, and dragSlop matches the arrange")
    func slopConstants() {
        // Not a tautology check: these two answer different questions
        // ("click or band?" vs "click or edit?") and were nearly merged in
        // design. If a future change makes them equal, that has to be a decision
        // someone took, not a coincidence nobody noticed.
        #expect(PianoRollMarquee.dragSlop == ArrangeMarquee.dragSlop)
        #expect(PianoRollMarquee.moveCommitSlop == 3)
        #expect(PianoRollMarquee.dragSlop != PianoRollMarquee.moveCommitSlop)
    }

    // MARK: - The staged-step value type

    @Test("PianoRollMarqueeStage.Action round-trips its wire spelling")
    func stageActionRawValues() {
        // The seam parses these strings straight off the wire, so a rename here
        // is a wire break even though the verb is debug tier.
        #expect(PianoRollMarqueeStage.Action(rawValue: "begin") == .begin)
        #expect(PianoRollMarqueeStage.Action(rawValue: "changed") == .changed)
        #expect(PianoRollMarqueeStage.Action(rawValue: "end") == .end)
        #expect(PianoRollMarqueeStage.Action(rawValue: "drag") == nil)
    }
}
