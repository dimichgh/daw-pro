import Foundation

// p2-sing-x4 — HARMONY PARTS FROM A MELODY (design docs/design/2026-10-06-p2-sing-expansion.md §4.2, §4.3, §4.5).
//
// A harmony part is a second melody with the SAME note count and timing as the lead, so the lead's words land on the
// same notes (the assigner reads only timing and syllables). This file decides each part note's PITCH, the song's key
// those pitches are counted in, and the whole-octave height the part is sung at. Pure: Foundation only, no store, no
// engine, no clock. The coordinator (x6) and the `sing.proposeHarmony` verb (x7) call it; nothing here renders.
//
// THE RULES (each pinned by `HarmonyPlannerTests`):
//   1. Diatonic step: a third = 2 scale steps, a fifth = 4, a sixth = 5, an octave = 7, in `KeyMode.scaleIntervals`
//      (the ONE scale table, ChordVoicing.swift). A chromatic lead note takes the step its nearest scale degree BELOW
//      would take, as a semitone distance (§4.3 [A]).
//   2. Chord snap: when a chord sounds at the note's onset and the diatonic note is not one of its tones, the note moves
//      to the nearest chord tone (nearest to the diatonic note) on the same side of the lead, 3...9 semitones from it
//      (§4.3 [A]). No chord tone in that window: the diatonic note stays.
//   3. Never unison, never a crossing: an "above" part is above every lead note, a "below" part below it. Holds by
//      construction (every step is at least 3 semitones, and so is the snap window).
//   4. The octave belongs to the WHOLE part (§4.5): `range(...)` picks one whole-octave shift with `VoiceRangeFit`'s
//      metric, song transposition fixed (t = 0), ties going to the lead's octave.
//
// DECISIONS THIS FILE MAKES THAT THE DESIGN LEFT OPEN ([A], each named where it is made): what counts as a chord (3 or
// more pitch classes), what "auto" means, that an octave part is never snapped, that muted tracks feed the key but not
// the chords, that slice kits are not pitched, the snap's tie-break, the ±2-octave wording, and the whole-part fold
// that keeps a written part inside MIDI 0...127.

// MARK: - The key

/// The key a harmony is counted in (§4.3 "The key").
public struct SongKey: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// The `key`/`mode` params (wire) or the card's key picker (UI).
        case given
        /// Estimated from every pitched MIDI note's duration (`HarmonyPlanner.estimateKey`).
        case estimated
    }

    /// 0 = C … 11 = B, the index convention of `KeyEstimate.pitchClassesSharp`. Wraps on construction.
    public var tonicPitchClass: Int
    public var mode: KeyMode
    public var source: Source
    /// The estimate's margin-gated confidence (`KeyEstimate.confidence`); 1 for a given key [A: the user said so].
    public var confidence: Double

    public init(tonicPitchClass: Int, mode: KeyMode, source: Source = .given, confidence: Double = 1) {
        self.tonicPitchClass = ((tonicPitchClass % 12) + 12) % 12
        self.mode = mode
        self.source = source
        self.confidence = confidence
    }

    /// Bridges an estimate (`KeyEstimate.tonic` is a sharp name, `mode` the strings `KeyMode`'s raw values match).
    /// nil only if either string is outside those tables. Does NOT look at `tonal`: `HarmonyPlanner.resolveKey` does.
    public init?(estimate: KeyEstimate) {
        guard let tonic = KeyEstimate.pitchClassesSharp.firstIndex(of: estimate.tonic),
              let mode = KeyMode(rawValue: estimate.mode) else { return nil }
        self.init(tonicPitchClass: tonic, mode: mode, source: .estimated, confidence: estimate.confidence)
    }

    /// "C major", "F# minor": the repo's one pitch-class name table.
    public var name: String { "\(KeyEstimate.pitchClassesSharp[tonicPitchClass]) \(mode.displayName)" }
}

// MARK: - What part to make

/// One derived part (§4.3).
public struct HarmonySpec: Codable, Sendable, Equatable {
    public enum Interval: String, Codable, Sendable, CaseIterable {
        case third, sixth, fifth, octave

        /// Scale steps: a third = 2, a fifth = 4, a sixth = 5, an octave = 7.
        public var scaleSteps: Int {
            switch self {
            case .third: return 2
            case .fifth: return 4
            case .sixth: return 5
            case .octave: return 7
            }
        }
    }

    public enum Direction: String, Codable, Sendable, CaseIterable {
        case above, below
        /// +1 above, −1 below.
        var sign: Int { self == .above ? 1 : -1 }
    }

    /// Where the chord a note may snap to comes from.
    public enum ChordSource: String, Codable, Sendable, CaseIterable {
        /// This clip's own chord at the onset when it has one, else the other tracks' (§4.3 [A]: a per-note fallback).
        case auto
        /// No snap: every note is the diatonic step.
        case none
        /// The melody clip's own notes sounding at the onset.
        case thisClip
        /// Every OTHER unmuted pitched MIDI track's notes sounding at the onset (drum tracks and slice kits excluded).
        case otherTracks
    }

    public var interval: Interval
    public var direction: Direction
    public var chordSource: ChordSource

    public init(interval: Interval, direction: Direction, chordSource: ChordSource = .auto) {
        self.interval = interval
        self.direction = direction
        self.chordSource = chordSource
    }

