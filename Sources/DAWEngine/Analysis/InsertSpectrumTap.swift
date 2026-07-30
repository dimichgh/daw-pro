import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Per-insert spectrum tap (m23-r1): a bounded single-producer /
/// single-consumer sample ring that lets an arbitrary point in the effect
/// chain feed the SAME `MasterMixAnalyzer` the master strip already uses.
///
/// THE HEADLINE, and the whole reason this type exists: **the render thread
/// performs no analysis.** `write(buffers:frameCount:)` is at most four
/// `memcpy`s into a preallocated ring plus one release-store. The FFT, the
/// band fold, the ballistics and the snapshot all run on the CONSUMER inside
/// an UNMODIFIED `MasterMixAnalyzer`, so a tapped insert and the master
/// overlay are comparable by shared IMPLEMENTATION, not by shared constants
/// — there is no second STFT front-end and no third band fold.
/// (Design: `docs/research/design-m23r-per-insert-spectrum-tap.md` §2.)
///
/// THREADING CONTRACT (`@unchecked Sendable`), split ownership exactly as
/// `EffectChainProcessor` documents it:
/// - `write(buffers:frameCount:)` — PRODUCER ONLY, one thread for the tap's
///   whole lifetime (in the engine: the render thread). Writes the ring
///   slots, then RELEASE-stores `writeIndex`.
/// - `drainAndSnapshot()` — CONSUMER ONLY, one thread at a time (in the
///   engine: the main actor, at UI rate). ACQUIRE-loads `writeIndex`, owns
///   `readIndex`, the staging buffers and the analyzer exclusively, and is
///   the only writer of `droppedFrames`.
/// - No other method may run concurrently with either. Deliberately NOT
///   `@MainActor`: main-actor residency is a deployment fact of r2/r3, not a
///   requirement of this object, and annotating it would drag every headless
///   test onto the main actor for nothing (the `MasterMixAnalyzer` idiom).
///
/// REAL-TIME SAFETY of `write`: every buffer is allocated in `init`; the body
/// contains no allocation, no locks, no ObjC/Swift-runtime dispatch (the
/// class is `final`, the calls are direct, the atomics are C inline
/// functions), no libm, no FFT, and no arithmetic on sample data — it only
/// COPIES. It reads the audio buffer and writes only to its own ring, so the
/// signal is structurally untouched: an armed tap cannot change a rendered
/// sample. Cost is bounded by `frameCount` and clamped at
/// `capacityFrames / 2`.
///
/// CHANNEL RULE — matches `MasterMixAnalyzer.processMix`'s
/// `channels[channelCount >= 2 ? 1 : 0]` (`:338`):
/// - 1 buffer  → ch0 is DUPLICATED into both ring channels. The drain then
///   mono-sums (L+L)/2, which is bit-identically L, so a mono write reads
///   exactly like `processMix(channelCount: 1)`.
/// - 2 buffers → straight L/R.
/// - ≥ 3 buffers → the FIRST TWO are used and the rest ignored. Ignoring is
///   the honest degradation: SKIPPING the write would leave a GAP in the
///   sample stream, and a gap corrupts every band, while a dropped 5th
///   channel only narrows what the meter sees. (The chain walk is ≤ 2
///   channels anyway — `ChainEffectUnit.scratchChannels`, pinned in the
///   tests.)
/// - Buffers are assumed NON-INTERLEAVED (one channel per `AudioBuffer`),
///   which is what the whole chain walk assumes.
///
/// DROP POLICY — DROP OLDEST, and count it. A UI stall (window inactive,
/// `TimelineView(.animation)` paused) must degrade gracefully rather than
/// tear or unboundedly lag: the drain keeps the newest `maxDrainFrames` and
/// counts everything it skipped into `droppedFrames`. Sustained drops shorten
/// the sample stream the analyzer sees and its ballistics are per-hop, not
/// per-wall-second, so a DROPPING tap runs its meters slow — which is why
/// every fidelity/comparability fixture must assert `droppedFrames == 0`
/// as its premise rather than ignoring the counter.
///
/// TEAR DEFENCE: the consumer stages its span, then RE-LOADS `writeIndex`.
/// If the producer advanced past `readIndex + capacityFrames` while the copy
/// was in flight, the staged bytes may have been overwritten mid-copy, so the
/// block is DISCARDED and counted — never fed. This is exact, not heuristic:
/// slot `readIndex % capacity` is first re-used by frame index
/// `readIndex + capacity`.
///
/// FOOTPRINT: ~230 KB per armed tap (ring 128 KB + staging 32 KB + the
/// analyzer's ~70 KB), and **0 bytes when disarmed**, because a disarmed
/// insert simply has no tap object.
final class InsertSpectrumTap: @unchecked Sendable {

    // MARK: - Sizes

