import AIServices
import DAWCore
import Foundation
import Observation

// p2-sing-x8 (design `docs/design/2026-10-06-p2-sing-expansion.md` §3.1, §4.1, §5.1, §6.1, §8.1-§8.3): the Sing sheet's
// expansion. Every press is a call the wire makes too:
// - the note field → `ProjectStore.setNoteWord` (`clip.setNoteWord`);
// - the language picker, the wordless buttons and [Sing it]'s words → `ProjectStore.setClipLyrics(…language:…)`
//   (`clip.setLyrics {language}` / `{wordless}`);
// - the Expression card → `ProjectStore.setSingStyle` (`clip.setSingStyle`);
// - [Sing it] with harmony parts → ONE `SingJobCoordinator.submit` carrying `SingJobRequest.parts` (`sing.render {parts}`);
// - "Write words for me" → `LyricsFit.write` (`ai.writeLyrics {fitClipId}`), which stores nothing.
// The harmony rows' range lines come from the coordinator's own calls (`SungVocalDerivedPart.derive`,
// `HarmonyPlanner.range`); `SingWireHandlers.harmonySpec`/`givenSongKey` are internal to DAWControl, so the sheet builds
// `HarmonySpec`/`SongKey` values directly (the wire's defaults: chord source `.auto`; chord notes rank 2, fill a third).

// MARK: - Pure parts (nonisolated; SingScreensExpansionTests)

/// The note field (design §3.1): open over one note of the strip.
public struct SingNoteWordField: Equatable, Sendable {
    public var noteID: UUID
    /// What the field holds: the note's word when it opened ("+" on a held note), then what is typed.
    public var draft: String
    /// What it held when it opened: an unchanged Return writes nothing.
    public var original: String
    /// A refusal in its own words (`LyricEditRefusal.sentence`), under the field.
    public var refusal: String?
    /// False while there are no stored words to change (§14 "No words yet"): Return does nothing.
    public var canCommit: Bool

    public init(noteID: UUID, draft: String, original: String, refusal: String?, canCommit: Bool) {
        self.noteID = noteID
        self.draft = draft
        self.original = original
        self.refusal = refusal
        self.canCommit = canCommit
    }

    /// THE ONE OPENING RULE: what a note's word "is" when a field opens over it (design §3.1; extracted for
    /// p2-sing-pr-words, design 2026-10-12 §2.6, so the Sing sheet and the piano roll's Words lane cannot disagree):
    /// - the word's FIRST note holds the word as typed;
    /// - any later note the word sings holds `+` (it is held: typing there edits the hold);
    /// - a note no word reaches is empty, with the "isn't sung" sentence under it (`LyricEditRefusal.noteNotSung`);
    /// - any other note (no word placed) is empty.
    /// The field can commit. The callers' own preconditions (stored words at all, the sheet's box saved first) stay
    /// with them.
    public static func opening(for noteID: UUID, in source: some SingNoteWordSource) -> SingNoteWordField {
        let word: String
        if let entry = source.noteWordEntries.first(where: { $0.noteIDs.contains(noteID) }) {
            word = entry.noteIDs.first == noteID ? entry.text : "+"
        } else {
            word = ""
        }
        let unsung = source.unsungNoteIDs.contains(noteID)
            ? LyricEditRefusal.noteNotSung(noteID: noteID).sentence : nil
        return SingNoteWordField(noteID: noteID, draft: word, original: word, refusal: unsung, canCommit: true)
    }
}

/// One placed word as a note field reads it: its text as typed and its notes, in order.
public struct SingNoteWordEntry: Equatable, Sendable {
    public var text: String
    public var noteIDs: [UUID]

    public init(text: String, noteIDs: [UUID]) {
        self.text = text
        self.noteIDs = noteIDs
    }
}

/// What `SingNoteWordField.opening(for:in:)` reads: the words one derivation placed (`SingPlanner.assignment`), in
/// reading order, and the melody notes no word reaches. The Sing sheet's preview and the roll's words both are one.
public protocol SingNoteWordSource {
    var noteWordEntries: [SingNoteWordEntry] { get }
    var unsungNoteIDs: [UUID] { get }
}

