import Foundation
import Testing
@testable import DAWCore

/// DAWCore coverage for the MIDI time-range primitives (beta m10-h): the
/// `deleteTimeRange` (delete-a-bar) and `insertTimeRange` (insert-a-bar) store
/// ops, in CLIP-LOCAL beats. Pins every crossing-note case documented on the
/// ops, the clip-length shrink/grow + clamps, the ONE-undo-per-call house rule
/// (notes + length fold together), and the validation errors. Reuses `FakeMedia`
/// (ImportTests.swift, same target) for the audio-clip rejection.
@MainActor
@Suite("ProjectStore — MIDI time-range editing")
struct MIDITimeRangeTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// (store, instrument track id, clip) with a MIDI clip of `length` beats and
    /// the given notes.
    private func midiClip(length: Double, notes: [MIDINote]) throws -> (ProjectStore, UUID, Clip) {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: length, notes: notes)
        return (store, inst.id, clip)
    }

    /// `[pitch, start, length]` rows, sorted by pitch then start, so a note list
    /// compares order-independently with `==` (arrays of tuples aren't Equatable).
    private func snapshot(_ notes: [MIDINote]?) -> [[Double]] {
        (notes ?? [])
            .map { [Double($0.pitch), $0.startBeat, $0.lengthBeats] }
            .sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }
    }

    // MARK: - deleteTimeRange

    @Test("delete: notes after shift left, onset-inside removed, before untouched; clip shrinks")
    func deleteShiftAndDrop() throws {
        let (store, _, clip) = try midiClip(length: 16, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2),   // wholly before [4,8)
            MIDINote(pitch: 62, startBeat: 5, lengthBeats: 2),   // onset inside → removed
            MIDINote(pitch: 64, startBeat: 8, lengthBeats: 2),   // at end e=8 → shift to 4
            MIDINote(pitch: 65, startBeat: 12, lengthBeats: 1),  // after → shift to 8
        ])

        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        #expect(updated.lengthBeats == 12)   // 16 − 4 excised
        #expect(snapshot(updated.notes) == [
            [60, 0, 2], [64, 4, 2], [65, 8, 1],
        ])
    }

    @Test("delete: a note ending exactly at the cut start stays (wholly before, inclusive)")
    func deleteEdgeEndsAtCut() throws {
        let (store, _, clip) = try midiClip(length: 12, notes: [
            MIDINote(pitch: 60, startBeat: 2, lengthBeats: 2),   // endBeat 4 == cut start
        ])
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        #expect(snapshot(updated.notes) == [[60, 2, 2]])
        #expect(updated.lengthBeats == 8)
    }

    @Test("delete: crossing note that ends inside the range keeps its head to the cut")
    func deleteCrossingEndsInside() throws {
        let (store, _, clip) = try midiClip(length: 8, notes: [
            MIDINote(pitch: 60, startBeat: 2, lengthBeats: 4),   // [2,6), crosses into [4,8)
        ])
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        // Head kept up to the cut: length = 4 − 2 = 2, ending at beat 4.
        #expect(snapshot(updated.notes) == [[60, 2, 2]])
        #expect(updated.lengthBeats == 4)
    }

    @Test("delete: crossing note that SPANS the whole range rejoins (length −= excised)")
    func deleteCrossingSpansRange() throws {
        let (store, _, clip) = try midiClip(length: 12, notes: [
            MIDINote(pitch: 60, startBeat: 2, lengthBeats: 8),   // [2,10) spans [4,8)
        ])
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        // Head [2,4] + tail [8,10] rejoin continuous → [2,6): length 8 − 4 = 4.
        #expect(snapshot(updated.notes) == [[60, 2, 4]])
        #expect(updated.lengthBeats == 8)
    }

    @Test("delete: a note starting exactly at the cut start is removed; at the cut END shifts")
    func deleteBoundaryOnsets() throws {
        let (store, _, clip) = try midiClip(length: 12, notes: [
            MIDINote(pitch: 60, startBeat: 4, lengthBeats: 1),   // onset == s → removed
            MIDINote(pitch: 62, startBeat: 8, lengthBeats: 1),   // onset == e → shift to 4
        ])
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        #expect(snapshot(updated.notes) == [[62, 4, 1]])
        #expect(updated.lengthBeats == 8)
    }

    @Test("delete: length runs off the clip end → truncates at startBeat")
    func deleteRunsOffEnd() throws {
        // Clip 7 beats, delete a full 4-beat bar starting at 4 → [4,8) clamps to
        // [4,7), so the clip truncates to 4 and only [4,7) content is excised.
        let (store, _, clip) = try midiClip(length: 7, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1),   // onset inside [4,7) → removed
        ])
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        #expect(snapshot(updated.notes) == [[60, 0, 1]])
        #expect(updated.lengthBeats == 4)   // truncated at s=4, not 7−4=3
    }

    @Test("delete: clip length never falls below a remaining note's extent")
    func deleteClampsToNoteExtent() throws {
        // Clip 6, note [4,8) extends past the end. Delete the first bar [0,4): the
        // note shifts to [0,4). Raw shrink would be 6−4=2, but the note extent 4
        // holds the length up.
        let (store, _, clip) = try midiClip(length: 6, notes: [
            MIDINote(pitch: 60, startBeat: 4, lengthBeats: 4),
        ])
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 0, lengthBeats: 4)
        #expect(snapshot(updated.notes) == [[60, 0, 4]])
        #expect(updated.lengthBeats == 4)   // clamped up to the note's extent
    }

    @Test("delete: an emptying range floors the clip at one beat")
    func deleteFloorsAtOneBeat() throws {
        let (store, _, clip) = try midiClip(length: 3, notes: [])
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 0, lengthBeats: 4)
        #expect((updated.notes ?? []).isEmpty)
        #expect(updated.lengthBeats == ProjectStore.minTimeRangeClipLengthBeats)   // 1.0
    }

    @Test("delete: one undo restores exact notes AND length in a single step; redo re-applies")
    func deleteUndoRoundTrip() throws {
        let originalNotes = [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2),
            MIDINote(pitch: 64, startBeat: 8, lengthBeats: 2),
        ]
        let (store, trackID, clip) = try midiClip(length: 16, notes: originalNotes)
        let before = store.tracks[0].clips[0]

        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        #expect(updated.lengthBeats == 12)

        // A SINGLE undo restores both the notes and the length (one journal entry).
        #expect(try store.undo() == "Delete Time Range")
        let restored = store.tracks[0].clips[0]
        #expect(restored == before)
        #expect(restored.lengthBeats == 16)
        #expect(snapshot(restored.notes) == snapshot(originalNotes))
        #expect(trackID == store.tracks[0].id)

        // Redo re-applies the same fold.
        #expect(try store.redo() == "Delete Time Range")
        #expect(store.tracks[0].clips[0].lengthBeats == 12)
        #expect(snapshot(store.tracks[0].clips[0].notes) == [[60, 0, 2], [64, 4, 2]])
    }

    @Test("delete: validation — clipNotFound, notAMIDIClip, non-positive length, startBeat outside")
    func deleteValidation() throws {
        let (store, _, clip) = try midiClip(length: 8, notes: [])

        // Unknown clip.
        if case .clipNotFound? = projectError({ _ = try store.deleteTimeRange(
            clipID: UUID(), startBeat: 0, lengthBeats: 4) }) {} else {
            Issue.record("expected clipNotFound")
        }
        // Audio clip.
        store.media = FakeMedia()
        let audioTrack = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: audioTrack.id)
        if case .notAMIDIClip? = projectError({ _ = try store.deleteTimeRange(
            clipID: audioClip.id, startBeat: 0, lengthBeats: 4) }) {} else {
            Issue.record("expected notAMIDIClip")
        }
        // Non-positive length.
        for bad in [0.0, -2.0] {
            if case .invalidClipEdit? = projectError({ _ = try store.deleteTimeRange(
                clipID: clip.id, startBeat: 0, lengthBeats: bad) }) {} else {
                Issue.record("expected invalidClipEdit for length \(bad)")
            }
        }
        // startBeat outside [0, length).
        for bad in [-1.0, 8.0, 20.0] {
            if case .invalidClipEdit? = projectError({ _ = try store.deleteTimeRange(
                clipID: clip.id, startBeat: bad, lengthBeats: 2) }) {} else {
                Issue.record("expected invalidClipEdit for startBeat \(bad)")
            }
        }
    }

    // MARK: - insertTimeRange

    @Test("insert: notes at/after shift right, clip grows")
    func insertShiftAndGrow() throws {
        let (store, _, clip) = try midiClip(length: 8, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),   // before atBeat → unchanged
            MIDINote(pitch: 62, startBeat: 4, lengthBeats: 2),   // at atBeat=4 → shift to 8
            MIDINote(pitch: 64, startBeat: 6, lengthBeats: 1),   // after → shift to 10
        ])
        let updated = try store.insertTimeRange(clipID: clip.id, atBeat: 4, lengthBeats: 4)
        #expect(updated.lengthBeats == 12)
        #expect(snapshot(updated.notes) == [[60, 0, 1], [62, 8, 2], [64, 10, 1]])
    }

    @Test("insert: a note crossing atBeat keeps BOTH its start and its length (sustains)")
    func insertCrossingKept() throws {
        let (store, _, clip) = try midiClip(length: 8, notes: [
            MIDINote(pitch: 60, startBeat: 2, lengthBeats: 4),   // [2,6) crosses atBeat=4
        ])
        let updated = try store.insertTimeRange(clipID: clip.id, atBeat: 4, lengthBeats: 4)
        #expect(snapshot(updated.notes) == [[60, 2, 4]])   // unchanged — sustains through the gap
        #expect(updated.lengthBeats == 12)
    }

    @Test("insert: a note starting exactly at atBeat shifts right")
    func insertBoundaryOnset() throws {
        let (store, _, clip) = try midiClip(length: 8, notes: [
            MIDINote(pitch: 60, startBeat: 4, lengthBeats: 1),
        ])
        let updated = try store.insertTimeRange(clipID: clip.id, atBeat: 4, lengthBeats: 2)
        #expect(snapshot(updated.notes) == [[60, 6, 1]])
        #expect(updated.lengthBeats == 10)
    }

    @Test("insert: at the clip end appends silence (grows, notes untouched)")
    func insertAtEnd() throws {
        let (store, _, clip) = try midiClip(length: 8, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
        ])
        let updated = try store.insertTimeRange(clipID: clip.id, atBeat: 8, lengthBeats: 4)
        #expect(snapshot(updated.notes) == [[60, 0, 1]])
        #expect(updated.lengthBeats == 12)
    }

    @Test("insert: one undo restores exact notes AND length in a single step; redo re-applies")
    func insertUndoRoundTrip() throws {
        let originalNotes = [MIDINote(pitch: 60, startBeat: 4, lengthBeats: 2)]
        let (store, _, clip) = try midiClip(length: 8, notes: originalNotes)
        let before = store.tracks[0].clips[0]

        _ = try store.insertTimeRange(clipID: clip.id, atBeat: 4, lengthBeats: 4)
        #expect(store.tracks[0].clips[0].lengthBeats == 12)

        #expect(try store.undo() == "Insert Time Range")
        #expect(store.tracks[0].clips[0] == before)
        #expect(store.tracks[0].clips[0].lengthBeats == 8)

        #expect(try store.redo() == "Insert Time Range")
        #expect(store.tracks[0].clips[0].lengthBeats == 12)
        #expect(snapshot(store.tracks[0].clips[0].notes) == [[60, 8, 2]])
    }

    @Test("insert: validation — clipNotFound, notAMIDIClip, non-positive length, atBeat outside")
    func insertValidation() throws {
        let (store, _, clip) = try midiClip(length: 8, notes: [])

        if case .clipNotFound? = projectError({ _ = try store.insertTimeRange(
            clipID: UUID(), atBeat: 0, lengthBeats: 4) }) {} else {
            Issue.record("expected clipNotFound")
        }
        store.media = FakeMedia()
        let audioTrack = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: audioTrack.id)
        if case .notAMIDIClip? = projectError({ _ = try store.insertTimeRange(
            clipID: audioClip.id, atBeat: 0, lengthBeats: 4) }) {} else {
            Issue.record("expected notAMIDIClip")
        }
        for bad in [0.0, -2.0] {
            if case .invalidClipEdit? = projectError({ _ = try store.insertTimeRange(
                clipID: clip.id, atBeat: 0, lengthBeats: bad) }) {} else {
                Issue.record("expected invalidClipEdit for length \(bad)")
            }
        }
        // atBeat outside [0, length] — end (8) is INCLUSIVE, so 8 is valid; 8.001 is not.
        for bad in [-1.0, 9.0, 20.0] {
            if case .invalidClipEdit? = projectError({ _ = try store.insertTimeRange(
                clipID: clip.id, atBeat: bad, lengthBeats: 2) }) {} else {
                Issue.record("expected invalidClipEdit for atBeat \(bad)")
            }
        }
        // atBeat exactly at the length is allowed (append).
        #expect(throws: Never.self) {
            _ = try store.insertTimeRange(clipID: clip.id, atBeat: 8, lengthBeats: 2)
        }
    }
}
