import CoreGraphics
import DAWAppKit
import DAWCore
import Foundation
import Testing

/// vf-2 (design 2026-10-12 §5, Lane D) — the Sing sheet's word strip lays its words out with THE piano roll's
/// Words-lane layout (`PianoRollWordLane.layout`), never a placement of its own: two rows, a dot when a word has no
/// room, never truncated, never overlapping. It scrolls sideways rather than squeezing a long tune below 24 pt per
/// beat, and a click still picks exactly the note it picked before.
///
/// Widths come from an injected table (a fixed advance per character, then the chip's padding), never from text
/// measurement. ⚠️ NOT `@MainActor` (the suite cap): the layout is pure. The model half of the pick (a chip click picks
/// its first note for the Expression card) is one `@MainActor` test appended to `GenerationPresenceModelTests`.
@Suite("Sing sheet strip — the lane's layout (vf-2)")
struct SingWordStripLayoutTests {

    private static let tempo = TempoMap(constantBPM: 120)
    private static let meter = MeterMap(constant: TimeSignature())
    /// The sheet's strip is about this wide (a 560 pt card less its padding).
    private static let visible: CGFloat = 520
    /// 6 pt per character, then the chip's padding: "hello" is a 36 pt chip.
    private static let advance: CGFloat = 6

    private static func table(_ texts: Set<String>) -> [String: CGFloat] {
        Dictionary(uniqueKeysWithValues: texts.map {
            ($0, SingWordStripLayout.chipWidth(textWidth: CGFloat($0.count) * advance))
        })
    }

    /// A melody clip, one note per entry of `onsets` (beats), each `length` beats long, with stored `lyrics`.
    private static func clip(onsets: [Double], length: Double = 1, pitches: [Int]? = nil, lyrics: String,
                             language: String? = nil, extraNotes: [MIDINote] = []) -> (Track, Clip) {
        let notes = onsets.enumerated().map { i, onset in
            MIDINote(pitch: pitches?[i] ?? 60 + (i % 5), startBeat: onset, lengthBeats: length)
        } + extraNotes
        let span = (onsets.map { $0 + length }.max() ?? 1)
        let clip = Clip(name: "Melody", lengthBeats: span, notes: notes,
                        lyrics: ClipLyrics(text: lyrics, language: language))
        return (Track(name: "Lead", kind: .instrument, clips: [clip]), clip)
    }

    private static func ones(_ count: Int) -> [Double] { (0..<count).map(Double.init) }

    /// The sheet's preview of the clip's own stored words: what the strip is handed when the box holds them.
    private static func preview(_ track: Track, _ clip: Clip) -> SingSheetPreview {
        SingSheetPreview.make(clip: clip, track: track, text: clip.lyrics?.text ?? "", octaveShift: 0,
                              tempoMap: tempo, meterMap: meter)
    }

    private static func strip(_ preview: SingSheetPreview, visible: CGFloat = visible) -> SingWordStripLayout {
        SingWordStripLayout(preview: preview, visibleWidth: visible,
                            textWidths: table(SingWordStripLayout.texts(of: preview)))
    }

    /// Everything the lane layout reads from a word, and the roll's derivation sets (the tooltip sentence aside).
    private struct Placed: Equatable {
        var index: Int
        var typed: String
        var parts: [String]
        var noteIDs: [UUID]
        var held: Bool
        var phrase: Int
    }

    private static func placed(_ words: PianoRollWords) -> [Placed] {
        words.items.map {
            Placed(index: $0.index, typed: $0.typed, parts: $0.parts, noteIDs: $0.noteIDs, held: $0.held,
                   phrase: $0.phrase)
        }
    }

