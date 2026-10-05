import Foundation

// m23-cv — ONE-FINGER CHORDS: the harmonic vocabulary and the voicing engine.
//
// ═══ WHY THIS FILE EXISTS, AND WHY IT IS PURE ═══
//
// The user has no MIDI keyboard and is not a trained musician (their own words).
// m23-ct gave them one key = one note; this gives them one key = one CHORD. The
// part that decides whether that sounds like music rather than like a beginner
// stacking root-position triads is **voicing**, and voicing is arithmetic on
// pitch numbers — no clock, no engine, no UI. So it lives here, headless, on the
// exact idiom `BreathContour` and `MusicalTypingRouting` already established: a
// free `enum` namespace of pure functions over value types.
//
// Everything below is a function of its arguments. The same chord, the same
// previous voicing and the same preset always produce a byte-identical pitch
// array — which is what makes it unit-testable without an audio device and safe
// to call from a wire verb (`chord.voice`) with no engine involvement at all.
//
// ═══ ONE HOME FOR THE HARMONIC VOCABULARY ═══
//
// ⚠️ **`m23-cq-3` (the chord track) MUST EXTEND THESE TYPES RATHER THAN MINT ITS
// OWN.** That item is a different, larger product — a project-wide timeline lane
// other tracks follow — but a second `ChordSymbol`/`ChordQuality` that disagrees
// with this one about what "Am7" means is exactly the divergence this codebase's
// "ONE home" discipline exists to prevent. `docs/research/spike-chord-buttons.md`
// §7.1 names this seam explicitly so nobody re-derives it.
//
// Two existing ONE-homes are REFERENCED here rather than re-declared:
//   * `KeyEstimate.pitchClassesSharp` — the repo's SOLE pitch-class-name array
//     (`AudioAnalysis.swift`), the same one `Fundamental.noteName` reads.
//   * `AuditionController.maxVoices` — the hard polyphony ceiling every live
//     path shares.
//
// ⚠️ **`KeyEstimate.mode` IS A BARE `String` ("major"/"minor"), NOT AN ENUM** —
// measured, not assumed (`AudioAnalysis.swift:40`). `KeyMode` below is therefore
// a NEW type, and its raw values are those exact two strings so the two can be
// bridged in one initialiser instead of by a mapping table someone has to keep
// in step.

// MARK: - Key mode

/// Major or natural minor — the two scales this feature offers.
///
/// ⚠️ **DELIBERATELY TWO, NOT SEVEN.** Dorian/Mixolydian/etc. are real and cheap
/// to add later (the scale is one array of intervals), but a beginner picking a
/// key from a list of seven modes is being asked the question this feature exists
/// to answer for them. The raw values match `KeyEstimate.mode`'s strings so a
/// future "default the picker to the project's detected key" (§7.5 phase 3) is a
/// direct construction rather than a translation.
public enum KeyMode: String, Sendable, Codable, Equatable, CaseIterable {
    case major
    case minor

    /// Semitone offsets of the scale degrees above the tonic.
    ///
    /// Natural minor (Aeolian) rather than harmonic/melodic: it is the one whose
    /// seventh degree gives the `VII` of `i–VI–III–VII`, the minor progression
    /// this feature ships as a preset (`spike-chord-buttons.md` §2.2).
    public var scaleIntervals: [Int] {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        }
    }

    /// Beginner-readable, for the key picker. Never "Ionian"/"Aeolian".
    public var displayName: String {
        switch self {
        case .major: return "major"
        case .minor: return "minor"
        }
    }
}

// MARK: - Chord quality

/// What kind of chord, independent of its root.
///
/// The eight `spike-chord-buttons.md` §7.1 names, and no more: they cover every
/// progression in §2.2's corpus table (the diatonic seven of either mode, plus
/// the dominant 7th the 12-bar blues wants and the sus4 that shows up as a
/// pop suspension). Extended qualities (9ths/11ths/13ths, the lo-fi/neo-soul
/// colour) are purely additive — a new case plus a row in `intervals`.
public enum ChordQuality: String, Sendable, Codable, Equatable, CaseIterable {
    case major
    case minor
    case diminished
    case augmented
    case major7
    case minor7
    case dominant7
    /// Half-diminished (m7♭5) — the seventh chord on the leading tone of a major
    /// key, and on the second degree of a minor key. Present because the diatonic
    /// seven in seventh-chord density is otherwise a lie: `vii°7` in a major key
    /// is a HALF-diminished chord, not a fully-diminished one, and shipping the
    /// wrong one would be a wrong note nobody could see.
    case halfDiminished7
    case suspended4

    /// Semitone offsets above the root, ascending, root first.
    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        case .dominant7: return [0, 4, 7, 10]
        case .halfDiminished7: return [0, 3, 6, 10]
        case .suspended4: return [0, 5, 7]
        }
    }

    /// The suffix printed after the root name: `C`, `Cm`, `Cdim`, `Cmaj7`, …
    ///
    /// ⚠️ **BEGINNER-READABLE ASCII, NOT ENGRAVER'S NOTATION.** `dim` rather than
    /// `°`, `m7b5` rather than `⦰`. Rule 6 of the design language: a user should
    /// not need to know a glyph to read what they just played, and these strings
    /// also travel over the wire and through the MCP tool where a musical symbol
    /// is a liability.
    public var symbolSuffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .diminished: return "dim"
        case .augmented: return "aug"
        case .major7: return "maj7"
        case .minor7: return "m7"
        case .dominant7: return "7"
        case .halfDiminished7: return "m7b5"
        case .suspended4: return "sus4"
        }
    }

    /// Whether a Roman numeral for this quality is written in lower case.
    var numeralIsLowercase: Bool {
        switch self {
        case .minor, .diminished, .minor7, .halfDiminished7: return true
        case .major, .augmented, .major7, .dominant7, .suspended4: return false
        }
    }

    /// The mark that follows a Roman numeral: `vii°`, `III+`, `V7`, `Imaj7`.
    var numeralSuffix: String {
        switch self {
        case .major, .minor: return ""
        case .diminished: return "°"
        case .augmented: return "+"
        case .major7: return "maj7"
        case .minor7, .dominant7: return "7"
        case .halfDiminished7: return "ø7"
        case .suspended4: return "sus4"
        }
    }
}

// MARK: - Chord symbol

