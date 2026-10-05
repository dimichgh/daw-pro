import Foundation

// Tune to Melody, M1 — THE MATCHING ENGINE. Design
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §3.2 (rules 1–5), §3.3
// (where voice and melody disagree), §3.6 (tests, failure modes), §6 row 7. The user asked
// for tuning a voice to a MIDI melody on 2026-10-04.
//
// ⭐ **f0 DECIDES WHERE NOTES ARE; THE MELODY DECIDES WHICH NOTE EACH ONE GETS.** The note
// parts come from `PitchNoteSplitter.parts`, the call both note-table builders make, and
// this file never moves an f0 edge. It adds a cut only where ONE held part spans two melody
// notes that want different pitches (rule 2), and it reports every place where the voice and
// the melody disagree (§3.3), so the store (M2) reports them without re-deriving any.
//
// ⭐ **WHAT THIS DOES NOT TOUCH, READ FROM `PitchAutoCorrect` (2026-10-04):**
//  * A `.transition` part (a slide) is passed through as a `.transition` piece with no
//    target. Under every preserve-vibrato preset, and under Hard Tune with the product's
//    `PitchAutoCorrect.slideShape` (a-T), a slide is IDENTITY (`segment(forPart:)`'s
//    `asSung()`), and the melody leaves it so.
//  * Sounds (`.unpitched`) are not parts: `PitchUnpitchedFinder` adds them between the notes
//    as IDENTITY segments drawn at the nearer neighbour's DETECTED median (U3, tie → the
//    following note). Pass this plan's pieces to the finder (`PitchUnpitchedFinder.Note`
//    from a piece's span and `centreHz`) so a sound borrows the piece drawn beside it.
//
// Pure: no clock, no I/O, no store, no engine. Seconds in, a plan out; it never sees beats
// (the store converts a MIDI clip to VOCAL SOURCE seconds first, §3.2). Nothing here reaches
// the render thread.
//
// ═══ THE DECISIONS THE DESIGN LEFT OPEN (each one pinned by `PitchMelodyTargetTests`) ═══
//  D1  An overlap COUNTS only when it is longer than half a detector frame. A part's edges
//      are known to one frame, and the store's beat-to-seconds arithmetic leaves overlaps of
//      ~1e-12 s at abutting edges; neither is singing under a note.
//  D2  Rule 1's tie: overlaps within half a frame of the largest are tied, and the note that
//      STARTS earlier wins (then the lower input index). The finder's "equal at frame
//      resolution" precedent.
//  D3  Legato is a TAIL overlap shorter than `legatoOverlapSeconds`: the later note starts
//      inside the earlier one and outlasts it, and the earlier note ends where the later one
//      starts. Every other overlap (60 ms or more, a note inside another, a shared start) is
//      a chord, and the HIGHEST sounding note wins each instant (equal pitches: the earlier
//      note). The design's "the earlier note ends" would cut a long note at a short grace
//      note inside it, so containment is never legato.
//  D4  Within a held part, the melody fragments that overlap it by at least
//      `PitchAutoCorrect.minimumNoteSeconds` are GROUPED, in time order, while their
//      provisional targets are equal. A cut is considered only between two groups. So C4
//      then C5 under `nearestOctave` (one target) is never cut, and a melody note under
//      60 ms never cuts (F-fast); a part that overlaps nothing else still takes it (rule 1).
//  D5  The melody boundary between two groups is the midpoint of the gap between their
//      neighbouring fragments (their shared edge when they abut). Its frame index `j` is the
//      number of the part's frames whose MIDPOINT lies before it (the finder's convention).
//  D6  "Any f0 cut" is either edge of the part (a run edge or a splitter cut): a boundary is
//      cut only when `j > S` and `n − j > S`, S the splitter's scoop limit in frames.
//  D7  The search runs on the part's de-glitched f0 `x` (the splitter's running median at its
//      own width), in MIDI. A crossing at frame k is `x[k−1] < m ≤ x[k]` on a rising step or
//      `x[k−1] > m ≥ x[k]` on a falling one, m the mean of the two provisional targets. The
//      crossing nearest `j` wins (tie: the earlier). No crossing → `j`. An f0 that is already
//      past m where the window starts has no crossing in it.
//  D8  The ±S window is clipped so every piece keeps at least `minimumNoteSeconds` of frames,
//      from the previous cut and from the next boundary. A cut with no room is not made.
//  D9  An uncut held part takes rule 1 over every fragment. A piece made by cuts takes the
//      majority over its OWN groups' fragments (overlap measured over the part), so a
//      crossing that moved a cut can never hand a short piece its neighbour's note.
//  D10 The fold reference. A provisional target (the group test, the midpoint) folds against
//      the median of the part's frames under that fragment; the final target folds against
//      the final piece's own median (an uncut part: its `centreHz`, rule 3 as written).
//  D11 The fold's tie: exactly 6 semitones (within `octaveTieSemitones`) goes LOWER. This is
//      NOT `PitchCorrectionScale.nearestAllowedMidi`, whose tie goes higher.
//  D12 Valid melody notes split into `notesUsed`, `unsungNotes` (no part overlaps the note)
//      and `outvotedNotes` (a part overlaps it, but every piece there took another note).
//  D13 A held part whose frames cannot be re-found is still matched (rule 1 needs only
//      spans) but never cut, and is named in `partsWithoutFrames`. Nothing is silent.
//  D14 A clip pitch shift (W7-PK's PK-F1, installed 2026-10-04 after the design was written):
//      the melody is what PLAYS, so every target is folded and compared at `sung + whole`
//      (the shift's whole semitones) and brought back to the recording by `− whole`, the
//      arithmetic `PitchAutoCorrect.segment(forPart:)` now uses for a scale. The shift's
//      fraction is a kept detune, never corrected (the 2026-10-04 ruling).

