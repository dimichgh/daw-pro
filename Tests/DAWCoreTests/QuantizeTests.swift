import Foundation
import Testing
@testable import DAWCore

// Pure quantize math (M5 iii-d, spec §4) + the destructive store op. Math tests
// need no engine; store tests run headless (nil engine). Reuses the DAWCoreTests
// fakes indirectly via ProjectStore(tracks:).

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

// MARK: - QuantizeTarget

@Suite("QuantizeTarget — grid + swing")
struct QuantizeTargetTests {

    // 1.
    @Test("straight grid snaps to the nearest slot; swing 50 is identity")
    func straightGrid() {
        let s = QuantizeSettings(gridBeats: 1.0)          // strength/swing default
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.2, settings: s), 0.0))
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.7, settings: s), 1.0))
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.4, settings: s), 1.0))
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.6, settings: s), 2.0))
        // Swing 50 == straight (offset 0 on every slot, odd included).
        let straight = QuantizeSettings(gridBeats: 1.0, swingPercent: 50)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.9, settings: straight), 1.0))
        // A grid <= 0 is a no-op (targets equal the input).
        #expect(approx(QuantizeTarget.nearest(toBeat: 3.3, settings: QuantizeSettings(gridBeats: 0)), 3.3))
    }

    // 2.
    @Test("swing 66 delays odd (offbeat) slots by (2·swing/100 − 1)·grid; even slots stay")
    func swing66() {
        // grid 1.0: odd-slot offset = (2·0.66 − 1)·1 = 0.32.
        let s = QuantizeSettings(gridBeats: 1.0, swingPercent: 66)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.9, settings: s), 1.32))   // slot 1 (odd)
        #expect(approx(QuantizeTarget.nearest(toBeat: 3.1, settings: s), 3.32))   // slot 3 (odd)
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.9, settings: s), 2.0))    // slot 2 (even) unshifted
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.1, settings: s), 0.0))    // slot 0 (even) unshifted
        // grid 0.5 (1/8): odd-slot offset = 0.32·0.5 = 0.16.
        let eighth = QuantizeSettings(gridBeats: 0.5, swingPercent: 66)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.5, settings: eighth), 0.66))  // slot 1 (odd)
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.0, settings: eighth), 1.0))   // slot 2 (even)
    }

    // 3.
    @Test("swing 75 is the max half-grid delay; sub-50 reads as straight")
    func swingBounds() {
        // 75 → (2·0.75 − 1)·grid = 0.5·grid (offbeat lands halfway to the next slot).
        let hot = QuantizeSettings(gridBeats: 1.0, swingPercent: 75)
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.1, settings: hot), 1.5))
        // Below 50 pins to 50 (straight) — no negative "rush".
        let low = QuantizeSettings(gridBeats: 1.0, swingPercent: 20)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.9, settings: low), 1.0))
    }
}

// MARK: - MIDIQuantizer

@Suite("MIDIQuantizer — strength, lengths, order, idempotence")
struct MIDIQuantizerTests {

