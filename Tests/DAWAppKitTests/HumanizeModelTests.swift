import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless tests for the Humanize panel's state machine (m25-c): the amounts
/// and their clamping, the bounds' agreement with the `clip.humanize` wire
/// validation, the MIDI-only + no-op refusals, the STICKY amounts that make ⌘Z +
/// reopen the panel's re-roll, and the beginner-readable descriptions. Drives
/// `HumanizeModel` against an injected apply recorder — no window, no store, no
/// engine (the `QuantizeModel` precedent).
///
/// ⚠️ What these tests CANNOT see: this item's real hazard is a DELETE keypress
/// landing on the arrange selection while the panel's scrim is up. That guard
/// lives in `AppModel.isModalPresented`, in the `DAWApp` executable target,
/// which has no test target — `HumanizePanelSiteTests` pins its SHAPE and says
/// so honestly. Nothing here observes it.
@MainActor
@Suite struct HumanizeModelTests {

    /// A recorder for the injected apply closure — the model's entire outward
    /// surface (it takes no providers; the amounts are its own state).
    @MainActor final class Harness {
        var applied: [(clipID: UUID, timingBeats: Double, velocityRange: Int)] = []

        func makeModel() -> HumanizeModel {
            HumanizeModel(apply: { self.applied.append(($0, $1, $2)) })
        }
    }

    private static let clipID = UUID()

    private func preparedModel(_ harness: Harness, isMIDI: Bool = true) -> HumanizeModel {
        let model = harness.makeModel()
        model.prepare(clipID: Self.clipID, clipName: "Bass", isMIDI: isMIDI)
        return model
    }

    // MARK: - Bounds agree with the wire

    /// The panel must not be able to BUILD a value `clip.humanize` would reject.
    /// The wire validates `(0...0.25).contains(timingBeats)` and
    /// `(0...64).contains(velocityRange)` (`DAWControl/Commands.swift`); if these
    /// drift apart, the human path and the agent path disagree about what is a
    /// legal humanize, which is exactly the split m25-c exists to close.
    @Test func boundsMatchTheWireValidation() {
        #expect(HumanizeModel.timingBounds == 0...0.25)
        #expect(HumanizeModel.velocityBounds == 0...64)
    }

    /// Defaults match the wire's defaults, so opening the panel and pressing
    /// Apply does what `clip.humanize {clipId}` with no arguments does.
    @Test func defaultsMatchTheWireDefaults() {
        let model = Harness().makeModel()
        #expect(model.timingBeats == 0.02)
        #expect(model.velocityRange == 8)
        #expect(HumanizeModel.defaultTimingBeats == 0.02)
        #expect(HumanizeModel.defaultVelocityRange == 8)
    }

    // MARK: - Target lifecycle

    @Test func prepareSeedsTheTarget() {
        let model = Harness().makeModel()
        #expect(model.targetClipID == nil)
        model.prepare(clipID: Self.clipID, clipName: "Lead", isMIDI: true)
        #expect(model.targetClipID == Self.clipID)
        #expect(model.targetClipName == "Lead")
        #expect(model.targetIsMIDI)
    }

    /// The amounts SURVIVE `prepare`. This is the re-roll substitute: the panel
    /// closes on Apply (a re-run compounds the jitter), so ⌘Z + reopen must land
    /// on the same two amounts or "try another feel" costs the user two slider
    /// drags every time.
    @Test func prepareKeepsTheAmountsSticky() {
        let model = Harness().makeModel()
        model.timingBeats = 0.08
        model.velocityRange = 22
        model.prepare(clipID: UUID(), clipName: "Other", isMIDI: true)
        #expect(model.timingBeats == 0.08)
        #expect(model.velocityRange == 22)
    }

    // MARK: - Clamping

    @Test(arguments: [
        (-1.0, 0.0), (0.0, 0.0), (0.02, 0.02), (0.25, 0.25), (5.0, 0.25),
    ])
    func timingClampsIntoTheWireRange(raw: Double, expected: Double) {
        let model = Harness().makeModel()
        model.timingBeats = raw
        #expect(model.effectiveTimingBeats == expected)
    }

    @Test(arguments: [(-5, 0), (0, 0), (8, 8), (64, 64), (200, 64)])
    func velocityClampsIntoTheWireRange(raw: Int, expected: Int) {
        let model = Harness().makeModel()
        model.velocityRange = raw
        #expect(model.effectiveVelocityRange == expected)
    }

