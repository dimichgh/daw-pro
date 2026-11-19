import Foundation

/// One change typed on ONE note of a melody clip's word strip (p2-sing-x1,
/// design `docs/design/2026-10-06-p2-sing-expansion.md` §3).
public enum LyricNoteEdit: Equatable, Sendable {
    /// Type `word` on the note. `"+"` (or OpenUtau's `"+~"`) means "the word
    /// before holds onto this note".
    case setWord(noteID: UUID, word: String)
    /// Clear the note's word: the word before holds on, exactly as `"+"`.
    case clearWord(noteID: UUID)

    /// The note the edit is on.
    public var noteID: UUID {
        switch self {
        case .setWord(let id, _), .clearWord(let id): return id
        }
    }

    /// The note field's and the wire's shape (design §3.4 `clip.setNoteWord`):
    /// an empty word (or only spaces) clears, anything else is typed.
    public static func typed(_ word: String, onNote noteID: UUID) -> LyricNoteEdit {
        word.allSatisfy(\.isWhitespace) ? .clearWord(noteID: noteID) : .setWord(noteID: noteID, word: word)
    }
}

/// Why a word cannot be typed onto that note. Every case has the sentence the
/// user reads; none names the user.
public enum LyricEditRefusal: Error, Equatable, Sendable {
    /// The clip is audio (wire `lyricsNeedMIDIClip`). Base design §5.7
    /// "Audio clip".
    case needsMIDIClip
    /// The clip has no words to change yet (wire `lyricsNoText`). §14.
    case noText
    /// No note with this id is in the clip (wire `noteNotFound`). NOT in §14;
    /// provisional copy.
    case noteNotFound(noteID: UUID)
    /// The note is in the clip but no word sings it: a chord note the
    /// one-note-at-a-time rule dropped, a note past the clip's end, or a line
    /// of the tune the words do not reach (wire `noteNotSung`). §14.
    case noteNotSung(noteID: UUID)
    /// More than one word (a space, or a separator such as "a/b" or
    /// "wait...what") (wire `lyricWordHasSpace`). §14.
    case wordHasSpace(word: String)
    /// A word with `+` marks glued on ("star+", "+star", "++"). A mark there
    /// would reach a neighbouring note. NOT in §14; provisional copy.
    case wordHasMarks(word: String)
    /// Only punctuation ("!", "—"): nothing to sing. NOT in §14; provisional.
    case wordHasNoLetters(word: String)
    /// `+` (or clearing) on the first note of a line of the tune: the word
    /// before is across a breath, and a word never crosses one (base §3.3
    /// rule 2). NOT in §14; provisional copy.
    case nothingToHold(noteID: UUID)
    /// The note is one of a hyphenated word's own parts ("twin-kle"), which
    /// that word needs. NOT in §14; provisional copy.
    case noteInsideHyphenatedWord(word: String)
    /// The assigner's own refusal, with its own sentence: the text as it is
    /// does not fit the notes (W > N, markup that needs more notes), the word
    /// is not English, or a hyphenated word needs more notes than it would get.
    case lyrics(LyricRefusal)
    /// The edit would move a word the user did not touch (wire
    /// `lyricEditUnstable`). §14.
    case unstable
    /// The new text would be longer than `ClipLyrics.maxTextLength` (wire
    /// `lyricsTooLong`). NOT in §5.7 or §14; provisional copy.
    case tooLong(characters: Int)

    public var sentence: String {
        switch self {
        case .needsMIDIClip:
            return "Sing needs a melody clip with notes. This one is audio."
        case .noText:
            return "Type the words in the box first; then you can change single notes."
        case .noteNotFound:
            // PROVISIONAL (not in design §14).
            return "I couldn't find that note in this clip."
        case .noteNotSung:
            return "This note isn't sung: it is part of a chord, or no words reach this line yet."
        case .wordHasSpace:
            return "Type one word per note. To type several, use the words box."
        case .wordHasMarks:
            // PROVISIONAL (not in design §14).
            return "Type the word without + marks. To hold the word before onto this note, type just +."
        case .wordHasNoLetters:
            // PROVISIONAL (not in design §14).
            return "Type a word with letters or numbers, or type + to hold the word before onto this note."
        case .nothingToHold:
            // PROVISIONAL (not in design §14). "Line of the tune" is the
            // tree's word for a breath phrase (`LyricWarning.unsungPhrases`).
            return "This note starts a new line of the tune, so there's no word before it to hold. Type a word instead."
        case .noteInsideHyphenatedWord(let word):
            // PROVISIONAL (not in design §14).
            return "This note sings part of '\(word)'. To change it, edit '\(word)' in the words box."
        case .lyrics(let refusal):
            return refusal.sentence
        case .unstable:
            return "I couldn't place that word without moving others. Type the line in the box instead."
        case .tooLong:
            // PROVISIONAL (not in base §5.7 or design §14).
            return "The words can be up to \(Self.grouped(ClipLyrics.maxTextLength)) characters long, "
                + "and this would go over. Shorten them first."
        }
    }

