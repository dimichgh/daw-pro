import Foundation
import Testing
@testable import DAWCore

/// m23-k4a store-level MIDI export: `exportMIDIFile` and `exportTrackMIDIFile`.
///
/// Everything the MAPPER decides is gated in `ProjectMIDIExportMapperTests`
/// against hand-built project values — headless, no store, no disk. What is left
/// for this suite is exactly the store's own business: the dry-run seam
/// (including the UNDO JOURNAL, which no snapshot comparison can see), the
/// destination policy, the refusals, and the bytes actually landing on disk.
@MainActor
@Suite("ProjectStore — MIDI file export (m23-k4a)")
struct ProjectStoreMIDIExportTests {

    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23k4a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store with one instrument track carrying one clip of on-grid notes.
    static func populatedStore() throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        let track = store.addTrack(name: "Lead", kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4)
        _ = try store.setClipNotes(clipID: clip.id, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, startBeat: 1, lengthBeats: 1),
            MIDINote(pitch: 67, startBeat: 2, lengthBeats: 2),
        ])
        return (store, track.id)
    }

    // MARK: - G7: the dry run is INERT

    /// **G7 —** a `performEdit` that mutates nothing STILL APPENDS A JOURNAL
    /// ENTRY, and a `project.snapshot` comparison cannot see that. `undoHistory()`
    /// is the seam that can — on the wire, `edit.history`. m23-k3 paid for this
    /// lesson once.
    ///
    /// Three claims in one leg, and the conjunction is the point: the report is
    /// identical, no file appears at the reported path, and the undo label list
    /// is UNCHANGED — not merely the same length.
    @Test("G7: dryRun writes nothing, journals nothing, and reports the same thing")
    func dryRunIsInert() throws {
        let (store, _) = try Self.populatedStore()
        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("song.mid").path

        let before = store.undoHistory()
        let dry = try store.exportMIDIFile(path: path, dryRun: true)
        let afterDry = store.undoHistory()

        #expect(dry.written == false)
        #expect(dry.path == path)
        #expect(FileManager.default.fileExists(atPath: path) == false)
        // IDENTICAL, not "the same count": a journal entry appended by a
        // zero-effect edit keeps the count of a DIFFERENT history equal only by
        // accident, and the label list is what makes the claim exact.
        #expect(afterDry.undo == before.undo)
        #expect(afterDry.redo == before.redo)

        let real = try store.exportMIDIFile(path: path)
        #expect(real.written == true)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(store.undoHistory().undo == before.undo)
        #expect(store.undoHistory().redo == before.redo)

        // The reports agree on everything except `written`. `byteCount` is
        // included in that agreement, which is STRONGER than the design's
        // "modulo written, path, byteCount": this implementation encodes on the
        // dry run too, so `dryRun: true` predicts the file size exactly.
        var normalized = dry
        normalized.written = true
        #expect(normalized == real)
        #expect(dry.byteCount == real.byteCount)
        #expect(dry.byteCount > 0)
    }

    @Test("export leaves the project itself untouched")
    func exportMutatesNothing() throws {
        let (store, _) = try Self.populatedStore()
        let dir = try Self.tempDirectory()
        let tracksBefore = store.tracks
        let transportBefore = store.transport
        _ = try store.exportMIDIFile(path: dir.appendingPathComponent("a.mid").path)
        #expect(store.tracks == tracksBefore)
        #expect(store.transport == transportBefore)
    }

    // MARK: - The bytes land, and come back

    @Test("a real export writes a file the shipped importer reads back")
    func roundTripThroughDisk() throws {
        let (store, _) = try Self.populatedStore()
        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("song.mid").path
        let report = try store.exportMIDIFile(path: path)

        #expect(report.written)
        #expect(report.tracksExported == 1)
        #expect(report.notesExported == 3)
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(onDisk.count == report.byteCount)

        let fresh = ProjectStore()
        let imported = try fresh.importMIDIFile(path: path)
        #expect(imported.tracksCreated == 1)
        #expect(imported.notesImported == 3)
        let notes = try #require(fresh.tracks.first?.clips.first?.notes)
        #expect(notes.map(\.pitch) == [60, 64, 67])
        #expect(notes.map(\.startBeat) == [0, 1, 2])
        #expect(notes.map(\.lengthBeats) == [1, 1, 2])
        // The clip's LENGTH survives too, because trailing silence is written
        // into `endTick` (m23-k3's R6 reads it back out of there).
        #expect(fresh.tracks.first?.clips.first?.lengthBeats == 4)
    }

    @Test("track.exportMIDI writes one part plus a conductor")
    func singleTrackExport() throws {
        let (store, trackID) = try Self.populatedStore()
        let other = store.addTrack(name: "Bass", kind: .instrument)
        let otherClip = try store.addMIDIClip(toTrack: other.id, atBeat: 0, lengthBeats: 4)
        _ = try store.setClipNotes(clipID: otherClip.id,
                                   notes: [MIDINote(pitch: 36, startBeat: 0, lengthBeats: 4)])

        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("lead.mid").path
        let report = try store.exportTrackMIDIFile(trackID: trackID, path: path)
        #expect(report.tracks.map(\.name) == ["Lead"])
        #expect(report.notesExported == 3)

        let decoded = try StandardMIDIFileReader.decode(
            contentsOf: URL(fileURLWithPath: path))
        #expect(decoded.tracks.count == 2)          // conductor + one part
        #expect(decoded.tracks[1].name == "Lead")
    }

    // MARK: - G13: skips and refusals

    /// **G13 —** the DRY-RUN half is the conjunction that matters: a leg testing
    /// only the refusal passes an implementation that ALSO refuses the dry run,
    /// which is the one call whose entire purpose is to find out.
    @Test("G13: a project with no instrument track refuses, but its dry run succeeds")
    func nothingToExport() throws {
        let store = ProjectStore()
        _ = store.addTrack(name: "Vox", kind: .audio)
        _ = store.addTrack(name: "Reverb", kind: .bus)
        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("empty.mid").path

        #expect(throws: MIDIExportError.self) {
            try store.exportMIDIFile(path: path)
        }
        #expect(FileManager.default.fileExists(atPath: path) == false)

        let dry = try store.exportMIDIFile(path: path, dryRun: true)
        #expect(dry.tracksExported == 0)
        #expect(dry.tracks.map(\.name) == ["Vox", "Reverb"])
        #expect(dry.tracks.allSatisfy { $0.exported == false })
        #expect(dry.tracks[0].skipReason?.contains("audio track") == true)
    }

    @Test("G13b: track.exportMIDI on an audio track refuses and names the kind")
    func trackExportRefusesNonInstrument() throws {
        let store = ProjectStore()
        let audio = store.addTrack(name: "Vox", kind: .audio)
        do {
            _ = try store.exportTrackMIDIFile(trackID: audio.id)
            Issue.record("expected notAnInstrumentTrack")
        } catch let error as MIDIExportError {
            guard case .notAnInstrumentTrack(let name, let kind) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(name == "Vox")
            #expect(kind == "audio")
            #expect(error.localizedDescription.contains("project.exportMIDI"))
        }
    }

    // MARK: - m23-m3b: the eligibility rule the track-header menu reads

    /// `Track.canExportMIDI` is the ONE home for "can this be written out as a
    /// `.mid`" — the track-header context menu offers the item from it, this
    /// store verb refuses on it, and `SMFProjectExporter.map` skips on it. Pinned
    /// over EVERY kind (not just the instrument case) so a rule that widened to
    /// `kind != .bus` reddens here rather than only at the menu.
    @Test("m23-m3b: canExportMIDI is true for instrument tracks and nothing else")
    func canExportMIDIPerKind() {
        #expect(Track(name: "Lead", kind: .instrument).canExportMIDI)
        #expect(Track(name: "Vox", kind: .audio).canExportMIDI == false)
        #expect(Track(name: "Reverb", kind: .bus).canExportMIDI == false)
        // Routing is irrelevant — a MIDI file has no notion of a mix bus, so the
        // rule must not accidentally pick up the Bounce-in-Place condition
        // (`kind == .bus || outputBusID == nil`) sitting beside it in the menu.
        var routed = Track(name: "Lead", kind: .instrument)
        routed.outputBusID = UUID()
        #expect(routed.canExportMIDI)
        var routedAudio = Track(name: "Vox", kind: .audio)
        routedAudio.outputBusID = UUID()
        #expect(routedAudio.canExportMIDI == false)
    }

    /// The store's refusal must stay wired to that property for BOTH ineligible
    /// kinds, and must leave NO file behind — the menu hides the item precisely
    /// because reaching this refusal from the UI would be a bug, so the refusal
    /// is the backstop, not the user-facing path.
    @Test("m23-m3b: the single-track verb refuses every kind canExportMIDI rejects")
    func refusalTracksThePredicate() throws {
        let store = ProjectStore()
        let dir = try Self.tempDirectory()
        for (kind, label) in [(TrackKind.audio, "audio"), (TrackKind.bus, "bus")] {
            let track = store.addTrack(name: "T-\(label)", kind: kind)
            #expect(track.canExportMIDI == false)
            let path = dir.appendingPathComponent("\(label).mid").path
            do {
                _ = try store.exportTrackMIDIFile(trackID: track.id, path: path)
                Issue.record("expected notAnInstrumentTrack for \(label)")
            } catch let error as MIDIExportError {
                guard case .notAnInstrumentTrack(let name, let reported) = error else {
                    Issue.record("wrong case for \(label): \(error)")
                    continue
                }
                #expect(name == "T-\(label)")
                #expect(reported == label)
            }
            // Absence, not just an error: a refusal that still wrote bytes would
            // pass a throws-only leg.
            #expect(FileManager.default.fileExists(atPath: path) == false)
        }
    }

    /// The bytes the menu item puts on disk parse as a Standard MIDI File by a
    /// reader that did not write them (k3's shipped `StandardMIDIFileReader`),
    /// magic word included — the surface's own verb, on the exact eligibility
    /// boundary the menu offers it at.
    @Test("m23-m3b: a single-track export lands bytes that read back as an SMF")
    func singleTrackExportBytesParse() throws {
        let (store, trackID) = try Self.populatedStore()
        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("Lead.mid").path
        let report = try store.exportTrackMIDIFile(trackID: trackID, path: path)
        #expect(report.written)

        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(onDisk.prefix(4) == Data("MThd".utf8))
        #expect(onDisk.count == report.byteCount)

        let decoded = try StandardMIDIFileReader.decode(contentsOf: URL(fileURLWithPath: path))
        #expect(decoded.tracks.count == 2)          // conductor + the one part
        #expect(decoded.tracks[1].name == "Lead")
        #expect(decoded.tracks[1].notes.count == report.notesExported)
    }

    @Test("G13c: an EMPTY instrument track still exports, as a named chunk")
    func emptyInstrumentTrackExports() throws {
        let store = ProjectStore()
        _ = store.addTrack(name: "Silent", kind: .instrument)
        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("silent.mid").path
        let report = try store.exportMIDIFile(path: path)
        #expect(report.tracksExported == 1)
        #expect(report.notesExported == 0)

        let decoded = try StandardMIDIFileReader.decode(
            contentsOf: URL(fileURLWithPath: path))
        #expect(decoded.tracks.count == 2)
        #expect(decoded.tracks[1].name == "Silent")
        #expect(decoded.tracks[1].notes.isEmpty)
    }

    @Test("an unknown track id is a trackNotFound, on both verbs")
    func unknownTrackID() throws {
        let (store, _) = try Self.populatedStore()
        let stranger = UUID()
        #expect(throws: ProjectError.self) {
            try store.exportMIDIFile(trackIDs: [stranger], dryRun: true)
        }
        #expect(throws: ProjectError.self) {
            try store.exportTrackMIDIFile(trackID: stranger, dryRun: true)
        }
    }

    // MARK: - Contract ranges

    @Test("division and format are contract-range checked, by field name")
    func contractRanges() throws {
        let (store, _) = try Self.populatedStore()
        for bad in [0, -1, 32768, 100_000] {
            #expect(throws: MIDIExportError.invalidTicksPerQuarterNote(bad)) {
                try store.exportMIDIFile(ticksPerQuarterNote: bad, dryRun: true)
            }
        }
        for bad in [2, -1, 3] {
            #expect(throws: MIDIExportError.invalidFormat(bad)) {
                try store.exportMIDIFile(format: bad, dryRun: true)
            }
        }
        // The legal edges pass.
        #expect(try store.exportMIDIFile(ticksPerQuarterNote: 1,
                                         dryRun: true).ticksPerQuarterNote == 1)
        #expect(try store.exportMIDIFile(ticksPerQuarterNote: 32767,
                                         dryRun: true).ticksPerQuarterNote == 32767)
        #expect(try store.exportMIDIFile(format: 0, dryRun: true).format == 0)
    }

    // MARK: - Destination policy

    @Test("the destination policy expands ~, appends .mid, and creates parents")
    func destinationPolicy() throws {
        let (store, _) = try Self.populatedStore()
        let dir = try Self.tempDirectory()

        // No extension -> .mid appended.
        let bare = dir.appendingPathComponent("song").path
        let appended = try store.exportMIDIFile(path: bare)
        #expect(appended.path == bare + ".mid")
        #expect(FileManager.default.fileExists(atPath: bare + ".mid"))

        // A .MIDI extension is already a MIDI extension, case-insensitively.
        let existing = dir.appendingPathComponent("song2.MIDI").path
        #expect(try store.exportMIDIFile(path: existing).path == existing)

        // Missing parent directories are created.
        let nested = dir.appendingPathComponent("a/b/c/deep.mid").path
        #expect(try store.exportMIDIFile(path: nested).written)
        #expect(FileManager.default.fileExists(atPath: nested))

        // Omitted path -> a unique file under the temp directory.
        let defaulted = try store.exportMIDIFile()
        #expect(defaulted.path.contains("DAWPro"))
        #expect(defaulted.path.hasSuffix(".mid"))
        #expect(FileManager.default.fileExists(atPath: defaulted.path))
    }

    @Test("an existing file is overwritten — the caller chose the path")
    func overwrites() throws {
        let (store, _) = try Self.populatedStore()
        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("song.mid").path
        try Data("not a midi file".utf8).write(to: URL(fileURLWithPath: path))
        let report = try store.exportMIDIFile(path: path)
        #expect(report.written)
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(onDisk.count == report.byteCount)
        #expect(onDisk.prefix(4) == Data("MThd".utf8))
    }

    @Test("a path that cannot be written surfaces writeFailed with the path in it")
    func writeFailure() throws {
        let (store, _) = try Self.populatedStore()
        // A directory that exists as a FILE cannot hold children.
        let dir = try Self.tempDirectory()
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        do {
            _ = try store.exportMIDIFile(path: blocker.appendingPathComponent("x.mid").path)
            Issue.record("expected writeFailed")
        } catch let error as MIDIExportError {
            guard case .writeFailed(let path, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(path.hasSuffix("x.mid"))
        }
    }

    // MARK: - Export is not blocked by the transport

    /// The deliberate asymmetry with m23-k3's D1″: import refuses while
    /// recording because it MUTATES and folds tempo adoption inside its own
    /// edit. Export mutates nothing, so there is no half-state to protect and no
    /// rule to explain.
    @Test("export works while the transport is recording")
    func exportDuringRecording() throws {
        let (store, _) = try Self.populatedStore()
        // `store.engine` is WEAK — bind the fake or `record()` fails with
        // engineUnavailable before the transport is ever busy (the
        // `ProjectStoreMIDIImportTests` recipe, verbatim).
        let engine = FakeTakeEngine()
        store.engine = engine
        try store.setTrackArm(id: store.tracks[0].id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)
        let dir = try Self.tempDirectory()
        let report = try store.exportMIDIFile(
            path: dir.appendingPathComponent("live.mid").path)
        #expect(report.written)
    }

    // MARK: - The whole-project shape

    @Test("a whole-project export names the project on the conductor chunk")
    func projectNameRidesTheConductor() throws {
        let (store, _) = try Self.populatedStore()
        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("named.mid").path
        _ = try store.exportMIDIFile(path: path)
        let decoded = try StandardMIDIFileReader.decode(
            contentsOf: URL(fileURLWithPath: path))
        #expect(decoded.tracks[0].name == store.projectName)
        #expect(decoded.tracks[0].notes.isEmpty)
    }

    /// The full circle a user actually performs: import a file, export it, and
    /// import the export. Uses the shipped k3 spine fixture.
    @Test("import -> export -> import preserves every note")
    func importExportImport() throws {
        let store = ProjectStore()
        let source = try ProjectStoreMIDIImportTests.stagedFixture("apple-type1")
        let first = try store.importMIDIFile(path: source.path, tempoPolicy: .adopt)
        #expect(first.notesImported == 8)

        let dir = try Self.tempDirectory()
        let path = dir.appendingPathComponent("again.mid").path
        let exported = try store.exportMIDIFile(path: path)
        #expect(exported.notesExported == 8)

        let round = ProjectStore()
        let second = try round.importMIDIFile(path: path, tempoPolicy: .adopt)
        #expect(second.notesImported == 8)
        #expect(second.tracksCreated == store.tracks.count)

        for (before, after) in zip(store.tracks, round.tracks) {
            let a = try #require(before.clips.first?.notes)
            let b = try #require(after.clips.first?.notes)
            #expect(a.map(\.pitch) == b.map(\.pitch))
            #expect(a.map(\.startBeat) == b.map(\.startBeat))
            #expect(a.map(\.lengthBeats) == b.map(\.lengthBeats))
            #expect(a.map(\.velocity) == b.map(\.velocity))
        }
        // The two tempo segments survive the trip. 120 is exact; the second is
        // 90.00009000009 BPM (666666 µs/qn), and `round(60e6/bpm)` returns
        // exactly 666666 — the one tempo in this chain for which every rounding
        // rule agrees, which is precisely why it is a VACUOUS gate for the
        // rounding rule and a fine one for the round trip.
        #expect(round.transport.tempoMap.segments.map(\.startBeat)
                == store.transport.tempoMap.segments.map(\.startBeat))
        #expect(round.transport.tempoMap.segments.map(\.bpm)
                == store.transport.tempoMap.segments.map(\.bpm))
    }
}