/// A chord as a name: a root pitch class plus a quality. **No octave, no
/// voicing** — where the notes actually sit is `ChordVoicing.voice`'s job, and
/// keeping the two apart is what lets one symbol be voiced differently by a
/// piano and a bass.
public struct ChordSymbol: Sendable, Codable, Equatable, Hashable {
    /// 0 = C, 1 = C♯ … 11 = B. Normalised into 0…11 on construction, so a caller
    /// that hands in a raw MIDI note or a negative transposition still gets a
    /// well-formed symbol rather than an index crash.
    public let rootPitchClass: Int
    public let quality: ChordQuality

    public init(rootPitchClass: Int, quality: ChordQuality) {
        let count = KeyEstimate.pitchClassesSharp.count
        self.rootPitchClass = ((rootPitchClass % count) + count) % count
        self.quality = quality
    }

    /// The pitch classes this chord contains, ascending from the root, wrapped
    /// into 0…11. Order is preserved (root, third, fifth, seventh) — the voicing
    /// engine relies on it to know which tone is droppable.
    public var pitchClasses: [Int] {
        let count = KeyEstimate.pitchClassesSharp.count
        return quality.intervals.map { (rootPitchClass + $0) % count }
    }

    /// `"C"`, `"Dm"`, `"G7"`, `"Bdim"`. Sharps only — this repo has exactly one
    /// pitch-class-name array and it is the sharp one; a private flats table here
    /// would be the competing home `Fundamental.noteName` explicitly forbids.
    public var name: String {
        KeyEstimate.pitchClassesSharp[rootPitchClass] + quality.symbolSuffix
    }

    /// Reads a chord symbol back from text: `"C"`, `"Am"`, `"F#m7"`, `"Bb"`,
    /// `"Gsus4"`, `"Bm7b5"`. Returns nil for anything it does not understand
    /// rather than guessing.
    ///
    /// ⭐ **NIL, NEVER A SILENT DEFAULT.** A parser that answered "C major" for an
    /// unrecognised string would hand an agent a wrong chord that looks exactly
    /// like a right one — this tree's characteristic failure mode. The caller
    /// turns nil into an error message naming what it could not read.
    ///
    /// ⚠️ **FLATS ARE ACCEPTED ON INPUT AND NEVER PRODUCED ON OUTPUT.** `"Bb"`
    /// parses (an agent or a human will write it), and `name` will spell the
    /// result `"A#"`, because this repo has exactly one pitch-class-name array.
    /// The asymmetry is deliberate and is better than either refusing common
    /// input or minting a second naming table.
    public static func parse(_ text: String) -> ChordSymbol? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        guard let letter = rest.first else { return nil }
        let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5,
                                          "G": 7, "A": 9, "B": 11]
        guard var root = naturals[Character(letter.uppercased())] else { return nil }
        rest = rest.dropFirst()
        if rest.first == "#" || rest.first == "♯" { root += 1; rest = rest.dropFirst() }
        else if rest.first == "b" || rest.first == "♭" {
            // ⚠️ Only when a suffix FOLLOWS or the string ends — "Bb" is B-flat,
            // but the "b" in "Bbm7b5"'s tail is part of the quality. Handled by
            // consuming at most one accidental here and letting the quality table
            // match the remainder verbatim.
            root -= 1
            rest = rest.dropFirst()
        }
        let suffix = String(rest)
        // Longest match first, so "maj7" is never read as "m" + "aj7".
        let byLength = ChordQuality.allCases.sorted {
            $0.symbolSuffix.count > $1.symbolSuffix.count
        }
        for quality in byLength where quality.symbolSuffix == suffix {
            return ChordSymbol(rootPitchClass: root, quality: quality)
        }
        return nil
    }
}

// MARK: - Instrument voicing presets

/// The five instrument families this feature voices differently, answering the
/// user's own question — *"presets of the chords and settings based on instrument
/// being played/selected"*.
///
/// ⚠️ **THIS IS NOT `InstrumentFamily`, AND THAT IS A DELIBERATE, NARROW
/// DIVERGENCE WITH A REASON.** `InstrumentFamily`
/// (`InstrumentFrequencyReference.swift:116`) is the repo's instrument-category
/// enum and its own header says it covers percussion / bass / guitar / piano /
/// vocals with **"NO bowed strings and NO winds in v1"** — it has no `.pad` and
/// no `.strings` case, which are two of the five this table needs.
/// `spike-chord-buttons.md` §7.1 recommends GROWING that enum rather than adding
/// a parallel one, and that is still the right end state (§7.5 phase 3). It is
/// deliberately not done here: `InstrumentFamily` is `Codable` and persisted
/// inside frequency-reference data, so adding cases is a migration question that
/// has nothing to do with chords, and doing it inside this item would couple a
/// performance feature to a stored format. **This enum is a VOICING STYLE, not an
/// instrument identity** — that is the honest distinction, and it is why the two
/// can coexist until phase 3 merges them.
public enum VoicingPresetKind: String, Sendable, Codable, Equatable, CaseIterable {
    case piano
    case pad
    case guitar
    case bass
    case strings

    /// The label the picker shows.
    public var displayName: String {
        switch self {
        case .piano: return "Piano"
        case .pad: return "Pad"
        case .guitar: return "Guitar"
        case .bass: return "Bass"
        case .strings: return "Strings"
        }
    }

    /// One line a beginner can act on, for the picker's help text. Says what the
    /// preset DOES, never what it is called.
    public var summary: String {
        switch self {
        case .piano:
            return "Bass note low, chord in the middle — like two hands on a piano."
        case .pad:
            return "Spread wide and high, with 7ths, to sit under everything else."
        case .guitar:
            return "Root-position triads in a guitar's range, the way a strum sits."
        case .bass:
            return "One note: the root. A bass playing a whole chord is the classic mistake."
        case .strings:
            return "Wide open spacing across a big range, like a section rather than an organ."
        }
    }
}

/// How far apart adjacent voices are allowed to sit.
public enum VoicingSpacing: String, Sendable, Codable, Equatable, CaseIterable {
    /// Tones stacked as tightly as the chord allows — a pianist's close position.
    case close
    /// Spread over more than an octave (drop-2 / drop-3 shapes, §5.4). A close
    /// string or pad chord reads as an organ; the spread is what makes it read as
    /// several players.
    case open
}

/// How many tones the chord carries.
public enum ChordDensity: String, Sendable, Codable, Equatable, CaseIterable {
    /// Three tones — root, third, fifth.
    case triad
    /// Four tones — the diatonic seventh. §2.2's lo-fi / neo-soul / deep-house
    /// row is literally the same progressions re-voiced with 7ths.
    case seventh
}

