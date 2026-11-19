import Foundation
import Testing
@testable import DAWCore

/// p2-sing-pr-words-f1: the piano roll's bar delete (`ProjectStore.deleteTimeRange`,
/// the roll's "−" and the wire's `clip.deleteTimeRange`) keeps the clip's words
/// the way the arrange's bar delete does (the 2026-10-05 ruling,
/// `ClipLyrics.distributeAfterDelete`): a word whose notes were ALL cut leaves
/// the text in the same edit, so the same undo step brings it back; a word that
/// keeps a note stays; text the singer cannot place is kept whole.
///
/// ⚠️ APPENDED to the existing `@MainActor` suite `MIDITimeRangeTests`
/// (`MIDITimeRangeTests.swift`, unmodified) as an extension: `ProjectStore` is
/// `@MainActor`, and the tree is at its `@MainActor` suite cap, so there is no
/// `@Suite` line here (the `ClipLyricsRebuildStoreTests` precedent). Helpers
/// carry a `rollWords` prefix so they never collide with the suite's own.
///
/// Lyrics are written straight into `store.tracks`, outside any undo step, the
/// way a reopened project arrives (the same precedent).
@MainActor
extension MIDITimeRangeTests {

    // MARK: - Fixtures

    /// A store with one instrument track holding one melody clip at beat 0.
    /// `notes` are `(start, length)` pairs at pitch 60.
    fileprivate static func rollWordsStore(notes: [(Double, Double)], length: Double, text: String?)
        throws -> (store: ProjectStore, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let added = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: length,
                                          notes: notes.map { MIDINote(pitch: 60, startBeat: $0.0, lengthBeats: $0.1) })
        if let text { store.tracks[0].clips[0].lyrics = ClipLyrics(text: text) }
        #expect(store.tracks[0].clips[0].id == added.id, "control: the fixture's one clip")
        return (store, store.tracks[0].clips[0])
    }

    /// One-beat notes at `onsets`, a rest between each, one word on each.
    fileprivate static func rollWordsStore(onsets: [Double], length: Double, text: String?)
        throws -> (store: ProjectStore, clip: Clip) {
        try rollWordsStore(notes: onsets.map { ($0, 1) }, length: length, text: text)
    }

    fileprivate static func rollWordsBytes(_ tracks: [Track]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tracks)
    }

    fileprivate static func rollWordsID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "0A000000-0000-0000-0000-%012d", n))!
    }

    fileprivate static func rollWordsJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// How many words the singer places on `clip` today, or nil when it refuses.
    fileprivate static func rollWordsPlaced(_ clip: Clip) -> Int? {
        (try? SingPlanner.assignment(for: clip, tempoMap: TempoMap(constantBPM: 120)))?.words.count
    }

    // MARK: - The rule

    @Test("roll bar delete (p2-sing-pr-words-f1): the words whose notes were ALL cut leave the text, and the rest are singable")
    func rollDeleteWordsRemovesEmptiedWords() throws {
        let (store, clip) = try Self.rollWordsStore(onsets: [0, 2, 4, 6, 8, 10], length: 12,
                                                    text: "one two three four five six")
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)   // "three", "four"
        #expect(updated.notes?.map(\.startBeat) == [0, 2, 4, 6], "control: the notes on beats 4 and 6 were cut")
        #expect(updated.lyrics == ClipLyrics(text: "one two five six"))
        #expect(store.tracks[0].clips[0].lyrics == updated.lyrics, "the store holds what the verb returned")
        #expect(Self.rollWordsPlaced(updated) == 4, "every word left has a note: the clip is singable")
        #expect(Self.rollWordsPlaced(clip) == 6, "control: the fixture was singable before the cut")
    }

    @Test("roll bar delete: a word that keeps a note stays (a + held word whose later note survives; a note crossing in from before)")
    func rollDeleteWordsKeepsAWordWithANoteLeft() throws {
        // "three +" sings beats 7 and 8. Cutting 4..<8 takes "two" (beat 4)
        // and the first note of "three", whose second note shifts to beat 4.
        let (held, heldClip) = try Self.rollWordsStore(onsets: [0, 4, 7, 8, 10], length: 12,
                                                       text: "one two three + four")
        let heldAfter = try held.deleteTimeRange(clipID: heldClip.id, startBeat: 4, lengthBeats: 4)
        #expect(heldAfter.notes?.count == 3, "control: three notes survive")
        #expect(heldAfter.lyrics == ClipLyrics(text: "one three + four"))

        // "two" sings [3, 5), which crosses into the cut 4..<8: its head stays
        // (same note id), so "two" stays. "three" (beat 5) goes.
        let (crossing, crossingClip) = try Self.rollWordsStore(notes: [(0, 1), (3, 2), (5, 1), (9, 1)], length: 12,
                                                               text: "one two three four")
        let crossingAfter = try crossing.deleteTimeRange(clipID: crossingClip.id, startBeat: 4, lengthBeats: 4)
        #expect(crossingAfter.notes?.map(\.startBeat) == [0, 3, 5], "control: the crossing note's head stayed")
        #expect(crossingAfter.lyrics == ClipLyrics(text: "one two four"))
    }

    @Test("roll bar delete: ONE undo restores the notes AND the words, byte for byte; redo removes them again")
    func rollDeleteWordsOneUndoRestoresNotesAndWords() throws {
        // Three two-note phrases, one line of words each; cutting 4..<8 takes the middle one.
        let (store, clip) = try Self.rollWordsStore(onsets: [0, 1, 4, 5, 8, 9], length: 12,
                                                    text: "one two\nthree four\nfive six")
        let before = try Self.rollWordsBytes(store.tracks)
        let history = store.undoHistory().undo.count
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 4, lengthBeats: 4)
        #expect(updated.lyrics == ClipLyrics(text: "one two\nfive six"), "one line break is kept between kept lines")
        #expect(store.undoHistory().undo.count == history + 1, "ONE undo step for the notes and the words")

        #expect(try store.undo() == "Delete Time Range")
        #expect(try Self.rollWordsBytes(store.tracks) == before, "undo brings back the notes, the length and the words")

        #expect(try store.redo() == "Delete Time Range")
        #expect(store.tracks[0].clips[0].lyrics == ClipLyrics(text: "one two\nfive six"))
        #expect(store.tracks[0].clips[0].notes?.count == 4)
    }

    @Test("roll bar delete: cutting every note leaves the clip with no words")
    func rollDeleteWordsAllNotesCutLeavesNoText() throws {
        let (store, clip) = try Self.rollWordsStore(onsets: [0, 2, 4, 6], length: 8, text: "one two three four")
        let updated = try store.deleteTimeRange(clipID: clip.id, startBeat: 0, lengthBeats: 8)
        #expect(updated.notes?.isEmpty == true, "control: every note was cut")
        #expect(updated.lyrics == nil)
        _ = try store.undo()
        #expect(store.tracks[0].clips[0].lyrics == ClipLyrics(text: "one two three four"))
    }

    // MARK: - Unchanged where the rule removes nothing

    /// Each case's result clip, encoded (sorted keys), captured by running
    /// `deleteTimeRange` on the tree BEFORE this fix (W10-PRWF slot A,
    /// 2026-10-12). The fix must not move a byte of them.
    fileprivate static let rollWordsGoldens: [String: String] = [
        "G1": #"{"id":"0A000000-0000-0000-0000-000000000090","isAIGenerated":false,"lengthBeats":12,"name":"No words","notes":[{"id":"0A000000-0000-0000-0000-000000000001","lengthBeats":2,"pitch":60,"startBeat":0,"velocity":90},{"id":"0A000000-0000-0000-0000-000000000003","lengthBeats":4,"pitch":64,"startBeat":2,"velocity":92},{"id":"0A000000-0000-0000-0000-000000000002","lengthBeats":1,"pitch":62,"startBeat":3,"velocity":91},{"id":"0A000000-0000-0000-0000-000000000005","lengthBeats":1,"pitch":67,"startBeat":4,"velocity":94},{"id":"0A000000-0000-0000-0000-000000000006","lengthBeats":2,"pitch":69,"startBeat":8,"velocity":95}],"startBeat":0}"#,
        "G2": #"{"id":"0A000000-0000-0000-0000-000000000091","isAIGenerated":false,"lengthBeats":11,"lyrics":{"text":"one two + three"},"name":"Held word","notes":[{"id":"0A000000-0000-0000-0000-000000000011","lengthBeats":1,"pitch":60,"startBeat":0,"velocity":100},{"id":"0A000000-0000-0000-0000-000000000012","lengthBeats":1,"pitch":62,"startBeat":4,"velocity":100},{"id":"0A000000-0000-0000-0000-000000000014","lengthBeats":1,"pitch":65,"startBeat":7,"velocity":100}],"startBeat":0}"#,
        "G3": #"{"id":"0A000000-0000-0000-0000-000000000092","isAIGenerated":false,"lengthBeats":8,"lyrics":{"text":"one two three four five six seven"},"name":"Too many words","notes":[{"id":"0A000000-0000-0000-0000-000000000021","lengthBeats":1,"pitch":60,"startBeat":0,"velocity":100},{"id":"0A000000-0000-0000-0000-000000000022","lengthBeats":1,"pitch":60,"startBeat":2,"velocity":100},{"id":"0A000000-0000-0000-0000-000000000025","lengthBeats":1,"pitch":60,"startBeat":4,"velocity":100},{"id":"0A000000-0000-0000-0000-000000000026","lengthBeats":1,"pitch":60,"startBeat":6,"velocity":100}],"startBeat":0}"#,
    ]

    fileprivate static func rollWordsGoldenCases() -> [(name: String, clip: Clip, start: Double, length: Double)] {
        let id = rollWordsID
        // G1: no words. Every crossing rule, cut 4..<8.
        let g1 = Clip(id: id(90), name: "No words", startBeat: 0, lengthBeats: 16, notes: [
            MIDINote(id: id(1), pitch: 60, velocity: 90, startBeat: 0, lengthBeats: 2),    // wholly before
            MIDINote(id: id(2), pitch: 62, velocity: 91, startBeat: 3, lengthBeats: 2),    // crosses in, ends inside
            MIDINote(id: id(3), pitch: 64, velocity: 92, startBeat: 2, lengthBeats: 8),    // spans the cut
            MIDINote(id: id(4), pitch: 65, velocity: 93, startBeat: 5, lengthBeats: 2),    // onset inside: cut
            MIDINote(id: id(5), pitch: 67, velocity: 94, startBeat: 8, lengthBeats: 1),    // at the cut's end: shifts
            MIDINote(id: id(6), pitch: 69, velocity: 95, startBeat: 12, lengthBeats: 2),   // after: shifts
        ])
        // G2: "two +" sings beats 4 and 5; cutting 5..<6 takes only its second note.
        let g2 = Clip(id: id(91), name: "Held word", startBeat: 0, lengthBeats: 12, notes: [
            MIDINote(id: id(11), pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(id: id(12), pitch: 62, startBeat: 4, lengthBeats: 1),
            MIDINote(id: id(13), pitch: 64, startBeat: 5, lengthBeats: 1),
            MIDINote(id: id(14), pitch: 65, startBeat: 8, lengthBeats: 1),
        ], lyrics: ClipLyrics(text: "one two + three"))
        // G3: seven words on six notes, which the singer refuses; cut 4..<8.
        let g3 = Clip(id: id(92), name: "Too many words", startBeat: 0, lengthBeats: 12,
                      notes: [0.0, 2, 4, 6, 8, 10].enumerated().map {
                          MIDINote(id: id(21 + $0.offset), pitch: 60, startBeat: $0.element, lengthBeats: 1)
                      },
                      lyrics: ClipLyrics(text: "one two three four five six seven"))
        return [("G1", g1, 4, 4), ("G2", g2, 5, 1), ("G3", g3, 4, 4)]
    }

    @Test("roll bar delete: byte-identical to the behaviour before the fix with no words, a word that keeps a note, and text the singer refuses")
    func rollDeleteWordsGoldensMatchTheOldBehaviour() throws {
        let cases = Self.rollWordsGoldenCases()
        #expect(cases[0].clip.lyrics == nil, "control: G1 has no words")
        let g2Words = try SingPlanner.assignment(for: cases[1].clip, tempoMap: TempoMap(constantBPM: 120)).words
        #expect(g2Words.map(\.noteIDs.count) == [1, 2, 1], "control: G2 places its words, and \"two\" holds two notes")
        #expect(Self.rollWordsPlaced(cases[2].clip) == nil, "control: G3's text is refused (more words than notes)")
        for golden in cases {
            let store = ProjectStore()
            _ = store.addTrack(kind: .instrument)
            store.tracks[0].clips.append(golden.clip)
            let result = try store.deleteTimeRange(clipID: golden.clip.id, startBeat: golden.start,
                                                   lengthBeats: golden.length)
            #expect(try Self.rollWordsJSON(result) == Self.rollWordsGoldens[golden.name], "\(golden.name) moved")
            #expect(result.lyrics == golden.clip.lyrics, "\(golden.name): the text is untouched")
        }
    }

    @Test("roll bar delete: a non-MIDI clip is refused and nothing changes, not even the undo history")
    func rollDeleteWordsNonMIDIClipUntouched() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let audioTrack = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: audioTrack.id)
        let before = try Self.rollWordsBytes(store.tracks)
        let history = store.undoHistory().undo.count
        var refused = false
        do {
            _ = try store.deleteTimeRange(clipID: audioClip.id, startBeat: 0, lengthBeats: 1)
        } catch let error as ProjectError {
            if case .notAMIDIClip = error { refused = true }
        }
        #expect(refused, "an audio clip is refused as not MIDI")
        #expect(try Self.rollWordsBytes(store.tracks) == before)
        #expect(store.undoHistory().undo.count == history)
    }
}
