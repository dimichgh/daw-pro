import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// MARK: - Offline metronome rig (the GaplessLoopMetronomeTests idiom)

private let lrRate = 48_000.0
private let lrQuantum = 512

@MainActor
private struct LoopRecordClickRig {
    let engine: AVAudioEngine
    let metronome: Metronome

    init() throws {
        engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: lrRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        metronome = Metronome()
        metronome.attach(to: engine)
        try engine.start()
    }

    /// Pulls `frames`, ticking `tick(renderedSeconds)` every third quantum —
    /// the live ~32 ms playhead cadence that drives the loop click top-up.
    func render(frames: Int, into channelData: inout [[Float]],
                tick: (Double) -> Void) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        var pulls = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, lrQuantum))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
            pulls += 1
            if pulls % 3 == 0 {
                tick(Double(rendered) / lrRate)
            }
        }
    }
}

/// True when a click SOUNDS at `seconds`: click buffers start at exactly 0
/// (5 ms linear attack from silence), so the first nonzero sample of a click
/// scheduled at `round(t·rate)` is one frame later.
private func clickPresent(_ output: [[Float]], atSeconds t: Double) -> Bool {
    let onset = Int((t * lrRate).rounded()) + 1
    guard onset < output[0].count else { return false }
    return output[0][onset] != 0
}

/// Every nonzero sample must fall inside one of the expected click windows
/// [onset, onset + 30 ms] — placement-exact: a misplaced, starved, or extra
/// click fails this. Returns the offending sample index, nil when clean.
private func firstStray(_ output: [[Float]], expectedClickSeconds: [Double]) -> Int? {
    let clickFrames = Int((0.030 * lrRate).rounded()) + 2
    let windows = expectedClickSeconds.map { t -> ClosedRange<Int> in
        let onset = Int((t * lrRate).rounded())
        return onset...(onset + clickFrames)
    }
    for (i, sample) in output[0].enumerated() where sample != 0 {
        if !windows.contains(where: { $0.contains(i) }) { return i }
    }
    return nil
}

// MARK: - The gates

/// m15-b — the engine half of loop-cycle take recording (design-m15b §5):
///  · the suppression lift: a loop-enabled take schedules WITH the window
///    (LoopContext non-nil while recording; playhead wraps modularly),
///  · G4 — the MIDI stop clamp is LINEAR: a note held across a live wrap
///    ends at its true linear beat, never the 0.001-beat collapse,
///  · G6 — count-in × loop reconciliation: the click unroll offset is
///    −countIn.delaySeconds and the loop click plan's head is
///    `delay + integral(recordBeat → loopEnd)` (the LOOKUP policy), with
///    offline placement proof + the 4-slow-bar starvation case at the 1 s
///    cycle floor,
///  · G7 — engine-side eligibility: loop off ⇒ no LoopContext while
///    recording (the store's engagement mirror).
@MainActor
@Suite("Loop-cycle recording — engine (m15-b)", .serialized)
struct LoopRecordEngineTests {

    /// Collects one take completion (the no-writer MIDI path completes
    /// synchronously inside `stopRecording`).
    @MainActor
    private final class TakeBox {
        var result: Result<TakeResult, Error>?
    }

    // MARK: G4 + suppression lift, live

