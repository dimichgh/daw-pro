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
        guard case .notAMIDIClip(let id)? = audioErr, id == audio.id else {
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