/// Tuning a vocal to a melody (design §3.2): which melody note each sung note gets, where the
/// melody cuts a sung note in two, and every disagreement the response must report (§3.3).
public enum PitchMelodyTarget {

    // MARK: - The constants — each is the ONE home for its number

    /// **An overlap shorter than this, seconds, is LEGATO, not a chord** (§3.3 row 5): the
    /// earlier note ends where the later one starts. 60 ms, the design's number; it equals
    /// `PitchAutoCorrect.minimumNoteSeconds` but is a fact about MIDI playing (a tail a
    /// player leaves when moving to the next key), not about detected notes, so it has its own
    /// home. Only a TAIL overlap can be legato (D3).
    public static let legatoOverlapSeconds: Double = 0.06

    /// **A move larger than this, cents, is reported in `farMoves`** (§3.3 row 7, §5: one of
    /// the defaults that is "one constant"). Strictly larger: a move of exactly 300 c is not
    /// far. Above it, with `formantPreserve` off, the voice's character moves with the pitch
    /// [INFERRED by the design].
    public static let farMoveCents: Double = 300

    /// **The octave fold's tie band, semitones** (D11). A median 6 semitones from both
    /// octaves of the melody's pitch class, within this, folds LOWER. It absorbs only the
    /// round-trip error of `hz(fromMidi:)` → `midi(fromHz:)` (~1e-14), not a judgement.
    public static let octaveTieSemitones: Double = 1e-9

    // MARK: - Input

    /// One melody note, already in VOCAL SOURCE seconds: the `ClipPitchFrame.timeSeconds`
    /// domain. The store converts beats (§3.2 "Beats to vocal seconds"); this never sees one.
    ///
    /// Nested, not top-level: `VoiceRangeFit.MelodyNote` (a duration and a fractional pitch,
    /// for range fitting) already holds the bare name in this module.
    public struct MelodyNote: Codable, Sendable, Equatable {
        public var startSeconds: Double
        /// Exclusive, like a note segment's.
        public var endSeconds: Double
        /// MIDI note number, as written (60 = C4). A value outside 0…127 makes the note
        /// invalid (`Plan.invalidNotes`), never clamped.
        public var midi: Int

        public init(startSeconds: Double, endSeconds: Double, midi: Int) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.midi = midi
        }

