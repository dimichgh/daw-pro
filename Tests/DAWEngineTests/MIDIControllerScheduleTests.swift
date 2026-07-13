import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m16-b2 gates — MIDI CC / pitch bend / channel pressure on the schedule path
// (docs/research/design-m16b-midi-cc.md §4/§5/§6, conditions C1b, C2, C3, C5,
// C6):
//
//  · C1b — note-only `buildEvents` output is byte-equal pre/post: a FROZEN
//    verbatim copy of the pre-m16-b2 algorithm (the A/B control) must produce
//    identical arrays — sampleTimes, kinds, pitches, velocities AND noteIDs —
//    for note-only projects, linear and loop-windowed.
//  · C3 — the chase matrix: seek mid-ramp / past-all-points / before-first-
//    point / loop-wrap / split-seam all open the block with the latest-≤ value
//    (else the neutral default) at the block's anchor frame, ranked strictly
//    after same-frame offs and before same-frame ons; a literal event at the
//    exact anchor frame suppresses the injection.
//  · C5 — noteIDs stay collision-free across unrolled cycle blocks WITH
//    controller events present (the `count / 2` trap fix), at the unit level
//    and on the REAL loop machinery; note-only ID accounting is unchanged.
//  · C6 — same-frame per-lane build coalescing bounds density at 1 event per
//    lane per frame, last value wins; different lanes never coalesce.
//  · C2 — offline == live: one mixed schedule delivered through
//    `renderQuantum` in `.offline` and synthetic-host-time `.live` harnesses
//    produces IDENTICAL (frame, kind, data1, data2) sequences (the m12-b
//    event-timestamp idiom, exact `==`).
//
// 48 kHz, 120 BPM → 1 beat = 24 000 frames. Frame values are EXACT.

private let ccRate = 48_000.0

// MARK: - Event shorthand

private func lane(_ type: MIDIControllerType,
                  _ points: [(Double, Int)]) -> MIDIControllerLane {
    MIDIControllerLane(type: type, points: points.map {
        MIDIControllerPoint(beat: $0.0, value: $0.1)
    })
}

private func bendData(_ value: Int) -> (pitch: UInt8, velocity: UInt8) {
    (UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F))
}

/// (frame, kind, data1, data2) — the identity-free comparison tuple (IDs are
/// asserted separately where they matter).
private func shape(_ e: ScheduledMIDIEvent) -> [Int64] {
    [e.sampleTime, Int64(e.kind), Int64(e.pitch), Int64(e.velocity)]
}

@Suite("MIDI controller schedule build (m16-b2)")
struct MIDIControllerScheduleTests {

    // MARK: - C1b: note-only A/B against the frozen pre-m16-b2 algorithm

    /// VERBATIM copy of the pre-m16-b2 `buildEvents` (notes only, the legacy
    /// off-before-on two-rank sort) — the A/B control. Frozen; never edit.
    private func frozenLegacyBuild(clips: [Clip], fromBeat: Double, tempoMap: TempoMap,
                                   sampleRate: Double,
                                   onsetEndBeat: Double? = nil,
                                   offsetSeconds: Double = 0,
                                   noteIDBase: UInt64 = 0) -> [ScheduledMIDIEvent] {
        var events: [ScheduledMIDIEvent] = []
        var nextNoteID: UInt64 = noteIDBase
        for clip in clips where clip.isMIDI {
            for note in clip.notes ?? [] {
                guard note.startBeat < clip.lengthBeats else { continue }
                let onBeat = clip.startBeat + note.startBeat
                guard onBeat >= fromBeat else { continue }
                if let onsetEndBeat, onBeat >= onsetEndBeat { continue }
                let offBeat = clip.startBeat + min(note.endBeat, clip.lengthBeats)
                let on = Int64(((offsetSeconds
                    + tempoMap.seconds(from: fromBeat, to: onBeat)) * sampleRate).rounded())
                let off = max(on + 1,
                              Int64(((offsetSeconds
                                  + tempoMap.seconds(from: fromBeat, to: offBeat)) * sampleRate).rounded()))
                let id = nextNoteID
                nextNoteID += 1
                let pitch = UInt8(clamping: note.pitch)
                events.append(ScheduledMIDIEvent(
                    sampleTime: on, noteID: id, kind: ScheduledMIDIEvent.noteOn,
                    pitch: pitch, velocity: UInt8(clamping: note.velocity)))
                events.append(ScheduledMIDIEvent(
                    sampleTime: off, noteID: id, kind: ScheduledMIDIEvent.noteOff,
                    pitch: pitch, velocity: 0))
            }
        }
        events.sort { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            if a.pitch != b.pitch { return a.pitch < b.pitch }
            return a.noteID < b.noteID
        }
        return events
    }