    /// 4000 → "4,000", without a locale (a sentence must not change with the Mac's region).
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (k, d) in digits.enumerated() {
            if k > 0, (digits.count - k) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return out
    }
}

/// Why a whole line of words cannot be typed across notes (p2-sing-pr-words phase 2, design
/// `docs/design/2026-10-12-piano-roll-words.md` §2.8). Every case has the sentence the user reads; none names the
/// user.
///
/// A type of its own, not new cases of `LyricEditRefusal`, on purpose: the wire's code mapping
/// (`SingWire.lyricEditRefusal`) switches over `LyricEditRefusal` with no default, so a new case there would stop
/// the build until the wire maps it. The one-note edit's refusals travel INSIDE this one (`cannotStart`, `word`), so
/// the wire can reuse their codes; only the line's own sentences are new cases.
///
/// `LocalizedError`, so a screen that shows any error's words (`SingScreenWords.sentence`) shows the sentence.
public enum LyricLineEditRefusal: Error, Equatable, Sendable, LocalizedError {
    /// Nothing was placed, for the one-note edit's own reason, in its own words: the clip is audio, it has no words
    /// yet, the start note is not in it or no word sings it, or its words as they are do not fit the notes.
    case cannotStart(LyricEditRefusal)
    /// The line has no words.
    case noWords
    /// More words than melody notes left from the start note. Design §7.5 "Line too long".
    case lineLongerThanNotes(words: Int, notes: Int)
    /// Few enough words, but each part of a hyphenated word takes a note of its own, and with those the words need
    /// `needed` notes where only `notes` are left.
    case lineNeedsMoreNotes(needed: Int, notes: Int)
    /// Word `index` (0-based) of the line, typed as `word` (trimmed), could not go on its note: the one-note edit's
    /// refusal for it. Nothing was placed: the line is all or nothing.
    case word(index: Int, word: String, refusal: LyricEditRefusal)
    /// Every word went on, but the whole-line check found a word outside the line that moved, or a word of the line
    /// that is not on its note. It should not happen; it is the gate that catches a defect in the steps.
    case unstable

    public var sentence: String {
        switch self {
        case .cannotStart(let refusal):
            return refusal.sentence
        case .noWords:
            // PROVISIONAL (not in design §7.5).
            return "Type the words to put on the notes, one word for each note."
        case .lineLongerThanNotes(let words, let notes):
            // Design §7.5 "Line too long" (PROVISIONAL there), with one note or word written in the singular.
            let left = notes == 1 ? "1 note is" : "\(notes) notes are"
            return "You typed \(Self.count(words, "word")) but only \(left) left from here. "
                + "Remove \(Self.count(words - notes, "word")), or add notes."
        case .lineNeedsMoreNotes(let needed, let notes):
            // PROVISIONAL (not in design §7.5).
            let left = notes == 1 ? "1 is" : "\(notes) are"
            return "Each part of a hyphenated word takes a note of its own, so these words need \(needed) notes, "
                + "but only \(left) left from here. Remove a word or a hyphen, or add notes."
        case .word(_, let word, let refusal):
            // PROVISIONAL (not in design §7.5): the word first, then why (design §2.8 "naming the word"). An
            // empty word is a hold, typed as "+".
            return "I couldn't put '\(word.isEmpty ? "+" : word)' on its note. " + refusal.sentence
        case .unstable:
            // PROVISIONAL: the one-note edit's `unstable` sentence, for a line.
            return "I couldn't place those words without moving others. Type the line in the box instead."
        }
    }

    public var errorDescription: String? { sentence }

    private static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}