        /// Finite times, a positive length and a MIDI note number.
        public var isValid: Bool {
            startSeconds.isFinite && endSeconds.isFinite && endSeconds > startSeconds
                && (0...127).contains(midi)
        }
    }

    /// Which octave of the melody's note a sung note goes to (rule 3). Raw strings are the
    /// wire values the design names for M2 (§3.4); additive only, never rename.
    public enum OctaveMatch: String, Codable, Sendable, Equatable, CaseIterable {
        /// The melody's pitch class in the octave nearest the sung note's own median, so a
        /// low voice can follow a high lead. A 6-semitone tie goes LOWER (D11). The default.
        case nearestOctave
        /// The melody's note exactly as written.
        case exact
    }

    // MARK: - Output

    /// One row of the note table a melody pass writes, in time order: a held part, one piece
    /// of a held part the melody cut, or a slide passed through.
    public struct Piece: Sendable, Equatable {
        public enum Role: String, Sendable, Equatable, CaseIterable {
            /// A held note with a melody note: tune it to `targetMidi`.
            case matched
            /// A held note where the melody rests: as sung, or to the scale if one was sent
            /// (§3.3 row 1). The caller decides which; this plan only says so.
            case unmatched
            /// A `.transition` part: the preset's own table, which the melody never changes.
            case transition
        }

        public let role: Role
        /// Index of the `NotePart` this row came from. Pieces of one cut part share it.
        public let partIndex: Int
        /// Source-file seconds. A cut's two sides share the boundary bit for bit: it is the
        /// right-hand piece's first frame time, the splitter's own convention.
        public let startSeconds: Double
        public let endSeconds: Double
        /// What was sung: an uncut part's own `centreHz`; a cut piece's MEDIAN of its own raw
        /// frames (`PitchCorrectionMath.medianFrequency`, the splitter's estimator).
        public let centreHz: Double
        public let medianConfidence: Double
        public let frameCount: Int
        /// The melody note this row took, as an index into the caller's `melody`. `nil`
        /// unless `.matched`.
        public let melodyIndex: Int?
        /// The pitch it PLAYS once tuned, a MIDI note number after the octave rule (in the
        /// melody's own domain: with a clip shift, the recording is moved to
        /// `targetMidi − whole`, and the shift's fraction stays on top). `nil` unless
        /// `.matched`.
        public let targetMidi: Int?
        /// Octaves between `targetMidi` and the written note (−1: an octave below it). 0
        /// when not folded, and for every row that is not `.matched`.
        public let octaveShift: Int
        /// `strength × (target − detected) × 100`, the arithmetic of
        /// `PitchAutoCorrect.segment(forPart:)`, operand for operand, clamped to
        /// `NoteSegment.pitchOffsetCentsRange` as the stored segment's is. `nil` unless
        /// `.matched`.
        public let offsetCents: Double?
    }

    /// A cut the melody added inside one held part (rule 2).
    public struct Cut: Sendable, Equatable {
        public enum Placement: String, Sendable, Equatable, CaseIterable {
            /// Where the de-glitched f0 crossed the midpoint of the two targets (D7).
            case crossing
            /// At the melody's own boundary: no crossing in the window.
            case melodyBoundary
        }
        public let partIndex: Int
        /// The right-hand piece's first frame time.
        public let seconds: Double
        /// The melody boundary the cut was searched around (D5).
        public let melodyBoundarySeconds: Double
        public let placement: Placement
    }

    /// A row whose target is not the written note (rule 3, §3.3 row 6).
    public struct OctaveFold: Sendable, Equatable {
        public let pieceIndex: Int
        public let octaves: Int
    }

    /// A move larger than `farMoveCents` (§3.3 row 7). Applied, and reported.
    public struct FarMove: Sendable, Equatable {
        public let pieceIndex: Int
        public let cents: Double
    }

    /// Everything a melody pass decided. The store (M2) reports these fields; it never
    /// re-derives one. Every index list is ascending.
    public struct Plan: Sendable, Equatable {
        /// The note table's rows (sounds excluded), in time order.
        public let pieces: [Piece]
        public let octaveMatch: OctaveMatch
        /// The strength the offsets were computed with, after healing.
        public let strength: Double
        /// Indices into `pieces` of the held rows under a melody rest (§3.3 row 1).
        public let unmatchedParts: [Int]
        /// Melody indices of valid notes that no part overlaps: nothing was sung there, and
        /// v1 never invents singing (§3.3 row 2).
        public let unsungNotes: [Int]
        /// Melody indices of valid notes a part overlaps but no row took: a note under
        /// 60 ms inside a longer one (F-fast), an edge the S guard kept (D6), a majority lost.
        public let outvotedNotes: [Int]
        /// Every cut the melody added (§3.3 row 4), in time order.
        public let cutsAdded: [Cut]
        /// Melody indices of notes that lost sounding time to a strictly HIGHER note: a
        /// chord, reduced to its top note (§3.3 row 5, D3). Legato tails are not here.
        public let chordsReduced: [Int]
        /// Rows tuned to another octave of the written note (§3.3 row 6).
        public let octaveFolded: [OctaveFold]
        /// Rows moved by more than `farMoveCents` (§3.3 row 7).
        public let farMoves: [FarMove]
        /// Melody indices of notes with a non-finite time, no length or no MIDI number. They
        /// take part in nothing.
        public let invalidNotes: [Int]
        /// Held part indices whose frames could not be re-found: matched, never cut (D13).
        public let partsWithoutFrames: [Int]

        /// Melody indices some row took, ascending.
        public var notesUsed: [Int] {
            Array(Set(pieces.compactMap(\.melodyIndex))).sorted()
        }

        /// How many rows were tuned to the melody.
        public var matchedParts: Int { pieces.filter { $0.role == .matched }.count }
    }

    // MARK: - The request and what was applied (phase 2: `PitchAutoCorrect.build(…, melody:)`)

    /// What a held part under a melody REST becomes (§3.3 row 1).
    public enum Unmatched: String, Codable, Sendable, Equatable, CaseIterable {
        /// As sung: identity under every preset, Hard Tune included. The default: the caller
        /// sent no scale.
        case asSung
        /// Tuned to the pass's scale exactly as a melody-less pass tunes it: the caller sent
        /// one (Waves Tune's "normal functioning resumes", §3.5).
        case toScale
    }

    /// A melody pass's target, the `melody:` argument of `PitchAutoCorrect.build` and
    /// `editSet`. Not a `PitchAutoCorrectOptions` field: the options are the preset, and the
    /// melody is the target (§3.4). Strength is the options' own; rule 5's "1 unless sent"
    /// is the store's to set.
    public struct Request: Sendable, Equatable {
        public var notes: [MelodyNote]
        public var octaveMatch: OctaveMatch
        public var unmatched: Unmatched

        public init(notes: [MelodyNote], octaveMatch: OctaveMatch = .nearestOctave,
                    unmatched: Unmatched = .asSung) {
            self.notes = notes
            self.octaveMatch = octaveMatch
            self.unmatched = unmatched
        }
    }

    /// What a melody pass applied (`PitchNoteTableBuild.melody`): the plan, and the id of the
    /// note segment each of its rows became, so the store reports `farMoves` and
    /// `unmatchedParts` by segment id without re-deriving them.
    public struct Applied: Sendable, Equatable {
        public let plan: Plan
        /// One per `plan.pieces` element, in the same order.
        public let segmentIDs: [UUID]

        public init(plan: Plan, segmentIDs: [UUID]) {
            self.plan = plan
            self.segmentIDs = segmentIDs
        }
    }

    // MARK: - The plan

    /// **THE MATCH** (§3.2 rules 1–4, §3.3, the D-rules in this file's banner).
    ///
    /// - Parameters:
    ///   - parts: `PitchNoteSplitter.parts(in: frames, …)`, in time order.
    ///   - frames: the SAME detection's frames (any order); a cut piece's median and the
    ///     crossing search read them.
    ///   - frameRateHz: the detection's own rate. A rate that is not a real positive number
    ///     makes no cut and no frame-resolution floor.
    ///   - melody: notes in vocal source seconds, any order, overlaps allowed.
    ///   - octaveMatch: rule 3; `nearestOctave` by default.
    ///   - strength: the pass's strength; healed like `PitchAutoCorrectOptions.strength`
    ///     (non-finite → 0, clamped to 0…1). Rule 5's "1 unless sent" is the caller's.
    ///   - clipShiftSemitones: the clip's pitch shift (PK-F1). The melody is what PLAYS, so a
    ///     note is matched at `sung + whole`, the shift's whole semitones
    ///     (`PitchAutoCorrect.splitClipShift`), and its offset comes back to the recording,
    ///     exactly as `PitchAutoCorrect`'s scale arithmetic does. The FRACTION is a kept
    ///     detune: a clip shifted +3.3 plays each note 30 c sharp of the melody, as its shift
    ///     asks (the 2026-10-04 ruling). 0, the default, changes nothing.
    public static func plan(parts: [NotePart], frames: [ClipPitchFrame], frameRateHz: Double,
                            melody: [MelodyNote], octaveMatch: OctaveMatch = .nearestOctave,
                            strength: Double = 1, clipShiftSemitones: Double = 0) -> Plan {
        let strength = PitchCorrectionMath.finite(strength, default: 0).clamped(to: 0...1)
        // A shift that is not a number shifts nothing (the store refuses one before this).
        let whole = PitchAutoCorrect.splitClipShift(
            PitchCorrectionMath.finite(clipShiftSemitones, default: 0)).whole
        let counts = PitchNoteSplitter.frameCounts(frameRateHz: frameRateHz)
        let period = counts == nil ? 0 : 1 / frameRateHz
        // D1 and D2: half a frame is both the floor and the tie band.
        let resolution = period / 2
        let valid = melody.indices.filter { melody[$0].isValid }
        let line = Self.line(melody, valid: valid)
        let voiced = frames.filter { $0.frequencyHz != nil && $0.timeSeconds.isFinite }
            .sorted { $0.timeSeconds < $1.timeSeconds }
        let context = Context(melody: melody, fragments: line.fragments, octaveMatch: octaveMatch,
                              strength: strength, whole: whole, resolution: resolution,
                              period: period)

        var pieces: [Piece] = []
        var cuts: [Cut] = []
        var withoutFrames: [Int] = []
        for (partIndex, part) in parts.enumerated() {
            guard part.kind == .held else {
                pieces.append(Piece(role: .transition, partIndex: partIndex, part: part))
                continue
            }
            let partFrames = Self.frames(of: part, in: voiced)
            if partFrames == nil { withoutFrames.append(partIndex) }
            let made = Self.pieces(of: part, partIndex: partIndex, frames: partFrames,
                                   counts: counts, context: context)
            pieces += made.pieces
            cuts += made.cuts
        }

        // D12: what became of every valid note.
        let used = Set(pieces.compactMap(\.melodyIndex))
        var unsung: [Int] = []
        var outvoted: [Int] = []
        for index in valid where !used.contains(index) {
            guard let span = line.spans[index] else { continue }
            let sungOver = parts.contains {
                overlap(span.start, span.end, $0.startSeconds, $0.endSeconds) > resolution
            }
            if sungOver { outvoted.append(index) } else { unsung.append(index) }
        }
        var folded: [OctaveFold] = []
        var far: [FarMove] = []
        for (index, piece) in pieces.enumerated() {
            if piece.octaveShift != 0 { folded.append(OctaveFold(pieceIndex: index, octaves: piece.octaveShift)) }
            if let cents = piece.offsetCents, abs(cents) > farMoveCents {
                far.append(FarMove(pieceIndex: index, cents: cents))
            }
        }
        return Plan(pieces: pieces, octaveMatch: octaveMatch, strength: strength,
                    unmatchedParts: pieces.indices.filter { pieces[$0].role == .unmatched },
                    unsungNotes: unsung, outvotedNotes: outvoted, cutsAdded: cuts,
                    chordsReduced: line.reduced, octaveFolded: folded, farMoves: far,
                    invalidNotes: melody.indices.filter { !melody[$0].isValid },
                    partsWithoutFrames: withoutFrames)
    }

    // MARK: - The melody line (D3)

    /// A stretch of the reduced melody line: one input note while it is the top sounding note.
    struct Fragment: Sendable, Equatable {
        let start: Double
        let end: Double
        let midi: Int
        /// Index into the caller's `melody`.
        let source: Int
    }

    /// The melody as ONE line, plus which notes a chord reduced and each valid note's span
    /// after the legato rule (what D12 tests "sung over" against).
    struct Line: Sendable, Equatable {
        let fragments: [Fragment]
        let reduced: [Int]
        let spans: [Int: Span]
    }

    struct Span: Sendable, Equatable {
        let start: Double
        let end: Double
    }

    /// D3. First the legato rule: a note whose tail overlaps a later note's start by under
    /// `legatoOverlapSeconds`, while that later note outlasts it, ends where the later note
    /// starts. Then, at every instant, the HIGHEST sounding note is the line (equal pitches:
    /// the earlier start, then the lower index); a note under a strictly higher one is
    /// reduced. Fragments of one note that abut are joined.
    static func line(_ melody: [MelodyNote], valid: [Int]) -> Line {
        var spans: [Int: Span] = [:]
        for a in valid {
            let note = melody[a]
            var end = note.endSeconds
            for b in valid where b != a {
                let later = melody[b]
                let tail = later.startSeconds > note.startSeconds && later.startSeconds < note.endSeconds
                    && note.endSeconds < later.endSeconds
                if tail, note.endSeconds - later.startSeconds < legatoOverlapSeconds {
                    end = min(end, later.startSeconds)
                }
            }
            spans[a] = Span(start: note.startSeconds, end: end)
        }
        let edges = Array(Set(spans.values.flatMap { [$0.start, $0.end] })).sorted()
        // The order a tie is broken in: the earlier start, then the lower index.
        let order = valid.sorted {
            (melody[$0].startSeconds, $0) < (melody[$1].startSeconds, $1)
        }
        var fragments: [Fragment] = []
        var reduced = Set<Int>()
        for (lo, hi) in zip(edges, edges.dropFirst()) {
            let sounding = order.filter { index in
                guard let span = spans[index] else { return false }
                return span.start <= lo && span.end >= hi
            }
            guard var top = sounding.first else { continue }
            for index in sounding.dropFirst() where melody[index].midi > melody[top].midi {
                top = index
            }
            for index in sounding where melody[index].midi < melody[top].midi {
                reduced.insert(index)
            }
            if let last = fragments.last, last.source == top, last.end == lo {
                fragments[fragments.count - 1] = Fragment(start: last.start, end: hi,
                                                          midi: last.midi, source: top)
            } else {
                fragments.append(Fragment(start: lo, end: hi, midi: melody[top].midi, source: top))
            }
        }
        return Line(fragments: fragments, reduced: reduced.sorted(), spans: spans)
    }

    // MARK: - One held part

    /// What every part's step reads.
    struct Context {
        let melody: [MelodyNote]
        let fragments: [Fragment]
        let octaveMatch: OctaveMatch
        let strength: Double
        /// The clip shift's whole semitones: what is added to a sung pitch to get the
        /// played one.
        let whole: Double
        let resolution: Double
        let period: Double
    }

    /// A group of D4: neighbouring eligible fragments with one provisional target.
    struct Group {
        var fragments: [Int]
        let target: Int
    }

    /// A held part's rows, and the cuts that made them.
    static func pieces(of part: NotePart, partIndex: Int, frames: [ClipPitchFrame]?,
                       counts: PitchNoteSplitter.FrameCounts?,
                       context: Context) -> (pieces: [Piece], cuts: [Cut]) {
        // Rule 1, whole: the part as the splitter made it, unless the melody cuts it.
        func whole() -> (pieces: [Piece], cuts: [Cut]) {
            let candidates = context.fragments.indices
            guard let source = majority(of: candidates, over: part.startSeconds, part.endSeconds,
                                        context: context) else {
                return ([Piece(role: .unmatched, partIndex: partIndex, part: part)], [])
            }
            return ([matched(partIndex: partIndex, start: part.startSeconds, end: part.endSeconds,
                             centreHz: part.centreHz, confidence: part.medianConfidence,
                             frameCount: part.frameCount, source: source, context: context)], [])
        }
        guard let frames, let counts, !frames.isEmpty else { return whole() }
        let n = frames.count
        let hz = frames.compactMap(\.frequencyHz)
        let midis = hz.map(PitchCorrectionMath.midi(fromHz:))
        let period = context.period

        // D4: the eligible fragments, grouped by their provisional target (D10).
        var groups: [Group] = []
        for index in context.fragments.indices {
            let fragment = context.fragments[index]
            let lo = max(fragment.start, part.startSeconds)
            let hi = min(fragment.end, part.endSeconds)
            guard hi - lo >= PitchAutoCorrect.minimumNoteSeconds - 1e-9 else { continue }
            let under = frames.indices.filter {
                let middle = frames[$0].timeSeconds + period / 2
                return middle >= lo && middle < hi
            }.map { hz[$0] }
            let reference = PitchCorrectionMath.medianFrequency(under) ?? part.centreHz
            // Played domain (sung + whole), like every target in this file.
            let target = folded(fragment.midi,
                                toward: PitchCorrectionMath.midi(fromHz: reference) + context.whole,
                                context.octaveMatch)
            if let last = groups.last, last.target == target {
                groups[groups.count - 1].fragments.append(index)
            } else {
                groups.append(Group(fragments: [index], target: target))
            }
        }
        guard groups.count > 1 else { return whole() }

        // D5 and D6: each boundary between groups, kept only away from the part's edges.
        let s = counts.scoopLimit
        var boundaries: [(after: Int, seconds: Double, j: Int, mid: Double)] = []
        for g in groups.indices.dropLast() {
            guard let leftIndex = groups[g].fragments.last,
                  let rightIndex = groups[g + 1].fragments.first else { continue }
            let b = (context.fragments[leftIndex].end + context.fragments[rightIndex].start) / 2
            let j = frames.filter { $0.timeSeconds + period / 2 < b }.count
            guard j > s, n - j > s else { continue }
            // Back in the SUNG domain, where `x` lives.
            let mid = (Double(groups[g].target) + Double(groups[g + 1].target)) / 2 - context.whole
            boundaries.append((after: g, seconds: b, j: j, mid: mid))
        }
        guard !boundaries.isEmpty else { return whole() }

        // D7 and D8: place each cut, left to right.
        let x = PitchNoteSplitter.runningMedian(midis, halfWidth: counts.deglitch / 2)
        let m = counts.minimumNote
        var accepted: [(k: Int, after: Int, cut: Cut)] = []
        var previous = 0
        for (i, boundary) in boundaries.enumerated() {
            let next = i + 1 < boundaries.count ? boundaries[i + 1].j : n
            let lo = max(boundary.j - s, previous + m, 1)
            let hi = min(boundary.j + s, next - m)
            guard lo <= hi else { continue }
            let rising = groups[boundary.after + 1].target > groups[boundary.after].target
            var best: Int?
            for k in lo...hi {
                let crosses = rising ? (x[k - 1] < boundary.mid && x[k] >= boundary.mid)
                    : (x[k - 1] > boundary.mid && x[k] <= boundary.mid)
                guard crosses else { continue }
                if let current = best, abs(current - boundary.j) <= abs(k - boundary.j) { continue }
                best = k
            }
            let k = best ?? min(max(boundary.j, lo), hi)
            accepted.append((k: k, after: boundary.after, cut: Cut(
                partIndex: partIndex, seconds: frames[k].timeSeconds,
                melodyBoundarySeconds: boundary.seconds,
                placement: best == nil ? .melodyBoundary : .crossing)))
            previous = k
        }
        guard !accepted.isEmpty else { return whole() }

        // D9: each piece takes the majority among its own groups' fragments.
        var pieces: [Piece] = []
        var firstGroup = 0
        for p in 0...accepted.count {
            let lower = p == 0 ? 0 : accepted[p - 1].k
            let upper = p == accepted.count ? n : accepted[p].k
            let lastGroup = p == accepted.count ? groups.count - 1 : accepted[p].after
            let start = p == 0 ? part.startSeconds : frames[lower].timeSeconds
            let end = p == accepted.count ? part.endSeconds : frames[upper].timeSeconds
            let own = groups[firstGroup...lastGroup].flatMap(\.fragments)
            let centre = PitchCorrectionMath.medianFrequency(Array(hz[lower..<upper])) ?? part.centreHz
            let confidence = PitchCorrectionMath.median(frames[lower..<upper].map(\.confidence)) ?? 0
            if let source = majority(of: own, over: part.startSeconds, part.endSeconds, context: context) {
                pieces.append(matched(partIndex: partIndex, start: start, end: end, centreHz: centre,
                                      confidence: confidence, frameCount: upper - lower,
                                      source: source, context: context))
            } else {
                // Defensive: a group's fragments always overlap the part by ≥ 60 ms.
                pieces.append(Piece(role: .unmatched, partIndex: partIndex, startSeconds: start,
                                    endSeconds: end, centreHz: centre, medianConfidence: confidence,
                                    frameCount: upper - lower, melodyIndex: nil, targetMidi: nil,
                                    octaveShift: 0, offsetCents: nil))
            }
            firstGroup = lastGroup + 1
        }
        return (pieces, accepted.map(\.cut))
    }

    /// Rule 1 (D1, D2) over `candidates` (indices into `context.fragments`): each note's
    /// summed overlap with `[start, end)`; only overlaps above the floor count; the largest
    /// wins, and the notes within half a frame of it tie, won by the earlier start (then the
    /// lower index). `nil` when nothing counts.
    static func majority(of candidates: some Sequence<Int>, over start: Double, _ end: Double,
                         context: Context) -> Int? {
        var totals: [Int: Double] = [:]
        for index in candidates {
            let fragment = context.fragments[index]
            let amount = overlap(fragment.start, fragment.end, start, end)
            if amount > 0 { totals[fragment.source, default: 0] += amount }
        }
        let counted = totals.filter { $0.value > context.resolution }
        guard let largest = counted.values.max() else { return nil }
        let tied = counted.filter { $0.value >= largest - context.resolution }.keys
        return tied.min {
            (context.melody[$0].startSeconds, $0) < (context.melody[$1].startSeconds, $1)
        }
    }

    /// A `.matched` row: the target folded against what this row PLAYS (D10, PK-F1), and the
    /// offset in `segment(forPart:)`'s arithmetic, expression for expression: the target comes
    /// back to the recording by the shift's whole semitones, then
    /// `strength * (targetMidi - detectedMidi) * 100`.
    static func matched(partIndex: Int, start: Double, end: Double, centreHz: Double,
                        confidence: Double, frameCount: Int, source: Int,
                        context: Context) -> Piece {
        let written = context.melody[source].midi
        let detectedMidi = PitchCorrectionMath.midi(fromHz: centreHz)
        let target = folded(written, toward: detectedMidi + context.whole, context.octaveMatch)
        let targetMidi = Double(target) - context.whole
        // Clamped where every stored offset is (`NoteSegment.init`), so this row's offset IS
        // the applied one, and `farMoves` reports what plays. A value inside the range comes
        // back bit for bit; only an `exact` move past two octaves is ever clamped.
        let offset = (context.strength * (targetMidi - detectedMidi) * 100)
            .clamped(to: NoteSegment.pitchOffsetCentsRange)
        return Piece(role: .matched, partIndex: partIndex, startSeconds: start, endSeconds: end,
                     centreHz: centreHz, medianConfidence: confidence, frameCount: frameCount,
                     melodyIndex: source, targetMidi: target, octaveShift: (target - written) / 12,
                     offsetCents: offset)
    }

    // MARK: - The octave rule (rule 3, D11)

    /// `written` under `match`: as written, or its pitch class in the octave nearest
    /// `medianMidi`, a 6-semitone tie going LOWER.
    static func folded(_ written: Int, toward medianMidi: Double, _ match: OctaveMatch) -> Int {
        guard match == .nearestOctave, medianMidi.isFinite else { return written }
        let octaves = ((medianMidi - Double(written)) / 12).rounded(.down)
        // A voice's median is a few octaves from any written note; anything else is not a
        // pitch this can fold toward.
        guard abs(octaves) < 32 else { return written }
        let lower = written + 12 * Int(octaves)
        let upper = lower + 12
        let below = medianMidi - Double(lower)
        let above = Double(upper) - medianMidi
        return below <= above + octaveTieSemitones ? lower : upper
    }

    // MARK: - Helpers

    /// The length of `[a0, a1) ∩ [b0, b1)`, or 0.
    static func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }

    /// A part's own frames in `voiced` (sorted, voiced, finite times): those whose time lies
    /// in `[start, end)`, which is exactly the splitter's frame convention. `nil` when their
    /// count is not the part's `frameCount` (D13).
    static func frames(of part: NotePart, in voiced: [ClipPitchFrame]) -> [ClipPitchFrame]? {
        var low = 0
        var high = voiced.count
        while low < high {
            let middle = (low + high) / 2
            if voiced[middle].timeSeconds < part.startSeconds { low = middle + 1 } else { high = middle }
        }
        var found: [ClipPitchFrame] = []
        var index = low
        while index < voiced.count, voiced[index].timeSeconds < part.endSeconds {
            found.append(voiced[index])
            index += 1
        }
        guard part.frameCount > 0, found.count == part.frameCount else { return nil }
        return found
    }
}

