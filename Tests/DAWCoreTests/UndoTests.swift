import Foundation
import Testing
@testable import DAWCore

// Reuses the fakes already defined in the DAWCoreTests target:
//   FakeEngine          (CoreTests.swift)          — records engine intents
//   FakeRecordingEngine (RecordingStoreTests.swift) — captures take completion
//   FakeMedia           (ImportTests.swift)         — deterministic import facts

@MainActor
@Suite("Undo — round trips per mutator")
struct UndoRoundTripTests {
    /// A happy take at `url`.
    private func take(_ url: URL, durationSeconds: Double = 2,
                      startOffsetSeconds: Double = 0) -> RecordingResult {
        RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: startOffsetSeconds
        )
    }

    // 1.
    @Test("setTempo")
    func tempo() throws {
        let store = ProjectStore()
        try store.setTempo(140)
        #expect(store.transport.tempoBPM == 140)
        #expect(store.undoLabel == "Set Tempo")
        try store.undo()
        #expect(store.transport.tempoBPM == 120)
        try store.redo()
        #expect(store.transport.tempoBPM == 140)
    }

    // 2.
    @Test("setLoop")
    func loop() throws {
        let store = ProjectStore()
        try store.setLoop(enabled: true, startBeat: 2, endBeat: 10)
        #expect(store.undoLabel == "Change Loop")
        try store.undo()
        #expect(!store.transport.isLoopEnabled)
        #expect(store.transport.loopStartBeat == 0)
        try store.redo()
        #expect(store.transport.isLoopEnabled)
        #expect(store.transport.loopStartBeat == 2)
        #expect(store.transport.loopEndBeat == 10)
    }

    // 3.
    @Test("setPunch")
    func punch() throws {
        let store = ProjectStore()
        try store.setPunch(enabled: true, inBeat: 4, outBeat: 12)
        #expect(store.undoLabel == "Change Punch")
        try store.undo()
        #expect(!store.transport.isPunchEnabled)
        try store.redo()
        #expect(store.transport.isPunchEnabled)
        #expect(store.transport.punchInBeat == 4)
        #expect(store.transport.punchOutBeat == 12)
    }

    // 4.
    @Test("setMetronome")
    func metronome() throws {
        let store = ProjectStore()
        try store.setMetronome(enabled: true, countInBars: 2)
        #expect(store.undoLabel == "Change Metronome")
        try store.undo()
        #expect(!store.transport.isMetronomeEnabled)
        // Undo restores the PRE-EDIT value, which for a fresh store is the
        // project default — moved 0 → 1 by m23-cy. Written as the default
        // rather than as a literal so this test keeps asserting "undo went
        // back", not "undo went to zero".
        #expect(store.transport.countInBars == TransportState().countInBars)
        try store.redo()
        #expect(store.transport.isMetronomeEnabled)
        #expect(store.transport.countInBars == 2)
    }

    // 5.
    @Test("setMasterVolume")
    func masterVolume() throws {
        let store = ProjectStore()
        store.setMasterVolume(0.5)
        #expect(store.undoLabel == "Set Master Volume")
        try store.undo()
        #expect(store.masterVolume == 1)
        try store.redo()
        #expect(store.masterVolume == 0.5)
    }

    // 6.
    @Test("addTrack")
    func addTrack() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Kick")
        #expect(store.undoLabel == "Add Track 'Kick'")
        #expect(store.tracks.count == 1)
        try store.undo()
        #expect(store.tracks.isEmpty)
        try store.redo()
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].id == track.id)  // identity restored, not a fresh track
    }

    // 7.
    @Test("removeTrack")
    func removeTrack() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Snare")
        try store.removeTrack(id: track.id)
        #expect(store.undoLabel == "Remove Track 'Snare'")
        #expect(store.tracks.isEmpty)
        try store.undo()
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].id == track.id)
        try store.redo()
        #expect(store.tracks.isEmpty)
    }

    // 8.
    @Test("updateTrack")
    func updateTrack() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Bass")
        store.updateTrack(id: track.id) { $0.name = "Sub Bass" }
        #expect(store.undoLabel == "Edit Track 'Bass'")  // label uses the pre-edit name
        try store.undo()
        #expect(store.tracks[0].name == "Bass")
        try store.redo()
        #expect(store.tracks[0].name == "Sub Bass")
    }

    // 9.
    @Test("setTrackVolume")
    func trackVolume() throws {
        let store = ProjectStore()
        let track = store.addTrack()
        store.setTrackVolume(id: track.id, volume: 0.3)
        #expect(store.undoLabel == "Set 'Audio 1' Volume")
        try store.undo()
        #expect(store.tracks[0].volume == 1)
        try store.redo()
        #expect(store.tracks[0].volume == 0.3)
    }

    // 10.
    @Test("setTrackPan")
    func trackPan() throws {
        let store = ProjectStore()
        let track = store.addTrack()
        store.setTrackPan(id: track.id, pan: -0.5)
        #expect(store.undoLabel == "Set 'Audio 1' Pan")
        try store.undo()
        #expect(store.tracks[0].pan == 0)
        try store.redo()
        #expect(store.tracks[0].pan == -0.5)
    }

    // 11.
    @Test("setTrackMute")
    func trackMute() throws {
        let store = ProjectStore()
        let track = store.addTrack()
        store.setTrackMute(id: track.id, muted: true)
        #expect(store.undoLabel == "Mute 'Audio 1'")
        try store.undo()
        #expect(!store.tracks[0].isMuted)
        try store.redo()
        #expect(store.tracks[0].isMuted)
    }

    // 12.
    @Test("setTrackSolo")
    func trackSolo() throws {
        let store = ProjectStore()
        let track = store.addTrack()
        store.setTrackSolo(id: track.id, soloed: true)
        #expect(store.undoLabel == "Solo 'Audio 1'")
        try store.undo()
        #expect(!store.tracks[0].isSoloed)
        try store.redo()
        #expect(store.tracks[0].isSoloed)
    }

    // 13.
    @Test("setTrackArm")
    func trackArm() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        #expect(store.undoLabel == "Arm 'Audio 1'")
        #expect(store.tracks[0].isArmed)
        try store.undo()
        #expect(!store.tracks[0].isArmed)
        try store.redo()
        #expect(store.tracks[0].isArmed)
    }

    // 14.
    @Test("renameTrack")
    func renameTrack() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Gtr")
        store.renameTrack(id: track.id, name: "Lead Gtr")
        #expect(store.undoLabel == "Rename Track")
        try store.undo()
        #expect(store.tracks[0].name == "Gtr")
        try store.redo()
        #expect(store.tracks[0].name == "Lead Gtr")
    }

    // 15.
    @Test("importAudio")
    func importAudio() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        _ = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Kick Loop.wav"), toTrack: track.id)
        #expect(store.undoLabel == "Import 'Kick Loop'")
        #expect(store.tracks[0].clips.count == 1)
        try store.undo()
        #expect(store.tracks[0].clips.isEmpty)
        try store.redo()
        #expect(store.tracks[0].clips.count == 1)
    }

    // MIDI 10.
    @Test("addMIDIClip")
    func addMIDIClip() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id)
        #expect(store.undoLabel == "Add MIDI Clip 'MIDI Clip 1'")
        #expect(store.tracks[0].clips.count == 1)
        try store.undo()
        #expect(store.tracks[0].clips.isEmpty)
        try store.redo()
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id == clip.id)  // identity restored
    }

    // MIDI 11.
    @Test("removeClip")
    func removeMIDIClip() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, name: "Lead")
        try store.removeClip(id: clip.id)
        #expect(store.undoLabel == "Remove Clip 'Lead'")
        #expect(store.tracks[0].clips.isEmpty)
        try store.undo()
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id == clip.id)
        try store.redo()
        #expect(store.tracks[0].clips.isEmpty)
    }

    // 16 + take-completion ordering.
    @Test("recorded take lands on top of the undo stack and round-trips")
    func takeCompletion() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        store.stop()
        let url = try #require(engine.startRecordingURLs.last)
        engine.finishTake(.success(take(url)))

        #expect(store.tracks[0].clips.count == 1)
        #expect(store.undoLabel == "Record Take 1")  // pushed last, sits on top
        try store.undo()
        #expect(store.tracks[0].clips.isEmpty)        // take removed, arm entry beneath survives
        #expect(store.undoLabel == "Arm 'Gtr'")
        try store.redo()
        #expect(store.tracks[0].clips.count == 1)
    }

    // MARK: - project.transpose (p2-sing-k, lane W7-PK)
    //
    // The store door over the pure planner (`ProjectTranspose.plan`, pinned in
    // the nonisolated `ProjectTransposeTests`): one undo step, one engine call,
    // and nothing at all for a preview, a zero move or a refusal. Appended to
    // this suite rather than a new one because of the @MainActor suite cap.

    /// Keys (moves), a tuned vocal (its shift moves, its tuning is kept) and a
    /// drum machine (skipped). `highNote` lets a leg push a note to the edge.
    private func transposeFixture(highNote: Int = 67) -> (store: ProjectStore, engine: FakeEngine) {
        let keys = Track(name: "Keys", kind: .instrument, clips: [
            Clip(name: "Chords", startBeat: 0, lengthBeats: 4, notes: [
                MIDINote(pitch: 60, startBeat: 0), MIDINote(pitch: 64, startBeat: 0),
                MIDINote(pitch: highNote, startBeat: 1),
            ]),
        ])
        let verse = Clip(name: "Verse", startBeat: 0, lengthBeats: 4,
                         audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-verse.wav"),
                         pitchShiftSemitones: -1,
                         pitchEdits: PitchEditSet(analysisVersion: 1, segments: [
                             NoteSegment(startSeconds: 0.2, endSeconds: 1, detectedHz: 220,
                                         detectedConfidence: 0.9, pitchOffsetCents: 25),
                         ]))
        let vocals = Track(name: "Vocals", kind: .audio, clips: [verse])
        let drums = Track(name: "808", kind: .instrument, clips: [
            Clip(name: "Beat", startBeat: 0, lengthBeats: 4, notes: [MIDINote(pitch: 36, startBeat: 0)]),
        ], instrument: InstrumentDescriptor(kind: .drumSynth))
        let engine = FakeEngine()
        let store = ProjectStore(tracks: [keys, vocals, drums])
        store.engine = engine
        return (store, engine)
    }

    /// The project as sorted-key JSON, with the three session fields an undo
    /// legitimately moves (the dirty flag and the two labels) held fixed, so
    /// what is compared is the song.
    private func songJSON(_ store: ProjectStore) throws -> Data {
        var snapshot = store.snapshot()
        snapshot.isDirty = false
        snapshot.undoLabel = nil
        snapshot.redoLabel = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private func trackChanges(_ engine: FakeEngine) -> Int {
        engine.calls.filter { if case .tracksDidChange = $0 { return true } else { return false } }.count
    }

    @Test("transposeProject: ONE undo step and one engine call; undo restores the song exactly")
    func transposeProjectIsOneUndoStep() throws {
        let (store, engine) = transposeFixture()
        let before = try songJSON(store)
        let beforeTracks = store.tracks
        engine.clearCalls()

        let report = try store.transposeProject(semitones: 3)
        #expect(report.applied)
        #expect(trackChanges(engine) == 1)
        #expect(store.journal.undoStack.count == 1)
        #expect(store.undoLabel == "Move Song Up 3 Semitones")
        #expect(store.tracks[0].clips[0].notes?.map(\.pitch) == [63, 67, 70])
        #expect(store.tracks[1].clips[0].pitchShiftSemitones == 2)
        #expect(store.tracks[1].clips[0].pitchEdits == beforeTracks[1].clips[0].pitchEdits)
        #expect(store.tracks[2] == beforeTracks[2])
        #expect(store.isDirty)
        let after = store.tracks

        try store.undo()
        #expect(store.tracks == beforeTracks)
        #expect(try songJSON(store) == before)
        #expect(!store.canUndo)
        try store.redo()
        #expect(store.tracks == after)
    }

    @Test("transposeProject dryRun: the whole store snapshot is unchanged, nothing journaled, no engine call")
    func transposeDryRunChangesNothing() throws {
        let (store, engine) = transposeFixture()
        engine.clearCalls()
        let before = store.snapshot()
        let preview = try store.transposeProject(semitones: 3, dryRun: true)
        #expect(store.snapshot() == before)
        #expect(engine.calls.isEmpty)
        #expect(!store.canUndo)
        #expect(!store.isDirty)
        #expect(preview.dryRun && !preview.applied)
        #expect(preview.notesMoved == 3 && preview.audioClipsShifted == 1)

        // The preview is the plan the real call carries out, word for word
        // apart from its tense and flags.
        let applied = try store.transposeProject(semitones: 3)
        var asApplied = preview
        asApplied.dryRun = false
        asApplied.applied = true
        asApplied.summary = applied.summary
        #expect(asApplied == applied)
    }

    @Test("transposeProject by 0: no journal entry, no dirty mark, no engine call")
    func transposeByZeroIsANoOp() throws {
        let (store, engine) = transposeFixture()
        engine.clearCalls()
        let before = store.snapshot()
        let report = try store.transposeProject(semitones: 0)
        #expect(!report.applied)
        #expect(store.snapshot() == before)
        #expect(engine.calls.isEmpty)
        #expect(store.journal.undoStack.isEmpty)
    }

    @Test("transposeProject refusals write nothing: a note past MIDI 127, an unknown exclude id, an open looper")
    func transposeRefusalsWriteNothing() throws {
        let (store, engine) = transposeFixture(highNote: 126)
        engine.clearCalls()
        let before = store.snapshot()

        let note = #expect(throws: TransposeRefusal.self) { try store.transposeProject(semitones: 3) }
        #expect(note?.code == .transposeNoteOutOfRange)
        #expect(throws: ProjectError.self) {
            try store.transposeProject(semitones: 1, excludeTrackIds: [UUID()])
        }

        let keys = store.tracks[0].id
        store.loopDeck = LoopDeck(originBeat: 0, cycleBeats: 4, beatsPerBar: 4, lengthMode: .fixedBars,
                                  layers: [LoopLayer(trackID: keys, ordinal: 1)])
        let looper = #expect(throws: TransposeRefusal.self) { try store.transposeProject(semitones: 1) }
        #expect(looper?.code == .transposeLooperOpen)
        // A pass still in flight on the keys (its layer not created yet) counts too.
        store.loopDeck = LoopDeck(originBeat: 0, cycleBeats: 4, beatsPerBar: 4, lengthMode: .fixedBars,
                                  pending: LoopPendingLayer(trackID: keys, layerID: UUID(), mode: .overdub,
                                                            launchBeat: 0, armBeat: 0, phase: .queued,
                                                            definesLength: false, isNewLayer: true))
        let pending = #expect(throws: TransposeRefusal.self) { try store.transposeProject(semitones: 1) }
        #expect(pending?.code == .transposeLooperOpen)

        #expect(store.snapshot() == before)
        #expect(engine.calls.isEmpty)
        #expect(store.journal.undoStack.isEmpty)

        // A layer on the DRUM track does not block: its notes do not move.
        store.loopDeck = LoopDeck(originBeat: 0, cycleBeats: 4, beatsPerBar: 4, lengthMode: .fixedBars,
                                  layers: [LoopLayer(trackID: store.tracks[2].id, ordinal: 1)])
        #expect(try store.transposeProject(semitones: 1).applied)
    }

    // MARK: - Auto-Correct on a shifted clip (PK-F1, round 3, lane W7-PK)
    //
    // The store door over `PitchAutoCorrect.build(…, clipShiftSemitones:)`: it
    // hands the policy the clip's CURRENT shift, and the pass stays ONE undo
    // step. The physics (tracked pitch through the render) is pinned in
    // DAWEngineTests' `ProjectTransposeRenderTests`. Appended here, not a new
    // suite, because of the @MainActor suite cap.

    private static let eFlatMajorOptions = PitchAutoCorrectOptions(
        scale: PKF1Fixture.eFlatMajor, strength: 1, retuneMs: 30, preserveVibrato: true)

    /// One vocal clip at `shift`, on a real (tiny) file: `detectClipPitch`
    /// checks the file exists before it asks the engine.
    private func autoCorrectFixture(shift: Double) throws
        -> (store: ProjectStore, engine: PKF1PitchEngine, clipID: UUID) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w7-pk-f1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("verse.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        let clip = Clip(name: "Verse take", startBeat: 0, lengthBeats: 8,
                        audioFileURL: url, pitchShiftSemitones: shift)
        let store = ProjectStore(tracks: [Track(name: "Lead vocal", kind: .audio, clips: [clip])])
        let engine = PKF1PitchEngine()
        store.engine = engine
        return (store, engine, clip.id)
    }

    @Test("PK-F1: Auto-Correct on a clip moved +3 snaps what PLAYS onto the song's key, and undoes in one step")
    func autoCorrectSnapsThePlayedPitch() async throws {
        let (store, engine, clipID) = try autoCorrectFixture(shift: 3)
        let clip = try await store.autoCorrectClipPitch(clipId: clipID, options: Self.eFlatMajorOptions)
        #expect(engine.detectCalls == 1)
        // Played = sung + 3 = 59.65 / 62.3 / 64.6 -> C4 / D4 / F4, all on E-flat
        // major, stored relative to the RECORDING: +35 / -30 / +40 cents.
        let offsets = PKF1Fixture.noteOffsets(clip.pitchEdits)
        #expect(offsets.count == 3)
        for (offset, expected) in zip(offsets, [35.0, -30, 40]) {
            #expect(abs(offset - expected) < 1e-6, "stored \(offset), expected \(expected)")
        }
        // Bit for bit what the policy builds at the clip's shift.
        let atShift = PitchAutoCorrect.build(from: PKF1Fixture.result(), options: Self.eFlatMajorOptions,
                                             clipShiftSemitones: 3).editSet
        #expect(offsets.map(\.bitPattern) == PKF1Fixture.noteOffsets(atShift).map(\.bitPattern))
        // NEGATIVE CONTROL, the pre-PK-F1 arithmetic: the RECORDING snapped with
        // the shift ignored stores -65 / +70 / +40, which then plays B3 (off the
        // key) and E-flat4 (a wrong note) once the +3 shift is added.
        let ignored = PitchAutoCorrect.build(from: PKF1Fixture.result(), options: Self.eFlatMajorOptions).editSet
        let ignoredOffsets = PKF1Fixture.noteOffsets(ignored)
        for (offset, expected) in zip(ignoredOffsets, [-65.0, 70, 40]) {
            #expect(abs(offset - expected) < 1e-6, "stored \(offset), expected \(expected)")
        }
        #expect(offsets != ignoredOffsets)
        // ONE undo step, and redo puts back exactly the same table.
        try store.undo()
        #expect(store.tracks[0].clips[0].pitchEdits == nil)
        try store.redo()
        #expect(PKF1Fixture.noteOffsets(store.tracks[0].clips[0].pitchEdits) == offsets)
        withExtendedLifetime(engine) {}
    }

    @Test("PK-F1: the shift the policy snaps at is the one the clip has AFTER detection, the one the table plays under")
    func autoCorrectReadsTheShiftAfterDetection() async throws {
        let (store, engine, clipID) = try autoCorrectFixture(shift: 0)
        // A key change (the real one, `project.transpose` +3) lands while the
        // pitch is being detected.
        var landed = false
        engine.onDetect = { landed = (try? store.transposeProject(semitones: 3))?.applied ?? false }
        let clip = try await store.autoCorrectClipPitch(clipId: clipID, options: Self.eFlatMajorOptions)
        #expect(landed)
        #expect(clip.pitchShiftSemitones == 3)
        let offsets = PKF1Fixture.noteOffsets(clip.pitchEdits)
        #expect(offsets.count == 3)
        for (offset, expected) in zip(offsets, [35.0, -30, 40]) {
            #expect(abs(offset - expected) < 1e-6, "stored \(offset), expected \(expected)")
        }
        withExtendedLifetime(engine) {}
    }

    @Test("PK-F1 INVARIANCE: a clip at shift 0 stores exactly what the frozen pre-change arithmetic stores, bit for bit")
    func autoCorrectAtShiftZeroIsUnchanged() async throws {
        let (store, engine, clipID) = try autoCorrectFixture(shift: 0)
        let report = try await store.autoCorrectClipPitchReport(clipId: clipID, options: Self.eFlatMajorOptions)
        let clip = report.clip
        // `PrePitchNoteSplitReference` is the FROZEN copy of the policy's old
        // arithmetic (one segment per run; this contour has one note per run).
        let frozen = PrePitchNoteSplitReference.editSet(from: PKF1Fixture.result(),
                                                        options: Self.eFlatMajorOptions)
        #expect(frozen.segments.count == 3)
        #expect(PKF1Fixture.noteOffsets(clip.pitchEdits).map(\.bitPattern)
                == frozen.segments.map(\.pitchOffsetCents.bitPattern))
        #expect(report.keptDetuneCents == nil)
        // Every stored field but `id`, note by note (the oracle's own comparison).
        let notes = (clip.pitchEdits?.segments ?? []).filter { $0.origin != .unpitched }
        try #require(notes.count == frozen.segments.count)
        for (i, (stored, reference)) in zip(notes, frozen.segments).enumerated() {
            let fields = PrePitchNoteSplitReference.differingFields(stored, reference)
            #expect(fields.compared >= 14 && fields.differing.isEmpty,
                    "note \(i): \(fields.differing) (\(fields.compared) fields compared)")
        }
        withExtendedLifetime(engine) {}
    }

    @Test("PK-F1 ruling: on a clip shifted +3.3, Auto-Correct stores the +3 table, keeps the +30 c detune, and says so in its response")
    func autoCorrectReportsTheKeptDetune() async throws {
        let (store, engine, clipID) = try autoCorrectFixture(shift: 3.3)
        let report = try await store.autoCorrectClipPitchReport(clipId: clipID, options: Self.eFlatMajorOptions)
        let atWhole = PitchAutoCorrect.build(from: PKF1Fixture.result(), options: Self.eFlatMajorOptions,
                                             clipShiftSemitones: 3).editSet
        let stored = PKF1Fixture.noteOffsets(report.clip.pitchEdits)
        #expect(stored.count == 3)
        #expect(stored.map(\.bitPattern) == PKF1Fixture.noteOffsets(atWhole).map(\.bitPattern))
        // ...and that table is the pre-registered one: +35 / -30 / +40 cents.
        for (offset, expected) in zip(stored, [35.0, -30, 40]) {
            #expect(abs(offset - expected) < 1e-6, "stored \(offset), expected \(expected)")
        }
        let kept = try #require(report.keptDetuneCents)
        #expect(abs(kept - 30) < 1e-9)
        #expect(report.keptDetuneNotice == "Kept this clip's +30 cent detune (its pitch shift is +3.3 "
                + "semitones): each corrected note plays 30 cents sharp of the scale, as the shift asks.")
        // A FLAT detune says so: -0.5 rounds away from zero to -1, keeping +50 c.
        let (flatStore, flatEngine, flatID) = try autoCorrectFixture(shift: 0.5)
        let flat = try await flatStore.autoCorrectClipPitchReport(clipId: flatID, options: Self.eFlatMajorOptions)
        #expect(flat.keptDetuneNotice == "Kept this clip's -50 cent detune (its pitch shift is +0.5 "
                + "semitones): each corrected note plays 50 cents flat of the scale, as the shift asks.")
        // CONTROL: a whole shift keeps nothing and says nothing.
        let (wholeStore, wholeEngine, wholeID) = try autoCorrectFixture(shift: 3)
        let plain = try await wholeStore.autoCorrectClipPitchReport(clipId: wholeID, options: Self.eFlatMajorOptions)
        #expect(plain.keptDetuneCents == nil)
        #expect(plain.keptDetuneNotice == nil)
        withExtendedLifetime((engine, flatEngine, wholeEngine)) {}
    }

    @Test("(d) the store door names a pending AI fix before the key moves, in a preview too, and nothing when none is pending")
    func transposeNamesPendingFixesBeforeTheKeyMoves() throws {
        let clip = Clip(name: "Verse take", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-d-verse.wav"))
        let store = ProjectStore(tracks: [Track(name: "Lead vocal", kind: .audio, clips: [clip])])
        store.pendingClipFixes["job-1"] = PendingClipFix(
            jobID: "job-1", trackID: store.tracks[0].id,
            target: .clip(id: clip.id, fingerprint: ClipGeometryFingerprint(of: clip)),
            windowStartBeat: 0, windowLengthBeats: 8, regionStartBeat: 0, regionEndBeat: 8,
            mapRevision: 0, regionBPM: 120, submittedAt: Date())

        let preview = try store.transposeProject(semitones: 2, dryRun: true)
        #expect(store.tracks[0].clips[0].pitchShiftSemitones == 0, "a preview moves nothing")
        let named = preview.warnings.filter { $0.code == .pendingFixWillBeRefused }
        #expect(named.count == 1)
        #expect(named.first?.clipIds == [clip.id])
        #expect(named.first?.message.contains("'Lead vocal'") == true)

        let applied = try store.transposeProject(semitones: 2)
        #expect(applied.applied)
        #expect(applied.warnings.filter { $0.code == .pendingFixWillBeRefused }.count == 1)

        store.pendingClipFixes = [:]
        let quiet = try store.transposeProject(semitones: 1)
        #expect(quiet.applied)
        #expect(quiet.warnings.allSatisfy { $0.code != .pendingFixWillBeRefused })
    }
}