/// Typing a word onto one note, as an edit of the clip's TEXT (p2-sing-x1,
/// design §3.2). Pure: Foundation only, no store, no engine.
///
/// ## The text stays the only truth
///
/// Nothing new is stored. The word-to-note assignment is still derived from
/// the text, the notes and the tempo map by `SingPlanner.assignment(for:tempoMap:)`,
/// THE one derivation. A note edit therefore rewrites the text so that the
/// derivation reproduces what the user sees, and then CHECKS that it does:
///
/// 1. **Derive** today's assignment. A text that does not fit refuses with its
///    own sentence (chips are not shown for it, so there is nothing to click).
/// 2. **Find** the word `k` that sings the note, and the note's place `j` among
///    `k`'s notes. A note no word sings refuses (`noteNotSung`).
/// 3. **Freeze**: every word in scope gets `+` marks for the spare notes the
///    assigner gave it (rules 5.1 and 5.2), so its markup asks for exactly the
///    notes it has now. Markup is honoured first and never re-shared (rule 3).
///    - Scope, `linePerPhrase`: the note's own line only. Lines are paired
///      with phrases one to one and shared out independently, so no other line
///      can move, and the other lines' text stays byte-identical.
///    - Scope, `flow`: EVERY word. ⚠️ A DEPARTURE from design §3.2 ("the freeze
///      touches ONE phrase"): in flow mode the words are spread over the
///      phrases by one global split (`LyricNoteAssigner.flowBreaks`) that
///      weighs every word's markup, so marks added in one phrase can move
///      words in another. With every word frozen each phrase asks for exactly
///      its notes and that split is the only one with no error; an edit keeps
///      every phrase's total, so the split cannot move.
/// 4. **Edit** the frozen text:
///    - on a word's first note, the word's own text is replaced and its `+`
///      marks adjusted so it covers the same notes;
///    - on a later note it holds, the word keeps the notes before it and the
///      new word, with `+` marks for the rest, is inserted after it;
///    - `+` or clearing on a word's first note: one `+` more for the word
///      before, and the word loses that note (and is removed if it had only
///      that one); on any later note it is already held, so nothing changes.
///    Every splice is checked by tokenizing again (`+` marks can be glued on,
///    so a mark is never found by its spelling alone).
/// 5. **Round trip**: derive again; every word must sing exactly the notes it
///    sang, except the edited ones, in the same mode with the same silent
///    notes. Anything else refuses `unstable`. It should not happen; it is the
///    gate that catches a defect in steps 3-4.
///
/// An edit that changes nothing (`+` on a held note, the same word again)
/// returns the text unchanged, so no marks appear that nobody asked for.
///
/// ## Languages (p2-sing-x3b)
///
/// Every reading of the text uses the CLIP's language (`ClipLyrics.language`),
/// exactly as the one derivation does: in a Chinese clip each Han character is
/// a word of its own (`LyricTokenizer`), so a character can be typed on one
/// note and `+` holds the character before. The edited text is stored with the
/// clip's language kept (`ClipLyrics.withText`). A word the clip cannot sing
/// is refused through `LyricRefusal.forUnsingable`, the assigner's own
/// classification (Chinese typed into an English clip is `scriptMismatch`).
/// Marks and inserted words are spliced with ASCII spaces around them, as in
/// an English clip; a space never changes a Chinese clip's words.
public enum LyricTextEdit {

