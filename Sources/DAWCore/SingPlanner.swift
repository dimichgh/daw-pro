import Foundation

// MARK: - The plan

/// One note as it will be sung (p2-sing-d2, design
/// `docs/design/2026-09-27-p2-sing-integration.md` §3.4 "Output").
public struct SingNote: Equatable, Sendable {
    /// The melody note this comes from.
    public var noteID: UUID
    /// Seconds from the unit's first onset: the singing engine's `startS` /
    /// `endS` (the unit's first note starts at 0).
    public var startSeconds: Double
    public var endSeconds: Double
    /// The pitch sung: `sourcePitch + 12 × octaveShift`, and nothing else
    /// (§3.4 "Octave"). A unit test holds every plan to it.
    public var midi: Int
    /// The melody note's own pitch.
    public var sourcePitch: Int

    public init(noteID: UUID, startSeconds: Double, endSeconds: Double, midi: Int, sourcePitch: Int) {
        self.noteID = noteID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.midi = midi
        self.sourcePitch = sourcePitch
    }
}

/// One lyric word of a unit, and which of the unit's notes it sings.
public struct SingWord: Equatable, Sendable {
    /// What the singing engine reads: `LyricWord.sung` ("twinkle" for the
    /// typed "twin-kle,"; "3 2 1" for "3-2-1"). W7-SD1 measured that the
    /// facade re-splits a hyphen, so the typed form must never be sent.
    public var text: String
    /// As typed, punctuation kept: what a word chip shows.
    public var typed: String
    /// Indices into the unit's `notes`: contiguous, ascending, never empty.
    /// Every note of a unit belongs to exactly one word (the facade refuses
    /// anything else with `wordsDoNotCoverNotes`).
    public var noteIndices: [Int]
    /// The language the facade sings this word in (p2-sing-x3, design
    /// `docs/design/2026-10-06-p2-sing-expansion.md` §6.3): nil is English,
    /// `"zh"` or `"yue"` a Chinese character or pinyin/jyutping syllable
    /// (`LyricWord.language`). Folded into the plan's `signature` only when
    /// set, so an English plan's signature is unchanged (design §9 S3).
    ///
    /// The request builder sends it as the word's `lang`
    /// (`Sources/AIServices/SingJobRequest.swift`, `SingingPhraseWord`;
    /// W8-XL), and the body is facade v2 only when a word carries one (§7.2).
    public var language: String?

    public init(text: String, typed: String, noteIndices: [Int]) {
        self.text = text
        self.typed = typed
        self.noteIndices = noteIndices
    }

    /// A word sung in `language` (nil: English).
    ///
    /// A SEPARATE init, not a defaulted parameter on the old one: the old
    /// init's symbol must stay, because `AIServicesTests` reaches DAWCore only
    /// through `AIServices` and SwiftPM does not recompile it when DAWCore
    /// changes (measured by W8-X3, 2026-10-06: its stale objects failed to
    /// link against a defaulted-parameter init).
    public init(text: String, typed: String, noteIndices: [Int], language: String?) {
        self.text = text
        self.typed = typed
        self.noteIndices = noteIndices
        self.language = language
    }
}

/// One render request's worth of singing: a run of whole breath phrases (or,
/// past the hard cap, part of one), at most `SingPlanner.unitCapSeconds` of
/// notes.
public struct SingUnit: Equatable, Sendable {
    public var notes: [SingNote]
    public var words: [SingWord]
    /// Where this unit's AUDIO starts (its first onset minus
    /// `SingPlanner.leadSeconds`), in seconds from the start of the landed file
    /// (`SingPlan.t0Seconds`). Only the first unit can be negative: when the
    /// melody starts less than the lead after the song's start, the file
    /// starts at 0 and that much of the unit's leading silence is cut.
    public var offsetSeconds: Double
    /// The unit's first onset, in seconds from beat zero.
    public var onsetSeconds: Double
    /// From the first onset to the last note's end, in seconds.
    public var spanSeconds: Double

