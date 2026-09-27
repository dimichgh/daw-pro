import Foundation

// m23-ap C5b-3a — THE DRAWN SHAPE'S WRITE RULE, ONE HOME.
//
// Design: `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §5.2
// (quantise, clamp, normalise), §5.3 (the split), §5.7 (the store), §5.8
// (failure modes). The fields and the curve term are C5b-1's
// (`NoteSegment.shapeStartIndex` / `shapeTenthsOfCents`, `healedShape`,
// `PitchCorrectionCurve.drawnShape`); this file is everything that WRITES them.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⛔ THE HELD-ENDS TRAP, AND WHY EVERY WRITE COVERS THE NOTE'S WHOLE GRID SPAN
// ═══════════════════════════════════════════════════════════════════════════
//
// The curve term is HELD at both ends: before the first stored sample it plays
// the first value, after the last it plays the last (§5.3). So a write that
// stored only the few samples a stroke or an agent touched — three samples of
// +50 c in the middle of an undrawn note — would play +50 c across the WHOLE
// note. The fix is structural, not a caller's duty: every normalised write
// (`normalised(for:)`) is materialised over the note's full grid span, with 0
// wherever the request does not reach. `splicing` goes one step further and
// keeps what the note ALREADY plays there (held ends included), so a patch
// changes exactly the stretch it names.
//
// ⭐ ONE HOME, THREE CALLERS. `ProjectStore.setClipNoteShapes` (the store, and so
// the wire verb C5b-3b adds), `PitchEditSet.applyingNoteShapes` (the pure
// transform a live brush draft can also call, C5b-4b) and the split in
// `ProjectStore.splitClipNoteSegment` all write through the functions below,
// so a drawing cannot store one thing through one door and another through the
// next.
//
// ⭐ ONE GRID RULE. `gridIndex(atOrAfter:)` / `gridIndex(atOrBefore:)` are the
// only place a second becomes a grid index. `0.07 × 100` is
// `7.000000000000001` in floating point, so two hand-written `ceil`s can
// disagree about the one sample at a boundary; tests call these too.

/// One note's drawn shape as a WRITE names it: `tenthsOfCents[k]` sits at grid
/// index `startIndex + k`, source second `Double(startIndex + k) /
/// NoteSegment.shapeGridHz`. EMPTY means CLEAR (remove the drawing).
///
/// ⚠️ **A WRITE IS THE NOTE'S WHOLE NEW SHAPE, NOT A PATCH** — the rule every
/// setter in `ProjectStore+PitchNoteEdits.swift` follows ("a final value, not a
/// delta"), for its reason: a dropped write and a write of nothing must read
/// back differently. Grid samples of the note the array does not reach store
/// 0. To change PART of a note and keep the rest, build the write with
/// `splicing(points:onto:)`, which reads what the note plays now.
public struct NoteShapeSamples: Sendable, Equatable {
    /// Grid index of `tenthsOfCents[0]`. Meaningless (0) for a clear.
    public var startIndex: Int
    /// The drawn delta, tenths of a cent, one per 10 ms grid step. Empty = clear.
    public var tenthsOfCents: [Int16]

    public init(startIndex: Int, tenthsOfCents: [Int16]) {
        self.startIndex = startIndex
        self.tenthsOfCents = tenthsOfCents
    }

    /// "Remove this note's drawing." An EMPTY array, never a zeroed one: an
    /// all-zero array is still a shape to the model (`NoteSegment.hasShape`),
    /// and it would keep the note on the stretcher for nothing.
    public static let clear = NoteShapeSamples(startIndex: 0, tenthsOfCents: [])

    /// True when this write removes the drawing.
    public var isClear: Bool { tenthsOfCents.isEmpty }

    /// The drawing `note` stores now, verbatim (no materialising).
    public init(storedIn note: NoteSegment) {
        self.init(startIndex: note.shapeStartIndex, tenthsOfCents: note.shapeTenthsOfCents)
    }
}

// MARK: - The grid rule

extension NoteShapeSamples {