/// The Sing sheet's chips are its placed words (`SingSheetPreview.chips`: `word.typed` over `word.noteIDs`).
extension SingSheetPreview: SingNoteWordSource {
    public var noteWordEntries: [SingNoteWordEntry] {
        chips.map { SingNoteWordEntry(text: $0.text, noteIDs: $0.noteIDs) }
    }
}

/// "Write words for me" (design §8.3).
public struct SingWriteWordsState: Equatable, Sendable {
    public var isOpen = false
    public var theme = ""
    public var isWriting = false
    /// `LyricsFit.Copy.notFit(lines:)` when some lines did not fit, or the writer's refusal in its own words.
    public var notice: String?

    public init() {}
}

/// One harmony part the person added (design §4.1).
public struct SingHarmonyPart: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SingJobPart.Kind
    /// A voice picked for this part; nil = the lead's (the coordinator's default).
    public var voiceID: String?

    public init(id: UUID = UUID(), kind: SingJobPart.Kind, voiceID: String? = nil) {
        self.id = id
        self.kind = kind
        self.voiceID = voiceID
    }
}

/// The "Add a harmony" menu's entries (§14 "Harmony choices").
public enum SingHarmonyChoice: Equatable, Sendable {
    case thirdAbove, sixthBelow, thirdBelow
    case otherMelody(clipID: UUID)
    /// Offered only when the tune has chords (`SingHarmony.tuneHasChords`).
    case chordNotes

    /// The part it adds, with the wire's defaults (`sing.render {parts}`: chord source `.auto`; `chordTones` rank 2,
    /// filled with a third below).
    public var kind: SingJobPart.Kind {
        switch self {
        case .thirdAbove: return .harmony(HarmonySpec(interval: .third, direction: .above, chordSource: .auto))
        case .sixthBelow: return .harmony(HarmonySpec(interval: .sixth, direction: .below, chordSource: .auto))
        case .thirdBelow: return .harmony(HarmonySpec(interval: .third, direction: .below, chordSource: .auto))
        case .otherMelody(let id): return .clip(id)
        case .chordNotes: return .chordTones(rank: .second, fillInterval: .third, fillChordSource: .auto)
        }
    }

    /// The menu's words (§14; "Sing my other melody…" heads a submenu of clips).
    public var title: String {
        switch self {
        case .thirdAbove: return SingCopy.harmonyThirdAbove
        case .sixthBelow: return SingCopy.harmonySixthBelow
        case .thirdBelow: return SingCopy.harmonyThirdBelow
        case .otherMelody: return SingCopy.harmonyOtherMelody
        case .chordNotes: return SingCopy.harmonyChordNotes
        }
    }
}

/// Another MIDI clip the harmony can sing ("Sing my other melody…").
public struct SingOtherMelody: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
}

/// One part's row (design §4.1): name, voice, range line, [Remove].
public struct SingHarmonyRow: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var voiceName: String
    /// §14's range line (`HarmonyRange.sentence`); nil when there is no fit to make (no measured range, a double).
    public var rangeLine: String?
    /// False: the amber line (the best octave still leaves the part out of the voice's range). A warning only.
    public var fits: Bool
    /// Why this part cannot be sung as it stands (the key cannot be worked out, its clip is gone), in its own words.
    public var refusal: String?
}

/// The key the harmony parts are counted in.
public enum SingHarmonyKeyState: Equatable, Sendable {
    /// No part needs a key.
    case notNeeded
    case given(SongKey)
    case estimated(SongKey)
    /// §14 "Key unknown": `HarmonyRefusal.needsKey`.
    case unknown

    /// The line over the parts (PROVISIONAL except the unknown case, which is §14's sentence).
    public var line: String? {
        switch self {
        case .notNeeded: return nil
        case .given(let key): return SingCopy.harmonyKey(key.name, worked: false)
        case .estimated(let key): return SingCopy.harmonyKey(key.name, worked: true)
        case .unknown: return HarmonyRefusal.needsKey.sentence
        }
    }
}

