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
//  1. **A HOLE IS THE SIGNAL. NEVER BRIDGE ONE** (§5.5.1). The contour is drawn
//     as N separate polylines — one `Path` per detected note — never one `Path`
//     that `addLine`s across an unvoiced stretch. A single path would invent
//     pitch where none was measured, and it is the obvious implementation.
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

    init() {}

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
        statusKey = ""
        statusText = ""
        captionText = ""
        presetLabels = []
        presetSummaries = []
        noteCount = 0
        tuningApplied = false
        ticks = 0
    }
}

// MARK: - The draw context

/// A value snapshot of everything the surface renderer needs, taken on the main
/// actor before the `@Sendable` closure (CANVAS CONTRACT, m16-a — a crash
/// precedent exists, `docs/research/design-m16a-canvas-crash.md`).
///
/// ⭐⭐ **`contour` IS SNAPSHOTTED, NOT COMPUTED HERE, AND THAT IS THE POINT.**
/// `PitchEditorModel.contourSegments` re-maps EVERY detected frame through the
/// geometry on each read — O(frames), ~11,250 of them on a three-minute vocal.
/// Calling it inside the renderer (or rebuilding this context on every transport
/// tick) would pay that per redraw. It is cached by the view and refreshed on
/// exactly the two events that can change it: a load completing, and the
/// geometry moving.
///
/// `positionBeats` is deliberately NOT a field — the playhead is its own view —
/// so a transport tick leaves every field here EQUAL, which is the precondition
/// for `.equatable()` to skip the surface (`PianoRollGrid`'s extraction, same
/// reason). ⚠️ **THAT THE SKIP ACTUALLY HAPPENS IS UNVERIFIED, AND IS NAMED
/// RATHER THAN ASSUMED** — `KeyboardSidebar` carries the same admission about
/// its own cadence. Two things are known: the fields are equal by construction,
/// and `Array`'s `==` short-circuits on an identical buffer, so comparing the
/// contour is not itself O(frames) for the unchanged case. What nobody has
/// measured here is how often SwiftUI re-evaluates this view under a running
/// transport. **A signpost on the draw closure during playback is what would
/// settle it**; until someone runs one, do not quote a cadence for this pane.
struct PitchEditorDrawContext: Equatable {
    var geometry: PitchEditorGeometry
    var blobs: [NoteBlob]
    /// One polyline per detected note. **Never one path across a hole.**
    var contour: [[CGPoint]]
    var gaps: [PitchEditorGap]
    var peaks: WaveformPeaks?
    /// The m25-e auto-fit scalar, resolved per-view from the headless rules —
    /// never per column and never per frame.
    var waveformScale: CGFloat
    /// Whether there are notes to draw at all (`PitchEditorState.drawsNotes`).
    var drawsNotes: Bool
}

// MARK: - The surface