    public init(notes: [SingNote], words: [SingWord], offsetSeconds: Double, onsetSeconds: Double,
                spanSeconds: Double) {
        self.notes = notes
        self.words = words
        self.offsetSeconds = offsetSeconds
        self.onsetSeconds = onsetSeconds
        self.spanSeconds = spanSeconds
    }
}

/// Everything a sing job needs from the project, frozen when the job starts
/// (design §3.4 "Output").
public struct SingPlan: Equatable, Sendable {
    /// The melody clip.
    public var clipID: UUID
    /// The whole octaves the vocal moves by (−2...2).
    public var octaveShift: Int
    public var units: [SingUnit]
    /// Which word sings which note: the ONE derivation (`SingPlanner.assignment`).
    public var assignment: LyricAssignment
    public var warnings: [SingPlanWarning]
    /// Where the landed file starts, in seconds from beat zero:
    /// `max(0, first sung onset − leadSeconds)`.
    public var t0Seconds: Double
    /// The beat the landed clip goes at: `TempoMap.beat(atSecondsFromZero:)`
    /// of `t0Seconds`.
    public var atBeat: Double
    /// A digest of everything the render depends on (every unit's notes,
    /// target pitches, words and offsets, the placement and the guards). Two
    /// plans with equal signatures ask the engine for the same audio, which
    /// is how landing notices "the melody changed while I was singing"
    /// (design §4.5). A change detector, not a cache key and not a security
    /// hash: 128-bit FNV-1a.
    public var signature: String

    public init(clipID: UUID, octaveShift: Int, units: [SingUnit], assignment: LyricAssignment,
                warnings: [SingPlanWarning], t0Seconds: Double, atBeat: Double, signature: String) {
        self.clipID = clipID
        self.octaveShift = octaveShift
        self.units = units
        self.assignment = assignment
        self.warnings = warnings
        self.t0Seconds = t0Seconds
        self.atBeat = atBeat
        self.signature = signature
    }

    /// Every planned note, in order, across the units.
    public var notes: [SingNote] { units.flatMap(\.notes) }
}

/// Something worth telling the user about a plan that still sings.
public enum SingPlanWarning: Equatable, Sendable {
    /// Two or more different pitches start together at `places` places; the
    /// top note of each is sung (§3.4 "Monophony").
    case chords(places: Int)
    /// A breath phrase longer than `SingPlanner.unitCapSeconds` was cut between
    /// two words, at this 1-based bar (§3.4 "Render units").
    case splitLine(bar: Int)
    /// The word-to-note assigner's own warnings (held words, squeezed words, …).
    case lyrics(LyricWarning)

    /// The sentence the user reads: design §5.7's copy where it has a row.
    public var sentence: String {
        switch self {
        case .chords(let places):
            // §5.7 "Chords", with the singular written out for one place.
            let at = places == 1 ? "1 place" : "\(places) places"
            return "Your tune has chords at \(at); I sang the top note."
        case .splitLine(let bar):
            return "I had to split a very long line without a breath at bar \(bar); you may hear a seam."
        case .lyrics(let warning):
            return warning.sentence
        }
    }
}

/// Why a clip cannot be sung as it is. Never guessed: the planner refuses
/// and says what to change.
public enum SingPlanRefusal: Error, Equatable, Sendable {
    /// §5.7 "Audio clip".
    case audioClip
    /// §5.7 "Drum track".
    case drumTrack
    /// The clip plays no notes. NOT in design §5.7 (the wire's
    /// `singClipHasNoNotes`); provisional copy.
    case noNotes
    /// The lyrics cannot be laid on the notes (§5.7 "No lyrics", "W > N",
    /// "Not English", and the assigner's two provisional ones).
    case lyrics(LyricRefusal)
    /// Not a whole number of octaves in −2...2. The sentence is design §6
    /// row 14's (`singOctaveShiftInvalid`).
    case octaveShiftInvalid(Int)
    /// The octave shift would take a note outside MIDI 0...127. Refused, never
    /// clamped: a clamp would move a sung note by something other than whole
    /// octaves. NOT in design §5.7; provisional copy.
    case targetOutOfRange(pitch: Int, octaveShift: Int)
    /// §5.7 "Note too long".
    case noteTooLong(noteID: UUID, seconds: Double)
    /// One word is held across notes for longer than the unit cap, so no cut
    /// between words can keep a unit under it. NOT in design §5.7;
    /// provisional copy.
    case wordTooLong(word: String, seconds: Double)

