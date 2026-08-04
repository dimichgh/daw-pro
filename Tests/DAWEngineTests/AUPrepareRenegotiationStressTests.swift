import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m19-e regression stress. The m18-d gate serialized every DLS bank LOAD and
/// DISPOSE on `AUHostRegistry.dlsBankQueue`, but left the prepare/renegotiation
/// window un-gated: DLS-family `allocateRenderResources` (AudioUnitInitialize)
/// touches the SAME process-global bank state. Pre-fix, a main-actor
/// initialize racing a queued load/dispose died with `CAVerboseAbort` →
/// `AudioUnitInitialize` → `-[AUAudioUnitV2Bridge
/// allocateRenderResourcesAndReturnError:]` inside
/// `AUHostRegistry.performPrepare` (helper .ips corpus 26–29, 2026-07-16; the
/// m19-j cooperative-render yields amplified it from once-per-suite to
/// 3-per-run). m19-j closed BOTH sites: `performPrepare`'s allocate and
/// failure-dealloc hop onto `dlsBankQueue` (awaited), and `HostedAUInstrument`
/// R7 renegotiation runs its dealloc/alloc via sync `withBankGateIfDLS`.
///
/// This suite is the purpose-built amplifier turned regression gate, in the
/// m18-d idiom: it packs hundreds of prepare-vs-renegotiate-vs-dispose windows
/// into one test and passes by SURVIVING (a regression kills the whole test
/// process — there is no softer signal), plus anti-vacuity counters proving
/// the gated paths actually ran: `.ready` prepares, a reload-hook tally that
/// counts every renegotiation completing its gated alloc, and real teardowns.
///
/// It also BOUNDS prepare-under-contention latency: one full-suite run showed
/// a SoundBankHostingTests AU-prepare TIMEOUT on a cold post-recompile suite
/// that re-ran green in isolation at 0.57 s. (HISTORICAL, 2026-07-16: that
/// timeout was 10 s — the value `AUHostRegistry.productionPrepareTimeout`
/// still carries. It is NOT the horizon that applies in THIS process; see the
/// latency contract at the bottom, which reads the horizon from the named
/// constant rather than restating a number that can rot.) Every prepare here
/// is timed mid-churn; per-prepare stalls fail via
/// `AUHostRegistry.defaultPrepareTimeout` → `.failed` → the `.ready` asserts,
/// and the distribution's MIN plus its count-under-budget are asserted under
/// evidence-based bounds, so a future systemic prepare slowdown fails loudly
/// instead of flaking. The MEDIAN bound that used to sit beside them was
/// DELETED at m23-as-2 — the median is still PRINTED, and the contract at the
/// bottom says why.
///
/// `.serialized` (m23-as-2): this suite's second test, the min bound's
/// mutation discriminator, issues 12 more `.soundBank` prepares onto the
/// SAME process-global `dlsBankQueue`. Run in parallel with the stress test
/// it would change the very load shape the stress test's `[measured]` line
/// is the continuity record OF — and that record is what every latency
/// number below was derived from. Serializing the two costs wall time and
/// buys comparability with runs A–F.
@MainActor
@Suite("AU prepare vs renegotiation vs teardown gate stress (m19-e)", .serialized)
struct AUPrepareRenegotiationStressTests {
    /// Main-actor-only tally box for the reload-hook wrapper (the hook runs
    /// inside the renegotiation's `MainActor.assumeIsolated` block).
    private final class Tally {
        var value = 0
    }

    /// THE clean-path latency budget, in seconds — ONE home, shared by the
    /// shipped assertion and by its mutation discriminator below. It is named
    /// rather than repeated so that "loosening it for the discriminator"
    /// cannot happen without visibly loosening the shipped bound too, which
    /// is exactly the mistake `docs/research/design-m23as2-prepare-estimator.md`
    /// §7.4 bans. Value unchanged since m19-e; re-derivation rule at the
    /// bottom of `preparesRaceRenegotiationsAndTeardowns`.
    private static let cleanPathBudgetSeconds = 1.0

    /// How many of the 32 timed prepares must land under
    /// `cleanPathBudgetSeconds`. Derived, MEASURED 2026-08-03 (m23-as-2), by
    /// the written rule `m = floor(C / 2)` where `C` is the WORST `under1s`
    /// observed across the gate's five green full-suite runs plus one
    /// adversarial run: C = 8 (observations 9, 9, 9, 8, 8, and 8 adversarial;
    /// two later verification runs added 9 and 9), so m = 4. Full
    /// derivation and the prohibition on mis-describing this channel: layer 3
    /// of the latency contract in `preparesRaceRenegotiationsAndTeardowns`.
    private static let minimumUnderBudgetPrepares = 4

