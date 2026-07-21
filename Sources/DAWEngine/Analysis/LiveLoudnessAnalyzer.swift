import CAtomics
import DAWCore
import Foundation

/// Live master-bus loudness analyzer (m22-c): the engine-side wrapper that
/// rides the SAME master tap as `MasterMixAnalyzer` and feeds
/// `Loudness.Stream` — ALL of the DSP (K-weighting, blocks/windows, gating,
/// LRA, 4× true peak, DC/crest) lives in DAWCore's Loudness.swift, the one
/// DSP home; this class only adds the cross-thread choreography.
///
/// ALWAYS ARMED, like `MasterMixAnalyzer`: it consumes tap deliveries the
/// engine already pays for, its per-sample cost is a fraction of the
/// analyzer FFT's, and an always-running meter is the point — an agent can
/// ask "how loud has this session been" without having pre-armed anything.
///
/// THREADING (`@unchecked Sendable`):
/// - `processAndSnapshot` runs ONLY on AVFAudio's serial tap queue (the
///   `MasterMixAnalyzer.process*` contract) and owns `stream` exclusively.
/// - `requestReset` may be called from ANY thread (in practice the main
///   actor, via `mixer.liveLoudness {reset:true}`) — it never touches
///   `stream`. It bumps the atomic generation, then flags a pending reset;
///   the NEXT tap delivery consumes the flag and resets the stream on the
///   tap queue itself, so the reset needs no lock and can never stall a tap.
/// - Stale-publish protection: `processAndSnapshot` reads the generation
///   BEFORE consuming the reset flag and tags its snapshot with it. The
///   engine's main-actor cache drops snapshots whose generation is not
///   current, so a callback already in flight when a reset lands can never
///   resurrect pre-reset values (its tag is stale by construction).
///
/// The atomics live in heap allocations (`UnsafeMutablePointer.allocate`)
/// per the CAtomics stable-address rule.
public final class LiveLoudnessAnalyzer: @unchecked Sendable {

    public let sampleRate: Double
    public let channelCount: Int

    /// Tap-queue-owned; never touched from any other thread.
    private let stream: Loudness.Stream
    /// 1 = a reset was requested and not yet consumed by the tap queue.
    private let pendingReset: UnsafeMutablePointer<daw_atomic_u32>
    /// Monotone reset generation; snapshots are tagged with it.
    private let generation: UnsafeMutablePointer<daw_atomic_u64>

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.stream = Loudness.Stream(sampleRate: sampleRate, channelCount: channelCount)
        pendingReset = .allocate(capacity: 1)
        daw_atomic_u32_store(pendingReset, 0)
        generation = .allocate(capacity: 1)
        daw_atomic_u64_store(generation, 0)
    }

    deinit {
        pendingReset.deallocate()
        generation.deallocate()
    }

    /// True when this analyzer was built for the given live format — the
    /// engine reuses it across tap reinstalls (running loudness survives an
    /// engine rebuild) and replaces it when the format actually changed.
    public func matches(sampleRate: Double, channelCount: Int) -> Bool {
        self.sampleRate == sampleRate && self.channelCount == channelCount
    }

    /// Request a measurement restart (any thread; never blocks, never
    /// touches the stream). Returns the NEW generation — the caller stores
    /// it and drops published snapshots carrying any other tag.
    ///
    /// ORDER IS LOAD-BEARING: the flag is set BEFORE the generation bump
    /// (release/acquire pairing with `processAndSnapshot`'s gen-then-flag
    /// reads), so a tap callback that observes the new generation is
    /// GUARANTEED to also observe — and consume — the pending reset; a
    /// callback that raced ahead tags the old generation and is dropped.
    public func requestReset() -> UInt64 {
        daw_atomic_u32_store(pendingReset, 1)
        return daw_atomic_u64_add(generation, 1) &+ 1
    }

    /// Tap-queue entry point: consume a pending reset (if any), feed the
    /// buffer, and return the fresh snapshot tagged with the generation
    /// read BEFORE the reset check (see the stale-publish note above).
    /// No locks; the only allocations are the stream's documented ≤ 10 Hz
    /// hop-boundary history/gating work — never per buffer.
    public func processAndSnapshot(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> (snapshot: LiveLoudnessSnapshot, generation: UInt64) {
        let taggedGeneration = daw_atomic_u64_load(generation)
        if daw_atomic_u32_exchange(pendingReset, 0) == 1 {
            stream.reset()
        }
        stream.process(channels: channels, channelCount: channelCount,
                       frameCount: frameCount)
        return (stream.snapshot(), taggedGeneration)
    }
}
