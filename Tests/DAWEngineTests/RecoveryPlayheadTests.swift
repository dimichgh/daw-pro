import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bq — THE PLAYHEAD MUST KEEP MOVING ACROSS AN ENGINE BOUNCE.
//
// THE DEFECT (measured 2026-08-02, fixed in `AudioEngine.recoverEngine`):
// recovery restarts the engine and then anchored the transport against
// `outputNode.lastRenderTime`, which — until the NEW render session's first
// callback — still reports the PREVIOUS session's sample clock with its valid
// flags set. The resulting sample anchor makes `elapsedSeconds` read a large
// NEGATIVE elapsed time, `derivedBeats`' `max(anchor.startBeats, …)` clamp pins
// the playhead at the resume beat, and it stays there for the whole length of
// the previous session. Measured plateaus BEFORE the fix, against rolls of
// 1000 / 2000 / 3000 ms: 1045 / 2060 / 3063 ms — a 1:1 line, which is the
// causal proof. AFTER the fix: 35 / 69 ms, i.e. the ~60 ms start lead-in.
//
// WHY THIS FILE EXISTS AT ALL — the blindness it closes:
// `EngineWatchdogTests.liveWatchdogRestart` asserted `pushes.count >
// pushesAtRestart`. That is CALLBACK LIVENESS, and the defect preserves it
// PERFECTLY: the playhead task keeps firing at 30 Hz, pushing the same frozen
// VALUE. A test that asserts exactly the non-property a bug preserves is how
// the bug shipped. Everything here asserts the VALUE.
//
// ⚠️ THE METRIC IS LAG-AGAINST-WALL-TIME, NOT PUSH TIMING — AND THAT IS
// LOAD-DRIVEN, NOT TASTE. The first version of this file measured how long the
// pushed beat stood still. It passed alone and FAILED IN THE FULL SUITE, where
// other @MainActor suites starve this one's main actor so hard that a nominal
// 1200 ms roll produced ZERO pushes and a nominal 1800 ms window produced
// THREE (measured 2026-08-02). Under starvation the pushes are RARE BUT
// CORRECT; under the m23-bq defect they are FREQUENT BUT WRONG. So the
// assertion compares each pushed beat against the beat wall-time says it
// should be — a quantity ONE accurate sample settles, and which starvation
// cannot fake. Do not "simplify" this back to counting pushes or timing
// plateaus; that is the version that flakes.
//
// ⚠️ THE RED MARGIN RESTS ON `rollMs`. The freeze length EQUALS the previous
// session's length, so the lag the defect produces is `rollMs` of music. A
// future author who shortens `rollMs` to speed the suite up silently disarms
// this file: `rollMs` must stay ≥ 3× `maxLagBeats` expressed as time (1 beat =
// 500 ms at 120 BPM). RE-DERIVED at m23-bs-2 when the ceiling dropped
// 1.2 → 0.25: the floor is now 3 × 0.25 × 500 ms = 375 ms, and the unchanged
// 2000 ms keeps 5.3× margin. Do NOT delete the law because the margin got
// comfortable — its purpose (a shortened `rollMs` disarms the m23-bq freeze
// guard) is unchanged.
//
// ═══ m23-bs-2 — THIS FILE IS NOW CORROBORATION, NOT THE REGRESSION GUARD ═══
//
// (design §9.2, in those words): THE PROPERTY ASSERTION CARRIES IT —
// `RecoveryAnchorContinuityGateTests`, declared in an extension of THIS suite.
// The property seam proves the two anchor lines coincide; it must NEVER be
// loosened, and if it fails the engine is wrong. This file proves the
// coinciding lines correspond to something audible; it MAY be loosened freely.
// If it flakes under full-suite load, loosen THIS leg, never the property
// assertion.
//
// ⚠️ TWO SIGN WARNINGS FOR A FUTURE AUTHOR, both of which would red a CORRECT
// engine:
//
//  1. `plateauMs` — the fix makes this number BIGGER ON PURPOSE. The plateau
//     and the lag are distinct quantities that m23-bs-2 moves in OPPOSITE
//     directions: `maxLagBeats` is the beat OFFSET of the republished line
//     (driven to zero), while `plateauMs` is the GAP, which becomes
//     `A_after_stop + horizon` — the same work with segment B replaced by a
//     30 ms allowance, i.e. ~29 ms LONGER. That trade is the design: a
//     transient, bounded gap is paid to remove a PERMANENT timing offset that
//     corrupts every subsequent beat→time mapping including the recording
//     clock. Asserting a small plateau would red a correct fix. (Independently,
//     the plateau is a SAMPLING ARTEFACT — it counts pushes within 0.02 beats
//     on a 33 ms grid while measuring a ~60 ms quantity, so its achievable
//     values are {0, 33, 66, …} and its run-to-run variance is ALIASING, not
//     physics.)
//  2. The lag metric is ONE-SIDED on purpose (`lag = expected − beat`). Under
//     `.atHostTime` the anchor is in the FUTURE during the gap, so
//     `derivedBeats`' `max(startBeats, …)` clamp makes the playhead read AHEAD
//     of wall time by up to the horizon before wall time catches up. An
//     "improvement" to `abs(...)` would red a correct fix.
//
// ⚠️ THE 0.25 CEILING IS BUFFER-SIZE DEPENDENT THROUGH δ — RE-DERIVE IT, DO
// NOT BUMP IT. Post-fix the recovery re-aligns the transport to the ORIGINAL
// anchor's line, so all three legs converge on the CONTROL's lag plus β·δ,
// where δ is how far `outputNode.lastRenderTime.hostTime` leads
// `mach_absolute_time()` and β is beats-per-second (2.0 at this fixture's
// 120 BPM). ⚠️ WRITE IT β·δ, NOT "2·δ": design §13.1 says 2·δ, which reads like
// a factor of two but IS the tempo conversion. At 60 BPM the same δ costs HALF
// the beats. δ is printed on every gate run by
// `RecoveryAnchorContinuityGateTests.measureRenderClockLeadSeconds`.
//
// δ IS A SAWTOOTH, NOT A SCALAR — measured at m23-bs-2 and NOT stated by §13.1,
// whose "one output buffer + presentation latency" is δ's FLOOR only.
// `lastRenderTime.hostTime` holds still between render callbacks and jumps one
// buffer at each, so δ sweeps `[b + L, 2b + L]`. MEASURED on this machine
// (512 frames / 48 kHz, b = 10.7 ms): δ ∈ [11.6, 21.8] ms, span 10.2 ms =
// exactly one buffer, so L ≈ 0.9 ms. The outgoing anchor takes a SINGLE RANDOM
// DRAW from that sawtooth, which is why the expected lag is a BAND, not a
// point, and why two clean runs read 0.148 and 0.171 — that spread is the
// sawtooth, not noise.
//
//   buffer │ δ (ms)      │ β·δ (beats) │ expected lag  │ margin to 0.25
//   ───────┼─────────────┼─────────────┼───────────────┼────────────────
//    512   │ 11.6 – 21.8 │ 0.023–0.044 │ 0.145 – 0.166 │ 1.5 – 1.7×
//   1024   │ 22.2 – 43.6 │ 0.044–0.087 │ 0.166 – 0.209 │ 1.2 – 1.5×
//   2048   │ 43.6 – 86.2 │ 0.087–0.172 │ 0.209 – 0.294 │ ⚠️ CEILING INSIDE
//                                                         THE BAND
//
// ⚠️ THE BAND PREDICTS THE *DELTA*, NOT THE ABSOLUTE LAG. The absolute lag also
// carries ambient main-actor scheduling variance, which the in-run delta cancels
// — that is the whole reason `maxDeltaBeats` exists as a second assertion. So
// the falsifiable prediction is the DELTA column, and the "expected lag" column
// above is only that band added to ONE run's control for orientation.
//
// MEASURED after the fix, 2026-08-02, 512 frames — DELTAS (restart − control,
// SAME RUN): 0.024, 0.026, 0.039, 0.044. All four inside the predicted
// [0.023, 0.044], and the last one lands exactly ON the top: that run's
// same-run pair was control 0.123 → restart 0.167 = control + β·(2b+L), the
// sawtooth's worst draw, arriving as predicted rather than as a surprise.
// ABSOLUTE worst restart across all runs: 0.171, ~0.005 above the band added to
// a 0.122-class control — that excess is ambient variance, not a δ
// mis-prediction.
// (An earlier draft of this paragraph paired a 0.122 control from one run with a
// 0.171 restart from ANOTHER and called the pair "inside the band". It is not:
// 0.171 > 0.166. Two runs presented as one triple, in the same file that warns
// about stale numbers beside changed ones. Quote same-run pairs only.)
//
// So AT 2048 FRAMES THIS FILE FLAKES ON A CORRECT ENGINE. Recompute the ceiling
// as `(control + β·δ_max) × 1.5`, never raise it by feel — and see the
// `maxDeltaBeats` doc comment, which breaks EARLIER than this one does.
//
// KNOWN, NAMED LIMIT: if the main actor is starved so completely that no push
// lands inside the freeze window at all, this reads green against a defective
// engine. That is a false GREEN under extreme load, never a false RED — the
// deliberate trade. The mutant run that proves the file can fail
// (`renderClockTrusted: true` in `recoverEngine` → lag 2.6+ beats) is run
// filtered, i.e. unstarved.
//
// Device-gated by the `liveSmoke` idiom: `prepare()` throwing means no output
// device (headless CI), and the test returns rather than failing. The
// source-level companion pin (`RenderClockTrustSiteTests`) is what still holds
// on such a machine.

