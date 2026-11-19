import Foundation

/// Singing without words (p2-sing-x7, design `docs/design/2026-10-06-p2-sing-expansion.md` §8.1, "No words? Sing:
/// Ooh · Aah · Mm").
///
/// A pure generator: it writes LYRIC TEXT, nothing else. The text stays the one truth (base §3.1): the result is an
/// ordinary words-box text the user can read and edit, sung by the ordinary path (a word on k notes becomes k entries
/// carrying the word's phonemes, base §2.4, which is how a held vowel is already sung). Nothing new is stored.
///
/// Two shapes, both ONE LINE PER BREATH PHRASE, so the assigner pairs line i with phrase i (`linePerPhrase`):
/// - **one sound per line** (`perNote == false`): the sound held across the phrase with `+` marks, "ooh+++" for a
///   four-note phrase (one note for the word, one per `+`, `LyricWord.markedNotes`);
/// - **one per note** (`perNote == true`): the sound once per note, "ooh ooh ooh ooh".
///
/// The phrases are the assigner's own (`PhraseDetection.phrases` over `SingPlanner.melody`, at
/// `HumanizeLegato.defaultMaxGapBeats`, exactly as `LyricNoteAssigner.assign` groups them), so the generated text
/// always fits the clip it was generated for. The wire (`clip.setLyrics {wordless, wordlessPerNote?}`) and the
/// words box's buttons (x8) call this; neither builds the text another way.
public enum WordlessLyrics {

    /// The three sounds (design §8.1, §14 "No words? Sing: Ooh · Aah · Mm"). The raw value is the word written into
    /// the text and the wire's spelling.
    public enum Sound: String, CaseIterable, Sendable, Codable {
        case ooh, aah, mm
    }

    /// The text for a melody whose breath phrases hold `phraseNoteCounts` notes each, in order. A phrase of 0 notes
    /// writes no line. Empty when there are no notes.
    public static func text(sound: Sound, phraseNoteCounts: [Int], perNote: Bool) -> String {
        phraseNoteCounts.filter { $0 > 0 }.map { count in
            perNote
                ? Array(repeating: sound.rawValue, count: count).joined(separator: " ")
                : sound.rawValue + String(repeating: "+", count: count - 1)
        }.joined(separator: "\n")
    }

    /// How many notes each breath phrase of `clip` holds, as the assigner groups them: the melody it sings
    /// (`SingPlanner.melody`, one note at a time), cut into phrases by `PhraseDetection` at the assigner's threshold.
    /// Empty for an audio clip or a clip with no notes.
    public static func phraseNoteCounts(of clip: Clip) -> [Int] {
        let melody = MIDINote.canonicallyOrdered(SingPlanner.melody(of: clip).notes)
        return PhraseDetection.phrases(in: melody, maxGapBeats: HumanizeLegato.defaultMaxGapBeats)
            .map(\.noteIDs.count)
    }

    /// The text for `clip`'s melody: `text(sound:phraseNoteCounts:perNote:)` over its phrases.
    public static func text(for clip: Clip, sound: Sound, perNote: Bool) -> String {
        text(sound: sound, phraseNoteCounts: phraseNoteCounts(of: clip), perNote: perNote)
    }
}