    /// The first grid index at or after `seconds`: `ceil(seconds · shapeGridHz)`
    /// (design §5.2's `ceil(start·100)`, §5.3's `ceil(cut·100)`). Total: a
    /// non-finite second reads as 0, and the result is kept inside
    /// `0...NoteSegment.shapeMaxIndex + 1` so no conversion can trap.
    ///
    /// ⚠️ **THE MATHEMATICAL CEILING, NOT THE FLOATING-POINT ONE.** A product
    /// within `gridSnapTolerance` of a whole step IS that step: `0.07 × 100`
    /// is `7.000000000000001` in floating point, and a bare `ceil` would skip
    /// the sample sitting exactly at 0.07 s (and `atOrBefore`'s `floor` would
    /// then disagree with it about a point placed exactly on the grid).
    public static func gridIndex(atOrAfter seconds: Double) -> Int {
        index(rounding: seconds, .up)
    }

    /// How close to a whole grid step (in steps) a position must be to count
    /// as ON it: far above the ~1e-9 error of `seconds × 100` at 24 h, far
    /// below anything a pointer or an agent can mean (10 ns).
    public static let gridSnapTolerance: Double = 1e-6

    /// The last grid index at or before `seconds`: `floor(seconds ·
    /// shapeGridHz)`, with `gridIndex(atOrAfter:)`'s bounds. The far end of a
    /// point list (`splicing`) is the one caller: its last point is INCLUDED.
    public static func gridIndex(atOrBefore seconds: Double) -> Int {
        index(rounding: seconds, .down)
    }

    /// The source second of grid index `index`.
    public static func seconds(atGridIndex index: Int) -> Double {
        Double(index) / NoteSegment.shapeGridHz
    }

    /// The grid indices INSIDE `note`, `[ceil(start·100), ceil(end·100))` —
    /// design §5.2's `[ceil(start·100), ceil(end·100) − 1]`, half-open. Empty
    /// for a note shorter than one grid step that holds no grid point.
    public static func gridSpan(of note: NoteSegment) -> Range<Int> {
        let lower = gridIndex(atOrAfter: note.startSeconds)
        let upper = gridIndex(atOrAfter: note.endSeconds)
        return lower..<max(lower, upper)
    }

    private static func index(rounding seconds: Double, _ rule: FloatingPointRoundingRule) -> Int {
        let exact = seconds * NoteSegment.shapeGridHz
        guard exact.isFinite else { return 0 }
        let nearest = exact.rounded()
        let position = abs(exact - nearest) <= gridSnapTolerance ? nearest : exact.rounded(rule)
        return Int(position.clamped(to: 0...Double(NoteSegment.shapeMaxIndex + 1)))
    }
}

// MARK: - What a note plays, and what a write stores

extension NoteShapeSamples {

    /// What `note`'s drawing PLAYS at every grid index of its own span, in
    /// tenths: the stored sample where there is one, the HELD end value
    /// before the first and after the last (the curve's own rule,
    /// `PitchCorrectionCurve.drawnShape`), and 0 everywhere for a note with no
    /// drawing. Not normalised: an undrawn note reads as zeros here, which is
    /// exactly what a patch must keep. Clear when the span is empty.
    public static func playing(on note: NoteSegment) -> NoteShapeSamples {
        let span = gridSpan(of: note)
        guard !span.isEmpty else { return .clear }
        let stored = note.shapeTenthsOfCents
        guard let first = stored.first, let last = stored.last else {
            return NoteShapeSamples(startIndex: span.lowerBound,
                                    tenthsOfCents: [Int16](repeating: 0, count: span.count))
        }
        let start = note.shapeStartIndex
        let values = span.map { index -> Int16 in
            let k = index - start
            if k < 0 { return first }
            if k >= stored.count { return last }
            return stored[k]
        }
        return NoteShapeSamples(startIndex: span.lowerBound, tenthsOfCents: values)
    }