    /// The new text, and the assignment derived from it.
    public static func apply(_ edit: LyricNoteEdit, to clip: Clip, tempoMap: TempoMap)
        throws(LyricEditRefusal) -> (text: String, assignment: LyricAssignment) {
        guard clip.isMIDI else { throw .needsMIDIClip }
        guard let lyrics = clip.lyrics else { throw .noText }
        let text = lyrics.text
        let language = lyrics.language
        let n = edit.noteID
        guard clip.notes?.contains(where: { $0.id == n }) == true else { throw .noteNotFound(noteID: n) }
        let typed = try typedWord(edit, language: language)

        // 1. Today's assignment, from the one derivation.
        let before: LyricAssignment
        do throws(LyricRefusal) {
            before = try SingPlanner.assignment(for: clip, tempoMap: tempoMap)
        } catch {
            throw error == .noWords ? .noText : .lyrics(error)
        }

        // 2. The word that sings the note.
        guard let k = before.words.firstIndex(where: { $0.noteIDs.contains(n) }),
              let j = before.words[k].noteIDs.firstIndex(of: n) else { throw .noteNotSung(noteID: n) }
        let word = before.words[k]
        let notes = word.noteIDs.count
        let parts = max(1, word.word.parts.count)

        // What the edit is, and what every word must sing afterwards.
        var expected = before.words.map(Placed.init)
        let op: Op
        switch typed {
        case .hold:
            guard j == 0 else { return (text, before) }              // already held by the word it is in
            guard k > 0, before.words[k - 1].phrase == word.phrase else { throw .nothingToHold(noteID: n) }
            guard notes == 1 || notes - 1 >= parts else { throw .noteInsideHyphenatedWord(word: word.word.typed) }
            op = .hold(k)
            expected[k - 1].noteIDs.append(n)
            expected[k].noteIDs.removeFirst()
            if expected[k].noteIDs.isEmpty { expected.remove(at: k) }
        case .word(let raw, let new):
            let newParts = max(1, new.parts.count)
            if j == 0 {
                if Placed(new, at: word) == expected[k] { return (text, before) }   // the same word again
                guard newParts <= notes else {
                    throw .lyrics(.markedWordDoesNotFit(word: new.sung, needed: newParts))
                }
                op = .replace(k, raw: raw, holds: notes - newParts)
                expected[k] = Placed(new, at: word)
            } else {
                guard j >= parts else { throw .noteInsideHyphenatedWord(word: word.word.typed) }
                guard newParts <= notes - j else {
                    throw .lyrics(.markedWordDoesNotFit(word: new.sung, needed: newParts))
                }
                op = .split(k, keep: j - parts, raw: raw, holds: notes - j - newParts)
                expected[k].noteIDs = Array(word.noteIDs[..<j])
                var inserted = Placed(new, at: word)
                inserted.noteIDs = Array(word.noteIDs[j...])
                expected.insert(inserted, at: k + 1)
            }
        }

        // 3. Freeze.
        let scope: [Int] = before.mode == .linePerPhrase
            ? before.words.indices.filter { before.words[$0].phrase == word.phrase }
            : Array(before.words.indices)
        var working = try frozen(text, assignment: before, scope: scope, language: language)

        // 4. Edit.
        switch op {
        case .replace(let k, let raw, let holds):
            working = try replacingOwnText(working, word: k, with: raw, language: language)
            working = try settingHolds(working, word: k, to: holds, language: language)
        case .split(let k, let keep, let raw, let holds):
            working = try settingHolds(working, word: k, to: keep, language: language)
            working = try insertingWord(working, after: k, raw: raw, holds: holds, language: language)
        case .hold(let k):
            // Word k first (it is later in the text), so word k - 1's offsets hold.
            if notes == 1 {
                working = try deletingWord(working, k, language: language)
            } else {
                working = try settingHolds(working, word: k, to: notes - 1 - parts, language: language)
            }
            let previous = try Scan(working, language: language).words[k - 1].holds
            working = try settingHolds(working, word: k - 1, to: previous + 1, language: language)
        }
        guard working.count <= ClipLyrics.maxTextLength else { throw .tooLong(characters: working.count) }

        // 5. Round trip.
        var edited = clip
        edited.lyrics = lyrics.withText(working)         // the clip's language kept
        let after: LyricAssignment
        do throws(LyricRefusal) {
            after = try SingPlanner.assignment(for: edited, tempoMap: tempoMap)
        } catch {
            throw .unstable
        }
        guard after.mode == before.mode, after.unsungNoteIDs == before.unsungNoteIDs,
              after.words.map(Placed.init) == expected else { throw .unstable }
        return (working, after)
    }

    // MARK: - What was typed

    enum Typed {
        /// `+`, `+~`, or nothing: the word before holds on.
        case hold
        /// One word: the text to splice in (trimmed, as typed), and its token.
        case word(raw: String, LyricWord)
    }

    /// What was typed, read in the clip's `language` (nil: English).
    static func typedWord(_ edit: LyricNoteEdit, language: String? = nil) throws(LyricEditRefusal) -> Typed {
        guard case .setWord(_, let word) = edit else { return .hold }
        var raw = Substring(word)
        while raw.first?.isWhitespace == true { raw.removeFirst() }
        while raw.last?.isWhitespace == true { raw.removeLast() }
        if raw.isEmpty || raw == "+" || raw == "+~" { return .hold }
        let text = String(raw)
        if raw.contains(where: \.isWhitespace) { throw .wordHasSpace(word: text) }
        let tokens = LyricTokenizer.tokenize(text, language: language)
        if tokens.words.count > 1 { throw .wordHasSpace(word: text) }
        guard let only = tokens.words.first else {
            if raw.contains("+") { throw .wordHasMarks(word: text) }
            throw .wordHasNoLetters(word: text)
        }
        if only.holds > 0 || !tokens.orphanHoldLines.isEmpty { throw .wordHasMarks(word: text) }
        if !only.isSingable { throw .lyrics(.forUnsingable(only)) }
        return .word(raw: text, only)
    }

