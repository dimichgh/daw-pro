import AVFAudio
import Darwin
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// Gate for m23-r2a: the per-insert spectrum tap wired INTO the chain walk,
/// plus the arm plumbing that keeps it alive across chain edits and graph
/// rebuilds. `InsertSpectrumTap` itself is r1's gate
/// (`InsertSpectrumTapTests`) and is consumed here unchanged; the coverage
/// matrix (per strip type, the full arm lifecycle, bypass honesty, the
/// budget legs) is r2b and is deliberately NOT here.
///
/// The load-bearing claims, and why each needs its own leg:
///
///  1. **An armed insert cannot change a rendered sample.** `write` only
///     COPIES, so the armed and disarmed walks must be BYTE-identical — in
///     both directions (arming leaves no residue, disarming leaves none
///     either). This is the discriminator the null-era SHA pin
///     (`ChainClickPolishTests:524`) cannot provide on its own: that pin
///     renders a chain with nothing armed, so it would stay green against a
///     tap that never ran.
///  2. **…which is exactly why byte-identity needs TWO liveness partners.**
///     "identical because the tap never ran" is the failure this cycle exists
///     to prevent. `framesWritten` advancing proves the PRODUCER ran; non-floor
///     drained bands prove the CONSUMER path works. Neither implies the other:
///     a ring that advances while the drain is broken yields floor bands, and a
///     tap reading a stale prior fill yields non-floor bands without advancing.
///  3. **The hook is POST, not PRE.** Pinned by measurement, not by reading:
///     with a −18 dB cut at 3 kHz in the tapped insert, the tapped 3 kHz band
///     must sit ≈ the cut depth below a dry-fed reference. A PRE tap reads the
///     insert's INPUT and the delta collapses to ≈ 0.
///  4. **Arming never republishes the chain.** Snapshot AND unit identity
///     survive arm → sync → param-edit sync → disarm → re-arm. The param edit
///     matters: `sync`'s `guard descriptors != lastDescriptors` early-outs the
///     whole pass, so a leg that only re-syncs identical descriptors never
///     reaches the `newIdentity != oldIdentity` republish decision at all and
///     would pass against a chain that DOES republish on arm.
///  5. **Zero heap allocation on the render path**, measured with the
///     `malloc_logger` probe — NOT `blocks_in_use`, which is a LEVEL and is
///     mutant-proven blind to allocate-then-free. That transient class (a
///     dynamic cast, a boxed closure, an ObjC bridge) is precisely what chain
///     integration can introduce.
///
/// `.serialized` because the allocation leg installs a process-global malloc
/// hook; it filters on the calling thread, but a parallel sibling running
/// inside the same window is still noise nobody needs.
@MainActor
@Suite("Per-insert spectrum — chain integration + arm plumbing (m23-r2a)", .serialized)
struct InsertSpectrumChainTests {

    private static let rate = 48_000.0
    private static let quantum = 512
    private static let floorDB = MasterAnalysisSnapshot.floorDB
    /// Drain cadence in quanta. 4 × 512 = 2_048 frames, half of
    /// `InsertSpectrumTap.maxDrainFrames`, so the drop-oldest path is
    /// unreachable and every fidelity leg can assert `droppedFrames == 0` as
    /// its premise instead of ignoring the counter (r1's rule).
    private static let drainEveryQuanta = 4

    // MARK: - Allocation probe (the r1 implementation, verbatim)
    //
    // `malloc_logger` is libmalloc's hook behind `MallocStackLogging`/`leaks`,
    // resolved with `dlsym` so no C shim is needed. It fires on EVERY malloc
    // and free, so a transient allocation is counted twice rather than
    // cancelling out — which is the whole point here. Unavailable is a
    // FAILURE, never a skip: a silently absent allocation probe is exactly
    // the vacuity the leg exists to prevent.

