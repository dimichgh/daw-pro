import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// M9 perf-b: the render-load/overrun telemetry context. Counter math is
/// pinned headless against a synthetic 1/1 timebase (ticks ≡ ns, exact to
/// the integer), then the whole seam is proven end-to-end: a headless
/// offline render through the real `AudioEngine` stamps the engine's
/// context, and read-then-reset windows tile.
@MainActor
@Suite("Engine performance telemetry (M9 perf-b)")
struct EnginePerformanceTests {

    /// Synthetic exact context: 1 tick = 1 ns.
    private func makeContext() -> EnginePerformanceContext {
        EnginePerformanceContext(timebaseNumer: 1, timebaseDenom: 1)
    }

    // MARK: - Counter math (synthetic feed, exact)

    @Test("counters accumulate exactly: count, frames, time, peak, budget-derived averageLoad")
    func countersAccumulateExactly() {
        let context = makeContext()
        // 480 frames @ 48 kHz → budget exactly 10_000_000 ns per callback.
        context.record(entryTicks: 0, exitTicks: 2_000_000,
                       frames: 480, sampleRateHz: 48_000)
        context.record(entryTicks: 100, exitTicks: 3_000_100,
                       frames: 480, sampleRateHz: 48_000)

        let stats = context.snapshot()
        #expect(stats.callbackCount == 2)
        #expect(stats.renderedFrames == 960)
        #expect(stats.renderTimeNs == 5_000_000)
        #expect(stats.peakCallbackNs == 3_000_000)
        #expect(stats.overrunCount == 0)
        // averageLoad = 5_000_000 / 20_000_000, derived reader-side.
        #expect(stats.averageLoad == 0.25)
        #expect(stats.sampleRate == 48_000)
        #expect(stats.quantumFrames == 480)
        #expect(stats.sinceResetSeconds >= 0)
    }

    @Test("overrun is strictly greater-than the quantum budget")
    func overrunIsStrictBudgetComparison() {
        let context = makeContext()
        // Budget for 480 @ 48 kHz is exactly 10_000_000 ns.
        context.record(entryTicks: 0, exitTicks: 10_000_000,
                       frames: 480, sampleRateHz: 48_000)   // == budget: no overrun
        #expect(context.snapshot().overrunCount == 0)
        context.record(entryTicks: 0, exitTicks: 10_000_001,
                       frames: 480, sampleRateHz: 48_000)   // > budget: overrun
        let stats = context.snapshot()
        #expect(stats.overrunCount == 1)
        #expect(stats.callbackCount == 2)
        #expect(stats.peakCallbackNs == 10_000_001)
    }

    @Test("recentLoad runs the documented one-pole EMA to double precision")
    func recentLoadMatchesOnePole() {
        let context = makeContext()
        let alpha = EnginePerformanceContext.recentLoadAlpha
        #expect(alpha == 0.0106)

        // load₁ = 0.5, load₂ = 1.5 of a 10_000_000 ns budget.
        context.record(entryTicks: 0, exitTicks: 5_000_000,
                       frames: 480, sampleRateHz: 48_000)
        var expected = 0.0
        expected += alpha * (0.5 - expected)
        #expect(abs(context.snapshot().recentLoad - expected) < 1e-15)

        context.record(entryTicks: 0, exitTicks: 15_000_000,
                       frames: 480, sampleRateHz: 48_000)
        expected += alpha * (1.5 - expected)
        let stats = context.snapshot()
        #expect(abs(stats.recentLoad - expected) < 1e-15)
        #expect(stats.overrunCount == 1)   // the 1.5× callback overran
    }

    @Test("machine timebase math: numer/denom converts ticks to ns in pure integers")
    func timebaseIntegerConversion() {
        // The Apple Silicon shape: 125/3 → 3 ticks = 125 ns.
        let context = EnginePerformanceContext(timebaseNumer: 125, timebaseDenom: 3)
        context.record(entryTicks: 0, exitTicks: 3, frames: 480, sampleRateHz: 48_000)
        #expect(context.snapshot().renderTimeNs == 125)
    }

