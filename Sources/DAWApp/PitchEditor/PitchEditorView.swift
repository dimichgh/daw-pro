import AppKit
import SwiftUI
import DAWAppKit
import DAWCore

// m23-ap Phase 2, item p2-b — THE PIXELS.
//
// Design record: `docs/design/2026-09-22-pitch-editor-ui.md` — §3 (why this is a
// SECOND bottom pane and not a mode of the roll), §5.6 (what is on screen), §5.7
// (the states), §5.8 (zoom / follow / density), §5.9 (real-time safety), §6.2
// Door 2 (the preset chips). The headless model — every conversion, every
// derived value, every string — is `DAWAppKit.PitchEditorModel`; **this file
// draws and gestures and does no math of its own.** `DAWApp` has no test
// target, which is the reason rather than a preference.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⛔ THREE RULES THIS FILE CAN BREAK SILENTLY, ALL THREE MEASURED ELSEWHERE
// ═══════════════════════════════════════════════════════════════════════════
//
//  1. **A HOLE IS THE SIGNAL. NEVER BRIDGE ONE** (§5.5.1). The line is drawn
//     as N separate polylines — one `Path` per voiced RUN (never per note: a
//     split puts two notes in one run, and the line must not break at the
//     cut) — never one `Path` that `addLine`s across an unvoiced stretch. A
//     single path would invent pitch where none was measured, and it is the
//     obvious implementation.
//
//  ⭐ **THE LINE IS WHAT THE RENDER WILL PLAY, NOT WHAT THE SINGER SANG** (m23-ap
//     C-0, design 2026-09-24 §4). It is `PitchPlayedLine` — the render's own
//     contour through the render's own curve, transpose included — so a note
//     dragged up a semitone carries its wobble INSIDE the moved blob, and the
//     ghost left at the sung pitch is an OUTLINE ONLY. Before C-0 the line was
//     the detected contour: the wobble stayed behind in the ghost while the
//     audio played it at the new pitch, and the user saw the picture disagree
//     with the sound.
//  2. **NO SMOOTHING** (§5.5.2). SwiftF0's output is an argmax over 256
//     log-spaced bins: 25.79 cents per bin. The visible staircase IS the
//     detector's resolution; a curve through it draws a precision nobody has.
//  3. **THE WAVEFORM'S x MUST GO THROUGH `PitchEditorGeometry`** and nothing
//     else. `ClipWaveform`'s inline `startOffsetSeconds + x/ppb × secondsPerBeat`
//     carries NO stretch-ratio term and no tempo map — copying it here would
//     slide the waveform out from under the blobs on any stretched or
//     tempo-changing clip, with nothing on screen to say so.
//
// ⚠️ **NOT IN THIS INCREMENT, AND NAMED SO IT IS NOT MISTAKEN FOR DONE:**
//  • **FOLLOW-PLAYHEAD.** §5.8 asks for `FollowPlayheadModel` + the ONE
//    `layout.followPlayhead` flag both surfaces read. It is deliberately NOT
//    wired here: the page-turn rule needs an app-held runtime that survives a
//    clip switch (`AppModel.pianoRollFollow`'s twin) plus a `ScrollViewReader`
//    offset owner, it is invisible to a still capture, and Increment A is a
//    microscope rather than a player. Wiring it is a later item; until then the
//    FOLLOW chip correctly says nothing about this pane, because this pane
//    makes no claim to follow.
//  • **SIMPLE / PRO CHIP.** §5.8 forbids one: this surface has ONE mode, and
//    `docs/DESIGN-LANGUAGE.md` — *"a toggle that changes nothing is worse than
//    none"* — is why. If Increment C's tool set makes the modes genuinely
//    differ, it earns a chip then, and the verdict is recorded in
//    `docs/research/simple-pro-inventory.md`.

// MARK: - The chrome ledger (the spy seam)

/// What the pitch editor's header ACTUALLY DREW, reported from inside the
/// drawing arguments themselves.
///
/// ⭐ **A SPY GATE BEATS A SOURCE-SHAPE GATE, and this is the seam that makes
/// one possible.** `DAWApp` has no test target, so the only honest way to prove
/// that the six states reach the screen as six DIFFERENT sentences is to have
/// the view report the very `String` it handed to `Text`. A gate that greps this
/// file for the strings proves the file contains them, not that anything drew
/// them; a gate that re-derives them from `PitchEditorState.message` agrees with
/// itself and with nothing on screen. This is `PianoRollView.BarOpsStyleLedger`'s
/// shape and its reasoning, one surface over.
///
/// Deliberately NOT `@Observable`: it is written DURING `body`, and an
/// observable write there would invalidate the view that is drawing.
/// `p2-c`'s `debug.pitchEditor` echo reads it.
@MainActor
final class PitchEditorChromeLedger {
    /// `PitchEditorState.statusKey` — the stable machine tag.
    private(set) var statusKey = ""
    /// The status sentence the header drew, verbatim.
    private(set) var statusText = ""
    /// The confidence legend, drawn only when notes are on screen ("" otherwise).
    private(set) var captionText = ""
    /// The preset chips' labels, in the order drawn.
    private(set) var presetLabels: [String] = []
    /// Each chip's drawn summary prose — §6.2 Door 2 requires these as DRAWN
    /// PROSE rather than tooltips, because a tooltip is invisible to
    /// `view.capture` and a captured gate then cannot tell a correct caption
    /// from a missing one (the `EQCurveEditor.help` lesson, verbatim).
    private(set) var presetSummaries: [String] = []
    /// How many note blobs the surface was handed.
    private(set) var noteCount = 0
    /// Whether the header said the clip already carries tuning.
    private(set) var tuningApplied = false
    /// One per report. Counted, never reasoned about.
    private(set) var ticks = 0

    // MARK: The interaction half (m23-ap Increment C)

    /// `PitchEditorTool.rawValue` of the slot the palette drew as ACTIVE.
    private(set) var toolKey = ""
    /// Every palette slot's label, in the order drawn.
    private(set) var paletteLabels: [String] = []
    /// The active tool's drawn help prose — DRAWN, not a tooltip, for the
    /// `EQCurveEditor.help` reason this whole type exists for.
    private(set) var toolHelp = ""
    /// The live drag's readout, verbatim, or "" when nothing is being dragged.
    /// ⚠️ "" and "+0 cents" are DIFFERENT facts and this must not merge them:
    /// the first is "no drag", the second would be a claim of a zero-cent move
    /// that `PitchEditorReadout`'s floor forbids anyone from making.
    private(set) var dragReadout = ""
    /// The refusal prose on screen, or "".
    private(set) var refusalText = ""
    /// How many commits the MODEL has emitted, as the palette last saw it.
    /// ⭐ This is the number that makes a per-tick commit VISIBLE from outside
    /// the view: it can only move on a gesture end.
    private(set) var commitCount = 0
    /// One per interaction report. Counted, never reasoned about.
    private(set) var interactionTicks = 0

    // MARK: The played line (m23-ap C-0, design 2026-09-24 §4.4)

    /// `PitchPlayedLine.Basis.key` of the line the surface strokes —
    /// `"render"` or `"estimate"` — or "" before the first report.
    private(set) var lineBasisKey = ""
    /// `PitchPlayedLine.Basis.reason` — why the line is an estimate, or `nil`
    /// when it is the render's own. (The drawn caption below equals it for an
    /// estimate; for a render-basis line the caption, if any, is the
    /// unresolved-notes sentence instead.)
    private(set) var lineReason: String?
    /// The caption the palette DREW about the line, verbatim, or "".
    private(set) var lineCaptionText = ""
    /// `PitchEditorLineCaption.Kind.rawValue` of that caption, or "".
    private(set) var lineCaptionKind = ""
    /// The notes drawn with the amber "no steady pitch" outline.
    private(set) var unresolvedNoteIDs: [UUID] = []
    /// The clip transpose the surface drew at.
    private(set) var clipPitchShiftSemitones: Double = 0
    /// Per drawn note, the played line's min / median / max midi.
    private(set) var perNote: [PitchPlayedLine.NoteSummary] = []
    /// One per played-line report. Counted, never reasoned about.
    private(set) var lineTicks = 0

    init() {}

    func recordPlayedLine(basisKey: String, reason: String?, captionText: String,
                          captionKind: String, unresolvedNoteIDs: [UUID],
                          clipPitchShiftSemitones: Double,
                          perNote: [PitchPlayedLine.NoteSummary]) {
        lineTicks += 1
        self.lineBasisKey = basisKey
        self.lineReason = reason
        self.lineCaptionText = captionText
        self.lineCaptionKind = captionKind
        self.unresolvedNoteIDs = unresolvedNoteIDs
        self.clipPitchShiftSemitones = clipPitchShiftSemitones
        self.perNote = perNote
    }

