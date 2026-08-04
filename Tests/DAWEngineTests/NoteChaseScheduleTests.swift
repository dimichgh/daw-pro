import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bp gates, LAYER 1 — pure build math for note chase
// (docs/research/design-m23bp-note-chase.md §3 semantics, §9 layer 1 G1–G10).
//
// THE DEFECT: `MIDIEventSchedule.buildEvents` dropped BOTH events of any note
// whose onset preceded `fromBeat`, so every mid-playback reschedule (a tempo
// drag, ANY piano-roll edit, a loop-bounds edit, a device flip) permanently
// silenced every note that was already sounding — `restart` cuts the voices
// via `stopAllPlayers`, and the new build then re-sounded nothing.
//
// THE RULE (§3.1), pinned below:
//   · not chasing → the v0 rule verbatim (BOTH events dropped);
//   · chasing and `offBeat <= fromBeat` → dropped (the note had ended; the
//     test is STRICT, so a note ending exactly at the anchor stays dropped);
//   · chasing and `offBeat > fromBeat` → admitted with the ONSET CLAMPED TO
//     `fromBeat` IN THE BEAT DOMAIN, so `seconds(from: fromBeat, to: fromBeat)`
//     is exactly 0 and the on frame is the block's own `anchorFrame` —
//     literally the expression the m16-b controller chase prefix uses;
//   · the loop-window test keeps reading the ORIGINAL onset;
//   · a chased note with no whole frame of tail left is DROPPED, not rescued
//     by the defensive `max(on + 1, …)` clamp (a 1-frame re-attack is a click,
//     not a note). Un-chased notes keep that clamp byte-identically.
//
// 48 kHz, 120 BPM ⇒ 1 beat = 24 000 frames. Frame values are EXACT (`==`).

private let ncRate = 48_000.0
private let ncMap = TempoMap(constantBPM: 120)

/// (frame, kind, data1, data2) — identity-free comparison tuple.
private func ncShape(_ e: ScheduledMIDIEvent) -> [Int64] {
    [e.sampleTime, Int64(e.kind), Int64(e.pitch), Int64(e.velocity)]
}

@Suite("Note chase — build semantics (m23-bp layer 1)")
struct NoteChaseScheduleTests {

    // MARK: - G1: the null case (default path provably unmoved)

