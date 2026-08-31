import Foundation
import Testing
@testable import DAWCore

/// m34-h-1 LIVE LOOPING — **the placement law, proved arithmetically.**
///
/// ⭐⭐ Every test here is a pure function of fabricated beats. That is
/// deliberate, and it is this milestone's own lesson: on m34-a-2 a test that
/// asserted "time has NOT yet passed" passed filtered in 0.69 s and FAILED in
/// the full suite at 11.81 s, because `Task.sleep(.milliseconds(200))` returns
/// seconds later under load. A quantized-launch bug looks exactly like "it
/// works" until the offsets are measured — so the offsets are measured here,
/// where a loaded machine cannot change the answer.
@Suite("Loop deck — placement arithmetic (m34-h-1)")
struct LoopDeckMathTests {

    // MARK: Grid

    @Test("a beat exactly ON a boundary returns THAT boundary, not the next one")
    func boundaryIsInclusive() {
        // The epsilon guard. Without it an arm pressed exactly on the downbeat
        // silently waits a whole extra bar — the single most likely way to ship
        // a launch-quantization bug that still looks like it works.
        #expect(LoopDeckMath.boundary(atOrAfter: 8, origin: 0, grid: 4) == 8)
        #expect(LoopDeckMath.boundary(atOrAfter: 8.000_000_001, origin: 0, grid: 4) == 8)
        #expect(LoopDeckMath.boundary(atOrAfter: 8.5, origin: 0, grid: 4) == 12)
        #expect(LoopDeckMath.boundary(atOrAfter: 0, origin: 0, grid: 4) == 0)
    }

    @Test("boundaries are measured from the deck ORIGIN, not from beat zero")
    func boundaryRespectsOrigin() {
        // A deck opened three bars into a song grids on ITS bar lines.
        #expect(LoopDeckMath.boundary(atOrAfter: 13, origin: 12, grid: 4) == 16)
        #expect(LoopDeckMath.boundary(atOrAfter: 12, origin: 12, grid: 4) == 12)
        // Behind the origin clamps forward to it — never a negative cycle.
        #expect(LoopDeckMath.boundary(atOrAfter: 5, origin: 12, grid: 4) == 12)
    }

    @Test("cycleIndex is 0-based from the origin and never negative")
    func cycleIndexFromOrigin() {
        #expect(LoopDeckMath.cycleIndex(ofBeat: 16, origin: 16, cycleBeats: 8) == 0)
        #expect(LoopDeckMath.cycleIndex(ofBeat: 23.9, origin: 16, cycleBeats: 8) == 0)
        #expect(LoopDeckMath.cycleIndex(ofBeat: 24, origin: 16, cycleBeats: 8) == 1)
        #expect(LoopDeckMath.cycleIndex(ofBeat: 0, origin: 16, cycleBeats: 8) == 0)
    }

    // MARK: Press-to-end length

    @Test("press-to-end rounds to the NEAREST whole bar — an off-grid loop is unrepresentable")
    func pressToEndSnapsToBars() {
        // The research's §3.2 arithmetic: an off-grid length does not average
        // out, it compounds on every repeat, and every later layer inherits it.
        #expect(LoopDeckMath.pressToEndCycleBeats(capturedBeats: 15.7, beatsPerBar: 4) == 16)
        #expect(LoopDeckMath.pressToEndCycleBeats(capturedBeats: 16.3, beatsPerBar: 4) == 16)
        #expect(LoopDeckMath.pressToEndCycleBeats(capturedBeats: 14.2, beatsPerBar: 4) == 16)
        // NEAREST, not up: a press a hair late must not cost a whole bar.
        #expect(LoopDeckMath.pressToEndCycleBeats(capturedBeats: 8.1, beatsPerBar: 4) == 8)
    }

