import AIServices
import CoreGraphics
import DAWCore
import Foundation
import Observation

// p2-sing-pr-words (design `docs/design/2026-10-12-piano-roll-words.md`, Lane A): the words on notes, in the piano
// roll. The headless half — what the Words lane draws, the field it types in, and whether a sung vocal still sings
// these words. `PianoRollView` (Lane B) owns the drawing and the gestures; everything it decides with lives here,
// where it can be tested without a window.
//
// ⭐ D1 — THE TEXT STAYS THE ONLY TRUTH. Nothing here stores a word on a note. The lane draws ONE derivation,
// `SingPlanner.assignment(for:tempoMap:)` — the answer `clip.getLyrics` gives (`SingWire.getLyrics`) and the one the
// singer sings — and every word typed in the field goes through the store's one writer (`ProjectStore.setNoteWord` →
// `setClipLyrics`, journaled with no coalescing key, so a word edit can never fold into a note edit's undo step).

// MARK: - The words (pure)

/// The words the lane draws for one clip: THE ONE DERIVATION, `SingPlanner.assignment`, never a second rule.
///
/// Mirrors `clip.getLyrics` exactly (`SingWire.getLyrics`): an audio clip or a clip with no lyrics has no words and NO
/// refusal (the lane's empty state); a clip WITH lyrics reports every refusal of the derivation — `.noWords` too (a
/// text of only `+` marks) — as `refusal`, in the wire's `problem.sentence` words, and then draws NO words at all.
/// Never the last good words: a stale record that looks valid is this tree's characteristic failure (design §2.4).
public struct PianoRollWords: Equatable, Sendable {

    /// One word of the text, with the notes it sings (`AssignedLyricWord`, reduced to what the lane needs).
    public struct Word: Equatable, Sendable {
        /// Reading order, 0-based: the `wordIndex` of the lane's items.
        public var index: Int
        /// The word as typed, punctuation kept ("star,"): what a single-part word draws (the Sing sheet's chip text,
        /// and `clip.getLyrics`'s `words[].text`).
        public var typed: String
        /// The hyphen parts ("twin", "kle"); one element for a word with no hyphen. A word with two or more draws
        /// each part on its own note.
        public var parts: [String]
        /// The notes it sings, in order. Never empty.
        public var noteIDs: [UUID]
        /// Rule 5.2 only: the derivation made this word hold across spare notes nobody else needed
        /// (`AssignedLyricWord.held`). A hold the user typed (`+`) is NOT this — the lane draws both the same
        /// (`PianoRollWordLane.heldNoteCount`); only this one carries `heldSentence`.
        public var held: Bool
        /// The breath phrase (0-based) its notes are in.
        public var phrase: Int
        /// The tooltip of an automatic hold: `LyricWarning.heldWord`'s sentence, the same words the Sing sheet's
        /// warnings and `clip.getLyrics`'s `warnings` use. nil unless `held`.
        public var heldSentence: String?

        public init(index: Int, typed: String, parts: [String], noteIDs: [UUID], held: Bool, phrase: Int,
                    heldSentence: String? = nil) {
            self.index = index
            self.typed = typed
            self.parts = parts
            self.noteIDs = noteIDs
            self.held = held
            self.phrase = phrase
            self.heldSentence = heldSentence
        }
    }

    /// Every placed word, in reading order. Empty when the clip has no lyrics or the derivation refused.
    public var items: [Word]
    /// Melody notes no word reaches (flow mode, fewer words than phrases): the lane draws a faint line under them.
    public var unsungNoteIDs: [UUID]
    /// Why no word is drawn, in `clip.getLyrics`'s `problem.sentence` words; nil when the words fit (or there are none).
    public var refusal: String?
    /// The clip's language code (`ClipLyrics.language`; nil = English).
    public var language: String?
    /// The melody the singer follows (`SingPlanner.melody(of:)`: one note per onset, chord notes dropped), in order:
    /// the order Tab and ⇧Tab walk, the Sing sheet's `noteAfter` order. The SAME melody the assignment is built on.
    public var melodyNoteIDs: [UUID]

    public static let empty = PianoRollWords(items: [], unsungNoteIDs: [], refusal: nil, language: nil,
                                             melodyNoteIDs: [])

    public init(items: [Word], unsungNoteIDs: [UUID], refusal: String?, language: String?, melodyNoteIDs: [UUID]) {
        self.items = items
        self.unsungNoteIDs = unsungNoteIDs
        self.refusal = refusal
        self.language = language
        self.melodyNoteIDs = melodyNoteIDs
    }

