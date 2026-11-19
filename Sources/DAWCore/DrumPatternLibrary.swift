import Foundation

// m39-w4-10 — READY-MADE DRUM BEATS, written in drum ROLES, never in note numbers.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §8 (Design F), §9.2, §10.2 L2, §10.3.
//
// Pure and headless: patterns in, `MIDINote`s out. The store writes them through
// `ProjectStore.addDrumPattern` (`ProjectStore+DrumPattern.swift`), and the step
// grid's "Start from a beat" menu reads the same two functions through
// `ProjectStore.fillDrumPattern` (the same file), which fills an EMPTY clip.
//
// ⛔ ROLES BECOME NOTES THROUGH THE TARGET'S OWN MAP, NEVER A TABLE OF OUR OWN.
// A drum machine answers in its own note layout (`pads` 36–43 on every song saved
// before 2026-10-07, `gm` on a new one), so "snare" is note 37 on one and 38 on the
// other, and note 38 on the `pads` kit is the CLOSED HAT. `roleNotes(for:)` asks
// `DrumVoice.primaryNote(in:)`, the drum lane map's own home, for the kit's own
// layout. Gate P1 (`DrumPatternRenderTests`): the same pattern on a `pads` and a
// `gm` drum machine renders byte-identically.
//
// ⛔ A ROLE THE KIT LACKS IS LEFT OUT, NEVER SUBSTITUTED. A loop chopped into a kit
// may have no open hat; its open-hat hits are dropped and the reply names the drum
// ("Open Hat"). Playing the closed hat instead would be a different beat that
// looks like success. Gate P3.
//
// ⭐ THE FIRST PATTERN IS THE USER'S L2 PICK (2026-10, decision `decisions/drums-w4`
// field L2 = "eighths"): the basic backbeat, kick on 1 and 3, snare on 2 and 4,
// a closed hi-hat on every eighth note. Its placements AND its velocities are the
// listening material the pick was made on (`W4LBeats.l2(hatStep: 0.5, lift: false)`,
// every hit at 100), so what ships is what was heard. The other patterns are
// conventional placements (design §10.3, delegated), velocities authored musically.
//
// ⚠️ The patterns do NOT read `NoteEntryDefaults.drumVelocity` (the hand-entry
// default, held at 100 until the L1 pick). A pattern is authored music: moving
// the entry default must not re-voice every beat. The one shared number is the
// accent, `NoteEntryDefaults.accentVelocity` (row letter `A`).

/// One hit of a drum pattern: which drum, on which sixteenth-note step, how hard.
public struct DrumPatternHit: Sendable, Equatable {
    /// The drum, by role (the drum machine's eight voices name the roles).
    public let role: DrumVoice
    /// Sixteenth-note step from the start of the pattern: 0 is beat 1 of bar 1,
    /// 4 is beat 2, 16 is beat 1 of bar 2.
    public let step: Int
    /// MIDI velocity, 1...127.
    public let velocity: Int

    public init(role: DrumVoice, step: Int, velocity: Int) {
        self.role = role
        self.step = step
        self.velocity = velocity
    }
}

/// A named, ready-made drum beat: one or two bars of 4/4 on a sixteenth-note grid.
public struct DrumPattern: Sendable, Equatable, Identifiable {
    /// Stable id, the wire's spelling ("basicRock").
    public let id: String
    /// What a beginner reads ("Basic Rock").
    public let name: String
    /// One plain sentence a beginner can read: what it sounds like, no jargon.
    public let summary: String
    /// The pattern's own length, 1 or 2 bars of 4 beats.
    public let bars: Int
    /// Every hit, ordered by step, then by `DrumVoice` order.
    public let hits: [DrumPatternHit]

    public init(id: String, name: String, summary: String, bars: Int, hits: [DrumPatternHit]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.bars = bars
        self.hits = hits
    }

    /// The drums this pattern plays, in `DrumVoice` order.
    public var roles: [DrumVoice] {
        DrumVoice.allCases.filter { voice in hits.contains { $0.role == voice } }
    }
}

/// How one drum of a pattern was written (or not) on a track.
public struct DrumPatternRoleUse: Sendable, Equatable {
    public let role: DrumVoice
    /// The MIDI note the role was written on; nil when the kit lacks the drum.
    public let note: Int?
    /// How many hits of this drum the written bars hold.
    public let hits: Int