    public var sentence: String {
        switch self {
        case .audioClip:
            return "Sing needs a melody clip with notes. This one is audio."
        case .drumTrack:
            return "This clip is on a drum track. Pick a melody clip — one with the notes you want sung."
        case .noNotes:
            // PROVISIONAL (not in design §5.7).
            return "This clip has no notes to sing. Add the tune first, then the words."
        case .lyrics(let refusal):
            return refusal.sentence
        case .octaveShiftInvalid:
            return "A vocal can only move by whole octaves on its own; to change the song's key use project.transpose."
        case .targetOutOfRange:
            // PROVISIONAL (not in design §5.7).
            return "Moving the voice by that many octaves would take some notes out of range. Try a smaller move."
        case .noteTooLong:
            return "One note is longer than 20 seconds. Please shorten it or split it."
        case .wordTooLong(let word, _):
            // PROVISIONAL (not in design §5.7).
            return "'\(word)' is held for longer than 20 seconds. Please give it fewer notes, or add a word."
        }
    }
}

// MARK: - The planner

/// Turns a melody clip and its lyrics into render units (p2-sing-d2, design
/// §3.4). Pure: Foundation only, no store, no engine, no clock.
///
/// ## The notes it sings, in order
///
/// 1. **The notes the clip PLAYS**, by playback's own rule
///    (`MIDIEventSchedule.buildEvents`, `Sources/DAWEngine/MIDISchedule.swift`):
///    a note sounds iff its onset is in `[0, clip length)`, and it stops at
///    `min(its end, clip length)`. DAWCore cannot call that evaluator (it is
///    in DAWEngine), so the rule is restated here and PINNED against it by
///    `SingPlannerPlaybackParityTests` (DAWEngineTests), which compares this
///    melody with the note-on/off pairs the evaluator schedules.
///
///    ⚠️ **Design §3.4 says "loop repeats are expanded by the evaluator
///    playback uses". There is nothing to expand.** A clip has no loop of its
///    own in this tree; the only repeat the evaluator knows is the TRANSPORT
///    cycle (its `onsetEndBeat` window and per-cycle blocks), and that cycle
///    replays the landed vocal together with the melody. Expanding it here
///    would sing every cycle into the file and then play the file again on
///    every cycle.
/// 2. **Canonical order** (`MIDINote.canonicallyOrdered`).
/// 3. **Monophony.** Notes that start together are a chord: the highest is
///    sung and the rest dropped, with a warning when the pitches differ. A
///    note still sounding at the next onset is cut there.
/// 4. **The words** (`assignment(for:tempoMap:)`) are laid on THESE notes,
///    as §3.3 asks ("the melody's notes after §3.4's monophony rule").
/// 5. **Legato.** A gap the tree's one breath rule calls articulation
///    (`PhraseDetection.classify` at `HumanizeLegato.defaultMaxGapBeats`) is
///    closed by extending the earlier note to the next onset, so the engine
///    inserts no tiny rests. A breath stays a rest.
/// 6. Notes no word sings (a phrase left silent because there are fewer words
///    than phrases) are left out: the engine needs every note it is sent
///    covered by exactly one word.
///
/// ## Units
///
/// Greedy, left to right, over the sung notes. A unit is cut only between two
/// breath phrases while it can be: the cut is the largest breath gap among
/// the cuts that make the unit between `unitTargetSeconds − seamSearchSeconds`
/// and `unitTargetSeconds` long (10–15 s), else the latest breath cut that
/// keeps it under the target. A breath phrase longer than the target is a
/// unit of its own while it is under the hard cap (`unitCapSeconds`). One
/// longer than the cap is cut between two WORDS (never inside one), at the
/// largest articulation gap by the same rule, with a "Split line" warning.
/// Design §3.4 fixes 15 s and 20 s; "near that length" is not specified, and
/// the 5 s search window is this implementation's choice [A].
///
/// ## Times and pitches
///
/// Beats become seconds through `TempoMap.seconds(fromBeatZeroTo:)`, so tempo
/// changes are honoured. The target pitch is the melody note plus 12 × the
/// octave shift, and nothing else moves a sung note.
public enum SingPlanner {

