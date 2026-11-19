import CoreGraphics
import DAWAppKit
import DAWCore
import Foundation
import Testing

/// p2-sing-pr-words (design 2026-10-12 §2.4, §6.1) — WHERE the Words lane draws each word. Never truncate, never
/// overlap; a word with no room becomes a dot; held words draw a line with a tick per held note; hyphen parts sit on
/// their own notes; zooming in only ever helps the words already showing.
///
/// Widths come from an injected table (a fixed advance per character), never from text measurement.
/// ⚠️ NOT `@MainActor` (the suite cap): the layout is pure.
@Suite("Piano roll words — the lane layout (p2-sing-pr-words)")
struct PianoRollWordLaneLayoutTests {

    /// 6 pt per character: "hello" is 30 pt.
    private static let advance: CGFloat = 6

    private static func widths(_ words: PianoRollWords) -> [String: CGFloat] {
        Dictionary(uniqueKeysWithValues: PianoRollWordLane.texts(of: words).map { ($0, CGFloat($0.count) * advance) })
    }

    /// One note per entry at `onsets` (beats), each `length` beats long, as the roll's rects at `ppb`.
    private static func notes(_ onsets: [Double], length: Double = 0.25) -> [MIDINote] {
        onsets.map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: length) }
    }

    private static func rects(_ notes: [MIDINote], ppb: CGFloat) -> [(id: UUID, rect: CGRect)] {
        notes.map { (id: $0.id, rect: PianoRollModel.noteRect($0, rowHeight: 14, pixelsPerBeat: ppb)) }
    }

    /// Words built directly: word k sings `noteCounts[k]` notes in order, one part unless `parts` says otherwise.
    private static func words(_ texts: [String], notes: [MIDINote], noteCounts: [Int]? = nil,
                              parts: [Int: [String]] = [:]) -> PianoRollWords {
        var next = 0
        var items: [PianoRollWords.Word] = []
        for (k, text) in texts.enumerated() {
            let count = noteCounts?[k] ?? 1
            let ids = notes[next..<(next + count)].map(\.id)
            next += count
            items.append(PianoRollWords.Word(index: k, typed: text, parts: parts[k] ?? [text], noteIDs: Array(ids),
                                             held: false, phrase: 0))
        }
        return PianoRollWords(items: items, unsungNoteIDs: [], refusal: nil, language: nil,
                              melodyNoteIDs: notes.map(\.id))
    }

    private static func textItems(_ items: [PianoRollWordLane.Item]) -> [PianoRollWordLane.Item] {
        items.filter { $0.kind != .dot }
    }

    /// The overlap law: within each text row, every item starts at least `rowGap` past the previous one's end.
    private static func overlaps(_ items: [PianoRollWordLane.Item]) -> [String] {
        var found: [String] = []
        for row in 0..<PianoRollWordLane.textRowCount {
            let inRow = items.filter { $0.kind != .dot && $0.row == row }.sorted { $0.x < $1.x }
            for (a, b) in zip(inRow, inRow.dropFirst()) where b.x < a.maxX + PianoRollWordLane.rowGap {
                found.append("row \(row): '\(a.text)' [\(a.x), \(a.maxX)] then '\(b.text)' at \(b.x)")
            }
        }
        return found
    }

    /// A small deterministic generator, so a failing property names its seed.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
        mutating func word() -> String {
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            return String((0..<(1 + Int(next() % 11))).map { _ in pick(letters) })
        }
    }

    /// A random melody and words over it: words of 1-12 letters, some holding 1-2 extra notes, some hyphenated.
    private static func randomLane(_ rng: inout Seeded) -> (PianoRollWords, [MIDINote]) {
        let count = 4 + Int(rng.next() % 16)
        var onset = 0.0
        var notes: [MIDINote] = []
        var texts: [String] = []
        var counts: [Int] = []
        var parts: [Int: [String]] = [:]
        for k in 0..<count {
            let hyphenated = rng.next() % 5 == 0
            let partList = hyphenated ? [rng.word(), rng.word()] : nil
            let holds = rng.next() % 4 == 0 ? 1 + Int(rng.next() % 2) : 0
            let n = (partList?.count ?? 1) + holds
            for _ in 0..<n {
                let length = rng.pick([0.125, 0.25, 0.5, 1.0])
                notes.append(MIDINote(pitch: 60, startBeat: onset, lengthBeats: length))
                onset += length
            }
            if let partList {
                texts.append(partList.joined(separator: "-"))
                parts[k] = partList
            } else {
                texts.append(rng.word())
            }
            counts.append(n)
        }
        return (words(texts, notes: notes, noteCounts: counts, parts: parts), notes)
    }

    // MARK: Never overlap, never truncate

    @Test("⭐ no two words overlap in a row — 400 random lanes at random zooms")
    func neverOverlapProperty() {
        var rng = Seeded(state: 0x5EED_0001)
        var placedText = 0
        for trial in 0..<400 {
            let (words, notes) = Self.randomLane(&rng)
            let ppb = CGFloat(rng.pick([4.0, 8, 12, 16, 24, 32, 48, 64, 96, 160]))
            let items = PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: ppb),
                                                 textWidths: Self.widths(words))
            #expect(Self.overlaps(items).isEmpty, "trial \(trial) at \(ppb) pt/beat: \(Self.overlaps(items))")
            #expect(items.allSatisfy { $0.row >= 0 && $0.row <= PianoRollWordLane.dotRow })
            #expect(items.filter { $0.kind == .dot }.allSatisfy { $0.row == PianoRollWordLane.dotRow })
            placedText += Self.textItems(items).count
        }
        #expect(placedText > 1000, "positive control: the property ran over real words, not a lane of dots")
    }

    @Test("⭐ every drawn text is a whole word or a whole part at its full width — never truncated")
    func neverTruncate() {
        var rng = Seeded(state: 0x5EED_0002)
        var dots = 0
        for trial in 0..<300 {
            let (words, notes) = Self.randomLane(&rng)
            let ppb = CGFloat(rng.pick([6.0, 16, 32, 64]))
            let table = Self.widths(words)
            let items = PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: ppb), textWidths: table)
            for item in items {
                let word = words.items[item.wordIndex]
                switch item.kind {
                case .word:
                    #expect(item.text == word.typed, "trial \(trial)")
                    #expect(item.width == table[word.typed], "trial \(trial): '\(item.text)' drawn narrower than itself")
                case .part:
                    #expect(word.parts.contains(item.text), "trial \(trial)")
                    #expect(item.width == table[item.text], "trial \(trial)")
                case .dot:
                    dots += 1
                    #expect(item.text == word.typed, "a dot carries its whole word, for the tooltip")
                    #expect(item.width == PianoRollWordLane.dotSize)
                }
                #expect(!item.text.hasSuffix("…") && !item.text.hasSuffix("..."), "trial \(trial): '\(item.text)'")
            }
            // Every word is somewhere: as a word, its parts, or a dot.
            #expect(Set(items.map(\.wordIndex)) == Set(words.items.map(\.index)), "trial \(trial): a word vanished")
        }
        #expect(dots > 0, "positive control: some lanes were tight enough to need dots")
    }

    @Test("a word with no room in either row becomes a DOT at its onset, in the dot band")
    func dotWhenNeitherRowFits() throws {
        let notes = Self.notes([0, 0.25, 0.5])                      // sixteenths: 8 pt apart at 32 pt/beat
        let words = Self.words(["wonderful", "beautiful", "marvellous"], notes: notes)
        let items = PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: 32),
                                             textWidths: Self.widths(words))
        #expect(items.map(\.kind) == [.word, .word, .dot])
        #expect(items.map(\.row) == [0, 1, PianoRollWordLane.dotRow])
        let dot = try #require(items.last)
        #expect(dot.x == 16, "at its note's onset: 0.5 beat × 32")
        #expect(dot.text == "marvellous")
        // Zoom in far enough and the dot is a word again (density follows fit, not a threshold).
        let wide = PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: 400),
                                            textWidths: Self.widths(words))
        #expect(wide.allSatisfy { $0.kind == .word })
    }

    @Test("placement: x = onset + 2; row 0 first, then row 1; free means starting rowGap past the row's last end")
    func placementRule() {
        let notes = Self.notes([0, 0.5, 1, 1.5])                    // 16 pt apart at 32 pt/beat
        let words = Self.words(["aa", "bbbb", "c", "dd"], notes: notes)   // 12, 24, 6, 12 pt
        let items = PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: 32),
                                             textWidths: Self.widths(words))
        #expect(items.map(\.x) == [2, 18, 34, 50])
        // aa [2,14] row 0; bbbb at 18 ≥ 14+4 → row 0 [18,42]; c at 34 < 46 → row 1 [34,40]; dd at 50 ≥ 46 → row 0.
        #expect(items.map(\.row) == [0, 0, 1, 0])
    }

    // MARK: Holds and parts

    @Test("a held word: a line from its first note's onset to its last note's end, one tick per HELD note")
    func heldLine() throws {
        let notes = Self.notes([0, 1, 2], length: 1)
        let words = Self.words(["love"], notes: notes, noteCounts: [3])
        let rects = Self.rects(notes, ppb: 32)
        let item = try #require(PianoRollWordLane.layout(words: words, noteRects: rects,
                                                          textWidths: Self.widths(words)).first)
        #expect(item.holdFromX == rects[0].rect.minX)
        #expect(item.holdToX == rects[2].rect.maxX)
        #expect(item.holdTickXs == [rects[1].rect.minX, rects[2].rect.minX])
        #expect(PianoRollWordLane.heldNoteCount(words.items[0]) == 2)
        // A word on one note holds nothing.
        let single = Self.words(["la"], notes: [notes[0]])
        let plain = try #require(PianoRollWordLane.layout(words: single, noteRects: rects,
                                                           textWidths: Self.widths(single)).first)
        #expect(plain.holdFromX == nil && plain.holdToX == nil && plain.holdTickXs.isEmpty)
    }

    @Test("a typed + hold and rule 5.2's automatic hold draw the SAME line (the line is the notes, not `held`)")
    func typedAndAutomaticHoldsLookTheSame() throws {
        let typed = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "hi + there now")
        let auto = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "now hi there")
        let tempo = TempoMap(constantBPM: 120)
        for clip in [typed, auto] {
            let words = PianoRollWords.derive(clip: clip, tempoMap: tempo)
            let holder = try #require(words.items.first { $0.noteIDs.count > 1 }, "the fixture holds a note")
            let rects = Self.rects(try #require(clip.notes), ppb: 32)
            let items = PianoRollWordLane.layout(words: words, noteRects: rects, textWidths: Self.widths(words))
            let item = try #require(items.first { $0.wordIndex == holder.index })
            let byID = Dictionary(uniqueKeysWithValues: rects.map { ($0.id, $0.rect) })
            #expect(item.holdFromX == byID[holder.noteIDs[0]]?.minX)
            #expect(item.holdToX == byID[holder.noteIDs.last!]?.maxX)
            #expect(item.holdTickXs.count == holder.noteIDs.count - 1)
        }
        // Positive control: the two fixtures really are the two kinds of hold.
        #expect(PianoRollWords.derive(clip: typed, tempoMap: tempo).items.allSatisfy { !$0.held })
        #expect(PianoRollWords.derive(clip: auto, tempoMap: tempo).items.contains { $0.held })
    }

    @Test("a hyphenated word draws each part on its own note; notes past the parts are held from the last part")
    func partsOnTheirOwnNotes() throws {
        let notes = Self.notes([0, 1, 2], length: 1)
        let words = Self.words(["twin-kle"], notes: notes, noteCounts: [3], parts: [0: ["twin", "kle"]])
        let rects = Self.rects(notes, ppb: 32)
        let items = PianoRollWordLane.layout(words: words, noteRects: rects, textWidths: Self.widths(words))
        #expect(items.map(\.kind) == [.part, .part])
        #expect(items.map(\.text) == ["twin", "kle"])
        #expect(items.map(\.noteID) == [notes[0].id, notes[1].id])
        #expect(items.map(\.wordIndex) == [0, 0])
        #expect(items[0].holdFromX == nil, "the first part holds nothing")
        #expect(items[1].holdFromX == rects[1].rect.minX)
        #expect(items[1].holdToX == rects[2].rect.maxX)
        #expect(items[1].holdTickXs == [rects[2].rect.minX])
        #expect(PianoRollWordLane.texts(of: words) == ["twin", "kle"], "the view measures the parts, not the word")
    }

    @Test("words ride with the DRAFT's rects: a note dragged right takes its word with it; which word is unchanged")
    func wordsRideWithTheirNotes() throws {
        let notes = Self.notes([0, 1], length: 1)
        let words = Self.words(["one", "two"], notes: notes)
        var rects = Self.rects(notes, ppb: 32)
        rects[1].rect.origin.x += 40
        let items = PianoRollWordLane.layout(words: words, noteRects: rects, textWidths: Self.widths(words))
        #expect(items.map(\.text) == ["one", "two"])
        #expect(items[1].x == rects[1].rect.minX + PianoRollWordLane.textInset)
        // A word whose first note has no rect (gone from the draft) is skipped, never drawn at a stale place.
        let gone = PianoRollWordLane.layout(words: words, noteRects: [rects[0]], textWidths: Self.widths(words))
        #expect(gone.map(\.text) == ["one"])
    }

    @Test("a text missing from the width table is never measured NARROWER than a full em per character")
    func fallbackWidthIsConservative() throws {
        let notes = Self.notes([0])
        let words = Self.words(["你好"], notes: notes)
        let item = try #require(PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: 32),
                                                          textWidths: [:]).first)
        #expect(item.width == 2 * PianoRollWordLane.fallbackAdvance)
        #expect(PianoRollWordLane.fallbackAdvance >= PianoRollWordLane.fontSize)
    }

    // MARK: Zoom (density follows fit)

    @Test("⭐ zooming in only helps: a lane with no dot keeps no dot, and the first dot never moves earlier")
    func zoomingInNeverHurtsTheWordsShowing() {
        var rng = Seeded(state: 0x5EED_0003)
        var allFullSeen = 0
        var dottedSeen = 0
        for trial in 0..<400 {
            let (words, notes) = Self.randomLane(&rng)
            let table = Self.widths(words)
            let ladder: [CGFloat] = [4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 200, 320]
            var previousFirstDot = -1
            var previousAllFull = false
            for ppb in ladder {
                let items = PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: ppb),
                                                     textWidths: table)
                let firstDot = items.firstIndex { $0.kind == .dot } ?? items.count
                let allFull = firstDot == items.count
                if allFull { allFullSeen += 1 } else { dottedSeen += 1 }
                #expect(!(previousAllFull && !allFull), "trial \(trial): dots came back at \(ppb) pt/beat")
                #expect(firstDot >= previousFirstDot, "trial \(trial): the first dot moved earlier at \(ppb) pt/beat")
                previousFirstDot = firstDot
                previousAllFull = allFull
            }
        }
        #expect(allFullSeen > 0 && dottedSeen > 0, "positive control: the ladder crossed from dotted to all-full lanes")
    }

    @Test("⚠️ KNOWN LIMIT of §2.4's rule (design §6.1 asked for more): zooming in CAN cost a word later on")
    func zoomingInCanCostAWordLaterOn() {
        // Five words on sixteenths. At 32 pt/beat word 3 is a dot, which leaves row 0 free for words 4 and 5; at 48 it
        // fits, takes row 0, and words 4 and 5 become dots. 4 full words, then 3. Any first-fit placement does this
        // (measured: best-fit and worst-fit row choice fail the same cases); only a maximum two-row selection, which
        // dots EARLY words to save later ones, does not. Pinned so the property the lane does have
        // (`zoomingInNeverHurtsTheWordsShowing`) is not mistaken for the stronger one.
        let notes = Self.notes([0, 0.25, 0.5, 0.75, 1.25])
        let words = Self.words(["aaa", "bbbbbbbb", "cccccc", "d", "e"], notes: notes)
        let table: [String: CGFloat] = ["aaa": 20, "bbbbbbbb": 50, "cccccc": 40, "d": 10, "e": 10]
        func full(_ ppb: CGFloat) -> Int {
            PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: ppb), textWidths: table)
                .filter { $0.kind != .dot }.count
        }
        #expect(full(32) == 4)
        #expect(full(48) == 3)
    }

    // MARK: Hit testing (the lane's ONE tap)

    @Test("the lane's one tap: a point resolves to the item in its row band; a dot gets slop; empty space is nothing")
    func hitTest() throws {
        let notes = Self.notes([0, 0.25, 0.5])
        let words = Self.words(["wonderful", "beautiful", "marvellous"], notes: notes)
        let items = PianoRollWordLane.layout(words: words, noteRects: Self.rects(notes, ppb: 32),
                                             textWidths: Self.widths(words))
        let rowHeight = PianoRollWordLane.rowHeight
        #expect(PianoRollWordLane.hitTest(items, at: CGPoint(x: 10, y: rowHeight / 2))?.wordIndex == 0)
        #expect(PianoRollWordLane.hitTest(items, at: CGPoint(x: 20, y: rowHeight * 1.5))?.wordIndex == 1)
        let dotY = PianoRollWordLane.rowTop(PianoRollWordLane.dotRow) + 2
        #expect(PianoRollWordLane.hitTest(items, at: CGPoint(x: 16 + 5, y: dotY))?.wordIndex == 2, "within slop")
        #expect(PianoRollWordLane.hitTest(items, at: CGPoint(x: 16 + 20, y: dotY)) == nil)
        #expect(PianoRollWordLane.hitTest(items, at: CGPoint(x: 400, y: rowHeight / 2)) == nil)
        #expect(PianoRollWordLane.hitTest(items, at: CGPoint(x: 10, y: PianoRollWordLane.laneHeight + 1)) == nil)
        #expect(PianoRollWordLane.row(atY: 0) == 0)
        #expect(PianoRollWordLane.row(atY: PianoRollWordLane.laneHeight - 0.5) == PianoRollWordLane.dotRow)
    }
}
