import CAtomics
import DAWCore
import Foundation

/// Render-load / overrun telemetry (M9 perf-b): the preallocated counter
/// context both Tier-1 workhorses stamp per render callback —
/// `InstrumentRenderer.renderQuantum` (every instrument source node) and
/// `ChainHostAU.internalRenderBlock` (every audio/bus strip's insert
/// sandwich, timed AFTER `pullInputBlock` returns so upstream work is never
/// double-counted through nested pulls). The sum of both ≈ the engine's own
/// per-quantum DSP work; AVFoundation-internal work (player file reads,
/// mixer SRC/sum) is deliberately outside the measurement.
///
/// RT-SAFETY (docs/ARCHITECTURE.md invariants — the law):
/// · All cells live in ONE heap allocation (`UnsafeMutablePointer<
///   daw_atomic_u64>`, stable addresses — the CAtomics idiom; never
///   `&property`).
/// · `record(...)` is the ONLY render-thread entry point: two
///   `mach_absolute_time()` reads happen at the call sites (commpage read,
///   not a syscall — the MIDIInputRTContext precedent), then integer math
///   plus one non-trapping Double division for the load EMA. No allocation,
///   no locks, no ObjC, no trapping division (rate and budget divisors are
///   guarded ≥ 1; the timebase factor is precomputed in init on the control
///   plane).
/// · Producers are the PARALLEL RENDER POOL plus offline renders:
///   AVAudioEngine renders independent graph branches on a worker-thread
///   pool, so `record` calls from the SAME quantum routinely overlap in
///   flight (proven live, docs/research/perf-c-load-profile.md "Scaling
///   experiment": debug at 16 dense tracks the old single-producer
///   load→store RMW lost 57 % of increments — 43 % callback-rate
///   fidelity). The five monotone accumulators therefore use
///   `daw_atomic_u64_add` (fetch_add, acq_rel — EXACT under any producer
///   count; a single LDADD on arm64) and the peak cell uses
///   `daw_atomic_u64_max` (bounded CAS loop; boundedness argument in
///   CAtomics.h). The EMA and last-seen cells stay multi-producer
///   racy-benign load/store BY DESIGN — see their comments below.
///   Stores are release, loads acquire, adds acq_rel, so cross-thread
///   readers always see whole values; nothing ever tears (C11 atomics).
///
/// RESET (windowed profiling, `engine.performanceStats {reset:true}`):
/// the five accumulators are LIFETIME-monotonic cells; reset never writes
/// them. Instead the reader captures baselines (plain vars, reader-side
/// only) from the SAME loads that produced the returned snapshot, so the
/// returned window and the new window tile exactly — every fetch_add is
/// indivisible, so a callback straddling the reset lands its whole delta
/// in exactly one window and pre-reset totals can never resurrect.
/// `peakCallbackNs` and the `recentLoad` EMA are ballistic (non-monotone)
/// values: reset stores 0 into their cells, which is benign under the race
/// analysis (a CAS-max straddling the store-0 either lands its genuine
/// elapsed — which the 0 may then clobber, one lost peak observation at
/// worst — or skips against a stale pre-reset max; a straddling EMA write
/// is a bounded, decaying distortion).
///
/// THREADING CONTRACT (`@unchecked Sendable`): `record` = ANY worker of
/// the parallel render pool (plus offline renders), concurrently;
/// `snapshot()` / `reset()` / `snapshotAndReset()` = ONE reader at a time —
/// in the engine that is the main actor (`AudioEngine.performanceStats`).
final class EnginePerformanceContext: @unchecked Sendable {

    /// One-pole coefficient for the per-callback `recentLoad` EMA:
    /// `ema += alpha * (load − ema)`. Chosen for a ~1 s time constant at
    /// 512-frame quanta at 48 kHz (93.75 callbacks/s per instrumented
    /// block): alpha = 1 − exp(−1 / 93.75) ≈ 0.0106, i.e. the EMA e-folds
    /// over ~94 callbacks. With N instrumented blocks per quantum the
    /// callback rate is N× and the effective time constant shortens to
    /// ~1/N s — documented behavior, not a bug: `recentLoad` is a "load
    /// right now" feel, not a calibrated integral (that is `averageLoad`).
    static let recentLoadAlpha = 0.0106

    /// EMA denormal flush floor (the MasterMixAnalyzer convention).
    private static let denormalFloor = 1e-12

    // Cell layout inside the single allocation.
    private enum Cell: Int, CaseIterable {
        case callbackCount = 0
        case renderedFrames = 1
        case renderTimeNs = 2
        case budgetNs = 3          // accumulated per-callback quantum budget
        case peakCallbackNs = 4
        case overrunCount = 5
        case recentLoadBits = 6    // Double.bitPattern
        case lastQuantumFrames = 7
        case lastSampleRateHz = 8
    }

    private let cells: UnsafeMutablePointer<daw_atomic_u64>

