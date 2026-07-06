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
        #expect(store.transport.countInBars == 0)
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
        store.removeTrack(id: track.id)
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
}