    // MARK: - The edit, and what every word must sing after it

    enum Op {
        /// Replace word k's own text; it then holds `holds` marks.
        case replace(Int, raw: String, holds: Int)
        /// Word k keeps `keep` marks; the new word goes after it with `holds`.
        case split(Int, keep: Int, raw: String, holds: Int)
        /// Word k's first note goes to word k - 1.
        case hold(Int)
    }

    /// One word as the round trip compares it. Not its `+` count, which the
    /// freeze changes on purpose, and not the warnings, which follow from it
    /// (a frozen word is held by its own marks, so "Held words" goes away).
    struct Placed: Equatable {
        var typed: String
        var sung: String
        var parts: [String]
        var language: String?
        var line: Int
        var phrase: Int
        var noteIDs: [UUID]

        init(_ assigned: AssignedLyricWord) {
            typed = assigned.word.typed
            sung = assigned.word.sung
            parts = assigned.word.parts
            language = assigned.word.language
            line = assigned.word.line
            phrase = assigned.phrase
            noteIDs = assigned.noteIDs
        }

        /// `word` typed in `slot`'s place: its line, phrase and notes.
        init(_ word: LyricWord, at slot: AssignedLyricWord) {
            typed = word.typed
            sung = word.sung
            parts = word.parts
            language = word.language
            line = slot.word.line
            phrase = slot.phrase
            noteIDs = slot.noteIDs
        }
    }

    // MARK: - Reading the text

    /// The text as characters, its words, and where each word's own text sits:
    /// `[starts[i], ownEnd(i))`, the token without the `+` marks peeled off
    /// either end. The starts come from the tokenizer's own scan
    /// (`LyricTokenizer.wordStartOffsets`), never a second parser; each span
    /// is checked character by character against the word's `typed`.
    struct Scan {
        let chars: [Character]
        let text: LyricText
        let starts: [Int]
        /// The clip's language: every tokenize of an edited text uses it.
        let language: String?

        var words: [LyricWord] { text.words }

        init(_ string: String, language: String? = nil) throws(LyricEditRefusal) {
            chars = Array(string)
            self.language = language
            text = LyricTokenizer.tokenize(string, language: language)
            starts = LyricTokenizer.wordStartOffsets(string, language: language)
            guard starts.count == text.words.count else { throw .unstable }
            for (i, word) in text.words.enumerated() {
                let own = Array(word.typed)
                guard starts[i] + own.count <= chars.count else { throw .unstable }
                for (offset, ch) in own.enumerated() {
                    let actual = chars[starts[i] + offset]
                    guard (Self.curly.contains(actual) ? "'" : actual) == ch else { throw .unstable }
                }
            }
        }

        static let curly: Set<Character> = Set(LyricTokenizer.curlyApostrophes.map(Character.init))

        func ownEnd(_ i: Int) -> Int { starts[i] + text.words[i].typed.count }

        /// Where word i's stretch of its own line ends: the next word's start
        /// when that is on the same line, else the line break (or the end).
        /// Every `+` that holds word i lies in `ownEnd(i)..<lineEnd(i)`.
        func lineEnd(_ i: Int) -> Int {
            let next = i + 1 < starts.count ? starts[i + 1] : chars.count
            var q = ownEnd(i)
            while q < next, !chars[q].isNewline { q += 1 }
            return q
        }
    }

    /// `count` hold marks, each with a space before it.
    static func marks(_ count: Int) -> [Character] {
        Array(String(repeating: " +", count: max(0, count)))
    }

    /// True when `new` has exactly `old`'s words, except that word i (if
    /// any) now has `holds` marks, and the same orphan `+` lines.
    static func sameWords(_ new: LyricText, _ old: LyricText, word i: Int? = nil, holds: Int = 0) -> Bool {
        guard new.words.count == old.words.count, new.orphanHoldLines == old.orphanHoldLines else { return false }
        for x in old.words.indices {
            var want = old.words[x]
            if x == i { want.holds = holds }
            if new.words[x] != want { return false }
        }
        return true
    }

