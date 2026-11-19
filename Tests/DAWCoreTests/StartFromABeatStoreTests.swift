import DAWCore
import Foundation
import Testing

// m39-w4-10 UI — `ProjectStore.fillDrumPattern`, the store half of the step grid's
// "Start from a beat" menu: it fills the EMPTY clip the grid has open.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §8 (last bullet), §10.2 L2.
//
// Appended to the existing `@MainActor` suite `DrumKitStoreTests` (the store is
// main-actor; no new `@MainActor` suite: the `DrumPatternStoreTests` precedent).
//
// ⛔ THE CLAIMS, EACH PINNED ON ITS OWN:
//  - the same beat on the same kit writes the same notes as `clip.addDrumPattern`
//    (twin tracks, every beat, every kind of drum track, 1–3 bars), plus a
//    hand-typed golden so the twin check is not the only witness;
//  - ONE undo step that never folds into the note edit before it (the discriminating
//    order: an unkeyed clip with a note, the note clicked off, then the beat);
//  - a drum the kit lacks is left out, nothing plays in its place, and the result
//    line names it;
//  - only an empty clip on a drum track, in 4 beats to the bar, is filled.

extension DrumKitStoreTests {

    /// A note as the ear hears it: everything but the id (each write mints ids).
    private struct BeatNote: Equatable, CustomStringConvertible {
        let pitch: Int
        let velocity: Int
        let startBeat: Double
        let lengthBeats: Double
        var description: String { "\(pitch)@\(startBeat)v\(velocity)/\(lengthBeats)" }
    }

    private func beatNotes(_ clip: Clip?) -> [BeatNote] {
        (clip?.notes ?? []).map {
            BeatNote(pitch: $0.pitch, velocity: $0.velocity, startBeat: $0.startBeat, lengthBeats: $0.lengthBeats)
        }
    }

    private func beatMessage(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    private func beatClip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap(\.clips).first { $0.id == id }
    }