    /// The overlap law, per text row: each item starts at least `rowGap` past the previous one's end.
    private static func overlaps(_ items: [PianoRollWordLane.Item]) -> [String] {
        var found: [String] = []
        for row in 0..<PianoRollWordLane.textRowCount {
            let inRow = items.filter { $0.kind != .dot && $0.row == row }.sorted { $0.x < $1.x }
            for (a, b) in zip(inRow, inRow.dropFirst()) where b.x < a.maxX + PianoRollWordLane.rowGap {
                found.append("row \(row): '\(a.text)' ends \(a.maxX), '\(b.text)' starts \(b.x)")
            }
        }
        return found
    }

    // MARK: One home

    /// The fixtures the one-home law is checked on: each kind of word the planner places.
    private static func fixtures() -> [(name: String, track: Track, clip: Clip)] {
        let chord = clip(onsets: [0, 1, 2], pitches: [67, 65, 64], lyrics: "one two three",
                         extraNotes: [MIDINote(pitch: 55, startBeat: 0, lengthBeats: 1),
                                      MIDINote(pitch: 52, startBeat: 2, lengthBeats: 1)])
        let cases: [(String, (Track, Clip))] = [
            ("english", clip(onsets: ones(4), lyrics: "hello big world now")),
            ("auto-held", clip(onsets: ones(4), lyrics: "hi there")),
            ("typed hold", clip(onsets: ones(4), lyrics: "hi + there now")),
            ("hyphenated", clip(onsets: ones(3), lyrics: "twin-kle star")),
            ("chinese", clip(onsets: ones(4), lyrics: "我爱你们", language: "zh")),
            ("chord", chord),
            ("long, short notes", clip(onsets: (0..<48).map { Double($0) * 0.5 }, length: 0.5,
                                       lyrics: (0..<48).map { $0 % 7 == 0 ? "beautiful" : "la" }
                                        .joined(separator: " "))),
        ]
        return cases.map { (name: $0.0, track: $0.1.0, clip: $0.1.1) }
    }

    @Test("the strip's items ARE the lane layout's items over the roll's own derivation — one home, every kind of word")
    func stripItemsAreTheLaneLayoutsItems() throws {
        for fixture in Self.fixtures() {
            let preview = Self.preview(fixture.track, fixture.clip)
            #expect(preview.refusal == nil, "\(fixture.name): the fixture must sing (\(preview.refusal ?? ""))")
            let strip = Self.strip(preview)
            // The oracle is the PIANO ROLL's path: its derivation of the stored words, laid out by the lane's function
            // over the same bars and the same width table.
            let roll = PianoRollWords.derive(clip: fixture.clip, tempoMap: Self.tempo)
            let oracle = PianoRollWordLane.layout(words: roll, noteRects: strip.noteRects,
                                                  textWidths: Self.table(PianoRollWordLane.texts(of: roll)))
            #expect(!oracle.isEmpty, "\(fixture.name): positive control, the fixture places words")
            #expect(strip.items == oracle, "\(fixture.name)")
            // ...because the strip's words ARE the roll's words, field for field.
            #expect(Self.placed(strip.words) == Self.placed(roll), "\(fixture.name)")
            #expect(strip.words.melodyNoteIDs == roll.melodyNoteIDs, "\(fixture.name)")
        }
    }

    @Test("the fixtures exercise parts, holds, a chord and dots (positive controls for the one-home test)")
    func oneHomeFixturesCoverEveryKind() throws {
        let byName = Dictionary(uniqueKeysWithValues: Self.fixtures().map {
            ($0.name, Self.strip(Self.preview($0.track, $0.clip)))
        })
        let hyphen = try #require(byName["hyphenated"])
        #expect(hyphen.items.filter { $0.kind == .part }.map(\.text) == ["twin", "kle"])
        #expect(hyphen.items.filter { $0.kind == .part }.allSatisfy { $0.wordIndex == 0 })
        let autoHeld = try #require(byName["auto-held"])
        #expect(autoHeld.items.contains { $0.holdFromX != nil })
        let typedHold = try #require(byName["typed hold"])
        #expect(typedHold.items.contains { $0.holdFromX != nil })
        let chord = try #require(byName["chord"])
        #expect(chord.noteFrames.count == 3, "the chord's lower notes are not the strip's (the singer drops them)")
        let chinese = try #require(byName["chinese"])
        #expect(chinese.items.map(\.text) == ["我", "爱", "你", "们"])
    }

