import Foundation
import Testing
@testable import DAWCore

// Tune to Melody, M2 (W7-TTM2): §3.2 "beats to vocal seconds", the PURE half of the store's
// melody resolution (`MelodyTuning.notes(of:under:tempoMap:)`). Every expected second below is
// derived by hand in the test's comment from the formula
//     t = vocal.startOffsetSeconds + tempoMap.seconds(from: vocal.startBeat, to: beat) / stretchRatio
// so a test that passes proves the arithmetic, not that two spellings of it agree.
//
// Deliberately NOT `@MainActor`: nothing here touches the store (the census in
// `MainActorOccupancySiteTests` counts suites).
@Suite("Tune to Melody M2 — beats to vocal source seconds (§3.2)")
struct PitchMelodyStoreResolveTests {
    static let tolerance = 1e-12

    static func vocal(startBeat: Double, lengthBeats: Double = 8, offset: Double,
                      ratio: Double = 1) -> Clip {
        Clip(name: "Verse take", startBeat: startBeat, lengthBeats: lengthBeats,
             audioFileURL: URL(fileURLWithPath: "/tmp/w7-ttm2-vocal.wav"),
             startOffsetSeconds: offset, stretchRatio: ratio)
    }

    static func melody(startBeat: Double, lengthBeats: Double = 8,
                       _ notes: [MIDINote]) -> Clip {
        Clip(name: "Lead", startBeat: startBeat, lengthBeats: lengthBeats, notes: notes)
    }

    static let at120 = TempoMap(constantBPM: 120)

    @Test("R1 ratio 1: a note at clip beat 1.5 of a clip at beat 1 lands at 0.75 to 1.25 vocal seconds")
    func ratioOne() throws {
        // 120 bpm = 0.5 s a beat. The note sounds at timeline beats 2.5 to 3.5; the vocal starts
        // at beat 2 and plays its file from 0.5 s, so t = 0.5 + 0.5·0.5 = 0.75 and
        // 0.5 + 1.5·0.5 = 1.25. Window: 0.5 to 0.5 + 8·0.5 = 4.5.
        let vocal = Self.vocal(startBeat: 2, offset: 0.5)
        let note = MIDINote(pitch: 60, startBeat: 1.5, lengthBeats: 1)
        let notes = MelodyTuning.notes(of: [Self.melody(startBeat: 1, [note])], under: vocal,
                                       tempoMap: Self.at120)
        let only = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(abs(only.note.startSeconds - 0.75) < Self.tolerance)
        #expect(abs(only.note.endSeconds - 1.25) < Self.tolerance)
        #expect(only.note.midi == 60)
        let window = MelodyTuning.vocalWindow(of: vocal, tempoMap: Self.at120)
        #expect(abs(window.start - 0.5) < Self.tolerance)
        #expect(abs(window.end - 4.5) < Self.tolerance)
    }

    @Test("R2 ratio 1.25: the same note lands at 0.7 to 1.1 vocal seconds (the timeline span divided by the ratio)")
    func ratioOnePointTwoFive() throws {
        // A ratio of 1.25 plays the file 1.25× slower, so a timeline second is 1/1.25 = 0.8 of a
        // source second: t = 0.5 + 0.25/1.25 = 0.7 and 0.5 + 0.75/1.25 = 1.1.
        // Window: 0.5 to 0.5 + 4/1.25 = 3.7.
        let vocal = Self.vocal(startBeat: 2, offset: 0.5, ratio: 1.25)
        let note = MIDINote(pitch: 60, startBeat: 1.5, lengthBeats: 1)
        let notes = MelodyTuning.notes(of: [Self.melody(startBeat: 1, [note])], under: vocal,
                                       tempoMap: Self.at120)
        let only = try #require(notes.first)
        #expect(abs(only.note.startSeconds - 0.7) < Self.tolerance)
        #expect(abs(only.note.endSeconds - 1.1) < Self.tolerance)
        let window = MelodyTuning.vocalWindow(of: vocal, tempoMap: Self.at120)
        #expect(abs(window.end - 3.7) < Self.tolerance)
    }

