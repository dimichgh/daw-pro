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

    // MARK: - I2 — the pinch: captured once, cumulative, the pointer's beat holds

    /// THE PINCH FIXTURE. Scrolled to 1000 at 32 pt/beat, the pointer at content
    /// 1300 — screen 300, clip beat 40.625 (project 48.625). The playhead is IN
    /// FRAME elsewhere (content 1600, screen 600), so a re-pin that fell back to
    /// the non-pointer rule would hold the wrong beat and show it.
    ///
    /// The sweep's scales run 16…96 pt/beat. Neither clamp may engage anywhere in
    /// it, or "the pointer holds" would be measuring a clamp: the anchored offset
    /// 40.625·p − 300 is ≥ 350 at p = 16 (the 0 floor is far), and the room to
    /// the new content's end, (120·p − 900) − (40.625·p − 300) = 79.375·p − 600,
    /// is ≥ 670 at p = 16. The sweep leg ALSO asserts both margins on every tick,
    /// so this arithmetic is checked, not trusted.
    private static let pinchStart = CGPoint(x: 1300, y: 100)
    private static let pinchStartOffset: CGFloat = 1000
    private static let pinchPointerBeat = Self.beat(atContentX: 1300, ppb: 32)     // 48.625
    private static let pinchPlayhead = Self.beat(atContentX: 1600, ppb: 32)        // screen 600

    /// ~40 ticks the way a hand pinches: in to ×3, then back out past the start
    /// to ×0.5. Cumulative ratios, as `MagnifyGesture` reports them.
    private static let pinchSweep: [CGFloat] =
        (1...20).map { 1 + 2 * CGFloat($0) / 20 } + (1...20).map { 3 - 2.5 * CGFloat($0) / 20 }

    /// How a sweep's anchor is obtained, per tick.
    private enum PinchAnchoring {
        /// The product: `PitchEditorPinch.tick`, which captures on the first tick only.
        case captureOnce
        /// ⛔ CONTROL — re-derived EVERY tick from the live viewport and the fixed
        /// `startLocation` (the plant "the reducer recaptures on every tick", with
        /// the scale held correct so the anchor's drift is all that is measured).
        case recaptureEveryTick
        /// ⛔ CONTROL — the offset re-read from the live viewport every tick with
        /// the screen x held: exact only while every scroll lands before the next
        /// tick, which a real pane does not promise.
        case liveOffsetEveryTick
    }

    /// Runs the sweep through the pane's loop, headless: tick → the slot → the
    /// ONE re-pin (`timeZoomOffset(pointerAnchor:)`) → the scroller. `lag` is how
    /// many ticks the MEASURED offset trails the re-pin that was issued (0 = every
    /// scroll lands before the next tick). Returns the pointer's screen x after
    /// each tick, the offsets issued, and whether either clamp ever engaged.
    private static func runPinchSweep(_ anchoring: PinchAnchoring, lag: Int)
        -> (screenXs: [CGFloat], offsets: [CGFloat], finalPPB: CGFloat, clampEngaged: Bool) {
        var slot: CGFloat = 32
        var issued: [CGFloat] = [Self.pinchStartOffset]
        var anchor: PitchEditorZoomAnchor?
        var screenXs: [CGFloat] = []
        var clampEngaged = false
        for magnification in Self.pinchSweep {
            let measured = issued[max(0, issued.count - 1 - lag)]
            let v = Self.viewport(offsetX: measured, geometry: Self.geometry(ppb: slot))
            let tick: (anchor: PitchEditorZoomAnchor, ppb: CGFloat)
            switch anchoring {
            case .captureOnce:
                tick = PitchEditorPinch.tick(anchor: anchor, viewport: v, startLocation: Self.pinchStart,
                                             currentPPB: slot, magnification: magnification)
            case .recaptureEveryTick:
                tick = (v.pinchAnchor(startLocation: Self.pinchStart, ppb: slot),
                        PianoRollZoom.clamp(32 * magnification))
            case .liveOffsetEveryTick:
                tick = (PitchEditorZoomAnchor(ppb: slot, offset: v.offset.x, screenX: 300),
                        PianoRollZoom.clamp(32 * magnification))
            }
            anchor = tick.anchor
            let rescaled = Self.geometry(ppb: tick.ppb)
            guard let offset = v.timeZoomOffset(geometry: rescaled, oldPPB: slot, newPPB: tick.ppb,
                                                playheadProjectBeat: Self.pinchPlayhead,
                                                pointerAnchor: tick.anchor) else {
                Issue.record("×\(magnification): \(slot) → \(tick.ppb) did not re-pin")
                continue
            }
            if !(offset > 0 && offset < rescaled.contentWidth - 900) { clampEngaged = true }
            issued.append(offset)
            slot = tick.ppb
            screenXs.append(rescaled.x(forProjectBeat: Self.pinchPointerBeat) - offset)
        }
        return (screenXs, Array(issued.dropFirst()), slot, clampEngaged)
    }

    @Test("I2 ⛔ the pinch anchor is CAPTURED ONCE: a later tick keeps it, whatever the viewport and scale are now")
    func pinchAnchorIsCapturedOnce() {
        let v0 = Self.viewport(offsetX: Self.pinchStartOffset)
        let first = PitchEditorPinch.tick(anchor: nil, viewport: v0, startLocation: Self.pinchStart,
                                          currentPPB: 32, magnification: 1.1)
        // The first tick measures the start: 32 pt/beat, offset 1000, screen 1300 − 1000.
        #expect(first.anchor == PitchEditorZoomAnchor(ppb: 32, offset: 1000, screenX: 300))
        #expect(first.anchor == v0.pinchAnchor(startLocation: Self.pinchStart, ppb: 32))
        // The second tick sees the pinch's OWN output: the scroll moved, the slot
        // moved, and it is even handed a different start point. None of it counts.
        let moved = Self.viewport(offsetX: 1130, geometry: Self.geometry(ppb: first.ppb))
        let second = PitchEditorPinch.tick(anchor: first.anchor, viewport: moved,
                                           startLocation: CGPoint(x: 777, y: 3),
                                           currentPPB: first.ppb, magnification: 1.2)
        #expect(second.anchor == first.anchor)
        // NEGATIVE CONTROL — capturing afresh from that viewport is a DIFFERENT
        // anchor, off by more than the leg's tolerance. If it were not, the
        // equality above would prove nothing.
        let fresh = moved.pinchAnchor(startLocation: Self.pinchStart, ppb: first.ppb)
        #expect(fresh != first.anchor)
        #expect(abs(fresh.screenX - first.anchor.screenX) > 0.5,
                "a re-captured anchor failed to differ (\(fresh.screenX) vs \(first.anchor.screenX))")
    }

    @Test("I2 ⛔ magnification is CUMULATIVE: ×1.1 then ×1.2 is the start scale ×1.2, never ×1.1×1.2")
    func pinchMagnificationIsCumulative() {
        let v = Self.viewport(offsetX: Self.pinchStartOffset)
        let t1 = PitchEditorPinch.tick(anchor: nil, viewport: v, startLocation: Self.pinchStart,
                                       currentPPB: 32, magnification: 1.1)
        #expect(abs(t1.ppb - 35.2) < 1e-9)
        let t2 = PitchEditorPinch.tick(anchor: t1.anchor, viewport: v, startLocation: Self.pinchStart,
                                       currentPPB: t1.ppb, magnification: 1.2)
        #expect(abs(t2.ppb - 38.4) < 1e-9, "×1.2 of the START scale (32) is 38.4, got \(t2.ppb)")
        // A hand that opens and closes again lands EXACTLY on the start scale —
        // which only a start-scale product can do.
        let back = PitchEditorPinch.tick(anchor: t2.anchor, viewport: v, startLocation: Self.pinchStart,
                                         currentPPB: t2.ppb, magnification: 1.0)
        #expect(back.ppb == 32)
        // NEGATIVE CONTROL — a scale compounded from the last tick lands on the
        // wrong scale (42.24), and after the return it would never come home.
        let compounded = PianoRollZoom.clamp(t1.ppb * 1.2)
        #expect(abs(compounded - 42.24) < 1e-9)
        #expect(abs(compounded - t2.ppb) > 1, "the compounding control failed to differ")
        #expect(abs(PianoRollZoom.clamp(compounded * 1.0) - 32) > 1)
    }

    @Test("I2 ⭐ over a 40-tick pinch in and out, the beat under the pointer stays within 0.5 pt of where it started")
    func pinchHoldsThePointersBeat() {
        let run = Self.runPinchSweep(.captureOnce, lag: 0)
        #expect(run.screenXs.count == 40)
        #expect(!run.clampEngaged, "the fixture let a clamp engage — the hold below would be measuring it")
        for (index, screenX) in run.screenXs.enumerated() {
            #expect(abs(screenX - 300) < 0.5,
                    "tick \(index + 1) (×\(Self.pinchSweep[index])): the pointer's beat is at \(screenX), not 300")
        }
        #expect(run.finalPPB == 16)                                     // 32 × 0.5, no ladder clamp
        // ⭐ AND THE RE-PIN NEVER READS THE MEASURED OFFSET WHILE A PINCH OWNS THE
        // ANCHOR: a pane whose scroll lands a tick or three late issues the SAME
        // offsets, to the bit. That is the real pane's case (the readers report
        // a landing a body pass after the `scrollTo`).
        for lag in [1, 3] {
            #expect(Self.runPinchSweep(.captureOnce, lag: lag).offsets == run.offsets, "lag \(lag)")
        }

        // NEGATIVE CONTROLS — each re-derives the anchor per tick and drifts.
        // (1) Recaptured from the fixed start point: wrong beat from tick 2 on.
        let recaptured = Self.runPinchSweep(.recaptureEveryTick, lag: 0)
        let recapturedDrift = recaptured.screenXs.map { abs($0 - 300) }.max() ?? 0
        #expect(recapturedDrift > 0.5, "the recapture control failed to drift (\(recapturedDrift) pt)")
        // (2) The live offset with the screen x held: exact while every scroll
        // lands in time, wrong as soon as one is late — the lag the pane has.
        let onTime = Self.runPinchSweep(.liveOffsetEveryTick, lag: 0)
        #expect(onTime.screenXs.allSatisfy { abs($0 - 300) < 0.5 })
        let late = Self.runPinchSweep(.liveOffsetEveryTick, lag: 1)
        let lateDrift = late.screenXs.map { abs($0 - 300) }.max() ?? 0
        #expect(lateDrift > 0.5, "the late-scroll control failed to drift (\(lateDrift) pt)")
    }

    @Test("I2 — zooming OUT with the pointer near the clip's start floors the offset at 0, and the anchor gives way")
    func pinchOutAtTheFloorGivesWay() {
        // Scrolled to 40, the pointer at screen 200: content 240, clip beat 7.5.
        let v = Self.viewport(offsetX: 40)
        let start = CGPoint(x: 240, y: 100)
        let pointerBeat = Self.beat(atContentX: 240, ppb: 32)
        let tick = PitchEditorPinch.tick(anchor: nil, viewport: v, startLocation: start,
                                         currentPPB: 32, magnification: 0.5)
        #expect(tick.ppb == 16)
        let rescaled = Self.geometry(ppb: 16)
        let offset = v.timeZoomOffset(geometry: rescaled, oldPPB: 32, newPPB: 16,
                                      playheadProjectBeat: Self.pinchPlayhead, pointerAnchor: tick.anchor)
        // Holding the beat would need 7.5 · 16 − 200 = −80: past the clip's start.
        #expect(offset == 0)
        // So the beat lands at 120, 80 pt left of the pointer — the one edge
        // where it cannot hold (the new-content end is the other).
        #expect(abs((rescaled.x(forProjectBeat: pointerBeat) - (offset ?? .nan)) - 120) < 1e-9)
        // CONTROL — the same pointer zooming IN holds exactly: the floor, not the
        // anchor, is what moved the beat above.
        let into = PitchEditorPinch.tick(anchor: nil, viewport: v, startLocation: start,
                                         currentPPB: 32, magnification: 1.5)
        let deeper = Self.geometry(ppb: into.ppb)
        let inOffset = v.timeZoomOffset(geometry: deeper, oldPPB: 32, newPPB: into.ppb,
                                        playheadProjectBeat: Self.pinchPlayhead, pointerAnchor: into.anchor)
        #expect(abs((deeper.x(forProjectBeat: pointerBeat) - (inOffset ?? .nan)) - 200) < 1e-9)
    }

    @Test("I2 — past either end of the ladder the scale clamps to 4 or 200, and a repeated clamped tick re-pins nothing")
    func pinchClampsAtTheLadderEnds() {
        let v = Self.viewport(offsetX: Self.pinchStartOffset)
        let range = PianoRollZoom.pixelsPerBeatRange                    // 4…200
        func tick(_ anchor: PitchEditorZoomAnchor?, _ current: CGFloat, _ m: CGFloat)
            -> (anchor: PitchEditorZoomAnchor, ppb: CGFloat) {
            PitchEditorPinch.tick(anchor: anchor, viewport: v, startLocation: Self.pinchStart,
                                  currentPPB: current, magnification: m)
        }
        func repin(from old: CGFloat, to new: CGFloat, _ anchor: PitchEditorZoomAnchor) -> CGFloat? {
            v.timeZoomOffset(geometry: Self.geometry(ppb: new), oldPPB: old, newPPB: new,
                             playheadProjectBeat: Self.pinchPlayhead, pointerAnchor: anchor)
        }
        // IN: ×10 of 32 asks for 320 and gets the top of the ladder.
        let top = tick(nil, 32, 10)
        #expect(top.ppb == range.upperBound)
        #expect(repin(from: 32, to: top.ppb, top.anchor) != nil)
        // The hand keeps opening: still 200, and a scale that did not move is
        // nothing to re-pin — no scroll write at pointer rate against a wall.
        let stillTop = tick(top.anchor, top.ppb, 12)
        #expect(stillTop.ppb == range.upperBound)
        #expect(repin(from: top.ppb, to: stillTop.ppb, stillTop.anchor) == nil)
        // CONTROL — one hair back inside the ladder DOES re-pin: the nil above is
        // the clamp, not a re-pin that never runs.
        let offTheWall = tick(top.anchor, top.ppb, 6.2)
        #expect(offTheWall.ppb < range.upperBound)
        #expect(repin(from: top.ppb, to: offTheWall.ppb, offTheWall.anchor) != nil)
        // OUT: ×0.05 asks for 1.6 and gets the bottom; so do a zero and a
        // negative ratio (the arrange's 0.001 floor, then the ladder).
        let bottom = tick(nil, 32, 0.05)
        #expect(bottom.ppb == range.lowerBound)
        #expect(tick(bottom.anchor, bottom.ppb, 0).ppb == range.lowerBound)
        #expect(tick(bottom.anchor, bottom.ppb, -3).ppb == range.lowerBound)
        #expect(repin(from: bottom.ppb, to: tick(bottom.anchor, bottom.ppb, 0.01).ppb, bottom.anchor) == nil)
        // A non-finite ratio asks for no change at all: the start scale.
        #expect(tick(nil, 32, .nan).ppb == 32)
        #expect(tick(nil, 32, .infinity).ppb == 32)
    }

    @Test("I2 — the staged pinch's two steps carry their own echo keys; a surface report starts with no live pinch; the hint says what the pinch does")
    func stagedPinchKeysAndHint() {
        #expect(PitchEditorStagedStep.pinch(CGPoint(x: 1300, y: 100), 1.5).key == "pinch")
        #expect(PitchEditorStagedStep.pinchEnd.key == "pinchEnd")
        // Distinct from every other step's key: an echo that said "drag" for a
        // pinch would send a gate after the wrong fact.
        let others: [PitchEditorStagedStep] = [.hover(.zero), .hoverEnd, .press(.zero, .none),
                                               .drag(.zero, .none), .release(.zero, .none),
                                               .scroll(x: 0, y: nil), .noteMenu(.clear, nil)]
        #expect(Set(others.map(\.key)).isDisjoint(with: ["pinch", "pinchEnd"]))
        #expect(PitchEditorSurfaceReport().pinchAnchor == nil)
        #expect(PitchEditorSurfaceReport.empty.pinchAnchor == nil)
        #expect(PitchEditorZoomHint.pinchTime == "Pinch to zoom time")
    }

    @Test("I5 — the staged ruler tick carries its own echo key; a surface report starts with no placement and no geometry")
    func stagedRulerKeyAndEmptyPlacement() {
        #expect(PitchEditorStagedStep.ruler(x: 120, .none).key == "ruler")
        let others: [PitchEditorStagedStep] = [.hover(.zero), .hoverEnd, .press(.zero, .none),
                                               .drag(.zero, .none), .release(.zero, .none),
                                               .tool(.pointer), .scroll(x: 0, y: nil),
                                               .noteMenu(.clear, nil), .pinch(.zero, 1), .pinchEnd]
        #expect(!others.map(\.key).contains("ruler"))
        #expect(PitchEditorSurfaceReport.empty.placementCount == 0)
        #expect(PitchEditorSurfaceReport.empty.lastPlacementBeat == nil)
        #expect(PitchEditorSurfaceReport.empty.geometry == nil)
    }

    /// The staged fixture's numbers (2026-09-25): the reader held 900 while a
    /// 1083 pt clip sat in a 1364 pt box, so the only position the scroller
    /// could show was 0.
    @Test("I5 — the ruler's offset is one the scroller can SHOW: a stale measured offset over fitting content reads 0, in-range passes through, past the end pins to the end")
    func shownOffsetIsTheScrollersRange() {
        let fits = PitchEditorViewport(offset: CGPoint(x: 900, y: 40),
                                       viewportSize: CGSize(width: 1364, height: 180),
                                       contentSize: CGSize(width: 1083, height: 294))
        #expect(fits.maxOffset.x == 0)
        #expect(fits.shownOffsetX == 0)
        #expect(fits.offset.x == 900)   // the measurement itself is left alone

        let wider = PitchEditorViewport(offset: CGPoint(x: 700, y: 0),
                                        viewportSize: CGSize(width: 1364, height: 180),
                                        contentSize: CGSize(width: 2166, height: 294))
        #expect(wider.shownOffsetX == 700)

        var past = wider
        past.offset.x = 1500
        #expect(past.shownOffsetX == 802)   // 2166 − 1364

        var negative = wider
        negative.offset.x = -12
        #expect(negative.shownOffsetX == 0)
    }
}