extension PitchMelodyTarget.Piece {
    /// A part passed through whole, with no melody note: a slide, or a held part under a rest.
    init(role: Role, partIndex: Int, part: NotePart) {
        self.init(role: role, partIndex: partIndex, startSeconds: part.startSeconds,
                  endSeconds: part.endSeconds, centreHz: part.centreHz,
                  medianConfidence: part.medianConfidence, frameCount: part.frameCount,
                  melodyIndex: nil, targetMidi: nil, octaveShift: 0, offsetCents: nil)
    }
}

// MARK: - The melody branch of the auto-correct policy (phase 2)

extension PitchAutoCorrect {
    /// `build(contour:…, melody:)`'s table (Tune to Melody, design §3.2): ONE segment per
    /// row of the plan, where `build`'s melody-less table has one per part.
    ///
    ///     row          segment
    ///     .matched     the plan's offset; scales `1 − strength` when flattening, else 1
    ///                  (exactly `segment(forPart:)`'s `locked`, aimed at the melody)
    ///     .unmatched   `.asSung`: identity (offset 0, both scales 1), whatever the preset;
    ///                  `.toScale`: `segment(forPart:)`, the melody-less segment
    ///     .transition  `segment(forPart:)`: the preset's own slide, identity under (a-T)
    ///
    /// Sounds come from the finder over the plan's ROWS, so a sound borrows the row drawn
    /// beside it (a cut part's nearer piece, not the whole part's median). Called only
    /// after `build`'s strength guard, with the splitter's own parts.
    static func melodyBuild(frames: [ClipPitchFrame], frameRateHz: Double, parts: [NotePart],
                            options: PitchAutoCorrectOptions, analysisVersion: Int,
                            slideShape: PitchSlideShape, clipShiftSemitones: Double,
                            melody: PitchMelodyTarget.Request) -> PitchNoteTableBuild {
        let plan = PitchMelodyTarget.plan(parts: parts, frames: frames, frameRateHz: frameRateHz,
                                          melody: melody.notes, octaveMatch: melody.octaveMatch,
                                          strength: options.strength,
                                          clipShiftSemitones: clipShiftSemitones)
        let unpitched = PitchUnpitchedFinder.sounds(
            in: frames, frameRateHz: frameRateHz,
            notes: plan.pieces.map {
                PitchUnpitchedFinder.Note(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                                          hz: $0.centreHz)
            })
        let shapeScale = options.preserveVibrato ? 1 : (1 - options.strength)
        let notes = plan.pieces.map { piece -> NoteSegment in
            // Today's segment for the whole part, when the row IS the whole part.
            func partSegment() -> NoteSegment? {
                guard parts.indices.contains(piece.partIndex),
                      parts[piece.partIndex].frameCount == piece.frameCount else { return nil }
                return segment(forPart: piece.partIndex, of: parts, options: options,
                               shapeScale: shapeScale, slideShape: slideShape,
                               clipShiftSemitones: clipShiftSemitones)
            }
            func asSung() -> NoteSegment {
                NoteSegment(startSeconds: piece.startSeconds, endSeconds: piece.endSeconds,
                            detectedHz: piece.centreHz, detectedConfidence: piece.medianConfidence,
                            origin: origin(of: piece.role == .transition ? .transition : .held))
            }
            switch piece.role {
            case .matched:
                return NoteSegment(startSeconds: piece.startSeconds, endSeconds: piece.endSeconds,
                                   detectedHz: piece.centreHz,
                                   detectedConfidence: piece.medianConfidence,
                                   pitchOffsetCents: piece.offsetCents ?? 0,
                                   driftScale: shapeScale, vibratoScale: shapeScale,
                                   origin: origin(of: .held))
            case .unmatched where melody.unmatched == .toScale, .transition:
                return partSegment() ?? asSung()
            case .unmatched:
                return asSung()
            }
        }
        let sounds = unpitched.sounds.map(segment(forSound:))
        return PitchNoteTableBuild(
            editSet: newSet(segments: notes + sounds, options: options,
                            analysisVersion: analysisVersion),
            unpitched: unpitched,
            melody: PitchMelodyTarget.Applied(plan: plan, segmentIDs: notes.map(\.id)))
    }
}