    /// This write as the store STORES it on `note` (design §5.2, "normalising,
    /// in the setter"):
    ///  * a clear stays a clear;
    ///  * TRIMMED to the note's grid span (`gridSpan(of:)`): samples outside
    ///    the note are dropped, never moved;
    ///  * ZERO-FILLED across the rest of the span, so the held ends can never
    ///    stretch a partial write across the note (this file's banner);
    ///  * every sample CLAMPED to `NoteSegment.shapeTenthsRange` (±1200 c);
    ///  * an all-zero result (or an empty span) is stored as CLEAR, index 0.
    /// Deterministic, so writing the same thing twice stores the same bytes
    /// and the second write journals nothing.
    public func normalised(for note: NoteSegment) -> NoteShapeSamples {
        guard !isClear else { return .clear }
        let span = Self.gridSpan(of: note)
        guard let reach = overlap(with: span) else { return .clear }
        var values = [Int16](repeating: 0, count: span.count)
        let range = NoteSegment.shapeTenthsRange
        for index in reach {
            values[index - span.lowerBound] = tenthsOfCents[index - startIndex].clamped(to: range)
        }
        guard values.contains(where: { $0 != 0 }) else { return .clear }
        return NoteShapeSamples(startIndex: span.lowerBound, tenthsOfCents: values)
    }

    /// `note` with this write stored on it, exactly as the store stores it
    /// (`normalised(for:)`). THE per-note half of
    /// `PitchEditSet.applyingNoteShapes`; a live draft's per-note case calls
    /// this and nothing else. It does not refuse anything: the refusals are
    /// the set transform's (a sound, a write that misses the note).
    public func applied(to note: NoteSegment) -> NoteSegment {
        let stored = normalised(for: note)
        var copy = note
        // A direct assignment skips `NoteSegment.init`'s healing, so it relies
        // on `normalised`: clamped samples, and index 0 for a clear.
        copy.shapeStartIndex = stored.startIndex
        copy.shapeTenthsOfCents = stored.tenthsOfCents
        return copy
    }

    /// True when this (non-clear) write puts at least one sample inside
    /// `note`'s grid span. A write that does not would normalise to a clear and
    /// silently ERASE the note's drawing, so the set transform refuses it.
    public func reaches(_ note: NoteSegment) -> Bool {
        overlap(with: Self.gridSpan(of: note)) != nil
    }

    /// The grid indices both this write and `span` cover, or nil for none.
    /// Written so no sum can overflow, `Int.min`/`Int.max` starts included.
    private func overlap(with span: Range<Int>) -> Range<Int>? {
        guard !isClear, !span.isEmpty, startIndex < span.upperBound else { return nil }
        let lower = Swift.max(span.lowerBound, startIndex)
        // `startIndex < span.upperBound <= shapeMaxIndex + 1`, so this sum is
        // bounded by that plus an array's count.
        let upper = Swift.min(span.upperBound, startIndex + tenthsOfCents.count)
        return lower < upper ? lower..<upper : nil
    }
}

// MARK: - The split (design §5.3)

extension NoteShapeSamples {

    /// ⭐ THE SPLIT RULE: the drawing of `note` cut at source second `cut`, BY
    /// INDEX. With `k = gridIndex(atOrAfter: cut)` (`ceil(cut·100)`), the LEFT
    /// half keeps the stored samples with index below `k` and the RIGHT half
    /// keeps the rest, each re-based to its own first index. Nothing is
    /// resampled: every kept sample stays at its own source second (the global
    /// grid, §5.2).
    ///
    /// Each half then gets the one normalisation that applies to a slice: an
    /// empty or all-zero half is stored as CLEAR (index 0), as the setter
    /// stores an all-zero write (§5.2), so a half with nothing drawn on it is
    /// not kept on the stretcher for a term of zero. It is NOT trimmed to the
    /// half's span or zero-filled: a split changes no sample's value.
    ///
    /// What a listener gets (§5.8 mode 5): inside each half the term is the
    /// parent's, sample for sample, except in the ONE grid step that straddles
    /// the cut. There each half HOLDS its end value instead of interpolating
    /// across the cut, so the two sides differ by at most the step between the
    /// two samples beside the cut.
    public static func halves(of note: NoteSegment,
                              atSourceSecond cut: Double) -> (left: NoteShapeSamples,
                                                              right: NoteShapeSamples) {
        let stored = note.shapeTenthsOfCents
        guard !stored.isEmpty else { return (.clear, .clear) }
        let start = note.shapeStartIndex
        let k = gridIndex(atOrAfter: cut)
        // `k` and `start` both sit inside `0...shapeMaxIndex + 1`: no overflow.
        let leftCount = Swift.min(Swift.max(0, k - start), stored.count)
        func half(_ from: Int, _ slice: ArraySlice<Int16>) -> NoteShapeSamples {
            guard slice.contains(where: { $0 != 0 }) else { return .clear }
            return NoteShapeSamples(startIndex: from, tenthsOfCents: Array(slice))
        }
        return (half(start, stored[..<leftCount]), half(start + leftCount, stored[leftCount...]))
    }
}