/// Everything about an instrument that changes how a chord should be laid out.
///
/// A value type with public members so a caller (the wire verb, a test, a future
/// panel) can build a one-off preset without this file having to anticipate it.
public struct InstrumentVoicingPreset: Sendable, Codable, Equatable {
    public var kind: VoicingPresetKind
    /// Whether a separate bass note is placed BELOW the chord body (§5.4: "even a
    /// simple version — root doubled an octave below a compact chord voiced above
    /// — avoids most of the 'toy' sound on its own").
    public var playsBassNote: Bool
    /// Where that bass note may sit. Ignored when `playsBassNote` is false.
    public var bassWindow: ClosedRange<Int>
    /// The hard bound on every pitch of the chord body. **Nothing this function
    /// returns is ever outside it** — that is a pinned property, not an aim.
    public var bodyWindow: ClosedRange<Int>
    /// Total tones including the bass note. Capped against
    /// `ChordVoicing.maxVoicedNotes` so a chord can never eat the live path's
    /// 8-voice ceiling on its own.
    public var maxNotes: Int
    public var spacing: VoicingSpacing
    public var density: ChordDensity
    /// Only the root sounds — the bass answer. `bodyWindow` is then the range the
    /// single note is placed in.
    public var rootOnly: Bool
    /// **The mud floor** (§5.3). Any pair of ADJACENT sounding pitches whose
    /// interval is not a fifth or an octave must have its UPPER note at or above
    /// this MIDI number, or the two stop reading as harmony and start reading as
    /// mud.
    public var mudFloorMIDI: Int
    /// Candidates spanning fewer semitones top-to-bottom than this are discarded.
    /// 0 for close presets; 12 for open ones, per §5.4's "no interval smaller than
    /// a third between adjacent chord tones… spreading the chord to more than an
    /// octave".
    public var minimumSpanSemitones: Int
    /// A cost added to any candidate that is NOT in root position, so a preset can
    /// PREFER root position without forbidding the alternatives.
    ///
    /// ⭐ **NON-ZERO FOR GUITAR ONLY, AND THAT IS MEASURED RATHER THAN TASTE.**
    /// De Clercq & Temperley hand-coded the 100 highest-ranked rock songs and
    /// found **94.1 % of chords in root position** (§2.3) — a fact about guitars
    /// and full-band arrangements, not about keyboards. On guitar, root position
    /// is the idiomatic sound; on a lone keyboard voice carrying a whole song it
    /// is the beginner sound (§5.1). So the bias is per-preset rather than global.
    public var rootPositionBias: Int
    /// Where the FIRST chord of a session sits when there is no previous voicing
    /// to lead from — the root of the home voicing.
    public var homeRootMIDI: Int

    public init(kind: VoicingPresetKind,
                playsBassNote: Bool,
                bassWindow: ClosedRange<Int>,
                bodyWindow: ClosedRange<Int>,
                maxNotes: Int,
                spacing: VoicingSpacing,
                density: ChordDensity,
                rootOnly: Bool,
                mudFloorMIDI: Int,
                minimumSpanSemitones: Int,
                rootPositionBias: Int,
                homeRootMIDI: Int) {
        self.kind = kind
        self.playsBassNote = playsBassNote
        self.bassWindow = bassWindow
        self.bodyWindow = bodyWindow
        self.maxNotes = maxNotes
        self.spacing = spacing
        self.density = density
        self.rootOnly = rootOnly
        self.mudFloorMIDI = mudFloorMIDI
        self.minimumSpanSemitones = minimumSpanSemitones
        self.rootPositionBias = rootPositionBias
        self.homeRootMIDI = homeRootMIDI
    }

    /// The shipped preset for a kind. **The registers are cited, not invented** —
    /// see each case.
    public static func preset(for kind: VoicingPresetKind) -> InstrumentVoicingPreset {
        switch kind {
        case .piano:
            // Piano's full range is MIDI 21–108 (`InstrumentFrequencyReference
            // .swift:990`, "A0–C8"). §6 puts the BASS note at ~36–48 (C2–C3) and
            // the chord body at ~60–72 (C4–C5): a sub-window matching how a
            // pianist actually splits hands. The body's top is widened here to
            // A5 (81) for one stated reason — an inversion of a C4-rooted seventh
            // already reaches 74, so a 60…72 hard bound would leave nearest-tone
            // voice leading (§5.2) with almost nowhere to go and would collapse
            // to root position, which is the sound this whole module exists to
            // avoid. The HOME root stays at middle C, which is where the app's
            // own piano-roll gutter draws its landmark.
            return InstrumentVoicingPreset(
                kind: .piano, playsBassNote: true, bassWindow: 36...48,
                bodyWindow: 55...81, maxNotes: 4, spacing: .close, density: .triad,
                rootOnly: false, mudFloorMIDI: defaultMudFloorMIDI,
                minimumSpanSemitones: 0, rootPositionBias: 0, homeRootMIDI: 60)
        case .pad:
            // §6: body ~60–79 (C4–G5), deliberately clear of the sub-bass region
            // because a pad is held UNDER everything else in a mix; no separate
            // bass note for the same reason. Widened to 84 (C6) so an open/drop
            // voicing of a seventh chord fits inside the window rather than being
            // discarded by it. Extended colour (7ths) is idiomatic here (§2.2's
            // lo-fi / deep-house rows).
            return InstrumentVoicingPreset(
                kind: .pad, playsBassNote: false, bassWindow: 60...84,
                bodyWindow: 60...84, maxNotes: 5, spacing: .open, density: .seventh,
                rootOnly: false, mudFloorMIDI: defaultMudFloorMIDI,
                minimumSpanSemitones: 12, rootPositionBias: 0, homeRootMIDI: 60)
        case .guitar:
            // MIDI 40–76 (E2–E5), verified at `InstrumentFrequencyReference
            // .swift:881,928` with the citation "guitar standard tuning". Root
            // position carries a real bias here and nowhere else — see
            // `rootPositionBias`.
            return InstrumentVoicingPreset(
                kind: .guitar, playsBassNote: false, bassWindow: 40...76,
                bodyWindow: 40...76, maxNotes: 4, spacing: .close, density: .triad,
                rootOnly: false, mudFloorMIDI: defaultMudFloorMIDI,
                minimumSpanSemitones: 0, rootPositionBias: guitarRootPositionBias,
                homeRootMIDI: 52)
        case .bass:
            // MIDI 28–43 (E1–G2), verified at `InstrumentFrequencyReference
            // .swift:779,838` (citations "Wikipedia, Bass guitar (New Grove
            // tuning)" / "Wikipedia, Double bass").
            //
            // ⭐ ROOT ONLY, AND THIS IS THE ANSWER TO THE USER'S OWN QUESTION.
            // §6: handing a bass instrument the full 3–5 note chord "is the single
            // most common way a naive auto-harmonizer sounds wrong". A single note
            // is not a simplification here — it is how basslines work.
            return InstrumentVoicingPreset(
                kind: .bass, playsBassNote: false, bassWindow: 28...43,
                bodyWindow: 28...43, maxNotes: 1, spacing: .close, density: .triad,
                rootOnly: true, mudFloorMIDI: defaultMudFloorMIDI,
                minimumSpanSemitones: 0, rootPositionBias: 0, homeRootMIDI: 40)
        case .strings:
            // §6: a wide spread, ~48–84 (C3–C6), "deliberately much wider
            // top-to-bottom than piano's window", open spacing, because a
            // close-position string chord reads as an organ rather than as a
            // section physically spread across register.
            return InstrumentVoicingPreset(
                kind: .strings, playsBassNote: false, bassWindow: 48...84,
                bodyWindow: 48...84, maxNotes: 5, spacing: .open, density: .seventh,
                rootOnly: false, mudFloorMIDI: defaultMudFloorMIDI,
                minimumSpanSemitones: 12, rootPositionBias: 0, homeRootMIDI: 55)
        }
    }