    /// Ring capacity in frames, per channel. 16_384 = 341 ms @ 48 kHz and
    /// **2× `ChainEffectUnit.scratchFrames` (8_192, the house max quantum)**,
    /// so one pathological max-quantum write can never fill the ring. Power
    /// of two: the slot index is a mask, not a modulo. 128 KB for the pair.
    static let capacityFrames = 16_384
    /// Most frames one `drainAndSnapshot()` will consume. 4_096 = 85 ms; a
    /// 46 fps poll needs ~1_044, so the drop path is unreachable at normal
    /// cadence and exists only for the stall case. 32 KB for the pair.
    static let maxDrainFrames = 4_096

    private static let capacityMask = UInt64(capacityFrames - 1)

    // MARK: - Shared state (producer writes / consumer reads)

    /// Non-interleaved L/R ring storage, `capacityFrames` each.
    private let ringL: UnsafeMutablePointer<Float>
    private let ringR: UnsafeMutablePointer<Float>
    /// MONOTONIC count of frames ever written — never wrapped; the slot is
    /// `index & capacityMask`. Producer stores RELEASE, consumer loads
    /// ACQUIRE (`CAtomics.h:31`/`:34`). Heap-allocated for a stable address,
    /// per the CAtomics rule.
    private let writeIndex: UnsafeMutablePointer<daw_atomic_u64>
    /// Frames the consumer discarded (stall drops + tear discards). Written
    /// ONLY by the consumer; exposed for gates and for r2/r4 honesty.
    private let dropped: UnsafeMutablePointer<daw_atomic_u64>

    // MARK: - Consumer-only state

    /// Frames ever consumed. Single reader ⇒ a plain value, no atomic.
    private var readIndex: UInt64 = 0
    private let stagingL: UnsafeMutablePointer<Float>
    private let stagingR: UnsafeMutablePointer<Float>
    /// Preallocated 2-element channel pointer array so `processMix` needs no
    /// per-poll allocation.
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// The one and only analyzer — the same class, the same geometry and the
    /// same ballistics as the master path.
    ///
    /// Exposed as a CONSUMER-TIER READ SEAM for tests and gates (`snapshot()`
    /// is a pure read that advances nothing). **Never feed it directly** — the
    /// FIFO, the ballistics and the drop accounting only stay coherent if
    /// every sample arrives through `drainAndSnapshot()`, on that one thread.
    let analyzer: MasterMixAnalyzer

    /// TEST SEAM (nil in production, so it costs one nil check per POLL —
    /// never anything on the render thread): invoked by the consumer AFTER
    /// the staging copy and BEFORE the tear-defence re-load, which is the
    /// only window in which a producer stomp is observable. Without it the
    /// tear branch is unreachable from a single-threaded test and would ship
    /// unproven; a real racing writer would make the gate a coin flip.
    var onStagedForTesting: (() -> Void)?

    // MARK: - Lifecycle

    /// `sampleRate` is forwarded to the analyzer, which falls back to 48 kHz
    /// for any non-positive value rather than trapping on a degenerate live
    /// format.
    init(sampleRate: Double) {
        precondition(Self.capacityFrames > 0
                     && Self.capacityFrames & (Self.capacityFrames - 1) == 0,
                     "InsertSpectrumTap.capacityFrames must be a power of two")
        precondition(Self.maxDrainFrames > 0
                     && Self.maxDrainFrames < Self.capacityFrames,
                     "maxDrainFrames must be a positive fraction of the ring")

        ringL = .allocate(capacity: Self.capacityFrames)
        ringR = .allocate(capacity: Self.capacityFrames)
        ringL.initialize(repeating: 0, count: Self.capacityFrames)
        ringR.initialize(repeating: 0, count: Self.capacityFrames)

        stagingL = .allocate(capacity: Self.maxDrainFrames)
        stagingR = .allocate(capacity: Self.maxDrainFrames)
        stagingL.initialize(repeating: 0, count: Self.maxDrainFrames)
        stagingR.initialize(repeating: 0, count: Self.maxDrainFrames)

        channelPointers = .allocate(capacity: 2)
        channelPointers.initialize(to: stagingL)
        (channelPointers + 1).initialize(to: stagingR)

        writeIndex = .allocate(capacity: 1)
        daw_atomic_u64_store(writeIndex, 0)
        dropped = .allocate(capacity: 1)
        daw_atomic_u64_store(dropped, 0)

        analyzer = MasterMixAnalyzer(sampleRate: sampleRate)
    }

    deinit {
        ringL.deallocate()
        ringR.deallocate()
        stagingL.deallocate()
        stagingR.deallocate()
        channelPointers.deinitialize(count: 2)
        channelPointers.deallocate()
        writeIndex.deallocate()
        dropped.deallocate()
    }

    // MARK: - Observable counters

    /// Frames ever accepted by `write` — the LIVENESS half of r2's gate: a
    /// ring that never advanced proves the tap never ran, independently of
    /// whether the drain path works.
    var framesWritten: UInt64 { daw_atomic_u64_load(writeIndex) }

    /// Frames discarded by the consumer (stall drop-oldest + tear discards).
    /// Must be 0 for any fixture that compares band values.
    var droppedFrames: UInt64 { daw_atomic_u64_load(dropped) }