    /// The defaulted parameter is a true no-op: over a corpus that exercises
    /// every parameter shape (linear / seek / loop-windowed / offset+base) the
    /// bare call and the explicit `chaseHeldNotes: false` call agree on every
    /// field INCLUDING noteIDs and on `nextNoteID`.
    @Test("G1 null: chaseHeldNotes:false is byte-identical to the bare call, and to v0 semantics")
    func nullCaseUnmoved() {
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
        let cases: [(from: Double, end: Double?, offset: Double, base: UInt64)] = [
            (0, nil, 0, 0),
            (2.5, nil, 0, 0),
            (0, 4, 0, 0),
            (0, 4, 1.0, 7),
            (3.25, 6, 0.5, 3),
        ]
        for c in cases {
            let bare = MIDIEventSchedule.buildEvents(
                clips: clips, fromBeat: c.from, tempoMap: ncMap, sampleRate: ncRate,
                onsetEndBeat: c.end, offsetSeconds: c.offset, noteIDBase: c.base)
            let explicit = MIDIEventSchedule.buildEvents(
                clips: clips, fromBeat: c.from, tempoMap: ncMap, sampleRate: ncRate,
                onsetEndBeat: c.end, offsetSeconds: c.offset, noteIDBase: c.base,
                chaseHeldNotes: false)
            #expect(bare.events == explicit.events)
            #expect(bare.nextNoteID == explicit.nextNoteID)
        }

        // The v0 suppression expectations, VERBATIM from
        // MIDISchedulerTests.fromBeatSuppressesEarlierOnsets — the default path
        // still drops both events of a note whose onset is behind the anchor.
        let clip = Clip(name: "m", startBeat: 1, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, velocity: 90, startBeat: 1.5, lengthBeats: 0.5),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 2, tempoMap: ncMap, sampleRate: ncRate).events
        #expect(events.count == 2)
        #expect(events[0].kind == 0 && events[0].pitch == 64 && events[0].velocity == 90)
        #expect(events[0].sampleTime == 12_000)
        #expect(events[1].kind == 1 && events[1].pitch == 64 && events[1].velocity == 0)
        #expect(events[1].sampleTime == 24_000)
        #expect(events[0].noteID == events[1].noteID)
        #expect(!events.contains { $0.pitch == 60 })
    }

    // MARK: - G2: the fix itself

    /// THE m23-bp fixture: one 128-beat note, rebuilt from beat 4 mid-note.
    /// Chase on → the note re-sounds at the anchor frame and ends at its TRUE
    /// time (beat 128 is 124 beats past the anchor = 2 976 000 frames). Chase
    /// off → zero events, the arm that reproduced the defect headlessly.
    @Test("G2 fix: a note spanning the anchor re-sounds at frame 0 and offs at its true time")
    func heldNoteIsChased() {
        let clip = Clip(name: "pad", startBeat: 0, lengthBeats: 128, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 128),
        ])
        let chased = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G2 chased events: \(chased.events.map(ncShape))")
        #expect(chased.events.count == 2)
        guard chased.events.count == 2 else { return }
        let on = chased.events[0]
        let off = chased.events[1]
        #expect(on.kind == ScheduledMIDIEvent.noteOn)
        #expect(on.sampleTime == 0)                 // clamped onset ≡ anchorFrame
        #expect(on.pitch == 60)
        #expect(on.velocity == 100)
        #expect(off.kind == ScheduledMIDIEvent.noteOff)
        #expect(off.sampleTime == 2_976_000)        // 124 beats — the TRUE off
        #expect(off.pitch == 60)
        #expect(on.noteID == off.noteID)            // one ID from the same counter
        #expect(chased.nextNoteID == 1)

        // The defect arm, kept permanently as the A/B control.
        let unchased = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate)
        #expect(unchased.events.isEmpty)
        #expect(unchased.nextNoteID == 0)
    }

    // MARK: - G3: a note that had already ended stays dropped

    /// `offBeat > fromBeat` is STRICT: a note ending exactly at the anchor had
    /// finished and must not be resurrected. The +0.5-beat twin proves the drop
    /// is the boundary rule, not a broken fixture.
    @Test("G3 ended: off exactly at the anchor drops; off past it is admitted")
    func endedNoteStaysDropped() {
        let ended = Clip(name: "e", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 4),
        ])
        let sounding = Clip(name: "s", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 4.5),
        ])
        let endedBuild = MIDIEventSchedule.buildEvents(
            clips: [ended], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        let soundingBuild = MIDIEventSchedule.buildEvents(
            clips: [sounding], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G3 ended=\(endedBuild.events.count) "
              + "sounding=\(soundingBuild.events.map(ncShape))")
        #expect(endedBuild.events.isEmpty)
        #expect(endedBuild.nextNoteID == 0)         // no ID consumed by a dropped note
        #expect(soundingBuild.events.count == 2)
        #expect(soundingBuild.events.first?.sampleTime == 0)
        #expect(soundingBuild.events.last?.sampleTime == 12_000)   // half a beat
    }

    // MARK: - G4: the sliver case

    /// A chased note can have an arbitrarily small remaining tail (the anchor
    /// lands anywhere inside it). One that rounds to ZERO frames is DROPPED —
    /// the defensive `max(on + 1, …)` clamp must not turn it into a 1-frame
    /// on/off pair, which is an attack transient with no note behind it. The
    /// 1e-4 twin (2.4 frames → 2) proves the drop is the ROUNDING rule and not
    /// a blanket short-note ban.
    @Test("G4 sliver: a zero-frame tail drops; a 2-frame tail survives with off==2")
    func sliverTailIsDroppedNotClamped() {
        let sliver = Clip(name: "sl", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 4 + 1e-6),
        ])
        let tiny = Clip(name: "ti", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 4 + 1e-4),
        ])
        let sliverBuild = MIDIEventSchedule.buildEvents(
            clips: [sliver], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        let tinyBuild = MIDIEventSchedule.buildEvents(
            clips: [tiny], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G4 sliver=\(sliverBuild.events.count) "
              + "tiny=\(tinyBuild.events.map(ncShape))")
        #expect(sliverBuild.events.isEmpty)
        #expect(tinyBuild.events.count == 2)
        #expect(tinyBuild.events.first?.sampleTime == 0)
        // 1e-4 beat × 0.5 s/beat × 48 000 = 2.4 → 2 (NOT the clamp's 1).
        #expect(tinyBuild.events.last?.sampleTime == 2)

        // WHY THE SLIVER CLASS IS NEW (§3.2b), pinned rather than asserted in
        // prose: an UN-chased note can never reach it. `MIDINote` floors
        // `lengthBeats` at `minLengthBeats` (0.001), which even at the 400 BPM
        // tempo cap is ≥ 7 frames at 48 kHz — the `MIDISchedule.swift:82-84`
        // comment — so the shortest note the MODEL can express still rounds to
        // 24 frames here, and `max(on + 1, …)` stays pure defense. Chase is
        // what makes a sub-frame tail reachable, because the anchor can land
        // anywhere inside a note; hence the explicit drop above rather than
        // leaning on that clamp.
        let shortAtAnchor = Clip(name: "sa", startBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 62, velocity: 100, startBeat: 4, lengthBeats: 1e-6),
        ])
        #expect(shortAtAnchor.notes?.first?.lengthBeats == MIDINote.minLengthBeats)
        let unchasedShort = MIDIEventSchedule.buildEvents(
            clips: [shortAtAnchor], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G4 model-floor note: \(unchasedShort.events.map(ncShape))")
        #expect(unchasedShort.events.count == 2)
        #expect(unchasedShort.events.first?.sampleTime == 0)
        #expect(unchasedShort.events.last?.sampleTime == 24)   // 0.001 beat, not the clamp
    }

    // MARK: - G5: same-pitch coexistence

    /// A chased note and a FRESH note of the same pitch starting exactly at the
    /// anchor both sound, as two voices with distinct noteIDs — the model's own
    /// "same-pitch overlaps are legal" rule. Every built-in instrument pairs
    /// offs by noteID, so both close correctly.
    @Test("G5 same pitch: chased + fresh coexist at frame 0 with distinct IDs, each off pairing")
    func samePitchChasedAndFreshCoexist() {
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 128, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 128),  // chased
            MIDINote(pitch: 60, velocity: 70, startBeat: 4, lengthBeats: 2),     // fresh at anchor
        ])
        let build = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G5 events: \(build.events.map(ncShape)) "
              + "ids \(build.events.map(\.noteID))")
        #expect(build.events.count == 4)
        let ons = build.events.filter { $0.kind == ScheduledMIDIEvent.noteOn }
        #expect(ons.count == 2)
        #expect(ons.allSatisfy { $0.sampleTime == 0 })
        #expect(Set(ons.map(\.noteID)).count == 2)
        // Same frame, same rank, same pitch → ordered by noteID.
        #expect(ons.map(\.noteID) == ons.map(\.noteID).sorted())
        // Each off pairs its own on: chased off at 124 beats, fresh off at 2.
        var offByID: [UInt64: Int64] = [:]
        for e in build.events where e.kind == ScheduledMIDIEvent.noteOff {
            offByID[e.noteID] = e.sampleTime
        }
        #expect(offByID.count == 2)
        #expect(Set(offByID.values) == Set([2_976_000, 48_000]))
    }

    // MARK: - G6: the off-before-on tie rule at a shared frame

    /// Chase moves a note's ON only, never its off, so the load-bearing tie
    /// rule is untouched: a chased note whose off lands exactly on a later
    /// same-pitch note's on frame still delivers the OFF FIRST.
    @Test("G6 tie: a chased note's off precedes a same-frame same-pitch on")
    func chasedOffStillPrecedesSameFrameOn() {
        // Chased note [0, 6) with the anchor at 4 → off at beat 6 (48 000).
        // Fresh note starts at beat 6 → on at 48 000, same pitch.
        let clip = Clip(name: "t", startBeat: 0, lengthBeats: 16, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 6),
            MIDINote(pitch: 60, velocity: 80, startBeat: 6, lengthBeats: 2),
        ])
        let build = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G6 events: \(build.events.map(ncShape))")
        #expect(build.events.count == 4)
        let atSeam = build.events.enumerated().filter { $0.element.sampleTime == 48_000 }
        #expect(atSeam.count == 2)
        #expect(atSeam.first?.element.kind == ScheduledMIDIEvent.noteOff)
        #expect(atSeam.last?.element.kind == ScheduledMIDIEvent.noteOn)
        // …and the array is globally ordered.
        for i in 1..<build.events.count {
            #expect(!MIDIEventSchedule.orderedBefore(build.events[i], build.events[i - 1]))
        }
    }

    // MARK: - G7: the controller chase prefix still opens the block

    /// Rank 1 (controllers) < rank 2 (note-ons) at a shared frame, so a chased
    /// sustain/bend/CC is in effect BEFORE a chased note re-attacks. The m16-b
    /// behaviour, inherited for free.
    @Test("G7 controller order: the chase prefix precedes the chased note-on at frame 0")
    func controllerChasePrecedesChasedNoteOn() {
        let clip = Clip(name: "cc", startBeat: 0, lengthBeats: 128, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 128),
        ], controllerLanes: [
            MIDIControllerLane(type: .cc(controller: 1), points: [
                MIDIControllerPoint(beat: 1, value: 42),     // below the anchor → chased
            ]),
        ])
        let build = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G7 events: \(build.events.map(ncShape))")
        #expect(build.events.count == 3)
        guard build.events.count == 3 else { return }
        #expect(build.events[0].kind == ScheduledMIDIEvent.controlChange)
        #expect(build.events[0].sampleTime == 0)
        #expect(build.events[0].pitch == 1)       // controller #
        #expect(build.events[0].velocity == 42)   // the chased value
        #expect(build.events[1].kind == ScheduledMIDIEvent.noteOn)
        #expect(build.events[1].sampleTime == 0)
        #expect(build.events[2].kind == ScheduledMIDIEvent.noteOff)
    }

    // MARK: - G8: the loop window reads the ORIGINAL onset

    /// A chased note's true onset is behind the anchor, hence behind
    /// `onsetEndBeat` too, so the window admits it — and its OFF is allowed to
    /// land past the window (the documented straddle: tails ring through the
    /// seam). Reading the CLAMPED onset would also pass here, but only by
    /// accident; the negative twin pins that the window still bites on notes
    /// whose onset is genuinely at/after it.
    @Test("G8 loop window: a chased note is admitted and its off may pass onsetEndBeat")
    func loopWindowReadsOriginalOnset() {
        let clip = Clip(name: "w", startBeat: 0, lengthBeats: 128, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 32),  // chased
            MIDINote(pitch: 67, velocity: 100, startBeat: 8, lengthBeats: 1),   // past the window
        ])
        let build = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            onsetEndBeat: 6, chaseHeldNotes: true)
        print("[measured] G8 events: \(build.events.map(ncShape))")
        #expect(build.events.count == 2)                      // only the chased note
        #expect(build.events.first?.pitch == 60)
        #expect(build.events.first?.sampleTime == 0)
        // Off at beat 32 = 28 beats past the anchor — well past onsetEndBeat 6.
        #expect(build.events.last?.sampleTime == 672_000)
        #expect(!build.events.contains { $0.pitch == 67 })    // window still bites
    }

    // MARK: - G9: anchor identity

    /// The clamped onset feeds `seconds(from: fromBeat, to: fromBeat)` ≡ 0, so
    /// the chased on frame is `round(offsetSeconds · rate)` — LITERALLY the
    /// `anchorFrame` expression the controller chase prefix uses. Production
    /// never combines chase with a nonzero offset (cycle blocks never chase);
    /// this pins the EXPRESSION, not a shipping path.
    @Test("G9 anchor identity: a chased on lands exactly on the block's anchorFrame")
    func chasedOnsetEqualsAnchorFrame() {
        // The bend lane's chase prefix lands at `anchorFrame` by the m16-b
        // expression — the INDEPENDENT witness that the chased note-on shares
        // that exact frame rather than merely a plausible one.
        let clip = Clip(name: "an", startBeat: 0, lengthBeats: 128, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 128),
        ], controllerLanes: [
            MIDIControllerLane(type: .pitchBend, points: [
                MIDIControllerPoint(beat: 1, value: 8_192),
            ]),
        ])
        let build = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4, tempoMap: ncMap, sampleRate: ncRate,
            offsetSeconds: 1.0, chaseHeldNotes: true)
        let anchorFrame = Int64((1.0 * ncRate).rounded())
        let ons = build.events.filter { $0.kind == ScheduledMIDIEvent.noteOn }
        let prefix = build.events.filter { $0.kind == ScheduledMIDIEvent.pitchBend }
        print("[measured] G9 anchorFrame=\(anchorFrame) events=\(build.events.map(ncShape))")
        #expect(anchorFrame == 48_000)
        #expect(ons.count == 1)
        #expect(ons.first?.sampleTime == 48_000)
        #expect(prefix.first?.sampleTime == 48_000)   // same frame, rank 1 first
        #expect(build.events.first?.kind == ScheduledMIDIEvent.pitchBend)
    }

    // MARK: - G-extra: the beat-domain test runs before any map integral

    /// §3.1: `offBeat > fromBeat` is decided in the BEAT domain, so resuming
    /// deep into a long song does not pay a tempo-map integral for every note
    /// in the past. Pinned behaviourally under a MULTI-SEGMENT map, where a
    /// frame-domain equivalent would have to evaluate the integral to decide:
    /// 5 000 long-finished notes contribute nothing, the one held note chases.
    @Test("G-extra: long-past notes are rejected in the beat domain under a multi-segment map")
    func pastNotesRejectedBeforeMapIntegral() throws {
        var notes: [MIDINote] = []
        for i in 0..<5_000 {
            notes.append(MIDINote(pitch: 40, velocity: 90,
                                  startBeat: Double(i) * 0.1, lengthBeats: 0.05))
        }
        notes.append(MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 4_000))
        let clip = Clip(name: "long", startBeat: 0, lengthBeats: 4_096, notes: notes)
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 200, bpm: 90),
            TempoMap.Segment(startBeat: 400, bpm: 150),
        ])
        let build = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 500, tempoMap: map, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G-extra events: \(build.events.count) "
              + "first=\(build.events.first.map(ncShape) ?? [])")
        #expect(build.events.count == 2)          // only the held note
        #expect(build.events.first?.pitch == 60)
        #expect(build.events.first?.sampleTime == 0)
        #expect(build.events.last?.kind == ScheduledMIDIEvent.noteOff)
        #expect((build.events.last?.sampleTime ?? 0) > 0)
    }

    // MARK: - G-extra 2: a clip whose START is behind the anchor

    /// The chase test is on ABSOLUTE beats, so a clip placed before the anchor
    /// with a note inside it chases correctly (`onBeat = clip.startBeat +
    /// note.startBeat`), and clip-end truncation still bounds the off.
    @Test("G-extra2: chase respects clip placement and clip-end truncation")
    func chaseRespectsClipPlacementAndTruncation() {
        // Clip at beat 2, 8 beats long; note [1, 9) clip-relative → truncated
        // to the clip end (beat 10 absolute). Anchor at 5, inside the note.
        let clip = Clip(name: "p", startBeat: 2, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 8),
        ])
        let build = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 5, tempoMap: ncMap, sampleRate: ncRate,
            chaseHeldNotes: true)
        print("[measured] G-extra2 events: \(build.events.map(ncShape))")
        #expect(build.events.count == 2)
        #expect(build.events.first?.sampleTime == 0)
        // Off at absolute beat 10 = 5 beats past the anchor.
        #expect(build.events.last?.sampleTime == 120_000)
    }
}