    func recordInteraction(toolKey: String, paletteLabels: [String], toolHelp: String,
                           dragReadout: String, refusalText: String, commitCount: Int) {
        interactionTicks += 1
        self.toolKey = toolKey
        self.paletteLabels = paletteLabels
        self.toolHelp = toolHelp
        self.dragReadout = dragReadout
        self.refusalText = refusalText
        self.commitCount = commitCount
    }

    func record(statusKey: String, statusText: String, caption: String,
                presetLabels: [String], presetSummaries: [String],
                noteCount: Int, tuningApplied: Bool) {
        ticks += 1
        self.statusKey = statusKey
        self.statusText = statusText
        self.captionText = caption
        self.presetLabels = presetLabels
        self.presetSummaries = presetSummaries
        self.noteCount = noteCount
        self.tuningApplied = tuningApplied
    }

    func clear() {
        toolKey = ""
        paletteLabels = []
        toolHelp = ""
        dragReadout = ""
        refusalText = ""
        commitCount = 0
        interactionTicks = 0
        statusKey = ""
        statusText = ""
        captionText = ""
        presetLabels = []
        presetSummaries = []
        noteCount = 0
        tuningApplied = false
        ticks = 0
        lineBasisKey = ""
        lineReason = nil
        lineCaptionText = ""
        lineCaptionKind = ""
        unresolvedNoteIDs = []
        clipPitchShiftSemitones = 0
        perNote = []
        lineTicks = 0
    }
}

// MARK: - The draw context

/// A value snapshot of everything the surface renderer needs, taken on the main
/// actor before the `@Sendable` closure (CANVAS CONTRACT, m16-a — a crash
/// precedent exists, `docs/research/design-m16a-canvas-crash.md`).
///
/// ⭐⭐ **`playedLine` IS SNAPSHOTTED, NOT COMPUTED HERE, AND THAT IS THE POINT.**
/// `PitchEditorModel.playedLineSegments(excluding:)` re-maps EVERY drawn frame
/// through the geometry on each call — O(frames), ~11,250 of them on a
/// three-minute vocal. Calling it inside the renderer (or rebuilding this
/// context on every transport tick) would pay that per redraw. It is cached by
/// the view and refreshed on exactly the events that can change it: the line
/// being rebuilt (`playedLineRevision`), the geometry moving, and a drag
/// starting or ending (the dragged note's stretch leaves the surface for the
/// drag overlay and comes back) — never per pointer tick.
///
/// `positionBeats` is deliberately NOT a field — the playhead is its own view —
/// so a transport tick leaves every field here EQUAL, which is the precondition
/// for `.equatable()` to skip the surface (`PianoRollGrid`'s extraction, same
/// reason). ⚠️ **THAT THE SKIP ACTUALLY HAPPENS IS UNVERIFIED, AND IS NAMED
/// RATHER THAN ASSUMED** — `KeyboardSidebar` carries the same admission about
/// its own cadence. Two things are known: the fields are equal by construction,
/// and `Array`'s `==` short-circuits on an identical buffer, so comparing the
/// played line is not itself O(frames) for the unchanged case. What nobody has
/// measured here is how often SwiftUI re-evaluates this view under a running
/// transport. **A signpost on the draw closure during playback is what would
/// settle it**; until someone runs one, do not quote a cadence for this pane.
struct PitchEditorDrawContext: Equatable {
    var geometry: PitchEditorGeometry
    var blobs: [NoteBlob]
    /// THE PLAYED LINE (m23-ap C-0): one polyline per voiced run, the pitch the
    /// render will play at each frame. **Never one path across a hole.**
    var playedLine: [[CGPoint]]
    /// True when the line is an ESTIMATE (the seam had no frames): it is drawn
    /// at reduced strength and the palette says why (design §4.4).
    var lineIsEstimate: Bool
    /// Notes whose wobble setting could not be applied — an amber dashed
    /// outline each.
    var unresolvedNoteIDs: Set<UUID>
    /// The note being dragged, drawn by `PitchEditorDragOverlay` instead of
    /// here for the length of the gesture — so the moving note is never drawn
    /// twice, and never left behind.
    var hiddenBlobID: UUID?
    var gaps: [PitchEditorGap]
    var peaks: WaveformPeaks?
    /// The m25-e auto-fit scalar, resolved per-view from the headless rules —
    /// never per column and never per frame.
    var waveformScale: CGFloat
    /// Whether there are notes to draw at all (`PitchEditorState.drawsNotes`).
    var drawsNotes: Bool

    init(geometry: PitchEditorGeometry, blobs: [NoteBlob], playedLine: [[CGPoint]],
         lineIsEstimate: Bool = false, unresolvedNoteIDs: Set<UUID> = [],
         hiddenBlobID: UUID? = nil, gaps: [PitchEditorGap], peaks: WaveformPeaks?,
         waveformScale: CGFloat, drawsNotes: Bool) {
        self.geometry = geometry
        self.blobs = blobs
        self.playedLine = playedLine
        self.lineIsEstimate = lineIsEstimate
        self.unresolvedNoteIDs = unresolvedNoteIDs
        self.hiddenBlobID = hiddenBlobID
        self.gaps = gaps
        self.peaks = peaks
        self.waveformScale = waveformScale
        self.drawsNotes = drawsNotes
    }
}

// MARK: - The surface

/// The pitch editor's drawing layers (design §5.6, bottom to top): waveform ·
/// pitch grid · unvoiced stretches · note blobs · the played line · note
/// names. **No playhead** — see `PitchEditorDrawContext`.
struct PitchEditorSurface: View, Equatable {
    var ctx: PitchEditorDrawContext

