import Foundation

/// What typing a word onto one note did, or (for a dry run) would do
/// (p2-sing-x1, design `docs/design/2026-10-06-p2-sing-expansion.md` §3.4:
/// the base `clip.setLyrics` shape). Typing a whole line across notes
/// (`setNoteWords`, p2-sing-pr-words phase 2) answers in the same shape.
public struct LyricNoteWordResult: Equatable, Sendable {
    public var clipID: UUID
    /// The clip's whole text after the edit (what the words box shows).
    public var text: String
    /// True when the project holds `text` after this call; false for a dry
    /// run, which changes nothing.
    public var stored: Bool
    /// False when the edit changed nothing (`+` on a note that is already
    /// held, the same word typed again): the text is returned unchanged, no
    /// undo step is recorded.
    public var changed: Bool
    /// Which word sings which note, derived from `text`
    /// (`SingPlanner.assignment(for:tempoMap:)`, the one derivation). Its
    /// `warnings` are the wire's `warnings`.
    public var assignment: LyricAssignment

    public init(clipID: UUID, text: String, stored: Bool, changed: Bool, assignment: LyricAssignment) {
        self.clipID = clipID
        self.text = text
        self.stored = stored
        self.changed = changed
        self.assignment = assignment
    }
}

/// Lyrics on a clip, written by the store (p2-sing-x1).
///
/// `setClipLyrics` is THE one write path for a clip's text. Typing a word on a
/// note (`setNoteWord`) goes through it, and so must the wire's
/// `clip.setLyrics` (base design §6 row 12, item p2-sing-e) with its own undo
/// label, so the text box and the note field can never disagree about what
/// a lyrics write checks or how it is undone.
///
/// TODO(p2-sing-x7): the wire. `clip.setNoteWord` (MCP tool
/// `clip_set_note_word`, design §3.4) in `Sources/DAWControl/Commands.swift`
/// and `mcp-server/src/server.ts` maps `clipId`, `noteId`, `word`, `dryRun?`
/// straight onto `setNoteWord(clipId:noteId:word:dryRun:)` and replies with
/// `LyricNoteWordResult` (`text`, `stored`, `assignment.words` as
/// `{text: typed, noteIds, startBeat, endBeat, held}`, `warnings` as
/// sentences), with `rejectUnknownKeys`. Not added here: the round's wire
/// count is held (W8 common rules).
/// TODO(p2-sing-e): `clip.setLyrics` calls `setClipLyrics(clipId:text:undoLabel:)`.
/// TODO(p2-sing-x7): its optional `language` param calls
/// `setClipLyrics(clipId:text:language:undoLabel:)`, which refuses an
/// unsupported code (`lyricsLanguageUnsupported`) before anything changes.
/// TODO(p2-sing-pr-words phase 2, the wire lane; design 2026-10-12 §2.8, §4):
/// the additive verb `clip.setNoteWords` in `Sources/DAWControl/Commands.swift`
/// + `SingWire.swift`, and the MCP tool `clip_set_note_words` in
/// `mcp-server/src/server.ts`. It maps `clipId`, `noteId` (the note the line
/// starts on), `words: [String]`, `dryRun?` onto
/// `setNoteWords(clipId:startNoteId:words:dryRun:)` and replies exactly as
/// `clip.setNoteWord` does, with `rejectUnknownKeys`. Refusals: the target's
/// (`ProjectError`, `LyricEditRefusal.needsMIDIClip`) as `clip.setNoteWord`
/// maps them; `LyricLineEditRefusal.cannotStart` / `.word` carry a
/// `LyricEditRefusal` whose existing code applies; `noWords`,
/// `lineLongerThanNotes`, `lineNeedsMoreNotes` and `unstable` need codes of
/// their own. Not added here: this wave's wire count is the orchestrator's.
@MainActor
extension ProjectStore {

    /// The undo step typing a word on a note records (design §3.4).
    public static let typeWordUndoLabel = "Type Word"

    /// The undo step typing a whole line across notes records (design
    /// 2026-10-12 §2.8, D6): ONE step for the whole line.
    public static let typeWordsUndoLabel = "Type Words"

    /// Sets a clip's lyrics text, as ONE undo step named `undoLabel`. The
    /// clip's language is KEPT (p2-sing-x3b, `ClipLyrics.withText`): writing
    /// only the words never turns a Chinese clip back into English.
    ///
    /// Blank text clears the lyrics (`ClipLyrics.normalized`, the one "no
    /// lyrics" state; `Clip.lyrics` set directly does not normalise). Lyrics
    /// are not render material, so nothing replays; `tracksDidChange` only
    /// keeps the engine's copy of the tracks fresh (the `setClipGain`
    /// precedent).
    ///
    /// - Throws: `ProjectError.clipNotFound`; `ProjectError.clipInTakeGroup`
    ///   for a comp member (its clip is rebuilt from the takes on every comp
    ///   edit, so a direct write would be silently overwritten: the rule
    ///   every ordinary clip edit follows); `LyricEditRefusal.needsMIDIClip`;
    ///   `LyricEditRefusal.tooLong` over `ClipLyrics.maxTextLength` characters.
    @discardableResult
    public func setClipLyrics(clipId: UUID, text: String, undoLabel: String) throws -> Clip {
        let (t, c) = try lyricsTarget(clipId)
        guard text.count <= ClipLyrics.maxTextLength else { throw LyricEditRefusal.tooLong(characters: text.count) }
        let kept = tracks[t].clips[c].lyrics?.withText(text) ?? ClipLyrics(text: text)
        writeLyrics(ClipLyrics.normalized(kept), track: t, clip: c, undoLabel: undoLabel)
        return tracks[t].clips[c]
    }

