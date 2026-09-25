import CoreGraphics
import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// m23-ap interaction batch I0 — `PitchEditorViewport`, the pitch editor's
/// viewport seam: where the scrollers look, and the zoom re-pin every driver
/// shares (design `2026-09-24-pitch-editor-interaction-batch.md` §3 items 1 & 4).
///
/// ⭐ **THE ROLL'S LITERAL FIXTURES.** `PianoRollZoomTests` pins "playhead at
/// content 500, scroller at 200, 900 pt viewport → anchor 300" and the anchored
/// zoom's arithmetic; these legs run the same numbers through this pane's own
/// geometry, so a disagreement between the two editors would show here.
///
/// ⚠️ NOT `@MainActor`: every subject is a pure value (`PitchEditorViewport`,
/// `PitchEditorGeometry`, the shared zoom enums), and an isolated suite would
/// spend one of the review-cadence slots `MainActorOccupancySiteTests` bounds.
@Suite("PitchEditorViewport — the pitch editor's scroll seam and zoom re-pin (m23-ap I0)")
struct PitchEditorViewportTests {

    // MARK: - Fixtures

    /// A long clip starting at beat 8 (so clip-local x is NOT project x), 120
    /// beats at 120 bpm (60 s of source, ratio 1), a 36-row pitch window.
    private static func geometry(ppb: CGFloat = 32, rowHeight: CGFloat = 14) -> PitchEditorGeometry {
        PitchEditorGeometry(sourceWindowStartSeconds: 0, sourceWindowSeconds: 60,
                            startBeat: 8, lengthBeats: 120,
                            tempoMap: TempoMap(constantBPM: 120),
                            pixelsPerBeat: ppb, midiRange: 48...83, rowHeight: rowHeight)
    }

    /// The project beat whose clip-local content x is `contentX` at `ppb`.
    private static func beat(atContentX contentX: CGFloat, ppb: CGFloat) -> Double {
        8 + Double(contentX / ppb)
    }

    private static func viewport(offsetX: CGFloat = 200, offsetY: CGFloat = 0,
                                 geometry: PitchEditorGeometry = Self.geometry()) -> PitchEditorViewport {
        PitchEditorViewport(offset: CGPoint(x: offsetX, y: offsetY),
                            viewportSize: CGSize(width: 900, height: 200),
                            contentSize: CGSize(width: geometry.contentWidth,
                                                height: geometry.contentHeight))
    }

    // MARK: - The value

    @Test("local/content round-trip, and maxOffset is content − viewport, floored at 0")
    func localContentAndMaxOffset() {
        let v = Self.viewport(offsetX: 200, offsetY: 30)
        #expect(v.local(CGPoint(x: 500, y: 100)) == CGPoint(x: 300, y: 70))
        #expect(v.content(CGPoint(x: 300, y: 70)) == CGPoint(x: 500, y: 100))
        // 120 beats × 32 = 3840 wide; 36 rows × 14 = 504 tall.
        #expect(v.maxOffset == CGPoint(x: 3840 - 900, y: 504 - 200))
        // A content smaller than its viewport scrolls nowhere — never backwards.
        let small = PitchEditorViewport(offset: .zero, viewportSize: CGSize(width: 900, height: 600),
                                        contentSize: CGSize(width: 300, height: 504))
        #expect(small.maxOffset == .zero)
        #expect(v.isMeasured)
        #expect(!PitchEditorViewport.unmeasured.isMeasured)
    }

    @Test("clamped pulls any proposal into 0…maxOffset, NaN included")
    func clampedIsTotal() {
        let v = Self.viewport()
        #expect(v.clamped(CGPoint(x: -50, y: -1)) == .zero)
        #expect(v.clamped(CGPoint(x: 99_999, y: 99_999)) == v.maxOffset)
        #expect(v.clamped(CGPoint(x: 1234, y: 56)) == CGPoint(x: 1234, y: 56))
        #expect(v.clamped(CGPoint(x: CGFloat.nan, y: .infinity)) == CGPoint(x: 0, y: 0))
    }

    // MARK: - The time re-pin: measured at the OLD scale

