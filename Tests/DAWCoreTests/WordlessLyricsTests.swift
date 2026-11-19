import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x7 part A: `WordlessLyrics`, singing without words (design 2026-10-06 §8.1). Pure tables, then the round
/// trip through the ONE derivation (`SingPlanner.assignment`): the generated text must sing every note of the clip it
/// was generated for, one line per breath phrase. Nonisolated.
@Suite("WordlessLyrics — ooh/aah/mm, per breath phrase or per note (p2-sing-x7)")
struct WordlessLyricsTests {

    @Test("the table: one held sound per phrase (k notes = the word + k-1 marks), or the sound once per note",
          arguments: [
            (WordlessLyrics.Sound.ooh, [4, 4], false, "ooh+++\nooh+++"),
            (.ooh, [4, 4], true, "ooh ooh ooh ooh\nooh ooh ooh ooh"),
            (.aah, [1], false, "aah"),
            (.aah, [3, 0, 2], true, "aah aah aah\naah aah"),
            (.mm, [2, 5], false, "mm+\nmm++++"),
            (.mm, [], false, ""),
            (.mm, [0], true, ""),
          ])
    func table(sound: WordlessLyrics.Sound, counts: [Int], perNote: Bool, expected: String) {
        #expect(WordlessLyrics.text(sound: sound, phraseNoteCounts: counts, perNote: perNote) == expected)
    }

    @Test("the three sounds are the wire's spellings")
    func sounds() {
        #expect(WordlessLyrics.Sound.allCases.map(\.rawValue) == ["ooh", "aah", "mm"])
    }

    /// A melody clip whose breath phrases hold `counts` notes (one-beat notes; a two-beat rest between phrases,
    /// far past the assigner's 0.125-beat breath threshold).
    private func clip(_ counts: [Int]) -> Clip {
        var notes: [MIDINote] = []
        var beat = 0.0
        for count in counts {
            for i in 0..<count {
                notes.append(MIDINote(pitch: 60 + (i % 5), startBeat: beat, lengthBeats: 1))
                beat += 1
            }
            beat += 2
        }
        return Clip(name: "Tune", startBeat: 0, lengthBeats: beat + 1, notes: notes)
    }

    @Test("round trip: each sound, both shapes, sings EVERY note, one line per phrase (the tokenizer's marks and the singable check measured, not assumed)",
          arguments: [[4, 4], [3, 1, 5], [1], [7]])
    func roundTrip(counts: [Int]) throws {
        let tune = clip(counts)
        #expect(WordlessLyrics.phraseNoteCounts(of: tune) == counts)
        for sound in WordlessLyrics.Sound.allCases {
            for perNote in [false, true] {
                let text = WordlessLyrics.text(for: tune, sound: sound, perNote: perNote)
                let tokens = LyricTokenizer.tokenize(text, language: nil)
                #expect(tokens.words.allSatisfy { $0.isSingable }, "\(sound) must pass the English check")
                #expect(tokens.lines.map { $0.reduce(0) { $0 + $1.markedNotes } } == counts, "\(sound) \(perNote)")
                var sung = tune
                sung.lyrics = ClipLyrics(text: text)
                let assignment = try SingPlanner.assignment(for: sung, tempoMap: TempoMap(constantBPM: 120))
                #expect(assignment.mode == .linePerPhrase)
                #expect(assignment.unsungNoteIDs.isEmpty)
                #expect(assignment.words.reduce(0) { $0 + $1.noteIDs.count } == counts.reduce(0, +))
                #expect(assignment.words.allSatisfy { $0.word.sung == sound.rawValue })
            }
        }
    }

    @Test("an audio clip or a clip with no notes has no phrases and gets no text")
    func noNotes() {
        let empty = Clip(name: "Empty", startBeat: 0, lengthBeats: 4, notes: [])
        #expect(WordlessLyrics.phraseNoteCounts(of: empty).isEmpty)
        #expect(WordlessLyrics.text(for: empty, sound: .ooh, perNote: false) == "")
    }
}