    /// Leading silence each unit's audio starts with (design §2.4, `leadS`).
    public static let leadSeconds = 0.24
    /// Trailing silence after each unit's last note (`trailS`).
    public static let trailSeconds = 0.24
    /// The unit length the greedy merge aims for (design §3.4).
    public static let unitTargetSeconds = 15.0
    /// No unit is longer than this; a single note longer than this is refused.
    public static let unitCapSeconds = 20.0
    /// How far below a limit a cut still counts as "near" it, where the
    /// largest gap wins [A].
    public static let seamSearchSeconds = 5.0
    /// The whole octaves a vocal may move by on its own.
    public static let octaveShiftRange = -2...2

    // MARK: The melody

    /// A clip's melody as the singer follows it.
    public struct Melody: Equatable, Sendable {
        /// The notes, one at a time, in canonical order, clip-relative beats.
        public var notes: [MIDINote]
        /// Attack points where two or more DIFFERENT pitches start together.
        public var chordPlaces: Int

        public init(notes: [MIDINote], chordPlaces: Int) {
            self.notes = notes
            self.chordPlaces = chordPlaces
        }
    }

    /// Steps 1–3: the notes the clip plays, in canonical order, one at a time.
    /// Empty for an audio clip.
    public static func melody(of clip: Clip) -> Melody {
        let voices = monophonic(clip)
        return Melody(notes: voices.notes.map {
            MIDINote(id: $0.id, pitch: $0.pitch, velocity: $0.velocity,
                     startBeat: $0.startBeat, lengthBeats: $0.endBeat - $0.startBeat)
        }, chordPlaces: voices.chordPlaces)
    }

    /// Which word sings which note for `clip`'s lyrics. **THE ONE
    /// DERIVATION:** splitting a clip's text (`ClipLyrics.WordPlacement`), the
    /// sing plan and, later, `clip.getLyrics` all ask this, so the words a
    /// chip shows are the words that are sung. A clip without lyrics throws
    /// `.noWords`.
    public static func assignment(for clip: Clip, tempoMap: TempoMap) throws(LyricRefusal) -> LyricAssignment {
        try LyricNoteAssigner.assign(LyricTokenizer.tokenize(clip.lyrics?.text ?? "", language: clip.lyrics?.language),
                                     notes: melody(of: clip).notes,
                                     clipStartBeat: clip.startBeat, tempoMap: tempoMap)
    }

    /// A note of the melody with its end in beats kept exactly (a `MIDINote`
    /// would floor a sliver's length at `MIDINote.minLengthBeats`).
    struct Voice: Equatable, Sendable {
        var id: UUID
        var pitch: Int
        var velocity: Int
        var startBeat: Double
        var endBeat: Double
    }