    /// "third above", "sixth below": the words the track name and the card use (§4.6, §14).
    public var name: String { "\(interval.rawValue) \(direction.rawValue)" }
}

/// Which chord note a "Sing the chord's other notes" part takes (§4.2): ranked from the top, the lead being the top.
public enum ChordToneRank: Int, Codable, Sendable, CaseIterable {
    case second = 2
    case third = 3
}

/// Why a harmony part cannot be planned.
public enum HarmonyRefusal: Error, Equatable, Sendable {
    /// The key estimate is not tonal and no key was given (§4.3). A part from another clip needs no key.
    case needsKey

    /// The wire's refusal code (§4.7).
    public var code: String {
        switch self {
        case .needsKey: return "singHarmonyNeedsKey"
        }
    }

    /// §14 "Key unknown", verbatim.
    public var sentence: String {
        switch self {
        case .needsKey: return "I couldn't tell this song's key. Pick the key, and I'll work out the harmony."
        }
    }
}

// MARK: - The plan

/// One part note: a lead note's timing with the part's pitch.
public struct HarmonyNote: Equatable, Sendable {
    /// How the pitch was chosen.
    public enum Rule: String, Codable, Sendable {
        /// The diatonic step of a scale note.
        case diatonic
        /// A chromatic lead note: its scale degree below's step, as a semitone distance.
        case chromatic
        /// Moved from the diatonic note to a chord tone.
        case chordSnap
        /// A chord-tones part: the chord's own note.
        case chordTone
    }

    /// The part note's id: a name-based UUID of the lead note's id and the part index (`HarmonyPlanner.partNoteID`).
    public var id: UUID
    public var leadNoteID: UUID
    public var leadPitch: Int
    /// The written part pitch (before the part's sung octave, after the whole-part fold, see `HarmonyPlan.foldOctaves`).
    public var pitch: Int
    /// The diatonic step before any snap (equal to `pitch` unless the rule is `chordSnap`); for a chord tone, the
    /// chord's note.
    public var unsnappedPitch: Int
    public var rule: Rule
    /// The lead note's timing and velocity, unchanged.
    public var startBeat: Double
    public var lengthBeats: Double
    public var velocity: Int
    /// The chord (pitch classes) the part's chord source sounds at this note's onset — for a chord-tones part, its
    /// fill's chord source — nil when that source is `.none` or no chord sounds. Exactly what the snap rule read (or
    /// would read), kept so the range line can derive the OTHER §4.1 choices from the same melody, key and chords
    /// (`HarmonyPlanner.alternatives`, p2-sing-x9-f1) without a second home for the derivation.
    var chord: Set<Int>?

    /// The note a transient part clip carries.
    public var midiNote: MIDINote {
        MIDINote(id: id, pitch: pitch, velocity: velocity, startBeat: startBeat, lengthBeats: lengthBeats)
    }
}

/// A planned part: its notes, one per lead note, in the lead's order.
public struct HarmonyPlan: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case derived(HarmonySpec)
        /// A chord-tones part; `fill` (always "… below") planned the notes where the clip has no such chord tone.
        case chordTones(rank: ChordToneRank, fill: HarmonySpec)
    }

    public var source: Source
    /// The key the steps were counted in; nil only for a chord-tones part that never needed its fill.
    public var key: SongKey?
    /// The part's index in its job (1 = the first harmony part). Feeds the note ids.
    public var partIndex: Int
    public var notes: [HarmonyNote]
    /// Whole octaves the WHOLE written part was moved to keep every note inside MIDI 0...127 (0 for any lead a voice
    /// can sing; [A]: a fold, never a per-note clamp, which would be a wrong note).
    public var foldOctaves: Int

    /// The part as notes, canonically ordered.
    public var partNotes: [MIDINote] { MIDINote.canonicallyOrdered(notes.map(\.midiNote)) }

    /// The TRANSIENT clip a part is planned from (§4.2): the lead clip with its notes replaced, same id, same lyrics,
    /// never stored. `SingPlanner.plan(clip:on:…)` on it gives the part's units; its words land where the lead's do.
    ///
    /// The lead's singing style comes along, with each per-note choice moved to the part note sung in its lead note's
    /// place (`leadNoteID` → `id`): the part's note ids are derived, so a choice still keyed by a lead note id would
    /// be an orphan the part never reads (W8-X5M's finding; p2-sing-x6). Clip-wide choices are kept as they are.
    public func transientClip(replacingNotesOf lead: Clip) -> Clip {
        var clip = lead
        clip.notes = partNotes
        if var style = clip.singStyle, let choices = style.notes {
            var moved: [UUID: NoteSingStyle] = [:]
            for note in notes {
                if let choice = choices[note.leadNoteID] { moved[note.id] = choice }
            }
            style.notes = moved.isEmpty ? nil : moved
            clip.singStyle = SingStyle.normalized(style)
        }
        return clip
    }

    /// True when this part's notes ARE `other`'s notes moved `octaves` whole octaves, note for note in the lead's
    /// order: the same lead notes, each pitch equal to `other`'s + 12 × `octaves`. EXACT pitches on purpose: pitch
    /// classes ignore the octave, so "a sixth below" would match "a third above" before any move (p2-sing-x9-f1).
    func sings(sameNotesAs other: HarmonyPlan, movedBy octaves: Int) -> Bool {
        !notes.isEmpty && notes.count == other.notes.count
            && zip(notes, other.notes).allSatisfy {
                $0.leadNoteID == $1.leadNoteID && $0.pitch == $1.pitch + 12 * octaves
            }
    }
}