    /// A clamped value is what APPLIES, not merely what displays — otherwise the
    /// panel would show a legal amount and send an illegal one.
    @Test func applySendsTheClampedAmounts() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.timingBeats = 9.0
        model.velocityRange = 900
        model.apply()
        #expect(harness.applied.count == 1)
        #expect(harness.applied.first?.timingBeats == 0.25)
        #expect(harness.applied.first?.velocityRange == 64)
        #expect(harness.applied.first?.clipID == Self.clipID)
    }

    // MARK: - No-op

    /// Both amounts at zero is LEGAL in the store (it round-trips the clip
    /// bit-identically) — which is precisely why the panel must refuse it: an
    /// undo step that changes nothing is a lie about what happened.
    @Test func bothAmountsZeroIsANoOpAndCannotApply() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.timingBeats = 0
        model.velocityRange = 0
        #expect(model.isNoOp)
        #expect(!model.canApply)
        model.apply()
        #expect(harness.applied.isEmpty)
    }

    @Test func oneNonZeroAmountIsNotANoOp() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.timingBeats = 0
        model.velocityRange = 3
        #expect(!model.isNoOp)
        #expect(model.canApply)

        model.timingBeats = 0.01
        model.velocityRange = 0
        #expect(!model.isNoOp)
        #expect(model.canApply)
    }

    // MARK: - Refusals

    /// `humanizeClipNotes` throws `notAMIDIClip` on an audio clip. The arrange
    /// menu HIDES the entry there, but the model refuses independently, so the
    /// guard does not depend on any view getting its `if` right.
    @Test func audioTargetCannotApply() {
        let harness = Harness()
        let model = preparedModel(harness, isMIDI: false)
        #expect(!model.targetIsMIDI)
        #expect(!model.canApply)
        model.apply()
        #expect(harness.applied.isEmpty)
    }

    @Test func noTargetCannotApply() {
        let harness = Harness()
        let model = harness.makeModel()
        #expect(!model.canApply)
        model.apply()
        #expect(harness.applied.isEmpty)
    }

    /// Each Apply is ONE call — the store method does not coalesce, so a double
    /// dispatch here would be a doubled, compounded jitter and two undo steps.
    @Test func applyDispatchesExactlyOncePerPress() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.apply()
        #expect(harness.applied.count == 1)
        model.apply()
        #expect(harness.applied.count == 2, "each press is its own edit; the panel closes to prevent this")
    }

    // MARK: - Readouts

    /// The ± is load-bearing: the jitter is TWO-SIDED, so a bare "0.020" would
    /// read as a shift rather than a spread.
    @Test func readoutsAreTwoSided() {
        let model = Harness().makeModel()
        model.timingBeats = 0.02
        model.velocityRange = 8
        #expect(model.timingReadout == "±0.020 beats")
        #expect(model.velocityReadout == "±8")
    }

    @Test func readoutsShowTheClampedValue() {
        let model = Harness().makeModel()
        model.timingBeats = 3
        model.velocityRange = 300
        #expect(model.timingReadout == "±0.250 beats")
        #expect(model.velocityReadout == "±64")
    }

    // MARK: - Beginner-readable descriptions

    @Test(arguments: [
        (0.0, "locked to the grid"),
        (0.005, "barely off the grid"),
        (0.01, "barely off the grid"),
        (0.03, "naturally played"),
        (0.05, "naturally played"),
        (0.2, "loose and laid-back"),
    ])
    func timingDescriptionTracksTheAmount(amount: Double, expected: String) {
        let model = Harness().makeModel()
        model.timingBeats = amount
        #expect(model.timingDescription == expected)
    }

    @Test(arguments: [
        (0, "every note equally hard"),
        (4, "subtly uneven"),
        (6, "subtly uneven"),
        (12, "naturally uneven"),
        (20, "naturally uneven"),
        (40, "strongly dynamic"),
    ])
    func velocityDescriptionTracksTheAmount(amount: Int, expected: String) {
        let model = Harness().makeModel()
        model.velocityRange = amount
        #expect(model.velocityDescription == expected)
    }

    /// Every description is non-empty and distinct per band — a duplicated string
    /// would make two different feels read identically to a beginner.
    @Test func descriptionsAreDistinctPerBand() {
        let model = Harness().makeModel()
        var timing: Set<String> = []
        for amount in [0.0, 0.005, 0.03, 0.2] {
            model.timingBeats = amount
            timing.insert(model.timingDescription)
        }
        #expect(timing.count == 4)

        var velocity: Set<String> = []
        for amount in [0, 4, 12, 40] {
            model.velocityRange = amount
            velocity.insert(model.velocityDescription)
        }
        #expect(velocity.count == 4)
    }
}
