import Foundation

/// The words typed onto a MIDI clip, to be sung on its notes (p2-sing-d1,
/// design `docs/design/2026-09-27-p2-sing-integration.md` §3.1).
///
/// ## Only the text is stored
///
/// Which word sings which note is DERIVED every time, by `LyricNoteAssigner`,
/// from this text, the clip's current notes and the tempo map. It is never
/// stored, so a note edit can never leave a stale word-to-note record behind
/// (design §8 F16; this tree's characteristic failure is a stored record that
/// disagrees with the thing it describes). Markup (`+`, hyphen parts) lives
/// inside the text (§3.2), so there is exactly one source of truth.
///
/// ## Not render material
///
/// Nothing the engine plays reads lyrics. `Clip.init` also drops them from any
/// clip that is not MIDI, and the only clips the engine renders (the stretch
/// cache, `Clip.rendersThroughStretchCache`) are audio clips, so no render key
/// or render signature can ever see them.
///
/// ## Persistence
///
/// `Clip`'s own Codable carries this under the `lyrics` key, written only when
/// the clip has lyrics, so a clip without lyrics encodes byte-identically to a
/// pre-lyrics build. The project FILE is written through the `ClipDocument`
/// mirror in `ProjectDocument.swift`, a second hand-maintained field list,
/// and it carries `lyrics` too (p2-sing-d1b): its init, encode and decode, and
/// BOTH `ClipDocument`→`Clip` reconstructions (`ProjectDocument.runtimeState`
/// and `TakeGroupDocument.takeGroup`). `ClipLyricsPersistenceTests` pins them.
///
/// ## When a clip is rebuilt (p2-sing-d1b)
///
/// Every edit that rebuilds a clip carries its text, by one of two rules:
///
/// - **One clip in, one clip out** (trim, the overlap trim, duplicate, paste):
///   the text is kept exactly. It is the user's text; the words are laid on
///   whatever notes remain the next time they are derived, and more words
///   than notes is a refusal with a sentence at sing time, not a loss.
/// - **One clip in, several out** (split, the straddling clip of
///   `arrange.insertBars` / `arrange.deleteBars`, comp members): the words go
///   with the notes they start on (`WordPlacement`), so no word is sung twice.
///
/// `ClipLyricsRebuildTests` and the store tests in `ProjectStoreClipEditTests`
/// pin each site.
///
/// ## Language (p2-sing-x3)
///
/// `language` says which language the words are sung in: nil is English
/// (`LyricLanguage`). It is written only when the clip has one, so every
/// English clip encodes exactly as before languages existed
/// (`ClipLyricsPersistenceTests.languageAbsentIsByteIdentical`). Every rebuild
/// that cuts a clip's text keeps the language on both pieces
/// (`WordPlacement`, `distributeAfterDelete`); the rebuilds that copy the
/// whole `lyrics` value carry it with the text.
///
/// TODO(p2-sing-x7): the wire's `clip.setLyrics` takes an optional `language`
/// (design §6.9) and stores `ClipLyrics(text:language:)`; `clip.getLyrics`
/// replies with `language` only when the clip has one. Refuse an unsupported
/// code with `LyricLanguage.isSupported` (`lyricsLanguageUnsupported`).
///
/// TODO(p2-sing-e): nothing sets lyrics yet. That item adds the store setter,
/// the control commands `clip.setLyrics` / `clip.getLyrics`
/// (`Sources/DAWControl/Commands.swift`) and the MCP tools `clip_set_lyrics` /
/// `clip_get_lyrics` (design §6 rows 12-13). The setter must refuse text
/// over `maxTextLength` (`lyricsTooLong`) and a non-MIDI clip
/// (`lyricsNeedMIDIClip`), and should journal through `performEdit` so a
/// lyrics edit can be undone.
public struct ClipLyrics: Codable, Sendable, Equatable {

    /// The text exactly as typed: punctuation, line breaks and markup kept.
    public var text: String

    /// The language the words are sung in (p2-sing-x3, design
    /// `docs/design/2026-10-06-p2-sing-expansion.md` §6.3): nil is English,
    /// `"zh"` Chinese (Mandarin), `"yue"` Chinese (Cantonese). Any other code
    /// is kept as given and REFUSED at sing time, never sung as English.
    /// `"en"` is stored as nil, so English has one spelling (`LyricLanguage.stored`).
    public var language: String?