    // MARK: - Step 3: the freeze

    /// `text` with every word in `scope` marked for the notes it sings now.
    static func frozen(_ text: String, assignment: LyricAssignment, scope: [Int],
                       language: String? = nil) throws(LyricEditRefusal) -> String {
        let scan = try Scan(text, language: language)
        guard scan.words.count == assignment.words.count else { throw .unstable }
        var chars = scan.chars
        var want = scan.text
        for i in scope.sorted(by: >) {
            let extra = assignment.words[i].noteIDs.count - scan.words[i].markedNotes
            guard extra >= 0 else { throw .unstable }
            guard extra > 0 else { continue }
            chars.insert(contentsOf: marks(extra), at: scan.ownEnd(i))
            want.words[i].holds += extra
        }
        let out = String(chars)
        guard sameWords(LyricTokenizer.tokenize(out, language: language), want) else { throw .unstable }
        return out
    }

    // MARK: - Step 4: splices, each checked by tokenizing again

    /// Word i's own text replaced by `raw` (one word, already checked).
    static func replacingOwnText(_ text: String, word i: Int, with raw: String,
                                 language: String? = nil) throws(LyricEditRefusal) -> String {
        let scan = try Scan(text, language: language)
        var chars = scan.chars
        chars.replaceSubrange(scan.starts[i]..<scan.ownEnd(i), with: Array(raw))
        let out = String(chars)
        let check = LyricTokenizer.tokenize(out, language: language)
        guard let new = LyricTokenizer.tokenize(raw, language: language).words.first,
              check.words.count == scan.words.count, check.orphanHoldLines == scan.text.orphanHoldLines
        else { throw .unstable }
        for x in scan.words.indices {
            var want = x == i ? new : scan.words[x]
            want.line = scan.words[x].line
            want.holds = scan.words[x].holds
            guard check.words[x] == want else { throw .unstable }
        }
        return out
    }

    /// Word i with exactly `target` hold marks: new ones go right after its
    /// own text; surplus ones are removed from the right, each removal checked.
    static func settingHolds(_ text: String, word i: Int, to target: Int,
                             language: String? = nil) throws(LyricEditRefusal) -> String {
        guard target >= 0 else { throw .unstable }
        var scan = try Scan(text, language: language)
        var out = text
        let have = scan.words[i].holds
        if target > have {
            var chars = scan.chars
            chars.insert(contentsOf: marks(target - have), at: scan.ownEnd(i))
            out = String(chars)
            guard sameWords(LyricTokenizer.tokenize(out, language: language), scan.text, word: i, holds: target) else {
                throw .unstable
            }
            return out
        }
        var holds = have
        while holds > target {
            out = try removingOneHold(scan, word: i)
            holds -= 1
            scan = try Scan(out, language: language)
        }
        return out
    }

    /// One of word i's hold marks removed, the rightmost that can be. A `+`
    /// counts only if tokenizing again shows word i holding one fewer and
    /// nothing else changed (a `+` inside punctuation, "!+!", holds nothing).
    /// A mark standing alone takes the space before it along, so the text
    /// does not collect double spaces.
    static func removingOneHold(_ scan: Scan, word i: Int) throws(LyricEditRefusal) -> String {
        let want = scan.words[i].holds - 1
        let lo = scan.ownEnd(i)
        var q = scan.lineEnd(i)
        while q > lo {
            q -= 1
            guard scan.chars[q] == "+" else { continue }
            let end = q + 1 < scan.chars.count && scan.chars[q + 1] == "~" ? q + 2 : q + 1
            var tidy = q
            if q > 0, scan.chars[q - 1] == " " || scan.chars[q - 1] == "\t",
               end == scan.chars.count || scan.chars[end].isWhitespace {
                tidy = q - 1
            }
            for start in Set([tidy, q]).sorted() {
                var chars = scan.chars
                chars.removeSubrange(start..<end)
                let out = String(chars)
                if sameWords(LyricTokenizer.tokenize(out, language: scan.language), scan.text, word: i, holds: want) {
                    return out
                }
            }
        }
        throw .unstable
    }