    /// Sets a clip's lyrics text AND the language it is sung in (p2-sing-x3b,
    /// design 2026-10-06 §6.3), as ONE undo step named `undoLabel`. `language`
    /// nil or `"en"` is English. A language-only change (the same text) is an
    /// edit too. Blank text clears the lyrics, language and all.
    ///
    /// - Throws: everything the text-only call throws, then
    ///   `LyricEditRefusal.lyrics(.languageUnsupported)` for a code that cannot
    ///   be sung (`LyricLanguage.isSupported`), before anything changes.
    @discardableResult
    public func setClipLyrics(clipId: UUID, text: String, language: String?, undoLabel: String) throws -> Clip {
        let (t, c) = try lyricsTarget(clipId)
        guard text.count <= ClipLyrics.maxTextLength else { throw LyricEditRefusal.tooLong(characters: text.count) }
        if let language, !LyricLanguage.isSupported(language) {
            throw LyricEditRefusal.lyrics(.languageUnsupported(language: language))
        }
        writeLyrics(ClipLyrics.normalized(ClipLyrics(text: text, language: language)), track: t, clip: c,
                    undoLabel: undoLabel)
        return tracks[t].clips[c]
    }

    /// The one write both `setClipLyrics` calls end in.
    private func writeLyrics(_ lyrics: ClipLyrics?, track t: Int, clip c: Int, undoLabel: String) {
        performEdit(undoLabel) {
            tracks[t].clips[c].lyrics = lyrics
            engine?.tracksDidChange(tracks)
        }
    }

    /// Types `word` on one note of a melody clip (design §3): `""` clears the
    /// note's word and `"+"` holds the word before onto it. The clip's TEXT is
    /// rewritten by `LyricTextEdit.apply`, the one pure edit, and stored
    /// through `setClipLyrics` as ONE undo step, "Type Word". The note field
    /// and the wire both call this.
    ///
    /// `dryRun` returns the same result without touching the project: no
    /// write, no undo step, the project not even marked edited. An edit that
    /// changes nothing records no undo step either.
    ///
    /// - Throws: `setClipLyrics`'s refusals (checked first, on both paths),
    ///   then `LyricEditRefusal` (every case has its sentence).
    @discardableResult
    public func setNoteWord(clipId: UUID, noteId: UUID, word: String,
                            dryRun: Bool = false) throws -> LyricNoteWordResult {
        let (t, c) = try lyricsTarget(clipId)
        let clip = tracks[t].clips[c]
        let (text, assignment) = try LyricTextEdit.apply(.typed(word, onNote: noteId), to: clip,
                                                         tempoMap: transport.tempoMap)
        let changed = text != clip.lyrics?.text
        if changed && !dryRun {
            try setClipLyrics(clipId: clipId, text: text, undoLabel: Self.typeWordUndoLabel)
        }
        return LyricNoteWordResult(clipID: clipId, text: text, stored: !dryRun, changed: changed,
                                   assignment: assignment)
    }

    /// Types a whole line across notes (p2-sing-pr-words phase 2, design
    /// `docs/design/2026-10-12-piano-roll-words.md` §2.8): `words[0]` on the
    /// note `startNoteId`, each next word on the next melody note (a
    /// hyphenated word one note per part; `"+"` or `""` holds the word before
    /// on). The clip's TEXT is rewritten by `LyricTextEdit.applyLine`, which
    /// types each word with the one-note edit and checks the whole line, and
    /// is stored through `setClipLyrics` ONCE: one undo step, "Type Words",
    /// journaled with no coalescing key (the one-writer rule, D6), so one ⌘Z
    /// takes the whole line back and a line never folds into a note edit.
    /// All or nothing: a refusal anywhere in the line writes nothing.
    ///
    /// `dryRun` returns the same result without touching the project: no
    /// write, no undo step, the project not even marked edited. A line that
    /// types the words the notes already sing changes nothing and records no
    /// undo step either.
    ///
    /// - Throws: `setClipLyrics`'s target refusals first, on both paths, the
    ///   same as `setNoteWord` (`ProjectError.clipNotFound`,
    ///   `ProjectError.clipInTakeGroup`, `LyricEditRefusal.needsMIDIClip`),
    ///   then `LyricLineEditRefusal` (every case has its sentence).
    @discardableResult
    public func setNoteWords(clipId: UUID, startNoteId: UUID, words: [String],
                             dryRun: Bool = false) throws -> LyricNoteWordResult {
        let (t, c) = try lyricsTarget(clipId)
        let clip = tracks[t].clips[c]
        let (text, assignment) = try LyricTextEdit.applyLine(words: words, startingAt: startNoteId, to: clip,
                                                             tempoMap: transport.tempoMap)
        let changed = text != clip.lyrics?.text
        if changed && !dryRun {
            try setClipLyrics(clipId: clipId, text: text, undoLabel: Self.typeWordsUndoLabel)
        }
        return LyricNoteWordResult(clipID: clipId, text: text, stored: !dryRun, changed: changed,
                                   assignment: assignment)
    }

    /// The clip a lyrics write would change, checked the same way for a dry
    /// run and a real one.
    private func lyricsTarget(_ clipId: UUID) throws -> (t: Int, c: Int) {
        guard let at = locateClipForLyrics(clipId) else { throw ProjectError.clipNotFound(clipId) }
        try requireNotCompMember(trackIndex: at.t, clipIndex: at.c)
        guard tracks[at.t].clips[at.c].isMIDI else { throw LyricEditRefusal.needsMIDIClip }
        return at
    }

    /// Locates a clip by id across every track (extension-local: the private
    /// `locateClip(_:)` in ProjectStore.swift is not visible here, the
    /// ProjectStore+Humanize.swift precedent).
    private func locateClipForLyrics(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
