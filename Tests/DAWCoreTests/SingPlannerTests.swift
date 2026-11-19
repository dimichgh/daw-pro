import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d2: `SingPlanner` (design `docs/design/2026-09-27-p2-sing-integration.md`
/// §3.4). Pure values, so NOT `@MainActor`.
///
/// 120 BPM throughout unless a test says otherwise: one beat is 0.5 s, so a
/// time in beats halves into seconds exactly.
///
/// Where the planner reads the playback evaluator's rule, the pin against the
/// evaluator itself is `SingPlannerPlaybackParityTests` (DAWEngineTests, in
/// `ClipLyricsRenderKeyTests.swift`): DAWCore cannot see DAWEngine.
@Suite("SingPlanner: the melody, the words and the render units (p2-sing-d2)")
struct SingPlannerTests {

    static let tempo = TempoMap(constantBPM: 120)
    static let meter = MeterMap(constant: TimeSignature())
    static let lead = Track(name: "Lead", kind: .instrument)

    static func note(_ pitch: Int, _ start: Double, _ length: Double, velocity: Int = 100) -> MIDINote {
        MIDINote(pitch: pitch, velocity: velocity, startBeat: start, lengthBeats: length)
    }

    /// A melody clip; its length defaults to the last note's end.
    static func clip(_ notes: [MIDINote], _ lyrics: String?, start: Double = 0, length: Double? = nil) -> Clip {
        let end = notes.map { $0.endBeat }.max() ?? 4
        return Clip(name: "Melody", startBeat: start, lengthBeats: length ?? end, notes: notes,
                    lyrics: lyrics.map { ClipLyrics(text: $0) })
    }

    static func plan(_ clip: Clip, shift: Int = 0, tempo: TempoMap = tempo, meter: MeterMap = meter,
                     on track: Track = lead) throws -> SingPlan {
        try SingPlanner.plan(clip: clip, on: track, tempoMap: tempo, meterMap: meter, octaveShift: shift)
    }

    /// The refusal, or nil when the clip plans.
    static func refusal(_ clip: Clip, shift: Int = 0, on track: Track = lead) -> SingPlanRefusal? {
        do throws(SingPlanRefusal) {
            _ = try SingPlanner.plan(clip: clip, on: track, tempoMap: tempo, meterMap: meter, octaveShift: shift)
            return nil
        } catch {
            return error
        }
    }

    /// "la la la …", `count` words.
    static func la(_ count: Int) -> String { Array(repeating: "la", count: count).joined(separator: " ") }

    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

    static func close(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { close($0, $1) }
    }

    // MARK: - The melody

    @Test("the melody is the notes the clip PLAYS, one at a time: window, order, chords, overlaps")
    func melodyIsWhatPlays() {
        let a = Self.note(60, 0, 1)
        let b = Self.note(64, 1, 1)
        let c = Self.note(67, 1, 1)            // a chord with b: the top note, 67, is sung
        let d = Self.note(62, 2, 3)            // runs past the next onset and past the clip's end
        let e = Self.note(65, 3, 0.5)
        let f = Self.note(70, 4, 1)            // starts AT the clip's end: playback never sounds it
        let g = Self.note(72, 6, 1)            // past the end
        let clip = Self.clip([g, e, d, c, b, a, f], nil, length: 4)   // written out of order on purpose
        let melody = SingPlanner.melody(of: clip)
        let ids = melody.notes.map { $0.id }
        let pitches = melody.notes.map { $0.pitch }
        let starts = melody.notes.map { $0.startBeat }
        let ends = melody.notes.map { $0.endBeat }
        #expect(ids == [a.id, c.id, d.id, e.id])
        #expect(pitches == [60, 67, 62, 65])
        #expect(starts == [0, 1, 2, 3])
        #expect(ends == [1, 2, 3, 3.5], "d stops where e starts")
        #expect(melody.chordPlaces == 1)

        // A note that runs past the clip's end stops there (playback's min(end, length)).
        let tail = SingPlanner.melody(of: Self.clip([Self.note(60, 1, 8)], nil, length: 4))
        #expect(tail.notes.first?.endBeat == 4)
    }

    @Test("two notes of the SAME pitch starting together are one note, the longer, and not a chord")
    func unisonIsNotAChord() {
        let short = Self.note(60, 0, 1)
        let long = Self.note(60, 0, 2)
        let melody = SingPlanner.melody(of: Self.clip([short, long], nil))
        let ids = melody.notes.map { $0.id }
        #expect(ids == [long.id])
        #expect(melody.chordPlaces == 0)
    }

    @Test("a chord sings its top note and says so, counting each place once")
    func chordsWarn() throws {
        let notes = [Self.note(60, 0, 1), Self.note(64, 0, 1), Self.note(62, 1, 1),
                     Self.note(67, 2, 1), Self.note(71, 2, 1)]
        let plan = try Self.plan(Self.clip(notes, "one two three"))
        let sung = plan.notes.map { $0.midi }
        #expect(sung == [64, 62, 71])
        #expect(plan.warnings == [.chords(places: 2)])
        #expect(SingPlanWarning.chords(places: 2).sentence == "Your tune has chords at 2 places; I sang the top note.")
        #expect(SingPlanWarning.chords(places: 1).sentence == "Your tune has chords at 1 place; I sang the top note.")
        // Control: no chord, no warning.
        let solo = try Self.plan(Self.clip([Self.note(60, 0, 1), Self.note(62, 1, 1)], "one two"))
        #expect(solo.warnings.isEmpty)
    }

    // MARK: - Legato and times

    @Test("legato: a gap of up to 0.125 beat is closed, a breath stays a rest")
    func legatoClosesArticulationGaps() throws {
        // Gaps: 0.1 beat (closed), exactly 0.125 (closed: the rule is <=), 0.25 (a breath, kept).
        let notes = [Self.note(60, 0, 0.9), Self.note(62, 1, 1), Self.note(64, 2.125, 0.875), Self.note(65, 3.25, 0.75)]
        let plan = try Self.plan(Self.clip(notes, "one two three four"))
        #expect(plan.units.count == 1)
        let unit = try #require(plan.units.first)
        let starts = unit.notes.map { $0.startSeconds }
        let ends = unit.notes.map { $0.endSeconds }
        #expect(Self.close(starts, [0, 0.5, 1.0625, 1.625]), "\(starts)")
        #expect(Self.close(ends, [0.5, 1.0625, 1.5, 2.0]), "the first two gaps close to an exact abut, the breath stays: \(ends)")
        #expect(Self.close(unit.spanSeconds, 2.0))
    }

    @Test("beats become seconds through the tempo map, so a tempo change is honoured")
    func tempoChangesAreHonoured() throws {
        let map = try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 60)])
        // Clip at beat 2; its notes sound at song beats 2–3, 4–5 and 5.5–6.5.
        let clip = Self.clip([Self.note(60, 0, 1), Self.note(62, 2, 1), Self.note(64, 3.5, 1)],
                             "one two three", start: 2, length: 5)
        let plan = try Self.plan(clip, tempo: map)
        let unit = try #require(plan.units.first)
        let starts = unit.notes.map { $0.startSeconds }
        let ends = unit.notes.map { $0.endSeconds }
        #expect(Self.close(unit.onsetSeconds, 1.0))
        #expect(Self.close(starts, [0, 1.0, 2.5]), "\(starts)")
        #expect(Self.close(ends, [0.5, 2.0, 3.5]), "\(ends)")
        #expect(Self.close(plan.t0Seconds, 0.76))
        #expect(Self.close(plan.atBeat, 1.52))
        #expect(Self.close(unit.offsetSeconds, 0))
        // Control: at a constant 120 BPM the last note would start 1.75 s after the first.
        let flat = try Self.plan(clip)
        #expect(Self.close(flat.units[0].notes[2].startSeconds, 1.75))
    }

    @Test("placement: the file starts one lead (0.24 s) before the first sung note, never before the song")
    func placement() throws {
        // First note at beat 8 (4 s): the file starts at 3.76 s = beat 7.52.
        let late = try Self.plan(Self.clip([Self.note(60, 0, 1)], "la", start: 8))
        #expect(Self.close(late.t0Seconds, 3.76))
        #expect(Self.close(late.atBeat, 7.52))
        #expect(Self.close(late.units[0].onsetSeconds, 4))
        #expect(Self.close(late.units[0].offsetSeconds, 0))
        // First note at 0.2 beat (0.1 s): the file starts at 0, so 0.14 s of the unit's lead is cut.
        let early = try Self.plan(Self.clip([Self.note(60, 0.2, 1)], "la"))
        #expect(early.t0Seconds == 0)
        #expect(early.atBeat == 0)
        #expect(Self.close(early.units[0].offsetSeconds, -0.14))
    }

    // MARK: - The octave

    @Test("⭐ the sung pitch is the written pitch plus whole octaves, and nothing else moves it (300 seeded clips)")
    func targetMinusSourceIsWholeOctaves() throws {
        var rng = SingPlanRNG(seed: 0x5D2_0C7A)
        var planned = 0
        var shifted = 0
        for _ in 0..<300 {
            var notes: [MIDINote] = []
            for _ in 0..<Int.random(in: 1...24, using: &rng) {
                notes.append(Self.note(Int.random(in: 36...96, using: &rng),
                                       Double(Int.random(in: 0...63, using: &rng)) * 0.25,
                                       Double(Int.random(in: 1...12, using: &rng)) * 0.25))
            }
            let shift = Int.random(in: -2...2, using: &rng)
            let sungNotes = SingPlanner.melody(of: Self.clip(notes, nil)).notes.count
            let clip = Self.clip(notes, Self.la(Int.random(in: 1...max(1, sungNotes), using: &rng)))
            guard let plan = try? Self.plan(clip, shift: shift) else { continue }
            planned += 1
            if shift != 0 { shifted += 1 }
            var written: [UUID: Int] = [:]
            for note in notes { written[note.id] = note.pitch }
            for sung in plan.notes {
                let moved = sung.midi - sung.sourcePitch
                #expect(moved % 12 == 0, "moved by \(moved) semitones")
                #expect(moved == 12 * shift)
                #expect(written[sung.noteID] == sung.sourcePitch, "the source is the written note's own pitch")
            }
            // Every unit's words cover its notes exactly once, contiguously, in order.
            for unit in plan.units {
                let covered = unit.words.flatMap { $0.noteIndices }
                let noEmptyWord = unit.words.allSatisfy { !$0.noteIndices.isEmpty }
                #expect(covered == Array(unit.notes.indices))
                #expect(noEmptyWord)
            }
        }
        #expect(planned >= 250, "control: the seeded clips plan (\(planned) of 300)")
        #expect(shifted >= 150, "control: most move by octaves (\(shifted))")
    }

    @Test("an octave shift outside −2...2 is refused first, with the design's sentence")
    func octaveShiftRange() {
        let clip = Self.clip([Self.note(60, 0, 1)], "la")
        #expect(Self.refusal(clip, shift: 3) == .octaveShiftInvalid(3))
        #expect(Self.refusal(clip, shift: -3) == .octaveShiftInvalid(-3))
        for shift in -2...2 {
            #expect(Self.refusal(clip, shift: shift) == nil, "shift \(shift)")
        }
        let audio = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/sd2-vox.wav"))
        #expect(Self.refusal(audio, shift: 5) == .octaveShiftInvalid(5), "checked before the clip kind")
        #expect(SingPlanRefusal.octaveShiftInvalid(3).sentence
                == "A vocal can only move by whole octaves on its own; to change the song's key use project.transpose.")
    }

    @Test("a shift that would take a note outside MIDI 0...127 is refused, never clamped")
    func targetOutOfRange() {
        #expect(Self.refusal(Self.clip([Self.note(120, 0, 1)], "la"), shift: 1)
                == .targetOutOfRange(pitch: 120, octaveShift: 1))
        #expect(Self.refusal(Self.clip([Self.note(5, 0, 1)], "la"), shift: -1)
                == .targetOutOfRange(pitch: 5, octaveShift: -1))
        #expect(Self.refusal(Self.clip([Self.note(115, 0, 1)], "la"), shift: 1) == nil, "127 is in range")
        #expect(Self.refusal(Self.clip([Self.note(12, 0, 1)], "la"), shift: -1) == nil, "0 is in range")
    }

    // MARK: - Refusals

    @Test("refusals: an audio clip, a clip that plays nothing, a drum track, and the lyrics' own")
    func refusals() {
        let audio = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/sd2-vox.wav"))
        #expect(Self.refusal(audio) == .audioClip)
        #expect(SingPlanRefusal.audioClip.sentence == "Sing needs a melody clip with notes. This one is audio.")

        #expect(Self.refusal(Self.clip([], "la", length: 4)) == .noNotes)
        #expect(Self.refusal(Self.clip([Self.note(60, 4, 1)], "la", length: 4)) == .noNotes,
                "a note starting at the clip's end never plays")

        let melody = Self.clip([Self.note(60, 0, 1)], "la")
        let drums = Track(name: "Drums", kind: .instrument, instrument: InstrumentDescriptor(kind: .drumSynth))
        #expect(Self.refusal(melody, on: drums) == .drumTrack)
        #expect(SingPlanRefusal.drumTrack.sentence
                == "This clip is on a drum track. Pick a melody clip — one with the notes you want sung.")
        let synth = Track(name: "Keys", kind: .instrument, instrument: InstrumentDescriptor(kind: .polySynth))
        #expect(Self.refusal(melody, on: synth) == nil, "control: the same clip on a synth track plans")

        #expect(Self.refusal(Self.clip([Self.note(60, 0, 1)], nil)) == .lyrics(.noWords))
        #expect(Self.refusal(Self.clip([Self.note(60, 0, 1)], "café")) == .lyrics(.notEnglish(word: "café")))
        #expect(Self.refusal(Self.clip([Self.note(60, 0, 1), Self.note(62, 1, 1)], "one two three"))
                == .lyrics(.tooManyWords(words: 3, notes: 2, line: 0)))
        #expect(SingPlanRefusal.lyrics(.noWords).sentence == LyricRefusal.noWords.sentence)
    }

    // MARK: - Units

    @Test("units: whole breath phrases merged up to 15 s, cut at the LARGEST breath near the target")
    func unitsCutAtTheLargestBreath() throws {
        // Seven one-note phrases, in beats (1 beat = 0.5 s). The breath after the
        // fourth is 2 beats (1 s); every other breath is 1 beat.
        let spans: [(Double, Double)] = [(0, 4), (5, 9), (10, 14), (15, 21), (23, 27), (28, 32), (33, 37)]
        let notes = spans.enumerated().map { Self.note(60 + $0.offset, $0.element.0, $0.element.1 - $0.element.0) }
        let plan = try Self.plan(Self.clip(notes, Self.la(7)))
        let units = plan.units.map { unit in unit.notes.map { $0.noteID } }
        let expected = [notes[0...3].map { $0.id }, notes[4...6].map { $0.id }]
        // Cut after the fourth phrase (10.5 s, the 1 s breath), not the latest
        // fitting breath (after the fifth, 13.5 s, a 0.5 s breath).
        #expect(units == expected)
        #expect(Self.close(plan.units[0].spanSeconds, 10.5))
        #expect(Self.close(plan.units[1].onsetSeconds, 11.5))
        #expect(Self.close(plan.units[0].offsetSeconds, -0.24))
        #expect(Self.close(plan.units[1].offsetSeconds, 11.26))
        #expect(plan.warnings.isEmpty)
    }

    @Test("units: a phrase longer than 15 s but under 20 s is a unit of its own, with no warning")
    func longPhraseStandsAlone() throws {
        var notes = [Self.note(60, 0, 4)]                              // 0–2 s
        for k in 0..<9 { notes.append(Self.note(62, 5 + Double(k) * 4, 4)) }   // one 18 s phrase, 2.5–20.5 s
        notes.append(Self.note(64, 42, 4))                              // 21–23 s
        let plan = try Self.plan(Self.clip(notes, Self.la(11)))
        let sizes = plan.units.map { $0.notes.count }
        #expect(sizes == [1, 9, 1])
        #expect(Self.close(plan.units[1].spanSeconds, 18))
        #expect(plan.warnings.isEmpty)
    }

    @Test("units: a breathless line longer than 20 s is cut between two words, with the bar in a warning")
    func overCapLineIsSplitBetweenWords() throws {
        // 52 one-beat notes with no breath (26 s). A 0.1-beat articulation gap
        // after the 25th note is the largest gap near 15 s: the cut goes there.
        let notes = (0..<52).map { Self.note(60 + $0 % 12, Double($0) + ($0 >= 25 ? 0.1 : 0), 1) }
        let plan = try Self.plan(Self.clip(notes, Self.la(52)))
        let sizes = plan.units.map { $0.notes.count }
        #expect(sizes == [25, 27])
        #expect(plan.warnings == [.splitLine(bar: 7)], "the second unit starts at beat 25.1, in bar 7")
        #expect(SingPlanWarning.splitLine(bar: 7).sentence
                == "I had to split a very long line without a breath at bar 7; you may hear a seam.")
    }

    @Test("a single note longer than 20 s is refused; exactly 20 s sings")
    func noteLongerThanTheCap() throws {
        let long = Self.note(60, 0, 41)                                 // 20.5 s
        #expect(Self.refusal(Self.clip([long], "la")) == .noteTooLong(noteID: long.id, seconds: 20.5))
        #expect(SingPlanRefusal.noteTooLong(noteID: long.id, seconds: 20.5).sentence
                == "One note is longer than 20 seconds. Please shorten it or split it.")
        let plan = try Self.plan(Self.clip([Self.note(60, 0, 40)], "la"))
        #expect(plan.units.count == 1)
        #expect(Self.close(plan.units[0].spanSeconds, 20))
    }

    @Test("a word held for longer than 20 s cannot be cut between words, so it is refused")
    func wordLongerThanTheCap() throws {
        let notes = (0..<42).map { Self.note(60, Double($0), 1) }       // 21 s, no breath
        #expect(Self.refusal(Self.clip(notes, "la")) == .wordTooLong(word: "la", seconds: 21))
        // Control: one word per note plans, cut between words.
        let plan = try Self.plan(Self.clip(notes, Self.la(42)))
        #expect(plan.units.count == 2)
    }

    @Test("notes no word sings are left out, and the assigner's warnings are the plan's")
    func unsungNotesAreLeftOut() throws {
        // Three phrases, one word: the first phrase sings, the other two are silent.
        let notes = [Self.note(60, 0, 1), Self.note(62, 1, 1), Self.note(64, 4, 1), Self.note(65, 8, 1)]
        let plan = try Self.plan(Self.clip(notes, "hel-lo"))
        let ids = plan.notes.map { $0.noteID }
        #expect(ids == [notes[0].id, notes[1].id])
        #expect(plan.warnings == [.lyrics(.unsungPhrases(phrases: 2, notes: 2))])
        let words = plan.units.flatMap { $0.words }
        #expect(words == [SingWord(text: "hello", typed: "hel-lo", noteIndices: [0, 1])])

        let held = try Self.plan(Self.clip((0..<4).map { Self.note(60, Double($0), 1) }, "la la"))
        #expect(held.warnings == [.lyrics(.heldWord(word: "la", spareNotes: 2, line: 0))])
        #expect(held.warnings[0].sentence == LyricWarning.heldWord(word: "la", spareNotes: 2, line: 0).sentence)
    }

    // MARK: - Words

    @Test("each word is sent as SUNG, never as typed")
    func wordsAreSentAsSung() throws {
        let notes = (0..<7).map { Self.note(60, Double($0), 1) }
        let plan = try Self.plan(Self.clip(notes, "Twin-kle, star! 3-2-1 go"))
        let words = try #require(plan.units.first).words
        let sung = words.map { $0.text }
        let typed = words.map { $0.typed }
        let indices = words.map { $0.noteIndices }
        #expect(sung == ["Twinkle", "star", "3 2 1", "go"])
        #expect(typed == ["Twin-kle,", "star!", "3-2-1", "go"])
        #expect(indices == [[0, 1], [2], [3, 4, 5], [6]])
    }

    @Test("the plan's word-to-note map IS the one derivation, laid on the monophonic melody")
    func oneDerivation() throws {
        let notes = [Self.note(64, 0, 1), Self.note(60, 0, 1), Self.note(62, 1, 1), Self.note(65, 3, 1)]
        let clip = Self.clip(notes, "one two\nthree")
        let plan = try Self.plan(clip)
        let derived = try SingPlanner.assignment(for: clip, tempoMap: Self.tempo)
        let byHand = try LyricNoteAssigner.assign(LyricTokenizer.tokenize("one two\nthree"),
                                                  notes: SingPlanner.melody(of: clip).notes,
                                                  clipStartBeat: 0, tempoMap: Self.tempo)
        #expect(plan.assignment == derived)
        #expect(derived == byHand)
        let assigned = derived.words.flatMap { $0.noteIDs }
        #expect(!assigned.contains(notes[1].id), "the chord's low note is in no word")
        #expect(assigned.count == 3)
    }

    // MARK: - The signature

    @Test("the signature is stable, moves with what the render depends on, and ignores the rest")
    func signature() throws {
        let notes = [Self.note(60, 0, 1), Self.note(62, 1, 1), Self.note(64, 2, 2)]
        let base = Self.clip(notes, "one two three", start: 4, length: 8)
        let signature = try Self.plan(base).signature
        let isHex = signature.allSatisfy { $0.isHexDigit }
        let again = try Self.plan(base).signature
        #expect(signature.count == 32)
        #expect(isHex)
        #expect(again == signature, "the same clip plans the same")

        func changed(_ edit: (inout Clip) -> Void) throws -> Bool {
            var clip = base
            edit(&clip)
            return try Self.plan(clip).signature != signature
        }
        let pitch = try changed { $0.notes![1].pitch = 63 }
        let length = try changed { $0.notes![2].lengthBeats = 1.5 }
        let word = try changed { $0.lyrics = ClipLyrics(text: "one two four") }
        let place = try changed { $0.startBeat = 6 }
        let shifted = try Self.plan(base, shift: 1).signature
        let slower = try Self.plan(base, tempo: TempoMap(constantBPM: 100)).signature
        #expect(pitch, "a pitch")
        #expect(length, "a note's length")
        #expect(word, "a word")
        #expect(place, "where the clip sits")
        #expect(shifted != signature, "the octave shift")
        #expect(slower != signature, "the tempo")

        let velocity = try changed { $0.notes![0].velocity = 30 }
        let name = try changed { $0.name = "Chorus" }
        let punctuation = try changed { $0.lyrics = ClipLyrics(text: "one, two... three!") }
        let pastTheEnd = try changed { $0.notes!.append(Self.note(70, 9, 1)) }
        #expect(!velocity, "velocity is not sung")
        #expect(!name, "nor is the clip's name")
        #expect(!punctuation, "nor typed punctuation (the words are sent as sung)")
        #expect(!pastTheEnd, "nor a note past the clip's end, which never plays")
    }
}