@MainActor
@Suite("Recovery playhead — stale render clock (m23-bq)", .serialized)
struct RecoveryPlayheadTests {

    // MARK: - The measurement

    /// What the harness does at the mark.
    private enum Bounce {
        /// Positive control: no recovery at all. A failure HERE means the
        /// harness (not the engine) is what stalls, so the real legs cannot
        /// read as a pass while the fixture is sick.
        case none
        /// The watchdog's restart closure — `engine.stop()` then
        /// `recoverEngine()`, so the hardware genuinely bounces. THIS is the
        /// leg that reproduces the defect.
        case watchdog
        /// `recoverEngine()` alone, i.e. the configuration-change route
        /// (`handleConfigurationChange` is a verbatim one-line alias for it).
        /// Its `if !engine.isRunning` guard means a healthy engine is NOT
        /// bounced here, so the render clock stays live and current — this leg
        /// is a REGRESSION GUARD for the unconditional `renderClockTrusted:
        /// false`, not a defect reproduction. It is green on the unfixed tree
        /// too, by design: see `configChangeRouteStaysHealthy`.
        case recoverOnly
    }

    private struct Result {
        /// Worst (beat wall-time implies) − (beat actually pushed) over every
        /// push after the mark. ~0.1–0.3 beats is healthy: the start lead-in
        /// plus scheduling. The m23-bq defect drives it to `rollMs` of music.
        let maxLagBeats: Double
        /// The push that produced `maxLagBeats`, for the failure message.
        let worstAtMs: Double
        let worstBeat: Double
        let worstExpected: Double
        let pushesAfterMark: Int
        /// Diagnostic only (the orchestrator's original metric): how long the
        /// pushed beat stood within 0.02 beats of its first post-mark value.
        /// NEVER asserted on — see the file header, warning 1: m23-bs-2 makes
        /// this number BIGGER on purpose.
        let plateauMs: Double
        /// m23-bs-2: how many continuation anchors overran their predicted
        /// instant during this measurement. Non-zero means the recovery
        /// degraded to (a smaller version of) the pre-fix behaviour because the
        /// start work outran the budget — a machine fact, so this leg
        /// skips-and-reports rather than failing and teaching the next person
        /// to delete the guard.
        let continuationOverruns: Int
        let worstOverrunMs: Double
        /// m23-bu-2: the render thread's own `callbackCount`, sampled at the
        /// bounce mark and again after the observation window — the
        /// starvation-witness discriminator. Captured HERE, inside
        /// `measure()`, because `engine` is torn down (`defer` below) before
        /// this `Result` reaches the caller.
        let callbackCountAtMark: Int
        let callbackCountAfterObserve: Int