    /// mach ticks → nanoseconds as integer numer/denom (denom guarded ≥ 1 so
    /// render-side division can never trap); ticks → seconds for the
    /// reader-side `sinceReset`.
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private let ticksToSeconds: Double

    // Reader-side window state (single reader — main actor in the engine).
    // The accumulator cells are lifetime-monotonic; these baselines implement
    // reset by subtraction (see the RESET note above).
    private var baseCallbackCount: UInt64 = 0
    private var baseRenderedFrames: UInt64 = 0
    private var baseRenderTimeNs: UInt64 = 0
    private var baseBudgetNs: UInt64 = 0
    private var baseOverrunCount: UInt64 = 0
    private var resetEpochTicks: UInt64

    /// Production init: reads the machine timebase once, on the control
    /// plane, so `record` never calls `mach_timebase_info`.
    convenience init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.init(timebaseNumer: UInt64(max(1, timebase.numer)),
                  timebaseDenom: UInt64(max(1, timebase.denom)))
    }

    /// Test seam: an exact synthetic timebase (1/1 makes ticks ≡ ns) so the
    /// counter math is assertable to the integer.
    init(timebaseNumer: UInt64, timebaseDenom: UInt64) {
        self.timebaseNumer = max(1, timebaseNumer)
        self.timebaseDenom = max(1, timebaseDenom)
        ticksToSeconds = Double(self.timebaseNumer) / Double(self.timebaseDenom) / 1e9
        cells = .allocate(capacity: Cell.allCases.count)
        for index in 0..<Cell.allCases.count {
            daw_atomic_u64_store(cells + index, 0)
        }
        resetEpochTicks = mach_absolute_time()
    }

    deinit {
        // Safe by ownership: every render block that can reach `record` holds
        // (directly or through its renderer/box) a strong reference to this
        // context, so deinit implies no callback is in flight — the same
        // lifetime argument as `InstrumentRenderer.deinit`.
        cells.deallocate()
    }

    // MARK: - Render-thread surface

    /// RENDER THREAD. Stamps one completed render callback: `entryTicks` /
    /// `exitTicks` are `mach_absolute_time()` values read at the callback's
    /// entry and exit, `frames` is the quantum length it rendered,
    /// `sampleRateHz` the block's graph rate (integer Hz, callers guarantee
    /// ≥ 1; guarded here anyway). Integer math + one non-trapping Double
    /// division only — no allocation, no locks, no ObjC.
    func record(entryTicks: UInt64, exitTicks: UInt64,
                frames: Int, sampleRateHz: UInt64) {
        let frameCount = UInt64(max(0, frames))
        let rate = max(1, sampleRateHz)
        // Ticks → ns in pure integer math; the monotonic clock guarantees
        // exit ≥ entry, &- keeps a pathological pair from trapping.
        let elapsedNs = ((exitTicks &- entryTicks) &* timebaseNumer) / timebaseDenom
        // The callback's real-time budget: frames / rate seconds. Overrunning
        // it means THIS block alone ate the whole quantum — a budget-overrun
        // proxy, not a CoreAudio xrun observation (AVAudioEngine exposes no
        // xrun count); the true overload threshold is the SUM of all blocks.
        let budgetNs = (frameCount &* 1_000_000_000) / rate

        bump(.callbackCount, by: 1)
        bump(.renderedFrames, by: frameCount)
        bump(.renderTimeNs, by: elapsedNs)
        bump(.budgetNs, by: budgetNs)
        // Multi-producer monotone max — bounded CAS loop (see CAtomics.h);
        // exact across concurrently racing render workers.
        daw_atomic_u64_max(cells + Cell.peakCallbackNs.rawValue, elapsedNs)
        if budgetNs > 0, elapsedNs > budgetNs {
            bump(.overrunCount, by: 1)
        }

        // recentLoad EMA — the one Double in the hot path. Non-trapping by
        // construction (budget divisor > 0 checked); NaN/denormal guarded so
        // a poisoned cell can never persist. MULTI-PRODUCER RACY-BENIGN by
        // design: concurrent render workers can interleave load→store here
        // and lose an EMA step — a bounded, decaying distortion of a
        // ballistic display value, never a torn Double (atomic u64 cell).
        // Do NOT "fix" this with a CAS loop; the cell does not need it.
        let instantaneous = budgetNs > 0 ? Double(elapsedNs) / Double(budgetNs) : 0
        var ema = Double(bitPattern: daw_atomic_u64_load(cells + Cell.recentLoadBits.rawValue))
        if !ema.isFinite || ema < 0 { ema = 0 }
        ema += Self.recentLoadAlpha * (instantaneous - ema)
        if !ema.isFinite || ema < Self.denormalFloor { ema = 0 }
        daw_atomic_u64_store(cells + Cell.recentLoadBits.rawValue, ema.bitPattern)

        // Last-seen facts — MULTI-PRODUCER RACY-BENIGN: concurrent workers
        // may interleave these two stores (frames from one, rate from
        // another), but all live producers share one graph format, so the
        // pair is coherent in practice and each store is whole regardless.
        daw_atomic_u64_store(cells + Cell.lastQuantumFrames.rawValue, frameCount)
        daw_atomic_u64_store(cells + Cell.lastSampleRateHz.rawValue, rate)
    }

    /// Multi-producer accumulator increment: `daw_atomic_u64_add`
    /// (fetch_add, acq_rel) — indivisible, so counts are EXACT under any
    /// number of concurrent render-pool workers, and each whole delta lands
    /// in exactly one reset window.
    @inline(__always)
    private func bump(_ cell: Cell, by delta: UInt64) {
        _ = daw_atomic_u64_add(cells + cell.rawValue, delta)
    }

    // MARK: - Reader surface (single reader; main actor in the engine)

    /// The LIFETIME-monotone callback count — the crash-c watchdog heartbeat.
    /// Deliberately NOT the windowed snapshot value (a perf-c `reset: true`
    /// rebases windows; the watchdog must never mistake a rebase for a
    /// frozen or advancing heartbeat). One load-acquire on the raw cell,
    /// reader-side only; never touches the render thread.
    func lifetimeCallbackCount() -> UInt64 {
        load(.callbackCount)
    }

    /// The current window's stats (since init or the last reset). Every
    /// field finite by contract; `averageLoad` derives HERE, never on the
    /// render thread. A stopped engine freezes the counters but the snapshot
    /// stays readable.
    func snapshot() -> EnginePerformanceStats {
        stats(from: loadWindow())
    }

    /// Read-then-reset for windowed profiling: returns the closing window's
    /// stats and starts a fresh window from the SAME loads (the windows tile
    /// exactly on the monotone accumulators — see the RESET note).
    func snapshotAndReset() -> EnginePerformanceStats {
        let window = loadWindow()
        rebase(on: window)
        return stats(from: window)
    }

    /// Starts a fresh window without reading (init-time convenience; the
    /// command path always goes through `snapshotAndReset`).
    func reset() {
        rebase(on: loadWindow())
    }

    // MARK: - Window math

    private struct Window {
        var callbackCount: UInt64
        var renderedFrames: UInt64
        var renderTimeNs: UInt64
        var budgetNs: UInt64
        var peakCallbackNs: UInt64
        var overrunCount: UInt64
        var recentLoad: Double
        var lastQuantumFrames: UInt64
        var lastSampleRateHz: UInt64
        var nowTicks: UInt64
    }

    private func load(_ cell: Cell) -> UInt64 {
        daw_atomic_u64_load(cells + cell.rawValue)
    }

    private func loadWindow() -> Window {
        var recent = Double(bitPattern: load(.recentLoadBits))
        if !recent.isFinite || recent < 0 { recent = 0 }
        return Window(
            callbackCount: load(.callbackCount) &- baseCallbackCount,
            renderedFrames: load(.renderedFrames) &- baseRenderedFrames,
            renderTimeNs: load(.renderTimeNs) &- baseRenderTimeNs,
            budgetNs: load(.budgetNs) &- baseBudgetNs,
            peakCallbackNs: load(.peakCallbackNs),
            overrunCount: load(.overrunCount) &- baseOverrunCount,
            recentLoad: recent,
            lastQuantumFrames: load(.lastQuantumFrames),
            lastSampleRateHz: load(.lastSampleRateHz),
            nowTicks: mach_absolute_time()
        )
    }

    private func rebase(on window: Window) {
        baseCallbackCount &+= window.callbackCount
        baseRenderedFrames &+= window.renderedFrames
        baseRenderTimeNs &+= window.renderTimeNs
        baseBudgetNs &+= window.budgetNs
        baseOverrunCount &+= window.overrunCount
        // Ballistic values restart from zero (benign-race semantics above).
        daw_atomic_u64_store(cells + Cell.peakCallbackNs.rawValue, 0)
        daw_atomic_u64_store(cells + Cell.recentLoadBits.rawValue, 0)
        resetEpochTicks = window.nowTicks
    }

    private func stats(from window: Window) -> EnginePerformanceStats {
        let average = window.budgetNs > 0
            ? Double(window.renderTimeNs) / Double(window.budgetNs)
            : 0
        let elapsedTicks = window.nowTicks &- resetEpochTicks
        var sinceReset = Double(elapsedTicks) * ticksToSeconds
        if !sinceReset.isFinite || sinceReset < 0 { sinceReset = 0 }
        return EnginePerformanceStats(
            callbackCount: Int(clamping: window.callbackCount),
            renderedFrames: Int(clamping: window.renderedFrames),
            renderTimeNs: Int(clamping: window.renderTimeNs),
            peakCallbackNs: Int(clamping: window.peakCallbackNs),
            overrunCount: Int(clamping: window.overrunCount),
            averageLoad: average.isFinite && average >= 0 ? average : 0,
            recentLoad: window.recentLoad,
            sampleRate: Double(window.lastSampleRateHz),
            quantumFrames: Int(clamping: window.lastQuantumFrames),
            sinceResetSeconds: sinceReset
        )
    }
}