/// SplitMix64, seeded: the same clips on every run.
private struct SingPlanRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - S3 / S4 (p2-sing-x3, design docs/design/2026-10-06-p2-sing-expansion.md §9.2)

/// The default plan, pinned BEFORE languages existed. ⭐ PIN-BEFORE: `s3Signatures` and `s4Digests` were captured by
/// W8-X3 on 2026-10-06 from the tree before `SingWord.language` / `ClipLyrics.language` existed (runs PB1/PB2 in the
/// lane's STATUS). A golden recorded after the change would pin nothing (design §9 "Pin-before").
extension SingPlannerTests {

    static func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    /// The SING-6 line T1T2 (`Fixtures/Sing/T1T2.json`, the facade's metadata form) as a melody clip at 120 BPM:
    /// one note per pitched entry (seconds × 2 = beats), a word on each `note_type` 2, a `+` on each 3 (the same
    /// word held on), a line break at each rest. "Twinkle + twinkle + little + star how I wonder + what you are",
    /// "hold me + +", "now": 19 notes, three lines, three breath phrases.
    static func t1t2Clip() throws -> Clip {
        let url = try #require(Bundle.module.url(forResource: "T1T2", withExtension: "json", subdirectory: "Fixtures/Sing"))
        let entries = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let entry = try #require(entries.first)
        func list(_ key: String) throws -> [String] {
            try #require(entry[key] as? String).split(separator: " ").map(String.init)
        }
        let durations = try list("duration").compactMap { Double($0) }
        let pitches = try list("note_pitch").compactMap { Int($0) }
        let types = try list("note_type").compactMap { Int($0) }
        let tokens = try list("text")
        try #require(durations.count == pitches.count && pitches.count == types.count && types.count == tokens.count)
        var notes: [MIDINote] = []
        var text = ""
        var newLine = false
        var seconds = 0.0
        for i in durations.indices {
            let start = seconds
            seconds += durations[i]
            guard pitches[i] > 0 else {
                if !text.isEmpty { newLine = true }
                continue
            }
            notes.append(MIDINote(id: fixedID(1_000 + i), pitch: pitches[i], velocity: 100,
                                  startBeat: start * 2, lengthBeats: durations[i] * 2))
            if types[i] == 3 {
                text += " +"
                continue
            }
            if !text.isEmpty { text += newLine ? "\n" : " " }
            text += tokens[i]
            newLine = false
        }
        return Clip(id: fixedID(1), name: "T1T2", startBeat: 0, lengthBeats: notes.map { $0.endBeat }.max() ?? 4,
                    notes: notes, lyrics: ClipLyrics(text: text))
    }