// MARK: - Sparse points onto the grid (the wire's form, C5b-3b)

/// One point of a drawing an agent sends: `cents` of drawn delta at SOURCE
/// second `seconds`. A named pair rather than a tuple, the `NotePitchOffset`
/// precedent: it carries a doc, and the refusals can name its fields.
public struct NoteShapePoint: Sendable, Equatable {
    public var seconds: Double
    public var cents: Double

    public init(seconds: Double, cents: Double) {
        self.seconds = seconds
        self.cents = cents
    }
}

extension NoteShapeSamples {

    /// ⭐ A PATCH BY POINTS (design §5.7, `clip.setNoteShape`'s `points`): the
    /// whole new shape of `note` after drawing `points` onto it.
    ///  * The points are in SOURCE seconds, sorted here. Between the first and
    ///    the last, every grid sample (`gridIndex(atOrAfter: first)` through
    ///    `gridIndex(atOrBefore: last)`, both included) takes the LINEAR
    ///    interpolation of the points' cents, each point first clamped to
    ///    `NoteSegment.shapeCentsRange`, then quantised to the nearest tenth.
    ///  * Everywhere else in the note, the note keeps what it PLAYS now
    ///    (`playing(on:)`): its stored samples, its held ends, or ⭐ ZERO for a
    ///    note with no drawing — without that zero-fill, the first and last
    ///    points would be held across the whole note (this file's banner).
    ///  * The result is normalised (`normalised(for:)`), so it is exactly what
    ///    the store will hold: an all-zero drawing comes back as a clear.
    ///
    /// Refused in words (`NoteShapeSentences`), all or nothing: no points, a
    /// point that is not a number, one second named twice with two different
    /// values, points that do not span a single grid step, and points that
    /// reach no part of the note. The sound ruling is the set transform's.
    public static func splicing(points: [NoteShapePoint],
                                onto note: NoteSegment) throws -> NoteShapeSamples {
        guard !points.isEmpty else {
            throw ProjectError.invalidClipEdit(NoteShapeSentences.noPoints)
        }
        for (position, point) in points.enumerated()
        where !point.seconds.isFinite || !point.cents.isFinite {
            throw ProjectError.invalidClipEdit(
                NoteShapeSentences.pointNotANumber(position: position + 1, point))
        }
        let range = NoteSegment.shapeCentsRange
        // Stable: equal seconds keep the caller's order, so the refusal below
        // names the same pair every time.
        let sorted = points.enumerated()
            .sorted { ($0.element.seconds, $0.offset) < ($1.element.seconds, $1.offset) }
            .map { NoteShapePoint(seconds: $0.element.seconds, cents: $0.element.cents.clamped(to: range)) }
        var distinct: [NoteShapePoint] = []
        for point in sorted {
            if let previous = distinct.last, previous.seconds == point.seconds {
                guard previous.cents == point.cents else {
                    throw ProjectError.invalidClipEdit(NoteShapeSentences.pointsTwiceAtOneSecond(
                        seconds: point.seconds, previous.cents, point.cents))
                }
                continue
            }
            distinct.append(point)
        }
        let firstIndex = gridIndex(atOrAfter: distinct[0].seconds)
        let lastIndex = gridIndex(atOrBefore: distinct[distinct.count - 1].seconds)
        guard firstIndex <= lastIndex else {
            throw ProjectError.invalidClipEdit(NoteShapeSentences.pointsMissTheGrid)
        }
        let span = gridSpan(of: note)
        let lower = Swift.max(firstIndex, span.lowerBound)
        let upper = Swift.min(lastIndex + 1, span.upperBound)
        guard lower < upper else {
            throw ProjectError.invalidClipEdit(NoteShapeSentences.pointsMissTheNote(
                note, from: distinct[0].seconds, to: distinct[distinct.count - 1].seconds))
        }

        var values = playing(on: note).tenthsOfCents
        var segment = 0   // `distinct[segment] … distinct[segment + 1]` brackets `t`
        let tenths = NoteSegment.shapeTenthsRange
        for index in lower..<upper {
            let t = seconds(atGridIndex: index)
            while segment + 1 < distinct.count - 1, distinct[segment + 1].seconds < t {
                segment += 1
            }
            let cents: Double
            if distinct.count == 1 {
                cents = distinct[0].cents
            } else {
                let a = distinct[segment], b = distinct[segment + 1]
                let fraction = ((t - a.seconds) / (b.seconds - a.seconds)).clamped(to: 0...1)
                cents = a.cents + (b.cents - a.cents) * fraction
            }
            let quantised = (cents * 10).rounded()
                .clamped(to: Double(tenths.lowerBound)...Double(tenths.upperBound))
            values[index - span.lowerBound] = Int16(quantised)
        }
        return NoteShapeSamples(startIndex: span.lowerBound, tenthsOfCents: values)
            .normalised(for: note)
    }
}

