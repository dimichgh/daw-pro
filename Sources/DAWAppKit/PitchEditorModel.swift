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
    public nonisolated static let centsResolutionFloor: Double = 12.90

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

    public init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double,
                detectedHz: Double, medianConfidence: Double, frameCount: Int) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.detectedHz = detectedHz
        self.centreMidi = PitchCorrectionMath.midi(fromHz: detectedHz)
        self.medianConfidence = medianConfidence
        self.frameCount = frameCount
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
                rowHeight: CGFloat = PitchEditorGeometry.defaultRowHeight) {
        self.sourceWindowStartSeconds = sourceWindowStartSeconds
        self.sourceWindowSeconds = sourceWindowSeconds
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.tempoMap = tempoMap
        self.pixelsPerBeat = pixelsPerBeat
        self.midiRange = midiRange
        self.rowHeight = rowHeight
    }

    /// **The blessed construction path.** Derives all four geometry terms from
    /// the clip itself, so no caller can pair a window with the wrong length or
    /// hand in a clamped detection window (see `sourceWindowSeconds`).
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
                  rowHeight: rowHeight)
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
    public func rect(for blob: NoteBlob) -> CGRect {
        let left = x(forSourceSecond: blob.startSeconds)
        let right = x(forSourceSecond: blob.endSeconds)
        let width = max(Self.minimumVisibleBlobWidth, right - left)
        let height = rowHeight * Self.blobHeightFraction
        return CGRect(x: left, y: y(forMidi: blob.centreMidi) - height / 2,
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

// MARK: - The model

/// What the pitch editor's detection provider does: a clip id in, a detection
/// out. `ProjectStore.detectClipPitch(clipId:)` IS this shape; the closure
/// exists so the model never holds the store and the suite can drive every
/// path — including the ones a real engine cannot be made to take on demand
/// (the `ClipFixModel` injected-closure precedent).
public typealias PitchEditorDetectionProvider = @MainActor (UUID) async throws -> ClipPitchDetection

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

    /// The contour as screen polylines — one per detected note, **never one
    /// path across a hole** (§5.5.1). Re-derived from `geometry` on read, so a
    /// zoom change needs no re-detection.
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

        // ⭐ SEGMENTATION IS `PitchAutoCorrect.voicedRuns`' JOB, NOT THIS
        // FILE'S. It already ends a run at a hole AND at any frame gap larger
        // than 1.5 frame periods, and drops runs under `minimumNoteSeconds`.
        // Re-implementing that rule here would be a second home for it, and
        // the two would drift silently — the contour below is therefore
        // derived FROM these runs rather than from a second split pass.
        let runs = PitchAutoCorrect.voicedRuns(in: result.frames, frameRateHz: result.frameRateHz)
        blobs = runs.map { NoteBlob(run: $0) }
        contourRuns = Self.contourRuns(frames: result.frames, blobs: blobs)
        gaps = Self.gaps(frames: result.frames, frameRateHz: result.frameRateHz)
        phase = .detected
        autoFitMidiRange()
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
        clearDetection()
        phase = .notStarted
    }

    private func clearDetection() {
        blobs = []
        contourRuns = []
        gaps = []
        frameRateHz = 0
        analysedFrameCount = 0
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
        geometry.midiRange = PitchEditorRange.midiRange(forNoteCentres: blobs.map(\.centreMidi))
    }

    // MARK: Contour derivation

    /// Gather each note's OWN voiced frames.
    ///
    /// ⛔ **THE HOLE RULE, AND WHY THIS IS NOT A SECOND IMPLEMENTATION OF IT.**
    /// The runs come from `PitchAutoCorrect.voicedRuns`, which is the ONE home
    /// for "where does a note stop". This function only collects the frames
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