    // MARK: - Render side

    /// PRODUCER ONLY — the ENTIRE render-thread surface of this feature.
    ///
    /// RT contract: no allocation, no locks, no ObjC, no libm, no FFT, no
    /// dynamic dispatch. At most four `memcpy`s (two channels × the wrap
    /// split) and one release-store. Never mutates `buffers`.
    ///
    /// A single write is clamped to `capacityFrames / 2` (8_192 = the house
    /// max quantum), so a write can never overtake itself. Frames beyond that
    /// clamp are dropped SILENTLY and are NOT counted: the counter is
    /// consumer-owned by contract and the path is structurally unreachable
    /// (the tests pin `capacityFrames / 2 >= ChainEffectUnit.scratchFrames`,
    /// so raising the max quantum reddens the suite instead).
    func write(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0, buffers.count >= 1 else { return }
        let stride = MemoryLayout<Float>.stride
        guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }

        // ONE frame count for BOTH channels. Deriving them per channel from
        // `mDataByteSize` would let L and R advance by different amounts,
        // which desynchronizes the ring: the bands (a mono sum) would still
        // look plausible while the stereo image silently went to garbage.
        var n = min(frameCount, Self.capacityFrames / 2)
        n = min(n, Int(buffers[0].mDataByteSize) / stride)
        let right: UnsafeMutablePointer<Float>
        if buffers.count >= 2,
           let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            right = second
            n = min(n, Int(buffers[1].mDataByteSize) / stride)
        } else {
            right = left  // mono: duplicate ch0 — see the CHANNEL RULE above.
        }
        guard n > 0 else { return }

        let w = daw_atomic_u64_load(writeIndex)  // sole producer
        let slot = Int(w & Self.capacityMask)
        let head = min(n, Self.capacityFrames - slot)
        (ringL + slot).update(from: left, count: head)
        (ringR + slot).update(from: right, count: head)
        if head < n {
            ringL.update(from: left + head, count: n - head)
            ringR.update(from: right + head, count: n - head)
        }
        // RELEASE: the slot writes above are visible to any consumer that
        // acquire-loads this value (CAtomics.h:31 ⇄ :34).
        daw_atomic_u64_store(writeIndex, w &+ UInt64(n))
    }

    // MARK: - Consumer side

    /// CONSUMER ONLY. Drains everything pending (dropping oldest beyond
    /// `maxDrainFrames`), feeds it to the analyzer and returns the current
    /// snapshot.
    ///
    /// Allocation is legal here and nowhere else: this is the same tier the
    /// master path already allocates on ~46×/s (`snapshot()`'s 24-element
    /// `bands` array).
    ///
    /// With nothing pending — or when the tear defence fires — the analyzer
    /// is not fed at all, so `snapshot()` returns the PREVIOUS reading by
    /// construction (it is a pure read that advances no ballistics); no
    /// cached snapshot field is needed.
    func drainAndSnapshot() -> MasterAnalysisSnapshot {
        let w = daw_atomic_u64_load(writeIndex)  // ACQUIRE
        var available = w &- readIndex

        // DROP OLDEST: keep the newest `maxDrainFrames`, count the rest.
        if available > UInt64(Self.maxDrainFrames) {
            let excess = available &- UInt64(Self.maxDrainFrames)
            readIndex = readIndex &+ excess
            daw_atomic_u64_add(dropped, excess)
            available = UInt64(Self.maxDrainFrames)
        }
        guard available > 0 else { return analyzer.snapshot() }

        let n = Int(available)
        let start = Int(readIndex & Self.capacityMask)
        let head = min(n, Self.capacityFrames - start)
        stagingL.update(from: ringL + start, count: head)
        stagingR.update(from: ringR + start, count: head)
        if head < n {
            (stagingL + head).update(from: ringL, count: n - head)
            (stagingR + head).update(from: ringR, count: n - head)
        }

        onStagedForTesting?()

        // TEAR DEFENCE. Slot `readIndex & mask` is first re-used by frame
        // index `readIndex + capacityFrames`; the producer has written up to
        // `w2 - 1`. So the staged span is intact iff `w2 - readIndex <=
        // capacityFrames`. Otherwise the copy raced a wrap and the bytes are
        // untrustworthy: discard the WHOLE lost span (not just the staged
        // block — everything from `readIndex` to `w2` is now suspect or
        // already gone), count it, and publish the previous reading.
        let w2 = daw_atomic_u64_load(writeIndex)  // ACQUIRE
        let spanSinceRead = w2 &- readIndex
        if spanSinceRead > UInt64(Self.capacityFrames) {
            daw_atomic_u64_add(dropped, spanSinceRead)
            readIndex = w2
            return analyzer.snapshot()
        }

        readIndex = readIndex &+ available
        analyzer.processMix(channels: channelPointers, channelCount: 2, frameCount: n)
        return analyzer.snapshot()
    }
}