// MARK: - The words (one home; the wire lane C5b-3b echoes them verbatim)

/// The refusal sentences of the drawn-shape writes. Written for a person who
/// has never used a pitch editor; each says what was wrong, that nothing
/// changed, and what to do instead.
public enum NoteShapeSentences {
    /// An empty map of notes.
    public static let nameAtLeastOneNote =
        "Name at least one note to draw on. Read the clip's note ids with "
        + "`clip.getPitchEdits` first."

    /// ⭐ THE SOUND RULING (C5b-3a): a breath or a consonant has no pitch line
    /// to draw, so drawing on one is refused. A CLEAR of a drawing a sound
    /// already carries (only a hand-written file can put one there) is the one
    /// write allowed on a sound: it only ever removes.
    public static func soundHasNoPitchLine(_ segmentId: UUID) -> String {
        "Note \(segmentId) is a breath or a consonant, not a sung note, so it has no pitch "
            + "line to draw. Nothing was changed. Name sung notes only."
    }

    /// A write whose samples land nowhere inside the note.
    public static func drawingMissesTheNote(_ note: NoteSegment) -> String {
        "The drawing for note \(note.id) lands outside it: the note runs from "
            + "\(secondsText(note.startSeconds)) to \(secondsText(note.endSeconds)), and no "
            + "part of the drawing falls between. Nothing was changed. Draw inside the note, "
            + "or clear its drawing instead."
    }

    /// A note too short to hold a single 10 ms grid step.
    public static func noteTooShortToDraw(_ note: NoteSegment) -> String {
        "Note \(note.id) is shorter than one 10 ms step of the drawing grid, so there is "
            + "nothing on it to draw. Nothing was changed."
    }

    /// `splicing` with no points.
    public static let noPoints =
        "Give at least one point to draw: each point is a time in seconds and a number of "
        + "cents. Nothing was changed."

    /// A point with a time or a value that is not a finite number.
    public static func pointNotANumber(position: Int, _ point: NoteShapePoint) -> String {
        "Point \(position) is not a number (seconds \(point.seconds), cents \(point.cents)). "
            + "Every point needs a real time and a real number of cents. Nothing was changed."
    }

    /// Two points at the same second asking for two different values.
    public static func pointsTwiceAtOneSecond(seconds: Double, _ first: Double,
                                              _ second: Double) -> String {
        "Two points sit at \(seconds) s with different cents (\(first) and \(second)). "
            + "Give each moment once. Nothing was changed."
    }