    public init(text: String) {
        self.text = text
    }

    /// Lyrics sung in `language` (nil or `"en"`: English).
    ///
    /// A SEPARATE init, not a defaulted parameter on the old one: the old
    /// init's symbol must stay, because `AIServicesTests` reaches DAWCore only
    /// through `AIServices` and SwiftPM does not recompile it when DAWCore
    /// changes (measured by W8-X3, 2026-10-06: its stale objects failed to
    /// link against a defaulted-parameter init).
    public init(text: String, language: String?) {
        self.text = text
        self.language = LyricLanguage.stored(language)
    }

    /// The same lyrics with `text` in place of this text: the language is
    /// kept. What a write that changes only the words should store, so an
    /// edit to a Chinese clip's text can never turn it back into English.
    public func withText(_ text: String) -> ClipLyrics {
        ClipLyrics(text: text, language: language)
    }

    /// The longest text the wire accepts (design §6, `lyricsTooLong`),
    /// counted in `Character`s, what a reader sees as one letter. The model
    /// does not truncate: refusing is the wire's job, and this is its number.
    public static let maxTextLength = 4_000

    /// The one "no lyrics" state. Text that is empty, or only spaces and line
    /// breaks, has no words, so it normalises to nil, exactly as `Clip.init`
    /// normalises an empty pitch-edit set: otherwise "no lyrics" would have two
    /// spellings (nil and `{"text": ""}`) that round-trip into each other.
    public static func normalized(_ lyrics: ClipLyrics?) -> ClipLyrics? {
        guard let lyrics else { return nil }
        return lyrics.text.allSatisfy(\.isWhitespace) ? nil : lyrics
    }

    private enum CodingKeys: String, CodingKey { case text, language }

    /// An absent `text` decodes as "" (which `Clip.init` normalises to nil),
    /// so a damaged lyrics object can never stop a whole clip from loading.
    /// An absent (or null) `language` is English, as every clip saved before
    /// languages existed is; `"en"` is English too. A `language` that is not
    /// text (a damaged file) is kept as `""`, a code no language has: the
    /// clip still loads, and singing it is refused rather than sung as English.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        do {
            self.language = LyricLanguage.stored(try c.decodeIfPresent(String.self, forKey: .language))
        } catch {
            self.language = ""
        }
    }

    /// `language` is written only when the clip has one, so English lyrics
    /// encode byte for byte as before languages existed (design §9 S1).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(language, forKey: .language)
    }
}

// MARK: - Cutting the text when a clip is cut (p2-sing-d1b)

extension ClipLyrics {

    /// Where each word of a clip's text starts, for cutting the text when the
    /// clip is cut in pieces.
    ///
    /// ## The rule: the words go with the notes they start on
    ///
    /// Each word's first note comes from the DERIVED assignment,
    /// `SingPlanner.assignment(for:tempoMap:)`, the same one the singer uses.
    /// A piece of the clip keeps the words whose first note starts inside it.
    /// That is the rule `ProjectStore.splitClip` already applies to the
    /// notes themselves (a note starting before the cut stays left), so after
    /// a split each half's words are laid on each half's notes exactly as they
    /// were before.
    ///
    /// The text is cut between words with `LyricTokenizer.cut`: line breaks,
    /// punctuation and `+` marks stay with the words they follow, so the user's
    /// typing survives verbatim on both sides.
    ///
    /// Text the assigner refuses (more words than notes, a word that is not
    /// English, markup that does not fit) cannot be placed word by word. Then
    /// the FIRST piece keeps all of it and the others get none: nothing typed
    /// is ever lost, and nothing is sung twice.
    ///
    /// Undoing the edit restores the clip, and with it the text, exactly: the
    /// store's undo snapshot holds the whole clip.
    public struct WordPlacement: Sendable, Equatable {
        /// The clip's text, as typed.
        public let text: String
        /// The clip's language (p2-sing-x3): it decides where the words are
        /// (one per Chinese character in a Chinese clip), and both pieces of a
        /// cut keep it.
        public let language: String?
        /// Each word's first-note onset, in clip-relative beats and reading
        /// order; nil when the assigner refuses the text.
        public let onsets: [Double]?