    /// A NEW drum machine (General MIDI keys), built straight into the track.
    private static var beatMachine: InstrumentDescriptor {
        InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams.newDrumMachineKit)
    }

    /// The four kinds of drum track, each built straight into a track (no file I/O).
    private static func beatKits() throws -> [(String, InstrumentDescriptor)] {
        var pads = DrumKitParams()
        pads.noteLayout = .pads
        let gm = GMProgramCatalog.standardDrumKit
        let sorted = try #require(DrumPatternStoreFixture.sortedKitTrack().instrument)
        return [
            ("new drum machine (gm)", beatMachine),
            ("pads drum machine", InstrumentDescriptor(kind: .drumSynth, drumKit: pads)),
            ("General MIDI kit", InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
                source: .generalMIDI, program: gm.program, bankMSB: gm.bankMSB))),
            ("sorted sampler kit (no open hat, no clap)", sorted),
        ]
    }

    // MARK: - The same notes as the store verb

    @Test("m39-w4-10 UI: Start from a beat writes exactly what clip.addDrumPattern writes, on a twin track, for every beat, kit and length")
    func startFromABeatMatchesTheStoreVerbOnATwinTrack() throws {
        var compared = 0
        for (label, instrument) in try Self.beatKits() {
            let verbTrack = Track(name: "Verb", kind: .instrument, instrument: instrument)
            let gridTrack = Track(name: "Grid", kind: .instrument, instrument: instrument)
            let store = ProjectStore(projectName: "W9-PATUI twin \(label)", tracks: [verbTrack, gridTrack])
            for pattern in DrumPatternLibrary.patterns {
                for bars in [1, 2, 3] {
                    let place = "\(label) / \(pattern.id) / \(bars) bar(s)"
                    let byVerb = try store.addDrumPattern(named: pattern.id, toTrack: verbTrack.id, bars: bars)
                    // The grid's twin: an EMPTY clip of the same length at the same beat.
                    let empty = try store.addMIDIClip(toTrack: gridTrack.id, atBeat: byVerb.clip.startBeat,
                                                      lengthBeats: byVerb.clip.lengthBeats)
                    #expect(empty.notes == [], "\(place)")
                    let byGrid = try store.fillDrumPattern(named: pattern.id, intoClip: empty.id)

                    #expect(!beatNotes(byGrid.clip).isEmpty, "\(place)")
                    #expect(beatNotes(byGrid.clip) == beatNotes(byVerb.clip), "\(place)")
                    #expect(beatNotes(beatClip(store, empty.id)) == beatNotes(byVerb.clip), "\(place): as stored")
                    #expect(byGrid.written == byVerb.written, "\(place)")
                    #expect(byGrid.leftOut == byVerb.leftOut, "\(place)")
                    #expect(byGrid.warnings == byVerb.warnings, "\(place)")
                    #expect(byGrid.bars == bars, "\(place)")
                    // The SAME clip is filled: its id, start and length do not move.
                    #expect(byGrid.clip.id == empty.id, "\(place)")
                    #expect(byGrid.clip.startBeat == empty.startBeat, "\(place)")
                    #expect(byGrid.clip.lengthBeats == empty.lengthBeats, "\(place)")
                    compared += 1
                }
            }
            #expect(store.tracks.first { $0.id == gridTrack.id }?.clips.count == 21, "\(label)")
        }
        #expect(compared == 4 * 7 * 3)
    }

    @Test("m39-w4-10 UI: Basic Rock fills an empty pads drum machine clip on ITS notes (hand-typed golden)")
    func startFromABeatGoldenOnAPadsDrumMachine() throws {
        var pads = DrumKitParams()
        pads.noteLayout = .pads
        let track = Track(name: "Old Drums", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .drumSynth, drumKit: pads))
        let store = ProjectStore(projectName: "W9-PATUI pads", tracks: [track])
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4)
        let filled = try store.fillDrumPattern(named: "Basic Rock", intoClip: clip.id)
        let notes = try #require(filled.clip.notes)
        func beats(_ pitch: Int) -> [Double] { notes.filter { $0.pitch == pitch }.map(\.startBeat) }
        // `pads`: kick 36, snare 37, closed hat 38 (on this layout 42 is the RIM).
        #expect(beats(36) == [0, 2])
        #expect(beats(37) == [1, 3])
        #expect(beats(38) == [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5])
        #expect(notes.count == 12)
        #expect(notes.allSatisfy { $0.velocity == 100 && $0.lengthBeats == 0.25 })
        #expect(filled.summary == "Added the Basic Rock beat: 12 hits on Kick, Snare and Closed Hat.")
        #expect(filled.warnings.isEmpty && filled.leftOut.isEmpty)
    }

    // MARK: - One undo step

    @Test("m39-w4-10 UI: Start from a beat is ONE undo step, and never folds into the note edit just before it")
    func startFromABeatIsOneUndoStepThatNeverFolds() throws {
        let track = Track(name: "Drums", kind: .instrument, instrument: Self.beatMachine)
        let store = ProjectStore(projectName: "W9-PATUI undo", tracks: [track])
        // The discriminating order, inside the journal's 800 ms window: a clip made WITH
        // a note (an unkeyed edit), that note clicked off (a `clip.notes:<id>` edit, the
        // step grid's commit), then the beat. A write that joined the click would make
        // the one ⌘Z bring the clicked-off note back.
        let kick = MIDINote(pitch: 36, startBeat: 0, lengthBeats: 0.25)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4, notes: [kick])
        _ = try store.setClipNotes(clipID: clip.id, notes: [])
        #expect(beatClip(store, clip.id)?.notes == [])
        let undoBefore = store.undoHistory().undo.count

        let filled = try store.fillDrumPattern(named: "basicRock", intoClip: clip.id)
        #expect(filled.clip.notes?.count == 12)
        #expect(store.undoHistory().undo.count == undoBefore + 1, "a NEW undo step, not folded into the click")
        #expect(store.undoLabel == "Add Beat 'Basic Rock'")

        _ = try store.undo()
        #expect(beatClip(store, clip.id)?.notes == [], "one undo empties the clip")
        #expect(store.tracks[0].clips.count == 1, "and keeps the clip")
        _ = try store.redo()
        #expect(beatNotes(beatClip(store, clip.id)) == beatNotes(filled.clip))
    }

    // MARK: - A drum the kit lacks

    @Test("m39-w4-10 UI: on a kit with no open hat, no open-hat note is written, nothing plays in its place, and the result names it")
    func startFromABeatLeavesAMissingDrumOut() throws {
        let track = DrumPatternStoreFixture.sortedKitTrack()
        let store = ProjectStore(projectName: "W9-PATUI P3", tracks: [track])
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4)
        let filled = try store.fillDrumPattern(named: "fourOnTheFloor", intoClip: clip.id)
        let notes = try #require(filled.clip.notes)
        // Only the four kicks, on the kit's kick pad: nothing on 46 (the General MIDI open
        // hat), and nothing on the closed-hat pad (42) where the open hats were.
        #expect(notes.map(\.pitch) == [36, 36, 36, 36])
        #expect(notes.map(\.startBeat) == [0, 1, 2, 3])
        #expect(!notes.contains { $0.pitch == DrumPatternStoreFixture.gmOpenHat })
        #expect(!notes.contains { $0.pitch == DrumPatternStoreFixture.gmClosedHat })
        #expect(filled.leftOut.map(\.role) == [.openHat, .clap])
        #expect(filled.leftOut.map(\.hits) == [4, 2])
        #expect(filled.written.map(\.role) == [.kick])
        #expect(filled.summary == "Added the Four on the Floor beat: 4 hits on Kick.")
        #expect(filled.warnings.contains { $0.contains("Open Hat") && $0.contains("4 Open Hat hits") })
        #expect(filled.warnings.contains { $0.contains("Clap") })
        #expect(filled.warnings.allSatisfy { $0.contains("Nothing else plays in their place") })
    }

    // MARK: - How many bars

    @Test("m39-w4-10 UI: the beat fills the clip's own length: repeated, cut at a bar line, or stopped at a clip end partway through a bar")
    func startFromABeatFillsTheClipsOwnLength() throws {
        let track = Track(name: "Drums", kind: .instrument, instrument: Self.beatMachine)
        let store = ProjectStore(projectName: "W9-PATUI length", tracks: [track])
        func beats(_ notes: [MIDINote], _ pitch: Int) -> [Double] {
            notes.filter { $0.pitch == pitch }.map(\.startBeat)
        }

        // 6 beats = one and a half bars of Basic Rock, every hit inside the clip.
        let six = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 6)
        let half = try store.fillDrumPattern(named: "basicRock", intoClip: six.id)
        let halfNotes = try #require(half.clip.notes)
        #expect(beats(halfNotes, 36) == [0, 2, 4])
        #expect(beats(halfNotes, 38) == [1, 3, 5])
        #expect(beats(halfNotes, 42) == [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5])
        #expect(halfNotes.allSatisfy { $0.startBeat < 6 }, "no hit at or past the clip's end")
        #expect(half.bars == 2)
        #expect(half.written.map(\.hits) == [3, 3, 12], "only the hits inside the clip are counted")
        #expect(half.clip.lengthBeats == 6, "the clip keeps its length")

        // A two-bar beat in a one-bar clip is cut at the bar line: Boom Bap's bar 1 only.
        let one = try store.addMIDIClip(toTrack: track.id, atBeat: 8, lengthBeats: 4)
        let cut = try #require(try store.fillDrumPattern(named: "boomBap", intoClip: one.id).clip.notes)
        #expect(beats(cut, 36) == [0, 1.75, 2.5])
        #expect(beats(cut, 38) == [1, 2.25, 3])
        #expect(beats(cut, 42) == [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5])
        #expect(cut.count == 14)

        // A clip that starts partway through a bar: the beat starts on the clip's first
        // beat, with the same warning `addDrumPattern` gives.
        let offBar = try store.addMIDIClip(toTrack: track.id, atBeat: 14, lengthBeats: 4)
        let shifted = try store.fillDrumPattern(named: "halfTime", intoClip: offBar.id)
        let warning = try #require(shifted.warnings.first)
        #expect(warning.contains("partway through bar 4"))
        #expect(warning.contains("beats 12 and 16"))
        #expect(shifted.warnings.count == 1)
        #expect(shifted.clip.startBeat == 14)
    }

    // MARK: - What it refuses

    @Test("m39-w4-10 UI: a clip with notes, a non-drum track, a song not in 4/4 and an unknown beat are refused, and nothing changes")
    func startFromABeatRefusesAndChangesNothing() throws {
        let drums = Track(name: "Drums", kind: .instrument, instrument: Self.beatMachine)
        let bass = Track(name: "Bass", kind: .instrument, instrument: InstrumentDescriptor(kind: .polySynth))
        let store = ProjectStore(projectName: "W9-PATUI refusals", tracks: [drums, bass])
        let snare = MIDINote(pitch: 38, startBeat: 1, lengthBeats: 0.25)
        let busy = try store.addMIDIClip(toTrack: drums.id, name: "Verse Beat", atBeat: 0, lengthBeats: 4,
                                         notes: [snare])
        let synthClip = try store.addMIDIClip(toTrack: bass.id, atBeat: 0, lengthBeats: 4)
        let empty = try store.addMIDIClip(toTrack: drums.id, atBeat: 4, lengthBeats: 8)
        let undoBefore = store.undoHistory().undo.count
        let tracksBefore = store.tracks

        let busyText = try #require(beatMessage { _ = try store.fillDrumPattern(named: "basicRock", intoClip: busy.id) })
        #expect(busyText.contains("'Verse Beat' already has 1 note"))
        #expect(busyText.contains("Nothing was added"))

        let synthText = try #require(beatMessage {
            _ = try store.fillDrumPattern(named: "basicRock", intoClip: synthClip.id)
        })
        #expect(synthText.contains("'Bass' plays the Poly Synth, not drums"))

        let unknown = try #require(beatMessage { _ = try store.fillDrumPattern(named: "polka", intoClip: empty.id) })
        #expect(unknown.contains("no drum beat called 'polka'"))

        #expect(beatMessage { _ = try store.fillDrumPattern(named: "basicRock", intoClip: UUID()) } != nil)
        #expect(store.tracks == tracksBefore, "no refusal changed anything")
        #expect(store.undoHistory().undo.count == undoBefore, "no refusal journaled an undo step")

        // The song turns 3/4 at beat 8, inside the empty clip (beats 4–12).
        let meter = try MeterMap(changes: [
            MeterMap.Change(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            MeterMap.Change(startBeat: 8, beatsPerBar: 3, beatUnit: 4),
        ])
        try store.setTempoMap(store.transport.tempoMap, meterMap: meter)
        let meterText = try #require(beatMessage {
            _ = try store.fillDrumPattern(named: "basicRock", intoClip: empty.id)
        })
        #expect(meterText.contains("3/4"))
        #expect(meterText.contains("4 beats to a bar"))
        #expect(meterText.contains("beat 8"))
        #expect(beatClip(store, empty.id)?.notes == [])
    }
}
