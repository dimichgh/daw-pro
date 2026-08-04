import Foundation
import Testing
@testable import DAWEngine

// m23-bs-2 LEG L0 — THE LEAD FORMULA, PINNED HEADLESS.
//
// `StartAnchorBudget` is the one home of the player-start anchor lead. This
// file owns THE FORMULA (floor, slope, cap, monotonicity, and the horizon
// identity); the live leg L3 owns THE READ SITE (that `recoverEngine` forecasts
// from a count taken at the right moment). That decomposition is deliberate and
// is written down in design §13.7: an earlier draft made the live leg assert on
// the HORIZON, which forced a ≥ 6-audio-clip fixture — below 6 players the lead
// is pinned at the floor, so a horizon assertion cannot tell a broken count read
// from a correct one — and that fixture is a whole extra live playback session
// the contention budget (§13.8) had just committed not to add. Keep the burden
// here, where it costs no device.
//
// NO DEVICE, NO ENGINE, NO ASYNC. If this file ever needs one, the budget has
// stopped being pure and the one-home property has already been lost.

@Suite("Start-anchor budget — the lead formula (m23-bs-2)")
struct StartAnchorBudgetTests {

    // MARK: - The floor

    @Test("n <= 5 sits exactly on the floor — the pre-m19-f null case, byte-identical")
    func floorHoldsForSmallProjects() {
        for n in 0...5 {
            let lead = StartAnchorBudget.lead(forStartablePlayerCount: n)
            let why: String = "n=\(n) must sit on the 0.06 floor: 0.02 + n*0.008 <= 0.06 for "
                + "n <= 5, and keeping the small-project case byte-identical to the constant "
                + "lead is what made m19-f's scaling safe to land"
            #expect(lead.seconds == StartAnchorBudget.leadFloorSeconds, "\(why)")
            #expect(!lead.wasCapped)
        }
    }

    // MARK: - The slope

    @Test("above the floor the lead is 0.02 + 0.008 per player — 8 ms covers the serial start loop")
    func slopeIsEightMillisecondsPerPlayer() {
        for n in 6...59 {
            let lead = StartAnchorBudget.lead(forStartablePlayerCount: n)
            let expected = 0.02 + Double(n) * 0.008
            let why: String = "n=\(n): expected \(expected), got \(lead.seconds). The slope "
                + "covers the serial play(at:) loop at 5.4-6.1 ms/player (m18-c); a call "
                + "completing after the anchor starts that player SHIFTED-ORIGIN."
            #expect(abs(lead.seconds - expected) < 1e-12, "\(why)")
            #expect(!lead.wasCapped, "n=\(n) is below the cap")
        }
        // The two figures bs-1 measured, spelled out as facts rather than
        // inferred from the loop above.
        #expect(StartAnchorBudget.lead(forStartablePlayerCount: 0).seconds == 0.06)
        #expect(abs(StartAnchorBudget.lead(forStartablePlayerCount: 16).seconds - 0.148) < 1e-12)
    }

    // MARK: - The cap, and its EDGE

    /// ⚠️ THE EDGE THAT MAKES THIS A PIN RATHER THAT A RESTATEMENT.
    /// At n = 60 the raw expression is EXACTLY 0.5. The engine's original code
    /// is `if startLead > maxStartLeadSeconds { warn; clamp }` — strictly
    /// greater — so n = 60 is NOT capped and emits NO stderr warning. Writing
    /// the formula as the tidier `min(0.5, max(0.06, …))` with
    /// `wasCapped = raw >= cap` would flip this and start warning at a count
    /// that never warned before. This assertion is the only thing standing
    /// between that tidy-up and a silent behaviour change.
    @Test("the cap uses STRICT greater-than: n = 60 lands on 0.5 uncapped and unwarned")
    func capEdgeIsStrictlyGreaterThan() {
        let atEdge = StartAnchorBudget.lead(forStartablePlayerCount: 60)
        #expect(atEdge.seconds == StartAnchorBudget.leadCapSeconds)
        let silent: String = "n=60 raw is exactly 0.5; today's `>` comparison leaves it uncapped "
            + "and SILENT. A `>=` (or a min/max rewrite) would emit a cap warning the engine "
            + "never emitted at this count."
        #expect(!atEdge.wasCapped, "\(silent)")

        let past = StartAnchorBudget.lead(forStartablePlayerCount: 61)
        #expect(past.seconds == StartAnchorBudget.leadCapSeconds)
        #expect(past.wasCapped, "n=61 raw is 0.508 > 0.5 — capped, and the caller warns")
    }

