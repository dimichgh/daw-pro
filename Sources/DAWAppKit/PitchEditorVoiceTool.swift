import CoreGraphics
import DAWCore
import Foundation

// W7-NTU U3 — THE VOICE TOOL, HEADLESS (natural tuning,
// `docs/design/2026-09-25-natural-tuning.md` §1(f) items 2-3, amended by R9,
// R11, R22 and R26).
//
// A press on a note in the Voice tool routes `.formantDrag(id)`
// (`PitchEditorGestureRouter`). A vertical drag sets that note's Voice
// (`NoteSegment.formantOffsetSemitones`): up is brighter, down is deeper, and
// the note's pitch does not move. The release writes it ONCE
// (`ProjectStore.setClipNoteFormant`, one "Set Note Voice" undo step, through
// `PitchEditorVoiceWrite`). A double-click puts it back as sung (the knob law).
//
// This file holds the numbers and the arithmetic, so a test can pin every one
// of them without a pane. `PitchEditorModel` wires them ("U3 — the Voice tool"),
// and every word the tool shows is `PitchEditorFormantCopy`'s.

/// The Voice tool's numbers and pure functions. Every constant is a PICK
/// unless it cites a measurement, and each sits on one line, so a listening
/// pick changes one number.
public enum PitchEditorVoiceTool {

    /// R9: how far a drag goes, in semitones. The wire keeps
    /// `NoteSegment.formantOffsetSemitonesRange` (±24). R9 keeps the UI at ±6:
    /// below about −6 the render's upper band stops following the ratio.
    public static let uiRange: ClosedRange<Double> = -6...6

    /// §1(f) item 2 asks for "0.1 st resolution": this many steps per
    /// semitone. A drawn value is always a whole number of steps DIVIDED by
    /// this (the canonical-decimal rule: 21 / 10 is the same double as the
    /// literal 2.1, and 21 × 0.1 is not).
    public static let stepsPerSemitone: Double = 10

    /// Points of vertical travel per semitone (a pick): the UI's whole ±6 is
    /// 72 pt either side of the press, and one step is 1.2 pt.
    public static let pointsPerSemitone: Double = 12

    /// ⌥ held means fine control: each tick's travel is divided by this (the
    /// knob law). It is the Wobble tool's own divisor, so ⌥ feels the same in
    /// both tools.
    public static let fineDivisor: Double = PitchWobbleGesture.fineDivisor

    /// §1(f) item 3: the note menu's "Voice: Deeper 2.0" and "Voice: Brighter
    /// 2.0" set every note they name to this far from as sung. The value is
    /// ABSOLUTE, not a step: the store takes ONE final value for every note in
    /// the batch (`setClipNoteFormant`), and the title prints it.
    public static let menuSemitones: Double = 2

    /// R11: a note shorter than `PitchEditSet.minimumVoiceNoteSeconds`
    /// (MEASURED by NT-E1) cannot hold a Voice of its own in the render,
    /// because the render sets one value per 1440-frame hop and shapes 120 ms
    /// blocks. The tool SAYS so (`PitchEditorFormantCopy.voiceTooShort`). It
    /// does not refuse: the store takes the value, and the note still moves
    /// part of the way.
    public static func isTooShort(_ segment: NoteSegment) -> Bool {
        segment.durationSeconds < PitchEditSet.minimumVoiceNoteSeconds
    }

    /// Where a drag may go from `baseline`: the UI range, widened to take in a
    /// baseline an agent set beyond it. Pressing such a note never pulls it
    /// back into range on its own.
    public static func reach(from baseline: Double) -> ClosedRange<Double> {
        min(uiRange.lowerBound, baseline)...max(uiRange.upperBound, baseline)
    }

    /// `steps` tenths of a semitone away from `baseline`, ON THE GRID and inside
    /// `reach(from:)`. Zero steps returns the baseline ITSELF, so a value off
    /// the grid (from the wire) stays exactly as stored until the drag moves.
    public static func value(baseline: Double, steps: Int) -> Double {
        guard steps != 0 else { return baseline }
        let tenths = (baseline * stepsPerSemitone).rounded() + Double(steps)
        return (tenths / stepsPerSemitone).clamped(to: reach(from: baseline))
    }

    /// Whole steps for `points` of travel UP (down is negative), to the nearest.
    public static func steps(forPointsUp points: Double) -> Int {
        Int((points * stepsPerSemitone / pointsPerSemitone).rounded())
    }

    /// The travel, in points, at which `value(baseline:steps:)` reaches each end
    /// of `reach(from:)`. A drag's banked travel is held inside it, so pulling
    /// past an end and back moves the value at once, never after a stretch of
    /// dead travel: a knob stops at its end.
    public static func travelBounds(from baseline: Double) -> ClosedRange<Double> {
        let range = reach(from: baseline)
        let start = (baseline * stepsPerSemitone).rounded()
        let low = (range.lowerBound * stepsPerSemitone).rounded(.up) - start
        let high = (range.upperBound * stepsPerSemitone).rounded(.down) - start
        // Whole steps times the points per semitone, THEN divided: exact for
        // every whole step (60 × 12 / 10 is 72; 60 × 1.2 is not quite).
        let lower = min(0, low) * pointsPerSemitone / stepsPerSemitone
        let upper = max(0, high) * pointsPerSemitone / stepsPerSemitone
        return lower...upper
    }

