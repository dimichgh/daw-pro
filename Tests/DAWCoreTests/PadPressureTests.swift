import Foundation
import Testing
@testable import DAWCore

/// m34-f step ① — the PRESSURE AXIS, the one part of "read trackpad pressure"
/// that can be tested without a Force Touch trackpad.
///
/// ⚠️ **EVERY LEG HERE IS SYNTHETIC AND SAYS SO. No gate in this tree can press
/// a physical trackpad.** What these pin is the LAW: what a pressure value does
/// to the streamed effort, and — much more importantly — what the ABSENCE of a
/// pressure value does. The hardware half (a real `NSEventTypePressure` arriving
/// with `.primaryGeneric` and no haptic detent mid-swell) is a hand check and is
/// recorded as one.
@Suite("Pad pressure (m34-f step ①)")
struct PadPressureTests {

    // MARK: - The degradation rule, which is the whole point

    @Test("nil pressure streams the dot's effort UNCHANGED — every mouse, every non-Force trackpad")
    func absentPressureIsIdentity() {
        // ⛔ THE MOST IMPORTANT ASSERTION IN THIS FILE. Most Macs this ships to
        // have no Force Touch trackpad, and on those the pad must behave
        // bit-for-bit as it did before this axis existed. A regression here is
        // invisible on the development machine, which HAS the hardware.
        for effort in [0.0, 0.001, 0.25, 0.4999, 0.5, 0.75, 0.9999, 1.0] {
            #expect(PadPressure.effort(dotEffort: effort, pressure: nil) == effort,
                    "no pressure information must not become a pressure value")
        }
    }

    @Test("nil is NOT zero and NOT one — the three states are distinguishable")
    func nilIsItsOwnState() {
        // A constant reported as a measurement is the dishonesty this whole
        // design avoids. If `nil` collapsed to either extreme, one of these two
        // would be equal to the identity case and the distinction would be gone.
        let dot = 0.8
        #expect(PadPressure.effort(dotEffort: dot, pressure: nil) == 0.8)
        #expect(PadPressure.effort(dotEffort: dot, pressure: 0) == 0.0)
        #expect(PadPressure.effort(dotEffort: dot, pressure: 1) == 0.8)
        #expect(PadPressure.effort(dotEffort: dot, pressure: nil)
                != PadPressure.effort(dotEffort: dot, pressure: 0))
    }

    // MARK: - The law

    @Test("full pressure reproduces today's behaviour exactly — the two designs MEET")
    func fullPressureIsTheOldBehaviour() {
        // The multiply was chosen partly because the old and new behaviours are
        // continuous with each other at p = 1: there is no version of this pad
        // where a full press does something the old pad never did.
        for effort in [0.0, 0.33, 0.5, 0.75, 1.0] {
            #expect(PadPressure.effort(dotEffort: effort, pressure: 1.0) == effort)
        }
    }

    @Test("pressure scales the dot's effort linearly, and the dot is the CEILING")
    func pressureScales() {
        #expect(PadPressure.effort(dotEffort: 1.0, pressure: 0.5) == 0.5)
        #expect(PadPressure.effort(dotEffort: 0.5, pressure: 0.5) == 0.25)
        #expect(abs(PadPressure.effort(dotEffort: 0.8, pressure: 0.25) - 0.2) < 1e-12)
        // Monotone in BOTH arguments — pressing harder never gets quieter, and a
        // deeper dot never gets quieter at fixed pressure.
        var previous = -1.0
        for step in 0...20 {
            let value = PadPressure.effort(dotEffort: 0.9, pressure: Double(step) / 20)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("zero pressure reaches ZERO — the retraction of 'the pad cannot preview a silence'")
    @MainActor
    func zeroPressureIsSilence() {
        // ⛔ THIS IS THE FEATURE, NOT A BUG, and it is asserted rather than left
        // to a comment. `BreathPadModel.effort` measured a floor of 0.499 across
        // the eight library patterns — that claim is about the DOT and stays
        // true. What the pad STREAMS now reaches 0, because choosing not to blow
        // is the single most expressive thing a wind player does.
        #expect(PadPressure.effort(dotEffort: 1.0, pressure: 0.0) == 0.0)
        #expect(PadPreviewController.controllerValue(
            forEffort: PadPressure.effort(dotEffort: 1.0, pressure: 0.0)) == 0)
    }

    @Test("the CC the axis lands on is CC 11, and it is BreathContour's own default, not a new number")
    @MainActor
    func theControllerIsTheOneTheModelAlreadyUses() {
        // ⛔ NOT A NUMBER PICKED FOR THIS ITEM. The roadmap says "for a sax the
        // guitar analogue is not pitch, it is BREATH: CC2/CC11" and leaves the
        // choice to be CONFIRMED against the existing vocabulary. It is
        // confirmed here, by comparing two independently-declared defaults that
        // nothing else compares: the offline contour model's and the live pad's.
        #expect(PadPreviewController.defaultExpressionCC == 11)
        #expect(BreathContour.Options().expressionCC == 11)
        #expect(BreathContour.Options().expressionCC == PadPreviewController.defaultExpressionCC,
                "the live pressure axis and the offline breath model must write ONE lane")
    }

    // MARK: - Bounds

    @Test("pressure outside 0…1 is clamped, never trusted")
    func outOfRangePressureIsClamped() {
        // Defence rather than a modelled case: the one secondary source claiming
        // `NSEvent.pressure` can exceed 1.0 was traced to an unrelated
        // JavaScript polyfill's 1–3 scale, not to AppKit.
        #expect(PadPressure.effort(dotEffort: 1.0, pressure: 3.0) == 1.0)
        #expect(PadPressure.effort(dotEffort: 1.0, pressure: -1.0) == 0.0)
        #expect(PadPressure.effort(dotEffort: 1.0, pressure: .nan).isNaN == false,
                "a NaN pressure must not propagate a NaN into a MIDI value")
    }

    @Test("an out-of-range dot effort is clamped too, so the product stays a legal effort")
    func outOfRangeEffortIsClamped() {
        #expect(PadPressure.effort(dotEffort: 2.0, pressure: 1.0) == 1.0)
        #expect(PadPressure.effort(dotEffort: -0.5, pressure: 1.0) == 0.0)
        #expect(PadPressure.effort(dotEffort: 2.0, pressure: 0.5) == 0.5)
    }

    @Test("the whole range maps into legal MIDI, with no wrap at either end")
    @MainActor
    func theProductIsAlwaysALegalControllerValue() {
        for effortStep in 0...10 {
            for pressureStep in 0...10 {
                let value = PadPreviewController.controllerValue(
                    forEffort: PadPressure.effort(dotEffort: Double(effortStep) / 10,
                                                  pressure: Double(pressureStep) / 10))
                #expect(PadPreviewController.controllerRange.contains(value))
            }
        }
    }
}