@MainActor
@Suite("Undo — history semantics")
struct UndoSemanticsTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func take(_ url: URL) -> RecordingResult {
        RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: 2, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: 0
        )
    }

    @Test("undo preserves the live playhead and play state, restoring only the document")
    func transiencePreserved() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        store.setMasterVolume(0.5)
        try store.seek(toBeats: 8)   // playhead move is not itself undoable
        store.play()
        #expect(store.transport.isPlaying)

        try store.undo()
        #expect(store.masterVolume == 1)             // document reverted
        #expect(store.transport.isPlaying)           // live play state kept
        #expect(store.transport.positionBeats == 8)  // live playhead kept
        #expect(!store.transport.isRecording)
    }

    @Test("a no-op mutation marks dirty but pushes no undo entry")
    func noOpSuppression() {
        let store = ProjectStore()
        store.setMasterVolume(1)  // already unity
        #expect(!store.canUndo)
        #expect(store.isDirty)

        let track = store.addTrack()  // a real edit
        store.setTrackMute(id: track.id, muted: false)  // already unmuted → no-op
        #expect(store.undoLabel == "Add Track 'Audio 1'")  // mute pushed nothing
    }

    @Test("rapid same-key edits coalesce into one undo step")
    func coalescingMerge() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        store.setMasterVolume(0.5)
        clock = clock.advanced(by: .milliseconds(200))
        store.setMasterVolume(0.7)
        #expect(store.journal.undoStack.count == 1)
        try store.undo()
        #expect(store.masterVolume == 1)  // restores to before the FIRST edit
    }

    // MIDI 12.
    @Test("rapid setClipNotes edits on one clip coalesce into a single undo step")
    func midiNotesCoalesce() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id)  // one entry so far
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        clock = clock.advanced(by: .milliseconds(200))
        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 62, startBeat: 1)])
        clock = clock.advanced(by: .milliseconds(200))
        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 64, startBeat: 2)])

        // addTrack + addMIDIClip + the three coalesced note edits (one step) =
        // three undo entries.
        #expect(store.journal.undoStack.count == 3)
        #expect(store.undoLabel == "Edit Notes")

        // One undo restores the clip to its (empty) pre-edit note list.
        try store.undo()
        #expect(store.tracks[0].clips[0].notes == [])
        #expect(store.undoLabel == "Add MIDI Clip 'MIDI Clip 1'")
    }

    @Test("a same-key edit past the window opens a new undo step")
    func coalescingExpiry() {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        store.setMasterVolume(0.5)
        clock = clock.advanced(by: .milliseconds(900))  // > 800 ms window
        store.setMasterVolume(0.7)
        #expect(store.journal.undoStack.count == 2)
    }

    @Test("the coalescing window slides forward on each merge")
    func coalescingSlides() {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        store.setMasterVolume(0.5)
        clock = clock.advanced(by: .milliseconds(500))
        store.setMasterVolume(0.6)
        clock = clock.advanced(by: .milliseconds(500))  // 1000 ms total, but each step < 800
        store.setMasterVolume(0.7)
        #expect(store.journal.undoStack.count == 1)
    }

    @Test("different coalescing keys never merge")
    func coalescingCrossTarget() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        store.setMasterVolume(0.5)         // key mixer.master
        clock = clock.advanced(by: .milliseconds(100))
        try store.setTempo(130)            // key transport.tempo
        #expect(store.journal.undoStack.count == 2)
    }

    @Test("a fresh edit clears the redo stack")
    func redoCleared() throws {
        let store = ProjectStore()
        store.setMasterVolume(0.5)
        try store.setTempo(130)
        try store.undo()
        #expect(store.canRedo)
        store.setMasterVolume(0.8)  // forks history
        #expect(!store.canRedo)
    }

    @Test("cap evicts the oldest undo entries")
    func capEviction() {
        let store = ProjectStore()
        store.journal.cap = 2
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        store.addTrack(name: "C")
        #expect(store.journal.undoStack.count == 2)
        #expect(store.journal.undoStack.first?.label == "Add Track 'B'")
    }

    @Test("undo / redo on empty history throw the exact messages")
    func errorCases() {
        let store = ProjectStore()
        do {
            _ = try store.undo(); Issue.record("expected nothingToUndo")
        } catch let error as ProjectError {
            guard case .nothingToUndo = error else { Issue.record("wrong case: \(error)"); return }
            #expect(error.errorDescription == "nothing to undo")
        } catch { Issue.record("unexpected: \(error)") }

        do {
            _ = try store.redo(); Issue.record("expected nothingToRedo")
        } catch let error as ProjectError {
            guard case .nothingToRedo = error else { Issue.record("wrong case: \(error)"); return }
            #expect(error.errorDescription == "nothing to redo")
        } catch { Issue.record("unexpected: \(error)") }
    }

    @Test("undo and redo are refused while recording, with the exact messages")
    func refusedWhileRecording() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()

        do {
            _ = try store.undo(); Issue.record("expected transportBusy")
        } catch let error as ProjectError {
            guard case .transportBusy(let message) = error else { Issue.record("wrong: \(error)"); return }
            #expect(message == "cannot undo while recording — stop first")
        }
        // The recording guard is checked before the empty-stack guard.
        do {
            _ = try store.redo(); Issue.record("expected transportBusy")
        } catch let error as ProjectError {
            guard case .transportBusy(let message) = error else { Issue.record("wrong: \(error)"); return }
            #expect(message == "cannot redo while recording — stop first")
        }
    }

    @Test("newProject clears the undo history")
    func newProjectClearsHistory() throws {
        let store = ProjectStore()
        store.addTrack(name: "A")
        #expect(store.canUndo)
        try store.newProject(discardChanges: true)
        #expect(!store.canUndo)
        #expect(!store.canRedo)
    }

    @Test("open clears history; save leaves it intact")
    func loadBarrierAndSave() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.addTrack(name: "Vox")
        let path = tempDir().appendingPathComponent("Song").path
        try store.saveProject(to: path)
        #expect(store.canUndo)  // saving does NOT wipe history

        let opener = ProjectStore()
        opener.media = FakeMedia()
        opener.addTrack(name: "scratch")
        #expect(opener.canUndo)
        try opener.openProject(at: path, discardChanges: true)
        #expect(!opener.canUndo)  // the load boundary cleared it
    }

    @Test("undo re-dirties a saved session")
    func dirtyAfterUndo() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.addTrack(name: "A")
        let path = tempDir().appendingPathComponent("Song").path
        try store.saveProject(to: path)
        #expect(!store.isDirty)
        try store.undo()
        #expect(store.isDirty)
    }

    @Test("undoing a track removal prunes its stale meter entry")
    func meterPruning() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.5, rms: 0.3))
        #expect(store.trackMeters[track.id] != nil)

        try store.undo()  // reverses the add — the track vanishes
        #expect(store.trackMeters[track.id] == nil)
    }

    @Test("undo reconciles only the engine intents whose inputs actually moved")
    func targetedReconcile() throws {
        // Master volume → masterVolumeChanged only.
        do {
            let engine = FakeEngine(); let store = ProjectStore(); store.engine = engine
            store.setMasterVolume(0.5); engine.clearCalls()
            try store.undo()
            #expect(engine.calls == [.masterVolume(1)])
        }
        // Tempo → setTempo only.
        do {
            let engine = FakeEngine(); let store = ProjectStore(); store.engine = engine
            try store.setTempo(90); engine.clearCalls()
            try store.undo()
            #expect(engine.calls == [.setTempo(bpm: 120)])
        }
        // Loop → loopChanged only.
        do {
            let engine = FakeEngine(); let store = ProjectStore(); store.engine = engine
            try store.setLoop(enabled: true, startBeat: 0, endBeat: 8); engine.clearCalls()
            try store.undo()
            #expect(engine.calls == [.loopChanged(enabled: false)])
        }
        // Track change → tracksDidChange only.
        do {
            let engine = FakeEngine(); let store = ProjectStore(); store.engine = engine
            store.addTrack(name: "X"); engine.clearCalls()
            try store.undo()
            #expect(engine.calls == [.tracksDidChange(count: 0)])
        }
        // Punch carries no engine intent — undo stays silent.
        do {
            let engine = FakeEngine(); let store = ProjectStore(); store.engine = engine
            try store.setPunch(enabled: true, inBeat: 0, outBeat: 8); engine.clearCalls()
            try store.undo()
            #expect(engine.calls.isEmpty)
        }
    }
}