    /// Steps 1–3 with exact ends.
    /// Step 1 alone: every note the clip plays, chords and overlaps included,
    /// in canonical order, each ending at `min(its end, clip length)`. What
    /// `SingPlannerPlaybackParityTests` compares with the playback evaluator.
    static func played(_ clip: Clip) -> [Voice] {
        guard let notes = clip.notes else { return [] }
        return MIDINote.canonicallyOrdered(notes.filter { $0.startBeat < clip.lengthBeats }).map {
            Voice(id: $0.id, pitch: $0.pitch, velocity: $0.velocity,
                  startBeat: $0.startBeat, endBeat: min($0.endBeat, clip.lengthBeats))
        }
    }

    static func monophonic(_ clip: Clip) -> (notes: [Voice], chordPlaces: Int) {
        let played = played(clip)
        // 2 + 3. One note per onset: the highest pitch; for the same pitch the
        // longest; then the first in canonical order.
        var voices: [Voice] = []
        var chordPlaces = 0
        var k = 0
        while k < played.count {
            var group = [played[k]]
            k += 1
            while k < played.count, played[k].startBeat == group[0].startBeat {
                group.append(played[k])
                k += 1
            }
            if Set(group.map(\.pitch)).count > 1 { chordPlaces += 1 }
            var top = group[0]
            for note in group.dropFirst()
            where note.pitch > top.pitch || (note.pitch == top.pitch && note.endBeat > top.endBeat) {
                top = note
            }
            voices.append(top)
        }
        // A note still sounding at the next onset stops there.
        for i in voices.indices.dropLast() where voices[i].endBeat > voices[i + 1].startBeat {
            voices[i].endBeat = voices[i + 1].startBeat
        }
        return (voices, chordPlaces)
    }

    // MARK: The plan