public enum SingHarmony {

    /// The part's name, as the coordinator names it (`SingJobPartStatus.name`): the spec's ("third above"), the
    /// other clip's, "chord notes", "double".
    public static func name(of kind: SingJobPart.Kind, tracks: [Track]) -> String {
        switch kind {
        case .harmony(let spec): return spec.name
        case .chordTones: return SingJobCoordinator.Copy.chordNotesPartName
        case .clip(let id): return tracks.lazy.flatMap(\.clips).first { $0.id == id }?.name ?? id.uuidString
        case .double: return SingJobCoordinator.Copy.doublePartName
        }
    }

    /// True when the melody clip holds a chord note under its tune at some onset: the chord-notes part's OWN source
    /// (`HarmonyChords(.thisClip).clipPitchesBelowLead`, what `HarmonyPlanner.chordTonePart` reads), so the choice is
    /// offered exactly when that part would sing a chord note.
    public static func tuneHasChords(clip: Clip, on track: Track, tracks: [Track]) -> Bool {
        guard clip.isMIDI else { return false }
        let own = HarmonyChords(source: .thisClip, clip: clip, on: track, tracks: tracks)
        return SingPlanner.melody(of: clip).notes.contains { !own.clipPitchesBelowLead(atClipBeat: $0.startBeat).isEmpty }
    }

    /// Every other MIDI clip with notes on a pitched track ("Sing my other melody…"), in song order.
    public static func otherMelodies(excluding clipID: UUID, tracks: [Track]) -> [SingOtherMelody] {
        tracks.filter { !ProjectTranspose.isDrumTrack($0) }.flatMap { track in
            track.clips.filter { $0.id != clipID && $0.isMIDI && !SingPlanner.melody(of: $0).notes.isEmpty }
                .map { SingOtherMelody(id: $0.id, title: SingCopy.otherMelody(clip: $0.name, track: track.name)) }
        }
    }

    /// The key for `kinds`: none needed without a harmony or chord-notes part; else the given one, else
    /// `HarmonyPlanner.resolveKey`'s estimate (the coordinator's call), else unknown.
    public static func keyState(kinds: [SingJobPart.Kind], given: SongKey?, tracks: [Track],
                                tempoMap: TempoMap) -> SingHarmonyKeyState {
        let needs = kinds.contains { kind in
            switch kind {
            case .harmony, .chordTones: return true
            case .clip, .double: return false
            }
        }
        guard needs else { return .notNeeded }
        if let given { return .given(given) }
        do throws(HarmonyRefusal) {
            return .estimated(try HarmonyPlanner.resolveKey(given: nil, tracks: tracks, tempoMap: tempoMap))
        } catch {
            return .unknown
        }
    }

    /// One part's row, from the SAME calls the coordinator plans the part with (`SingJobCoordinator.planPart`):
    /// `SungVocalDerivedPart.derive` (THE one derivation) then `HarmonyPlanner.range(of:)`, or
    /// `HarmonyPlanner.range(ofClipNotes:)` for another clip, against the lead's octave.
    public static func row(part: SingHarmonyPart, index: Int, clip: Clip, track: Track, tracks: [Track],
                           tempoMap: TempoMap, givenKey: SongKey?, voiceName: String, voiceRange: VoiceRange?,
                           leadOctaveShift: Int) -> SingHarmonyRow {
        var row = SingHarmonyRow(id: part.id, name: name(of: part.kind, tracks: tracks), voiceName: voiceName,
                                 rangeLine: nil, fits: true, refusal: nil)
        func derived(_ rule: SungVocalDerivedPart.Rule) {
            do throws(HarmonyRefusal) {
                let plan = try SungVocalDerivedPart.derive(rule, givenKey: givenKey, partIndex: index, clip: clip,
                                                           on: track, tracks: tracks, tempoMap: tempoMap)
                let range = HarmonyPlanner.range(of: plan, clipStartBeat: clip.startBeat, tempoMap: tempoMap,
                                                 voice: voiceRange, leadOctaveShift: leadOctaveShift)
                row.rangeLine = range.sentence
                row.fits = range.fits
            } catch {
                row.refusal = error.sentence
            }
        }
        switch part.kind {
        case .harmony(let spec):
            derived(.harmony(spec))
        case .chordTones(let rank, let fillInterval, let fillChordSource):
            derived(.chordTones(rank: rank, fillInterval: fillInterval, fillChordSource: fillChordSource))
        case .clip(let id):
            guard let other = tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else {
                row.refusal = SingScreenWords.sentence(SingJobError.partClipNotFound(id))
                return row
            }
            let range = HarmonyPlanner.range(ofClipNotes: SingPlanner.melody(of: other).notes,
                                             clipStartBeat: other.startBeat, tempoMap: tempoMap, voice: voiceRange,
                                             leadOctaveShift: leadOctaveShift)
            row.rangeLine = range.sentence
            row.fits = range.fits
        case .double:
            break
        }
        return row
    }
}

