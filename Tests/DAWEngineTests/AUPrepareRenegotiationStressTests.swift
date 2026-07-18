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
/// a SoundBankHostingTests AU-prepare TIMEOUT (10 s) on a cold
/// post-recompile suite that re-ran green in isolation at 0.57 s. Every
/// prepare here is timed mid-churn; per-prepare stalls fail via the 10 s
/// timeout → `.failed` → the `.ready` asserts, and the distribution's MEDIAN
/// is asserted under an evidence-based bound (see the latency contract at
/// the bottom), so a future systemic prepare slowdown fails loudly instead
/// of flaking.
@MainActor
@Suite("AU prepare vs renegotiation vs teardown gate stress (m19-e)")
struct AUPrepareRenegotiationStressTests {
    /// Main-actor-only tally box for the reload-hook wrapper (the hook runs
    /// inside the renegotiation's `MainActor.assumeIsolated` block).
    private final class Tally {
        var value = 0
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

        // Prepare-under-contention latency distribution + bound. The 10 s
        // suite prepare timeout is the flake horizon this guards against.
        let seconds = prepareDurations.map {
            Double($0.components.seconds) + Double($0.components.attoseconds) * 1e-18
        }.sorted()
        let minSeconds = seconds.first ?? 0
        let median = seconds[seconds.count / 2]
        let p90 = seconds[Int(Double(seconds.count) * 0.9)]
        let maxSeconds = seconds.last ?? 0
        print("[measured] m19-e contended prepares: n=\(seconds.count), "
              + "min \(minSeconds) s, median \(median) s, p90 \(p90) s, "
              + "max \(maxSeconds) s")
        // Three-layer latency contract (measured 2026-07-16, this machine).
        // Wall times here include main-actor QUEUING: under the 300-suite
        // parallel run a prepare measured 14 s wall with every `.ready`
        // green, so absolute max is scheduling noise and is NOT asserted.
        //  1. PER-PREPARE: each prepare races the registry's 10 s timeout —
        //     an AU-side stall flips status to .failed and the `.ready`
        //     asserts above fail. That is the individual bound.
        //  2. MIN: the least scheduling-contaminated sample — the true gated
        //     path cost on the luckiest turn. Isolated: sub-ms. A regression
        //     that adds seconds to EVERY prepare (e.g. each allocate
        //     serialized behind seconds of queue work) raises the whole
        //     distribution, min included, in any environment.
        //  3. MEDIAN: the systemic detector. Isolated runs: 0.8–2.2 ms.
        //     Full parallel suite: 0.195 s (12×3 shape), 2.02 s (10×2 —
        //     dominated by ~0.4 s main-actor turn latency, not the gate).
        //     8 s ≈ 4× the worst measured median, still under the 10 s
        //     timeout horizon this test exists to keep far away.
        #expect(minSeconds < 1.0)
        #expect(median < 8.0)
    }
}