// MARK: - Chords at an onset

/// The chords a part may snap to, built once per part from the project (§4.3 rule 2). Pitch classes, 0...11.
public struct HarmonyChords: Sendable, Equatable {
    /// A sounding note, in absolute beats.
    struct Sounding: Sendable, Equatable {
        var start: Double
        var end: Double
        var pitch: Int
    }

    /// The fewest distinct pitch classes that make a chord [A]: two notes (a melody note over a bass note) are an
    /// interval, not a chord, and snapping a third to one of them would only ever produce a fourth or a fifth.
    public static let minimumChordPitchClasses = 3

    public let source: HarmonySpec.ChordSource
    let clipStartBeat: Double
    /// This clip: at each melody onset (clip beats), the pitches sounding there that are not ANOTHER melody note.
    let clipChords: [Double: [Int]]
    /// This clip: each melody onset's lead pitch.
    let leadPitchAt: [Double: Int]
    /// Other tracks' sounding notes.
    let others: [Sounding]

    /// - Parameters:
    ///   - clip: the melody clip; `track`: the track it lives on (its other clips are not "other tracks").
    ///   - tracks: every track of the project. Drum tracks (`ProjectTranspose.isDrumTrack`), slice kits
    ///     (`ProjectTranspose.isSliceKitTrack`) and muted tracks [A: a chord no one hears must not move a note] are
    ///     left out; each clip sounds by playback's rule (`SingPlanner.played`).
    public init(source: HarmonySpec.ChordSource, clip: Clip, on track: Track, tracks: [Track]) {
        self.source = source
        self.clipStartBeat = clip.startBeat
        var clipChords: [Double: [Int]] = [:]
        var leadPitchAt: [Double: Int] = [:]
        if source == .thisClip || source == .auto {
            let played = SingPlanner.played(clip)
            let melody = SingPlanner.monophonic(clip).notes
            let melodyIDs = Set(melody.map(\.id))
            for lead in melody {
                let b = lead.startBeat
                leadPitchAt[b] = lead.pitch
                clipChords[b] = played.filter {
                    $0.startBeat <= b && b < $0.endBeat && ($0.id == lead.id || !melodyIDs.contains($0.id))
                }.map(\.pitch)
            }
        }
        var others: [Sounding] = []
        if source == .otherTracks || source == .auto {
            for other in tracks where other.id != track.id && !other.isMuted
                && !ProjectTranspose.isDrumTrack(other) && !ProjectTranspose.isSliceKitTrack(other) {
                for otherClip in other.clips where otherClip.isMIDI {
                    for voice in SingPlanner.played(otherClip) {
                        others.append(Sounding(start: otherClip.startBeat + voice.startBeat,
                                               end: otherClip.startBeat + voice.endBeat, pitch: voice.pitch))
                    }
                }
            }
        }
        self.clipChords = clipChords
        self.leadPitchAt = leadPitchAt
        self.others = others
    }

    /// No chords: every note takes its diatonic step.
    public static let noChords = HarmonyChords()

    private init() {
        source = .none
        clipStartBeat = 0
        clipChords = [:]
        leadPitchAt = [:]
        others = []
    }

    /// The chord sounding at a melody onset (clip beats), as pitch classes; nil when fewer than
    /// `minimumChordPitchClasses` sound there, or the source is `.none`.
    public func pitchClasses(atClipBeat beat: Double) -> Set<Int>? {
        switch source {
        case .none: return nil
        case .thisClip: return thisClipChord(beat)
        case .otherTracks: return otherTracksChord(beat)
        case .auto: return thisClipChord(beat) ?? otherTracksChord(beat)
        }
    }

    /// This clip's distinct pitches strictly BELOW the lead note at a melody onset, highest first (the chord-tones
    /// part's candidates: index 0 is the note ranked 2nd from the top). Empty when the source never read this clip.
    public func clipPitchesBelowLead(atClipBeat beat: Double) -> [Int] {
        guard let lead = leadPitchAt[beat], let pitches = clipChords[beat] else { return [] }
        return Array(Set(pitches.filter { $0 < lead })).sorted(by: >)
    }

    private func thisClipChord(_ beat: Double) -> Set<Int>? {
        guard let pitches = clipChords[beat] else { return nil }
        return Self.chord(pitches)
    }

    private func otherTracksChord(_ beat: Double) -> Set<Int>? {
        let at = clipStartBeat + beat
        return Self.chord(others.filter { $0.start <= at && at < $0.end }.map(\.pitch))
    }

    private static func chord(_ pitches: [Int]) -> Set<Int>? {
        let classes = Set(pitches.map { (($0 % 12) + 12) % 12 })
        return classes.count >= minimumChordPitchClasses ? classes : nil
    }
}

// MARK: - A part's height

