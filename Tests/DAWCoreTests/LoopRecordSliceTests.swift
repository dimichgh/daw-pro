import Foundation
import Testing
@testable import DAWCore

/// m15-b — loop-cycle take recording, store side (design-m15b-loop-record §3,
/// §4, §6). Drives the REAL `record()` → `finishTake` path headlessly via
/// `FakeTakeEngine` (the TakeAutoGroupTests idiom) and pins:
///  · G1 — ≥ 3 cycles land N lanes on ONE group, every boundary == the
///    absolute integral `(k−1)·L − lag` under a multi-segment map with a
///    segment BEYOND the loop end (the timeline law: it must never leak in),
///  · G2 — mid-cycle stop = honest partial last lane, comp = that lane,
///  · G5 — the record-with-loop refusals teach verbatim (loop×punch, cycle
///    floor) and the seek-to-loop-start is visible to the engine,
///  · G7 — store/engine eligibility unity at the guard edges,
///  · G10 — the whole loop take is ONE undo entry; undo restores the
///    pre-record track exactly; redo relands.
/// MIDI slicing: seconds-domain exact inversion of the capture session's
/// linear map conversion, onset-cycle clamp, empty lanes land, single-cycle
/// degrades to the linear landing verbatim.
@MainActor
@Suite("Loop-cycle take recording — store slicing (m15-b)")
struct LoopRecordSliceTests {