    @Test("C1b: note-only builds are byte-equal to the frozen legacy algorithm, incl. noteIDs")
    func noteOnlyByteEquality() {
        let map = TempoMap(constantBPM: 120)
        let clips = [
            Clip(name: "a", startBeat: 0, lengthBeats: 4, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
                MIDINote(pitch: 60, velocity: 90, startBeat: 1, lengthBeats: 1),   // adjacency tie
                MIDINote(pitch: 64, velocity: 80, startBeat: 0.5, lengthBeats: 2),
            ]),
            Clip(name: "b", startBeat: 2, lengthBeats: 4, notes: [
                MIDINote(pitch: 72, velocity: 127, startBeat: 1.5, lengthBeats: 4),  // truncates
            ]),
        ]
        // Linear, offset, loop-windowed, nonzero base — every parameter shape.
        let cases: [(from: Double, end: Double?, offset: Double, base: UInt64)] = [
            (0, nil, 0, 0),
            (2.5, nil, 0, 0),
            (0, 4, 0, 0),
            (0, 4, 1.0, 7),
        ]
        for c in cases {
            let new = MIDIEventSchedule.buildEvents(
                clips: clips, fromBeat: c.from, tempoMap: map, sampleRate: ccRate,
                onsetEndBeat: c.end, offsetSeconds: c.offset, noteIDBase: c.base)
            let legacy = frozenLegacyBuild(
                clips: clips, fromBeat: c.from, tempoMap: map, sampleRate: ccRate,
                onsetEndBeat: c.end, offsetSeconds: c.offset, noteIDBase: c.base)
            #expect(new.events == legacy)
            // Note-only ID accounting unchanged: one ID per pair, so the next
            // ID is exactly base + count/2 — the invariant the OLD PlaybackGraph
            // arithmetic relied on (and which mixed kinds break, C5).
            #expect(new.nextNoteID == c.base + UInt64(new.events.count / 2))
        }
    }

    // MARK: - C3: the chase matrix

    /// The matrix fixture: one note + three lanes with state on both sides of
    /// every seek point used below.
    private func chaseClip() -> Clip {
        Clip(name: "c", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 4, lengthBeats: 1),
        ], controllerLanes: [
            lane(.cc(controller: 1), [(0, 10), (2, 40), (6, 90)]),
            lane(.cc(controller: 64), [(3.5, 127)]),
            lane(.pitchBend, [(1, 8_192), (5, 16_383)]),
        ])
    }

    @Test("C3 seek mid-ramp: chased latest-≤ values at the anchor, rank 1, before the same-frame note-on")
    func chaseSeekMidRamp() {
        let events = MIDIEventSchedule.buildEvents(
            clips: [chaseClip()], fromBeat: 4, tempoMap: TempoMap(constantBPM: 120),
            sampleRate: ccRate).events
        // Anchor frame 0: chase bend 8192 (data 0,64), chase cc1 40, chase
        // cc64 127 — rank 1, pitch-ordered — THEN the note-on (rank 2).
        // Beat 5 (frame 24 000): the note-off (rank 0) precedes the literal
        // bend 16383. Beat 6 (frame 48 000): literal cc1 90.
        let bend = bendData(8_192)
        #expect(events.map(shape) == [
            [0, 3, Int64(bend.pitch), Int64(bend.velocity)],
            [0, 2, 1, 40],
            [0, 2, 64, 127],
            [0, 0, 60, 100],
            [24_000, 1, 60, 0],
            [24_000, 3, 127, 127],          // literal bend 16383 AFTER the off
            [48_000, 2, 1, 90],
        ])
        // Mixed-kind ID uniqueness within one build.
        #expect(Set(events.map(\.noteID)).count == 6)  // note pair shares 1 of 6
    }

    @Test("C3 seek past all points: chase-only block carries every lane's final value")
    func chaseSeekPastAllPoints() {
        let events = MIDIEventSchedule.buildEvents(
            clips: [chaseClip()], fromBeat: 7, tempoMap: TempoMap(constantBPM: 120),
            sampleRate: ccRate).events
        // The note (onset 4 < 7) is dropped by the untouched no-chase guard;
        // the three lanes chase to their latest values. Pitch order: cc1(1),
        // cc64(64), bend LSB(127).
        #expect(events.map(shape) == [
            [0, 2, 1, 90],
            [0, 2, 64, 127],
            [0, 3, 127, 127],
        ])
    }

    @Test("C3 seek before the first point: neutral defaults (bend 8192, CC64 0, CC11 127, pressure 0)")
    func chaseNeutralDefaults() {
        let clip = Clip(name: "n", startBeat: 0, lengthBeats: 8, notes: [], controllerLanes: [
            lane(.cc(controller: 1), [(2, 99)]),
            lane(.cc(controller: 11), [(2, 50)]),
            lane(.cc(controller: 64), [(2, 127)]),
            lane(.pitchBend, [(2, 0)]),
            lane(.channelPressure, [(2, 100)]),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: TempoMap(constantBPM: 120),
            sampleRate: ccRate).events
        let bend = bendData(8_192)
        let atAnchor = events.filter { $0.sampleTime == 0 }
        // Anchor order: rank 1 events sort by data1 then injection ID — bend
        // (LSB 0) and pressure (value 0) share data1 0, bend injected first.
        #expect(atAnchor.map(shape) == [
            [0, 3, Int64(bend.pitch), Int64(bend.velocity)],  // bend neutral 8192
            [0, 4, 0, 0],       // pressure neutral 0
            [0, 2, 1, 0],       // cc1 neutral 0
            [0, 2, 11, 127],    // cc11 neutral: expression full
            [0, 2, 64, 0],      // cc64 neutral: pedal up
        ])
        // The literal points then fire at beat 2 (frame 48 000), one per lane.
        #expect(events.filter { $0.sampleTime == 48_000 }.count == 5)
    }

    @Test("C3 literal suppression: a point exactly at fromBeat yields ONE event at the anchor, the literal")
    func chaseLiteralSuppression() {
        let events = MIDIEventSchedule.buildEvents(
            clips: [chaseClip()], fromBeat: 2, tempoMap: TempoMap(constantBPM: 120),
            sampleRate: ccRate).events
        // cc1 has a literal at beat 2 (value 40): exactly one cc1 event at the
        // anchor — no injected duplicate of the earlier value 10.
        let cc1AtAnchor = events.filter {
            $0.sampleTime == 0 && $0.kind == ScheduledMIDIEvent.controlChange && $0.pitch == 1
        }
        #expect(cc1AtAnchor.count == 1)
        #expect(cc1AtAnchor.first?.velocity == 40)
        // The other lanes still chase (cc64 has no state before 2 → neutral 0;
        // bend chases its beat-1 value 8192).
        #expect(events.contains { $0.sampleTime == 0 && $0.kind == 2 && $0.pitch == 64 && $0.velocity == 0 })
        let bend = bendData(8_192)
        #expect(events.contains { $0.sampleTime == 0 && $0.kind == 3
            && $0.pitch == bend.pitch && $0.velocity == bend.velocity })
    }

    @Test("C3 split seam: the right half's schedule == building the original from the split beat (shape-equal)")
    func chaseSplitSeamEquivalence() {
        let map = TempoMap(constantBPM: 120)
        let lanes = [lane(.cc(controller: 1), [(0, 10), (2, 40), (6, 90)]),
                     lane(.pitchBend, [(1, 12_288)])]
        let original = Clip(name: "o", startBeat: 0, lengthBeats: 8, notes: [],
                            controllerLanes: lanes)
        // Split at beat 3: the right half opens with the windowing helper's
        // injected boundary points (cc1 40, bend 12288) — the store's seam law.
        let right = Clip(name: "r", startBeat: 3, lengthBeats: 5, notes: [],
                         controllerLanes: Clip.windowedControllerLanes(
                            lanes, delta: 3, newLength: 5))
        let fromOriginal = MIDIEventSchedule.buildEvents(
            clips: [original], fromBeat: 3, tempoMap: map, sampleRate: ccRate).events
        let fromRight = MIDIEventSchedule.buildEvents(
            clips: [right], fromBeat: 3, tempoMap: map, sampleRate: ccRate).events
        // Chase-at-build of the ORIGINAL == literal boundary points of the
        // SPLIT half: one definition of "the value in effect at beat B".
        #expect(fromOriginal.map(shape) == fromRight.map(shape))
        #expect(fromOriginal.contains { $0.sampleTime == 0 && $0.kind == 2 && $0.velocity == 40 })
    }

    // MARK: - C3/C5: loop-cycle blocks (the wrap chase + rank across merged blocks)

    @Test("C3 loop wrap: every cycle block opens with fresh loop-start state; off < chase < on at the seam")
    func loopWrapChaseAndRank() {
        let map = TempoMap(constantBPM: 120)
        // Loop [0, 2): full-loop note; cc1 steps mid-cycle 10 → 99; bend jumps
        // to 16383 mid-cycle with NO point at the loop start — the stale-bend
        // trap fixture (the wrap must re-establish neutral 8192, not leak).
        let clips = [Clip(name: "m", startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
        ], controllerLanes: [
            lane(.cc(controller: 1), [(0, 10), (1, 99)]),
            lane(.pitchBend, [(0.5, 16_383)]),
        ])]
        let head = MIDIEventSchedule.buildEvents(
            clips: clips, fromBeat: 0, tempoMap: map, sampleRate: ccRate, onsetEndBeat: 2)
        let block = MIDIEventSchedule.buildEvents(
            clips: clips, fromBeat: 0, tempoMap: map, sampleRate: ccRate,
            onsetEndBeat: 2, offsetSeconds: 1.0, noteIDBase: head.nextNoteID)
        let merged = MIDIEventSchedule.mergeSorted(head.events, block.events)

        // Self-containment: the cycle block == a fresh seek-to-loop-start
        // build, modulo the cycle's frame offset (IDs aside).
        let fresh = MIDIEventSchedule.buildEvents(
            clips: clips, fromBeat: 0, tempoMap: map, sampleRate: ccRate, onsetEndBeat: 2)
        #expect(block.events.map { [$0.sampleTime - 48_000, Int64($0.kind), Int64($0.pitch), Int64($0.velocity)] }
                == fresh.events.map(shape))

        // The seam frame (48 000): off(head, rank 0) → bend chase 8192 (rank 1,
        // NOT the 16383 the cycle ended on) → cc1 literal 10 (rank 1) →
        // on(block, rank 2).
        let seam = merged.filter { $0.sampleTime == 48_000 }
        let bend = bendData(8_192)
        #expect(seam.map(shape) == [
            [48_000, 1, 60, 0],
            [48_000, 3, Int64(bend.pitch), Int64(bend.velocity)],
            [48_000, 2, 1, 10],
            [48_000, 0, 60, 100],
        ])
        // C5: mixed-kind IDs unique across the merged blocks; the counter is
        // the build's returned value, never a pair count — the old `count / 2`
        // derivation is provably wrong on this fixture.
        #expect(Set(merged.map(\.noteID)).count == Int(block.nextNoteID))
        #expect(Int(head.nextNoteID) != head.events.count / 2)  // the dead trap, demonstrated
    }

    @Test("C5 unit: IDs stay unique across head + 3 cycle blocks with controller events present")
    func noteIDUniquenessAcrossCycles() {
        let map = TempoMap(constantBPM: 120)
        let clips = [Clip(name: "m", startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 0.5),
            MIDINote(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 0.5),
        ], controllerLanes: [
            lane(.cc(controller: 1), [(0.25, 20), (1.25, 80)]),
            lane(.channelPressure, [(0.5, 64)]),
        ])]
        let head = MIDIEventSchedule.buildEvents(
            clips: clips, fromBeat: 0, tempoMap: map, sampleRate: ccRate, onsetEndBeat: 2)
        var merged = head.events
        var base = head.nextNoteID
        for cycle in 1...3 {
            let block = MIDIEventSchedule.buildEvents(
                clips: clips, fromBeat: 0, tempoMap: map, sampleRate: ccRate,
                onsetEndBeat: 2, offsetSeconds: Double(cycle), noteIDBase: base)
            #expect(block.nextNoteID > base)
            base = block.nextNoteID
            merged = MIDIEventSchedule.mergeSorted(merged, block.events)
        }
        // Every ID belongs to exactly one thing: a note pair (2 events) or a
        // single controller event — no collisions anywhere.
        var byID: [UInt64: [ScheduledMIDIEvent]] = [:]
        for event in merged { byID[event.noteID, default: []].append(event) }
        #expect(byID.count == Int(base))
        for (id, group) in byID {
            if group.count == 2 {
                #expect(Set(group.map(\.kind)) == [ScheduledMIDIEvent.noteOn,
                                                   ScheduledMIDIEvent.noteOff],
                        "id \(id): a 2-event group must be an on/off pair")
            } else {
                #expect(group.count == 1)
                #expect(group[0].kind >= 2, "id \(id): singleton must be a controller event")
            }
        }
    }

    // MARK: - C6: build coalescing

    @Test("C6: consecutive same-lane points rounding to one frame collapse LAST-WINS; lanes never cross-coalesce")
    func sameFrameCoalescing() {
        let map = TempoMap(constantBPM: 120)
        // Three cc1 points inside one frame (sub-frame beat spacing) + a cc2
        // point at the same beat: cc1 collapses to its LAST value, cc2 stays.
        let clip = Clip(name: "d", startBeat: 0, lengthBeats: 4, notes: [], controllerLanes: [
            lane(.cc(controller: 1), [(1.0, 10), (1.0000001, 20), (1.0000002, 30)]),
            lane(.cc(controller: 2), [(1.0, 77)]),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: map, sampleRate: ccRate).events
        let atFrame = events.filter { $0.sampleTime == 24_000 }
        #expect(atFrame.count == 2)
        #expect(atFrame.first { $0.pitch == 1 }?.velocity == 30)   // last wins
        #expect(atFrame.first { $0.pitch == 2 }?.velocity == 77)   // untouched

        // Adversarial density: 4096 points over 240 frames → ≤ 1 event per
        // lane per frame, and the final value survives (the endpoint law).
        var dense: [(Double, Int)] = []
        for index in 0..<4_096 {
            dense.append((Double(index) * 0.01 / 4_096.0, index % 128))
        }
        let denseClip = Clip(name: "x", startBeat: 0, lengthBeats: 4, notes: [],
                             controllerLanes: [lane(.cc(controller: 11), dense)])
        let denseEvents = MIDIEventSchedule.buildEvents(
            clips: [denseClip], fromBeat: 0, tempoMap: map, sampleRate: ccRate).events
        let frames = denseEvents.map(\.sampleTime)
        #expect(Set(frames).count == frames.count)          // ≤ 1/lane/frame
        #expect(frames.count <= 242)                        // 0.01 beat ≈ 240 frames + anchor
        #expect(denseEvents.last?.velocity == UInt8(4_095 % 128))  // final value kept
        print("[measured] C6 coalesce: 4096 points → \(denseEvents.count) events "
              + "over \((frames.max() ?? 0) + 1) frames")
    }

    // MARK: - C2: offline == live delivery equality

    @Test("C2: a bend-ramp + CC + note schedule delivers identical sequences offline and live")
    @MainActor
    func offlineEqualsLiveDelivery() throws {
        let map = TempoMap(constantBPM: 120)
        var ramp: [(Double, Int)] = []
        for step in 0...8 {           // bend ramp across beat [0, 0.5]
            ramp.append((Double(step) * 0.0625, 8_192 + step * 1_024))
        }
        let clip = Clip(name: "c2", startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 0.5),
            MIDINote(pitch: 64, velocity: 90, startBeat: 0.5, lengthBeats: 0.5),
        ], controllerLanes: [
            lane(.pitchBend, ramp),
            lane(.cc(controller: 11), [(0.1, 40), (0.6, 90)]),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: map, sampleRate: ccRate).events
        #expect(events.count > 12)

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: ccRate,
                                                channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let pulls = 60   // 60 × 512 = 30 720 frames > beat 1.1 (26 400)

        func deliveredShapes(offline: Bool) -> [[Int64]] {
            let capture = EventCaptureInstrument()
            capture.prepare(sampleRate: ccRate, maxFramesPerQuantum: 512, channelCount: 2)
            let renderer = InstrumentRenderer(instrument: capture, sampleRate: ccRate)
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
            let anchor: UInt64 = 1_000_000
            renderer.publish(MIDIEventSchedule(
                generation: 1,
                mode: offline ? .offline : .live(anchorHostTime: anchor),
                sampleRate: ccRate, events: events))
            for pull in 0..<pulls {
                var timestamp = AudioTimeStamp()
                if offline {
                    timestamp.mSampleTime = Double(pull * 512)
                    timestamp.mFlags = .sampleTimeValid
                } else {
                    timestamp.mHostTime = anchor + UInt64(
                        (Double(pull * 512) / ccRate * ticksPerSecond).rounded())
                    timestamp.mFlags = .hostTimeValid
                }
                var silence = ObjCBool(false)
                _ = renderer.renderQuantum(
                    timestamp: &timestamp, frameCount: 512,
                    audioBufferList: buffer.mutableAudioBufferList, isSilence: &silence)
            }
            return capture.capturedEvents().filter { !$0.wasReset }.map {
                [$0.firedAtFrame, Int64($0.event.kind), Int64($0.event.pitch),
                 Int64($0.event.velocity)]
            }
        }

        let offline = deliveredShapes(offline: true)
        let live = deliveredShapes(offline: false)
        print("[measured] C2 offline==live: \(offline.count) events delivered on each path")
        #expect(offline.count == events.count)   // everything within the pulled window fired
        #expect(offline == live)                 // exact ==, the m12-b idiom
    }

    // MARK: - Restart primitive composition (stop → seek → play)

    @Test("stop→seek→play: flush fires, then the fresh timeline's chase lands before its first note-on")
    @MainActor
    func restartChaseComposition() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: ccRate,
                                                channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let capture = EventCaptureInstrument()
        capture.prepare(sampleRate: ccRate, maxFramesPerQuantum: 512, channelCount: 2)
        let renderer = InstrumentRenderer(instrument: capture, sampleRate: ccRate)
        func pull(_ sampleTime: Double) {
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            _ = renderer.renderQuantum(timestamp: &timestamp, frameCount: 512,
                                       audioBufferList: buffer.mutableAudioBufferList,
                                       isSilence: &silence)
        }
        let map = TempoMap(constantBPM: 120)

        // Roll 1 from beat 0: bend + pedal state gets established (and would
        // be STALE at the next roll without chase).
        let scheduleA = MIDIEventSchedule.buildEvents(
            clips: [chaseClip()], fromBeat: 0, tempoMap: map, sampleRate: ccRate).events
        renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: ccRate, events: scheduleA))
        pull(0)
        pull(512)

        // Stop (the flush family) → seek to beat 4 → play (fresh timelineID).
        renderer.requestFlush()
        renderer.publish(nil)
        pull(1_024)
        let scheduleB = MIDIEventSchedule.buildEvents(
            clips: [chaseClip()], fromBeat: 4, tempoMap: map, sampleRate: ccRate).events
        renderer.publish(MIDIEventSchedule(
            generation: 2, mode: .offline, sampleRate: ccRate, events: scheduleB))
        pull(1_536)

        let captured = capture.capturedEvents()
        let maybeResetIndex = captured.lastIndex { $0.wasReset }
        let resetIndex = try #require(maybeResetIndex)
        #expect(captured.filter(\.wasReset).count == 1)
        let afterReset = captured[(resetIndex + 1)...].filter { !$0.wasReset }
        // The fresh block opens with the chase snapshot (bend 8192, cc1 40,
        // cc64 127) at its anchor, THEN the beat-4 note-on — no stale state
        // window at all.
        let bend = bendData(8_192)
        #expect(afterReset.prefix(4).map { shape($0.event) } == [
            [0, 3, Int64(bend.pitch), Int64(bend.velocity)],
            [0, 2, 1, 40],
            [0, 2, 64, 127],
            [0, 0, 60, 100],
        ])
        // Fresh timeline: the epoch re-latched at the restart pull, so the
        // new block delivers schedule-relative from frame 0.
        #expect(afterReset.allSatisfy { $0.renderStart == 0 })
    }

    // MARK: - C5 on the REAL loop machinery

    /// The production pin: PlaybackGraph loop unroll with notes + CC + bend
    /// lanes across ≥ 3 wraps — exactly-once IDs, zero flushes, and every
    /// cycle boundary re-establishing loop-start controller state (the
    /// stale-bend wrap fix, live).
    @Test("C5 production: 3-cycle loop with CC — unique IDs, zero flushes, per-cycle chase at every seam")
    @MainActor
    func productionLoopWithControllers() throws {
        let capture = EventCaptureInstrument()
        capture.prepare(sampleRate: ccRate, maxFramesPerQuantum: 4_096, channelCount: 2)
        let track = Track(name: "I", kind: .instrument, clips: [
            Clip(name: "m", startBeat: 0, lengthBeats: 2, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 0.5),
                MIDINote(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 0.5),
            ], controllerLanes: [
                lane(.cc(controller: 1), [(0, 10), (1.5, 99)]),
                lane(.pitchBend, [(0.5, 16_383)]),  // no loop-start point: chase must neutralize
            ]),
        ])
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        graph.instrumentFactory = { _ in capture }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: ccRate,
                                                channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: [track]))
        graph.applyParameters(tracks: [track])
        try engine.start()
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120),
                          loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2))
        graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)

        let renderBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                         frameCapacity: 4_096))
        var rendered = 0
        var pulls = 0
        let total = 3 * 48_000 + 24_000
        while rendered < total {
            let request = AVAudioFrameCount(min(total - rendered, 512))
            let status = try engine.renderOffline(request, to: renderBuffer)
            try #require(status == .success)
            rendered += Int(renderBuffer.frameLength)
            pulls += 1
            if pulls % 3 == 0 {
                graph.topUpLoopCycles(elapsedPlayerSeconds: Double(rendered) / ccRate,
                                      horizonSeconds: 0.2)
            }
        }
        engine.stop()
        #expect(capture.overflowCount == 0)

        let fired = capture.capturedEvents()
        #expect(fired.filter(\.wasReset).isEmpty)   // the wrap never flushes

        // Exactly-once per ID; every ID is a note pair or one controller event.
        var byID: [UInt64: [EventCaptureInstrument.CapturedEvent]] = [:]
        for entry in fired where !entry.wasReset {
            byID[entry.event.noteID, default: []].append(entry)
        }
        var notePairs = 0
        var controllerSingles = 0
        for (id, group) in byID {
            let kinds = group.map(\.event.kind)
            if kinds.allSatisfy({ $0 >= 2 }) {
                #expect(group.count == 1, "controller id \(id) delivered \(group.count)×")
                controllerSingles += 1
            } else {
                #expect(kinds.filter { $0 == ScheduledMIDIEvent.noteOn }.count == 1,
                        "id \(id): note on not exactly-once")
                #expect(kinds.filter { $0 == ScheduledMIDIEvent.noteOff }.count <= 1)
                #expect(kinds.allSatisfy { $0 <= 1 }, "id \(id) mixes notes and controllers")
                notePairs += 1
            }
        }
        print("[measured] C5 production: \(notePairs) note voices, "
              + "\(controllerSingles) controller events, IDs all unique across "
              + "\(byID.count) groups, resets 0")
        #expect(notePairs >= 7)              // 2 notes × (3 cycles + head half)

        // Per-cycle chase at every seam: bend re-establishes NEUTRAL 8192 at
        // each cycle boundary (the lane has no loop-start point — without the
        // chase the 16383 from mid-cycle would leak), and cc1 re-fires its
        // beat-0 literal value 10.
        let bend = bendData(8_192)
        for boundary in [Int64(48_000), 96_000, 144_000] {
            let atSeam = fired.filter { !$0.wasReset && $0.firedAtFrame == boundary }
            #expect(atSeam.contains {
                $0.event.kind == ScheduledMIDIEvent.pitchBend
                    && $0.event.pitch == bend.pitch && $0.event.velocity == bend.velocity
            }, "seam \(boundary): missing neutral bend chase")
            #expect(atSeam.contains {
                $0.event.kind == ScheduledMIDIEvent.controlChange
                    && $0.event.pitch == 1 && $0.event.velocity == 10
            }, "seam \(boundary): missing cc1 loop-start literal")
            // And mid-cycle (beat 0.5 → 12 000 into each cycle) the literal
            // 16383 bend fired — state really moved before every wrap.
            let midBend = fired.first {
                !$0.wasReset && $0.firedAtFrame == boundary - 36_000
                    && $0.event.kind == ScheduledMIDIEvent.pitchBend
            }
            #expect(midBend?.event.pitch == 127 && midBend?.event.velocity == 127)
        }
    }
}
