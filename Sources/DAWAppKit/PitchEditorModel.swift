import CoreGraphics
import Foundation
import Observation
import DAWCore

// m23-ap Phase 2, item p2-a — THE HEADLESS PITCH-EDITOR MODEL.
//
// Design record: `docs/design/2026-09-22-pitch-editor-ui.md` — §5.3 (the data
// path), §5.4 (this type), §5.5 (the five honesty rules), §5.7 (the four
// states), §5.8 (zoom/follow/density), §5.9 (real-time safety), §12.1 (the
// suite that gates this file). Increment A is READ-ONLY: nothing here writes
// `Clip.pitchEdits`, nothing here persists, nothing here reaches the store
// except through an injected closure.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⚠️⚠️ THE ONE COORDINATE HOME — AND THE ONE MISTAKE THAT CORRUPTS DATA
// ═══════════════════════════════════════════════════════════════════════════
//
// The DATA is in SOURCE-FILE-ABSOLUTE SECONDS. `ClipPitchFrame.timeSeconds`
// (`PitchDetection.swift`) and `NoteSegment.startSeconds`/`endSeconds`
// (`PitchCorrection.swift`) are geometry-free ON PURPOSE: a trim, a split, a
// move or a tempo change does NOT move those numbers, which is exactly what
// lets a split clip share one phase-coherent render.
//
// The SCREEN is in PROJECT BEATS, because the playhead, the arrange and the
// user's mental model are all in bars.
//
// ⛔ **RE-ANCHORING THE DATA IS THE BUG.** `Clip.windowedGainEnvelope` and
// `windowedControllerLanes` sit three lines from every `Clip(...)` rebuild
// site doing exactly that re-anchoring — because THOSE fields are clip-relative
// BEATS. Copying their shape onto a `NoteSegment` silently de-tunes every
// segment to the right of a split and leaves a healthy-looking non-nil set
// behind. An agent proved it by planting it on 2026-09-22 and watching a
// segment clamp to [0.0, 0.4] instead of [0.25, 0.90].
//
// So: the conversion lives HERE, in the GEOMETRY, and the data is never
// touched. Exactly two functions convert, `x(forSourceSecond:)` and
// `sourceSecond(forX:)`, and nothing else in the app may.
//
// ⚠️ **PHASE 3 IS WHY THEY ARE FUNCTIONS AND NOT AN INLINE MULTIPLY.** Today
// `stretchRatio` is constant over a clip, so source→output is one multiply and
// the only piecewise term is the tempo map. With per-segment time deltas
// (`NoteSegment.timeStartDeltaSeconds`, phase 3) the source→output schedule
// becomes piecewise in its own right. Keeping BOTH directions in these two
// functions is what makes phase 3 a change to one file. **Do not inline the
// arithmetic at a draw site.**
//
// The render path owns the OTHER half of this mapping and deliberately does
// not know about clip geometry: `StretchCurvePlan.sourceSecond(forOutputFrame:)`
// renders the WHOLE source file, so `startOffsetSeconds`/`startBeat`/
// `lengthBeats` never enter there. Verified directly, 2026-09-22 — its ratio
// term has the same sense as this file's (output seconds = source seconds ×
// ratio), and dropping that term is named there as "the single most likely
// mistake here". It is the single most likely mistake here too, and
// `PitchEditorModelTests.xIsHandComputedOnATrimmedOffsetStretchedClip` is the
// assertion that catches it: a ROUND TRIP cannot, because a ratio dropped from
// BOTH directions round-trips perfectly.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⚠️ COMMAND SURFACE — NOT THIS ITEM'S, AND DELIBERATELY NOT WRITTEN HERE
// ═══════════════════════════════════════════════════════════════════════════
//
// This file adds NO user-facing operation: it mutates no model state, reaches
// no store, and answers no wire verb. The doors this model will eventually sit
// behind are assigned by §9.1/§15 to a LATER item, and two other agents are
// live in those files as this lands:
//
// TODO(p2-c): `view.openPitchEditor` (production tier, `view.selectClip`'s
//   sibling; handler in `Sources/DAWApp/ViewUIWireSurface.swift`, typed seam in
//   `Sources/DAWControl/ViewUISurface.swift`) + `debug.pitchEditor` (the echo:
//   open clip id, blob count, visible midi range, `state.statusKey`,
//   `state.message` — resolved at ONE home and passed in as plain values, never
//   re-derived by the echo).
// TODO(p2-c): MCP tool `view_open_pitch_editor`, one tool for the one verb.
//   `debug.*` is NEVER an MCP tool (the standing tier rule).

// MARK: - Readout floors

/// The measured limits on what a pitch readout over this chain is ALLOWED to
/// claim. From `PitchCorrection.swift`'s header and design §5.5.3 — these are
/// MEASUREMENTS, not styling.
public enum PitchEditorReadout {
    /// SwiftF0's output is an argmax over 256 log-spaced bins: **25.79 cents
    /// per bin**. The contour's visible staircase IS that resolution, and
    /// §5.5.2 forbids smoothing it away.
    public nonisolated static let detectorBinCents: Double = 25.79

    /// Half a bin — the finest distinction this detector can support, so no
    /// readout may imply anything finer. (The transposer used to add a second
    /// error, +5.45 c at +2 st and +3.95 at −2 st, until p2-acc's vendored
    /// patch on 2026-09-25; it now lands within 0.5 c for |shift| ≤ 3 st. This
    /// floor never depended on it.)
    public nonisolated static let centsResolutionFloor: Double = PitchCorrectionMath.detectorResolutionFloorCents

    /// A cents figure as a readout, or `nil` when the figure is inside the
    /// detector's own resolution.
    ///
    /// ⚠️ **`nil` DOES NOT MEAN "IN TUNE".** It means "closer than this
    /// detector can resolve". A surface that renders `nil` as "0 cents" would
    /// be claiming a measurement nobody made. Whole numbers only (§5.5.3) —
    /// `%+.0f`, the `SamplerEditorModel` cents-readout idiom.
    public nonisolated static func centsReadout(_ cents: Double) -> String? {
        guard cents.isFinite, abs(cents) >= centsResolutionFloor else { return nil }
        return String(format: "%+.0f cents", cents)
    }

    /// UE-1 — what a SOUND with no detected pitch (`NoteOrigin.unpitched`) says
    /// INSTEAD of a cents readout. Verbatim from the unpitched-notes design
    /// §1.7 (U5), which natural-tuning R21 keeps ("U5's on-screen text stays
    /// true") and R26's renames do not touch.
    ///
    /// ⛔ **A SOUND GETS NO NUMBER.** Its drawn pitch is BORROWED from the note
    /// beside it (§1.5), so "+100 cents" or a note name would be a measurement
    /// nobody made. What moving it DOES is the useful fact: the breath or
    /// consonant is transposed, and only gets brighter or darker.
    public nonisolated static let unpitchedSound =
        "No pitch found. Moving it shifts this sound: a breath or an 's' just gets brighter or darker."

    /// UE-2 — the TAG a dragged sound carries ABOVE itself (the drag overlay),
    /// while `unpitchedSound` sits in the palette's readout slot.
    ///
    /// ⚠️ **THE SENTENCE CANNOT LIVE AT THE POINTER.** ~94 characters of 9 pt
    /// mono is ~500 pt, centred over a breath 20–60 pt wide, on a Canvas as
    /// wide as the clip — so it runs off the visible pane at either end and
    /// clamping it to the Canvas is not clamping it to what a person sees. Two
    /// words, the sentence's own first two, are what fits there; the palette
    /// (the readout's ONE home) says the rest. No direction word ("brighter"):
    /// §1.7 marks what a move DOES to a sound as inferred, not measured.
    public nonisolated static let unpitchedSoundTag = "No pitch"
}

// MARK: - The visible pitch window

/// How the editor picks the vertical window it opens at (design §5.6,
/// "Vertical range").
///
/// ⚠️ **EVERY CONSTANT HERE IS A PICK, NOT A MEASUREMENT.** They are bounded
/// by two facts — a 128-row view makes a vocal an invisible ribbon, and a
/// one-row view of a monotone phrase is useless — and nothing finer. Said out
/// loud so nobody cites them as tuned.
public enum PitchEditorRange {
    /// Headroom above the highest and below the lowest detected note centre.
    /// A PICK: four semitones comfortably contains a scoop or a vibrato swing
    /// around a note's centre, so the contour rarely leaves the window.
    public nonisolated static let paddingSemitones: Double = 4

    /// Smallest window the editor will open at. A PICK: a phrase sung on one
    /// note would otherwise produce a window a few rows tall, which reads as a
    /// broken view rather than a tight one.
    public nonisolated static let minimumVisibleSemitones: Double = 12

    /// Largest window the editor will open at — three octaves. A PICK, and it
    /// is the guard against §5.6's "never the full 128": SwiftF0 is MONOPHONIC
    /// and will report *something* for a drum loop or a full mix (design §11
    /// P9), so a detected "range" of 90 semitones is evidence of nonsense, not
    /// of a nine-octave singer. Clamping keeps the surface readable instead of
    /// drawing confident nonsense at one pixel per note.
    public nonisolated static let maximumVisibleSemitones: Double = 36

    /// Where the editor opens when NOTHING was detected. C2…C5 — a PICK,
    /// chosen C-to-C so the ruler reads as deliberate, and wide enough to hold
    /// a bass-baritone low C2 and an alto/tenor high C5. §5.6 requires the
    /// surface to SAY IN WORDS that it fell back; that is
    /// `PitchEditorState.noNotesFound.message`, not this range.
    public nonisolated static let fallbackMidiRange: ClosedRange<Double> = 36...72

    /// The full MIDI span, the outer clamp for any window.
    public nonisolated static let fullMidiRange: ClosedRange<Double> = 0...127

    /// The window to open at for a set of detected note centres.
    ///
    /// Centres, not the raw contour: a centre is a run's MEDIAN (the thing
    /// that survives vibrato and an onset scoop), while the contour's extremes
    /// include every octave-error excursion the detector made. `paddingSemitones`
    /// is what re-admits the contour around each centre.
    ///
    /// Bounds come back INTEGRAL, so semitone rows line up with the ruler's
    /// keys; `PitchEditorGeometry` does not require that, so a view is free to
    /// scroll or animate to fractional bounds.
    public nonisolated static func midiRange(forNoteCentres centres: [Double]) -> ClosedRange<Double> {
        let usable = centres.filter(\.isFinite)
        guard let lowest = usable.min(), let highest = usable.max() else {
            return fallbackMidiRange
        }
        var low = (lowest - paddingSemitones).rounded(.down)
        var high = (highest + paddingSemitones).rounded(.up)

        if high - low < minimumVisibleSemitones {
            let grow = (minimumVisibleSemitones - (high - low)) / 2
            low = (low - grow).rounded(.down)
            high = (high + grow).rounded(.up)
        }
        if high - low > maximumVisibleSemitones {
            // Re-centre on the MEDIAN centre rather than on the midpoint of the
            // outliers: one octave-error note must not drag the window off the
            // material that is actually there.
            let centre = PitchCorrectionMath.median(usable) ?? ((low + high) / 2)
            low = (centre - maximumVisibleSemitones / 2).rounded(.down)
            high = low + maximumVisibleSemitones
        }

        // Clamp into 0…127 by SLIDING (the span the rules above chose is kept
        // wherever the full range can hold it), never by silently narrowing.
        let span = min(high - low, fullMidiRange.upperBound - fullMidiRange.lowerBound)
        if low < fullMidiRange.lowerBound {
            low = fullMidiRange.lowerBound
            high = low + span
        }
        if high > fullMidiRange.upperBound {
            high = fullMidiRange.upperBound
            low = high - span
        }
        return low...high
    }

    // MARK: I6c — the window grows to fill the pane (interaction batch §9)

    /// The window to LAY OUT in a pane `availableHeight` points tall at
    /// `rowHeight` points per semitone: `fitted` (the notes' own window) grown
    /// by WHOLE rows while one more whole row still fits, the new rows split
    /// above and below so the notes stay centred (m23-ap I6c).
    ///
    /// ⭐ **THE ROW HEIGHT IS THE USER'S, SO THE ROW COUNT MOVES AND THE ROW
    /// HEIGHT DOES NOT** (the I6c brief's approach A). PITCH −/+ keeps meaning
    /// "shorter/taller rows"; a pane with room to spare shows MORE rows, never
    /// fatter ones. Stretching the rows to fit instead (approach B) would make
    /// PITCH −/+ do nothing while the editor is maximized.
    ///
    /// ⚠️ **FLOOR, NOT CEIL, AND THE REMAINDER UNDER ONE ROW IS DELIBERATE.** A
    /// row is added only while a WHOLE row fits, so the window THIS returns is
    /// never taller than its pane and ends less than one row above the pane's
    /// floor. (The strand rule can still widen the LAID-OUT window past the
    /// pane; `PitchEditorModel.layOutPitchWindow` says when.) Ceil
    /// would overshoot the pane by up to a row. That means a scroll of a
    /// fraction of a row, and the gap strip (drawn on the CONTENT's floor,
    /// `PitchEditorSurface.drawGaps`) sitting under the viewport's edge. It
    /// would also give the DOCKED default pane an 18th row it has no room for:
    /// MEASURED 2026-09-25 at 1400×1000, that pane is 245.6 pt tall for a
    /// 17-row, 238 pt window. Floor leaves that pane exactly as it was.
    ///
    /// ⚠️ Bounded by `fullMidiRange`, NOT by `maximumVisibleSemitones`. That cap
    /// guards the OPENING window against detection nonsense drawn at one pixel
    /// per note. The fill never makes a row shorter; it only spends room the
    /// user gave it, at the row height they chose.
    ///
    /// The ODD row goes ABOVE: a PICK, because nothing prefers either side,
    /// and the extra row is room to drag a note UP into.
    ///
    /// Total: an unmeasured pane (`availableHeight` ≤ 0 or not finite), a
    /// non-positive row height, or a window already at least as tall as the pane
    /// returns `fitted` unchanged. That keeps every caller with no pane (every
    /// headless test, the model before its first layout) exactly where it was.
    public nonisolated static func filled(_ fitted: ClosedRange<Double>,
                                          rowHeight: CGFloat,
                                          availableHeight: CGFloat) -> ClosedRange<Double> {
        guard rowHeight.isFinite, rowHeight > 0,
              availableHeight.isFinite, availableHeight > 0 else { return fitted }
        let fittedRows = fitted.upperBound - fitted.lowerBound + 1
        let allRows = fullMidiRange.upperBound - fullMidiRange.lowerBound + 1
        // A hair of slack, so a pane EXACTLY n rows tall (give or take layout
        // rounding) holds n rows and not n − 1.
        let fits = (Double(availableHeight / rowHeight) + 1e-6).rounded(.down)
        let rows = min(allRows, fits)
        guard rows > fittedRows else { return fitted }
        let extra = rows - fittedRows
        let below = (extra / 2).rounded(.down)
        var low = fitted.lowerBound - below
        var high = fitted.upperBound + (extra - below)
        // Into 0…127 by SLIDING, keeping the span (`midiRange(forNoteCentres:)`'s
        // rule): the span is at most 128 rows, so a slide always fits.
        if low < fullMidiRange.lowerBound {
            high += fullMidiRange.lowerBound - low
            low = fullMidiRange.lowerBound
        }
        if high > fullMidiRange.upperBound {
            low -= high - fullMidiRange.upperBound
            high = fullMidiRange.upperBound
        }
        return max(fullMidiRange.lowerBound, low)...high
    }

    /// Rows kept free on either side of a note the strand rule holds. The note's
    /// NAME is drawn in the gutter ABOVE it (`PitchEditorSurface.drawBlobLabels`),
    /// so a note held on the window's very top row would keep its blob and lose
    /// its label off the content. MEASURED on staging 2026-09-25: a restore left
    /// the dragged note on the top row with no "B4" drawn. One row is room for
    /// the 8 pt label at every row height the zoom reaches (10 pt and up).
    public nonisolated static let heldNoteHeadroomRows: Double = 1

    /// `window`, widened by whole rows just enough to hold every pitch in
    /// `drawnMidis` with `heldNoteHeadroomRows` to spare, and never narrowed
    /// (m23-ap I6c).
    ///
    /// ⛔ **THE STRAND RULE.** A note dragged into a row the fill added must not
    /// vanish when the pane shrinks (restore, PITCH +, a shorter splitter): that
    /// is the drag clamp's own "A NOTE DRAGGED OFF THE WINDOW IS DATA LOSS" rule,
    /// applied when the WINDOW moves rather than the note. The caller decides
    /// which notes are held (`PitchEditorModel.fitOutlierIDs` says why not all
    /// of them). Clamped to `fullMidiRange`; non-finite pitches are ignored.
    public nonisolated static func holding(_ window: ClosedRange<Double>,
                                           drawnMidis: [Double]) -> ClosedRange<Double> {
        let usable = drawnMidis.filter(\.isFinite)
        guard let lowest = usable.min(), let highest = usable.max() else { return window }
        let low = min(window.lowerBound,
                      max(fullMidiRange.lowerBound, lowest.rounded(.down) - heldNoteHeadroomRows))
        let high = max(window.upperBound,
                       min(fullMidiRange.upperBound, highest.rounded(.up) + heldNoteHeadroomRows))
        return low...high
    }

    // MARK: I6b — the window grows under a drag at its edge (interaction batch §9)

    /// `window` widened by `rows` whole rows at ONE end (m23-ap I6b S2): the TOP
    /// (higher pitches) for `.leading`, the bottom for `.trailing` — the sides
    /// `EdgeAutoScroll.Side` names on y, where `.leading` is the top because
    /// the pane draws its highest pitch there.
    ///
    /// Widen-only and clamped to `fullMidiRange`: a non-positive `rows` is no
    /// change, a bound already at 0 or 127 stays, and a bound somehow already
    /// PAST the clamp is never pulled back in (that would narrow). The other end
    /// never moves.
    public nonisolated static func grown(_ window: ClosedRange<Double>,
                                         towards side: EdgeAutoScroll.Side,
                                         by rows: Int) -> ClosedRange<Double> {
        guard rows > 0 else { return window }
        switch side {
        case .leading:
            let high = max(window.upperBound,
                           min(fullMidiRange.upperBound, window.upperBound + Double(rows)))
            return window.lowerBound...high
        case .trailing:
            let low = min(window.lowerBound,
                          max(fullMidiRange.lowerBound, window.lowerBound - Double(rows)))
            return low...window.upperBound
        }
    }
}

// MARK: - One key of the pitch ruler

/// One semitone row of the pitch ruler down the left edge (design §5.6.6).
///
/// ⚠️ **A DIVERGENCE FROM §5.4, STATED SO IT IS NOT MISTAKEN FOR A SLIP.** The
/// doc sketches `rulerKeys: [(midi: Int, isBlack: Bool, label: String?)]`. The
/// label here is NON-optional, because §5.6.6 requires EVERY key named (the
/// `KeyboardSidebar.keyLabel` density decision, m25-i) and an optional invites
/// a caller to drop it silently. `isOctaveC` is added because §5.6.2 asks for a
/// brighter hairline at each C and the view would otherwise re-derive `% 12`.
///
/// `isBlack` reads `MusicalKeyboardGeometry.isBlackKey` and `name` reads
/// `Fundamental.noteName` — the repo's ONE home for each question. Neither is
/// restated here.
public struct PitchRulerKey: Sendable, Equatable, Identifiable {
    public let midi: Int
    public var id: Int { midi }

    public init(midi: Int) { self.midi = midi }

    /// An accidental — the dark, narrow key.
    public var isBlack: Bool { MusicalKeyboardGeometry.isBlackKey(midi) }
    /// Scientific-pitch name: MIDI 60 = "C4".
    public var name: String { Fundamental.noteName(midiNote: midi) }
    /// True at every C — the octave landmark §5.6.2 brightens.
    public var isOctaveC: Bool { ((midi % 12) + 12) % 12 == 0 }
}

// MARK: - A detected note

/// One detected note, as the surface draws it: a `VoicedRun` in the editor's
/// own vocabulary (design §5.4, "blobs").
///
/// ⚠️ **`startSeconds`/`endSeconds` ARE SOURCE-FILE-ABSOLUTE AND STAY THAT
/// WAY.** They are never re-anchored to the clip; the geometry converts them
/// at draw time. See this file's banner.
public struct NoteBlob: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Note start / end, SOURCE-FILE seconds.
    public let startSeconds: Double
    public let endSeconds: Double
    /// The run's MEDIAN frequency — what survives vibrato and an onset scoop.
    public let detectedHz: Double
    /// `detectedHz` as a FRACTIONAL midi number. ⚠️ `Double`, not `Int`: this
    /// is the axis divergence that makes `PianoRollModel`/`KeyboardSidebar`
    /// unreusable (design §3.3.1).
    public let centreMidi: Double
    /// Median per-frame confidence.
    ///
    /// ⚠️ **VOICING, NOT ACCURACY** (§5.5.4). A 440 Hz sine reads 437.55 Hz —
    /// 9.7 cents flat — at confidence ≥ 0.985. If a surface encodes this (blob
    /// opacity is the natural encoding) its label is **"how sure we are you
    /// were singing here"**, never "how accurate". It must never gate a
    /// tolerance.
    public let medianConfidence: Double
    /// How many voiced frames the run was built from.
    public let frameCount: Int

    /// The EDIT this note carries: its stored `NoteSegment.pitchOffsetCents`,
    /// or 0 for a note nobody has touched (m23-ap C1).
    ///
    /// ⚠️ **THE MEASUREMENT AND THE EDIT ARE SEPARATE FIELDS ON PURPOSE.**
    /// `centreMidi` stays where the singer sang, forever; this is how far the
    /// user asked it to move. Folding the two into one number would make the
    /// ghost at the detected position — the thing that shows a novice WHAT they
    /// changed — underivable, and would quietly turn a measurement into an
    /// intention.
    public let offsetCents: Double

    /// vf-18 leg 3 — what a FOLLOWED slide's neighbours add to where it plays,
    /// cents: `glideFollow · (from + to) / 2`, the mean of its bridge
    /// (`PitchEditSet.slideFollowCents(only:)`, DAWCore's one home). 0 for
    /// every note that does not follow, and for a slide whose neighbours sit
    /// where they were sung.
    ///
    /// ⚠️ **A THIRD FIELD, NOT FOLDED INTO `offsetCents`.** The stored offset
    /// of a followed slide is RELATIVE to the line between its neighbours
    /// (natural tuning §4.b.3), so after Select All +12 a carried slide stores
    /// +0 and plays +12. The blob is drawn where it PLAYS
    /// (`PitchEditorGeometry.drawnMidi(for:)` adds this), and a drag maps the
    /// drawn pitch back to the stored offset by taking it out again — so a
    /// slide left an octave below its line can never invite a hand drag that
    /// moves it twice (vf-18). The edit stays the edit: `offsetCents` keeps
    /// its meaning, and this is read from the table, never stored.
    public let followCents: Double

    /// `NoteSegment.isEdited` of the segment this blob was drawn from — ANY
    /// per-note edit, not only a pitch move (m23-ap C-0). A Hard-Tuned note
    /// that already sat in tune carries offset 0 and flattened scales; before
    /// this it drew as untouched while its line visibly changed.
    ///
    /// ⚠️ **A CLEARED NOTE IS "EDITED" TOO** (`NoteSegment.hasLevelEdits` is part
    /// of `isEdited`), so a surface that asks `isEdited` first would draw a
    /// cleared note in the TUNED accent. Ask `isCleared` first — the cleared
    /// look (hollow, dashed, labelled) replaces the tuned one, it does not sit
    /// on top of it.
    public let hasEdits: Bool

    /// m23-ap I7b — the note is CLEARED (`NoteSegment.isCleared`, I7a): the
    /// render silences it between two 10 ms ramps, IN PLACE. It stays drawn and
    /// selectable, and Restore brings it back at its own level.
    public let isCleared: Bool

    /// m23-ap I7b — the note's LEVEL, dB (`NoteSegment.amplitudeDb`, U-D's
    /// `clip.setNoteGain`): 0 is as sung, −72 the quietest level (never
    /// silence — that is `isCleared`). Read from the segment, never derived.
    public let amplitudeDb: Double

    /// ⭐ THE TUNED COLOUR'S QUESTION (m23-ap I1 UI hooks, item 7): does this
    /// note's PITCH half depart from identity — `!NoteSegment.isPitchIdentity`
    /// of the segment it was drawn from. The SAME per-note predicate the header
    /// badge aggregates (`Clip.hasTuningEdits` = `!PitchEditSet.isPitchIdentity`),
    /// so the note and the badge cannot disagree: ONE home, read, not restated.
    ///
    /// ⛔ NOT `isEdited`, which also counts LEVEL edits (a clear, a level) and a
    /// vibrato RATE with no depth (which renders as nothing). Found by I7b-2: a
    /// note that was only turned down drew in the tuned green while the header
    /// said NOTES EDITED, and a rate-only note drew green over a sound nobody
    /// changed. A level keeps its own plate and a clear its own look; neither
    /// is "tuned". A Hard-Tuned note that already sat in tune (offset 0,
    /// flattened drift and vibrato) IS pitch-edited: green, with no ghost
    /// (`isMoved` is the ghost's question, and it is false there).
    ///
    /// ⚠️ vf-18 leg 3 — ONE EXTENSION, STATED: `init(segment:frameCount:followCents:)`
    /// also answers true for a FOLLOWED slide whose neighbours move it
    /// (`followCents != 0`) while its own segment is pitch-identity — it plays
    /// tuned, so it is drawn tuned (design REVIEW §3.7). The header badge
    /// still agrees: a non-zero follow needs a neighbour with a non-zero
    /// offset, which is itself not pitch-identity, so the set is not either.
    public let isPitchEdited: Bool

    /// UE-1 — where the segment this blob was drawn from came from
    /// (`NoteSegment.origin`, U-A): a note the splitter found, a sung slide, or
    /// a SOUND with no detected pitch. A detection fact, copied, never derived.
    /// A blob built without a segment (`init(run:)`) is `.detected`.
    public let origin: NoteOrigin

    public init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double,
                detectedHz: Double, medianConfidence: Double, frameCount: Int,
                offsetCents: Double = 0, hasEdits: Bool? = nil,
                isCleared: Bool = false, amplitudeDb: Double = 0,
                isPitchEdited: Bool? = nil, origin: NoteOrigin = .detected,
                followCents: Double = 0) {
        self.origin = origin
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.detectedHz = detectedHz
        self.centreMidi = PitchCorrectionMath.midi(fromHz: detectedHz)
        self.medianConfidence = medianConfidence
        self.frameCount = frameCount
        self.offsetCents = offsetCents
        self.followCents = followCents
        self.hasEdits = hasEdits ?? (offsetCents != 0 || isCleared || amplitudeDb != 0)
        self.isCleared = isCleared
        self.amplitudeDb = amplitudeDb
        // A blob built without a segment knows only its offset — the one pitch
        // field it carries. `init(segment:)` hands the segment's own answer.
        self.isPitchEdited = isPitchEdited ?? (offsetCents != 0)
    }

    /// One stored note, as the surface draws it (m23-ap C1/C3). `id` is the
    /// SEGMENT's id — which is what makes a drag addressable, a split
    /// attributable, and an undo key derivable without a second table.
    ///
    /// vf-18 leg 3: `followCents` is the segment's follow contribution in its
    /// table (`PitchEditSet.slideFollowCents(only:)`); a segment alone knows
    /// nothing of its neighbours. A followed slide that plays away from where
    /// it was sung wears the tuned colour (design REVIEW §3.7).
    public init(segment: NoteSegment, frameCount: Int, followCents: Double = 0) {
        self.init(id: segment.id,
                  startSeconds: segment.startSeconds,
                  endSeconds: segment.endSeconds,
                  detectedHz: segment.detectedHz,
                  medianConfidence: segment.detectedConfidence,
                  frameCount: frameCount,
                  offsetCents: segment.pitchOffsetCents,
                  hasEdits: segment.isEdited,
                  isCleared: segment.isCleared,
                  amplitudeDb: segment.amplitudeDb,
                  isPitchEdited: !segment.isPitchIdentity || followCents != 0,
                  origin: segment.origin,
                  followCents: followCents)
    }

    /// UE-1 — this blob is a SOUND with no detected pitch: a breath, a
    /// consonant, or a piece of a sung note the detector did not commit to
    /// (`NoteOrigin.unpitched`, unpitched-notes design §1.4). Its `centreMidi`
    /// is the BORROWED anchor of the note beside it (§1.5), never a
    /// measurement, so it prints no cents (`soundReadout` instead), snaps
    /// relative to where it sits (`PitchEditorModel.updatePitchDrag`), and is
    /// a "Sound" in the selection menu (`menuTarget`).
    public var isUnpitched: Bool { origin == .unpitched }

    /// UE-1 — §1.7's sentence for a sound (`PitchEditorReadout.unpitchedSound`),
    /// or `nil` for a note. The line a surface shows where a note would show
    /// its cents.
    public var soundReadout: String? { isUnpitched ? PitchEditorReadout.unpitchedSound : nil }

    /// m23-ap I7b — the note's LEVEL as a readout, "Level -6.0 dB", or `nil`
    /// when there is nothing to say: a note at its sung level (0 dB), or a
    /// CLEARED note (it plays silence, and its "cleared" label says so; the
    /// level it keeps for Restore is in the echo, `levelDb`).
    ///
    /// ⭐ **A LEVEL IS NEVER INVISIBLE** (design §17.3): any non-zero level
    /// reads, even one that rounds to "0.0 dB" — nothing on screen may pretend
    /// an edited level is the sung one. Formatted by the house's ONE dB
    /// readout (`ClipEdit.gainDbString`: one decimal, explicit `+`), so a note's
    /// level and a clip's gain read in the same style.
    public var levelReadout: String? {
        guard !isCleared, amplitudeDb != 0 else { return nil }
        return "Level " + ClipEdit.gainDbString(amplitudeDb)
    }

    /// What the selection menu needs to know about this note
    /// (`PitchEditorNoteMenu`). UE-1: a SOUND is a `.sound`, so its items read
    /// "Clear Sound" / "Restore 2 Sounds" and a mix reads "Clear 3 Selected"
    /// (the nouns the menu already mapped; this is their producer).
    public var menuTarget: PitchEditorNoteMenu.Target {
        PitchEditorNoteMenu.Target(kind: isUnpitched ? .sound : .note, isCleared: isCleared)
    }

    /// The detected centre plus the edit, WITHOUT the clip's transpose — the
    /// stored note's own pitch. ⚠️ What a surface DRAWS is
    /// `PitchEditorGeometry.drawnMidi(for:)`, which adds the transpose; the two
    /// are equal only on an untransposed clip.
    public var editedCentreMidi: Double { centreMidi + offsetCents / 100 }

    /// True when this note carries ANY edit (`NoteSegment.isEdited`): "has
    /// anyone touched this note". ⚠️ NOT the tuned colour's question since
    /// m23-ap I1 UI hooks item 7 — that is `isPitchEdited`, the pitch half only.
    public var isEdited: Bool { hasEdits || offsetCents != 0 }

    /// True when the note was MOVED off where it was sung — the ghost's
    /// question. A note whose only edit is its wobble has no second place to
    /// draw an outline at.
    ///
    /// vf-18 leg 3: a followed slide its neighbours carried (`followCents`)
    /// is drawn off where it was sung too, so it keeps a ghost like every
    /// note around it — otherwise Select All +12 leaves a ghost under every
    /// note but the slides.
    public var isMoved: Bool { offsetCents != 0 || followCents != 0 }

    /// The note the EDIT lands on — what the blob's label says once it has been
    /// dragged. ⚠️ Distinct from `nearestMidiNote`, which names the note that
    /// was SUNG; conflating them would make a corrected vocal's editor claim
    /// the singer hit a note they did not.
    public var editedNearestMidiNote: Int { Int(editedCentreMidi.rounded()) }

    /// Its name, e.g. "A3" — the blob's label when there is room.
    public var editedNoteName: String { Fundamental.noteName(midiNote: editedNearestMidiNote) }

    /// The edit as a READOUT, or `nil` when it is inside the detector's own
    /// resolution (`PitchEditorReadout`'s ±12.90 cent floor). ⚠️ `nil` is
    /// "too small for us to claim", never "no edit". UE-1: `nil` for a SOUND,
    /// always — it has no pitch to move by cents from (`soundReadout`).
    public var offsetReadout: String? {
        isUnpitched ? nil : PitchEditorReadout.centsReadout(offsetCents)
    }

    /// The editor's vocabulary for one `VoicedRun`. Verbatim — no rounding, no
    /// re-anchoring, no filtering.
    public init(run: VoicedRun, id: UUID = UUID()) {
        self.init(id: id, startSeconds: run.startSeconds, endSeconds: run.endSeconds,
                  detectedHz: run.centreHz, medianConfidence: run.medianConfidence,
                  frameCount: run.frameCount)
    }

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }

    /// The equal-tempered note this centre is nearest to.
    public var nearestMidiNote: Int { Int(centreMidi.rounded()) }
    /// Its name, e.g. "A3" — the blob's label when there is room (§5.6.3).
    public var noteName: String { Fundamental.noteName(midiNote: nearestMidiNote) }
    /// Signed distance from that note, cents. The raw measurement.
    public var centsFromNearestNote: Double {
        (centreMidi - Double(nearestMidiNote)) * 100
    }
    /// The distance as a READOUT, or `nil` when it is inside the detector's own
    /// resolution. ⚠️ `nil` is "we cannot tell", never "in tune" —
    /// `PitchEditorReadout.centsReadout`. UE-1: `nil` for a SOUND, always — its
    /// centre is borrowed, so its distance from a note measures nothing.
    public var centsReadout: String? {
        isUnpitched ? nil : PitchEditorReadout.centsReadout(centsFromNearestNote)
    }
}

// MARK: - The contour

/// One point of the per-frame detected pitch contour, in DATA space.
public struct PitchEditorContourPoint: Sendable, Equatable {
    /// Frame start, SOURCE-FILE seconds.
    public var sourceSeconds: Double
    /// The frame's detected pitch as a fractional midi number.
    public var midi: Double
    /// The detector's confidence at this frame. Voicing evidence only (§5.5.4).
    public var confidence: Double

    public init(sourceSeconds: Double, midi: Double, confidence: Double) {
        self.sourceSeconds = sourceSeconds
        self.midi = midi
        self.confidence = confidence
    }
}

/// One UNBROKEN stretch of the contour — the frames of exactly one detected
/// note, and never a frame from outside it.
///
/// ⛔ **A HOLE IS THE SIGNAL. NEVER BRIDGE ONE** (§5.5.1). The contour is N
/// separate polylines with visible gaps, never one `Path` that `addLine`s
/// across a hole — that would invent pitch where none was measured.
///
/// `id` is the id of the `NoteBlob` this stretch belongs to, so a view can
/// associate a polyline with its blob without a second lookup table.
public struct PitchEditorContourRun: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var points: [PitchEditorContourPoint]

    public init(id: UUID, points: [PitchEditorContourPoint]) {
        self.id = id
        self.points = points
    }
}

// MARK: - The gaps between the notes