    /// Where a Voice bar sits in its note's blob: −1 at the bottom edge, +1 at
    /// the top edge, the value over the UI range and clamped. An agent's −10
    /// sits at the bottom edge, and the chip prints the number.
    public static func offsetFraction(_ semitones: Double) -> Double {
        guard semitones.isFinite else { return 0 }
        return (semitones / uiRange.upperBound).clamped(to: -1...1)
    }
}

/// W7-NTU U3 — ONE Voice-tool press in flight, from its first tick to its
/// release.
///
/// ⭐ **IT LIVES IN THE MODEL, LIKE `PitchEditorDragDraft`,** for that type's
/// reason: nothing is written to the store until the release, so this is the
/// only place the live value exists. The surface's bar and chip, the
/// palette's readout and the echo all read it, with no store write per tick.
public struct PitchEditorVoiceDraft: Sendable, Equatable {
    /// The pressed note, by `NoteSegment.id`.
    public let segmentID: UUID
    /// The note's STORED Voice at the press: where the drag starts from.
    public let baseline: Double
    /// R11: the note is shorter than `PitchEditSet.minimumVoiceNoteSeconds`.
    public let isTooShort: Bool
    /// The live value, in semitones: what the release writes.
    public private(set) var semitones: Double
    /// The press has travelled past the router's slop, so it is a drag.
    public private(set) var isDragging = false
    /// ⌥ was held on the last tick.
    public private(set) var fine = false
    /// Travel banked so far, in points UP. Each tick adds its own part,
    /// divided by `fineDivisor` while ⌥ was held on it, and the total is held
    /// inside `PitchEditorVoiceTool.travelBounds`.
    public private(set) var bankedPoints: Double = 0
    /// The gesture's whole vertical travel on the last tick (y grows down).
    private var lastTranslationHeight: Double = 0

    public init(segmentID: UUID, baseline: Double, isTooShort: Bool) {
        self.segmentID = segmentID
        self.baseline = baseline
        self.isTooShort = isTooShort
        self.semitones = baseline
    }

    /// One pointer tick. `translationHeight` is the gesture's WHOLE vertical
    /// travel from the press (SwiftUI's, so y grows down). Only this tick's
    /// part of it is banked, at this tick's ⌥, so pressing or letting go of ⌥
    /// mid-drag never makes the value jump. Returns whether the value changed.
    @discardableResult
    public mutating func update(translationHeight: Double, fine: Bool) -> Bool {
        let up = lastTranslationHeight - translationHeight
        lastTranslationHeight = translationHeight
        let part = fine ? up / PitchEditorVoiceTool.fineDivisor : up
        bankedPoints = (bankedPoints + part).clamped(to: PitchEditorVoiceTool.travelBounds(from: baseline))
        self.fine = fine
        isDragging = true
        let next = PitchEditorVoiceTool.value(
            baseline: baseline, steps: PitchEditorVoiceTool.steps(forPointsUp: bankedPoints))
        guard next != semitones else { return false }
        semitones = next
        return true
    }

    /// What the release writes: the live value, or `nil` for a press that
    /// never became a drag, or a drag that ends on the stored value. That write
    /// would change nothing and add an undo step that undoes nothing.
    public var commitValue: Double? {
        isDragging && semitones != baseline ? semitones : nil
    }
}

/// W7-NTU U3 — ONE note's Voice as the surface draws it while the Voice tool
/// is engaged (§1(f) item 2, R22): a thin bar inside the blob, off its centre
/// by the value (up is brighter), and an SF Mono chip under the note, both in
/// `signal` ink. `PitchEditorModel.voiceMarks` resolves it. The view draws it
/// and the echo reports it; neither re-derives it.
public struct PitchEditorVoiceMark: Sendable, Equatable {
    /// The note, by `NoteSegment.id`.
    public let segmentID: UUID
    /// The note's Voice, in semitones: the live draft's for the note being
    /// dragged, the stored one for every other note. Never 0: a note as sung
    /// has no mark.
    public let semitones: Double
    /// `PitchEditorVoiceTool.offsetFraction(semitones)`: where the bar sits.
    public let offsetFraction: Double
    /// The chip's words, verbatim (`PitchEditorFormantCopy.voiceChip`).
    public let chip: String
    /// The note's drawn rect, in content space: the bar sits inside it and the
    /// chip below it.
    public let blobRect: CGRect
    /// The note is the one being dragged.
    public let isLive: Bool

    public init(segmentID: UUID, semitones: Double, blobRect: CGRect, isLive: Bool) {
        self.segmentID = segmentID
        self.semitones = semitones
        self.offsetFraction = PitchEditorVoiceTool.offsetFraction(semitones)
        self.chip = PitchEditorFormantCopy.voiceChip(semitones)
        self.blobRect = blobRect
        self.isLive = isLive
    }
}
