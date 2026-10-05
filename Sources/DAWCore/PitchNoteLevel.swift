import Foundation

// I7a merged with U-C: THE ONE LEVEL MASK HOME.
//
// Design: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §10 (I7,
// "clear a note") and §17 (the reconciliation, whose rulings win), with
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §1.8 as
// amended there.
//
// Two stored fields reach the audio through this file and nowhere else:
//  * `NoteSegment.isCleared` is SILENCE. A cleared note renders as exact zeros
//    between its ramps.
//  * `NoteSegment.amplitudeDb` is LEVEL, 10^(dB/20). −72 dB is 2.5e-4, a very
//    quiet level and never silence (the same meaning it has on a clip).
//
// The render (`StretchRenderCache.performRender`, DAWEngine, offline only, never
// the render thread) multiplies each delivered output frame by
// `gain(atSourceSecond:)` of the source second that frame plays, found through
// the one output-to-source mapping (`StretchCurvePlan.sourceSecond`). There is
// no second stage, and no second ramp constant.
//
// ═══════════════════════════════════════════════════════════════════════════
// THE SHAPE
// ═══════════════════════════════════════════════════════════════════════════
//
//  * Outside every note, and inside every note with no level edit, the mask is
//    the literal 1.0. The render never touches those samples, so they stay
//    byte-identical (design §17.5).
//  * Inside a level-edited note the mask holds the note's PLATEAU: 0 when it
//    is cleared, else 10^(amplitudeDb/20).
//  * ONE raised-cosine ramp of `levelRampSeconds`, clamped to half the note,
//    joins the plateau to each edge. The ramp sits INSIDE the note, so a
//    neighbour is never touched.
//
// ⛔ ABUTTING NOTES — WHERE THE SOURCE CONTRADICTS THE LITERAL DESIGN RULE.
// The design says "the ramp goes from 1 at each edge to the plateau". That
// silently assumes a gap between notes. `PitchNoteSplitter` does not leave
// one: every interior boundary of a sung phrase is SHARED BIT FOR BIT
// (`PitchNoteSplitter.swift`'s banner), and a split's halves meet exactly at
// the cut (`ProjectStore.splitClipNoteSegment`). Under the literal rule,
// clearing two abutting notes (the ordinary "Clear 3 Notes" over one phrase)
// ramps both back up to 1 at their shared edge and plays a 20 ms burst of the
// cleared sound at full level. So the edge value is defined as follows:
//  * An edge that meets a gap, or an abutting note with NO level edit, ramps
//    to 1. That is the literal rule, and the untouched neighbour stays
//    byte-exact.
//  * An edge shared bit for bit with another LEVEL-EDITED note ramps to the
//    MIDPOINT of the two plateaus, from both sides. It is continuous, it
//    touches no untouched neighbour, and two cleared notes meet at exactly 0,
//    so they are silent across the boundary. The pitch curve makes the same
//    choice at an abutting boundary ("the shared boundary is the MIDPOINT").
//    `PitchNoteLevelTests` pins the junction, and the per-note literal rule,
//    planted, fails it.

extension PitchEditSet {

    /// THE ramp length, seconds: one raised-cosine ramp, placed inside the
    /// note and clamped to half of it. A PICK, not a measurement. Design §17.1
    /// chose 10 ms over 8 ms ("one PICK, not two"). It is long enough that a
    /// cleared note does not click at its edges, and short enough that the
    /// sound it silences does not linger.
    public static let levelRampSeconds: Double = 0.010

    /// The version of the mask's ARITHMETIC, hashed into the render digest's
    /// level block (`PitchEditSetDigest`, slot 5). Bump it whenever
    /// `gain(atSourceSecond:)` would return a different number for the same
    /// set: a new ramp length, a new ramp shape, or a new junction rule.
    /// Otherwise every level-edited render already on disk would be served
    /// under a key whose audio no longer matches. It is the time-warp block's
    /// `PitchTimeWarp.scheduleVersion` precedent.
    public static let levelMaskVersion: Int = 1