@Suite("UndoJournal")
struct UndoJournalTests {
    private func state(_ v: Double) -> EditState {
        EditState(tracks: [], masterVolume: v, transport: TransportState())
    }

    @Test("recordEdit appends and surfaces the top label")
    func appendAndLabel() {
        var journal = UndoJournal()
        #expect(journal.undoLabel == nil)
        journal.recordEdit(label: "A", key: nil, before: state(1))
        #expect(journal.undoStack.count == 1)
        #expect(journal.undoLabel == "A")
        #expect(journal.redoLabel == nil)
    }

    @Test("popUndo moves the entry to redo; popRedo mirrors it back")
    func popUndoRedo() {
        var journal = UndoJournal()
        journal.recordEdit(label: "A", key: nil, before: state(1))
        let popped = journal.popUndo(current: state(2))
        #expect(popped?.label == "A")
        #expect(popped?.before == state(1))
        #expect(journal.undoStack.isEmpty)
        #expect(journal.redoLabel == "A")

        let redone = journal.popRedo(current: state(1))
        #expect(redone?.before == state(2))  // redo captured the state at undo time
        #expect(journal.undoLabel == "A")
        #expect(journal.redoStack.isEmpty)
    }

    @Test("recordEdit clears any pending redo")
    func recordClearsRedo() {
        var journal = UndoJournal()
        journal.recordEdit(label: "A", key: nil, before: state(1))
        _ = journal.popUndo(current: state(2))
        #expect(journal.redoLabel == "A")
        journal.recordEdit(label: "B", key: nil, before: state(3))
        #expect(journal.redoStack.isEmpty)
    }

