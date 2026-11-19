import CoreGraphics
import Foundation

// p2-sing-pr-words (design `docs/design/2026-10-12-piano-roll-words.md` §2.4, Lane A): WHERE each word of the Words
// lane is drawn. Pure and nonisolated: the words (`PianoRollWords`, derived once per change), the roll's live note
// rects and a text-width table in, the items out. Arithmetic only, so it may run on every drag frame and zoom step;
// it never derives (`PianoRollWordsModel.derivationCount` is the spy). The Sing sheet's strip (vf-2, Lane D) is meant
// to adopt the same function.
//
// ⭐ NEVER TRUNCATE, NEVER OVERLAP — the `PianoRollNoteLabel` "suppress, never truncate" law, applied to words. A
// word that does not fit in either text row becomes a DOT at its onset (its own band, so it cannot cover a word),
// and zooming in turns dots back into words: density follows fit, never a zoom threshold.
//
// ⚠️ WHAT ZOOMING IN PROMISES — AND WHAT IT DOES NOT (MEASURED). Design §6.1 asks that "more ppb never yields fewer
// full words". §2.4's placement rule (words in reading order, try row 0 then row 1) does NOT have that property, and
// no first-fit rule can: zooming in can let an early word fit that used to be a dot, and that word then takes the row
// two later words were sharing. Smallest case found (`PianoRollWordLaneLayoutTests.zoomingInCanCostAWordLaterOn`):
// five words on sixteenths, 4 full at 32 pt/beat, 3 at 48. A random probe (W10-PRWA, 2026-10-12) found 160 such cases
// in 300,000, and the SAME count with best-fit or worst-fit row choice. What DOES hold, with 0 violations in 300,000,
// and is pinned instead: (1) a lane with no dot keeps no dot at every larger zoom; (2) the first dot (left to right)
// never moves earlier. This file builds §2.4 as written; the stronger property needs a
// different rule (a maximum two-row interval selection), which would dot an EARLY word to save two later ones — a
// look question for the user, not this lane's call.

/// The Words lane's geometry and placement (design §2.4). Numbers marked [A] are the design's measurable defaults
/// (§7.3); a LOOK round may move them, the rules stay.
public enum PianoRollWordLane {

    // MARK: Constants

    /// The lane's height, under the note grid. [A]
    public static let laneHeight: CGFloat = 30
    /// The words' font size: SF Pro semibold (labels are SF Pro; mono is for numbers). [A]
    public static let fontSize: CGFloat = 10
    /// The two text rows, each this tall, stacked from the lane's top. [A]
    public static let rowHeight: CGFloat = 12
    /// How many text rows the lane staggers words over.
    public static let textRowCount = 2
    /// The row a dot is drawn in: its own band under the two text rows, so a dot can never cover a word.
    public static let dotRow = 2
    /// A word starts this far right of its first note's onset.
    public static let textInset: CGFloat = 2
    /// A text row is free for a word when the word starts at least this far past the row's last word's end.
    public static let rowGap: CGFloat = 4
    /// A word with no room in either row: a dot this wide (and tall), at its onset.
    public static let dotSize: CGFloat = 4
    /// The held-word line's thickness, at the lane's bottom. [A]
    public static let holdLineWidth: CGFloat = 1.5
    /// The tick at each held note's onset. [A]
    public static let holdTickHeight: CGFloat = 3
    /// The word field overlaid on the lane. [A]
    public static let fieldSize = CGSize(width: 140, height: 22)
    /// A text the width table does not hold is measured as this many points per character: a full em at 10 pt, so
    /// an estimate is never NARROWER than the text (a narrow estimate is an overlap). The view passes a table
    /// measured once per derivation (`texts(of:)`), so this is a backstop, not the path.
    public static let fallbackAdvance: CGFloat = 10

    /// The top of a row's band, from the lane's top: the two text rows, then the dot band.
    public static func rowTop(_ row: Int) -> CGFloat {
        CGFloat(row) * rowHeight
    }

    // MARK: Items

    public enum Kind: String, Equatable, Sendable {
        /// A whole word, drawn in full (its typed text, punctuation kept).
        case word
        /// One hyphen part of a word ("twin" of "twin-kle"), on its own note.
        case part
        /// A word with no room in either row: a dot at its onset. Its `text` is the word, for the tooltip.
        case dot
    }

    /// One thing the lane draws.
    public struct Item: Equatable, Sendable {
        /// The word's `PianoRollWords.Word.index`. A click on any item opens the field on that word's FIRST note.
        public var wordIndex: Int
        /// The note it sits on: the word's first note, or the part's own note.
        public var noteID: UUID
        /// What is drawn, in FULL: the word as typed, or the part. A dot carries its whole word (the tooltip).
        public var text: String
        public var kind: Kind
        /// Left edge, in the grid's x (content coordinates, the same space as the note rects).
        public var x: CGFloat
        /// The text's full width, or `dotSize`.
        public var width: CGFloat
        /// 0 or 1 for text, `dotRow` for a dot.
        public var row: Int
        /// A held word's line, from the onset of the note it starts holding from to the end of its last note; nil
        /// when nothing is held. A typed `+` and the automatic hold (rule 5.2) draw the same.
        public var holdFromX: CGFloat?
        public var holdToX: CGFloat?
        /// One tick at each HELD note's onset.
        public var holdTickXs: [CGFloat]

        public init(wordIndex: Int, noteID: UUID, text: String, kind: Kind, x: CGFloat, width: CGFloat, row: Int,
                    holdFromX: CGFloat? = nil, holdToX: CGFloat? = nil, holdTickXs: [CGFloat] = []) {
            self.wordIndex = wordIndex
            self.noteID = noteID
            self.text = text
            self.kind = kind
            self.x = x
            self.width = width
            self.row = row
            self.holdFromX = holdFromX
            self.holdToX = holdToX
            self.holdTickXs = holdTickXs
        }