    /// `Duration` → `Double` seconds. Local to this suite on purpose: it is
    /// test-timing scaffolding, so it must not migrate into `DAWCore` (which
    /// stays headless and ships the product domain model). If a second file
    /// in this target needs it, make a module-local
    /// `Tests/DAWEngineTests/Support/TimingSeconds.swift` — not a new target.
    private static func secondsOf(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
    }

    private func bankTrack(program: Int, bankMSB: Int = 121) -> Track {
        Track(name: "PrepareStress", kind: .instrument,
              instrument: InstrumentDescriptor(
                  kind: .soundBank,
                  soundBank: SoundBankConfig(source: .generalMIDI, program: program,
                                             bankMSB: bankMSB)))
    }

    /// One full prepare (instantiate → allocate-on-gate → bank load → wrap),
    /// wall-timed under whatever contention the sibling tasks generate.
    private func timedPrepare(_ registry: AUHostRegistry, _ track: Track) async -> Duration {
        await ContinuousClock().measure {
            await registry.prepare(track: track, sampleRate: 48_000)
        }
    }

    /// Disposes the victim's live sampler while prepares and renegotiations
    /// are in flight — the teardown lands on `dlsBankQueue` mid-churn.
    private func disposeAfterDelay(_ registry: AUHostRegistry, _ trackID: UUID) async {
        try? await Task.sleep(for: .milliseconds(5))
        registry.releaseInstrument(forTrack: trackID)
    }

    /// Churn: load → immediately dispose, repeatedly, overlapping whatever
    /// the other concurrent tasks are doing at that moment (m18-d shape,
    /// plus per-prepare timing and a ready tally).
    private func churnLoadDispose(iteration: Int) async -> (durations: [Duration], ready: Int) {
        var durations: [Duration] = []
        var ready = 0
        for churn in 0..<3 {
            let registry = AUHostRegistry()
            let track = bankTrack(program: (iteration + churn * 13) % 128,
                                  bankMSB: churn == 2 ? 120 : 121)
            durations.append(await timedPrepare(registry, track))
            if registry.status[track.id] == .ready { ready += 1 }
            registry.releaseInstrument(forTrack: track.id)
        }
        return (durations, ready)
    }

    /// R7-style renegotiation churn on a live DLS instrument: each rate flip
    /// runs dealloc → setFormat → alloc → bank re-load with the dealloc/alloc
    /// sync-hopped onto `dlsBankQueue` (`withBankGateIfDLS`), exactly the
    /// m19-j gate, while sibling prepares queue allocates on the same gate.
    /// `Task.yield()` between flips lets those prepares interleave.
    private func renegotiationChurn(_ instrument: HostedAUInstrument,
                                    roundTrips: Int) async -> Int {
        var attempts = 0
        for _ in 0..<roundTrips {
            for rate in [44_100.0, 48_000.0] {
                instrument.prepare(sampleRate: rate, maxFramesPerQuantum: 4_096,
                                   channelCount: 2)
                attempts += 1
                await Task.yield()
            }
        }
        return attempts
    }