    @Test("clear empties both stacks")
    func clearBoth() {
        var journal = UndoJournal()
        journal.recordEdit(label: "A", key: nil, before: state(1))
        _ = journal.popUndo(current: state(2))
        journal.clear()
        #expect(journal.undoStack.isEmpty && journal.redoStack.isEmpty)
        #expect(journal.undoLabel == nil && journal.redoLabel == nil)
    }

    @Test("cap evicts the oldest undo entries")
    func capEviction() {
        var journal = UndoJournal()
        journal.cap = 3
        for i in 0..<5 { journal.recordEdit(label: "e\(i)", key: nil, before: state(Double(i))) }
        #expect(journal.undoStack.count == 3)
        #expect(journal.undoStack.first?.label == "e2")
        #expect(journal.undoStack.last?.label == "e4")
    }

    @Test("an in-window same-key edit merges, keeping the first before-state")
    func inWindowMerges() {
        var journal = UndoJournal()
        var clock = ContinuousClock.now
        journal.now = { clock }
        journal.recordEdit(label: "Vol", key: "k1", before: state(1))
        clock = clock.advanced(by: .milliseconds(200))
        journal.recordEdit(label: "Vol", key: "k1", before: state(2))
        #expect(journal.undoStack.count == 1)
        #expect(journal.undoStack.first?.before == state(1))
    }