    /// Runs `body`, returning the thrown `ProjectError` (nil if none) — the
    /// RecordingStoreTests idiom.
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil } catch { return error as? ProjectError }
    }

    /// The G1 map: 120 → 96 @ 4 → 150 @ 8; loop [2, 6) spans the 96 boundary
    /// and the 150 segment sits PAST the loop end (never in cycle timing).
    /// L = 2·0.5 + 2·0.625 = 2.25 s — every constant exactly representable.
    private func g1Map() throws -> TempoMap {
        try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 4, bpm: 96),
            TempoMap.Segment(startBeat: 8, bpm: 150),
        ])
    }

    private let loopL = 2.25            // the cycle integral, exact
    private let lag = 0.0078125         // capture lag, exactly representable

    private func loopStore(kind: TrackKind = .audio) throws -> (ProjectStore, FakeTakeEngine, Track) {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: kind)
        try store.setTrackArm(id: track.id, armed: true)
        try store.setTempoMap(try g1Map())
        try store.setLoop(enabled: true, startBeat: 2, endBeat: 6)
        return (store, engine, track)
    }

    private func audioResult(_ engine: FakeTakeEngine, duration: Double, lag: Double) throws -> RecordingResult {
        let url = try #require(engine.startTakeAudioURLs.last.flatMap { $0 })
        return RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: duration, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: lag
        )
    }

    // MARK: - G1: three full cycles == the absolute integrals

    @Test("G1: 3-cycle audio loop take lands 3 lanes on ONE group, boundaries == absolute integrals")
    func threeCycleAudioSlices() throws {
        let (store, engine, _) = try loopStore()
        try store.record()
        // Seek-to-loop-start is visible in the transport (G8's response body
        // encodes this same state) AND in what the engine was handed.
        #expect(store.transport.positionBeats == 2)
        #expect(engine.startTakeTransports.last?.positionBeats == 2)
        store.stop()
        // File covers elapsed [lag, 3L) — exactly three cycles.
        engine.finishTake(.success(TakeResult(
            audio: try audioResult(engine, duration: 3 * loopL - lag, lag: lag),
            stopBeats: nil)))

        let track = store.tracks[0]
        #expect(track.takeGroups.count == 1)
        let group = try #require(track.takeGroups.first)
        #expect(group.lanes.count == 3)
        #expect(group.lanes.map(\.name) == ["Gtr Take 1.1", "Gtr Take 1.2", "Gtr Take 1.3"])

        // THE INTEGRAL LAW, pinned with == against independent arithmetic
        // (never previous + L). Lane 1 starts lag into cycle 1 (@120,
        // spb = 0.5): 2 + lag/0.5; ends AT the loop end.
        let lane1 = group.lanes[0].clip
        #expect(lane1.startBeat == 2 + lag / 0.5)
        #expect(lane1.lengthBeats == 6 - (2 + lag / 0.5))
        #expect(lane1.startOffsetSeconds == 0)

        // Lanes 2 and 3: full cycles at the loop start; file read positions
        // are the ABSOLUTE integrals (k−1)·L − lag.
        let lane2 = group.lanes[1].clip
        #expect(lane2.startBeat == 2)
        #expect(lane2.lengthBeats == 4)
        #expect(lane2.startOffsetSeconds == 1 * loopL - lag)
        let lane3 = group.lanes[2].clip
        #expect(lane3.startBeat == 2)
        #expect(lane3.lengthBeats == 4)
        #expect(lane3.startOffsetSeconds == 2 * loopL - lag)

        // All lanes share the ONE take file.
        #expect(Set(group.lanes.map { $0.clip.audioFileURL }).count == 1)
        // Comp = the newest lane across the full range (newest wins).
        #expect(group.comp.count == 1)
        #expect(group.comp[0].laneID == group.lanes[2].id)
        #expect(group.comp[0].startBeat == 2)
        #expect(group.comp[0].endBeat == 6)
        // ONE undo entry for the whole loop take (G10's label half).
        #expect(store.undoLabel == "Record Take 1")
    }

    // MARK: - G2: mid-cycle stop = honest partial lane

    @Test("G2: mid-cycle stop lands the partial last lane; comp = that lane; no phantom cycle")
    func midCycleStopPartialLane() throws {
        let (store, engine, _) = try loopStore()
        try store.record()
        store.stop()
        // Elapsed cover ends 0.5 s into cycle 3 (@120 inside the window:
        // 0.5 s = 1 beat) — lanes 1..2 as in G1, lane 3 = 1 beat, no lane 4.
        engine.finishTake(.success(TakeResult(
            audio: try audioResult(engine, duration: 2 * loopL + 0.5 - lag, lag: lag),
            stopBeats: nil)))

        let group = try #require(store.tracks[0].takeGroups.first)
        #expect(group.lanes.count == 3)
        let partial = group.lanes[2].clip
        #expect(partial.startBeat == 2)
        #expect(partial.lengthBeats == 1.0)          // the inverse integral of 0.5 s @120
        #expect(partial.startOffsetSeconds == 2 * loopL - lag)
        #expect(group.comp.count == 1)
        #expect(group.comp[0].laneID == group.lanes[2].id)
    }

    // MARK: - N == 1 degrades to today's landing exactly

    @Test("stop inside cycle 1 lands a plain clip with today's exact formulas and name")
    func singleCycleDegradesToLinear() throws {
        let (store, engine, _) = try loopStore()
        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: try audioResult(engine, duration: 0.5, lag: lag), stopBeats: nil)))

        let track = store.tracks[0]
        #expect(track.takeGroups.isEmpty)            // no group from one lane
        #expect(track.clips.count == 1)
        let clip = track.clips[0]
        #expect(clip.name == "Gtr Take 1")           // no ".1" suffix
        // Today's two-step formula verbatim: start from lag, length from the
        // file duration integrated from that start (0.5 s wholly inside the
        // 120 segment = exactly 1 beat).
        #expect(clip.startBeat == 2 + lag / 0.5)
        #expect(clip.lengthBeats == 1.0)
        #expect(clip.startOffsetSeconds == 0)
    }

    // MARK: - Re-record over a loop group appends lanes (the comping workflow)

    @Test("re-recording over a loop take appends N more lanes to the SAME group; undo peels one take")
    func reRecordAppendsLanes() throws {
        let (store, engine, _) = try loopStore()
        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: try audioResult(engine, duration: 2 * loopL - lag, lag: lag), stopBeats: nil)))
        #expect(store.tracks[0].takeGroups.first?.lanes.count == 2)

        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: try audioResult(engine, duration: 2 * loopL - lag, lag: lag), stopBeats: nil)))

        let group = try #require(store.tracks[0].takeGroups.first)
        #expect(store.tracks[0].takeGroups.count == 1)  // ONE group, never a second
        #expect(group.lanes.count == 4)
        #expect(group.lanes.map(\.name) == ["Gtr Take 1.1", "Gtr Take 1.2",
                                            "Gtr Take 2.1", "Gtr Take 2.2"])
        #expect(group.comp[0].laneID == group.lanes[3].id)  // newest still wins

        // G10: one undo peels EXACTLY the second take.
        #expect(store.undoLabel == "Record Take 2")
        try store.undo()
        #expect(store.tracks[0].takeGroups.first?.lanes.count == 2)
    }

    // MARK: - G10: one undo restores the pre-record track exactly; redo relands

    @Test("G10: undo of a 3-lane loop take restores the pre-record track; redo relands the group")
    func oneUndoWholeTake() throws {
        let (store, engine, _) = try loopStore()
        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: try audioResult(engine, duration: 3 * loopL - lag, lag: lag), stopBeats: nil)))
        #expect(store.tracks[0].takeGroups.count == 1)
        #expect(store.undoLabel == "Record Take 1")

        try store.undo()
        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.isEmpty)

        try store.redo()
        let group = try #require(store.tracks[0].takeGroups.first)
        #expect(group.lanes.count == 3)
        #expect(group.comp[0].laneID == group.lanes[2].id)
    }

    // MARK: - G5/G7: refusals teach verbatim; eligibility unity at the edges

    @Test("loop × punch refuses with the exact teaching error; nothing rolls")
    func loopPunchRefusal() throws {
        let (store, engine, _) = try loopStore()
        try store.setPunch(enabled: true, inBeat: 3, outBeat: 5)
        let error = projectError { try store.record() }
        guard case .invalidPunchRange(let message) = try #require(error) else {
            Issue.record("expected invalidPunchRange"); return
        }
        #expect(message == "recording with both a loop and a punch window is not supported — disable one: loop-cycle takes (transport.setLoop) or punch (transport.setPunch)")
        #expect(store.lastRecordingError == message)
        #expect(!store.transport.isRecording)
        #expect(engine.startTakeTransports.isEmpty)   // the engine never saw a take
    }

    @Test("sub-1-second cycle refuses with the exact teaching error; playhead never moves")
    func cycleFloorRefusal() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        // 120 BPM, loop [0, 1) → 0.5 s per cycle: below the 1.0 s floor.
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 1)
        try store.seek(toBeats: 7)
        let error = projectError { try store.record() }
        guard case .invalidLoopRange(let message) = try #require(error) else {
            Issue.record("expected invalidLoopRange"); return
        }
        #expect(message == "loop is too short for take recording — use a loop of at least 1 second per cycle")
        #expect(store.transport.positionBeats == 7)   // a refused record never seeks
        #expect(engine.startTakeTransports.isEmpty)
    }

    @Test("G7: pre-seek position past the loop end still records FROM the loop start (unity by the seek)")
    func positionPastLoopEndSeeks() throws {
        let (store, engine, _) = try loopStore()
        try store.seek(toBeats: 40)                   // far past loop end 6
        try store.record()
        #expect(store.transport.positionBeats == 2)   // the §3 seek
        // The engine received beats < loopEnd, so its window guard passes —
        // store engagement ⇔ engine LoopContext, by construction.
        #expect(engine.startTakeTransports.last?.positionBeats == 2)
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: try audioResult(engine, duration: 2 * loopL - lag, lag: lag), stopBeats: nil)))
        #expect(store.tracks[0].takeGroups.first?.lanes.count == 2)
    }

    // MARK: - MIDI: seconds-domain slicing by exact inversion

    @Test("MIDI loop take: notes slice to their onset cycles, held note clamps at its cycle end, partial lane honest")
    func midiThreeCycleSlices() throws {
        let (store, engine, _) = try loopStore(kind: .instrument)
        try store.record()
        store.stop()
        // Linear capture domain (clip-relative to record start = beat 2):
        //  · A: beats [1.0, 1.5) — inside cycle 1 (elapsed [0.5, 0.75)).
        //  · B: onset elapsed 3.75 s (1.5 s into cycle 2), HELD past the
        //    cycle-2 wrap at 4.5 s to elapsed 4.75 s — linear beats
        //    [6.625, 9.125): the linear domain crosses INTO the 150 segment
        //    past the loop end (abs beat 8.625), which must never leak into
        //    the within-cycle geometry.
        //  · C: elapsed [4.75, 4.95) — inside the partial cycle 3.
        // Stop at elapsed 5.0 s ⇒ linear stop beat 11.75 ⇒ 3 cycles
        // (⌈5.0 / 2.25⌉), cycle 3 partial by 0.5 s.
        let notes = [
            MIDINote(pitch: 60, velocity: 100, startBeat: 1.0, lengthBeats: 0.5),
            MIDINote(pitch: 64, velocity: 90, startBeat: 6.625, lengthBeats: 2.5),
            MIDINote(pitch: 67, velocity: 80, startBeat: 9.125, lengthBeats: 0.5),
        ]
        engine.finishTake(.success(TakeResult(
            audio: nil,
            midi: MIDIRecordingResult(notes: notes, lengthBeats: 10),
            stopBeats: 11.75)))

        let track = store.tracks[0]
        #expect(track.takeGroups.count == 1)
        let group = try #require(track.takeGroups.first)
        #expect(group.lanes.count == 3)
        #expect(group.lanes.map(\.name) == ["Gtr Take 1.1", "Gtr Take 1.2", "Gtr Take 1.3"])

        // Every lane is a MIDI clip at the loop start; full cycles span the
        // window, the last lane is the honest partial (0.5 s @120 = 1 beat).
        for lane in group.lanes {
            #expect(lane.clip.isMIDI)
            #expect(lane.clip.startBeat == 2)
        }
        #expect(group.lanes[0].clip.lengthBeats == 4)
        #expect(group.lanes[1].clip.lengthBeats == 4)
        #expect(group.lanes[2].clip.lengthBeats == 1.0)

        // Note A round-trips exactly (all constants exact in the 120 span).
        let laneANotes = try #require(group.lanes[0].clip.notes)
        #expect(laneANotes.count == 1)
        #expect(abs(laneANotes[0].startBeat - 1.0) <= 1e-9)
        #expect(abs(laneANotes[0].lengthBeats - 0.5) <= 1e-9)

        // Note B: onset 1.5 s into cycle 2 → within-window beat 2.8 (beat 4 +
        // 0.5 s @96), clip-relative 0.8... onset = 2.8 − 2 = 0.8 + 2 beats
        // of the 120 span = onset 2.8; clamped at the CYCLE END (beat 6 →
        // clip-relative 4) — never the 0.001 collapse.
        let laneBNotes = try #require(group.lanes[1].clip.notes)
        #expect(laneBNotes.count == 1)
        #expect(abs(laneBNotes[0].startBeat - 2.8) <= 1e-9)
        #expect(abs(laneBNotes[0].endBeat - 4.0) <= 1e-9)

        // Note C: onset 0.25 s into cycle 3 → 0.5 beats @120; 0.2 s long.
        let laneCNotes = try #require(group.lanes[2].clip.notes)
        #expect(laneCNotes.count == 1)
        #expect(abs(laneCNotes[0].startBeat - 0.5) <= 1e-9)
        #expect(abs(laneCNotes[0].lengthBeats - 0.4) <= 1e-9)

        #expect(group.comp.count == 1)
        #expect(group.comp[0].laneID == group.lanes[2].id)
        #expect(store.undoLabel == "Record Take 1")
    }

    @Test("a cycle with no notes still lands an EMPTY lane (lane index == cycle index)")
    func midiEmptyCycleLane() throws {
        let (store, engine, _) = try loopStore(kind: .instrument)
        try store.record()
        store.stop()
        // One note in cycle 1, NONE in cycle 2; stop exactly at 2 cycles
        // (elapsed 4.5 s ⇒ linear stop beat 2 + 2 + 4 + 1·(60/96)… simpler:
        // elapsed 4.5 s from beat 2 = beat 10.5 linear).
        let notes = [MIDINote(pitch: 60, velocity: 100, startBeat: 1.0, lengthBeats: 0.5)]
        engine.finishTake(.success(TakeResult(
            audio: nil,
            midi: MIDIRecordingResult(notes: notes, lengthBeats: 9),
            stopBeats: 10.5)))

        let group = try #require(store.tracks[0].takeGroups.first)
        #expect(group.lanes.count == 2)               // stop AT the boundary: no cycle 3
        #expect((group.lanes[0].clip.notes ?? []).count == 1)
        #expect((group.lanes[1].clip.notes ?? []).isEmpty)  // honest empty lane
        #expect(group.lanes[1].clip.lengthBeats == 4)       // full cycle, not partial
    }

    @Test("MIDI stop inside cycle 1 degrades to today's landing verbatim")
    func midiSingleCycleDegrades() throws {
        let (store, engine, _) = try loopStore(kind: .instrument)
        try store.record()
        store.stop()
        let notes = [MIDINote(pitch: 60, velocity: 100, startBeat: 0.25, lengthBeats: 1.0)]
        engine.finishTake(.success(TakeResult(
            audio: nil,
            midi: MIDIRecordingResult(notes: notes, lengthBeats: 2),
            stopBeats: 4.0)))                          // elapsed 1.0 s < L

        let track = store.tracks[0]
        #expect(track.takeGroups.isEmpty)
        #expect(track.clips.count == 1)
        #expect(track.clips[0].name == "Gtr Take 1")
        #expect(track.clips[0].startBeat == 2)
        #expect(track.clips[0].lengthBeats == 2)       // midi.lengthBeats verbatim
        #expect(track.clips[0].notes == notes)         // notes verbatim, no slicing
    }

    @Test("a multi-cycle MIDI take with zero notes overall is discarded exactly as today")
    func midiZeroNotesDiscarded() throws {
        let (store, engine, _) = try loopStore(kind: .instrument)
        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: nil,
            midi: MIDIRecordingResult(notes: [], lengthBeats: 9),
            stopBeats: 11.75)))
        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.isEmpty)
        #expect(store.lastRecordingError == "empty take discarded — no MIDI notes received")
    }
}
