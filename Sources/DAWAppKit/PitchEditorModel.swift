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
    /// readout may imply anything finer. Note the chain is wrong twice over:
    /// the transposer we ship is itself sharp (+5.45 cents at +2 st, +3.95 at
    /// −2 st), so a readout implying closed-loop exactness would be a second
    /// lie on top of this one.
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

    /// `NoteSegment.isEdited` of the segment this blob was drawn from — ANY
    /// per-note edit, not only a pitch move (m23-ap C-0). A Hard-Tuned note
    /// that already sat in tune carries offset 0 and flattened scales; before
    /// this it drew as untouched while its line visibly changed.
    public let hasEdits: Bool

    public init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double,
                detectedHz: Double, medianConfidence: Double, frameCount: Int,
                offsetCents: Double = 0, hasEdits: Bool? = nil) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.detectedHz = detectedHz
        self.centreMidi = PitchCorrectionMath.midi(fromHz: detectedHz)
        self.medianConfidence = medianConfidence
        self.frameCount = frameCount
        self.offsetCents = offsetCents
        self.hasEdits = hasEdits ?? (offsetCents != 0)
    }

    /// One stored note, as the surface draws it (m23-ap C1/C3). `id` is the
    /// SEGMENT's id — which is what makes a drag addressable, a split
    /// attributable, and an undo key derivable without a second table.
    public init(segment: NoteSegment, frameCount: Int) {
        self.init(id: segment.id,
                  startSeconds: segment.startSeconds,
                  endSeconds: segment.endSeconds,
                  detectedHz: segment.detectedHz,
                  medianConfidence: segment.detectedConfidence,
                  frameCount: frameCount,
                  offsetCents: segment.pitchOffsetCents,
                  hasEdits: segment.isEdited)
    }

    /// The detected centre plus the edit, WITHOUT the clip's transpose — the
    /// stored note's own pitch. ⚠️ What a surface DRAWS is
    /// `PitchEditorGeometry.drawnMidi(for:)`, which adds the transpose; the two
    /// are equal only on an untransposed clip.
    public var editedCentreMidi: Double { centreMidi + offsetCents / 100 }

    /// True when this note carries ANY edit (`NoteSegment.isEdited`) — the
    /// accent's question: an edited object must not look like an untouched one.
    public var isEdited: Bool { hasEdits || offsetCents != 0 }

    /// True when the note was MOVED off where it was sung — the ghost's
    /// question. A note whose only edit is its wobble has no second place to
    /// draw an outline at.
    public var isMoved: Bool { offsetCents != 0 }

    /// The note the EDIT lands on — what the blob's label says once it has been
    /// dragged. ⚠️ Distinct from `nearestMidiNote`, which names the note that
    /// was SUNG; conflating them would make a corrected vocal's editor claim
    /// the singer hit a note they did not.
    public var editedNearestMidiNote: Int { Int(editedCentreMidi.rounded()) }

    /// Its name, e.g. "A3" — the blob's label when there is room.
    public var editedNoteName: String { Fundamental.noteName(midiNote: editedNearestMidiNote) }

    /// The edit as a READOUT, or `nil` when it is inside the detector's own
    /// resolution (`PitchEditorReadout`'s ±12.90 cent floor). ⚠️ `nil` is
    /// "too small for us to claim", never "no edit".
    public var offsetReadout: String? { PitchEditorReadout.centsReadout(offsetCents) }

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
    /// `PitchEditorReadout.centsReadout`.
    public var centsReadout: String? {
        PitchEditorReadout.centsReadout(centsFromNearestNote)
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

    /// **THE ONE CONVERSION, BACK** — what a drag landing on drawn pitch
    /// `drawnMidi` stores: `(drawnMidi − clipPitchShiftSemitones − centreMidi)
    /// × 100` cents. ⛔ Drop the transpose term and every drag on a transposed
    /// clip stores a note that plays that many semitones away from where the
    /// user let go; `transposeIsDrawnAndUndrawn` plants exactly that.
    public nonisolated static func storedOffsetCents(drawnMidi: Double, centreMidi: Double,
                                                     clipPitchShiftSemitones: Double) -> Double {
        (drawnMidi - clipPitchShiftSemitones - centreMidi) * 100
    }

    /// Where a note is DRAWN — the pitch it plays at.
    public func drawnMidi(for blob: NoteBlob) -> Double {
        Self.drawnMidi(centreMidi: blob.centreMidi, offsetCents: blob.offsetCents,
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
    /// Detection found notes and they are on screen.
    case ready(noteCount: Int)
    /// Detection ran to completion and found nothing.
    case noNotesFound
    /// The engine could not be asked.
    case engineUnavailable
    /// The store refused, carrying its teaching text.
    case refused(String)

    /// **The total function §12.1 requires.** Two inputs, no impossible
    /// combination: `PitchEditorPhase` cannot be "in flight" and "failed" at
    /// once, and the note count only decides anything once detection completed.
    public nonisolated static func resolve(phase: PitchEditorPhase, noteCount: Int) -> PitchEditorState {
        switch phase {
        case .notStarted: return .idle
        case .detecting: return .analysing
        case .failed(.engineUnavailable): return .engineUnavailable
        case .failed(.refused(let text)): return .refused(text)
        case .detected: return noteCount > 0 ? .ready(noteCount: noteCount) : .noNotesFound
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
        case .ready(let count):
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

    public var id: String { rawValue }

    /// SF Symbol. `scissors` is the frames' own glyph for this slot.
    public var symbolName: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .scissors: return "scissors"
        }
    }

    /// The palette's label — one word, for a person.
    public var label: String {
        switch self {
        case .pointer: return "Move"
        case .scissors: return "Split"
        }
    }

    /// What it does, written for someone who has never used a tuner.
    /// ⚠️ Drawn, not only hovered: a tooltip is invisible to `view.capture`, so
    /// a captured gate cannot tell a correct caption from a missing one (the
    /// `EQCurveEditor.help` lesson).
    public var help: String {
        switch self {
        case .pointer: return "Drag a note up or down to change its pitch. Hold ⌥ to move it freely."
        case .scissors: return "Click a note to cut it in two, so you can tune each half on its own."
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

    /// Where the blob is drawn RIGHT NOW — DRAWN pitch, transpose included.
    public var targetMidi: Double {
        PitchEditorGeometry.drawnMidi(centreMidi: detectedMidi, offsetCents: offsetCents,
                                      clipPitchShiftSemitones: clipPitchShiftSemitones)
    }

    /// Where the ghost is drawn: the SUNG centre on the transposed axis (see
    /// `PitchEditorGeometry.ghostRect(for:)` for why the transpose is in it).
    public var ghostMidi: Double { detectedMidi + clipPitchShiftSemitones }

    /// How far this gesture has moved the note, cents — the number a person
    /// reads while dragging.
    public var gestureCents: Double { offsetCents - baselineCents }

    /// True when releasing here would change nothing.
    public var isNoOp: Bool { offsetCents == baselineCents }

    /// The note the drag is landing on, e.g. "A3".
    public var targetNoteName: String {
        Fundamental.noteName(midiNote: Int(targetMidi.rounded()))
    }

    /// The readout beside the cursor, or `nil` when the move is smaller than
    /// the detector can resolve. ⚠️ **`nil` IS NOT "0 cents"** — a free drag of
    /// three cents is a move nobody can measure, and printing a number for it
    /// would claim a precision this chain does not have (§5.5.3).
    public var readout: String? { PitchEditorReadout.centsReadout(offsetCents) }
}

// MARK: - Increment C — what a gesture submits

/// ONE store write, emitted on gesture END and never per tick (§8.2 / §11 P7b).
///
/// ⛔⛔ **WHY THE CADENCE IS STRUCTURAL AND NOT A MATTER OF TASTE.**
/// `Clip.pitchEdits` rides `ClipKey.pitchEditSetHash`. A commit per pointer
/// tick would re-key the clip's offline render at pointer rate, the render
/// would never be ready, and `StretchResolution.pending` **skips the clip**
/// (`PlaybackGraph.swift:78-83`, consumed at `:953`) — so the vocal would go
/// SILENT for the whole drag. `AutomationLaneEditor` commits per tick and is
/// right to: there is no offline render behind an automation lane. That
/// precedent does not transfer, and the design doc records getting this
/// backwards on its first pass.
public struct PitchEditorCommit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// C1 — an ABSOLUTE offset in cents for one note. Absolute, not a
        /// delta: a dropped delta and a delta of zero are indistinguishable.
        case notePitch(segmentID: UUID, offsetCents: Double)
        /// C3 — cut one note in two at a source-file second.
        case splitNote(segmentID: UUID, atSourceSecond: Double)
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
    public var geometry: PitchEditorGeometry

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

    /// The same line with the live DRAG applied, or `nil` when nothing is being
    /// dragged. **A VALUE COPY, NEVER A COMMIT** (design §4.4, F5): the note
    /// table is copied with the dragged note's offset set to the draft, passed
    /// through the same `PitchPlayedLine.make`, and nothing reaches the store
    /// until release.
    public private(set) var draftPlayedLine: PitchPlayedLine?

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

    /// The last refusal this surface produced, in words for a person, or `nil`.
    /// A tool that refused and a tool that did nothing must not look the same.
    public private(set) var refusal: String?

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
    }

    // MARK: Derived state

    /// What the surface says — §5.7, resolved at ONE home so the echo, the
    /// header and any gate all read the SAME string the view drew.
    public var state: PitchEditorState {
        PitchEditorState.resolve(phase: phase, noteCount: blobs.count)
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
        out.reserveCapacity(playedLine.runs.count)
        for run in playedLine.runs {
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

    /// The source-second span a live pitch drag can change: the dragged note
    /// widened by half the set's retune ramp on each side — the reach of its
    /// boundary crossfade (`PitchCorrectionCurve`'s centred ramps). Outside it
    /// the dragged note's gate is exactly 0, so the draft and the committed
    /// line are the same numbers there, bit for bit. `nil` with no drag.
    public var draftSpan: ClosedRange<Double>? {
        guard let draft = drag else { return nil }
        let half = max(0, noteTable.retuneMs / 1000 / 2)
        return (draft.startSeconds - half)...(draft.endSeconds + half)
    }

    /// The DRAFT line inside `draftSpan`, as screen polylines — the part of
    /// the line that moves with the pointer. Each piece is extended by ONE
    /// point on each side from the same run (never across a hole), which is
    /// exactly the point the committed line's cut stops at, so the two draw as
    /// one unbroken line. Empty with no drag.
    public var draftLineSegments: [[CGPoint]] {
        guard let line = draftPlayedLine, let span = draftSpan else { return [] }
        var out: [[CGPoint]] = []
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
        return playedLine.noteSummaries(for: noteTable.segments.filter { drawn.contains($0.id) })
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
        if drag != nil { rebuildDraftLine() }
    }

    /// The draft line: `noteTable` copied, the dragged note's offset set to
    /// the draft, through the same `make`. Nothing is committed.
    private func rebuildDraftLine() {
        guard let draft = drag else {
            draftPlayedLine = nil
            return
        }
        var segments = noteTable.segments
        if let index = segments.firstIndex(where: { $0.id == draft.segmentID }) {
            segments[index].pitchOffsetCents = draft.offsetCents
        }
        let table = PitchEditSet(analysisVersion: noteTable.analysisVersion,
                                 segments: segments, retuneMs: noteTable.retuneMs)
        draftPlayedLine = PitchPlayedLine.make(
            contour: contourPhase.contour,
            fallback: fallbackDetection,
            editSet: table,
            clipPitchShiftSemitones: geometry.clipPitchShiftSemitones,
            sourceWindow: geometry.sourceWindow)
        draftLineRevision &+= 1
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
        seedTable = PitchNoteTable.detected(from: result)
        // C-0: kept whole — the estimate's sung line until the seam answers.
        fallbackDetection = result
        rebuildBlobs()
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
        storedTable = table
        rebuildBlobs()
        // C-0: the line is what the render plays, and the render plays the
        // STORED table — so a read-back rebuilds it.
        rebuildPlayedLine()
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
            return NoteBlob(segment: segment, frameCount: count)
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
        draftPlayedLine = nil
        refusal = nil
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
        self.geometry.midiRange = PitchEditorRange.midiRange(
            forNoteCentres: blobs.map { geometry.drawnMidi(for: $0) })
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
        var best: (blob: NoteBlob, distance: CGFloat)?
        for blob in blobs {
            let rect = geometry.rect(for: blob).insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop)
            guard rect.contains(point) else { continue }
            let distance = abs(point.y - rect.midY)
            if best == nil || distance < best!.distance { best = (blob, distance) }
        }
        return best?.blob
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
                                    clipPitchShiftSemitones: geometry.clipPitchShiftSemitones)
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
        // y grows DOWNWARD and pitch grows UPWARD: the minus sign is the whole
        // of that relationship and it is the one thing a reviewer should check.
        let semitones = -Double(translationHeight) / Double(max(1, geometry.rowHeight))
        // ⚠️ DRAWN PITCH from here to `landed` (m23-ap C-0): the window, the
        // clamp and the snap are all on the axis the user SEES, which on a
        // transposed clip is not the stored one. The way back to a stored
        // offset is the ONE conversion below.
        let origin = PitchEditorGeometry.drawnMidi(
            centreMidi: draft.detectedMidi, offsetCents: draft.baselineCents,
            clipPitchShiftSemitones: draft.clipPitchShiftSemitones)
        let raw = origin + semitones
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
        draft.offsetCents = PitchEditorGeometry.storedOffsetCents(
            drawnMidi: landed, centreMidi: draft.detectedMidi,
            clipPitchShiftSemitones: draft.clipPitchShiftSemitones)
            .clamped(to: NoteSegment.pitchOffsetCentsRange)
        let moved = draft.offsetCents != drag?.offsetCents
        drag = draft
        // C-0: the live line follows the draft — rebuilt only when the VALUE
        // moved (a snapped drag crosses a row a few times per gesture; most
        // ticks change nothing), and never committed.
        if moved { rebuildDraftLine() }
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
        guard !draft.isNoOp else { return nil }
        return emit(.notePitch(segmentID: draft.segmentID, offsetCents: draft.offsetCents))
    }

    /// The gesture was abandoned — the window deactivated, the pane closed, a
    /// clip switched. ⚠️ **NOT THE SAME CALL AS `endPitchDrag`**: SwiftUI's
    /// `DragGesture.onEnded` does not fire when a window resigns key, and a
    /// draft left behind would leak into the next gesture as a phantom
    /// baseline.
    public func cancelDrag() {
        drag = nil
        draftPlayedLine = nil
    }

    /// Cut the note under a point in two (C3). Returns the commit it emitted,
    /// or `nil` — and sets `refusal` to teaching prose whenever it returned
    /// `nil` for a reason the user can act on.
    ///
    /// The cut lands where the pointer is, converted through the ONE coordinate
    /// home. Refusal is `ProjectStore.splitClipNoteSegment`'s rule, restated
    /// here only so the user hears it BEFORE the store does — the numbers come
    /// from `PitchAutoCorrect.minimumNoteSeconds`, not from a second constant.
    @discardableResult
    public func splitNote(at point: CGPoint) -> PitchEditorCommit? {
        guard tool == .scissors else { return nil }
        refusal = nil
        guard let blob = blob(at: point) else {
            refusal = "Nothing to cut there. Click on one of the notes."
            return nil
        }
        let cut = geometry.sourceSecond(forX: point.x)
        let floor = PitchAutoCorrect.minimumNoteSeconds
        guard cut - blob.startSeconds >= floor, blob.endSeconds - cut >= floor else {
            refusal = "That is too close to the edge of the note. Each half has to be at "
                + "least \(Int((floor * 1000).rounded())) milliseconds long — zoom in and "
                + "click nearer the middle."
            return nil
        }
        return emit(.splitNote(segmentID: blob.id, atSourceSecond: cut))
    }

    /// Clear a refusal the user has read (they moved on, or acted again).
    public func clearRefusal() { refusal = nil }

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