    @Test("the post-pop barrier blocks the next in-window same-key coalesce")
    func barrierBlocksCoalesce() {
        var journal = UndoJournal()
        var clock = ContinuousClock.now
        journal.now = { clock }
        journal.recordEdit(label: "Vol", key: "k1", before: state(1))    // entry1 @ t0
        clock = clock.advanced(by: .milliseconds(100))
        journal.recordEdit(label: "Tempo", key: "k2", before: state(2))  // entry2, different key → separate
        #expect(journal.undoStack.count == 2)

        _ = journal.popUndo(current: state(3))  // pops entry2, arms the barrier; entry1 (k1 @ t0) is now top
        #expect(journal.undoStack.count == 1)

        clock = clock.advanced(by: .milliseconds(100))  // t0+200: inside entry1's window
        journal.recordEdit(label: "Vol2", key: "k1", before: state(3))  // same key, in window, BUT barrier → append
        #expect(journal.undoStack.count == 2)
    }

    // MARK: - Label projection (m11-b)

    @Test("undoLabels / redoLabels project both stacks NEWEST-FIRST")
    func labelProjectionOrder() {
        var journal = UndoJournal()
        journal.recordEdit(label: "A", key: nil, before: state(1))   // oldest
        journal.recordEdit(label: "B", key: nil, before: state(2))
        journal.recordEdit(label: "C", key: nil, before: state(3))   // newest (top)
        // Newest-first: [0] is the top of the stack (what popUndo reverses next).
        #expect(journal.undoLabels == ["C", "B", "A"])
        #expect(journal.redoLabels == [])

        // Undo twice: C then B move to redo; redo top is B (last popped) → newest-first.
        _ = journal.popUndo(current: state(4))   // pops C
        _ = journal.popUndo(current: state(5))   // pops B
        #expect(journal.undoLabels == ["A"])
        #expect(journal.redoLabels == ["B", "C"])  // redo[0] = next redo = B (the top)
    }
}

