import AVFAudio
import Darwin
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// Headless gate for `InsertSpectrumTap` (m23-r1): the SPSC ring and its
/// consumer, proven in ISOLATION. Nothing here touches `EffectChainProcessor`,
/// the arm plumbing, the UI or the wire — that is r2/r3/r4. The tap is
/// constructed directly and fed `AudioBufferList`s by hand, so SPSC
/// correctness surfaces before anything touches the chain walk or the pins.
///
/// The load-bearing claim under test is §2.2 of
/// `docs/research/design-m23r-per-insert-spectrum-tap.md`: a tapped insert
/// and the master overlay are the SAME numbers, not merely similar, because
/// both funnel into one unmodified `MasterMixAnalyzer`. That is asserted here
/// as BIT-IDENTICAL bands against a reference analyzer fed the same stream in
/// one shot, together with a discriminator proving the assertion can see a
/// broken ring.
///
/// No `.serialized`: the ONE probe this suite uses (`malloc_logger`, below)
/// filters on the calling thread, so a sibling suite allocating in parallel
/// is invisible to it — see the ALLOCATION PROBE note.
@Suite("Per-insert spectrum tap — SPSC ring + consumer (m23-r1)")
struct InsertSpectrumTapTests {

    // MARK: - Allocation probe
    //
    // ONE probe. There used to be two — history, and the m23-ab-2 measurement
    // that removed the first, below.
    //
    // The design's originally stated leg was
    // `malloc_zone_statistics(...).blocks_in_use`, with `.serialized` on this
    // suite to keep it from reading other suites' allocation noise.
    // `.serialized` orders tests WITHIN this suite; it does nothing about
    // OTHER suites loading the machine, and `blocks_in_use` reads a
    // PROCESS-GLOBAL zone counter — so the leg still fired under full-suite
    // parallel load (m23-ab, item 4: filed 14/14 green in isolation). MEASURED
    // at m23-ab-2: a full-suite run produced `controlDeltas.min()! == -240` on
    // the harness's OWN control loop — a loop that RETAINS 10_000 allocations
    // and so can NEVER legitimately produce a non-positive delta — because sibling test
    // threads were freeing memory in the SAME zone during the window. A
    // counter that can read *negative* while the calling thread is purely
    // allocating is not "conservative under load", it is WRONG under load,
    // and no amount of `.serialized` on this suite fixes a process-global
    // read of work happening in every OTHER suite.
    //
    // The second probe, kept, is libmalloc's `malloc_logger` hook (the
    // mechanism behind `MallocStackLogging`/`leaks`), resolved with `dlsym`
    // so no C shim is needed. It fires on EVERY malloc and free, and because
    // it filters on the calling thread (`watchedThread`) it is immune to the
    // parallel test threads that make `blocks_in_use` noisy — including the
    // negative-delta failure above, which is a PROCESS-GLOBAL-ness failure
    // that a thread-filtered probe cannot have by construction.
    //
    // Does one probe cover both jobs the original two were split across
    // (retained leaks vs. transient churn)? MEASURED, not assumed:
    // `writeIsAllocationFreeAndActuallyRan`'s own control loop RETAINS every
    // allocation it makes (appends to `sink`, never freed inside the
    // measured window) and asserts `controlEvents.min()! >= perWindow` — the
    // logger fires on every one of those retained allocations, because the
    // hook triggers on the MALLOC CALL ITSELF, not on whether a matching free
    // ever happens. A `write()` that leaked one RETAINED block per call would
    // therefore trip the exact same `eventCounts.max()! == 0` strict check
    // that already catches transient churn — there is no "retained but
    // silent to the logger" shape for a single-threaded allocator call.
    // (The r1 mutation — `sink = [Float](repeating: 0, count: 4)` at the top
    // of `write`, a transient per-call alloc/free — re-reddens the same check
    // with `blocks_in_use` gone; re-verified by hand at m23-ab-2, along with a
    // second mutation that RETAINS instead of churning, e.g. a `class`-scoped
    // array appended once per `write` call and never cleared — both trip
    // `eventCounts.max()! == 0`.) The one shape a thread-filtered probe
    // genuinely cannot see is an allocation
    // made on a DIFFERENT thread than the one calling `write` — not a gap in
    // this suite: `write`'s own contract (this file's header, and
    // `InsertSpectrumTap.swift`) is single-producer, called synchronously
    // with no dispatch, so a cross-thread allocation would already be a
    // severe, independently-detectable RT-safety violation, not a leak this
    // probe was ever positioned to catch.