    /// THE derivation. Pure: the clip value and the tempo map in, the words out. `PianoRollWordsModel` calls it once
    /// per input change (its `derivationCount` spy); nothing calls it per frame.
    ///
    /// `tempoMap` only times rule 7's "squeezed word" warning; word PLACEMENT never depends on it (design §1.1).
    public static func derive(clip: Clip, tempoMap: TempoMap) -> PianoRollWords {
        var words = PianoRollWords(items: [], unsungNoteIDs: [], refusal: nil, language: clip.lyrics?.language,
                                   melodyNoteIDs: SingPlanner.melody(of: clip).notes.map(\.id))
        // `SingWire.getLyrics`'s guard, exactly: no MIDI, or no lyrics → nothing to place and nothing refused.
        guard clip.isMIDI, clip.lyrics != nil else { return words }
        do throws(LyricRefusal) {
            let assignment = try SingPlanner.assignment(for: clip, tempoMap: tempoMap)
            words.items = assignment.words.enumerated().map { index, assigned in
                Word(index: index, typed: assigned.word.typed, parts: assigned.word.parts, noteIDs: assigned.noteIDs,
                     held: assigned.held, phrase: assigned.phrase,
                     heldSentence: assigned.held
                        ? LyricWarning.heldWord(word: assigned.word.sung, spareNotes: assigned.heldNotes,
                                                line: assigned.word.line).sentence
                        : nil)
            }
            words.unsungNoteIDs = assignment.unsungNoteIDs
        } catch {
            // `clip.getLyrics`'s `problem.sentence`, through the same wrapper the wire uses.
            words.refusal = SingJobError.planRefused(.lyrics(error)).errorDescription ?? error.sentence
        }
        return words
    }

    /// Whether a clip on `track` gets a Words lane at all (design §2.3): a MIDI clip on a track the SINGER would sing —
    /// `ProjectTranspose.isDrumTrack`, the planner's own drum rule (`SingPlanner.plan`), never the MIDI-export
    /// `isDrumKit` predicate (design F2: that one says "not drums" for our pads machine, which the singer refuses).
    /// The roll's Steps mode is the view's own state and is ANDed by the view.
    public static func isEligible(clip: Clip, on track: Track) -> Bool {
        clip.isMIDI && !ProjectTranspose.isDrumTrack(track)
    }

    /// The word whose notes include `noteID`, or nil (a chord note the singer drops, an unsung note, no words).
    public func word(singing noteID: UUID) -> Word? {
        items.first { $0.noteIDs.contains(noteID) }
    }
}

/// The roll's words open a note field by the Sing sheet's own rule (`SingNoteWordField.opening(for:in:)`).
extension PianoRollWords: SingNoteWordSource {
    public var noteWordEntries: [SingNoteWordEntry] {
        items.map { SingNoteWordEntry(text: $0.typed, noteIDs: $0.noteIDs) }
    }
}

// MARK: - Has the sung vocal been sung with these words? (design §3.3, D7)

/// Whether a sung vocal made from a clip still sings the clip's words. Pure; ContentView passes the cheap VALUE
/// (`leadLyrics`, an O(tracks) scan, no derivation) and `PianoRollWordsModel` compares only when it changes.
///
/// Only LEAD takes count (`partRole` nil — a take sung on its own — or `"lead"`): a harmony part sung from another
/// clip records THAT clip's words, and the notice names only the lead (design §3.3).
public enum SungWordsFreshness {

    /// The words each lead take sung from `clipID` was planned with (`SungVocalProvenance.lyricsText`), in track order.
    public static func leadLyrics(for clipID: UUID, in tracks: [Track]) -> [String] {
        tracks.compactMap { track in
            guard let take = track.sungVocalProvenance, take.sourceClipId == clipID,
                  take.partRole == nil || take.partRole == SungVocalProvenance.PartRole.lead else { return nil }
            return take.lyricsText
        }
    }

    /// True when a lead take sang different words from the clip's words now (`clip.lyrics?.text ?? ""`): "The words
    /// changed since this vocal was sung." False with no lead take at all.
    public static func isStale(leadLyrics: [String], clipText: String) -> Bool {
        leadLyrics.contains { $0 != clipText }
    }
}

// MARK: - The model the roll owns