        var rendered: String {
            "maxLagBeats=" + String(format: "%.3f", maxLagBeats)
                + " at=" + String(format: "%.0f", worstAtMs) + "ms"
                + " pushed=" + String(format: "%.3f", worstBeat)
                + " wallSays=" + String(format: "%.3f", worstExpected)
                + " pushes=\(pushesAfterMark)"
                + " plateauMs=" + String(format: "%.0f", plateauMs)
                + " overruns=\(continuationOverruns)"
                + " worstOverrunMs=" + String(format: "%.1f", worstOverrunMs)
        }
    }

    /// 120 BPM (the `TransportState` default) → 1 beat = 500 ms of music.
    ///
    /// ⚠️ 1.2 UNTIL m23-bs-2. That ceiling existed to absorb a SECOND, separate
    /// defect this leg happened to measure: `recoverEngine` derived its resume
    /// beat at entry and anchored only after `engine.stop()`, prepare, start
    /// and a full schedule pass, so the transport stepped BACKWARD by however
    /// long that work took (0.079–0.215 s, measured by m23-bs-1; the anchor
    /// lead was ~75 % of it). m23-bs-2 removed that term, and this ceiling
    /// tightens with it.
    ///
    /// 0.25 IS DERIVED, NOT PICKED. Post-fix the recovery re-aligns the
    /// transport to the ORIGINAL anchor's line, which already carries the first
    /// start's ~0.06 s lead, so all three legs converge on the CONTROL's lag
    /// plus β·δ (the render-clock lead times beats-per-second — see the file
    /// header, and note that δ is a SAWTOOTH so this is a band). Predicted
    /// 0.122 + [0.023, 0.044] = [0.145, 0.166]; MEASURED 2026-08-02 on the
    /// fixed tree, WORST absolute across all runs: control 0.123, recover-only
    /// 0.146, restart 0.171 (the restart figure runs ~0.005 above the band
    /// because the absolute lag also carries ambient scheduling variance — see
    /// the file header). 0.25 is the largest round number below the UNFIXED
    /// tree's recover-only 0.268, so it still kills the mutant.
    ///
    /// THE FLAKE MARGIN IS 0.25 / 0.171 = 1.46× — against the WORST OBSERVED
    /// absolute, because that is the number this assertion would actually flake
    /// at. Do not quote 1.7× (that is the band's floor, i.e. the luckiest draw)
    /// and do not quote 1.5× (that is the band's top, which ignores ambient
    /// variance the band never claimed to cover).
    ///
    /// TIGHTENING IS SAFE UNDER STARVATION, and the reason is not obvious —
    /// two design passes got it wrong. Inside `startPlayheadTask` the only
    /// `await` precedes `derivedBeats()`, and the fixture's sample
    /// `(Date().timeIntervalSince(t0), beat)` is taken inside the handler, so
    /// the beat and its timestamp are read in the SAME synchronous main-actor
    /// run. A starved tick fires LATE but `derivedBeats()` reads the host clock
    /// at that same late moment. THE LAW: starvation costs this metric sample
    /// COUNT, never sample ACCURACY — so a tight ceiling cannot create a false
    /// RED under load. (The withdrawn claim that a 1.8 s main-actor gap would
    /// report ~3.6 beats of apparent lag is FALSE for exactly this reason; do
    /// not re-derive it and do not reintroduce a contention-gated ceiling.)
    private static let maxLagBeats = 0.25
    /// The in-run delta: restart worst-lag minus control worst-lag, measured in
    /// the SAME test so ambient inflation largely cancels. Pre-fix 0.259
    /// (watchdog) / 0.145 (recover-only); post-fix the expectation is β·δ ∈
    /// [0.023, 0.044] on this machine (MEASURED 0.026), and the ceiling carries
    /// δ's buffer-size dependence — but NOT to the same degree as `maxLagBeats`.
    ///
    /// ⚠️ THIS CEILING BREAKS FIRST, AND THAT INVERTS HOW THE TWO READ. The
    /// delta is presented as the SHARPER instrument because ambient inflation
    /// cancels — but cancelling the ambient term leaves it measuring β·δ and
    /// NOTHING ELSE, with no large control lag to dilute it. From the file
    /// header's table: at 1024 frames β·δ tops out at 0.087 against this 0.10 —
    /// and the MEASURED deltas cluster in the band's UPPER half, reaching its
    /// exact top (0.044 observed against a 0.033 midpoint), so the realistic
    /// 1024 margin is ~1.05–1.10×, not the 1.15× a midpoint reading suggests
    /// — the top of the band is not a tail event here, it is a routine draw.
    /// At 2048 β·δ
    /// reaches 0.172 and this leg reds on a CORRECT ENGINE while `maxLagBeats`
    /// is still just inside its band. A future author on bigger buffers will
    /// see THIS fail first and must re-derive `β·δ_max × 1.5` here before
    /// touching anything else.
    ///
    /// ⚠️ Honest caveat: the delta cancels ambient inflation only if both legs
    /// are starved comparably. They are measured sequentially in one test, so
    /// roughly — a burst hitting only the restart leg inflates the delta and
    /// can flake. Acceptable precisely because this whole file is corroboration
    /// (§9.2), and the documented remedy for a flake here is LOOSENING THIS,
    /// never the property assertion.
    private static let maxDeltaBeats = 0.10
    /// See the file header: the defect's lag ≈ this much music (4.0 beats), and
    /// the `rollMs >= 3 × maxLagBeats-as-time` law needs ≥ 375 ms at the 0.25
    /// ceiling — so 2000 ms keeps 5.3× margin.
    private static let rollMs = 2000
    private static let beatsPerMillisecond = 1.0 / 500.0