    // 4.
    @Test("strength lerps onsets 0 → 0.5 → 1 exactly; lengths preserved")
    func strength() {
        let notes = [
            MIDINote(pitch: 60, startBeat: 0.2, lengthBeats: 0.75),  // target 0.0
            MIDINote(pitch: 64, startBeat: 0.8, lengthBeats: 0.5),   // target 1.0
        ]
        // strength 1 → snap fully.
        let full = MIDIQuantizer.quantize(notes, settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(approx(full[0].startBeat, 0.0) && approx(full[1].startBeat, 1.0))
        // Lengths untouched (quantizeEnds default false).
        #expect(approx(full[0].lengthBeats, 0.75) && approx(full[1].lengthBeats, 0.5))
        // strength 0.5 → exactly halfway.
        let half = MIDIQuantizer.quantize(notes, settings: QuantizeSettings(gridBeats: 1.0, strength: 0.5))
        #expect(approx(half[0].startBeat, 0.1) && approx(half[1].startBeat, 0.9))
        // strength 0 → identity.
        let none = MIDIQuantizer.quantize(notes, settings: QuantizeSettings(gridBeats: 1.0, strength: 0))
        #expect(approx(none[0].startBeat, 0.2) && approx(none[1].startBeat, 0.8))
    }

    // 5.
    @Test("quantizeEnds snaps ends and never collapses below minLength")
    func ends() {
        // Normal case: onset 0.1 → 0, end 1.1 → 1 ⇒ length 1.0.
        let n1 = [MIDINote(pitch: 60, startBeat: 0.1, lengthBeats: 1.0)]
        let q1 = MIDIQuantizer.quantize(n1, settings: QuantizeSettings(gridBeats: 1.0, strength: 1, quantizeEnds: true))
        #expect(approx(q1[0].startBeat, 0.0) && approx(q1[0].lengthBeats, 1.0))
        // Collapse case: onset and end both snap to slot 0 ⇒ length floored at minLength.
        let n2 = [MIDINote(pitch: 60, startBeat: 0.4, lengthBeats: MIDINote.minLengthBeats)]
        let q2 = MIDIQuantizer.quantize(n2, settings: QuantizeSettings(gridBeats: 1.0, strength: 1, quantizeEnds: true))
        #expect(approx(q2[0].startBeat, 0.0))
        #expect(q2[0].lengthBeats == MIDINote.minLengthBeats)
    }

    // 6.
    @Test("output is canonically ordered even when quantize reorders onsets")
    func canonicalOrder() {
        let a = MIDINote(pitch: 64, startBeat: 0.9)   // → 1.0
        let b = MIDINote(pitch: 60, startBeat: 1.1)   // → 1.0 (same onset, lower pitch sorts first)
        let c = MIDINote(pitch: 62, startBeat: 0.1)   // → 0.0 (earliest, sorts first)
        let out = MIDIQuantizer.quantize([a, b, c], settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(out.map(\.pitch) == [62, 60, 64])
        #expect(out.map(\.startBeat).map { ($0 * 10).rounded() / 10 } == [0.0, 1.0, 1.0])
    }

    // 7.
    @Test("determinism + idempotence: quantize twice at strength 1 equals once (straight and swung)")
    func idempotence() {
        let notes = [
            MIDINote(pitch: 60, startBeat: 0.9),
            MIDINote(pitch: 62, startBeat: 3.1),
            MIDINote(pitch: 64, startBeat: 1.9),
            MIDINote(pitch: 67, startBeat: 0.1),
        ]
        for settings in [
            QuantizeSettings(gridBeats: 1.0, strength: 1),
            QuantizeSettings(gridBeats: 1.0, strength: 1, swingPercent: 66),
        ] {
            let once = MIDIQuantizer.quantize(notes, settings: settings)
            let twice = MIDIQuantizer.quantize(once, settings: settings)
            // Determinism: a fresh pass matches; idempotence: a second pass is a no-op.
            #expect(MIDIQuantizer.quantize(notes, settings: settings) == once)
            #expect(twice == once)
        }
    }
}

// MARK: - Store op

@MainActor
@Suite("ProjectStore — quantizeClipNotes")
struct QuantizeStoreTests {

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    // 8.
    @Test("quantizeClipNotes: snaps onsets, preserves lengths, canonical order, single undo restores")
    func happyPath() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.2, lengthBeats: 1.0),
            MIDINote(pitch: 64, startBeat: 1.1, lengthBeats: 0.5),
            MIDINote(pitch: 67, startBeat: 1.9, lengthBeats: 0.5),
        ])
        let updated = try store.quantizeClipNotes(
            clipId: clip.id, settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        let starts = updated.notes!.map(\.startBeat)
        #expect(starts.count == 3)
        #expect(approx(starts[0], 0) && approx(starts[1], 1) && approx(starts[2], 2))
        #expect(updated.notes!.map(\.lengthBeats) == [1.0, 0.5, 0.5])   // lengths preserved
        #expect(store.tracks[0].clips[0].notes!.map(\.startBeat).allSatisfy { $0 == $0.rounded() })

        // One undo step restores the exact original onsets.
        #expect(try store.undo() == "Quantize Notes")
        let restored = store.tracks[0].clips[0].notes!.map(\.startBeat)
        #expect(approx(restored[0], 0.2) && approx(restored[1], 1.1) && approx(restored[2], 1.9))
    }

    // 9.
    @Test("audio clip rejected with quantizeRequiresMIDIClip verbatim")
    func audioRejected() throws {
        let audio = Clip(name: "a", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/a.wav"))
        let track = Track(name: "Aud", kind: .audio, clips: [audio])
        let store = ProjectStore(tracks: [track])
        let err = projectError {
            _ = try store.quantizeClipNotes(clipId: audio.id, settings: QuantizeSettings(gridBeats: 1.0))
        }
        guard case .quantizeRequiresMIDIClip(let id)? = err, id == audio.id else {
            Issue.record("expected quantizeRequiresMIDIClip, got \(String(describing: err))"); return
        }
        #expect(err?.errorDescription
                == "clip \(audio.id.uuidString) is an audio clip — clip.quantize applies only to MIDI clips; audio quantize (clip.quantizeAudio) lands later")
        #expect(store.tracks[0].clips[0].audioFileURL != nil)   // nothing changed
    }

    // 10.
    @Test("comp member rejected with clipInTakeGroup (shared requireNotCompMember guard)")
    func compMemberRejected() throws {
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 60, startBeat: 0.3, lengthBeats: 1)])
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 62, startBeat: 0.4, lengthBeats: 1)])
        let track = Track(name: "Keys", kind: .instrument, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })
        let err = projectError {
            _ = try store.quantizeClipNotes(clipId: member.id, settings: QuantizeSettings(gridBeats: 1.0))
        }
        if case .clipInTakeGroup? = err {} else {
            Issue.record("expected clipInTakeGroup, got \(String(describing: err))")
        }
    }

    // 11.
    @Test("unknown clip id throws clipNotFound")
    func unknownClip() {
        let store = ProjectStore()
        let bogus = UUID()
        let err = projectError { _ = try store.quantizeClipNotes(clipId: bogus, settings: QuantizeSettings(gridBeats: 1.0)) }
        guard case .clipNotFound(let id)? = err, id == bogus else {
            Issue.record("expected clipNotFound, got \(String(describing: err))"); return
        }
    }

    // 12.
    @Test("rapid same-clip quantizes coalesce into one undo step")
    func coalescing() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.2, lengthBeats: 1.0),
        ])
        // A strength-slider scrub: two writes under one coalescing key.
        _ = try store.quantizeClipNotes(clipId: clip.id, settings: QuantizeSettings(gridBeats: 1.0, strength: 0.5))
        _ = try store.quantizeClipNotes(clipId: clip.id, settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(approx(store.tracks[0].clips[0].notes![0].startBeat, 0.0))   // last write won
        // One undo reverts BOTH scrubs to the original onset.
        #expect(try store.undo() == "Quantize Notes")
        #expect(approx(store.tracks[0].clips[0].notes![0].startBeat, 0.2))
    }
}