    /// The clips S3 and S4 pin: T1T2 (as written and an octave up), the suite's own signature and word clips
    /// with fixed ids, and a long flow-mode clip with a chord that cuts into two units and holds a word.
    static func s3s4Cases() throws -> [(name: String, clip: Clip, shift: Int)] {
        let t1t2 = try t1t2Clip()
        let base = Clip(id: fixedID(2), name: "Melody", startBeat: 4, lengthBeats: 8,
                        notes: [MIDINote(id: fixedID(201), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
                                MIDINote(id: fixedID(202), pitch: 62, velocity: 100, startBeat: 1, lengthBeats: 1),
                                MIDINote(id: fixedID(203), pitch: 64, velocity: 100, startBeat: 2, lengthBeats: 2)],
                        lyrics: ClipLyrics(text: "one two three"))
        let wordNotes = (0..<7).map {
            MIDINote(id: fixedID(300 + $0), pitch: 60 + $0, velocity: 100, startBeat: Double($0), lengthBeats: 1)
        }
        let words = Clip(id: fixedID(3), name: "Words", startBeat: 0, lengthBeats: 7, notes: wordNotes,
                         lyrics: ClipLyrics(text: "Twin-kle, star! 3-2-1 go"))
        var longNotes: [MIDINote] = []
        for p in 0..<4 {
            for k in 0..<8 {
                longNotes.append(MIDINote(id: fixedID(400 + p * 10 + k), pitch: 55 + p + k, velocity: 100,
                                          startBeat: Double(p * 10 + k), lengthBeats: 1))
            }
        }
        longNotes.append(MIDINote(id: fixedID(499), pitch: 48, velocity: 100, startBeat: 0, lengthBeats: 1))
        let long = Clip(id: fixedID(4), name: "Long", startBeat: 2, lengthBeats: 40, notes: longNotes,
                        lyrics: ClipLyrics(text: la(29) + " sing-ing"))
        return [("T1T2", t1t2, 0), ("T1T2 up an octave", t1t2, 1), ("one two three", base, 0),
                ("words", words, 0), ("long", long, 0)]
    }

    /// Everything in a plan except its signature (S3 pins that), in a canonical text. Note ids are written as
    /// their index in the clip's note list; doubles by their shortest round-trip description.
    static func dump(_ plan: SingPlan, notes clipNotes: [MIDINote]) -> String {
        let index = Dictionary(clipNotes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func ids(_ list: [UUID]) -> String { list.map { index[$0].map(String.init) ?? "?" }.joined(separator: ",") }
        var out = "clip=\(plan.clipID) shift=\(plan.octaveShift) t0=\(plan.t0Seconds) at=\(plan.atBeat)\n"
        for (u, unit) in plan.units.enumerated() {
            out += "unit \(u) offset=\(unit.offsetSeconds) onset=\(unit.onsetSeconds) span=\(unit.spanSeconds)\n"
            for n in unit.notes {
                out += " n \(ids([n.noteID])) \(n.startSeconds) \(n.endSeconds) \(n.midi) \(n.sourcePitch)\n"
            }
            for w in unit.words {
                out += " w \(w.text.debugDescription) \(w.typed.debugDescription) \(w.noteIndices)\n"
            }
        }
        let a = plan.assignment
        out += "assignment \(a.mode.rawValue) phrases=\(a.phraseCount) lines=\(a.lineCount) unsung=\(ids(a.unsungNoteIDs))\n"
        for w in a.words {
            out += " a \(w.word.typed.debugDescription) \(w.word.sung.debugDescription) \(w.word.parts) h\(w.word.holds)"
                + " l\(w.word.line) num=\(w.word.isNumber) en=\(w.word.isEnglish) [\(ids(w.noteIDs))]"
                + " \(w.startBeat) \(w.endBeat) p\(w.phrase) s\(w.syllables) held=\(w.heldNotes)\n"
        }
        for warning in plan.warnings { out += " warn \(warning.sentence)\n" }
        return out
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let s3Signatures: [String] = [
        "855b343074cb71305a019b5a027ad186", "dde826adc96928e5875613fcbf122b2f", "eba76d5447953b8339b715fb359de495",
        "c0fb62a143c9857281920bc6b22c2c48", "b5aefdc2c540fd69cf414bdf1963ec0b",
    ]
    static let s4Digests: [String] = [
        "7f255a54d1a7e2ac842b16fd01333c390f1cfa7d4f03eefe8e904ab621ec6ad1",
        "b5225a9541f3bd9058242affff3f9552e7f5b1fe50374feb529a3beb71c5e912",
        "7e3457b3f544256ee645760e54e89150877f7932d445365c2e3b05823bc843c6",
        "fd47ef7a1a71558e8524db40a451aa88790f69e8a917093cb299bc03ab60b769",
        "a0f979babaee2bd0d41442eb080be6bc14aa47c3f57e2c20fe75e83f2f13b1a7",
    ]

    @Test("S3: each default plan's signature equals its pin-before value")
    func defaultSignatureUnchanged() throws {
        let cases = try Self.s3s4Cases()
        let signatures = try cases.map { try Self.plan($0.clip, shift: $0.shift).signature }
        #expect(signatures == Self.s3Signatures)
    }

    @Test("S4: each whole default plan (units, notes, words, offsets, assignment, warnings) equals its pin-before value")
    func defaultPlanUnchanged() throws {
        let cases = try Self.s3s4Cases()
        let dumps = try cases.map { Self.dump(try Self.plan($0.clip, shift: $0.shift), notes: $0.clip.notes ?? []) }
        let digests = dumps.map(Self.sha256)
        #expect(digests == Self.s4Digests, "\(dumps.joined(separator: "----\n"))")
        #expect(cases.map { $0.clip.lyrics?.text.isEmpty == false } == [true, true, true, true, true], "control")
        // Added after the change (p2-sing-x3): no word of a default plan carries a language.
        let plans = try cases.map { try Self.plan($0.clip, shift: $0.shift) }
        #expect(plans.allSatisfy { plan in plan.units.allSatisfy { unit in unit.words.allSatisfy { $0.language == nil } } })
        #expect(plans.allSatisfy { plan in plan.assignment.words.allSatisfy { $0.word.language == nil } })
    }
}
