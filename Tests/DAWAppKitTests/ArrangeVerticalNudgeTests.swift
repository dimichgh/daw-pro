import Foundation
import Testing
@testable import DAWAppKit

/// m23-aj-3 — the VERTICAL (↑/↓) half of the arrange arrow-key nudge.
///
/// SCOPE, and why it is narrower than `ArrangeNudgeTests`. The horizontal rule
/// has four competing magnitude sources and a grid to read, so its suite has to
/// compose `ArrangeNudge.step` with `ProjectStore.moveClips` to see a weld or a
/// clamp. The vertical rule has ONE magnitude (±1 lane, always) and no grid, so
/// everything decidable here is decidable from the pure function; the store-side
/// behaviour it feeds — the whole-group top/bottom clamp, the kind refusal, the
/// manufactured-collision refusal — is already proven by
/// `Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift` against the verb itself,
/// and re-asserting it through a keyboard fixture here would be a second, weaker
/// copy of that suite.
///
/// WHAT THESE TESTS CANNOT REACH, stated rather than implied: `DAWApp` has no
/// test target, so `AppModel.handleArrangeNudgeKey`'s six guards, the
/// `ArrangeNudgeAxisKey` routing, and the vertical CONSUME rule (a `.store`
/// refusal returns `handled: true` on this axis and `false` on the horizontal
/// one) are UNREACHABLE from here. That half is proven by
/// `scripts/gates/m23aj-cross-track-move.mjs` against a real app on staging.
///
/// EVERY MODIFIER LEG IS A CONTROLLED PAIR. A leg that only asserts nil for ⇧
/// passes against a `verticalStep` that returns nil for everything, including a
/// bare press — i.e. against a completely dead key. So each one strips the
/// modifier and asserts the SAME call then answers.
@Suite("Arrange vertical arrow-key nudge (m23-aj-3)")
struct ArrangeVerticalNudgeTests {

    /// The four chord modifiers, singly. Named so a failure says WHICH.
    private static let singles: [(String, TransportKeyModifiers)] = [
        ("⌘", .command), ("⌃", .control), ("⇧", .shift), ("⌥", .option),
    ]

    // MARK: - The direction enum