/// What one commit of the word field did. The roll engages (marker m23-al R13) ONLY on `changed` — a funnel never
/// engages on a no-op (the `applyStartFromBeat` rule) — and selects `fieldNoteID` when the field moved (Tab / ⇧Tab).
public struct PianoRollWordCommit: Equatable, Sendable {
    /// The store changed the clip's text (`LyricNoteWordResult.changed`).
    public var changed: Bool
    /// Why nothing was written, in the store's own words. Return / Tab keep the field open with it; a commit on focus
    /// loss closes the field and hands the sentence back for the roll's amber notice.
    public var refusal: String?
    /// The note the field is open on after the commit (Tab's next note, or the same note after a refusal); nil when
    /// the field closed.
    public var fieldNoteID: UUID?

    public init(changed: Bool, refusal: String?, fieldNoteID: UUID?) {
        self.changed = changed
        self.refusal = refusal
        self.fieldNoteID = fieldNoteID
    }

    /// No field was open: nothing happened (the guard that stops Return-then-blur committing twice).
    public static let nothing = PianoRollWordCommit(changed: false, refusal: nil, fieldNoteID: nil)
}

/// The Words lane's model (design §2.4, §2.6). Owned by the roll as `@State` and recreated per clip by the roll's
/// `.id(clip.id)`.
///
/// ⭐ ONE DERIVATION PER INPUT CHANGE, NEVER PER FRAME. `update(clip:tempoMap:leadLyrics:)` is the roll's
/// `.onChange(of:initial:)` path; it derives only when the derivation's inputs — the clip's notes, lyrics, length and
/// start, and the tempo map — differ from the ones it last derived from (the `PianoRollModel.needsReseed` idempotence
/// shape). Laying out (`layout(noteRects:textWidths:)`) is arithmetic over the last derivation and may run on every
/// drag frame or zoom step. `derivationCount` is the spy that proves it.
///
/// ⭐ THE OWN-COMMIT ECHO. A word commit derives AT ONCE from the text the store returned
/// (`LyricNoteWordResult.text`), stored the way the store stores it (`ClipLyrics.withText`, then `normalized` —
/// `ProjectStore.setClipLyrics`), so Tab opens the next note on fresh words; the store's change then reaches the roll
/// one body pass later through `.onChange`, carrying inputs equal to the ones just derived, and is a no-op. Without
/// that memo the echo would derive a second time AND close the field Tab just opened.
///
/// ⭐ AN OUTSIDE CHANGE CLOSES THE FIELD WITHOUT WRITING (the m18-i cancel rule): an agent's edit, undo / redo, a note
/// drag — anything that changes the derivation's inputs other than this model's own commit.
@MainActor
@Observable
public final class PianoRollWordsModel {

    /// The store's one word writer for this clip: `ProjectStore.setNoteWord(clipId:noteId:word:)`, wired by the
    /// caller (the view is store-free). Throws the store's refusals (`ProjectError`, `LyricEditRefusal`).
    public typealias NoteWordWriter = @MainActor (_ noteID: UUID, _ word: String) throws -> LyricNoteWordResult

    /// Which way a commit moves the field: Return / focus loss (`none`), Tab (`next`), ⇧Tab (`previous`).
    public enum Advance: String, Sendable, CaseIterable {
        case none, next, previous
    }

    /// The last derivation. What the lane draws.
    public private(set) var words: PianoRollWords = .empty
    /// A lead take sung from this clip sang other words (`SungWordsFreshness`): the lane's "Sing again…" notice.
    public private(set) var isStale = false
    /// The open field, or nil. The roll overlays a `TextField` on the lane while it is set.
    public private(set) var field: SingNoteWordField?

    /// How many times `PianoRollWords.derive` ran. A spy, never rendered: `@ObservationIgnored` so bumping it
    /// invalidates nothing (the derivation it counts already changes `words`, which IS observed).
    @ObservationIgnored public private(set) var derivationCount = 0

    /// The inputs of the last derivation (the memo the echo and the outside-change rule compare against).
    @ObservationIgnored private var derivedFrom: DerivationInputs?
    /// The clip value and tempo map of the last derivation: a commit re-derives from them with the store's new text.
    @ObservationIgnored private var lastClip: Clip?
    @ObservationIgnored private var lastTempoMap: TempoMap?
    /// The freshness inputs last compared.
    @ObservationIgnored private var freshnessFrom: FreshnessInputs?