    /// The level multiplier at a SOURCE-FILE second: 1 outside notes and in
    /// notes with no level edit. Inside a level-edited note it is the
    /// plateau (0 when cleared, else 10^(amplitudeDb/20)), reached through one
    /// `levelRampSeconds` raised-cosine ramp inside the note. See this file's
    /// banner for the abutting-note rule.
    ///
    /// Pure and total. A non-finite second returns 1 (no change), and every
    /// value it can return is finite (`amplitudeDb` is sanitised and clamped to
    /// `Clip.gainDbRange` by `NoteSegment.init`).
    ///
    /// Spans are half-open, `[startSeconds, endSeconds)`, matching the
    /// canonical set's non-overlap: a second on a shared boundary belongs to
    /// the later note, and both sides agree on the value there.
    public func gain(atSourceSecond sourceSecond: Double) -> Double {
        guard sourceSecond.isFinite, let index = levelNoteIndex(containing: sourceSecond) else {
            return 1
        }
        let note = segments[index]
        guard note.hasLevelEdits else { return 1 }
        let plateau = Self.plateauGain(of: note)
        let ramp = min(Self.levelRampSeconds, note.durationSeconds / 2)
        guard ramp > 0 else { return plateau }
        let intoNote = sourceSecond - note.startSeconds
        if intoNote < ramp {
            return Self.raisedCosine(from: edgeGain(beforeNoteAt: index), to: plateau,
                                     progress: intoNote / ramp)
        }
        let beforeEnd = note.endSeconds - sourceSecond
        if beforeEnd < ramp {
            return Self.raisedCosine(from: edgeGain(afterNoteAt: index), to: plateau,
                                     progress: beforeEnd / ramp)
        }
        return plateau
    }

    /// A level-edited note's plateau: exactly 0 when cleared (the literal, so
    /// the samples between the ramps are exact zeros), else 10^(dB/20).
    static func plateauGain(of note: NoteSegment) -> Double {
        note.isCleared ? 0 : pow(10, note.amplitudeDb / 20)
    }

    /// `edge + (plateau − edge) × (½ − ½·cos(π·progress))`. At progress 0 the
    /// weight is exactly 0 (`cos(0) == 1`), so the mask equals the edge value
    /// bit for bit. At an edge that meets a gap that value is 1.0, so the
    /// sample on the edge is unchanged.
    static func raisedCosine(from edge: Double, to plateau: Double, progress: Double) -> Double {
        let weight = 0.5 - 0.5 * cos(Double.pi * progress)
        return edge + (plateau - edge) * weight
    }

    /// The index of the note whose half-open span holds `sourceSecond`, or nil
    /// in a gap. Binary search: `segments` is canonical (ascending,
    /// non-overlapping), which `PitchEditSet.init` guarantees for every
    /// construction path.
    private func levelNoteIndex(containing sourceSecond: Double) -> Int? {
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].startSeconds <= sourceSecond { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard index >= 0, sourceSecond < segments[index].endSeconds else { return nil }
        return index
    }

    /// The mask's value AT a note's start edge: the midpoint of the two
    /// plateaus when the previous note is level-edited and shares this edge
    /// bit for bit, else 1 (see the banner).
    private func edgeGain(beforeNoteAt index: Int) -> Double {
        guard index > 0 else { return 1 }
        let previous = segments[index - 1]
        let note = segments[index]
        guard previous.hasLevelEdits, previous.endSeconds == note.startSeconds else { return 1 }
        return (Self.plateauGain(of: previous) + Self.plateauGain(of: note)) / 2
    }

    /// The mask's value AT a note's end edge; `edgeGain(beforeNoteAt:)`'s
    /// mirror. The two agree on every shared edge, which keeps the mask
    /// continuous there.
    private func edgeGain(afterNoteAt index: Int) -> Double {
        guard index + 1 < segments.count else { return 1 }
        let next = segments[index + 1]
        let note = segments[index]
        guard next.hasLevelEdits, next.startSeconds == note.endSeconds else { return 1 }
        return (Self.plateauGain(of: note) + Self.plateauGain(of: next)) / 2
    }
}
