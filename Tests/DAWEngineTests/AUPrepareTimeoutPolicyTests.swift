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

    /// The test-time value carries no claim about AU behaviour, but it does
    /// carry one about headroom: it must clear the slowest prepare actually
    /// measured under a full parallel run with margin, or it is just a slower
    /// version of the same flake.
    ///
    /// 26.9 s is the SLOWEST of eight full runs at m23-at (`[measured] GM bank
    /// prepare-to-ready wall time`, printed by `SoundBankHostingTests` on every
    /// run — so if this figure ever goes stale, the run that invalidates it
    /// also prints its replacement). Note it is above the 17–22 s seen before
    /// this policy existed, because prepares that used to be abandoned at 10 s
    /// now run to completion and lengthen the main-actor queue they wait in.
    @Test("the test-time timeout clears the measured full-suite prepare with margin")
    func testTimeoutHasHeadroomOverMeasuredWorstCase() {
        let measuredWorstCase = Duration.seconds(27)   // m23-at, slowest of 8 full runs
        #expect(AUHostRegistry.testPrepareTimeout >= measuredWorstCase * 2)
    }
}