    // MARK: The floor

    @Test("a short tune still fills the strip; a long one scrolls at 24 pt per beat instead of squeezing")
    func floorFillsAShortTuneAndScrollsALongOne() throws {
        #expect(SingWordStripLayout.minPixelsPerBeat == 24)
        let (shortTrack, shortClip) = Self.clip(onsets: Self.ones(4), lyrics: "one two three four")
        let short = Self.strip(Self.preview(shortTrack, shortClip))
        #expect(short.pixelsPerBeat == 130)
        #expect(short.contentWidth == Self.visible)
        let (track, long) = Self.clip(onsets: Self.ones(64), lyrics: Array(repeating: "la", count: 64)
            .joined(separator: " "))
        let wide = Self.strip(Self.preview(track, long))
        #expect(wide.pixelsPerBeat == 24, "520 / 64 = 8.1 pt per beat would squeeze; the floor holds")
        #expect(wide.contentWidth == CGFloat(64 * 24))
        #expect(wide.noteFrames.last?.rect.minX == CGFloat(63 * 24))
        // The pure rule, both branches and the boundary.
        #expect(SingWordStripLayout.pixelsPerBeat(lengthBeats: 4, visibleWidth: 520) == 130)
        #expect(SingWordStripLayout.pixelsPerBeat(lengthBeats: 64, visibleWidth: 520) == 24)
        #expect(SingWordStripLayout.pixelsPerBeat(lengthBeats: 520.0 / 24, visibleWidth: 520) == 24)
    }

    // MARK: vf-2 itself

    @Test("vf-2: a long tune of short notes draws every word whole, in two rows, with no overlap and no dot")
    func longTuneOfShortNotesDrawsWholeWords() throws {
        // 48 eighth notes (24 beats): squeezed into 520 pt that is 10.8 pt a note, and a third of the words would
        // have no room. At the floor (12 pt a note) every "la" chip (18 pt) fits, alternating rows.
        let words = Array(repeating: "la", count: 48)
        let (track, clip) = Self.clip(onsets: (0..<48).map { Double($0) * 0.5 }, length: 0.5,
                                      lyrics: words.joined(separator: " "))
        let strip = Self.strip(Self.preview(track, clip))
        #expect(strip.pixelsPerBeat == 24)
        #expect(strip.contentWidth > Self.visible, "it scrolls")
        #expect(Self.overlaps(strip.items).isEmpty, "\(Self.overlaps(strip.items))")
        #expect(strip.items.count == 48)
        #expect(strip.items.filter { $0.kind == .dot }.isEmpty, "every word has room at the floor")
        #expect(strip.items.allSatisfy { $0.text == "la" }, "never truncated")
        #expect(Set(strip.items.map(\.row)) == [0, 1], "staggered over the lane's two rows")
    }

    @Test("vf-2: where words cannot all fit, the rest become dots — never a shortened word, never an overlap")
    func crowdedWordsBecomeDotsNotTruncations() throws {
        let words = (0..<32).map { $0 % 2 == 0 ? "wonderful" : "everything" }
        let (track, clip) = Self.clip(onsets: (0..<32).map { Double($0) * 0.25 }, length: 0.25,
                                      lyrics: words.joined(separator: " "))
        let strip = Self.strip(Self.preview(track, clip))
        let dots = strip.items.filter { $0.kind == .dot }
        #expect(!dots.isEmpty, "positive control: this fixture is crowded")
        #expect(strip.items.count == 32, "every word is drawn: as a word or as a dot")
        #expect(Self.overlaps(strip.items).isEmpty, "\(Self.overlaps(strip.items))")
        for item in strip.items {
            #expect(item.text == words[item.wordIndex], "a dot carries its whole word; a word is drawn in full")
        }
        #expect(dots.allSatisfy { $0.row == PianoRollWordLane.dotRow && $0.width == PianoRollWordLane.dotSize })
        // The dot's tooltip is its word.
        for dot in dots {
            #expect(strip.tooltip(for: dot) == words[dot.wordIndex])
        }
    }