    /// ⛔⛔ **THE TRAP THIS LEG EXISTS FOR.** The pane re-pins from the ppb slot's
    /// `onChange`, where the geometry may already carry the NEW scale. The
    /// anchor must be measured at the OLD one regardless — so the geometry here
    /// is handed in ALREADY RESCALED, exactly as the view hands it, and the
    /// anchor must still be the roll's 300.
    @Test("⛔ the anchor is the playhead's screen x MEASURED AT THE OLD SCALE, even from a rescaled geometry")
    func anchorIsMeasuredAtTheOldScale() {
        let playhead = Self.beat(atContentX: 500, ppb: 32)          // content 500 at 32
        let v = Self.viewport(offsetX: 200)
        for handedIn in [CGFloat(32), 40] {                         // either scale
            let anchor = v.timeZoomAnchor(geometry: Self.geometry(ppb: handedIn), oldPPB: 32,
                                          playheadProjectBeat: playhead)
            #expect(anchor.screenX == 300, "geometry handed in at \(handedIn) pt/beat")
            #expect(anchor.ppb == 32)
            #expect(anchor.offset == 200)
        }
    }

    @Test("⭐ one zoom step holds the playhead's screen x — the roll's fixture, 32 → 40 pt/beat")
    func oneStepHoldsThePlayhead() {
        let playhead = Self.beat(atContentX: 500, ppb: 32)
        let v = Self.viewport(offsetX: 200)
        // The view's order: the slot's onChange has ALREADY rescaled the geometry.
        let rescaled = Self.geometry(ppb: 40)
        let offset = v.timeZoomOffset(geometry: rescaled, oldPPB: 32, newPPB: 40,
                                      playheadProjectBeat: playhead)
        #expect(offset == 325)                                      // (200+300)/32·40 − 300
        let screenX = rescaled.x(forProjectBeat: playhead) - (offset ?? .nan)
        #expect(abs(screenX - 300) < 1e-9)
        // THE SAME ANSWER from a geometry still at the old scale: the function
        // measures at `oldPPB` whatever it is handed.
        #expect(v.timeZoomOffset(geometry: Self.geometry(ppb: 32), oldPPB: 32, newPPB: 40,
                                 playheadProjectBeat: playhead) == 325)

        // NEGATIVE CONTROL — the anchor measured at the NEW scale (the plant this
        // leg must catch) is a plausible number that DRIFTS the line: 625 − 200
        // = 425 → offset 356.25 → the playhead lands at 268.75, not 300. If
        // this ever stopped drifting, the assertion above would prove nothing.
        let wrongAnchor = rescaled.x(forProjectBeat: playhead) - 200
        let wrongOffset = ArrangeZoom.offsetPreservingAnchor(oldPPB: 32, newPPB: 40, oldOffset: 200,
                                                             anchorScreenX: wrongAnchor)
        let drift = (rescaled.x(forProjectBeat: playhead) - wrongOffset) - 300
        #expect(abs(drift) > 1, "the new-scale control failed to drift (\(drift) pt)")
    }

    /// The looked-at item's claim, headless: three presses of the ladder with the
    /// playhead mid-view, each re-pin fed the offset the previous one produced.
    @Test("three zoom steps in a row keep the playhead exactly where it was on screen")
    func threeStepsHoldThePlayhead() {
        let playhead = Self.beat(atContentX: 500, ppb: 32)
        var ppb: CGFloat = 32
        var v = Self.viewport(offsetX: 200)
        for step in 1...3 {
            let next = PianoRollZoom.zoomedIn(ppb)
            let geometry = Self.geometry(ppb: next)
            guard let offset = v.timeZoomOffset(geometry: geometry, oldPPB: ppb, newPPB: next,
                                                playheadProjectBeat: playhead) else {
                Issue.record("step \(step) did not re-pin")
                return
            }
            let screenX = geometry.x(forProjectBeat: playhead) - offset
            #expect(abs(screenX - 300) < 1e-9, "step \(step): \(ppb) → \(next), line at \(screenX)")
            v.offset.x = offset
            v.contentSize.width = geometry.contentWidth
            ppb = next
        }
        #expect(ppb == 62.5)                                        // 32 · 1.25³
    }

    @Test("off-clip, or scrolled out of frame, the anchor is the viewport CENTRE (the shared rule's own)")
    func centreWhenThePlayheadIsNotInFrame() {
        let centre = ArrangeZoom.anchorScreenX(playheadContentX: .infinity, offset: 0, viewportWidth: 900)
        #expect(centre == 450)
        let v = Self.viewport(offsetX: 200)
        // Before the clip (beat 2 < startBeat 8): no line is drawn to hold.
        #expect(v.timeZoomAnchor(geometry: Self.geometry(), oldPPB: 32,
                                 playheadProjectBeat: 2).screenX == centre)
        // Past its end (8 + 120): the half-open window excludes the end beat.
        #expect(v.timeZoomAnchor(geometry: Self.geometry(), oldPPB: 32,
                                 playheadProjectBeat: 128).screenX == centre)
        // Inside the clip but scrolled out of frame (content 100, offset 200).
        #expect(v.timeZoomAnchor(geometry: Self.geometry(), oldPPB: 32,
                                 playheadProjectBeat: Self.beat(atContentX: 100, ppb: 32)).screenX
                == centre)
    }

    @Test("zooming OUT near the end clamps to the NEW content's end — the anchor gives way there")
    func timeZoomOutClampsToTheNewContent() {
        let v = Self.viewport(offsetX: 3840 - 900)                  // parked at the end, at 32
        let out = PianoRollZoom.zoomedOut(32)                       // 25.6
        let playheadOffFrame: Double = 2                            // centre anchor
        let offset = v.timeZoomOffset(geometry: Self.geometry(ppb: out), oldPPB: 32, newPPB: out,
                                      playheadProjectBeat: playheadOffFrame)
        let newMax = 120 * out - 900                                // 2172
        #expect(offset == newMax)
        // The control: the raw anchored offset DOES overshoot here, so the clamp
        // is load-bearing — a marker that long would not fit on its content.
        let raw = ArrangeZoom.offsetPreservingAnchor(oldPPB: 32, newPPB: out, oldOffset: 3840 - 900,
                                                     anchorScreenX: 450)
        #expect(raw > newMax)
    }

    @Test("nothing to re-pin: an unchanged scale, or a viewport not yet laid out")
    func nothingToRepin() {
        let playhead = Self.beat(atContentX: 500, ppb: 32)
        #expect(Self.viewport().timeZoomOffset(geometry: Self.geometry(), oldPPB: 32, newPPB: 32,
                                               playheadProjectBeat: playhead) == nil)
        #expect(PitchEditorViewport.unmeasured.timeZoomOffset(
            geometry: Self.geometry(), oldPPB: 32, newPPB: 40, playheadProjectBeat: playhead) == nil)
        #expect(Self.viewport().rowZoomOffset(geometry: Self.geometry(), oldRowHeight: 14,
                                              newRowHeight: 14) == nil)
        #expect(PitchEditorViewport.unmeasured.rowZoomOffset(
            geometry: Self.geometry(), oldRowHeight: 14, newRowHeight: 17.5) == nil)
    }

    /// The I2 seam: a pinch hands in the anchor it captured at gesture start, and
    /// that anchor — the POINTER — wins over the playhead for the whole gesture.
    @Test("a gesture's pointer anchor wins over the playhead: the beat under the pointer holds")
    func pointerAnchorWins() {
        let playhead = Self.beat(atContentX: 500, ppb: 32)          // screen 300
        let v = Self.viewport(offsetX: 200)
        let pointer = PitchEditorZoomAnchor(ppb: 32, offset: 200, screenX: 120)
        let geometry = Self.geometry(ppb: 40)
        guard let offset = v.timeZoomOffset(geometry: geometry, oldPPB: 32, newPPB: 40,
                                            playheadProjectBeat: playhead,
                                            pointerAnchor: pointer) else {
            Issue.record("no re-pin")
            return
        }
        // The pointer's beat: (200 + 120) / 32 = 10 clip-local beats → 400 at 40.
        #expect(abs((10 * 40 - offset) - 120) < 1e-9)
        // …and the playhead is NOT the anchor now: it moves on screen.
        #expect(abs((geometry.x(forProjectBeat: playhead) - offset) - 300) > 1)
    }

    // MARK: - The row re-pin: the centre row, against THIS pane's content

    @Test("⭐ a row-height zoom holds the pitch at the viewport's centre")
    func rowZoomHoldsTheCentrePitch() {
        let old = Self.geometry(rowHeight: 14)
        let v = Self.viewport(offsetY: 150, geometry: old)          // viewport height 200
        let centrePitch = old.midi(forY: 150 + 100)
        for newRow in [17.5 as CGFloat, 10, 28] {
            let rescaled = Self.geometry(rowHeight: newRow)
            guard let offset = v.rowZoomOffset(geometry: rescaled, oldRowHeight: 14,
                                               newRowHeight: newRow) else {
                Issue.record("no re-pin at \(newRow)")
                continue
            }
            let maxOffset = rescaled.contentHeight - 200
            let after = rescaled.midi(forY: offset + 100)
            if offset < maxOffset {
                #expect(abs(after - centrePitch) < 1e-9, "row 14 → \(newRow): \(centrePitch) → \(after)")
            }
            // NEGATIVE CONTROL — keep the old offset and the centre pitch moves by
            // more than a row: the anchored answer above is doing the work.
            #expect(abs(rescaled.midi(forY: 150 + 100) - centrePitch) > 1,
                    "the un-anchored control failed to drift at row \(newRow)")
        }
        let literal = v.rowZoomOffset(geometry: Self.geometry(rowHeight: 17.5), oldRowHeight: 14,
                                      newRowHeight: 17.5) ?? .nan
        #expect(abs(literal - 212.5) < 1e-9)                        // 250/14·17.5 − 100
    }

    /// ⚠️ **THE SOURCE CONTRADICTS DESIGN §3 HERE, AND THIS LEG PINS WHY.** §3
    /// names `PianoRollZoom.rowZoomOffset` for this axis. That function clamps
    /// against the ROLL's 128 rows; this pane's content is its 36-row window. At
    /// the bottom of the window, zooming out, the roll's answer overshoots this
    /// pane's content — a marker that long would not fit on the ruler it hangs on.
    @Test("the row clamp is this pane's OWN window, not the roll's 128 rows")
    func rowClampIsThisPanesContent() {
        let old = Self.geometry(rowHeight: 14)                      // 504 tall
        let bottom: CGFloat = 504 - 200
        let v = Self.viewport(offsetY: bottom, geometry: old)
        let offset = v.rowZoomOffset(geometry: Self.geometry(rowHeight: 10), oldRowHeight: 14,
                                     newRowHeight: 10)
        let newMax: CGFloat = 36 * 10 - 200                         // 160
        #expect(offset == newMax)
        // The roll's function, on the same inputs, is not clamped by this content.
        let roll = PianoRollZoom.rowZoomOffset(oldRowHeight: 14, newRowHeight: 10,
                                               oldOffset: bottom, viewportHeight: 200)
        #expect(roll > newMax, "the roll's clamp was expected to overshoot this pane (got \(roll))")
    }

    /// m23-ap I6c — the pitch window is FILLED to the pane at the current row
    /// height, so a row zoom can add or drop rows ABOVE the notes, and the
    /// window's top moves. The borrowed arithmetic assumes it does not.
    @Test("I6c — a row zoom that MOVES the window's top still holds the centre pitch, given the old window; with none it is the old arithmetic exactly")
    func i6cRowZoomHoldsTheCentreAcrossAWindowChange() {
        // At 14 pt the pane showed 40…72 (33 rows, 462 pt), scrolled to 150 in a
        // 200 pt viewport. At 17.5 pt the fill leaves 40…70: the top came DOWN two.
        var old = Self.geometry(rowHeight: 14)
        old.midiRange = 40...72
        var new = Self.geometry(rowHeight: 17.5)
        new.midiRange = 40...70
        let v = Self.viewport(offsetY: 150, geometry: old)
        let centrePitch = old.midi(forY: 150 + 100)                 // 72.5 − 250/14
        guard let offset = v.rowZoomOffset(geometry: new, oldRowHeight: 14, newRowHeight: 17.5,
                                           oldMidiRange: old.midiRange) else {
            Issue.record("no re-pin")
            return
        }
        #expect(abs(offset - 177.5) < 1e-9)                         // (70.5 − centre)·17.5 − 100
        #expect(abs(new.midi(forY: offset + 100) - centrePitch) < 1e-9)
        // NEGATIVE CONTROL — the same call WITHOUT the old window is the borrowed
        // arithmetic (250/14·17.5 − 100 = 212.5), and it misses the centre pitch
        // by exactly the two rows that left the top.
        let blind = v.rowZoomOffset(geometry: new, oldRowHeight: 14, newRowHeight: 17.5) ?? .nan
        #expect(abs(blind - 212.5) < 1e-9)
        #expect(abs((centrePitch - new.midi(forY: blind + 100)) - 2) < 1e-9)
        // An UNCHANGED window takes the old path, to the bit: the roll fixture's 212.5.
        let same = Self.viewport(offsetY: 150)
        #expect(same.rowZoomOffset(geometry: Self.geometry(rowHeight: 17.5), oldRowHeight: 14,
                                   newRowHeight: 17.5, oldMidiRange: 48...83)
                == same.rowZoomOffset(geometry: Self.geometry(rowHeight: 17.5), oldRowHeight: 14,
                                      newRowHeight: 17.5))
    }
}