// MARK: - The Expression card (design §5.1)

/// Vibrato, air and "Follow note loudness" for the whole vocal, or for the notes picked in the strip. Every change
/// is ONE `setSingStyle` call (one undo step, "Set Singing Style"); a refusal stays on the card in its own words.
@MainActor
@Observable
public final class SingExpressionModel {
    private let store: ProjectStore
    private let styles: any SingSheetStyleWriting

    public private(set) var clipID: UUID?
    /// Closed by default ("Style: Vibrato Normal" while nothing is chosen).
    public private(set) var isExpanded = false
    /// The notes the card applies to; empty = the whole vocal.
    public private(set) var selectedNoteIDs: Set<UUID> = []
    /// The last refusal, in its own words (`SingStyleRefusal.sentence`, the looper's included).
    public private(set) var refusal: String?
    /// The air slider while it is dragged; written on release (one undo step per drag).
    public private(set) var airDraft: Double?

    public init(store: ProjectStore, styles: any SingSheetStyleWriting) {
        self.store = store
        self.styles = styles
    }

    /// The sheet opened on a clip (or closed): the card starts closed, with nothing picked.
    public func attach(clipID: UUID?) {
        self.clipID = clipID
        isExpanded = false
        selectedNoteIDs = []
        refusal = nil
        airDraft = nil
    }

    private var clip: Clip? {
        guard let clipID else { return nil }
        return store.tracks.lazy.flatMap(\.clips).first { $0.id == clipID }
    }

    /// The clip's stored style (nil: nothing chosen, sung with the defaults, `SingStyle.resolved`).
    public var style: SingStyle? { clip?.singStyle }
    private var resolved: SingStyle { style ?? SingStyle() }

    /// The notes with a choice of their own (the dot on their chip), among the clip's notes.
    public var notesWithOwnSetting: Set<UUID> {
        guard let overrides = style?.notes, let notes = clip?.notes else { return [] }
        let held = Set(notes.map(\.id))
        return Set(overrides.filter { held.contains($0.key) && !$0.value.isEmpty }.keys)
    }

    /// The closed card's line: "Style: Vibrato Normal" while nothing is set (the default vibrato), §14 "Style: as
    /// sung" once "As sung" is chosen.
    public var summary: String {
        SingCopy.styleSummary(vibrato: style?.vibrato, air: style?.air, follows: style?.followsVelocity ?? false,
                              notesStyled: notesWithOwnSetting.count)
    }

    /// "{n} notes selected" while notes are picked.
    public var selectionLine: String? {
        selectedNoteIDs.isEmpty ? nil : SingCopy.notesSelected(selectedNoteIDs.count)
    }

    /// The vibrato the card lights: the clip's (`SingStyle.defaultVibrato` when it names none), or the picked notes'
    /// when they agree; nil when they differ.
    public var vibrato: SingStyle.Vibrato? {
        if selectedNoteIDs.isEmpty { return style?.vibrato ?? SingStyle.defaultVibrato }
        let values = Set(selectedNoteIDs.map { resolved.resolvedVibrato(forNote: $0) })
        return values.count == 1 ? values.first : nil
    }