// MARK: - I0-F — no scroll write while the NEW content fits (W7-NTU)

extension PitchEditorViewportTests {

    /// The fixture's geometry at `ppb` in a viewport `width` wide, scrolled to
    /// `offsetX` (the reader's value, stale or not).
    private static func viewport(width: CGFloat, offsetX: CGFloat, ppb: CGFloat) -> PitchEditorViewport {
        let geometry = Self.geometry(ppb: ppb)
        return PitchEditorViewport(offset: CGPoint(x: offsetX, y: 0),
                                   viewportSize: CGSize(width: width, height: 200),
                                   contentSize: CGSize(width: geometry.contentWidth,
                                                       height: geometry.contentHeight))
    }

    /// Planted and seen red (W7-NTU P-I0F): the `limit > 0` guard removed —
    /// the re-pin then answers 0 for a content that fits, and the pane issues
    /// the `scrollTo` that left the reader stale.
    ///
    /// ⚠️ WHAT THIS PROVES, AND WHAT IT CANNOT: the pane ASKS for no scroll
    /// when the new content fits. That the scroller then sits at 0 by itself
    /// and SwiftUI's reader stays true across the second fit-zoom (the 36-of-57
    /// race) is a drawn-window fact; `shownOffsetX`'s clamp stays as the net.
    @Test("I0-F — a time zoom whose NEW content fits the viewport re-pins nothing (no scrollTo); one point narrower a viewport, and it does")
    func noRepinWhileTheNewContentFits() {
        // The MEASURED case (`shownOffsetX`'s note): scrolled to 900 at 160
        // pt/beat, zoomed out until the clip fits — 1083 pt of content in a
        // 1364 pt box — then zoomed out AGAIN. Neither zoom may ask the
        // scroller for anything.
        let fit: CGFloat = 1083.0 / 120
        #expect(abs(Self.geometry(ppb: fit).contentWidth - 1083) < 1e-9)
        #expect(Self.viewport(width: 1364, offsetX: 900, ppb: 160).timeZoomOffset(
            geometry: Self.geometry(ppb: fit), oldPPB: 160, newPPB: fit, playheadProjectBeat: 2) == nil)
        let smaller = PianoRollZoom.zoomedOut(fit)
        #expect(smaller < fit)
        #expect(Self.viewport(width: 1364, offsetX: 900, ppb: fit).timeZoomOffset(
            geometry: Self.geometry(ppb: smaller), oldPPB: fit, newPPB: smaller, playheadProjectBeat: 2) == nil)
        // A pinch owning the anchor changes nothing: the content still fits.
        let pointer = PitchEditorZoomAnchor(ppb: 160, offset: 900, screenX: 400)
        #expect(Self.viewport(width: 1364, offsetX: 900, ppb: 160).timeZoomOffset(
            geometry: Self.geometry(ppb: fit), oldPPB: 160, newPPB: fit, playheadProjectBeat: 2,
            pointerAnchor: pointer) == nil)
        // THE BOUNDARY, in exact arithmetic (11.25 × 120 = 1350): a content
        // exactly as wide as its viewport has one position, so nothing…
        #expect(Self.viewport(width: 1350, offsetX: 900, ppb: 160).timeZoomOffset(
            geometry: Self.geometry(ppb: 11.25), oldPPB: 160, newPPB: 11.25, playheadProjectBeat: 2) == nil)
        // …and CONTROL: a viewport one point narrower leaves one point of
        // travel, so the re-pin RUNS. Parked at the END at 160 (19200 − 1349),
        // the centre's beat (~115.8) wants ~628 at the new scale, so what comes
        // back is the clamp to that one point. Were this nil too, the nils
        // above would prove nothing.
        let control = Self.viewport(width: 1349, offsetX: 19200 - 1349, ppb: 160).timeZoomOffset(
            geometry: Self.geometry(ppb: 11.25), oldPPB: 160, newPPB: 11.25, playheadProjectBeat: 2)
        #expect(control == 1, "the control did not re-pin to the one point of travel: \(String(describing: control))")
    }
}