    /// **12 — a whole octave of voice-leading motion.**
    ///
    /// ⚠️ **6 WAS MEASURABLY TOO WEAK.** At 6 the guitar preset still landed F
    /// major with A in the bass after an A minor chord, because the inversion
    /// saved more than 6 semitones of motion; `rootPositionBiasIsGuitarOnly`
    /// caught it. De Clercq & Temperley measured 94.1 % root position in real
    /// recorded rock (§2.3), which is a preference strong enough that an octave
    /// of motion is the right price — an inversion has to be worth more than a
    /// whole octave of extra movement before it wins. It is still a BIAS and not
    /// a rule: nothing here forbids an inversion, it just has to earn it.
    public static let guitarRootPositionBias = 12

    /// **MIDI 52 — E3, the E below middle C in this codebase's own octave naming**
    /// (`Fundamental.noteName(midiNote: 60) == "C4"`, traced by hand).
    ///
    /// ⚠️ **THE CONCEPT IS SOURCED; THE EXACT PER-INTERVAL TABLE IS NOT, AND THAT
    /// IS SAID HERE RATHER THAN IMPLIED.** `spike-chord-buttons.md` §5.3 records
    /// that the two low-interval-limit tables it found present their numbers as
    /// staff-notation IMAGES, so the per-interval octave figures could not be
    /// quoted from a primary source. What IS verified is the commonly cited rule
    /// of thumb — for any interval other than a fifth or an octave, the upper note
    /// should not sit much below the E under middle C. That rule of thumb is what
    /// this number encodes, expressed in MIDI to dodge the octave-naming
    /// disagreement (Cubase/Yamaha vs Ableton/Logic) that trips this guideline up
    /// across software. **(estimate, sourced as a rule of thumb — not a measured
    /// per-interval table.)**
    public static let defaultMudFloorMIDI = 52
}

// MARK: - Named progressions

/// A named chord progression, expressed as SCALE DEGREES so it is key-agnostic.
///
/// ⭐ **THIS IS AN OVERLAY, NOT A MODE.** Selecting one lights and numbers four or
/// five of the same keys scale mode already plays; it removes nothing and gates
/// nothing. The user chose exactly this shape — *"Both — presets highlight the
/// scale"* — and the rule that follows from it is enforced structurally: this type
/// carries no playable state at all, only labels and indices, so there is no way
/// for a preset to make a key unplayable even by accident.
public struct ChordProgressionPreset: Sendable, Codable, Equatable, Identifiable, Hashable {
    /// Stable id for pickers and for the staging seam to name one by.
    public let id: String
    /// What the user sees. Plain language first, theory second.
    public let name: String
    /// The mode the progression is written in. Selecting a preset switches the
    /// key picker's mode to this — the tonic the user picked is kept.
    public let mode: KeyMode
    /// 1-based scale degrees, in playing order. `[1, 5, 6, 4]` is I–V–vi–IV.
    public let degrees: [Int]
    /// The genre note shown under the name. One line, no jargon.
    public let blurb: String

    public init(id: String, name: String, mode: KeyMode, degrees: [Int], blurb: String) {
        self.id = id
        self.name = name
        self.mode = mode
        self.degrees = degrees
        self.blurb = blurb
    }

    /// The Roman-numeral spelling, e.g. `"I – V – vi – IV"`. Derived from
    /// `degrees` + `mode` so it can never disagree with what the keys light.
    public func numeralLine(density: ChordDensity = .triad) -> String {
        let numerals = ChordVoicing.romanNumerals(mode: mode, density: density)
        return degrees.map { degree -> String in
            let index = ChordVoicing.scaleIndex(forDegree: degree)
            return numerals.indices.contains(index) ? numerals[index] : "?"
        }.joined(separator: " – ")
    }

    /// Where this degree first appears in the progression, 1-based, or nil if the
    /// progression never uses it. **This is the number printed under a lit key** —
    /// the `1 … 4 2 3` row of the user's own mock-up.
    public func order(ofDegree degree: Int) -> Int? {
        degrees.firstIndex(of: degree).map { $0 + 1 }
    }

    /// The set of degrees this progression lights. Everything else stays dim and
    /// **fully playable**.
    public var litDegrees: Set<Int> { Set(degrees) }
}

/// The shipped progressions — `spike-chord-buttons.md` §2.2's table, verbatim in
/// its choices and in its genre attributions.
public enum ChordProgressionLibrary {

    /// Pop I–V–vi–IV, the "four chords of pop" / axis progression.
    public static let fourChords = ChordProgressionPreset(
        id: "four-chords", name: "Four Chords", mode: .major, degrees: [1, 5, 6, 4],
        blurb: "Pop, pop-rock and a lot of dance music. The one everybody knows.")

    /// '50s I–vi–IV–V, the doo-wop changes.
    public static let dooWop = ChordProgressionPreset(
        id: "doo-wop", name: "'50s Doo-Wop", mode: .major, degrees: [1, 6, 4, 5],
        blurb: "Heart and Soul, Stand By Me. Warm and old-fashioned on purpose.")

