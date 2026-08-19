import Foundation
import Testing
@testable import DAWCore

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

/// M7 (macro-a) coverage for `ProjectStore.humanizeClipNotes` + the seeded
/// splitmix64 generator (tested THROUGH the public method): determinism vs. a
/// fresh seed, the both-axes-zero bit-identical round-trip, velocity/timing
/// clamps at both rails, id/length/order preservation, one-step undo, and the
/// non-MIDI rejection. Deterministic throughout — every "randomness" assertion
/// is pinned by an explicit seed or is a clamp INVARIANT that holds for any seed.
@MainActor
@Suite("ProjectStore — humanizeClipNotes")
struct HumanizeTests {

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// A store with one instrument track carrying an 8-beat MIDI clip of `notes`.
    private func makeClip(_ notes: [MIDINote], lengthBeats: Double = 8) throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, lengthBeats: lengthBeats, notes: notes)
        return (store, clip.id)
    }

    /// A fixed, id-stable note set so two runs are comparable by `==`.
    private func sampleNotes() -> [MIDINote] {
        [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.5, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 64, velocity: 80, startBeat: 1.5, lengthBeats: 0.5),
            MIDINote(id: UUID(), pitch: 67, velocity: 100, startBeat: 2.5, lengthBeats: 0.25),
            MIDINote(id: UUID(), pitch: 72, velocity: 70, startBeat: 3.5, lengthBeats: 2.0),
        ]
    }

    // 1. Same seed → identical result (determinism).
    @Test("same seed twice yields identical notes")
    func determinism() throws {
        let notes = sampleNotes()
        let (s1, c1) = try makeClip(notes)
        let (s2, c2) = try makeClip(notes)
        let a = try s1.humanizeClipNotes(clipID: c1, timingBeats: 0.05, velocityRange: 12, seed: 42)
        let b = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0.05, velocityRange: 12, seed: 42)
        #expect(a.clip.notes! == b.clip.notes!)
        #expect(a.seedUsed == 42 && b.seedUsed == 42)
    }

    // 2. Two seeds → different result (with overwhelming probability; seeds fixed).
    @Test("different seeds yield different notes")
    func difference() throws {
        let notes = sampleNotes()
        let (s1, c1) = try makeClip(notes)
        let (s2, c2) = try makeClip(notes)
        let a = try s1.humanizeClipNotes(clipID: c1, timingBeats: 0.05, velocityRange: 12, seed: 1)
        let b = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0.05, velocityRange: 12, seed: 2)
        #expect(a.clip.notes! != b.clip.notes!)
    }

    // 3. Both axes zero → bit-identical round-trip.
    @Test("timingBeats 0 + velocityRange 0 round-trips the clip bit-identically")
    func zeroParamsIdentity() throws {
        let (store, clipID) = try makeClip(sampleNotes())
        let before = store.tracks[0].clips[0].notes!
        let out = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0, seed: nil)
        #expect(out.clip.notes! == before)                       // returned clip unchanged
        #expect(store.tracks[0].clips[0].notes! == before)       // stored clip unchanged
    }

    // 4. Velocity clamps at BOTH rails (1 and 127).
    @Test("velocity clamps to 1...127 at both rails")
    func velocityClamp() throws {
        // Low rail: 24 notes pinned at velocity 1, big range → some go negative
        // (clamp to 1); every result stays in 1...127.
        let lowNotes = (0..<24).map { MIDINote(id: UUID(), pitch: 40 + $0, velocity: 1, startBeat: 0, lengthBeats: 0.1) }
        let (sLow, cLow) = try makeClip(lowNotes)
        let low = try sLow.humanizeClipNotes(clipID: cLow, timingBeats: 0, velocityRange: 40, seed: 7)
        let lowVels = low.clip.notes!.map(\.velocity)
        #expect(lowVels.allSatisfy { (1...127).contains($0) })
        #expect(lowVels.contains(1))   // proves a low clamp actually fired

        // High rail: 24 notes pinned at velocity 127 → some go over (clamp to 127).
        let hiNotes = (0..<24).map { MIDINote(id: UUID(), pitch: 40 + $0, velocity: 127, startBeat: 0, lengthBeats: 0.1) }
        let (sHi, cHi) = try makeClip(hiNotes)
        let hi = try sHi.humanizeClipNotes(clipID: cHi, timingBeats: 0, velocityRange: 40, seed: 7)
        let hiVels = hi.clip.notes!.map(\.velocity)
        #expect(hiVels.allSatisfy { (1...127).contains($0) })
        #expect(hiVels.contains(127))  // proves a high clamp actually fired
    }

    // 5. Timing clamps at clip START and clip END.
    @Test("timing clamps to [0, clipEnd) at both edges")
    func timingClamp() throws {
        // START: 32 notes at onset 0 with a big timing range → some go negative
        // and clamp to exactly 0; none is ever < 0 or >= clipEnd.
        let atZero = (0..<32).map { MIDINote(id: UUID(), pitch: 40 + $0, velocity: 90, startBeat: 0, lengthBeats: 0.1) }
        let (sStart, cStart) = try makeClip(atZero, lengthBeats: 8)
        let start = try sStart.humanizeClipNotes(clipID: cStart, timingBeats: 1.0, velocityRange: 0, seed: 9)
        let starts = start.clip.notes!.map(\.startBeat)
        #expect(starts.allSatisfy { $0 >= 0 && $0 < 8 })
        #expect(starts.contains(0.0))  // proves a start clamp actually fired

        // END: a note authored PAST the clip end (8.5 in an 8-beat clip). Any
        // small offset leaves it beyond the end, so it clamps to
        // clipEnd − minLengthBeats deterministically for any seed.
        let overhang = [MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 8.5, lengthBeats: 1.0)]
        let (sEnd, cEnd) = try makeClip(overhang, lengthBeats: 8)
        let end = try sEnd.humanizeClipNotes(clipID: cEnd, timingBeats: 0.25, velocityRange: 0, seed: 123)
        let endStart = end.clip.notes![0].startBeat
        #expect(approx(endStart, 8 - MIDINote.minLengthBeats))
        #expect(endStart < 8)
    }

    // 6. Note lengths, ids, and array order are all preserved.
    @Test("lengths, ids, and array order preserved")
    func structurePreserved() throws {
        let (store, clipID) = try makeClip(sampleNotes())
        let before = store.tracks[0].clips[0].notes!
        _ = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0.2, velocityRange: 20, seed: 314)
        let after = store.tracks[0].clips[0].notes!
        #expect(after.map(\.id) == before.map(\.id))               // order + ids preserved
        #expect(after.map(\.lengthBeats) == before.map(\.lengthBeats))  // lengths untouched
        #expect(after.map(\.pitch) == before.map(\.pitch))         // pitches untouched
    }

    // 7. One undo step restores the EXACT prior notes.
    @Test("single undo restores the exact prior notes")
    func undoRestores() throws {
        let (store, clipID) = try makeClip(sampleNotes())
        let before = store.tracks[0].clips[0].notes!
        _ = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0.1, velocityRange: 16, seed: 55)
        #expect(store.tracks[0].clips[0].notes! != before)         // something changed
        #expect(try store.undo() == "Humanize")
        #expect(store.tracks[0].clips[0].notes! == before)         // exact restore
    }

    // 8. A non-MIDI (audio) clip is rejected with notAMIDIClip; unknown id → clipNotFound.
    @Test("audio clip → notAMIDIClip; unknown id → clipNotFound")
    func rejections() throws {
        let audio = Clip(name: "a", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/a.wav"))
        let track = Track(name: "Aud", kind: .audio, clips: [audio])
        let store = ProjectStore(tracks: [track])
        let audioErr = projectError {
            _ = try store.humanizeClipNotes(clipID: audio.id, timingBeats: 0.02, velocityRange: 8, seed: nil)
        }
        guard case .notAMIDIClip(let id, _)? = audioErr, id == audio.id else {
            Issue.record("expected notAMIDIClip, got \(String(describing: audioErr))"); return
        }
        #expect(store.tracks[0].clips[0].audioFileURL != nil)      // nothing changed

        let bogus = UUID()
        let missingErr = projectError {
            _ = try store.humanizeClipNotes(clipID: bogus, timingBeats: 0.02, velocityRange: 8, seed: nil)
        }
        guard case .clipNotFound(let mid)? = missingErr, mid == bogus else {
            Issue.record("expected clipNotFound, got \(String(describing: missingErr))"); return
        }
    }

    // 8b. A comp MEMBER is rejected with clipInTakeGroup (the shared
    // requireNotCompMember guard quantize/setNotes enforce); notes stay put.
    @Test("comp member rejected with clipInTakeGroup, notes unchanged")
    func compMemberRejected() throws {
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(id: UUID(), pitch: 60, startBeat: 0.3, lengthBeats: 1)])
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(id: UUID(), pitch: 62, startBeat: 0.4, lengthBeats: 1)])
        let track = Track(name: "Keys", kind: .instrument, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })
        let before = member.notes!
        let err = projectError {
            _ = try store.humanizeClipNotes(clipID: member.id, timingBeats: 0.05, velocityRange: 12, seed: 1)
        }
        if case .clipInTakeGroup? = err {} else {
            Issue.record("expected clipInTakeGroup, got \(String(describing: err))")
        }
        // The member's notes are untouched — the guard fired before any edit.
        let after = try #require(store.tracks[0].clips.first { $0.id == member.id }).notes!
        #expect(after == before)
    }

    // MARK: - Legato / gate pass (m27-o ⓑ)
    //
    // The measured defect these cover: across 225 tenor-sax notes every note
    // either ABUTTED the next or left a gap and NOT ONE overlapped, so every
    // note-on exposed a fresh attack transient. The pass closes small gaps and
    // overlaps the joins so each attack lands under the previous note's tail.
    // It does NOT remove the retrigger — nothing in this engine can (spike
    // §3.1) — and no assertion here should ever be read as claiming otherwise.

    /// The sax fixture, in a 12-beat clip, with `timingBeats`/`velocityRange`
    /// left at 0 by every caller so the gap arithmetic is exact rather than
    /// seed-dependent:
    ///
    ///   0.0 +1.00 → abuts the next (gap 0.00)
    ///   1.0 +0.90 → gap 0.10  (small: articulation)
    ///   2.0 +1.00 → gap 0.50  (LARGE: a breath rest, must survive)
    ///   3.5 +0.50 → abuts the next (gap 0.00)
    ///   4.0 +1.00 → last note, nothing follows it
    private func breathFixture() -> [MIDINote] {
        [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 62, velocity: 88, startBeat: 1.0, lengthBeats: 0.9),
            MIDINote(id: UUID(), pitch: 64, velocity: 92, startBeat: 2.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 65, velocity: 85, startBeat: 3.5, lengthBeats: 0.5),
            MIDINote(id: UUID(), pitch: 67, velocity: 95, startBeat: 4.0, lengthBeats: 1.0),
        ]
    }

    // L1. THE REPORTED DEFECT, and the musical intent that bounds the fix:
    // every small gap closes into an overlap, and the BREATH REST survives.
    @Test("legato overlaps every close join and leaves the breath rest untouched")
    func legatoClosesGapsButKeepsBreaths() throws {
        let notes = breathFixture()

        // ANTI-VACUITY: the fixture must actually contain BOTH a gap the pass
        // closes and a gap it must refuse to close. Without this the breath
        // assertion below would pass just as green on a clip with no rests.
        let gaps = zip(notes, notes.dropFirst()).map { $1.startBeat - ($0.startBeat + $0.lengthBeats) }
        #expect(gaps.contains { $0 >= 0 && $0 <= HumanizeLegato.defaultMaxGapBeats },
                "fixture has no small gap — the gap-closing half of this test would be vacuous")
        #expect(gaps.contains { $0 > HumanizeLegato.defaultMaxGapBeats },
                "fixture has no LARGE gap — the breath-rest half of this test would be vacuous")

        let (store, clipID) = try makeClip(notes, lengthBeats: 12)
        let out = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0,
                                              seed: 5, legatoOverlapBeats: 0.03)
        let after = try #require(out.clip.notes)

        // Gap 0.00 → ends 0.03 past the next onset.
        #expect(approx(after[0].lengthBeats, 1.03))
        // Gap 0.10 (≤ 0.125) → closed AND overlapped: ends at 2.03.
        #expect(approx(after[1].startBeat + after[1].lengthBeats, 2.03))
        // Gap 0.50 (> 0.125) → THE BREATH. Byte-identical to what was authored.
        #expect(after[2] == notes[2],
                "the breath rest was closed — that is destroying musical intent, not improving articulation")
        // Gap 0.00 → ends 0.03 past the next onset.
        #expect(approx(after[3].startBeat + after[3].lengthBeats, 4.03))
        // Nothing follows the last note.
        #expect(after[4] == notes[4])

        // And the overlaps are REAL — the defect was that none existed.
        let overlapCount = zip(after, after.dropFirst())
            .filter { $1.startBeat < ($0.startBeat + $0.lengthBeats) }.count
        #expect(overlapCount == 3, "expected three overlapped joins, got \(overlapCount)")
    }

    // L2a. Omitting the legato arguments leaves the result BIT-IDENTICAL to the
    // four-argument call every existing caller makes.
    @Test("omitting the legato arguments is bit-identical to the pre-legato call")
    func omittedLegatoIsBitIdentical() throws {
        let notes = breathFixture()
        let (s1, c1) = try makeClip(notes, lengthBeats: 12)
        let (s2, c2) = try makeClip(notes, lengthBeats: 12)
        let old = try s1.humanizeClipNotes(clipID: c1, timingBeats: 0.05, velocityRange: 12, seed: 99)
        let new = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0.05, velocityRange: 12, seed: 99,
                                           legatoOverlapBeats: 0)
        #expect(old.clip.notes! == new.clip.notes!)
        #expect(old.clip.notes!.map(\.lengthBeats) == notes.map(\.lengthBeats))  // lengths untouched
    }

    // L2b. THE DISCRIMINATING ONE: the pass draws NO random numbers. L2a would
    // stay green even if it did (with legato off the pass never runs), so this
    // is what actually pins the RNG stream — same seed, legato ON vs OFF, and
    // every onset and velocity must match to the bit. Only lengths may differ.
    @Test("the legato pass consumes no RNG — onsets and velocities are identical with it on")
    func legatoDoesNotDisturbTheSeededStream() throws {
        let notes = breathFixture()
        let (s1, c1) = try makeClip(notes, lengthBeats: 12)
        let (s2, c2) = try makeClip(notes, lengthBeats: 12)
        let off = try s1.humanizeClipNotes(clipID: c1, timingBeats: 0.05, velocityRange: 12, seed: 2024)
        let on = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0.05, velocityRange: 12, seed: 2024,
                                          legatoOverlapBeats: 0.04)
        #expect(off.clip.notes!.map(\.startBeat) == on.clip.notes!.map(\.startBeat))
        #expect(off.clip.notes!.map(\.velocity) == on.clip.notes!.map(\.velocity))
        #expect(off.seedUsed == on.seedUsed)
        // Anti-vacuity: the legato run really did do something to the lengths.
        #expect(off.clip.notes!.map(\.lengthBeats) != on.clip.notes!.map(\.lengthBeats))
    }

    // L2c. `maxGapBeats` alone is inert — it bounds a pass that is not running.
    @Test("maxGapBeats without a positive overlap changes nothing")
    func maxGapAloneIsInert() throws {
        let notes = breathFixture()
        let (store, clipID) = try makeClip(notes, lengthBeats: 12)
        let out = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0,
                                              seed: 1, legatoOverlapBeats: 0, maxGapBeats: 4)
        #expect(out.clip.notes! == notes)
    }

    // L3. Clip bounds: an extension stops at the clip end, and a note authored
    // to overhang the end is NOT trimmed by that same bound.
    @Test("legato never extends past the clip end, and never trims an existing overhang")
    func legatoClampsToTheClipEnd() throws {
        // Clamp: the successor sits 0.05 beats from the end, the requested
        // overlap (0.2) would reach 4.15 in a 4-beat clip.
        let tight = [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.0, lengthBeats: 3.9),
            MIDINote(id: UUID(), pitch: 62, velocity: 90, startBeat: 3.95, lengthBeats: 0.05),
        ]
        let (s1, c1) = try makeClip(tight, lengthBeats: 4)
        let clamped = try s1.humanizeClipNotes(clipID: c1, timingBeats: 0, velocityRange: 0,
                                               seed: 1, legatoOverlapBeats: 0.2)
        let first = clamped.clip.notes![0]
        #expect(approx(first.startBeat + first.lengthBeats, 4.0))
        #expect(first.startBeat + first.lengthBeats <= 4.0 + 1e-9,
                "a note was extended past the clip end")
        // Anti-vacuity: without the clamp this would have reached 4.15.
        #expect(first.lengthBeats > 3.9, "the note was not extended at all — the clamp test is vacuous")

        // Overhang: the pass only ever EXTENDS, so a note that already runs past
        // the clip end keeps the length it was authored with.
        let overhang = [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.0, lengthBeats: 6.0),
            MIDINote(id: UUID(), pitch: 62, velocity: 90, startBeat: 0.5, lengthBeats: 0.25),
        ]
        let (s2, c2) = try makeClip(overhang, lengthBeats: 4)
        let kept = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0, velocityRange: 0,
                                            seed: 1, legatoOverlapBeats: 0.2)
        #expect(kept.clip.notes![0].lengthBeats == 6.0)
    }

    // L4a. CHORDS: notes that share an onset are ONE attack point. They never
    // truncate each other, and the whole block extends into the next attack.
    @Test("a chord extends as a block — simultaneous notes are not each other's successor")
    func chordsExtendTogether() throws {
        let chord = [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 64, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 67, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 65, velocity: 90, startBeat: 1.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 69, velocity: 90, startBeat: 1.0, lengthBeats: 1.0),
        ]
        // ANTI-VACUITY: three notes really do share the first onset.
        #expect(chord.filter { $0.startBeat == 0.0 }.count == 3)

        let (store, clipID) = try makeClip(chord, lengthBeats: 8)
        let out = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0,
                                              seed: 1, legatoOverlapBeats: 0.05)
        let after = try #require(out.clip.notes)
        // ALL THREE extend — the rejected "next note in start order" rule would
        // have extended only one of them and left the other two at 1.0.
        for index in 0..<3 {
            #expect(approx(after[index].lengthBeats, 1.05),
                    "a chord tone was not extended — simultaneous notes were treated as each other's successor")
        }
        // The last onset is the last onset for EVERY note that shares it.
        #expect(after[3] == chord[3])
        #expect(after[4] == chord[4])

        // THE INTERACTION of the two chord rules: one tone of the next chord
        // REPEATS a pitch of this one. That tone must abut (a pitch-only MIDI
        // note-off cannot say which of two same-pitch voices it ends); its
        // neighbours in the same chord still overlap. Neither rule may swallow
        // the other.
        let sharedTone = [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 64, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 67, velocity: 90, startBeat: 0.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 1.0, lengthBeats: 1.0),
            MIDINote(id: UUID(), pitch: 65, velocity: 90, startBeat: 1.0, lengthBeats: 1.0),
        ]
        let (s2, c2) = try makeClip(sharedTone, lengthBeats: 8)
        let mixed = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0, velocityRange: 0,
                                             seed: 1, legatoOverlapBeats: 0.05)
        let mixedNotes = try #require(mixed.clip.notes)
        #expect(approx(mixedNotes[0].lengthBeats, 1.0),
                "the repeated pitch overlapped its own repeat — its note-off would cut the second one short")
        #expect(approx(mixedNotes[1].lengthBeats, 1.05))
        #expect(approx(mixedNotes[2].lengthBeats, 1.05))
    }

    // L4b. ALREADY OVERLAPPING (gap < 0): left alone, never normalised down.
    // A held pad under a melody is the ordinary case, and shortening it would be
    // the destructive reading of a control the user pressed for the melody.
    @Test("notes that already overlap are never shortened")
    func existingOverlapsSurvive() throws {
        let pad = [
            MIDINote(id: UUID(), pitch: 48, velocity: 70, startBeat: 0.0, lengthBeats: 4.0),
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 1.0, lengthBeats: 1.5),
            MIDINote(id: UUID(), pitch: 64, velocity: 90, startBeat: 2.0, lengthBeats: 1.5),
        ]
        // ANTI-VACUITY: every join in this fixture really is a negative gap.
        let gaps = zip(pad, pad.dropFirst()).map { $1.startBeat - ($0.startBeat + $0.lengthBeats) }
        #expect(gaps.allSatisfy { $0 < 0 }, "fixture has a non-negative gap — this test would prove nothing")

        let (store, clipID) = try makeClip(pad, lengthBeats: 8)
        let out = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0,
                                              seed: 1, legatoOverlapBeats: 0.05, maxGapBeats: 4)
        #expect(out.clip.notes! == pad)   // byte-identical: the pass only extends
    }

    // L4c. Same-pitch repeats ABUT instead of overlapping. A hosted AU is sent
    // plain MIDI note-off (`0x80 pitch 0`), which carries no note identity — an
    // overlap there would silence the note that just started.
    @Test("a same-pitch successor abuts exactly; a different pitch overlaps")
    func samePitchRepeatsAbut() throws {
        let repeated = [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.0, lengthBeats: 0.9),
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 1.0, lengthBeats: 1.0),
        ]
        let (s1, c1) = try makeClip(repeated, lengthBeats: 8)
        let abutted = try s1.humanizeClipNotes(clipID: c1, timingBeats: 0, velocityRange: 0,
                                               seed: 1, legatoOverlapBeats: 0.05)
        let first = abutted.clip.notes![0]
        // The gap CLOSED (0.9 → 1.0) but did not overlap.
        #expect(approx(first.lengthBeats, 1.0))
        #expect(first.startBeat + first.lengthBeats <= 1.0 + 1e-9,
                "a same-pitch overlap was emitted — its note-off would cut the repeat short on a hosted AU")

        // CONTROL, same shape at a different pitch: this one DOES overlap, so
        // the assertion above is about the pitch rule and not about the gap.
        let stepped = [
            MIDINote(id: UUID(), pitch: 60, velocity: 90, startBeat: 0.0, lengthBeats: 0.9),
            MIDINote(id: UUID(), pitch: 62, velocity: 90, startBeat: 1.0, lengthBeats: 1.0),
        ]
        let (s2, c2) = try makeClip(stepped, lengthBeats: 8)
        let overlapped = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0, velocityRange: 0,
                                                  seed: 1, legatoOverlapBeats: 0.05)
        #expect(approx(overlapped.clip.notes![0].lengthBeats, 1.05))
    }

    // L5. Ids, array order, pitches, velocities and START beats all survive the
    // legato pass — only lengths move.
    @Test("legato changes lengths ONLY: ids, order, pitches, velocities, starts preserved")
    func legatoPreservesEverythingElse() throws {
        let notes = breathFixture()
        let (store, clipID) = try makeClip(notes, lengthBeats: 12)
        _ = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0,
                                        seed: 1, legatoOverlapBeats: 0.04)
        let after = store.tracks[0].clips[0].notes!
        #expect(after.map(\.id) == notes.map(\.id))
        #expect(after.map(\.pitch) == notes.map(\.pitch))
        #expect(after.map(\.velocity) == notes.map(\.velocity))
        #expect(after.map(\.startBeat) == notes.map(\.startBeat))
        #expect(after.map(\.lengthBeats) != notes.map(\.lengthBeats))  // anti-vacuity
    }

    // L6. The pass is IDEMPOTENT (unlike the jitter, which compounds): after one
    // run every touched note overlaps its successor, and an overlap is left
    // alone. Re-running with no jitter must therefore change nothing.
    @Test("a second identical legato pass changes nothing (unlike the jitter, which compounds)")
    func legatoIsIdempotent() throws {
        let (store, clipID) = try makeClip(breathFixture(), lengthBeats: 12)
        let once = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0,
                                               seed: 1, legatoOverlapBeats: 0.03)
        let twice = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0, velocityRange: 0,
                                                seed: 1, legatoOverlapBeats: 0.03)
        #expect(once.clip.notes! == twice.clip.notes!)
    }

    // L7. Under real jitter the exact beats are seed-dependent, so assert the
    // INVARIANTS instead: nothing shrinks, nothing leaves the clip, and every
    // note still ends at or before the last onset plus the overlap.
    @Test("with timing jitter on, legato holds its invariants for any seed")
    func legatoInvariantsUnderJitter() throws {
        let notes = breathFixture()
        for seed in [UInt64(1), 17, 4242] {
            let (store, clipID) = try makeClip(notes, lengthBeats: 12)
            let out = try store.humanizeClipNotes(clipID: clipID, timingBeats: 0.05, velocityRange: 8,
                                                  seed: seed, legatoOverlapBeats: 0.04, maxGapBeats: 0.6)
            let after = try #require(out.clip.notes)
            for (index, note) in after.enumerated() {
                #expect(note.lengthBeats >= notes[index].lengthBeats,
                        "the legato pass shortened a note; it must only ever extend")
                #expect(note.startBeat + note.lengthBeats <= 12.0 + 1e-9,
                        "a note ran past the clip end")
            }
        }
    }

    // 9. Re-roll workflow: a nil seed draws one, returns it, and re-applying it reproduces.
    @Test("nil seed returns a reproducible seedUsed in [0, 2^53)")
    func seedUsedReproduces() throws {
        let notes = sampleNotes()
        let (s1, c1) = try makeClip(notes)
        let rolled = try s1.humanizeClipNotes(clipID: c1, timingBeats: 0.05, velocityRange: 12, seed: nil)
        #expect(rolled.seedUsed < (1 << 53))

        // Replaying the drawn seed on a fresh, identical clip reproduces exactly.
        let (s2, c2) = try makeClip(notes)
        let replay = try s2.humanizeClipNotes(clipID: c2, timingBeats: 0.05, velocityRange: 12, seed: rolled.seedUsed)
        #expect(replay.clip.notes! == rolled.clip.notes!)
    }
}