    /// Field-by-field over ONE value, so `.equatable()` can skip a redraw whose
    /// inputs did not move — which is what keeps a transport tick from
    /// re-stroking several thousand contour points.
    nonisolated static func == (a: PitchEditorSurface, b: PitchEditorSurface) -> Bool {
        a.ctx == b.ctx
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): value captures only, computed before the closure.
        let ctx = ctx
        return Canvas { @Sendable context, size in
            Self.drawWaveform(&context, size: size, ctx: ctx)
            Self.drawPitchGrid(&context, size: size, ctx: ctx)
            Self.drawGaps(&context, size: size, ctx: ctx)
            Self.drawBlobs(&context, ctx: ctx)
            Self.drawPlayedLine(&context, lines: ctx.playedLine, estimate: ctx.lineIsEstimate)
            Self.drawBlobLabels(&context, ctx: ctx)
        }
    }

    // MARK: Layer 1 — the waveform

    /// The clip's peaks, full height and **dim**: it is context, not the subject
    /// (§5.6.1). Mirrored around the vertical centre like every other waveform
    /// in the app, so the same recording reads the same shape here and in the
    /// arrange.
    ///
    /// ⛔ **x → SOURCE SECOND GOES THROUGH THE GEOMETRY**, which carries the
    /// stretch ratio AND the tempo map. `ClipWaveform`'s inline arithmetic
    /// carries neither and must not be copied here (this file's banner, rule 3).
    private nonisolated static func drawWaveform(_ context: inout GraphicsContext,
                                                 size: CGSize, ctx: PitchEditorDrawContext) {
        guard let peaks = ctx.peaks else { return }
        let midY = size.height / 2
        let halfH = size.height / 2 - 2
        let maxH = size.height / 2
        // ⚠️ **1.0, NOT `ClipWaveform`'s 1.5 — AND THAT IS A DEFECT I COULD ONLY
        // SEE BY RENDERING ONE.** At a 1.5 pt step with a 1 pt stroke the
        // columns do not touch, and over a clip-block's 30-odd points the gaps
        // are invisible. Here the layer is FULL PANE HEIGHT — hundreds of points
        // — so the same gaps stack into a picket fence that reads as diagonal
        // hatching behind the notes rather than as a waveform. Contiguous
        // columns cost one extra stroke per 1.5 pt of width and are still
        // rebuilt only on a data change, never per frame.
        let step: CGFloat = 1.0
        var body = Path()
        var core = Path()
        var x: CGFloat = 0
        while x <= size.width {
            let seconds = ctx.geometry.sourceSecond(forX: x)
            let mag = CGFloat(peaks.magnitude(atSeconds: seconds))
            let drawn = max(0.5, mag * ctx.waveformScale * halfH)
            let bodyH = min(maxH, drawn)
            body.move(to: CGPoint(x: x, y: midY - bodyH))
            body.addLine(to: CGPoint(x: x, y: midY + bodyH))
            let coreH = min(maxH, drawn * 0.55)
            core.move(to: CGPoint(x: x, y: midY - coreH))
            core.addLine(to: CGPoint(x: x, y: midY + coreH))
            x += step
        }
        // `textDim` at low opacity — the muted tier, dimmed further because this
        // layer is BEHIND the subject. No accent: a waveform is not a state.
        context.stroke(body, with: .color(DAWTheme.textDim.opacity(0.16)), lineWidth: 1)
        context.stroke(core, with: .color(DAWTheme.textDim.opacity(0.30)), lineWidth: 1)
    }

    // MARK: Layer 2 — the pitch grid

    /// One hairline per semitone, brighter at each C (§5.6.2). The rows come
    /// from `PitchEditorGeometry.rulerKeys` and are placed by
    /// `rowTopY(forMidi:)` — the SAME two calls `PitchRulerSidebar` makes, which
    /// is why the two columns cannot drift a fraction of a row apart.
    private nonisolated static func drawPitchGrid(_ context: inout GraphicsContext,
                                                  size: CGSize, ctx: PitchEditorDrawContext) {
        for key in ctx.geometry.rulerKeys {
            let y = ctx.geometry.rowTopY(forMidi: Double(key.midi))
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: key.isOctaveC ? 1 : 0.5)),
                with: .color(key.isOctaveC ? DAWTheme.gridEmphasis : DAWTheme.hairline))
        }
    }

    // MARK: Layer 3 — the gaps

    /// The unvoiced stretches, **kept apart by KIND** (§5.5's sixth rule, from
    /// `PitchDetection.swift`): *"A stretch of `belowLevel` is a REST; a stretch
    /// of `belowConfidence` is WE COULD NOT TELL. Those are different facts and
    /// the UI may show them differently, but must not merge them into 'no
    /// note'."*
    ///
    /// So a rest draws in the decorative floor tier (nothing happened, and
    /// nothing is wrong), while an uncertain stretch draws in **amber** —
    /// `DAWTheme.record`, the "warning" token the refusal line already owns —
    /// because the detector heard something it would not name, and that is a
    /// fact about the measurement rather than about the music. Both draw as a
    /// dashed strip along the floor of the surface, never as a silence that
    /// looks like the rest of the editor.
    ///
    /// The prose is drawn too, when the stretch is wide enough to hold it. ⚠️ A
    /// gap is reported for EVERY unvoiced run including one-frame ones (the
    /// model does not filter by width, on purpose), so the width test here is a
    /// DRAWING decision and not a second opinion about what counts as a gap.
    private nonisolated static func drawGaps(_ context: inout GraphicsContext,
                                             size: CGSize, ctx: PitchEditorDrawContext) {
        guard ctx.drawsNotes else { return }
        let stripHeight: CGFloat = 3
        let y = size.height - stripHeight - 1
        for gap in ctx.gaps {
            let left = ctx.geometry.x(forSourceSecond: gap.startSeconds)
            let right = ctx.geometry.x(forSourceSecond: gap.endSeconds)
            let width = right - left
            guard width > 1 else { continue }
            let ink = gap.kind == .rest
                ? DAWTheme.textFaint.opacity(0.55)
                : DAWTheme.record.opacity(0.55)
            // ⚠️ **THE FULL-HEIGHT BAND EXISTS BECAUSE A FOOTER STRIP ALONE DID
            // NOT READ.** MEASURED by looking: with the notes in the middle of a
            // 320 pt window and the strip pinned to the floor, the marks read as
            // stray specks at the bottom edge rather than as "this stretch of
            // TIME has no note". The band is what locates them in x; the strip
            // is what makes the KIND legible. Very low alpha on purpose — it is
            // a region, not an object.
            context.fill(
                Path(CGRect(x: left, y: 0, width: width, height: size.height)),
                with: .color(ink.opacity(gap.kind == .rest ? 0.045 : 0.06)))
            var strip = Path()
            strip.move(to: CGPoint(x: left, y: y))
            strip.addLine(to: CGPoint(x: right, y: y))
            context.stroke(strip, with: .color(ink),
                           style: StrokeStyle(lineWidth: stripHeight, dash: [3, 3]))
            // `gap.label` — the model's own words ("No sound here" /
            // "We could not hear a clear note here"), never a merged "no note".
            guard width > 150 else { continue }
            context.draw(
                Text(gap.label)
                    .font(.system(size: 9))
                    .foregroundColor(ink),
                at: CGPoint(x: left + width / 2, y: y - 9), anchor: .center)
        }
    }

    // MARK: Layer 4 — the blobs

    /// One rounded rect per detected note (§5.6.3).
    ///
    /// **Fill = neutral raised panel; NO ACCENT AT REST.** The design language's
    /// Rule 3: an accent is earned by state, not by inviting a click. And
    /// specifically **no violet** — a detected contour is a MEASUREMENT, not
    /// AI-generated content — and **no cyan**, which means playback and nothing
    /// else.
    ///
    /// ⚠️ **OPACITY ENCODES CONFIDENCE, AND CONFIDENCE IS VOICING — NOT
    /// ACCURACY** (§5.5.4). A 440 Hz sine reads 437.55 Hz, 9.7 cents flat, at
    /// confidence ≥ 0.985. The header draws the honest label for this encoding
    /// ("how sure we are you were singing here"); it must never gate a tolerance
    /// and must never be presented as accuracy.
    private nonisolated static func drawBlobs(_ context: inout GraphicsContext,
                                              ctx: PitchEditorDrawContext) {
        // The dragged note is the DRAG OVERLAY's for the length of the gesture
        // (it draws the ghost, the moving blob and the moving line) — drawn
        // here too, it would sit at its committed row under the moving one.
        for blob in ctx.blobs where blob.id != ctx.hiddenBlobID {
            let rect = ctx.geometry.rect(for: blob)
            let confidence = min(1, max(0, blob.medianConfidence))
            let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.height / 3))
            // ⚠️ **TWO FILLS, AND THE SECOND ONE IS WHY THE BLOB IS VISIBLE AT
            // ALL.** MEASURED by looking at a render: `panelRaised` (#181C27)
            // composited over `background` (#0B0D12) is a delta of ~13 levels —
            // the first pass drew the blobs and they could not be seen, only
            // their hairline could. The opaque base pins the surface, and the
            // NEUTRAL wash on top is what carries the confidence encoding into
            // visible range. Still no accent: a detected note is not a state
            // (Rule 3), and `textDim` is the app's neutral ink, not a colour.
            context.fill(shape, with: .color(DAWTheme.panelRaised))
            // ⛔ **AN EDITED NOTE MUST NOT LOOK LIKE AN UNTOUCHED ONE — A
            // DEFECT I COULD ONLY SEE BY RENDERING ONE.** The first pass drew
            // every blob in the neutral ink at its EDITED position, which is
            // right, and left the picture unable to say WHICH notes had been
            // moved: six identical rectangles, three of them changed. The
            // accent is earned by STATE here, which is the one thing
            // `docs/DESIGN-LANGUAGE.md` Rule 3 allows it for. `signal`, never
            // cyan (playback) and never violet (AI-touched content) — a person
            // tuning their own vocal is neither.
            let ink = blob.isEdited ? DAWTheme.signal : DAWTheme.textDim
            context.fill(shape, with: .color(ink.opacity(0.10 + 0.18 * confidence)))
            context.stroke(shape,
                           with: .color(ink.opacity(0.22 + 0.33 * confidence)),
                           lineWidth: 1)
            // C-0 — a note whose wobble setting the render could NOT apply
            // (no steady pitch heard in it, or no contour to shape against):
            // an AMBER dashed outline, set 2 pt outside the blob so its own
            // stroke still reads. Amber is `record` — the warning token the
            // palette's caption line wears for the same fact, in words.
            if ctx.unresolvedNoteIDs.contains(blob.id) {
                let halo = rect.insetBy(dx: -2, dy: -2)
                context.stroke(Path(roundedRect: halo, cornerRadius: min(5, halo.height / 3)),
                               with: .color(DAWTheme.record.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            guard blob.isMoved else { continue }
            // ⭐ THE GHOST STAYS AFTER THE DRAG ENDS. Where the note was SUNG
            // is a fact about the performance, and it is the only thing that
            // makes "how far did I move this" answerable once the pointer is
            // up. ⛔ **AN OUTLINE ONLY — NOTHING IS DRAWN INSIDE IT** (C-0).
            // The line is the PLAYED line and it moved with the note; a wobble
            // drawn in the ghost is exactly the "left behind" picture the user
            // reported, of a sound that is no longer there. On the transposed
            // axis, like everything else (`ghostRect(for:)` says why).
            let sung = ctx.geometry.ghostRect(for: blob)
            context.stroke(Path(roundedRect: sung, cornerRadius: min(4, sung.height / 3)),
                           with: .color(DAWTheme.textDim.opacity(0.40)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if abs(sung.midY - rect.midY) > 1 {
                var link = Path()
                link.move(to: CGPoint(x: sung.midX, y: sung.midY))
                link.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
                context.stroke(link, with: .color(DAWTheme.signal.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
    }

    /// The note names, in their OWN pass **after** the contour, and drawn in the
    /// gutter ABOVE each blob rather than inside it.
    ///
    /// ⛔ **BOTH OF THOSE ARE FIXES FOR A DEFECT I COULD ONLY SEE BY LOOKING.**
    /// The first render drew the name inside the blob at its leading edge, which
    /// is *exactly* where the onset scoop puts the brightest part of the contour
    /// — every label came out as illegible glyph fragments under a white line.
    /// Ordering alone would not have fixed it (the label would then hide the
    /// measurement), so the label moves off the line entirely.
    ///
    /// Suppressed, never truncated and never scaled down, when the rect is too
    /// narrow or the row too short to hold an 8 pt face — `PianoRollNoteLabel.fits`'
    /// rule, and the reason this is a fit test rather than a zoom threshold table.
    private nonisolated static func drawBlobLabels(_ context: inout GraphicsContext,
                                                   ctx: PitchEditorDrawContext) {
        guard ctx.geometry.rowHeight >= 11 else { return }
        for blob in ctx.blobs where blob.id != ctx.hiddenBlobID {
            let rect = ctx.geometry.rect(for: blob)
            guard rect.width >= 20 else { continue }
            // ⛔ **THE DRAWN NOTE'S NAME, NOT `noteName` — THE SECOND DEFECT
            // THE RENDER SHOWED.** With the blob drawn at its EDITED pitch, a
            // label carrying the SUNG note put "B3" on a rectangle sitting on
            // the C4 row: the picture contradicted itself, and the label is the
            // part a novice believes. The label names the note this blob IS —
            // on a transposed clip, the transposed note (C-0) — and where it
            // came from is said by the ghost outline, a picture of a
            // measurement rather than a claim in words.
            context.draw(
                Text(ctx.geometry.drawnNoteName(for: blob))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(blob.isEdited ? DAWTheme.signal : DAWTheme.textSecondary),
                at: CGPoint(x: rect.minX + 1, y: rect.minY - 1), anchor: .bottomLeading)
        }
    }

    // MARK: Layer 5 — the played line

    /// How strong an ESTIMATE line is drawn, as a fraction of the render line
    /// (design §4.4: `textPrimary` at 45 %). The halo scales with it, so the
    /// estimate reads as the same line, fainter — not as a different object.
    nonisolated static let estimateStrength: Double = 0.45 / 0.92

    /// THE PLAYED LINE (m23-ap C-0) — the pitch the render will play at each
    /// frame — drawn THROUGH the blobs, bloom-under-core (the house glow
    /// recipe: wide faint stroke, then a bright narrow one —
    /// `AutomationLaneEditor.drawPolyline`). Shared with `PitchEditorDragOverlay`,
    /// which strokes the dragged note's stretch of the SAME line with the SAME
    /// recipe, so the two halves read as one line while the pointer is down.
    ///
    /// ⛔ **ONE `Path` PER RUN.** `lines` arrives already split at every hole
    /// by `PitchEditorModel`; joining them here would be exactly the
    /// bridged-hole lie rule 1 forbids, and the loop below is the whole of the
    /// mitigation.
    ///
    /// ⛔ **`textPrimary`, NOT AN ACCENT.** Cyan is playback/position and
    /// nothing else; violet is AI-touched content, and a tuned vocal is the
    /// user's own voice run through a curve they chose. `lineJoin: .miter`
    /// rather than `.round`: the 25.79-cent staircase IS the instrument's
    /// resolution (rule 2) and a rounded join would sand it off.
    nonisolated static func drawPlayedLine(_ context: inout GraphicsContext,
                                           lines: [[CGPoint]], estimate: Bool) {
        let strength = estimate ? estimateStrength : 1
        for points in lines {
            guard points.count > 1 else {
                // A one-frame run still gets drawn — as a dot. Dropping it would
                // silently unreport a measurement that exists.
                if let only = points.first {
                    context.fill(
                        Path(ellipseIn: CGRect(x: only.x - 1, y: only.y - 1, width: 2, height: 2)),
                        with: .color(DAWTheme.textPrimary.opacity(0.9 * strength)))
                }
                continue
            }
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }
            context.stroke(line, with: .color(DAWTheme.textPrimary.opacity(0.16 * strength)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .butt, lineJoin: .miter))
            context.stroke(line, with: .color(DAWTheme.textPrimary.opacity(0.92 * strength)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .miter))
        }
    }
}

// MARK: - The playhead

/// The cyan transport line over the pitch editor, in its own view so a transport
/// tick redraws THIS and not the surface.
///
/// **The SAME transport source the arrange consumes — no second ticker.** The
/// clip-local mapping is `PitchEditorGeometry`'s, which is also what every other
/// layer maps with, so the line cannot sit a pixel off the blob it is crossing.
struct PitchEditorPlayhead: View {
    var geometry: PitchEditorGeometry
    var positionBeats: Double

    var body: some View {
        let inside = geometry.isInsideClip(projectBeat: positionBeats)
        let x = geometry.x(forProjectBeat: positionBeats)
        return Rectangle()
            .fill(DAWTheme.playback)
            .frame(width: 1.5)
            .glow(DAWTheme.playback, radius: 5, intensity: 0.55)
            .offset(x: x)
            .opacity(inside ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - "Listening…" shimmer

/// The re-analysing cue — `ClipShimmer`'s recipe (`TimelineLanesView`), copied
/// rather than shared because that type is `private` to a file a concurrent
/// agent owns. ⚠️ If the two ever need to agree, HOIST it into `Components/`;
/// do not let a third copy appear.
private struct PitchAnalysisShimmer: View {
    var tint: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(28, w * 0.4)
            LinearGradient(
                colors: [.clear, tint.opacity(0.22), Color.white.opacity(0.16),
                         tint.opacity(0.22), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + phase * (w + band))
                .blendMode(.screen)
                .onAppear {
                    withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The live drag (m23-ap C1)

/// The moving note, its GHOST at the pitch it was sung at, and the readout.
///
/// ⭐⭐ **ITS OWN VIEW, FOR THE SAME REASON THE PLAYHEAD IS.** A pitch drag
/// changes one number sixty times a second. If the moving blob were drawn by
/// `PitchEditorSurface`, `PitchEditorDrawContext` would differ on every tick,
/// `.equatable()` could never skip, and the Canvas would re-stroke several
/// thousand contour points at pointer rate — the exact cost the surface's
/// snapshot was built to avoid. Here the draft moves and the surface does not.
///
/// ⚠️ **THE COST IS PER POINTER TICK, NOT PER DISPLAY FRAME — AND THE
/// DISTINCTION IS THE REASON THIS IS ALLOWED TO ALLOCATE AT ALL.** Two `Path`s,
/// a `Text` and two `CGRect`s are allocations, and the house rule that drawing
/// code must not allocate per frame is about surfaces that redraw CONTINUOUSLY
/// (meters, scopes, a `TimelineView` at 60 fps). This layer redraws only while
/// a finger is down, at pointer rate, over two rectangles and ONE NOTE'S
/// stretch of the line (C-0: a few dozen points). What it must not do is drag
/// the WHOLE line — several thousand points — along with it, and that is what
/// putting it in its own view buys: the surface cuts the dragged stretch out
/// once when the gesture starts and puts it back once when it ends. Inputs
/// are captured before the closure either way (CANVAS CONTRACT, m16-a).
struct PitchEditorDragOverlay: View, Equatable {
    var geometry: PitchEditorGeometry
    var draft: PitchEditorDragDraft
    /// C-0 — the dragged note's stretch of the DRAFT played line
    /// (`PitchEditorModel.draftLineSegments`): the wobble riding with the
    /// moving note. The surface leaves exactly this stretch out while the
    /// pointer is down, so the line is drawn once, in one place.
    var draftLine: [[CGPoint]] = []
    /// Whether the line is an estimate (drawn fainter, like the surface's).
    var lineIsEstimate: Bool = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.geometry == b.geometry && a.draft == b.draft
            && a.draftLine == b.draftLine && a.lineIsEstimate == b.lineIsEstimate
    }

    var body: some View {
        let geometry = geometry
        let draft = draft
        let draftLine = draftLine
        let estimate = lineIsEstimate
        return Canvas { @Sendable context, _ in
            // Both on the TRANSPOSED axis the surface draws on (C-0).
            let ghost = geometry.rect(startSeconds: draft.startSeconds,
                                      endSeconds: draft.endSeconds,
                                      centreMidi: draft.ghostMidi)
            let live = geometry.rect(startSeconds: draft.startSeconds,
                                     endSeconds: draft.endSeconds,
                                     centreMidi: draft.targetMidi)

            // THE GHOST — where the singer actually was. Dashed, dim, no fill,
            // and ⛔ NOTHING INSIDE IT (C-0): it is a memory of a measurement,
            // not an object, and the wobble it once held is now drawn where it
            // will be HEARD, in the moving note below. Without it a novice has
            // no way to see how far they have moved a note.
            context.stroke(Path(roundedRect: ghost, cornerRadius: min(4, ghost.height / 3)),
                           with: .color(DAWTheme.textDim.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // The connector: one hairline from the ghost's centre to the live
            // centre, so the distance is a THING on screen and not an inference.
            if abs(live.midY - ghost.midY) > 1 {
                var link = Path()
                link.move(to: CGPoint(x: ghost.midX, y: ghost.midY))
                link.addLine(to: CGPoint(x: live.midX, y: live.midY))
                context.stroke(link, with: .color(DAWTheme.signal.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }

            // THE MOVING NOTE. `signal` — the accent is EARNED BY STATE here
            // (Rule 3): this note is being changed right now. Never cyan
            // (playback) and never violet (AI-touched content) — a person
            // dragging their own vocal is neither.
            let shape = Path(roundedRect: live, cornerRadius: min(4, live.height / 3))
            context.fill(shape, with: .color(DAWTheme.panelRaised))
            context.fill(shape, with: .color(DAWTheme.signal.opacity(0.30)))
            context.stroke(shape, with: .color(DAWTheme.signal.opacity(0.85)), lineWidth: 1.5)

            // THE MOVING LINE (C-0) — the dragged note's stretch of what the
            // render WILL play at this draft, built by the same `make` the
            // committed line is, and committed nowhere. Over the moving fill,
            // so the wobble reads inside the note that carries it. A few dozen
            // points: this is the part of the line that is allowed to move at
            // pointer rate, and the only part.
            PitchEditorSurface.drawPlayedLine(&context, lines: draftLine, estimate: estimate)

            // The readout, ABOVE the note and never inside it — the same defect
            // the note labels were moved out of the blob for: the contour runs
            // through the middle of a blob and eats anything drawn there.
            // ⚠️ `draft.readout` is nil BELOW the detector's 12.90-cent floor,
            // and nil draws NOTHING. A "+0 cents" there would be a precision
            // claim this chain cannot support (§5.5.3).
            if let readout = draft.readout {
                let text = "\(draft.targetNoteName)  \(readout)"
                context.draw(
                    Text(text)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(DAWTheme.signal),
                    at: CGPoint(x: live.midX, y: live.minY - 3), anchor: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The scissors preview (m23-ap C3)

/// Where the cut would land. Drawn only while the scissors tool is engaged and
/// the pointer is over a note — a cut line hovering over empty space would be
/// an offer the tool refuses.
struct PitchEditorCutPreview: View, Equatable {
    var x: CGFloat
    var rect: CGRect

    var body: some View {
        Rectangle()
            .fill(DAWTheme.signal)
            .frame(width: 1, height: max(4, rect.height + 8))
            .glow(DAWTheme.signal, radius: 4, intensity: 0.5)
            .position(x: x, y: rect.midY)
            .allowsHitTesting(false)
    }
}

// MARK: - The tool palette (m23-ap, design §7.2)

/// The bottom-mounted palette the reference frames show, with the ACTIVE slot
/// highlighted.
///
/// ⚠️⚠️ **TWO SLOTS, NOT NINE.** The reference app's palette has nine; seven of
/// them are tools this app does not have. See `PitchEditorTool`'s own banner —
/// seven controls that do nothing when pressed is the fake-affordance failure
/// `docs/DESIGN-LANGUAGE.md` Rule 3 names, multiplied by seven.
///
/// The active tool's HELP is drawn beside the palette rather than hung on a
/// tooltip: a tooltip is invisible to `view.capture`, so a gate cannot tell a
/// correct caption from a missing one.
struct PitchEditorToolPalette: View {
    var tool: PitchEditorTool
    /// The live drag's readout, or nil.
    var dragReadout: String?
    /// A refusal to show, or nil.
    var refusal: String?
    /// C-0 — the one sentence about the LINE (design §4.4), or nil: still
    /// matching it to the sound, or a way it cannot be the sound.
    var lineCaption: PitchEditorLineCaption? = nil
    var onSelect: (PitchEditorTool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let refusal {
                PanelRefusalLine(message: refusal)
            }
            // DRAWN, never a tooltip: a tooltip is invisible to `view.capture`,
            // and "the line you are looking at is an estimate" is exactly the
            // sentence a captured gate must be able to see (§4.6 test 7).
            if let lineCaption {
                switch lineCaption.kind {
                case .shortfall:
                    // A real shortfall — the line cannot fully be the sound.
                    // `PanelRefusalLine`'s amber, the warning token the unresolved
                    // notes' outline wears for the same fact.
                    PanelRefusalLine(message: lineCaption.text)
                case .progress:
                    // ⚠️ PROGRESS, NOT A WARNING: nothing refused. The header's
                    // `.analysing` shape — a mini spinner and secondary ink —
                    // because a warning triangle over a transient is how a
                    // warning stops meaning anything.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(lineCaption.text)
                            .font(.system(size: 10))
                            .foregroundStyle(DAWTheme.textSecondary)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(PitchEditorTool.allCases) { candidate in
                    let active = candidate == tool
                    Button { onSelect(candidate) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: candidate.symbolName)
                                .font(.system(size: 11, weight: .medium))
                            Text(candidate.label)
                                .font(.system(size: 10, weight: .medium))
                        }
                        // The ACTIVE slot wears `signal` — an accent earned by
                        // state, which is the one thing Rule 3 allows it for.
                        // An inactive slot is neutral ink on the raised panel:
                        // a tool you are not using is not a state.
                        .foregroundStyle(active ? DAWTheme.signal : DAWTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(active ? DAWTheme.signal.opacity(0.14) : DAWTheme.panelRaised,
                                    in: Capsule())
                        .overlay(Capsule().stroke(
                            active ? DAWTheme.signal.opacity(0.55) : DAWTheme.hairline,
                            lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.label)
                    .help(candidate.help)
                }
                Text(tool.help)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // The live readout sits with the palette, in SF Mono, so a
                // number that changes sixty times a second has ONE home on
                // screen and never re-lays the pane out as it grows a digit.
                if let dragReadout {
                    Text(dragReadout)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DAWTheme.signal)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(DAWTheme.panel)
    }
}

// MARK: - Zoom (m23-ap C4)

/// What the pane's zoom cluster asks the app for. An enum rather than five
/// closures so the pane cannot grow a sixth zoom the app does not implement.
///
/// ⚠️ **THE PANE DOES NOT WRITE `PanelLayoutStore` ITSELF.** `AppModel`'s
/// `zoomPitchEditor*` / `pitchEditorRowZoom*` entry points are the one home for
/// the LADDER, shared with ⌘+/⌘−/⌘0 through `EditorSurfaceRouter`; a button
/// here calling `setPitchEditorPPB` directly would be a second ladder that
/// disagrees with the keyboard about what "one step" means.
enum PitchEditorZoomCommand: Sendable {
    case timeIn, timeOut, pitchIn, pitchOut, reset
}

// MARK: - The pane

/// **Open a vocal recording and SEE the notes you sang** — drawn over the
/// waveform, lined up against a piano ruler — without changing anything
/// (design §5.1). The second bottom editor pane; a sibling of the piano roll,
/// never a mode of it (§3).
struct PitchEditorView: View {
    /// The clip this pane is open on. ⚠️ **Addressed BY ID everywhere below**
    /// (m23-q condition 4 / F11) so take lanes work from day one.
    var clip: Clip
    var tempoMap: TempoMap
    /// The ONE transport source the arrange consumes. No second ticker.
    var positionBeats: Double
    /// The meter governing the CLIP's start — the v1 one-meter-per-clip-view
    /// policy, matching the roll's call site.
    var beatsPerBar: Int
    var layout: PanelLayoutStore
    /// The app's ONE peak cache, keyed by URL and shared by every clip that
    /// windows the same source. ⚠️ A second cache here would re-read every file.
    var waveforms: WaveformStore
    /// Detection, injected. The model never holds the store (the `ClipFixModel`
    /// precedent), which is what lets the suite drive every path.
    var detect: PitchEditorDetectionProvider
    /// C-0 — THE contour the render uses (`ProjectStore.renderPitchContour`),
    /// fetched in parallel with `detect` (design 2026-09-24 §4.3). Required,
    /// not defaulted: a pane built without it would draw an estimate forever
    /// and caption it as a failure nobody had.
    var renderContour: PitchEditorRenderContourProvider
    /// Apply one of the four offered presets (§6.2 Door 2). The caller owns
    /// the store call and the refusal surface.
    var onApplyPreset: (PitchCorrectionPreset) -> Void
    /// Remove this clip's tuning. Offered only when it carries some.
    var onClearTuning: () -> Void
    var onClose: () -> Void
    /// The user just acted inside this pane — `editorEngagement.engage(.pitchEditor)`.
    /// Without this the `.engagedPitchEditor` router case is dead in the app and
    /// ⌘+ never reaches this surface.
    var onEngage: () -> Void
    /// ONE note edit, submitted on gesture END (m23-ap C1/C3, design §8.2).
    ///
    /// ⛔ **THE VIEW NEVER CALLS THIS.** It is handed to `PitchEditorModel` at
    /// mount and the model is the only caller — which is what makes
    /// `PitchEditorModelTests.aDragTickNeverCommits` a gate over the real
    /// cadence instead of a grep over a `DragGesture` closure. If you find
    /// yourself invoking it from a `.onChanged`, that is the P7b defect: the
    /// vocal goes silent for the whole drag.
    var onCommitNoteEdit: (PitchEditorCommit) -> Void
    /// C4 — both axes. See `PitchEditorZoomCommand`.
    var onZoom: (PitchEditorZoomCommand) -> Void
    /// The spy seam (`p2-c`'s `debug.pitchEditor`). Optional so a preview and an
    /// offscreen harness stay one-liners.
    var chrome: PitchEditorChromeLedger?

    @State private var model: PitchEditorModel
    /// ⭐ THE O(frames) SNAPSHOT — the played line on screen, with the dragged
    /// note's stretch cut out while a drag is in flight. See
    /// `PitchEditorDrawContext`.
    @State private var playedSegments: [[CGPoint]] = []
    /// Where the pointer is, for the scissors preview. `nil` off the surface.
    @State private var hoverPoint: CGPoint?

    private static let rulerWidth: CGFloat = 52

    /// What decides whether the seam must be asked AGAIN (§4.3 step 6): the
    /// contour is a function of the file and the detector generation alone,
    /// never of the edits, so only these two re-fetch it.
    private struct RenderContourKey: Equatable {
        let url: URL?
        let analysisVersion: Int
    }

    private var renderContourKey: RenderContourKey {
        RenderContourKey(url: clip.audioFileURL,
                         analysisVersion: clip.pitchEdits?.analysisVersion
                            ?? PitchEditSet.currentAnalysisVersion)
    }

    init(clip: Clip,
         tempoMap: TempoMap,
         positionBeats: Double,
         beatsPerBar: Int,
         layout: PanelLayoutStore,
         waveforms: WaveformStore,
         detect: @escaping PitchEditorDetectionProvider,
         renderContour: @escaping PitchEditorRenderContourProvider,
         onApplyPreset: @escaping (PitchCorrectionPreset) -> Void,
         onClearTuning: @escaping () -> Void,
         onClose: @escaping () -> Void,
         onEngage: @escaping () -> Void,
         onCommitNoteEdit: @escaping (PitchEditorCommit) -> Void = { _ in },
         onZoom: @escaping (PitchEditorZoomCommand) -> Void = { _ in },
         chrome: PitchEditorChromeLedger? = nil) {
        self.clip = clip
        self.tempoMap = tempoMap
        self.positionBeats = positionBeats
        self.beatsPerBar = beatsPerBar
        self.layout = layout
        self.waveforms = waveforms
        self.detect = detect
        self.renderContour = renderContour
        self.onApplyPreset = onApplyPreset
        self.onClearTuning = onClearTuning
        self.onClose = onClose
        self.onEngage = onEngage
        self.onCommitNoteEdit = onCommitNoteEdit
        self.onZoom = onZoom
        self.chrome = chrome
        // The pane is mounted under `.id(clip.id)`, so this runs once per clip —
        // a switch REBUILDS rather than migrating a draft, which is the same
        // rule the roll's mount follows (`ContentView`).
        let model = PitchEditorModel(
            clipID: clip.id,
            geometry: PitchEditorGeometry(clip: clip, tempoMap: tempoMap,
                                          pixelsPerBeat: layout.pitchEditorPPB,
                                          rowHeight: layout.pitchEditorRowHeight))
        // ⭐ THE COMMIT SEAM IS INSTALLED ONCE, HERE, AND NOWHERE ELSE. See
        // `onCommitNoteEdit`.
        model.onCommit = onCommitNoteEdit
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DAWTheme.hairline)
            editorBody
            Divider().overlay(DAWTheme.hairline)
            palette
        }
        .background(DAWTheme.panel)
        .task {
            // The clip's STORED notes first, so a clip that was already tuned
            // draws its tuning from the moment the pane opens rather than
            // waiting on a detection to finish.
            model.syncStoredNoteTable(clip.pitchEdits)
            // §5.9: REAL-TIME SAFETY IS STRUCTURAL HERE, NOT CAREFUL.
            // `detectClipPitch` → `AudioEngine.detectPitch` → `Task.detached` →
            // a `nonisolated` analyzer. Nothing on this path is reachable from
            // the render thread.
            await model.load(using: detect)
            refreshPlayedSegments()
        }
        // C-0 §4.3 step 2 — THE SEAM, IN PARALLEL with the detection above (its
        // own task, so neither waits on the other). `task(id:)` re-asks exactly
        // when the file or the set's detector generation changes (step 6) and
        // never for an edit. The engine hops off the main actor itself
        // (`StretchRenderCache.renderContour`); nothing here blocks.
        .task(id: renderContourKey) {
            await model.loadRenderContour(using: renderContour)
        }
        .onChange(of: layout.pitchEditorPPB) { _, ppb in
            model.geometry.pixelsPerBeat = ppb
        }
        // C4's other axis. One slot, read here, and the ruler sidebar reads the
        // SAME geometry — so the two columns cannot drift a fraction of a row.
        .onChange(of: layout.pitchEditorRowHeight) { _, height in
            model.geometry.rowHeight = height
        }
        // ⭐ THE READ-BACK. Every commit returns through the store, into the
        // clip, and lands here — so what is on screen after a drag is what was
        // SAVED, not what was asked for. A write that silently did nothing
        // shows up as a blob — and its line — springing back, which is the
        // honest picture.
        .onChange(of: clip.pitchEdits) { _, table in
            model.syncStoredNoteTable(table)
        }
        // C-0 — the clip's transpose can change while the pane is open (the
        // pane is rebuilt only on a clip SWITCH), and the render plays it.
        .onChange(of: clip.pitchShiftSemitones) { _, semitones in
            model.setClipPitchShiftSemitones(semitones)
        }
        // ⚠️ `DragGesture.onEnded` DOES NOT FIRE when the window resigns key or
        // the pane is torn down. A draft left behind would become a phantom
        // baseline for the next gesture on the next clip.
        .onDisappear { model.cancelDrag() }
        // The events — and the only ones — that can move the line on screen:
        // a load completing (above), the line being rebuilt (an edit read back,
        // the seam answering, a transpose), the geometry changing (the zoom,
        // and the auto-fit `apply` performs), and a drag starting or ending
        // (the dragged stretch leaves for the overlay and comes back). NOT a
        // pointer tick: the draft moves in the overlay, never here.
        .onChange(of: model.playedLineRevision) { _, _ in
            refreshPlayedSegments()
            recordPlayedLine()
        }
        .onChange(of: model.geometry) { _, _ in refreshPlayedSegments() }
        .onChange(of: model.drag?.segmentID) { _, _ in refreshPlayedSegments() }
        .onAppear { recordPlayedLine() }
        .onChange(of: model.state) { _, _ in recordPlayedLine() }
    }

    private func refreshPlayedSegments() {
        playedSegments = model.playedLineSegments(excluding: model.draftSpan)
    }

    /// Reports the line to the spy ledger (`debug.pitchEditor`'s `playedLine`)
    /// — the SAME `lineCaption` the palette draws, the same basis and
    /// unresolved set the surface draws from.
    private func recordPlayedLine() {
        let caption = model.lineCaption
        chrome?.recordPlayedLine(
            basisKey: model.playedLine.basis.key,
            reason: model.playedLine.basis.reason,
            captionText: caption?.text ?? "",
            captionKind: caption?.kind.rawValue ?? "",
            // The SAME list the surface outlines (empty while waiting).
            unresolvedNoteIDs: model.unresolvedNoteIDList,
            clipPitchShiftSemitones: model.geometry.clipPitchShiftSemitones,
            perNote: model.playedLineNoteSummaries)
    }

    // MARK: The palette (m23-ap Increment C)

    /// Bottom-mounted, the reference frames' own placement (§7.2). Reports what
    /// it DREW to the ledger from the same `let`s it drew from.
    @ViewBuilder
    private var palette: some View {
        let tool = model.tool
        let readout = model.drag?.readout
        let refusal = model.refusal
        // C-0 — the SAME value `recordPlayedLine` reports to the ledger.
        let lineCaption = model.lineCaption
        PitchEditorToolPalette(
            tool: tool,
            dragReadout: readout,
            refusal: refusal,
            lineCaption: lineCaption,
            onSelect: { chosen in
                onEngage()
                model.tool = chosen
                model.clearRefusal()
            })
            .onAppear { recordInteraction() }
            .onChange(of: model.tool) { _, _ in recordInteraction() }
            .onChange(of: model.drag) { _, _ in recordInteraction() }
            .onChange(of: model.refusal) { _, _ in recordInteraction() }
            .onChange(of: model.commitCount) { _, _ in recordInteraction() }
    }

    /// ⚠️ **`dragReadout` IS "" WHEN THERE IS NO DRAG AND NEVER "+0 cents".**
    /// Those are different facts: the second would be a claim that a note moved
    /// by an amount `PitchEditorReadout`'s ±12.90-cent floor says nobody can
    /// measure.
    private func recordInteraction() {
        chrome?.recordInteraction(
            toolKey: model.tool.rawValue,
            paletteLabels: PitchEditorTool.allCases.map(\.label),
            toolHelp: model.tool.help,
            dragReadout: model.drag?.readout ?? "",
            refusalText: model.refusal ?? "",
            commitCount: model.commitCount)
    }

    /// Where the scissors would cut, or `nil` when the pointer is not over a
    /// note. ⚠️ **Resolved through the MODEL's own hit test**, not a second one
    /// — a preview that used different arithmetic from the cut would draw a
    /// line where the knife does not land, which is worse than no preview.
    private var cutPreview: (x: CGFloat, rect: CGRect)? {
        guard let point = hoverPoint, let blob = model.blob(at: point) else { return nil }
        return (point.x, model.rect(for: blob))
    }

    // MARK: The gestures (m23-ap C1 + C3)

    /// ⛔⛔ **NOTHING IN HERE COMMITS.** The model owns the cadence (§8.2): a
    /// tick updates a draft, and only `endPitchDrag`/`splitNote` can emit. This
    /// function existing without a single store call is the point of it.
    private func dragChanged(_ value: DragGesture.Value) {
        guard state.drawsNotes, model.tool == .pointer else { return }
        if model.drag == nil {
            guard let blob = model.blob(at: value.startLocation) else { return }
            onEngage()
            model.beginPitchDrag(on: blob)
        }
        // ⌥ = free movement, no snap (§7.3 C1). Read from `NSEvent` at the tick
        // rather than from the gesture value, which carries no modifiers — the
        // `ControllerLaneStrip` idiom, already shipped one surface over.
        model.updatePitchDrag(translationHeight: value.translation.height,
                              free: NSEvent.modifierFlags.contains(.option))
    }

    /// The ONE place a gesture can produce a store write.
    private func dragEnded(_ value: DragGesture.Value) {
        guard state.drawsNotes else { return }
        onEngage()
        switch model.tool {
        case .pointer:
            // The model emits at most one commit, and none at all when the note
            // finished where it started.
            _ = model.endPitchDrag()
        case .scissors:
            // The cut lands where the click BEGAN, not where it ended: a cut is
            // a click, and a hand that slipped two points during it did not
            // mean to move the knife.
            _ = model.splitNote(at: value.startLocation)
        }
    }

    // MARK: Header

    private var state: PitchEditorState { model.state }

    @ViewBuilder
    private var header: some View {
        // ⭐ RESOLVED ONCE, DRAWN AND REPORTED FROM THE SAME `let`. The ledger
        // gets the exact `String` the `Text` below is handed, so the echo can
        // never agree with a re-derivation instead of with the screen.
        let status = state.message
        let caption = confidenceLegend
        let presets = PitchCorrectionPreset.offeredInUI
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(clip.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                if clip.hasPitchEdits {
                    // ⭐ SAY THAT THE CLIP IS TUNED, IN WORDS. Since C-0 the line
                    // IS the corrected one (it is what the render will play),
                    // so the picture does change when a preset lands — but a
                    // gentle preset moves most notes by less than a row, and a
                    // novice who pressed it must not have to read a few pixels
                    // of line to learn that the tuner did anything. The badge
                    // is the sentence; the line is the evidence.
                    Text("TUNING APPLIED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(DAWTheme.signal)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DAWTheme.signal.opacity(0.14),
                                    in: Capsule())
                }
                Spacer(minLength: 0)
                zoomCluster
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DAWTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close the note editor")
            }

            statusLine(status)

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            presetRow(presets)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // ⚠️ **TWO TRIGGERS, AND THE SECOND ONE IS THE EASY ONE TO MISS.**
        // `status` alone is not enough: applying a preset flips
        // `clip.hasPitchEdits` — which puts the TUNING APPLIED badge on screen —
        // while the status line goes on saying "Found 5 notes.". A ledger keyed
        // only on the status would then report `tuningApplied: false` about a
        // badge a person can see, which is precisely the "the echo agrees with
        // itself and with nothing on screen" failure this seam exists to
        // prevent — and it is the one transition a `debug.pitchEditor` gate will
        // press first.
        .onAppear { recordChrome(status: status, caption: caption, presets: presets) }
        .onChange(of: status) { _, _ in
            recordChrome(status: status, caption: caption, presets: presets)
        }
        .onChange(of: clip.hasPitchEdits) { _, _ in
            recordChrome(status: status, caption: caption, presets: presets)
        }
    }

    /// C4 — zoom, BOTH AXES, as on-screen buttons.
    ///
    /// ⚠️ **BUTTONS, NOT ONLY A CHORD.** ⌘+/⌘−/⌘0 already reach this pane
    /// through `EditorSurfaceRouter`, and they stay. But the target reader here
    /// is a NOVICE, and a zoom that exists only as a key combination is a zoom
    /// most people will never find. The words are spelled out — TIME and PITCH,
    /// not two magnifying glasses — because "which axis does this one change"
    /// is exactly the question two identical glyphs cannot answer.
    @ViewBuilder
    private var zoomCluster: some View {
        HStack(spacing: 6) {
            zoomGroup(title: "TIME",
                      outHelp: "Show more of the clip at once.",
                      inHelp: "Spread the notes out along time.",
                      out: { onZoom(.timeOut) }, into: { onZoom(.timeIn) })
            zoomGroup(title: "PITCH",
                      outHelp: "Shorter rows — see more notes up and down.",
                      inHelp: "Taller rows — see small pitch differences.",
                      out: { onZoom(.pitchOut) }, into: { onZoom(.pitchIn) })
            Button("Reset") { onZoom(.reset) }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textSecondary)
                .help("Back to the standard zoom on both axes.")
        }
    }

    @ViewBuilder
    private func zoomGroup(title: String, outHelp: String, inHelp: String,
                           out: @escaping () -> Void, into: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
            zoomButton("minus", help: outHelp, action: out)
            zoomButton("plus", help: inHelp, action: into)
        }
    }

    @ViewBuilder
    private func zoomButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DAWTheme.textSecondary)
                .frame(width: 18, height: 16)
                .background(DAWTheme.panelRaised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// One reporting call site, fed the SAME `let`s the header drew from.
    private func recordChrome(status: String, caption: String,
                              presets: [PitchCorrectionPreset]) {
        chrome?.record(statusKey: state.statusKey, statusText: status, caption: caption,
                       presetLabels: presets.map(\.displayName),
                       presetSummaries: presets.map(\.summary),
                       noteCount: model.blobs.count,
                       tuningApplied: clip.hasPitchEdits)
    }

    /// §5.5.4's honest label for the blob-opacity encoding. Drawn only when
    /// there are blobs to explain — a legend for an empty surface is noise.
    private var confidenceLegend: String {
        guard state.drawsNotes else { return "" }
        return "Fainter notes mean we are less sure you were singing there."
    }

    /// ⛔ **THE STATUS LINE IS DRAWN PROSE IN EVERY STATE — never a spinner,
    /// never silence, never a colour** (§5.7). A read-only view whose empty
    /// state is indistinguishable from its broken state is the exact failure
    /// this project keeps paying for.
    ///
    /// ⚠️ **AMBER IS FOR THE THREE THAT ACTUALLY REFUSED.** `PanelRefusalLine`
    /// wears `ArrangeRefusalBubble`'s semantics — *the thing did not happen, and
    /// nothing was destroyed* — so putting "Found 12 notes." behind its warning
    /// triangle would be a warning about nothing, which is how a warning stops
    /// meaning anything. This is a deliberate narrowing of §5.7's table, which
    /// says "use `PanelRefusalLine`" for all four rows.
    @ViewBuilder
    private func statusLine(_ status: String) -> some View {
        switch state {
        case .noNotesFound, .engineUnavailable, .refused:
            PanelRefusalLine(message: status)
        case .analysing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textSecondary)
            }
        case .idle, .ready:
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// **DOOR 2 — the pitch editor's own header** (§6.2). FOUR chips, each with
    /// its `summary` rendered as DRAWN PROSE underneath rather than as a
    /// tooltip: a tooltip is invisible to `view.capture`, so a captured gate
    /// cannot tell a correct caption from a missing one. That is the
    /// `EQCurveEditor.help` lesson, verbatim.
    ///
    /// ⭐ **`offeredInUI`, NEVER `allCases` — AND SINCE 2026-09-24 THAT LIST IS
    /// ALL FOUR.** `hardTune` was withheld while the render built every curve
    /// with no contour, so its flattening resolved to nothing and it shipped as
    /// *a stronger Tight wearing the label "the robot effect"*. The render now
    /// shapes against the detected whole-file contour (contour-to-render), the
    /// label is true, and the chip is offered —
    /// `PitchCorrectionPresetTests.uiDoorOffersEveryPresetTheRenderHonours`
    /// pins the list and its reason. The rule it served still stands: a
    /// control whose label promises one result and whose mechanism delivers
    /// another is worse than a missing one. What remains true, and is SAID
    /// rather than hidden: when the pitch analysis cannot run, Hard Tune plays
    /// its fallback (notes on pitch, wobble kept) — the engine posts a notice,
    /// and since C-0 this pane's own line caption names the notes it could not
    /// flatten.
    ///
    /// ⚠️ **FOUR BUTTONS, NEVER A SLIDER.** `PitchCorrectionPreset.ladder` holds
    /// the three that share one axis; Hard Tune is a different algorithm, and a
    /// UI that presented the four as one dial would be lying about what the
    /// last stop does.
    @ViewBuilder
    private func presetRow(_ presets: [PitchCorrectionPreset]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("TUNE THIS VOCAL")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(DAWTheme.textDim)
                // ⚠️ BESIDE THE LABEL, NOT BEHIND A `Spacer`. MEASURED by
                // looking: pushed to the trailing edge it sat the better part of
                // a thousand points from the chips it undoes, on a pane that is
                // as wide as the window.
                if clip.hasPitchEdits {
                    Button("Remove tuning") {
                        onEngage()
                        onClearTuning()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(presets) { preset in
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            onEngage()
                            onApplyPreset(preset)
                        } label: {
                            Text(preset.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DAWTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(DAWTheme.panelRaised, in: Capsule())
                                .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        // The prose, DRAWN. See this function's banner.
                        Text(preset.summary)
                            .font(.system(size: 9))
                            .foregroundStyle(DAWTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: 190, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Body

    private var drawContext: PitchEditorDrawContext {
        let peaks = clip.audioFileURL.flatMap { waveforms.peaks(for: $0) }
        return PitchEditorDrawContext(
            geometry: model.geometry,
            blobs: model.blobs,
            // C-0 — THE PLAYED LINE: the snapshot, not a per-body rebuild (see
            // `playedSegments`), with the dragged note's stretch cut out while
            // the overlay owns it.
            playedLine: playedSegments,
            lineIsEstimate: model.playedLine.basis != .render,
            unresolvedNoteIDs: model.unresolvedNoteIDs,
            hiddenBlobID: model.drag?.segmentID,
            gaps: model.gaps,
            peaks: peaks,
            // ONE scalar, resolved from the headless rules before the closure —
            // per-view, never per column and never per frame (m25-e).
            waveformScale: WaveformScale.drawScale(
                peakMax: peaks?.peakMax ?? 1,
                normalize: layout.waveformNormalize,
                verticalZoom: layout.waveformVerticalZoom),
            drawsNotes: state.drawsNotes)
    }

    @ViewBuilder
    private var editorBody: some View {
        let ctx = drawContext
        let cue = PianoRollPlayhead.offClipCue(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
        // VERTICAL scroll wraps BOTH columns, so the ruler and the surface can
        // never scroll apart; the HORIZONTAL scroll is nested inside and moves
        // the surface alone, which is what keeps the ruler pinned.
        ScrollView(.vertical) {
            HStack(spacing: 0) {
                PitchRulerSidebar(geometry: ctx.geometry, width: Self.rulerWidth)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        PitchEditorSurface(ctx: ctx)
                            .equatable()
                            .frame(width: max(1, ctx.geometry.contentWidth),
                                   height: ctx.geometry.contentHeight)
                        // ⭐ DRAWN IN EVERY STATE, INCLUDING THE THREE THAT
                        // FOUND NOTHING. Where the transport is, is a fact about
                        // the project and not about this detection — and the
                        // grid and the ruler are on screen in every state for
                        // the same reason. Hiding it when detection failed would
                        // make a failed analysis look like a stopped transport.
                        PitchEditorPlayhead(geometry: ctx.geometry,
                                            positionBeats: positionBeats)
                            .frame(height: ctx.geometry.contentHeight)
                        if state == .analysing {
                            PitchAnalysisShimmer(tint: DAWTheme.textDim)
                                .frame(width: max(1, ctx.geometry.contentWidth),
                                       height: ctx.geometry.contentHeight)
                        }
                        // ⭐ THE DRAFT, IN ITS OWN LAYER. The surface below is
                        // untouched during a drag — see
                        // `PitchEditorDragOverlay`'s banner for why that is
                        // structural and not tidiness.
                        if let draft = model.drag {
                            PitchEditorDragOverlay(geometry: ctx.geometry, draft: draft,
                                                   draftLine: model.draftLineSegments,
                                                   lineIsEstimate: ctx.lineIsEstimate)
                                .equatable()
                                .frame(width: max(1, ctx.geometry.contentWidth),
                                       height: ctx.geometry.contentHeight)
                        }
                        if model.tool == .scissors, let cut = cutPreview {
                            PitchEditorCutPreview(x: cut.x, rect: cut.rect)
                                .frame(width: max(1, ctx.geometry.contentWidth),
                                       height: ctx.geometry.contentHeight)
                        }
                    }
                    .frame(width: max(1, ctx.geometry.contentWidth),
                           height: ctx.geometry.contentHeight)
                    .contentShape(Rectangle())
                    // C1 + C3. `minimumDistance: 0` so a scissors CLICK is a
                    // gesture too — otherwise a cut would need a wiggle.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { dragChanged($0) }
                            .onEnded { dragEnded($0) })
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoverPoint = point
                        case .ended: hoverPoint = nil
                        }
                    }
                }
                // m23-c1: the transport outside the clip gets a directional
                // bleed at the VIEWPORT edge — so it hangs off the scroller, not
                // off the content, or it would sit off-screen exactly when it is
                // needed.
                .overlay(alignment: .topLeading) {
                    if let cue { OffClipEdgeCue(cue: cue) }
                }
            }
            .frame(height: ctx.geometry.contentHeight, alignment: .top)
        }
        // m23-al: the ONE engagement funnel for this pane. A click here is what
        // makes ⌘+/⌘−/⌘0 reach this surface instead of the arrange; the latch's
        // change-guard is what makes calling it freely safe.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onEngage() })
        .background(DAWTheme.background)
    }
}