    /// Pop-punk vi–IV–I–V — the same four chords as `fourChords`, opened on the
    /// minor sixth, which is why it reads as unresolved rather than triumphant.
    public static let popPunk = ChordProgressionPreset(
        id: "pop-punk", name: "Pop-Punk", mode: .major, degrees: [6, 4, 1, 5],
        blurb: "The same four chords, started on the sad one. Late-90s and 2000s rock.")

    /// Jazz ii–V–I.
    public static let jazzTwoFiveOne = ChordProgressionPreset(
        id: "ii-v-i", name: "Jazz ii–V–I", mode: .major, degrees: [2, 5, 1],
        blurb: "The building block of jazz standards. Try it with the Pad preset.")

    /// The 12-bar blues skeleton, reduced to its three chords in the order they
    /// first appear. **Not the 12-bar FORM** — this feature lights keys, it does
    /// not count bars, and pretending otherwise would be a promise the surface
    /// cannot keep.
    public static let blues = ChordProgressionPreset(
        id: "blues", name: "12-Bar Blues", mode: .major, degrees: [1, 4, 5],
        blurb: "Blues and early rock and roll. Three chords, in this order, over 12 bars.")

    /// Minor-key i–VI–III–VII.
    public static let minorRock = ChordProgressionPreset(
        id: "minor-rock", name: "Minor Rock", mode: .minor, degrees: [1, 6, 3, 7],
        blurb: "The four chords of pop, in minor. Picking this switches the key to minor.")

    /// Every shipped progression, in the order the preset row draws them.
    public static let all: [ChordProgressionPreset] = [
        fourChords, dooWop, popPunk, jazzTwoFiveOne, blues, minorRock,
    ]

    /// Look one up by id — the staging seam's resolver, so a gate names a preset
    /// the way the UI does instead of hardcoding a second copy of the degrees.
    public static func preset(id: String) -> ChordProgressionPreset? {
        all.first { $0.id == id }
    }
}

// MARK: - The voicing engine

/// Turns a chord symbol into actual MIDI pitches: **pure, deterministic, and the
/// ONE home for "how should this chord be laid out".**
///
/// The algorithm is `spike-chord-buttons.md` §5.5, built directly:
///
///   1. The chord is a pitch-class set plus a preferred bass pitch class.
///   2. The caller tracks the last voiced set (session-scoped, never persisted).
///   3. Candidate octave placements are enumerated inside the preset's register
///      window, scored by summed semitone motion from the previous voicing (§5.2,
///      Tymoczko's efficient voice leading), and any candidate that breaks the mud
///      floor (§5.3) or the preset's spacing rule (§5.4) is discarded.
///   4. With no previous voicing, a fixed home voicing at the preset's home octave.
///   5. It is a pure function.
///
/// ⚠️ **NOBODY ON THIS SIDE OF THE SCREEN CAN HEAR ANYTHING.** Every claim in
/// this file is about pitch numbers and intervals — that a voicing minimises
/// summed motion, that no close interval sits below the floor, that the set fits
/// the window. Whether the result SOUNDS good is the user's judgement and is not
/// asserted anywhere.
public enum ChordVoicing {

    /// The most tones any single chord may sound.
    ///
    /// ⛔ **HEADROOM UNDER THE LIVE CEILING IS THE POINT, NOT A ROUND NUMBER.**
    /// `AuditionController.maxVoices` is 8 and is REFERENCED rather than repeated.
    /// A chord capped at 8 would fill the whole polyphony budget by itself, so the
    /// oldest note of the chord the user is still holding would be stolen the
    /// instant they touched anything else. Five leaves room for a layered note and
    /// keeps two chords' worth of common tones alive across a change.
    public static let maxVoicedNotes = 5

    // MARK: Scale + diatonic chords

    /// Scale degrees are 1-based for humans (`I` is degree 1) and 0-based in the
    /// arrays. ONE conversion, here, so no caller does its own ±1.
    public static func scaleIndex(forDegree degree: Int) -> Int {
        let count = 7
        return (((degree - 1) % count) + count) % count
    }

    /// The seven diatonic chords of a key, in scale order.
    ///
    /// Major triads: **I ii iii IV V vi vii°**. Natural-minor triads:
    /// **i ii° III iv v VI VII** (§2.1). At `.seventh` density the qualities
    /// become the diatonic sevenths, which is NOT the triad quality with a 7
    /// glued on — the leading-tone chord of a major key is half-diminished, not
    /// diminished, and getting that wrong would be an audibly wrong note nothing
    /// else in the pipeline would catch.
    ///
    /// - Parameters:
    ///   - key: tonic pitch class, 0 = C.
    ///   - mode: major or natural minor.
    ///   - density: triads or sevenths.
    public static func diatonicChords(key: Int,
                                      mode: KeyMode,
                                      density: ChordDensity = .triad) -> [ChordSymbol] {
        let intervals = mode.scaleIntervals
        return zip(intervals, qualities(mode: mode, density: density)).map {
            ChordSymbol(rootPitchClass: key + $0.0, quality: $0.1)
        }
    }

    /// The chord on one scale degree. `degree` is 1-based and wraps, so degree 8
    /// is degree 1 again — which is exactly what the 17-key layout needs when it
    /// runs past the seventh degree.
    public static func diatonicChord(degree: Int,
                                     key: Int,
                                     mode: KeyMode,
                                     density: ChordDensity = .triad) -> ChordSymbol {
        diatonicChords(key: key, mode: mode, density: density)[scaleIndex(forDegree: degree)]
    }

    /// The seven Roman numerals, in scale order, matching `diatonicChords`.
    public static func romanNumerals(mode: KeyMode,
                                     density: ChordDensity = .triad) -> [String] {
        let base = ["I", "II", "III", "IV", "V", "VI", "VII"]
        return zip(base, qualities(mode: mode, density: density)).map { numeral, quality in
            (quality.numeralIsLowercase ? numeral.lowercased() : numeral) + quality.numeralSuffix
        }
    }

    /// The Roman numeral for one degree. 1-based and wrapping, like
    /// `diatonicChord`.
    public static func romanNumeral(degree: Int,
                                    mode: KeyMode,
                                    density: ChordDensity = .triad) -> String {
        romanNumerals(mode: mode, density: density)[scaleIndex(forDegree: degree)]
    }

    private static func qualities(mode: KeyMode, density: ChordDensity) -> [ChordQuality] {
        switch (mode, density) {
        case (.major, .triad):
            return [.major, .minor, .minor, .major, .major, .minor, .diminished]
        case (.major, .seventh):
            return [.major7, .minor7, .minor7, .major7, .dominant7, .minor7, .halfDiminished7]
        case (.minor, .triad):
            return [.minor, .diminished, .major, .minor, .minor, .major, .major]
        case (.minor, .seventh):
            return [.minor7, .halfDiminished7, .major7, .minor7, .minor7, .major7, .dominant7]
        }
    }