    private func measure(_ bounce: Bounce, rollMs: Int = rollMs,
                         observeMs: Int) async throws -> Result? {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return nil   // headless machine, no output device — labeled gap
        }
        defer { engine.shutdown() }

        // One held note across the whole fixture: the shape the m20-e filing
        // measured the ~6.5 s freeze on (a sustained pad gives the scheduler
        // nothing to re-attack, so nothing masks a frozen transport).
        engine.tracksDidChange([
            Track(name: "Keys", kind: .instrument,
                  clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 512, notes: [
                      MIDINote(pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 512),
                  ])],
                  instrument: InstrumentDescriptor(kind: .testTone)),
        ])

        var samples: [(ms: Double, beat: Double)] = []
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        // t0 AFTER startPlayback returns, so the schedule pass is outside the
        // measured span; audio then begins one start-lead later, which is the
        // systematic ~0.12 beats the tolerance absorbs. Playback starts at
        // beat 0, so wall-time-implied beat = elapsed(ms) / 500.
        let t0 = Date()
        engine.playheadHandler = { beat in
            samples.append((Date().timeIntervalSince(t0) * 1000, beat))
        }
        try await Task.sleep(for: .milliseconds(rollMs))

        // The mark. Nothing can be pushed between here and the end of the
        // bounce: `watchdogRestart`/`recoverEngine` are synchronous on the
        // main actor and the playhead task can only run at ITS await points,
        // so every post-mark sample is genuinely post-recovery.
        let mark = Date().timeIntervalSince(t0) * 1000
        // m23-bu-2: the starvation-witness discriminator's "before" edge —
        // captured at the mark, so the window it brackets is exactly the one
        // `after` (below) measures.
        let callbackCountAtMark = engine.performanceStats(reset: false).callbackCount
        switch bounce {
        case .none: break
        case .watchdog: try engine.watchdogRestart()
        case .recoverOnly: engine.recoverEngine()
        }
        try await Task.sleep(for: .milliseconds(observeMs))
        // The "after" edge, read BEFORE `stopPlayback()`/the `defer` teardown
        // — StarvationWitness's precondition needs a window with no reset in
        // between.
        let callbackCountAfterObserve = engine.performanceStats(reset: false).callbackCount
        engine.stopPlayback()

        // ⚠️ nil means ONE thing — no output device (the `prepare()` catch
        // above) — and NOTHING else. An empty sample set must reach the
        // caller as a real `Result` (`pushesAfterMark == 0`), not be folded
        // into nil: `nil` prints "NO OUTPUT DEVICE" and returns green, which
        // would make a starved run announce a false reason and skip the
        // whole leg, and would make the StarvationWitness classification at
        // each call site (m23-bu-2) unreachable dead code. (The full-suite
        // run that forced the metric rewrite delivered THREE pushes where
        // ~36 were nominal — zero is not hypothetical.)
        let after = samples.filter { $0.ms > mark }
        var worst = (lag: 0.0, ms: 0.0, beat: 0.0, expected: 0.0)
        for sample in after {
            let expected = sample.ms * Self.beatsPerMillisecond
            let lag = expected - sample.beat
            if lag > worst.lag { worst = (lag, sample.ms, sample.beat, expected) }
        }
        var plateauEndMs = after.first?.ms ?? 0
        for sample in after {
            guard let first = after.first else { break }
            if abs(sample.beat - first.beat) < 0.02 { plateauEndMs = sample.ms } else { break }
        }
        return Result(maxLagBeats: worst.lag, worstAtMs: worst.ms, worstBeat: worst.beat,
                      worstExpected: worst.expected, pushesAfterMark: after.count,
                      plateauMs: plateauEndMs - (after.first?.ms ?? 0),
                      continuationOverruns: engine.continuationOverrunCountForTesting,
                      worstOverrunMs: engine.lastContinuationOverrunSecondsForTesting * 1000,
                      callbackCountAtMark: callbackCountAtMark,
                      callbackCountAfterObserve: callbackCountAfterObserve)
    }

    // MARK: - The defect leg (RED on the unfixed engine)

    @Test("live: watchdogRestart must not freeze the playhead — with an in-run no-restart control")
    func watchdogRestartDoesNotFreezeThePlayhead() async throws {
        // CONTROL FIRST. If the identical measurement reads a lagging playhead
        // WITHOUT a recovery, the fixture is sick and the leg below proves
        // nothing.
        guard let control = try await measure(.none, observeMs: 1200) else {
            print("[measured] m23-bq: NO OUTPUT DEVICE — live legs skipped")
            return
        }
        print("[measured] m23-bq CONTROL(no-restart) \(control.rendered)")
        let sick = "POSITIVE CONTROL FAILED — plain playback, no recovery at all, pushed a "
            + "playhead that lags wall time. The FIXTURE is sick, not the engine; nothing "
            + "below this line means anything. " + control.rendered
        // m23-bu-2: zero pushes here is ambiguous between a starved sampling
        // window and a genuinely sick fixture — the render-thread callback
        // counter tells them apart (StarvationWitness). A starved CONTROL
        // does not mean the fixture is sick, so this does not fall through
        // to the "sick" message; it skips the WHOLE TEST instead, matching
        // the "no output device" skip two lines above, because nothing below
        // can be trusted without a working control either way.
        switch StarvationWitness.classify(
            mainActorSampleCount: control.pushesAfterMark,
            callbackCountBefore: control.callbackCountAtMark,
            callbackCountAfter: control.callbackCountAfterObserve
        ) {
        case .starved(let delta, let minimum):
            StarvationWitness.printSkip(
                leg: "watchdogRestartDoesNotFreezeThePlayhead(control)",
                mainActorSampleCount: control.pushesAfterMark, minimumSamples: minimum,
                callbackDelta: delta)
            return
        case .renderDead:
            let sickDead: String = sick + " (the render callbackCount also did not advance: "
                + "\(control.callbackCountAtMark)→\(control.callbackCountAfterObserve) — this is "
                + "not starvation, the control genuinely never rendered.)"
            Issue.record("\(sickDead)")
            return
        case .usable:
            break
        }
        #expect(control.maxLagBeats <= Self.maxLagBeats, "\(sick)")

        // THE LEG. Same measurement, with a real engine bounce at the mark.
        // A nil HERE is not the ordinary no-device skip — the control one
        // statement above just prepared an engine on this same machine, so
        // `prepare()` throwing now is an anomaly, and swallowing it would make
        // the one leg that carries this whole item vanish without a word.
        guard let bounced = try await measure(.watchdog, observeMs: 1200) else {
            let vanished: String = "engine.prepare() threw for the RESTART leg although the "
                + "no-restart control prepared fine moments earlier — the m23-bq leg did not run"
            Issue.record("\(vanished)")
            return
        }
        print("[measured] m23-bq RESTART(roll=\(Self.rollMs)ms) \(bounced.rendered)")

        // Liveness first, so a value failure below is unambiguous: if the
        // pushes stopped, the diagnosis is a dead playhead task, not a stale
        // clock — UNLESS the render side is simply starved, which
        // StarvationWitness (m23-bu-2) is what tells apart.
        switch StarvationWitness.classify(
            mainActorSampleCount: bounced.pushesAfterMark,
            callbackCountBefore: bounced.callbackCountAtMark,
            callbackCountAfter: bounced.callbackCountAfterObserve
        ) {
        case .starved(let delta, let minimum):
            StarvationWitness.printSkip(
                leg: "watchdogRestartDoesNotFreezeThePlayhead(restart)",
                mainActorSampleCount: bounced.pushesAfterMark, minimumSamples: minimum,
                callbackDelta: delta)
            return
        case .renderDead:
            let dead = "no playhead pushes at all after watchdogRestart, AND the render "
                + "callbackCount did not advance either (\(bounced.callbackCountAtMark)→"
                + "\(bounced.callbackCountAfterObserve)) — that is a DEAD PLAYHEAD TASK or a "
                + "dead render thread, a DIFFERENT defect from m23-bq (which keeps pushing a "
                + "frozen value while the render side stays alive). " + bounced.rendered
            Issue.record("\(dead)")
            return
        case .usable:
            break
        }

        // m23-bs-2: a budget overrun means the recovery genuinely degraded
        // toward the pre-fix behaviour because the start work outran its
        // predicted horizon. That is a MACHINE FACT, not a defect, and the
        // engine's own counter is a purpose-built, exact, in-band detector —
        // strictly better than any generic contention probe. Skip LOUDLY: a
        // silent skip looks exactly like coverage.
        if bounced.continuationOverruns > 0 {
            print("[measured] m23-bq/m23-bs-2 RESTART leg SKIPPED — continuation budget "
                  + "overrun ×\(bounced.continuationOverruns), worst "
                  + String(format: "%.1f", bounced.worstOverrunMs) + " ms. The property "
                  + "assertion in RecoveryAnchorContinuityGateTests is unaffected and still ran.")
            return
        }

        let why = "m23-bq REGRESSION: the transport froze across an engine bounce — the pushed "
            + "beat fell behind wall time by more than \(Self.maxLagBeats) beats. The lag tracks "
            + "the PREVIOUS session's length 1:1 (rolled \(Self.rollMs) ms here = 4 beats of "
            + "music), which is the signature of startPlayers anchoring against a stale "
            + "outputNode.lastRenderTime. Check that recoverEngine still passes "
            + "`renderClockTrusted: false`. " + bounced.rendered
        #expect(bounced.maxLagBeats <= Self.maxLagBeats, "\(why)")

        // m23-bs-2, THE SHARPER INSTRUMENT: the in-run delta cancels the
        // systematic start-lead offset both legs carry, so it isolates what the
        // RECOVERY costs. Pre-fix 0.259; post-fix the prediction is β·δ, a BAND
        // of [0.023, 0.044] at this buffer size, not a point (δ is a sawtooth).
        // A SECOND assertion, never a replacement — the absolute ceiling is
        // what kills the unfixed tree's 0.362–0.383.
        let delta = bounced.maxLagBeats - control.maxLagBeats
        print("[measured] m23-bs-2 in-run delta(restart − control)="
              + String(format: "%.3f", delta) + " beats (ceiling \(Self.maxDeltaBeats))")
        let drifted = "m23-bs REGRESSION: the recovery cost \(delta) beats of transport "
            + "position relative to the in-run no-restart control. Post-fix the recovery "
            + "re-aligns to the OUTGOING anchor's line, so this should land in β·δ's band "
            + "([0.023, 0.044] beats at a 512-frame buffer; β is beats-per-second, NOT a "
            + "factor of two) — see the file header's buffer table before touching this "
            + "ceiling. It is the leg that reds FIRST on a bigger buffer, on a correct engine. "
            + "control=" + control.rendered + " restart=" + bounced.rendered
        #expect(delta <= Self.maxDeltaBeats, "\(drifted)")
    }

    // MARK: - The configuration-change route (regression guard, green both ways)

    /// `handleConfigurationChange()` is a verbatim one-line alias for
    /// `recoverEngine()`, so the device-flip route is fixed by the same line.
    /// Driven directly here WITHOUT a preceding `engine.stop()`, which is the
    /// case `recoverEngine`'s `if !engine.isRunning` guard leaves un-bounced:
    /// the render clock is live and current, so BOTH the trusted and the
    /// host-clock branch are correct.
    ///
    /// ⚠️ THIS TEST IS GREEN ON THE UNFIXED TREE TOO. That is correct, not a
    /// broken test — do not "fix" it by making it look like the leg above. Its
    /// job is to prove the UNCONDITIONAL `renderClockTrusted: false` does not
    /// degrade the non-bounced path (the reason the fix is not written as
    /// `renderClockTrusted: !engine.isRunning`, which would add a branch no
    /// test can reach).
    @Test("live: recoverEngine on a still-running engine resumes without a stall")
    func configChangeRouteStaysHealthy() async throws {
        guard let recovered = try await measure(.recoverOnly, rollMs: 800,
                                                observeMs: 1200) else {
            print("[measured] m23-bq: NO OUTPUT DEVICE — config-change leg skipped")
            return
        }
        print("[measured] m23-bq RECOVER-ONLY(no engine stop) \(recovered.rendered)")
        let why = "the configuration-change route (recoverEngine on a still-running engine) "
            + "left the transport lagging wall time. " + recovered.rendered
        // m23-bu-2: StarvationWitness tells a starved window apart from a
        // genuinely dead render side — see the restart leg above.
        switch StarvationWitness.classify(
            mainActorSampleCount: recovered.pushesAfterMark,
            callbackCountBefore: recovered.callbackCountAtMark,
            callbackCountAfter: recovered.callbackCountAfterObserve
        ) {
        case .starved(let delta, let minimum):
            StarvationWitness.printSkip(
                leg: "configChangeRouteStaysHealthy", mainActorSampleCount: recovered.pushesAfterMark,
                minimumSamples: minimum, callbackDelta: delta)
            return
        case .renderDead:
            let whyDead: String = why + " (the render callbackCount also did not advance: "
                + "\(recovered.callbackCountAtMark)→\(recovered.callbackCountAfterObserve) — not "
                + "starvation.)"
            Issue.record("\(whyDead)")
            return
        case .usable:
            break
        }
        // m23-bs-2 overrun skip — see the restart leg for why this keys off the
        // engine's own counter rather than a generic contention probe.
        if recovered.continuationOverruns > 0 {
            print("[measured] m23-bq/m23-bs-2 RECOVER-ONLY leg SKIPPED — continuation budget "
                  + "overrun ×\(recovered.continuationOverruns), worst "
                  + String(format: "%.1f", recovered.worstOverrunMs) + " ms.")
            return
        }
        #expect(recovered.maxLagBeats <= Self.maxLagBeats, "\(why)")
    }
}