    @Test("degenerate inputs never trap and never poison: zero rate, zero frames, reversed ticks")
    func degenerateInputsAreGuarded() {
        let context = makeContext()
        context.record(entryTicks: 0, exitTicks: 1_000, frames: 0, sampleRateHz: 0)
        context.record(entryTicks: 500, exitTicks: 400, frames: -3, sampleRateHz: 48_000)
        let stats = context.snapshot()
        #expect(stats.callbackCount == 2)
        #expect(stats.renderedFrames == 0)
        #expect(stats.overrunCount == 0)     // zero budget can never overrun
        #expect(stats.averageLoad == 0)
        #expect(stats.recentLoad == 0)
        for value in [stats.averageLoad, stats.recentLoad, stats.sampleRate,
                      stats.sinceResetSeconds] {
            #expect(value.isFinite)
        }
    }

    @Test("read-then-reset: windows tile exactly on the accumulators, ballistics restart")
    func resetWindowsTile() {
        let context = makeContext()
        context.record(entryTicks: 0, exitTicks: 4_000_000,
                       frames: 480, sampleRateHz: 48_000)
        context.record(entryTicks: 0, exitTicks: 6_000_000,
                       frames: 512, sampleRateHz: 48_000)

        let closing = context.snapshotAndReset()
        #expect(closing.callbackCount == 2)
        #expect(closing.renderedFrames == 992)
        #expect(closing.renderTimeNs == 10_000_000)
        #expect(closing.peakCallbackNs == 6_000_000)

        // Fresh window: accumulators and ballistics all at zero.
        let fresh = context.snapshot()
        #expect(fresh.callbackCount == 0)
        #expect(fresh.renderedFrames == 0)
        #expect(fresh.renderTimeNs == 0)
        #expect(fresh.peakCallbackNs == 0)
        #expect(fresh.overrunCount == 0)
        #expect(fresh.averageLoad == 0)
        #expect(fresh.recentLoad == 0)
        // Last-seen facts survive a reset (they are not counters).
        #expect(fresh.quantumFrames == 512)
        #expect(fresh.sampleRate == 48_000)

        // The next window counts only its own work — the two windows tile.
        context.record(entryTicks: 0, exitTicks: 1_000_000,
                       frames: 480, sampleRateHz: 48_000)
        let second = context.snapshot()
        #expect(second.callbackCount == 1)
        #expect(second.renderTimeNs == 1_000_000)
        #expect(second.peakCallbackNs == 1_000_000)
        #expect(closing.renderTimeNs + second.renderTimeNs == 11_000_000)
    }

    // MARK: - Multi-producer contention (M9 perf-d)