/// The pitch editor's drawing layers (design §5.6, bottom to top): waveform ·
/// pitch grid · unvoiced stretches · note blobs · contour · note names. **No
/// playhead** — see `PitchEditorDrawContext`.
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
            Self.drawContour(&context, ctx: ctx)
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
        for blob in ctx.blobs {
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
            context.fill(shape, with: .color(DAWTheme.textDim.opacity(0.10 + 0.18 * confidence)))
            context.stroke(shape,
                           with: .color(DAWTheme.textDim.opacity(0.22 + 0.33 * confidence)),
                           lineWidth: 1)
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
        for blob in ctx.blobs {
            let rect = ctx.geometry.rect(for: blob)
            guard rect.width >= 20 else { continue }
            context.draw(
                Text(blob.noteName)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(DAWTheme.textSecondary),
                at: CGPoint(x: rect.minX + 1, y: rect.minY - 1), anchor: .bottomLeading)
        }
    }

    // MARK: Layer 5 — the contour

    /// The per-frame detected pitch line, drawn THROUGH the blobs, bloom-under-
    /// core (the house glow recipe: wide faint stroke, then a bright narrow one —
    /// `AutomationLaneEditor.drawPolyline`).
    ///
    /// ⛔ **ONE `Path` PER RUN.** `ctx.contour` arrives already split at every
    /// hole by `PitchEditorModel`; joining them here would be exactly the
    /// bridged-hole lie rule 1 forbids, and the loop below is the whole of the
    /// mitigation.
    ///
    /// ⛔ **`textPrimary`, NOT AN ACCENT.** Cyan is playback/position and
    /// nothing else; violet is AI-touched content and this is a measurement of
    /// the user's own voice. `lineJoin: .miter` rather than `.round`: the
    /// 25.79-cent staircase IS the instrument's resolution (rule 2) and a
    /// rounded join would sand it off.
    private nonisolated static func drawContour(_ context: inout GraphicsContext,
                                                ctx: PitchEditorDrawContext) {
        for points in ctx.contour {
            guard points.count > 1 else {
                // A one-frame run still gets drawn — as a dot. Dropping it would
                // silently unreport a measurement that exists.
                if let only = points.first {
                    context.fill(
                        Path(ellipseIn: CGRect(x: only.x - 1, y: only.y - 1, width: 2, height: 2)),
                        with: .color(DAWTheme.textPrimary.opacity(0.9)))
                }
                continue
            }
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }
            context.stroke(line, with: .color(DAWTheme.textPrimary.opacity(0.16)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .butt, lineJoin: .miter))
            context.stroke(line, with: .color(DAWTheme.textPrimary.opacity(0.92)),
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
    /// Apply one of the three offered presets (§6.2 Door 2). The caller owns the
    /// store call and the refusal surface.
    var onApplyPreset: (PitchCorrectionPreset) -> Void
    /// Remove this clip's tuning. Offered only when it carries some.
    var onClearTuning: () -> Void
    var onClose: () -> Void
    /// The user just acted inside this pane — `editorEngagement.engage(.pitchEditor)`.
    /// Without this the `.engagedPitchEditor` router case is dead in the app and
    /// ⌘+ never reaches this surface.
    var onEngage: () -> Void
    /// The spy seam (`p2-c`'s `debug.pitchEditor`). Optional so a preview and an
    /// offscreen harness stay one-liners.
    var chrome: PitchEditorChromeLedger?

    @State private var model: PitchEditorModel
    /// ⭐ THE O(frames) SNAPSHOT. See `PitchEditorDrawContext`.
    @State private var contour: [[CGPoint]] = []

    private static let rulerWidth: CGFloat = 52

    init(clip: Clip,
         tempoMap: TempoMap,
         positionBeats: Double,
         beatsPerBar: Int,
         layout: PanelLayoutStore,
         waveforms: WaveformStore,
         detect: @escaping PitchEditorDetectionProvider,
         onApplyPreset: @escaping (PitchCorrectionPreset) -> Void,
         onClearTuning: @escaping () -> Void,
         onClose: @escaping () -> Void,
         onEngage: @escaping () -> Void,
         chrome: PitchEditorChromeLedger? = nil) {
        self.clip = clip
        self.tempoMap = tempoMap
        self.positionBeats = positionBeats
        self.beatsPerBar = beatsPerBar
        self.layout = layout
        self.waveforms = waveforms
        self.detect = detect
        self.onApplyPreset = onApplyPreset
        self.onClearTuning = onClearTuning
        self.onClose = onClose
        self.onEngage = onEngage
        self.chrome = chrome
        // The pane is mounted under `.id(clip.id)`, so this runs once per clip —
        // a switch REBUILDS rather than migrating a draft, which is the same
        // rule the roll's mount follows (`ContentView`).
        _model = State(initialValue: PitchEditorModel(
            clipID: clip.id,
            geometry: PitchEditorGeometry(clip: clip, tempoMap: tempoMap,
                                          pixelsPerBeat: layout.pitchEditorPPB)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DAWTheme.hairline)
            editorBody
        }
        .background(DAWTheme.panel)
        .task {
            // §5.9: REAL-TIME SAFETY IS STRUCTURAL HERE, NOT CAREFUL.
            // `detectClipPitch` → `AudioEngine.detectPitch` → `Task.detached` →
            // a `nonisolated` analyzer. Nothing on this path is reachable from
            // the render thread.
            await model.load(using: detect)
            refreshContour()
        }
        .onChange(of: layout.pitchEditorPPB) { _, ppb in
            model.geometry.pixelsPerBeat = ppb
        }
        // The two events — and the only two — that can move the contour on
        // screen: a load completing (above) and the geometry changing (here,
        // which covers the zoom, and the auto-fit `apply` performs).
        .onChange(of: model.geometry) { _, _ in refreshContour() }
    }

    private func refreshContour() { contour = model.contourSegments }

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
                    // ⭐ THE SOUND CHANGED AND THE PICTURE DID NOT. This pane
                    // draws the DETECTED contour, which is what the singer did —
                    // not the corrected one. Without this badge a novice who
                    // pressed a preset sees an unchanged screen and concludes
                    // the tuner did nothing.
                    Text("TUNING APPLIED")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(DAWTheme.signal)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DAWTheme.signal.opacity(0.14),
                                    in: Capsule())
                }
                Spacer(minLength: 0)
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

    /// **DOOR 2 — the pitch editor's own header** (§6.2). Three chips, each with
    /// its `summary` rendered as DRAWN PROSE underneath rather than as a
    /// tooltip: a tooltip is invisible to `view.capture`, so a captured gate
    /// cannot tell a correct caption from a missing one. That is the
    /// `EQCurveEditor.help` lesson, verbatim.
    ///
    /// ⛔⛔ **THREE, NOT FOUR — `offeredInUI`, NEVER `allCases`.** `hardTune` is
    /// withheld from every on-screen door because **the app cannot currently
    /// produce it**: the render path calls `StretchCurvePlan.make` with
    /// `contour: []`, so the only preset with `preserveVibrato: false` has
    /// nothing to resolve its shaping against and degrades to a constant
    /// per-note offset — measured on a real vocal it asks for a median 62.1
    /// cents against `tight`'s 18.8, i.e. it would ship as *a stronger Tight
    /// wearing the label "the robot effect"*. A control whose label promises one
    /// result and whose mechanism delivers another is worse than a missing
    /// control, because nothing in the product can tell the user they were lied
    /// to. `PitchCorrectionPresetTests.uiDoorWithholdsHardTune` pins both the
    /// list and the reason. ⚠️ The WIRE still accepts `hardTune` and returns the
    /// degradation in its warnings — only the pixels withhold it, because only
    /// the pixels have no room to explain.
    ///
    /// ⚠️ **FOUR BUTTONS, NEVER A SLIDER** — and now three, for the reason above.
    /// `PitchCorrectionPreset.ladder` exists but a UI that presented the set as
    /// one dial would be lying about what the last stop does.
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
            contour: contour,
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
                    }
                    .frame(width: max(1, ctx.geometry.contentWidth),
                           height: ctx.geometry.contentHeight)
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