    // MARK: The voicing

    /// **The function this whole module exists for.** Chord symbol + prior voicing
    /// + instrument preset → a well-spaced pitch array, ascending, deduplicated.
    ///
    /// - Parameters:
    ///   - chord: what to play.
    ///   - previous: the pitches that were sounding immediately before, or nil /
    ///     empty for the first chord of a session. Nearest-tone voice leading is
    ///     measured against this.
    ///   - preset: the instrument style.
    ///   - octaveShift: whole octaves to move the whole preset window by. The
    ///     17-key layout uses it so the second run of scale degrees sits an octave
    ///     higher than the first; the octave chip (Z/X) uses it too. Clamped so
    ///     nothing can leave 0…127.
    /// - Returns: 1…`maxVoicedNotes` MIDI pitches, ascending. **Never empty** —
    ///   every fallback path still returns a sounding chord, because a key press
    ///   that silently produced nothing is the failure mode this tree calls
    ///   characteristic.
    public static func voice(_ chord: ChordSymbol,
                             previous: [Int]? = nil,
                             preset: InstrumentVoicingPreset,
                             octaveShift: Int = 0) -> [Int] {
        let shift = 12 * octaveShift
        let body = shiftWindow(preset.bodyWindow, by: shift)
        let previousPitches = (previous ?? []).sorted()

        // ── BASS ONLY (the bass preset). One note, led to the nearest octave. ──
        if preset.rootOnly {
            let reference = previousPitches.first ?? (preset.homeRootMIDI + shift)
            return [nearestPlacement(ofPitchClass: chord.rootPitchClass,
                                     to: reference, within: body)]
        }

        // ── THE BODY'S PITCH CLASSES, trimmed to the density budget. ──
        let budget = min(preset.maxNotes - (preset.playsBassNote ? 1 : 0), maxVoicedNotes)
        let bodyClasses = trimmedPitchClasses(chord, to: max(2, budget),
                                              droppingRoot: preset.playsBassNote)

        // ⚠️ THE BODY IS LED AGAINST THE PREVIOUS BODY, NOT THE PREVIOUS BASS.
        // With a bass note an octave and a half below the chord, including it in
        // the reference set drags every candidate downwards — the body would
        // chase the bass instead of leading smoothly against itself.
        let previousBody = previousPitches.filter { $0 >= body.lowerBound }
        let reference = previousBody.isEmpty ? previousPitches : previousBody

        // ⚠️ **THE BASS IS CHOSEN FIRST, AND THAT ORDER IS A BUG FIX.** It used to
        // be added after the body was picked, which meant the mud floor was only
        // ever checked against the body — so the interval between the BASS and the
        // lowest body note, which is the single likeliest place for mud to appear,
        // was never examined at all. Caught by `mudFloorHolds` at a downward
        // octave shift, where it produced `[35, 50, 59, 65]`: a minor tenth from
        // B1 to D3 with its upper note 2 semitones under the floor.
        let bass = bassPitch(for: chord, previous: previous, preset: preset,
                             octaveShift: octaveShift)

        let all = candidates(pitchClasses: bodyClasses, window: body, preset: preset)
        let chosen = bestCandidate(all, previous: reference, preset: preset,
                                   rootPitchClass: chord.rootPitchClass, shift: shift,
                                   bass: bass)
        guard let bass else { return chosen }
        return ([bass] + chosen).sorted()
    }

    /// The separate bass note this preset would place under the chord, or nil when
    /// it does not play one.
    ///
    /// Public because the chord's mud floor cannot be judged without it — a test
    /// that re-derives the candidate pool has to apply the same filter the engine
    /// applies, and that filter takes the bass into account.
    public static func bassPitch(for chord: ChordSymbol,
                                 previous: [Int]? = nil,
                                 preset: InstrumentVoicingPreset,
                                 octaveShift: Int = 0) -> Int? {
        guard preset.playsBassNote, !preset.rootOnly else { return nil }
        let shift = 12 * octaveShift
        let body = shiftWindow(preset.bodyWindow, by: shift)
        let bassWindow = shiftWindow(preset.bassWindow, by: shift)
        let previousPitches = (previous ?? []).sorted()
        // Led to the nearest octave from the PREVIOUS bass — a bassline that
        // leapt an octave between two neighbouring chords would undo the point of
        // leading the body smoothly above it.
        let previousBass = previousPitches.first.flatMap {
            $0 < body.lowerBound ? $0 : nil
        } ?? (preset.homeRootMIDI + shift - 12)
        return nearestPlacement(ofPitchClass: chord.rootPitchClass,
                                to: previousBass, within: bassWindow)
    }

    // MARK: Candidate enumeration (public so the tests can prove minimality)

    /// Every well-formed close/drop voicing of these pitch classes that fits the
    /// window, ascending, deduplicated.
    ///
    /// ⭐ **ROTATIONS × OCTAVES, NOT THE FULL CROSS-PRODUCT.** Enumerating every
    /// octave of every pitch class independently would generate voicings no player
    /// would ever make (doubled tones, a third stacked below its own root) and
    /// would make the "best" one a search over nonsense. A rotation is an
    /// INVERSION; stacking the remainder ascending gives a close voicing; the
    /// drop-2 / drop-3 variants are the standard way to open one up (§5.4). That
    /// is the whole space a keyboard player actually chooses from.
    ///
    /// **Exposed publicly so a test can assert the chosen voicing minimises the
    /// cost over EVERY alternative** — a minimiser proved only against itself is
    /// not proved at all.
    public static func candidates(pitchClasses: [Int],
                                  window: ClosedRange<Int>,
                                  preset: InstrumentVoicingPreset) -> [[Int]] {
        guard !pitchClasses.isEmpty else { return [] }
        var out: [[Int]] = []
        var seen = Set<[Int]>()

        func admit(_ voicing: [Int]) {
            guard voicing.allSatisfy({ window.contains($0) }) else { return }
            let sorted = voicing.sorted()
            guard Set(sorted).count == sorted.count else { return }
            guard seen.insert(sorted).inserted else { return }
            out.append(sorted)
        }

        for rotation in 0..<pitchClasses.count {
            let order = Array(pitchClasses[rotation...] + pitchClasses[..<rotation])
            var lowest = window.lowerBound
            while lowest <= window.upperBound {
                guard mod12(lowest) == mod12(order[0]) else { lowest += 1; continue }
                var stack = [lowest]
                var cursor = lowest
                var fits = true
                for pitchClass in order.dropFirst() {
                    cursor = nextPitch(above: cursor, pitchClass: pitchClass)
                    guard cursor <= window.upperBound else { fits = false; break }
                    stack.append(cursor)
                }
                if fits {
                    admit(stack)
                    // Drop-2: the second voice from the top falls an octave.
                    // Drop-3: the third does. Both are the canonical way to turn a
                    // close voicing into an open one without changing which tones
                    // are present (§5.4).
                    if stack.count >= 4 {
                        admit(dropped(stack, fromTop: 2))
                        admit(dropped(stack, fromTop: 3))
                    } else if stack.count == 3 {
                        admit(dropped(stack, fromTop: 2))
                    }
                }
                lowest += 12
            }
        }
        return out
    }