/// The whole-octave height a part is sung at (§4.5).
public struct HarmonyRange: Equatable, Sendable {
    /// Whole octaves the part moves by, applied to every note (`SingPlanner.plan(…, octaveShift:)`).
    public var octaveShift: Int
    /// The winning candidate's score, nil without a measured voice.
    public var fit: KeyFitCandidate?
    /// Every candidate considered (t = 0, `VoiceRangeFit.octaveShiftRange`, unison heights left out).
    public var candidates: [KeyFitCandidate]
    /// False when the best height still leaves the part outside what the voice sings (p2-sing-x9-f3, a harmony part's
    /// OWN rule in `HarmonyPlanner.range(melody:…)`): more than `KeyFitWeights.harmonyAcceptOutOfBand` semitones out
    /// of band on average, or one sounding note past `harmonyNoteMaxAboveBand` / `harmonyNoteMaxBelowBand`. The card
    /// shows the line in amber. A warning, never a refusal. True without a voice.
    public var fits: Bool
    /// §14 "Part fits" / "Part moved" / "Part out of range" (its suggestion derived from what was measured,
    /// `HarmonyPlanner.rangeSentence`); nil without a voice (no range line).
    public var sentence: String?
    /// The side a line that does not fit names ("goes lower" when true): when the average is within tolerance and
    /// exactly one per-note cap was crossed, that cap's side; otherwise the side holding more of the part's time.
    var lowSide: Bool = false
}

// MARK: - The planner

public enum HarmonyPlanner {

    /// The chord-snap window, semitones from the lead note on the part's side (§4.3 [A]; Round H1 and x4's tables).
    public static let snapMinimumSemitones = 3
    public static let snapMaximumSemitones = 9

    // MARK: Rule 1: the diatonic step

    /// `pitch` moved `interval` in `direction` through `key`'s scale. A chromatic pitch takes the semitone distance
    /// its nearest scale degree below would move (§4.3 [A]).
    public static func diatonicStep(_ pitch: Int, interval: HarmonySpec.Interval, direction: HarmonySpec.Direction,
                                    key: SongKey) -> (pitch: Int, chromatic: Bool) {
        let scale = key.mode.scaleIntervals
        let relative = mod(pitch - key.tonicPitchClass, 12)
        // The scale degree at or below the pitch (degree 0 is the tonic, 0 semitones, so one always exists).
        var index = 0
        for (i, step) in scale.enumerated() where step <= relative { index = i }
        let degreePitch = pitch - (relative - scale[index])
        let target = index + direction.sign * interval.scaleSteps
        let octaves = floorDiv(target, scale.count)
        let targetPitch = degreePitch - scale[index] + scale[mod(target, scale.count)] + 12 * octaves
        return (pitch + (targetPitch - degreePitch), scale[index] != relative)
    }

    // MARK: Rule 2: the chord snap

    /// The snapped pitch for a lead `pitch` whose diatonic step is `diatonic`, or nil when no snap applies: no chord,
    /// the diatonic note is already a chord tone, an octave part (never snapped [A]: an octave doubles the lead, and
    /// the window cannot reach 12), or no chord tone in the window.
    public static func snap(lead pitch: Int, diatonic: Int, interval: HarmonySpec.Interval,
                            direction: HarmonySpec.Direction, chord: Set<Int>?) -> Int? {
        guard interval != .octave, let chord, !chord.contains(mod(diatonic, 12)) else { return nil }
        var best: Int?
        for distance in snapMinimumSemitones...snapMaximumSemitones {
            let candidate = pitch + direction.sign * distance
            guard chord.contains(mod(candidate, 12)) else { continue }
            // Nearest to the diatonic note; a tie goes to the one nearer the lead [A] (the loop runs outward from
            // the lead, so the first of two equally near candidates is kept).
            if let kept = best, abs(kept - diatonic) <= abs(candidate - diatonic) { continue }
            best = candidate
        }
        return best
    }

    // MARK: A derived part (§4.2 "Derived")

    /// The design's entry point (§4.3): one part note per lead note, same timing, rules 1-3.
    ///
    /// - Parameters:
    ///   - lead: the melody as sung, `SingPlanner.melody(of: clip).notes` (after the monophony rule; legato is applied
    ///     by `SingPlanner.plan` on the transient clip, identically, since the timing is the lead's).
    ///   - chordAt: the chord at a lead onset in clip beats, as pitch classes (`HarmonyChords.pitchClasses`); ignored
    ///     when `spec.chordSource == .none`.
    ///   - partIndex: the part's place in its job (1, 2, 3); with the lead note id, it names each part note's id.
    public static func notes(lead: [MIDINote], spec: HarmonySpec, key: SongKey, partIndex: Int,
                             chordAt: (Double) -> Set<Int>?) -> HarmonyPlan {
        notes(lead: lead, chords: lead.map { spec.chordSource == .none ? nil : chordAt($0.startBeat) }, spec: spec,
              key: key, partIndex: partIndex)
    }

    /// The same rule with the chord at each lead note already read (`chords[i]` for `lead[i]`): the one body both
    /// the entry point above and a range line's other choices (`alternatives`) plan through.
    static func notes(lead: [MIDINote], chords: [Set<Int>?], spec: HarmonySpec, key: SongKey,
                      partIndex: Int) -> HarmonyPlan {
        let notes = zip(lead, chords).map { note, chord in
            derivedNote(for: note, spec: spec, key: key, partIndex: partIndex, chord: chord)
        }
        return folded(HarmonyPlan(source: .derived(spec), key: key, partIndex: partIndex, notes: notes,
                                  foldOctaves: 0))
    }