    /// The air the slider shows: the drag, else the clip's, else the picked notes' when they agree (nil = they differ).
    public var air: Double? {
        if let airDraft { return airDraft }
        if selectedNoteIDs.isEmpty { return style?.air ?? 0 }
        let values = Set(selectedNoteIDs.map { resolved.resolvedAir(forNote: $0) })
        return values.count == 1 ? values.first : nil
    }

    public var followsVelocity: Bool { style?.followsVelocity ?? false }

    /// The loudness toggle is clip-wide only (`NoteSingStyle` has no loudness choice): dark, with this reason, while
    /// notes are picked.
    public var followDisabledReason: String? { selectedNoteIDs.isEmpty ? nil : SingCopy.followLoudnessIsClipWide }

    public func toggleExpanded() {
        isExpanded.toggle()
        if !isExpanded { selectedNoteIDs = [] }
        refusal = nil
    }

    /// A note clicked in the strip while the card is open.
    public func toggleNote(_ id: UUID) {
        if selectedNoteIDs.contains(id) { selectedNoteIDs.remove(id) } else { selectedNoteIDs.insert(id) }
        refusal = nil
    }

    public func clearSelection() {
        selectedNoteIDs = []
        refusal = nil
    }

    /// One of the five vibrato buttons.
    public func setVibrato(_ vibrato: SingStyle.Vibrato) {
        if selectedNoteIDs.isEmpty {
            write(SingStyleEdit(vibrato: vibrato))
        } else {
            // `NoteSingStyleEdit` REPLACES a note's whole choice: carry its own air.
            write(SingStyleEdit(notes: pickedInOrder.map {
                NoteSingStyleEdit(noteID: $0, style: NoteSingStyle(vibrato: vibrato, air: style?.notes?[$0]?.air))
            }))
        }
    }

    /// The slider moved (nothing is written yet).
    public func dragAir(_ value: Double) {
        airDraft = min(SingStyle.airRange.upperBound, max(SingStyle.airRange.lowerBound, value))
    }

    /// The slider was let go: ONE write.
    public func commitAir() {
        guard let value = airDraft else { return }
        airDraft = nil
        if selectedNoteIDs.isEmpty {
            write(SingStyleEdit(air: value))
        } else {
            // Carry each note's own vibrato (the whole choice is replaced).
            write(SingStyleEdit(notes: pickedInOrder.map {
                NoteSingStyleEdit(noteID: $0, style: NoteSingStyle(vibrato: style?.notes?[$0]?.vibrato, air: value))
            }))
        }
    }

    /// "Follow note loudness" (the whole vocal only).
    public func setFollowVelocity(_ on: Bool) {
        guard followDisabledReason == nil else { return }
        write(SingStyleEdit(followVelocity: on))
    }

    /// The picked notes in the clip's own order (a stable call for the wire's all-or-nothing check).
    private var pickedInOrder: [UUID] {
        (clip?.notes ?? []).map(\.id).filter { selectedNoteIDs.contains($0) }
    }

    private func write(_ edit: SingStyleEdit) {
        guard let clipID else { return }
        refusal = nil
        do {
            try styles.setSingStyle(clipId: clipID, edit: edit)
        } catch {
            refusal = SingScreenWords.sentence(error)
        }
    }
}

// MARK: - The sheet's expansion

extension SingSheetModel {

    // MARK: Language (design §6.1)

    /// "English", "Chinese (Mandarin)", "Chinese (Cantonese)".
    public var languageTitle: String { SingCopy.languageName(language) }

    /// The picker. The STORED words take the new language at once, through the language overload ("Set Lyrics",
    /// one undo step); words still being typed in the box are stored by [Sing it] (or the note field), with it. With
    /// no stored words nothing is written: the picker's value waits here for the first write.
    public func setLanguage(_ code: String) {
        let next = LyricLanguage.stored(code)
        guard next != language else { return }
        language = next
        refusal = nil
        noteWord = nil
        if let clipID, let stored = located?.clip.lyrics, stored.language != next {
            do {
                try lyrics.setClipLyrics(clipId: clipID, text: stored.text, language: next, undoLabel: Self.undoLabel)
            } catch {
                refusal = Self.words(error)
            }
        }
        refresh()
    }