    public init(role: DrumVoice, note: Int?, hits: Int) {
        self.role = role
        self.note = note
        self.hits = hits
    }
}

/// A pattern turned into notes for one kit.
public struct DrumPatternNotes: Sendable, Equatable {
    /// The notes, clip-relative (beat 0 is the clip's start), canonically ordered.
    public let notes: [MIDINote]
    /// The drums that were written, in `DrumVoice` order.
    public let written: [DrumPatternRoleUse]
    /// The drums the kit lacks, left out, in `DrumVoice` order.
    public let leftOut: [DrumPatternRoleUse]
}

/// THE ONE HOME for the ready-made drum beats (m39-w4-10).
public enum DrumPatternLibrary {

    /// Sixteenth-note steps in one bar.
    public static let stepsPerBar = 16
    /// Beats in one bar: every pattern is written in 4/4.
    public static let beatsPerBar = 4
    /// One step, in beats (a sixteenth note).
    public static let stepBeats = 0.25
    /// How many bars one write may fill.
    public static let barsRange: ClosedRange<Int> = 1...64

    /// Every pattern, in the order a menu lists them. ⭐ The FIRST is the user's
    /// L2 pick (basic rock with eighth-note hats); `firstPattern` reads it.
    public static let patterns: [DrumPattern] = definitions.map { build($0).pattern }

    /// The pattern a "Start from a beat" menu offers first (the user's L2 pick).
    public static var firstPattern: DrumPattern { patterns[0] }