    /// **The mud-floor predicate (§5.3), exposed so a test can check it directly.**
    ///
    /// For every pair of ADJACENT sounding pitches: if the interval between them
    /// is a fifth or an octave (or a compound of either), it may sit as low as the
    /// window allows. Anything else — thirds, sixths, seconds, sevenths — must
    /// have its UPPER note at or above the floor, or the two pitches stop reading
    /// as two pitches.
    public static func satisfiesMudFloor(_ voicing: [Int], preset: InstrumentVoicingPreset) -> Bool {
        let sorted = voicing.sorted()
        guard sorted.count > 1 else { return true }
        for index in 1..<sorted.count {
            let lower = sorted[index - 1]
            let upper = sorted[index]
            let interval = mod12(upper - lower)
            if interval == 0 || interval == 7 { continue }
            if upper < preset.mudFloorMIDI { return false }
        }
        return true
    }

    /// **Summed semitone motion between two voicings (§5.2), exposed for the same
    /// reason `candidates` is.**
    ///
    /// A monotone (DTW-shaped) alignment over the two ascending pitch arrays: every
    /// voice in each set is matched to at least one in the other, and the cost is
    /// the summed absolute distance of the cheapest such matching. Two properties
    /// make this the right measure rather than a nearest-neighbour sum:
    ///
    ///   * **It is symmetric.** `cost(a, b) == cost(b, a)`, because the recurrence
    ///     is. A one-directional "each new note to its nearest old note" sum is
    ///     not, and it scores a candidate CLUSTERED around one previous note as
    ///     nearly free.
    ///   * **It handles a triad → seventh change** without pretending a voice
    ///     appeared from nowhere.
    ///
    /// For two equal-size voicings this reduces to the pairwise sum in sorted
    /// order, which is the textbook answer: C(60,64,67) → F voiced (60,65,69)
    /// costs 0+1+2 = 3, and every other placement of F costs more.
    public static func voiceLeadingCost(_ a: [Int], _ b: [Int]) -> Int {
        let lhs = a.sorted(), rhs = b.sorted()
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var table = [[Int]](repeating: [Int](repeating: Int.max / 4, count: rhs.count),
                            count: lhs.count)
        for i in 0..<lhs.count {
            for j in 0..<rhs.count {
                let step = abs(lhs[i] - rhs[j])
                if i == 0 && j == 0 { table[i][j] = step; continue }
                var best = Int.max / 4
                if i > 0 { best = min(best, table[i - 1][j]) }
                if j > 0 { best = min(best, table[i][j - 1]) }
                if i > 0 && j > 0 { best = min(best, table[i - 1][j - 1]) }
                table[i][j] = step + best
            }
        }
        return table[lhs.count - 1][rhs.count - 1]
    }

    // MARK: - Internals

    /// Picks the cheapest surviving candidate.
    ///
    /// ⚠️ **THE FILTERS DEGRADE, THEY DO NOT REFUSE.** If no candidate satisfies
    /// the mud floor and the spacing rule, the spacing rule is dropped first and
    /// the floor second, rather than returning nothing. A key press that produced
    /// silence because an arranging guideline could not be met would be this
    /// tree's characteristic failure — an instrument returning something that
    /// looks like a valid answer (an empty array) for a reason nobody can see.
    private static func bestCandidate(_ all: [[Int]],
                                      previous: [Int],
                                      preset: InstrumentVoicingPreset,
                                      rootPitchClass: Int,
                                      shift: Int,
                                      bass: Int?) -> [Int] {
        guard !all.isEmpty else {
            // Unreachable for every shipped preset (a triad always fits a
            // two-octave window). Kept as a sounding fallback rather than a
            // crash or an empty set.
            return [min(127, max(0, preset.homeRootMIDI + shift))]
        }
        let pool = survivingCandidates(all, preset: preset, bass: bass)

        let home = preset.homeRootMIDI + shift
        return pool.min { lhs, rhs in
            let l = cost(lhs, previous: previous, preset: preset,
                         rootPitchClass: rootPitchClass, home: home)
            let r = cost(rhs, previous: previous, preset: preset,
                         rootPitchClass: rootPitchClass, home: home)
            if l != r { return l < r }
            // ⚠️ **TIE-BREAK ON SPAN, AND THE FIRST VERSION OF THIS LINE WAS
            // MEASURABLY WRONG.** It preferred the candidate whose TOP note sat
            // nearest an octave above home, which on the piano preset picked a
            // drop-2 of the G-rooted stack — `[60, 67, 76]` (C4 G4 E5, span 16) —
            // over plain root position `[60, 64, 67]` (span 7) for the very FIRST
            // chord of a session, because both have their lowest note exactly at
            // home and the wider one reaches closer to the top of the window.
            // §5.5 step 4 says the home voicing IS root position at the home
            // octave; a rule that silently opened it up contradicted the spec it
            // was implementing. Printed by the exploratory probe before any
            // assertion was written, which is why it was caught at all.
            //
            // Narrower first, then lower. Open presets are unaffected: their
            // `minimumSpanSemitones` filter has already removed every close
            // voicing before this comparator ever runs, so "narrowest" there means
            // "the tightest OPEN voicing", which is what a spread wants anyway.
            let lSpan = span(lhs), rSpan = span(rhs)
            if lSpan != rSpan { return lSpan < rSpan }
            return (lhs.first ?? 0) < (rhs.first ?? 0)
        } ?? pool[0]
    }

