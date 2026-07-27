import Foundation
import Testing
@testable import DAWCore

/// m23-k3 store-level MIDI import: `importMIDIFile` and `importMIDIIntoClip`.
///
/// Everything the MAPPER decides is gated in `StandardMIDIFileMapperTests`
/// against hand-built IR values — headless, no store, no undo journal. What is
/// left for this suite is exactly the store's own business and nothing else:
/// atomicity, the dry-run seam, the engine reschedule, and the refusals. Split
/// that way on purpose: a hazard that needs a `@MainActor` store and an undo
/// journal just to assert that a note landed on beat 3 gets under-tested.
///
/// Reuses `FakeEngine` (CoreTests.swift, same target) — the only seam that can
/// observe the `tracksDidChange` requirement at all.
@MainActor
@Suite("ProjectStore — MIDI file import (m23-k3)")
struct ProjectStoreMIDIImportTests {

    // MARK: - Fixtures on disk

    /// The import commands take a PATH, so the bundled fixture bytes are staged
    /// into a temp file. Its NAME matters (the extension check runs before the
    /// existence check), so it keeps the `.mid` suffix.
    static func stagedFixture(_ name: String,
                              extension ext: String = "mid") throws -> URL {
        let data = try StandardMIDIFileMapperTests.fixtureData(name)
        return try staged(data, name: "\(name).\(ext)")
    }

    static func staged(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23k3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A format-1 file whose ONLY chunk is a conductor track: a tempo event and
    /// an end-of-track marker, no channel events anywhere. Hand-authored bytes
    /// rather than a fixture because the claim it carries is store-level
    /// (§3.3b's refusal), not a parsing one.
    static func conductorOnlyFile() throws -> URL {
        let bytes: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,  // MThd, length 6
            0x00, 0x01, 0x00, 0x01, 0x01, 0xE0,              // format 1, 1 track, 480 tpqn
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x0B,  // MTrk, length 11
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,        // set tempo 500000 (120 BPM)
            0x00, 0xFF, 0x2F, 0x00,                          // end of track
        ]
        return try staged(Data(bytes), name: "conductor-only.mid")
    }

    static func makeStore() -> (ProjectStore, FakeEngine) {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine
        return (store, engine)
    }

    // MARK: - G5 — the conflict policy, in both directions, on the same file

    @Test("G5 — adopt on an empty project installs the file's 2-segment tempo override")
    func adoptInstallsTempoOverride() throws {
        let (store, _) = Self.makeStore()
        let url = try Self.stagedFixture("apple-type1")
        #expect(store.transport.tempoBPM == 120)

        let report = try store.importMIDIFile(path: url.path, tempoPolicy: .adopt)
        #expect(report.resolvedTempoPolicy == "adopt")
        #expect(report.tempoSegmentsAdopted == 2)
        #expect(store.tracks.count == 2)
        let override = try #require(store.transport.tempoMapOverride)
        #expect(override.segments.count == 2)
        #expect(override.segments[1].bpm == 60_000_000.0 / 666_666.0)
        #expect(store.transport.tempoBPM == 120)
        // H4c for meter: this file carries no `FF 58` at all, so the project's
        // own time signature must be untouched.
        #expect(store.transport.meterMapOverride == nil)
        #expect(report.meterChangesAdopted == 0)
    }

    @Test("G5 — ignore leaves the tempo where it was, on the same file")
    func ignoreLeavesTempoAlone() throws {
        let (store, _) = Self.makeStore()
        try store.setTempo(91)
        let url = try Self.stagedFixture("apple-type1")

        let report = try store.importMIDIFile(path: url.path, tempoPolicy: .ignore)
        #expect(report.resolvedTempoPolicy == "ignore")
        #expect(report.tempoSegmentsAdopted == 0)
        #expect(store.transport.tempoBPM == 91)
        #expect(store.transport.tempoMapOverride == nil)
        // The notes are on the SAME beats they were under `adopt` — the §0
        // spine: a MIDI file's beats come from its ticks, not from its tempo.
        let notes = try #require(store.tracks[0].clips[0].notes)
        #expect(notes.map(\.startBeat) == [0.0, 1.0, 2.0, 3.0])
    }