    /// `raw` (one word) inserted after word i and its marks, on word i's line,
    /// followed by `holds` marks.
    static func insertingWord(_ text: String, after i: Int, raw: String, holds: Int,
                              language: String? = nil) throws(LyricEditRefusal) -> String {
        let scan = try Scan(text, language: language)
        guard let new = LyricTokenizer.tokenize(raw, language: language).words.first else { throw .unstable }
        var q = scan.lineEnd(i)
        while q > scan.ownEnd(i), scan.chars[q - 1].isWhitespace { q -= 1 }
        var insert: [Character] = [" "] + Array(raw) + marks(holds)
        if q < scan.chars.count, !scan.chars[q].isWhitespace { insert.append(" ") }
        var chars = scan.chars
        chars.insert(contentsOf: insert, at: q)
        let out = String(chars)
        var want = scan.text
        var placed = new
        placed.line = scan.words[i].line
        placed.holds = holds
        want.words.insert(placed, at: i + 1)
        guard sameWords(LyricTokenizer.tokenize(out, language: language), want) else { throw .unstable }
        return out
    }

    /// Word i's own text removed (it has no marks of its own: it sang one
    /// note). A space it leaves doubled is removed with it.
    static func deletingWord(_ text: String, _ i: Int, language: String? = nil) throws(LyricEditRefusal) -> String {
        let scan = try Scan(text, language: language)
        var lo = scan.starts[i]
        var hi = scan.ownEnd(i)
        let chars = scan.chars
        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }
        let afterIsGap = hi == chars.count || chars[hi].isWhitespace
        if lo > 0, isSpace(chars[lo - 1]), afterIsGap {
            lo -= 1
        } else if lo == 0 || chars[lo - 1].isNewline, hi < chars.count, isSpace(chars[hi]) {
            hi += 1
        }
        var out = chars
        out.removeSubrange(lo..<hi)
        let result = String(out)
        var want = scan.text
        want.words.remove(at: i)
        guard sameWords(LyricTokenizer.tokenize(result, language: language), want) else { throw .unstable }
        return result
    }
}

// MARK: - A whole line across notes (p2-sing-pr-words phase 2)

extension LyricTextEdit {