    // MARK: The note field (design §3.1)

    /// A note (or its chip) clicked in the strip: the note field, or — while the Expression card is open — the
    /// card's note pick.
    public func tapNote(_ id: UUID) {
        if expression.isExpanded {
            expression.toggleNote(id)
        } else {
            beginNoteWord(noteID: id)
        }
    }

    /// A chip clicked: its first note.
    public func tapChip(_ chipID: Int) {
        guard let first = preview.chips.first(where: { $0.id == chipID })?.noteIDs.first else { return }
        tapNote(first)
    }

    /// Opens "Word on this note" over `noteID`. The field edits the STORED words (`setNoteWord`), so a changed box
    /// is stored first ("Set Lyrics", its own undo step), but never words the planner refuses.
    public func beginNoteWord(noteID: UUID) {
        guard let clip = located?.clip, preview.notes.contains(where: { $0.id == noteID }) else { return }
        refusal = nil
        let boxed = ClipLyrics.normalized(ClipLyrics(text: text, language: LyricLanguage.stored(language)))
        if boxed != clip.lyrics {
            if let reason = preview.refusal {
                noteWord = SingNoteWordField(noteID: noteID, draft: "", original: "", refusal: reason, canCommit: false)
                return
            }
            do {
                try writeLyricsIfChanged()
            } catch {
                noteWord = SingNoteWordField(noteID: noteID, draft: "", original: "", refusal: Self.words(error),
                                             canCommit: false)
                return
            }
        }
        guard located?.clip.lyrics != nil else {
            noteWord = SingNoteWordField(noteID: noteID, draft: "", original: "",
                                         refusal: LyricEditRefusal.noText.sentence, canCommit: false)
            return
        }
        noteWord = SingNoteWordField.opening(for: noteID, in: preview)
    }

    public func setNoteWordDraft(_ draft: String) {
        noteWord?.draft = draft
    }

    /// Return (`advance: false`) or Tab (`advance: true`): `setNoteWord`, ONE undo step "Type Word"; the box takes
    /// the store's text at once. `+` and an empty field both hold the word before (the store's rule). A refusal keeps
    /// the field open with the sentence under it.
    public func commitNoteWord(advance: Bool) {
        guard let field = noteWord, let clipID else { return }
        guard field.canCommit else { return }
        if field.draft != field.original {
            do {
                let result = try lyrics.setNoteWord(clipId: clipID, noteId: field.noteID, word: field.draft,
                                                    dryRun: false)
                text = result.text
            } catch {
                noteWord?.refusal = Self.words(error)
                return
            }
            refresh()
        }
        if advance, let next = noteAfter(field.noteID) {
            beginNoteWord(noteID: next)
        } else {
            noteWord = nil
        }
    }

    public func cancelNoteWord() { noteWord = nil }

    private func noteAfter(_ id: UUID) -> UUID? {
        guard let index = preview.notes.firstIndex(where: { $0.id == id }), index + 1 < preview.notes.count else {
            return nil
        }
        return preview.notes[index + 1].id
    }

    // MARK: Singing without words (design §8.1)

    func refreshWordless(_ clip: Clip?) {
        guard let clip, clip.isMIDI else {
            wordlessTexts = []
            wordlessOffered = false
            return
        }
        let counts = WordlessLyrics.phraseNoteCounts(of: clip)
        var texts = Set<String>()
        for sound in WordlessLyrics.Sound.allCases {
            for perNote in [false, true] {
                texts.insert(WordlessLyrics.text(sound: sound, phraseNoteCounts: counts, perNote: perNote))
            }
        }
        texts.remove("")
        wordlessTexts = texts
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        wordlessOffered = !texts.isEmpty && (typed.isEmpty || texts.contains(typed))
    }

    public func setWordlessPerNote(_ perNote: Bool) { wordlessPerNote = perNote }