        /// Right edge.
        public var maxX: CGFloat { x + width }
    }

    // MARK: What a word draws

    /// How many of `word`'s notes it HOLDS: the notes past its own syllables (one note, or one per hyphen part).
    /// Counted from the notes, not from `held`, so a typed `+` draws the same line as rule 5.2's automatic hold.
    public static func heldNoteCount(_ word: PianoRollWords.Word) -> Int {
        max(0, word.noteIDs.count - max(1, word.parts.count))
    }

    /// The texts the lane may draw for `words` — measure exactly these, once per derivation, into the table
    /// `layout` reads.
    public static func texts(of words: PianoRollWords) -> Set<String> {
        var out = Set<String>()
        for word in words.items {
            if word.parts.count > 1 { out.formUnion(word.parts) } else { out.insert(word.typed) }
        }
        return out
    }

    // MARK: Layout

    /// Places every word (design §2.4):
    /// - a word starts at its first note's onset x + `textInset`; a hyphenated word draws each PART at its own note's
    ///   onset;
    /// - pieces are placed left to right (by that x, reading order breaking ties); each tries row 0, then row 1, and a
    ///   row is free when the piece starts at least `rowGap` past the row's last end;
    /// - with neither free, the piece becomes a dot at its onset, in `dotRow`;
    /// - a word holding notes past its syllables carries its hold line and ticks (on its last part for a hyphenated
    ///   word, on its word or dot otherwise).
    /// Words are positioned by the rects handed in — the roll's DRAFT, so words ride with their notes during a drag —
    /// while WHICH word sits on which note is the last derivation (design §2.4 "During a live drag"). A word whose
    /// first note has no rect is skipped (it has nowhere to be drawn until the next derivation).
    public static func layout(words: PianoRollWords, noteRects: [(id: UUID, rect: CGRect)],
                              textWidths: [String: CGFloat]) -> [Item] {
        let rects = Dictionary(noteRects.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })

        struct Piece {
            var order: Int
            var item: Item
            var onsetX: CGFloat
            /// The whole word, for a dot's tooltip (a part's dot names its word, not just the part).
            var wordText: String
        }
        var pieces: [Piece] = []
        for word in words.items {
            let isHyphenated = word.parts.count > 1
            let syllables = isHyphenated ? min(word.parts.count, word.noteIDs.count) : 1
            let heldIDs = Array(word.noteIDs.dropFirst(syllables))
            var hold: (from: CGFloat, to: CGFloat, ticks: [CGFloat])?
            if !heldIDs.isEmpty, let holdStart = rects[word.noteIDs[syllables - 1]] {
                let held = heldIDs.compactMap { rects[$0] }
                if let last = held.last {
                    hold = (holdStart.minX, last.maxX, held.map(\.minX))
                }
            }
            for k in 0..<syllables {
                let noteID = word.noteIDs[k]
                guard let rect = rects[noteID] else { continue }
                let text = isHyphenated ? word.parts[k] : word.typed
                let carriesHold = k == syllables - 1
                pieces.append(Piece(
                    order: pieces.count,
                    item: Item(wordIndex: word.index, noteID: noteID, text: text, kind: isHyphenated ? .part : .word,
                               x: rect.minX + textInset, width: width(of: text, in: textWidths), row: 0,
                               holdFromX: carriesHold ? hold?.from : nil, holdToX: carriesHold ? hold?.to : nil,
                               holdTickXs: carriesHold ? hold?.ticks ?? [] : []),
                    onsetX: rect.minX, wordText: word.typed))
            }
        }
        pieces.sort { ($0.item.x, $0.order) < ($1.item.x, $1.order) }

        var rowEnds = [CGFloat](repeating: -.greatestFiniteMagnitude, count: textRowCount)
        var out: [Item] = []
        out.reserveCapacity(pieces.count)
        for piece in pieces {
            var item = piece.item
            if let row = rowEnds.indices.first(where: { item.x >= rowEnds[$0] + rowGap }) {
                item.row = row
                rowEnds[row] = item.maxX
            } else {
                // No room: a dot, never a shortened word. A hyphen part's dot stays on its own note and names the
                // whole word.
                item.kind = .dot
                item.text = piece.wordText
                item.x = piece.onsetX
                item.width = dotSize
                item.row = dotRow
            }
            out.append(item)
        }
        return out
    }

    private static func width(of text: String, in table: [String: CGFloat]) -> CGFloat {
        table[text] ?? CGFloat(text.count) * fallbackAdvance
    }

    // MARK: Hit testing

    /// The row band a point in the lane falls in: 0 and 1 for the text rows, `dotRow` below them; nil outside the lane.
    public static func row(atY y: CGFloat) -> Int? {
        guard y >= 0, y < laneHeight else { return nil }
        return min(Int(y / rowHeight), dotRow)
    }

    /// The item a click at `point` (lane coordinates: the grid's x, the lane's y) lands on — the lane's ONE tap,
    /// resolved by arithmetic, never per-item gesture views. A dot is a small target, so it takes `rowGap` of slop
    /// each side; text is hit within its own span. Nearest centre wins.
    public static func hitTest(_ items: [Item], at point: CGPoint) -> Item? {
        guard let row = row(atY: point.y) else { return nil }
        var best: (item: Item, distance: CGFloat)?
        for item in items where item.row == row {
            let slop = item.kind == .dot ? rowGap : 0
            guard point.x >= item.x - slop, point.x <= item.maxX + slop else { continue }
            let distance = abs(point.x - (item.x + item.width / 2))
            if let current = best, current.distance <= distance { continue }
            best = (item, distance)
        }
        return best?.item
    }
}