    /// Points that do not span one grid step (a lone point off the grid).
    public static let pointsMissTheGrid =
        "Those points don't reach a single 10 ms step of the drawing grid, so there is "
        + "nothing to draw between them. Spread them out, or put one exactly on a step "
        + "(a multiple of 0.01 s). Nothing was changed."

    /// Points that reach no part of the note.
    public static func pointsMissTheNote(_ note: NoteSegment, from: Double, to: Double) -> String {
        "Those points run from \(secondsText(from)) to \(secondsText(to)), but note "
            + "\(note.id) runs from \(secondsText(note.startSeconds)) to "
            + "\(secondsText(note.endSeconds)), so none of them lands on it. Nothing was "
            + "changed. Give points inside the note."
    }

    /// Seconds for a person: two decimals, one grid step's resolution.
    private static func secondsText(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }
}

// MARK: - The set transform (the store's commit and a brush's draft)

extension PitchEditSet {

    /// This set with each named note's drawing replaced, exactly as
    /// `ProjectStore.setClipNoteShapes` stores it (design §5.7):
    ///  * each value is the note's WHOLE new drawing (`NoteShapeSamples`'s
    ///    doc), trimmed, zero-filled, clamped and normalised
    ///    (`normalised(for:)`); an empty value CLEARS it;
    ///  * refused in words, ALL OR NOTHING (nothing is written unless every
    ///    note passes): an empty map; an unknown id (naming how many notes the
    ///    set carries, the store's `segmentIndex` words); a SOUND
    ///    (`.unpitched`), unless the write clears a drawing it already carries
    ///    (`NoteShapeSentences.soundHasNoPitchLine`); a non-clear write on a
    ///    note too short for one grid step; and a non-clear write that reaches
    ///    no part of its note, which would otherwise normalise to a clear and
    ///    silently ERASE the drawing;
    ///  * writes those two fields and nothing else, then
    ///    `afterHandEdit(from: self)` (a drawn shape is a HAND edit: D4-1's
    ///    home, so on a vocal that predates natural tuning a drawing that
    ///    changes a note also updates the whole vocal, and one that changes
    ///    nothing, such as clearing a note with no drawing, updates nothing;
    ///    the user's ruling (b), `handEditUpgradesLegacyVocal`; the C4 rule).
    /// `clipId` only words the refusals. Notes are resolved in the SET's order
    /// and unknown ids in ascending `uuidString` order, so the same bad input
    /// names the same note every time.
    public func applyingNoteShapes(_ shapes: [UUID: NoteShapeSamples],
                                   clipId: UUID) throws -> PitchEditSet {
        guard !shapes.isEmpty else {
            throw ProjectError.invalidClipEdit(NoteShapeSentences.nameAtLeastOneNote)
        }
        let known = Set(segments.map(\.id))
        if let unknown = shapes.keys.filter({ !known.contains($0) })
            .sorted(by: { $0.uuidString < $1.uuidString }).first {
            throw ProjectError.invalidClipEdit(
                "No note with id \(unknown) on clip \(clipId). That clip carries "
                    + "\(segments.count) note(s); read them back with "
                    + "`clip.getPitchEdits` before editing one.")
        }
        var table = self
        for index in table.segments.indices {
            let note = table.segments[index]
            guard let write = shapes[note.id] else { continue }
            if note.origin == .unpitched, !(write.isClear && note.hasShape) {
                throw ProjectError.invalidClipEdit(NoteShapeSentences.soundHasNoPitchLine(note.id))
            }
            if !write.isClear {
                guard !NoteShapeSamples.gridSpan(of: note).isEmpty else {
                    throw ProjectError.invalidClipEdit(NoteShapeSentences.noteTooShortToDraw(note))
                }
                guard write.reaches(note) else {
                    throw ProjectError.invalidClipEdit(NoteShapeSentences.drawingMissesTheNote(note))
                }
            }
            table.segments[index] = write.applied(to: note)
        }
        return table.afterHandEdit(from: self)
    }
}