    @Test("trackSign is the ONE home for a vertical arrow's sign, and the two are exact opposites")
    func trackSignIsOpposite() {
        #expect(ArrangeVerticalNudgeDirection.up.trackSign == -1)
        #expect(ArrangeVerticalNudgeDirection.down.trackSign == 1)
        // Not merely "one is negative": the pair must be exact opposites, which
        // is what makes ↑ then ↓ a round trip rather than two unrelated moves.
        #expect(ArrangeVerticalNudgeDirection.up.trackSign
                == -ArrangeVerticalNudgeDirection.down.trackSign)
    }

    /// ⚠️ THIS LEG IS A TRIPWIRE, NOT A COUNT. `ArrangeVerticalNudgeDirection`
    /// exists precisely so that `ArrangeNudgeDirection` keeps exactly two cases
    /// (design §10.1: a third case there would force `sign: Double`,
    /// `magnitudeBeats` and `source` to lie). If someone later adds `.up`/`.down`
    /// to the HORIZONTAL enum and deletes this one, this leg is what notices.
    @Test("the vertical enum has exactly two cases, and each round-trips its own sign")
    func allCasesRoundTrip() {
        #expect(ArrangeVerticalNudgeDirection.allCases.count == 2)
        for direction in ArrangeVerticalNudgeDirection.allCases {
            let step = ArrangeNudge.verticalStep(direction: direction, modifiers: [])
            #expect(step?.direction == direction)
            // The step's delta may not be a SECOND opinion about the sign — it
            // must be `trackSign` itself, or the enum stops being the one home.
            #expect(step?.trackDelta == direction.trackSign)
            #expect(abs(step?.trackDelta ?? 0) == 1)
        }
    }

    // MARK: - The bare press

    @Test("a bare ↑ steps exactly one lane UP, a bare ↓ exactly one lane DOWN")
    func barePressStepsOneLane() {
        let up = ArrangeNudge.verticalStep(direction: .up, modifiers: [])
        let down = ArrangeNudge.verticalStep(direction: .down, modifiers: [])
        #expect(up?.trackDelta == -1)
        #expect(down?.trackDelta == 1)
        #expect(up?.direction == .up)
        #expect(down?.direction == .down)
    }

    /// There is no coarse/fine variant on this axis — a lane is a lane. This
    /// pins that the magnitude is a CONSTANT ±1 and not, say, something that
    /// grows with a grid the way the horizontal step does.
    @Test("the magnitude is always exactly one lane, in both directions")
    func magnitudeIsAlwaysOne() {
        for direction in ArrangeVerticalNudgeDirection.allCases {
            #expect(abs(ArrangeNudge.verticalStep(direction: direction,
                                                  modifiers: [])?.trackDelta ?? 0) == 1)
        }
    }

    // MARK: - Modifier policy: BARE PRESS ONLY (each a controlled pair)

    @Test("⌘ / ⌃ / ⇧ / ⌥ each PASS THROUGH — and the same call answers without them",
          arguments: ArrangeVerticalNudgeDirection.allCases)
    func everySingleModifierPassesThrough(direction: ArrangeVerticalNudgeDirection) {
        for (name, modifier) in Self.singles {
            #expect(ArrangeNudge.verticalStep(direction: direction, modifiers: modifier) == nil,
                    "\(name)\(direction.rawValue) must pass through, not nudge")
            // THE CONTROLLED HALF. Without it this leg passes against a
            // `verticalStep` that returns nil unconditionally, i.e. a dead key.
            #expect(ArrangeNudge.verticalStep(direction: direction, modifiers: []) != nil,
                    "the bare press must still answer (else the \(name) leg is vacuous)")
        }
    }

    /// ⇧ AND ⌥ ARE THE DECISION, not an accident of copying the horizontal rule
    /// — there they carry meaning (⇧ = one bar, ⌥ = the fine step). Here they are
    /// RESERVED for extend-selection and duplicate-down, so this leg is the
    /// regression guard against someone "fixing" the asymmetry by making ⇧↓ nudge.
    @Test("⇧ and ⌥ pass through on this axis even though they MEAN something on the other one")
    func reservedModifiersDifferFromTheHorizontalAxis() {
        // Horizontal: both answer, with DIFFERENT magnitudes — so the vertical
        // nil below is a real difference in policy, not the same rule twice.
        let horizontalShift = ArrangeNudge.step(direction: .right, modifiers: .shift,
                                                snap: .sixteenth, beatsPerBar: 4)
        let horizontalOption = ArrangeNudge.step(direction: .right, modifiers: .option,
                                                 snap: .sixteenth, beatsPerBar: 4)
        #expect(horizontalShift?.source == .bar)
        #expect(horizontalOption?.source == .fine)
        #expect(horizontalShift?.magnitudeBeats != horizontalOption?.magnitudeBeats)

        #expect(ArrangeNudge.verticalStep(direction: .down, modifiers: .shift) == nil)
        #expect(ArrangeNudge.verticalStep(direction: .down, modifiers: .option) == nil)
        #expect(ArrangeNudge.verticalStep(direction: .up, modifiers: .shift) == nil)
        #expect(ArrangeNudge.verticalStep(direction: .up, modifiers: .option) == nil)
    }

    @Test("every COMBINATION of the four modifiers passes through too",
          arguments: ArrangeVerticalNudgeDirection.allCases)
    func everyChordPassesThrough(direction: ArrangeVerticalNudgeDirection) {
        // All 16 subsets of {⌘,⌃,⇧,⌥}: 0 is the bare press (must answer), the
        // other 15 are chords (must all pass through). Enumerated rather than
        // sampled, because "⌥ beats ⇧" on the horizontal axis proves that a
        // hand-picked list of chords is exactly where a precedence bug hides.
        let all: [TransportKeyModifiers] = [.command, .control, .shift, .option]
        for mask in 0..<16 {
            var mods: TransportKeyModifiers = []
            for (bit, m) in all.enumerated() where mask & (1 << bit) != 0 { mods.insert(m) }
            let step = ArrangeNudge.verticalStep(direction: direction, modifiers: mods)
            if mask == 0 {
                #expect(step?.trackDelta == direction.trackSign, "the bare press must answer")
            } else {
                #expect(step == nil, "chord mask \(mask) must pass through")
            }
        }
    }
}