    @Test("concurrent prepares race renegotiations and teardowns without faulting, latency bounded")
    func preparesRaceRenegotiationsAndTeardowns() async throws {
        // Shape calibrated 2026-07-16 against the PARALLEL full suite, whose
        // critical path is the 42.9 s stretch-wire suite: heavier shapes
        // (12×3, 10×2) ran fine alone (0.3–4.4 s) but their main-actor
        // dlsBankQueue.sync flips and ~500+ sequential main-actor turns
        // stretched the full run to ~72 s and flaked fixed-window live
        // tests (stretch cancellation; one engine-rebuild playhead window
        // at 6×2). 4×2 still packs ~an order of magnitude more deliberately
        // overlapped race windows than the ORGANIC load that fired the
        // pre-fix race 3×/run (a handful of suite prepares, no churn at
        // all), at modest full-suite cost. Do NOT grow this shape without
        // re-checking the full suite's marginal live tests under load.
        let iterations = 4
        let renegotiationRoundTrips = 2
        // 1 renegotiator + 1 victim + 3 concurrent holders + 3 churn cycles.
        let preparesPerIteration = 8

        var prepareDurations: [Duration] = []
        var churnReady = 0
        var victimTeardowns = 0
        var renegotiationAttempts = 0
        let reloads = Tally()

        for iteration in 0..<iterations {
            // Renegotiator: a bank-loaded sampler whose R7 churn below flips
            // 48 kHz ↔ 44.1 kHz while everything else runs. Victim: a live
            // sampler disposed mid-flight (queue teardown). Their setup
            // prepares run CONCURRENTLY — two overlapping bank loads, and
            // one sequential main-actor barrier instead of two.
            let renegotiatorRegistry = AUHostRegistry()
            let renegotiatorTrack = bankTrack(program: (iteration * 5 + 1) % 128)
            let victim = AUHostRegistry()
            let victimTrack = bankTrack(program: iteration % 128)
            async let renegotiatorSetup = timedPrepare(renegotiatorRegistry, renegotiatorTrack)
            async let victimSetup = timedPrepare(victim, victimTrack)
            let (renegotiatorDuration, victimDuration) = await (renegotiatorSetup, victimSetup)
            prepareDurations += [renegotiatorDuration, victimDuration]
            #expect(victim.status[victimTrack.id] == .ready)
            if victim.preparedInstrument(forTrack: victimTrack.id) != nil {
                victimTeardowns += 1
            }
            let instrument = try #require(
                renegotiatorRegistry.preparedInstrument(forTrack: renegotiatorTrack.id))
            // Structural sensitivity: the churned instrument IS DLS-family,
            // so its renegotiation and teardown take the gated paths — a
            // degenerate fixture (non-DLS component) cannot pass silently.
            #expect(instrument.serializedBankTeardown)
            // Count completed renegotiations: the registry's R7 reload hook
            // fires only AFTER the gated alloc succeeds, so this tally is
            // proof each flip ran the whole dealloc/alloc/reload sequence.
            let originalReload = instrument.reloadAfterRenegotiation
            instrument.reloadAfterRenegotiation = { [reloads] au in
                reloads.value += 1
                originalReload?(au)
            }

            // Three concurrent prepares: each suspends the main actor at its
            // awaited dlsBankQueue allocate + off-actor bank load, racing the
            // renegotiator's sync gate hops and the victim's dispose.
            let holders = (0..<3).map { _ in AUHostRegistry() }
            let tracks = (0..<3).map { bankTrack(program: (iteration * 7 + $0 * 11) % 128) }
            async let prepare0 = timedPrepare(holders[0], tracks[0])
            async let prepare1 = timedPrepare(holders[1], tracks[1])
            async let prepare2 = timedPrepare(holders[2], tracks[2])
            async let dispose: Void = disposeAfterDelay(victim, victimTrack.id)
            async let churn = churnLoadDispose(iteration: iteration)
            async let renegotiations = renegotiationChurn(
                instrument, roundTrips: renegotiationRoundTrips)
            let (duration0, duration1, duration2, _, churnResult, attempts) =
                await (prepare0, prepare1, prepare2, dispose, churn, renegotiations)
            prepareDurations += [duration0, duration1, duration2]
            prepareDurations += churnResult.durations
            churnReady += churnResult.ready
            renegotiationAttempts += attempts

            // Serialized or not, every surviving load must actually be ready —
            // the gates must not drop or deadlock prepares, only order them.
            for (registry, track) in zip(holders, tracks) {
                #expect(registry.status[track.id] == .ready)
            }
            // `renegotiatorRegistry` and `holders` die here with LIVE
            // instruments: four deinit hand-off disposals land on
            // `dlsBankQueue` right as the next iteration starts queueing
            // allocates and bank loads behind them.
        }

        // Anti-vacuity: the churn provably drove every gated path, nonzero
        // and in the exact expected quantities.
        #expect(prepareDurations.count == iterations * preparesPerIteration)
        #expect(victimTeardowns == iterations)
        #expect(churnReady > 0)
        #expect(renegotiationAttempts == iterations * renegotiationRoundTrips * 2)
        // Every attempted renegotiation completed its gated dealloc/alloc and
        // re-load — a failed flip would skip the hook and break equality.
        #expect(reloads.value == renegotiationAttempts)

        // Prepare-under-contention latency distribution + bound.
        //
        // THE APPLICABLE HORIZON IS `AUHostRegistry.defaultPrepareTimeout`,
        // AND IT IS NEVER A LITERAL IN THIS FILE. `timedPrepare` passes no
        // `timeout:`, so every prepare takes the registry default, which is
        // `AUHostRegistry.testPrepareTimeout` (60 s) in any process
        // `DAWCore.TestEnvironment` recognises as a Swift test — and
        // `./scripts/test.sh` runs `swift test --disable-xctest`, whose
        // harness binary is `swiftpm-testing-helper`. Only a production
        // process gets `productionPrepareTimeout` (10 s). This block asserted
        // "10 s" in three places until m23-as-2 and had been factually wrong
        // in all three since m23-at split the two values; nobody noticed
        // because learning the real horizon meant chasing
        // `TestEnvironment.isRunningTests` across two modules. The print below
        // now emits the horizon, so this class of staleness self-corrects.
        let seconds = prepareDurations.map(Self.secondsOf).sorted()
        let minSeconds = seconds.first ?? 0
        let median = seconds[seconds.count / 2]
        let p90 = seconds[Int(Double(seconds.count) * 0.9)]
        let maxSeconds = seconds.last ?? 0
        let underCleanPathBudget = seconds.filter { $0 < Self.cleanPathBudgetSeconds }.count
        // ADDITIVE ONLY. `n=`, `min`, `median`, `p90`, `max` keep their exact
        // order and spelling: m23-ab-3, m23-at, m23-aw and
        // `docs/research/design-m23as2-prepare-estimator.md` all read past
        // measurements off this line, and a reformat silently breaks
        // continuity with every number already recorded in ROADMAP.md.
        // ⚠️ Since m23-aw this line also has a MACHINE reader alongside the
        // human ones: `scripts/gates/m23aw-prepare-headroom.mjs` parses the
        // sibling `[measured] GM bank prepare-to-ready wall time` /
        // `horizon` / `margin` line in `SoundBankHostingTests.swift`, not
        // this one — but both lines share the same additive-only discipline,
        // and a future reformat here should assume a script, not just a
        // person, is one of the things it can silently blind.
        print("[measured] m19-e contended prepares: n=\(seconds.count), "
              + "min \(minSeconds) s, median \(median) s, p90 \(p90) s, "
              + "max \(maxSeconds) s, under1s \(underCleanPathBudget), "
              + "horizon \(AUHostRegistry.defaultPrepareTimeout)")

