import Testing

// m23-bu-2 — THE SHARED STARVATION-WITNESS HELPER.
//
// docs/ARCHITECTURE.md's m23-bu-1 rule (SETTLED 2026-08-02) says: prefer a
// property witness over a timing one, and where timing genuinely cannot be
// avoided the metric must survive a SPARSE sample (lag-against-wall-clock,
// not advance-per-window — a RATE metric needs many samples and starvation
// destroys the sample count while ONE accurate sample settles a LAG metric).
// This file is the piece that rule left open: the one case a property or a
// lag metric cannot resolve on its own is when the observation IS "did
// anything main-actor-side arrive at all" — a sparse (often zero) sample
// count is genuinely ambiguous between two very different machine facts:
//
//   • a STARVED window — the main actor never got scheduled to run the
//     sampling task, while the render thread kept producing audio
//     underneath it the whole time. Not a defect. Skip-and-report.
//   • a genuinely DEAD render thread — nothing is playing, full stop. A
//     real defect. Must FAIL, never skip; wrapping this in a starvation
//     excuse is exactly the false-green this item exists to prevent.
//
// THE DISCRIMINATOR: `AudioEngine.performanceStats(reset:
// false).callbackCount` (`Sources/DAWEngine/AudioEngine.swift:4290`, `public`,
// field on `EnginePerformanceStats` at `Sources/DAWCore/Model.swift:2193`,
// already read exactly this way from this test target at
// `Tests/DAWEngineTests/EnginePerformanceTests.swift:210`) — a monotone
// counter incremented on the REAL-TIME render thread. Main-actor starvation
// cannot touch that thread, so comparing its count across the same window a
// main-actor sample was drawn from tells the two cases apart:
//
//   render callbackCount ADVANCED  + sparse main-actor samples  → starved
//   render callbackCount UNCHANGED + sparse main-actor samples  → render dead
//   main-actor samples >= the required minimum                 → usable
//
// ⚠️ PRECONDITION, LOAD-BEARING: `callbackCount` is the CURRENT WINDOW count,
// not a lifetime cell (`EnginePerformanceContext.lifetimeCallbackCount()`
// exists at `Sources/DAWEngine/EnginePerformance.swift:205` but hangs off
// `AudioEngine`'s `private let performance`, which `@testable` does not
// open). The window is rebased ONLY by `performanceStats(reset: true)` or by
// `AudioEngine` init — nothing on the recovery paths this helper retrofits
// (`watchdogRestart`, `recoverEngine`, `rebuildEngine`) touches `performance`
// itself (verified: `performance` is assigned, never reassigned, into the
// graph/renderer at rebuild — `AudioEngine.swift:615`/`:1986` — so the SAME
// counter threads through a bounce). Each retrofitted leg in this tree owns
// ONE fresh `AudioEngine` per measurement and never calls `reset: true` on
// it, so within one measurement the count is monotone-since-init and a
// simple before/after comparison is valid. A future caller that reuses an
// engine across an explicit reset, or reads a SECOND engine's counter, breaks
// this precondition and must not use this helper as-is.
//
// The API takes raw `Int` counts rather than a live `AudioEngine`, on
// purpose: `RecoveryPlayheadTests.measure()` (the B3 retrofit site) captures
// both counts and shuts its engine down BEFORE returning its `Result` to the
// caller that classifies, so a caller-observed live engine is not always
// available at classification time. Capture both counts yourself, at the
// edges of the SAME window whose main-actor sample count you are about to
// judge, before any teardown.
enum StarvationWitness {
    /// The three-way classification this helper exists to make.
    enum Outcome: Equatable {
        /// The main-actor sample count already cleared `minimumSamples` —
        /// nothing to classify. Proceed with the caller's normal assertions.
        case usable
        /// Samples were sparse (below `minimumSamples`) AND the render
        /// thread's own callback counter advanced across the same window:
        /// the main actor was starved of scheduling time, not the render
        /// side. Not a defect — the caller must skip-and-report, never fail.
        ///
        /// ⚠️ It carries `minimumSamples` for the same reason it carries
        /// `callbackDelta`: so the skip MESSAGE cannot disagree with the
        /// classification that produced it. An earlier draft let each call
        /// site pass its own `minimumSamples` to `printSkip` separately, and
        /// a forced-starvation run (m23-bu-2 verification) printed
        /// `(minimum 1)` for a skip actually triggered at 10 000 — two
        /// computations of one fact, on a path that fires rarely enough that
        /// nobody would be watching when it lied. Read it off the outcome.
        case starved(callbackDelta: Int, minimumSamples: Int)
        /// Samples were sparse AND the render thread's callback counter did
        /// NOT advance: the render thread itself is not running. This is the
        /// genuine defect a starvation skip would otherwise hide. The caller
        /// must fail, never skip.
        case renderDead
    }