    /// "Ooh" / "Aah" / "Mm": `WordlessLyrics` writes the TEXT (the one generator), stored through THE lyrics write
    /// ("Set Lyrics", one undo step), so the box shows it and the person can edit it. A clip with no notes is
    /// refused in the wire's words (`SingWire.wordlessText`: no notes), never turned into a blank that clears.
    public func singWordless(_ sound: WordlessLyrics.Sound) {
        guard let clipID, let clip = located?.clip else { return }
        refusal = nil
        noteWord = nil
        let generated = WordlessLyrics.text(for: clip, sound: sound, perNote: wordlessPerNote)
        guard !generated.isEmpty else {
            refusal = SingPlanRefusal.noNotes.sentence
            return
        }
        let after = ClipLyrics.normalized(ClipLyrics(text: generated, language: LyricLanguage.stored(language)))
        if after != clip.lyrics {
            do {
                try lyrics.setClipLyrics(clipId: clipID, text: generated, language: language,
                                         undoLabel: Self.undoLabel)
            } catch {
                refusal = Self.words(error)
                return
            }
        }
        text = generated
        refresh()
    }

    // MARK: Write words for me (design §8.3)

    /// Offered only with a writer and a melody clip.
    public var canWriteWords: Bool { makeWriter != nil && located?.clip.isMIDI == true }