    @Test("press-to-end never returns less than one bar, however short the pass")
    func pressToEndHasAFloor() {
        #expect(LoopDeckMath.pressToEndCycleBeats(capturedBeats: 0, beatsPerBar: 4) == 4)
        #expect(LoopDeckMath.pressToEndCycleBeats(capturedBeats: 0.3, beatsPerBar: 3) == 3)
    }

    // MARK: Folding — the placement law

    /// One note per bar of a 2-cycle pass, at known musical positions.
    private func twoCycles(open: Double, cycle: Double) -> [MIDINote] {
        [0, 1, 2, 3].map { k in
            MIDINote(pitch: 60 + k, velocity: 100,
                     startBeat: Double(k) * (cycle / 2) + (open - open),
                     lengthBeats: 0.5)
        }
    }

    @Test("⭐ PLACEMENT IS A FUNCTION OF WHERE IN THE MUSIC A NOTE WAS PLAYED, NOT WHEN THE BUTTON WAS PRESSED")
    func foldIsIndependentOfPressTiming() {
        // The SAME performance — notes on the four beats of every bar — captured
        // from two very different press instants. A launch-quantization bug
        // would make these disagree; the fold makes them identical.
        let cycle = 4.0
        let origin = 8.0

        // Pressed on the boundary: capture opened at 8, notes at 8,9,10,11.
        let early = (0..<4).map { MIDINote(pitch: 60 + $0, startBeat: Double($0), lengthBeats: 0.5) }
        let a = LoopDeckMath.fold(early, clipStartBeat: 8, captureOpenBeat: 8,
                                  originBeat: origin, cycleBeats: cycle)

        // Pressed 2.7 beats late: capture really began at 10.7, the window
        // opened at the NEXT boundary (12), and the same four notes were played
        // at 12,13,14,15 — one whole cycle further down the timeline.
        let late = (0..<4).map { MIDINote(pitch: 60 + $0, startBeat: 1.3 + Double($0), lengthBeats: 0.5) }
        let b = LoopDeckMath.fold(late, clipStartBeat: 10.7, captureOpenBeat: 12,
                                  originBeat: origin, cycleBeats: cycle)

        #expect(a.map(\.pitch) == [60, 61, 62, 63])
        #expect(a.map(\.startBeat) == [0, 1, 2, 3])
        #expect(b.map(\.pitch) == [60, 61, 62, 63])
        #expect(b.map(\.startBeat) == [0, 1, 2, 3])
    }

    @Test("material played BEFORE the capture window is DROPPED, not folded into the loop")
    func preWindowMaterialIsDropped() {
        // The pre-roll: `armLoopLayer` fires the take a beat EARLY so the
        // engine's anchor is live by the boundary. Anything played in that beat
        // is the performer waiting, and folding it would put a stray note into
        // the loop forever.
        let notes = [
            MIDINote(pitch: 50, startBeat: 0.0, lengthBeats: 0.25),   // absolute 7.0 — pre-roll
            MIDINote(pitch: 60, startBeat: 1.0, lengthBeats: 0.25),   // absolute 8.0 — the downbeat
        ]
        let folded = LoopDeckMath.fold(notes, clipStartBeat: 7, captureOpenBeat: 8,
                                       originBeat: 8, cycleBeats: 4)
        #expect(folded.map(\.pitch) == [60])
        #expect(folded.map(\.startBeat) == [0])
    }

