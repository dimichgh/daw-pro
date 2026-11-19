import CoreGraphics
import Foundation

// vf-2 (design `docs/design/2026-10-12-piano-roll-words.md` §5, Lane D): the Sing sheet's word strip, laid out by THE
// SAME FUNCTION as the piano roll's Words lane (`PianoRollWordLane.layout`): two text rows, a dot when a word has no
// room, never truncated, never overlapping. The strip used to squeeze the whole clip into the sheet's width and floor
// every chip at 18 pt, so on a long clip with short notes the chips overlapped as truncated circles (vf-2). Now it
// scrolls sideways instead, never narrower than `minPixelsPerBeat`.
//
// Pure and nonisolated: the preview (the sheet's one derivation), the visible width and a width table in; every number
// the strip draws or hit-tests with out. `SingWordStrip` (DAWApp) only renders this, so everything a test pins lives
// here, where a plant can reach it.

/// Where the Sing sheet's strip draws its words and notes, and what a click on it means.
public struct SingWordStripLayout: Equatable, Sendable {

    // MARK: Constants

    /// The strip's height. Unchanged by vf-2, so the sheet's height budget (`SingCardLayout`) does not move.
    public static let height: CGFloat = 54
    /// The strip never squeezes the tune below this many points per beat; past it the strip scrolls sideways.
    /// Design §7.3's measurable default. [A]
    public static let minPixelsPerBeat: CGFloat = 24
    /// The words' band at the top: the piano roll's Words lane, row for row (`PianoRollWordLane.rowTop`, `dotRow`).
    public static let wordBandHeight: CGFloat = PianoRollWordLane.laneHeight
    /// A note's bar: this tall, its top between `barTop` (the highest note) and `barTop + barTravel` (the lowest).
    public static let barHeight: CGFloat = 3
    public static let barTop: CGFloat = 36
    public static let barTravel: CGFloat = 12
    /// A note's click column is at least this wide (thin notes stay clickable), from its onset rightwards.
    public static let noteColumnMinWidth: CGFloat = 8
    /// "Word on this note", drawn over the word band at its note.
    public static let fieldSize = CGSize(width: 132, height: 20)
    /// The space each side of a word inside its chip. The width table holds whole CHIPS (text + padding), so the
    /// layout's no-overlap rule holds for what is painted, not just for the letters.
    public static let chipPadding: CGFloat = 3
    /// A held word's line, at the word band's bottom, and the tick at each held note's onset.
    public static let holdLineY: CGFloat = PianoRollWordLane.laneHeight - PianoRollWordLane.holdLineWidth

    // MARK: Values

    /// One note's bar, by id.
    public struct NoteFrame: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var rect: CGRect