/// WHY a stretch of the clip carries no note — §5.5's sixth rule, from
/// `PitchDetection.swift`: *"A stretch of `belowLevel` is a REST; a stretch of
/// `belowConfidence` is WE COULD NOT TELL. Those are different facts and the UI
/// may show them differently, but must not merge them into 'no note'."*
public enum PitchEditorGapKind: String, Sendable, Equatable, CaseIterable {
    /// EVERY frame in the stretch was below the silence floor. There was no
    /// sound to have a pitch.
    case rest
    /// Anything else — the detector heard something and would not commit
    /// (`belowConfidence`), or named a pitch outside its own range
    /// (`outOfRange`), or the stretch mixes reasons.
    case uncertain

    /// Beginner-readable, drawn in the gap.
    public var label: String {
        switch self {
        case .rest: return "No sound here"
        case .uncertain: return "We could not hear a clear note here"
        }
    }
}

/// One unvoiced stretch, in SOURCE-FILE seconds.
///
/// ⚠️ **CLAIMING SILENCE TAKES UNANIMOUS EVIDENCE.** A stretch is a `rest` only
/// when every one of its frames said `belowLevel`. One `belowConfidence` frame
/// in the middle means the detector heard SOMETHING it could not name, and
/// "no sound here" would then be a claim the measurement does not support.
///
/// Every unvoiced stretch is reported, including one-frame ones: filtering by
/// width is a DRAWING decision (a 16 ms gap is sub-pixel at any sane zoom) and
/// inventing a minimum here would be a second threshold nobody measured.
public struct PitchEditorGap: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var startSeconds: Double
    public var endSeconds: Double
    public var kind: PitchEditorGapKind
    public var frameCount: Int

    public init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double,
                kind: PitchEditorGapKind, frameCount: Int) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.kind = kind
        self.frameCount = frameCount
    }

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }
    /// The prose for this gap — `kind.label`, never a merged "no note".
    public var label: String { kind.label }
}

// MARK: - Geometry

/// Every conversion the pitch editor needs, as a pure VALUE.
///
/// A struct, not a method bag on the `@MainActor` model, for the Canvas
/// contract (m16-a): a `@Sendable` renderer closure may capture VALUES only,
/// snapshotted on the main actor before the closure. A crash precedent exists
/// (`docs/research/design-m16a-canvas-crash.md`). Snapshot this whole struct
/// into the draw context and the mapping inside the renderer is the same one
/// the model and the tests use — no inline re-derivation, which is how a
/// surface starts disagreeing with itself.
public struct PitchEditorGeometry: Sendable, Equatable {
    /// `clip.startOffsetSeconds` — where the clip's window starts in the SOURCE
    /// FILE.
    public var sourceWindowStartSeconds: Double

    /// `clip.sourceWindowSeconds(tempoMap:)` — how much SOURCE material the
    /// clip consumes.
    ///
    /// ⚠️⚠️ **THE CLIP'S FULL WINDOW, NOT WHAT DETECTION ANALYSED.**
    /// `ClipPitchDetection.clipWindowDurationSeconds` is this number;
    /// `PitchDetectionResult.windowDurationSeconds` is what was actually
    /// analysed and MAY BE CLAMPED SHORTER. Passing the clamped one silently
    /// changes `stretchRatio` below and skews the entire x-axis — with no
    /// error, no warning, and a screen that looks plausible. Use
    /// `init(clip:tempoMap:…)` and this cannot happen.
    public var sourceWindowSeconds: Double

    /// The clip's span on the project timeline.
    public var startBeat: Double
    public var lengthBeats: Double

    /// For beat↔second. The project's map, not a constant BPM: a tempo change
    /// inside the clip makes source-second→x piecewise, and that is not
    /// optional arithmetic.
    public var tempoMap: TempoMap

    /// Horizontal scale. Fed from the persisted `pitchEditorPPB` slot (§5.8) —
    /// `debug.panelLayout` tier, NOT `view.panelLayout`, which owns only what
    /// determines what a capture can SEE.
    public var pixelsPerBeat: CGFloat

    /// The visible pitch window. `Double` bounds: the view may scroll or
    /// animate to fractional positions. `PitchEditorRange` produces integral
    /// ones so rows line up with ruler keys.
    public var midiRange: ClosedRange<Double>

    /// Pixels per semitone.
    public var rowHeight: CGFloat

    /// `Clip.pitchShiftSemitones` — the whole-clip transpose (m23-ap C-0,
    /// finding F17).
    ///
    /// ⛔ **THE VERTICAL AXIS IS THE PITCH YOU HEAR, SO IT INCLUDES THIS.**
    /// The render's curve SUBSUMES the transpose, so a clip transposed +2 plays
    /// every note two semitones above its stored pitch; a surface that drew
    /// the stored pitch put every blob, every note name and the whole line two
    /// rows off the sound. Rows, names, snap targets and the auto-fit all work
    /// in DRAWN pitch; the drag converts back to a stored offset through
    /// `storedOffsetCents(drawnMidi:centreMidi:clipPitchShiftSemitones:)` and
    /// nothing else.
    ///
    /// ⚠️ Change it through `PitchEditorModel.setClipPitchShiftSemitones` —
    /// the played line is rebuilt there, and a direct write here leaves it on
    /// the old transpose.
    public var clipPitchShiftSemitones: Double

    /// Opens at the piano roll's scale so the two bottom-pane editors feel like
    /// siblings. A second CONSUMER of `PianoRollZoom`'s constants, never a
    /// second home for them.
    public nonisolated static let defaultPixelsPerBeat: CGFloat = PianoRollZoom.defaultPixelsPerBeat
    public nonisolated static let defaultRowHeight: CGFloat = PianoRollZoom.defaultRowHeight

    /// A blob's height as a fraction of its row (§5.6.3) — leaves a visible
    /// gutter between neighbouring semitones.
    public nonisolated static let blobHeightFraction: CGFloat = 0.8

    /// Narrowest a blob is ever DRAWN. A PICK, and a visibility floor only: at
    /// a zoom where a 60 ms note is under a pixel wide, a rect of width 0 is a
    /// detected note the surface silently fails to mention. ⚠️ This widens the
    /// RECT and never the DATA — `blob.startSeconds`/`endSeconds` are
    /// untouched, and `PitchEditorModelTests` pins that.
    public nonisolated static let minimumVisibleBlobWidth: CGFloat = 1.5

    public init(sourceWindowStartSeconds: Double,
                sourceWindowSeconds: Double,
                startBeat: Double,
                lengthBeats: Double,
                tempoMap: TempoMap,
                pixelsPerBeat: CGFloat = PitchEditorGeometry.defaultPixelsPerBeat,
                midiRange: ClosedRange<Double> = PitchEditorRange.fallbackMidiRange,
                rowHeight: CGFloat = PitchEditorGeometry.defaultRowHeight,
                clipPitchShiftSemitones: Double = 0) {
        self.sourceWindowStartSeconds = sourceWindowStartSeconds
        self.sourceWindowSeconds = sourceWindowSeconds
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.tempoMap = tempoMap
        self.pixelsPerBeat = pixelsPerBeat
        self.midiRange = midiRange
        self.rowHeight = rowHeight
        self.clipPitchShiftSemitones = PitchCorrectionMath.finite(clipPitchShiftSemitones, default: 0)
    }

    /// **The blessed construction path.** Derives every geometry term from the
    /// clip itself — its window, its span AND its transpose — so no caller can
    /// pair a window with the wrong length, hand in a clamped detection window
    /// (see `sourceWindowSeconds`), or forget the transpose.
    public init(clip: Clip,
                tempoMap: TempoMap,
                pixelsPerBeat: CGFloat = PitchEditorGeometry.defaultPixelsPerBeat,
                midiRange: ClosedRange<Double> = PitchEditorRange.fallbackMidiRange,
                rowHeight: CGFloat = PitchEditorGeometry.defaultRowHeight) {
        self.init(sourceWindowStartSeconds: clip.startOffsetSeconds,
                  sourceWindowSeconds: clip.sourceWindowSeconds(tempoMap: tempoMap),
                  startBeat: clip.startBeat,
                  lengthBeats: clip.lengthBeats,
                  tempoMap: tempoMap,
                  pixelsPerBeat: pixelsPerBeat,
                  midiRange: midiRange,
                  rowHeight: rowHeight,
                  clipPitchShiftSemitones: clip.pitchShiftSemitones)
    }

    /// The clip's window in the SOURCE file — what the played line is cropped
    /// to. Total: a non-finite or negative span collapses to an empty range.
    public var sourceWindow: Range<Double> {
        let start = sourceWindowStartSeconds.isFinite ? sourceWindowStartSeconds : 0
        let end = sourceWindowSeconds.isFinite && sourceWindowSeconds > 0
            ? start + sourceWindowSeconds : start
        return start..<end
    }

    // MARK: Transpose — stored pitch ↔ drawn pitch (m23-ap C-0)

    /// **THE ONE CONVERSION, FORWARD.** Where a note with a stored offset is
    /// DRAWN: its sung centre, plus its edit, plus the clip's transpose.
    public nonisolated static func drawnMidi(centreMidi: Double, offsetCents: Double,
                                             clipPitchShiftSemitones: Double) -> Double {
        centreMidi + offsetCents / 100 + clipPitchShiftSemitones
    }

    /// vf-18 leg 3 — the forward conversion for a note that may be a FOLLOWED
    /// slide: its sung centre, plus its own edit AND what its neighbours add
    /// (`NoteBlob.followCents`), plus the transpose. ⛔ BRANCH ON PRESENCE,
    /// NEVER `+ 0` (the curve's own law): at `followCents == 0` this is the
    /// three-term conversion above, verbatim, so every note that does not
    /// follow is drawn and dragged bit for bit as before.
    public nonisolated static func drawnMidi(centreMidi: Double, offsetCents: Double,
                                             followCents: Double,
                                             clipPitchShiftSemitones: Double) -> Double {
        if followCents == 0 {
            return drawnMidi(centreMidi: centreMidi, offsetCents: offsetCents,
                             clipPitchShiftSemitones: clipPitchShiftSemitones)
        }
        return centreMidi + (offsetCents + followCents) / 100 + clipPitchShiftSemitones
    }

    /// **THE ONE CONVERSION, BACK** — what a drag landing on drawn pitch
    /// `drawnMidi` stores: `(drawnMidi − clipPitchShiftSemitones − centreMidi)
    /// × 100` cents. ⛔ Drop the transpose term and every drag on a transposed
    /// clip stores a note that plays that many semitones away from where the
    /// user let go; `transposeIsDrawnAndUndrawn` plants exactly that.
    public nonisolated static func storedOffsetCents(drawnMidi: Double, centreMidi: Double,
                                                     clipPitchShiftSemitones: Double) -> Double {
        (drawnMidi - clipPitchShiftSemitones - centreMidi) * 100
    }

    /// vf-18 leg 3 — the way BACK for a note that may be a followed slide:
    /// what its neighbours add (`followCents`) is not the note's own edit, so
    /// it is taken out of the drawn pitch before the offset is stored. During
    /// a lone drag of a slide the neighbours stay put, so `followCents` is
    /// constant and a drag of +D stores +D (natural tuning §4.b.3, kept).
    /// At `followCents == 0` this is the conversion above, verbatim.
    public nonisolated static func storedOffsetCents(drawnMidi: Double, centreMidi: Double,
                                                     followCents: Double,
                                                     clipPitchShiftSemitones: Double) -> Double {
        let stored = storedOffsetCents(drawnMidi: drawnMidi, centreMidi: centreMidi,
                                       clipPitchShiftSemitones: clipPitchShiftSemitones)
        return followCents == 0 ? stored : stored - followCents
    }

    /// Where a note is DRAWN — the pitch it plays at. vf-18 leg 3: a followed
    /// slide's neighbours' contribution included (`NoteBlob.followCents`).
    public func drawnMidi(for blob: NoteBlob) -> Double {
        Self.drawnMidi(centreMidi: blob.centreMidi, offsetCents: blob.offsetCents,
                       followCents: blob.followCents,
                       clipPitchShiftSemitones: clipPitchShiftSemitones)
    }

    /// The name of the note a blob is drawn on — what its label says.
    /// "A LABEL NAMES WHAT THE THING IS NOW": on a transposed clip that is the
    /// transposed note, never the stored one.
    public func drawnNoteName(for blob: NoteBlob) -> String {
        Fundamental.noteName(midiNote: Int(drawnMidi(for: blob).rounded()))
    }

    // MARK: Time — source seconds ↔ project beats ↔ x

    /// How long the clip sounds for, in OUTPUT seconds: the tempo-map integral
    /// over its beat span.
    public var outputSpanSeconds: Double {
        tempoMap.seconds(from: startBeat, to: startBeat + lengthBeats)
    }

    /// `Clip.stretchRatio`, DERIVED rather than carried — it is exactly
    /// `outputSpanSeconds / sourceWindowSeconds` by `sourceWindowSeconds`'
    /// own definition (`Model.swift`), so carrying it too would be a second
    /// home that could disagree with the window it is supposed to describe.
    ///
    /// ⚠️ A degenerate clip (a zero or non-finite window) answers 1 rather
    /// than a NaN: a flat, wrong-but-finite x-axis is recoverable on screen; a
    /// NaN poisons every `Path` in the Canvas.
    public var stretchRatio: Double {
        let span = outputSpanSeconds
        guard span.isFinite, span > 0,
              sourceWindowSeconds.isFinite, sourceWindowSeconds > 0 else { return 1 }
        return span / sourceWindowSeconds
    }

    /// Where a SOURCE-FILE second lands on the project timeline.
    ///
    /// Two terms, both load-bearing: the stretch ratio (source seconds are
    /// consumed `ratio`× faster or slower than output seconds pass) and the
    /// tempo map (output seconds are not beats).
    public func projectBeat(forSourceSecond seconds: Double) -> Double {
        guard seconds.isFinite else { return startBeat }
        let elapsedOutputSeconds = (seconds - sourceWindowStartSeconds) * stretchRatio
        return tempoMap.beat(from: startBeat, elapsedSeconds: elapsedOutputSeconds)
    }

    /// The inverse: which SOURCE-FILE second sounds at a project beat.
    public func sourceSecond(forProjectBeat beat: Double) -> Double {
        guard beat.isFinite else { return sourceWindowStartSeconds }
        let ratio = stretchRatio
        guard ratio > 0 else { return sourceWindowStartSeconds }
        return sourceWindowStartSeconds + tempoMap.seconds(from: startBeat, to: beat) / ratio
    }

    /// Pane-local x for a project beat. x = 0 is the clip's start, which is
    /// also the editor's left edge.
    public func x(forProjectBeat beat: Double) -> CGFloat {
        guard beat.isFinite else { return 0 }
        return CGFloat(beat - startBeat) * pixelsPerBeat
    }

    /// The inverse.
    public func projectBeat(forX x: CGFloat) -> Double {
        guard pixelsPerBeat > 0, x.isFinite else { return startBeat }
        return startBeat + Double(x / pixelsPerBeat)
    }

    /// **CONVERSION 1 OF 2.** Source-file second → pane-local x. Nothing else
    /// in the app may do this arithmetic (see the banner).
    public func x(forSourceSecond seconds: Double) -> CGFloat {
        x(forProjectBeat: projectBeat(forSourceSecond: seconds))
    }

    /// **CONVERSION 2 OF 2.** Pane-local x → source-file second.
    public func sourceSecond(forX x: CGFloat) -> Double {
        sourceSecond(forProjectBeat: projectBeat(forX: x))
    }

    /// The clip's own span in pane-local x.
    public var contentWidth: CGFloat {
        CGFloat(max(0, lengthBeats)) * pixelsPerBeat
    }

    /// True when a project beat sounds inside this clip — the playhead is drawn
    /// only here, and `OffClipEdgeCue` takes over otherwise (§5.6.5).
    /// Half-open, matching the engine's strict `<` window rule.
    public func isInsideClip(projectBeat beat: Double) -> Bool {
        beat >= startBeat && beat < startBeat + lengthBeats
    }

    // MARK: Pitch — midi ↔ y

    /// Top y of the visible window is the TOP EDGE of `midiRange.upperBound`'s
    /// row; y grows downward as pitch falls, so the surface reads like a
    /// keyboard on its side (`PianoRollModel`'s convention).
    ///
    /// The returned y is the row's CENTRE — the line a blob is centred on and
    /// the line a contour point sits at. `rowTopY(forMidi:)` is the row's top
    /// edge, for hairlines and ruler keys.
    ///
    /// ⚠️ **`Double`, NOT `Int`** — the largest single divergence from
    /// `PianoRollModel` (design §3.3.1), and the reason `KeyboardSidebar`
    /// cannot be reused. A pitch contour is continuous; an integer axis would
    /// quantise every measurement to a semitone before it reached the screen.
    public func y(forMidi midi: Double) -> CGFloat {
        guard midi.isFinite else { return 0 }
        return CGFloat(midiRange.upperBound - midi + 0.5) * rowHeight
    }

    /// The inverse, total for any y (above the window answers above the window
    /// — the view clips, the model does not lie about where the pointer is).
    public func midi(forY y: CGFloat) -> Double {
        guard rowHeight > 0, y.isFinite else { return midiRange.upperBound }
        return midiRange.upperBound + 0.5 - Double(y / rowHeight)
    }

    /// Top edge of a semitone's row.
    public func rowTopY(forMidi midi: Double) -> CGFloat {
        y(forMidi: midi) - rowHeight / 2
    }

    /// Full height of the visible window: one row per semitone, plus the half
    /// row above the top pitch and below the bottom one that makes both
    /// end rows whole.
    public var contentHeight: CGFloat {
        CGFloat(midiRange.upperBound - midiRange.lowerBound + 1) * rowHeight
    }

    /// The ruler's keys, TOP DOWN (highest pitch first) so the array's order is
    /// the drawing order. Every key named (§5.6.6).
    public var rulerKeys: [PitchRulerKey] {
        let low = Int(midiRange.lowerBound.rounded(.down))
            .clamped(to: Int(PitchEditorRange.fullMidiRange.lowerBound)
                     ... Int(PitchEditorRange.fullMidiRange.upperBound))
        let high = Int(midiRange.upperBound.rounded(.up))
            .clamped(to: Int(PitchEditorRange.fullMidiRange.lowerBound)
                     ... Int(PitchEditorRange.fullMidiRange.upperBound))
        guard low <= high else { return [] }
        return (low...high).reversed().map { PitchRulerKey(midi: $0) }
    }

    // MARK: Derived draw geometry

    /// Where a blob is drawn. The DATA is untouched — see
    /// `minimumVisibleBlobWidth`.
    ///
    /// ⚠️ **THE DRAWN PITCH — the edit AND the clip's transpose (m23-ap C1,
    /// C-0).** A note the user dragged, a preset moved, or the whole clip was
    /// transposed under is drawn where it now SOUNDS, not where it was sung. At
    /// offset 0 on an untransposed clip that is `centreMidi` exactly, so an
    /// untouched clip draws as the read-only Increment A did. Where it was sung
    /// is the GHOST's job (`ghostRect(for:)`); the line drawn through the blob
    /// is the PLAYED line, which travels with the note.
    public func rect(for blob: NoteBlob) -> CGRect {
        rect(startSeconds: blob.startSeconds, endSeconds: blob.endSeconds,
             centreMidi: drawnMidi(for: blob))
    }

    /// The ghost: the note at its SUNG centre, at its unedited edges, on the
    /// transposed axis (design §4.4).
    ///
    /// ⚠️ **THE TRANSPOSE IS IN THE GHOST, AND THAT IS DELIBERATE.** The ghost
    /// answers "how far did I move THIS note". A whole-clip transpose is not a
    /// per-note edit and has its own control; a ghost drawn at the raw sung
    /// pitch would sit a transpose away from every note on a transposed clip
    /// and put a false edit on each of them.
    public func ghostRect(for blob: NoteBlob) -> CGRect {
        rect(startSeconds: blob.startSeconds, endSeconds: blob.endSeconds,
             centreMidi: blob.centreMidi + clipPitchShiftSemitones)
    }

    /// One run of the PLAYED line as screen points: x from the point's
    /// `editedSeconds` (equal to its source second until C2), y from the pitch
    /// the render plays there (the transpose is already inside it).
    public func points(forPlayed run: [PitchPlayedLine.Point]) -> [CGPoint] {
        run.map {
            CGPoint(x: x(forSourceSecond: $0.editedSeconds), y: y(forMidi: $0.playedMidi))
        }
    }

    /// The same rectangle for an ARBITRARY centre — what a live drag draws at,
    /// from the draft rather than from the stored note (§8.2: the store is not
    /// touched until the gesture ends, so the moving blob cannot come from a
    /// `NoteBlob`).
    public func rect(startSeconds: Double, endSeconds: Double,
                     centreMidi: Double) -> CGRect {
        let left = x(forSourceSecond: startSeconds)
        let right = x(forSourceSecond: endSeconds)
        let width = max(Self.minimumVisibleBlobWidth, right - left)
        let height = rowHeight * Self.blobHeightFraction
        return CGRect(x: left, y: y(forMidi: centreMidi) - height / 2,
                      width: width, height: height)
    }

    /// One contour stretch as screen points, in frame order.
    public func points(for run: PitchEditorContourRun) -> [CGPoint] {
        run.points.map {
            CGPoint(x: x(forSourceSecond: $0.sourceSeconds), y: y(forMidi: $0.midi))
        }
    }
}

// MARK: - What went wrong

/// Why the editor has nothing to draw. Two cases, and keeping them apart is the
/// whole point of §5.7.
public enum PitchEditorFailure: Sendable, Equatable {
    /// `ProjectError.engineUnavailable` — headless, or the engine has no pitch
    /// capability. ⚠️ **Never fabricate a detection** (the `analyzeAudioContent`
    /// precedent): nothing ran, so nothing may be shown as a result.
    case engineUnavailable
    /// Any other refusal, carrying the store's own TEACHING text verbatim
    /// (§5.7: "the store's own teaching error text is shown verbatim").
    case refused(String)

    /// Map a thrown error onto the two cases.
    ///
    /// ⚠️ `ProjectError.engineUnavailable.errorDescription` is
    /// `"audio engine not available"` — developer text, measured 2026-09-22.
    /// That is why this case is MODELLED rather than passed through: §5.7's
    /// novice line lives on `PitchEditorState`, and the raw string never
    /// reaches a user.
    public init(_ error: Error) {
        if let projectError = error as? ProjectError,
           case .engineUnavailable = projectError {
            self = .engineUnavailable
            return
        }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self = .refused(text)
    }
}

// MARK: - The load's own progress

/// What has HAPPENED to this model's detection — a fact about the load, not
/// about the screen. `PitchEditorState` is the screen.
///
/// ⭐ `.notStarted` exists because **a tool that never looked and a tool that
/// looked and found nothing produce the same output.** Folding "nothing has
/// been requested" into "detection returned no notes" is exactly the conflation
/// this project keeps paying for, and it is unrepresentable here.
public enum PitchEditorPhase: Sendable, Equatable {
    /// Nothing has been requested. NOT "found nothing".
    case notStarted
    /// Detection is in flight.
    case detecting
    /// Detection completed and its result was applied. The note count decides
    /// what the screen says, not this case.
    case detected
    /// Detection threw.
    case failed(PitchEditorFailure)
}

// MARK: - The four states this surface must render honestly

/// What the surface SAYS (design §5.7).
///
/// ⛔ **A READ-ONLY VIEW WHOSE EMPTY STATE IS INDISTINGUISHABLE FROM ITS BROKEN
/// STATE IS THE EXACT FAILURE THIS PROJECT KEEPS PAYING FOR.** Every case gets
/// DRAWN PROSE — not a spinner, not silence, not a colour. The strings are
/// `message`, and `PitchEditorModelTests` asserts them BY VALUE: a
/// "non-empty" check passes against a placeholder.
///
/// ⚠️ **SIX CASES, NOT §5.7's FOUR — STATED SO THE DIFFERENCE IS NOT READ AS
/// SCOPE CREEP.** §5.7 tabulates the four DEGENERATE states a novice must be
/// able to tell apart. A total function needs two more: `.ready`, the ordinary
/// case where notes are on screen, and `.idle`, "nobody has asked yet", which
/// is the very distinction §5.7's own warning is about.
public enum PitchEditorState: Sendable, Equatable {
    /// No detection has been requested. ⚠️ **NOT `noNotesFound`.**
    case idle
    /// Detection is running.
    case analysing
    /// Detection found notes and they are on screen. `noteCount` is every
    /// drawn blob; UE-2 — `soundCount` is how many of them are SOUNDS with no
    /// pitch (`NoteOrigin.unpitched`), so the sentence never calls a breath a
    /// note. Defaulted: a table with no sound reads exactly as before.
    case ready(noteCount: Int, soundCount: Int = 0)
    /// Detection ran to completion and found nothing.
    case noNotesFound
    /// The engine could not be asked.
    case engineUnavailable
    /// The store refused, carrying its teaching text.
    case refused(String)

    /// **The total function §12.1 requires.** Two inputs, no impossible
    /// combination: `PitchEditorPhase` cannot be "in flight" and "failed" at
    /// once, and the note count only decides anything once detection completed.
    public nonisolated static func resolve(phase: PitchEditorPhase, noteCount: Int,
                                           soundCount: Int = 0) -> PitchEditorState {
        switch phase {
        case .notStarted: return .idle
        case .detecting: return .analysing
        case .failed(.engineUnavailable): return .engineUnavailable
        case .failed(.refused(let text)): return .refused(text)
        case .detected:
            return noteCount > 0 ? .ready(noteCount: noteCount, soundCount: soundCount) : .noNotesFound
        }
    }

    /// A STABLE machine-readable tag for the echo (`debug.pitchEditor`, §12.4)
    /// and for gates. Additive only — never renamed, the standing wire rule,
    /// even though this is not itself on the wire yet.
    public var statusKey: String {
        switch self {
        case .idle: return "idle"
        case .analysing: return "analysing"
        case .ready: return "ready"
        case .noNotesFound: return "noNotes"
        case .engineUnavailable: return "engineUnavailable"
        case .refused: return "refused"
        }
    }

    /// The DRAWN prose. Beginner-readable — the target user is a novice, and
    /// that is a standing project rule, not this surface's preference.
    ///
    /// Three of these are §5.7's own strings, VERBATIM; `refused` is the
    /// store's text, verbatim; `idle` and `ready` are this item's, written to
    /// the same rule.
    public var message: String {
        switch self {
        case .idle:
            // The honest statement of "nothing has run". It must not be
            // mistakable for `noNotesFound` below, and a test pins that they
            // differ.
            return "We have not listened to this clip yet."
        case .analysing:
            return "Listening to your vocal…"
        case .ready(let count, let sounds) where sounds > 0:
            // ⛔ UE-2 — A SOUND IS NOT COUNTED AS A NOTE. "Found 72 notes."
            // beside "1 sound selected" was measured on a real take (32 of the
            // 72 were breaths and consonants): the words the novice believes
            // called every one of them a sung note.
            let notes = max(0, count - sounds)
            let soundWords = sounds == 1 ? "1 sound with no pitch" : "\(sounds) sounds with no pitch"
            guard notes > 0 else { return "Found \(soundWords)." }
            let noteWords = notes == 1 ? "1 note" : "\(notes) notes"
            return "Found \(noteWords) and \(soundWords)."
        case .ready(let count, _):
            return count == 1 ? "Found 1 note." : "Found \(count) notes."
        case .noNotesFound:
            return "We could not hear any sung notes here. This works best on one voice "
                + "singing on its own — not on drums, chords or a full mix."
        case .engineUnavailable:
            return "The audio engine is not running, so we cannot analyse this clip yet."
        case .refused(let text):
            return text
        }
    }

    /// True only when there is something to draw notes from. The waveform, the
    /// grid and the ruler are drawn in every state — they are honest in all of
    /// them.
    public var drawsNotes: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Increment C — the tools

/// What the palette offers (design §7.2: the frames show a **tool palette**,
/// bottom-mounted, with the pointer highlighted when it is active).
///
/// ⚠️⚠️ **TWO SLOTS, NOT THE NINE THE FRAMES SHOW, AND THAT IS DELIBERATE.**
/// The reference app's palette has nine; seven of them are tools this app does
/// not have. Drawing nine and wiring two would put seven controls on screen
/// that do nothing when pressed — the fake-affordance failure
/// `docs/DESIGN-LANGUAGE.md` Rule 3 names, multiplied by seven. The palette
/// grows a slot when a tool lands, and never before.
public enum PitchEditorTool: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Select and DRAG a note's pitch (C1).
    case pointer
    /// Cut a note in two where you click (C3).
    case scissors
    /// m23-ap C5a-4b — change a note's WOBBLE (vibrato): drag a note up to widen
    /// it, down to smooth it flat, sideways for a faster or slower one; click
    /// the dot at its top centre for one step (design 2026-09-24 vibrato-handle
    /// §4.1, the unpitched design's §4). The slot sits after Split (§4.1); the
    /// Drift (C5a-5) and Shape (C5b) slots are NOT drawn until they work.
    case wobble
    /// W7-NTU U3 — make one note's VOICE deeper or brighter without moving its
    /// pitch (natural tuning §1(f) item 2; R25 names the Formant tool
    /// "Voice"): drag the note down for deeper, up for brighter; ⌥ for finer
    /// steps; double-click to put it back as sung. The slot sits after Wobble,
    /// the order the tools landed in.
    case voice

    public var id: String { rawValue }

    /// SF Symbol. `scissors` is the frames' own glyph for this slot;
    /// `waveform.path` is the reference frames' glyph for the wobble tool (§4.1).
    /// W7-NTU U3 — `mouth` is §1(f) item 2's pick for the Voice slot. The design
    /// asks for it to be checked on macOS 14 (else `person.wave.2`). MEASURED
    /// 2026-10-04 in Apple's own table (CoreGlyphs' `name_availability.plist`):
    /// `mouth` is a 2020 symbol, first in macOS 11.0, so the app's macOS 14
    /// floor has it. (An earlier note here said "SF Symbols 3, macOS 12, from
    /// memory": the memory was one release off.)
    /// `PitchEditorPaletteFitTests.everyGlyphExistsOnTheFloorOS` reads the same
    /// table for every slot; `measuringIsReal` proves only that each loads on
    /// the machine running the tests.
    public var symbolName: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .scissors: return "scissors"
        case .wobble: return "waveform.path"
        case .voice: return "mouth"
        }
    }

    /// The palette's label — one word, for a person.
    public var label: String {
        switch self {
        case .pointer: return "Move"
        case .scissors: return "Split"
        case .wobble: return "Wobble"
        case .voice: return PitchEditorFormantCopy.voiceToolLabel
        }
    }

    /// What it does, written for someone who has never used a tuner.
    /// ⚠️ Drawn, not only hovered: a tooltip is invisible to `view.capture`, so
    /// a captured gate cannot tell a correct caption from a missing one (the
    /// `EQCurveEditor.help` lesson).
    ///
    /// The Wobble tool's help is DERIVED from the one layout constant
    /// (`PitchWobbleGesture.help`, design §4.3 D3), so swapping the axis answer
    /// cannot leave the help lying.
    ///
    /// m23-ap C5b-4b — ⌘-drag DRAWS in the Move and Wobble tools now
    /// (`PitchEditorGestureRouter.commandDraws`), so both helps say so: the
    /// Move help is design §5.6's minus its timing clause (C2's edge drag is
    /// not built, and a help may not name a gesture that does nothing), and
    /// the Wobble help carries its "Hold ⌘ to draw instead." (`drawToolAvailable:
    /// true`: the sentence names a gesture that works, which is what the flag
    /// guards). While ⌘ is held the palette shows the brush's own help instead
    /// (`PitchEditorModel.paletteHelp`).
    public var help: String {
        switch self {
        case .pointer:
            return "Drag a note up or down to change its pitch. Hold ⌘ to draw its line; "
                + "hold ⌥ to move it freely."
        case .scissors: return "Click a note to cut it in two, so you can tune each half on its own."
        case .wobble: return PitchWobbleGesture.help(drawToolAvailable: true)
        // W7-NTU U3 — every word from `PitchEditorFormantCopy`; the ⌘ sentence
        // asks the router's one home, so it can never name a gesture that
        // does nothing here.
        case .voice:
            return PitchEditorFormantCopy.voiceToolHelp(
                drawToolAvailable: PitchEditorGestureRouter.commandDraws(in: .voice))
        }
    }
}

// MARK: - Increment C — the live drag

/// A pitch drag in flight (C1). **Lives in the model, not in a `View`** — §8.2:
/// the store is not written until the gesture ends, so this is the only place
/// the live value exists, and it has to be readable by the readout, the moving
/// blob and any echo.
public struct PitchEditorDragDraft: Sendable, Equatable {
    /// The note being dragged — a `NoteSegment.id`, so the commit and the undo
    /// key need no second lookup.
    public let segmentID: UUID
    public let startSeconds: Double
    public let endSeconds: Double
    /// Where the singer actually was. Never moves.
    public let detectedMidi: Double
    /// The offset the note carried when the drag began — so a second drag
    /// starts from where the first one left it, not from the detected centre.
    public let baselineCents: Double
    /// The live offset, in cents, already snapped and clamped. STORED space:
    /// this is the number the commit writes.
    public internal(set) var offsetCents: Double
    /// ⌥ was held: free movement, no snap.
    public internal(set) var isFree: Bool
    /// The clip's transpose when the drag began (m23-ap C-0) — what turns the
    /// stored offset above into the pitch the note is DRAWN and heard at.
    public let clipPitchShiftSemitones: Double
    /// m23-ap I4 — the OTHER selected notes riding this drag, in table order.
    /// EMPTY for a one-note drag, which is then byte-identical to before I4:
    /// it snaps, clamps and commits (`.notePitch`) exactly as it always did.
    /// Non-empty, every member takes the pressed note's LANDED delta, so the
    /// intervals between the notes are kept (`PitchEditorModel.updatePitchDrag`).
    public internal(set) var members: [PitchEditorDragMember] = []
    /// m23-ap I6b — the laid-out window's TOP (`midiRange.upperBound`) when
    /// this drag began. The press point is a CONTENT y fixed for the gesture's
    /// life, and every row's y counts down from the window's top, so a top that
    /// moves under the drag (a row grown by `growPitchWindowForDrag`, or a
    /// relayout) moves every row by that many rows. `updatePitchDrag` takes the
    /// difference back out: exactly 0, and so bit-identical, while it has not
    /// moved.
    public let windowTopAtPress: Double
    /// m23-ap I6b — whole rows THIS drag grew the window by at its top and at
    /// its bottom (`PitchEditorModel.growPitchWindowForDrag`). Counters for the
    /// echo and for the release's headroom pass; the pointer arithmetic reads
    /// `windowTopAtPress`, never these.
    public internal(set) var topGrowthRows: Int = 0
    public internal(set) var bottomGrowthRows: Int = 0
    /// UE-1 — the PRESSED blob is a sound with no detected pitch
    /// (`NoteBlob.isUnpitched`). Set once by `beginPitchDrag` and fixed for the
    /// gesture's life (a `var` only so the memberwise init can default it). It
    /// decides two things: the drag's snap is RELATIVE — whole semitones from
    /// where the sound sits, ⌥ free — for the whole group
    /// (`PitchEditorModel.updateSoundPitchDrag`), and the readout is §1.7's
    /// sentence, never a number.
    public internal(set) var isUnpitched: Bool = false
    /// vf-18 leg 3 — the PRESSED note's carry `k` in a GROUP drag: the share
    /// of the group's delta its OWN offset takes. 1 for every note, sound and
    /// slide moved without its anchors; `1 − glideFollow` for a followed slide
    /// whose anchors move with it (their move already reaches it through its
    /// bridge). Read ONCE, at the press, from DAWCore's one home
    /// (`PitchEditSet.groupMoveCarries(movingIDs:)`, which reads the rule the
    /// release will store), and fixed for the gesture — the moving set is.
    /// 1 for a one-note drag.
    public internal(set) var carry: Double = 1
    /// vf-18 leg 3 — what the pressed note's neighbours added to where it
    /// played when the drag began, cents (`NoteBlob.followCents`). The drag's
    /// drawn origin includes it, and the one-note drag's drawn → stored
    /// mapping takes it back out: a lone slide's neighbours do not move, so
    /// a drag of +D stores +D.
    public internal(set) var baselineFollowCents: Double = 0
    /// vf-18 leg 3 — the same contribution NOW, read from the draft set each
    /// time the draft changes (`PitchEditorModel.rebuildDraftLine`): in a
    /// group drag a carried slide's anchors move under it, and the blob is
    /// drawn where the draft PLAYS it. A display read, never an input to the
    /// stored offset.
    public internal(set) var followCents: Double = 0

