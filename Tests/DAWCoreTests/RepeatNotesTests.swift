import Testing
import Foundation
@testable import DAWCore

/// m31-c — `ProjectStore.repeatNotes`: literal, time-shifted, optionally
/// chromatically-transposed copies of a clip-relative note window (or an
/// explicit note set), written back into the SAME clip as an UNCOALESCED
/// edit. Built to the `pasteNotes` shape (`ProjectStore+Paste.swift`) for the
/// same reason: `setClipNotes` coalesces same-clip edits within 800 ms, and a
/// repeat must not fold into a neighbouring edit or vice versa.
@MainActor
@Suite("Repeat notes (m31-c)")
struct RepeatNotesTests {

    // MARK: - Helpers

    private func makeStore(
        clipNotes: [MIDINote] = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)],
        clipLengthBeats: Double = 4
    ) throws -> (store: ProjectStore, track: Track, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0,
                                         lengthBeats: clipLengthBeats, notes: clipNotes)
        return (store, track, clip)
    }

    // MARK: - 1. The coalescing trap — the highest-value tests in this file

    /// ⚠️⚠️ THE TEST THE NAIVE IMPLEMENTATION (`getNotes` -> append ->
    /// `setClipNotes`) PASSES WITHOUT EVER SEEING THE BUG IT EXISTS TO CATCH.
    /// See the plant-and-redden verification recorded in the task report:
    /// planting `key: "clip.notes:\(clipID.uuidString)"` on the `performEdit`
    /// call inside `ProjectStore.repeatNotes` turns this test RED.
    @Test("a repeat 100 ms after a note edit is its OWN undo step")
    func repeatDoesNotCoalesceIntoThePrecedingEdit() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        let afterEdit = store.journal.undoStack.count
        // WELL INSIDE the 800 ms window — this is the whole point.
        clock = clock.advanced(by: .milliseconds(100))
        try store.repeatNotes(clipID: clip.id, periodBeats: 4, count: 1)

        #expect(store.journal.undoStack.count == afterEdit + 1)
        #expect(store.undoLabel == "Repeat Notes \u{00D7}1")

        // One undo reverses ONLY the repeat, leaving the edit standing.
        try store.undo()
        #expect(store.tracks[0].clips[0].notes?.count == 1)
        #expect(store.undoLabel == "Edit Notes")
    }

    /// ⚠️ ANTI-VACUITY CONTROL, for THIS suite's own store/clock (the paste
    /// suite's control does not cover a different store instance). Same gap,
    /// same clock, two ordinary edits instead of edit-then-repeat: reports
    /// ONE entry, proving the window is actually active here.
    @Test("CONTROL: two note EDITS 100 ms apart DO coalesce under this store's clock")
    func setClipNotesStillCoalescesUnderTheSameClock() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        let afterEdit = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(100))
        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 62, startBeat: 1)])

        #expect(store.journal.undoStack.count == afterEdit,
                "coalescing must be ACTIVE here, or the repeat test above is vacuous")
    }

    @Test("a note EDIT 100 ms after a repeat does not fold into the repeat (reverse order)")
    func editAfterRepeatIsItsOwnStep() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.repeatNotes(clipID: clip.id, periodBeats: 4, count: 1)
        let afterRepeat = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(100))
        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 72, startBeat: 3)])

        #expect(store.journal.undoStack.count == afterRepeat + 1)
        #expect(store.undoLabel == "Edit Notes")
    }

    // MARK: - 2. Two rapid repeats never fold into each other

    @Test("two rapid repeats are two undo steps — repeat never folds into repeat either")
    func twoRapidRepeatsDoNotFold() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.repeatNotes(clipID: clip.id, periodBeats: 4, count: 1)
        let afterFirst = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(50))
        try store.repeatNotes(clipID: clip.id, periodBeats: 4, count: 1)

        #expect(store.journal.undoStack.count == afterFirst + 1)
    }

    // MARK: - 3. One undo restores copies AND length extension together

    @Test("one undo restores BOTH the copies and the length extension")
    func undoRestoresNotesAndLengthTogether() throws {
        let (store, _, clip) = try makeStore(clipLengthBeats: 4)
        let originalLength = store.tracks[0].clips[0].lengthBeats
        let originalNotes = store.tracks[0].clips[0].notes

        try store.repeatNotes(clipID: clip.id, periodBeats: 4, count: 3)
        #expect(store.tracks[0].clips[0].lengthBeats > originalLength)
        #expect((store.tracks[0].clips[0].notes?.count ?? 0) > (originalNotes?.count ?? 0))

        try store.undo()
        #expect(store.tracks[0].clips[0].lengthBeats == originalLength)
        #expect(store.tracks[0].clips[0].notes == originalNotes)
    }

    // MARK: - 4. Copy geometry — exact onsets, canonical ordering, counts

    @Test("copy geometry: count 11, periodBeats 4 — exact onsets, canonical ordering, notesAdded == count * sourceNoteCount")
    func copyGeometryIsExact() throws {
        let sourceNotes = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
                           MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1)]
        let (store, _, clip) = try makeStore(clipNotes: sourceNotes, clipLengthBeats: 4)

        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 4,
                                           periodBeats: 4, count: 11, extendClip: true)
        #expect(report.copiesMade == 11)
        #expect(report.sourceNoteCount == 2)
        #expect(report.notesAdded == 22)

        let notes = store.tracks[0].clips[0].notes ?? []
        #expect(notes.count == 2 + 22)
        for i in 1..<notes.count {
            #expect(notes[i - 1].startBeat <= notes[i].startBeat, "canonical ordering (by startBeat)")
        }
        for k in 1...11 {
            let base = Double(4 * k)
            #expect(notes.contains { abs($0.startBeat - base) < 1e-9 && $0.pitch == 60 })
            #expect(notes.contains { abs($0.startBeat - (base + 2)) < 1e-9 && $0.pitch == 64 })
        }
    }

    // MARK: - 5. Meter change — counted on the TIMELINE span, with a negative control

    @Test("meterChangesInSpan: counted on the TIMELINE span, with a negative control entirely before the change")
    func meterChangeSpanIsMeasuredOnTheTimeline() throws {
        func meterMap() throws -> MeterMap {
            try MeterMap(changes: [
                .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4),
            ])
        }

        // Span [4, 13) crosses the change at beat 8.
        let (store, _, clip) = try makeStore(
            clipNotes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)], clipLengthBeats: 30)
        try store.setTempoMap(TempoMap(constantBPM: 120), meterMap: try meterMap())
        let crossing = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 4,
                                             periodBeats: 4, count: 3, extendClip: true)
        #expect(crossing.meterChangesInSpan == 1)

        // ⭐ NEGATIVE CONTROL, without which this field could be hardcoded to
        // 1: the same repeat, entirely before the change, reports 0.
        let (store2, _, clip2) = try makeStore(
            clipNotes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)], clipLengthBeats: 30)
        try store2.setTempoMap(TempoMap(constantBPM: 120), meterMap: try meterMap())
        let before = try store2.repeatNotes(clipID: clip2.id, fromBeat: 0, toBeat: 4,
                                            periodBeats: 1, count: 1, extendClip: true)
        #expect(before.meterChangesInSpan == 0)
    }

    // MARK: - 6. Capped grow — both shapes `ClipAutoExtend.outcome` can produce here

    /// The onset-audibility test FAILS even though the ceiling nominally
    /// leaves 6 beats of room: refused, length UNCHANGED, neighbour
    /// untouched, `extendRefusal` named, `latentNotesPastClipEnd > 0`.
    @Test("capped grow that fails the onset test: refused, length unchanged, neighbour untouched, refusal named")
    func cappedGrowRefusedByNeighbourOnsetTooFarPast() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        // trailingHeadroom == 10.
        let neighbour = try store.addMIDIClip(toTrack: track.id, atBeat: 10, lengthBeats: 4)

        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                           periodBeats: 4, count: 5, extendClip: true)
        #expect(report.extended == false)
        #expect(report.extendRefusal != nil)
        #expect(report.clipLengthBeats == 4)
        #expect(report.latentNotesPastClipEnd > 0)
        let survivor = store.tracks[0].clips.first { $0.id == neighbour.id }
        #expect(survivor?.startBeat == 10)
        #expect(survivor?.lengthBeats == 4)
    }

    /// The onset stays comfortably audible: the clip GROWS, capped EXACTLY at
    /// the headroom (10, not the bar-snapped 12 the content alone would earn),
    /// neighbour untouched, no refusal, nothing left latent.
    @Test("capped grow that passes the onset test: clip grows to EXACTLY the headroom, no refusal")
    func cappedGrowSucceedsExactlyAtHeadroom() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        // Onset 0, length 9 (end 9): the ONSET stays well inside a small
        // grown target even though the END forces a grow.
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 9)])
        let neighbour = try store.addMIDIClip(toTrack: track.id, atBeat: 10, lengthBeats: 4)

        // One copy, offset 2 -> covers [2, 11).
        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                           periodBeats: 4, count: 1, firstCopyAtBeat: 2,
                                           extendClip: true)
        #expect(report.extended == true)
        #expect(report.extendRefusal == nil)
        #expect(report.clipLengthBeats == 10)
        #expect(report.latentNotesPastClipEnd == 0)
        let survivor = store.tracks[0].clips.first { $0.id == neighbour.id }
        #expect(survivor?.startBeat == 10, "flush, not trimmed or removed")
        #expect(survivor?.lengthBeats == 4)
    }

    // MARK: - 6b. m23-ap AX — the SONG's bar line

    /// Repeat runs the same rule, and its REPORT (what the wire's
    /// `clip.repeatNotes` reply carries as `clipLengthBeats`) says so: a clip at
    /// song beat 2 in 4/4 with one copy at local 4…5 (song 6…7) grows to local 6
    /// (song 8), not local 8 (song 10).
    @Test("m23-ap AX — a repeat past an OFF-bar clip's end grows it to the SONG's next bar line, and the report says so")
    func offBarRepeatGrowsToTheSongsBarLine() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 2, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                           periodBeats: 4, count: 1, extendClip: true)
        #expect(report.extended == true)
        #expect(report.extendRefusal == nil)
        #expect(report.clipLengthBeats == 6)
        #expect(report.latentNotesPastClipEnd == 0)
        #expect(store.tracks[0].clips.first { $0.id == clip.id }?.lengthBeats == 6)
    }

    // MARK: - 7. extendClip: false

    @Test("extendClip: false — length unchanged, notes still stored (m18-f legal-but-latent), latent count reported")
    func extendClipFalseLeavesLengthUnchangedButStoresNotes() throws {
        let (store, _, clip) = try makeStore(
            clipNotes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)], clipLengthBeats: 4)
        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                           periodBeats: 4, count: 3, extendClip: false)
        #expect(report.extended == false)
        #expect(report.extendRefusal == nil, "never attempted, so nothing was refused")
        #expect(report.clipLengthBeats == 4)
        #expect(report.latentNotesPastClipEnd == 3)
        #expect(store.tracks[0].clips[0].notes?.count == 1 + 3)
    }

    // MARK: - 8. Nothing to write

    @Test("nothing to write: zeroed report, no mutation, dirty flag and undo depth unchanged")
    func emptySelectionMutatesNothing() throws {
        let (store, _, clip) = try makeStore()
        let dirtyBefore = store.isDirty
        let undoDepthBefore = store.journal.undoStack.count
        let tracksBefore = store.tracks

        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 100, toBeat: 200,
                                           periodBeats: 4, count: 1)
        #expect(report.copiesMade == 0)
        #expect(report.notesAdded == 0)
        #expect(report.sourceNoteCount == 0)
        #expect(store.isDirty == dirtyBefore)
        #expect(store.journal.undoStack.count == undoDepthBefore)
        #expect(store.tracks == tracksBefore)
    }

    // MARK: - 9. Guards — each a distinct, field-named error

    @Test("guard: unknown clip id -> clipNotFound")
    func guardClipNotFound() throws {
        let (store, _, _) = try makeStore()
        #expect(throws: ProjectError.self) {
            try store.repeatNotes(clipID: UUID(), periodBeats: 1, count: 1)
        }
    }

    @Test("guard: comp member -> clipInTakeGroup")
    func guardCompMember() throws {
        let (store, _, clip) = try makeStore()
        let idx = store.tracks[0].clips.firstIndex { $0.id == clip.id }!
        store.tracks[0].clips[idx].takeGroupID = UUID()
        do {
            _ = try store.repeatNotes(clipID: clip.id, periodBeats: 1, count: 1)
            Issue.record("expected clipInTakeGroup")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("take group") == true)
        }
    }

    @Test("guard: audio clip -> notAMIDIClip naming the 'repeat' verb")
    func guardAudioClip() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: track.id)
        do {
            _ = try store.repeatNotes(clipID: audioClip.id, periodBeats: 1, count: 1)
            Issue.record("expected notAMIDIClip")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("repeat") == true)
        }
    }

    @Test("guard: periodBeats <= 0 -> field-named error")
    func guardPeriodBeatsMustBePositive() throws {
        let (store, _, clip) = try makeStore()
        do {
            _ = try store.repeatNotes(clipID: clip.id, periodBeats: 0, count: 1)
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("periodBeats") == true)
        }
    }

    @Test("guard: count < 1 -> field-named error")
    func guardCountMustBeAtLeastOne() throws {
        let (store, _, clip) = try makeStore()
        do {
            _ = try store.repeatNotes(clipID: clip.id, periodBeats: 1, count: 0)
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("count") == true)
        }
    }

    @Test("guard: count > 512 -> field-named ceiling error")
    func guardCountCeiling() throws {
        let (store, _, clip) = try makeStore()
        do {
            _ = try store.repeatNotes(clipID: clip.id, periodBeats: 1, count: 513)
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("512") == true)
        }
    }

    @Test("guard: noteIds AND fromBeat/toBeat together -> mutually-exclusive field-named error")
    func guardMutuallyExclusiveSelection() throws {
        let (store, _, clip) = try makeStore()
        let noteID = store.tracks[0].clips[0].notes!.first!.id
        do {
            _ = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                      noteIDs: [noteID], periodBeats: 1, count: 1)
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("noteIds") == true)
        }
    }

    @Test("guard: transposeSemitones length mismatch -> names both lengths")
    func guardTransposeLengthMismatch() throws {
        let (store, _, clip) = try makeStore()
        do {
            _ = try store.repeatNotes(clipID: clip.id, periodBeats: 1, count: 3,
                                      transposeSemitones: [1, 2])
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("transposeSemitones") == true)
            #expect(error.errorDescription?.contains("2") == true)
            #expect(error.errorDescription?.contains("3") == true)
        }
    }

    @Test("guard: negative resolved offset -> refused rather than silently welded to beat 0")
    func guardNegativeResolvedOffsetRefused() throws {
        let (store, _, clip) = try makeStore()
        do {
            _ = try store.repeatNotes(clipID: clip.id, periodBeats: 1, count: 1, firstCopyAtBeat: -100)
            Issue.record("expected a throw")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("before the clip start") == true)
        }
    }

    // MARK: - 10. preExistingNotesInSpan / copiesOverlapEachOther — positive + negative each

    @Test("preExistingNotesInSpan: positive when a note already sits in the written span, negative when clear")
    func preExistingNotesInSpanBothCases() throws {
        let (store, _, clip) = try makeStore(
            clipNotes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)], clipLengthBeats: 30)
        let clean = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                          periodBeats: 4, count: 2)
        #expect(clean.preExistingNotesInSpan == 0)

        let store2 = ProjectStore()
        let track2 = store2.addTrack(kind: .instrument)
        let clip2 = try store2.addMIDIClip(toTrack: track2.id, atBeat: 0, lengthBeats: 30, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 71, startBeat: 4, lengthBeats: 1),   // sits in the copies' span
        ])
        let stacked = try store2.repeatNotes(clipID: clip2.id, fromBeat: 0, toBeat: 1,
                                             periodBeats: 4, count: 2)
        #expect(stacked.preExistingNotesInSpan >= 1)
    }

    @Test("copiesOverlapEachOther: true when periodBeats < patternSpanBeats, false otherwise")
    func copiesOverlapEachOtherBothCases() throws {
        let (store, _, clip) = try makeStore(
            clipNotes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
                       MIDINote(pitch: 64, startBeat: 3, lengthBeats: 1)],
            clipLengthBeats: 30)
        let overlapping = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 4,
                                                periodBeats: 2, count: 3)
        #expect(overlapping.copiesOverlapEachOther == true)

        let store2 = ProjectStore()
        let track2 = store2.addTrack(kind: .instrument)
        let clip2 = try store2.addMIDIClip(toTrack: track2.id, atBeat: 0, lengthBeats: 30, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, startBeat: 3, lengthBeats: 1),
        ])
        let clean = try store2.repeatNotes(clipID: clip2.id, fromBeat: 0, toBeat: 4,
                                           periodBeats: 4, count: 3)
        #expect(clean.copiesOverlapEachOther == false)
    }

    // MARK: - 11. Transpose — scalar, per-copy array, clamping with a negative control

    @Test("transpose: scalar broadcasts to every copy")
    func transposeScalarBroadcasts() throws {
        let (store, _, clip) = try makeStore(
            clipNotes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)], clipLengthBeats: 30)
        _ = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                  periodBeats: 4, count: 3, transposeSemitones: [5])
        let pitches = (store.tracks[0].clips[0].notes ?? [])
            .filter { $0.startBeat > 0 }
            .sorted { $0.startBeat < $1.startBeat }
            .map(\.pitch)
        #expect(pitches == [65, 65, 65])
    }

    @Test("transpose: per-copy array, one entry per copy")
    func transposePerCopyArray() throws {
        let (store, _, clip) = try makeStore(
            clipNotes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)], clipLengthBeats: 30)
        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                           periodBeats: 4, count: 3, transposeSemitones: [0, 5, -5])
        #expect(report.pitchesClamped == 0)
        let pitches = (store.tracks[0].clips[0].notes ?? [])
            .filter { $0.startBeat > 0 }
            .sorted { $0.startBeat < $1.startBeat }
            .map(\.pitch)
        #expect(pitches == [60, 65, 55])
    }

    @Test("transpose: pitch clamping at 0/127 is counted per note, with a negative control (untransposed reports 0)")
    func transposeClampingCounted() throws {
        let (store, _, clip) = try makeStore(
            clipNotes: [MIDINote(pitch: 2, startBeat: 0, lengthBeats: 1),
                       MIDINote(pitch: 125, startBeat: 0, lengthBeats: 1)],
            clipLengthBeats: 30)
        // copy 1 (-10): pitch 2 -> -8, CLAMPS to 0; pitch 125 -> 115, no clamp.
        // copy 2 (+10): pitch 2 -> 12, no clamp; pitch 125 -> 135, CLAMPS to 127.
        let report = try store.repeatNotes(clipID: clip.id, fromBeat: 0, toBeat: 1,
                                           periodBeats: 4, count: 2, transposeSemitones: [-10, 10])
        #expect(report.pitchesClamped == 2)

        // ⭐ NEGATIVE CONTROL: identical shape, no transpose at all.
        let store2 = ProjectStore()
        let track2 = store2.addTrack(kind: .instrument)
        let clip2 = try store2.addMIDIClip(toTrack: track2.id, atBeat: 0, lengthBeats: 30, notes: [
            MIDINote(pitch: 2, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 125, startBeat: 0, lengthBeats: 1),
        ])
        let clean = try store2.repeatNotes(clipID: clip2.id, fromBeat: 0, toBeat: 1,
                                           periodBeats: 4, count: 2)
        #expect(clean.pitchesClamped == 0)
    }

    // MARK: - 12. noteIDs mode's `sourceWindowOrigin` — the design's one underdefined case

    /// The design leaves "source window origin" undefined for noteIDs-mode
    /// selection. Resolved here as the MINIMUM selected note's `startBeat` —
    /// this test is only meaningful with an EXPLICIT `firstCopyAtBeat`,
    /// because when it is omitted the origin cancels out algebraically
    /// (`(origin + period) - origin == period`) and could not discriminate
    /// this choice from a wrong one (e.g. always anchoring at clip beat 0).
    @Test("noteIDs mode anchors the pattern on the MINIMUM selected startBeat, not on the clip's beat 0")
    func noteIDsModeUsesMinSelectedStartAsOrigin() throws {
        let n0 = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let n4 = MIDINote(pitch: 62, startBeat: 4, lengthBeats: 1)
        let n8 = MIDINote(pitch: 64, startBeat: 8, lengthBeats: 1)
        let (store, _, clip) = try makeStore(clipNotes: [n0, n4, n8], clipLengthBeats: 40)

        // Selected min startBeat is 4 (n4). offset = firstCopyAtBeat(20) - origin(4) = 16.
        // Under a WRONG origin of 0 this would instead compute offset 20 and
        // firstCopyStartBeat 24 — this assertion would fail under that bug.
        let report = try store.repeatNotes(clipID: clip.id, noteIDs: [n4.id, n8.id],
                                           periodBeats: 4, count: 1, firstCopyAtBeat: 20)
        #expect(report.firstCopyStartBeat == 20)
        #expect(report.lastCopyEndBeat == 25)
        let newNotes = (store.tracks[0].clips[0].notes ?? [])
            .filter { $0.startBeat >= 20 }
            .sorted { $0.startBeat < $1.startBeat }
        #expect(newNotes.map(\.startBeat) == [20, 24])
        #expect(newNotes.map(\.pitch) == [62, 64])
    }
}