    /// A derived part for `clip` on `track`: its melody, its chords by `spec.chordSource`.
    public static func derivedPart(clip: Clip, on track: Track, tracks: [Track], spec: HarmonySpec, key: SongKey,
                                   partIndex: Int) -> HarmonyPlan {
        let chords = HarmonyChords(source: spec.chordSource, clip: clip, on: track, tracks: tracks)
        return notes(lead: SingPlanner.melody(of: clip).notes, spec: spec, key: key, partIndex: partIndex,
                     chordAt: chords.pitchClasses(atClipBeat:))
    }

    // MARK: A chord-tones part (§4.2 "Chord tones of the melody clip")

    /// Where the melody clip has a chord, the part takes its note ranked `rank` from the top (the lead is the top);
    /// where it has no such note, the derived rule fills in with "`fillInterval` below", snapping by
    /// `fillChordSource`. Always BELOW the lead: the chord's other notes are under its top note, so a fill above would
    /// cross the part over the lead.
    ///
    /// Throws `.needsKey` only when a fill note is needed and `key` is nil: a part made of chord notes alone needs no
    /// key, and its plan's `key` is nil.
    public static func chordTonePart(clip: Clip, on track: Track, tracks: [Track], rank: ChordToneRank,
                                     fillInterval: HarmonySpec.Interval, fillChordSource: HarmonySpec.ChordSource,
                                     key: SongKey?, partIndex: Int) throws(HarmonyRefusal) -> HarmonyPlan {
        let fill = HarmonySpec(interval: fillInterval, direction: .below, chordSource: fillChordSource)
        let lead = SingPlanner.melody(of: clip).notes
        // The clip's own chord notes are read whatever the fill's chord source is.
        let own = HarmonyChords(source: .thisClip, clip: clip, on: track, tracks: tracks)
        let chords = HarmonyChords(source: fill.chordSource, clip: clip, on: track, tracks: tracks)
        var notes: [HarmonyNote] = []
        var usedFill = false
        for note in lead {
            let below = own.clipPitchesBelowLead(atClipBeat: note.startBeat)
            // The fill's chord at this onset: what a fill note snaps to, and what the range line's other choices
            // are planned with (`HarmonyNote.chord`), so it is read for every note.
            let chord = fill.chordSource == .none ? nil : chords.pitchClasses(atClipBeat: note.startBeat)
            if below.count >= rank.rawValue - 1 {
                let pitch = below[rank.rawValue - 2]
                notes.append(HarmonyNote(id: partNoteID(leadNoteID: note.id, partIndex: partIndex),
                                         leadNoteID: note.id, leadPitch: note.pitch, pitch: pitch,
                                         unsnappedPitch: pitch, rule: .chordTone, startBeat: note.startBeat,
                                         lengthBeats: note.lengthBeats, velocity: note.velocity, chord: chord))
            } else {
                guard let key else { throw .needsKey }
                usedFill = true
                notes.append(derivedNote(for: note, spec: fill, key: key, partIndex: partIndex, chord: chord))
            }
        }
        return folded(HarmonyPlan(source: .chordTones(rank: rank, fill: fill), key: usedFill ? key : nil,
                                  partIndex: partIndex, notes: notes, foldOctaves: 0))
    }

    // MARK: The key (§4.3)

    /// Seconds each pitch class sounds, over every pitched MIDI note in the project: every MIDI clip of every track
    /// except drum tracks and slice kits (their notes pick sounds, not pitches), each clip by playback's rule
    /// (`SingPlanner.played`), through the tempo map. Muted tracks COUNT [A: the key is the song's material, not
    /// the current mix; read literally, "every pitched MIDI note in the project"].
    public static func keyChroma(tracks: [Track], tempoMap: TempoMap) -> [Double] {
        var chroma = [Double](repeating: 0, count: 12)
        for track in tracks where !ProjectTranspose.isDrumTrack(track) && !ProjectTranspose.isSliceKitTrack(track) {
            for clip in track.clips where clip.isMIDI {
                for voice in SingPlanner.played(clip) {
                    let seconds = tempoMap.seconds(from: clip.startBeat + voice.startBeat,
                                                   to: clip.startBeat + voice.endBeat)
                    if seconds > 0, seconds.isFinite { chroma[mod(voice.pitch, 12)] += seconds }
                }
            }
        }
        return chroma
    }

    /// The project's key estimate: `KeyProfileMatch` (the ONE home of the Krumhansl–Kessler math) over `keyChroma`.
    public static func estimateKey(tracks: [Track], tempoMap: TempoMap) -> KeyEstimate {
        KeyProfileMatch.estimate(chroma: keyChroma(tracks: tracks, tempoMap: tempoMap))
    }

    /// The key a derived part uses: `given` when there is one, else the estimate. An estimate that is not tonal
    /// refuses with `.needsKey` (§4.3).
    public static func resolveKey(given: SongKey?, tracks: [Track], tempoMap: TempoMap) throws(HarmonyRefusal)
        -> SongKey {
        if let given { return given }
        let estimate = estimateKey(tracks: tracks, tempoMap: tempoMap)
        guard estimate.tonal, let key = SongKey(estimate: estimate) else { throw .needsKey }
        return key
    }

    // MARK: Rule 4: the part's height (§4.5)