/// The `ProjectStore.undoHistory()` projection (m11-b): the read-only façade the
/// history panel + `edit.history` wire read. Pins the ordering CONTRACT
/// (newest-first, undo[0]/redo[0] = what undo()/redo() act on next), that
/// coalescing folds to one entry, movement between stacks on undo/redo, cap
/// eviction, and the load-boundary clear — WITHOUT any journal mutation surface.
@MainActor
@Suite("Undo history — projection (m11-b)")
struct UndoHistoryProjectionTests {

    @Test("undoHistory is newest-first and undo[0] is what undo() reverses next")
    func newestFirstContract() {
        let store = ProjectStore()
        store.addTrack(name: "A")   // "Add Track 'A'"
        store.addTrack(name: "B")
        store.addTrack(name: "C")   // newest edit
        let h = store.undoHistory()
        #expect(h.undo == ["Add Track 'C'", "Add Track 'B'", "Add Track 'A'"])
        #expect(h.redo == [])
        #expect(h.canUndo && !h.canRedo)
        // undo[0] is exactly the label undo() reverses (mirrors undoLabel).
        #expect(h.undo.first == store.undoLabel)
    }

    @Test("empty history projects empty lists mirroring canUndo/canRedo")
    func emptyProjection() {
        let store = ProjectStore()
        let h = store.undoHistory()
        #expect(h.undo.isEmpty && h.redo.isEmpty)
        #expect(!h.canUndo && !h.canRedo)
    }