    @Test("⭐⭐ AN ANTICIPATED FIRST DOWNBEAT SNAPS TO THE WINDOW — it must NOT fold to the END of the loop")
    func anticipatedDownbeatSnapsForward() {
        // A performer lands the first note 0.05 beats (25 ms at 120 BPM) early.
        // A naive `mod` puts it at 3.95 of a 4-beat loop: an entire cycle early,
        // on every single repeat. An onset gate reading 3.95 could easily be
        // waved through as "close enough" — which is precisely why this is
        // pinned rather than left emergent.
        let notes = [MIDINote(pitch: 60, startBeat: 0.95, lengthBeats: 0.5)]
        let folded = LoopDeckMath.fold(notes, clipStartBeat: 7, captureOpenBeat: 8,
                                       originBeat: 8, cycleBeats: 4)
        #expect(folded.count == 1)
        #expect(folded[0].startBeat == 0)

        // And the grace is NARROW: 0.3 beats early is not an anticipation, it is
        // pre-roll noodling, and it is dropped.
        let noodle = [MIDINote(pitch: 60, startBeat: 0.7, lengthBeats: 0.5)]
        #expect(LoopDeckMath.fold(noodle, clipStartBeat: 7, captureOpenBeat: 8,
                                  originBeat: 8, cycleBeats: 4).isEmpty)
    }

    @Test("MID-TAKE anticipation is NOT snapped — it stays just before the downbeat, which is where it was played")
    func midTakeAnticipationIsPreserved() {
        // The asymmetry that makes the grace correct rather than arbitrary. At
        // capture open, an early note unambiguously means "the layer starts
        // here". Three cycles in, an early note is a musical anticipation and
        // belongs just before every downbeat.
        let notes = [MIDINote(pitch: 60, startBeat: 7.95, lengthBeats: 0.25)]  // absolute 15.95
        let folded = LoopDeckMath.fold(notes, clipStartBeat: 8, captureOpenBeat: 8,
                                       originBeat: 8, cycleBeats: 4)
        #expect(folded.count == 1)
        #expect(abs(folded[0].startBeat - 3.95) < 1e-9)
    }

    @Test("a note running past the cycle end is clamped to it, never wrapped into its own head")
    func longNotesClampAtTheCycleEnd() {
        let notes = [MIDINote(pitch: 60, startBeat: 3.0, lengthBeats: 8)]
        let folded = LoopDeckMath.fold(notes, clipStartBeat: 0, captureOpenBeat: 0,
                                       originBeat: 0, cycleBeats: 4)
        #expect(folded.count == 1)
        #expect(folded[0].startBeat == 3)
        #expect(folded[0].lengthBeats == 1)
    }

    @Test("a capture spanning several cycles STACKS onto one cycle — that is what overdubbing over a loop means")
    func multiCycleCaptureStacks() {
        // Four bars played over a 1-bar loop become four notes in one bar. This
        // is why a layer take is ONE multi-cycle capture rather than an
        // auto-finish per pass: an auto-finish would re-enter the engine's
        // ~70–300 ms pre-anchor drop window at the top of every cycle.
        let notes = (0..<4).map { MIDINote(pitch: 60 + $0, startBeat: Double($0) * 4 + 1,
                                           lengthBeats: 0.5) }
        let folded = LoopDeckMath.fold(notes, clipStartBeat: 0, captureOpenBeat: 0,
                                       originBeat: 0, cycleBeats: 4)
        #expect(folded.count == 4)
        #expect(folded.allSatisfy { $0.startBeat == 1 })
    }

    // MARK: Tiling

    @Test("tiling repeats the cycle forward and gives every copy its own id")
    func tilingRepeatsWithFreshIDs() {
        let cycle = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
                     MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1)]
        let tiled = LoopDeckMath.tile(cycle, cycles: 3, cycleBeats: 4)
        #expect(tiled.count == 6)
        #expect(tiled.map(\.startBeat) == [0, 2, 4, 6, 8, 10])
        // Two notes in one clip may not share an id.
        #expect(Set(tiled.map(\.id)).count == 6)
    }

    @Test("tiling an empty cycle produces nothing, and zero cycles produce nothing")
    func tilingDegeneracies() {
        #expect(LoopDeckMath.tile([], cycles: 4, cycleBeats: 4).isEmpty)
        #expect(LoopDeckMath.tile([MIDINote(pitch: 60, startBeat: 0)],
                                  cycles: 0, cycleBeats: 4).isEmpty)
    }

    // MARK: Overdub vs replace

    @Test("overdub ADDS to the cycle, replace throws the old cycle away — one parameter, not two modes")
    func overdubAndReplaceAreOneDial() {
        let existing = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)]
        let incoming = [MIDINote(pitch: 67, startBeat: 2, lengthBeats: 1)]
        #expect(LoopDeckMath.merge(existingCycle: existing, incomingCycle: incoming,
                                   mode: .overdub).map(\.pitch) == [60, 67])
        #expect(LoopDeckMath.merge(existingCycle: existing, incomingCycle: incoming,
                                   mode: .replace).map(\.pitch) == [67])
    }

    // MARK: Runway

    @Test("the runway only extends when the playhead is closing on the end of the material")
    func runwayExtendsLate() {
        // Sixteen cycles materialised, playhead in cycle 3: nothing to do. This
        // is the common case and it must stay free — every extension rides the
        // engine's `tracksDidChange` continuation restart.
        #expect(LoopDeckMath.extendedSpan(spanCycles: 16, playheadCycle: 3) == nil)
        // Two cycles left: extend, and extend by the WHOLE horizon so the next
        // extension is another fourteen cycles away.
        #expect(LoopDeckMath.extendedSpan(spanCycles: 16, playheadCycle: 14) == 30)
        #expect(LoopDeckMath.extendedSpan(spanCycles: 16, playheadCycle: 15) == 31)
    }

    @Test("the runway never SHRINKS — that would delete material a performer recorded")
    func runwayNeverShrinks() {
        #expect(LoopDeckMath.extendedSpan(spanCycles: 40, playheadCycle: 39,
                                          horizonCycles: 2) == 41)
        // A horizon shorter than what is already there proposes nothing.
        #expect(LoopDeckMath.extendedSpan(spanCycles: 40, playheadCycle: 39,
                                          horizonCycles: 1) == nil)
    }
}

