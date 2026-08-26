import Foundation

/// **The ONE definition of "is this gap a breath?"** — factored out of the
/// humanize legato pass (m27-o ⓑ) so the breath pad (P1) classifies rests the
/// same way the articulation pass does, instead of growing a second threshold
/// that drifts from the first.
///
/// ## Why this is its own file
///
/// `ProjectStore+Humanize.applyLegatoPass` owned this test inline as a `guard`.
/// It is a *musical* judgement — "a gap this size is articulation; a gap this
/// size is the player breathing" — and the pad needs exactly the same judgement
/// to decide where one phrase ends and the next begins. Two copies of a
/// threshold rule is how "the legato pass closed the gap the pad thinks is a
/// breath" ships. The number itself still lives in one place
/// (`HumanizeLegato.defaultMaxGapBeats`) and is still argued there.
///
/// ## Everything here is PURE
///
/// No store, no engine, no UI, no randomness, no clock. Every function is a
/// function of its arguments — the `BreathContour` / `applyLegatoPass`
/// precedent — so the same notes always classify the same way, in a test, in a
/// bounce, and in the app.
public enum PhraseDetection {

    // MARK: - The gap classifier

    /// What the gap between a note's end and the NEXT attack means musically.
    ///
    /// Deliberately three cases and not a `Bool`: the legato pass treats
    /// `.overlap` and `.breath` identically (it touches neither) but for
    /// *opposite* reasons — one is already joined, the other must stay open —
    /// and a caller that cannot tell them apart cannot report either honestly.
    public enum NoteGap: Equatable, Sendable {
        /// `gap < 0` — the notes already overlap. Never shortened by anything
        /// here: the legato pass only ever extends (its idempotence rests on
        /// this), and a phrase is certainly not broken by an overlap.
        case overlap
        /// `0 <= gap <= maxGapBeats` — a join. Small enough to be the
        /// articulation between two notes of one gesture, so the legato pass
        /// closes it and phrase detection keeps both notes in one phrase.
        case articulation
        /// `gap > maxGapBeats` — a REST. For a wind part, the player breathing.
        /// Left exactly as authored by the legato pass, and it is where
        /// `phrases(in:maxGapBeats:)` cuts.
        case breath
    }

    /// Classifies one gap, in beats, against the ceiling.
    ///
    /// ⚠️ **The branch ORDER is load-bearing and is a behaviour-preservation
    /// contract**, not a style choice. `applyLegatoPass` guarded with
    /// `gap >= 0, gap <= maxGapBeats` and skipped otherwise; a NaN gap (or a
    /// NaN ceiling — a hand-authored wire payload can produce either) fails
    /// BOTH comparisons and was skipped. Testing `.articulation` FIRST, with
    /// exactly that conjunction, and only then `< 0`, reproduces this: NaN is
    /// neither articulation nor overlap and falls through to `.breath`, which
    /// the legato pass also skips. Reordering the branches — `if gap < 0`
    /// first — is still correct for every finite input and silently changes
    /// nothing observable, but it stops being a *transcription* of the code it
    /// replaced, and this refactor's whole claim is that it is one.
    public static func classify(gapBeats: Double, maxGapBeats: Double) -> NoteGap {
        if gapBeats >= 0, gapBeats <= maxGapBeats { return .articulation }
        if gapBeats < 0 { return .overlap }
        return .breath
    }

    // MARK: - Phrases

    /// A run of notes with no breath in it — the span a phrase-scoped effort
    /// pattern (a hairpin, a terraced level) is normalised against.
    ///
    /// `startBeat` is the FIRST note's onset and `endBeat` the LAST note's end,
    /// both clip-relative, which is the span §7.1 of the breath-pad design
    /// names ("onset of first note to end of last").
    public struct Phrase: Equatable, Sendable {
        /// The notes in this phrase, in the order `phrases(in:)` visited them:
        /// ascending by onset, and within one onset in the input array's order.
        /// Ids rather than notes so a caller can look them up in whatever
        /// (possibly re-ordered) array it holds.
        public var noteIDs: [UUID]
        /// Clip-relative onset of the first note.
        public var startBeat: Double
        /// Clip-relative end (`startBeat + lengthBeats`) of the note that ends
        /// LAST — not necessarily the note that starts last.
        public var endBeat: Double

        public init(noteIDs: [UUID], startBeat: Double, endBeat: Double) {
            self.noteIDs = noteIDs
            self.startBeat = startBeat
            self.endBeat = endBeat
        }

        /// Span in beats. Zero for a one-note phrase of zero length; never
        /// negative.
        public var lengthBeats: Double { max(0, endBeat - startBeat) }

