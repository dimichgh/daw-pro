import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-w4-4 — THE MUSICAL CLOCK, the nonisolated half (design
/// `docs/design/2026-10-07-loop-drum-depth.md` §4.2, §9.2).
///
/// What lives here: the clock's compile (K1), the §4.2 alignment claim stated
/// literally against the REAL MIDI schedule (A1), the no-state law (A2), the
/// free-running invariance (A3), zero allocation on the evaluator (G7a), and an
/// env-gated cost measurement (T1, `W44_TIMING=1`). The render-level gates
/// (G1–G7 through the graph and the bounce) are appended to
/// `AutomationEngineTests`, which is `@MainActor` and already owns the
/// modulation render gates.
///
/// ⭐ A1 is the one to read first. It does not re-derive the MIDI schedule's
/// rounding: it builds a clip with a note on every sixteenth, runs it through
/// `MIDIEventSchedule.buildEvents` — the head pass and the loop-cycle blocks with
/// the builders' own offset expression — and reads the synced source AT EACH
/// NOTE-ON FRAME. Every hit must read the step it was written on.
@Suite("Modulation clock (m39-w4-4): compile, MIDI alignment, no state, zero allocation")
struct ModulationClockTests {
    static let rate = 48_000.0

    /// 16 distinct values: an off-by-one step is a wrong VALUE, never a coincidence.
    static let sixteenDistinct: [Double] = (0..<16).map { Double($0) / 16 - 0.5 }
    /// 5 distinct values: 64 sixteenths (bar 5 of 4/4) is 4 mod 5, so the
    /// pattern restart at a meter change is visible.
    static let fiveDistinct: [Double] = [-0.5, -0.25, 0, 0.25, 0.5]

    static func g2TempoMap() throws -> TempoMap {
        try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 8, bpm: 90)])
    }

    static func g2MeterMap() throws -> MeterMap {
        try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                               .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])
    }

    static func syncedSource(steps: [Double], division: String = "1/16",
                             edgeMs: Double = 0) -> ModulationSource {
        ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: steps, stepDivision: division, rateHz: 4, edgeMs: edgeMs)))
    }

    static func freeSource(steps: [Double] = [1, 0, 0.5, -0.5, 0.25], rateHz: Double = 7.3,
                           edgeMs: Double = 3) -> ModulationSource {
        ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: steps, rateHz: rateHz, edgeMs: edgeMs)))
    }

    /// The loop spec exactly as `PlaybackGraph` derives it from
    /// `LoopUnrollState` (whose constants `AudioEngine`/`buildLoopUnroll`
    /// compute with these two calls).
    static func spec(tempoMap: TempoMap, meterMap: MeterMap = MeterMap(constant: TimeSignature()),
                     fromBeat: Double, loop: (start: Double, end: Double)? = nil,
                     rate: Double = rate) -> ModulationClockSpec {
        ModulationClockSpec(
            fromBeat: fromBeat, tempoMap: tempoMap, meterMap: meterMap,
            loop: loop.map {
                ModulationClockSpec.Loop(startBeat: $0.start, endBeat: $0.end,
                                         headSeconds: tempoMap.seconds(from: fromBeat, to: $0.end),
                                         cycleSeconds: tempoMap.seconds(from: $0.start, to: $0.end))
            },
            sampleRate: rate)
    }

    /// `PlaybackGraph.modulationOrigin`'s expression.
    static func originSample(_ spec: ModulationClockSpec) -> Int64 {
        Int64((spec.tempoMap.seconds(from: 0, to: spec.fromBeat) * spec.sampleRate).rounded())
    }

    static func snapshot(_ sources: [ModulationSource], spec: ModulationClockSpec?,
                         rate: Double = rate, origin: Int64 = 0,
                         positionValid: Bool = true) -> ModulationSnapshot? {
        let routes = sources.map { ModulationRoute(sourceID: $0.id, target: .volume, depth: 0.1) }
        return ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(sources: sources, routes: routes),
            generation: 1, timelineID: 1, sampleRate: rate, originSample: origin,
            positionValid: positionValid, clock: spec)
    }

    /// The source's value at ROLL frame `n`, through the render-side evaluator.
    static func read(_ snapshot: ModulationSnapshot, source index: Int = 0, rollFrame n: Int64) -> Double {
        ModulationEvaluator.value(of: snapshot.sources[index], atSample: snapshot.originSample &+ n,
                                  positionValid: snapshot.positionValid, snapshot: snapshot,
                                  followerEnvelope: 0)
    }

    // MARK: - K1: compile

    @Test("K1: segments split at the roll anchor, every tempo and meter change, and the loop's cycle template")
    func compileSplitsWhereTheDesignSays() throws {
        let tempo = try Self.g2TempoMap()
        let meter = try Self.g2MeterMap()
        let linear = ModulationSnapshotBuilder.compileClock(
            Self.spec(tempoMap: tempo, meterMap: meter, fromBeat: 2))
        #expect(linear.headCount == 3)
        let linearBeats: [Double] = [2, 8, 16]
        let linearSeconds: [Double] = [0, 3, tempo.seconds(from: 2, to: 16)]
        let linearRates: [Double] = [1.0 / 24_000, 1.0 / 32_000, 1.0 / 32_000]
        let linearOrigins: [Double] = [0, 0, 16]
        #expect(linear.segments.map(\.startBeat) == linearBeats)
        #expect(linear.segments.map(\.startSeconds) == linearSeconds)
        #expect(linear.segments.map(\.beatsPerSample) == linearRates)
        #expect(linear.segments.map(\.patternOriginBeat) == linearOrigins)
        #expect(linear.loopHeadSeconds == 0 && linear.loopCycleSeconds == 0)

        let looped = ModulationSnapshotBuilder.compileClock(
            Self.spec(tempoMap: tempo, meterMap: meter, fromBeat: 2, loop: (6, 14)))
        #expect(looped.headCount == 2, "the meter change at 16 is past the loop end: not in the head")
        let loopedBeats: [Double] = [2, 8, 6, 8]
        let loopedSeconds: [Double] = [0, 3, 0, 1]
        #expect(looped.segments.map(\.startBeat) == loopedBeats)
        #expect(looped.segments.map(\.startSeconds) == loopedSeconds)
        #expect(looped.loopHeadSeconds == tempo.seconds(from: 2, to: 14))
        #expect(looped.loopCycleSeconds == tempo.seconds(from: 6, to: 14))

        // Nothing the render thread could not use survives the compile.
        #expect(ModulationSnapshotBuilder.compileClock(
            Self.spec(tempoMap: tempo, fromBeat: 0, rate: 0)) == .empty)
        // A strip without a synced source carries no clock even when handed one.
        let free = try #require(Self.snapshot([Self.freeSource()],
                                              spec: Self.spec(tempoMap: tempo, fromBeat: 0)))
        #expect(free.clock.count == 0 && free.clockHeadCount == 0)
        let synced = try #require(Self.snapshot([Self.syncedSource(steps: Self.sixteenDistinct)],
                                                spec: Self.spec(tempoMap: tempo, fromBeat: 0)))
        #expect(synced.clock.count == 2 && synced.clockHeadCount == 2)
        #expect(synced.sources[0].divisionBeats == 0.25)
    }

    @Test("K1: only a recognised NoteDivision syncs; a hand-edited garbage division runs free exactly as before")
    func onlyARecognisedDivisionSyncs() throws {
        let garbage = ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, 0], stepDivision: "1/17", rateHz: 4)))
        let strip = { (sources: [ModulationSource]) in
            ModulationSnapshotBuilder.Strip(sources: sources, routes: [])
        }
        #expect(!ModulationSnapshotBuilder.hasSyncedSource(strip([garbage])))
        #expect(!ModulationSnapshotBuilder.hasSyncedSource(strip([Self.freeSource()])))
        #expect(ModulationSnapshotBuilder.hasSyncedSource(
            strip([Self.freeSource(), Self.syncedSource(steps: [1, 0])])))
        for division in NoteDivision.allCases {
            let params = StepSequencerSourceParams(steps: [1], stepDivision: division.rawValue)
            #expect(params.syncedDivision == division)
        }
        let snap = try #require(Self.snapshot([garbage], spec: Self.spec(
            tempoMap: TempoMap(constantBPM: 120), fromBeat: 0)))
        #expect(snap.sources[0].divisionBeats == 0)
        #expect(snap.clock.count == 0)
    }

    // MARK: - A1: the §4.2 alignment claim, against the real MIDI schedule

    struct Alignment {
        var hits = 0
        var wrongAtHit = 0
        var checkedBefore = 0
        var wrongBefore = 0
        var ties = 0
        var scheduleMismatch = 0
        var firstWrong: String?
    }

    /// A clip at beat 0 with a note on every sixteenth below `lastBeat`; the note
    /// index rides in pitch and velocity so each note-on names its own beat.
    static func sixteenthsClip(lastBeat: Double) -> Clip {
        var notes: [MIDINote] = []
        var index = 0
        while Double(index) * 0.25 < lastBeat {
            notes.append(MIDINote(pitch: index % 128, velocity: 1 + index / 128,
                                  startBeat: Double(index) * 0.25, lengthBeats: 0.125))
            index += 1
        }
        return Clip(name: "sixteenths", startBeat: 0, lengthBeats: lastBeat + 1, notes: notes)
    }

    /// The step a beat was written on: the pattern restarts at every meter
    /// change (§4.2 "Where a pattern starts").
    static func authoredIndex(beat: Double, meterMap: MeterMap, count: Int) -> Int {
        let origin = meterMap.changes.last { $0.startBeat <= beat }?.startBeat ?? 0
        let k = Int(((beat - origin) / 0.25).rounded())
        return ((k % count) + count) % count
    }

    static func align(spec: ModulationClockSpec, steps: [Double], edgeMs: Double,
                      lastBeat: Double, throughCycle: Int = 0) throws -> Alignment {
        let clip = sixteenthsClip(lastBeat: lastBeat)
        let origin = originSample(spec)
        let snap = try #require(Self.snapshot([syncedSource(steps: steps, edgeMs: edgeMs)], spec: spec,
                                              rate: spec.sampleRate, origin: origin))
        var blocks: [(fromBeat: Double, offsetSeconds: Double, events: [ScheduledMIDIEvent])] = []
        let head = MIDIEventSchedule.buildEvents(clips: [clip], fromBeat: spec.fromBeat,
                                                 tempoMap: spec.tempoMap, sampleRate: spec.sampleRate,
                                                 onsetEndBeat: spec.loop?.endBeat)
        blocks.append((spec.fromBeat, 0, head.events))
        if let loop = spec.loop, throughCycle >= 1 {
            var cycle = 1
            while cycle <= throughCycle {
                // The builders' expression, verbatim (PlaybackGraph.extendLoopMIDI).
                let offset = loop.headSeconds + Double(cycle - 1) * loop.cycleSeconds
                let block = MIDIEventSchedule.buildEvents(
                    clips: [clip], fromBeat: loop.startBeat, tempoMap: spec.tempoMap,
                    sampleRate: spec.sampleRate, onsetEndBeat: loop.endBeat, offsetSeconds: offset)
                blocks.append((loop.startBeat, offset, block.events))
                cycle += 1
            }
        }
        var result = Alignment()
        let count = steps.count
        for block in blocks {
            for event in block.events where event.kind == ScheduledMIDIEvent.noteOn {
                let index = Int(event.pitch) + 128 * (Int(event.velocity) - 1)
                let beat = Double(index) * 0.25
                let exact = (block.offsetSeconds
                    + spec.tempoMap.seconds(from: block.fromBeat, to: beat)) * spec.sampleRate
                if Int64(exact.rounded()) != event.sampleTime { result.scheduleMismatch += 1 }
                let n = event.sampleTime
                let k = authoredIndex(beat: beat, meterMap: spec.meterMap, count: count)
                let expected = Double(Float(steps[k]))
                let atHit = read(snap, rollFrame: n)
                result.hits += 1
                if abs(atHit - expected) > 1e-9 {
                    result.wrongAtHit += 1
                    if result.firstWrong == nil {
                        result.firstWrong = "beat \(beat) frame \(n): read \(atHit), wrote \(expected)"
                    }
                }
                // Frame N − 1 belongs to the step before: on a hard edge only,
                // and except at an exact tie (x = m + 0.5), where the clock's
                // frame-centre boundary flips one frame before `round` does.
                guard edgeMs == 0 else { continue }
                if exact - exact.rounded(.down) == 0.5 { result.ties += 1; continue }
                let isCycleBlock = block.offsetSeconds > 0
                var previousBeat = beat - 0.25
                if isCycleBlock, let loop = spec.loop, beat == loop.startBeat {
                    previousBeat = loop.endBeat - 0.25   // the wrap: the pass before ended here
                }
                if !isCycleBlock, previousBeat < spec.fromBeat { continue }   // before the roll
                let previous = Double(Float(steps[authoredIndex(beat: previousBeat,
                                                                meterMap: spec.meterMap, count: count)]))
                result.checkedBefore += 1
                if read(snap, rollFrame: n - 1) != previous {
                    result.wrongBefore += 1
                    if result.firstWrong == nil {
                        result.firstWrong = "frame before beat \(beat) (\(n - 1)) read "
                            + "\(read(snap, rollFrame: n - 1)), expected \(previous)"
                    }
                }
            }
        }
        return result
    }

    @Test("⭐ A1: every note-on frame of the REAL MIDI schedule reads the step it was written on — 90/120/174 BPM, a tempo change, a meter change, a roll from beat 3.25, three loop cycles")
    func everyHitReadsItsOwnStep() throws {
        let g2 = try Self.g2TempoMap()
        let meter = try Self.g2MeterMap()
        let cases: [(name: String, spec: ModulationClockSpec, steps: [Double], lastBeat: Double, cycles: Int)] = [
            ("120", Self.spec(tempoMap: TempoMap(constantBPM: 120), fromBeat: 0), Self.sixteenDistinct, 16, 0),
            ("90", Self.spec(tempoMap: TempoMap(constantBPM: 90), fromBeat: 0), Self.sixteenDistinct, 16, 0),
            ("174", Self.spec(tempoMap: TempoMap(constantBPM: 174), fromBeat: 0), Self.sixteenDistinct, 16, 0),
            ("120→90@8 + 3/4@16, 16 steps", Self.spec(tempoMap: g2, meterMap: meter, fromBeat: 0),
             Self.sixteenDistinct, 28, 0),
            ("120→90@8 + 3/4@16, 5 steps", Self.spec(tempoMap: g2, meterMap: meter, fromBeat: 0),
             Self.fiveDistinct, 28, 0),
            ("from beat 3.25", Self.spec(tempoMap: g2, meterMap: meter, fromBeat: 3.25),
             Self.fiveDistinct, 24, 0),
            ("loop 1.5→12 @120", Self.spec(tempoMap: TempoMap(constantBPM: 120), fromBeat: 1.5,
                                         loop: (1.5, 12)), Self.fiveDistinct, 13, 3),
            ("loop 6→14 across 120→90", Self.spec(tempoMap: g2, fromBeat: 4, loop: (6, 14)),
             Self.fiveDistinct, 15, 3),
            ("loop 6→14 @174", Self.spec(tempoMap: TempoMap(constantBPM: 174), fromBeat: 4,
                                       loop: (6, 14)), Self.sixteenDistinct, 15, 3),
        ]
        for edgeMs in [0.0, 2.0] {
            for item in cases {
                let result = try Self.align(spec: item.spec, steps: item.steps, edgeMs: edgeMs,
                                            lastBeat: item.lastBeat, throughCycle: item.cycles)
                print("[measured] W44 A1 \(item.name) edgeMs \(edgeMs): hits \(result.hits), wrong at hit "
                      + "\(result.wrongAtHit), frame-before checked \(result.checkedBefore) wrong "
                      + "\(result.wrongBefore), ties \(result.ties), schedule mismatch "
                      + "\(result.scheduleMismatch)\(result.firstWrong.map { " — first: \($0)" } ?? "")")
                #expect(result.hits > 0, "\(item.name): no note-on reached the check")
                #expect(result.scheduleMismatch == 0, "\(item.name): the test's own frame math is not the schedule's")
                #expect(result.wrongAtHit == 0, "\(item.name) edgeMs \(edgeMs): \(result.firstWrong ?? "")")
                #expect(result.wrongBefore == 0, "\(item.name) edgeMs \(edgeMs): \(result.firstWrong ?? "")")
                if edgeMs == 0 { #expect(result.checkedBefore > 0) }
            }
        }
    }

    @Test("A1: at 44.1 kHz and 120 BPM every other sixteenth is an exact tie — the hit still reads its own step")
    func aTieStillLatchesTheHitsOwnStep() throws {
        let spec = Self.spec(tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, rate: 44_100)
        let result = try Self.align(spec: spec, steps: Self.sixteenDistinct, edgeMs: 0, lastBeat: 8)
        print("[measured] W44 A1 44.1k ties: hits \(result.hits), ties \(result.ties), wrong at hit "
              + "\(result.wrongAtHit), frame-before wrong \(result.wrongBefore)")
        #expect(result.ties > 0, "the fixture must contain ties (5 512.5 frames per sixteenth)")
        #expect(result.wrongAtHit == 0, "\(result.firstWrong ?? "")")
        #expect(result.wrongBefore == 0, "\(result.firstWrong ?? "")")
    }

    // MARK: - A2: no state

    @Test("A2: the synced source keeps NO state — random-order reads equal a playthrough, bit for bit, across loop wraps")
    func syncedReadsAreStateless() throws {
        let tempo = try Self.g2TempoMap()
        let spec = Self.spec(tempoMap: tempo, meterMap: try Self.g2MeterMap(), fromBeat: 4, loop: (6, 14))
        let source = Self.syncedSource(steps: Self.fiveDistinct, edgeMs: 2)
        let origin = Self.originSample(spec)
        let a = try #require(Self.snapshot([source], spec: spec, origin: origin))
        let frames = Int64(18 * Self.rate)
        var sequential: [UInt64] = []
        var n: Int64 = 0
        while n < frames {
            sequential.append(Self.read(a, rollFrame: n).bitPattern)
            n += 7
        }
        // A FRESH snapshot read in a scrambled order (deterministic LCG).
        let b = try #require(Self.snapshot([source], spec: spec, origin: origin))
        var order = Array(sequential.indices)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var i = order.count - 1
        while i > 0 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let j = Int(state >> 33) % (i + 1)
            order.swapAt(i, j)
            i -= 1
        }
        var differing = 0
        for index in order where Self.read(b, rollFrame: Int64(index) * 7).bitPattern != sequential[index] {
            differing += 1
        }
        // And the scrambled pass again on the FIRST snapshot, after its playthrough.
        for index in order where Self.read(a, rollFrame: Int64(index) * 7).bitPattern != sequential[index] {
            differing += 1
        }
        print("[measured] W44 A2: \(differing) differing of \(2 * sequential.count) scrambled reads")
        #expect(differing == 0)
    }

    // MARK: - A3: free-running invariance

    @Test("A3: a FREE-RUNNING step source reads bit-identically with a clock in its snapshot, without one, and against the closed form")
    func freeRunningIgnoresTheClock() throws {
        let tempo = try Self.g2TempoMap()
        let spec = Self.spec(tempoMap: tempo, meterMap: try Self.g2MeterMap(), fromBeat: 4, loop: (6, 14))
        let free = Self.freeSource()
        let origin = Self.originSample(spec)
        // With a synced sibling, so the snapshot really carries a clock.
        let withClock = try #require(Self.snapshot([free, Self.syncedSource(steps: [1, 0])],
                                                   spec: spec, origin: origin))
        #expect(withClock.clock.count > 0)
        let without = try #require(Self.snapshot([free], spec: nil, origin: origin))
        #expect(without.clock.count == 0)
        let samplesPerStep = Self.rate / 7.3
        let edgeFraction = min(3 * 0.001 * Self.rate / samplesPerStep, 0.98)
        var differing = 0
        var closedFormDiffering = 0
        var n: Int64 = 0
        while n < Int64(18 * Self.rate) {
            let a = Self.read(withClock, rollFrame: n)
            let b = Self.read(without, rollFrame: n)
            if a.bitPattern != b.bitPattern { differing += 1 }
            let closed = ModulationMath.stepSequencer(
                stepPosition: Double(origin &+ n) / samplesPerStep,
                steps: [1, 0, 0.5, -0.5, 0.25], edgeFraction: edgeFraction)
            if a.bitPattern != closed.bitPattern { closedFormDiffering += 1 }
            n += 11
        }
        print("[measured] W44 A3: free-running with vs without a clock: \(differing) differing; "
              + "vs closed form: \(closedFormDiffering)")
        #expect(differing == 0)
        #expect(closedFormDiffering == 0)
    }

    @Test("A3: a synced source with no clock (not rolling, or no spec) holds neutral, never free-runs")
    func syncedWithoutAClockHoldsNeutral() throws {
        let source = Self.syncedSource(steps: [1, -1])
        let noSpec = try #require(Self.snapshot([source], spec: nil))
        let stopped = try #require(Self.snapshot([source], spec: Self.spec(
            tempoMap: TempoMap(constantBPM: 120), fromBeat: 0), positionValid: false))
        var nonNeutral = 0
        var n: Int64 = 0
        while n < 96_000 {
            if Self.read(noSpec, rollFrame: n) != ModulationEvaluator.neutral { nonNeutral += 1 }
            if Self.read(stopped, rollFrame: n) != ModulationEvaluator.neutral { nonNeutral += 1 }
            n += 97
        }
        #expect(nonNeutral == 0)
    }

    // MARK: - G7a: zero allocation on the evaluator

    // The hook, the counter cells and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe): one measurement at a time.
    // `warmup:` runs with the hook live and the counter is zeroed after it.

    @Test("G7a: four synced sources summed per sample across a tempo change, a meter change and loop wraps allocate NOTHING")
    func fourSyncedSourcesAllocateNothing() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        let spec = Self.spec(tempoMap: try Self.g2TempoMap(), meterMap: try Self.g2MeterMap(),
                             fromBeat: 4, loop: (6, 14))
        let sources = [Self.syncedSource(steps: Self.sixteenDistinct, edgeMs: 2),
                       Self.syncedSource(steps: Self.fiveDistinct, division: "1/8t", edgeMs: 0),
                       Self.syncedSource(steps: [1, 0, 1], division: "1/4d", edgeMs: 5),
                       Self.syncedSource(steps: [-1, 1], division: "1/32", edgeMs: 1)]
        let snap = try #require(Self.snapshot(sources, spec: spec, origin: Self.originSample(spec)))
        let origin = snap.originSample
        // Starts 1 000 frames before cycle 1 and covers it: a wrap inside the run.
        let firstFrame = Int64(spec.loop!.headSeconds * Self.rate) - 1_000
        var sink = 0.0
        let events = MallocProbe.events(slot: slot, warmup: {
            sink += ModulationEvaluator.sum(forTargetAt: 0, snapshot: snap,
                                            atSample: origin &+ firstFrame, positionValid: true)
        }) {
            var n = firstFrame
            let end = firstFrame + 16 * 512
            while n < end {
                sink += ModulationEvaluator.sum(forTargetAt: 0, snapshot: snap,
                                                atSample: origin &+ n, positionValid: true)
                n += 1
            }
        }
        let control = MallocProbe.events(slot: slot) {
            var array: [Int] = []
            var index = 0
            while index < 200 { array.append(index); index += 1 }
            sink += Double(array.count)
        }
        print("[measured] W44 G7a: \(events) malloc events over 8 192 samples × 4 synced sources "
              + "(control \(control)); sink \(sink.isFinite)")
        #expect(events == 0)
        #expect(control > 0, "the probe cannot see an allocation: the zero above proves nothing")
    }

    // MARK: - T1: cost (env-gated)

    /// §13.2 lists the clock's per-sample cost as unverified. This measures it
    /// against the free-running path, INTERLEAVED (A, B, A, B …) so machine load
    /// hits both alike; the medians and their ratio are printed. It does not run
    /// under `timing.lock`, so the absolute numbers are an upper bound on a busy
    /// machine; the RATIO is the robust figure. Opt in with `W44_TIMING=1`.
    @Test("T1: synced vs free-running evaluation cost per sample and per 512-frame block (W44_TIMING=1)",
          .enabled(if: ProcessInfo.processInfo.environment["W44_TIMING"] == "1"))
    func clockCostPerBlock() throws {
        let block = 512
        let blocks = 400
        var report: [String] = []
        for changes in [0, 7, 63] {
            var segments: [TempoMap.Segment] = [.init(startBeat: 0, bpm: 120)]
            var index = 1
            while index <= changes {
                segments.append(.init(startBeat: Double(index) * 2, bpm: 90 + Double(index % 7) * 10))
                index += 1
            }
            let spec = Self.spec(tempoMap: try TempoMap(segments: segments), fromBeat: 0, loop: (0, 200))
            let synced = try #require(Self.snapshot([Self.syncedSource(steps: Self.sixteenDistinct, edgeMs: 2)],
                                                    spec: spec))
            let free = try #require(Self.snapshot([Self.freeSource()], spec: nil))
            var syncedTimes: [Double] = []
            var freeTimes: [Double] = []
            var sink = 0.0
            var round = 0
            let clock = ContinuousClock()
            while round < 9 {
                for which in [true, false] {
                    let snapshot = which ? synced : free
                    let elapsed = clock.measure {
                        var b = 0
                        while b < blocks {
                            var n = Int64(b * block) * 97
                            let end = n + Int64(block)
                            while n < end {
                                sink += ModulationEvaluator.sum(forTargetAt: 0, snapshot: snapshot,
                                                                atSample: n, positionValid: true)
                                n += 1
                            }
                            b += 1
                        }
                    }
                    let seconds = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) * 1e-18
                    let nsPerSample = seconds * 1e9 / Double(blocks * block)
                    if which { syncedTimes.append(nsPerSample) } else { freeTimes.append(nsPerSample) }
                }
                round += 1
            }
            let median = { (values: [Double]) in values.sorted()[values.count / 2] }
            let syncedNs = median(syncedTimes)
            let freeNs = median(freeTimes)
            let blockMicros = syncedNs * Double(block) / 1_000
            let budgetMicros = Double(block) / Self.rate * 1e6
            report.append("segments \(synced.clock.count) (head \(synced.clockHeadCount)): synced "
                + String(format: "%.1f", syncedNs) + " ns/sample, free "
                + String(format: "%.1f", freeNs) + " ns/sample, ratio "
                + String(format: "%.2f", syncedNs / freeNs) + "; one synced source costs "
                + String(format: "%.2f", blockMicros) + " µs per 512-frame block = "
                + String(format: "%.3f", 100 * blockMicros / budgetMicros) + " % of its "
                + String(format: "%.0f", budgetMicros) + " µs budget (sink \(sink.isFinite))")
        }
        for line in report { print("[measured] W44 T1 (busy machine, not under timing.lock) \(line)") }
        #expect(report.count == 3)
    }
}