    @Test("live: loop take schedules WITH the window; held note across a wrap clamps LINEAR, never collapses")
    func heldNoteAcrossWrapClampsLinear() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return  // headless machine without an output device
        }
        defer { engine.shutdown() }

        var pushes: [Double] = []
        engine.playheadHandler = { pushes.append($0) }

        var transport = TransportState()
        transport.isLoopEnabled = true
        transport.loopStartBeat = 0
        transport.loopEndBeat = 2      // 1.0 s per cycle at 120 BPM
        transport.positionBeats = 0    // the store's §3 seek, mirrored

        let box = TakeBox()
        try engine.startTake(transport, audioURL: nil, captureMIDI: true) { result in
            box.result = result
        }
        // The lift itself: recording rolls WITH a live loop window.
        #expect(engine.loopContextActiveForTesting)

        // Hold a note from inside cycle 1 across ≥ 2 wraps. Pitch 113 is a
        // sentinel no other suite sends — CoreMIDI is system-global, so a
        // PARALLEL suite's virtual-source traffic can land in this capture
        // session; assertions below filter to the sentinel pitch.
        try await Task.sleep(for: .milliseconds(250))
        let session = engine.midiCaptureSessionForTesting
        session?.ingest(LiveMIDIEvent(
            hostTime: mach_absolute_time(), source: 0,
            kind: ScheduledMIDIEvent.noteOn, pitch: 113, velocity: 100, channel: 0))
        try await Task.sleep(for: .milliseconds(2_400))

        // Linear vs modular divergence while rolling: the capture clock ran
        // past the loop end; the playhead wrapped inside it.
        let linear = engine.derivedLinearBeats()
        engine.stopRecording()
        let result = try #require(box.result)
        let take = try result.get()

        let maxPush = pushes.max() ?? 0
        let notes = take.midi?.notes ?? []
        print("[measured] m15-b G4: linear stop domain \(linear) (loop end 2.0), "
              + "max playhead push \(maxPush), stopBeats \(take.stopBeats ?? -1), "
              + "captured notes \(notes.map { ($0.pitch, $0.startBeat, $0.lengthBeats) })")
        #expect(linear > 2.0)                    // capture clock is linear
        #expect(maxPush <= 2.0)                  // playhead stayed modular
        let stop = try #require(take.stopBeats)
        #expect(stop > 2.0)                      // the linear clamp reached the store surface
        // The held sentinel note: clamped at the LINEAR stop — spanning at
        // least one full cycle (2 beats), nowhere near the 0.001 collapse.
        let held = notes.filter { $0.pitch == 113 }
        #expect(held.count == 1)
        let note = try #require(held.first)
        #expect(note.lengthBeats > 2.0)
        #expect(abs(note.endBeat - stop) <= 1e-6)  // clamped at the stop beat
    }

    // MARK: G7 engine half — no loop, no context

    @Test("live: a loop-DISABLED take never builds a LoopContext (eligibility unity, engine half)")
    func linearTakeHasNoLoopContext() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return
        }
        defer { engine.shutdown() }

        var transport = TransportState()
        transport.isLoopEnabled = false
        let box = TakeBox()
        try engine.startTake(transport, audioURL: nil, captureMIDI: false) { result in
            box.result = result
        }
        #expect(!engine.loopContextActiveForTesting)
        #expect(engine.metronomeElapsedOffsetForTesting == 0)
        try await Task.sleep(for: .milliseconds(150))
        engine.stopRecording()
        #expect(box.result != nil)
    }

    // MARK: G6 live — the engine hands the metronome BOTH riders

    @Test("live: count-in × loop record sets the click offset to −delay and the plan head to delay + integral")
    func countInLoopClickRiders() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return
        }
        defer { engine.shutdown() }

        // Tempo boundary AT the record beat (90 → 120 @ 2): the LOOKUP
        // pre-roll (4 clicks · 0.5 s = 2.0 s) differs from the old pre-roll-
        // span integral (integral(−2 → 6) = 2.667 + 2.0), so both riders are
        // discriminated, not just present.
        var transport = TransportState()
        transport.tempoMapOverride = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 90),
            TempoMap.Segment(startBeat: 2, bpm: 120),
        ])
        transport.isLoopEnabled = true
        transport.loopStartBeat = 2
        transport.loopEndBeat = 6      // 4 beats @120 → L = 2.0 s
        transport.positionBeats = 2    // the store's seek
        transport.isMetronomeEnabled = true
        transport.countInBars = 1      // 4/4 @ the record beat → 2.0 s delay

        let box = TakeBox()
        try engine.startTake(transport, audioURL: nil, captureMIDI: false) { result in
            box.result = result
        }
        #expect(engine.loopContextActiveForTesting)
        // §5.4a: the click player's timeline begins 2.0 s BEFORE the anchor.
        #expect(engine.metronomeElapsedOffsetForTesting == -2.0)
        // §5.4b: head = delay + integral(2 → 6) = 2.0 + 2.0 — NOT the
        // pre-roll-span integral 4.667.
        #expect(engine.metronomeLoopHeadSecondsForTesting == 4.0)
        #expect(engine.metronomeLoopScheduledThroughCycle != nil)  // unroll armed under recording
        try await Task.sleep(for: .milliseconds(200))
        engine.stopRecording()
        #expect(box.result != nil)
    }

    // MARK: G6 offline — click placement under count-in + loop

    @Test("offline: count-in + loop clicks land at delay + integral + k·L, nothing anywhere else")
    func countInLoopClickPlacement() throws {
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 90),
            TempoMap.Segment(startBeat: 2, bpm: 120),
        ])
        let meter = MeterMap(constant: TimeSignature())
        let rig = try LoopRecordClickRig()

        // Exactly the production shape from startMetronome's loop branch.
        let plan = Metronome.countInPlan(countInBars: 1, meterMap: meter,
                                         tempoMap: map, atBeat: 2)
        #expect(plan.delaySeconds == 2.0)
        #expect(plan.clickBeats == 4)
        rig.metronome.scheduleCountIn(clickBeats: plan.clickBeats, tempoMap: map,
                                      atBeat: 2, meterMap: meter)
        rig.metronome.scheduleLoopClicks(
            fromBeat: 2, loopStartBeat: 2, loopEndBeat: 6,
            tempoMap: map, meterMap: meter,
            playerStartBeat: 2, countInDelaySeconds: plan.delaySeconds)
        rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        rig.metronome.start(at: nil)

        // 2 s count-in + head pass (2 s) + 2 unrolled cycles = 8 s.
        let frames = Int(8.0 * lrRate)
        var output: [[Float]] = [[], []]
        try rig.render(frames: frames, into: &output) { elapsed in
            // serviceLoop's feed: elapsed − metronomeElapsedOffset, offset −2.
            rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: elapsed - (-2.0),
                                          horizonSeconds: 0.2)
        }
        rig.engine.stop()

        // Count-in at 0, 0.5, 1.0, 1.5; head pass beats 2..5 @ 2.0 + 0.5·i;
        // cycle k at 2.0 + 2.0 + (k−1)·2.0 + 0.5·i — ALL absolute integrals.
        var expected: [Double] = [0, 0.5, 1.0, 1.5]
        for cycle in 0...2 {
            for beatInWindow in 0..<4 {
                expected.append(2.0 + Double(cycle) * 2.0 + 0.5 * Double(beatInWindow))
            }
        }
        let missing = expected.filter { !clickPresent(output, atSeconds: $0) }
        let stray = firstStray(output, expectedClickSeconds: expected)
        print("[measured] m15-b G6 placement: \(expected.count) expected clicks, "
              + "missing \(missing), first stray sample \(String(describing: stray))")
        #expect(missing.isEmpty)
        #expect(stray == nil)
    }

    // MARK: G6 offline — no starvation: 4 slow count-in bars at the 1 s cycle floor

    @Test("offline: a 4-bar 60 BPM count-in over a 1 s cycle loop starves nothing")
    func slowCountInNoStarvation() throws {
        let map = TempoMap(constantBPM: 60)          // spb 1.0
        let meter = MeterMap(constant: TimeSignature())
        let rig = try LoopRecordClickRig()

        let plan = Metronome.countInPlan(countInBars: 4, meterMap: meter,
                                         tempoMap: map, atBeat: 0)
        #expect(plan.delaySeconds == 16.0)           // the full starvation window
        rig.metronome.scheduleCountIn(clickBeats: plan.clickBeats, tempoMap: map,
                                      atBeat: 0, meterMap: meter)
        rig.metronome.scheduleLoopClicks(
            fromBeat: 0, loopStartBeat: 0, loopEndBeat: 1,   // 1.0 s — the record floor
            tempoMap: map, meterMap: meter,
            playerStartBeat: 0, countInDelaySeconds: plan.delaySeconds)
        rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        rig.metronome.start(at: nil)

        // 16 s count-in + 6 loop cycles = 22 s. Without the −delay offset the
        // unroll believes it is 16 s in the past and cycles ≥ 3 never queue.
        let frames = Int(22.0 * lrRate)
        var output: [[Float]] = [[], []]
        try rig.render(frames: frames, into: &output) { elapsed in
            rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: elapsed - (-16.0),
                                          horizonSeconds: 0.2)
        }
        rig.engine.stop()

        var expected = (0..<16).map { Double($0) }            // count-in, 1 Hz
        expected += (0...5).map { 16.0 + Double($0) }         // head + 5 cycles
        let missing = expected.filter { !clickPresent(output, atSeconds: $0) }
        print("[measured] m15-b G6 starvation: \(expected.count) expected clicks, missing \(missing), "
              + "clicks queued through cycle \(rig.metronome.loopScheduledThroughCycle ?? -1)")
        #expect(missing.isEmpty)
        #expect((rig.metronome.loopScheduledThroughCycle ?? -1) >= 5)
    }

    // MARK: null case — no count-in keeps the m14-c loop click arithmetic verbatim

    @Test("offline: countInDelaySeconds 0 is arithmetic-identical to the m14-c loop click shape")
    func zeroDelayNullCase() throws {
        let map = TempoMap(constantBPM: 120)
        let meter = MeterMap(constant: TimeSignature())

        // A: the m15-b call with delay 0. B: the pre-m15-b shape (no param).
        var outputs: [[Float]] = []
        for explicitZero in [true, false] {
            let rig = try LoopRecordClickRig()
            if explicitZero {
                rig.metronome.scheduleLoopClicks(
                    fromBeat: 0, loopStartBeat: 0, loopEndBeat: 4,
                    tempoMap: map, meterMap: meter,
                    playerStartBeat: 0, countInDelaySeconds: 0)
            } else {
                rig.metronome.scheduleLoopClicks(
                    fromBeat: 0, loopStartBeat: 0, loopEndBeat: 4,
                    tempoMap: map, meterMap: meter, playerStartBeat: 0)
            }
            rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
            rig.metronome.start(at: nil)
            var output: [[Float]] = [[], []]
            try rig.render(frames: Int(6.0 * lrRate), into: &output) { elapsed in
                rig.metronome.topUpLoopCycles(elapsedPlayerSeconds: elapsed,
                                              horizonSeconds: 0.2)
            }
            rig.engine.stop()
            outputs.append(output[0])
        }
        #expect(outputs[0] == outputs[1])   // byte-identical null case
    }
}