/// The deck's decision surface: what is due at a given beat.
@Suite("Loop deck — scheduler (m34-h-1)")
struct LoopDeckSchedulerTests {

    private func deck(cycleBeats: Double? = 4, origin: Double = 0,
                      quantize: LoopLaunchQuantize = .cycle,
                      pending: LoopPendingLayer? = nil,
                      spanCycles: Int = 0) -> LoopDeck {
        LoopDeck(originBeat: origin, cycleBeats: cycleBeats, beatsPerBar: 4,
                 lengthMode: .fixedBars, quantize: quantize, defaultMode: .overdub,
                 spanCycles: spanCycles, layers: [], pending: pending)
    }

    private func pending(phase: LoopPendingLayer.Phase, launch: Double, arm: Double,
                         close: Double? = nil) -> LoopPendingLayer {
        LoopPendingLayer(trackID: UUID(), layerID: UUID(), mode: .overdub,
                         launchBeat: launch, armBeat: arm, closeBeat: close,
                         phase: phase, definesLength: false, isNewLayer: true)
    }

    @Test("a queued layer fires its take at the ARM beat, a whole beat BEFORE the window opens")
    func armFiresAtThePreRoll() {
        // The pre-roll is the answer to the engine's pre-anchor drop window: a
        // take started ON the boundary loses the downbeat that defines the
        // layer. Firing a beat early costs nothing, because `fold` drops
        // everything played before the window anyway.
        let d = deck(pending: pending(phase: .queued, launch: 8, arm: 7))
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 6.9).isEmpty)
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 7.0) == [.fireArm])
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 7.6) == [.fireArm])
    }

    @Test("a RECORDING layer with no close beat is due for nothing")
    func aRollingLayerIsQuiet() {
        let d = deck(pending: pending(phase: .recording, launch: 8, arm: 7))
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 40).isEmpty)
    }

    @Test("a CLOSING layer fires its finish at the close beat and not before")
    func closeFiresAtTheCloseBeat() {
        let d = deck(pending: pending(phase: .closing, launch: 8, arm: 7, close: 16))
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 15.9).isEmpty)
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 16) == [.fireClose])
    }

    @Test("the runway extension rides the same tick, and does not need a pending layer")
    func runwayRidesTheTick() {
        let d = deck(spanCycles: 16)
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 8).isEmpty)   // cycle 2 of 16
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 57)           // cycle 14
                == [.extendSpan(cycles: 30)])
    }

    @Test("⚠️ actions() IGNORES launchInFlight — the store owns that gate, and this stays a pure function of the beat")
    func schedulerIgnoresTheInFlightFlag() {
        // Reading the flag here would make the function return [] when
        // re-evaluated INSIDE the very hopped task the flag was set for, so the
        // launch would never fire. Pinned because the bug is invisible: a deck
        // that simply never records looks like a deck nobody armed.
        var d = deck(pending: pending(phase: .queued, launch: 8, arm: 7))
        d.launchInFlight = true
        #expect(LoopDeckScheduler.actions(deck: d, playheadBeat: 7.5) == [.fireArm])
    }

    @Test("plan() quantizes to the CYCLE by default, to the BAR on request, and to nothing on instant")
    func planHonoursTheQuantizeSetting() {
        let cycleDeck = deck(cycleBeats: 8, quantize: .cycle)
        #expect(LoopDeckScheduler.plan(deck: cycleDeck, playheadBeat: 3).launchBeat == 8)
        let barDeck = deck(cycleBeats: 8, quantize: .bar)
        #expect(LoopDeckScheduler.plan(deck: barDeck, playheadBeat: 3).launchBeat == 4)
        let nowDeck = deck(cycleBeats: 8, quantize: .instant)
        let now = LoopDeckScheduler.plan(deck: nowDeck, playheadBeat: 3.37)
        #expect(now.launchBeat == 3.37)
        #expect(now.armBeat == 3.37)
    }

    @Test("before the loop length exists, `cycle` quantization degrades to the BAR")
    func lengthlessDeckQuantizesToTheBar() {
        // Press-to-end's first layer: there is no cycle yet to wait for, and a
        // bar is what the performer can actually see coming.
        let d = deck(cycleBeats: nil, quantize: .cycle)
        #expect(LoopDeckScheduler.plan(deck: d, playheadBeat: 1).launchBeat == 4)
    }

    @Test("⭐⭐ A PRESS ON A BOUNDARY TARGETS THE NEXT ONE — the pre-roll is GUARANTEED, never best-effort")
    func theArmBeatIsNeverBehindThePlayhead() {
        // You cannot record a moment that has already arrived. Searching for the
        // boundary from `playhead` rather than `playhead + preRoll` would hand
        // back the line the playhead is standing on, so the take's anchor —
        // scheduled ~70–300 ms AHEAD of the call — would still not be live when
        // the window opened, and the layer's first chord would vanish with no
        // visible cause. `armBeat >= playheadBeat` is the invariant.
        let d = deck(cycleBeats: 4)
        for press in [0.0, 3.999, 4.0, 4.001, 7.5] {
            let plan = LoopDeckScheduler.plan(deck: d, playheadBeat: press)
            #expect(plan.armBeat >= press - 1e-9,
                    "arm \(plan.armBeat) is behind a press at \(press)")
            #expect(plan.launchBeat > press)
        }
        #expect(LoopDeckScheduler.plan(deck: d, playheadBeat: 4.0).launchBeat == 8)
        #expect(LoopDeckScheduler.plan(deck: d, playheadBeat: 3.5).launchBeat == 8)
        #expect(LoopDeckScheduler.plan(deck: d, playheadBeat: 2.9).launchBeat == 4)
    }

    @Test("the pre-roll is derived from the music: one beat, so it scales with tempo")
    func preRollIsMusical() {
        let d = deck(cycleBeats: 4)
        let plan = LoopDeckScheduler.plan(deck: d, playheadBeat: 1)
        #expect(plan.launchBeat == 4)
        #expect(plan.armBeat == 3)
        // At 120 BPM one beat is 500 ms — comfortably past the engine's
        // ~70–300 ms pre-anchor drop plus a 33 ms tick plus a main-actor hop.
    }
}