    /// **The candidates that survive the spacing rule and the mud floor**, in that
    /// order, with the same degrade-rather-than-refuse fallback the chooser uses.
    ///
    /// Public for one reason: a test that asserts "the answer is the cheapest
    /// candidate" has to score the SAME pool the engine scored. Re-deriving the
    /// filters in the test would let the two drift, and a minimality proof against
    /// the wrong pool proves nothing.
    ///
    /// - Parameter bass: the separate bass note, if the preset plays one. The mud
    ///   floor is evaluated on the chord AS IT WILL SOUND, bass included.
    public static func survivingCandidates(_ all: [[Int]],
                                           preset: InstrumentVoicingPreset,
                                           bass: Int?) -> [[Int]] {
        guard !all.isEmpty else { return [] }
        let spaced = all.filter { span($0) >= preset.minimumSpanSemitones }
        let base = spaced.isEmpty ? all : spaced
        let clean = base.filter { candidate in
            let asItSounds = bass.map { [$0] + candidate } ?? candidate
            return satisfiesMudFloor(asItSounds, preset: preset)
        }
        // ⚠️ **THE FILTERS DEGRADE, THEY DO NOT REFUSE.** Transpose far enough
        // down (the octave chip, Z) and the whole register sits under the mud
        // floor — the floor is an absolute property of human hearing, not a
        // relative one, so it becomes unsatisfiable rather than wrong. A key press
        // that produced silence because an arranging guideline could not be met
        // would be this tree's characteristic failure: an instrument returning
        // something that looks like a valid answer for a reason nobody can see.
        return clean.isEmpty ? base : clean
    }

    /// **The total cost a candidate is ranked by** — exposed so a test can assert
    /// the chosen voicing is the minimiser over the whole enumerated space rather
    /// than merely a plausible member of it.
    ///
    /// Two terms, and only two:
    ///   * the voice-leading distance from `previous` (§5.2), or — with nothing to
    ///     lead from — the distance of the candidate's lowest note from the
    ///     preset's home root, which is §5.5 step 4's home voicing;
    ///   * `preset.rootPositionBias` if the candidate is NOT in root position,
    ///     which is non-zero for the guitar preset alone.
    public static func cost(_ candidate: [Int],
                            previous: [Int],
                            preset: InstrumentVoicingPreset,
                            rootPitchClass: Int,
                            home: Int) -> Int {
        let isRootPosition = mod12(candidate.first ?? 0) == mod12(rootPitchClass)
        if previous.isEmpty {
            // ── THE HOME VOICING (§5.5 step 4): "root position at the preset's
            // home octave". BOTH halves, and the second one was missing at first.
            //
            // ⚠️ **"NEAREST TO HOME" ALONE IS NOT ROOT POSITION, AND FOR MOST
            // CHORDS IT IS NOT EVEN CLOSE.** With home at middle C, the G major
            // candidate whose lowest note sits nearest to 60 is `[59, 62, 67]` —
            // B3 D4 G4, a first inversion — because B3 is one semitone from home
            // while the root-position G is five away. The first chord of every
            // session in every key but C came out inverted. Caught by
            // `previousChangesTheAnswer`, which noticed that G voiced from nothing
            // and G voiced after a C chord were the SAME array: the home rule was
            // accidentally reproducing the voice-led answer.
            //
            // The penalty is two octaves so root position is decisive rather than
            // merely favoured: every root-position placement is at most six
            // semitones from home, so nothing can outrun it.
            return abs((candidate.first ?? home) - home)
                + (isRootPosition ? 0 : homeInversionPenalty)
        }
        return voiceLeadingCost(candidate, previous)
            + (isRootPosition ? 0 : preset.rootPositionBias)
    }

    /// See `cost`. Two octaves — decisive, not merely preferential.
    static let homeInversionPenalty = 24

    private static func span(_ voicing: [Int]) -> Int {
        guard let low = voicing.min(), let high = voicing.max() else { return 0 }
        return high - low
    }

    private static func dropped(_ stack: [Int], fromTop index: Int) -> [Int] {
        guard stack.count >= index else { return stack }
        var copy = stack
        copy[stack.count - index] -= 12
        return copy
    }

    /// The lowest pitch strictly above `pitch` with this pitch class.
    private static func nextPitch(above pitch: Int, pitchClass: Int) -> Int {
        let delta = mod12(pitchClass - pitch)
        return pitch + (delta == 0 ? 12 : delta)
    }

    /// The placement of a pitch class closest to `reference` that still lies in
    /// `window`. Ties resolve DOWNWARD — a bass note that jumped up on a coin flip
    /// would make the same progression voice differently on different runs.
    private static func nearestPlacement(ofPitchClass pitchClass: Int,
                                         to reference: Int,
                                         within window: ClosedRange<Int>) -> Int {
        var best: Int?
        var candidate = window.lowerBound + mod12(pitchClass - window.lowerBound)
        while candidate <= window.upperBound {
            if let current = best {
                let improves = abs(candidate - reference) < abs(current - reference)
                if improves { best = candidate }
            } else {
                best = candidate
            }
            candidate += 12
        }
        // Windows shorter than an octave can contain no member of a pitch class;
        // clamp rather than return nothing.
        return best ?? min(window.upperBound,
                           max(window.lowerBound,
                               reference - mod12(reference - pitchClass)))
    }

    /// Trims a chord's tones to a budget.
    ///
    /// ⭐ **THE FIFTH GOES FIRST, THEN THE ROOT — and that order is standard
    /// arranging practice, not an arbitrary pick.** The fifth carries the least
    /// information (it is implied by the root and does not distinguish major from
    /// minor); the root is droppable ONLY when a separate bass note is already
    /// sounding it, which is exactly the `playsBassNote` case. The third and the
    /// seventh are never dropped: they are what make the chord that chord.
    private static func trimmedPitchClasses(_ chord: ChordSymbol,
                                            to budget: Int,
                                            droppingRoot: Bool) -> [Int] {
        var tones = chord.pitchClasses           // root, third, fifth, [seventh]
        guard tones.count > budget else { return tones }
        if tones.count > budget, tones.count >= 3 {
            tones.remove(at: 2)                  // the fifth
        }
        if tones.count > budget, droppingRoot, tones.count >= 2 {
            tones.remove(at: 0)                  // the root, doubled by the bass
        }
        return Array(tones.prefix(max(1, budget)))
    }

    private static func shiftWindow(_ window: ClosedRange<Int>, by shift: Int) -> ClosedRange<Int> {
        let low = min(120, max(0, window.lowerBound + shift))
        let high = min(127, max(low + 1, window.upperBound + shift))
        return low...high
    }

    private static func mod12(_ value: Int) -> Int { ((value % 12) + 12) % 12 }
}
