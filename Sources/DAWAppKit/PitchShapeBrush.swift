import Foundation
import DAWCore

// m23-ap C5b-4a — THE PITCH BRUSH'S MATH, HEADLESS.
//
// Design: `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §5.5 (the
// brush: kernel, accumulation, the release formula, the readout, `.estimate`),
// §5.6 (the drawn help) and §5.8 mode 3; the store it commits to is C5b-3a's
// `ProjectStore.setClipNoteShapes` (`NoteShapeSamples.swift`).
//
// Everything the ⌘-drag brush computes between a press and a release, as plain
// values: no SwiftUI, no store, no actor. The view (C5b-4b) feeds it pointer
// positions in SOURCE seconds and fractional MIDI, draws the draft it returns,
// and hands `commit()` to the store ONCE, on release.
//
// ═══════════════════════════════════════════════════════════════════════════
// THE FOUR RULES, EACH WITH THE DEFECT IT PREVENTS
// ═══════════════════════════════════════════════════════════════════════════
//
//  1. **MAX WEIGHT, NEVER A SUM.** Every grid sample keeps the LARGEST weight
//     the stroke ever gave it, and the target from that moment (on a tie the
//     latest wins). Going back over a place re-aims it; it never applies
//     twice. A sum would push a sample drawn over three times three times as
//     far as the pointer went.
//  2. **THE SWEPT PATH, NOT A TRAIL OF DABS.** Between two pointer ticks the
//     brush centre sweeps the whole interval, so every grid sample's weight is
//     read at its distance from that INTERVAL, with the target at the moment
//     the centre was nearest. Dabbing the kernel every 10 ms instead leaves
//     gaps whenever the radius is under half a grid step (zoomed right in),
//     and a fast drag would comb the line.
//  3. **THE PRE-STROKE LINE, HELD BY THE STROKE.** The release writes
//     `shape_i += w_i · (target_i − played_i)` with `played_i` the line as it
//     played BEFORE the stroke (§5.5). The stroke captures that line at
//     mouse-down and never takes another, so a caller cannot hand it the live
//     draft line — against which every delta would shrink towards zero.
//  4. **ONLY WHERE THERE IS A LINE, ONLY IN SUNG NOTES.** A sample is written
//     only inside a sung note's grid span AND where the pre-stroke line has a
//     pitch (`PitchPlayedLine.playedMidi`, nil across holes). Gaps between
//     notes, holes inside a note, cleared notes and SOUNDS (C5b-3a's sound
//     ruling: the store refuses a drawing on a breath or a consonant) are all
//     crossed and never written.
//
// ⚠️ **A STROKE STARTS ON A NOTE** (the survey's correction to §5.5's "anywhere"):
// ⌘-click on empty space places the playhead (I5) and ⌘-drag on empty space is
// the additive band (I4), so `begin` is only ever called for a press on a note
// (`PitchEditorGestureRouter`, C5b-4b). The stroke may then cross gaps.

// MARK: - The brush's constants and words

/// The brush's fixed numbers and its sentences, ONE home (the UI lane draws
/// them verbatim; the design's words, §5.5-§5.6).
public enum PitchShapeBrush {

    /// The kernel's radius ON SCREEN, points (§5.5). Converted to seconds
    /// once, at mouse-down, so the brush feels the same at every zoom.
    public static let radiusPoints: Double = 12

    /// The raised-cosine kernel, `w(Δ) = 0.5 · (1 + cos(π · Δ / R))` for
    /// `|Δ| < R`, else 0 (§5.5): 1 at the centre, falling to 0 with ZERO SLOPE
    /// at the edge, so the brush has no corner where it ends. Symmetric.
    public static func weight(distanceSeconds: Double, radiusSeconds: Double) -> Double {
        guard radiusSeconds > 0, distanceSeconds.isFinite else { return 0 }
        let distance = abs(distanceSeconds)
        guard distance < radiusSeconds else { return 0 }
        return 0.5 * (1 + cos(.pi * distance / radiusSeconds))
    }

    /// `radiusPoints` in SOURCE seconds at a zoom of `pointsPerSourceSecond`
    /// (the editor's horizontal scale at the press, e.g. `x(forSourceSecond:
    /// s + 1) − x(forSourceSecond: s)`). A zoom that is not a positive number
    /// reads as one grid step, a defensive default no real editor reaches.
    public static func radiusSeconds(pointsPerSourceSecond: Double) -> Double {
        guard pointsPerSourceSecond.isFinite, pointsPerSourceSecond > 0 else {
            return 1 / NoteSegment.shapeGridHz
        }
        return radiusPoints / pointsPerSourceSecond
    }

    /// Shown instead of drawing while the line is an ESTIMATE (§5.5, verbatim):
    /// a delta computed against an estimate would land off by the estimate's
    /// own error (§5.8 mode 3).
    public static let estimateCaption =
        "Drawing needs the app's analysis of this recording. One moment."

    /// Shown when the press lands on a SOUND (C5b-3a's sound ruling, in the
    /// words the orchestrator proposed for it).
    public static let soundCaption =
        "This is a breath or a consonant, not a sung note — it has no pitch line to draw."