    private struct DerivationInputs: Equatable {
        var notes: [MIDINote]?
        var lyrics: ClipLyrics?
        var lengthBeats: Double
        var startBeat: Double
        var tempoMap: TempoMap

        init(_ clip: Clip, _ tempoMap: TempoMap) {
            notes = clip.notes
            lyrics = clip.lyrics
            lengthBeats = clip.lengthBeats
            startBeat = clip.startBeat
            self.tempoMap = tempoMap
        }
    }

    private struct FreshnessInputs: Equatable {
        var leadLyrics: [String]
        var clipText: String
    }

    public init() {}

    // MARK: Inputs

    /// The roll's `.onChange(of:initial:)` path: the clip VALUE the roll was handed, the song's tempo map, and
    /// `SungWordsFreshness.leadLyrics(for:in:)`. Derives only when the derivation's inputs changed — and then closes
    /// an open field WITHOUT writing (the change came from outside this model). Answers whether it derived.
    @discardableResult
    public func update(clip: Clip, tempoMap: TempoMap, leadLyrics: [String]) -> Bool {
        var derived = false
        if DerivationInputs(clip, tempoMap) != derivedFrom {
            rederive(clip, tempoMap)
            field = nil
            derived = true
        }
        refreshFreshness(FreshnessInputs(leadLyrics: leadLyrics, clipText: clip.lyrics?.text ?? ""))
        return derived
    }

    /// The lane's items for the roll's live note rects (`PianoRollModel.noteRects()`, the draft's — words ride with
    /// their notes during a drag) and the text widths measured once per derivation. Arithmetic only: never derives.
    public func layout(noteRects: [(id: UUID, rect: CGRect)], textWidths: [String: CGFloat]) -> [PianoRollWordLane.Item] {
        PianoRollWordLane.layout(words: words, noteRects: noteRects, textWidths: textWidths)
    }

    // MARK: The field (design §2.6)

    /// True when a field can open at all: the clip has stored words. With none the lane is in its empty state and the
    /// field never opens (its "Add words…" goes to the Sing sheet, the one place a whole lyric is typed). Set by each
    /// derivation, and observed, so a view that draws the empty state from it redraws when words arrive.
    public private(set) var canOpenField = false

    /// Opens the field over `noteID` (a double-click on a note, the debug seam's `open`) by the Sing sheet's own rule
    /// (`SingNoteWordField.opening(for:in:)`): the word on its first note, `+` on a note it holds, empty with the "isn't
    /// sung" sentence on an unsung note. Two cases only the roll can reach, neither changing what a word "is":
    /// - a derivation that refused: the field opens with that sentence and cannot commit (the store would refuse
    ///   every edit with it: `LyricTextEdit.apply` step 1);
    /// - a note the singer drops (a chord's lower note; the sheet's strip never shows one): the "isn't sung" sentence.
    /// Answers the note the field opened on, or nil (no stored words, a note this clip does not have).
    @discardableResult
    public func openField(noteID: UUID) -> UUID? {
        guard canOpenField, lastClip?.notes?.contains(where: { $0.id == noteID }) == true else { return nil }
        var opened = SingNoteWordField.opening(for: noteID, in: words)
        if let refusal = words.refusal {
            opened.refusal = refusal
            opened.canCommit = false
        } else if !words.melodyNoteIDs.contains(noteID) {
            opened.refusal = LyricEditRefusal.noteNotSung(noteID: noteID).sentence
        }
        field = opened
        return noteID
    }

    /// A click on a word, a dot or a hyphen PART in the lane: the field opens on the word's FIRST note, so a part never
    /// lands on the "edit it in the words box" refusal (`LyricEditRefusal.noteInsideHyphenatedWord`).
    @discardableResult
    public func openField(wordIndex: Int) -> UUID? {
        guard words.items.indices.contains(wordIndex), let first = words.items[wordIndex].noteIDs.first else {
            return nil
        }
        return openField(noteID: first)
    }

    /// Return with notes selected (the key monitor's hand-off): the EARLIEST selected melody note, in melody order;
    /// with only chord notes selected, the earliest of those (the field then says the note isn't sung). nil when
    /// nothing opens.
    @discardableResult
    public func openField(selection: Set<UUID>) -> UUID? {
        if let melody = words.melodyNoteIDs.first(where: { selection.contains($0) }) {
            return openField(noteID: melody)
        }
        let earliest = (lastClip?.notes ?? []).filter { selection.contains($0.id) }
            .min { ($0.startBeat, -$0.pitch) < ($1.startBeat, -$1.pitch) }
        return earliest.flatMap { openField(noteID: $0.id) }
    }