    // MARK: The pick

    @Test("a click picks the same thing as before: a word (or part, or dot) its chip, a note's column that note")
    func clickResolvesTheSameTarget() throws {
        let (track, clip) = Self.clip(onsets: Self.ones(5), lyrics: "twin-kle lit-tle star")
        let preview = Self.preview(track, clip)
        let strip = Self.strip(preview)
        #expect(preview.chips.map(\.id) == Array(0..<preview.chips.count),
                "a chip's id is its reading order: the glow and `tapChip` both depend on it")
        #expect(Set(strip.items.map(\.wordIndex)) == Set(preview.chips.map(\.id)))
        #expect(strip.items.count == 5, "positive control: four parts and a word")
        for item in strip.items {
            let point = CGPoint(x: item.x + item.width / 2, y: PianoRollWordLane.rowTop(item.row) + 2)
            #expect(strip.target(at: point) == .word(item.wordIndex), "'\(item.text)'")
            // The chip a part names opens (or picks) its word's FIRST note — the old chip's click.
            #expect(preview.chips[item.wordIndex].noteIDs.first == strip.words.items[item.wordIndex].noteIDs.first)
        }
        for note in strip.noteFrames {
            let point = CGPoint(x: note.rect.midX, y: SingWordStripLayout.barTop + 6)
            #expect(strip.target(at: point) == .note(note.id))
        }
        // Nothing under the point: nothing picked.
        let lastEnd = try #require(strip.items.map(\.maxX).max())
        #expect(strip.target(at: CGPoint(x: lastEnd + 40, y: 3)) == nil, "empty word band")
        #expect(strip.target(at: CGPoint(x: 10, y: SingWordStripLayout.height + 1)) == nil, "below the strip")
        #expect(strip.target(at: CGPoint(x: 10, y: -1)) == nil, "above the strip")
    }

    @Test("a dot is a small target: the lane's slop makes it clickable a few points either side")
    func dotsAreClickable() throws {
        let words = (0..<32).map { $0 % 2 == 0 ? "wonderful" : "everything" }
        let (track, clip) = Self.clip(onsets: (0..<32).map { Double($0) * 0.25 }, length: 0.25,
                                      lyrics: words.joined(separator: " "))
        let strip = Self.strip(Self.preview(track, clip))
        let dot = try #require(strip.items.first { $0.kind == .dot })
        let y = PianoRollWordLane.rowTop(PianoRollWordLane.dotRow) + 2
        #expect(strip.target(at: CGPoint(x: dot.x + dot.width / 2, y: y)) == .word(dot.wordIndex))
        #expect(strip.target(at: CGPoint(x: dot.x - PianoRollWordLane.rowGap + 0.5, y: y)) == .word(dot.wordIndex))
    }

    @Test("where two notes' columns overlap, the LATER note wins (it was drawn on top), as before")
    func overlappingColumnsPickTheLaterNote() throws {
        // Sixteenths at the floor: 6 pt apart, each column 8 pt wide, so each overlaps the next by 2 pt.
        let (track, clip) = Self.clip(onsets: (0..<96).map { Double($0) * 0.25 }, length: 0.25,
                                      lyrics: Array(repeating: "la", count: 96).joined(separator: " "))
        let strip = Self.strip(Self.preview(track, clip))
        #expect(strip.pixelsPerBeat == 24)
        let y = SingWordStripLayout.barTop + 6
        for i in 1..<(strip.noteFrames.count - 1) {
            let note = strip.noteFrames[i].rect
            #expect(note.width < SingWordStripLayout.noteColumnMinWidth, "positive control: a thin note")
            #expect(strip.target(at: CGPoint(x: note.minX + 7, y: y)) == .note(strip.noteFrames[i + 1].id),
                    "in the overlap with the next note")
            #expect(strip.target(at: CGPoint(x: note.minX + 1, y: y)) == .note(strip.noteFrames[i].id),
                    "in the overlap with the note before")
        }
    }

    @Test("a click inside the open note field is the field's, not a pick")
    func clickInsideTheFieldPicksNothing() throws {
        let (track, clip) = Self.clip(onsets: Self.ones(4), lyrics: "one two three four")
        let strip = Self.strip(Self.preview(track, clip))
        let note = strip.noteFrames[1]
        let field = try #require(strip.fieldRect(noteID: note.id))
        // A point on the word the field covers: inside the field, and on a chip.
        let word = try #require(strip.items.first { $0.noteID == note.id })
        let inside = CGPoint(x: word.x + 2, y: PianoRollWordLane.rowTop(word.row) + 2)
        #expect(field.contains(inside), "the fixture's point is inside the field")
        #expect(strip.target(at: inside) == .word(word.wordIndex),
                "positive control: without a field the point picks the word")
        #expect(strip.target(at: inside, fieldNoteID: note.id) == nil)
        #expect(strip.target(at: CGPoint(x: note.rect.midX, y: SingWordStripLayout.barTop + 6), fieldNoteID: note.id)
                == .note(note.id), "outside the field the pick still works")
    }

    // MARK: Geometry the view draws with

    @Test("the field opens just left of its note and stays inside the scrolled content")
    func fieldStaysInsideTheContent() throws {
        let (track, clip) = Self.clip(onsets: Self.ones(64), lyrics: Array(repeating: "la", count: 64)
            .joined(separator: " "))
        let strip = Self.strip(Self.preview(track, clip))
        let first = try #require(strip.fieldRect(noteID: strip.noteFrames[0].id))
        #expect(first.minX == 0)
        let middle = try #require(strip.fieldRect(noteID: strip.noteFrames[10].id))
        #expect(middle.minX == strip.noteFrames[10].rect.minX - 4)
        let lastNote = try #require(strip.noteFrames.last)
        let last = try #require(strip.fieldRect(noteID: lastNote.id))
        #expect(last.maxX == strip.contentWidth)
        #expect(last.size == SingWordStripLayout.fieldSize)
        #expect(strip.fieldRect(noteID: UUID()) == nil)
    }

    @Test("bars sit under the words band, highest note highest, and a held word's tooltip says so")
    func barsAndTooltips() throws {
        let (track, clip) = Self.clip(onsets: Self.ones(4), pitches: [60, 72, 66, 60], lyrics: "hi there")
        let preview = Self.preview(track, clip)
        let strip = Self.strip(preview)
        let tops = strip.noteFrames.map(\.rect.minY)
        #expect(tops[1] == SingWordStripLayout.barTop, "the highest note at the top of its band")
        #expect(tops[0] == SingWordStripLayout.barTop + SingWordStripLayout.barTravel)
        #expect(tops.allSatisfy { $0 >= SingWordStripLayout.wordBandHeight })
        #expect(strip.noteFrames.allSatisfy { $0.rect.maxY + 2 <= SingWordStripLayout.height },
                "a picked note's ring stays inside the strip")
        let held = try #require(preview.chips.first { $0.held })
        let item = try #require(strip.items.first { $0.wordIndex == held.id })
        #expect(strip.tooltip(for: item) == "'\(held.text)' is held across \(held.noteCount) notes")
    }

    @Test("a chip's width is its text's, rounded up to whole points, plus the padding both sides")
    func chipWidth() {
        #expect(SingWordStripLayout.chipWidth(textWidth: 10.2) == 11 + 2 * SingWordStripLayout.chipPadding)
        #expect(SingWordStripLayout.chipWidth(textWidth: 12) == 12 + 2 * SingWordStripLayout.chipPadding)
    }
}