    @Test("G5 — auto adopts into an empty project and ignores into one with clips")
    func autoResolvesOffTheProjectPredicate() throws {
        let url = try Self.stagedFixture("apple-type1")

        let (empty, _) = Self.makeStore()
        #expect(try empty.importMIDIFile(path: url.path).resolvedTempoPolicy == "adopt")

        let (populated, _) = Self.makeStore()
        let track = populated.addTrack(kind: .instrument)
        _ = try populated.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4, notes: [])
        try populated.setTempo(91)
        let report = try populated.importMIDIFile(path: url.path)
        #expect(report.resolvedTempoPolicy == "ignore")
        #expect(populated.transport.tempoBPM == 91)

        // An empty TRACK is not a clip: the predicate is
        // `tracks.contains { !$0.clips.isEmpty }`, verbatim from
        // importGeneration, so a bare track still counts as empty enough.
        let (bareTrack, _) = Self.makeStore()
        _ = bareTrack.addTrack(kind: .instrument)
        #expect(try bareTrack.importMIDIFile(path: url.path).resolvedTempoPolicy == "adopt")
    }

    // MARK: - G6 — atomicity

    /// The `importGeneration` invariant. A two-`performEdit` implementation
    /// passes every other leg in this suite and fails only here.
    @Test("G6 — ONE undo removes every created track AND restores the previous tempo")
    func oneUndoRestoresTempoAndTracks() throws {
        let (store, _) = Self.makeStore()
        try store.setTempo(91)
        let url = try Self.stagedFixture("apple-type1")

        try store.importMIDIFile(path: url.path, tempoPolicy: .adopt)
        #expect(store.tracks.count == 2)
        #expect(store.transport.tempoMapOverride?.segments.count == 2)
        #expect(store.undoLabel == "Import MIDI File")

        try store.undo()
        #expect(store.tracks.isEmpty)
        #expect(store.transport.tempoBPM == 91)
        #expect(store.transport.tempoMapOverride == nil)
    }

    /// The engine seam. Both notes and controller lanes ride the `ClipKey` that
    /// drives schedule rebuilds, so an import that skips this is SILENT until
    /// some unrelated edit happens to trigger a reschedule — a bug no purely
    /// model-level assertion catches.
    @Test("the import reschedules the engine, and a dry run does not")
    func importNotifiesTheEngine() throws {
        let (store, engine) = Self.makeStore()
        let url = try Self.stagedFixture("apple-type1")

        engine.clearCalls()
        try store.importMIDIFile(path: url.path, dryRun: true)
        #expect(engine.calls.isEmpty)

        try store.importMIDIFile(path: url.path)
        #expect(engine.calls.contains(.tracksDidChange(count: 2)))
    }

    // MARK: - G7 — the dry run

    /// The report identity is the easy half. The UNDO JOURNAL is the half that
    /// catches the real bug — a `performEdit` that runs on a dry run, mutates
    /// nothing, and quietly appends a history entry. A `project.snapshot`
    /// comparison cannot observe that at all; `undoHistory()` can.
    @Test("G7 — a dry run matches the real report modulo ids and leaves the journal untouched")
    func dryRunChangesNothing() throws {
        let (store, _) = Self.makeStore()
        try store.setTempo(91)
        let track = store.addTrack(kind: .instrument)
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4, notes: [])
        let url = try Self.stagedFixture("apple-type1")

        let historyBefore = store.undoHistory().undo
        let tracksBefore = store.tracks
        let transportBefore = store.transport

        let dry = try store.importMIDIFile(path: url.path, tempoPolicy: .adopt, dryRun: true)
        #expect(store.tracks == tracksBefore)
        #expect(store.transport == transportBefore)
        #expect(store.undoHistory().undo == historyBefore)

        // Nothing was created, so nothing is named.
        #expect(dry.parts.allSatisfy { $0.trackID == nil && $0.clipID == nil })
        #expect(dry.tracksCreated == 2)

        let real = try store.importMIDIFile(path: url.path, tempoPolicy: .adopt)
        #expect(real.parts.contains { $0.trackID != nil })
        // Identical modulo the ids: strip them and the two reports are equal.
        var stripped = real
        for index in stripped.parts.indices {
            stripped.parts[index].trackID = nil
            stripped.parts[index].clipID = nil
        }
        #expect(stripped == dry)
        #expect(store.undoHistory().undo.first == "Import MIDI File")
    }

    // MARK: - G13 — the zero-effect refusal

    /// §3.3b, and the CONJUNCTION is the whole rule: a leg that only tested the
    /// refusal would pass an implementation that also refused the legitimate
    /// "import a conductor track to pick up its tempo map" workflow.
    @Test("G13 — a conductor-only file refuses under ignore and SUCCEEDS under adopt")
    func conductorOnlyFileRefusesOnlyWhenNothingWouldHappen() throws {
        let url = try Self.conductorOnlyFile()

        let (ignoring, _) = Self.makeStore()
        #expect(throws: MIDIImportError.self) {
            try ignoring.importMIDIFile(path: url.path, tempoPolicy: .ignore)
        }
        #expect(ignoring.tracks.isEmpty)
        #expect(ignoring.undoHistory().undo.isEmpty)

        let (adopting, _) = Self.makeStore()
        try adopting.setTempo(91)
        let report = try adopting.importMIDIFile(path: url.path, tempoPolicy: .adopt)
        #expect(report.tracksCreated == 0)
        #expect(report.tempoSegmentsAdopted == 1)
        #expect(adopting.transport.tempoBPM == 120)
    }

    /// A dry run NEVER refuses on this ground — the whole point of a dry run is
    /// to find out. (`importSampleLibrary` draws the same line at the same
    /// place: its `dryRun` returns before its `noPlayableZones` refusal.)
    @Test("G13 — a dry run of the same file reports instead of refusing")
    func dryRunNeverRefusesOnEmptiness() throws {
        let (store, _) = Self.makeStore()
        let url = try Self.conductorOnlyFile()
        let report = try store.importMIDIFile(path: url.path, tempoPolicy: .ignore, dryRun: true)
        #expect(report.tracksCreated == 0)
        #expect(report.wouldChangeNothing)
        #expect(report.parts.count == 1)
        #expect(report.parts[0].skipReason == "no notes or controller data")
    }

    // MARK: - The error surface (§4.3)

    /// D1″ — refused while recording, under EVERY policy, before any file work.
    /// `setTempoMap` already refuses while recording and this import folds tempo
    /// adoption inside its own edit (bypassing that guard); without the up-front
    /// check the behaviour would silently differ by policy.
    @Test("D1″ — importing while recording is refused with transportBusy")
    func recordingRefusesImport() throws {
        // `store.engine` is WEAK — bind the fake or `record()` fails with
        // engineUnavailable before the transport is ever busy. `FakeTakeEngine`
        // (MIDIRecordingStoreTests.swift, same target) rather than `FakeEngine`,
        // because only it accepts a MIDI-capturing take.
        let store = ProjectStore()
        let engine = FakeTakeEngine()
        store.engine = engine
        let track = store.addTrack(kind: .instrument)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)
        let url = try Self.stagedFixture("apple-type1")

        #expect(throws: ProjectError.self) {
            try store.importMIDIFile(path: url.path, tempoPolicy: .ignore)
        }
        #expect(throws: ProjectError.self) {
            try store.importMIDIFile(path: url.path, dryRun: true)
        }
        withExtendedLifetime(engine) {}
    }

    /// Extension FIRST, existence second — the shipped importer's order, which
    /// makes a non-existent `.txt` say "not a MIDI file" rather than "no file
    /// there". The two messages send a user to different places.
    @Test("a wrong extension says 'not a MIDI file' even when the file does not exist")
    func extensionIsCheckedBeforeExistence() throws {
        let (store, _) = Self.makeStore()
        #expect(throws: MIDIImportError.notAMIDIFile(fileName: "nope.txt")) {
            try store.importMIDIFile(path: "/tmp/definitely-absent-m23k3/nope.txt")
        }
        #expect(throws: MIDIImportError.fileNotFound(path: "/tmp/definitely-absent-m23k3/x.mid")) {
            try store.importMIDIFile(path: "/tmp/definitely-absent-m23k3/x.mid")
        }
    }

    /// k1's decode errors are already teaching-grade, so they surface VERBATIM
    /// rather than being re-wrapped — and nothing is mutated on the way out.
    @Test("an SMF decode error surfaces verbatim with nothing mutated")
    func decodeErrorsSurfaceVerbatim() throws {
        let (store, _) = Self.makeStore()
        let url = try Self.stagedFixture("malformed-bad-magic")
        #expect(throws: SMFDecodeError.missingHeaderChunk(foundTag: "MThX")) {
            try store.importMIDIFile(path: url.path)
        }
        #expect(store.tracks.isEmpty)
        #expect(store.undoHistory().undo.isEmpty)
    }

    @Test("D1′ — adopt at a non-zero beat refuses at the store boundary too")
    func adoptAtNonZeroBeatRefusesThroughTheStore() throws {
        let (store, _) = Self.makeStore()
        let url = try Self.stagedFixture("apple-type1")
        #expect(throws: MIDIImportError.tempoAdoptionRequiresBeatZero(atBeat: 4)) {
            try store.importMIDIFile(path: url.path, atBeat: 4, tempoPolicy: .adopt)
        }
        #expect(store.tracks.isEmpty)
    }

    // MARK: - clip.importMIDI

    @Test("clip import replaces notes and lanes wholesale and reschedules the engine")
    func clipImportReplacesContent() throws {
        let (store, engine) = Self.makeStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(
            toTrack: track.id, atBeat: 8, lengthBeats: 16,
            notes: [MIDINote(pitch: 36, startBeat: 0, lengthBeats: 4)])
        _ = try store.setControllerLane(clipID: clip.id, type: .cc(controller: 1),
                                        points: [MIDIControllerPoint(beat: 0, value: 5)])
        let url = try Self.stagedFixture("apple-type1")

        engine.clearCalls()
        let report = try store.importMIDIIntoClip(clipID: clip.id, path: url.path)
        let updated = store.tracks[0].clips[0]
        #expect(updated.notes?.map(\.pitch) == [60, 62, 64, 66])
        #expect(updated.notes?.map(\.startBeat) == [0.0, 1.0, 2.0, 3.0])
        // The mod-wheel lane the clip HAD is gone — the replace is wholesale,
        // exactly like clip.setNotes.
        #expect(updated.controllerLanes.map(\.type) == [.cc(controller: 11)])
        // Neither the clip's position nor its length moved.
        #expect(updated.startBeat == 8)
        #expect(updated.lengthBeats == 16)
        #expect(engine.calls.contains(.tracksDidChange(count: 1)))
        // The report names the clip that RECEIVED the content, not a throwaway
        // track the mapper built to carry it.
        let part = try #require(report.parts.first { $0.imported })
        #expect(part.clipID == clip.id)
        #expect(part.trackID == track.id)
        // ...and neither does the COUNT. The mapper has one shape for building
        // content — it plans a Track carrying a Clip — so this verb necessarily
        // produces one throwaway PlannedTrack whose Track is discarded. The
        // report must count what the caller GOT, and the caller got no new
        // track: the project still has exactly the one it started with.
        #expect(report.tracksCreated == 0,
                "a clip import created no track — reporting the mapper's scaffolding as a result is a false claim in the one field the user reads")
        #expect(store.tracks.count == 1)
        // The other adoption counters were already 0 here, and stay the control
        // that says this assertion is about tracksCreated specifically.
        #expect(report.tempoSegmentsAdopted == 0)
        #expect(report.meterChangesAdopted == 0)
    }

    /// The default part rule: notes beat controllers, lowest index wins. On
    /// `apple-type1.mid` that is part 1 (part 0 is the conductor).
    @Test("clip import defaults to the lowest-indexed part with notes")
    func clipImportDefaultPart() throws {
        let (store, _) = Self.makeStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 8, notes: [])
        let url = try Self.stagedFixture("apple-type1")

        try store.importMIDIIntoClip(clipID: clip.id, path: url.path)
        #expect(store.tracks[0].clips[0].notes?.map(\.pitch) == [60, 62, 64, 66])

        // …and an explicit part picks the other one.
        try store.importMIDIIntoClip(clipID: clip.id, path: url.path, part: 2)
        #expect(store.tracks[0].clips[0].notes?.map(\.pitch) == [48, 50, 52, 54])
    }

    /// The clip import NEVER touches the project grid — that is
    /// `project.importMIDI`'s job — and NEVER resizes the clip. Content past the
    /// end is imported and REPORTED so the caller can compose with
    /// `clip.fitToContent` rather than have an import silently trim a
    /// neighbouring clip through the overlap apparatus.
    @Test("clip import leaves the tempo alone and reports content past the clip end")
    func clipImportNeverMovesTheGridOrResizes() throws {
        let (store, _) = Self.makeStore()
        try store.setTempo(91)
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 2, notes: [])
        let url = try Self.stagedFixture("apple-type1")

        let report = try store.importMIDIIntoClip(clipID: clip.id, path: url.path)
        #expect(store.transport.tempoBPM == 91)
        #expect(store.transport.tempoMapOverride == nil)
        #expect(store.tracks[0].clips[0].lengthBeats == 2)
        // Notes at beats 2 and 3 sit past a 2-beat clip.
        #expect(report.notesPastClipEnd == 2)
        #expect(report.tempoSegmentsAdopted == 0)
        #expect(report.degradations.contains { $0.contains("fitToContent") })
    }

    /// The clip-relative `atBeat` shifts the CONTENT inside the clip — it is not
    /// a timeline beat, and it must not move the clip.
    @Test("clip import's atBeat offsets the content inside the clip")
    func clipImportOffsetsContent() throws {
        let (store, _) = Self.makeStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 4, lengthBeats: 16, notes: [])
        let url = try Self.stagedFixture("apple-type1")

        try store.importMIDIIntoClip(clipID: clip.id, path: url.path, atBeat: 2)
        #expect(store.tracks[0].clips[0].startBeat == 4)
        #expect(store.tracks[0].clips[0].notes?.map(\.startBeat) == [2.0, 3.0, 4.0, 5.0])
    }

    @Test("clip import refuses an audio clip, an unknown clip, and an out-of-range part")
    func clipImportGuards() throws {
        let (store, _) = Self.makeStore()
        let audioTrack = store.addTrack(kind: .audio)
        let audioClip = Clip(name: "wav", startBeat: 0, lengthBeats: 4,
                             audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        store.tracks[0].clips = [audioClip]
        _ = audioTrack
        let url = try Self.stagedFixture("apple-type1")

        #expect(throws: ProjectError.self) {
            try store.importMIDIIntoClip(clipID: audioClip.id, path: url.path)
        }
        #expect(throws: ProjectError.self) {
            try store.importMIDIIntoClip(clipID: UUID(), path: url.path)
        }

        let midiTrack = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: midiTrack.id, atBeat: 0,
                                         lengthBeats: 4, notes: [])
        #expect(throws: MIDIImportError.partIndexOutOfRange(index: 5, partCount: 3)) {
            try store.importMIDIIntoClip(clipID: clip.id, path: url.path, part: 5)
        }
        // Selecting the conductor part would CLEAR the clip; an import says what
        // it found instead. `clip.setNotes` is the command for clearing.
        #expect(throws: MIDIImportError.self) {
            try store.importMIDIIntoClip(clipID: clip.id, path: url.path, part: 0)
        }
    }

    @Test("clip import undoes in one step and leaves the previous content intact")
    func clipImportIsOneUndoStep() throws {
        let (store, _) = Self.makeStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(
            toTrack: track.id, atBeat: 0, lengthBeats: 8,
            notes: [MIDINote(pitch: 36, startBeat: 0, lengthBeats: 1)])
        let url = try Self.stagedFixture("apple-type1")

        try store.importMIDIIntoClip(clipID: clip.id, path: url.path)
        #expect(store.undoLabel == "Import MIDI into Clip")
        try store.undo()
        #expect(store.tracks[0].clips[0].notes?.map(\.pitch) == [36])
    }
}