    /// Why [Write] is dark, or nil.
    public var writeWordsDisabledReason: String? {
        if writeWords.isWriting { return SingCopy.writingWords }
        if writeWords.theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SingCopy.writeWordsThemePlaceholder
        }
        return nil
    }

    public func openWriteWords() {
        writeWords.isOpen = true
        writeWords.notice = nil
    }

    public func closeWriteWords() {
        guard !writeWords.isWriting else { return }
        writeWords = SingWriteWordsState()
    }

    public func setWriteWordsTheme(_ theme: String) { writeWords.theme = theme }

    /// [Write]: `LyricsFit.write` (the function `ai.writeLyrics {fitClipId}` calls), whose reply is checked against
    /// the tune and asked again once. The words go INTO THE BOX; nothing is stored (§8.3): [Sing it] or the note
    /// field stores them. Lines that still do not fit are named in §14's sentence (`LyricsFit.Copy.notFit`).
    public func writeWordsForMe() async {
        guard let makeWriter, let clip = located?.clip, writeWordsDisabledReason == nil else { return }
        let theme = writeWords.theme.trimmingCharacters(in: .whitespacesAndNewlines)
        writeWords.isWriting = true
        writeWords.notice = nil
        defer { writeWords.isWriting = false }
        let writer: any LyricsGenerating
        do {
            writer = try makeWriter()
        } catch {
            writeWords.notice = Self.words(error)
            return
        }
        let code = LyricLanguage.stored(language)
        do {
            let outcome = try await LyricsFit.write(LyricsWriteRequest(prompt: theme, language: code), clip: clip,
                                                    language: code, tempoMap: store.transport.tempoMap, writer: writer)
            guard clipID == clip.id else { return }   // the sheet moved on while the writer worked
            setText(outcome.result.lyrics)
            if outcome.report.allFit {
                writeWords.isOpen = false
            } else {
                writeWords.notice = LyricsFit.Copy.notFit(lines: outcome.report.lines.filter { !$0.fits }.map(\.phrase))
            }
        } catch {
            writeWords.notice = Self.words(error)
        }
    }

    // MARK: Harmony (design §4.1)

    /// The menu's entries: the three intervals, and "Sing the chord's other notes" only when the tune has chords.
    /// ("Sing my other melody…" is a submenu over `otherMelodies`.)
    public var harmonyChoices: [SingHarmonyChoice] {
        [.thirdAbove, .sixthBelow, .thirdBelow] + (tuneHasChords ? [.chordNotes] : [])
    }

    /// Why [Add a harmony] is dark: §14 "Too many parts", from the coordinator's own refusal.
    public var addHarmonyDisabledReason: String? {
        guard harmonyParts.count >= SingJobPart.maximumCount else { return nil }
        return SingScreenWords.sentence(SingJobError.tooManyParts(maximum: SingJobPart.maximumCount))
    }

    public func addHarmony(_ choice: SingHarmonyChoice) {
        guard addHarmonyDisabledReason == nil else { return }
        if case .chordNotes = choice, !tuneHasChords { return }
        harmonyParts.append(SingHarmonyPart(kind: choice.kind))
        refresh()
    }

    public func removeHarmony(_ id: UUID) {
        harmonyParts.removeAll { $0.id == id }
        refresh()
    }

    /// A part's own voice (nil = the lead's).
    public func setHarmonyVoice(_ partID: UUID, voiceID: String?) {
        guard let index = harmonyParts.firstIndex(where: { $0.id == partID }) else { return }
        harmonyParts[index].voiceID = voiceID
        refresh()
    }

    /// The key picker (§14 "Key unknown": "Pick the key"); nil = work it out from the song again.
    public func setHarmonyKey(_ key: SongKey?) {
        givenKey = key
        refresh()
    }

    /// The parts as ONE request's `SingJobRequest.parts` (design §4.4), each voice through `SingVoiceLibrary.ownVoice`.
    var harmonyJobParts: [SingJobPart] {
        harmonyParts.map { part in
            SingJobPart(part.kind, voice: part.voiceID.flatMap { id in voices.first { $0.id == id } }
                .map { jobVoice(for: $0) })
        }
    }

    func refreshHarmony(_ found: (track: Track, clip: Clip)?) {
        guard let found else {
            harmonyRows = []
            harmonyKey = .notNeeded
            tuneHasChords = false
            otherMelodies = []
            return
        }
        let tracks = store.tracks
        let tempo = store.transport.tempoMap
        tuneHasChords = SingHarmony.tuneHasChords(clip: found.clip, on: found.track, tracks: tracks)
        otherMelodies = SingHarmony.otherMelodies(excluding: found.clip.id, tracks: tracks)
        harmonyKey = SingHarmony.keyState(kinds: harmonyParts.map(\.kind), given: givenKey, tracks: tracks,
                                          tempoMap: tempo)
        let leadShift = height?.octaveShift ?? 0
        harmonyRows = harmonyParts.enumerated().map { offset, part in
            let voice = part.voiceID.flatMap { id in voices.first { $0.id == id } } ?? selectedVoice
            return SingHarmony.row(part: part, index: offset + 1, clip: found.clip, track: found.track,
                                   tracks: tracks, tempoMap: tempo, givenKey: givenKey, voiceName: voice.name,
                                   voiceRange: jobVoice(for: voice).range, leadOctaveShift: leadShift)
        }
    }

    // MARK: The playback glow (design §8.2)

    /// The chip under the playhead while the song plays: a LOOKUP over the chips the last derivation made, never a
    /// derivation (`derivationCount` does not move). The view that reads it is the strip's own, so only the strip
    /// redraws at the playhead's rate.
    public var playingChipID: Int? {
        let beat: Double
        if let staged = stagedPlayheadBeat {
            beat = staged
        } else {
            guard store.transport.isPlaying else { return nil }
            beat = store.transport.positionBeats
        }
        return preview.chipID(atClipBeat: beat - derivedClipStartBeat)
    }

    public var isTransportPlaying: Bool { store.transport.isPlaying }

    /// "Play the tune": the transport's own seek and play, from the clip's first beat (the `playSungTake` shape).
    public func playTune() {
        guard let clip = located?.clip else { return }
        refusal = nil
        if store.transport.isPlaying { store.stop() }
        do {
            try store.seek(toBeats: clip.startBeat)
        } catch {
            refusal = Self.words(error)
            return
        }
        store.play()
    }

    public func stopTune() { store.stop() }

    /// A screenshot-only playhead, clip-relative beats (`debug.singScreens`); nil clears it.
    public func stagePlayhead(clipBeat: Double?) {
        stagedPlayheadBeat = clipBeat.map { $0 + derivedClipStartBeat }
    }
}