    /// The whole-octave height for a planned part. `VoiceRangeFit.score` with the song transposition fixed (t = 0)
    /// over `VoiceRangeFit.octaveShiftRange`; candidates within `tieWindow` of the best tie, and a tie goes to the
    /// lead's octave, then the smaller move, then the lower cost (NOT `VoiceRangeFit.pick`, whose ties go to the
    /// smallest move). A height that would sing any note in unison with the lead is never a candidate (an octave
    /// part one octave toward the lead). Without a voice, the part sits at the lead's octave.
    ///
    /// When the part does not fit, its line names only what was MEASURED (p2-sing-x9-f1): another §4.1 choice
    /// (`rangeLineChoices`) planned from the same melody, key and chords and fitted by this same rule, never the part
    /// that was asked for and never one that does not fit itself.
    public static func range(of plan: HarmonyPlan, clipStartBeat: Double, tempoMap: TempoMap, voice: VoiceRange?,
                             leadOctaveShift: Int, weights: KeyFitWeights = VoiceRangeFit.defaultWeights)
        -> HarmonyRange {
        var height = fit(of: plan, clipStartBeat: clipStartBeat, tempoMap: tempoMap, voice: voice,
                         leadOctaveShift: leadOctaveShift, weights: weights)
        guard let winner = height.fit else { return height }
        var others: RangeLineAlternatives = .unmeasured
        var sameNotesAs: HarmonySpec?
        if !height.fits,
           let measured = alternatives(to: plan, clipStartBeat: clipStartBeat, tempoMap: tempoMap, voice: voice,
                                       leadOctaveShift: leadOctaveShift, weights: weights) {
            others = .measured(measured)
            if winner.octaveShift != 0 {
                sameNotesAs = measured.first { $0.plan.sings(sameNotesAs: plan, movedBy: winner.octaveShift) }?.spec
            }
        }
        height.sentence = rangeSentence(octaveShift: winner.octaveShift, fits: height.fits, lower: height.lowSide,
                                        sameNotesAs: sameNotesAs, others: others)
        return height
    }

    /// The same rule for a part sung from another clip (§4.2 "Another MIDI clip"): its own notes, its own height.
    /// Its line names no other choice: they are planned from the LEAD's melody, which this call never sees, so none
    /// of them was measured here.
    public static func range(ofClipNotes notes: [MIDINote], clipStartBeat: Double, tempoMap: TempoMap,
                             voice: VoiceRange?, leadOctaveShift: Int,
                             weights: KeyFitWeights = VoiceRangeFit.defaultWeights) -> HarmonyRange {
        let melody = notes.map {
            VoiceRangeFit.MelodyNote(midi: Double($0.pitch),
                                     durationSeconds: tempoMap.seconds(from: clipStartBeat + $0.startBeat,
                                                                       to: clipStartBeat + $0.endBeat))
        }
        var height = range(melody: melody, voice: voice, leadOctaveShift: leadOctaveShift, excluding: [],
                           weights: weights)
        if let winner = height.fit {
            height.sentence = rangeSentence(octaveShift: winner.octaveShift, fits: height.fits, lower: height.lowSide,
                                            sameNotesAs: nil, others: .unmeasured)
        }
        return height
    }

    /// A planned part's height without its line: its notes through the tempo map, its unison heights left out, then
    /// `range(melody:…)`. The asked part and every other choice a line may name are fitted HERE, one rule.
    static func fit(of plan: HarmonyPlan, clipStartBeat: Double, tempoMap: TempoMap, voice: VoiceRange?,
                    leadOctaveShift: Int, weights: KeyFitWeights) -> HarmonyRange {
        let melody = plan.notes.map {
            VoiceRangeFit.MelodyNote(midi: Double($0.pitch),
                                     durationSeconds: tempoMap.seconds(from: clipStartBeat + $0.startBeat,
                                                                       to: clipStartBeat + $0.startBeat
                                                                           + $0.lengthBeats))
        }
        let unison = Set(plan.notes.compactMap { note -> Int? in
            let gap = note.leadPitch + 12 * leadOctaveShift - note.pitch
            return gap % 12 == 0 ? gap / 12 : nil
        })
        return range(melody: melody, voice: voice, leadOctaveShift: leadOctaveShift, excluding: unison,
                     weights: weights)
    }