    /// Classify a window from callback counts captured at its edges.
    ///
    /// - Parameters:
    ///   - mainActorSampleCount: how many main-actor-side samples (playhead
    ///     pushes, etc.) landed inside the window.
    ///   - minimumSamples: the smallest count the caller is willing to trust
    ///     without consulting the render-side witness. Default 1 — the
    ///     common case is "did anything arrive at all".
    ///   - callbackCountBefore: `engine.performanceStats(reset:
    ///     false).callbackCount` sampled at the window's start.
    ///   - callbackCountAfter: the same read, sampled at the window's end
    ///     (before any teardown — see the precondition above).
    static func classify(
        mainActorSampleCount: Int,
        minimumSamples: Int = 1,
        callbackCountBefore: Int,
        callbackCountAfter: Int
    ) -> Outcome {
        guard mainActorSampleCount < minimumSamples else { return .usable }
        let delta = callbackCountAfter - callbackCountBefore
        return delta > 0
            ? .starved(callbackDelta: delta, minimumSamples: minimumSamples)
            : .renderDead
    }

    /// The one greppable print for every starvation-skip site in this tree.
    /// Deliberately distinct wording from the other `[measured] … SKIPPED`
    /// idioms already in this tree (m23-bt/m23-bs-2 use that phrasing for
    /// OTHER machine facts — a missing loopback device, a continuation budget
    /// overrun) so a grep for `STARVATION-SKIP` specifically finds only
    /// starvation-witness skips, and finding zero of them in a run is a
    /// coverage fact worth noticing, not silence indistinguishable from
    /// "nothing to skip".
    static func printSkip(
        leg: String, mainActorSampleCount: Int, minimumSamples: Int, callbackDelta: Int
    ) {
        print("[measured] STARVATION-SKIP \(leg): mainActorSamples=\(mainActorSampleCount) "
              + "(minimum \(minimumSamples)) while the render thread's callbackCount advanced by "
              + "\(callbackDelta) across the same window — classified as main-actor starvation, "
              + "not a dead render thread.")
    }
}

// MARK: - Durable pin of the three-way contract

/// Headless, no engine, no wall clock — pins `classify`'s arithmetic itself
/// so the contract stays checked between the rare occasions a live leg
/// actually exercises `.starved` or `.renderDead` under real contention. This
/// is NOT a substitute for the forced live proof (see the m23-bu-2 report);
/// it is what stays behind after that forcing is reverted.
@Suite("Starvation witness — classification contract (m23-bu-2)")
struct StarvationWitnessTests {
    @Test("sparse samples + advancing render side classify as starved, never a failure")
    func sparseWithAdvancingRenderIsStarved() {
        let outcome = StarvationWitness.classify(
            mainActorSampleCount: 0, callbackCountBefore: 100, callbackCountAfter: 108)
        #expect(outcome == .starved(callbackDelta: 8, minimumSamples: 1))
    }

    @Test("the outcome carries the minimum that produced it — the skip message cannot lie")
    func starvedCarriesItsOwnMinimum() {
        // ⚠️ NON-DEFAULT on purpose. A pin written at the default (1) cannot
        // discriminate a CARRIED value from a HARDCODED one — it passes
        // either way, which is exactly how the defect this guards against
        // survived to a forced run in the first place (m23-bu-2: a skip
        // triggered at 10 000 printed `(minimum 1)`).
        let outcome = StarvationWitness.classify(
            mainActorSampleCount: 2, minimumSamples: 7,
            callbackCountBefore: 100, callbackCountAfter: 142)
        #expect(outcome == .starved(callbackDelta: 42, minimumSamples: 7))
    }

    @Test("sparse samples + a frozen render side classify as renderDead, never a skip")
    func sparseWithFrozenRenderIsDead() {
        let outcome = StarvationWitness.classify(
            mainActorSampleCount: 0, callbackCountBefore: 100, callbackCountAfter: 100)
        #expect(outcome == .renderDead)
    }

    @Test("a sample count clearing the minimum is usable regardless of the render side")
    func sufficientSamplesAreUsable() {
        // The render side is UNCHANGED here on purpose — usable must not
        // consult the render witness at all once the main-actor count alone
        // clears the bar.
        let outcome = StarvationWitness.classify(
            mainActorSampleCount: 5, minimumSamples: 1,
            callbackCountBefore: 100, callbackCountAfter: 100)
        #expect(outcome == .usable)

        // The boundary itself: exactly `minimumSamples` is usable.
        let boundary = StarvationWitness.classify(
            mainActorSampleCount: 3, minimumSamples: 3,
            callbackCountBefore: 100, callbackCountAfter: 100)
        #expect(boundary == .usable)

        // One below the boundary, with the render side frozen, is renderDead.
        let belowBoundary = StarvationWitness.classify(
            mainActorSampleCount: 2, minimumSamples: 3,
            callbackCountBefore: 100, callbackCountAfter: 100)
        #expect(belowBoundary == .renderDead)
    }
}