    /// Rows this drag grew the window by, both ends.
    public var grownRows: Int { topGrowthRows + bottomGrowthRows }

    /// Every note this drag moves — the pressed one first, then `members`.
    public var movingSegmentIDs: [UUID] { [segmentID] + members.map(\.segmentID) }

    /// Where the blob is drawn RIGHT NOW — DRAWN pitch, transpose included
    /// (and, vf-18 leg 3, a followed slide's live `followCents`).
    public var targetMidi: Double {
        PitchEditorGeometry.drawnMidi(centreMidi: detectedMidi, offsetCents: offsetCents,
                                      followCents: followCents,
                                      clipPitchShiftSemitones: clipPitchShiftSemitones)
    }

    /// Where the ghost is drawn: the SUNG centre on the transposed axis (see
    /// `PitchEditorGeometry.ghostRect(for:)` for why the transpose is in it).
    public var ghostMidi: Double { detectedMidi + clipPitchShiftSemitones }

    /// How far this gesture has moved the note, cents — the number a person
    /// reads while dragging.
    public var gestureCents: Double { offsetCents - baselineCents }

    /// True when releasing here would change nothing — for a group, when NO
    /// note moved (they all take one delta, so that is "the delta is zero").
    public var isNoOp: Bool {
        offsetCents == baselineCents && members.allSatisfy { $0.offsetCents == $0.baselineCents }
    }

    /// The note the drag is landing on, e.g. "A3".
    public var targetNoteName: String {
        Fundamental.noteName(midiNote: Int(targetMidi.rounded()))
    }

    /// The readout beside the cursor, or `nil` when the move is smaller than
    /// the detector can resolve. ⚠️ **`nil` IS NOT "0 cents"** — a free drag of
    /// three cents is a move nobody can measure, and printing a number for it
    /// would claim a precision this chain does not have (§5.5.3).
    ///
    /// UE-1: a SOUND's readout is §1.7's sentence
    /// (`PitchEditorReadout.unpitchedSound`) for the whole drag, from the press
    /// on — it prints no cents, because it has no pitch to be moved by cents
    /// from, and what a person needs to know before letting go is what moving
    /// it does to the sound.
    ///
    /// vf-18 leg 3: a FOLLOWED slide reads where it is drawn and plays — its
    /// own offset plus what its neighbours add (`followCents`) — so the cents
    /// agree with the note name beside them and with the ghost's distance.
    /// Every other note reads its offset exactly as before (branch on
    /// presence).
    public var readout: String? {
        if isUnpitched { return PitchEditorReadout.unpitchedSound }
        return PitchEditorReadout.centsReadout(followCents == 0 ? offsetCents : offsetCents + followCents)
    }

    /// The label drawn ABOVE the moving blob (`PitchEditorDragOverlay`): the
    /// target note's name and the readout ("A3  +100 cents"), or `nil` when the
    /// readout is `nil`. UE-1: a SOUND's label carries no note name — a note
    /// name over a breath would be a pitch claim, the same one its missing cents
    /// refuse to make. UE-2: and not the whole sentence either, which cannot fit
    /// over a breath (`PitchEditorReadout.unpitchedSoundTag` says why) — the
    /// two-word tag, with the sentence in the palette's readout (`readout`).
    public var overlayLabel: String? {
        if isUnpitched { return PitchEditorReadout.unpitchedSoundTag }
        return readout.map { "\(targetNoteName)  \($0)" }
    }
}

/// One OTHER selected note riding a GROUP pitch drag (m23-ap I4). The pressed
/// note is the drag's own `PitchEditorDragDraft`; this is everyone else.
public struct PitchEditorDragMember: Sendable, Equatable {
    /// The note — a `NoteSegment.id`.
    public let segmentID: UUID
    public let startSeconds: Double
    public let endSeconds: Double
    /// Where the singer actually was. Never moves.
    public let detectedMidi: Double
    /// The offset the note carried when the drag began.
    public let baselineCents: Double
    /// The live offset, in cents — the baseline plus the group's landed delta.
    /// STORED space: the number the commit writes.
    public internal(set) var offsetCents: Double
    /// UE-1 — this member is a sound with no detected pitch
    /// (`NoteBlob.isUnpitched`). It rides the group's one delta like any note
    /// (the PRESSED blob decides the snap, `PitchEditorModel.updatePitchDrag`);
    /// carried so a surface can draw a moving sound as a sound.
    public let isUnpitched: Bool
    /// vf-18 leg 3 — this member's carry `k` (`PitchEditorDragDraft.carry`):
    /// its offset is `baseline + delta·100` at k == 1 (the I4 arithmetic,
    /// verbatim) and `baseline + delta·100·k` below. Fixed at the press.
    public let carry: Double
    /// vf-18 leg 3 — what its neighbours added to where it played at the
    /// press, cents (`NoteBlob.followCents`): part of its drawn origin.
    public let baselineFollowCents: Double
    /// vf-18 leg 3 — the same contribution NOW, from the draft set
    /// (`PitchEditorModel.rebuildDraftLine`): where the draft plays it.
    public internal(set) var followCents: Double

    public init(segmentID: UUID, startSeconds: Double, endSeconds: Double,
                detectedMidi: Double, baselineCents: Double, offsetCents: Double,
                isUnpitched: Bool = false, carry: Double = 1, followCents: Double = 0) {
        self.segmentID = segmentID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.detectedMidi = detectedMidi
        self.baselineCents = baselineCents
        self.offsetCents = offsetCents
        self.isUnpitched = isUnpitched
        self.carry = carry
        self.baselineFollowCents = followCents
        self.followCents = followCents
    }

    /// Where the note is DRAWN right now, on the clip's transposed axis (and,
    /// vf-18 leg 3, a followed slide's live `followCents`).
    public func targetMidi(clipPitchShiftSemitones: Double) -> Double {
        PitchEditorGeometry.drawnMidi(centreMidi: detectedMidi, offsetCents: offsetCents,
                                      followCents: followCents,
                                      clipPitchShiftSemitones: clipPitchShiftSemitones)
    }

    /// vf-18 leg 3 — its drawn pitch when the drag began: the group's clamp
    /// (`groupDeltaBounds`) measures every note's room from here.
    func originMidi(clipPitchShiftSemitones: Double) -> Double {
        PitchEditorGeometry.drawnMidi(centreMidi: detectedMidi, offsetCents: baselineCents,
                                      followCents: baselineFollowCents,
                                      clipPitchShiftSemitones: clipPitchShiftSemitones)
    }

    /// vf-18 leg 3 — the offset this member stores for the group's delta
    /// (drawn semitones): `baseline + delta·100` at k == 1, today's I4
    /// expression VERBATIM (`ue1NotesOnlyDragIsBitIdenticalToTheFrozenArithmetic`
    /// pins it), and `baseline + delta·100·k` for a carried slide — the
    /// expression `PitchEditSet.applyingGroupPitchMove` stores for the same
    /// move, so the release writes what the one transform would.
    func movedOffsetCents(forDelta delta: Double) -> Double {
        let moved = carry == 1 ? baselineCents + delta * 100 : baselineCents + delta * 100 * carry
        return moved.clamped(to: NoteSegment.pitchOffsetCentsRange)
    }

    /// Where its ghost is drawn: the SUNG centre on the transposed axis.
    public func ghostMidi(clipPitchShiftSemitones: Double) -> Double {
        detectedMidi + clipPitchShiftSemitones
    }
}

/// m23-ap C5a-4b — ONE Wobble-tool press in flight, from its first tick to its
/// release: the headless gesture (`PitchWobbleSession`, C5a-4a), where the press
/// came in (the dot or the note), and what the palette's readout slot says.
///
/// ⭐ **LIVES IN THE MODEL, LIKE `PitchEditorDragDraft`**, for that type's
/// reason: the store is not written until the release, so this is the only
/// place the live value exists, and the overlay, the palette and the echo all
/// read it without a store write per tick.
public struct PitchEditorWobbleDraft: Sendable, Equatable {
    /// The pressed note — a `NoteSegment.id`.
    public let segmentID: UUID
    public let startSeconds: Double
    public let endSeconds: Double
    /// The door the press came in by: the dot (a click is one step) or the
    /// note (a click is the house click). Decided at press, never re-decided.
    public let door: PitchWobbleDoor
    /// The knob the press grabbed (`PitchWobbleGesture.knob`): `.both` in the
    /// shipped one-knob layout.
    public let knob: PitchWobbleKnob
    /// The gesture. Fed pointer travel from the moment the press is promoted
    /// past the router's slop, never before, so a click steps or selects from
    /// the STORED note.
    public internal(set) var session: PitchWobbleSession
    /// The press has travelled past `PitchEditorGestureRouter.slop`: it is a
    /// drag, its draft line is live, and its release commits.
    public internal(set) var isDragging: Bool = false
    /// The last pointer travel fed to the session, already mapped by the layout
    /// (`PitchWobbleGesture.travel`), for the echo.
    public internal(set) var travel: PitchWobbleTravel = .zero
    /// ⌥ was held on the last tick (fine control, ÷4 gains).
    public internal(set) var fine: Bool = false
    /// The estimator's reading of the DRAFT's played line (`nil` off the own
    /// branch, or before the first rebuild): what the readout prints for your
    /// wobble (design §9.3: never `keep × depth`).
    public internal(set) var played: PitchWobbleReading?
    /// The line the palette's SF Mono slot draws, verbatim (`session.readout`).
    public internal(set) var readout: PitchWobbleReadout

    /// The edit a release would write: all six fields as the draft holds them
    /// (design §10, "the UI's commit").
    public var edit: NoteVibratoEdit { NoteVibratoEdit(storedIn: session.draft) }
}

/// m23-ap C5b-4b — THE FREEHAND BRUSH'S STROKE IN FLIGHT (design 2026-09-24
/// timing-and-freehand §5.5): the headless stroke (C5b-4a's
/// `PitchShapeStroke`), what its release would write, and what the palette's
/// readout slot says.
///
/// ⭐ **LIVES IN THE MODEL, LIKE `PitchEditorDragDraft`**, for that type's
/// reason: the store is not written until the release, so this is the only
/// place the live value exists, and the overlay, the palette and the echo all
/// read it without a store write per tick.
public struct PitchEditorBrushDraft: Sendable, Equatable {
    /// The note the press began on — a `NoteSegment.id`. A stroke STARTS on a
    /// note (C5b-4a's banner) and may then cross into others.
    public let pressedNoteID: UUID
    /// The stroke: the largest weight and its target per grid sample, the
    /// notes it may write into, and the line as it played BEFORE it.
    public internal(set) var stroke: PitchShapeStroke
    /// ⭐ **WHAT THE RELEASE WRITES, AS OF THE LAST TICK** — `stroke.commit()`,
    /// read ONCE per tick and kept: the draft line is drawn from it
    /// (`PitchEditorModel.draftNotes`) and the release hands it to the store
    /// unchanged (`endBrush`), so what the stroke shows IS what its release
    /// stores. Empty: the stroke changes nothing (yet).
    public internal(set) var shapes: [UUID: NoteShapeSamples]
    /// The palette's SF Mono line, verbatim (`PitchShapeStroke.readout`).
    public internal(set) var readout: String
    /// Where the pointer is, content space: the band's centre.
    public internal(set) var point: CGPoint

    /// The notes the release would write, in a fixed order (ascending
    /// `uuidString`), for the echo and for the view's `onChange`.
    public var touchedNoteIDs: [UUID] { shapes.keys.sorted { $0.uuidString < $1.uuidString } }
}

/// m23-ap C5b-4b — THE BRUSH BAND, as the surface draws it (design §5.5: "A
/// faint band 2R wide follows the pointer while ⌘ is held, showing where a
/// stroke would act"). Resolved by ONE function
/// (`PitchEditorModel.brushBand(at:commandHeld:)`), which the band, the
/// cursor and the palette's help all read, so none of them can promise a
/// stroke the press would not start.
public struct PitchEditorBrushBand: Sendable, Equatable {
    /// The band, content space: `2 × PitchShapeBrush.radiusPoints` wide (the
    /// kernel's whole reach: its weight is 0 at the edges), centred on the
    /// pointer, the surface's full height.
    public let rect: CGRect
    /// The pointer, content space: the band's centre line.
    public let point: CGPoint
    /// A stroke is in flight (the band follows it), rather than ⌘ held over a
    /// note with the button up.
    public let isStroking: Bool
    /// Why a press here would NOT draw, in `PitchShapeStroke.begin`'s own
    /// words (the line is an estimate; the note is a sound), or `nil` when it
    /// would. The band is drawn dim, and the palette's help says this instead.
    public let refusal: String?
}

/// m23-ap C5a-4b — THE DOT, as the surface draws it on a note the Wobble tool can
/// grab (unpitched design §4): where, what its tip says, and what the palette's
/// readout says about that note. Resolved by `PitchEditorModel.wobbleDot(at:)`
/// from the STORED note — the view draws it and the echo reports it, never a
/// re-derivation.
public struct PitchEditorWobbleDot: Sendable, Equatable {
    /// The note it sits on.
    public let segmentID: UUID
    /// The dot's centre, content space: the blob's top centre
    /// (`PitchWobbleGesture.dot(in:)`).
    public let centre: CGPoint
    /// The blob's drawn rect, for the tip's placement.
    public let blobRect: CGRect
    /// The dot's TIP, drawn beside it (the user's own words, unpitched design
    /// §4's table: `PitchWobbleSession.dotTip`).
    public let tip: PitchWobbleReadout
    /// The palette's readout for this note at rest (design §9.2's hover row).
    public let readout: PitchWobbleReadout
    /// Why it is showing: the pointer is over the note or its dot (`hover`), or
    /// a dot click just stepped it (`afterClick`).
    public let reason: Reason

    public enum Reason: String, Sendable, Equatable {
        case hover, afterClick
    }
}

/// m23-ap C5a-4b — one drawn note's two wobble readings, for the
/// `debug.pitchEditor` wobble block (design §12.5's `perNote`): what was SUNG
/// (`PitchWobbleEstimate.sung`, over the render's contour; `nil` without one)
/// and what the committed line PLAYS (`PitchWobbleEstimate.played`).
public struct PitchEditorWobbleNoteReadings: Sendable, Equatable {
    public let segmentID: UUID
    public let sung: PitchWobbleReading?
    public let played: PitchWobbleReading
}

/// m23-ap C5a-4b — the estimator's two readings of each note, kept until the
/// line or the contour they were read from changes. Internal: the model's
/// plumbing, never drawn.
struct PitchEditorWobbleReadingCache: Sendable {
    /// What the readings were read from; any change empties the cache.
    var lineRevision: Int = -1
    var contourAnswered: Bool = false
    /// `PitchWobbleEstimate.sung` per note (`nil` = no `.detected` contour).
    var sung: [Key: PitchWobbleReading?] = [:]
    /// `PitchWobbleEstimate.played` over the committed line, per note.
    var played: [Key: PitchWobbleReading] = [:]

    /// What a reading of one note depends on besides the line and the contour:
    /// which frames it owns (its edges) and what it is read against (its
    /// detected centre).
    struct Key: Hashable, Sendable {
        let id: UUID
        let startSeconds: Double
        let endSeconds: Double
        let detectedHz: Double

        init(_ segment: NoteSegment) {
            id = segment.id
            startSeconds = segment.startSeconds
            endSeconds = segment.endSeconds
            detectedHz = segment.detectedHz
        }
    }

    mutating func sync(lineRevision: Int, contourAnswered: Bool) {
        guard lineRevision != self.lineRevision || contourAnswered != self.contourAnswered else { return }
        self = PitchEditorWobbleReadingCache(lineRevision: lineRevision, contourAnswered: contourAnswered)
    }
}

/// A rubber band in flight on the pitch editor's surface (m23-ap I4) — the
/// roll's `.marquee(origin:base:additive:)` state, held by the MODEL so the
/// band's arithmetic is headless and testable.
public struct PitchEditorBand: Sendable, Equatable {
    /// Where the band began: the press point, frozen at promotion.
    public let origin: CGPoint
    /// The selection when the band armed — FROZEN, so shrinking the band gives
    /// notes back (`PianoRollMarquee.selection`'s rule).
    public let base: Set<UUID>
    /// ⇧ or ⌘ at the press: union onto `base` rather than replace it.
    public let additive: Bool
    /// The band as last drawn, normalized (`PianoRollMarquee.band(from:to:)`).
    public internal(set) var rect: CGRect
    /// The notes it touches right now (`PianoRollMarquee.hits` over
    /// `PitchEditorModel.hitRects()`, the click's own rects).
    public internal(set) var hits: Set<UUID>
}

/// Which edge of the pane an I6b edge step last acted at — the words the
/// `debug.pitchEditor` echo reports (`autoscroll.lastSide`).
public enum PitchEditorEdge: String, Sendable, Equatable {
    case top, bottom, left, right
}

/// What ONE pointer event (or held-pointer tick) near the pane's edge asks the
/// VIEW to do (m23-ap I6b S3), as decided by `PitchEditorModel.edgeStep` —
/// which has ALREADY grown the window when that was the answer. The view only
/// writes the scroll targets; it decides nothing.
public struct PitchEditorEdgeStep: Sendable, Equatable {
    /// A new horizontal offset (a band only), or nil to leave x alone.
    public var scrollX: CGFloat?
    /// A new vertical offset, or nil to leave y alone. After a BOTTOM growth it
    /// is the new content's own `maxOffset`: the row just grown sits under the
    /// viewport's edge until it is revealed, and a writer clamped against the
    /// OLD content could never reach it.
    public var scrollY: CGFloat?
    /// Whole rows the window grew by at this step (a pitch drag at a wall).
    public var grownRows: Int
    /// The edge this step acted at, or nil when it did nothing.
    public var edge: PitchEditorEdge?

    public init(scrollX: CGFloat? = nil, scrollY: CGFloat? = nil, grownRows: Int = 0,
                edge: PitchEditorEdge? = nil) {
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.grownRows = grownRows
        self.edge = edge
    }

    /// Nothing to do: the pointer is in no band, the viewport sits at the wall
    /// with nothing to grow, or the press is not one that pushes.
    public static let none = PitchEditorEdgeStep()
}

// MARK: - Increment C — what a gesture submits

/// ONE store write, emitted on gesture END and never per tick (§8.2 / §11 P7b).
///
/// ⛔⛔ **WHY THE CADENCE IS STRUCTURAL AND NOT A MATTER OF TASTE.**
/// `Clip.pitchEdits` rides `ClipKey.pitchEditSetHash`. A commit per pointer
/// tick would re-key the clip's offline render at pointer rate, and the render
/// would never be ready. What the transport plays meanwhile — ⚠️ CHANGED BY
/// p2-ren Stages A and B (2026-09-25): a clip whose render is pending after an
/// edit that keeps its time base (a note's pitch, level, clear or timing)
/// plays a PREVIEW when one can be built (Stage B, `StretchResolution
/// .provisional`: its last committed render with the changed notes spliced in
/// from a span render; the snapshot's `renderAudible` reads `preview`), else
/// its PREVIOUS version (Stage A, `StretchResolution.bridge`; `previous`). A
/// commit per tick would re-ask for both at pointer rate: the provisional slot
/// is latest-wins, so each tick's build cancels the last before it lands, and
/// the vocal would sound STALE for the whole drag — the edit never heard in
/// context — while a render is started and thrown away per tick. Silence
/// (`StretchResolution.pending`, the clip skipped) is now only for a change
/// that moves the time base (a stretch) or a render that failed; before
/// Stage A it was silence either way, which is what design §11 P7b records
/// (p2-ren design `docs/design/2026-09-25-incremental-note-render.md` §17
/// is the as-built record). `AutomationLaneEditor` commits per
/// tick and is right to: there is no offline render behind an automation
/// lane. That precedent does not transfer, and the design doc records getting
/// this backwards on its first pass.
public struct PitchEditorCommit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// C1 — an ABSOLUTE offset in cents for one note. Absolute, not a
        /// delta: a dropped delta and a delta of zero are indistinguishable.
        case notePitch(segmentID: UUID, offsetCents: Double)
        /// C3 — cut one note in two at a source-file second.
        case splitNote(segmentID: UUID, atSourceSecond: Double)
        /// m23-ap I4 — a GROUP pitch drag: one ABSOLUTE offset per moved note
        /// (the pressed note and every other selected note, in table order),
        /// written in ONE store edit (`ProjectStore.setClipNotePitchOffsets`).
        /// `selectionToken` is the selection's identity at the drag — the
        /// group undo key's token (`PitchCorrectionUndoKey.group`), so a second
        /// drag of the SAME selection coalesces (UI design §8.4). A ONE-note
        /// drag never uses this case: it stays `.notePitch`, byte-identical.
        case notePitches(offsets: [NotePitchOffset], selectionToken: UUID)
        /// m23-ap I7b — CLEAR (`cleared: true`, silence in place) or RESTORE
        /// (`false`) these notes, in ONE store edit
        /// (`ProjectStore.setClipNotesCleared`: one "Clear Notes" / "Restore
        /// Notes" journal entry for all of them). The ids are the notes the
        /// action CHANGES, in table order — the count the menu's title named.
        /// Emitted only by `PitchEditorModel.performNoteAction`, the one action
        /// behind ⌫, Edit ▸ Delete and the right-click menu.
        case notesCleared(segmentIDs: [UUID], cleared: Bool)
        /// m23-ap C5a-4b — ONE note's WOBBLE: a Wobble-tool drag or a dot
        /// click, all six fields ABSOLUTE (design §10, "the UI's commit": what
        /// the draft drew is what it submits), through
        /// `ProjectStore.setClipNoteVibrato` under
        /// `PitchCorrectionUndoKey.vibrato` — so dot clicks on one note inside
        /// the journal's 800 ms window fold into one undo step (T-dot-4).
        case noteVibrato(segmentID: UUID, edit: NoteVibratoEdit)
        /// m23-ap C5a-4b — "Back to how you sang it" (the note menu): these
        /// notes' six wobble fields back to their defaults, ONE undo step under
        /// `structuralKey` (design §10 item 8: a deliberate reset never merges
        /// into the drag before it). Sounds are never named.
        case noteVibratoReset(segmentIDs: [UUID])
        /// m23-ap C5b-4b — the FREEHAND BRUSH: every note ONE stroke drew on,
        /// each with its WHOLE new drawing (`PitchShapeStroke.commit()`), or
        /// `NoteShapeSamples.clear` per note for the note menu's "Reset drawn
        /// shape". ONE `ProjectStore.setClipNoteShapes` call, ONE undo step
        /// ("Draw Pitch" / "Reset Drawn Shape") under `structuralKey`
        /// (`PitchEditorShapeWrite`). Emitted on RELEASE only, never per tick,
        /// and never empty (design §5.3).
        case noteShapes(shapes: [UUID: NoteShapeSamples])
        /// W7-NTU U1 — the header's "Keep voice size" (natural tuning §1(f)):
        /// the clip's `formantCorrection`, 0...1, ONE store call on the
        /// slider's RELEASE (`ProjectStore.setClipFormantCorrection`, "Keep
        /// Voice Size"). Never emitted on a vocal that `predatesNaturalTuning`:
        /// a press there is `.naturalTuningUpdate` (see the model's section).
        case voiceSize(amount: Double)
        /// W7-NTU U1 — "Older tuning. Tap, or change a note, to update." (and a
        /// press on the dim slider): X4's ONE upgrade path,
        /// `ProjectStore.upgradeToNaturalTuning`, ONE undo step ("Update
        /// Tuning").
        case naturalTuningUpdate
        /// W7-NTU U1 — "Consonants" switched on or off
        /// (`ProjectStore.setClipConsonantProtection`, "Keep Consonants").
        case consonants(enabled: Bool)
        /// W7-NTU U1 — one of the four "Slides" steps
        /// (`ProjectStore.setClipPitchTransitionSmoothness`, "Slide
        /// Smoothness"). Always a step's value, never 0 (§4.e).
        case slideSmoothness(centsPerSecond: Double)
        /// W7-NTU U3 — these NOTES' Voice, one FINAL value in semitones for
        /// all of them (0 = as sung; negative deeper, positive brighter), in
        /// ONE store call (`ProjectStore.setClipNoteFormant`, one "Set Note
        /// Voice" undo step; `PitchEditorVoiceWrite`). A Voice drag's release
        /// names its one note; a double-click names it with 0; the note menu's
        /// Voice row names every selected NOTE that changes, in table order.
        /// Never a sound: the store refuses one, and the tool and the menu
        /// never name one.
        case noteFormant(segmentIDs: [UUID], semitones: Double)
    }

    public var kind: Kind
    /// The note table to seed the clip with if it carries none
    /// (`ProjectStore.setClipNotePitchOffset(seedIfAbsent:)`). Always the
    /// editor's own seed; the store ignores it when the clip already has one.
    public var seedIfAbsent: PitchEditSet
}

// MARK: - The model

/// What the pitch editor's detection provider does: a clip id in, a detection
/// out. `ProjectStore.detectClipPitch(clipId:)` IS this shape; the closure
/// exists so the model never holds the store and the suite can drive every
/// path — including the ones a real engine cannot be made to take on demand
/// (the `ClipFixModel` injected-closure precedent).
public typealias PitchEditorDetectionProvider = @MainActor (UUID) async throws -> ClipPitchDetection

/// The pitch editor's SECOND provider (m23-ap C-0, design 2026-09-24 §4.3): a
/// clip id in, THE contour the render uses for it out.
/// `ProjectStore.renderPitchContour(clipId:)` IS this shape. Never throws —
/// every refusal is `PitchRenderContour.unavailable(reason:)`.
public typealias PitchEditorRenderContourProvider = @MainActor (UUID) async -> PitchRenderInputs

/// What has happened to the render-contour fetch — the `PitchEditorPhase`
/// discipline one seam over: **nothing asked, still asking and answered are
/// three different facts**, and "answered `.unavailable`" is not "not asked".
public enum PitchEditorContourPhase: Sendable, Equatable {
    /// Nobody has asked the seam.
    case notStarted
    /// The seam is being asked; the line is an estimate until it answers.
    case fetching
    /// The seam answered — including an honest `.unavailable`.
    case answered(PitchRenderInputs)

    /// The answer, or `nil` while there is none — what `PitchPlayedLine.make`
    /// takes (`nil` there reads as "not answered yet").
    public var contour: PitchRenderContour? {
        if case .answered(let inputs) = self { return inputs.contour }
        return nil
    }
}

/// The ONE sentence the editor shows about its line, and how to show it.
public struct PitchEditorLineCaption: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Still matching the line to the sound — PROGRESS, drawn quietly with
        /// a spinner. ⚠️ Never in `PanelRefusalLine`'s amber: nothing refused,
        /// and a warning over a transient is how a warning stops meaning
        /// anything (docs/DESIGN-LANGUAGE.md, the note editor's state line).
        case progress
        /// The line cannot fully be the sound (another detector generation,
        /// analysis failed, notes with no steady pitch) — a real SHORTFALL,
        /// drawn in `PanelRefusalLine`.
        case shortfall
    }
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The headless model behind the read-only pitch editor (design §5.4).
///
/// **All the math is here and none is in the view** — `EQCurveEditorModel`'s
/// pattern, and not a preference: `DAWApp` has no test target, so
/// `Tests/DAWAppKitTests/` is the only place this geometry can be tested at all.
///
/// **Zero persistence.** `Clip.pitchEdits` is neither read nor written here.
/// The detection lives for the life of the pane and dies with it. ⚠️ Do not
/// "optimise" that by caching into the clip — that is R3 (§4), and it arms the
/// carry trap §2.2 describes.
///
/// **Real-time safety is structural, not careful** (§5.9): `detectClipPitch` →
/// `AudioEngine.detectPitch` → `Task.detached` → a `nonisolated` analyzer. This
/// type is `@MainActor`; nothing in it is reachable from the render thread.
@MainActor
@Observable
public final class PitchEditorModel {
    /// ⚠️ **ID, NEVER TRACK-AND-INDEX** — m23-q condition 4 / F11, so take
    /// lanes work from day one (`TakeLane.clip` IS a `Clip`, addressed by id).
    public let clipID: UUID

    /// Every conversion, as one value. Mutate it to zoom, scroll or re-range;
    /// the derived outputs below follow without re-detecting.
    ///
    /// ⚠️ m23-ap I6c: `midiRange` is LAID OUT by this model (`fittedMidiRange`
    /// grown to fill `availableHeight`). Change the row height through
    /// `setRowHeight(_:)` and report the pane through `setAvailableHeight(_:)`.
    /// A direct write to `geometry.rowHeight` still draws correctly, but the
    /// window is not re-filled until the next layout.
    public var geometry: PitchEditorGeometry

    /// m23-ap I6c: THE NOTES' OWN WINDOW, what `autoFitMidiRange` chose (or
    /// the geometry's opening window before any fit). `geometry.midiRange` is
    /// this grown to fill the pane (`PitchEditorRange.filled`); the pitch window
    /// the editor OPENS at is still exactly this.
    public private(set) var fittedMidiRange: ClosedRange<Double>

    /// m23-ap I6c: the notes the last fit LEFT OFF the window on purpose. The
    /// 36-semitone cap re-centres on the median so that one octave-error
    /// detection cannot drag the window off the singing (`PitchEditorRange`).
    /// Every OTHER drawn note is held on the content whenever the window is
    /// laid out (`PitchEditorRange.holding`). A blanket "hold every note" would
    /// undo that cap the moment the pane was first measured.
    public private(set) var fitOutlierIDs: Set<UUID> = []

    /// m23-ap I6c: the pitch viewport's height as MEASURED by the view (the
    /// vertical scroller's visible height), or 0 before the first layout. It
    /// is 0 in every headless caller, and then nothing is filled.
    public private(set) var availableHeight: CGFloat = 0

    /// What has happened to the load. `state` is what the screen says.
    public private(set) var phase: PitchEditorPhase = .notStarted

    /// One per detected note (§5.4). Geometry-free — a zoom change does not
    /// re-derive these.
    public private(set) var blobs: [NoteBlob] = []

    /// The contour, split at every hole (§5.5.1). Index-for-index with `blobs`.
    public private(set) var contourRuns: [PitchEditorContourRun] = []

    /// The unvoiced stretches, and WHY each one is unvoiced (§5.5's sixth
    /// rule). A rest and a shrug are different facts and this surface is not
    /// allowed to merge them.
    public private(set) var gaps: [PitchEditorGap] = []

    /// The detector's OWN reported frame rate (never a hardcoded 62.5 — the
    /// wire contract says the rate is a property of the backend).
    public private(set) var frameRateHz: Double = 0

    /// How many frames the detection returned, voiced or not — the denominator
    /// behind "we looked at this much".
    public private(set) var analysedFrameCount: Int = 0

    // MARK: C-0 — the line the render will play

    /// The editor's own WINDOW detection, kept whole: the note table's seed,
    /// and the sung line whenever the seam has no frames (the estimate).
    public private(set) var fallbackDetection: PitchDetectionResult?

    /// What the seam has answered, if anything. See `PitchEditorContourPhase`.
    public private(set) var contourPhase: PitchEditorContourPhase = .notStarted

    /// ⭐ **THE LINE THE EDITOR DRAWS: what the render will PLAY** — the
    /// render's own contour through the render's own curve, for the note table
    /// as it is COMMITTED (`noteTable`). Rebuilt on every change of table,
    /// transpose, contour or detection, and cached here so a zoom or a redraw
    /// never rebuilds it. `PitchEditorDisplayMatchesRenderTests` holds its
    /// `curve` equal to the render's.
    public private(set) var playedLine: PitchPlayedLine =
        PitchPlayedLine.make(contour: nil, fallback: nil, editSet: nil,
                             clipPitchShiftSemitones: 0, sourceWindow: 0..<0)

    /// ⭐ m23-ap I7b → I7b-2 — **THE LINE AS DRAWN IS THE LINE AS MADE.** The
    /// line means "what the render will play", and a cleared note plays
    /// silence (`PitchEditSet.gain(atSourceSecond:)` is 0 between its ramps).
    /// `PitchPlayedLine.make` — the ONE producer, which the wire verb
    /// `clip.getPlayedPitch` returns too — already leaves a hole over every
    /// cleared note, so this reads `playedLine` and filters nothing of its
    /// own. Every surface reader (the committed segments, the echo's
    /// `perNote`) reads this name; the drag's draft line is built by the same
    /// `make` from a table carrying the same clears.
    ///
    /// ⛔ I7b first filtered here, on the finished line, while `make` ignored
    /// the flag — two producers that disagreed, so the editor hid a stretch the
    /// wire still reported as pitch. Do not bring a second filter back.
    public var visiblePlayedLine: PitchPlayedLine { playedLine }

    /// The same line with the live DRAG applied, or `nil` when nothing is being
    /// dragged. **A VALUE COPY, NEVER A COMMIT** (design §4.4, F5): the note
    /// table is copied with the dragged note's offset set to the draft, passed
    /// through the same `PitchPlayedLine.make`, and nothing reaches the store
    /// until release.
    public private(set) var draftPlayedLine: PitchPlayedLine?

    /// The note table `draftPlayedLine` was last built from, or `nil` when no
    /// drag is in flight — the draft line's INPUT, kept so a test can read what
    /// the line was drawn through (NT-U0). `@ObservationIgnored`: nothing draws
    /// it; the line itself is what the surface watches.
    @ObservationIgnored public private(set) var draftEditSet: PitchEditSet?

    /// Bumped on every rebuild of `playedLine` — what a view watches instead of
    /// comparing ~16 000 points with `==` on every body evaluation.
    public private(set) var playedLineRevision: Int = 0

    /// Bumped on every rebuild of `draftPlayedLine`.
    public private(set) var draftLineRevision: Int = 0

    // MARK: Increment C — the interaction state