    /// Plans `clip`, which lives on `track`, for singing `octaveShift` whole
    /// octaves away from the written melody.
    ///
    /// Refusals, in the order they are checked: the octave shift, an audio
    /// clip, a clip that plays no notes, a drum track, the lyrics (none, too
    /// many words, not English, markup that does not fit), a target outside
    /// MIDI 0...127, a note longer than the cap, a word held longer than it.
    public static func plan(clip: Clip, on track: Track, tempoMap: TempoMap, meterMap: MeterMap,
                            octaveShift: Int) throws(SingPlanRefusal) -> SingPlan {
        guard octaveShiftRange.contains(octaveShift) else { throw .octaveShiftInvalid(octaveShift) }
        guard clip.isMIDI else { throw .audioClip }
        let (voices, chordPlaces) = monophonic(clip)
        guard !voices.isEmpty else { throw .noNotes }
        // The tree's one drum-track rule (our drum machine, or a percussion
        // sound bank), which `project.transpose` also skips by.
        guard !ProjectTranspose.isDrumTrack(track) else { throw .drumTrack }
        let assignment: LyricAssignment
        do throws(LyricRefusal) {
            assignment = try Self.assignment(for: clip, tempoMap: tempoMap)
        } catch {
            throw .lyrics(error)
        }

        // Legato (step 5), on the whole melody: a gap the one breath rule calls
        // articulation is closed to an exact abut, never an overlap.
        var legato = voices
        for i in legato.indices.dropLast() {
            let gap = legato[i + 1].startBeat - legato[i].endBeat
            if PhraseDetection.classify(gapBeats: gap, maxGapBeats: HumanizeLegato.defaultMaxGapBeats)
                == .articulation {
                legato[i].endBeat = legato[i + 1].startBeat
            }
        }

        // The sung notes (step 6), in seconds from beat zero.
        var wordOfNote: [UUID: Int] = [:]
        for (w, word) in assignment.words.enumerated() {
            for id in word.noteIDs { wordOfNote[id] = w }
        }
        let base = clip.startBeat
        let sung: [Sung] = voices.indices.compactMap { i in
            guard let w = wordOfNote[voices[i].id] else { return nil }
            return Sung(voice: voices[i],
                        start: tempoMap.seconds(fromBeatZeroTo: base + voices[i].startBeat),
                        end: tempoMap.seconds(fromBeatZeroTo: base + legato[i].endBeat),
                        writtenEnd: tempoMap.seconds(fromBeatZeroTo: base + voices[i].endBeat),
                        word: w, phrase: assignment.words[w].phrase)
        }
        guard !sung.isEmpty else { throw .noNotes }         // unreachable: a word always has a note
        for note in sung where !MIDINote.pitchRange.contains(note.voice.pitch + 12 * octaveShift) {
            throw .targetOutOfRange(pitch: note.voice.pitch, octaveShift: octaveShift)
        }
        for note in sung where note.end - note.start > unitCapSeconds {
            throw .noteTooLong(noteID: note.voice.id, seconds: note.end - note.start)
        }

        let (ranges, cutBars) = try Self.units(sung, words: assignment.words, clipStartBeat: base,
                                               meterMap: meterMap)

        // Placement (§3.4): the file starts one lead before the first sung note,
        // never before the song's start.
        let t0 = max(0, sung[0].start - leadSeconds)
        let atBeat = tempoMap.beat(atSecondsFromZero: t0)
        let renderUnits: [SingUnit] = ranges.map { range in
            let onset = sung[range.lowerBound].start
            var words: [SingWord] = []
            var lastWord = -1
            for (j, i) in range.enumerated() {
                let w = sung[i].word
                if w == lastWord {
                    words[words.count - 1].noteIndices.append(j)
                } else {
                    words.append(SingWord(text: assignment.words[w].word.sung,
                                          typed: assignment.words[w].word.typed, noteIndices: [j],
                                          language: assignment.words[w].word.language))
                    lastWord = w
                }
            }
            return SingUnit(
                notes: range.map { i in
                    SingNote(noteID: sung[i].voice.id, startSeconds: sung[i].start - onset,
                             endSeconds: sung[i].end - onset, midi: sung[i].voice.pitch + 12 * octaveShift,
                             sourcePitch: sung[i].voice.pitch)
                },
                words: words, offsetSeconds: onset - leadSeconds - t0, onsetSeconds: onset,
                spanSeconds: sung[range.upperBound - 1].end - onset)
        }

        var warnings: [SingPlanWarning] = chordPlaces > 0 ? [.chords(places: chordPlaces)] : []
        warnings += assignment.warnings.map { .lyrics($0) }
        warnings += cutBars.map { .splitLine(bar: $0) }
        return SingPlan(clipID: clip.id, octaveShift: octaveShift, units: renderUnits, assignment: assignment,
                        warnings: warnings, t0Seconds: t0, atBeat: atBeat,
                        signature: signature(units: renderUnits, t0Seconds: t0, atBeat: atBeat,
                                             octaveShift: octaveShift))
    }

    /// A sung note: its melody note, its sung start and (legato) end, its
    /// written end, all in seconds from beat zero, and its word and phrase.
    struct Sung {
        var voice: Voice
        var start: Double
        var end: Double
        var writtenEnd: Double
        var word: Int
        var phrase: Int
    }