    /// Shown when the press is not on a note of this clip (a stroke starts on
    /// a note; the router sends empty space elsewhere, so this is a guard).
    public static let startOnANoteCaption = "Start on a note to draw its line."

    /// The Shape tool's drawn help (§5.6, verbatim).
    public static let help =
        "Drag along a note's line to redraw it. Press and drag up or down to pull a peak. "
        + "Let go to hear it."

    /// The readout while drawing (§5.5): an EXCURSION, rounded to the nearest
    /// 5 cents (the readout floor's resolution; UI design §7.4).
    public static func readout(maxExcursionCents: Double) -> String {
        let cents = maxExcursionCents.isFinite ? abs(maxExcursionCents) : 0
        let rounded = Int((cents / 5).rounded() * 5)
        return "Drawing · moves the line by up to \(rounded) cents"
    }

    /// Why the brush may not draw on this line, or `nil` when it may: the one
    /// `.estimate` rule (§5.5). `begin` applies it; a view that dims the
    /// Shape slot or the ⌘ band asks it too.
    public static func refusal(basis: PitchPlayedLine.Basis) -> String? {
        if case .estimate = basis { return estimateCaption }
        return nil
    }
}

// MARK: - One stroke

/// What a press starts.
public enum PitchShapeBrushStart: Sendable, Equatable {
    /// A stroke is drawing.
    case drawing(PitchShapeStroke)
    /// No stroke; say this sentence (drawn, never only a tooltip) and draw
    /// nothing.
    case refused(String)

    public var stroke: PitchShapeStroke? {
        if case .drawing(let stroke) = self { return stroke }
        return nil
    }

    public var refusal: String? {
        if case .refused(let sentence) = self { return sentence }
        return nil
    }
}

/// One brush stroke from press to release: the accumulated weights and
/// targets, the notes it may write into, and the pre-stroke line it measures
/// against. A value: the view holds it, `move` updates it, `commit()` reads it.
public struct PitchShapeStroke: Sendable, Equatable {

    /// One grid sample's accumulation: the largest weight the stroke gave it,
    /// and the pointer's pitch (fractional MIDI) at that moment.
    public struct Sample: Sendable, Equatable {
        public let weight: Double
        public let targetMidi: Double
    }

    /// The kernel's radius, SOURCE seconds, fixed at mouse-down.
    public let radiusSeconds: Double
    /// ⭐ The played line as it was BEFORE this stroke (rule 3 of the banner).
    public let prestrokePlayedLine: PitchPlayedLine
    /// The notes the stroke may write into: every SUNG note of the table at
    /// mouse-down, in table order. Sounds are left out (rule 4).
    public let notes: [NoteSegment]
    /// Grid index → what the stroke has given that sample so far.
    public private(set) var samples: [Int: Sample]
    /// The last pointer position, SOURCE seconds and fractional MIDI.
    public private(set) var lastSeconds: Double
    public private(set) var lastMidi: Double

    /// Start a stroke with a press on note `pressedNoteID` at SOURCE second
    /// `seconds`, pitch `midi` (fractional MIDI, where the pointer is):
    ///  * refused while the line is an ESTIMATE (`PitchShapeBrush.refusal`);
    ///  * refused on a SOUND (`soundCaption`) and on an id the table does not
    ///    hold (`startOnANoteCaption`);
    ///  * otherwise the press itself is the first stroke point, so a press
    ///    that pulls straight up or down is a moving target on one place.
    /// `table` is the note table as committed (the editor's `noteTable`), and
    /// `prestrokePlayedLine` the line as drawn right now (never a draft).
    public static func begin(pressedNoteID: UUID,
                             atSourceSecond seconds: Double,
                             midi: Double,
                             table: PitchEditSet,
                             prestrokePlayedLine: PitchPlayedLine,
                             pointsPerSourceSecond: Double) -> PitchShapeBrushStart {
        if let refusal = PitchShapeBrush.refusal(basis: prestrokePlayedLine.basis) {
            return .refused(refusal)
        }
        guard let pressed = table.segments.first(where: { $0.id == pressedNoteID }),
              seconds.isFinite, midi.isFinite else {
            return .refused(PitchShapeBrush.startOnANoteCaption)
        }
        guard pressed.origin != .unpitched else { return .refused(PitchShapeBrush.soundCaption) }
        var stroke = PitchShapeStroke(
            radiusSeconds: PitchShapeBrush.radiusSeconds(pointsPerSourceSecond: pointsPerSourceSecond),
            prestrokePlayedLine: prestrokePlayedLine,
            notes: table.segments.filter { $0.origin != .unpitched },
            samples: [:], lastSeconds: seconds, lastMidi: midi)
        stroke.sweep(from: (seconds, midi), to: (seconds, midi))
        return .drawing(stroke)
    }

    /// The pointer moved to SOURCE second `seconds`, pitch `midi`. The path
    /// from the last position is swept at grid resolution (rule 2); a
    /// non-finite position is ignored.
    public mutating func move(toSourceSecond seconds: Double, midi: Double) {
        guard seconds.isFinite, midi.isFinite else { return }
        sweep(from: (lastSeconds, lastMidi), to: (seconds, midi))
        lastSeconds = seconds
        lastMidi = midi
    }