    /// The editor's own note table, minted from the detection and NEVER
    /// written to the store by itself. See `syncStoredNoteTable`.
    public private(set) var seedTable: PitchEditSet = .empty

    /// The clip's stored table, as last handed in by the view.
    public private(set) var storedTable: PitchEditSet?

    /// Which tool the palette has engaged (§7.2: the frames show a PALETTE,
    /// not one contextual tool).
    public var tool: PitchEditorTool = .pointer

    /// What a snapped drag lands on (§7.3 C1: "snap to the scale; ⌥ for free").
    ///
    /// ⚠️ **CHROMATIC IS NOT A PLACEHOLDER, IT IS THE HONEST DEFAULT.** This
    /// app has no project key — there is no `keySignature` anywhere in
    /// `DAWCore.Model` — so any other default would be a key the app invented
    /// for the user. Chromatic snapping means "the nearest semitone", which is
    /// what a person dragging a note expects before they have told anyone what
    /// key they are in. The frames show a `C#` chip next to the grid chip;
    /// **that chip is NOT built** (§7.2 records what is seen, not what is
    /// owed), and this property is where it will write when it is.
    public var snapScale: PitchCorrectionScale = .chromatic

    /// The live drag, or `nil`. ⭐ **THE WHOLE POINT OF §8.2 LIVES HERE**: this
    /// is `@Observable` state in `DAWAppKit`, so the readout, the moving blob
    /// and any echo can all watch a drag WITHOUT the store being touched once
    /// per pointer tick. `PianoRollView`'s draft is `@State private` inside a
    /// `View` and cannot be read from anywhere else, which is why its precedent
    /// looks the same and is not.
    public private(set) var drag: PitchEditorDragDraft?

    /// m23-ap C5a-4b — the Wobble-tool press in flight, or `nil`: the dot or the
    /// note it came in by, its headless session, and the readout the palette
    /// draws. Observable for `drag`'s reason (the overlay, the palette and the
    /// echo watch it, and the store is written only at the release).
    public private(set) var wobble: PitchEditorWobbleDraft?

    /// m23-ap C5a-4b — the note whose dot TIP shows after a dot click
    /// (unpitched design §4: "shows on hover and after each click"), until the
    /// next press, a tool switch or the pane's rebuild. Its words are re-read
    /// from the STORED note every time they are drawn, so they say what the
    /// store kept, not what the click asked for.
    public private(set) var wobbleTipNoteID: UUID?

    /// D4-1 #2 — `draftReach`'s memo: the line revision it was read at, and
    /// each draft note's reach. Plumbing, never drawn.
    @ObservationIgnored private var draftReachCache: (revision: Int, reaches: [UUID: ClosedRange<Double>])
        = (-1, [:])

    /// m23-ap C5b-4b — the brush stroke in flight, or `nil`: begun when a
    /// `.brush` press crosses the slop, gone at its release, its Escape, or a
    /// new press. Observable for `drag`'s reason (the overlay, the palette and
    /// the echo watch it, and the store is written only at the release).
    public private(set) var brush: PitchEditorBrushDraft?

    /// W7-NTU U3 — the Voice-tool press in flight, or `nil`: begun on the
    /// FIRST tick of a `.formantDrag` press (a sound is refused there), fed
    /// travel once the press is past the slop, and gone at its release, its
    /// Escape, or a new press. Observable for `drag`'s reason: the surface's
    /// bar and chip, the palette and the echo watch it, and the store is
    /// written only at the release.
    public private(set) var voiceDrag: PitchEditorVoiceDraft?

    /// m23-ap C5a-4b — the estimator's readings per note, cached against the
    /// line they were read from (`playedLineRevision`) and the render contour
    /// (`contourPhase`), so hovering from note to note costs one pass per note
    /// per line rebuild, never one per pointer move. Plumbing, not state.
    @ObservationIgnored private var wobbleReadings = PitchEditorWobbleReadingCache()

    /// m23-ap I6b — the fraction of a row the window has earned towards its
    /// next grown row (`growPitchWindowForDrag`). GROWTH STATE, reset per press
    /// in `beginPitchDrag` and zeroed at 0/127 so a pause at the limit banks
    /// nothing — never pointer integration: the pointer's own position is
    /// recomputed from what is observed, every tick (`EdgeAutoScroll.tick`).
    /// `@ObservationIgnored`: nothing draws it.
    @ObservationIgnored private var growthRemainder: Double = 0

    /// The last refusal this surface produced, in words for a person, or `nil`.
    /// A tool that refused and a tool that did nothing must not look the same.
    public private(set) var refusal: String?

    /// W7-NTU §1(f) item 4 — the notes the last pitch drag COMMITTED, for the
    /// far-move hint (`farMoveHint(formantPreserve:)`), in table order. Set
    /// only when a pitch drag emits its commit; emptied by the next press of
    /// any kind and by a clip switch. It names notes, never distances: how far
    /// each sits is read from the stored table when the hint is asked.
    public private(set) var farMoveNoteIDs: [UUID] = []

    /// UE-1 — the line about the last "Find sounds with no pitch" press
    /// (`PitchEditorFindSounds`): working while the pitch is read, then the
    /// answer in words — sounds added, none to add, or why nothing was added.
    /// `nil` before any press. It outlives the answer on purpose (the sounds it
    /// names are on screen), until the next press or the pane's rebuild.
    ///
    /// UE-2 — with two exceptions, both in `syncStoredNoteTable`:
    ///  • **"Added N sounds" is WITHDRAWN when the table no longer holds a
    ///    sound** (the merge was undone): the line would name sounds that are
    ///    gone, beside the button that is back — **and when the table is
    ///    REBUILT under it** (a preset pass: every segment gets a new id, so the
    ///    sounds it named are gone even though new ones are drawn, and "Undo
    ///    takes them away" would undo the preset). Keyed on the added sounds'
    ///    ids (`findSoundsAddedIDs`), so a pitch drag, a level change or a
    ///    note's split keeps it.
    ///  • **A finder's DECLINE outlives the pane** through `findSoundsMemory`
    ///    (app-held), so a pane rebuilt on the same table shows the same
    ///    button WITH the reason it declined, instead of a bare button that
    ///    looks as if it was never pressed.
    public private(set) var findSoundsLine: PitchEditorFindSoundsLine?

    /// UE-2 — how many sounds the last finished press ADDED (0 for none, a
    /// decline or a refusal): what makes an "Added" line withdrawable on undo
    /// without parsing its words. Nothing draws it.
    @ObservationIgnored private var findSoundsAdded = 0

    /// UE-2 edge — the ids of the sounds an "Added" line names, taken from the
    /// merge's OWN write (`nil` until that write has reached this pane: the
    /// answer and the table can arrive in either order). The merge never moves
    /// or re-identifies a segment (`ProjectStore.findUnpitchedSounds`), so these
    /// ids stay in the table until something REBUILDS it — a preset pass mints
    /// new ones — and then "Undo takes them away" would point at that rebuild.
    @ObservationIgnored private var findSoundsAddedIDs: Set<UUID>?

    /// UE-2 — the app-held memory of each clip's last Find-sounds DECLINE
    /// (`PitchEditorInteractionBridge.findSoundsMemory`), installed once by the
    /// view. `nil` (a preview, a test that does not ask) remembers nothing.
    @ObservationIgnored public var findSoundsMemory: PitchEditorFindSoundsMemory?

    // MARK: I4 — the selection (interaction batch §7)

    /// The selected notes, by `NoteSegment.id` (m23-ap I4). The user's words:
    /// "when I select segment, it should stay selected and I should also be able
    /// to do mutiselect with mouse clicking or drawing rectangle, select all,
    /// basically the same functionality we have in note editor".
    ///
    /// ⭐ **THE RULES ARE THE ROLL'S; THE SET IS THIS MODEL'S** (design §7, the
    /// house ruling F12). The click table is `PianoRollGridPress` (through I0's
    /// router), the band arithmetic is `PianoRollMarquee.selection`, the chord is
    /// `ArrangeClickIntent` — none re-spelled here. Only ids of DRAWN notes are
    /// ever held: every table sync prunes to them (`reconcileSelection`), the
    /// roll's `survivors` rule.
    ///
    /// ⚠️ **SELECTING IS NOT EDITING.** Nothing here reaches `emit`: a
    /// selection change is never journalled and never re-keys a render.
    public private(set) var selection: Set<UUID> = []

    /// The selection's IDENTITY — re-minted on every CHANGE of `selection`, and
    /// never otherwise (`setSelection` compares first). It is the group undo
    /// key's token (`PitchCorrectionUndoKey.group`, UI design §8.4): a second
    /// drag of the SAME selection coalesces into the first, a drag of a
    /// DIFFERENT one does not. A re-mint on a no-change write would make "the
    /// same selection" unobservable, so the comparison is the rule.
    public private(set) var selectionToken = UUID()

    /// The rubber band in flight, or `nil` — promoted out of an empty-surface
    /// press that travelled past the slop (I0's `.band` kind).
    public private(set) var band: PitchEditorBand?

    /// vf-19 — the SOUNDS (`NoteBlob.isUnpitched`) that are selected ONLY
    /// because Select All took every drawn blob. A group pitch drag leaves
    /// them where they are (`beginSelectionPitchDrag`): a sound keeps its own
    /// pitch unless the user picks it (natural tuning R21: "a sound the user
    /// drags on purpose still moves"). Select All still SELECTS them, so
    /// "Clear Selected Sounds" (UE-2) reads exactly as before.
    ///
    /// A sound leaves this set the moment the user chooses it: a ⇧/⌘ click
    /// (`toggle`), a band that touches it, or a press on it. A plain click
    /// and Deselect empty it. A table sync only PRUNES it, like the selection
    /// (`reconcileSelection`), so a second drag after one Select All still
    /// leaves the sounds. Not observed: nothing draws it.
    @ObservationIgnored private var soundsSelectedOnlyByAll: Set<UUID> = []
    /// `soundsSelectedOnlyByAll` when the live band armed, so a band gives
    /// back exactly what it found, as the selection's frozen `base` does.
    @ObservationIgnored private var soundsSelectedOnlyByAllAtBandArm: Set<UUID> = []

    /// ⭐ **THE COMMIT SEAM, AND THE SPY GATE'S HOME.** Set once by the view;
    /// the model is the ONLY thing that calls it. Every commit this surface
    /// makes goes through here and is counted, so a test can assert that forty
    /// pointer ticks produced ZERO store writes — which no source-shape gate
    /// over a `DragGesture` can honestly claim.
    ///
    /// `@ObservationIgnored`: a closure the view installs is plumbing, not
    /// state, and observing it would invalidate every reader when the pane
    /// remounts.
    @ObservationIgnored public var onCommit: ((PitchEditorCommit) -> Void)?

    /// How many commits this model has emitted, ever. Counted, never reasoned
    /// about — the `PitchEditorChromeLedger.ticks` discipline.
    public private(set) var commitCount: Int = 0

    /// The last commit emitted, verbatim. Read by the suite so a gate asserts
    /// the CONTENTS of a write rather than that a call returned.
    public private(set) var lastCommit: PitchEditorCommit?

    /// ⭐ **THE AUDITION SEAM — `onCommit`'s twin, and ITS spy gate's home**
    /// (m23-ap I1 UI hooks). Set once by the view; the model is the ONLY thing
    /// that calls it, and it calls it on exactly four events:
    ///
    ///  * a PRESS on a note — the first tick of a `.noteDrag` press, so a click
    ///    is heard at mouse-down, the roll's first-tick sound (design §4);
    ///  * a DRAG STEP — each change of the draft's OFFSET, never a pointer tick:
    ///    a snapped drag moving inside one scale step asks for nothing;
    ///  * ESCAPE — a stop, then the ladder's own rung (`handleEscapeKey`);
    ///  * the pane going away or the switch turning off — a stop
    ///    (`stopAudition`).
    ///
    /// The RELEASE audition is not here: it follows the commit, and only the
    /// app knows the commit landed (`PitchEditorAuditionRouter.commitLanded`).
    /// Nothing here reads the audition switch either — the router passes it to
    /// the store's doors at the call site, so a gate over this seam counts
    /// gestures and the router's own gate counts the switch.
    ///
    /// `@ObservationIgnored` for `onCommit`'s reason: plumbing, not state.
    @ObservationIgnored public var onAudition: ((PitchEditorAuditionRequest) -> Void)?

    /// ⭐ **THE SEEK SEAM — `onCommit`'s other twin** (m23-ap I5). Set once by the
    /// view; the model is the ONLY caller, and it calls it from exactly two
    /// places: the time ruler's ticks (`placePlayhead`, one seek per tick) and a
    /// ⌘-click on empty surface (`releasePress`, one seek per click). It carries
    /// a PROJECT beat, snapped and clamped by `placementBeat` — the view never
    /// computes one. The app installs `store.seek(toBeats:)` here.
    ///
    /// `@ObservationIgnored` for `onCommit`'s reason: plumbing, not state.
    @ObservationIgnored public var onSeek: ((Double) -> Void)?

    /// m23-ap I5 — the app's snap IN FORCE (`AppModel.effectiveClipSnap`, the
    /// roll's own input), which decides only ON or OFF here: the division the
    /// playhead lands on is this pane's own `placementGrid`. Any value but
    /// `.off` snaps. Plain state, not observed by anything that draws; the view
    /// keeps it current as the app's snap changes.
    @ObservationIgnored public var appSnap: ClipSnap = .beat

    /// What the drag in flight last ASKED TO HEAR, note by note, or nil before
    /// its first step — then what is sounding is the press: every moving note
    /// at its baseline. Reset by `beginPitchDrag`. See `requestDragAudition`.
    @ObservationIgnored private var dragAuditionHeard: [UUID: Double]?

    /// Bumped by every `load` and every `reset`. A result whose token is stale
    /// is DROPPED: a detection that finished after the pane moved on must never
    /// paint, and "it painted something plausible" is this tree's
    /// characteristic failure.
    ///
    /// ⭐ **`@ObservationIgnored` (p2-b): THIS IS NOT VIEW STATE.** It is a
    /// race token, and every `load` bumps it — so without the annotation,
    /// starting a detection would invalidate every observer of this model for a
    /// value no view reads, on top of the `phase` change that is the real
    /// signal. The `AppModel.keyDownMonitor` / `contentWindow` precedent: the
    /// backing of a mechanism is shielded, the observed state is not.
    @ObservationIgnored private var loadGeneration: Int = 0

    /// The render-contour fetch's OWN race token (m23-ap C-0).
    ///
    /// ⚠️ **NOT `loadGeneration`, THOUGH §4.3 NAMES THAT ONE — AND THE REASON
    /// IS THE LOAD ORDER ITSELF.** The two fetches run IN PARALLEL (§4.3 steps
    /// 1–2), and `load` bumps `loadGeneration` when it starts. Sharing the
    /// token would let the detection that starts a moment after the contour
    /// fetch invalidate it, and the seam's answer would be dropped every time
    /// the pane opened. `reset()` bumps both, which is the "a late answer never
    /// paints" guarantee §4.3 step 5 asks for.
    @ObservationIgnored private var contourGeneration: Int = 0

    public init(clipID: UUID, geometry: PitchEditorGeometry) {
        self.clipID = clipID
        self.geometry = geometry
        self.fittedMidiRange = geometry.midiRange
    }

    // MARK: Derived state

    /// What the surface says — §5.7, resolved at ONE home so the echo, the
    /// header and any gate all read the SAME string the view drew.
    public var state: PitchEditorState {
        PitchEditorState.resolve(phase: phase, noteCount: blobs.count,
                                 soundCount: blobs.count { $0.isUnpitched })
    }

    /// The DETECTED contour as screen polylines — one per detected run, **never
    /// one path across a hole** (§5.5.1). Re-derived from `geometry` on read,
    /// so a zoom change needs no re-detection.
    ///
    /// ⚠️ **NOT WHAT THE EDITOR DRAWS SINCE C-0** — the surface draws
    /// `playedLineSegments(excluding:)`, the line the render plays. This is
    /// the measurement (what the singer did, frame STARTS, no transpose), kept
    /// for the suite and for any surface that means to show the measurement.
    ///
    /// ⚠️ **NO SMOOTHING** (§5.5.2). SwiftF0's argmax over 256 log-spaced bins
    /// is 25.79 cents wide, so the line has a visible staircase. That staircase
    /// is the instrument's real resolution; smoothing it draws a precision the
    /// detector does not have.
    public var contourSegments: [[CGPoint]] {
        contourRuns.map { geometry.points(for: $0) }
    }

    /// The pitch ruler's keys, top down.
    public var rulerKeys: [PitchRulerKey] { geometry.rulerKeys }

    /// Where a blob is drawn.
    public func rect(for blob: NoteBlob) -> CGRect { geometry.rect(for: blob) }

    // MARK: C-0 — the played line on screen