    /// Types a whole line across notes (p2-sing-pr-words phase 2, design
    /// `docs/design/2026-10-12-piano-roll-words.md` §2.8): `words[0]` on the note `noteID`, and each next word on the
    /// next notes of the MELODY, the notes words are sung on (`SingPlanner.melody`: one note per onset, the highest;
    /// a chord's other notes never get a word). Each element is exactly what the one-note field takes
    /// (`LyricNoteEdit.typed`): one word, or `"+"` / `""` for "the word before holds onto this note". To cut a typed
    /// line into elements the way the clip reads it, use `lineWords(_:language:)`.
    ///
    /// ## How many notes a word takes
    ///
    /// One, and a hyphenated word one per part ("twin-kle" takes two: the words box's own rule). The next word goes
    /// on the note after them. Known limit v1 (design §2.8): a hyphenated word is refused (`markedWordDoesNotFit`)
    /// unless the word it lands on already sings enough notes, because each word is typed by the one-note edit,
    /// which never takes notes from a neighbour.
    ///
    /// ## Built from the one-note edit, never beside it
    ///
    /// Each word is `apply`'d in turn to the clip AS THE WORDS BEFORE IT LEFT IT, so every step runs the one-note
    /// edit's own round trip (every other word still sings exactly the notes it sang). Then the whole line is
    /// checked once more against the clip as it was: the same mode and the same silent notes; every word with no
    /// note under the line sings exactly what it sang; each typed word starts on its own note and sings its parts'
    /// notes; each `+` shares the word of the note before it. Anything else refuses `unstable`.
    ///
    /// All or nothing: the first refusal stops the line, and nothing but the refusal comes back. A line that types
    /// the words the notes already sing returns the text unchanged, byte for byte.
    public static func applyLine(words: [String], startingAt noteID: UUID, to clip: Clip, tempoMap: TempoMap)
        throws(LyricLineEditRefusal) -> (text: String, assignment: LyricAssignment) {
        guard clip.isMIDI else { throw .cannotStart(.needsMIDIClip) }
        guard let lyrics = clip.lyrics else { throw .cannotStart(.noText) }
        guard clip.notes?.contains(where: { $0.id == noteID }) == true else {
            throw .cannotStart(.noteNotFound(noteID: noteID))
        }
        guard !words.isEmpty else { throw .noWords }

        // What each word is, read in the clip's language (nil: a hold), and how many notes it takes.
        var typed: [LyricWord?] = []
        for (i, word) in words.enumerated() {
            do throws(LyricEditRefusal) {
                switch try typedWord(.typed(word, onNote: noteID), language: lyrics.language) {
                case .hold: typed.append(nil)
                case .word(_, let token): typed.append(token)
                }
            } catch {
                throw .word(index: i, word: trimmed(word), refusal: error)
            }
        }
        let takes = typed.map { max(1, $0?.parts.count ?? 1) }

        // Today's words, and where the line starts in the melody.
        let before: LyricAssignment
        do throws(LyricRefusal) {
            before = try SingPlanner.assignment(for: clip, tempoMap: tempoMap)
        } catch {
            throw .cannotStart(error == .noWords ? .noText : .lyrics(error))
        }
        let melody = SingPlanner.melody(of: clip).notes.map(\.id)
        guard let start = melody.firstIndex(of: noteID),
              before.words.contains(where: { $0.noteIDs.contains(noteID) }) else {
            throw .cannotStart(.noteNotSung(noteID: noteID))
        }
        let left = melody.count - start
        let needed = takes.reduce(0, +)
        guard words.count <= left else { throw .lineLongerThanNotes(words: words.count, notes: left) }
        guard needed <= left else { throw .lineNeedsMoreNotes(needed: needed, notes: left) }

        // Word by word, each typed on the clip as the words before it left it.
        var working = clip
        var result = (text: lyrics.text, assignment: before)
        var at: [Int] = []                                     // each word's first note, as a melody index
        var cursor = start
        for (i, word) in words.enumerated() {
            at.append(cursor)
            do throws(LyricEditRefusal) {
                result = try apply(.typed(word, onNote: melody[cursor]), to: working, tempoMap: tempoMap)
            } catch {
                throw .word(index: i, word: trimmed(word), refusal: error)
            }
            working.lyrics = lyrics.withText(result.text)      // the clip's language kept
            cursor += takes[i]
        }

        // The whole line, checked against the clip as it was.
        let after = result.assignment
        guard after.mode == before.mode, after.unsungNoteIDs == before.unsungNoteIDs else { throw .unstable }
        let underLine = Set(melody[start..<(start + needed)])
        let placedAfter = after.words.map(Placed.init)
        for word in before.words where underLine.isDisjoint(with: word.noteIDs) {
            guard placedAfter.contains(Placed(word)) else { throw .unstable }
        }
        var singer: [UUID: Int] = [:]                          // note → the word that sings it
        for (k, word) in after.words.enumerated() {
            for id in word.noteIDs { singer[id] = k }
        }
        for (i, token) in typed.enumerated() {
            guard let k = singer[melody[at[i]]] else { throw .unstable }
            if let token {
                guard after.words[k].word.typed == token.typed,
                      after.words[k].noteIDs.starts(with: melody[at[i]..<(at[i] + takes[i])]) else { throw .unstable }
            } else {
                guard at[i] > 0, singer[melody[at[i] - 1]] == k else { throw .unstable }
            }
        }
        return result
    }

    /// A typed line cut into the elements `applyLine` takes, one per note, the way the clip reads words: at
    /// whitespace, and in a Chinese clip (`"zh"`, `"yue"`) also before each Han character, exactly where the
    /// tokenizer cuts (`LyricTokenizer.hanPieces`), so "一闪一闪" is four words where "split on whitespace" makes one.
    /// Marks stay as typed: "star+" is one element, refused as in the one-note field (type "star +").
    public static func lineWords(_ line: String, language: String?) -> [String] {
        let chinese = LyricLanguage.isChinese(LyricLanguage.stored(language))
        var out: [String] = []
        for token in line.split(whereSeparator: \.isWhitespace) {
            let chars = Array(token)
            guard chinese else {
                out.append(String(token))
                continue
            }
            out += LyricTokenizer.hanPieces(chars, 0..<chars.count).map { String(chars[$0]) }
        }
        return out
    }

    /// `word` without the whitespace around it, trimmed exactly as `typedWord` trims.
    static func trimmed(_ word: String) -> String {
        var raw = Substring(word)
        while raw.first?.isWhitespace == true { raw.removeFirst() }
        while raw.last?.isWhitespace == true { raw.removeLast() }
        return String(raw)
    }
}