        /// nil when the clip has no lyrics.
        public init?(clip: Clip, tempoMap: TempoMap) {
            guard let lyrics = clip.lyrics else { return nil }
            text = lyrics.text
            language = lyrics.language
            if let assignment = try? SingPlanner.assignment(for: clip, tempoMap: tempoMap),
               assignment.words.count == LyricTokenizer.wordStartOffsets(lyrics.text, language: lyrics.language).count {
                onsets = assignment.words.map(\.startBeat)
            } else {
                onsets = nil
            }
        }

        /// The two halves' texts when the clip is cut at clip-relative beat
        /// `cut`: words starting before it go left, the rest right.
        public func split(atClipBeat cut: Double) -> (left: ClipLyrics?, right: ClipLyrics?) {
            guard let onsets else { return (ClipLyrics(text: text, language: language), nil) }
            let k = onsets.firstIndex { $0 >= cut } ?? onsets.count
            let (left, right) = LyricTokenizer.cut(text, beforeWord: k, language: language)
            return (ClipLyrics.normalized(ClipLyrics(text: left, language: language)),
                    ClipLyrics.normalized(ClipLyrics(text: right, language: language)))
        }

        /// The text a comp member playing the clip-relative `window` of this
        /// clip carries: the words whose first note starts inside it.
        /// `isFirstWindow` marks the first member cut from this clip, which
        /// keeps the whole text when it cannot be placed.
        public func window(_ window: Range<Double>, isFirstWindow: Bool) -> ClipLyrics? {
            guard let onsets else { return isFirstWindow ? ClipLyrics(text: text, language: language) : nil }
            let first = onsets.firstIndex { $0 >= window.lowerBound } ?? onsets.count
            let end = onsets.firstIndex { $0 >= window.upperBound } ?? onsets.count
            guard first < end else { return nil }
            return ClipLyrics.normalized(ClipLyrics(text: LyricTokenizer.slice(text, words: first..<end, language: language),
                                                    language: language))
        }
    }

    /// Hands `pieces` — what one clip became after a cut at clip-relative beat
    /// `cut` of `source` — their share of `source`'s text. Two pieces are a
    /// real split and are given `WordPlacement.split`'s halves; one piece is
    /// the only survivor and keeps the whole text (it came out of a trim or a
    /// duplicate, which already carried it). Used by the store's bar-insert and
    /// bar-delete geometry, whose straddling clip is a split in disguise.
    public static func distribute(_ pieces: [Clip], cutFrom source: Clip, atClipBeat cut: Double,
                                  tempoMap: TempoMap) -> [Clip] {
        guard pieces.count == 2, let placement = WordPlacement(clip: source, tempoMap: tempoMap) else {
            return pieces
        }
        let (left, right) = placement.split(atClipBeat: cut)
        var out = pieces
        out[0].lyrics = left
        out[1].lyrics = right
        return out
    }
}


// MARK: - Bars deleted through a clip (p2-sing-e, ruled 2026-10-05)

extension ClipLyrics {