        public init(id: UUID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// What a click on the strip lands on.
    public enum Target: Equatable, Sendable {
        /// A word, a hyphen part or a dot: the chip with this id (`SingWordChip.id`, the word's reading order).
        case word(Int)
        /// A note's column under the words.
        case note(UUID)
    }

    /// The span the strip draws, in beats (today's rule: the clip's length, stretched to its last note's end).
    public var lengthBeats: Double
    /// `max(minPixelsPerBeat, visible width / lengthBeats)`: a short tune still fills the strip.
    public var pixelsPerBeat: CGFloat
    /// The scrolled content's width: never narrower than the visible width.
    public var contentWidth: CGFloat
    /// The melody's bars, in the preview's (melody) order.
    public var noteFrames: [NoteFrame]
    /// The words, as the lane layout reads them (`words(of:)`).
    public var words: PianoRollWords
    /// What the strip draws: `PianoRollWordLane.layout` over `words` and the bars. Never a placement of its own.
    public var items: [PianoRollWordLane.Item]

    public init(preview: SingSheetPreview, visibleWidth: CGFloat, textWidths: [String: CGFloat]) {
        let length = max(preview.lengthBeats, preview.notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 1, 1)
        let ppb = Self.pixelsPerBeat(lengthBeats: length, visibleWidth: visibleWidth)
        let pitches = preview.notes.map(\.pitch)
        let low = pitches.min() ?? 60
        let high = max(pitches.max() ?? 72, low + 1)
        lengthBeats = length
        pixelsPerBeat = ppb
        contentWidth = max(visibleWidth, ppb * CGFloat(length))
        noteFrames = preview.notes.map { note in
            let y = Self.barTop + Self.barTravel * (1 - CGFloat(note.pitch - low) / CGFloat(high - low))
            return NoteFrame(id: note.id, rect: CGRect(x: ppb * CGFloat(note.startBeat), y: y,
                                                       width: max(2, ppb * CGFloat(note.lengthBeats) - 1),
                                                       height: Self.barHeight))
        }
        words = Self.words(of: preview)
        items = PianoRollWordLane.layout(words: words, noteRects: noteFrames.map { (id: $0.id, rect: $0.rect) },
                                         textWidths: textWidths)
    }

    /// The floor: the visible width spread over the tune, but never below `minPixelsPerBeat`.
    public static func pixelsPerBeat(lengthBeats: Double, visibleWidth: CGFloat) -> CGFloat {
        max(minPixelsPerBeat, visibleWidth / CGFloat(max(lengthBeats, 1)))
    }

    /// The preview's chips as the lane layout reads them: each chip IS one word of the sheet's derivation
    /// (`SingPlanner.assignment` over the words in the box), so `index` is the chip's id, and the typed text, hyphen
    /// parts, notes, hold and phrase are the planner's. Two things are deliberately not carried: `refusal` (the sheet
    /// says why it cannot sing elsewhere, and can still show words when only the HEIGHT is refused, while a refused
    /// `PianoRollWords` has none) and `heldSentence` (the strip's tooltip is its own).
    public static func words(of preview: SingSheetPreview) -> PianoRollWords {
        PianoRollWords(items: preview.chips.map {
            PianoRollWords.Word(index: $0.id, typed: $0.text, parts: $0.parts, noteIDs: $0.noteIDs, held: $0.held,
                                phrase: $0.phrase)
        }, unsungNoteIDs: preview.unsungNoteIDs, refusal: nil, language: nil,
           melodyNoteIDs: preview.notes.map(\.id))
    }

    /// The texts to measure, once each, into the width table (`chipWidth(textWidth:)` per text).
    public static func texts(of preview: SingSheetPreview) -> Set<String> {
        PianoRollWordLane.texts(of: words(of: preview))
    }

    /// A chip's width from its text's measured width: whole points, plus the padding both sides.
    public static func chipWidth(textWidth: CGFloat) -> CGFloat {
        ceil(textWidth) + 2 * chipPadding
    }

    /// The bars as the lane layout takes them.
    public var noteRects: [(id: UUID, rect: CGRect)] {
        noteFrames.map { (id: $0.id, rect: $0.rect) }
    }

    /// The top of an item's chip (or dot), from the strip's top: the lane's own rows.
    public static func top(of item: PianoRollWordLane.Item) -> CGFloat {
        PianoRollWordLane.rowTop(item.row)
    }

    // MARK: The note field

    /// "Word on this note" over `noteID`: just left of the note, kept inside the content. nil for a note the strip
    /// does not draw.
    public func fieldRect(noteID: UUID) -> CGRect? {
        noteFrames.first { $0.id == noteID }.map(fieldRect(for:))
    }

    /// The field's frame over `note` (also where the strip scrolls to show that note's field).
    public func fieldRect(for note: NoteFrame) -> CGRect {
        let x = min(max(0, note.rect.minX - 4), max(0, contentWidth - Self.fieldSize.width))
        return CGRect(origin: CGPoint(x: x, y: 0), size: Self.fieldSize)
    }

    // MARK: Clicks

    /// What a click at `point` (content coordinates: the scrolled strip's own x, the strip's y) picks — the strip's
    /// ONE tap, resolved by arithmetic:
    /// - inside the open note field: nothing (the field takes its own clicks);
    /// - in the word band: the word, part or dot under it (`PianoRollWordLane.hitTest`, the lane's own rule), as its
    ///   chip — a chip opens (or picks) its FIRST note, exactly as a click on the old chip did;
    /// - under the words: the note whose column holds x. A column runs from the note's onset, at least
    ///   `noteColumnMinWidth` wide, and where two overlap the LATER note wins (it was drawn on top).
    public func target(at point: CGPoint, fieldNoteID: UUID? = nil) -> Target? {
        if let fieldNoteID, let field = fieldRect(noteID: fieldNoteID), field.contains(point) { return nil }
        guard point.y >= 0, point.y <= Self.height else { return nil }
        if point.y < Self.wordBandHeight {
            return PianoRollWordLane.hitTest(items, at: point).map { .word($0.wordIndex) }
        }
        for note in noteFrames.reversed()
        where point.x >= note.rect.minX && point.x < note.rect.minX + max(Self.noteColumnMinWidth, note.rect.width) {
            return .note(note.id)
        }
        return nil
    }

    // MARK: Tooltips

    /// What hovering an item says: its whole word (a dot and a hyphen part name the word they belong to), and for a
    /// word held across notes, how many.
    public func tooltip(for item: PianoRollWordLane.Item) -> String {
        // A chip's id is its reading order, so the word is usually at that position; the search is the backstop.
        let word = words.items.indices.contains(item.wordIndex) && words.items[item.wordIndex].index == item.wordIndex
            ? words.items[item.wordIndex] : words.items.first { $0.index == item.wordIndex }
        guard let word else { return item.text }
        return word.held ? "'\(word.typed)' is held across \(word.noteIDs.count) notes" : word.typed
    }
}