    /// THE fit rule (§4.5): the winning height and whether it fits. `sentence` is nil here; the two public `range`
    /// calls write the line, because only they know what else was measured.
    ///
    /// A harmony part has its OWN rule (p2-sing-x9-f3; the key proposal keeps `octaveOnlyAcceptOutOfBand`): it fits
    /// when the winner's out-of-band mean is at most `harmonyAcceptOutOfBand` AND no sounding note sits more than
    /// `harmonyNoteMaxAboveBand` over the band or `harmonyNoteMaxBelowBand` under it (a mean cannot protect one far
    /// note). The winner itself is chosen by cost exactly as before.
    static func range(melody: [VoiceRangeFit.MelodyNote], voice: VoiceRange?, leadOctaveShift: Int,
                      excluding: Set<Int>, weights: KeyFitWeights) -> HarmonyRange {
        guard let voice, melody.contains(where: { $0.durationSeconds > 0 }) else {
            return HarmonyRange(octaveShift: leadOctaveShift, fit: nil, candidates: [], fits: true, sentence: nil)
        }
        let candidates = VoiceRangeFit.octaveShiftRange.filter { !excluding.contains($0) }.map {
            VoiceRangeFit.score(melody: melody, voice: voice, songTranspose: 0, octaveShift: $0, weights: weights)
        }
        guard let best = candidates.map(\.cost).min() else {
            return HarmonyRange(octaveShift: leadOctaveShift, fit: nil, candidates: [], fits: true, sentence: nil)
        }
        let winner = candidates.filter { $0.cost <= best + weights.tieWindow }.min { a, b in
            let da = abs(a.octaveShift - leadOctaveShift), db = abs(b.octaveShift - leadOctaveShift)
            if da != db { return da < db }
            if abs(a.octaveShift) != abs(b.octaveShift) { return abs(a.octaveShift) < abs(b.octaveShift) }
            if a.cost != b.cost { return a.cost < b.cost }
            return a.octaveShift < b.octaveShift
        }!
        // The band is `VoiceRangeFit.score`'s (p10 − margin … p90 + margin), and a note counts when it sounds, as there.
        let low = voice.p10Midi - weights.bandMarginSemitones
        let high = voice.p90Midi + weights.bandMarginSemitones
        let sung = melody.filter { $0.durationSeconds > 0 }.map { $0.midi + Double(winner.vocalOffset) }
        let tooHigh = sung.contains { $0 - high > weights.harmonyNoteMaxAboveBand }
        let tooLow = sung.contains { low - $0 > weights.harmonyNoteMaxBelowBand }
        let meanFits = winner.outOfBandSemitones <= weights.harmonyAcceptOutOfBand
        let fits = meanFits && !tooHigh && !tooLow
        let lowSide = meanFits && tooHigh != tooLow
            ? tooLow : winner.fractionBelowBand >= winner.fractionAboveBand
        return HarmonyRange(octaveShift: winner.octaveShift, fit: winner, candidates: candidates, fits: fits,
                            sentence: nil, lowSide: lowSide)
    }

    // MARK: What a range line may name (p2-sing-x9-f1)

    /// The §4.1 choices a range line may name, in the "Add a harmony" menu's order (§14 "Harmony choices"): the three
    /// planned from the melody by the interval rule. "Sing my other melody…" and "Sing the chord's other notes" are
    /// not: their notes come from other notes in the song, not from this part's melody.
    static let rangeLineChoices: [(interval: HarmonySpec.Interval, direction: HarmonySpec.Direction)] = [
        (.third, .above), (.sixth, .below), (.third, .below),
    ]

    /// Another §4.1 choice, planned and fitted next to the asked part.
    struct RangeLineAlternative {
        /// Its spec: the asked part's chord source (a chord-tones part: its fill's), so it is the part the user
        /// would get by picking it with the same chords.
        var spec: HarmonySpec
        var plan: HarmonyPlan
        /// `fit(of:…)` over its own notes: the same rule, the same voice, the same lead octave.
        var height: HarmonyRange
    }

    /// What a range line can say about the other choices.
    enum RangeLineAlternatives {
        /// Nothing was measured (a part from another clip; a chord-tones part with no key): name none, claim none.
        case unmeasured
        /// Every other §4.1 choice, measured, in menu order.
        case measured([RangeLineAlternative])
    }

    /// Every §4.1 choice except the one asked for, planned from `plan`'s own melody (each note's lead pitch and
    /// timing), key and chords (`HarmonyNote.chord`) and fitted by `fit(of:…)`. Nil when `plan` has no key (a
    /// chord-tones part that never needed its fill): the steps cannot be counted.
    static func alternatives(to plan: HarmonyPlan, clipStartBeat: Double, tempoMap: TempoMap, voice: VoiceRange?,
                             leadOctaveShift: Int, weights: KeyFitWeights) -> [RangeLineAlternative]? {
        guard let key = plan.key else { return nil }
        let asked: HarmonySpec?
        let chordSource: HarmonySpec.ChordSource
        switch plan.source {
        case .derived(let spec):
            asked = spec
            chordSource = spec.chordSource
        case .chordTones(_, let fill):
            asked = nil
            chordSource = fill.chordSource
        }
        let lead = plan.notes.map {
            MIDINote(id: $0.leadNoteID, pitch: $0.leadPitch, velocity: $0.velocity, startBeat: $0.startBeat,
                     lengthBeats: $0.lengthBeats)
        }
        let chords = plan.notes.map(\.chord)
        return rangeLineChoices.compactMap { choice -> RangeLineAlternative? in
            if let asked, asked.interval == choice.interval, asked.direction == choice.direction { return nil }
            let spec = HarmonySpec(interval: choice.interval, direction: choice.direction, chordSource: chordSource)
            let other = notes(lead: lead, chords: chords, spec: spec, key: key, partIndex: plan.partIndex)
            let height = fit(of: other, clipStartBeat: clipStartBeat, tempoMap: tempoMap, voice: voice,
                             leadOctaveShift: leadOctaveShift, weights: weights)
            guard height.fit != nil else { return nil }
            return RangeLineAlternative(spec: spec, plan: other, height: height)
        }
    }

    /// The other choice a line suggests: of those that FIT, the lowest cost; an exact tie keeps menu order.
    static func suggestion(_ alternatives: [RangeLineAlternative]) -> RangeLineAlternative? {
        var best: RangeLineAlternative?
        for alternative in alternatives where alternative.height.fits {
            guard let cost = alternative.height.fit?.cost else { continue }
            if let kept = best?.height.fit?.cost, kept <= cost { continue }
            best = alternative
        }
        return best
    }

    // MARK: The line