    private typealias MallocLoggerFn =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Heap cells, NOT Swift stored properties: the hook runs INSIDE malloc
    /// with its locks held, so it must never allocate and never trip a lazy
    /// global initializer.
    private nonisolated(unsafe) static let eventCount =
        UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let watchedThread =
        UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private static let eventHook: MallocLoggerFn = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)  // no allocation, safe under malloc
        if tid == InsertSpectrumChainTests.watchedThread.pointee {
            InsertSpectrumChainTests.eventCount.pointee &+= 1
        }
    }

    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
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

    // MARK: - Fixtures

    /// A period-aligned tone: at 48 kHz, 3 kHz is 16 samples/period and 750 Hz
    /// is 64, so a 512-frame quantum is a whole number of periods either way
    /// and a repeated chunk is genuinely continuous (no chop artefacts).
    private static func tone(hz: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * .pi * hz * Double(index) / rate))
        }
    }

    /// Owns the scratch and the `AudioBufferList` a chain walk processes IN
    /// PLACE. Sized once; `stage` only copies, so measured loops never
    /// allocate.
    private final class Scratch {
        let list: UnsafeMutableAudioBufferListPointer
        private let storage: UnsafeMutablePointer<Float>
        let capacity: Int
        let channels: Int

        init(capacity: Int, channels: Int = 2) {
            self.capacity = capacity
            self.channels = channels
            storage = .allocate(capacity: capacity * channels)
            storage.initialize(repeating: 0, count: capacity * channels)
            list = AudioBufferList.allocate(maximumBuffers: channels)
            for channel in 0..<channels {
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

        var raw: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }

        /// Loads `count` frames from `source` at `offset` into EVERY channel.
        func stage(_ source: [Float], offset: Int, count: Int) {
            precondition(count <= capacity)
            source.withUnsafeBufferPointer { input in
                for channel in 0..<channels {
                    (storage + channel * capacity)
                        .update(from: input.baseAddress! + offset, count: count)
                }
            }
        }

        func read(channel: Int, count: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: storage + channel * capacity, count: count))
        }
    }

    private func makeChain(_ descriptors: [EffectDescriptor])
        -> (processor: EffectChainProcessor, state: EffectChainState) {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        state.sync(descriptors: descriptors, sampleRate: Self.rate)
        return (processor, state)
    }

    /// The fixture chain: an ACTIVE delay (so tails cross quantum boundaries
    /// and any per-quantum divergence compounds), an ACTIVE gain, and a
    /// STEADILY BYPASSED saturator — the same shape the null-era SHA pin
    /// renders, so the byte-identity legs exercise the active path, the
    /// bypass-skip path, and cross-quantum state at once.
    private func fixtureDescriptors(delayID: UUID, gainID: UUID, bypassedID: UUID,
                                    gainLinear: Double = 1.0) -> [EffectDescriptor] {
        [
            EffectDescriptor(id: delayID, kind: .delay,
                             delay: DelayParams(timeMs: 25, feedback: 0.4, mix: 0.3)),
            EffectDescriptor(id: gainID, kind: .gain,
                             gain: GainParams(gainLinear: gainLinear)),
            EffectDescriptor(id: bypassedID, kind: .saturator, isBypassed: true),
        ]
    }

    /// Renders `quanta` quanta of `input` through the chain, returning the
    /// left channel's BIT PATTERNS (so ±0 and NaN compare honestly, unlike
    /// `Float` equality). `onQuantum` runs after each walk — how the mid-render
    /// arm/disarm legs toggle without a second render loop.
    private func renderBits(processor: EffectChainProcessor, scratch: Scratch,
                            input: [Float], quanta: Int,
                            onQuantum: ((Int) -> Void)? = nil) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(quanta * Self.quantum)
        for index in 0..<quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            out.append(contentsOf: scratch.read(channel: 0, count: Self.quantum)
                .map(\.bitPattern))
            onQuantum?(index)
        }
        return out
    }

    // MARK: - The discriminator: armed ≡ disarmed, in both directions

    @Test("an armed insert changes no rendered sample — byte-identical both directions, and the tap demonstrably ran")
    func armedWalkIsByteIdenticalAndAlive() throws {
        let delayID = UUID(), gainID = UUID(), bypassedID = UUID()
        let descriptors = fixtureDescriptors(delayID: delayID, gainID: gainID,
                                             bypassedID: bypassedID)
        let quanta = 40  // 20_480 frames = 426 ms @ 48 kHz — well past the
                         // analyzer's 2_048-frame warm-up (the m3c premise).
        let input = Self.tone(hz: 750, frames: quanta * Self.quantum)
        let scratch = Scratch(capacity: Self.quantum)

        // A — the reference: a chain that is NEVER armed. Every run gets its
        // OWN chain: units carry delay tails across quanta, so a second render
        // on the same units would start inside the first run's tail and
        // diverge for reasons that have nothing to do with the tap.
        let reference = renderBits(processor: makeChain(descriptors).processor,
                                   scratch: scratch, input: input, quanta: quanta)

        // B — armed for the WHOLE render.
        let armedChain = makeChain(descriptors)
        #expect(armedChain.state.setAnalysisArmed(true, forEffect: gainID))
        let tap = try #require(armedChain.state.analysisTap(forEffect: gainID))
        var snapshots: [MasterAnalysisSnapshot] = []
        let armed = renderBits(processor: armedChain.processor, scratch: scratch,
                               input: input, quanta: quanta) { index in
            if index % Self.drainEveryQuanta == Self.drainEveryQuanta - 1 {
                snapshots.append(tap.drainAndSnapshot())
            }
        }
        #expect(armed == reference, "an armed insert altered the rendered signal")

        // LIVENESS (i) — the PRODUCER ran: the ring's monotonic write index
        // advanced by exactly the rendered frame count.
        #expect(tap.framesWritten == UInt64(quanta * Self.quantum),
                "the tap never saw the walk — byte-identity would then be vacuous")
        // LIVENESS (ii) — the CONSUMER path works: drained bands left the
        // floor, and on the injected tone's own band. Independent of (i): a
        // broken drain advances the ring just as happily.
        #expect(tap.droppedFrames == 0)
        let final = try #require(snapshots.last)
        let peak = try #require(final.bands.max())
        #expect(peak > Self.floorDB + 20,
                "drained bands sat on the floor — the consumer path is dead")
        #expect(final.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))

        // C — the OTHER direction: armed, then disarmed before a sample is
        // rendered. A disarmed slot must leave no residue at all.
        let disarmedChain = makeChain(descriptors)
        #expect(disarmedChain.state.setAnalysisArmed(true, forEffect: gainID))
        #expect(disarmedChain.state.setAnalysisArmed(false, forEffect: gainID))
        #expect(disarmedChain.state.armedEffectIDs.isEmpty)
        let afterDisarm = renderBits(processor: disarmedChain.processor,
                                     scratch: scratch, input: input, quanta: quanta)
        #expect(afterDisarm == reference,
                "a disarmed insert left residue in the walk")

        // D — both directions WITHIN one render: arm at quantum 10, disarm at
        // quantum 25. The transitions themselves must be sample-transparent.
        let toggledChain = makeChain(descriptors)
        var toggledTap: InsertSpectrumTap?
        let toggled = renderBits(processor: toggledChain.processor, scratch: scratch,
                                 input: input, quanta: quanta) { index in
            if index == 10 {
                #expect(toggledChain.state.setAnalysisArmed(true, forEffect: gainID))
                toggledTap = toggledChain.state.analysisTap(forEffect: gainID)
            }
            if index == 25 {
                #expect(toggledChain.state.setAnalysisArmed(false, forEffect: gainID))
            }
        }
        #expect(toggled == reference, "arming mid-render moved a sample")
        // …and it really was armed for that window: quanta 11...25 inclusive.
        let liveTap = try #require(toggledTap)
        #expect(liveTap.framesWritten == UInt64(15 * Self.quantum))
    }

    // MARK: - Placement: the hook is POST this insert, not PRE

    @Test("the tapped 3 kHz band sits ≈ the insert's cut depth below a dry reference (a PRE tap would read ≈ 0)")
    func tapIsPostEffectNotPre() throws {
        let cutDb = -18.0
        let eqID = UUID()
        let descriptors = [
            EffectDescriptor(id: eqID, kind: .eq,
                             eq: EQParams(peak2Freq: 3_000, peak2GainDb: cutDb,
                                          peak2Q: 0.9)),
        ]
        let quanta = 40
        let input = Self.tone(hz: 3_000, frames: quanta * Self.quantum)
        let scratch = Scratch(capacity: Self.quantum)

        let chain = makeChain(descriptors)
        #expect(chain.state.setAnalysisArmed(true, forEffect: eqID))
        let tapped = try #require(chain.state.analysisTap(forEffect: eqID))

        // The DRY reference is a bare tap fed the same samples on the same
        // cadence — same class, same analyzer, so the only difference between
        // the two readings is the EQ the walk applied before the hook.
        let dry = InsertSpectrumTap(sampleRate: Self.rate)
        let dryFeed = Scratch(capacity: Self.quantum)

        var tappedSnapshot = MasterAnalysisSnapshot.floor
        var drySnapshot = MasterAnalysisSnapshot.floor
        for index in 0..<quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            chain.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            dryFeed.stage(input, offset: index * Self.quantum, count: Self.quantum)
            dry.write(buffers: dryFeed.list, frameCount: Self.quantum)
            if index % Self.drainEveryQuanta == Self.drainEveryQuanta - 1 {
                tappedSnapshot = tapped.drainAndSnapshot()
                drySnapshot = dry.drainAndSnapshot()
            }
        }

        #expect(tapped.droppedFrames == 0)
        #expect(dry.droppedFrames == 0)
        let band = MasterMixAnalyzer.bandIndex(containing: 3_000)
        let dryBand = Double(drySnapshot.bands[band])
        let postBand = Double(tappedSnapshot.bands[band])
        let delta = dryBand - postBand
        print("[measured] m23-r2a post-tap 3 kHz band: dry \(dryBand) dB, "
              + "post \(postBand) dB, delta \(delta) dB (cut \(cutDb) dB)")
        // The tone sits at the band centre and the peaking filter's full cut
        // lands at its own centre frequency, so the fold cannot dilute this
        // much — but the leg's job is discriminating POST from PRE, and a PRE
        // tap reads the insert's INPUT (delta ≈ 0). A generous window keeps it
        // a placement pin rather than an EQ-response pin (that is
        // `EQFilterResponse`'s null-pinned job, not this file's).
        #expect(delta > 8, "the tap is reading the insert's INPUT — the hook is PRE")
        #expect(abs(delta - -cutDb) < 4,
                "the tapped band does not track the insert's cut depth")
        // Both readings peak on the injected tone's band: the dry one because
        // that is where the tone is, the tapped one because a −18 dB cut does
        // not push a 0.5-amplitude tone below its neighbours (which are floor).
        #expect(drySnapshot.bands.firstIndex(of: Float(dryBand)) == band)
    }

    // MARK: - Arming never republishes the chain

    @Test("arming, disarming and re-arming never republish the snapshot and never rebuild the unit")
    func armingNeverRepublishes() throws {
        let delayID = UUID(), gainID = UUID(), bypassedID = UUID()
        let descriptors = fixtureDescriptors(delayID: delayID, gainID: gainID,
                                             bypassedID: bypassedID)
        let chain = makeChain(descriptors)
        let snapshot0 = try #require(chain.processor.currentSnapshot)
        let unit0 = try #require(chain.state.unit(forEffect: gainID))
        #expect(unit0.publishedTap == nil)

        #expect(chain.state.setAnalysisArmed(true, forEffect: gainID))
        let tap0 = try #require(chain.state.analysisTap(forEffect: gainID))
        #expect(unit0.publishedTap === tap0)
        #expect(chain.processor.currentSnapshot === snapshot0,
                "arming republished the chain")
        #expect(chain.state.unit(forEffect: gainID) === unit0)

        // A re-sync with IDENTICAL descriptors takes `sync`'s early-out at
        // `guard descriptors != lastDescriptors` and never reaches the
        // republish decision — necessary, but NOT sufficient on its own.
        chain.state.sync(descriptors: descriptors, sampleRate: Self.rate)
        #expect(chain.processor.currentSnapshot === snapshot0)
        #expect(chain.state.analysisTap(forEffect: gainID) === tap0)

        // THE LEG THAT MATTERS: a real param edit walks the whole pass, builds
        // both identity lists and evaluates `newIdentity != oldIdentity`. If
        // arm state ever leaks into that decision, THIS is where it shows.
        let edited = fixtureDescriptors(delayID: delayID, gainID: gainID,
                                        bypassedID: bypassedID, gainLinear: 0.5)
        chain.state.sync(descriptors: edited, sampleRate: Self.rate)
        #expect(chain.processor.currentSnapshot === snapshot0,
                "a param edit on an ARMED chain republished the snapshot")
        #expect(chain.state.unit(forEffect: gainID) === unit0,
                "a param edit on an ARMED chain rebuilt the unit")
        #expect(chain.state.analysisTap(forEffect: gainID) === tap0,
                "the sync re-application replaced a live tap instead of keeping it")
        #expect(unit0.publishedTap === tap0)

        // Disarm → re-arm: a NEW tap (the old one is gone, not reused), the
        // SAME unit, the SAME snapshot. This is what makes opening and closing
        // an effect editor free of DSP resets and clicks.
        #expect(chain.state.setAnalysisArmed(false, forEffect: gainID))
        #expect(unit0.publishedTap == nil)
        #expect(chain.state.setAnalysisArmed(true, forEffect: gainID))
        let tap1 = try #require(chain.state.analysisTap(forEffect: gainID))
        #expect(tap1 !== tap0)
        #expect(chain.processor.currentSnapshot === snapshot0)
        #expect(chain.state.unit(forEffect: gainID) === unit0)

        // Idempotence: a redundant re-arm keeps the SAME tap, so a
        // re-application pass can never reset a live measurement's ballistics.
        #expect(chain.state.setAnalysisArmed(true, forEffect: gainID))
        #expect(chain.state.analysisTap(forEffect: gainID) === tap1)

        // An arm for an effect this chain has never seen is REFUSED, not held
        // as a phantom that would occupy an engine tap slot forever.
        #expect(chain.state.setAnalysisArmed(true, forEffect: UUID()) == false)
        #expect(chain.state.armedEffectIDs == [gainID])
    }

    // MARK: - Allocation on the render path

    @Test("an armed chain walk allocates nothing across 10_000 quanta — transient AND retained — and the tap ran")
    func armedWalkIsAllocationFree() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — the transient-allocation probe cannot run, and this leg's entire value is seeing allocate-then-free. Treat this as a FAILURE, not a skip.")
            return
        }

        let gainID = UUID()
        // Unity gain: the walk is arithmetically an identity, so ONE staged
        // chunk can be re-processed 10_000 times without decaying to silence —
        // which is what keeps `stage` (and its bounds math) outside the
        // measured window while the positive counterpart below stays real.
        let descriptors = [
            EffectDescriptor(id: gainID, kind: .gain,
                             gain: GainParams(gainLinear: 1.0)),
        ]
        let chain = makeChain(descriptors)
        #expect(chain.state.setAnalysisArmed(true, forEffect: gainID))
        let tap = try #require(chain.state.analysisTap(forEffect: gainID))

        let scratch = Scratch(capacity: Self.quantum)
        scratch.stage(Self.tone(hz: 750, frames: Self.quantum), offset: 0,
                      count: Self.quantum)

        let windows = 25
        let perWindow = 400  // 25 × 400 = 10_000 quanta
        // THE MEASURED LOOPS ARE `while`, NOT `for … in 0..<n`, AND MUST STAY
        // THAT WAY: at `-Onone` (how `swift test` builds) an EMPTY-bodied
        // `for _ in 0..<400` raises ~800 malloc/free events from Range
        // iteration itself, while the identical `while` raises zero. Tidying
        // these into `for … in` would redden the leg with the harness's own
        // allocations and invite someone to "fix" it by loosening the
        // threshold, at which point it stops seeing the walk.
        var eventCounts: [Int] = []
        eventCounts.reserveCapacity(windows)
        var window = 0
        while window < windows {
            let events = Self.mallocEvents(slot: slot) {
                var call = 0
                while call < perWindow {
                    chain.processor.process(bufferList: scratch.raw,
                                            frameCount: Self.quantum)
                    call &+= 1
                }
            }
            eventCounts.append(events)
            window &+= 1
        }

        // The DISARMED control on the identical chain shape. It is not a
        // baseline to subtract — both must be ABSOLUTELY zero — but it says
        // which side a regression came from, and it is what makes the armed
        // reading meaningful rather than a delta that would silently absorb a
        // future allocation in the walk itself. (The walk's own loop is a
        // `while` for exactly this reason: at `-Onone` the `Range` form raised
        // 2 malloc/free events per unit per quantum, measured here at r2a.)
        let controlChain = makeChain(descriptors)
        controlChain.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
        var disarmedCounts: [Int] = []
        disarmedCounts.reserveCapacity(windows)
        var disarmedWindow = 0
        while disarmedWindow < windows {
            let events = Self.mallocEvents(slot: slot) {
                var call = 0
                while call < perWindow {
                    controlChain.processor.process(bufferList: scratch.raw,
                                                   frameCount: Self.quantum)
                    call &+= 1
                }
            }
            disarmedCounts.append(events)
            disarmedWindow &+= 1
        }
        #expect(controlChain.state.armedEffectIDs.isEmpty)
        #expect(disarmedCounts.max() == 0,
                "the DISARMED chain walk allocated; per-window events: \(disarmedCounts)")

        // Anti-vacuity for the PROBE: an identically shaped loop that DOES
        // allocate must be seen. Without it, a `malloc_logger` that stopped
        // firing would turn the leg above into a permanent green observing
        // nothing.
        var sink: [[Float]] = []
        sink.reserveCapacity(perWindow)  // outside the measured window
        let controlEvents = Self.mallocEvents(slot: slot) {
            var call = 0
            while call < perWindow {
                sink.append([Float](repeating: 0, count: 8))
                call &+= 1
            }
        }
        #expect(controlEvents >= perWindow,
                "malloc_logger did not fire — this leg is vacuous")
        #expect(sink.count == perWindow)

        #expect(eventCounts.max() == 0,
                "the armed chain walk allocated; per-window malloc/free events: \(eventCounts)")

        // Anti-vacuity for the SUBJECT, in the SAME test (a sibling could be
        // skipped and the pairing silently lost): a walk that allocated
        // nothing BECAUSE THE TAP DID NOTHING must not pass.
        #expect(tap.framesWritten == UInt64(windows * perWindow * Self.quantum))
        // Drop-oldest is expected here (10_000 quanta, never drained), so this
        // leg asserts only that the surviving newest block is REAL audio.
        let snapshot = tap.drainAndSnapshot()
        let peak = try #require(snapshot.bands.max())
        #expect(peak > Self.floorDB + 20)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }

    // MARK: - The re-application point (the plumbing, not r2b's lifecycle)

    @Test("the graph re-applies its arm mirror at the tail of every parameter pass, onto a chain state that had none")
    func graphReappliesArmsAtParameterPassTail() throws {
        let effectID = UUID()
        let track = Track(name: "SRC", kind: .audio,
                          effects: [EffectDescriptor(id: effectID, kind: .eq,
                                                     eq: EQParams())])
        let graph = PlaybackGraph(engine: AVAudioEngine())
        _ = graph.reconcile(tracks: [track])
        graph.applyParameters(tracks: [track])
        let state = try #require(graph.effectChainState(forTrack: track.id))
        #expect(state.armedEffectIDs.isEmpty)

        // The intent is assigned here in the SHAPE `AudioEngine.wireGraphHooks`
        // delivers it to a FRESH graph — a mirror assignment, strips already
        // reconciled, nothing armed on them yet. This hand-assignment
        // SIMULATES that delivery and cannot prove the install happens; that
        // is `armSurvivesAWholeGraphRebuild`'s job, and it is the only leg
        // here that reddens when the `wireGraphHooks` assignment is deleted.
        // What THIS leg pins is the graph-side half: nothing happens until a
        // parameter pass runs — that is the re-application point.
        let key = InsertAnalysisKey(trackID: track.id, effectID: effectID)
        graph.analysisArms = [key]
        #expect(state.armedEffectIDs.isEmpty,
                "the mirror armed something without a parameter pass")
        graph.applyParameters(tracks: [track])
        #expect(state.armedEffectIDs == [effectID],
                "the parameter-pass tail did not re-apply the arm mirror")
        let tap = try #require(state.analysisTap(forEffect: effectID))

        // Idempotent across further passes: the SAME tap survives, so a
        // re-application can never reset a live measurement.
        graph.applyParameters(tracks: [track])
        #expect(state.analysisTap(forEffect: effectID) === tap)
        #expect(graph.hasAnalysisTarget(key))
        #expect(graph.insertAnalysis(forInsert: key) != nil)

        // An arm whose effect leaves the chain is DROPPED by `sync`, so it can
        // never keep occupying one of the engine's tap slots.
        let stripped = Track(id: track.id, name: "SRC", kind: .audio)
        graph.applyParameters(tracks: [stripped])
        #expect(state.armedEffectIDs.isEmpty)
        #expect(graph.hasAnalysisTarget(key) == false)
        #expect(graph.insertAnalysis(forInsert: key) == nil)
    }

    // MARK: - …and its POSITION in the pass, not merely its presence

    @Test("the arm re-application runs AFTER every chain sync: an arm lands on a unit created during THAT SAME pass")
    func armsAreReappliedAfterTheChainSyncNotBefore() throws {
        // The leg above proves `applyAnalysisArms()` is CALLED. It cannot
        // prove WHERE: it arms an effect whose unit already exists from an
        // earlier pass, so the call passes from either end of
        // `applyParameters`. Moving it to the head of the function is a real,
        // silently-green mutation — the house laws' exact failure class ("a
        // source scrape proves the call exists, not that it runs first";
        // "a test seam's POSITION is itself load-bearing — mutate it").
        //
        // The discriminating case is the one the placement comment names: an
        // arm landing on a unit that DOES NOT EXIST at the top of the pass and
        // is created by the chain sync inside it. At the head the arm is
        // silently refused (`units[id]` is nil, `setAnalysisArmed` returns
        // false); at the tail it lands.
        let effectID = UUID()
        let track = Track(name: "SRC", kind: .audio,
                          effects: [EffectDescriptor(id: effectID, kind: .gain,
                                                     gain: GainParams(gainLinear: 1.0))])
        let key = InsertAnalysisKey(trackID: track.id, effectID: effectID)

        // THE WHOLE-GRAPH REBUILD SHAPE, RECONSTRUCTED: `AudioEngine` builds a
        // fresh graph, `wireGraphHooks` installs the arm mirror while it still
        // has NO strips, then exactly ONE reconcile and ONE parameter pass
        // follow. Nothing else is scheduled — so an arm that misses THIS pass
        // is lost until some later model edit that may never come, and the
        // user's open editor sits on a permanently dead spectrum (the m3c
        // failure class the roadmap names).
        //
        // The mirror is hand-assigned, so this leg pins the ORDERING of the
        // re-application, NOT the fact that `wireGraphHooks` installs it —
        // `armSurvivesAWholeGraphRebuild` drives the real rebuild for that.
        // Both are needed: deleting the install leaves this leg green, and
        // moving the re-application leaves that one green.
        let graph = PlaybackGraph(engine: AVAudioEngine())
        graph.analysisArms = [key]
        _ = graph.reconcile(tracks: [track])
        graph.applyParameters(tracks: [track])

        let state = try #require(graph.effectChainState(forTrack: track.id))
        #expect(state.armedEffectIDs == [effectID],
                "the arm did not land in the pass that created its unit — the re-application is running BEFORE the chain sync, not after")
        let tap = try #require(state.analysisTap(forEffect: effectID))

        // Arm → render ≥100 ms → poll, both liveness assertions: a leg that
        // stopped at `armedEffectIDs` would pass against an arm that produced
        // a tap nothing ever feeds or drains.
        let quanta = 20  // 10_240 frames = 213 ms @ 48 kHz
        let input = Self.tone(hz: 750, frames: quanta * Self.quantum)
        let scratch = Scratch(capacity: Self.quantum)
        var index = 0
        while index < quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            state.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            index &+= 1
        }
        #expect(tap.framesWritten == UInt64(quanta * Self.quantum))
        let snapshot = try #require(graph.insertAnalysis(forInsert: key))
        let peak = try #require(snapshot.bands.max())
        #expect(peak > Self.floorDB + 20)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }

    @Test("…and on a strip that already exists: an insert ADDED mid-session is armed by the very pass that syncs it")
    func armHeldAcrossAnInsertAddLandsInThatSamePass() throws {
        // Sub-case (b) of the ordering claim, deliberately its OWN test: the
        // rebuild leg above ends at a `#require`, and a `#require` that trips
        // aborts the whole function — folded together, a mutation that killed
        // (a) would hide whether (b) still discriminates at all.
        //
        // Here the strip exists throughout and only the UNIT is new. The arm
        // is held BEFORE the effect is in the model (the editor-open-first
        // order), so the pass that syncs the new descriptor must also land it.
        let liveID = UUID(), addedID = UUID()
        let track = Track(name: "SRC", kind: .audio,
                          effects: [EffectDescriptor(id: liveID, kind: .gain,
                                                     gain: GainParams(gainLinear: 1.0))])
        let graph = PlaybackGraph(engine: AVAudioEngine())
        _ = graph.reconcile(tracks: [track])
        graph.applyParameters(tracks: [track])
        let state = try #require(graph.effectChainState(forTrack: track.id))

        graph.analysisArms = [InsertAnalysisKey(trackID: track.id, effectID: liveID)]
        graph.applyParameters(tracks: [track])
        let liveTap = try #require(state.analysisTap(forEffect: liveID))

        graph.analysisArms.insert(InsertAnalysisKey(trackID: track.id,
                                                    effectID: addedID))
        #expect(state.armedEffectIDs == [liveID],
                "an arm landed on an effect the model does not contain yet")

        let grown = Track(id: track.id, name: "SRC", kind: .audio, effects: [
            EffectDescriptor(id: liveID, kind: .gain,
                             gain: GainParams(gainLinear: 1.0)),
            EffectDescriptor(id: addedID, kind: .eq, eq: EQParams()),
        ])
        graph.applyParameters(tracks: [grown])
        #expect(state.armedEffectIDs == [liveID, addedID],
                "the freshly synced insert was not armed in its own pass — the re-application ran before the sync")
        // …and the tail position left the arm that was ALREADY live alone.
        #expect(state.analysisTap(forEffect: liveID) === liveTap,
                "the re-application replaced a LIVE tap")

        // Liveness for the newly armed insert: it must actually see the walk
        // and drain non-floor, not merely appear in `armedEffectIDs`.
        let addedTap = try #require(state.analysisTap(forEffect: addedID))
        #expect(addedTap !== liveTap)
        let quanta = 20
        let input = Self.tone(hz: 750, frames: quanta * Self.quantum)
        let scratch = Scratch(capacity: Self.quantum)
        var index = 0
        while index < quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            state.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            index &+= 1
        }
        #expect(addedTap.framesWritten == UInt64(quanta * Self.quantum))
        let snapshot = addedTap.drainAndSnapshot()
        let peak = try #require(snapshot.bands.max())
        #expect(peak > Self.floorDB + 20)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }

    @Test("…and after the MASTER chain's sync too: a master insert arm lands in the pass that syncs it")
    func armOnAMasterInsertLandsInThePassThatSyncsIt() throws {
        // The third position, and the one the two legs above CANNOT see:
        // between the track loop and `masterChainState?.sync(...)`. Both of
        // them arm TRACK inserts, which are already synced by then — so that
        // placement leaves them green while every MASTER arm is silently
        // dropped on every rebuild. The placement comment claims the tail
        // covers the master half; this is the leg that makes that true.
        //
        // Master coverage as a FEATURE (bypass honesty, budgets, the full
        // lifecycle) is r2b's matrix and is deliberately not here: this leg
        // exists only to pin the ordering claim the comment makes today.
        let masterEffectID = UUID()
        let key = InsertAnalysisKey(trackID: nil, effectID: masterEffectID)
        let graph = PlaybackGraph(engine: AVAudioEngine())
        _ = graph.reconcile(tracks: [Track(name: "SRC", kind: .audio)])
        graph.ensureMasterSandwich()

        // The mirror arrives BEFORE the effect exists — the rebuild order.
        graph.analysisArms = [key]
        graph.masterEffects = [EffectDescriptor(id: masterEffectID, kind: .gain,
                                                gain: GainParams(gainLinear: 1.0))]
        graph.applyParameters(tracks: [])

        let state = try #require(graph.masterChainState)
        #expect(state.armedEffectIDs == [masterEffectID],
                "the master arm did not land in the pass that synced it — the re-application runs before the MASTER chain sync")
        let tap = try #require(state.analysisTap(forEffect: masterEffectID))

        let quanta = 20
        let input = Self.tone(hz: 750, frames: quanta * Self.quantum)
        let scratch = Scratch(capacity: Self.quantum)
        var index = 0
        while index < quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            state.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            index &+= 1
        }
        #expect(tap.framesWritten == UInt64(quanta * Self.quantum))
        let snapshot = try #require(graph.insertAnalysis(forInsert: key))
        let peak = try #require(snapshot.bands.max())
        #expect(peak > Self.floorDB + 20)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }

    // MARK: - The mirror install itself, across a real whole-graph rebuild

    @Test("an arm survives a whole-graph rebuild: the fresh graph gets the mirror from wireGraphHooks, not from a later arm call")
    func armSurvivesAWholeGraphRebuild() throws {
        // Every OTHER leg in this file hand-assigns `graph.analysisArms`,
        // which SIMULATES what `AudioEngine.wireGraphHooks` does rather than
        // exercising it — so deleting that one assignment leaves them all
        // green while a mid-session `rebuildEngine` silently produces a graph
        // with no arms at all. That is the m3c failure class the roadmap line
        // exists to prevent: the editor stays open, the spectrum is dead, and
        // nothing recovers until the user happens to re-arm.
        //
        // This leg therefore drives the REAL rebuild: a once-rendered engine
        // plus an announce-class routing change routes `tracksDidChange`
        // through `rebuildEngine`, which discards the engine, builds a fresh
        // `PlaybackGraph`, and calls `wireGraphHooks()`.
        let effectID = UUID()
        let busID = UUID()
        let track = Track(name: "SRC", kind: .audio,
                          sends: [Send(destinationBusID: busID, level: 0.4)],
                          effects: [EffectDescriptor(id: effectID, kind: .gain,
                                                     gain: GainParams(gainLinear: 1.0))])
        let bus = Track(id: busID, name: "FX", kind: .bus)
        let engine = AudioEngine()
        engine.tracksDidChange([track, bus])

        #expect(engine.setInsertAnalysisArmed(trackID: track.id, effectID: effectID,
                                              armed: true))
        let stateBefore = try #require(engine.graph.effectChainState(forTrack: track.id))
        let tapBefore = try #require(stateBefore.analysisTap(forEffect: effectID))
        let graphBefore = ObjectIdentifier(engine.graph)

        // The "once-rendered" precondition without hardware — exactly what a
        // successful `prepare()` sets (the EngineRebuildTests convention).
        engine.graph.engineHasRun = true
        var rewired = track
        rewired.sends = []  // routing-key change = announce-class = rebuild
        engine.tracksDidChange([rewired, bus])

        // The engine really was replaced, not surgically mutated — otherwise
        // this leg would be re-testing the ordinary parameter-pass path.
        #expect(ObjectIdentifier(engine.graph) != graphBefore,
                "no rebuild happened — this leg is not exercising wireGraphHooks")

        // The arm is on the FRESH graph's strip. Nothing re-armed it: the only
        // path that can put it there is `wireGraphHooks`' mirror install plus
        // the parameter-pass tail inside the cold build.
        let state = try #require(engine.graph.effectChainState(forTrack: track.id))
        #expect(state.armedEffectIDs == [effectID],
                "the arm did not survive the rebuild — wireGraphHooks is not re-installing the arm mirror onto the fresh graph")
        let tap = try #require(state.analysisTap(forEffect: effectID))
        // Intent survives; the TAP does not — the fresh strip built a new one,
        // so a stale ring can never be read as live post-rebuild audio.
        #expect(tap !== tapBefore)

        // Arm → render ≥100 ms → poll, both liveness assertions, through the
        // rebuilt strip and the public read-back.
        let quanta = 20  // 10_240 frames = 213 ms @ 48 kHz
        let input = Self.tone(hz: 750, frames: quanta * Self.quantum)
        let scratch = Scratch(capacity: Self.quantum)
        var index = 0
        while index < quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            state.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            index &+= 1
        }
        #expect(tap.framesWritten == UInt64(quanta * Self.quantum))
        let snapshot = try #require(engine.insertAnalysis(trackID: track.id,
                                                          effectID: effectID))
        let peak = try #require(snapshot.bands.max())
        #expect(peak > Self.floorDB + 20,
                "the rebuilt strip's tap drained floor — the arm is nominal, not live")
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }

    // MARK: - The engine's arm home, end to end through the public surface

    @Test("the engine's arm home reaches the real strip's chain, survives a track re-intake, and reads back through the public API")
    func engineArmHomeReachesTheStripAndReadsBack() throws {
        let effectID = UUID()
        // Unity gain: the strip's chain is arithmetically an identity, so what
        // the tap reads is exactly the tone that was staged — this leg is about
        // the PLUMBING (engine → graph → strip → tap), not about DSP.
        let track = Track(name: "SRC", kind: .audio,
                          effects: [EffectDescriptor(id: effectID, kind: .gain,
                                                     gain: GainParams(gainLinear: 1.0))])
        let engine = AudioEngine()
        engine.tracksDidChange([track])

        // An UNARMED insert reads nothing at all — nil, not a floor snapshot
        // that a meter would render as "live and silent" (the `liveLoudness`
        // convention; the extension default in `AudioEngineControlling` returns
        // the same nil so a headless/fake engine is honestly unarmed).
        #expect(engine.insertAnalysis(trackID: track.id, effectID: effectID) == nil)

        #expect(engine.setInsertAnalysisArmed(trackID: track.id, effectID: effectID,
                                              armed: true))
        // The arm reached the REAL strip's chain state, not merely the engine's
        // own bookkeeping set: `armedEffectIDs` is read off the strip.
        let state = try #require(engine.graph.effectChainState(forTrack: track.id))
        #expect(state.armedEffectIDs == [effectID])
        let tap = try #require(state.analysisTap(forEffect: effectID))

        // ARM → RENDER → POLL, through that strip's own walk. A freshly armed
        // tap legitimately reads floor, so a leg that polled immediately would
        // pass against a tap that is never fed.
        let quanta = 20  // 10_240 frames = 213 ms @ 48 kHz
        let input = Self.tone(hz: 750, frames: quanta * Self.quantum)
        let scratch = Scratch(capacity: Self.quantum)
        var index = 0
        while index < quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            state.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            index &+= 1
        }
        #expect(tap.framesWritten == UInt64(quanta * Self.quantum))

        // The read-back is through the PUBLIC engine surface, which is the
        // whole point of this leg: engine → graph → strip → tap → snapshot.
        let snapshot = try #require(engine.insertAnalysis(trackID: track.id,
                                                          effectID: effectID))
        let peak = try #require(snapshot.bands.max())
        #expect(peak > Self.floorDB + 20,
                "the engine's read-back sat on the floor — the accessor chain is dead")
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))

        // A track re-intake runs reconcile + a full parameter pass: the arm
        // must come back on the SAME tap (a re-application that replaced it
        // would reset a live meter's ballistics every time the model changed).
        engine.tracksDidChange([track])
        let afterIntake = try #require(engine.graph.effectChainState(forTrack: track.id))
        #expect(afterIntake.armedEffectIDs == [effectID],
                "a track re-intake dropped the arm — the mirror is not re-applied")
        #expect(afterIntake.analysisTap(forEffect: effectID) === tap)

        // Disarm through the public API: nothing left on the strip, and the
        // read-back returns to nil rather than a stale last snapshot.
        #expect(engine.setInsertAnalysisArmed(trackID: track.id, effectID: effectID,
                                              armed: false))
        #expect(engine.insertAnalysis(trackID: track.id, effectID: effectID) == nil)
        #expect(afterIntake.armedEffectIDs.isEmpty)
    }

    // MARK: - r1's one-sided write clamp, exercised through the chain

    @Test("a walk quantum larger than the tap's per-write bound is CLAMPED, not overrun")
    func oversizedWalkQuantumIsClamped() throws {
        // r1 left `write`'s clamp deliberately ONE-SIDED, on the argument that
        // no caller can exceed `ChainEffectUnit.scratchFrames` (8_192). r2a
        // makes the chain walk a caller and hands the tap the strip's own
        // in-place buffer list — so that argument now needs a BEHAVIOURAL pin,
        // not the constants relation r1 pins (`capacityFrames / 2 >=
        // scratchFrames` stays green if the clamp is deleted outright).
        let gainID = UUID()
        let chain = makeChain([
            EffectDescriptor(id: gainID, kind: .gain,
                             gain: GainParams(gainLinear: 1.0)),
        ])
        #expect(chain.state.setAnalysisArmed(true, forEffect: gainID))
        let tap = try #require(chain.state.analysisTap(forEffect: gainID))

        let bound = InsertSpectrumTap.capacityFrames / 2
        #expect(bound == ChainEffectUnit.scratchFrames,
                "the tap's per-write bound drifted from the house max quantum")
        let oversized = bound + 1_024
        let scratch = Scratch(capacity: oversized)
        scratch.stage(Self.tone(hz: 750, frames: oversized), offset: 0, count: oversized)
        chain.processor.process(bufferList: scratch.raw, frameCount: oversized)

        // Exactly the bound: the excess is DROPPED, not wrapped over live ring
        // content and not written past the allocation.
        #expect(tap.framesWritten == UInt64(bound),
                "an oversized walk quantum was not clamped to the tap's write bound")
        // …and what survived is real audio, so the clamp truncated rather than
        // refusing the write outright.
        let snapshot = tap.drainAndSnapshot()
        let peak = try #require(snapshot.bands.max())
        #expect(peak > Self.floorDB + 20)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: 750))
    }
}