    @Test("the cap holds for every large count")
    func capHoldsAbove() {
        for n in [61, 80, 200, 5_000] {
            let lead = StartAnchorBudget.lead(forStartablePlayerCount: n)
            #expect(lead.seconds == StartAnchorBudget.leadCapSeconds, "n=\(n)")
            #expect(lead.wasCapped, "n=\(n)")
        }
    }

    // MARK: - Monotonicity and bounds

    @Test("the lead is non-decreasing in n and always inside [floor, cap]")
    func leadIsMonotonicAndBounded() {
        var previous = StartAnchorBudget.lead(forStartablePlayerCount: 0).seconds
        for n in 1...200 {
            let seconds = StartAnchorBudget.lead(forStartablePlayerCount: n).seconds
            #expect(seconds >= previous, "lead must never DECREASE with more players (n=\(n))")
            #expect(seconds >= StartAnchorBudget.leadFloorSeconds, "n=\(n)")
            #expect(seconds <= StartAnchorBudget.leadCapSeconds, "n=\(n)")
            previous = seconds
        }
    }

    /// A negative count is not reachable from `startablePlayerCount` (it counts
    /// nodes), but the forecast path passes a value read at a different moment
    /// than the one the formula is evaluated for, so the function must not
    /// produce something absurd if that ever changes shape.
    @Test("a nonsensical count still yields the floor, never a negative lead")
    func negativeCountsClampToTheFloor() {
        for n in [-1, -10, -1_000] {
            #expect(StartAnchorBudget.lead(forStartablePlayerCount: n).seconds
                    == StartAnchorBudget.leadFloorSeconds, "n=\(n)")
        }
    }

    // MARK: - The horizon identity

    /// The identity live leg L3 asserts against the engine's reported horizon.
    /// If this ever stops holding, L3's exact read-back becomes a comparison
    /// between two different formulas and stops discriminating anything.
    @Test("horizon(n) == lead(n) + the schedule allowance, for every n")
    func horizonIsLeadPlusAllowance() {
        for n in [0, 1, 5, 6, 7, 16, 32, 59, 60, 61, 200] {
            let horizon = StartAnchorBudget.continuationHorizonSeconds(forStartablePlayerCount: n)
            let expected = StartAnchorBudget.lead(forStartablePlayerCount: n).seconds
                + StartAnchorBudget.scheduleAllowanceSeconds
            #expect(horizon == expected, "n=\(n)")
        }
        // Anchored to their derivations (design §13.4), not to a snapshot:
        // 0.030 is bs-1's full-suite worst segment B (20.2 ms) x 1.5, and it
        // also buys 8 ms/player x 3 players of unforeseen-count headroom.
        #expect(StartAnchorBudget.scheduleAllowanceSeconds == 0.030)
        #expect(StartAnchorBudget.scheduleAllowanceSeconds
                >= 3.0 * 0.008,
                "the allowance must absorb at least three unforeseen players (§13.3)")
        #expect(abs(StartAnchorBudget.continuationHorizonSeconds(forStartablePlayerCount: 0)
                    - 0.090) < 1e-12)
    }

    /// The horizon can never exceed the gap bound the tree already tolerates
    /// for a normal start's lead plus the allowance — the fix introduces no
    /// NEW tolerance for how long the recovery dropout may last.
    @Test("the horizon is bounded by cap + allowance for every n")
    func horizonIsBounded() {
        let bound = StartAnchorBudget.leadCapSeconds + StartAnchorBudget.scheduleAllowanceSeconds
        for n in [0, 5, 16, 60, 61, 1_000] {
            let horizon = StartAnchorBudget.continuationHorizonSeconds(forStartablePlayerCount: n)
            #expect(horizon <= bound, "n=\(n)")
            #expect(horizon >= StartAnchorBudget.leadFloorSeconds
                    + StartAnchorBudget.scheduleAllowanceSeconds, "n=\(n)")
        }
    }
}