    /// The field's text binding.
    public func setDraft(_ draft: String) {
        field?.draft = draft
    }

    /// Escape: close, write nothing.
    public func cancelField() {
        field = nil
    }

    /// Return (`.none`), Tab (`.next`) or ⇧Tab (`.previous`) — the roll's `commitWordField(advance:)` body. An
    /// unchanged field writes nothing; a changed one is ONE `write` ("Type Word", one undo step). On success the field
    /// moves to the next / previous melody note (closing past either end) or closes; on a refusal it STAYS open with
    /// the store's sentence and nothing moves.
    @discardableResult
    public func commitField(advance: Advance, write: NoteWordWriter) -> PianoRollWordCommit {
        commit(advance: advance, closingOnRefusal: false, write: write)
    }

    /// Focus left the field (a click elsewhere): commit, the rename-field rule. A refusal CLOSES the field and comes
    /// back for the roll's amber notice. With no field open (Return or Escape already closed it) nothing happens, so
    /// the blur that follows them can never commit twice.
    @discardableResult
    public func commitFieldOnFocusLoss(write: NoteWordWriter) -> PianoRollWordCommit {
        commit(advance: .none, closingOnRefusal: true, write: write)
    }

    private func commit(advance: Advance, closingOnRefusal: Bool, write: NoteWordWriter) -> PianoRollWordCommit {
        guard let current = field else { return .nothing }
        guard current.canCommit else {
            // The Sing sheet's rule: a field that cannot commit writes nothing; it already shows why. Focus loss just
            // closes it (nothing was refused just now, so there is nothing new to flash).
            if closingOnRefusal {
                field = nil
                return .nothing
            }
            return PianoRollWordCommit(changed: false, refusal: current.refusal, fieldNoteID: current.noteID)
        }
        var changed = false
        if current.draft != current.original {
            do {
                let result = try write(current.noteID, current.draft)
                if result.changed {
                    applyOwnWrite(text: result.text)
                    changed = true
                }
            } catch {
                let sentence = SingScreenWords.sentence(error)
                if closingOnRefusal {
                    field = nil
                    return PianoRollWordCommit(changed: false, refusal: sentence, fieldNoteID: nil)
                }
                field?.refusal = sentence
                return PianoRollWordCommit(changed: false, refusal: sentence, fieldNoteID: current.noteID)
            }
        }
        let melody = words.melodyNoteIDs
        let next: UUID?
        switch advance {
        case .none:
            next = nil
        case .next:
            next = melody.firstIndex(of: current.noteID).flatMap { $0 + 1 < melody.count ? melody[$0 + 1] : nil }
        case .previous:
            next = melody.firstIndex(of: current.noteID).flatMap { $0 > 0 ? melody[$0 - 1] : nil }
        }
        field = nil
        let opened = next.flatMap { openField(noteID: $0) }
        return PianoRollWordCommit(changed: changed, refusal: nil, fieldNoteID: opened)
    }

    // MARK: Derivation

    /// The model's own write landed: derive NOW from the text the store returned, stored the store's way, and record
    /// those inputs so the `.onChange` echo of the same clip is a no-op.
    private func applyOwnWrite(text: String) {
        guard var clip = lastClip, let tempoMap = lastTempoMap else { return }
        clip.lyrics = ClipLyrics.normalized(clip.lyrics?.withText(text) ?? ClipLyrics(text: text))
        rederive(clip, tempoMap)
        if let freshnessFrom {
            refreshFreshness(FreshnessInputs(leadLyrics: freshnessFrom.leadLyrics, clipText: clip.lyrics?.text ?? ""))
        }
    }

    private func rederive(_ clip: Clip, _ tempoMap: TempoMap) {
        derivationCount += 1
        words = PianoRollWords.derive(clip: clip, tempoMap: tempoMap)
        canOpenField = clip.lyrics != nil
        lastClip = clip
        lastTempoMap = tempoMap
        derivedFrom = DerivationInputs(clip, tempoMap)
    }

    private func refreshFreshness(_ inputs: FreshnessInputs) {
        guard inputs != freshnessFrom else { return }
        freshnessFrom = inputs
        isStale = SungWordsFreshness.isStale(leadLyrics: inputs.leadLyrics, clipText: inputs.clipText)
    }
}
