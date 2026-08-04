import DAWCore
import DAWEngine
import Foundation
import Testing

/// m23-at — the AU-prepare timeout POLICY, pinned.
///
/// m23-at made the deadline real (`DAWCore.DeadlineRace`: the timeout no
/// longer needs the main actor to fire). That exposed a pre-existing fact
/// rather than creating one — under a full parallel test run the same prepare
/// that takes 0.05–0.6 s isolated takes 17–22 s, queued behind ~78%
/// `@MainActor`-isolated sibling suites (m23-ab-3) — so the default timeout
/// now diverges between the shipped app and a detected test process.
///
/// A divergence like that is a hiding place unless something pins the side
/// that ships. That is this file's entire job: the PRODUCTION constant, not
/// the test-time one, is the assertion with teeth. The roadmap's m23-at line
/// says in as many words "Do NOT just raise the 10 s number"; until now
/// nothing enforced it but memory.
@Suite("AU prepare timeout policy (m23-at)")
struct AUPrepareTimeoutPolicyTests {

    /// THE PIN. Pinned against the LITERAL, deliberately — deriving it from
    /// anything in the source would make the test pass for whatever the source
    /// happens to say, which is the tautology this project has a named law
    /// about. If a future cycle wants a different shipped wall, it must change
    /// this number by hand and justify it against the roadmap.
    @Test("the shipped prepare timeout is 10 s — raising it is what m23-at forbids")
    func productionTimeoutIsTenSeconds() {
        #expect(AUHostRegistry.productionPrepareTimeout == .seconds(10))
    }

    /// Anti-vacuity for the pin above: the production constant must be a real
    /// wall, not a placeholder that a zero/huge value could satisfy while
    /// still reading as "10 seconds" to a careless eye.
    @Test("the shipped timeout is finite and positive")
    func productionTimeoutIsAUsableWall() {
        #expect(AUHostRegistry.productionPrepareTimeout > .zero)
        #expect(AUHostRegistry.productionPrepareTimeout < .seconds(60))
    }

    /// The divergence itself, stated out loud rather than left implicit. This
    /// process IS a test process (that is what makes the whole redirection
    /// meaningful), so the effective default must be the test value — and the
    /// two values must actually differ, or the divergence is decorative and
    /// the AU suites go back to reporting harness load as plugin stalls.
    @Test("inside a test process the default diverges from the shipped wall")
    func defaultDivergesUnderTest() {
        #expect(TestEnvironment.isRunningTests,
                "this assertion runs inside ./scripts/test.sh, so the detector must say so")
        #expect(AUHostRegistry.defaultPrepareTimeout == AUHostRegistry.testPrepareTimeout)
        #expect(AUHostRegistry.defaultPrepareTimeout != AUHostRegistry.productionPrepareTimeout)
    }

    /// m23-aw — THE ANTI-CIRCUMVENTION PIN, replacing a TAUTOLOGY.
    ///
    /// The assertion this replaced (`testTimeoutHasHeadroomOverMeasuredWorstCase`)
    /// compared `Duration.seconds(27) * 2 <= Duration.seconds(60)` — two
    /// compile-time constants, an assertion that could not observe the
    /// program and could not fail for any behaviour of it. Deleting it is NOT
    /// the m23-as-2 precedent (that deleted a CALIBRATED bound whose
    /// derivation rule had stopped having a solution); this deletes a
    /// statement that never measured anything in the first place.
    ///
    /// What replaces it pins the ONE edit both m23-at and m23-aw forbid:
    /// raising this constant to make an AU suite's headroom problem go away
    /// quietly. `scripts/gates/m23aw-prepare-headroom.mjs` independently fails
    /// its own `horizon` leg on the same edit, so the forbidden move cannot be
    /// made quietly in either place.
    ///
    /// THE MEASUREMENT THIS CONSTANT NOW CARRIES, replacing the stale "27":
    ///   - m23-at derived 60 s as ~2.2x a measured 26.9 s worst case (n=8,
    ///     mixed regimes; the post-policy sub-population was 24.3-26.9 s, n=6).
    ///   - m23-aw RE-MEASURED it 2026-08-03: worst 30.994 s over 5 green
    ///     full-suite runs -> actual margin 1.936x, i.e. BELOW the 2x the
    ///     number was derived under. Under ordinary machine load the same
    ///     channel reached 49.311 s = 82% of the horizon. So the literal this
    ///     replaced — `60 >= 2 * 27 = 54`, true — was already FALSE against
    ///     the real number: `60 >= 2 * 30.994 = 61.99` does not hold.
    ///   - The live headroom check is `scripts/gates/m23aw-prepare-headroom.mjs`
    ///     (worst-of-campaign T1 <= 36 s, campaign-validity-checked); the
    ///     structural early warning is `MainActorOccupancySiteTests`
    ///     (deliberate main-actor occupancy, currently 2 sites / 3000 ms).
    ///   - Raising this constant is forbidden. The permitted response to
    ///     either check firing is m23-aw-1 (reduce the harness's main-actor
    ///     load) or a roadmap-approved, argued change of horizon — never a
    ///     quiet edit here.
    @Test("the test-time horizon is 60 s — raising it is the m23-at move, one regime over")
    func testTimeoutIsSixtySeconds() {
        #expect(AUHostRegistry.testPrepareTimeout == .seconds(60))
    }
}