    /// The units, as ranges of `sung`, and the 1-based bars where a phrase
    /// longer than the cap was cut between two words. See the type's
    /// "Units" section for the rule.
    static func units(_ sung: [Sung], words: [AssignedLyricWord], clipStartBeat: Double,
                      meterMap: MeterMap) throws(SingPlanRefusal) -> (ranges: [Range<Int>], cutBars: [Int]) {
        let n = sung.count
        func span(_ from: Int, _ to: Int) -> Double { sung[to].end - sung[from].start }
        // A boundary b is between sung notes b and b + 1.
        func isBreath(_ b: Int) -> Bool { sung[b].phrase != sung[b + 1].phrase }
        func isBetweenWords(_ b: Int) -> Bool { sung[b].word != sung[b + 1].word }
        func gap(_ b: Int) -> Double { sung[b + 1].start - sung[b].writtenEnd }
        // The largest gap among the cuts that make the unit `limit − seam ...
        // limit` long (a tie goes to the later cut), else the latest cut that
        // keeps it within `limit`.
        func bestCut(_ candidates: [Int], from s: Int, limit: Double) -> Int? {
            let fitting = candidates.filter { span(s, $0) <= limit }
            guard let latest = fitting.last else { return nil }
            let near = fitting.filter { span(s, $0) >= limit - seamSearchSeconds }
            guard var best = near.first else { return latest }
            for b in near.dropFirst() where gap(b) >= gap(best) { best = b }
            return best
        }

        var ranges: [Range<Int>] = []
        var cutBars: [Int] = []
        var s = 0
        while s < n {
            if span(s, n - 1) <= unitTargetSeconds {
                ranges.append(s..<n)
                break
            }
            let breaths = (s..<(n - 1)).filter(isBreath)
            let cut: Int
            if let c = bestCut(breaths, from: s, limit: unitTargetSeconds) {
                cut = c
            } else if let first = breaths.first, span(s, first) <= unitCapSeconds {
                cut = first                                   // one phrase past the target, under the cap
            } else if breaths.isEmpty, span(s, n - 1) <= unitCapSeconds {
                ranges.append(s..<n)                          // the rest is one phrase under the cap
                break
            } else {
                // The phrase starting at s is longer than the cap: cut it between
                // two words, never inside one.
                let phraseLast = breaths.first ?? (n - 1)
                let wordCuts = (s..<phraseLast).filter(isBetweenWords)
                guard let c = bestCut(wordCuts, from: s, limit: unitTargetSeconds)
                        ?? wordCuts.last(where: { span(s, $0) <= unitCapSeconds }) else {
                    let w = sung[s].word
                    var last = s
                    while last + 1 < n, sung[last + 1].word == w { last += 1 }
                    throw .wordTooLong(word: words[w].word.sung, seconds: span(s, last))
                }
                cut = c
                cutBars.append(meterMap.barBeat(atBeat: clipStartBeat + sung[c + 1].voice.startBeat).bar + 1)
            }
            ranges.append(s..<(cut + 1))
            s = cut + 1
        }
        return (ranges, cutBars)
    }

    // MARK: The signature

    /// A digest of everything the render depends on, in a canonical text:
    /// doubles by their bit patterns, word texts length-prefixed, a word's
    /// language (`;l:zh`) ONLY when it has one, so a plan of English words
    /// has the signature it had before languages existed (design
    /// 2026-10-06 §9 S3, `SingPlannerTests.defaultSignatureUnchanged`). Two passes
    /// of 64-bit FNV-1a with different salts (the `Groove.builtinID`
    /// precedent), so no import beyond Foundation.
    static func signature(units: [SingUnit], t0Seconds: Double, atBeat: Double, octaveShift: Int) -> String {
        var text = "sing-plan-v1|lead:\(leadSeconds.bitPattern)|trail:\(trailSeconds.bitPattern)"
            + "|shift:\(octaveShift)|t0:\(t0Seconds.bitPattern)|beat:\(atBeat.bitPattern)"
        for unit in units {
            text += "|unit:\(unit.offsetSeconds.bitPattern):\(unit.onsetSeconds.bitPattern)"
            for note in unit.notes {
                text += ";n:\(note.startSeconds.bitPattern),\(note.endSeconds.bitPattern),\(note.midi)"
            }
            for word in unit.words {
                text += ";w:\(word.text.utf8.count):\(word.text)@"
                    + word.noteIndices.map(String.init).joined(separator: ",")
                if let language = word.language { text += ";l:\(language)" }
            }
        }
        func fnv1a(salt: String) -> UInt64 {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in salt.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return hash
        }
        func hex(_ value: UInt64) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }
        return hex(fnv1a(salt: "sing-plan.hi|")) + hex(fnv1a(salt: "sing-plan.lo|"))
    }
}
