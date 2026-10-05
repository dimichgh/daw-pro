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

    public init(text: String) {
        self.text = text
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

    private enum CodingKeys: String, CodingKey { case text }

    /// An absent `text` decodes as "" (which `Clip.init` normalises to nil),
    /// so a damaged lyrics object can never stop a whole clip from loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
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
        /// Each word's first-note onset, in clip-relative beats and reading
        /// order; nil when the assigner refuses the text.
        public let onsets: [Double]?

        /// nil when the clip has no lyrics.
        public init?(clip: Clip, tempoMap: TempoMap) {
            guard let lyrics = clip.lyrics else { return nil }
            text = lyrics.text
            if let assignment = try? SingPlanner.assignment(for: clip, tempoMap: tempoMap),
               assignment.words.count == LyricTokenizer.wordStartOffsets(lyrics.text).count {
                onsets = assignment.words.map(\.startBeat)
            } else {
                onsets = nil
            }
        }

        /// The two halves' texts when the clip is cut at clip-relative beat
        /// `cut`: words starting before it go left, the rest right.
        public func split(atClipBeat cut: Double) -> (left: ClipLyrics?, right: ClipLyrics?) {
            guard let onsets else { return (ClipLyrics(text: text), nil) }
            let k = onsets.firstIndex { $0 >= cut } ?? onsets.count
            let (left, right) = LyricTokenizer.cut(text, beforeWord: k)
            return (ClipLyrics.normalized(ClipLyrics(text: left)), ClipLyrics.normalized(ClipLyrics(text: right)))
        }

        /// The text a comp member playing the clip-relative `window` of this
        /// clip carries: the words whose first note starts inside it.
        /// `isFirstWindow` marks the first member cut from this clip, which
        /// keeps the whole text when it cannot be placed.
        public func window(_ window: Range<Double>, isFirstWindow: Bool) -> ClipLyrics? {
            guard let onsets else { return isFirstWindow ? ClipLyrics(text: text) : nil }
            let first = onsets.firstIndex { $0 >= window.lowerBound } ?? onsets.count
            let end = onsets.firstIndex { $0 >= window.upperBound } ?? onsets.count
            guard first < end else { return nil }
            return ClipLyrics.normalized(ClipLyrics(text: LyricTokenizer.slice(text, words: first..<end)))
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