    /// Hands `pieces` — what one clip became after `arrange.deleteBars`
    /// removed the clip-relative beats from `deleteStart` on — their share of
    /// `source`'s text.
    ///
    /// ## The rule (the orchestrator's ruling on W7-SD2's open question, 2026-10-05)
    ///
    /// **A word whose notes were ALL deleted is removed from the text**, in the
    /// same edit, so the same undo step brings it back. A word that keeps at
    /// least one note stays. The words left are then shared by the split rule
    /// (`WordPlacement.split` at the delete's start: a word goes with the piece
    /// its first note starts in), so a word whose first note was deleted but
    /// which still holds a later note goes with the tail. This replaces the
    /// earlier "the deleted words ride with the tail", which left the tail
    /// unsingable (more words than notes) until the user edited the text. It
    /// applies to a lone survivor too (only the head, or only the tail, is
    /// left): there, too, a word with no note left is removed.
    ///
    /// "Its notes" are the notes the ONE derivation gives it
    /// (`SingPlanner.assignment(for:tempoMap:)`); a note survives when a piece
    /// still holds a note with its id (the bar-delete geometry keeps note ids).
    ///
    /// Cutting the text: each run of removed words takes its own characters
    /// and everything up to the next word that stays (its punctuation, its `+`
    /// holds). When the run crossed a line break and words stay on both sides
    /// of it, ONE line break is kept, so the words left keep their lines and
    /// still line up with the melody's breath phrases (rule 1). At the very end
    /// of the text, what was left before the removed words loses its trailing
    /// whitespace; at the very start, nothing of the run is kept.
    ///
    /// Unchanged from the split rule: text the assigner refuses (so it cannot
    /// be placed word by word) is shared exactly as `distribute` shares it, and
    /// nothing is removed from it; nothing typed is lost. A delete that removes
    /// no whole word is exactly `distribute`.
    ///
    /// Known limit: a word that loses SOME of its notes keeps its `+` holds,
    /// so its markup may ask for more notes than are left; the sing-time
    /// refusal then says so in words (the same as any note edit).
    public static func distributeAfterDelete(_ pieces: [Clip], cutFrom source: Clip, atClipBeat deleteStart: Double,
                                             tempoMap: TempoMap) -> [Clip] {
        guard !pieces.isEmpty, let lyrics = source.lyrics else { return pieces }
        let language = lyrics.language
        let offsets = LyricTokenizer.wordStartOffsets(lyrics.text, language: language)
        guard let assignment = try? SingPlanner.assignment(for: source, tempoMap: tempoMap),
              assignment.words.count == offsets.count else {
            return distribute(pieces, cutFrom: source, atClipBeat: deleteStart, tempoMap: tempoMap)
        }
        let surviving = Set(pieces.flatMap { $0.notes ?? [] }.map(\.id))
        let keeps = assignment.words.map { word in word.noteIDs.contains { surviving.contains($0) } }
        guard keeps.contains(false) else {
            return distribute(pieces, cutFrom: source, atClipBeat: deleteStart, tempoMap: tempoMap)
        }
        let text = removingWords(lyrics.text, offsets: offsets, keeps: keeps)
        let onsets = zip(assignment.words, keeps).filter { $0.1 }.map { $0.0.startBeat }
        guard LyricTokenizer.wordStartOffsets(text, language: language).count == onsets.count else {
            // The text left does not read back as the words kept (it should
            // always): fall back to the split rule, which loses nothing.
            return distribute(pieces, cutFrom: source, atClipBeat: deleteStart, tempoMap: tempoMap)
        }
        var out = pieces
        if pieces.count == 2 {
            let k = onsets.firstIndex { $0 >= deleteStart } ?? onsets.count
            let (left, right) = LyricTokenizer.cut(text, beforeWord: k, language: language)
            out[0].lyrics = ClipLyrics.normalized(ClipLyrics(text: left, language: language))
            out[1].lyrics = ClipLyrics.normalized(ClipLyrics(text: right, language: language))
        } else {
            for i in out.indices { out[i].lyrics = ClipLyrics.normalized(ClipLyrics(text: text, language: language)) }
        }
        return out
    }

    /// `text` without the words whose `keeps` entry is false (see
    /// `distributeAfterDelete` for the rule). `offsets` are
    /// `LyricTokenizer.wordStartOffsets(text, language:)` in the clip's language.
    static func removingWords(_ text: String, offsets: [Int], keeps: [Bool]) -> String {
        guard keeps.count == offsets.count else { return text }
        let chars = Array(text)
        var out: [Character] = []
        var position = 0
        var i = 0
        while i < offsets.count {
            guard !keeps[i] else { i += 1; continue }
            var j = i
            while j < offsets.count, !keeps[j] { j += 1 }
            let start = offsets[i]
            let end = j < offsets.count ? offsets[j] : chars.count
            out.append(contentsOf: chars[position..<start])
            if j == offsets.count {
                // Nothing stays after the run: the text ends with the last word kept.
                while let last = out.last, last.isWhitespace { out.removeLast() }
            } else if i > 0, chars[start..<end].contains(where: { $0.isNewline }) {
                // Words stay on both sides of a line break: keep ONE, never a blank line.
                while let last = out.last, last.isWhitespace, !last.isNewline { out.removeLast() }
                if out.last?.isNewline != true { out.append("\n") }
            }
            position = end
            i = j
        }
        out.append(contentsOf: chars[position...])
        return String(out)
    }
}