        /// Where `beat` sits inside this phrase, as a fraction in 0...1 — the
        /// `u` a phrase-scoped `EffortPattern` is evaluated at.
        ///
        /// A zero-length phrase (one instantaneous note) returns 0 rather than
        /// dividing by zero: the pattern's value at its own start is the only
        /// defensible answer when there is no span to be anywhere in.
        public func position(ofBeat beat: Double) -> Double {
            let span = lengthBeats
            guard span > 0 else { return 0 }
            return min(1, max(0, (beat - startBeat) / span))
        }
    }

    /// Splits `notes` into phrases at every BREATH.
    ///
    /// ## The rule, and the case that decides it
    ///
    /// Notes are visited in onset order and grouped into *attack points* (exact
    /// `startBeat` equality — a chord is one attack point, the
    /// `applyLegatoPass` definition). The phrase breaks between attack point
    /// *i* and *i+1* when the gap from the point where **every voice of group
    /// *i* has stopped** to the next onset classifies as `.breath`.
    ///
    /// ⭐ **"Every voice has stopped" means the group's MAXIMUM end, which is
    /// the SMALLEST gap, which produces the FEWEST breaks.** The case that
    /// decides it: a chord where one voice sustains across what would otherwise
    /// be a rest. Under a per-note rule the short voices each report a breath
    /// and the phrase would break *while a note is still sounding* — a phrase
    /// boundary the ear cannot hear, and a hairpin normalised against it would
    /// restart its crescendo mid-chord. A player who is still making a sound has
    /// not taken a breath. This is a deliberate, tested decision, not a
    /// convenience: the opposite rule (break if ANY voice leaves a breath) is
    /// defensible for strictly monophonic input, where the two agree exactly,
    /// and wrong the moment anything overlaps.
    ///
    /// An empty input returns no phrases. Input with one attack point returns
    /// exactly one phrase. `maxGapBeats` is passed to `classify` unchanged, so a
    /// negative or NaN ceiling degrades the same way it does in the legato pass:
    /// every gap becomes a breath and every attack point its own phrase.
    ///
    /// ⚠️ This grouping is a SECOND implementation of the onset grouping in
    /// `applyLegatoPass`, deliberately. That one writes back through the notes'
    /// ORIGINAL array indices (its contract is index-preserving) and sorts with
    /// a non-total predicate it documents as safe for exactly that use; this one
    /// needs a total order and returns ids. Sharing one grouping would mean
    /// making `applyLegatoPass`'s sort total, which changes its code without
    /// changing its behaviour — and this refactor's claim is that the legato
    /// pass's behaviour is untouched. Two small groupings beat one shared
    /// grouping plus a caveat.
    public static func phrases(in notes: [MIDINote],
                               maxGapBeats: Double = HumanizeLegato.defaultMaxGapBeats) -> [Phrase] {
        guard !notes.isEmpty else { return [] }

        // A TOTAL order — `sorted(by:)` is not documented stable, so ties are
        // broken explicitly or the returned id order would vary run to run.
        // Onset first, then the input array position, so notes sharing an onset
        // come back in the order the caller wrote them.
        let ordered = notes.indices.sorted {
            if notes[$0].startBeat != notes[$1].startBeat {
                return notes[$0].startBeat < notes[$1].startBeat
            }
            return $0 < $1
        }

        var groups: [(onset: Double, maxEnd: Double, ids: [UUID])] = []
        for index in ordered {
            let note = notes[index]
            if var last = groups.last, last.onset == note.startBeat {
                last.ids.append(note.id)
                last.maxEnd = max(last.maxEnd, note.endBeat)
                groups[groups.count - 1] = last
            } else {
                groups.append((onset: note.startBeat, maxEnd: note.endBeat, ids: [note.id]))
            }
        }

        var out: [Phrase] = []
        var currentIDs: [UUID] = []
        var currentStart = groups[0].onset
        var currentEnd = groups[0].maxEnd

        for (i, group) in groups.enumerated() {
            if currentIDs.isEmpty {
                currentStart = group.onset
                currentEnd = group.maxEnd
            } else {
                currentEnd = max(currentEnd, group.maxEnd)
            }
            currentIDs += group.ids

            let isLast = i == groups.count - 1
            let breaksHere: Bool
            if isLast {
                breaksHere = true
            } else {
                let gap = groups[i + 1].onset - currentEnd
                breaksHere = classify(gapBeats: gap, maxGapBeats: maxGapBeats) == .breath
            }
            if breaksHere {
                out.append(Phrase(noteIDs: currentIDs, startBeat: currentStart, endBeat: currentEnd))
                currentIDs = []
            }
        }
        return out
    }
}