    /// The pattern called `name`: its id or its display name, ignoring case,
    /// spaces and punctuation ("fourOnTheFloor", "Four on the Floor" and
    /// "four-on-the-floor" all match). nil when there is none.
    public static func pattern(named name: String) -> DrumPattern? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        return patterns.first { normalized($0.id) == key || normalized($0.name) == key }
    }

    /// Which MIDI note plays each drum on `instrument`, or nil when it is not a
    /// drum instrument (`DrumLaneMap.lanes(for:)` returned nil: no drum rows).
    ///
    /// - Drum machine: every drum, at `DrumVoice.primaryNote(in:)` for the kit's
    ///   OWN note layout (`pads` or `gm`), the note its step-grid row writes.
    /// - General MIDI drum kit (a sound bank on the percussion bank): every drum,
    ///   at `primaryNote(in: .gm)`. Not from its rows: those list the 17 drums
    ///   the frequency guide covers and leave out the side stick (37) and the hand
    ///   clap (39), which the kit itself plays.
    /// - Sampler sorted into a kit: each drum some pad is labelled with, on the
    ///   first row the lane map gives that drum (the loudest hit's pad). A drum no
    ///   pad is labelled with is absent from the answer, so it is left out.
    public static func roleNotes(for instrument: InstrumentDescriptor?) -> [DrumVoice: Int]? {
        guard let instrument, let lanes = DrumLaneMap.lanes(for: instrument) else { return nil }
        switch instrument.kind {
        case .drumSynth:
            let layout = instrument.resolvedDrumKit.noteLayout
            return Dictionary(uniqueKeysWithValues: DrumVoice.allCases.map {
                ($0, Int($0.primaryNote(in: layout)))
            })
        case .soundBank:
            return Dictionary(uniqueKeysWithValues: DrumVoice.allCases.map {
                ($0, Int($0.primaryNote(in: .gm)))
            })
        case .sampler:
            var notes: [DrumVoice: Int] = [:]
            for lane in lanes {
                if let voice = lane.voice, notes[voice] == nil { notes[voice] = lane.note }
            }
            return notes
        case .testTone, .polySynth, .audioUnit:
            return nil
        }
    }

    /// `pattern` over `bars` bars, as notes for a kit whose drums sit on
    /// `roleNotes`. Longer than the pattern: it repeats from its first bar.
    /// Shorter: it stops at the bar line. Every hit lasts one step, the length a
    /// step-grid click writes. A drum missing from `roleNotes` is left out and
    /// listed in `leftOut`; nothing plays in its place.
    ///
    /// `limit` (m39-w4-10 UI, "Start from a beat"): keep only the hits that
    /// START before this beat, and count only those in `written`/`leftOut`. An
    /// empty clip that ends partway through a bar is filled up to its own end:
    /// a hit at or past the end would be stored but never sound (the engine's
    /// strict `startBeat < length` rule, `MIDISchedule.buildEvents`). nil, the
    /// default, keeps every hit of every bar, so `clip.addDrumPattern` is
    /// unchanged.
    public static func notes(for pattern: DrumPattern, bars: Int,
                             roleNotes: [DrumVoice: Int],
                             before limit: Double? = nil) -> DrumPatternNotes {
        var notes: [MIDINote] = []
        var hitCounts: [DrumVoice: Int] = [:]
        for bar in 0..<max(0, bars) {
            let patternBar = bar % max(1, pattern.bars)
            for hit in pattern.hits where hit.step / stepsPerBar == patternBar {
                let step = bar * stepsPerBar + hit.step % stepsPerBar
                let startBeat = Double(step) * stepBeats
                if let limit, !(startBeat < limit) { continue }
                hitCounts[hit.role, default: 0] += 1
                guard let note = roleNotes[hit.role] else { continue }
                notes.append(MIDINote(pitch: note, velocity: hit.velocity,
                                      startBeat: startBeat, lengthBeats: stepBeats))
            }
        }
        var written: [DrumPatternRoleUse] = []
        var leftOut: [DrumPatternRoleUse] = []
        for role in DrumVoice.allCases {
            guard let count = hitCounts[role] else { continue }
            if let note = roleNotes[role] {
                written.append(DrumPatternRoleUse(role: role, note: note, hits: count))
            } else {
                leftOut.append(DrumPatternRoleUse(role: role, note: nil, hits: count))
            }
        }
        return DrumPatternNotes(notes: MIDINote.canonicallyOrdered(notes), written: written, leftOut: leftOut)
    }

    /// The warning for a drum the kit lacks. It names the drum by its display name.
    public static func leftOutSentence(_ use: DrumPatternRoleUse) -> String {
        let name = use.role.displayName
        let hits = use.hits == 1 ? "1 \(name) hit was" : "\(use.hits) \(name) hits were"
        return "This kit has no \(name), so the beat's \(hits) left out. Nothing else plays in their place."
    }

    // MARK: - Authoring

    /// One authored pattern: rows of sixteenth-note steps, one row per drum.
    ///
    /// Row letters (velocity): `A` the accent (`NoteEntryDefaults.accentVelocity`,
    /// 127), `X` 112 (strong), `x` 100 (normal), `o` 84 (lighter), `h` 68 (soft),
    /// `g` 40 (a ghost note: a soft in-between tap), `.` no hit. `|` separates bars
    /// for the eye and is ignored. A row is exactly `bars * 16` steps.
    struct Definition: Sendable {
        let id: String
        let name: String
        let summary: String
        let bars: Int
        let rows: [(DrumVoice, String)]
    }

    /// The velocity a row letter writes, or nil for a letter that is not one.
    static func velocity(for letter: Character) -> Int? {
        switch letter {
        case "A": return NoteEntryDefaults.accentVelocity
        case "X": return 112
        case "x": return 100
        case "o": return 84
        case "h": return 68
        case "g": return 40
        default: return nil
        }
    }

    /// A definition parsed into a pattern, plus every authoring mistake found
    /// (a wrong row length, an unknown letter, a drum given two rows). Tests pin
    /// the problems empty for every shipped definition (`authoringProblems`).
    static func build(_ definition: Definition) -> (pattern: DrumPattern, problems: [String]) {
        var hits: [DrumPatternHit] = []
        var problems: [String] = []
        var seen = Set<DrumVoice>()
        let expected = definition.bars * stepsPerBar
        for (role, row) in definition.rows {
            if !seen.insert(role).inserted {
                problems.append("\(definition.id): \(role.rawValue) has two rows")
            }
            let steps = row.filter { $0 != "|" }
            if steps.count != expected {
                problems.append("\(definition.id): \(role.rawValue) row has \(steps.count) steps, not \(expected)")
            }
            for (step, letter) in steps.enumerated() where letter != "." {
                guard let velocity = velocity(for: letter) else {
                    problems.append("\(definition.id): \(role.rawValue) step \(step) has letter '\(letter)'")
                    continue
                }
                hits.append(DrumPatternHit(role: role, step: step, velocity: velocity))
            }
        }
        let order = DrumVoice.allCases
        hits.sort {
            $0.step != $1.step ? $0.step < $1.step
                : (order.firstIndex(of: $0.role) ?? 0) < (order.firstIndex(of: $1.role) ?? 0)
        }
        let pattern = DrumPattern(id: definition.id, name: definition.name, summary: definition.summary,
                                  bars: definition.bars, hits: hits)
        return (pattern, problems)
    }

    /// Every authoring mistake in the shipped definitions. Empty when they are sound.
    static var authoringProblems: [String] { definitions.flatMap { build($0).problems } }

    /// Lowercased letters and digits only: the matching key for `pattern(named:)`.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    /// THE SHIPPED PATTERNS, in menu order. The first is the user's L2 pick.
    /// Steps: `1 e & a 2 e & a 3 e & a 4 e & a` across each bar of 16.
    static let definitions: [Definition] = [
        Definition(
            id: "basicRock", name: "Basic Rock",
            summary: "The everyday beat most pop and rock songs start from: a kick drum on beats 1 and 3, "
                + "a snare on 2 and 4, and a closed hi-hat ticking twice on every beat.",
            bars: 1,
            rows: [
                // Exactly the L2 "eighths" listening material: every hit at 100.
                (.kick, "x.......x......."),
                (.snare, "....x.......x..."),
                (.closedHat, "x.x.x.x.x.x.x.x."),
            ]),
        Definition(
            id: "fourOnTheFloor", name: "Four on the Floor",
            summary: "A steady kick on every beat, like dance music, with a clap on beats 2 and 4 "
                + "and an open hi-hat in between the kicks.",
            bars: 1,
            rows: [
                (.kick, "X...X...X...X..."),
                (.openHat, "..o...o...o...o."),
                (.clap, "....x.......x..."),
            ]),
        Definition(
            id: "boomBap", name: "Boom Bap",
            summary: "A laid-back hip-hop beat: a punchy kick, a hard snare on beats 2 and 4 with a few "
                + "soft taps in between, and a steady hi-hat.",
            bars: 2,
            rows: [
                (.kick, "X......x..x.....|X.x.......x....."),
                (.snare, "....X....g..X...|....X.......X..g"),
                (.closedHat, "x.o.x.o.x.o.x.o.|x.o.x.o.x.o.x.o."),
            ]),
        Definition(
            id: "trap", name: "Trap",
            summary: "A modern hip-hop beat that feels slow and heavy: a booming kick, a loud clap on "
                + "beat 3 of each bar, and fast, busy hi-hats that build up at the very end.",
            bars: 2,
            rows: [
                (.kick, "X......x........|X.....x..x......"),
                (.closedHat, "xhohxhohxhohxhoh|xhohxhohxhohhoxX"),
                (.clap, "........A.......|........A......."),
            ]),
        Definition(
            id: "halfTime", name: "Half-Time",
            summary: "A heavy, slowed-down feel: the snare hits only once a bar, on beat 3, so the song "
                + "feels half as fast without changing its speed.",
            bars: 1,
            rows: [
                (.kick, "X.........x....."),
                (.snare, "........X......."),
                (.closedHat, "x.o.x.o.x.o.x.o."),
            ]),
        Definition(
            id: "breakbeat", name: "Breakbeat",
            summary: "A busy, funky beat in the style of old soul and funk drum breaks: kicks and snares "
                + "that skip around the beat, with soft snare taps in between.",
            bars: 2,
            rows: [
                (.kick, "X.x.......xx....|X.x.......x....."),
                (.snare, "....X..o.o..X..o|....X..o.o....X."),
                (.closedHat, "o.h.o.h.o.h.o.h.|o.h.o.h.o.h.o.h."),
            ]),
        Definition(
            id: "oneDrop", name: "One Drop",
            summary: "The classic reggae beat: beat 1 is left empty, and the kick and a rim click land "
                + "together on beat 3, with a gentle hi-hat ticking twice on every beat.",
            bars: 1,
            rows: [
                // ⚠️ HEADROOM, MEASURED 2026-10-12 (W9-PAT): the kick and the rim land on the SAME sample, and
                // at 112 + 112 this beat peaked at +1.93 dBTP on a new drum machine at fader 1.0 (the rim alone
                // at 112 reads -1.46 dBTP). At kick 100 + rim 68 (a lighter click under the kick, the usual
                // cross-stick balance) the same render measured -1.29 dBTP. The kick stays at 100, which is
                // still at the drum machine's accent threshold. `DrumPatternRenderTests` holds every pattern
                // at or under -1 dBTP.
                (.kick, "........x......."),
                (.closedHat, "o.h.o.h.o.h.o.h."),
                (.rim, "........h......."),
            ]),
    ]
}