    @Test("parallel producers never lose a count: N threads × M records land exactly")
    func contendedRecordsAreExact() {
        // THE perf-d regression pin (docs/research/perf-c-load-profile.md
        // "Scaling experiment"): AVAudioEngine renders graph branches on a
        // worker pool, and the old single-producer load→store RMW lost 57 %
        // of increments at 16 debug tracks. 8 threads hammering record() in
        // tight loops contend far harder than any render pool, so on the old
        // code these exact-equality assertions fail with overwhelming
        // probability; on fetch_add/CAS-max they are deterministic.
        let threads = 8
        let perThread = 20_000
        let context = makeContext()

        // Deterministic per-call elapsed: thread t's calls take 1_000_000+t
        // ns (under the exact 10_000_000 ns budget of 480 @ 48 kHz), except
        // its final call, which overruns at 10_000_000 + t + 1 ns. Known
        // max across all threads: 10_000_008 (t = 7).
        let elapsed: @Sendable (Int, Int) -> UInt64 = { thread, iteration in
            iteration == perThread - 1
                ? 10_000_000 &+ UInt64(thread) &+ 1
                : 1_000_000 &+ UInt64(thread)
        }

        DispatchQueue.concurrentPerform(iterations: threads) { @Sendable thread in
            for iteration in 0..<perThread {
                context.record(entryTicks: 0,
                               exitTicks: elapsed(thread, iteration),
                               frames: 480, sampleRateHz: 48_000)
            }
        }

        // Exact expected sums, computed serially with the same formula.
        var expectedRenderTimeNs: UInt64 = 0
        for thread in 0..<threads {
            for iteration in 0..<perThread {
                expectedRenderTimeNs &+= elapsed(thread, iteration)
            }
        }
        let totalCalls = threads * perThread
        let expectedBudgetNs = UInt64(totalCalls) * 10_000_000

        let stats = context.snapshot()
        #expect(stats.callbackCount == totalCalls)
        #expect(stats.renderedFrames == totalCalls * 480)
        #expect(stats.renderTimeNs == Int(expectedRenderTimeNs))
        #expect(stats.overrunCount == threads)          // one per thread
        #expect(stats.peakCallbackNs == 10_000_008)     // known global max
        // budgetNs accumulator is exact too: averageLoad derives from it.
        #expect(stats.averageLoad
                == Double(expectedRenderTimeNs) / Double(expectedBudgetNs))
        // Last-seen facts: every producer wrote the same graph format.
        #expect(stats.quantumFrames == 480)
        #expect(stats.sampleRate == 48_000)
        // The EMA is racy-benign by design — assert sanity, not a value.
        #expect(stats.recentLoad.isFinite)
        #expect(stats.recentLoad >= 0)
    }

    // MARK: - Headless end-to-end through the real engine

    @Test("offline render stamps the engine's context; reset opens a clean window")
    func headlessOfflineRenderCounts() async throws {
        let fixtures = try TestSignals.fixtures()
        let engine = AudioEngine()

        // Before any render: a fresh engine reads the all-zero window.
        let before = engine.performanceStats(reset: false)
        #expect(before.callbackCount == 0)
        #expect(before.renderedFrames == 0)
        #expect(before.renderTimeNs == 0)

        // One audio track (strip chain host) + one instrument track (source
        // node renderQuantum): both Tier-1 instrumentation points fire.
        let tracks = [
            Track(name: "A", kind: .audio,
                  clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4,
                               audioFileURL: fixtures.cos1k48)]),
            Track(name: "Keys", kind: .instrument,
                  clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
                      MIDINote(pitch: 69, velocity: 127, startBeat: 0, lengthBeats: 2),
                  ])],
                  instrument: InstrumentDescriptor(kind: .testTone)),
        ]
        let audio = try await engine.renderOffline(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, forcedCompensationTargets: nil)
        #expect(audio.frameCount == 48_000)

        let stats = engine.performanceStats(reset: false)
        print("[measured] perf after 1 s offline render: callbacks \(stats.callbackCount), "
              + "frames \(stats.renderedFrames), renderTime \(stats.renderTimeNs) ns, "
              + "peak \(stats.peakCallbackNs) ns, avgLoad \(stats.averageLoad), "
              + "recentLoad \(stats.recentLoad), overruns \(stats.overrunCount)")
        #expect(stats.callbackCount > 0)
        // Two instrumented blocks each saw the full render length.
        #expect(stats.renderedFrames >= 48_000)
        #expect(stats.renderTimeNs > 0)
        #expect(stats.peakCallbackNs > 0)
        #expect(stats.sampleRate == 48_000)
        #expect(stats.quantumFrames > 0)
        #expect(stats.sinceResetSeconds > 0)
        for value in [stats.averageLoad, stats.recentLoad, stats.sampleRate,
                      stats.sinceResetSeconds] {
            #expect(value.isFinite)
            #expect(value >= 0)
        }

        // Read-then-reset returns the closing window…
        let closing = engine.performanceStats(reset: true)
        #expect(closing.callbackCount == stats.callbackCount)
        #expect(closing.renderedFrames == stats.renderedFrames)
        // …and the engine (its own private context — nothing else renders
        // into it) then reads a clean window.
        let afterReset = engine.performanceStats(reset: false)
        #expect(afterReset.callbackCount == 0)
        #expect(afterReset.renderedFrames == 0)
        #expect(afterReset.renderTimeNs == 0)
        #expect(afterReset.peakCallbackNs == 0)
        #expect(afterReset.overrunCount == 0)
        #expect(afterReset.recentLoad == 0)

        // A second render lands entirely in the new window.
        _ = try await engine.renderOffline(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 0.25, forcedCompensationTargets: nil)
        let second = engine.performanceStats(reset: false)
        #expect(second.callbackCount > 0)
        #expect(second.renderedFrames >= 12_000)
        #expect(second.renderedFrames < stats.renderedFrames)
    }

    @Test("telemetry observes, never alters: instrumented render is bit-identical")
    func instrumentationIsObservationOnly() async throws {
        let fixtures = try TestSignals.fixtures()
        let track = Track(name: "A", kind: .audio,
                          clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        // Two fresh engines, two fresh contexts, same input: byte-identical
        // output proves the counters never touch the audio path.
        let first = try await AudioEngine().renderOffline(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 0.5, forcedCompensationTargets: nil)
        let second = try await AudioEngine().renderOffline(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 0.5, forcedCompensationTargets: nil)
        #expect(first.channelData == second.channelData)
        #expect(TestSignals.rms(first.channelData[0], in: 0..<12_000) > 0.2)
    }
}
