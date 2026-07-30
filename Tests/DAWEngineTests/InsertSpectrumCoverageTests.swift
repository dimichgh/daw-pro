import AVFAudio
import Darwin
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// Gate for m23-r2b: the per-insert spectrum tap's COVERAGE MATRIX — breadth
/// over the mechanism m23-r2a proved. `InsertSpectrumTap` itself is r1's gate
/// (`InsertSpectrumTapTests`); the chain hook, the arm plumbing, the
/// allocation leg and the re-application ORDERING are r2a's
/// (`InsertSpectrumChainTests`) and are deliberately NOT repeated here.
///
/// What THIS file adds, and why each needs its own leg:
///
///  1. **Every strip class actually meters.** `EffectChainState` is
///     constructed at THREE sites (`PlaybackGraph.swift:1920` master and
///     `:2051` audio/bus, both behind a `ChainHostAU`; `:2078` instrument,
///     behind an `InstrumentRenderer` — structurally a different producer).
///     If one class were spectrum-free nobody would find out until a user
///     asked. r2a's master leg pins the re-application ORDERING, not master
///     coverage as a feature.
///  2. **…driven by the REAL render block, not a hand-built buffer list.**
///     Every r2a leg called `processor.process(bufferList:frameCount:)` with
///     its own `Scratch`, which proves the CONSUMER and merely SIMULATES the
///     PRODUCER. The per-class risk lives exactly there: channel layout,
///     `mDataByteSize`, the frame count the block is pulled with. So the
///     strip legs below run a real manual-rendering `AVAudioEngine` over a
///     real `PlaybackGraph`, and the tap is fed by `ChainHostAU`'s own render
///     block / `InstrumentSourceNode.renderQuantum`.
///  3. **Bypass honesty.** The hook is the LAST statement of the walk body,
///     so a steadily bypassed unit's tap reads its own INPUT — which IS a
///     bypassed unit's output. A/B-ing bypass must therefore visibly MOVE the
///     spectrum, or the meter is lying about what the user is hearing.
///  4. **The arm lifecycle r2a did not cover**: a kind change, the hosted-AU
///     `invalidateEffect` swap (driven through the REAL
///     `AudioEngine.syncAudioUnitEffects` async re-entry), and a rate change.
///     Graph-rebuild-with-the-arm-held is r2a's `armSurvivesAWholeGraphRebuild`
///     and is not redone.
///  5. **The `graph.analysisArms` mirror FAMILY.** `AudioEngine` assigns it
///     at four sites; r2a pinned one (`:488`, `wireGraphHooks`). The other
///     three — disarm `:1514`, cap-prune `:1532`, arm `:1537` — were
///     collectively unpinned by all 4142 tests.
///  6. **Budget legs 2 and 3** of the design's §Q4 (leg 1, allocation, is
///     r2a's and is done).
///
/// `.serialized` because the budget legs measure wall time.
@MainActor
@Suite("Per-insert spectrum — coverage matrix (m23-r2b)", .serialized)
struct InsertSpectrumCoverageTests {

    private static let rate = 48_000.0
    private static let quantum = 512
    private static let floorDB = MasterAnalysisSnapshot.floorDB
    /// 4 × 512 = 2_048 frames, half of `InsertSpectrumTap.maxDrainFrames`, so
    /// the drop-oldest path is unreachable and every leg can assert
    /// `droppedFrames == 0` as its premise rather than ignoring the counter
    /// (r1's rule).
    private static let drainEveryQuanta = 4
    /// 40 × 512 = 20_480 frames = 426 ms @ 48 kHz — past the analyzer's
    /// 2_048-frame warm-up with room for its ballistics to settle. Every leg
    /// here ARMS → RENDERS ≥ 100 ms → POLLS; a leg that armed and read
    /// immediately would be measuring the premise, not the feature.
    private static let renderQuanta = 40

    // MARK: - The real-strip harness

    /// A REAL manual-rendering `AVAudioEngine` driving a REAL `PlaybackGraph`,
    /// built in `OfflineRenderer.beginSession`'s exact call order (that order
    /// is load-bearing — see the measurement notes there). The point is the
    /// PRODUCER: strips are pulled by AVAudioEngine, so `ChainHostAU`'s render
    /// block and `InstrumentSourceNode.renderQuantum` hand the chain walk
    /// their OWN buffer lists, exactly as they do live.
    @MainActor
    final class Strips {
        let engine: AVAudioEngine
        let graph: PlaybackGraph
        private let buffer: AVAudioPCMBuffer
        private let tracks: [Track]
        private let quantum: Int
        /// The engine-side arm intent this harness mirrors — see `arm`.
        private(set) var armIntent: Set<InsertAnalysisKey> = []