    private typealias MallocLoggerFn =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Heap cells, NOT Swift stored properties: the hook runs INSIDE malloc
    /// with its locks held, so it must never allocate and never trip a lazy
    /// global initializer. `mallocEvents` touches both cells before it
    /// installs the hook, which is what guarantees their `swift_once` tokens
    /// are already resolved by the time the hook can fire.
    private nonisolated(unsafe) static let eventCount =
        UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let watchedThread =
        UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private static let eventHook: MallocLoggerFn = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)  // no allocation, safe under malloc
        if tid == InsertSpectrumTapTests.watchedThread.pointee {
            InsertSpectrumTapTests.eventCount.pointee &+= 1
        }
    }

    /// The address of libmalloc's `malloc_logger` global, or nil if the
    /// symbol ever goes away. Nil is treated as a FAILURE by the caller, not
    /// as a skip — a silently-absent allocation probe is exactly the vacuity
    /// this leg exists to prevent.
    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
        // RTLD_DEFAULT: search every loaded image.
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: MallocLoggerFn?.self)
    }

    /// malloc + free events raised BY THE CALLING THREAD while `body` runs.
    private static func mallocEvents(
        slot: UnsafeMutablePointer<MallocLoggerFn?>, _ body: () -> Void
    ) -> Int {
        pthread_threadid_np(nil, &watchedThread.pointee)
        eventCount.pointee = 0
        let previous = slot.pointee  // restore, don't assume it was nil
        slot.pointee = eventHook
        body()
        slot.pointee = previous
        return eventCount.pointee
    }

    private static let sampleRate = 48_000.0
    private static let bandCount = MasterAnalysisSnapshot.bandCount
    private static let floorDB = MasterAnalysisSnapshot.floorDB

    // MARK: - Fixtures

    /// Deterministic noise (no `random()` — a gate must be reproducible).
    private struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
    }

    /// The comparability fixture. **NON-STATIONARY ON PURPOSE — DO NOT
    /// "SIMPLIFY" THIS TO A STEADY TONE.**
    ///
    /// `bands` are chunk-invariant BIT-EXACTLY (the analyzer funnels
    /// everything through a fixed 2048/1024 FIFO and the mono sum is
    /// elementwise), but `correlation`/`width`/`balance` are NOT: they
    /// accumulate per-chunk `vDSP_dotpr` Float partials into Double sums, so
    /// different chunk boundaries regroup the partials and move the last ulp.
    /// Measured against this analyzer, the drift is ~1.9e-9 on `correlation`
    /// — small, but real, and only VISIBLE with a non-stationary signal: fed
    /// a steady tone the ~300 ms smoother washes the grouping-dependent
    /// rounding out entirely and all three fields come back bit-equal. A
    /// later cycle that re-derived the tolerance against a steady fixture
    /// would therefore "discover" it could be tightened to bit-equality and
    /// ship a flake. It cannot. The envelope is what keeps this honest.
    private static func nonStationaryStereo(
        frames: Int, seed: UInt64 = 0x5EED_1A70
    ) -> (left: [Float], right: [Float]) {
        var rng = LCG(state: seed)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let seconds = Double(frames) / sampleRate
        for index in 0..<frames {
            let t = Double(index) / sampleRate
            // 3 Hz tremolo × a slow swell: the amplitude never settles.
            let tremolo = 0.5 - 0.5 * cos(2 * .pi * 3.0 * t)
            let swell = 0.35 + 0.65 * (t / max(1e-9, seconds))
            let env = Float(0.12 + 0.7 * tremolo * swell)
            let low = Float(sin(2 * .pi * 220 * t))
            let high = Float(sin(2 * .pi * 1_970 * t + 0.7))
            let shared = rng.next()
            let onlyRight = rng.next()
            left[index] = env * (0.60 * low + 0.25 * high + 0.15 * shared)
            right[index] = env * (0.45 * low - 0.30 * high + 0.20 * onlyRight
                                  + 0.10 * shared)
        }
        return (left, right)
    }

    /// A period-aligned tone: 750 Hz at 48 kHz is 64 samples/period, so a
    /// 512-frame chunk is exactly 8 periods and REPEATING that one chunk
    /// produces a genuinely continuous tone (no chop artefacts) — which is
    /// what lets the allocation leg stage once, outside the measured window.
    private static func alignedTone(frames: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * .pi * 750 * Double(index) / sampleRate))
        }
    }

    /// Owns the scratch + `AudioBufferList` a test hands to `write`. Sized
    /// once; `stage` only copies and re-stamps `mDataByteSize`, so the write
    /// loops never allocate.
    private final class Feeder {
        let list: UnsafeMutableAudioBufferListPointer
        private let storage: UnsafeMutablePointer<Float>
        let capacity: Int
        let channelCount: Int

        init(capacity: Int, channelCount: Int) {
            self.capacity = capacity
            self.channelCount = channelCount
            storage = .allocate(capacity: capacity * channelCount)
            storage.initialize(repeating: 0, count: capacity * channelCount)
            list = AudioBufferList.allocate(maximumBuffers: channelCount)
            for channel in 0..<channelCount {
                list[channel] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(capacity * MemoryLayout<Float>.stride),
                    mData: UnsafeMutableRawPointer(storage + channel * capacity))
            }
        }

        deinit {
            free(list.unsafeMutablePointer)
            storage.deallocate()
        }

        /// Loads `count` frames starting at `offset` from `left`/`right`.
        func stage(left: [Float], right: [Float], offset: Int, count: Int) {
            precondition(count <= capacity)
            left.withUnsafeBufferPointer {
                storage.update(from: $0.baseAddress! + offset, count: count)
            }
            if channelCount >= 2 {
                right.withUnsafeBufferPointer {
                    (storage + capacity).update(from: $0.baseAddress! + offset,
                                                count: count)
                }
            }
            for channel in 0..<channelCount {
                list[channel].mDataByteSize =
                    UInt32(count * MemoryLayout<Float>.stride)
            }
        }

        /// Re-stamps `mDataByteSize` PER CHANNEL, so a test can hand `write` a
        /// RAGGED buffer list (channel 1 declaring fewer frames than channel
        /// 0). Every other fixture in this file stamps both channels
        /// identically, which is exactly why the clamp needs its own leg: a
        /// ragged list is the one shape that turns a missing clamp into a heap
        /// OVERREAD on the render thread.
        func restamp(_ frameCounts: [Int]) {
            precondition(frameCounts.count == channelCount)
            for channel in 0..<channelCount {
                list[channel].mDataByteSize =
                    UInt32(frameCounts[channel] * MemoryLayout<Float>.stride)
            }
        }

        /// Fills ONE channel's scratch with a constant, so a test can prove the
        /// tap does not hear a channel it is supposed to ignore.
        func fill(channel: Int, with value: Float) {
            (storage + channel * capacity).update(repeating: value,
                                                  count: capacity)
        }

        /// Loads one repeating chunk (the aligned-tone case).
        func stageRepeating(_ chunk: [Float], count: Int) {
            precondition(count <= capacity && count <= chunk.count)
            for channel in 0..<channelCount {
                chunk.withUnsafeBufferPointer {
                    (storage + channel * capacity)
                        .update(from: $0.baseAddress!, count: count)
                }
                list[channel].mDataByteSize =
                    UInt32(count * MemoryLayout<Float>.stride)
            }
        }
    }

    /// A fresh analyzer fed the whole stream in ONE shot — the reference the
    /// tap must reproduce bit-for-bit in `bands`.
    private static func referenceSnapshot(
        left: [Float], right: [Float], channelCount: Int
    ) -> MasterAnalysisSnapshot {
        let analyzer = MasterMixAnalyzer(sampleRate: sampleRate)
        var l = left
        var r = right
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                let channels = [lb.baseAddress!, rb.baseAddress!]
                channels.withUnsafeBufferPointer { cb in
                    analyzer.processMix(channels: cb.baseAddress!,
                                        channelCount: channelCount,
                                        frameCount: lb.count)
                }
            }
        }
        return analyzer.snapshot()
    }

    /// Feeds the tap in `chunkSizes` (cycling), draining whenever the next
    /// chunk would push the pending span past `maxDrainFrames`.
    ///
    /// The interleaved drain is NOT decoration: one drain consumes at most
    /// `maxDrainFrames` (4_096), so writing a whole multi-second stream and
    /// draining once at the end would trip DROP-OLDEST and the fidelity
    /// assertion would be measuring the drop policy instead of the ring.
    /// Chunking the DRAIN is free (bands are chunk-invariant); dropping is
    /// fatal — hence the `droppedFrames == 0` premise every caller asserts.
    @discardableResult
    private static func feedChunked(
        tap: InsertSpectrumTap, feeder: Feeder,
        left: [Float], right: [Float], chunkSizes: [Int]
    ) -> MasterAnalysisSnapshot {
        var snapshot = tap.analyzer.snapshot()
        var offset = 0
        var pending = 0
        var cursor = 0
        while offset < left.count {
            let want = chunkSizes[cursor % chunkSizes.count]
            cursor += 1
            let count = min(want, left.count - offset)
            if pending + count > InsertSpectrumTap.maxDrainFrames {
                snapshot = tap.drainAndSnapshot()
                pending = 0
            }
            feeder.stage(left: left, right: right, offset: offset, count: count)
            tap.write(buffers: feeder.list, frameCount: count)
            offset += count
            pending += count
        }
        while pending > 0 {
            snapshot = tap.drainAndSnapshot()
            pending = 0
        }
        return snapshot
    }

    // MARK: - Sizes (the "cannot happen" claims, pinned)

    @Test("sizes: power-of-two ring ≥ 2× the house max quantum, ≤ 256 KB")
    func sizes() {
        #expect(InsertSpectrumTap.capacityFrames == 16_384)
        #expect(InsertSpectrumTap.capacityFrames
                & (InsertSpectrumTap.capacityFrames - 1) == 0)
        #expect(InsertSpectrumTap.maxDrainFrames == 4_096)
        #expect(InsertSpectrumTap.maxDrainFrames < InsertSpectrumTap.capacityFrames)

        // `write` clamps a single call to capacityFrames / 2 and drops the
        // excess SILENTLY and UNCOUNTED. That is only honest while the clamp
        // is unreachable — so pin the reachability claim against the chain's
        // own bounds rather than asserting it in prose. Raising the house max
        // quantum (or widening the walk past stereo) reddens this leg.
        #expect(InsertSpectrumTap.capacityFrames / 2 >= ChainEffectUnit.scratchFrames)
        #expect(ChainEffectUnit.scratchChannels == 2)

        // Ring + staging, both channels. The analyzer adds ~70 KB on top;
        // the design's stated ceiling is 256 KB per armed tap.
        let ownBytes = (2 * InsertSpectrumTap.capacityFrames
                        + 2 * InsertSpectrumTap.maxDrainFrames)
            * MemoryLayout<Float>.stride
        #expect(ownBytes == 163_840)
        #expect(ownBytes <= 256 * 1024)
    }

    @Test("fresh tap: floor snapshot, zero counters, empty drain is a no-op")
    func freshTapIsHonestlyEmpty() {
        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        #expect(tap.framesWritten == 0)
        #expect(tap.droppedFrames == 0)
        let first = tap.drainAndSnapshot()
        #expect(first.bands.allSatisfy { $0 == Self.floorDB })
        #expect(first.levelDB == Self.floorDB)
        // A second empty drain must not move anything (no phantom drops).
        let second = tap.drainAndSnapshot()
        #expect(second == first)
        #expect(tap.framesWritten == 0)
        #expect(tap.droppedFrames == 0)
    }

    // MARK: - Fidelity (the comparability claim)

    @Test("fidelity POSITIVE: irregular chunks (37/512/1024/3000) drain to bands bit-identical to a one-shot analyzer")
    func fidelityBitIdenticalUnderIrregularChunking() {
        let frames = 48_000  // 1 s, and deliberately NOT a multiple of hopSize
        let (left, right) = Self.nonStationaryStereo(frames: frames)
        let reference = Self.referenceSnapshot(left: left, right: right,
                                               channelCount: 2)

        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: 3_000, channelCount: 2)
        let tapped = Self.feedChunked(tap: tap, feeder: feeder,
                                      left: left, right: right,
                                      chunkSizes: [37, 512, 1024, 3_000])

        // Premise first: a dropping tap sees a SHORTER stream, so the
        // comparison would be meaningless rather than merely wrong.
        #expect(tap.droppedFrames == 0)
        #expect(tap.framesWritten == UInt64(frames))

        // BIT-IDENTICAL bands — the whole point of reusing the analyzer.
        for band in 0..<Self.bandCount {
            #expect(tapped.bands[band] == reference.bands[band],
                    "band \(band): \(tapped.bands[band]) vs \(reference.bands[band])")
        }
        #expect(tapped.levelDB == reference.levelDB)
        #expect(tapped.peakDB == reference.peakDB)
        #expect(tapped.centroidHz == reference.centroidHz)

        // Stereo fields: TOLERANCE, never bit-equality — see the fixture's
        // comment. These are the fields that legitimately move in the last
        // ulp when the chunk boundaries change.
        #expect(abs(tapped.correlation - reference.correlation) <= 1e-5)
        #expect(abs(tapped.width - reference.width) <= 1e-5)
        #expect(abs(tapped.balance - reference.balance) <= 1e-5)
    }

    @Test("fidelity NEGATIVE: one dropped 1024-frame block breaks the same assertion")
    func fidelityDiscriminatorSeesADroppedBlock() {
        let frames = 48_000
        let (left, right) = Self.nonStationaryStereo(frames: frames)
        let reference = Self.referenceSnapshot(left: left, right: right,
                                               channelCount: 2)

        // Exactly the perturbation a broken ring produces: one hop-sized
        // block of the stream never reaches the analyzer.
        let gapStart = 20_000
        let gapCount = 1_024
        var holedLeft = Array(left[0..<gapStart])
        holedLeft.append(contentsOf: left[(gapStart + gapCount)...])
        var holedRight = Array(right[0..<gapStart])
        holedRight.append(contentsOf: right[(gapStart + gapCount)...])
        #expect(holedLeft.count == frames - gapCount)

        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: 3_000, channelCount: 2)
        let tapped = Self.feedChunked(tap: tap, feeder: feeder,
                                      left: holedLeft, right: holedRight,
                                      chunkSizes: [37, 512, 1024, 3_000])
        #expect(tap.droppedFrames == 0)

        // The POSITIVE leg's assertion must FAIL here, or it proves nothing.
        let bandsDiffer = (0..<Self.bandCount).contains {
            tapped.bands[$0] != reference.bands[$0]
        }
        #expect(bandsDiffer, "a dropped 1024-frame block left the bands identical")
    }

    @Test("channel rule: a 1-channel write reads exactly like duplicated stereo AND like processMix(channelCount: 1)")
    func monoWriteDuplicatesChannelZero() {
        let frames = 32_000
        let (mono, _) = Self.nonStationaryStereo(frames: frames)

        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: 3_000, channelCount: 1)
        let tapped = Self.feedChunked(tap: tap, feeder: feeder,
                                      left: mono, right: mono,
                                      chunkSizes: [37, 512, 1024, 3_000])
        #expect(tap.droppedFrames == 0)
        #expect(tap.framesWritten == UInt64(frames))

        // The gate's literal claim: duplicated stereo.
        let duplicated = Self.referenceSnapshot(left: mono, right: mono,
                                                channelCount: 2)
        // And the claim that MATTERS: duplication is not an invention, it is
        // `processMix`'s own mono rule (`channels[channelCount >= 2 ? 1 : 0]`),
        // so a mono insert reads the same as the analyzer's mono entry point.
        let asMono = Self.referenceSnapshot(left: mono, right: mono,
                                            channelCount: 1)
        for band in 0..<Self.bandCount {
            #expect(tapped.bands[band] == duplicated.bands[band], "dup band \(band)")
            #expect(tapped.bands[band] == asMono.bands[band], "mono band \(band)")
        }
        #expect(tapped.levelDB == duplicated.levelDB)
        #expect(tapped.levelDB == asMono.levelDB)
        // Mono is correlated with itself by construction: +1 exactly.
        #expect(tapped.correlation == 1)
        #expect(tapped.width == 0)
        #expect(tapped.balance == 0)
    }

    @Test("channel geometry: the SHORTER channel clamps the frame count, and a 3rd buffer is ignored — not skipped")
    func raggedAndExtraChannelsAreClamped() {
        // `write` takes ONE `frameCount` but TWO pointers. The per-channel
        // `mDataByteSize` clamp is the only thing between a ragged buffer list
        // and a read past channel 1's allocation ON THE RENDER THREAD, and
        // this is the only leg in the file that exercises it — every other
        // fixture stamps both channels identically, so deleting the clamp
        // would otherwise ship green.
        let staged = 512          // frames the buffer PHYSICALLY holds
        let declared = 256        // frames channel 1 DECLARES
        let chunks = 16
        let total = chunks * declared   // 4_096 == maxDrainFrames: one drain, no drops
        let (left, right) = Self.nonStationaryStereo(frames: 6_000)

        // --- RAGGED. Each write is handed `staged` frames of real data with
        // channel 1 stamped short; the tap must take `declared` from BOTH.
        // Advancing the offset by `declared` therefore makes the accepted
        // frames a CONTIGUOUS stream, so the result is comparable to a
        // one-shot analyzer over the same prefix — which pins not just HOW
        // MANY frames the clamp keeps but WHICH ones.
        let ragged = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let raggedFeeder = Feeder(capacity: staged, channelCount: 2)
        var offset = 0
        while offset < total {
            raggedFeeder.stage(left: left, right: right,
                               offset: offset, count: staged)
            raggedFeeder.restamp([staged, declared])
            ragged.write(buffers: raggedFeeder.list, frameCount: staged)
            offset += declared
        }
        // MIN, applied to BOTH channels: not `staged` (an overread), and not
        // `staged + declared` (two channels advancing independently, which
        // would desynchronize L from R while the mono bands still looked fine).
        #expect(ragged.framesWritten == UInt64(total))
        #expect(ragged.droppedFrames == 0)

        let raggedSnapshot = ragged.drainAndSnapshot()
        let raggedReference = Self.referenceSnapshot(
            left: Array(left[0..<total]), right: Array(right[0..<total]),
            channelCount: 2)
        for band in 0..<Self.bandCount {
            #expect(raggedSnapshot.bands[band] == raggedReference.bands[band],
                    "ragged band \(band)")
        }

        // --- EXTRA. A 3rd buffer is IGNORED, and its presence must not make
        // the tap skip the write: a skipped quantum is a gap in the sample
        // stream, and a gap corrupts every band after it.
        let extra = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let extraFeeder = Feeder(capacity: total, channelCount: 3)
        extraFeeder.stage(left: left, right: right, offset: 0, count: total)
        extraFeeder.fill(channel: 2, with: 0.9)   // loud DC the tap must not hear
        extra.write(buffers: extraFeeder.list, frameCount: total)
        #expect(extra.framesWritten == UInt64(total))

        let extraSnapshot = extra.drainAndSnapshot()
        for band in 0..<Self.bandCount {
            #expect(extraSnapshot.bands[band] == raggedReference.bands[band],
                    "3-channel band \(band)")
        }
    }

    // MARK: - Drop policy

    @Test("drop policy POSITIVE: 10 s of audio at a normal poll cadence drops nothing")
    func normalCadenceNeverDrops() {
        // A separate fixture from the fidelity legs ON PURPOSE: dropping
        // SHORTENS the stream the analyzer sees, so the two families of
        // assertion cannot share a fixture without one poisoning the other.
        let quantum = 512
        let quanta = 938  // 480_256 frames ≈ 10.0 s @ 48 kHz
        let chunk = Self.alignedTone(frames: quantum)

        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: quantum, channelCount: 2)
        feeder.stageRepeating(chunk, count: quantum)

        var snapshot = tap.analyzer.snapshot()
        for index in 0..<quanta {
            tap.write(buffers: feeder.list, frameCount: quantum)
            // ~46 fps: one poll every two 512-frame quanta (≈21 ms).
            if index % 2 == 1 { snapshot = tap.drainAndSnapshot() }
        }
        snapshot = tap.drainAndSnapshot()

        #expect(tap.droppedFrames == 0)
        #expect(tap.framesWritten == UInt64(quanta * quantum))
        // Positive counterpart: it also actually analyzed something.
        let peak = snapshot.bands.max()!
        #expect(peak > -40)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }

    @Test("drop policy NEGATIVE: a 40_000-frame stall drops exactly 35_904, then recovers")
    func stallDropsOldestAndRecovers() {
        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let stallFrames = 40_000
        let writeSize = 8_000  // 5 writes; a single write is clamped at 8_192

        // Fill with broadband noise so the recovery assertion below cannot be
        // satisfied by leftover stall content.
        var rng = LCG(state: 0xDEAD_BEEF)
        let noise = (0..<writeSize).map { _ in rng.next() * 0.4 }
        let stallFeeder = Feeder(capacity: writeSize, channelCount: 2)
        stallFeeder.stageRepeating(noise, count: writeSize)
        for _ in 0..<(stallFrames / writeSize) {
            tap.write(buffers: stallFeeder.list, frameCount: writeSize)
        }
        #expect(tap.framesWritten == UInt64(stallFrames))
        #expect(tap.droppedFrames == 0)  // nothing is dropped until a DRAIN

        _ = tap.drainAndSnapshot()
        // DROP OLDEST keeps the newest maxDrainFrames; everything older goes.
        #expect(tap.droppedFrames == UInt64(stallFrames
                                            - InsertSpectrumTap.maxDrainFrames))
        #expect(tap.droppedFrames == 35_904)

        // Recovery: ~1 s of a clean 750 Hz tone at a normal cadence. Asserting
        // the PEAK BAND rather than fitting a tolerance to a steady-state
        // level keeps this a real discriminator and not a flake.
        let quantum = 512
        let chunk = Self.alignedTone(frames: quantum)
        let feeder = Feeder(capacity: quantum, channelCount: 2)
        feeder.stageRepeating(chunk, count: quantum)
        var snapshot = tap.analyzer.snapshot()
        for index in 0..<94 {  // 48_128 frames ≈ 1 s
            tap.write(buffers: feeder.list, frameCount: quantum)
            if index % 2 == 1 { snapshot = tap.drainAndSnapshot() }
        }
        snapshot = tap.drainAndSnapshot()

        let peak = snapshot.bands.max()!
        #expect(peak > -40)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
        // Recovery costs no further drops.
        #expect(tap.droppedFrames == 35_904)
    }

    @Test("drop policy: the drain keeps the NEWEST frames — drop-OLDEST, not drop-newest")
    func dropsOldestNotNewest() {
        // The stall leg above pins the drop COUNT, which a drop-NEWEST
        // implementation would also satisfy — same arithmetic, opposite
        // meaning (a stalled meter would then display permanently stale
        // audio). This leg pins the DIRECTION: fill the ring with a low tone,
        // cap it with exactly `maxDrainFrames` of a high tone, and assert the
        // single drain hears the HIGH one.
        let quantum = 512
        let lowHz = 187.5   // 256 samples/period @ 48 kHz → 512 is 2 periods
        let highHz = 6_000.0  // 8 samples/period → 512 is 64 periods
        func alignedChunk(_ hz: Double) -> [Float] {
            (0..<quantum).map { 0.6 * Float(sin(2 * .pi * hz * Double($0) / Self.sampleRate)) }
        }

        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: quantum, channelCount: 2)

        feeder.stageRepeating(alignedChunk(lowHz), count: quantum)
        for _ in 0..<70 { tap.write(buffers: feeder.list, frameCount: quantum) }  // 35_840
        feeder.stageRepeating(alignedChunk(highHz), count: quantum)
        for _ in 0..<8 { tap.write(buffers: feeder.list, frameCount: quantum) }   // 4_096
        #expect(tap.framesWritten == 39_936)

        let snapshot = tap.drainAndSnapshot()
        #expect(tap.droppedFrames == 35_840)
        let peak = snapshot.bands.max()!
        #expect(peak > -40)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: highHz),
                "the drain consumed the OLDEST frames — that is drop-newest")
    }

    // MARK: - Tear defence

    @Test("tear defence: a staged block stomped mid-copy is discarded and counted, not consumed")
    func stompedStagedBlockIsDiscarded() {
        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let quantum = 2_048

        // Stage a LOUD block: 4_096 frames = two full analysis windows, so
        // consuming it would visibly move the bands off the floor. That is
        // what makes "discarded, not consumed" observable at all — a shorter
        // staged block would leave the analyzer on the floor either way and
        // the leg would pass vacuously.
        let loud = Self.alignedTone(frames: quantum, amplitude: 0.8)
        let loudFeeder = Feeder(capacity: quantum, channelCount: 2)
        loudFeeder.stageRepeating(loud, count: quantum)
        tap.write(buffers: loudFeeder.list, frameCount: quantum)
        tap.write(buffers: loudFeeder.list, frameCount: quantum)
        #expect(tap.framesWritten == 4_096)

        // The stomp: SILENCE, written from inside the drain's staging window.
        // `write` clamps one call at capacityFrames / 2, so pushing the write
        // index past readIndex + capacityFrames (16_384) takes several calls.
        let stompSize = 8_192
        let silentFeeder = Feeder(capacity: stompSize, channelCount: 2)
        silentFeeder.stageRepeating([Float](repeating: 0, count: stompSize),
                                    count: stompSize)
        var fired = false
        tap.onStagedForTesting = { [weak tap] in
            guard let tap, !fired else { return }
            fired = true
            for _ in 0..<3 {
                tap.write(buffers: silentFeeder.list, frameCount: stompSize)
            }
        }

        let before = tap.analyzer.snapshot()
        let after = tap.drainAndSnapshot()
        tap.onStagedForTesting = nil

        #expect(fired)
        // NOT CONSUMED: the analyzer never saw the staged block, so the
        // published reading is byte-identical to the previous one (still the
        // floor — a fresh analyzer). Had the block been fed, the 750 Hz band
        // would be tens of dB above the floor.
        #expect(after == before)
        #expect(after.bands.allSatisfy { $0 == Self.floorDB })
        // COUNTED: the whole suspect span (readIndex → the re-loaded write
        // index) is discarded, not merely the staged frames.
        #expect(tap.framesWritten == 4_096 + UInt64(3 * stompSize))
        #expect(tap.droppedFrames == 28_672)

        // AND NOT WEDGED: the very next normal drain works.
        tap.write(buffers: loudFeeder.list, frameCount: quantum)
        tap.write(buffers: loudFeeder.list, frameCount: quantum)
        let recovered = tap.drainAndSnapshot()
        #expect(tap.droppedFrames == 28_672)  // no further drops
        #expect(recovered.bands.max()! > -40)
    }

    @Test("tear defence BOUNDARY: a span of exactly capacityFrames is CONSUMED, capacityFrames + 1 is DISCARDED")
    func tearThresholdIsPinnedFromBothSides() {
        // The tear threshold must be pinned from BOTH sides, and the leg above
        // only pins one. A LOOSENED (or deleted) check lets a torn block
        // through — that one catches it. A TIGHTENED check is invisible there:
        // it discards VALID audio and inflates `droppedFrames`, and because
        // `droppedFrames == 0` is a PREMISE of every fidelity fixture in this
        // file, such a regression would surface as baffling failures in
        // unrelated legs instead of here. MEASURED: before this test existed,
        // `> capacityFrames / 4` — wrong by 4× in the conservative direction —
        // passed the entire suite green.
        //
        // The derivation, which is exact: slot `readIndex & mask` is first
        // re-used by frame index `readIndex + capacityFrames`, and the
        // producer has written up to `w2 - 1`. So the staged span is intact
        // iff `w2 - readIndex <= capacityFrames`. EXACTLY `capacityFrames` is
        // the last SAFE value, not the first unsafe one.
        let staged = InsertSpectrumTap.maxDrainFrames    // 4_096
        let capacity = InsertSpectrumTap.capacityFrames  // 16_384

        /// Stages `staged` loud frames, then advances the producer to EXACTLY
        /// `target` from inside the staging window.
        func run(advanceTo target: Int)
            -> (tap: InsertSpectrumTap,
                before: MasterAnalysisSnapshot, after: MasterAnalysisSnapshot) {
            let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
            let loud = Self.alignedTone(frames: staged, amplitude: 0.8)
            let loudFeeder = Feeder(capacity: staged, channelCount: 2)
            loudFeeder.stageRepeating(loud, count: staged)
            tap.write(buffers: loudFeeder.list, frameCount: staged)
            #expect(tap.framesWritten == UInt64(staged))

            // `write` clamps one call to capacityFrames / 2, so reaching the
            // target takes more than one. The payload is SILENCE, so a span
            // that was wrongly consumed could never be mistaken for the loud
            // staged block.
            let chunk = capacity / 2
            let silentFeeder = Feeder(capacity: chunk, channelCount: 2)
            silentFeeder.stageRepeating([Float](repeating: 0, count: chunk),
                                        count: chunk)
            var fired = false
            tap.onStagedForTesting = { [weak tap] in
                guard let tap, !fired else { return }
                fired = true
                var remaining = target - staged
                while remaining > 0 {
                    let count = min(remaining, chunk)
                    silentFeeder.restamp([count, count])
                    tap.write(buffers: silentFeeder.list, frameCount: count)
                    remaining -= count
                }
            }
            let before = tap.analyzer.snapshot()
            let after = tap.drainAndSnapshot()
            tap.onStagedForTesting = nil
            #expect(fired)
            // The whole pin depends on landing on the target EXACTLY.
            #expect(tap.framesWritten == UInt64(target))
            return (tap, before, after)
        }

        // --- LEG A — exactly `capacityFrames`: the last SAFE span. Slot 0 is
        // re-used only by frame index `capacityFrames`, and the producer
        // stopped at `capacityFrames - 1`, so the staged copy is intact.
        // CONSUME it. THIS IS THE LEG THAT REDDENS ON ANY TIGHTENING.
        let safe = run(advanceTo: capacity)
        #expect(safe.tap.droppedFrames == 0,
                "a VALID span was discarded as torn — the threshold is too tight")
        #expect(safe.after != safe.before, "the staged block was not consumed")
        let peak = safe.after.bands.max()!
        #expect(peak > -40)
        #expect(safe.after.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))

        // --- LEG B — exactly `capacityFrames + 1`: the first UNSAFE span.
        // Frame index `capacityFrames` lands in slot 0 and stomps the first
        // staged frame. DISCARD and count it.
        // THIS IS THE LEG THAT REDDENS ON ANY LOOSENING.
        let torn = run(advanceTo: capacity + 1)
        #expect(torn.tap.droppedFrames == UInt64(capacity + 1),
                "a TORN span was consumed — the threshold is too loose")
        #expect(torn.after == torn.before)
        #expect(torn.after.bands.allSatisfy { $0 == Self.floorDB })
    }

    // MARK: - Allocation (with its anti-vacuity partner in the SAME test)

    @Test("write() allocates nothing across 10_000 quanta — retained AND transient — and the ring advanced while it didn't")
    func writeIsAllocationFreeAndActuallyRan() {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — the allocation probe cannot run. Treat this as a FAILURE, not a skip.")
            return
        }

        let quantum = 512
        let windows = 25
        let perWindow = 400  // 25 × 400 = 10_000 quanta
        let chunk = Self.alignedTone(frames: quantum)

        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: quantum, channelCount: 2)
        feeder.stageRepeating(chunk, count: quantum)

        // THE MEASURED LOOPS ARE `while`, NOT `for … in 0..<n`, AND MUST STAY
        // THAT WAY. Measured here: at `-Onone` (which is how `swift test`
        // builds) a `for _ in 0..<400 { }` loop with an EMPTY BODY raises
        // exactly 800 malloc/free events — two per iteration, from the
        // Range iteration itself — while the identical `while` loop raises
        // ZERO. Tidying these back into `for … in` would redden the leg with
        // the harness's own allocations and invite someone to "fix" it by
        // loosening the threshold, at which point it stops seeing `write`.
        var eventCounts: [Int] = []
        eventCounts.reserveCapacity(windows)
        var window = 0
        while window < windows {
            let events = Self.mallocEvents(slot: slot) {
                var call = 0
                while call < perWindow {
                    tap.write(buffers: feeder.list, frameCount: quantum)
                    call &+= 1
                }
            }
            eventCounts.append(events)
            window &+= 1
        }

        // The harness's own discriminator: an identically-shaped loop that
        // DOES allocate — and RETAINS every allocation (never freed inside
        // the measured window) — must still be seen by the logger. Without
        // it, a toolchain change that re-routed small allocations away from
        // libmalloc's logged path, or a `malloc_logger` that silently stopped
        // firing, would turn the leg above into a permanent green that
        // observes nothing. Retaining (not just churning) is the deliberate
        // choice here: it is the shape that used to need `blocks_in_use` (see
        // the ALLOCATION PROBE note at the top of this file) and proves the
        // logger alone covers that job too.
        var sink: [[Float]] = []
        sink.reserveCapacity(windows * perWindow)  // outside the measured window
        var controlEvents: [Int] = []
        var controlWindow = 0
        while controlWindow < windows {
            let events = Self.mallocEvents(slot: slot) {
                var call = 0
                while call < perWindow {
                    sink.append([Float](repeating: 0, count: 8))
                    call &+= 1
                }
            }
            controlEvents.append(events)
            controlWindow &+= 1
        }
        #expect(controlEvents.min()! >= perWindow,
                "malloc_logger did not fire on a RETAINED allocation — the probe is vacuous")
        #expect(sink.count == windows * perWindow)

        // THE STRICT ONE: zero malloc/free events on this thread, at all.
        #expect(eventCounts.max()! == 0,
                "write() allocated; per-window malloc/free events: \(eventCounts)")

        // ANTI-VACUITY: a tap that allocated nothing BECAUSE IT DID NOTHING
        // must not pass. Same test, not a sibling — a sibling can be deleted
        // or skipped independently and the pairing silently lost.
        #expect(tap.framesWritten == UInt64(windows * perWindow * quantum))

        // …and the drained samples are real: settle at a normal cadence and
        // land the peak on the injected tone's band.
        var snapshot = tap.analyzer.snapshot()
        for index in 0..<48 {
            tap.write(buffers: feeder.list, frameCount: quantum)
            if index % 2 == 1 { snapshot = tap.drainAndSnapshot() }
        }
        snapshot = tap.drainAndSnapshot()
        let peak = snapshot.bands.max()!
        #expect(peak > -40)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }

    // MARK: - Poisoned input

    @Test("NaN/Inf input: nothing non-finite ever reaches a published field")
    func poisonedInputPublishesFiniteFields() {
        let quantum = 512
        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: quantum, channelCount: 2)

        let clean = Self.alignedTone(frames: quantum)
        var poisoned = clean
        poisoned[10] = .nan
        poisoned[200] = .infinity
        poisoned[300] = -.infinity
        poisoned[301] = .greatestFiniteMagnitude

        var snapshot = tap.analyzer.snapshot()
        for index in 0..<96 {
            let source = index % 3 == 0 ? poisoned : clean
            feeder.stageRepeating(source, count: quantum)
            tap.write(buffers: feeder.list, frameCount: quantum)
            if index % 2 == 1 { snapshot = tap.drainAndSnapshot() }
        }
        snapshot = tap.drainAndSnapshot()

        // The tap only COPIES; the analyzer's frame-skip guards do the work.
        // This leg pins that the copy path cannot defeat them.
        for band in snapshot.bands {
            #expect(band.isFinite)
            #expect(band >= Self.floorDB)
        }
        #expect(snapshot.levelDB.isFinite)
        #expect(snapshot.peakDB.isFinite)
        #expect(snapshot.centroidHz.isFinite)
        #expect(snapshot.flux.isFinite)
        #expect(snapshot.correlation.isFinite)
        #expect(snapshot.width.isFinite)
        #expect(snapshot.balance.isFinite)
        #expect(tap.droppedFrames == 0)
    }

    // MARK: - Ring mechanics

    @Test("ring wraps: a stream many laps long stays in order and bit-exact")
    func ringWrapsWithoutReordering() {
        // 7.3 laps of the 16_384-frame ring, chunk sizes chosen to land the
        // wrap split inside a write AND inside a drain.
        let frames = 120_000
        let (left, right) = Self.nonStationaryStereo(frames: frames, seed: 0xA11CE)
        let reference = Self.referenceSnapshot(left: left, right: right,
                                               channelCount: 2)

        let tap = InsertSpectrumTap(sampleRate: Self.sampleRate)
        let feeder = Feeder(capacity: 4_000, channelCount: 2)
        let tapped = Self.feedChunked(tap: tap, feeder: feeder,
                                      left: left, right: right,
                                      chunkSizes: [4_000, 1, 3_331, 777])

        #expect(tap.droppedFrames == 0)
        #expect(tap.framesWritten == UInt64(frames))
        #expect(tap.framesWritten > UInt64(7 * InsertSpectrumTap.capacityFrames))
        for band in 0..<Self.bandCount {
            #expect(tapped.bands[band] == reference.bands[band], "band \(band)")
        }
        #expect(abs(tapped.correlation - reference.correlation) <= 1e-5)
        #expect(abs(tapped.width - reference.width) <= 1e-5)
        #expect(abs(tapped.balance - reference.balance) <= 1e-5)
    }
}