        // ── LATENCY CONTRACT ─────────────────────────────────────────────
        // Re-derived 2026-08-03 (m23-as-2). Full analysis, including every
        // rejected alternative instrument:
        // `docs/research/design-m23as2-prepare-estimator.md`.
        //
        // MEASURED — `[measured] m19-e contended prepares` lines, n=32 each,
        // this machine, this tree, all 2026-08-03. A/B/C: the m23-as-1 audit.
        // D/E: the m23-as-2 design. F: the m23-as-2 pre-edit baseline. G–M:
        // the m23-as-2 post-edit campaign. Every run D onward was verified
        // GREEN before use — `Test run with N tests in 483 suites passed`,
        // `grep -c '✘'` = 0 (N = 4692 up to F, 4693 from G, this test being
        // the +1). `under1s` did not exist before G. (Run L's full-suite run
        // did carry one ✘, in `WhisperTranscriberFixtureTests` — a wedged
        // `/usr/bin/say` child under `waitUntilExit`, unrelated to this file
        // and to this module; THIS suite was green in that run and its row is
        // included on that basis.)
        //
        //   run                       min       median    p90      max     under1s
        //   isolated (--filter)       0.000168  0.000780  —        0.0511  32/32
        //   full suite A              0.065457  3.149543  14.143   23.206  —
        //   full suite B              0.061028  2.466742  12.293   18.452  —
        //   full suite C              0.062611  2.451709  11.041   24.886  —
        //   full suite D              0.052400  4.637244  11.059   20.574  —
        //   full suite E              0.079429  2.486943  12.049   18.879  —
        //   full suite F              0.055827  3.567406  13.173   17.111  —
        //   full suite G              0.070061  3.645403  14.370   15.455  9
        //   full suite H              0.057818  4.321532  12.566   14.897  9
        //   full suite I              0.062069  2.291965  13.847   27.326  9
        //   full suite J              0.065253  2.443291  13.427   14.520  8
        //   full suite K              0.049420  3.294276  13.001   18.105  8
        //   full suite L              0.056466  2.447989  12.043   22.101  9
        //   full suite M              0.062917  2.314688  15.111   26.447  9
        //   full suite N              0.048030  2.489122  12.251   24.346  9
        //   full suite O              0.085794  2.738358  12.450   17.271  8
        //   ADVERSARIAL (20 CPU hogs) 0.161555  2.777165  23.920   37.304  8
        //
        // ⚠️ TWO POPULATIONS, AND EVERY FIGURE BELOW SAYS WHICH IT MEANS. The
        // eleven FULL-SUITE runs A–K are the normal population. The last row
        // is one deliberately adversarial run (the full suite under 20 extra
        // CPU-bound background processes — the m23-ab-2 protocol); it took
        // 164 s against a ~95 s norm and is NOT part of the ranges quoted for
        // the full-suite population. Conflating the two is how a future
        // author "discovers" an erosion that never happened.
        //
        // Run-to-run spread across the fifteen full-suite runs (worst/best):
        //   min 1.79×,  median 2.02×,  p90 1.37×,  max 1.88×,
        //   under1s 1.13× (G–O only, and it held at 8 ADVERSARIAL too).
        // ⚠️ This table is the DERIVATION SNAPSHOT taken at the m23-as-2 close,
        // not a running log. Every bound below is derived from the WORST
        // observation in its channel, so a later run that lands inside these
        // ranges CONFIRMS the derivation and does not require re-deriving it.
        // Only a worse-than-worst observation does — see the re-derivation
        // rule in layer 2.
        // Isolated→loaded inflation, full suite: min 294–473×, median
        // 2 938–5 945× (the m23-as-2 design's five-run figures were 312–473×
        // and 3 143–5 945×; runs F–K widen the low ends and change nothing
        // that matters — the point is the ORDER OF MAGNITUDE).
        //
        //  1. PER-PREPARE — THE HARD BOUND. Each prepare races
        //     `AUHostRegistry.defaultPrepareTimeout` (above; printed on the
        //     line above too). An AU-side stall flips status to `.failed` and
        //     the `.ready` asserts at the top of the loop fail, with a far
        //     more readable message than any latency bound produces.
        //
        //  2. MIN — THE PRIMARY DETECTOR. It is the least
        //     scheduling-contaminated sample: the true gated-path cost on the
        //     luckiest turn. Across the fifteen FULL-SUITE runs it spanned
        //     0.0480–0.0858 s — **11.7× headroom** under the 1.0 s budget at
        //     the worst FULL-SUITE observation. On the ADVERSARIAL run it was
        //     0.1616 s — **6.2× headroom**. Isolated it is 0.000168 s. The
        //     bound therefore means the same thing in all three environments,
        //     which is precisely the property the deleted median bound lacked.
        //     Its run-to-run spread across the full-suite runs is 1.79×,
        //     tighter than the median's 2.02×. ⚠️ p90 (1.37×) is steadier
        //     still and max is comparable (1.88×); that is NOT an argument for
        //     asserting either of them — see 4.
        //
        //     It is also the more SENSITIVE instrument, exactly: for a
        //     regression adding `d` to every prepare,
        //     `min(W+Q+d) = d + min(W+Q)`, so `d` passes through this channel
        //     with coefficient 1 (MEASURED — the discriminator below adds a
        //     deterministic 1.5 s and sees minAmp 1.488–1.570 s). This bound
        //     trips at `d > 1.0 − 0.0858 = 0.914 s` under the worst full-suite
        //     load, `d > 0.838 s` adversarial, and `d > 0.99983 s` isolated —
        //     a 19 % span across every measured condition. The deleted
        //     `median < 8.0` tripped at `d > 3.363 s` (worst load) to
        //     `d > 5.708 s` (best load), a 70 % span: 3.7–6.2× less sensitive
        //     AND load-dependent, so its last green run told you little about
        //     its next.
        //
        //     RE-DERIVATION RULE, for when this bound erodes — follow it
        //     instead of inventing a fresh constant:
        //       Re-measure the loaded min across >= 5 green FULL-SUITE runs
        //       (the normal population — NOT the adversarial one). The bound
        //       must retain >= 5x headroom over the worst observation. If it
        //       cannot, the prepare path has changed by more than an order of
        //       magnitude and the correct response is an investigation, not a
        //       new constant.
        //     Today that rule has a solution with room to spare
        //     (5 × 0.0858 = 0.43 s, well under 1.0). Even measured against the
        //     ADVERSARIAL worst — which the rule does not require — 6.2× still
        //     clears the 5× floor, so the bound survives its own rule under a
        //     load it was never promised to survive. Unlike the rule it
        //     replaces, it degrades legibly rather than silently.
        //
        //     `instantiateRegressionTripsCleanPathBudget` below is this
        //     bound's mutation discriminator: a bound nobody has seen fire is
        //     a bound nobody has calibrated.
        //
        //  3. UNDER-1s COUNT — the second asserted channel, and a strict
        //     STRENGTHENING of 2. `min < 1.0` is exactly `under1s >= 1`, so
        //     `under1s >= 4` implies it. Measured `under1s` (of 32): 9, 9, 9,
        //     8, 8, 9, 9, 9, 8 on the nine full-suite runs G–O, and 8
        //     ADVERSARIAL — a
        //     1.13× spread that survived a 3× whole-suite slowdown intact,
        //     the steadiest channel measured anywhere in this file. Worst
        //     observation C = 8; the bound is `m = floor(C / 2) = 4`, the same
        //     2× margin discipline `AUHostRegistry.testPrepareTimeout` was
        //     derived under.
        //
        //     ⚠️ It does NOT need its own discriminator, and the reason is
        //     PROOF rather than measurement: `under1s >= 4` ⇒ `under1s >= 1`
        //     ⇔ `min < 1.0`, so any regression that trips the min bound has
        //     already tripped this one. What it adds over min is partial cover
        //     for a stall that spares the luckiest prepare but evicts the rest
        //     of the fast bucket — the one regression class the deleted median
        //     bound uniquely saw.
        //
        //     ⚠️ DO NOT describe this as "load-tolerant by construction
        //     because it is an order statistic". That claim is FALSE. Order
        //     statistics resist OUTLIERS; the contaminant here is a
        //     DISTRIBUTION SHIFT (min moves 294–473×, median 2 938–5 945×),
        //     and a count against a fixed boundary is sensitive exactly where
        //     load moves mass across that boundary. This relocates the load
        //     sensitivity into a channel that is bounded in [0, 32] and
        //     monotone, and the 1.13× spread above is why that relocation was
        //     worth making. It does not remove the sensitivity.
        //
        //  4. MEDIAN, P90 and MAX — RECORDED, NEVER ASSERTED. ⚠️ DO NOT ADD A
        //     BOUND TO ANY OF THEM. The table above is the evidence: across
        //     green runs where every `.ready` assert passed, p90 ran
        //     11.04–15.11 s and max 14.52–27.33 s full-suite, and 23.92 /
        //     37.30 s adversarial. Wall time here is ~99.98 % main-actor /
        //     `dlsBankQueue` QUEUING and ~0.02 % work (isolated median
        //     0.00078 s against a loaded 2.29–4.64 s), so a bound on those
        //     channels measures the harness's ambient load, not this gate.
        //
        //     `#expect(median < 8.0)` LIVED HERE AND WAS DELETED at
        //     m23-as-2. Its stated derivation was "≈ 4× the worst measured
        //     median, still under the timeout horizon". Both clauses died:
        //       • the horizon clause named 10 s and has been VOID since
        //         m23-at — see the paragraph above the print;
        //       • the "4×" clause STOPPED HAVING A SOLUTION. Worst measured
        //         median is 4.637 s, so the rule demands 18.55 s. But
        //         `max/median` across those runs is 4.44–10.15, so the median
        //         at which the worst prepare in a run reaches the 60 s
        //         horizon and flips `.failed` is 60/10.15 = 5.9 s to
        //         60/4.44 = 13.5 s. The rule's own output (18.55 s) sits
        //         ABOVE the median at which prepares begin FAILING (13.5 s).
        //         No number is simultaneously "4× the worst median" and
        //         "below the failure horizon".
        //     The retained 8.0 was worse than merely unsatisfiable: it sat
        //     INSIDE that 5.9–13.5 s failure-onset band, so it reddened at or
        //     AFTER the `.ready` asserts it was a lossy proxy for — while
        //     carrying 1.73× headroom against a channel whose run-to-run
        //     spread is 2.02× (4.637 × 2.02 = 9.38 s: the bound sat INSIDE its
        //     own measured noise envelope, one ordinary bad run from a flake
        //     with no regression present). Its only unique coverage was "more
        //     than half the prepares got ≥ 3.36 s slower", a ~4 300×
        //     regression on a majority of samples; no mechanism in
        //     `performPrepare` produces that while sparing the fastest 40 %,
        //     min catches the all-samples version at 0.92 s (four times
        //     sooner), and layer 3 now covers part of the partial-stall case
        //     it was reaching for.
        //
        //     ⚠️ THIS DELETION IS NOT PRECEDENT FOR DELETING TIMING BOUNDS.
        //     It is licensed by ONE measurement: the isolated→loaded
        //     inflation factor here is 294–5 945×, i.e. QUEUEING, which is
        //     ADDITIVE — not CPU contention, which is multiplicative and
        //     lands at ~2–10×. A ratio cancels MULTIPLICATIVE noise, not
        //     additive; a subtraction cancels ADDITIVE noise, not
        //     multiplicative. Measure the inflation factor first; it, not
        //     taste, picks the instrument.
        //
        //     ⚠️ ONE OPEN FLAG, NOT A PROPOSAL: max reached 27.33 s
        //     full-suite (46 % of the 60 s horizon) and 37.30 s adversarial
        //     (62 %). That is the number that will actually break this suite
        //     as the harness grows, and it is evidence for the open item
        //     m23-aw. It is NOT a reason to raise
        //     `AUHostRegistry.testPrepareTimeout` — m23-at's roadmap line
        //     forbids it, and 60 s was itself derived as ~2.2× a measured
        //     26.9 s worst case.
        //
        //     ADDENDUM (m23-aw, comment-only — this suite's `[measured]`
        //     print and both shipped `#expect`s above are untouched): m23-aw
        //     measured a DIFFERENT channel, `SoundBankHostingTests`' GM
        //     bank prepare-to-ready wall time (T1, `soundbank_host.instrument`
        //     against a real AVAudioUnitSampler, not this file's synthetic
        //     `dlsBankQueue` renegotiation load), at 30.994 s / 51.7 % of the
        //     60 s horizon normal-population worst-of-6, and 49.311 s / 82.2 %
        //     adversarial — both HIGHER than this file's max column above,
        //     confirming the open flag was not this suite's alone. The m19-e
        //     `max` column recorded here did NOT move over that interval (no
        //     edit here changes what it measures). The resolution is
        //     `scripts/gates/m23aw-prepare-headroom.mjs`, which asserts a
        //     campaign worst-of-N T1 bound this file's own point 4 above
        //     explicitly declines to place on ITS OWN median/p90/max —
        //     because T1 is a single-sample per-run channel (not an
        //     order-statistic-over-32 one) the load-sensitivity argument in
        //     point 4 does not transfer to it unmodified.
        #expect(minSeconds < Self.cleanPathBudgetSeconds)
        #expect(underCleanPathBudget >= Self.minimumUnderBudgetPrepares)
    }

    // MARK: - m23-as-2: the min bound's mutation discriminator

    /// The synthetic regression: +1.5 s added INSIDE the real instantiate.
    ///
    /// Sizing: it must exceed `budget − worst loaded min` = `1.0 − 0.0858 =
    /// 0.914 s`. At 1.5 s the perturbed leg's min has a DETERMINISTIC FLOOR of
    /// 1.5 s — 1.64× margin that cannot erode under load, because a
    /// `Task.sleep(for:)` of fixed wall duration can only be made longer by
    /// contention, never shorter. (Contrast the EQ precedent at
    /// `EQCurveEditorModelTests.recomputeRegressionTripsCalibratedBudget`,
    /// where load moved the ratio in both directions and 4× had to be
    /// escalated to 8×.)
    ///
    /// ⚠️ UPPER CONSTRAINT, and the reason this is a named constant: 1.5 s
    /// must stay FAR INSIDE `AUHostRegistry.defaultPrepareTimeout` (60 s in a
    /// test process, and only 10 s in production) so the perturbed prepare
    /// still reaches `.ready`. Raise this and the test silently stops
    /// measuring latency and starts exercising the timeout path instead —
    /// where `#expect(status == .ready)` would redden and the latency
    /// assertion would pass for the wrong reason.
    private static let discriminatorInstantiateDelay = Duration.milliseconds(1_500)

    /// Control-leg sample count. A min-of-8 is a weaker estimator than the
    /// shipped test's min-of-32, so it carries its own calibration gate: the
    /// control min must stay <= 0.25 s (4× margin under the budget).
    ///
    /// MEASURED 2026-08-03: control min ran 0.0124 / 0.0180 / 0.0385 / 0.0418
    /// / 0.0176 / 0.0431 / 0.0129 / 0.0135 / 0.0163 s across nine green
    /// full-suite runs and 0.0220 s ADVERSARIAL (20 CPU-bound background
    /// processes) — worst 0.0431 s, i.e. 5.8× under the 0.25 s gate and 23.2×
    /// under budget.
    /// These prepares are cheap because they hit the warm process-global DLS
    /// bank cache: the whole test costs 2.00–2.15 s under full-suite load,
    /// 2.40 s adversarial.
    ///
    /// ⚠️ If `control.min()` ever approaches the budget, RAISE THIS (16) — do
    /// NOT loosen `cleanPathBudgetSeconds`, which is shared with the shipped
    /// assertion and would silently weaken it.
    private static let discriminatorControlPrepares = 8

    /// One unperturbed prepare on a fresh registry, released immediately.
    private func controlPrepareSeconds(program: Int) async -> Double {
        let registry = AUHostRegistry()
        let track = bankTrack(program: program)
        let seconds = Self.secondsOf(await timedPrepare(registry, track))
        #expect(registry.status[track.id] == .ready)
        registry.releaseInstrument(forTrack: track.id)
        return seconds
    }

    /// One prepare whose REAL instantiate is wrapped with a fixed extra delay.
    ///
    /// The seam is `AUHostRegistry.instantiator` — a per-registry
    /// `@MainActor var`, so the blast radius of the perturbation is EXACTLY
    /// ONE PREPARE. The tempting alternative, occupying
    /// `AUHostRegistry.dlsBankQueue` (the class this code is structurally most
    /// exposed to), is REJECTED: that queue is `static` and process-global, so
    /// seconds of deliberate occupancy would delay every sibling suite's
    /// sound-bank prepare in the same test process and push them toward their
    /// own 60 s timeout. A discriminator that can flake other suites is worse
    /// than the bound it validates.
    ///
    /// Two further properties make it the better model: the `await
    /// Task.sleep` RELEASES the main actor, so it is a clean additive delay
    /// rather than actor hogging and does not perturb the ambient queue wait
    /// the control leg is measured against; and it models a real regression
    /// class (a component's instantiate got slower, or negotiation gained a
    /// round trip) rather than an arbitrary sleep in the test body.
    private func regressedPrepareSeconds(program: Int) async -> Double {
        let registry = AUHostRegistry()
        let real = registry.instantiator
        registry.instantiator = { description, options in
            let unit = try await real(description, options)
            try? await Task.sleep(for: Self.discriminatorInstantiateDelay)
            return unit
        }
        let track = bankTrack(program: program)
        let seconds = Self.secondsOf(await timedPrepare(registry, track))
        // A perturbation that FAILED the prepare would satisfy the latency
        // assertion for entirely the wrong reason.
        #expect(registry.status[track.id] == .ready)
        registry.releaseInstrument(forTrack: track.id)
        return seconds
    }

    /// Proves `minSeconds < cleanPathBudgetSeconds` has teeth, WITHOUT
    /// reddening the shipped test — the convention
    /// `EQCurveEditorModelTests.recomputeRegressionTripsCalibratedBudget` and
    /// `InsertSpectrumTapTests.fidelityDiscriminatorSeesADroppedBlock` share:
    /// perturb the real thing, then assert the SAME assertion shape now goes
    /// the other way.
    @Test("m23-as-2 discriminator: a +1.5 s instantiate regression trips the clean-path budget")
    func instantiateRegressionTripsCleanPathBudget() async {
        // CONTROL: sequential on purpose. Concurrent control prepares would
        // self-contend on `dlsBankQueue` and inflate the very min this leg
        // exists to establish as low.
        var control: [Double] = []
        for index in 0..<Self.discriminatorControlPrepares {
            control.append(await controlPrepareSeconds(program: (index * 9 + 3) % 128))
        }

        // REGRESSED: concurrent, purely as a cost decision — the 1.5 s sleeps
        // overlap, so wall cost is ~1.5–2 s rather than ~6 s, and since the
        // sleep does not hold the bank gate the concurrency adds no gate
        // pressure.
        async let regressed0 = regressedPrepareSeconds(program: 11)
        async let regressed1 = regressedPrepareSeconds(program: 29)
        async let regressed2 = regressedPrepareSeconds(program: 53)
        async let regressed3 = regressedPrepareSeconds(program: 71)
        let regressed = await [regressed0, regressed1, regressed2, regressed3].sorted()

        let sortedControl = control.sorted()
        let controlMin = sortedControl.first ?? 0
        let controlMedian = sortedControl[sortedControl.count / 2]
        let regressedMin = regressed.first ?? 0
        let regressedMedian = regressed[regressed.count / 2]
        // `minAmp`/`medianAmp` measure how a KNOWN additive 1.5 s propagates
        // through each channel. Both should land near 1.5, and MEASURED
        // 2026-08-03 across nine full-suite runs plus one adversarial they
        // do: minAmp 1.488–1.570 s, medianAmp 1.460–1.533 s — coefficient ≈ 1
        // in both, medianAmp never above minAmp. That is the empirical
        // confirmation of the additive pass-through the min bound's
        // sensitivity arithmetic assumes.
        //
        // ⚠️ SCOPE — it does NOT measure the queue-depth amplification `α`
        // that design §4.2 marks REASONED. This perturbation sleeps OUTSIDE
        // `dlsBankQueue` (deliberately — see `regressedPrepareSeconds`), so it
        // cannot lengthen a gate critical section, which is what `α` scales.
        // §4.2 stays REASONED; nothing here closes it.
        print("[measured] m23-as-2 discriminator: control n=\(control.count) "
              + "min \(controlMin) s, median \(controlMedian) s; "
              + "regressed n=\(regressed.count) min \(regressedMin) s, "
              + "median \(regressedMedian) s; minAmp \(regressedMin - controlMin) s, "
              + "medianAmp \(regressedMedian - controlMedian) s, "
              + "perturbation \(Self.discriminatorInstantiateDelay), "
              + "budget \(Self.cleanPathBudgetSeconds) s")

        // ANTI-VACUITY, and the entire reason this test is trustworthy: if
        // ambient load ALONE had breached the budget, this reddens too and the
        // discriminator cannot claim a false success. Do not drop it as
        // "redundant with the shipped assertion" — the shipped assertion runs
        // over a different sample in a different window.
        #expect(controlMin < Self.cleanPathBudgetSeconds)
        // THE DISCRIMINATION: the same assertion shape the shipped leg is held
        // to, now going the other way.
        #expect(regressedMin >= Self.cleanPathBudgetSeconds)
        // THE LOAD-CANCELLING CROSS-CHECK, and the only genuinely
        // load-invariant statement in this file. The perturbation is
        // deterministic and additive, so `regressedMin ≈ controlMin + 1.5`;
        // both legs draw their queue wait from the same distribution in the
        // same window, so the difference is common-mode in the contaminant.
        // Lower bound ONLY — an upper bound would make a slow control leg
        // fragile for no gain.
        //
        // ⚠️ NOTE WHICH LEG BREAKS FIRST. Since
        // `regressedMin ≈ controlMin + 1.5`, this assertion reddens once
        // `controlMin ≳ 0.6 s`, i.e. 40 % EARLIER than the anti-vacuity leg
        // above (which needs 1.0 s). If this one goes red, the diagnosis is a
        // NOISY CONTROL LEG, not a broken discrimination — and the fix is
        // raising `discriminatorControlPrepares`, never loosening 0.9 or the
        // shared budget.
        #expect(regressedMin - controlMin > 0.9)
    }
}