    @Test("coalesced same-key edits fold to ONE history entry")
    func coalescingFoldsToOne() {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        store.setMasterVolume(0.5)
        clock = clock.advanced(by: .milliseconds(200))
        store.setMasterVolume(0.7)
        clock = clock.advanced(by: .milliseconds(200))
        store.setMasterVolume(0.9)
        // Three rapid same-key scrubs = one undo step = one history label.
        #expect(store.undoHistory().undo == ["Set Master Volume"])
    }

    @Test("undo/redo move a label between the two projected stacks in order")
    func movementBetweenStacks() throws {
        let store = ProjectStore()
        store.addTrack(name: "A")
        try store.setTempo(140)   // newest
        #expect(store.undoHistory().undo == ["Set Tempo", "Add Track 'A'"])

        try store.undo()   // reverses "Set Tempo"
        var h = store.undoHistory()
        #expect(h.undo == ["Add Track 'A'"])
        #expect(h.redo == ["Set Tempo"])   // redo[0] = what redo() reapplies next

        try store.redo()   // reapplies "Set Tempo"
        h = store.undoHistory()
        #expect(h.undo == ["Set Tempo", "Add Track 'A'"])
        #expect(h.redo == [])
    }

    @Test("undo TWICE moves both labels to redo newest-first")
    func undoTwiceOrder() throws {
        let store = ProjectStore()
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        store.addTrack(name: "C")
        try store.undo()   // reverses C
        try store.undo()   // reverses B
        let h = store.undoHistory()
        #expect(h.undo == ["Add Track 'A'"])
        // redo[0] is the NEXT redo (B, the most recently undone); C sits below it.
        #expect(h.redo == ["Add Track 'B'", "Add Track 'C'"])
    }

    @Test("cap eviction is reflected in the projection (oldest labels drop)")
    func capEvictionProjected() {
        let store = ProjectStore()
        store.journal.cap = 2
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        store.addTrack(name: "C")   // evicts A
        #expect(store.undoHistory().undo == ["Add Track 'C'", "Add Track 'B'"])
    }

    @Test("a fresh edit clears the redo projection (history forks)")
    func freshEditClearsRedoProjection() throws {
        let store = ProjectStore()
        store.addTrack(name: "A")
        try store.setTempo(140)
        try store.undo()
        #expect(store.undoHistory().redo == ["Set Tempo"])
        store.setMasterVolume(0.5)   // forks — redo is discarded
        #expect(store.undoHistory().redo == [])
    }

    @Test("a load boundary (newProject) clears the projected history")
    func loadBoundaryClearsProjection() throws {
        let store = ProjectStore()
        store.addTrack(name: "A")
        try store.undo()
        #expect(store.undoHistory().canRedo)   // both stacks populated
        try store.newProject(discardChanges: true)
        let h = store.undoHistory()
        #expect(h.undo.isEmpty && h.redo.isEmpty)
    }
}