    @Test("R3 a tempo change inside the note: 120 bpm to beat 4, then 60 bpm, puts beats 3 to 6 at 0.5 to 3.0 s")
    func acrossATempoChange() throws {
        // Vocal at beat 2, offset 0, ratio 1. Beat 3 is one 120-bpm beat after it: 0.5 s.
        // Beat 6 is two 120-bpm beats (1.0 s) to beat 4, then two 60-bpm beats (2.0 s): 3.0 s.
        // A single 120-bpm formula would say 2.0 s.
        let map = try TempoMap(segments: [TempoMap.Segment(startBeat: 0, bpm: 120),
                                          TempoMap.Segment(startBeat: 4, bpm: 60)])
        let vocal = Self.vocal(startBeat: 2, offset: 0)
        let note = MIDINote(pitch: 64, startBeat: 3, lengthBeats: 3)
        let notes = MelodyTuning.notes(of: [Self.melody(startBeat: 0, [note])], under: vocal,
                                       tempoMap: map)
        let only = try #require(notes.first)
        #expect(abs(only.note.startSeconds - 0.5) < Self.tolerance)
        #expect(abs(only.note.endSeconds - 3.0) < Self.tolerance)
    }

    @Test("R4 a note is clipped to its clip: past lengthBeats it does not sound, and a note starting there is dropped")
    func clippedToItsClip() throws {
        // Clip at beat 0, 2 beats long. A note at beats 1-5 sounds only to beat 2: 0.5 to 1.0 s.
        // A note at clip beat 2.5 starts after the clip ends: dropped.
        let vocal = Self.vocal(startBeat: 0, offset: 0)
        let long = MIDINote(pitch: 62, startBeat: 1, lengthBeats: 4)
        let after = MIDINote(pitch: 65, startBeat: 2.5, lengthBeats: 1)
        let notes = MelodyTuning.notes(of: [Self.melody(startBeat: 0, lengthBeats: 2, [long, after])],
                                       under: vocal, tempoMap: Self.at120)
        #expect(notes.count == 1)
        let only = try #require(notes.first)
        #expect(only.note.midi == 62)
        #expect(abs(only.note.startSeconds - 0.5) < Self.tolerance)
        #expect(abs(only.note.endSeconds - 1.0) < Self.tolerance)
    }

    @Test("R5 only notes that overlap the vocal are kept, and a note straddling its start keeps its true start")
    func onlyNotesUnderTheVocal() throws {
        // Vocal at beat 2 for 8 beats, offset 0.5: window 0.5 to 4.5 s, timeline beats 2 to 10.
        // before: beats 0-1, wholly before -> dropped. after: beats 11-12 -> dropped.
        // straddle: beats 1.5-2.5 -> t = 0.5 + (−0.5)·0.5 = 0.25 to 0.75: kept, start 0.25.
        // abutting: beats 1-2, ends exactly where the vocal starts -> dropped (no overlap).
        let vocal = Self.vocal(startBeat: 2, offset: 0.5)
        let before = MIDINote(pitch: 50, startBeat: 0, lengthBeats: 1)
        let abutting = MIDINote(pitch: 51, startBeat: 1, lengthBeats: 1)
        let straddle = MIDINote(pitch: 52, startBeat: 1.5, lengthBeats: 1)
        let after = MIDINote(pitch: 53, startBeat: 11, lengthBeats: 1)
        let notes = MelodyTuning.notes(
            of: [Self.melody(startBeat: 0, lengthBeats: 16, [before, abutting, straddle, after])],
            under: vocal, tempoMap: Self.at120)
        #expect(notes.map(\.note.midi) == [52])
        let only = try #require(notes.first)
        #expect(abs(only.note.startSeconds - 0.25) < Self.tolerance)
        #expect(abs(only.note.endSeconds - 0.75) < Self.tolerance)
    }

    @Test("R6 every kept note names its MIDI note: clip id, note id, pitch, clip-relative start; sorted by time then pitch")
    func refsNameTheMIDINotes() throws {
        let vocal = Self.vocal(startBeat: 0, offset: 0)
        let late = MIDINote(pitch: 60, startBeat: 2, lengthBeats: 1)
        let chordLow = MIDINote(pitch: 55, startBeat: 0.5, lengthBeats: 1)
        let chordHigh = MIDINote(pitch: 67, startBeat: 0.5, lengthBeats: 1)
        let first = Self.melody(startBeat: 0, [late, chordHigh])
        let second = Self.melody(startBeat: 0, [chordLow])
        let notes = MelodyTuning.notes(of: [first, second], under: vocal, tempoMap: Self.at120)
        #expect(notes.map(\.note.midi) == [55, 67, 60])
        #expect(notes.map(\.ref.noteId) == [chordLow.id, chordHigh.id, late.id])
        #expect(notes.map(\.ref.clipId) == [second.id, first.id, first.id])
        #expect(notes.map(\.ref.startBeat) == [0.5, 0.5, 2])
        #expect(notes.map(\.ref.pitch) == [55, 67, 60])
    }
}