    /// Accumulate one straight piece of the path (rules 1 and 2).
    private mutating func sweep(from start: (seconds: Double, midi: Double),
                                to end: (seconds: Double, midi: Double)) {
        let earliest = min(start.seconds, end.seconds)
        let latest = max(start.seconds, end.seconds)
        let lower = NoteShapeSamples.gridIndex(atOrAfter: earliest - radiusSeconds)
        let upper = NoteShapeSamples.gridIndex(atOrBefore: latest + radiusSeconds)
        guard lower <= upper else { return }
        let duration = end.seconds - start.seconds
        for index in lower...upper {
            let t = NoteShapeSamples.seconds(atGridIndex: index)
            // The moment the centre was nearest this sample, and how near.
            let nearest = t.clamped(to: earliest...latest)
            let weight = PitchShapeBrush.weight(distanceSeconds: t - nearest, radiusSeconds: radiusSeconds)
            guard weight > 0 else { continue }
            // A move straight up or down has no duration: every moment is as
            // near, so the LATEST pitch is the target (a tie, rule 1).
            let target = duration == 0
                ? end.midi
                : start.midi + (end.midi - start.midi) * ((nearest - start.seconds) / duration)
            if let held = samples[index], held.weight > weight { continue }
            samples[index] = Sample(weight: weight, targetMidi: target)
        }
    }

    /// ⭐ THE RELEASE (§5.5): every sung note the stroke wrote into, as its
    /// WHOLE new drawing — what `ProjectStore.setClipNoteShapes` takes, in one
    /// call, as one undo step. For each written sample `i` of a note:
    ///
    ///     shape_i ← shape_i + w_i · (target_i − played_i)
    ///
    /// with `shape_i` what the note's drawing PLAYS there now
    /// (`NoteShapeSamples.playing(on:)`), `played_i` the PRE-stroke line
    /// (rule 3), in tenths of a cent, then quantised, clamped and normalised
    /// exactly as the store stores it (`NoteShapeSamples.normalised(for:)`).
    /// A note whose result the store would not change is left out, so an
    /// EMPTY map means "nothing to commit".
    ///
    /// It is also THE DRAFT: during the stroke, the notes' shapes after this
    /// commit, applied to copies (`NoteShapeSamples.applied(to:)`), are what
    /// the live line draws, so what a stroke shows is what its release stores.
    public func commit() -> [UUID: NoteShapeSamples] {
        var out: [UUID: NoteShapeSamples] = [:]
        for (note, written) in writes() where written.applied(to: note) != note {
            out[note.id] = written
        }
        return out
    }

    /// The largest change the release makes to any sample, cents (after the
    /// quantise and the clamp): the readout's number.
    public var maxExcursionCents: Double {
        var largest = 0.0
        for (note, written) in writes() where written.applied(to: note) != note {
            let before = NoteShapeSamples.playing(on: note)
            let after = written.isClear
                ? [Int16](repeating: 0, count: before.tenthsOfCents.count) : written.tenthsOfCents
            for (old, new) in zip(before.tenthsOfCents, after) {
                largest = max(largest, abs(Double(new) - Double(old)) / 10)
            }
        }
        return largest
    }

    /// The readout while drawing (`PitchShapeBrush.readout`).
    public var readout: String { PitchShapeBrush.readout(maxExcursionCents: maxExcursionCents) }

    /// Every note with at least one sample written, and its normalised result.
    /// Asked on every tick (the readout, the draft), so notes wholly outside
    /// the samples the stroke has touched are skipped before any lookup.
    private func writes() -> [(NoteSegment, NoteShapeSamples)] {
        guard let touchedLow = samples.keys.min(), let touchedHigh = samples.keys.max() else { return [] }
        var out: [(NoteSegment, NoteShapeSamples)] = []
        let range = NoteSegment.shapeTenthsRange
        let low = Double(range.lowerBound), high = Double(range.upperBound)
        for note in notes {
            let span = NoteShapeSamples.gridSpan(of: note)
            guard !span.isEmpty, span.upperBound > touchedLow, span.lowerBound <= touchedHigh else { continue }
            var values = NoteShapeSamples.playing(on: note).tenthsOfCents.map(Double.init)
            var wrote = false
            for index in span {
                guard let sample = samples[index],
                      let played = prestrokePlayedLine.playedMidi(
                          atSourceSecond: NoteShapeSamples.seconds(atGridIndex: index)) else { continue }
                // Semitones × 1000 = tenths of a cent.
                values[index - span.lowerBound] += sample.weight * (sample.targetMidi - played) * 1000
                wrote = true
            }
            guard wrote else { continue }
            let quantised = values.map { Int16($0.rounded().clamped(to: low...high)) }
            out.append((note, NoteShapeSamples(startIndex: span.lowerBound, tenthsOfCents: quantised)
                .normalised(for: note)))
        }
        return out
    }
}