    /// The PLAYED line as screen polylines, one per voiced run — what the
    /// surface strokes. When `excluding` is given (a drag is in flight), every
    /// point whose edited second falls inside it is left out and the run is
    /// SPLIT there: those points are the draft's to draw
    /// (`draftLineSegments`), so the committed line never shows a wobble left
    /// behind on the old row while the note moves.
    ///
    /// O(points). The view calls it on a line rebuild, a zoom, and the start
    /// and end of a drag — never per pointer tick.
    public func playedLineSegments(excluding span: ClosedRange<Double>? = nil) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        out.reserveCapacity(visiblePlayedLine.runs.count)
        // I7b-2 — a cleared note's stretch is already a hole, made by `make`.
        for run in visiblePlayedLine.runs {
            guard let span else {
                out.append(geometry.points(forPlayed: run))
                continue
            }
            var before: [PitchPlayedLine.Point] = []
            var after: [PitchPlayedLine.Point] = []
            for point in run {
                if point.editedSeconds < span.lowerBound {
                    before.append(point)
                } else if point.editedSeconds > span.upperBound {
                    after.append(point)
                }
            }
            if !before.isEmpty { out.append(geometry.points(forPlayed: before)) }
            if !after.isEmpty { out.append(geometry.points(forPlayed: after)) }
        }
        return out
    }

    /// The source-second span a live edit of the FIRST draft note can change:
    /// DAWCore's ONE rule, `PitchEditSet.pitchDragReach(ofSegmentAt:)`, asked
    /// of the committed table (`draftReach`). Outside it the draft and the
    /// committed line are the same numbers, so the surface keeps drawing the
    /// committed line there and the overlay draws the draft inside it. `nil`
    /// with nothing in flight.
    ///
    /// ⭐ D4-1 #2 (natural tuning, the user's ruling (b); orchestrator's scope
    /// addition to C5b-4b, 2026-09-27) — **ASKED, NOT RESTATED.** This used to
    /// restate the reach itself — the note widened by half the retune ramp —
    /// which is right for a later edit of a legacy set and WRONG for the FIRST
    /// hand edit of a vocal that predates natural tuning: that release updates
    /// the WHOLE vocal (`afterHandEdit(from:)`), so the draft line differs from the
    /// committed one everywhere, and a window narrower than the vocal left the
    /// rest of the line stale until the release. `pitchDragReach` returns the
    /// whole vocal's span then, and on a set with soft joins the note's own
    /// soft reach (its neighbours across a soft join included).
    ///
    /// m23-ap C5a-4b — a WOBBLE drag's note, and C5b-4b — each note a brush
    /// STROKE draws on: the same reach, one home ("Do not invent a second
    /// span", design §9.3). CONSERVATIVE by DAWCore's own doc: a wider window
    /// only redraws more of a line that is correct everywhere.
    public var draftSpan: ClosedRange<Double>? {
        guard let first = draftNotes.first else { return nil }
        return draftReach(of: first.segmentID, startSeconds: first.startSeconds,
                          endSeconds: first.endSeconds)
    }

    /// `PitchEditSet.pitchDragReach(ofSegmentAt:)` for note `id` on the
    /// committed table, MEMOISED per line revision: every change of the table
    /// rebuilds the line and bumps `playedLineRevision` (`apply`,
    /// `syncStoredNoteTable`, `clearDetection`), so a cached reach can never
    /// outlive the table it was read from, and a pointer tick costs a
    /// dictionary read instead of `afterHandEdit()`'s whole-set transform per
    /// moving note. A note the table does not hold (a stranded draft) keeps
    /// the rule from before NT-U2 — its span widened by half the retune — so
    /// the window never vanishes mid-gesture.
    private func draftReach(of id: UUID, startSeconds: Double, endSeconds: Double) -> ClosedRange<Double> {
        if draftReachCache.revision != playedLineRevision {
            draftReachCache = (playedLineRevision, [:])
        }
        if let cached = draftReachCache.reaches[id] { return cached }
        let table = noteTable
        let reach: ClosedRange<Double>
        if let index = table.segments.firstIndex(where: { $0.id == id }),
           let asked = table.pitchDragReach(ofSegmentAt: index) {
            reach = asked
        } else {
            let half = max(0, table.retuneMs / 1000 / 2)
            reach = (startSeconds - half)...(endSeconds + half)
        }
        draftReachCache.reaches[id] = reach
        return reach
    }

    /// ⭐ m23-ap C5a-4b — **EVERY NOTE THE LIVE GESTURE CHANGES, AND HOW**: the
    /// pitch drag's pressed note then its members, or the wobble drag's note —
    /// each with its span and its `PitchEditorDraftEdit`. THE one list the
    /// draft line (`rebuildDraftLine`) and its spans (`draftSpan`,
    /// `draftSpans`) are built from, so a new tool adds a producer here and
    /// never a second draft path. Empty with nothing in flight. A wobble press
    /// joins only once it is a DRAG: a dot click never draws a draft.
    ///
    /// m23-ap C5b-4b — or the brush STROKE's notes: every note its release
    /// would write (`PitchEditorBrushDraft.shapes`, the value the release
    /// commits), in table order, each `.shape` with its own span.
    private var draftNotes: [(segmentID: UUID, startSeconds: Double, endSeconds: Double,
                              edit: PitchEditorDraftEdit)] {
        if let brush {
            guard !brush.shapes.isEmpty else { return [] }
            return noteTable.segments.compactMap { note in
                brush.shapes[note.id].map { (note.id, note.startSeconds, note.endSeconds, .shape($0)) }
            }
        }
        if let draft = drag {
            return [(draft.segmentID, draft.startSeconds, draft.endSeconds,
                     .pitch(offsetCents: draft.offsetCents))]
                + draft.members.map {
                    ($0.segmentID, $0.startSeconds, $0.endSeconds, .pitch(offsetCents: $0.offsetCents))
                }
        }
        if let wobble, wobble.isDragging {
            return [(wobble.segmentID, wobble.startSeconds, wobble.endSeconds,
                     wobbleDraftEdit(wobble))]
        }
        return []
    }

    /// The draft edit a wobble gesture draws: all six fields as its session's
    /// draft holds them, at the clip's ratio — what its release commits
    /// (`endWobbleDrag`: the same `edit`) and so what the store writes.
    private func wobbleDraftEdit(_ wobble: PitchEditorWobbleDraft) -> PitchEditorDraftEdit {
        .wobble(wobble.edit, stretchRatio: geometry.stretchRatio)
    }

    /// m23-ap I4 — EVERY moving note's reach, asked like `draftSpan`, merged
    /// where they overlap and sorted: what a GROUP drag's line owns while the
    /// pointer is down. For a one-note drag this is `[draftSpan]` exactly, so
    /// nothing a one-note drag draws changed. Empty with no drag.
    public var draftSpans: [ClosedRange<Double>] {
        let notes = draftNotes
        guard let first = draftSpan else { return [] }
        guard notes.count > 1 else { return [first] }
        // D4-1 #2 — each moving note's reach from the SAME memoised DAWCore
        // rule as `draftSpan` (never a second restatement of it).
        let spans = notes.map {
            draftReach(of: $0.segmentID, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds)
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// The PLAYED line with EVERY span in `spans` left out (m23-ap I4) — the
    /// group drag's twin of `playedLineSegments(excluding:)`, which it calls
    /// VERBATIM for zero or one span so a one-note drag draws exactly what it
    /// did. With several spans a run is split at each one: every point inside
    /// any span is the draft's to draw.
    public func playedLineSegments(excludingAll spans: [ClosedRange<Double>]) -> [[CGPoint]] {
        guard spans.count > 1 else { return playedLineSegments(excluding: spans.first) }
        var out: [[CGPoint]] = []
        // I7b-2 — a cleared note's stretch is already a hole, made by `make`.
        for run in visiblePlayedLine.runs {
            var piece: [PitchPlayedLine.Point] = []
            for point in run {
                if spans.contains(where: { $0.contains(point.editedSeconds) }) {
                    if !piece.isEmpty { out.append(geometry.points(forPlayed: piece)) }
                    piece = []
                } else {
                    piece.append(point)
                }
            }
            if !piece.isEmpty { out.append(geometry.points(forPlayed: piece)) }
        }
        return out
    }

    /// The DRAFT line inside `draftSpan`, as screen polylines — the part of
    /// the line that moves with the pointer. Each piece is extended by ONE
    /// point on each side from the same run (never across a hole), which is
    /// exactly the point the committed line's cut stops at, so the two draw as
    /// one unbroken line. Empty with no drag.
    public var draftLineSegments: [[CGPoint]] {
        guard let line = draftPlayedLine else { return [] }
        // I4 — one pass per moving span (a one-note drag has exactly one, the
        // `draftSpan` this always used, so its output is unchanged).
        // I7b-2 — a cleared note's stretch is a hole in the DRAFT line too: it
        // is built by the same `make` from a table carrying the same clears, so
        // a slice of one run can never reach across it.
        var out: [[CGPoint]] = []
        for span in draftSpans {
            for run in line.runs {
                guard let first = run.first, let last = run.last,
                      last.editedSeconds >= span.lowerBound,
                      first.editedSeconds <= span.upperBound else { continue }
                guard let lo = run.firstIndex(where: { $0.editedSeconds >= span.lowerBound }),
                      let hi = run.lastIndex(where: { $0.editedSeconds <= span.upperBound }),
                      lo <= hi else { continue }
                let from = max(0, lo - 1)
                let to = min(run.count - 1, hi + 1)
                out.append(geometry.points(forPlayed: Array(run[from...to])))
            }
        }
        return out
    }

    /// The sentence the editor shows about its line, or `nil` — drawn only
    /// when notes are on screen (a caption for an empty surface is noise).
    public var lineCaption: PitchEditorLineCaption? {
        guard state.drawsNotes, let text = playedLine.caption else { return nil }
        if case .answered = contourPhase {
            return PitchEditorLineCaption(kind: .shortfall, text: text)
        }
        return PitchEditorLineCaption(kind: .progress, text: text)
    }

    /// The notes drawn with the amber outline, in table order — the in-window
    /// notes whose wobble setting the render cannot apply.
    ///
    /// ⛔ **EMPTY UNTIL THE SEAM HAS ANSWERED. A WAIT IS NOT A WARNING** — and
    /// a defect I only saw by LOOKING at the pending render: before the answer
    /// the line is built with no contour, so every note that asks for a
    /// wobble change reads "unresolved", and the first render put an amber
    /// outline on it beside a caption saying "Matching the line to the
    /// sound…". The outline claimed a failure the app had not had yet; a
    /// second later it would vanish for most clips. The caption carries the
    /// wait, in progress ink; the outline appears only once there is an
    /// answer that actually cannot be applied.
    public var unresolvedNoteIDList: [UUID] {
        guard case .answered = contourPhase else { return [] }
        return playedLine.unresolvedSegmentIDsInWindow
    }

    /// `unresolvedNoteIDList` as a set — what the surface tests membership in.
    public var unresolvedNoteIDs: Set<UUID> { Set(unresolvedNoteIDList) }

    /// Per drawn note, what its slice of the played line spans — the
    /// `debug.pitchEditor` spy's `playedLine.perNote` (§4.4). Built from the
    /// line the surface strokes, in blob order, so an agent reads the same
    /// numbers a person sees.
    public var playedLineNoteSummaries: [PitchPlayedLine.NoteSummary] {
        let drawn = Set(blobs.map(\.id))
        // I7b — a cleared note reports no points (`pointCount` 0,
        // min/median/max null): the surface strokes nothing there, and the
        // echo must not claim a line a person cannot see. Since I7b-2 that is
        // `make`'s own hole, the wire's answer too.
        return visiblePlayedLine.noteSummaries(
            for: noteTable.segments.filter { drawn.contains($0.id) })
    }

    // MARK: C-0 — building the line

    /// Ask THE seam for the contour the render uses (§4.3 step 2). Runs in
    /// PARALLEL with `load(using:)`; until it answers, the line is drawn as an
    /// estimate. Never throws. A late answer after a `reset()` or a newer
    /// fetch is dropped by `contourGeneration`.
    public func loadRenderContour(using provider: PitchEditorRenderContourProvider) async {
        contourGeneration &+= 1
        let token = contourGeneration
        contourPhase = .fetching
        rebuildPlayedLine()
        let inputs = await provider(clipID)
        guard token == contourGeneration else { return }
        contourPhase = .answered(inputs)
        rebuildPlayedLine()
    }

    /// The clip's transpose changed while the pane is open (the pane is only
    /// rebuilt on a CLIP switch). Rebuilds the line, and re-fits the window
    /// only when a note would otherwise leave it — a +2 transpose visibly
    /// moves the notes up two rows; an octave does not strand them off-screen.
    public func setClipPitchShiftSemitones(_ semitones: Double) {
        let shift = PitchCorrectionMath.finite(semitones, default: 0)
        guard shift != geometry.clipPitchShiftSemitones else { return }
        geometry.clipPitchShiftSemitones = shift
        rebuildPlayedLine()
        let window = geometry.midiRange
        if blobs.contains(where: { !window.contains(geometry.drawnMidi(for: $0)) }) {
            autoFitMidiRange()
        }
    }

    /// The ONE place `playedLine` is built — and the draft with it when a drag
    /// is in flight, so a stored-table change or a late contour under a live
    /// drag cannot leave the draft on stale inputs.
    private func rebuildPlayedLine() {
        playedLine = PitchPlayedLine.make(
            contour: contourPhase.contour,
            fallback: fallbackDetection,
            editSet: noteTable,
            clipPitchShiftSemitones: geometry.clipPitchShiftSemitones,
            sourceWindow: geometry.sourceWindow)
        playedLineRevision &+= 1
        rebuildGaps()
        if !draftNotes.isEmpty { rebuildDraftLine() }
    }

    /// The draft line: `noteTable` copied, the dragged note's offset set to
    /// the draft, through the same `make`. Nothing is committed.
    ///
    /// ⭐ NT-U0 (natural tuning, X2 rule 2) — **A REBUILD CARRIES.** (Since
    /// C5a-4b the copy is the commit's own set transform, which starts from
    /// `noteTable` itself, so every set-level field rides along.) The table used
    /// to be minted with
    /// `PitchEditSet(analysisVersion:segments:retuneMs:)`, which silently put
    /// every OTHER set-level field back to legacy — the formant amount, the
    /// consonant flag and the transition slope — so the line drawn during a drag
    /// could differ from what plays once any of them shapes the curve (NT-C C4's
    /// transitions do). `PitchEditorModelTests` pins the carry, plant shown red.
    ///
    /// ⭐ m23-ap C5a-4b — **ONE DRAFT PATH (design V4).** Every changing note
    /// goes through `PitchEditorDraftEdit.draftSet` — a pitch drag's pressed
    /// note and its members (I4: the line rides with all of them), or a wobble
    /// drag's note — which runs the SAME DAWCore set transform the release's
    /// commit runs (`applyingNotePitchOffsets` / `applyingNoteVibratos` /
    /// `applyingNoteShapes`), so the draft ends in `afterHandEdit(from:)` —
    /// the whole-vocal upgrade when the edit changed a note, nothing when it
    /// did not — exactly when the stored set will (natural tuning D4-1, Q-U1 =
    /// (b)). Nothing here writes a field itself.
    private func rebuildDraftLine() {
        let notes = draftNotes
        guard !notes.isEmpty else {
            draftPlayedLine = nil
            draftEditSet = nil
            return
        }
        let built = playedLine(applying: notes.map { ($0.segmentID, $0.edit) })
        draftEditSet = built.table
        draftPlayedLine = built.line
        draftLineRevision &+= 1
        refreshDragFollow(from: built.table)
    }

    /// vf-18 leg 3 — a pitch drag's moving notes are drawn where the DRAFT
    /// plays them: a carried slide's anchors move under it, so its
    /// `followCents` is re-read from the draft set (`PitchEditSet.slideFollowCents`,
    /// moving notes only) each time the draft changes. A DISPLAY read: the
    /// carry `k` was fixed at the press and no stored offset reads this.
    /// Writes `drag` only when a value changed.
    private func refreshDragFollow(from table: PitchEditSet) {
        guard var live = drag else { return }
        let follows = table.slideFollowCents(only: Set(live.movingSegmentIDs))
        var changed = false
        let pressed = follows[live.segmentID] ?? 0
        if pressed != live.followCents {
            live.followCents = pressed
            changed = true
        }
        for index in live.members.indices {
            let value = follows[live.members[index].segmentID] ?? 0
            if value != live.members[index].followCents {
                live.members[index].followCents = value
                changed = true
            }
        }
        if changed { drag = live }
    }

    /// The unvoiced stretches, from the SAME frames the line is drawn from —
    /// so a gap band and a hole in the line are one analysis, never two that
    /// disagree by a frame. The render's contour is cropped to the window (it
    /// covers the whole file); the window detection already is one.
    private func rebuildGaps() {
        if let detection = contourPhase.contour?.detection {
            let period = detection.frameRateHz > 0 ? 1 / detection.frameRateHz : 0
            let window = geometry.sourceWindow
            let frames = detection.frames.filter {
                $0.timeSeconds > window.lowerBound - 2 * period
                    && $0.timeSeconds < window.upperBound + period
            }
            gaps = Self.gaps(frames: frames, frameRateHz: detection.frameRateHz)
        } else if let fallback = fallbackDetection {
            gaps = Self.gaps(frames: fallback.frames, frameRateHz: fallback.frameRateHz)
        } else {
            gaps = []
        }
    }

    // MARK: Loading

    /// Run detection and apply it. The ONE entry point a view uses.
    ///
    /// Never throws: every outcome is a STATE, because a thrown error a view
    /// swallows is an empty screen with no explanation — which is the failure
    /// §5.7 exists to prevent.
    public func load(using detect: PitchEditorDetectionProvider) async {
        loadGeneration &+= 1
        let token = loadGeneration
        phase = .detecting
        clearDetection()
        do {
            let detection = try await detect(clipID)
            guard token == loadGeneration else { return }
            apply(detection)
        } catch is CancellationError {
            guard token == loadGeneration else { return }
            // A cancelled load CONCLUDED NOTHING. Reporting it as a refusal
            // would put Foundation's "The operation couldn't be completed"
            // on screen as if the store had said it.
            reset()
        } catch {
            guard token == loadGeneration else { return }
            fail(error)
        }
    }

    /// Apply a detection result: derive the notes, the contour and the opening
    /// pitch window. Public so the suite can drive the pure half without an
    /// async provider — and so it stays the ONE place a result becomes a
    /// screen.
    public func apply(_ detection: ClipPitchDetection) {
        let result = detection.pitch
        frameRateHz = result.frameRateHz
        analysedFrameCount = result.frames.count

        // ⭐ NEITHER RULE LIVES IN THIS FILE. The RUN rule is
        // `PitchAutoCorrect.voicedRuns`' (a run ends at a hole AND at any frame
        // gap larger than 1.5 frame periods; runs under `minimumNoteSeconds`
        // are dropped), and the contour below is derived FROM these runs. The
        // NOTE rule is `PitchNoteSplitter`'s (p2-seg: notes are parts of a run,
        // split where the singer changes note without stopping), and the notes
        // reach this model only through `PitchNoteTable.detected` below — the
        // same call `PitchAutoCorrect.editSet` makes, so the editor and the
        // corrector cannot disagree about what a note is. Re-implementing
        // either rule here would be a second home that drifts silently.
        let runs = PitchAutoCorrect.voicedRuns(in: result.frames, frameRateHz: result.frameRateHz)
        // ⛔ **THE CONTOUR IS PER RUN, NOT PER NOTE, AND AFTER C3 THOSE ARE
        // DIFFERENT COUNTS.** A split makes two notes out of one run; deriving
        // the contour per NOTE would then break the measured line in two at the
        // cut, drawing a 16 ms hole where the singer never stopped — exactly
        // the bridged-hole lie (§5.5.1) with its sign reversed. The runs are
        // the measurement and they are what the contour follows.
        contourRuns = Self.contourRuns(frames: result.frames,
                                       blobs: runs.map { NoteBlob(run: $0) })
        // The note table the editor draws and edits, minted ONCE per detection
        // (§C1's seeding rule — `ProjectStore+PitchNoteEdits.swift`'s banner).
        // Held here, NOT written to the store: opening a viewer must not dirty
        // a project. The first edit carries it to the store as `seedIfAbsent`,
        // which is what makes the ids the user dragged the ids that get saved.
        let previous = noteTable
        seedTable = PitchNoteTable.detected(from: result)
        // C-0: kept whole — the estimate's sung line until the seam answers.
        fallbackDetection = result
        rebuildBlobs()
        // I4: a fresh detection mints fresh ids — whatever was selected is
        // pruned to what this table still draws.
        reconcileSelection(previous: previous)
        // The gaps are rebuilt here too, from whichever frames the line uses.
        rebuildPlayedLine()
        phase = .detected
        autoFitMidiRange()
    }

    // MARK: The note table (m23-ap Increment C)

    /// Adopt the clip's STORED note table — `Clip.pitchEdits`, handed in by the
    /// view whenever it changes.
    ///
    /// ⭐ **THE STORE IS THE TRUTH THE MOMENT IT HAS ONE.** Before the first
    /// edit the editor draws its own seed; after it, it draws what was saved.
    /// That is what makes a drag verifiable by reading the field back rather
    /// than by trusting that the call returned — and it is why a commit that
    /// silently wrote nothing shows up as a blob springing back.
    public func syncStoredNoteTable(_ table: PitchEditSet?) {
        let previous = noteTable
        storedTable = table
        rebuildBlobs()
        // C-0: the line is what the render plays, and the render plays the
        // STORED table — so a read-back rebuilds it.
        rebuildPlayedLine()
        // I4: the selection follows the table — pruned to what is still drawn,
        // and a split's right half joins a selected parent.
        reconcileSelection(previous: previous)
        // I6c: a note the table moved off the laid-out window (a redo after the
        // pane shrank, a wire edit) widens it. Never a shrink, so a commit
        // read back never moves the grid.
        holdStrandedNotes()
        // UE-2: an undone merge withdraws its "Added" line; a remembered
        // decline comes back on a rebuilt pane.
        reconcileFindSoundsLine()
    }

    /// The table blobs are drawn from: the store's when there is one, the
    /// editor's own seed otherwise.
    public var noteTable: PitchEditSet { storedTable ?? seedTable }

    /// The table to hand a store op as `seedIfAbsent`. Always the SEED — the
    /// store ignores it whenever the clip already carries one, so sending the
    /// stored table back would be a no-op with a clobber's shape.
    public var seedForCommit: PitchEditSet { seedTable }

    /// One blob per segment of `noteTable`, in the table's canonical order.
    ///
    /// ⚠️ **SEGMENTS OUTSIDE THE CLIP'S SOURCE WINDOW ARE NOT DRAWN.** A clip
    /// tuned and then trimmed keeps every segment it ever had (they are
    /// source-absolute and deliberately never re-anchored), so a table can name
    /// notes this clip no longer plays. Drawing them would put blobs at
    /// negative x and stretch the vertical auto-fit around pitches nothing on
    /// screen sings. OVERLAP, not containment: a note the trim cut in half is
    /// still half audible and is still drawn.
    private func rebuildBlobs() {
        let table = noteTable
        let windowStart = geometry.sourceWindowStartSeconds
        let windowEnd = windowStart + geometry.sourceWindowSeconds
        let points = contourRuns.flatMap(\.points).map(\.sourceSeconds)
        // vf-18 leg 3: where each followed slide PLAYS, from the whole table
        // (a slide's anchors may sit outside the window), from DAWCore's one
        // home.
        let follows = table.slideFollowCents()
        blobs = table.segments.compactMap { segment in
            guard segment.endSeconds > windowStart, segment.startSeconds < windowEnd else {
                return nil
            }
            // "How many frames were measured inside this note" — counted from
            // the contour the surface is drawing rather than restated, so a
            // split's two halves report the frames each actually covers.
            let count = points.reduce(into: 0) { total, second in
                if second >= segment.startSeconds && second < segment.endSeconds { total += 1 }
            }
            return NoteBlob(segment: segment, frameCount: count, followCents: follows[segment.id] ?? 0)
        }
    }

    /// Record a refusal. See `PitchEditorFailure`.
    public func fail(_ error: Error) {
        clearDetection()
        phase = .failed(PitchEditorFailure(error))
    }

    /// Back to "nobody has asked yet", and any load still in flight is
    /// invalidated so it cannot paint.
    public func reset() {
        loadGeneration &+= 1
        // C-0: the seam's answer goes too, and a fetch still in flight can no
        // longer land (§4.3 step 5).
        contourGeneration &+= 1
        contourPhase = .notStarted
        clearDetection()
        phase = .notStarted
    }

    private func clearDetection() {
        blobs = []
        contourRuns = []
        gaps = []
        frameRateHz = 0
        analysedFrameCount = 0
        // ⚠️ The SEED goes with the detection that produced it. Leaving a stale
        // seed behind would let a commit hand the store a note table built from
        // a clip the pane is no longer looking at — the "it painted something
        // plausible" failure, written to disk.
        seedTable = .empty
        fallbackDetection = nil
        drag = nil
        wobble = nil
        brush = nil
        voiceDrag = nil   // W7-NTU U3
        wobbleTipNoteID = nil
        farMoveNoteIDs = []   // W7-NTU §1(f) item 4
        draftPlayedLine = nil
        draftEditSet = nil
        refusal = nil
        // I4: nothing is drawn, so nothing can be selected or banded.
        band = nil
        setSelection([])
        soundsSelectedOnlyByAll = []
        rebuildPlayedLine()
    }

    // MARK: Vertical window

    /// Open the vertical window on what was detected (§5.6). Called by
    /// `apply`; public so a view can offer a "fit" affordance later.
    ///
    /// ⚠️ This OVERWRITES a scrolled/zoomed `geometry.midiRange`. A read-only
    /// surface re-fitting on a fresh detection is the behaviour a novice
    /// expects; if Increment C grows a vertical scroll the user can keep, this
    /// is the call that has to learn to respect it.
    public func autoFitMidiRange() {
        // The DRAWN pitch: the window opens on where the notes ARE, which
        // after a preset, a drag or a clip transpose is not where they were
        // sung. Fitting on the detected centres would scroll a corrected note
        // off its own screen — and on a clip transposed an octave, every note.
        let geometry = geometry
        let fitted = PitchEditorRange.midiRange(
            forNoteCentres: blobs.map { geometry.drawnMidi(for: $0) })
        fittedMidiRange = fitted
        // I6c: what the fit chose NOT to show (only the 36-semitone cap ever
        // leaves a note out) stays out. See `fitOutlierIDs`.
        fitOutlierIDs = Set(blobs.filter { !fitted.contains(geometry.drawnMidi(for: $0)) }.map(\.id))
        layOutPitchWindow()
    }

    /// m23-ap I6c: the pitch viewport's measured height. The view reports it
    /// whenever it changes (maximize, restore, the splitter, a window
    /// resize), and the window is re-filled for it.
    public func setAvailableHeight(_ height: CGFloat) {
        let height = height.isFinite ? max(0, height) : 0
        guard height != availableHeight else { return }
        availableHeight = height
        layOutPitchWindow()
    }

    /// m23-ap I6c: the pitch zoom (PITCH −/+, ⌘ row zoom, `debug.panelLayout`
    /// all write the ONE slot, and the view hands its change here). The row
    /// height is the user's. Only the NUMBER of rows the pane can hold changes,
    /// so the window is re-filled BEFORE the view re-pins its scroll offset:
    /// the re-pin clamps against the new content height, which reads the window.
    public func setRowHeight(_ rowHeight: CGFloat) {
        guard rowHeight != geometry.rowHeight else { return }
        geometry.rowHeight = rowHeight
        layOutPitchWindow()
    }

    /// ⭐ **THE ONE PLACE `geometry.midiRange` IS LAID OUT** (m23-ap I6c): the
    /// notes' window, filled to the pane at the current row height
    /// (`PitchEditorRange.filled`), then widened to hold every drawn note the
    /// fit did not leave out on purpose (`PitchEditorRange.holding`, the strand
    /// rule). Every reader of the window (the rows, the ruler, the drag and
    /// group clamps, the hit rects and so the band, the cut line, the ghosts,
    /// the labels, the playhead's height) reads the result and follows it.
    ///
    /// Only a held note OUTSIDE the notes' own window is passed on. Every other
    /// note is inside `fittedMidiRange`, which the fill never shrinks below, so
    /// giving it the strand rule's headroom would only re-open the fit the
    /// editor already chose (and change the window it OPENS at).
    ///
    /// ⚠️ **THE PANE-HEIGHT BOUND IS `filled`'s, NOT THIS WINDOW'S.** A held note
    /// on the filled window's edge row (a drag reaches it) gets its headroom row
    /// at the next layout, so the grid can end up one row taller than the pane,
    /// and after PITCH + (fewer rows fit) several. The strand rule outranks the
    /// fill: a note off the window is the drag clamp's DATA LOSS case.
    ///
    /// Compare-first: the splitter reports a new height every frame, and the
    /// window only moves when a whole row appears or goes.
    ///
    /// m23-ap I6b: a LIVE DRAG's drawn pitches are held too. A draft is not in
    /// `blobs` until it commits, so without this a resize or a zoom mid-drag
    /// could lay the window out from under the note in the user's hand — the
    /// same data-loss shape, one gesture earlier. Nothing changes with no drag.
    private func layOutPitchWindow() {
        let geometry = geometry
        let fitted = fittedMidiRange
        var drawn = blobs.filter { !fitOutlierIDs.contains($0.id) }
            .map { geometry.drawnMidi(for: $0) }
        if let drag { drawn += Self.drawnMidis(of: drag) }
        let held = drawn.filter { !fitted.contains($0) }
        let window = PitchEditorRange.holding(
            PitchEditorRange.filled(fittedMidiRange, rowHeight: geometry.rowHeight,
                                    availableHeight: availableHeight),
            drawnMidis: held)
        if window != geometry.midiRange { self.geometry.midiRange = window }
    }

    /// m23-ap I6c: after the stored table changes (a commit read back, an undo,
    /// a redo, a wire edit), a held note that now sits OUTSIDE the laid-out
    /// window widens it. This only ever WIDENS: a commit must never make the
    /// grid jump under the note the user just let go of, and re-running the
    /// whole layout here would shrink the window whenever a note that had
    /// widened it moved back inside. The next pane or zoom change lays it out
    /// afresh.
    private func holdStrandedNotes() {
        let geometry = geometry
        let window = geometry.midiRange
        let stranded = blobs.filter {
            !fitOutlierIDs.contains($0.id) && !window.contains(geometry.drawnMidi(for: $0))
        }
        guard !stranded.isEmpty else { return }
        self.geometry.midiRange = PitchEditorRange.holding(
            window, drawnMidis: stranded.map { geometry.drawnMidi(for: $0) })
    }

    // MARK: Increment C — hit testing, dragging, splitting

    /// How far outside a blob's drawn rectangle a click still counts as that
    /// note, in points. A PICK, bounded by two facts: a blob is ~0.8 of a row
    /// tall, so a few points of slop never reaches the next row's note, and a
    /// pixel-exact target on a 10 pt-tall rectangle is not something a person
    /// with a trackpad can hit. `docs/DESIGN-LANGUAGE.md`'s hit-target rule.
    public nonisolated static let hitSlop: CGFloat = 4

    /// The note under a point, or `nil`.
    ///
    /// ⚠️ **NEAREST BY VERTICAL DISTANCE, NOT FIRST MATCH.** Blobs never
    /// overlap in time (`PitchEditSet.canonical` guarantees it), but two notes
    /// a semitone apart at a tall zoom have rectangles whose SLOP overlaps, and
    /// "first in the array" would then mean "the earlier one", which is not
    /// what the user aimed at.
    public func blob(at point: CGPoint) -> NoteBlob? {
        // I4: the rects are `hitRects()` — the ONE producer the band reads too.
        var best: (index: Int, distance: CGFloat)?
        for (index, entry) in hitRects().enumerated() {
            guard entry.rect.contains(point) else { continue }
            let distance = abs(point.y - entry.rect.midY)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best.map { blobs[$0.index] }
    }

    /// ⭐ **THE ONE HIT-RECT PRODUCER** (m23-ap I4): every drawn note's rect,
    /// inflated by `hitSlop`, in `blobs` order — exactly the rects `blob(at:)`
    /// (and so `pressHit(at:)`, the click) tests, and the rects the band hands
    /// `PianoRollMarquee.hits`. The roll's marquee law (`PianoRollMarquee.swift`'s
    /// banner, "THE REAL TRAP IS WHICH RECT"): a band and a click that read two
    /// different rect sets disagree somewhere, and the user sees a note a click
    /// selects that a sweep over it does not.
    public func hitRects() -> [(id: UUID, rect: CGRect)] {
        blobs.map { blob in
            (blob.id, geometry.rect(for: blob).insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop))
        }
    }

    /// Start dragging a note's pitch (C1). Returns false when there is no note
    /// there, so the caller can tell a miss from a zero-length drag.
    @discardableResult
    public func beginPitchDrag(on blob: NoteBlob) -> Bool {
        guard tool == .pointer else { return false }
        refusal = nil
        drag = PitchEditorDragDraft(segmentID: blob.id,
                                    startSeconds: blob.startSeconds,
                                    endSeconds: blob.endSeconds,
                                    detectedMidi: blob.centreMidi,
                                    baselineCents: blob.offsetCents,
                                    offsetCents: blob.offsetCents,
                                    isFree: false,
                                    clipPitchShiftSemitones: geometry.clipPitchShiftSemitones,
                                    windowTopAtPress: geometry.midiRange.upperBound,
                                    isUnpitched: blob.isUnpitched,
                                    baselineFollowCents: blob.followCents,
                                    followCents: blob.followCents)
        // I6b — growth state is per PRESS: a new drag banks nothing from the last.
        growthRemainder = 0
        dragAuditionHeard = nil
        // C-0: the draft line exists from the first moment of the gesture, so
        // the note's own stretch of line leaves the surface and rides with the
        // blob before the pointer has moved a pixel.
        rebuildDraftLine()
        return true
    }

    /// A pointer tick. ⛔ **THIS FUNCTION MUST NEVER COMMIT** — see
    /// `PitchEditorCommit`. `aDragTickNeverCommits` is the gate.
    ///
    /// `translationHeight` is the gesture's total dy from where it began, in
    /// points, y-down as SwiftUI reports it. `free` is ⌥.
    public func updatePitchDrag(translationHeight: CGFloat, free: Bool) {
        guard var draft = drag else { return }
        // ⭐ m23-ap I6b — THE TOP MOVED, SO EVERY ROW DID. Rows are laid out down
        // from the window's top (`y(forMidi:)`), so a row grown there
        // (`growPitchWindowForDrag`) or a relayout that moved it shifts every
        // row, while the press point — a CONTENT y fixed for the gesture — does
        // not. Without this the note falls one row behind the pointer per row
        // grown. `translationHeight` itself when the top has not moved, so a
        // drag that never grows is bit-identical (`PitchEditorModelTests`
        // proves it on `.bitPattern`).
        let topShift = geometry.midiRange.upperBound - draft.windowTopAtPress
        let travel = topShift == 0
            ? translationHeight
            : translationHeight - CGFloat(topShift) * geometry.rowHeight
        // y grows DOWNWARD and pitch grows UPWARD: the minus sign is the whole
        // of that relationship and it is the one thing a reviewer should check.
        let semitones = -Double(travel) / Double(max(1, geometry.rowHeight))
        // ⚠️ DRAWN PITCH from here to `landed` (m23-ap C-0): the window, the
        // clamp and the snap are all on the axis the user SEES, which on a
        // transposed clip is not the stored one. The way back to a stored
        // offset is the ONE conversion below.
        // vf-18 leg 3: a followed slide's origin is where it is DRAWN — its
        // neighbours' contribution at the press included (0 for every other
        // note, which then takes the three-term conversion verbatim).
        let origin = PitchEditorGeometry.drawnMidi(
            centreMidi: draft.detectedMidi, offsetCents: draft.baselineCents,
            followCents: draft.baselineFollowCents,
            clipPitchShiftSemitones: draft.clipPitchShiftSemitones)
        let raw = origin + semitones
        // ⭐ UE-1 — A SOUND PRESSED WITHOUT ⌥ takes its own branch, alone or
        // leading a group: whole semitones from where it sits
        // (`updateSoundPitchDrag`, §1.7). ⌥ falls through to the free paths
        // below, which are the same for a sound as for a note. A drag whose
        // pressed blob is a NOTE never enters it, so both branches below are
        // left exactly as they were.
        if draft.isUnpitched, !free {
            updateSoundPitchDrag(&draft, origin: origin, raw: raw)
            return
        }
        // ⭐ m23-ap I4 — A GROUP DRAG takes its own branch, and the one-note
        // path below is left EXACTLY as it was: a drag with no other selected
        // note never enters it, so it snaps, clamps and commits byte-identically.
        if !draft.members.isEmpty {
            updateGroupPitchDrag(&draft, origin: origin, raw: raw, free: free)
            return
        }
        // ⛔ **A NOTE DRAGGED OFF THE WINDOW IS DATA LOSS TO THE PERSON HOLDING
        // THE MOUSE.** The visible range is the detected span padded by four
        // semitones, so a big drag would commit a note above the top of the
        // content and it would simply be GONE — nothing on screen, nothing
        // refused, and an edit saved to disk. Clamping keeps it at the edge,
        // which reads as "this is as far as this view goes".
        //
        // ⚠️ THE INSET IS ONE SEMITONE AND THAT IS A PROOF, NOT A GUESS: every
        // mode `PitchCorrectionScaleMode` offers (chromatic, major, minor) has a
        // largest gap of 2 semitones, so `nearestAllowedMidi` moves a value by
        // at most 1. Clamping the RAW value an inset in therefore guarantees the
        // SNAPPED value lands inside — which is what lets the snap stay exact at
        // the boundary instead of a clamp silently putting a note off the scale.
        // `PitchEditorRange.minimumVisibleSemitones` is 12, so the inset window
        // is never inverted.
        let window = geometry.midiRange
        let clamped = min(max(raw, window.lowerBound), window.upperBound)
        let landed = free
            ? clamped
            : snapScale.nearestAllowedMidi(
                to: min(max(raw, window.lowerBound + 1), window.upperBound - 1))
        draft.isFree = free
        // vf-18 leg 3: a lone drag of a followed slide lands in DRAWN space and
        // stores the drawn pitch minus what its (unmoving) neighbours add, so
        // +D drawn is +D stored and the release is `.notePitch` as before.
        draft.offsetCents = PitchEditorGeometry.storedOffsetCents(
            drawnMidi: landed, centreMidi: draft.detectedMidi,
            followCents: draft.baselineFollowCents,
            clipPitchShiftSemitones: draft.clipPitchShiftSemitones)
            .clamped(to: NoteSegment.pitchOffsetCentsRange)
        let moved = draft.offsetCents != drag?.offsetCents
        drag = draft
        // C-0: the live line follows the draft — rebuilt only when the VALUE
        // moved (a snapped drag crosses a row a few times per gesture; most
        // ticks change nothing), and never committed.
        // I1 UI hooks: and the drag is HEARD on exactly that event — once per
        // change of the offset, never per pointer tick (a SNAPPED change inside
        // the detector floor asks nothing: `requestDragAudition`).
        if moved {
            rebuildDraftLine()
            requestDragAudition(draft)
        }
    }

    /// The gesture ended. Emits AT MOST ONE commit — none at all when the note
    /// finished where it started, because a no-op write is an undo entry for a
    /// decision nobody made.
    @discardableResult
    public func endPitchDrag() -> PitchEditorCommit? {
        guard let draft = drag else { return nil }
        drag = nil
        // The draft line goes with the draft: from here the line is what the
        // STORE says, and a commit that silently wrote nothing shows up as the
        // line springing back with its blob.
        draftPlayedLine = nil
        draftEditSet = nil
        // m23-ap I6b — THE RELEASE'S HEADROOM, only for a drag that GREW the
        // window: a note let go on a grown edge row (a free drag reaches it; a
        // group member can too) keeps a row above it for its NAME, drawn in the
        // gutter over the note (I6c's measured "no B4"). Widen-only, through the
        // strand rule's own arithmetic. A drag that never grew skips it, so its
        // release leaves the window exactly as before.
        if draft.grownRows > 0 {
            let window = PitchEditorRange.holding(geometry.midiRange,
                                                  drawnMidis: Self.drawnMidis(of: draft))
            if window != geometry.midiRange { geometry.midiRange = window }
        }
        guard !draft.isNoOp else { return nil }
        guard !draft.members.isEmpty else {
            // W7-NTU §1(f) item 4 — the hint asks about the note this drag moved.
            farMoveNoteIDs = [draft.segmentID]
            return emit(.notePitch(segmentID: draft.segmentID, offsetCents: draft.offsetCents))
        }
        // m23-ap I4 — a GROUP drag: ONE commit carrying every moved note's
        // absolute offset, in table order, and the selection's token for the
        // group undo key. Never N `.notePitch` commits: that would be N undo
        // steps for one gesture (UI design §8.4).
        // vf-18 leg 3 — the offsets ALREADY carry the carry (a followed slide
        // moved with its anchors stores `baseline + delta·100·k`, k from
        // `groupMoveCarries` at the press), so this commit stores exactly what
        // `PitchEditSet.applyingGroupPitchMove` stores for the same move, and
        // exactly the set the draft line was drawn from (the app applies it
        // through `setClipNotePitchOffsets` → `applyingNotePitchOffsets`, the
        // draft's own transform). The shape is unchanged on purpose: this
        // model emits commits and never calls the store, and the app's
        // applier reads every note back against the number committed here.
        let offsets = [NotePitchOffset(segmentId: draft.segmentID, offsetCents: draft.offsetCents)]
            + draft.members.map { NotePitchOffset(segmentId: $0.segmentID, offsetCents: $0.offsetCents) }
        let order = Dictionary(uniqueKeysWithValues: blobs.enumerated().map { ($1.id, $0) })
        let ordered = offsets.sorted {
            (order[$0.segmentId] ?? Int.max) < (order[$1.segmentId] ?? Int.max)
        }
        // W7-NTU §1(f) item 4 — and about every note a group drag moved.
        farMoveNoteIDs = ordered.map(\.segmentId)
        return emit(.notePitches(offsets: ordered, selectionToken: selectionToken))
    }

    /// The gesture was abandoned — the window deactivated, the pane closed, a
    /// clip switched. ⚠️ **NOT THE SAME CALL AS `endPitchDrag`**: SwiftUI's
    /// `DragGesture.onEnded` does not fire when a window resigns key, and a
    /// draft left behind would leak into the next gesture as a phantom
    /// baseline.
    public func cancelDrag() {
        drag = nil
        // C5a-4b — and a Wobble-tool press, dropped with nothing committed.
        wobble = nil
        // C5b-4b — and a brush stroke, dropped with nothing committed.
        brush = nil
        // W7-NTU U3 — and a Voice-tool press, dropped the same way.
        voiceDrag = nil
        // W7-NTU U1 — and a "Keep voice size" press, dropped the same way.
        cancelVoiceSize()
        draftPlayedLine = nil
        draftEditSet = nil
        // I4 — a band that cannot finish gives the selection BACK: it is put
        // away with the frozen base it armed with, never left half-applied.
        cancelBand()
        // I0 — and the PRESS that owned the drag. A press left in flight would
        // make the next gesture's first tick look like a later tick of this one
        // whenever it happened to start at the same point.
        press.cancel()
    }

    // MARK: C5a-4b — the Wobble tool and its dot (vibrato-handle design §4–§6, §9, §18)
    //
    // ⭐ THE GESTURE IS C5a-4a's, HEADLESS (`PitchWobbleSession`); THIS IS ITS
    // WIRING. A press on a note in the Wobble tool routes `.wobble(id, door:)`
    // (`PitchEditorGestureRouter`), begins a session on its FIRST tick
    // (`beginWobble`, from `trackPress`), feeds it pointer travel only once the
    // press is past the router's 4 pt slop (`updateWobbleDrag`: the one slop,
    // §18.8), and at the release either commits the drag (`endWobbleDrag`) or
    // steps the dot (`stepWobble`) — ONE commit each, none for a gesture that
    // plays like the stored note (T10), through `emit` like every other write.

    /// The note table's segment behind a drawn note, as STORED.
    private func storedSegment(_ id: UUID) -> NoteSegment? {
        noteTable.segments.first { $0.id == id }
    }

    /// Empty the reading cache when the line it was read from has changed.
    private func syncWobbleReadings() {
        var answered = false
        if case .answered = contourPhase { answered = true }
        wobbleReadings.sync(lineRevision: playedLineRevision, contourAnswered: answered)
    }

    /// The SUNG reading of a note (`PitchWobbleEstimate.sung` over the
    /// render's own contour, design §8.1), cached. `nil` without a `.detected`
    /// contour: the editor's window detection is another analysis (F18).
    private func sungWobbleReading(of segment: NoteSegment) -> PitchWobbleReading? {
        syncWobbleReadings()
        let key = PitchEditorWobbleReadingCache.Key(segment)
        if let cached = wobbleReadings.sung[key] { return cached }
        let reading = contourPhase.contour.flatMap { PitchWobbleEstimate.sung(segment, contour: $0) }
        wobbleReadings.sung[key] = .some(reading)
        return reading
    }

    /// The PLAYED reading of a note as STORED — the estimator over the line
    /// the surface draws (design §9.2's hover row), cached.
    private func playedWobbleReading(of segment: NoteSegment) -> PitchWobbleReading {
        syncWobbleReadings()
        let key = PitchEditorWobbleReadingCache.Key(segment)
        if let cached = wobbleReadings.played[key] { return cached }
        let reading = PitchWobbleEstimate.played(segment, line: playedLine)
        wobbleReadings.played[key] = reading
        return reading
    }

    /// What a Wobble-tool press on `segment` would start (design §5.1 as
    /// amended by §18.3): `PitchWobbleGesture.classify` — a SOUND refused in
    /// §1.7's words, the basis gate (§5.5) refused in its two captions, else
    /// your wobble or a new one.
    public func wobbleStart(for segment: NoteSegment) -> PitchWobbleStart {
        PitchWobbleGesture.classify(segment: segment, sung: sungWobbleReading(of: segment),
                                    basis: playedLine.basis)
    }

    /// Whether the Wobble tool can grab `segment` NOW — the question the dot
    /// asks before it is drawn (unpitched design §4: none on a sound, none
    /// while the tool is gated). The refusal never depends on the sung reading
    /// (only own-vs-new does), so this reads none.
    public func wobbleCanGrab(_ segment: NoteSegment) -> Bool {
        PitchWobbleGesture.classify(segment: segment, sung: nil, basis: playedLine.basis).refusal == nil
    }

    /// The drawn note whose DOT is under `point` — within
    /// `PitchWobbleGesture.knobHitRadius` of a grabbable note's top centre, the
    /// nearest if two reach — in the Wobble tool only; else `nil`. The dot's
    /// radius reaches above the blob, past `hitSlop`, so this is asked BEFORE
    /// `blob(at:)` (`pressHit`), and the hover asks the same function, so the
    /// dot a person sees is the dot a press grabs.
    public func wobbleDotHit(at point: CGPoint) -> NoteBlob? {
        guard tool == .wobble, state.drawsNotes else { return nil }
        var best: (blob: NoteBlob, distance: CGFloat)?
        for blob in blobs {
            let rect = geometry.rect(for: blob)
            guard PitchWobbleGesture.door(at: point, blobRect: rect) == .dot,
                  let segment = storedSegment(blob.id), wobbleCanGrab(segment) else { continue }
            let centre = PitchWobbleGesture.dot(in: rect)
            let distance = hypot(point.x - centre.x, point.y - centre.y)
            if best == nil || distance < best!.distance { best = (blob, distance) }
        }
        return best?.blob
    }

    /// ⭐ **THE DOT, AS DRAWN** (unpitched design §4): on the grabbable note
    /// under `point` (its dot, or the note itself) while the Wobble tool is
    /// engaged — or, with the pointer on neither, on the note a dot click just
    /// stepped (`wobbleTipNoteID`). Its tip and the palette's readout are read
    /// from the STORED note through a throwaway session, so they say what the
    /// store holds. `nil` during a wobble DRAG (the knob is the drag overlay's
    /// then), on a sound, while the tool is gated, and in every other tool.
    public func wobbleDot(at point: CGPoint?) -> PitchEditorWobbleDot? {
        // C5b-4b — nor during a brush stroke: the press is the brush's.
        guard tool == .wobble, state.drawsNotes, wobble?.isDragging != true, brush == nil
        else { return nil }
        var target: (blob: NoteBlob, reason: PitchEditorWobbleDot.Reason)?
        if let point {
            if let hit = wobbleDotHit(at: point) {
                target = (hit, .hover)
            } else if let hit = blob(at: point), let segment = storedSegment(hit.id),
                      wobbleCanGrab(segment) {
                target = (hit, .hover)
            }
        }
        if target == nil, let id = wobbleTipNoteID, let tipped = blobs.first(where: { $0.id == id }) {
            target = (tipped, .afterClick)
        }
        guard let target, let segment = storedSegment(target.blob.id), wobbleCanGrab(segment),
              let session = wobbleSession(on: segment, start: wobbleStart(for: segment), door: .dot)
        else { return nil }
        let rect = geometry.rect(for: target.blob)
        return PitchEditorWobbleDot(segmentID: segment.id, centre: PitchWobbleGesture.dot(in: rect),
                                    blobRect: rect, tip: session.dotTip(),
                                    readout: session.readout(played: playedWobbleReading(of: segment),
                                                            hasDrawnShape: segment.hasShape),
                                    reason: target.reason)
    }

    /// The palette's SF Mono readout in the Wobble tool (design §9.1, the UE-2
    /// one-line slot): the press in flight's own line, else the dot's note's.
    /// `nil` in every other tool and with nothing to say.
    public func wobbleReadout(dot: PitchEditorWobbleDot?) -> PitchWobbleReadout? {
        guard tool == .wobble else { return nil }
        return wobble?.readout ?? dot?.readout
    }

    /// Where the KNOB of a wobble DRAG in flight is drawn, content space: the
    /// pressed note's dot (`PitchWobbleGesture.dot(in:)`), which does not move
    /// — a wobble drag never moves the note. `nil` with no drag.
    public var wobbleKnob: CGPoint? {
        guard let wobble, wobble.isDragging,
              let blob = blobs.first(where: { $0.id == wobble.segmentID }) else { return nil }
        return PitchWobbleGesture.dot(in: geometry.rect(for: blob))
    }

    /// A session on `segment` at this pane's ratio, row height and time warp.
    private func wobbleSession(on segment: NoteSegment, start: PitchWobbleStart,
                               door: PitchWobbleDoor) -> PitchWobbleSession? {
        PitchWobbleSession.begin(segment: segment, start: start,
                                 stretchRatio: geometry.stretchRatio,
                                 rowHeight: Double(geometry.rowHeight),
                                 timeWarp: playedLine.curve.timeWarp,
                                 door: door)
    }

    /// The FIRST tick of a `.wobble` press (`trackPress`): a session on the
    /// STORED note, or a refusal said in words — a sound (§1.7), the basis gate
    /// (§5.5: "Changing a wobble needs the app's analysis…"), a knob too narrow
    /// to grab — and the press ABANDONED, so its ticks and its release do
    /// nothing (`PitchEditorPressTracker.abandon`): no draft, no selection, no
    /// commit. The refusal is drawn on the palette's `PanelRefusalLine`, the
    /// slot every refusal on this surface uses: a tool that refused must not
    /// look like one that did nothing.
    private func beginWobble(segmentID id: UUID, door: PitchWobbleDoor, origin: CGPoint) {
        refusal = nil
        guard let blob = blobs.first(where: { $0.id == id }), let segment = storedSegment(id) else {
            press.abandon()
            return
        }
        guard let knob = PitchWobbleGesture.knob(at: origin, in: geometry.rect(for: blob)) else {
            refusal = PitchWobbleCopy.zoomInForTwoHandles
            press.abandon()
            return
        }
        let start = wobbleStart(for: segment)
        if let sentence = start.refusal {
            refusal = sentence
            press.abandon()
            return
        }
        guard let session = wobbleSession(on: segment, start: start, door: door) else {
            press.abandon()
            return
        }
        let played: PitchWobbleReading? = session.phase == .own ? playedWobbleReading(of: segment) : nil
        wobble = PitchEditorWobbleDraft(segmentID: id, startSeconds: segment.startSeconds,
                                        endSeconds: segment.endSeconds, door: door, knob: knob,
                                        session: session, played: played,
                                        readout: session.readout(played: played,
                                                                hasDrawnShape: segment.hasShape))
    }

    /// One pointer tick of the Wobble-tool press in flight. ⛔ **NEVER
    /// COMMITS** — `PitchWobbleSession.update` has no commit output at all (T10).
    ///
    /// `translation` is the gesture's total travel from the PRESS (SwiftUI's:
    /// y grows down), handed to the one function that reads a translation
    /// (`PitchWobbleGesture.travel`, D3); `fine` is ⌥ as held THIS tick. Does
    /// nothing until the press is past the router's slop (`isPromoted`, the one
    /// 4 pt home, §18.8): a click steps or selects from the STORED note. The
    /// draft line and the readout are rebuilt only when the QUANTISED draft
    /// changed (§9.3), and the readout's reading of YOUR wobble is the
    /// estimator over that draft line, never `keep × depth`.
    public func updateWobbleDrag(translation: CGSize, fine: Bool) {
        guard var current = wobble, press.current?.isPromoted == true else { return }
        let startedDragging = !current.isDragging
        current.isDragging = true
        current.travel = PitchWobbleGesture.travel(translation: translation, knob: current.knob)
        current.fine = fine
        let changed = current.session.update(travel: current.travel, fine: fine,
                                             playedLine: { draft in self.wobbleHandoffLine(with: draft) })
        wobble = current
        if changed || startedDragging {
            // `draftNotes` reads `wobble`, so it is stored FIRST.
            rebuildDraftLine()
            current.played = current.session.phase == .own || current.session.phase == .group
                ? draftPlayedLine.map { PitchWobbleEstimate.played(current.session.draft, line: $0) }
                : nil
        }
        // §13: on a note with a drawn shape (C5b) the line says the drawing stays.
        current.readout = current.session.readout(played: current.played,
                                                  hasDrawnShape: current.session.stored.hasShape)
        wobble = current
    }

    /// The line the handoff reads at its crossing tick (§6.2 step 1): the
    /// committed table with `draft` in place of its note, through the ONE draft
    /// path (`PitchEditorDraftEdit.draftSet`) and the render's own `make` — with
    /// the note's DRAWN SHAPE (C5b-1, `shapeTenthsOfCents`) CLEARED IN THE
    /// COPY (§13): otherwise the drawing would be read as part of the wobble,
    /// copied into the new sine, and then play twice. The stored note keeps
    /// its shape; only this measurement's copy loses it.
    private func wobbleHandoffLine(with draft: NoteSegment) -> PitchPlayedLine {
        playedLine(applying: [(draft.id, .wobble(NoteVibratoEdit(storedIn: draft),
                                                 stretchRatio: geometry.stretchRatio))],
                   clearingShapeOf: draft.id).line
    }

    /// The committed table with `edits` applied through
    /// `PitchEditorDraftEdit.draftSet` — the SAME DAWCore set transforms the
    /// commits run, `afterHandEdit(from:)` included (natural tuning D4-1) — and its
    /// played line through the render's own `make`: THE one builder the draft
    /// line (`rebuildDraftLine`) and the handoff line share.
    private func playedLine(applying edits: [(segmentID: UUID, edit: PitchEditorDraftEdit)],
                            clearingShapeOf shapeCleared: UUID? = nil)
    -> (table: PitchEditSet, line: PitchPlayedLine) {
        var table = PitchEditorDraftEdit.draftSet(noteTable, applying: edits, clipID: clipID)
        // The handoff's measurement copy only (`wobbleHandoffLine`): "no
        // shape" is an empty array at index 0, the model's own spelling.
        if let shapeCleared, let index = table.segments.firstIndex(where: { $0.id == shapeCleared }) {
            table.segments[index].shapeTenthsOfCents = []
            table.segments[index].shapeStartIndex = 0
        }
        let line = PitchPlayedLine.make(
            contour: contourPhase.contour,
            fallback: fallbackDetection,
            editSet: table,
            clipPitchShiftSemitones: geometry.clipPitchShiftSemitones,
            sourceWindow: geometry.sourceWindow)
        return (table, line)
    }

    /// The wobble DRAG ended (`PitchEditorReleaseAction.endWobble`). Emits AT
    /// MOST ONE commit, `.noteVibrato` with all six fields — and NONE for a
    /// gesture whose result plays exactly like the stored note
    /// (`PitchWobbleSession.commit`, §5.4 / T10). The draft line goes with the
    /// draft: from here the line is what the STORE says.
    @discardableResult
    public func endWobbleDrag() -> PitchEditorCommit? {
        guard let current = wobble else { return nil }
        wobble = nil
        draftPlayedLine = nil
        draftEditSet = nil
        guard current.isDragging, let commit = current.session.commit(),
              let item = commit.items.first else { return nil }
        return emit(.noteVibrato(segmentID: item.segmentId, edit: item.edit))
    }

    /// A click on the DOT (`PitchEditorReleaseAction.wobbleStep`): ONE step —
    /// keep ± 0.10 on your wobble, width ± 5 c on a new one (C5a-4a's
    /// `PitchWobbleSession.step`) — from the STORED note, and one commit, or
    /// none when the step changes nothing (at a cap, or at flat). The dot's
    /// tip then shows for this note (`wobbleTipNoteID`) until the next press.
    /// Clicks on one note inside 800 ms fold into one undo step in the store
    /// (`PitchCorrectionUndoKey.vibrato`, T-dot-4).
    @discardableResult
    public func stepWobble(segmentID: UUID, bigger: Bool) -> PitchEditorCommit? {
        guard var current = wobble, current.segmentID == segmentID else { return nil }
        wobble = nil
        // A step is a click, so it never drew a draft; cleared anyway, so a
        // step can never leave a drag's line behind (`endWobbleDrag`'s rule).
        draftPlayedLine = nil
        draftEditSet = nil
        wobbleTipNoteID = segmentID
        current.session.step(bigger: bigger)
        guard let commit = current.session.commit(), let item = commit.items.first else { return nil }
        return emit(.noteVibrato(segmentID: item.segmentId, edit: item.edit))
    }

    /// Put the dot's after-click tip away (a tool switch).
    public func clearWobbleTip() { wobbleTipNoteID = nil }

    /// Every drawn note's two readings, in blob order (the echo's `perNote`,
    /// design §12.5). Cached per line, so asking twice costs one pass per note.
    public func wobbleReadingsReport() -> [PitchEditorWobbleNoteReadings] {
        blobs.compactMap { blob in
            guard let segment = storedSegment(blob.id) else { return nil }
            return PitchEditorWobbleNoteReadings(segmentID: segment.id,
                                                 sung: sungWobbleReading(of: segment),
                                                 played: playedWobbleReading(of: segment))
        }
    }

    // MARK: C5b-4b — the freehand brush (timing-and-freehand design §5.5–§5.6)
    //
    // ⭐ THE MATH IS C5b-4a's, HEADLESS (`PitchShapeStroke`); THIS IS ITS
    // WIRING. ⌘ held at a press on a note, in the Move or the Wobble tool,
    // routes `.brush(id)` (`PitchEditorGestureRouter`). Nothing happens until
    // the press crosses the router's 4 pt slop: released inside it, the press
    // is the house click (⌘ toggles the note), as it was before the brush.
    // At the promotion the stroke BEGINS at the press point (`beginBrush`) or
    // is REFUSED in words and the press abandoned; every tick sweeps it
    // (`advanceBrush`) and redraws the draft only when what the release would
    // write CHANGED; the release emits ONE `.noteShapes` commit (`endBrush`),
    // none for a stroke that changed nothing — so a stroke across three notes
    // is ONE store call and ONE undo step, never three. `trackPress` drives
    // it WHOLE (the band's shape), so a staged press and a real one run the
    // same code.

    /// Points per SOURCE second at `seconds`: the geometry's own mapping over
    /// one 10 ms grid step (a tempo change bends it, so no constant is right
    /// everywhere). The kernel's radius is converted with it ONCE, at the
    /// stroke's start (§5.5: "the brush feels the same at every zoom").
    private func pointsPerSourceSecond(at seconds: Double) -> Double {
        let step = 1 / NoteSegment.shapeGridHz
        let width = geometry.x(forSourceSecond: seconds + step) - geometry.x(forSourceSecond: seconds)
        return Double(width) / step
    }

    /// The note a press at `point` with this chord would DRAW on — the
    /// router's own answer (`.brush`), asked exactly as the press will ask it
    /// — or `nil`.
    public func brushNote(at point: CGPoint, modifiers: ArrangeClickModifiers) -> UUID? {
        guard case .brush(let id) = PitchEditorGestureRouter.route(
            tool: tool, modifiersAtPress: modifiers, hit: pressHit(at: point)) else { return nil }
        return id
    }

    /// What a stroke on note `id` starting at `point` would be: C5b-4a's ONE
    /// `begin` — its refusals (an estimate line, a sound) in its own words —
    /// on the COMMITTED table and the line as drawn now (never a draft). The
    /// press and the hover both ask this, so the band can never promise a
    /// stroke the press then refuses, or the other way round.
    private func brushStart(on id: UUID, at point: CGPoint) -> PitchShapeBrushStart {
        let seconds = geometry.sourceSecond(forX: point.x)
        return PitchShapeStroke.begin(pressedNoteID: id, atSourceSecond: seconds,
                                      midi: geometry.midi(forY: point.y), table: noteTable,
                                      prestrokePlayedLine: playedLine,
                                      pointsPerSourceSecond: pointsPerSourceSecond(at: seconds))
    }

    /// ⭐ **THE BAND, AS DRAWN** (design §5.5): following the stroke in flight,
    /// or — with ⌘ held, the button up, over a note a ⌘-press would draw on —
    /// following the pointer, dimmed and carrying the sentence when that press
    /// would be refused. `nil` otherwise: over empty surface ⌘ places the
    /// playhead (I5, its own ghost line), and the knife never draws.
    public func brushBand(at hover: CGPoint?, commandHeld: Bool) -> PitchEditorBrushBand? {
        if let brush { return brushBand(centre: brush.point, isStroking: true, refusal: nil) }
        guard commandHeld, press.current == nil, state.drawsNotes, let hover,
              let id = brushNote(at: hover, modifiers: [.command]) else { return nil }
        return brushBand(centre: hover, isStroking: false,
                         refusal: brushStart(on: id, at: hover).refusal)
    }

    private func brushBand(centre: CGPoint, isStroking: Bool, refusal: String?) -> PitchEditorBrushBand {
        let radius = CGFloat(PitchShapeBrush.radiusPoints)
        return PitchEditorBrushBand(
            rect: CGRect(x: centre.x - radius, y: 0, width: 2 * radius, height: geometry.contentHeight),
            point: centre, isStroking: isStroking, refusal: refusal)
    }

    /// ⭐ **THE PALETTE'S DRAWN HELP** (design §5.6: "While ⌘ is held: the help
    /// slot shows the Shape help"): the brush's own words while a stroke is in
    /// flight, or while ⌘ is held over the surface in a tool where ⌘ draws —
    /// or, over a note the brush would refuse, that refusal's sentence (the
    /// estimate caption §5.5 says the disabled brush shows). Else the engaged
    /// tool's help. `band` is `brushBand(at:commandHeld:)`'s answer for the
    /// same hover, so the words and the band cannot disagree.
    public func paletteHelp(commandHeld: Bool, band: PitchEditorBrushBand?) -> String {
        if let refusal = band?.refusal { return refusal }
        if brush != nil || (commandHeld && PitchEditorGestureRouter.commandDraws(in: tool)) {
            return PitchShapeBrush.help
        }
        return tool.help
    }

    /// The `.brush` press crossed the slop (`trackPress`): the stroke BEGINS at
    /// the PRESS point — its first point, so a press that then pulls straight
    /// up or down is one place with a moving target, "pull a peak" (§5.5) —
    /// or is REFUSED in words and the press ABANDONED
    /// (`PitchEditorPressTracker.abandon`), so its later ticks and its release
    /// do nothing: no draft, no selection, no commit. The refusal is drawn on
    /// the palette's `PanelRefusalLine`, the slot every refusal on this surface
    /// uses: a tool that refused must not look like one that did nothing.
    private func beginBrush(on id: UUID, origin: CGPoint) {
        refusal = nil
        switch brushStart(on: id, at: origin) {
        case .refused(let sentence):
            refusal = sentence
            press.abandon()
        case .drawing(let stroke):
            brush = PitchEditorBrushDraft(pressedNoteID: id, stroke: stroke, shapes: [:],
                                          readout: PitchShapeBrush.readout(maxExcursionCents: 0),
                                          point: origin)
        }
    }

    /// One pointer tick of the stroke in flight: sweep it to `point` (source
    /// seconds and fractional midi, through the geometry's ONE mapping each
    /// way — the played line's own axis, the clip's transpose included), then,
    /// ONLY when what the release would write CHANGED, store the new write,
    /// its readout and the draft line. ⛔ **NEVER COMMITS.**
    ///
    /// ⚠️ C2 (per-note timing) will move a frame's EDITED second away from its
    /// source second; the pointer's x is then an edited second and needs the
    /// warp's inverse here. Until C2 lands the two are equal
    /// (`PitchPlayedLine.Point.editedSeconds`).
    private func advanceBrush(to point: CGPoint) {
        guard var current = brush else { return }
        current.stroke.move(toSourceSecond: geometry.sourceSecond(forX: point.x),
                            midi: geometry.midi(forY: point.y))
        current.point = point
        let shapes = current.stroke.commit()
        let changed = shapes != current.shapes
        if changed {
            current.shapes = shapes
            current.readout = current.stroke.readout
        }
        // `draftNotes` reads `brush`, so it is stored BEFORE the rebuild.
        brush = current
        if changed { rebuildDraftLine() }
    }

    /// The stroke ended (`PitchEditorReleaseAction.endBrush`). Emits AT MOST
    /// ONE commit — `.noteShapes` with every note the stroke drew on, the very
    /// value the last tick drew (`PitchEditorBrushDraft.shapes`) — and NONE for
    /// a stroke that changed nothing (a no-op write is an undo entry for a
    /// decision nobody made). The draft line goes with the draft: from here
    /// the line is what the STORE says.
    @discardableResult
    public func endBrush() -> PitchEditorCommit? {
        guard let current = brush else { return nil }
        brush = nil
        draftPlayedLine = nil
        draftEditSet = nil
        guard !current.shapes.isEmpty else { return nil }
        return emit(.noteShapes(shapes: current.shapes))
    }

    /// C5b-4b — a drawn note (or a sound, from a hand-written file) whose
    /// stored drawing is not empty: what "Reset drawn shape" offers to clear.
    private func hasDrawnShape(_ id: UUID) -> Bool {
        storedSegment(id)?.hasShape == true
    }

    // MARK: I6b — the window grows under a pitch drag (interaction batch §9)

    /// Every note a draft moves, at the pitch it is DRAWN at right now — the
    /// pressed note, then each member, on the clip's transposed axis.
    nonisolated static func drawnMidis(of draft: PitchEditorDragDraft) -> [Double] {
        [draft.targetMidi] + draft.members.map {
            $0.targetMidi(clipPitchShiftSemitones: draft.clipPitchShiftSemitones)
        }
    }

    /// A pitch drag held in the pane's top or bottom edge band with the
    /// viewport already against that wall (`EdgeAutoScroll.Push.isAtWall`): the
    /// WINDOW grows there instead, so the note can keep going (m23-ap I6b S2).
    /// Returns the whole rows grown now (0 for most calls: a row is earned over
    /// several ticks).
    ///
    /// The rate is `EdgeAutoScroll.growthSemitonesPerSecond` × `depthFraction`
    /// (how deep in the band, `0...1`, the scroll's own ramp) × `dt`, and the
    /// fraction of a row left over is carried in `growthRemainder`. `dt` is the
    /// caller's measured time since its last growth step; it owns the clamp
    /// that keeps a pause from arriving as a burst.
    ///
    /// Growing the TOP moves every row down, which `updatePitchDrag` takes back
    /// out through `windowTopAtPress`; growing the bottom moves nothing, but the
    /// new row sits under the viewport's edge until the view reveals it (a
    /// writer clamped against the NEW content height). A drag only: a band, a
    /// cut and an idle surface never grow the window. Commits nothing.
    @discardableResult
    public func growPitchWindowForDrag(side: EdgeAutoScroll.Side, depthFraction: CGFloat,
                                       dt: Double) -> Int {
        guard var draft = drag else { return 0 }
        let window = geometry.midiRange
        let atLimit = side == .leading
            ? window.upperBound >= PitchEditorRange.fullMidiRange.upperBound
            : window.lowerBound <= PitchEditorRange.fullMidiRange.lowerBound
        guard !atLimit else {
            growthRemainder = 0   // a pause at 0/127 banks nothing
            return 0
        }
        let depth = depthFraction.isFinite ? min(max(Double(depthFraction), 0), 1) : 0
        let step = dt.isFinite ? max(0, dt) : 0
        growthRemainder += EdgeAutoScroll.growthSemitonesPerSecond * depth * step
        let earned = Int(growthRemainder.rounded(.down))
        guard earned >= 1 else { return 0 }
        growthRemainder -= Double(earned)
        let grown = PitchEditorRange.grown(window, towards: side, by: earned)
        let rows = Int((grown.upperBound - grown.lowerBound) - (window.upperBound - window.lowerBound))
        guard rows > 0 else {
            growthRemainder = 0
            return 0
        }
        // Reached the limit mid-step: what was left over has nowhere to go.
        if rows < earned { growthRemainder = 0 }
        switch side {
        case .leading: draft.topGrowthRows += rows
        case .trailing: draft.bottomGrowthRows += rows
        }
        drag = draft
        geometry.midiRange = grown
        return rows
    }

    /// Rows the window grew by during the press in flight, or during the last
    /// one once it is over — what `debug.pitchEditor`'s `autoscroll.grownRows`
    /// reads. Reset at every press's first tick (`trackPress`).
    @ObservationIgnored public private(set) var edgeGrownRows = 0
    /// The edge the last edge step of this press (or the last one) acted at.
    @ObservationIgnored public private(set) var lastEdge: PitchEditorEdge?

    /// The longest step `edgeStep` grows the window for, in seconds: three
    /// frames at 60 Hz. A PICK (a delegated default): the pointer's events and
    /// the held repeat both arrive far faster, so this only bites after a gap —
    /// the held repeat's 200 ms wait, a staged step — where it keeps the gap
    /// from arriving as a burst of rows.
    public nonisolated static let maxEdgeStepSeconds: Double = 0.05

    /// The `dt` one edge step grows for: the time since the press's previous
    /// edge step, capped at `maxEdgeStepSeconds`; the repeat's own interval when
    /// there is no previous step to measure from. ⚠️ In the pane that `nil` is
    /// reached only by a press's own first tick, which never grows (a press
    /// pushes nothing until it has travelled): `applyEdgeStep` stamps every
    /// call, so a press's first GROWING step measures from the tick before it.
    public nonisolated static func edgeStepSeconds(sinceLastStep elapsed: Duration?) -> Double {
        guard let elapsed else {
            let interval = PianoRollEdgeRepeat.interval.components
            return Double(interval.seconds) + Double(interval.attoseconds) * 1e-18
        }
        let parts = elapsed.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
        return min(max(0, seconds), maxEdgeStepSeconds)
    }

    /// The axes the press in flight pushes along at the pane's edge, EMPTY when
    /// it pushes nothing — what the view's held-pointer clock arms on and ticks
    /// with. The same answer `edgeStep` acts on (`edgeBehaviour`), so the clock
    /// is never live where a real event would be inert.
    public var edgePushAxes: EdgeAutoScroll.Axes { edgeBehaviour?.axes ?? [] }

    /// Whether the press in flight GROWS the pitch window at a wall — the other
    /// half of `edgeStep`'s answer, read from the same switch. Exposed so the
    /// `.band` arm's "never grows" is pinned on its own (S4 follow-up): through
    /// `edgeStep` alone it cannot be seen, because `growPitchWindowForDrag`'s
    /// `drag == nil` guard also stops a band, and each guard hid the other's
    /// removal.
    public var edgeGrowsAtWall: Bool { edgeBehaviour?.grows ?? false }

    /// The one exhaustive switch behind `edgeStep` and `edgePushAxes`: the axes a
    /// press pushes along and whether it grows the window at a wall, or nil.
    private var edgeBehaviour: (axes: EdgeAutoScroll.Axes, grows: Bool)? {
        guard let current = press.current, current.isPromoted else { return nil }
        switch current.kind {
        case .noteDrag: return drag != nil ? (.vertical, true) : nil
        case .band: return band != nil ? (.both, false) : nil
        // C5a-4b — a wobble drag pushes nothing: its travel is a GAIN on the
        // note's wobble, not a position, and the note it edits never moves, so
        // a scroll under it would only change what the pointer is over.
        // C5b-4b — nor does a brush stroke: it DRAWS where the hand is, and a
        // scroll under a still pointer would draw a line the hand never made.
        // W7-NTU U3 — nor a Voice drag, for the wobble's reason: its travel is
        // a VALUE, and the note it edits never moves.
        case .cut, .none, .wobble, .brush, .formantDrag: return nil
        }
    }

    /// ⭐ **THE ONE EDGE DECISION** (m23-ap I6b S3): what a pointer at `pointer`
    /// (content space) near the pane's edge does for the press in flight. The
    /// view's live pointer, its held repeat and the staged seam all ask HERE,
    /// then write the returned targets — so none of them can decide differently.
    ///
    /// ⛔ **AN EXHAUSTIVE SWITCH ON THE PRESS KIND, NO `default`.** A new press
    /// kind (C5a's wobble, C5b's brush, C2's edge) must opt in or out here, or
    /// this does not compile:
    /// - `.noteDrag` pushes on y only: it scrolls while there is room, and at
    ///   the wall it GROWS the window (`growPitchWindowForDrag`) — the pitch
    ///   pane's divergence from the roll, whose rows are all 128 already;
    /// - `.band` scrolls on x AND y and never grows (every note is already
    ///   inside the window; its origin is content space, so a scroll does not
    ///   move it) — a DELEGATED divergence from the roll's marquee, which does
    ///   not scroll at all;
    /// - `.cut` and `.none` push nothing.
    ///
    /// Only a PROMOTED press with its draft or band live pushes: an Escape (the
    /// model's `cancelGestureForEscape`) or a cancel ends it here, with no
    /// teardown the view has to remember.
    ///
    /// `viewport`'s offset is read CLAMPED (`PitchEditorViewport.clamped`): the
    /// measured x can hold a position the scroller is not at
    /// (`shownOffsetX`'s warning), and a push measured from it would scroll from
    /// the wrong place.
    @discardableResult
    public func edgeStep(pointer: CGPoint, viewport: PitchEditorViewport, dt: Double) -> PitchEditorEdgeStep {
        guard let behaviour = edgeBehaviour else { return .none }
        let axes = behaviour.axes
        let grows = behaviour.grows
        let pushes = EdgeAutoScroll.push(pointer: pointer, offset: viewport.clamped(viewport.offset),
                                         viewport: viewport.viewportSize,
                                         content: viewport.contentSize, axes: axes)
        var step = PitchEditorEdgeStep()
        if let x = pushes.horizontal, let next = x.next {
            step.scrollX = next
            step.edge = x.side == .leading ? .left : .right
        }
        if let y = pushes.vertical {
            if let next = y.next {
                step.scrollY = next
                step.edge = y.side == .leading ? .top : .bottom
            } else if grows {
                let rows = growPitchWindowForDrag(side: y.side, depthFraction: y.depthFraction, dt: dt)
                if rows > 0 {
                    step.grownRows = rows
                    step.edge = y.side == .leading ? .top : .bottom
                    edgeGrownRows += rows
                    // The bottom's new row is under the viewport's edge: reveal
                    // it against the NEW content. The top needs no write: its
                    // rows push the content down under an offset of 0.
                    if y.side == .trailing {
                        step.scrollY = FollowPlayhead.maxOffset(contentWidth: geometry.contentHeight,
                                                                viewportWidth: viewport.viewportSize.height)
                    }
                }
            }
        }
        if let edge = step.edge { lastEdge = edge }
        return step
    }

    // MARK: I0 — the press router (interaction batch §3 item 5)

    /// The press in flight — `PitchEditorPressTracker`, which asks
    /// `PitchEditorGestureRouter` ONCE per gesture and remembers the answer.
    ///
    /// `@ObservationIgnored`: it moves on every pointer tick and nothing DRAWS
    /// it — the draft the overlay draws is `drag`, which stays observable. The
    /// debug tier sees it through the view's report to
    /// `PitchEditorInteractionBridge`.
    @ObservationIgnored public private(set) var press = PitchEditorPressTracker()

    /// What the last release did, verbatim — the seam I4 (selection) and I5 (⌘
    /// on empty places the playhead) act on; reported to the debug echo.
    @ObservationIgnored public private(set) var lastRelease: PitchEditorReleaseAction?

    /// What is under a press, for the router — the ONE hit producer the press
    /// path uses: `blob(at:)` (its slop and its nearest-by-vertical rule) on a
    /// surface that is drawing notes, `.inert` on one that is not.
    ///
    /// m23-ap C5a-4b — in the Wobble tool the DOT is asked first: its 12 pt
    /// radius reaches above the blob, past `hitSlop`, where `blob(at:)` finds
    /// nothing (`wobbleDotHit`). Every other tool reads exactly as before.
    public func pressHit(at point: CGPoint) -> PitchEditorPressHit {
        guard state.drawsNotes else { return .inert }
        if tool == .wobble, let dot = wobbleDotHit(at: point) { return .dot(dot.id) }
        return blob(at: point).map { .note($0.id) } ?? .empty
    }

    /// One pointer tick of the gesture that began at `start` (content space).
    /// Decides nothing itself: the tracker routes on the gesture's first tick,
    /// with the tool engaged NOW and the note under `start` NOW, and never asks
    /// again. ⛔ **COMMITS NOTHING** — it is the router's half of a tick; the
    /// view's `dragChanged` owns the draft.
    ///
    /// ⚠️ **A NEW PRESS DROPS A DRAFT LEFT IN FLIGHT.** Before I0 a pitch drag
    /// began at mouse-down, so every new gesture replaced whatever draft a lost
    /// `onEnded` had stranded. Now it begins only on promotion, so without this a
    /// stranded draft would take the NEXT gesture's ticks — a knife stroke or a
    /// click elsewhere would move the old note's draft. A first tick means a new
    /// gesture (`PitchEditorPressTracker.tick`), so any draft still here is the
    /// stranded one. Nothing is committed either way.
    ///
    /// ⭐ m23-ap I4 — A `.band` PRESS IS DRIVEN HERE, WHOLE. Once it travels past
    /// the slop the band arms (base = the selection at that moment, additive =
    /// ⇧/⌘ AT THE PRESS — decided once, I0's rule) and every later tick
    /// re-decides the whole selection from that frozen base. Selecting is not
    /// editing, so this still commits nothing. A band a lost `onEnded` stranded
    /// is put away on the next gesture's first tick, like a stranded draft.
    @discardableResult
    public func trackPress(start: CGPoint, location: CGPoint,
                           modifiers: ArrangeClickModifiers) -> PitchEditorPressTick {
        let tick = press.tick(start: start, location: location, tool: tool, modifiers: modifiers,
                              hit: { pressHit(at: $0) })
        if tick.isFirst, drag != nil || wobble != nil || brush != nil || voiceDrag != nil {
            drag = nil
            wobble = nil
            brush = nil
            voiceDrag = nil   // W7-NTU U3
            draftPlayedLine = nil
            draftEditSet = nil
        }
        // C5a-4b — a new press puts the dot's after-click tip away, and a
        // `.wobble` press begins its session NOW, on its first tick: the door
        // is decided at the press, and a refused press is abandoned before any
        // later tick can act on it (`beginWobble`).
        if tick.isFirst {
            wobbleTipNoteID = nil
            // W7-NTU §1(f) item 4 — a new press puts the far-move hint away.
            if !farMoveNoteIDs.isEmpty { farMoveNoteIDs = [] }
            if case .wobble(let id, let door) = tick.kind {
                beginWobble(segmentID: id, door: door, origin: start)
            }
            // W7-NTU U3 — a Voice-tool press begins its draft NOW, on its
            // first tick, from the STORED note, so a sound is refused (and the
            // press abandoned) before any later tick or its release can act.
            if case .formantDrag(let id) = tick.kind {
                beginVoiceDrag(segmentID: id)
            }
        }
        // I6b — the edge echo describes THIS press from its first tick.
        if tick.isFirst {
            edgeGrownRows = 0
            lastEdge = nil
        }
        if tick.isFirst, band != nil { cancelBand() }
        if case .band = tick.kind, tick.isPromoted, let current = press.current {
            advanceBand(origin: current.origin, to: location,
                        modifiersAtPress: current.modifiersAtPress, didPromote: tick.didPromote)
        }
        // ⭐ C5b-4b — THE BRUSH, DRIVEN HERE WHOLE, like the band: nothing
        // inside the slop (the release is then the house click), the stroke
        // begun at the PRESS point on the tick that crosses it (or refused,
        // and the press abandoned), and swept to the pointer on that tick and
        // every one after. Commits nothing: `endBrush` is the release's.
        if case .brush(let id) = tick.kind, tick.isPromoted, let current = press.current {
            if tick.didPromote { beginBrush(on: id, origin: current.origin) }
            advanceBrush(to: location)
        }
        // ⭐ m23-ap I1 UI hooks — A PRESS ON A NOTE IS HEARD, ONCE, AT ITS FIRST
        // TICK: the note as it sounds NOW (design §4, the roll's first-tick
        // sound). Decided by the router's kind, so a press on empty surface, a
        // knife press or an inert surface asks for nothing, and a later tick of
        // the same press never asks again. If the press becomes a drag, its
        // steps take over (latest wins, in the engine).
        if tick.isFirst, case .noteDrag(let id) = tick.kind {
            requestAudition(.press(segmentIDs: [id], seedIfAbsent: seedForCommit))
        }
        return tick
    }

    /// The gesture that began at `start` ended at `location`: what the release
    /// does, decided by the press it ends (never by the tool engaged at
    /// mouse-up). Recorded as `lastRelease`. Commits nothing itself.
    ///
    /// ⭐ m23-ap I4 — AND IT APPLIES THE RELEASE'S SELECTION HALF, so the answer
    /// I0 computed is ACTED ON and never decided twice: a click resolves
    /// through `PianoRollGridPress`'s table (plain on a note selects only it,
    /// ⇧/⌘ toggles it, plain on empty deselects, ⇧ on empty does nothing), and
    /// a travelled band lands its final selection at the release point.
    ///
    /// ⭐ m23-ap I5 — ⌘ ON EMPTY SURFACE (`.positionPlayhead`) PLACES THE
    /// PLAYHEAD, at the press's START x (the knife's rule: a hand that slipped
    /// during a click did not mean to move it), through `placePlayhead` — one
    /// seek, snapped unless `snapBypassed` (⌥ held at release). It still does
    /// NOT deselect: the click table sent it here, not to `.deselect`. Only a
    /// LIVE surface routes it: a surface drawing no notes is `.inert` and its
    /// press is `.none`, so there the time ruler is the way to place it. The two
    /// commit-producing answers (`.endNoteDrag`, `.cut`) stay the view's to
    /// dispatch — it owns the one path that can write.
    ///
    /// ⛔ **A CLICK ON A NOTE NEVER RETUNES IT.** Nothing here touches `drag`,
    /// so a note drawn off the scale that is clicked in place is selected and
    /// left exactly where it was (`PitchEditorModelTests` pins it on an
    /// off-grid note, with the zero-length drag that used to retune it as the
    /// positive control).
    ///
    /// W7-NTU U3 — `clickCount` is the mouse-up's own click count: the Voice
    /// tool's double-click reset reads it (`PitchEditorGestureRouter.release`),
    /// and it defaults to 1, so every caller before U3 reads as it did.
    @discardableResult
    public func releasePress(start: CGPoint, location: CGPoint,
                             modifiers: ArrangeClickModifiers,
                             snapBypassed: Bool = false,
                             clickCount: Int = 1) -> PitchEditorReleaseAction {
        // C5a-4b — ⌥ at the release is the dot's smaller step
        // (`PitchEditorGestureRouter.release`); every other kind ignores it.
        let action = press.release(start: start, at: location, modifiers: modifiers,
                                   optionAtRelease: snapBypassed, clickCount: clickCount)
        lastRelease = action
        switch action {
        case .click(let answer):
            applyClick(answer, pressStart: start, snapBypassed: snapBypassed)
        case .endBand:
            finishBand(at: location)
        case .endNoteDrag, .cut, .nothing, .endWobble, .wobbleStep, .endBrush,
             .endFormantDrag, .formantReset:
            break
        }
        // C5a-4b — a Wobble-tool press that ended as anything but its drag or
        // its step (the house click on the note's body) ends its session here:
        // nothing else would, and a stale session would keep speaking in the
        // palette's readout slot for a press that is over.
        switch action {
        case .endWobble, .wobbleStep: break
        default: wobble = nil
        }
        // W7-NTU U3 — the same for a Voice-tool press that ended as a click:
        // its draft goes here. Its drag's end and its double-click keep it for
        // the view's `endVoiceDrag` / `resetVoice`, which clear it themselves.
        switch action {
        case .endFormantDrag, .formantReset: break
        default: voiceDrag = nil
        }
        return action
    }

    // MARK: I5 — the playhead (interaction batch §8)

    /// The division a snapped placement lands on: 1/16 of a beat (design §8),
    /// `SnapResolution`'s own value and never `ClipSnap`'s (the timing doc's
    /// F21). C2-5's chip will own this later; its default already agrees.
    public nonisolated static let placementGrid: SnapResolution = .sixteenth

    /// The grid a placement snaps to RIGHT NOW: `.off` when the app's snap is
    /// off, else `placementGrid` — through `SnapResolution.effective`, the one
    /// home of that rule (the user's 2026-08-13 ruling: the note editors follow
    /// the arrange's snap ON/OFF).
    ///
    /// ⚠️ **`density: .pro` IS NOT A PREFERENCE, IT IS THE ONLY CORRECT
    /// ARGUMENT.** `effective` locks every non-Pro density to `.beat` — the
    /// roll's Simple scaffolding — and this pane has ONE mode (no Simple/Pro
    /// chip, `PitchEditorView`'s banner). Passing anything else would silently
    /// coarsen the snap to whole beats with nothing on screen to say why.
    public var placementSnap: SnapResolution {
        SnapResolution.effective(appSnap: appSnap, density: .pro, picked: Self.placementGrid)
    }

    /// **THE ONE PLACEMENT PRODUCER** (design §8): the PROJECT beat a playhead
    /// placed at content x lands on — the ruler's ticks and the ⌘-click both
    /// come here, and so does the ⌘ ghost line.
    ///
    /// Content x → the PROJECT beat (x 0 is the clip's start, through the
    /// geometry's one mapping) → snapped to `placementSnap` ON THE SONG'S GRID
    /// unless ⌥ bypasses it → clamped to the clip by
    /// `PianoRollPlayhead.projectBeat`.
    ///
    /// ⭐ **I5-F1 (2026-09-25): THE SNAP IS IN SONG SPACE, NOT CLIP-LOCAL.** I5
    /// snapped the clip-local beat, to match a ruler numbered from the clip's
    /// first beat; that ruler named a different bar from the transport for any
    /// vocal that does not start on a bar line. The ruler now numbers the song's
    /// bars (`PitchEditorSongRuler`), so the playhead lands on the song's 1/16 —
    /// the lines the transport, the arrange and this ruler all count. Song bars
    /// start on whole beats (`MeterMap` puts every change on a barline, from
    /// beat 0), so a 1/16 grid from beat 0 is the song's grid under any meter.
    /// `PianoRollPlayhead.projectBeat`'s "snap in clip-local space" warning is
    /// the ROLL's, whose grid lines are clip-local; this pane draws none.
    ///
    /// ⚠️ **THE CLAMP WINS AT THE CLIP'S EDGES, SO AN EDGE CAN BE OFF THE GRID.**
    /// A clip starting at beat 3.1: x 0 snaps to 3.0, outside the clip, and
    /// clamps back to 3.1. The clip's own start and end are honest places to put
    /// the playhead, and walking the transport out of the editor's span is what
    /// the clamp exists to prevent.
    ///
    /// ⚠️ `x` IS CONTENT SPACE. A caller holding a VIEWPORT x (the ruler, which
    /// does not scroll) adds the scroll offset first, in exactly one place
    /// (`PitchEditorView.rulerTick`); a caller on the surface (the ⌘-click) is
    /// already in content space and must add nothing.
    public func placementBeat(atContentX x: CGFloat, snapBypassed: Bool) -> Double {
        let project = geometry.projectBeat(forX: x)
        let placed = snapBypassed ? project : placementSnap.snapped(project)
        return PianoRollPlayhead.projectBeat(localBeat: placed - geometry.startBeat,
                                             clipStartBeat: geometry.startBeat,
                                             lengthBeats: geometry.lengthBeats)
    }

    /// Place the playhead at content x: one seek through `onSeek`, carrying
    /// `placementBeat`. The time ruler's every tick calls this (click jumps, drag
    /// scrubs), and nothing else seeks but the ⌘-click below. Returns the beat
    /// it asked for, so a caller can report it.
    @discardableResult
    public func placePlayhead(atContentX x: CGFloat, snapBypassed: Bool) -> Double {
        let beat = placementBeat(atContentX: x, snapBypassed: snapBypassed)
        placementCount += 1
        lastPlacementBeat = beat
        onSeek?(beat)
        return beat
    }

    /// How many placements this model has asked for, ever — the `commitCount`
    /// discipline: counted, never reasoned about. With `lastPlacementBeat` it is
    /// what `debug.pitchEditor`'s `playhead` echo shows of what was ASKED, beside
    /// the transport's own position (what the store DID): a seek that failed
    /// quietly shows up as the two disagreeing. `@ObservationIgnored`: nothing
    /// draws it.
    @ObservationIgnored public private(set) var placementCount = 0
    /// The project beat the last placement asked for, or `nil` before any.
    @ObservationIgnored public private(set) var lastPlacementBeat: Double?

    // MARK: I4 — the selection's writers (interaction batch §7)

    /// THE ONE WRITER of `selection`. Compares first, so `selectionToken`
    /// re-mints on a real change and never on a write of the same set.
    private func setSelection(_ next: Set<UUID>) {
        guard next != selection else { return }
        selection = next
        selectionToken = UUID()
    }

    /// Whether this note is selected.
    public func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    /// What the pane's status line says about the selection — `nil` when
    /// nothing is selected (the line says nothing rather than "0 notes
    /// selected"), "1 note selected", "3 notes selected". Resolved HERE so the
    /// wording is tested headless; the view draws it verbatim.
    ///
    /// UE-1: SOUNDS are counted as sounds — "1 sound selected", "2 notes and 1
    /// sound selected" — the menu's own nouns (`PitchEditorNoteMenu`), so the
    /// status line and "Clear Sound" never disagree about what is selected. A
    /// selection with no sound reads exactly as before.
    public var selectionSummary: String? {
        let sounds = selection.isEmpty ? 0 : blobs.reduce(into: 0) { count, blob in
            if blob.isUnpitched, selection.contains(blob.id) { count += 1 }
        }
        if sounds > 0 {
            // The selection only ever holds DRAWN ids, so the rest are notes.
            let notes = selection.count - sounds
            let soundWords = sounds == 1 ? "1 sound" : "\(sounds) sounds"
            guard notes > 0 else { return "\(soundWords) selected" }
            let noteWords = notes == 1 ? "1 note" : "\(notes) notes"
            return "\(noteWords) and \(soundWords) selected"
        }
        switch selection.count {
        case 0: return nil
        case 1: return "1 note selected"
        case let count: return "\(count) notes selected"
        }
    }

    /// UE-2 — WHAT KINDS the selection holds (`NoteBlob.menuTarget`'s kind):
    /// `[.note]`, `[.sound]`, both, or empty. The Edit menu's Clear title reads
    /// it through the pane's bridge (`PitchEditorInteractionBridge
    /// .selectionKinds` → `DeleteMenuPolicy`), so "Clear Selected Sounds" and
    /// the note menu's "Clear Sound" come from one noun table
    /// (`PitchEditorNoteMenu.selectionClearTitle`). A selected id's kind cannot
    /// change under it (`NoteSegment.origin` is a `let`, and the merge never
    /// re-identifies a segment), so the pane reports it on `selectionToken`.
    public var selectionKinds: Set<PitchEditorNoteMenu.Kind> {
        guard !selection.isEmpty else { return [] }
        var kinds: Set<PitchEditorNoteMenu.Kind> = []
        for blob in blobs where selection.contains(blob.id) {
            kinds.insert(blob.menuTarget.kind)
            if kinds.count == 2 { break }
        }
        return kinds
    }

    /// Select exactly this note — a plain click on it. A note this surface
    /// does not draw is ignored: the selection only ever holds drawn notes.
    public func selectOnly(_ id: UUID) {
        guard isDrawn(id) else { return }
        setSelection([id])
        soundsSelectedOnlyByAll = []
    }

    /// Add this note to the selection, or take it out — a ⇧ or ⌘ click on it.
    /// vf-19: either way the user CHOSE it, so a sound clicked back in after
    /// Select All rides a group drag again.
    public func toggle(_ id: UUID) {
        guard isDrawn(id) else { return }
        var next = selection
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        setSelection(next)
        soundsSelectedOnlyByAll.remove(id)
    }

    /// Select nothing — a plain click on empty surface, Escape's
    /// `.clearSelection` rung, the debug tier's `clearSelection` act.
    public func clearSelection() {
        setSelection([])
        soundsSelectedOnlyByAll = []
    }

    /// Select EVERY DRAWN note — ⌘A / Edit ▸ Select All (routed by
    /// `SelectAllMenuPolicy` to `.pitchEditorNotes`, handed over
    /// `PitchEditorInteractionBridge.selectAllNonce`) and the debug tier's
    /// `selectAll` act. REPLACES, never unions — the roll's `selectAllNotes`.
    ///
    /// vf-19: the SOUNDS it takes are remembered as taken by Select All, so a
    /// group pitch drag leaves them where they are
    /// (`soundsSelectedOnlyByAll`). They are still selected.
    public func selectAll() {
        setSelection(Set(blobs.map(\.id)))
        soundsSelectedOnlyByAll = Set(blobs.lazy.filter(\.isUnpitched).map(\.id))
    }

    private func isDrawn(_ id: UUID) -> Bool { blobs.contains { $0.id == id } }

    /// The click table's answer, acted on (see `releasePress`).
    private func applyClick(_ answer: PianoRollGridRelease, pressStart: CGPoint,
                            snapBypassed: Bool) {
        switch answer {
        case .selectOnly(let id): selectOnly(id)
        case .toggle(let id): toggle(id)
        case .deselect: clearSelection()
        case .positionPlayhead:
            // I5 — ⌘ on empty surface places the playhead where the press
            // BEGAN (content space: the surface's own point, no scroll term).
            // It does NOT deselect: the click table sent it here, not to
            // `.deselect`.
            placePlayhead(atContentX: pressStart.x, snapBypassed: snapBypassed)
        case .doNothing:
            break
        }
    }

    /// THE SELECTION FOLLOWS THE NOTE TABLE, the roll's `survivors` rule
    /// (`PianoRollModel.reseed`), plus one rule the roll has no need for.
    ///
    /// 1. **Pruned to what is drawn.** A note the new table no longer has, or
    ///    no longer draws, cannot stay selected — a selection naming a note
    ///    nobody can see is a delete (I7b) aimed at nothing the user chose.
    /// 2. **A split's right half joins a selected parent.** The store keeps the
    ///    parent's id on the LEFT half and mints the right one
    ///    (`ProjectStore.splitClipNoteSegment`), so without this a selected note
    ///    cut in two would come back half selected. Recognised from the two
    ///    tables rather than from a remembered commit, so a split that arrives
    ///    any way at all (the wire, a redo) behaves the same: a NEW note that
    ///    starts exactly where a selected note now ends, and ends exactly where
    ///    that note used to end, is its right half.
    ///
    /// ⭐ The FIRST commit on a clip with no stored table hands the seed back
    /// verbatim (`ProjectStore.noteTable(seedIfAbsent:)`), so the ids survive it
    /// and nothing is pruned.
    private func reconcileSelection(previous: PitchEditSet) {
        guard !selection.isEmpty else { return }
        let drawn = Set(blobs.map(\.id))
        var next = selection.intersection(drawn)
        let before = Dictionary(previous.segments.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let now = noteTable.segments
        for parent in now where next.contains(parent.id) {
            guard let old = before[parent.id], parent.endSeconds < old.endSeconds else { continue }
            if let right = now.first(where: {
                before[$0.id] == nil && $0.startSeconds == parent.endSeconds
                    && $0.endSeconds == old.endSeconds
            }), drawn.contains(right.id) {
                next.insert(right.id)
                // vf-19: a sound Select All took keeps that status in both halves.
                if soundsSelectedOnlyByAll.contains(parent.id) { soundsSelectedOnlyByAll.insert(right.id) }
            }
        }
        setSelection(next)
        // vf-19: a sync PRUNES, it never chooses: what Select All took stays so.
        soundsSelectedOnlyByAll.formIntersection(next)
    }

    /// A tick of a promoted `.band` press: arm the band on the promoting tick,
    /// then re-decide the selection from its frozen base.
    private func advanceBand(origin: CGPoint, to location: CGPoint,
                             modifiersAtPress: ArrangeClickModifiers, didPromote: Bool) {
        if band == nil {
            guard didPromote else { return }
            band = PitchEditorBand(
                origin: origin, base: selection,
                additive: ArrangeClickIntent.intent(for: modifiersAtPress) == .toggle,
                rect: .zero, hits: [])
            soundsSelectedOnlyByAllAtBandArm = soundsSelectedOnlyByAll
        }
        updateBand(to: location)
    }

    /// Re-decide the WHOLE selection for the band's current corner — from the
    /// frozen base, so growing the band adds notes and shrinking it gives them
    /// back. The hits are `PianoRollMarquee.hits` over `hitRects()`, the SAME
    /// rects the click tests; the rule is `PianoRollMarquee.selection`.
    private func updateBand(to location: CGPoint) {
        guard var live = band else { return }
        live.rect = PianoRollMarquee.band(from: live.origin, to: location)
        live.hits = PianoRollMarquee.hits(band: live.rect, rects: hitRects())
        band = live
        setSelection(PianoRollMarquee.selection(base: live.base, hits: live.hits,
                                                additive: live.additive))
        // vf-19: a sound the band touches is CHOSEN; a replacing band chose
        // everything it holds.
        soundsSelectedOnlyByAll = live.additive
            ? soundsSelectedOnlyByAllAtBandArm.subtracting(live.hits) : []
    }

    /// The band's release: its final selection lands, and the band goes.
    private func finishBand(at location: CGPoint) {
        guard band != nil else { return }
        updateBand(to: location)
        band = nil
    }

    /// Put a live band away WITHOUT applying it: the selection goes back to
    /// the base it armed with.
    private func cancelBand() {
        guard let live = band else { return }
        band = nil
        setSelection(live.base)
        soundsSelectedOnlyByAll = soundsSelectedOnlyByAllAtBandArm
    }

    // MARK: I4 — the group pitch drag (interaction batch §7)

    /// The Move tool's press on a note travelled past the slop (I0's
    /// promotion): drag the SELECTION's pitch (m23-ap I4). An UNSELECTED note
    /// is selected first — alone, or added to the selection when the press
    /// carried ⇧ (the house additive chord, `ArrangeClickIntent`; since C5b-4b
    /// a ⌘-press on a note is the BRUSH and never reaches here). The
    /// pressed note is the drag's anchor — `beginPitchDrag(on:)`, UNCHANGED —
    /// and every OTHER selected, drawn note rides along as a member.
    ///
    /// ⭐ **A LONE SELECTED NOTE IS THE ONE-NOTE DRAG, BYTE FOR BYTE.** With no
    /// other note selected there are no members, `updatePitchDrag` never enters
    /// its group branch, and the release commits `.notePitch` under the
    /// `.segment` undo key exactly as before I4.
    ///
    /// ⭐ vf-19: **A SOUND SELECT ALL TOOK DOES NOT RIDE**
    /// (`soundsSelectedOnlyByAll`). Select All then a drag moves every pitched
    /// note by the one delta and writes nothing to the sounds, so a breath or
    /// an "s" keeps its own pitch (and its level: a moved sound enters the
    /// pitch and formant curves). The PRESSED blob always moves, and pressing
    /// a sound chooses it. A sound the user picked (a click, a ⇧/⌘ click, a
    /// band) rides as UE-1 says.
    @discardableResult
    public func beginSelectionPitchDrag(on blob: NoteBlob) -> Bool {
        guard tool == .pointer, isDrawn(blob.id) else { return false }
        if !selection.contains(blob.id) {
            let additive = press.current.map {
                ArrangeClickIntent.intent(for: $0.modifiersAtPress) == .toggle
            } ?? false
            setSelection(additive ? selection.union([blob.id]) : [blob.id])
            if !additive { soundsSelectedOnlyByAll = [] }
        }
        soundsSelectedOnlyByAll.remove(blob.id)
        guard beginPitchDrag(on: blob), var draft = drag else { return false }
        let others = blobs.filter {
            $0.id != blob.id && selection.contains($0.id) && !soundsSelectedOnlyByAll.contains($0.id)
        }
        guard !others.isEmpty else { return true }
        // ⭐ vf-18 leg 3 — THE CARRY, ONCE PER GESTURE, FROM DAWCORE'S ONE HOME.
        // The moving set (the pressed note and every member) is fixed from
        // here to the release, so each note's `k` is too: read it now from
        // `PitchEditSet.groupMoveCarries` — the factor `applyingGroupPitchMove`
        // stores with, under the rule the release will store — and never per
        // tick. A followed slide whose anchors ride this drag takes `1 − follow`
        // of the delta (its bridge brings the rest); everything else takes 1,
        // which keeps the I4 arithmetic verbatim.
        let moving = Set([blob.id] + others.map(\.id))
        let carries = noteTable.groupMoveCarries(movingIDs: moving)
        draft.carry = carries[blob.id] ?? 1
        draft.members = others.map {
            PitchEditorDragMember(segmentID: $0.id, startSeconds: $0.startSeconds,
                                  endSeconds: $0.endSeconds, detectedMidi: $0.centreMidi,
                                  baselineCents: $0.offsetCents, offsetCents: $0.offsetCents,
                                  isUnpitched: $0.isUnpitched, carry: carries[$0.id] ?? 1,
                                  followCents: $0.followCents)
        }
        drag = draft
        rebuildDraftLine()
        return true
    }

    /// `updatePitchDrag`'s GROUP branch (m23-ap I4).
    ///
    /// ⭐ **ONE DELTA, SO THE INTERVALS ARE KEPT.** The pressed note resolves its
    /// landing as the one-note drag does — snapped to the scale, or free with
    /// ⌥ — and every other selected note takes the SAME landed delta. A member
    /// is never snapped on its own: that would bend the intervals the user
    /// sang between the notes.
    ///
    /// ⛔ **THE CLAMP IS THE TIGHTEST MEMBER'S** (`groupDeltaBounds`): the delta
    /// is limited so that NO moving note leaves the visible window — the
    /// data-loss rule of the one-note branch, applied to every note at once —
    /// or the stored offset range. Clamping each note on its own instead would
    /// flatten the group against the edge and change its shape.
    ///
    /// Snapping inside those bounds: the pressed note lands on the nearest
    /// scale pitch; if that is outside the bounds it steps to the nearest scale
    /// pitch inside them, and if there is none the group stays where it is.
    private func updateGroupPitchDrag(_ draft: inout PitchEditorDragDraft,
                                      origin: Double, raw: Double, free: Bool) {
        let shift = draft.clipPitchShiftSemitones
        // vf-18 leg 3: each member's origin is where it is DRAWN at the press
        // (`originMidi`, a followed slide's neighbours included; the
        // three-term conversion verbatim for everything else). The bounds'
        // cents term still assumes k = 1: for a carried slide (k < 1) that is
        // TIGHTER than `applyingGroupPitchMove`'s own range, never looser, so
        // the release can never be refused.
        let origins = [origin] + draft.members.map { $0.originMidi(clipPitchShiftSemitones: shift) }
        let baselines = [draft.baselineCents] + draft.members.map(\.baselineCents)
        let bounds = Self.groupDeltaBounds(origins: origins, baselines: baselines,
                                           window: geometry.midiRange)
        let rawDelta = raw - origin
        let delta: Double
        let landed: Double
        if free {
            delta = min(max(rawDelta, bounds.lowerBound), bounds.upperBound)
            landed = origin + delta
        } else {
            (delta, landed) = snappedGroupLanding(origin: origin, rawDelta: rawDelta, bounds: bounds)
        }
        draft.isFree = free
        // A zero delta writes the baselines back EXACTLY, so a group released
        // where it began is a no-op and commits nothing — never a write of a
        // float's rounding error.
        // vf-18 leg 3: the pressed note at k == 1 lands as I4 always did (its
        // snapped drawn pitch, back through the one conversion, minus what its
        // unmoving neighbours add when it is a slide pressed without them);
        // a CARRIED pressed slide (k < 1) stores `baseline + delta·100·k`, the
        // one transform's expression — its drawn pitch still lands on
        // `landed`, because its anchors bring the rest.
        if delta == 0 {
            draft.offsetCents = draft.baselineCents
        } else if draft.carry == 1 {
            draft.offsetCents = PitchEditorGeometry.storedOffsetCents(
                drawnMidi: landed, centreMidi: draft.detectedMidi,
                followCents: draft.baselineFollowCents,
                clipPitchShiftSemitones: shift).clamped(to: NoteSegment.pitchOffsetCentsRange)
        } else {
            draft.offsetCents = (draft.baselineCents + delta * 100 * draft.carry)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
        }
        for index in draft.members.indices {
            draft.members[index].offsetCents = draft.members[index].movedOffsetCents(forDelta: delta)
        }
        let moved = draft.offsetCents != drag?.offsetCents || draft.members != drag?.members
        drag = draft
        // I1 UI hooks: one drag step per change of the GROUP's offsets, the
        // one-note branch's rule (and its floor) — the whole selection is heard
        // moving.
        if moved {
            rebuildDraftLine()
            requestDragAudition(draft)
        }
    }

    /// The delta, in DRAWN semitones, every moving note can take — the
    /// intersection over the notes of "stay inside the window" and "stay inside
    /// `NoteSegment.pitchOffsetCentsRange`". A note ALREADY outside either is
    /// never pushed further out but may come back in, so the result always
    /// contains 0 and a group can always stay where it is.
    nonisolated static func groupDeltaBounds(origins: [Double], baselines: [Double],
                                             window: ClosedRange<Double>) -> ClosedRange<Double> {
        let cents = NoteSegment.pitchOffsetCentsRange
        var lower = -Double.infinity
        var upper = Double.infinity
        for (origin, baseline) in zip(origins, baselines) {
            lower = max(lower, min(0, window.lowerBound - origin),
                        min(0, (cents.lowerBound - baseline) / 100))
            upper = min(upper, max(0, window.upperBound - origin),
                        max(0, (cents.upperBound - baseline) / 100))
        }
        return lower...upper
    }

    /// The pressed note's snapped landing inside `bounds` (see
    /// `updateGroupPitchDrag`), as (delta, landed pitch).
    private func snappedGroupLanding(origin: Double, rawDelta: Double,
                                     bounds: ClosedRange<Double>) -> (Double, Double) {
        let target = origin + min(max(rawDelta, bounds.lowerBound), bounds.upperBound)
        var landed = snapScale.nearestAllowedMidi(to: target)
        if landed - origin > bounds.upperBound {
            landed = allowedMidi(from: origin + bounds.upperBound, step: -1) ?? origin
        } else if landed - origin < bounds.lowerBound {
            landed = allowedMidi(from: origin + bounds.lowerBound, step: 1) ?? origin
        }
        let delta = landed - origin
        // No scale pitch inside the bounds at all: the group stays put.
        guard delta <= bounds.upperBound + 1e-9, delta >= bounds.lowerBound - 1e-9 else {
            return (0, origin)
        }
        return (min(max(delta, bounds.lowerBound), bounds.upperBound), landed)
    }

    /// The nearest whole-semitone pitch the scale allows, walking from `midi`
    /// in `step`'s direction (the first candidate is `midi` rounded that way).
    private func allowedMidi(from midi: Double, step: Double) -> Double? {
        let allowed = Set(snapScale.allowedPitchClasses)
        var candidate = step < 0 ? midi.rounded(.down) : midi.rounded(.up)
        for _ in 0...12 {
            if allowed.contains(((Int(candidate) % 12) + 12) % 12) { return candidate }
            candidate += step
        }
        return nil
    }

    // MARK: UE-1 — a sound with no pitch is dragged RELATIVELY (unpitched design §1.7)

    /// `updatePitchDrag`'s branch for a drag whose PRESSED blob is a SOUND and
    /// ⌥ is NOT held — one sound, or a group led by one (UE-1).
    ///
    /// ⭐ **WHOLE SEMITONES FROM WHERE IT SITS** (§1.7, U5 as kept by
    /// natural-tuning R21: a sound the user drags on purpose still moves). A
    /// sound's drawn pitch is borrowed from its neighbour (§1.5), so snapping
    /// it to the SCALE would snap a guess: the sound moves by a whole number of
    /// semitones, `k`, from its offset at the press, and its stored offset is
    /// EXACTLY `baseline + 100·k` — never routed through
    /// `PitchEditorGeometry.storedOffsetCents`, whose float round trip would
    /// put a sound a hair off "whole" and make a release at the start read as a
    /// move (`isNoOp`). A sound sung 37 c off its anchor stays 37 c off it.
    ///
    /// ⭐ **THE GROUP RULE: THE PRESSED BLOB DECIDES THE SNAP; EVERY MEMBER RIDES
    /// THE ONE DELTA.** Pressing a sound, every other selected blob — note or
    /// sound — moves by the same `k` semitones, so the intervals are kept and a
    /// note riding along lands `100·k` c from where it was, not on the scale.
    /// Pressing a NOTE is the I4 group branch, unchanged: the note snaps to the
    /// scale and every sound riding along takes that (possibly fractional)
    /// delta, so it stays drawn at the note it borrowed its pitch from — "a
    /// sound drawn away from its word cannot be read as part of it" (§1.5).
    /// A notes-only drag never reaches this function
    /// (`ue1NotesOnlyDragIsBitIdenticalToTheFrozenArithmetic`). vf-19: "every
    /// member" never includes a sound only Select All took
    /// (`beginSelectionPitchDrag`).
    ///
    /// ⛔ **THE CLAMP IS `groupDeltaBounds`', the tightest member's** (the I4
    /// data-loss rule, one home for one sound or many), narrowed to its whole
    /// semitones. Those bounds always contain 0, so a sound can always stay
    /// where it is.
    private func updateSoundPitchDrag(_ draft: inout PitchEditorDragDraft,
                                      origin: Double, raw: Double) {
        let shift = draft.clipPitchShiftSemitones
        // vf-18 leg 3: members' drawn origins and carries as in the I4 group
        // branch (`originMidi`, `movedOffsetCents(forDelta:)`). A sound cannot be
        // made to follow (`applyingNoteGlideFollow` refuses it), so the
        // pressed sound's carry is 1 and its arithmetic below is untouched;
        // only a hand-written file that gives a sound a follow reaches `k < 1`.
        let origins = [origin] + draft.members.map { $0.originMidi(clipPitchShiftSemitones: shift) }
        let baselines = [draft.baselineCents] + draft.members.map(\.baselineCents)
        let bounds = Self.groupDeltaBounds(origins: origins, baselines: baselines,
                                           window: geometry.midiRange)
        let semitones = Self.wholeSemitones(raw - origin, within: bounds)
        draft.isFree = false
        // Zero writes the baseline back EXACTLY: released where it began is a
        // no-op, never a write of a rounding error (the group branch's rule).
        if semitones == 0 {
            draft.offsetCents = draft.baselineCents
        } else if draft.carry == 1 {
            draft.offsetCents = (draft.baselineCents + semitones * 100)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
        } else {
            draft.offsetCents = (draft.baselineCents + semitones * 100 * draft.carry)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
        }
        for index in draft.members.indices {
            draft.members[index].offsetCents = draft.members[index].movedOffsetCents(forDelta: semitones)
        }
        let moved = draft.offsetCents != drag?.offsetCents || draft.members != drag?.members
        drag = draft
        // I1 UI hooks, unchanged: one drag step per change of the offsets. Every
        // step here is a whole semitone (100 c), above the detector floor the
        // audition thins at, so each one is HEARD — a transposed breath, which
        // U5 accepts; the release plays it too (`commitLanded`). Never a silent
        // no-op.
        if moved {
            rebuildDraftLine()
            requestDragAudition(draft)
        }
    }

    /// `delta` (drawn semitones) rounded to the nearest WHOLE semitone —
    /// half a row moves one, the snap's own nearest rule — and held inside the
    /// whole semitones of `bounds`. `bounds` comes from `groupDeltaBounds`,
    /// which always contains 0, so the result range is never empty. A
    /// non-finite delta moves nothing.
    nonisolated static func wholeSemitones(_ delta: Double,
                                           within bounds: ClosedRange<Double>) -> Double {
        guard delta.isFinite else { return 0 }
        let lower = min(0, bounds.lowerBound.rounded(.up))
        let upper = max(0, bounds.upperBound.rounded(.down))
        return min(max(delta.rounded(), lower), upper)
    }

    // MARK: I3 — the cut line (interaction batch §6)

    /// Whether the Split tool is LIVE: engaged, AND the surface is drawing notes
    /// it could cut. These are the knife's own two preconditions — `splitNote`'s
    /// tool guard and the view's `state.drawsNotes` guard in `dragEnded` — stated
    /// once, so the hover line can never offer a cut the click would silently
    /// ignore (a load still running, a take with no notes).
    public var isCutToolLive: Bool { tool == .scissors && state.drawsNotes }

    /// The pointer the surface shows while hovered: the crosshair while the
    /// Split tool is live (the "precise place" family, `CursorKind.crosshair`;
    /// design §6), nothing special otherwise. There is deliberately no
    /// `CursorAffordance` case for it: that catalog lists surfaces that advertise
    /// a cursor AT REST, and this one is tool-gated, like the roll's ⌘ bar.
    public var surfaceCursor: CursorKind? { isCutToolLive ? .crosshair : nil }

    /// m23-ap I5 — whether a click at `point` with this chord would PLACE THE
    /// PLAYHEAD: the press router's own answer (`.band` — the Move tool, on a live
    /// surface, with no note under the point) and the house click table's
    /// (`PianoRollGridPress.placesPlayhead`), asked exactly as the press and the
    /// release will ask them — so the ⌘ affordance can never promise a playhead
    /// and deliver a deselect (the roll's `playheadPlaceGhost` rule).
    public func placesPlayhead(at point: CGPoint, modifiers: ArrangeClickModifiers) -> Bool {
        guard PitchEditorGestureRouter.route(tool: tool, modifiersAtPress: modifiers,
                                             hit: pressHit(at: point)) == .band else { return false }
        return PianoRollGridPress.placesPlayhead(noteID: nil, modifiers: modifiers)
    }

    /// The pointer over the surface at `point` with this chord held: the
    /// transport's `.verticalBar` where a click would place the playhead (⌘ on
    /// empty surface), else `surfaceCursor`. The ruler wears the same bar.
    ///
    /// m23-ap C5b-4b — and ⌘ over a note the brush WOULD draw on (the band's
    /// own two questions: the router says `.brush`, and `begin` does not
    /// refuse) wears the `.crosshair`, the "precise place / paint" family
    /// (`CursorKind`). The design's pencil would be a NEW family, which
    /// `docs/DESIGN-LANGUAGE.md` asks for by name, not by hand-coding; where
    /// the brush would refuse, the pointer stays plain and the band is dim.
    public func surfaceCursor(at point: CGPoint, modifiers: ArrangeClickModifiers) -> CursorKind? {
        if placesPlayhead(at: point, modifiers: modifiers) { return .verticalBar }
        if let id = brushNote(at: point, modifiers: modifiers),
           brushStart(on: id, at: point).refusal == nil {
            return .crosshair
        }
        return surfaceCursor
    }

    /// ⭐⭐ **THE ONE VERDICT** (I3, design §6 D3): what the Split tool would do
    /// at `point`. The hover line (`cutLine(at:)`) carries it and the knife
    /// (`splitNote(at:)`) switches over it, so the two cannot disagree —
    /// `PitchEditorModelTests` sweeps 200 points to hold them to that.
    ///
    /// The cut lands where the pointer is, converted through the ONE coordinate
    /// home. The floor is `ProjectStore.splitClipNoteSegment`'s rule, restated
    /// here only so the user sees it BEFORE the store refuses — from
    /// `PitchAutoCorrect.minimumNoteSeconds`, never from a second constant.
    ///
    /// Tool-agnostic on purpose: which tool is engaged is the READERS' guard
    /// (`isCutToolLive`, `splitNote`'s own), not part of what the geometry says.
    public func cutVerdict(at point: CGPoint) -> PitchEditorCutVerdict {
        resolveCut(at: point).verdict
    }

    /// What the cut line draws at a hover point, or `nil` when nothing is drawn
    /// (the Split tool is not live, or the pointer is off the surface). Its
    /// verdict IS `cutVerdict(at:)` — this adds only where to draw it.
    public func cutLine(at point: CGPoint?) -> PitchEditorCutLine? {
        guard isCutToolLive, let point else { return nil }
        let resolved = resolveCut(at: point)
        return PitchEditorCutLine(x: point.x,
                                  sourceSecond: geometry.sourceSecond(forX: point.x),
                                  verdict: resolved.verdict,
                                  noteRect: resolved.blob.map { rect(for: $0) })
    }

    /// The verdict AND the note it found, from ONE hit test, so the line's
    /// glowing segment is drawn on exactly the note the verdict is about.
    private func resolveCut(at point: CGPoint) -> (verdict: PitchEditorCutVerdict, blob: NoteBlob?) {
        guard let blob = blob(at: point) else { return (.noNote, nil) }
        let cut = geometry.sourceSecond(forX: point.x)
        let floor = PitchAutoCorrect.minimumNoteSeconds
        let left = cut - blob.startSeconds
        let right = blob.endSeconds - cut
        guard left >= floor, right >= floor else {
            return (.tooCloseToEdge(segmentID: blob.id, atSourceSecond: cut,
                                    minimumMs: floor * 1000), blob)
        }
        return (.cut(segmentID: blob.id, atSourceSecond: cut,
                     leftMs: left * 1000, rightMs: right * 1000), blob)
    }

    /// Cut the note under a point in two (C3). Returns the commit it emitted,
    /// or `nil` — and sets `refusal` to teaching prose whenever it returned
    /// `nil` for a reason the user can act on.
    ///
    /// ⭐ **A `switch` OVER `cutVerdict(at:)` AND NOTHING ELSE** (I3): the knife
    /// cuts exactly where the hover line said "cut", at the same second, and
    /// refuses exactly where it did not. The click itself is unchanged by I3 —
    /// the same two sentences, word for word (`splitRefusalsAreSpokenNotSilent`
    /// pins them): the hover's amber is a PREDICTION on the line, and nothing is
    /// refused until the click.
    @discardableResult
    public func splitNote(at point: CGPoint) -> PitchEditorCommit? {
        guard tool == .scissors else { return nil }
        refusal = nil
        switch cutVerdict(at: point) {
        case .noNote:
            refusal = "Nothing to cut there. Click on one of the notes."
            return nil
        case .tooCloseToEdge(_, _, let minimumMs):
            refusal = "That is too close to the edge of the note. Each half has to be at "
                + "least \(Int(minimumMs.rounded())) milliseconds long — zoom in and "
                + "click nearer the middle."
            return nil
        case .cut(let segmentID, let atSourceSecond, _, _):
            return emit(.splitNote(segmentID: segmentID, atSourceSecond: atSourceSecond))
        }
    }

    // MARK: I6a — ESCAPE on this pane

    /// ESCAPE was pressed while this pane held key focus (m23-ap I6a). Returns
    /// whether the key was consumed; `false` lets it keep propagating to the
    /// arrange workspace's backstop mount, exactly as the roll's does.
    ///
    /// `appDecision` is the app's ONE Escape decision
    /// (`AppModel.handleEditorEscape`: leave the maximized mode, refused while a
    /// modal or a rename field owns the key). The pane never re-decides it.
    ///
    /// ⭐⭐ **THE SEAM I4 FILLS — THE ONLY PLACE ITS LADDER GOES.** I4 (design §7,
    /// "Esc") builds `EditorEscapeLadder.resolve(gestureLive:hasSelection:
    /// maximized:blocked:)` for BOTH editors: `.cancelGesture` and
    /// `.clearSelection` are answered HERE, from this model's own `drag` and
    /// selection, and consume the key without asking the app; `.exitMaximize`
    /// falls through to `appDecision`; `.pass` returns false. Until I4 lands
    /// there is no selection to clear and no cancel rung, so every press goes
    /// straight to the app — which means a press during a live pitch drag still
    /// only leaves the maximized mode (`PitchEditorModelTests` pins that today's
    /// behaviour, and I4 is expected to change that test on purpose).
    ///
    /// ⭐ **FILLED AT I4.** `appDecision` is now handed THIS pane's two facts —
    /// is a gesture live (`escapeGestureLive`), is anything selected — and
    /// returns the ladder's rung (`EditorEscapeLadder`, resolved ONCE by the
    /// app, which alone knows the mode and whether a modal or a rename field
    /// owns the key). The pane applies the two rungs that are its own —
    /// `.cancelGesture` (`cancelGestureForEscape`) and `.clearSelection` — and
    /// the app has already applied `.exitMaximize`. So a press during a live
    /// pitch drag now CANCELS the drag (the old leg of
    /// `escapeAsksTheAppDecisionOnce`, rewritten on purpose), and a press with
    /// notes selected clears them before the mode is left.
    ///
    /// ⭐ **m23-ap I1 UI hooks (the RT review's H5): EVERY ESCAPE THAT REACHES
    /// THE PANE STOPS A SOUNDING NOTE AUDITION FIRST — AND THEN DOES EXACTLY
    /// WHAT THE LADDER SAYS.** Not a rung: the ladder is untouched, so the
    /// first press still cancels the drag or clears the selection as it always
    /// did, and stops the sound with it. Both routes land here (the key
    /// monitor's hand-off and this pane's own mount), one per press, so one
    /// Escape is one stop. The note the audition plays was pressed or dragged,
    /// which selected it, so the monitor route has something to take down and
    /// hands the key over.
    public func handleEscapeKey(
        appDecision: (_ gestureLive: Bool, _ hasSelection: Bool) -> EditorEscapeRung
    ) -> Bool {
        requestAudition(.stop)
        let rung = appDecision(escapeGestureLive, !selection.isEmpty)
        switch rung {
        case .cancelGesture: cancelGestureForEscape()
        case .clearSelection: clearSelection()
        case .exitMaximize, .pass: break
        }
        return rung.consumesKey
    }

    /// Whether this pane holds a gesture Escape would cancel: a pitch drag or a
    /// band in flight. A press still inside the slop is not one — nothing on
    /// screen has changed yet.
    ///
    /// C5a-4b — a wobble DRAG is one too (its draft line is on screen); a dot
    /// press still inside the slop is not.
    ///
    /// W7-NTU U3 — a Voice DRAG too (its bar and chip are moving on screen); a
    /// Voice press still inside the slop is not.
    public var escapeGestureLive: Bool {
        drag != nil || band != nil || wobble?.isDragging == true || brush != nil
            || voiceDrag?.isDragging == true
    }

    /// Escape's `.cancelGesture` rung on this pane: the drag is dropped with
    /// NOTHING committed, a band gives the selection back, and the press is
    /// ABANDONED rather than forgotten — the pointer is still down, and its
    /// remaining ticks and its release must resolve to nothing
    /// (`PitchEditorPressTracker.abandon`), not start a fresh gesture.
    public func cancelGestureForEscape() {
        drag = nil
        wobble = nil   // C5a-4b — a wobble drag too, nothing committed
        brush = nil    // C5b-4b — and a brush stroke, nothing committed
        voiceDrag = nil   // W7-NTU U3 — and a Voice drag, nothing committed
        draftPlayedLine = nil
        draftEditSet = nil
        cancelBand()
        press.abandon()
    }

    // MARK: I1 UI hooks — hearing the note (design 2026-09-24 §4, I1-F1)

    /// Stop a sounding note audition: the pane is going away (closed, or
    /// rebuilt on another clip — the view's `.onDisappear`) or the audition
    /// switch was turned off. ONE request per call, and nothing else changes:
    /// a draft, a selection and a press are `cancelDrag`'s business, and a
    /// stop is not a cancel.
    public func stopAudition() {
        requestAudition(.stop)
    }

    /// THE ONE PLACE AN AUDITION REQUEST LEAVES THIS MODEL (`emit`'s twin).
    private func requestAudition(_ request: PitchEditorAuditionRequest) {
        onAudition?(request)
    }

    /// One drag step: every moving note's ABSOLUTE offset — the pressed note
    /// first, then the members, in the draft's order (the numbers the release
    /// would commit) — snapped unless ⌥ freed it, with the editor's seed for a
    /// clip that has never been edited.
    ///
    /// ⭐ **A SNAPPED STEP NOBODY CAN HEAR ASKS NOTHING.** A sung note is almost
    /// never exactly on the grid, so the first tick past the slop snaps it onto
    /// its OWN scale step: −6 c and −1 c on the staging look's synthetic take
    /// (2026-09-25, measured: 4 requests for a 3-row drag, 2 for a 1-row group
    /// drag). Asking for that re-rendered the note and, when its buffer was
    /// ready, restarted it (the engine's replace-on-ready) with no pitch
    /// anyone could tell apart. So a snapped step whose every note lands
    /// within `PitchEditorReadout.centsResolutionFloor` of what was last asked
    /// for asks nothing — the same floor below which this editor refuses to
    /// PRINT a number. A note sung 45 c off still snaps audibly and is heard;
    /// every row crossed is 100 c and is heard. ⌥ FREE steps are never
    /// thinned: their changes come from the hand, and fine adjustment is their
    /// point. The draft itself (its line, its commit) is untouched.
    private func requestDragAudition(_ draft: PitchEditorDragDraft) {
        let offsets = [NotePitchOffset(segmentId: draft.segmentID, offsetCents: draft.offsetCents)]
            + draft.members.map { NotePitchOffset(segmentId: $0.segmentID, offsetCents: $0.offsetCents) }
        let heard = dragAuditionHeard ?? Dictionary(
            [(draft.segmentID, draft.baselineCents)] + draft.members.map { ($0.segmentID, $0.baselineCents) },
            uniquingKeysWith: { first, _ in first })
        if !draft.isFree, offsets.allSatisfy({ offset in
            heard[offset.segmentId].map {
                abs(offset.offsetCents - $0) < PitchEditorReadout.centsResolutionFloor
            } ?? false
        }) {
            return
        }
        dragAuditionHeard = Dictionary(offsets.map { ($0.segmentId, $0.offsetCents) },
                                       uniquingKeysWith: { first, _ in first })
        requestAudition(.dragStep(offsets: offsets, snapped: !draft.isFree,
                                  seedIfAbsent: seedForCommit))
    }

    /// Clear a refusal the user has read (they moved on, or acted again).
    public func clearRefusal() { refusal = nil }

    /// The DELETE key was pressed while this pane is open, and the app refused
    /// to let it delete the clip the pane shows (m23-ap p2-del) — say so, on
    /// the refusal line this surface already owns.
    ///
    /// ⭐ **THE WORDS ARE THE POLICY'S** (`DeleteMenuPolicy.pitchEditorOpenHint`),
    /// never composed here: the routing decision and the sentence that explains
    /// it live in one file, so they cannot come apart. Since m23-ap p2-del-2 the
    /// sentence names Cut too. ⌘X itself never reaches this method: a greyed
    /// Edit ▸ Cut runs no action, and the key-down monitor leaves ⌘ chords to
    /// the menu, so only ⌫ ever raises the line.
    ///
    /// ⚠️ **NOT A COMMIT AND NOT A SELECTION CHANGE.** It touches nothing but
    /// `refusal`, and it inherits that slot's lifetime unchanged — the next
    /// drag, cut attempt, tool switch or reload clears it, exactly as it clears
    /// "Nothing to cut there.". The app reaches it through a nonce the view
    /// watches (`PitchEditorView.deleteKeyHintNonce`), because this model is
    /// `@State private` inside the pane.
    public func refuseDeleteKey() { refusal = DeleteMenuPolicy.pitchEditorOpenHint }

    // MARK: UE-1 — Find sounds with no pitch (unpitched design §1.6, §1.10)

    /// Whether the editor OFFERS "Find sounds with no pitch": the clip's STORED
    /// table exists and holds no sound (`PitchEditorFindSounds.isOffered`). The
    /// editor's own seed already has its sounds, so a pane drawing a seed is
    /// never offered it. Read from the table the pane was HANDED
    /// (`syncStoredNoteTable`), so the merge's own write hides it.
    public var offersFindSounds: Bool { PitchEditorFindSounds.isOffered(storedTable: storedTable) }

    /// A Find Sounds press is waiting for its answer.
    public var isFindingSounds: Bool { findSoundsLine?.kind == .working }

    /// The press: returns `true` when the caller should now run the store's
    /// verb, and `false` when it must not — one is already running (a second
    /// click is ignored, never a second pass), or the table is one the store
    /// would refuse, which is then said in a person's words on the line
    /// (`PitchEditorFindSounds.refusal`) without asking the store.
    ///
    /// ⚠️ **NOT A COMMIT.** The store's verb is its own undo step ("Find
    /// Sounds", one `performEdit`, U-B); it never passes through `emit`, so
    /// `commitCount` does not move. The app funnel is
    /// `AppModel.findUnpitchedSoundsFromEditor`, reached through the view's
    /// `onFindSounds`.
    @discardableResult
    public func beginFindSounds() -> Bool {
        guard !isFindingSounds else { return false }
        if let words = PitchEditorFindSounds.refusal(storedTable: storedTable) {
            findSoundsLine = PitchEditorFindSoundsLine(kind: .shortfall, text: words)
            return false
        }
        findSoundsLine = PitchEditorFindSounds.workingLine
        return true
    }

    /// The store answered (or refused): say what happened, in words.
    ///
    /// UE-2 — a finder DECLINE is also REMEMBERED for this clip's current
    /// table (`PitchEditorFindSoundsMemory`), because the offer's predicate
    /// cannot see it: the table still holds no sound, so the button stays, and
    /// a rebuilt pane would otherwise show it with no word about the answer.
    public func finishFindSounds(_ outcome: PitchEditorFindSoundsOutcome) {
        let line = PitchEditorFindSounds.line(for: outcome)
        findSoundsLine = line
        switch outcome {
        case .finished(let added, let skipped):
            findSoundsAdded = added
            // The merge's write may already be here (it is, when the table
            // reached the pane before the answer); else the next sync takes it.
            findSoundsAddedIDs = added > 0 ? Self.soundIDs(in: storedTable) : nil
            if skipped != nil, let storedTable {
                findSoundsMemory?.remember(clipID: clipID, table: storedTable, line: line)
            }
        case .refused:
            findSoundsAdded = 0
            findSoundsAddedIDs = nil
        }
    }

    /// The ids of a table's sounds, or `nil` when it holds none.
    private nonisolated static func soundIDs(in table: PitchEditSet?) -> Set<UUID>? {
        let ids = Set((table?.segments ?? []).lazy.filter { $0.origin == .unpitched }.map(\.id))
        return ids.isEmpty ? nil : ids
    }

    /// UE-2 — the rules that keep the Find-sounds line true across a table
    /// change (see `findSoundsLine`). Called by `syncStoredNoteTable` only.
    private func reconcileFindSoundsLine() {
        if findSoundsAdded > 0, findSoundsLine?.kind == .done {
            if offersFindSounds {
                // An "Added" line whose sounds are gone: the offer is back,
                // which is exactly "a stored table with no sound" (the merge's
                // own undo).
                withdrawAddedLine()
            } else if let named = findSoundsAddedIDs {
                // UE-2 edge — a table REBUILT under the line (a preset pass
                // mints new ids for every segment): the sounds it names are
                // gone even though sounds are drawn, and "Undo takes them
                // away" would now undo the rebuild.
                let present = Set(storedTable?.segments.map(\.id) ?? [])
                if !named.isSubset(of: present) { withdrawAddedLine() }
            } else {
                // The merge's own write, arriving after the answer.
                findSoundsAddedIDs = Self.soundIDs(in: storedTable)
            }
        }
        // A decline this clip met on THIS table before the pane was rebuilt.
        if findSoundsLine == nil,
           let remembered = findSoundsMemory?.line(clipID: clipID, table: storedTable) {
            findSoundsLine = remembered
        }
    }

    /// Take down an "Added" line and what it named.
    private func withdrawAddedLine() {
        findSoundsLine = nil
        findSoundsAdded = 0
        findSoundsAddedIDs = nil
    }

    // MARK: W7-NTU U1 — the header group "Sound like the singer" (natural tuning X9)
    //
    // THE GROUP'S THREE ROWS, AS GESTURES. Every gesture is ONE commit through
    // `emit` (counted: the spy gate's home), and every commit is ONE store call
    // in `PitchEditorSingerWrite`, so every gesture is ONE undo step. What the
    // rows DRAW is `PitchEditorSingerGroup.resolve` over `noteTable`; nothing
    // here draws.
    //
    // ⭐ THE SLIDER COMMITS ON RELEASE, NEVER PER TICK (the "what does a commit
    // re-key?" law): the amount is render material (digest slot 7), so a write
    // per pointer tick would re-key the clip's render at pointer rate.
    //
    // ⛔⛔ ON A VOCAL THAT `predatesNaturalTuning`, EVERY PRESS ON THE VOICE ROW
    // IS THE UPDATE, NEVER A VOICE-SIZE WRITE. `setClipFormantCorrection` writes
    // its own field only (an explicit request, by the store's rule). On an old
    // vocal it would make the amount non-nil, so `predatesNaturalTuning` goes
    // false while the consonants stay off and the slides stay on the old rule:
    // the update line would vanish, and D4-1's whole-vocal update (the user's
    // ruling (b)) would never come, because the first note change would find a
    // set that no longer "predates". So the dim slider starts no draft (its
    // thumb must not follow the pointer to an amount it will not write) and its
    // release is `.naturalTuningUpdate`, which lands at the seed amount.
    // Dragging to a chosen amount in that SAME step would need a store door
    // that updates AND sets the amount; none exists (reported, W7-NTU).

    /// A press on the "Keep voice size" slider, from its first tick to its
    /// release.
    public enum VoiceSizePress: Sendable, Equatable {
        /// A press on the DIM slider of an old vocal: its release is the update.
        case update
        /// A drag on the live slider, at this amount (already snapped).
        case drag(amount: Double)
    }

    /// Whether the header offers the group: a note table is on screen. With no
    /// table (still listening, or nothing found) every row would be a control
    /// that does nothing, and the store refuses an empty seed.
    public var offersSingerGroup: Bool { !noteTable.segments.isEmpty }

    /// The voice-size press in flight, or nil.
    public private(set) var voiceSizePress: VoiceSizePress?

    /// The amount a live voice-size DRAG is at, or nil (none, or an update
    /// press, which has no amount).
    public var voiceSizeDraft: Double? {
        if case .drag(let amount) = voiceSizePress { return amount }
        return nil
    }

    /// W7-NTU §1(f) item 4 — the far-move hint's words, or nil: after a pitch
    /// drag that left a note 3 semitones or more from where it was sung, on a
    /// vocal that keeps under half its voice size (`PitchEditorFarMoveHint`).
    /// `formantPreserve` is the clip's STORED whole-clip flag, which decides
    /// the amount on a vocal with none of its own. Read from the table as it
    /// is NOW, so it appears once the store holds the move and goes when the
    /// move is undone or the amount turned up.
    public func farMoveHint(formantPreserve: Bool) -> String? {
        PitchEditorFarMoveHint.line(movedNoteIDs: farMoveNoteIDs, table: noteTable,
                                    formantPreserve: formantPreserve)
    }

    /// The group's faces for this clip. `stretchRatio` and `clipSemitones` are
    /// the clip's STORED fields (see `PitchEditorSingerGroup.resolve`).
    public func singerGroup(stretchRatio: Double, clipSemitones: Double) -> PitchEditorSingerGroup {
        PitchEditorSingerGroup.resolve(table: noteTable, stretchRatio: stretchRatio,
                                       clipSemitones: clipSemitones, voiceDraft: voiceSizeDraft)
    }

    /// A press, and each drag tick after it, on the "Keep voice size" track at
    /// `fraction` of its width (0 = the left end). The FIRST tick decides the
    /// press: on an old vocal it is the update and later ticks change nothing;
    /// otherwise the draft follows the pointer (`PitchEditorVoiceSize.amount`:
    /// detents, ⌥ = `fine`). Never commits.
    public func trackVoiceSize(atFraction fraction: Double, fine: Bool) {
        guard offersSingerGroup else { return }
        switch voiceSizePress {
        case .update:
            return
        case nil where noteTable.predatesNaturalTuning:
            voiceSizePress = .update
        default:
            voiceSizePress = .drag(amount: PitchEditorVoiceSize.amount(atFraction: fraction, fine: fine))
        }
    }

    /// The slider's release: ONE commit, or none. An update press commits the
    /// update; a drag commits its amount, unless it ends on the amount already
    /// stored (a press released where it started changes nothing, so it writes
    /// nothing and adds no undo step).
    @discardableResult
    public func releaseVoiceSize() -> PitchEditorCommit? {
        guard let press = voiceSizePress else { return nil }
        voiceSizePress = nil
        switch press {
        case .update:
            return updateToNaturalTuning()
        case .drag(let amount):
            guard amount != noteTable.formantCorrection else { return nil }
            return emit(.voiceSize(amount: amount))
        }
    }

    /// The slider's press dropped with nothing committed (the pane went away).
    public func cancelVoiceSize() {
        voiceSizePress = nil
    }

    /// The update line tapped (or the dim slider released): X4's ONE upgrade
    /// path, `ProjectStore.upgradeToNaturalTuning`. Only on a vocal that
    /// `predatesNaturalTuning` (R16), which is always a STORED table: the
    /// editor's seed is seeded new.
    @discardableResult
    public func updateToNaturalTuning() -> PitchEditorCommit? {
        guard offersSingerGroup, noteTable.predatesNaturalTuning else { return nil }
        return emit(.naturalTuningUpdate)
    }

    /// The "Consonants" switch clicked: it switches to the other state. A
    /// switch never writes the state it shows, so a click is never a no-op.
    @discardableResult
    public func toggleConsonants() -> PitchEditorCommit? {
        guard offersSingerGroup else { return nil }
        return emit(.consonants(enabled: !noteTable.keepsConsonantsUntuned))
    }

    /// A "Slides" step clicked. The lit step writes nothing (the smoothness it
    /// would store is already stored).
    @discardableResult
    public func pickSlides(_ step: PitchEditorSlideStep) -> PitchEditorCommit? {
        guard offersSingerGroup,
              noteTable.transitionSlopeCentsPerSecond != step.centsPerSecond else { return nil }
        return emit(.slideSmoothness(centsPerSecond: step.centsPerSecond))
    }

    // MARK: W7-NTU U3 — the Voice tool (natural tuning §1(f) items 2-3)
    //
    // ⭐ THE ARITHMETIC IS HEADLESS (`PitchEditorVoiceTool`,
    // `PitchEditorVoiceDraft`); THIS IS ITS WIRING, in the Wobble tool's shape.
    // A press on a note in the Voice tool routes `.formantDrag(id)` and begins
    // its draft on its FIRST tick (`beginVoiceDrag`, from `trackPress`; a sound
    // is refused there in words and the press abandoned). It is fed vertical
    // travel only once past the router's 4 pt slop (`updateVoiceDrag`). At the
    // release it commits the drag (`endVoiceDrag`) or, on a double-click, puts
    // the note back as sung (`resetVoice`): ONE commit each, none for a gesture
    // that changes nothing, through `emit` like every other write. The note's
    // pitch, its blob and the played line never move: a Voice changes how the
    // note SOUNDS, not where it sits.

    /// The FIRST tick of a `.formantDrag` press: a draft on the STORED note.
    /// On a SOUND the press is refused in words and ABANDONED
    /// (`PitchEditorPressTracker.abandon`), so its later ticks and its release
    /// do nothing: no draft, no selection, no commit. The refusal is drawn on
    /// the palette's `PanelRefusalLine`, the slot every refusal here uses.
    private func beginVoiceDrag(segmentID id: UUID) {
        refusal = nil
        guard let segment = storedSegment(id) else {
            press.abandon()
            return
        }
        guard segment.origin != .unpitched else {
            refusal = PitchEditorFormantCopy.voiceSoundRefusal
            press.abandon()
            return
        }
        voiceDrag = PitchEditorVoiceDraft(segmentID: id, baseline: segment.formantOffsetSemitones,
                                          isTooShort: PitchEditorVoiceTool.isTooShort(segment))
    }

    /// One pointer tick of the Voice press in flight. ⛔ **NEVER COMMITS.**
    /// `translationHeight` is the gesture's whole vertical travel from the
    /// PRESS (SwiftUI's: y grows down), and `fine` is ⌥ as held THIS tick. It
    /// does nothing until the press is past the router's slop, so a click, and
    /// each click of a double-click, leaves the value alone.
    public func updateVoiceDrag(translationHeight: Double, fine: Bool) {
        guard var current = voiceDrag, press.current?.isPromoted == true else { return }
        current.update(translationHeight: translationHeight, fine: fine)
        voiceDrag = current
    }

    /// The Voice DRAG ended (`PitchEditorReleaseAction.endFormantDrag`). Emits
    /// AT MOST ONE commit, `.noteFormant` for the one note, and NONE for a drag
    /// that ends on the stored value (`PitchEditorVoiceDraft.commitValue`).
    @discardableResult
    public func endVoiceDrag() -> PitchEditorCommit? {
        guard let current = voiceDrag else { return nil }
        voiceDrag = nil
        guard let value = current.commitValue else { return nil }
        return emit(.noteFormant(segmentIDs: [current.segmentID], semitones: value))
    }

    /// A DOUBLE-click on a note in the Voice tool
    /// (`PitchEditorReleaseAction.formantReset`): its Voice back to as sung,
    /// ONE commit, or none when it already is (a reset that changes nothing
    /// adds no undo step). Never a sound: a press on one was refused at its
    /// first tick.
    @discardableResult
    public func resetVoice(segmentID id: UUID) -> PitchEditorCommit? {
        voiceDrag = nil
        guard let segment = storedSegment(id), segment.origin != .unpitched,
              segment.formantOffsetSemitones != 0 else { return nil }
        return emit(.noteFormant(segmentIDs: [id], semitones: 0))
    }

    /// ⭐ **THE VOICE MARKS, AS DRAWN** (§1(f) item 2, R22): while the Voice
    /// tool is engaged, every drawn NOTE whose Voice is not as sung, in blob
    /// order. The note being dragged shows the live draft's value; every other
    /// note shows its STORED value. Empty in every other tool, so nothing
    /// about a Voice is drawn where it cannot be changed. The surface draws
    /// these and the echo reports them.
    public var voiceMarks: [PitchEditorVoiceMark] {
        guard tool == .voice else { return [] }
        var stored: [UUID: Double] = [:]
        for segment in noteTable.segments where segment.origin != .unpitched {
            stored[segment.id] = segment.formantOffsetSemitones
        }
        return blobs.compactMap { blob in
            guard let storedValue = stored[blob.id] else { return nil }
            let live = voiceDrag?.segmentID == blob.id ? voiceDrag : nil
            let value = live?.semitones ?? storedValue
            guard value != 0 else { return nil }
            return PitchEditorVoiceMark(segmentID: blob.id, semitones: value,
                                        blobRect: geometry.rect(for: blob), isLive: live != nil)
        }
    }

    /// The Voice tool's line in the palette's SF Mono readout slot: for the
    /// press in flight's note, else for the NOTE under `hover`. `nil` in any
    /// other tool, over empty surface, over a sound, or while another kind of
    /// press is in flight. A note shorter than
    /// `PitchEditSet.minimumVoiceNoteSeconds` says R11's sentence instead of
    /// its number; the chip under it still prints the number.
    public func voiceReadout(hover: CGPoint?) -> String? {
        guard tool == .voice else { return nil }
        if let draft = voiceDrag {
            return draft.isTooShort ? PitchEditorFormantCopy.voiceTooShort
                : PitchEditorFormantCopy.voiceToolReadout(draft.semitones)
        }
        guard press.current == nil, let hover, let blob = blob(at: hover),
              let segment = storedSegment(blob.id), segment.origin != .unpitched else { return nil }
        return PitchEditorVoiceTool.isTooShort(segment) ? PitchEditorFormantCopy.voiceTooShort
            : PitchEditorFormantCopy.voiceToolReadout(segment.formantOffsetSemitones)
    }

    // MARK: I7b — clear and restore the selected notes (interaction batch §10)

    /// The SELECTED notes this surface draws, in table order — what ⌫, Edit ▸
    /// Delete and the right-click menu act on.
    public var selectedBlobs: [NoteBlob] { blobs.filter { selection.contains($0.id) } }

    /// ⭐⭐ **THE ONE ACTION BEHIND ⌫, EDIT ▸ DELETE AND THE RIGHT-CLICK MENU**
    /// (m23-ap I7b; the user's `delete-clears = yes`). ⌫ and Edit ▸ Delete reach
    /// it through the bridge's `deleteNonce` (`DeleteSurface.pitchEditorNotes`),
    /// the menu's items and the debug tier's staged `noteMenu` step through the
    /// view's `runNoteMenu` — never a second spelling, so what the menu said,
    /// what the key does and what the store receives cannot come apart.
    ///
    /// **`.clear`** emits ONE `.notesCleared(cleared: true)` carrying the
    /// selected notes that are NOT already cleared, in table order — the count
    /// the menu's "Clear 3 Notes" named — so one gesture is one undo step
    /// ("Clear Notes"). When every selected note is already cleared it commits
    /// NOTHING and says so on the refusal line, pointing at Restore
    /// (`PitchEditorNoteMenu.alreadyClearedLine`). **`.restore`** emits one
    /// `cleared: false` carrying the selected notes that ARE cleared, and does
    /// nothing when none is (the menu never offers it then).
    ///
    /// ⚠️ **NOTHING SELECTED IS A RACE, NOT A STATE THE APP ROUTES HERE.** With
    /// no selection the app's policy never names this surface (⌫ keeps p2-del's
    /// `.pitchEditorOpen` refusal and its line). If a stale bridge bit ever
    /// hands a ⌫ to an empty selection anyway, the pane shows that same p2-del
    /// line rather than swallowing the key in silence — the roll's rule that
    /// the pane's LIVE selection wins over the bridge's report.
    ///
    /// Clears the refusal first, like every other action on this surface. The
    /// selection is kept: the notes stay drawn (hollow) and stay selected, so a
    /// Restore or an undo is one step away.
    @discardableResult
    public func performNoteAction(_ action: PitchEditorNoteMenu.Action) -> PitchEditorCommit? {
        refusal = nil
        let targets = selectedBlobs
        guard !targets.isEmpty else {
            if action == .clear { refusal = DeleteMenuPolicy.pitchEditorOpenHint }
            return nil
        }
        switch action {
        case .clear:
            let changing = targets.filter { !$0.isCleared }.map(\.id)
            guard !changing.isEmpty else {
                refusal = PitchEditorNoteMenu.alreadyClearedLine(targets.map(\.menuTarget))
                return nil
            }
            return emit(.notesCleared(segmentIDs: changing, cleared: true))
        case .restore:
            let changing = targets.filter(\.isCleared).map(\.id)
            guard !changing.isEmpty else { return nil }
            return emit(.notesCleared(segmentIDs: changing, cleared: false))
        case .resetWobble:
            // C5a-4b — "Back to how you sang it": the selected NOTES whose
            // wobble changed, in table order, ONE commit (one undo step under
            // `structuralKey`, applied by the app funnel). Sounds are never
            // named: they have no wobble (§1.7), and the store would refuse.
            let changing = targets.filter { hasWobbleEdit($0.id) }.map(\.id)
            guard !changing.isEmpty else { return nil }
            return emit(.noteVibratoReset(segmentIDs: changing))
        case .resetShape:
            // C5b-4b — "Reset drawn shape" (design §5.5): every selected note
            // that carries a drawing, ONE commit of clears (one "Reset Drawn
            // Shape" undo step through `setClipNoteShapes`). A sound is named
            // too when it carries one: the store allows that clear (only a
            // hand-written file can put a drawing on a sound, and this is its
            // cleanup path).
            let changing = targets.filter { hasDrawnShape($0.id) }.map(\.id)
            guard !changing.isEmpty else { return nil }
            return emit(.noteShapes(shapes: Dictionary(uniqueKeysWithValues:
                changing.map { ($0, NoteShapeSamples.clear) })))
        case .voiceDeeper, .voiceBrighter, .voiceAsSung:
            // W7-NTU U3 — the Voice row (natural tuning §1(f) item 3): every
            // selected NOTE whose Voice is not already the row's value, in
            // table order, ONE commit (one "Set Note Voice" undo step). Sounds
            // are never named: the store refuses a sound's Voice, and would
            // refuse the whole batch with it.
            let value = PitchEditorNoteMenu.voiceValue(of: action) ?? 0
            let changing = targets.filter { blob in
                guard let segment = storedSegment(blob.id), segment.origin != .unpitched else {
                    return false
                }
                return segment.formantOffsetSemitones != value
            }.map(\.id)
            guard !changing.isEmpty else { return nil }
            return emit(.noteFormant(segmentIDs: changing, semitones: value))
        }
    }

    /// C5a-4b — a drawn NOTE (never a sound) whose stored wobble is not as sung.
    private func hasWobbleEdit(_ id: UUID) -> Bool {
        guard let segment = storedSegment(id), segment.origin != .unpitched else { return false }
        return NoteVibratoEdit(storedIn: segment) != .asSung
    }

    /// A blob as the note menu counts it: its kind and clear, and — C5a-4b —
    /// whether its wobble was changed (the "Back to how you sang it" row).
    private func menuTarget(for blob: NoteBlob) -> PitchEditorNoteMenu.Target {
        var target = blob.menuTarget
        target.hasWobbleEdit = hasWobbleEdit(blob.id)
        target.hasDrawnShape = hasDrawnShape(blob.id)   // C5b-4b
        // W7-NTU U3 — the note's STORED Voice, for the Voice row.
        target.voiceSemitones = storedSegment(blob.id)?.formantOffsetSemitones ?? 0
        return target
    }

    /// The right-click's SELECTION half, applied before the menu opens (the
    /// brief's house rule for this pane: "a right-click on an UNSELECTED note
    /// selects it first"). An unselected note under `point` becomes the whole
    /// selection; a selected note, or empty surface, leaves the selection
    /// alone — so a right-click inside a selection acts on all of it.
    ///
    /// ⚠️ **`docs/DESIGN-LANGUAGE.md` SAYS A RIGHT-CLICKED OBJECT OUTSIDE THE
    /// SELECTION IS ACTED ON "ALONE" WITH THE SELECTION "UNTOUCHED"**
    /// (`DeleteMenuPolicy.clipContextCommand`'s arrange rule). The TARGET is
    /// the same here — that note alone; what differs is that this pane shows
    /// the target by selecting it, as the I7b brief rules. Recorded as a
    /// disagreement, not resolved silently.
    public func selectForContextMenu(at point: CGPoint) {
        guard let hit = blob(at: point), !selection.contains(hit.id) else { return }
        selectOnly(hit.id)
    }

    /// The selection menu a right-click at `point` would show — titles and
    /// enabled states from `PitchEditorNoteMenu`, for the notes that click
    /// would act on: the unselected note under `point` ALONE (the one
    /// `selectForContextMenu` is about to select), else the selection. `nil`
    /// (the pointer is off the surface) reads the selection.
    ///
    /// ⭐ WHY IT TAKES THE POINT: SwiftUI builds a `.contextMenu`'s items when
    /// the view's body runs, BEFORE the right-click lands, so a menu built from
    /// the selection alone would name the OLD selection's notes over a note the
    /// click is about to select. Resolved from the hover point instead, the
    /// title names the notes the action will act on.
    ///
    /// W7-NTU U3 — the Voice row's "Deeper" and "Brighter" are offered in the
    /// Voice tool (`voiceTool:`); its "As sung", a reset like "Back to how you
    /// sang it", in every tool once a note has a Voice.
    public func noteMenu(at point: CGPoint?) -> [PitchEditorNoteMenu.Item] {
        PitchEditorNoteMenu.items(for: contextMenuTargets(at: point).map { menuTarget(for: $0) },
                                  voiceTool: tool == .voice)
    }

    private func contextMenuTargets(at point: CGPoint?) -> [NoteBlob] {
        if let point, let hit = blob(at: point), !selection.contains(hit.id) { return [hit] }
        return selectedBlobs
    }

    /// ⭐ **THE ONE PLACE A COMMIT LEAVES THIS MODEL.** Counted and recorded
    /// here so a gate asserts the CADENCE — N ticks, zero writes; one release,
    /// one write — rather than reading a `DragGesture` closure and believing it.
    @discardableResult
    private func emit(_ kind: PitchEditorCommit.Kind) -> PitchEditorCommit {
        let commit = PitchEditorCommit(kind: kind, seedIfAbsent: seedForCommit)
        commitCount += 1
        lastCommit = commit
        onCommit?(commit)
        return commit
    }

    // MARK: Contour derivation

    /// Gather each note's OWN voiced frames.
    ///
    /// ⛔ **THE HOLE RULE, AND WHY THIS IS NOT A SECOND IMPLEMENTATION OF IT.**
    /// The runs come from `PitchAutoCorrect.voicedRuns`, which is the ONE home
    /// for "where does the singer stop" (a note can also end inside a run since
    /// p2-seg; the contour does not break there). This function only collects the frames
    /// that fall inside a run it was handed — half-open `[start, end)`, which
    /// is exactly the interval `voicedRuns` built from `first.timeSeconds` and
    /// `last.timeSeconds + framePeriod`. Runs are ascending and disjoint, so
    /// one forward pass suffices, and an unvoiced frame can never sit inside
    /// one.
    ///
    /// Two consequences, both deliberate:
    ///
    ///  1. `contourRuns.count == blobs.count` STRUCTURALLY. The hole test in
    ///     the suite therefore asserts the GAP IN THE GEOMETRY as well as the
    ///     count — a count that cannot disagree proves nothing on its own.
    ///  2. A voiced blip SHORTER than `PitchAutoCorrect.minimumNoteSeconds`
    ///     (0.06 s, ~4 frames) gets no blob AND no contour, because it belongs
    ///     to no run. That is the same threshold the correction policy already
    ///     applies, rather than a second opinion about what counts as a note.
    ///     ⚠️ It does mean a few measured frames are not drawn; the alternative
    ///     — a second split pass here — buys those frames at the price of a
    ///     rule with two homes, and this tree pays more for the second home.
    public nonisolated static func contourRuns(frames: [ClipPitchFrame],
                                               blobs: [NoteBlob]) -> [PitchEditorContourRun] {
        guard !blobs.isEmpty else { return [] }
        let ordered = frames.sorted { $0.timeSeconds < $1.timeSeconds }
        var out: [PitchEditorContourRun] = []
        out.reserveCapacity(blobs.count)
        var index = 0
        for blob in blobs {
            while index < ordered.count, ordered[index].timeSeconds < blob.startSeconds {
                index += 1
            }
            var points: [PitchEditorContourPoint] = []
            var scan = index
            while scan < ordered.count, ordered[scan].timeSeconds < blob.endSeconds {
                let frame = ordered[scan]
                if let hz = frame.frequencyHz {
                    points.append(PitchEditorContourPoint(
                        sourceSeconds: frame.timeSeconds,
                        midi: PitchCorrectionMath.midi(fromHz: hz),
                        confidence: frame.confidence))
                }
                scan += 1
            }
            index = scan
            out.append(PitchEditorContourRun(id: blob.id, points: points))
        }
        return out
    }

    /// The unvoiced stretches and their reason (§5.5's sixth rule).
    ///
    /// A stretch is one maximal run of consecutive frames with no pitch. Its
    /// end is the last frame's start plus one frame period — the same
    /// convention `PitchAutoCorrect.voicedRuns` uses for a run's end, so a
    /// gap's end meets the next note's start exactly.
    ///
    /// ⚠️ A VOICED blip too short to be a note (under
    /// `PitchAutoCorrect.minimumNoteSeconds`) INTERRUPTS a gap even though it
    /// produced no note, so a long silence with one spurious frame in it comes
    /// back as two gaps. That is the honest reading — something WAS measured
    /// there — and it is recorded because the alternative (swallowing the
    /// blip) would require a second opinion about what counts as a note.
    public nonisolated static func gaps(frames: [ClipPitchFrame],
                                        frameRateHz: Double) -> [PitchEditorGap] {
        guard frameRateHz.isFinite, frameRateHz > 0, !frames.isEmpty else { return [] }
        let framePeriod = 1 / frameRateHz
        let ordered = frames.sorted { $0.timeSeconds < $1.timeSeconds }
        var out: [PitchEditorGap] = []
        var current: [ClipPitchFrame] = []

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard let first = current.first, let last = current.last else { return }
            // ⛔ UNANIMOUS EVIDENCE OR IT IS NOT SILENCE.
            let everyFrameSilent = current.allSatisfy { $0.absence == .belowLevel }
            out.append(PitchEditorGap(
                startSeconds: first.timeSeconds,
                endSeconds: last.timeSeconds + framePeriod,
                kind: everyFrameSilent ? .rest : .uncertain,
                frameCount: current.count))
        }

        for frame in ordered {
            if frame.frequencyHz == nil {
                current.append(frame)
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}