        /// `schedule: false` reproduces the COLD-APP state: the graph is built
        /// and rendering, but `scheduleAll` has never run, so an instrument
        /// renderer's `scheduleSlot` is still nil and its quantum takes the
        /// `schedule == nil` idle branch (`InstrumentSourceNode.swift:645`).
        /// That branch has its own chain walk, and an armed insert must be fed
        /// by it — the case of a user opening an EQ editor on a cold app with
        /// the transport stopped.
        init(tracks: [Track], masterEffects: [EffectDescriptor] = [],
             masterVolume: Double = 1, schedule: Bool = true,
             rate: Double = InsertSpectrumCoverageTests.rate,
             quantum: Int = InsertSpectrumCoverageTests.quantum) throws {
            self.tracks = tracks
            self.quantum = quantum
            engine = AVAudioEngine()
            graph = PlaybackGraph(engine: engine, graphRate: rate)
            graph.masterEffects = masterEffects
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            try engine.enableManualRenderingMode(
                .offline, format: format,
                maximumFrameCount: AVAudioFrameCount(quantum))
            _ = engine.mainMixerNode
            _ = graph.reconcile(tracks: tracks)
            let tempoMap = TempoMap(constantBPM: 120)
            engine.mainMixerNode.outputVolume = Float(masterVolume)
            graph.armOfflineAutomation(fromBeat: 0, tempoMap: tempoMap)
            graph.applyParameters(tracks: tracks, playheadBeat: 0)
            try engine.start()
            graph.applyParameters(tracks: tracks, playheadBeat: 0)
            if schedule {
                graph.scheduleAll(fromBeat: 0, tempoMap: tempoMap)
                graph.startAllPlayers(at: nil)
            }
            buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format,
                                 frameCapacity: AVAudioFrameCount(quantum)))
        }

        /// Takes an arm the way `AudioEngine.setInsertAnalysisArmed` does —
        /// **BOTH production statements, in production order**:
        /// `graph.setAnalysisArmed(true, forInsert:)` (`AudioEngine.swift:1535`)
        /// and then the mirror assignment `graph.analysisArms = <intent>`
        /// (`:1537`). This is NOT r2a's shortcut: r2a assigned the mirror
        /// ALONE and captioned it "the way `wireGraphHooks` delivers it",
        /// which is what let the `wireGraphHooks` install be deleted with all
        /// 4141 tests green. Mirroring both statements is faithful to the
        /// engine's arm path; that the mirror SURVIVES a graph replacement is
        /// r2a's `armSurvivesAWholeGraphRebuild`, and that the three
        /// engine-side mirror sites exist at all is `mirrorFamily…` below.
        @discardableResult
        func arm(_ key: InsertAnalysisKey) -> Bool {
            guard graph.setAnalysisArmed(true, forInsert: key) else { return false }
            armIntent.insert(key)
            graph.analysisArms = armIntent
            return true
        }

        /// A parameter pass with the harness's own track list — the pass every
        /// live model edit runs, and the one that re-applies the arm mirror.
        func applyParameters(_ tracks: [Track]? = nil) {
            graph.applyParameters(tracks: tracks ?? self.tracks, playheadBeat: 0)
        }

        /// Pulls `quanta` real quanta through the engine. `onQuantum` runs
        /// after each pull — how every leg drains on the r1 cadence.
        func pull(quanta: Int, onQuantum: ((Int) -> Void)? = nil) throws {
            var index = 0
            while index < quanta {
                let status = try engine.renderOffline(
                    AVAudioFrameCount(quantum), to: buffer)
                try #require(status == .success)
                onQuantum?(index)
                index &+= 1
            }
        }

        /// Renders `quanta` and returns the LAST snapshot drained from `key`
        /// on the r1 cadence. The drain is the only consumer of that insert —
        /// `insertAnalysis` DRAINS, so two pollers would split the stream and
        /// both would run slow with nothing reported (the r2a handoff note).
        func renderAndPoll(_ key: InsertAnalysisKey,
                           quanta: Int = InsertSpectrumCoverageTests.renderQuanta) throws
            -> MasterAnalysisSnapshot {
            var last = MasterAnalysisSnapshot.floor
            try pull(quanta: quanta) { index in
                if index % InsertSpectrumCoverageTests.drainEveryQuanta
                    == InsertSpectrumCoverageTests.drainEveryQuanta - 1,
                   let snapshot = self.graph.insertAnalysis(forInsert: key) {
                    last = snapshot
                }
            }
            return last
        }
    }

    // MARK: - Shared assertions

    /// BOTH liveness facts, always, because neither implies the other: a ring
    /// that advances while the drain is broken yields floor bands, and a tap
    /// reading a stale prior fill yields non-floor bands without advancing.
    private func expectLive(tap: InsertSpectrumTap, snapshot: MasterAnalysisSnapshot,
                            frames: Int, toneHz: Double, label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(tap.framesWritten == UInt64(frames),
                "\(label): the tap did not see the real render block's every quantum",
                sourceLocation: sourceLocation)
        #expect(tap.droppedFrames == 0, "\(label): the drain fell behind",
                sourceLocation: sourceLocation)
        let peak = try #require(snapshot.bands.max(), sourceLocation: sourceLocation)
        #expect(peak > Self.floorDB + 20,
                "\(label): drained bands sat on the floor — nothing reached the analyzer",
                sourceLocation: sourceLocation)
        #expect(snapshot.bands.firstIndex(of: peak)
                == MasterMixAnalyzer.bandIndex(containing: toneHz),
                "\(label): the tapped peak is not on the injected tone's band",
                sourceLocation: sourceLocation)
    }

    /// Analytic tone at `sampleRate` — the fixture for the processor-level
    /// legs, where there is no file player to pull from.
    private static func tone(hz: Double, frames: Int, sampleRate: Double = rate,
                             amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * .pi * hz * Double(index) / sampleRate))
        }
    }

    /// Owns the scratch and the `AudioBufferList` a chain walk processes IN
    /// PLACE — the r2a harness, for the legs whose SUBJECT is the chain state
    /// rather than the strip's render block (the hosted-AU swap and the rate
    /// change, neither of which is reachable from a `PlaybackGraph` strip in
    /// a headless test). The strip-type legs above deliberately do NOT use
    /// this: their whole point is the real producer's own buffer list.
    final class Scratch {
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

        func stage(_ source: [Float], offset: Int, count: Int) {
            precondition(count <= capacity)
            source.withUnsafeBufferPointer { input in
                for channel in 0..<channels {
                    (storage + channel * capacity)
                        .update(from: input.baseAddress! + offset, count: count)
                }
            }
        }
    }

    /// Walks `quanta` quanta of `input` through `state`'s processor, draining
    /// `tap` on the r1 cadence so `droppedFrames == 0` stays a premise rather
    /// than an excuse. Returns the last snapshot drained (floor when no tap
    /// was given).
    @discardableResult
    private func renderAndDrain(state: EffectChainState, scratch: Scratch,
                                input: [Float], quanta: Int,
                                tap: InsertSpectrumTap? = nil) throws
        -> MasterAnalysisSnapshot {
        var last = MasterAnalysisSnapshot.floor
        var index = 0
        while index < quanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            state.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            if index % Self.drainEveryQuanta == Self.drainEveryQuanta - 1,
               let tap {
                last = tap.drainAndSnapshot()
            }
            index &+= 1
        }
        return last
    }

    private func gainFX(_ id: UUID, _ linear: Double = 1.0,
                        bypassed: Bool = false) -> EffectDescriptor {
        EffectDescriptor(id: id, kind: .gain, isBypassed: bypassed,
                         gain: GainParams(gainLinear: linear))
    }

    private func audioTrack(id: UUID = UUID(), clip url: URL, volume: Double = 1,
                            outputBusID: UUID? = nil,
                            effects: [EffectDescriptor] = []) -> Track {
        Track(id: id, name: "SRC", kind: .audio, volume: volume,
              clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 8,
                           audioFileURL: url)],
              outputBusID: outputBusID, effects: effects)
    }

    // MARK: - 1. Strip-type matrix — AUDIO strip (ChainHostAU, PlaybackGraph:2051)

    @Test("an armed insert on an AUDIO strip meters through ChainHostAU's own render block — and reads PRE-fader")
    func audioStripInsertMeters() throws {
        let fixtures = try TestSignals.fixtures()
        let effectID = UUID()
        let trackID = UUID()
        let track = audioTrack(id: trackID, clip: fixtures.cos1k48,
                               effects: [gainFX(effectID)])
        let key = InsertAnalysisKey(trackID: trackID, effectID: effectID)

        let strips = try Strips(tracks: [track])
        #expect(strips.arm(key))
        let state = try #require(strips.graph.effectChainState(forTrack: trackID))
        #expect(state.armedEffectIDs == [effectID])
        let tap = try #require(state.analysisTap(forEffect: effectID))

        let snapshot = try strips.renderAndPoll(key)
        try expectLive(tap: tap, snapshot: snapshot,
                       frames: Self.renderQuanta * Self.quantum,
                       toneHz: 1_000, label: "audio strip")

        // PRE-FADER, and it is not obvious: the strip sandwich is
        // `sumMixer → chainHost → mixer`, so the strip FADER is DOWNSTREAM of
        // the walk and a fader move cannot move this reading. Pinned by
        // measurement against an otherwise identical −6 dB render, because
        // r3/r4's UI has to say which signal the curve represents (and the
        // MASTER leg below pins the opposite answer for master inserts).
        let quiet = audioTrack(id: trackID, clip: fixtures.cos1k48, volume: 0.5,
                               effects: [gainFX(effectID)])
        let quietStrips = try Strips(tracks: [quiet])
        #expect(quietStrips.arm(key))
        let quietTap = try #require(
            quietStrips.graph.effectChainState(forTrack: trackID)?
                .analysisTap(forEffect: effectID))
        let quietSnapshot = try quietStrips.renderAndPoll(key)
        try expectLive(tap: quietTap, snapshot: quietSnapshot,
                       frames: Self.renderQuanta * Self.quantum,
                       toneHz: 1_000, label: "audio strip @ −6 dB fader")

        let band = MasterMixAnalyzer.bandIndex(containing: 1_000)
        let full = Double(snapshot.bands[band])
        let halved = Double(quietSnapshot.bands[band])
        print("[measured] m23-r2b audio-strip tap is PRE-fader: 1 kHz band "
              + "\(full) dB @ fader 1.0 vs \(halved) dB @ fader 0.5, "
              + "delta \(full - halved) dB (expected ≈ 0)")
        #expect(abs(full - halved) < 0.5,
                "the strip fader moved a PRE-fader insert tap — the hook drifted downstream")
        // m23-r4 L9: the ONE home for the wire label agrees with the fact
        // just measured above, extending this leg rather than cloning it
        // into a second fixture.
        #expect(InsertSpectrumTapPoint.forInsert(trackID: trackID).wireValue
                == "postInsertPreFader",
                "InsertSpectrumTapPoint disagrees with the measured PRE-fader strip tap")
    }

    // MARK: - 1. Strip-type matrix — BUS strip (ChainHostAU, PlaybackGraph:2051)

    @Test("an armed insert on a BUS strip meters the summed send/route, through the bus sandwich")
    func busStripInsertMeters() throws {
        let fixtures = try TestSignals.fixtures()
        let effectID = UUID()
        let busID = UUID()
        // The bus is fed by ROUTING (the audio strip's output), so the bus
        // chain walks real summed audio rather than the strip's own buffer —
        // `busNodes` is a third lookup arm in `effectChainState(forTrack:)`
        // and would answer nil if the resolver ever forgot it.
        let track = audioTrack(clip: fixtures.cos1k48, outputBusID: busID)
        let bus = Track(id: busID, name: "FX", kind: .bus,
                        effects: [gainFX(effectID)])
        let key = InsertAnalysisKey(trackID: busID, effectID: effectID)

        let strips = try Strips(tracks: [track, bus])
        #expect(strips.arm(key))
        let state = try #require(strips.graph.effectChainState(forTrack: busID))
        #expect(state.armedEffectIDs == [effectID])
        let tap = try #require(state.analysisTap(forEffect: effectID))

        let snapshot = try strips.renderAndPoll(key)
        try expectLive(tap: tap, snapshot: snapshot,
                       frames: Self.renderQuanta * Self.quantum,
                       toneHz: 1_000, label: "bus strip")
    }

    // MARK: - 1. Strip-type matrix — MASTER (ChainHostAU, PlaybackGraph:1920)

    @Test("an armed MASTER insert meters the summed mix — and reads POST master fader (the strip rule inverted)")
    func masterInsertMeters() throws {
        let fixtures = try TestSignals.fixtures()
        let effectID = UUID()
        let key = InsertAnalysisKey(trackID: nil, effectID: effectID)
        let track = audioTrack(clip: fixtures.cos1k48)

        let strips = try Strips(tracks: [track],
                                masterEffects: [gainFX(effectID)])
        #expect(strips.arm(key))
        let state = try #require(strips.graph.masterChainState)
        #expect(state.armedEffectIDs == [effectID])
        let tap = try #require(state.analysisTap(forEffect: effectID))

        let snapshot = try strips.renderAndPoll(key)
        try expectLive(tap: tap, snapshot: snapshot,
                       frames: Self.renderQuanta * Self.quantum,
                       toneHz: 1_000, label: "master chain")

        // POST-FADER — the OPPOSITE of the audio-strip leg above, and neither
        // the roadmap nor the design says so. The master sandwich is
        // `mainMixerNode → masterChainHost → output` (`PlaybackGraph:1865`),
        // so the master fader sits UPSTREAM of the master walk: a master
        // insert's tap reads the faded programme. r3/r4's UI must label these
        // two curves differently or the same control will appear to move one
        // meter and not the other for no visible reason.
        let quiet = try Strips(tracks: [track],
                               masterEffects: [gainFX(effectID)],
                               masterVolume: 0.5)
        #expect(quiet.arm(key))
        let quietTap = try #require(
            quiet.graph.masterChainState?.analysisTap(forEffect: effectID))
        let quietSnapshot = try quiet.renderAndPoll(key)
        try expectLive(tap: quietTap, snapshot: quietSnapshot,
                       frames: Self.renderQuanta * Self.quantum,
                       toneHz: 1_000, label: "master chain @ −6 dB fader")

        let band = MasterMixAnalyzer.bandIndex(containing: 1_000)
        let full = Double(snapshot.bands[band])
        let halved = Double(quietSnapshot.bands[band])
        print("[measured] m23-r2b master tap is POST-fader: 1 kHz band "
              + "\(full) dB @ master 1.0 vs \(halved) dB @ master 0.5, "
              + "delta \(full - halved) dB (expected ≈ 6.02)")
        #expect(abs((full - halved) - 6.0206) < 1.0,
                "a master insert tap did not follow the master fader — the master walk moved relative to the volume stage")
        // m23-r4 L9: the ONE home for the wire label agrees with the fact
        // just measured above, extending this leg rather than cloning it.
        #expect(InsertSpectrumTapPoint.forInsert(trackID: nil).wireValue
                == "postInsertPostFader",
                "InsertSpectrumTapPoint disagrees with the measured POST-fader master tap")
    }

    // MARK: - 1. Strip-type matrix — INSTRUMENT (InstrumentRenderer, PlaybackGraph:2078)

    @Test("an armed insert on an INSTRUMENT strip meters through InstrumentSourceNode's render — including the no-schedule silence path")
    func instrumentStripInsertMeters() throws {
        let effectID = UUID()
        let trackID = UUID()
        // A4 = 440 Hz from `TestToneInstrument` (pitch 69), held for the whole
        // render so the tapped band is stable.
        let track = Track(id: trackID, name: "Keys", kind: .instrument,
                          clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 8,
                                       notes: [MIDINote(pitch: 69, velocity: 127,
                                                        startBeat: 0, lengthBeats: 8)])],
                          instrument: InstrumentDescriptor(kind: .testTone),
                          effects: [gainFX(effectID)])
        let key = InsertAnalysisKey(trackID: trackID, effectID: effectID)

        let strips = try Strips(tracks: [track])
        #expect(strips.arm(key))
        let state = try #require(strips.graph.effectChainState(forTrack: trackID))
        #expect(state.armedEffectIDs == [effectID])
        // Structurally a DIFFERENT producer from the two legs above: this
        // chain state was built over `renderer.chain`
        // (`PlaybackGraph.swift:2078`), not over a `ChainHostAU`'s processor.
        #expect(strips.graph.instrumentRenderer(forTrack: trackID)?.chain
                === state.processor,
                "the instrument strip's chain state is not the renderer's own chain")
        let tap = try #require(state.analysisTap(forEffect: effectID))

        let snapshot = try strips.renderAndPoll(key)
        try expectLive(tap: tap, snapshot: snapshot,
                       frames: Self.renderQuanta * Self.quantum,
                       toneHz: 440, label: "instrument strip")

        // THE IDLE SILENCE PATH, which only this strip class has: with NO
        // schedule ever published — cold app, transport stopped, the user just
        // opened an effect editor — the renderer takes its own early branch
        // (`InstrumentSourceNode.swift:645`) and walks the chain there because
        // effect tails must ring on silent input. An armed insert must keep
        // the ring ADVANCING and read FLOOR, not freeze on a stale reading
        // that a meter would draw as live audio.
        //
        // `schedule: false` IS THE LOAD-BEARING PART OF THIS SETUP, and it was
        // added because mutation said so: with the harness's normal
        // `scheduleAll`, an empty instrument track still gets a (non-nil,
        // empty) schedule published, so the quantum takes the ORDINARY render
        // path and deleting the idle branch's `chain.process` left this
        // sub-case green. It exercised a silent instrument, not the silence
        // path.
        let silentID = UUID()
        let silentEffectID = UUID()
        let silent = Track(id: silentID, name: "Quiet", kind: .instrument,
                           instrument: InstrumentDescriptor(kind: .testTone),
                           effects: [gainFX(silentEffectID)])
        let silentKey = InsertAnalysisKey(trackID: silentID, effectID: silentEffectID)
        let silentStrips = try Strips(tracks: [silent], schedule: false)
        #expect(silentStrips.graph.instrumentRenderer(forTrack: silentID)?
                .currentSchedule == nil,
                "a schedule reached the renderer — this sub-case is exercising the ordinary render path, not the idle branch")
        #expect(silentStrips.arm(silentKey))
        let silentTap = try #require(
            silentStrips.graph.effectChainState(forTrack: silentID)?
                .analysisTap(forEffect: silentEffectID))
        let silentSnapshot = try silentStrips.renderAndPoll(silentKey)
        #expect(silentTap.framesWritten == UInt64(Self.renderQuanta * Self.quantum),
                "the silence path skipped the tap — an armed insert on a resting instrument track freezes instead of reading floor")
        #expect(silentTap.droppedFrames == 0)
        let silentPeak = try #require(silentSnapshot.bands.max())
        print("[measured] m23-r2b instrument silence path: framesWritten "
              + "\(silentTap.framesWritten), peak band \(silentPeak) dB "
              + "(floor \(Self.floorDB))")
        #expect(silentPeak == Self.floorDB,
                "a silent armed insert read above the floor")
    }

    // MARK: - 2. Bypass honesty

    @Test("A/B-ing an insert's bypass visibly MOVES its own tap — a bypassed unit's tap reads its input, which IS its output")
    func bypassMovesTheTappedSpectrum() throws {
        let fixtures = try TestSignals.fixtures()
        let cutDb = -18.0
        let effectID = UUID()
        let trackID = UUID()
        // A deep cut ON the fixture's own 1 kHz tone: ACTIVE the tapped band
        // collapses, BYPASSED it must come back, because the hook is the last
        // statement of the walk body and a skipped unit hands on its input
        // untouched.
        func track(bypassed: Bool) -> Track {
            audioTrack(id: trackID, clip: fixtures.cos1k48, effects: [
                EffectDescriptor(id: effectID, kind: .eq, isBypassed: bypassed,
                                 eq: EQParams(peak2Freq: 1_000,
                                              peak2GainDb: cutDb, peak2Q: 0.9)),
            ])
        }
        let key = InsertAnalysisKey(trackID: trackID, effectID: effectID)

        let strips = try Strips(tracks: [track(bypassed: false)])
        #expect(strips.arm(key))
        let state = try #require(strips.graph.effectChainState(forTrack: trackID))
        let tap = try #require(state.analysisTap(forEffect: effectID))
        let unit = try #require(state.unit(forEffect: effectID))

        let active = try strips.renderAndPoll(key)

        // THE TOGGLE ARRIVES THE WAY A USER'S CLICK DOES: a model edit through
        // a real parameter pass, which reaches `unit.setBypassed` via
        // `EffectChainState.sync`. Not a direct flag poke.
        strips.applyParameters([track(bypassed: true)])
        #expect(state.unit(forEffect: effectID) === unit,
                "a bypass toggle rebuilt the unit")
        #expect(state.analysisTap(forEffect: effectID) === tap,
                "a bypass toggle replaced the live tap — the meter's ballistics reset")
        // Long enough for the 10 ms equal-power crossfade to finish AND the
        // analyzer's ballistics to re-settle on the new signal.
        let bypassed = try strips.renderAndPoll(key, quanta: 80)

        let band = MasterMixAnalyzer.bandIndex(containing: 1_000)
        let activeDb = Double(active.bands[band])
        let bypassedDb = Double(bypassed.bands[band])
        let delta = bypassedDb - activeDb
        print("[measured] m23-r2b bypass honesty: 1 kHz band \(activeDb) dB ACTIVE "
              + "vs \(bypassedDb) dB BYPASSED, delta \(delta) dB (cut \(cutDb) dB)")
        #expect(delta > 8,
                "bypassing the insert did not move its own tap — the meter cannot tell the user what they are hearing")
        #expect(abs(delta - -cutDb) < 5,
                "the bypassed reading does not return to the insert's input level")
        #expect(tap.droppedFrames == 0)
        #expect(tap.framesWritten == UInt64((Self.renderQuanta + 80) * Self.quantum))
    }

    // MARK: - 3. Lifecycle — a KIND change under a held arm

    @Test("changing an armed insert's KIND rebuilds the unit, keeps the SAME tap, and the tap follows the NEW unit's output")
    func kindChangeKeepsTheSameTapOnTheNewUnit() throws {
        let fixtures = try TestSignals.fixtures()
        let effectID = UUID()
        let trackID = UUID()
        let cutDb = -18.0
        // Same id, different kind — the ONE edit that forces
        // `EffectChainState.sync` to build a replacement unit (`IdentityKey`
        // is (id, kind)) and republish the snapshot. The arm must ride across
        // on the SAME tap object, or opening an editor and changing the
        // effect type silently kills the meter until the user re-arms.
        func track(kind: EffectDescriptor.Kind) -> Track {
            let descriptor: EffectDescriptor
            switch kind {
            case .gain:
                descriptor = gainFX(effectID)
            default:
                descriptor = EffectDescriptor(
                    id: effectID, kind: .eq,
                    eq: EQParams(peak2Freq: 1_000, peak2GainDb: cutDb, peak2Q: 0.9))
            }
            return audioTrack(id: trackID, clip: fixtures.cos1k48,
                              effects: [descriptor])
        }
        let key = InsertAnalysisKey(trackID: trackID, effectID: effectID)

        let strips = try Strips(tracks: [track(kind: .gain)])
        #expect(strips.arm(key))
        let state = try #require(strips.graph.effectChainState(forTrack: trackID))
        let tap = try #require(state.analysisTap(forEffect: effectID))
        let unitBefore = try #require(state.unit(forEffect: effectID))
        let snapshotBefore = try strips.renderAndPoll(key)
        try expectLive(tap: tap, snapshot: snapshotBefore,
                       frames: Self.renderQuanta * Self.quantum,
                       toneHz: 1_000, label: "before the kind change")

        // The edit arrives as a real parameter pass, the way a model change
        // reaches the engine.
        strips.applyParameters([track(kind: .eq)])
        let unitAfter = try #require(state.unit(forEffect: effectID))
        #expect(unitAfter !== unitBefore,
                "the kind change did not rebuild the unit — this leg is not exercising the replacement path")
        #expect(state.analysisTap(forEffect: effectID) === tap,
                "the kind change replaced the tap — a live meter's ballistics and history reset")
        #expect(unitAfter.publishedTap === tap,
                "the replacement unit came back DISARMED — the sync-time re-application (EffectChainProcessor.swift:579) did not run")
        #expect(state.armedEffectIDs == [effectID])

        // Continuity is the real claim, and identity alone cannot prove it:
        // render on and watch the SAME tap keep advancing, then read the NEW
        // unit's output — the 1 kHz band must now show the EQ's cut, so the
        // tap is demonstrably reading the replacement, not the discarded unit.
        let snapshotAfter = try strips.renderAndPoll(key, quanta: 80)
        #expect(tap.framesWritten == UInt64((Self.renderQuanta + 80) * Self.quantum),
                "the ring stopped advancing after the kind change")
        #expect(tap.droppedFrames == 0)
        let band = MasterMixAnalyzer.bandIndex(containing: 1_000)
        let before = Double(snapshotBefore.bands[band])
        let after = Double(snapshotAfter.bands[band])
        print("[measured] m23-r2b kind change gain→eq under a held arm: 1 kHz band "
              + "\(before) dB → \(after) dB, delta \(before - after) dB (cut \(cutDb) dB)")
        #expect(before - after > 8,
                "the tap did not follow the replacement unit's output")
    }

    // MARK: - 3. Lifecycle — the hosted-AU swap, through the REAL async re-entry

    @Test("a hosted-AU insert swapping in under a held arm keeps the SAME tap live — driven through AudioEngine's real async prepare re-entry")
    func hostedEffectSwapKeepsTheSameTapLive() async throws {
        let effectID = UUID()
        let trackID = UUID()
        // Apple's stock AULowpass ('aufx'/'lpas'), the component
        // `AUEffectHostingTests` already hosts headless from this bare-SPM
        // process. Its ONLY job here is to be a real hosted instance that
        // arrives LATE.
        let config = AudioUnitConfig(component: AudioUnitComponentID(
            type: "aufx", subType: "lpas", manufacturer: "appl"))
        let track = Track(id: trackID, name: "SRC", kind: .audio,
                          effects: [EffectDescriptor(id: effectID, kind: .audioUnit,
                                                     audioUnit: config)])

        // THE REAL PRODUCER, not a direct `invalidateEffect` call:
        // `tracksDidChange` → `syncAudioUnitEffects` → the async prepare Task,
        // whose `@MainActor` continuation calls `invalidateEffect(id:)` and
        // then `applyParameters(...)`. That async re-entry is the one most
        // likely to drop a held arm, because it lands after the user has
        // already opened the editor.
        let engine = AudioEngine()
        let graphIdentity = ObjectIdentifier(engine.graph)
        engine.tracksDidChange([track])
        let state = try #require(engine.graph.effectChainState(forTrack: trackID))
        let placeholder = try #require(state.unit(forEffect: effectID))

        // The editor opens while the placeholder is still installed.
        #expect(engine.setInsertAnalysisArmed(trackID: trackID, effectID: effectID,
                                              armed: true))
        let tap = try #require(state.analysisTap(forEffect: effectID))
        #expect(placeholder.publishedTap === tap)

        // Arm → render ≥ 100 ms → poll, against the PLACEHOLDER.
        let scratch = Scratch(capacity: Self.quantum)
        let input = Self.tone(hz: 1_000, frames: Self.renderQuanta * Self.quantum)
        try renderAndDrain(state: state, scratch: scratch, input: input,
                           quanta: Self.renderQuanta, tap: tap)
        let framesBeforeSwap = tap.framesWritten
        #expect(framesBeforeSwap == UInt64(Self.renderQuanta * Self.quantum))

        // Wait for the REAL async re-entry. The detector is the replacement
        // itself: `invalidateEffect` drops the unit and the parameters pass
        // rebuilds it around the hosted instance.
        var waitedMs = 0
        while state.unit(forEffect: effectID) === placeholder, waitedMs < 10_000 {
            try await Task.sleep(for: .milliseconds(10))
            waitedMs += 10
        }
        let swapped = try #require(state.unit(forEffect: effectID))
        #expect(swapped !== placeholder,
                "the hosted AU never swapped in (waited \(waitedMs) ms) — this leg is not exercising the async re-entry")
        #expect(ObjectIdentifier(engine.graph) == graphIdentity,
                "the swap rebuilt the whole graph — that is r2a's `armSurvivesAWholeGraphRebuild` path, not this one")

        // Meter continuity across the swap: the SAME tap object, published on
        // the REPLACEMENT unit. If `sync`'s re-application were dropped, the
        // tap would still be in `armedTaps` (so `analysisTap` answers) while
        // the new unit's slot stayed nil and the ring quietly stopped — which
        // is exactly why the liveness assertions below are not optional.
        #expect(state.analysisTap(forEffect: effectID) === tap,
                "the hosted-AU swap replaced the tap — the open editor's meter restarted from zero")
        #expect(swapped.publishedTap === tap,
                "the replacement unit came back DISARMED")
        #expect(state.armedEffectIDs == [effectID])

        try renderAndDrain(state: state, scratch: scratch, input: input,
                           quanta: Self.renderQuanta, tap: tap)
        #expect(tap.framesWritten == framesBeforeSwap
                + UInt64(Self.renderQuanta * Self.quantum),
                "the ring stopped advancing after the hosted-AU swap")
        #expect(tap.droppedFrames == 0)
        let snapshot = try #require(engine.insertAnalysis(trackID: trackID,
                                                          effectID: effectID))
        let peak = try #require(snapshot.bands.max())
        print("[measured] m23-r2b hosted-AU swap: waited \(waitedMs) ms, "
              + "framesWritten \(framesBeforeSwap) → \(tap.framesWritten), "
              + "peak band \(peak) dB")
        #expect(peak > Self.floorDB + 20,
                "the post-swap reading sat on the floor — the meter is nominally armed and actually dead")
    }

    // MARK: - 3. Lifecycle — a live RATE change

    @Test("a live rate change re-allocates an armed tap at the NEW rate: arm survives, sample history does not, band geometry moves")
    func rateChangeRearmsTheTapAtTheNewGeometry() throws {
        // ⚠️ REACHABILITY, measured at r2b and NOT what the roadmap implies:
        // this event has NO production producer today. `PlaybackGraph`'s
        // `chainRate` is `graphFormat().sampleRate`, and `graphRate` is stored
        // at construction; all four production `PlaybackGraph(...)` sites
        // (`AudioEngine.swift:437`/`:974`, `OfflineRenderer.swift:246`/`:464`)
        // inject it, so a graph's chain rate is CONSTANT for its lifetime. A
        // device-rate flip goes through `rebuildEngine` → a fresh graph →
        // fresh `EffectChainState`s whose `preparedSampleRate` is 0 and whose
        // `armedTaps` are empty, so `sync`'s `if !armedTaps.isEmpty` guard is
        // never true there either. `rearmTapsAtPreparedRate()` is therefore
        // BUILT-BUT-UNREACHABLE defensive code, and this leg pins it at the
        // only seam that can deliver the event — a direct second `sync` at a
        // different rate. It is deliberately NOT dressed up as a production
        // path; see the r2b report.
        let effectID = UUID()
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let descriptors = [gainFX(effectID)]
        state.sync(descriptors: descriptors, sampleRate: 48_000)
        #expect(state.setAnalysisArmed(true, forEffect: effectID))
        let tapAt48k = try #require(state.analysisTap(forEffect: effectID))
        let unit = try #require(state.unit(forEffect: effectID))

        let scratch = Scratch(capacity: Self.quantum)
        let band = MasterMixAnalyzer.bandIndex(containing: 1_000)
        let at48k = Self.tone(hz: 1_000, frames: Self.renderQuanta * Self.quantum,
                              sampleRate: 48_000)
        let before = try renderAndDrain(state: state, scratch: scratch, input: at48k,
                                        quanta: Self.renderQuanta, tap: tapAt48k)
        #expect(tapAt48k.framesWritten == UInt64(Self.renderQuanta * Self.quantum))
        #expect(before.bands.firstIndex(of: try #require(before.bands.max())) == band)

        state.sync(descriptors: descriptors, sampleRate: 44_100)

        // The ARM survives; the TAP does not — a device rate flip is a
        // measurement discontinuity, not a gap to stitch across.
        let tapAt44k = try #require(state.analysisTap(forEffect: effectID))
        #expect(state.armedEffectIDs == [effectID])
        #expect(tapAt44k !== tapAt48k, "the tap was not re-allocated at the new rate")
        #expect(unit.publishedTap === tapAt44k,
                "the re-allocated tap was never published onto the unit — the ring is orphaned and the meter freezes")
        #expect(tapAt44k.framesWritten == 0, "the new tap inherited sample history")
        #expect(state.unit(forEffect: effectID) === unit,
                "a rate change rebuilt the unit — DSP state was supposed to survive a re-prepare")

        // THE GEOMETRY REALLY MOVED, proven by a reading rather than by
        // reading the source: a 1 kHz tone GENERATED AT 44.1 kHz is 44.1
        // samples per cycle. An analyzer still running at 48 kHz would call
        // that 1088.4 Hz and peak on band 13; one correctly re-created at
        // 44.1 kHz peaks on band 12. So deleting `rearmTapsAtPreparedRate()`
        // moves this assertion by exactly one band.
        let at44k = Self.tone(hz: 1_000, frames: Self.renderQuanta * Self.quantum,
                              sampleRate: 44_100)
        let after = try renderAndDrain(state: state, scratch: scratch, input: at44k,
                                       quanta: Self.renderQuanta, tap: tapAt44k)
        #expect(tapAt44k.framesWritten == UInt64(Self.renderQuanta * Self.quantum))
        #expect(tapAt44k.droppedFrames == 0)
        let peak = try #require(after.bands.max())
        let peakBand = after.bands.firstIndex(of: peak)
        let staleBand = MasterMixAnalyzer.bandIndex(containing: 1_000 * 48_000 / 44_100)
        print("[measured] m23-r2b rate change 48k→44.1k: peak band \(peakBand as Any) "
              + "(\(band) = correct at 44.1 kHz, \(staleBand) = stale 48 kHz geometry), "
              + "level \(peak) dB")
        #expect(band != staleBand, "the fixture cannot discriminate the two geometries")
        #expect(peak > Self.floorDB + 20)
        #expect(peakBand == band,
                "the tap is still folding bands with the OLD sample rate's geometry")

        // The guard's other side: a chain with nothing armed must not
        // manufacture taps on a rate change.
        let bare = EffectChainState(processor: EffectChainProcessor())
        bare.sync(descriptors: descriptors, sampleRate: 48_000)
        bare.sync(descriptors: descriptors, sampleRate: 44_100)
        #expect(bare.armedEffectIDs.isEmpty)
        #expect(bare.unit(forEffect: effectID)?.publishedTap == nil)
    }

    // MARK: - 4. The `graph.analysisArms` mirror FAMILY

    /// Locates a repo source file from `#filePath` (no bundle resources) —
    /// the `CanvasContractPinTests` / `ZeroParamVerbRejectionTests` idiom.
    private func repoSource(_ relative: String) -> [String]? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relative)
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return text.components(separatedBy: "\n")
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    @Test("the analysisArms mirror family: every engine-side arm-intent mutation reaches the graph, or the next fresh chain state silently disagrees with the user")
    func mirrorFamilyKeepsTheGraphInStepWithTheIntent() throws {
        // `AudioEngine` holds the arm INTENT (`spectrumArms`) and the graph
        // holds a MIRROR it re-applies at each parameter-pass tail. r2a pinned
        // exactly one of the four mirror assignments — `:488` in
        // `wireGraphHooks`, by `armSurvivesAWholeGraphRebuild`. The other
        // three (disarm, cap-prune, arm) were collectively unpinned: deleting
        // the ARM one alone left all 4142 tests green, because the live strip
        // is armed DIRECTLY at `:1535` and nothing in the suite ever asked a
        // FRESH chain state to reproduce the intent.
        //
        // ONE leg over the family, not three hand-written site legs (standing
        // law). Two halves that fail differently:
        //  · STRUCTURAL — the family's SIZE and the "every mutation is
        //    mirrored" invariant, scraped so a FIFTH site cannot be added
        //    without landing here. A scrape proves the token exists, never the
        //    behaviour, which is why it is only half.
        //  · BEHAVIOURAL — three rows, each reddening on a DIFFERENT site.
        //
        // The two halves are INDEPENDENTLY load-bearing, which had to be shown
        // rather than assumed: deleting any one mirror site reddens BOTH halves
        // at once, so on that evidence alone the scrape could have been
        // carrying the leg. Neutering `PlaybackGraph.applyAnalysisArms()`
        // instead (invert its guard — the CONSUMER of the mirror, which the
        // scrape cannot see because it lives in a different file) reddens row 1
        // ONLY, with the scrape green. Keep both halves.
        //
        // Every row asserts the graph object is UNCHANGED. Without that the
        // rows are worthless: a rebuild re-installs the mirror from
        // `spectrumArms` through `wireGraphHooks` and masks the mutation.

        // ---- STRUCTURAL half -------------------------------------------------
        let source = try #require(repoSource("Sources/DAWEngine/AudioEngine.swift"),
                                  "could not locate AudioEngine.swift from \(#filePath)")
        // Line numbers of CODE lines only; a comment between a mutation and its
        // mirror must not count as distance (`:1527`→`:1532` is five raw lines
        // apart and four of them are the comment explaining why the mirror is
        // there).
        var codeLines: [(number: Int, text: String)] = []
        for (index, raw) in source.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
            codeLines.append((index + 1, trimmed))
        }
        let mirrorSites = codeLines.enumerated()
            .filter { $0.element.text == "graph.analysisArms = spectrumArms" }
        let intentMutations = codeLines.enumerated().filter {
            $0.element.text.hasPrefix("spectrumArms.insert(")
                || $0.element.text.hasPrefix("spectrumArms.remove(")
                || $0.element.text.hasPrefix("spectrumArms = ")
        }
        print("[measured] m23-r2b analysisArms mirror family: "
              + "\(mirrorSites.count) mirror assignments at lines "
              + "\(mirrorSites.map(\.element.number)), "
              + "\(intentMutations.count) intent mutations at lines "
              + "\(intentMutations.map(\.element.number))")
        #expect(mirrorSites.count == 4,
                "the analysisArms mirror family changed size — add a behavioural row below for the new site before re-pinning this count")
        #expect(intentMutations.count == 3,
                "`spectrumArms` gained a mutation site — every one of them must be mirrored into the graph")
        for mutation in intentMutations {
            let followers = codeLines[(mutation.offset + 1)...]
                .prefix(3).map(\.text)
            #expect(followers.contains("graph.analysisArms = spectrumArms"),
                    "the `spectrumArms` mutation at AudioEngine.swift:\(mutation.element.number) is not mirrored into the graph — a fresh chain state will disagree with the user's intent")
        }

        // ---- BEHAVIOURAL half ------------------------------------------------
        let scratch = Scratch(capacity: Self.quantum)
        let input = Self.tone(hz: 1_000, frames: Self.renderQuanta * Self.quantum)

        // ROW 1 — the ARM mirror (`:1537`). A strip whose `EffectChainState`
        // is destroyed and rebuilt loses `armedTaps` outright, while the
        // engine's intent survives; the ONLY thing that can bring the arm back
        // is the graph mirror plus the parameter-pass tail. Removing and
        // re-adding the TRACK is that event, and it involves no rebuild — the
        // first-guess "the rebuild re-arms it" mechanism is wrong.
        do {
            let effectID = UUID(), trackID = UUID()
            let track = Track(id: trackID, name: "SRC", kind: .audio,
                              effects: [gainFX(effectID)])
            let engine = AudioEngine()
            let identity = ObjectIdentifier(engine.graph)
            engine.tracksDidChange([track])
            #expect(engine.setInsertAnalysisArmed(trackID: trackID,
                                                  effectID: effectID, armed: true))
            let firstState = try #require(engine.graph.effectChainState(forTrack: trackID))
            let firstTap = try #require(firstState.analysisTap(forEffect: effectID))

            engine.tracksDidChange([])          // strip + chain state + armedTaps die
            engine.tracksDidChange([track])     // a FRESH chain state, no arms of its own
            #expect(ObjectIdentifier(engine.graph) == identity,
                    "row 1 rebuilt the graph — `wireGraphHooks` would re-install the mirror and mask the very site this row exists to pin")
            let state = try #require(engine.graph.effectChainState(forTrack: trackID))
            #expect(state !== firstState,
                    "row 1 reused the old chain state — the arm was never at risk")
            #expect(state.armedEffectIDs == [effectID],
                    "the arm did not survive a strip re-intake — the engine's arm path never mirrored the intent into the graph")
            let tap = try #require(state.analysisTap(forEffect: effectID))
            #expect(tap !== firstTap)
            // Arm → render ≥ 100 ms → poll: nominal re-arming is not enough.
            let snapshot = try renderAndDrain(state: state, scratch: scratch,
                                              input: input, quanta: Self.renderQuanta,
                                              tap: tap)
            try expectLive(tap: tap, snapshot: snapshot,
                           frames: Self.renderQuanta * Self.quantum,
                           toneHz: 1_000, label: "mirror row 1 (arm)")
        }

        // ROW 2 — the DISARM mirror (`:1514`). No strip reset needed: if the
        // disarm never reaches the mirror, the very next parameter pass
        // RE-ARMS the insert the user just closed — 230 KB and a live meter
        // resurrected behind their back.
        do {
            let effectID = UUID(), trackID = UUID()
            let track = Track(id: trackID, name: "SRC", kind: .audio,
                              effects: [gainFX(effectID)])
            let engine = AudioEngine()
            let identity = ObjectIdentifier(engine.graph)
            engine.tracksDidChange([track])
            #expect(engine.setInsertAnalysisArmed(trackID: trackID,
                                                  effectID: effectID, armed: true))
            #expect(engine.insertAnalysis(trackID: trackID, effectID: effectID) != nil)
            #expect(engine.setInsertAnalysisArmed(trackID: trackID,
                                                  effectID: effectID, armed: false))

            engine.tracksDidChange([track])     // any model edit: a parameter pass
            #expect(ObjectIdentifier(engine.graph) == identity)
            let state = try #require(engine.graph.effectChainState(forTrack: trackID))
            #expect(state.armedEffectIDs.isEmpty,
                    "a parameter pass resurrected a DISARMED insert — the disarm never reached the graph mirror")
            #expect(engine.insertAnalysis(trackID: trackID, effectID: effectID) == nil)
        }

        // ROW 3 — the CAP-PRUNE mirror (`:1532`), and it needs the ONE
        // sequence in which that assignment is observable at all: the prune
        // must be followed by a REFUSED arm, because a successful one would
        // immediately overwrite the mirror at `:1537` and the site could be
        // deleted with nothing to show for it. Sequence: fill the cap, delete
        // one armed effect from the model, then attempt an arm that must be
        // refused (unknown effect id) — that is what triggers the prune — and
        // finally bring the deleted effect back. If the prune did not reach
        // the mirror, the returning effect is silently re-armed although the
        // engine's own intent dropped it: two homes disagreeing, in the cycle
        // whose whole thesis is ONE HOME.
        do {
            let trackID = UUID()
            let ids = (0..<AudioEngine.maxArmedInsertAnalysis).map { _ in UUID() }
            let doomed = ids[5]
            func track(_ effectIDs: [UUID]) -> Track {
                Track(id: trackID, name: "SRC", kind: .audio,
                      effects: effectIDs.map { gainFX($0) })
            }
            let engine = AudioEngine()
            let identity = ObjectIdentifier(engine.graph)
            engine.tracksDidChange([track(ids)])
            for id in ids {
                #expect(engine.setInsertAnalysisArmed(trackID: trackID, effectID: id,
                                                      armed: true))
            }
            let state = try #require(engine.graph.effectChainState(forTrack: trackID))
            #expect(state.armedEffectIDs == Set(ids))

            let survivors = ids.filter { $0 != doomed }
            engine.tracksDidChange([track(survivors)])
            #expect(state.armedEffectIDs == Set(survivors),
                    "removing an effect did not drop its arm from the chain")

            // The refused arm that triggers the prune — the cap is full of
            // intent (8) even though only 7 are live.
            #expect(engine.setInsertAnalysisArmed(trackID: trackID, effectID: UUID(),
                                                  armed: true) == false,
                    "an arm on an unknown effect id was accepted — the cap sequence this row needs never happened")

            engine.tracksDidChange([track(ids)])   // the deleted effect returns
            #expect(ObjectIdentifier(engine.graph) == identity)
            #expect(engine.insertAnalysis(trackID: trackID, effectID: doomed) == nil,
                    "a pruned arm came back to life when its effect returned — the cap prune never reached the graph mirror")
            #expect(state.armedEffectIDs == Set(survivors),
                    "the graph is arming inserts the engine's intent no longer holds")
        }
    }

    // MARK: - 5. Budget leg 2 — the per-quantum cost (design §Q4)

    private static func nanoseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1e9 + Double(parts.attoseconds) / 1e9
    }

    /// Wall time of `quanta` chain walks, in nanoseconds PER QUANTUM.
    /// THE LOOP IS A `while`, NOT `for … in 0..<n`, AND MUST STAY THAT WAY:
    /// at `-Onone` the `Range` form allocates ~2 malloc/free per iteration
    /// (r1's law), which is exactly the kind of harness overhead that would
    /// swamp a sub-microsecond measurement.
    private func nsPerQuantum(_ processor: EffectChainProcessor, scratch: Scratch,
                              quanta: Int) -> Double {
        let start = ContinuousClock.now
        var call = 0
        while call < quanta {
            processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            call &+= 1
        }
        return Self.nanoseconds(start.duration(to: .now)) / Double(quanta)
    }

    /// Interleaved A/B/A/B windows, MIN per side. Min, not mean: the minimum
    /// is the robust estimator for wall-clock work — it is the run least
    /// disturbed by the scheduler — and interleaving stops a machine that
    /// gets busier mid-test from being charged entirely to whichever side ran
    /// second. (`.serialized` orders this suite's own tests; it does not stop
    /// other suites from running beside it.)
    private func interleavedMinima(a: EffectChainProcessor, b: EffectChainProcessor,
                                   scratch: Scratch, windows: Int, quanta: Int)
        -> (a: Double, b: Double) {
        var minA = Double.greatestFiniteMagnitude
        var minB = Double.greatestFiniteMagnitude
        var window = 0
        while window < windows {
            minA = min(minA, nsPerQuantum(a, scratch: scratch, quanta: quanta))
            minB = min(minB, nsPerQuantum(b, scratch: scratch, quanta: quanta))
            window &+= 1
        }
        return (minA, minB)
    }

    @Test("[budget 2] an armed insert costs ≤ 3 µs per 512-frame quantum on the render path, and a disarmed one is a load-and-branch")
    func armedInsertCostPerQuantum() throws {
        let armedID = UUID(), controlID = UUID()
        let armedChain = EffectChainState(processor: EffectChainProcessor())
        armedChain.sync(descriptors: [gainFX(armedID)], sampleRate: Self.rate)
        #expect(armedChain.setAnalysisArmed(true, forEffect: armedID))
        let tap = try #require(armedChain.analysisTap(forEffect: armedID))
        let control = EffectChainState(processor: EffectChainProcessor())
        control.sync(descriptors: [gainFX(controlID)], sampleRate: Self.rate)
        #expect(control.armedEffectIDs.isEmpty)

        let scratch = Scratch(capacity: Self.quantum)
        scratch.stage(Self.tone(hz: 1_000, frames: Self.quantum), offset: 0,
                      count: Self.quantum)
        let windows = 15, quanta = 400
        let measured = interleavedMinima(a: armedChain.processor, b: control.processor,
                                         scratch: scratch, windows: windows,
                                         quanta: quanta)
        let delta = measured.a - measured.b
        print("[measured] m23-r2b budget 2 — armed \(measured.a) ns/quantum, "
              + "disarmed \(measured.b) ns/quantum, delta \(delta) ns "
              + "(ceiling 3000 ns; design target ~200 ns for 4 KB copied)")
        // ~15× the design target on purpose: this leg guards an ARCHITECTURAL
        // regression — putting the FFT back on the render thread costs
        // 10–20 µs per hop and blows it by an order of magnitude — not a
        // microbenchmark. Loosening it to accommodate a slow machine is fine;
        // loosening it past ~10 µs makes it stop seeing the thing it exists
        // for.
        #expect(delta <= 3_000,
                "an armed insert costs \(delta) ns/quantum on the render path — the tap is doing more than copying")
        // Anti-vacuity: a tap that cost nothing BECAUSE IT NEVER RAN must not
        // pass. (No drain during the windows, so drops are expected and only
        // the write side is asserted.)
        #expect(tap.framesWritten == UInt64(windows * quanta * Self.quantum),
                "the timed walk never fed the tap — the delta above measures nothing")

        // The DISARMED hook's own cost, isolated the only honest way: eight
        // STEADILY BYPASSED units against one, disarmed on both sides. A
        // bypassed unit skips `processActive` entirely, so the per-unit delta
        // is essentially {resetFlag exchange, bypassFlag load, observeBypass,
        // the fade branch, the tapSlot acquire load and its not-taken branch}
        // — the design's "one acquire load + branch" claim, measured rather
        // than asserted. (`disarmed_delta ≤ 0.2 µs` in the design's §Q4 leg 2
        // is not measurable as literally written: the hook cannot be compiled
        // out, so there is no no-hook baseline to subtract. This is the
        // substitute, and it is labelled as one.)
        let wide = EffectChainState(processor: EffectChainProcessor())
        wide.sync(descriptors: (0..<8).map { _ in gainFX(UUID(), bypassed: true) },
                  sampleRate: Self.rate)
        let narrow = EffectChainState(processor: EffectChainProcessor())
        narrow.sync(descriptors: [gainFX(UUID(), bypassed: true)],
                    sampleRate: Self.rate)
        let bypassed = interleavedMinima(a: wide.processor, b: narrow.processor,
                                         scratch: scratch, windows: windows,
                                         quanta: quanta)
        let perUnit = (bypassed.a - bypassed.b) / 7
        print("[measured] m23-r2b budget 2 — disarmed bypassed walk: "
              + "8 units \(bypassed.a) ns/quantum, 1 unit \(bypassed.b) ns/quantum, "
              + "\(perUnit) ns per disarmed unit per quantum (design ≤ 100 ns)")
        // The design's own ≤ 100 ns, KEPT rather than widened, deliberately —
        // this is the one bound in the file with less than an order of
        // magnitude of headroom, so the choice is written down:
        //
        //  * Measured 14.3–16.2 ns across six runs (min-of-15-windows, spread
        //    ~2 ns) ⇒ ~6× headroom. Preemption noise enters the derived number
        //    DIVIDED BY 7, and only from the 8-unit side; for this to reach
        //    100 ns that window's min would have to inflate by ~600
        //    ns/quantum, which a min-of-15 estimator does not do quietly.
        //  * The bound is STRICTER than the design literally requires, because
        //    the measurement is a SUPERSET of the hook (it also carries the
        //    reset exchange, the bypass load, `observeBypass` and the fade
        //    branch). That is the argument for widening — and it is refused
        //    because the realistic regressions sit right at the line: a heap
        //    allocation per unit per quantum, a bridged ObjC send, or a
        //    dictionary lookup are all ~30–100 ns, so a 200 ns bound would
        //    wave every one of them through.
        //  * What it does NOT catch, stated so nobody trusts it further than
        //    it goes: an uncontended `os_unfair_lock` pair (~15–20 ns) fits
        //    under 100 ns. Locks on the render path are r2a's territory and
        //    the allocation leg's; this leg is an ORDER-OF-MAGNITUDE guard.
        #expect(perUnit <= 100,
                "a DISARMED insert costs \(perUnit) ns per quantum — idle inserts are supposed to pay a load and a branch")
    }

    // MARK: - 5. Budget leg 3 — N-scaling at the enforced cap

    @Test("[budget 3] eight armed inserts in ONE chain stay inside 24 µs/quantum, all eight read live, and the ninth arm is REFUSED with its tap slot nil")
    func eightArmedInsertsScaleAndTheNinthIsRefused() throws {
        let cap = AudioEngine.maxArmedInsertAnalysis
        #expect(cap == 8, "the design's N = 8 budget is keyed to this cap")

        // POSITIVE — all `cap` taps live at once, drained on the r1 cadence so
        // `droppedFrames == 0` is a premise and not an excuse. Each insert has
        // exactly ONE consumer: `insertAnalysis` DRAINS, so a second poller on
        // the same insert would split the stream and BOTH readings would run
        // slow with nothing reported anywhere.
        let liveIDs = (0..<cap).map { _ in UUID() }
        let live = EffectChainState(processor: EffectChainProcessor())
        live.sync(descriptors: liveIDs.map { gainFX($0) }, sampleRate: Self.rate)
        var taps: [InsertSpectrumTap] = []
        for id in liveIDs {
            #expect(live.setAnalysisArmed(true, forEffect: id))
            taps.append(try #require(live.analysisTap(forEffect: id)))
        }
        #expect(live.armedEffectIDs.count == cap)

        let scratch = Scratch(capacity: Self.quantum)
        let input = Self.tone(hz: 1_000, frames: Self.renderQuanta * Self.quantum)
        var snapshots = [MasterAnalysisSnapshot](repeating: .floor, count: cap)
        var index = 0
        while index < Self.renderQuanta {
            scratch.stage(input, offset: index * Self.quantum, count: Self.quantum)
            live.processor.process(bufferList: scratch.raw, frameCount: Self.quantum)
            if index % Self.drainEveryQuanta == Self.drainEveryQuanta - 1 {
                var slot = 0
                while slot < cap {
                    snapshots[slot] = taps[slot].drainAndSnapshot()
                    slot &+= 1
                }
            }
            index &+= 1
        }
        let band = MasterMixAnalyzer.bandIndex(containing: 1_000)
        for (slot, tap) in taps.enumerated() {
            #expect(tap.framesWritten == UInt64(Self.renderQuanta * Self.quantum),
                    "armed insert \(slot) never saw the walk")
            #expect(tap.droppedFrames == 0, "armed insert \(slot) fell behind")
            let peak = try #require(snapshots[slot].bands.max())
            #expect(peak > Self.floorDB + 20,
                    "armed insert \(slot) drained floor — N taps do not all work")
            #expect(snapshots[slot].bands.firstIndex(of: peak) == band)
        }

        // COST at N = 8, against an identically shaped DISARMED chain.
        let armedIDs = (0..<cap).map { _ in UUID() }
        let armed = EffectChainState(processor: EffectChainProcessor())
        armed.sync(descriptors: armedIDs.map { gainFX($0) }, sampleRate: Self.rate)
        for id in armedIDs { #expect(armed.setAnalysisArmed(true, forEffect: id)) }
        let control = EffectChainState(processor: EffectChainProcessor())
        control.sync(descriptors: (0..<cap).map { _ in gainFX(UUID()) },
                     sampleRate: Self.rate)
        let windows = 15, quanta = 400
        let measured = interleavedMinima(a: armed.processor, b: control.processor,
                                         scratch: scratch, windows: windows,
                                         quanta: quanta)
        let delta = measured.a - measured.b
        print("[measured] m23-r2b budget 3 — N = \(cap): armed \(measured.a) ns/quantum, "
              + "disarmed \(measured.b) ns/quantum, aggregate delta \(delta) ns "
              + "(ceiling 24000 ns; design target ~1600 ns)")
        #expect(delta <= 24_000,
                "\(cap) armed inserts cost \(delta) ns/quantum aggregate")
        let armedTap = try #require(armed.analysisTap(forEffect: armedIDs[0]))
        #expect(armedTap.framesWritten == UInt64(windows * quanta * Self.quantum),
                "the timed walk never fed the taps")

        // NEGATIVE — the cap REFUSES, never evicts. It lives in `AudioEngine`,
        // not in `EffectChainState`, so this half must go through the public
        // engine surface.
        let trackID = UUID()
        let effectIDs = (0..<(cap + 1)).map { _ in UUID() }
        let track = Track(id: trackID, name: "SRC", kind: .audio,
                          effects: effectIDs.map { gainFX($0) })
        let engine = AudioEngine()
        engine.tracksDidChange([track])
        for id in effectIDs.prefix(cap) {
            #expect(engine.setInsertAnalysisArmed(trackID: trackID, effectID: id,
                                                  armed: true))
        }
        let ninth = effectIDs[cap]
        #expect(engine.setInsertAnalysisArmed(trackID: trackID, effectID: ninth,
                                              armed: false) == true,
                "disarming beyond the cap must still report the requested state")
        #expect(engine.setInsertAnalysisArmed(trackID: trackID, effectID: ninth,
                                              armed: true) == false,
                "the \(cap + 1)th arm was accepted — the memory bound is a hope, not a bound")
        let state = try #require(engine.graph.effectChainState(forTrack: trackID))
        let ninthUnit = try #require(state.unit(forEffect: ninth))
        #expect(ninthUnit.publishedTap == nil,
                "the refused arm still published a tap — REFUSE-DON'T-CORRUPT was not honoured")
        #expect(state.analysisTap(forEffect: ninth) == nil)
        #expect(engine.insertAnalysis(trackID: trackID, effectID: ninth) == nil)
        // …and REFUSING means the eight that were already there keep working:
        // eviction would silently stop a meter the user is looking at.
        #expect(state.armedEffectIDs == Set(effectIDs.prefix(cap)))

        // The parameter pass that follows the refusal must not smuggle it in
        // through the mirror either.
        engine.tracksDidChange([track])
        #expect(engine.insertAnalysis(trackID: trackID, effectID: ninth) == nil)
        #expect(state.armedEffectIDs == Set(effectIDs.prefix(cap)))
    }
}