    /// §14's range lines. "Part fits" and "Part moved" are VERBATIM, and so is "Part out of range"'s first sentence
    /// for a part at its written octave; two octaves keeps the same shape ([A]: §14 has no row for it).
    ///
    /// A part that does not fit (p2-sing-x9-f1; the added words are PROVISIONAL):
    /// - moved: says so, and when the moved notes ARE another choice's notes (`sameNotesAs`), names it;
    /// - then the measured alternative that fits (§14's "Try '…' instead.", derived, never fixed), or, when every
    ///   measured one misses too, says so and offers what really exists: another voice ("Add your voice…",
    ///   `sing.addVoice`) or moving the song's key ("Move the song up …", `project.transpose`);
    /// - `.unmeasured`: no suggestion and no claim about the others.
    static func rangeSentence(octaveShift: Int, fits: Bool, lower: Bool, sameNotesAs: HarmonySpec?,
                              others: RangeLineAlternatives) -> String {
        let moved = "\(octaveShift == 1 || octaveShift == -1 ? "an octave" : VoiceRangeFit.octaveWords(octaveShift)) "
            + (octaveShift < 0 ? "lower" : "higher")
        guard !fits else {
            return octaveShift == 0 ? "Fits your voice." : "I'll sing this part \(moved)."
        }
        let side = lower ? "lower" : "higher"
        var line: String
        if octaveShift == 0 {
            line = "This part goes \(side) than this voice usually sings."
        } else {
            line = "I'll sing this part \(moved)"
            if let sameNotesAs { line += ", which is the same notes as '\(choiceName(sameNotesAs))'" }
            line += ". That's the closest fit, but it still goes \(side) than this voice usually sings."
        }
        guard case .measured(let measured) = others, !measured.isEmpty else { return line }
        if let best = suggestion(measured) {
            return line + " Try '\(choiceName(best.spec))' instead."
        }
        return line + " \(choiceList(measured.map(\.spec))) \(measured.count == 1 ? "doesn't" : "don't") fit this "
            + "voice either. Try a different voice, or move the song's key."
    }

    /// "a third above": the choice as the line names it.
    static func choiceName(_ spec: HarmonySpec) -> String { "a \(spec.name)" }

    /// "'A third above', 'a sixth below' and 'a third below'", starting a sentence.
    static func choiceList(_ specs: [HarmonySpec]) -> String {
        var names = specs.map { "'\(choiceName($0))'" }
        if let first = names.first { names[0] = "'A" + String(first.dropFirst(2)) }
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Note ids (§4.2 [A])

    /// A part note's id: a pure function of the lead note's id and the part index, so the same input always gives
    /// the same plan. Two salted 64-bit FNV-1a passes (the `Groove.builtinID` precedent; DAWCore imports no hash
    /// library), stamped as an RFC 9562 version-8 ("custom") UUID: name-derived, not random, and not SHA-1 v5.
    public static func partNoteID(leadNoteID: UUID, partIndex: Int) -> UUID {
        let name = "\(leadNoteID.uuidString)|part:\(partIndex)"
        func fnv1a(_ salt: String) -> UInt64 {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in salt.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return hash
        }
        let hi = fnv1a("harmony-note.hi|")
        let lo = fnv1a("harmony-note.lo|")
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: hi >> UInt64(56 - i * 8))
            bytes[8 + i] = UInt8(truncatingIfNeeded: lo >> UInt64(56 - i * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x80   // RFC 9562 version 8 (custom)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122/9562 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Helpers

    static func derivedNote(for note: MIDINote, spec: HarmonySpec, key: SongKey, partIndex: Int,
                            chord: Set<Int>?) -> HarmonyNote {
        let step = diatonicStep(note.pitch, interval: spec.interval, direction: spec.direction, key: key)
        let snapped = snap(lead: note.pitch, diatonic: step.pitch, interval: spec.interval,
                           direction: spec.direction, chord: chord)
        return HarmonyNote(id: partNoteID(leadNoteID: note.id, partIndex: partIndex), leadNoteID: note.id,
                           leadPitch: note.pitch, pitch: snapped ?? step.pitch, unsnappedPitch: step.pitch,
                           rule: snapped != nil ? .chordSnap : (step.chromatic ? .chromatic : .diatonic),
                           startBeat: note.startBeat, lengthBeats: note.lengthBeats, velocity: note.velocity,
                           chord: chord)
    }

    /// Moves the WHOLE part by the fewest whole octaves that put every note inside MIDI 0...127 (a lead at the very
    /// top of the keyboard, a third above). A no-op for anything a voice sings.
    static func folded(_ plan: HarmonyPlan) -> HarmonyPlan {
        guard let low = plan.notes.map(\.pitch).min(), let high = plan.notes.map(\.pitch).max() else { return plan }
        var octaves = 0
        if high > MIDINote.pitchRange.upperBound {
            octaves = -((high - MIDINote.pitchRange.upperBound + 11) / 12)
        } else if low < MIDINote.pitchRange.lowerBound {
            octaves = (MIDINote.pitchRange.lowerBound - low + 11) / 12
        }
        guard octaves != 0 else { return plan }
        var plan = plan
        plan.foldOctaves = octaves
        for i in plan.notes.indices {
            plan.notes[i].pitch += 12 * octaves
            plan.notes[i].unsnappedPitch += 12 * octaves
        }
        return plan
    }

    static func mod(_ value: Int, _ modulus: Int) -> Int { ((value % modulus) + modulus) % modulus }

    static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        (value - mod(value, divisor)) / divisor
    }
}
