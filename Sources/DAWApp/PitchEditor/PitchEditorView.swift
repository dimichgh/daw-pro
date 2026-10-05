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
//  • ~~FOLLOW-PLAYHEAD~~ — WIRED by m23-ap I5 (interaction batch §8): the
//    app-held `AppModel.pitchEditorFollow` (the `pianoRollFollow` twin), the ONE
//    `layout.followPlayhead` flag, I0's writer, `reportOffset` in the horizontal
//    reader, and a stand-down while a pinch owns the scroll. See `followTick`.
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
    /// Whether the header DREW the "TUNING APPLIED" badge — a pitch was moved
    /// (`PitchEditorClipBadge.tuningApplied`, `Clip.hasTuningEdits`).
    private(set) var tuningApplied = false
    /// Whether the header DREW the "NOTES EDITED" badge — the clip carries
    /// edits and every one is a clear or a level (I7b-2). Never true together
    /// with `tuningApplied`: one badge slot, at most one face.
    private(set) var notesEdited = false
    /// The badge's words as drawn, verbatim, or "" when no badge is drawn.
    private(set) var clipBadgeText = ""
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
    /// W7-NTU §1(f) item 4 — the far-move hint on screen, or "".
    private(set) var farMoveHint = ""
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

    // MARK: The cut line (m23-ap interaction batch I3)

    /// The cut line the surface DREW, verbatim — the very `PitchEditorCutLine`
    /// handed to `PitchEditorCutPreview` — or `nil` when none is drawn (Split
    /// not engaged, no notes on the surface, or the pointer off it).
    private(set) var cutLine: PitchEditorCutLine?
    /// One per cut-line report. Counted, never reasoned about.
    private(set) var cutLineTicks = 0

    // MARK: The bigger editor (m23-ap interaction batch I6a)

    /// Whether the header's MAXIMIZE toggle was DRAWN in its maximized face.
    /// `debug.pitchEditor` echoes it beside the store's own `editorMaximized`:
    /// two instruments, and a disagreement between them is the signal.
    private(set) var maximizeToggleMaximized = false
    /// The SF Symbol the toggle drew (`EditorMaximize.toggleSymbol`), "" before
    /// it drew.
    private(set) var maximizeToggleSymbol = ""
    /// How many ESCAPE key-downs reached THIS pane's own `.onKeyPress(.escape)`
    /// mount — bumped as the mount's FIRST statement, before any decision (the
    /// `KeyPressProbe` discriminator). It separates the two silences m34-k is
    /// about: this counter flat means SwiftUI never delivered the key to the
    /// pane; this counter moving while `AppModel.editorEscapeMountHits` also
    /// moves means the pane's mount reached the app's decision.
    private(set) var escapeMountHits = 0

    // MARK: Hearing the note (m23-ap I1 UI hooks)

    /// Whether the header's HEAR switch was DRAWN on. Echoed beside the
    /// store's own `auditionEnabled`: two instruments that must agree.
    private(set) var auditionToggleOn = false
    /// The SF Symbol the switch drew, "" before it drew.
    private(set) var auditionToggleSymbol = ""
    /// The help the switch carries, verbatim — a tooltip is invisible to
    /// `view.capture`, so this is the only way a gate can read that it says
    /// "one switch for both note editors".
    private(set) var auditionToggleHelp = ""
    /// The audition line the state row DREW, verbatim, or "".
    private(set) var auditionLineText = ""
    /// `PitchEditorLineCaption.Kind.rawValue` of that line, or "".
    private(set) var auditionLineKind = ""
    /// One per audition-line report. Counted, never reasoned about.
    private(set) var auditionLineTicks = 0
    /// p2-ren Stage B″(c) — the "Preview" caption the state row DREW, verbatim
    /// (`PitchEditorRenderCaption`), or "" while the clip plays its exact render.
    private(set) var renderCaptionText = ""
    /// How many times the pane's `body` has been EVALUATED — counted, never
    /// reasoned about, so a gate can read a re-render RATE (orchestrator ask
    /// with B″(c): the poll must not add re-renders while a render is pending).
    private(set) var bodyEvaluations = 0

    // MARK: Pinch to zoom (m23-ap interaction batch I2)

    /// The zoom cluster's DRAWN pinch help, verbatim (`PitchEditorZoomHint`),
    /// or "" before the cluster drew. Design §5 asks for it drawn, never a
    /// tooltip — and a tooltip is invisible to `view.capture`, so this is how a
    /// gate reads that it is there.
    private(set) var zoomHintText = ""

    // MARK: The Wobble tool (m23-ap C5a-4b)

    /// The DOT the surface drew, verbatim (the very value handed to
    /// `PitchEditorWobbleOverlay`), or `nil` when none is drawn.
    private(set) var wobbleDot: PitchEditorWobbleDot?
    /// The Wobble-tool press in flight as the model held it when the palette
    /// last drew, or `nil`.
    private(set) var wobbleDraft: PitchEditorWobbleDraft?
    /// The Wobble tool's readout the palette DREW, verbatim, or "" — and
    /// whether it was drawn in the red warning ink (design §9.2).
    private(set) var wobbleReadoutText = ""
    private(set) var wobbleReadoutIsWarning = false
    /// One per wobble report. Counted, never reasoned about.
    private(set) var wobbleTicks = 0
    /// The estimator's two readings of every drawn note (design §12.5's
    /// `perNote`), asked LAZILY by the echo — never computed per draw. The pane
    /// installs it on appear and removes it on disappear, token-guarded like
    /// the surface report (a clip switch's outgoing pane must not remove the
    /// incoming one's).
    private(set) var wobbleReadingsProvider: (@MainActor () -> [PitchEditorWobbleNoteReadings])?
    private var wobbleReadingsOwner: UUID?

    // MARK: The freehand brush (m23-ap C5b-4b)

    /// The brush BAND the surface drew, verbatim (the very value handed to
    /// `PitchEditorBrushOverlay`), or `nil` when none is drawn.
    private(set) var brushBand: PitchEditorBrushBand?
    /// The stroke in flight as the model held it when the palette last drew
    /// (its `shapes` are what the release would store), or `nil`.
    private(set) var brushDraft: PitchEditorBrushDraft?
    /// ⌘ as the pane held it (`commandHeld`: the flags monitor, or a staged
    /// `keys` step) when it last reported.
    private(set) var commandHeld = false
    /// One per brush report. Counted, never reasoned about.
    private(set) var brushTicks = 0

    // MARK: The header group "Sound like the singer" (W7-NTU U1)

    /// The group the header DREW, verbatim (the very value handed to
    /// `PitchEditorSingerGroupView`), or `nil` when none is drawn.
    private(set) var singerGroup: PitchEditorSingerGroup?
    /// Where the header's layout PUT the group and the preset chips, in
    /// window points, as measured after layout (`onGeometryChange`) — never
    /// the rule re-run: whether the group sits beside the chips or below them
    /// is read off these two frames. `nil` = not drawn.
    private(set) var singerFrame: CGRect?
    private(set) var presetsFrame: CGRect?
    /// One per group report. Counted, never reasoned about.
    private(set) var singerTicks = 0

    // MARK: The Voice tool (W7-NTU U3)

    /// The Voice marks the surface DREW, verbatim (the very values handed to
    /// `PitchEditorVoiceOverlay`), empty when none is drawn (another tool, or
    /// every note as sung).
    private(set) var voiceMarks: [PitchEditorVoiceMark] = []
    /// The Voice-tool press in flight as the model held it when the palette
    /// last drew, or `nil`.
    private(set) var voiceDraft: PitchEditorVoiceDraft?
    /// The Voice tool's readout the palette DREW, verbatim, or "".
    private(set) var voiceReadoutText = ""
    /// One per Voice report. Counted, never reasoned about.
    private(set) var voiceTicks = 0

    init() {}

    func recordVoice(marks: [PitchEditorVoiceMark], draft: PitchEditorVoiceDraft?, readout: String?) {
        voiceTicks += 1
        voiceMarks = marks
        voiceDraft = draft
        voiceReadoutText = readout ?? ""
    }

    func recordSingerGroup(_ group: PitchEditorSingerGroup?) {
        singerTicks += 1
        singerGroup = group
    }

    func recordSingerFrame(_ frame: CGRect?) {
        singerFrame = frame
    }

    func recordPresetsFrame(_ frame: CGRect?) {
        presetsFrame = frame
    }

    func recordBrush(band: PitchEditorBrushBand?, draft: PitchEditorBrushDraft?, commandHeld: Bool) {
        brushTicks += 1
        brushBand = band
        brushDraft = draft
        self.commandHeld = commandHeld
    }

    func installWobbleReadings(token: UUID,
                               _ provider: @escaping @MainActor () -> [PitchEditorWobbleNoteReadings]) {
        wobbleReadingsOwner = token
        wobbleReadingsProvider = provider
    }

    func removeWobbleReadings(token: UUID) {
        guard wobbleReadingsOwner == token else { return }
        wobbleReadingsOwner = nil
        wobbleReadingsProvider = nil
    }

    func recordWobble(dot: PitchEditorWobbleDot?, draft: PitchEditorWobbleDraft?,
                      readout: PitchWobbleReadout?) {
        wobbleTicks += 1
        wobbleDot = dot
        wobbleDraft = draft
        wobbleReadoutText = readout?.text ?? ""
        wobbleReadoutIsWarning = readout?.isWarning ?? false
    }

    func recordZoomHint(_ text: String) {
        zoomHintText = text
    }

    func recordAuditionToggle(on: Bool, symbol: String, help: String) {
        auditionToggleOn = on
        auditionToggleSymbol = symbol
        auditionToggleHelp = help
    }

    func recordAuditionLine(_ line: PitchEditorLineCaption?) {
        auditionLineTicks += 1
        auditionLineText = line?.text ?? ""
        auditionLineKind = line?.kind.rawValue ?? ""
    }

    func recordRenderCaption(_ text: String?) {
        renderCaptionText = text ?? ""
    }

    func countBodyEvaluation() {
        bodyEvaluations &+= 1
    }

    func recordCutLine(_ line: PitchEditorCutLine?) {
        cutLineTicks += 1
        cutLine = line
    }

    func recordMaximizeToggle(maximized: Bool, symbol: String) {
        maximizeToggleMaximized = maximized
        maximizeToggleSymbol = symbol
    }

    func recordEscapeMountHit() {
        escapeMountHits += 1
    }

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
                           dragReadout: String, refusalText: String, farMoveHint: String,
                           commitCount: Int) {
        interactionTicks += 1
        self.toolKey = toolKey
        self.paletteLabels = paletteLabels
        self.toolHelp = toolHelp
        self.dragReadout = dragReadout
        self.refusalText = refusalText
        self.farMoveHint = farMoveHint
        self.commitCount = commitCount
    }

    func record(statusKey: String, statusText: String, caption: String,
                presetLabels: [String], presetSummaries: [String],
                noteCount: Int, badge: PitchEditorClipBadge?) {
        ticks += 1
        self.statusKey = statusKey
        self.statusText = statusText
        self.captionText = caption
        self.presetLabels = presetLabels
        self.presetSummaries = presetSummaries
        self.noteCount = noteCount
        self.tuningApplied = badge == .tuningApplied
        self.notesEdited = badge == .notesEdited
        self.clipBadgeText = badge?.title ?? ""
    }

    func clear() {
        toolKey = ""
        paletteLabels = []
        toolHelp = ""
        dragReadout = ""
        refusalText = ""
        farMoveHint = ""
        commitCount = 0
        interactionTicks = 0
        statusKey = ""
        statusText = ""
        captionText = ""
        presetLabels = []
        presetSummaries = []
        noteCount = 0
        tuningApplied = false
        notesEdited = false
        clipBadgeText = ""
        ticks = 0
        lineBasisKey = ""
        lineReason = nil
        lineCaptionText = ""
        lineCaptionKind = ""
        unresolvedNoteIDs = []
        clipPitchShiftSemitones = 0
        perNote = []
        lineTicks = 0
        cutLine = nil
        cutLineTicks = 0
        maximizeToggleMaximized = false
        maximizeToggleSymbol = ""
        escapeMountHits = 0
        auditionToggleOn = false
        auditionToggleSymbol = ""
        auditionToggleHelp = ""
        auditionLineText = ""
        auditionLineKind = ""
        auditionLineTicks = 0
        renderCaptionText = ""
        bodyEvaluations = 0
        wobbleDot = nil
        wobbleDraft = nil
        wobbleReadoutText = ""
        wobbleReadoutIsWarning = false
        wobbleTicks = 0
        brushBand = nil
        brushDraft = nil
        commandHeld = false
        brushTicks = 0
        singerGroup = nil
        singerFrame = nil
        presetsFrame = nil
        singerTicks = 0
        voiceMarks = []
        voiceDraft = nil
        voiceReadoutText = ""
        voiceTicks = 0
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
    /// The notes being dragged, drawn by `PitchEditorDragOverlay` instead of
    /// here for the length of the gesture — so a moving note is never drawn
    /// twice, and never left behind. One id for a one-note drag; every moving
    /// note for a GROUP drag (m23-ap I4).
    var hiddenBlobIDs: Set<UUID>
    /// m23-ap I4 — the SELECTED notes. Since I7b their own signal: a white
    /// wash and a glowing white ring (`PitchEditorSurface.drawSelectionGlow`),
    /// never the `signal` green every TUNED note already wears. A drawn note
    /// that is NOT selected looks exactly as it did before I4.
    var selectedIDs: Set<UUID>
    var gaps: [PitchEditorGap]
    var peaks: WaveformPeaks?
    /// The m25-e auto-fit scalar, resolved per-view from the headless rules —
    /// never per column and never per frame.
    var waveformScale: CGFloat
    /// Whether there are notes to draw at all (`PitchEditorState.drawsNotes`).
    var drawsNotes: Bool

    init(geometry: PitchEditorGeometry, blobs: [NoteBlob], playedLine: [[CGPoint]],
         lineIsEstimate: Bool = false, unresolvedNoteIDs: Set<UUID> = [],
         hiddenBlobIDs: Set<UUID> = [], selectedIDs: Set<UUID> = [],
         gaps: [PitchEditorGap], peaks: WaveformPeaks?,
         waveformScale: CGFloat, drawsNotes: Bool) {
        self.geometry = geometry
        self.blobs = blobs
        self.playedLine = playedLine
        self.lineIsEstimate = lineIsEstimate
        self.unresolvedNoteIDs = unresolvedNoteIDs
        self.hiddenBlobIDs = hiddenBlobIDs
        self.selectedIDs = selectedIDs
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
        // m23-ap I7b — THE WAVEFORM UNDER A CLEARED NOTE IS DIMMED: the sound is
        // still in the file (Restore brings it back), but the render plays
        // silence there, so it recedes. The columns are the same columns,
        // stroked into a second, fainter pair of paths — nothing is re-sampled.
        let silenced: [ClosedRange<CGFloat>] = ctx.blobs.filter(\.isCleared).map { blob in
            let rect = ctx.geometry.rect(for: blob)
            return rect.minX...rect.maxX
        }
        var body = Path()
        var core = Path()
        var dimBody = Path()
        var dimCore = Path()
        var x: CGFloat = 0
        while x <= size.width {
            let seconds = ctx.geometry.sourceSecond(forX: x)
            let mag = CGFloat(peaks.magnitude(atSeconds: seconds))
            let drawn = max(0.5, mag * ctx.waveformScale * halfH)
            let bodyH = min(maxH, drawn)
            let coreH = min(maxH, drawn * 0.55)
            let dimmed = !silenced.isEmpty && silenced.contains { $0.contains(x) }
            if dimmed {
                dimBody.move(to: CGPoint(x: x, y: midY - bodyH))
                dimBody.addLine(to: CGPoint(x: x, y: midY + bodyH))
                dimCore.move(to: CGPoint(x: x, y: midY - coreH))
                dimCore.addLine(to: CGPoint(x: x, y: midY + coreH))
            } else {
                body.move(to: CGPoint(x: x, y: midY - bodyH))
                body.addLine(to: CGPoint(x: x, y: midY + bodyH))
                core.move(to: CGPoint(x: x, y: midY - coreH))
                core.addLine(to: CGPoint(x: x, y: midY + coreH))
            }
            x += step
        }
        // `textDim` at low opacity — the muted tier, dimmed further because this
        // layer is BEHIND the subject. No accent: a waveform is not a state.
        context.stroke(body, with: .color(DAWTheme.textDim.opacity(0.16)), lineWidth: 1)
        context.stroke(core, with: .color(DAWTheme.textDim.opacity(0.30)), lineWidth: 1)
        // A third of that under a cleared note: still readable as "the sound is
        // here", no longer as "this plays".
        context.stroke(dimBody, with: .color(DAWTheme.textDim.opacity(0.16 * Self.clearedWaveformStrength)),
                       lineWidth: 1)
        context.stroke(dimCore, with: .color(DAWTheme.textDim.opacity(0.30 * Self.clearedWaveformStrength)),
                       lineWidth: 1)
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

    /// m23-ap I7b — how much of the selected look's white wash sits over a
    /// selected note's fill. Enough to lift the note a clear step above its
    /// neighbours at forty notes, not so much that its own tuned/untuned
    /// colour is lost under it.
    nonisolated static let selectedWashOpacity: Double = 0.16

    /// m23-ap I7b — a CLEARED note's dash: longer than the moved-note ghost's
    /// `[3, 3]` and drawn heavier and brighter, so "silenced, still here" and
    /// "where it was sung" never read as the same outline.
    nonisolated static let clearedDash: [CGFloat] = [4, 3]

    /// m23-ap I7b — the waveform's strength under a cleared note, as a fraction
    /// of its normal strength.
    nonisolated static let clearedWaveformStrength: Double = 0.33

    /// UE-2 — a SOUND's look (`PitchEditorBlobLook.sound`): FIXED strengths,
    /// never the confidence wash. The wash is lighter than the faintest NOTE's
    /// (0.10 at confidence 0) and there is no opaque plate under it, so the
    /// sound's own waveform shows through its stripes; the outline is SOLID —
    /// a dash is the cleared note's and the ghost's grammar, never a sound's.
    nonisolated static let soundWashOpacity: Double = 0.06
    nonisolated static let soundHatchOpacity: Double = 0.42
    nonisolated static let soundOutlineOpacity: Double = 0.34
    /// The stripes' pitch, points along x: dense enough to read as a texture on
    /// a 20 pt breath, open enough that the waveform shows between them.
    nonisolated static let soundHatchSpacing: CGFloat = 5

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
    ///
    /// ⭐ m23-ap I7b — THE STATES, AS ONE SYSTEM (each must read apart from
    /// every other at the default zoom, for a novice):
    ///   • plain — neutral fill, faint neutral hairline;
    ///   • tuned (any edit) — the same fill tinted `signal`, a `signal` hairline;
    ///   • SELECTED — a white wash over whichever of those it is and a 2 pt WHITE
    ///     ring with the house glow (`drawSelectionGlow`): the roll's "selected
    ///     note" grammar (brighter, a `textPrimary` hairline, a bloom), because
    ///     on a tuned clip every note already wears `signal`, and I4's selection
    ///     — the same hue, brighter — was measured reading as "slightly
    ///     brighter" at forty notes;
    ///   • CLEARED — HOLLOW (no fill), a dashed `textSecondary` outline, the
    ///     word "cleared", its stretch of the line gone and its waveform dimmed:
    ///     silenced, still here — never "deleted" (it is drawn) and never
    ///     "selected" (no white, no glow);
    ///   • selected + cleared — still hollow, the outline dashed AND white AND
    ///     glowing;
    ///   • a moved note's ghost — fainter (`textDim` 40 %), a shorter dash, no
    ///     label, and a connector to the note it became;
    ///   • UE-2 — a SOUND with no pitch — HATCHED AND FAINT (design §1.9, §1.10:
    ///     Melodyne's "displayed hatched"; F-many "sounds draw faint"): no
    ///     opaque plate, a fixed faint wash, diagonal stripes and a SOLID
    ///     hairline, all `textDim` — `signal` once its pitch is edited, like a
    ///     note — at a strength NO confidence can move, and no note name.
    ///     Selected, it takes the note's white wash and solid glowing ring. A
    ///     CLEARED sound draws cleared (`NoteBlob.look` asks that first).
    private nonisolated static func drawBlobs(_ context: inout GraphicsContext,
                                              ctx: PitchEditorDrawContext) {
        // I7b — every selected note's ring, gathered and stroked in ONE glowing
        // layer after the loop: one layer however many are selected (⌘A on a
        // long take is hundreds), and never under a later neighbour's fill.
        var selectedRings = Path()
        var selectedClearedRings = Path()
        // UE-2 — every sound's shape (the clip) and stripes, gathered and drawn
        // in ONE clipped layer per ink after the loop — never a layer per sound
        // (a dense take has dozens).
        var soundShapes = Path()
        var soundHatch = Path()
        var tunedSoundShapes = Path()
        var tunedSoundHatch = Path()
        // The dragged note is the DRAG OVERLAY's for the length of the gesture
        // (it draws the ghost, the moving blob and the moving line) — drawn
        // here too, it would sit at its committed row under the moving one.
        for blob in ctx.blobs where !ctx.hiddenBlobIDs.contains(blob.id) {
            let rect = ctx.geometry.rect(for: blob)
            let confidence = min(1, max(0, blob.medianConfidence))
            let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.height / 3))
            let selected = ctx.selectedIDs.contains(blob.id)
            switch blob.look {
            case .cleared:
                // ⭐ I7b — CLEARED: HOLLOW. No fill at all — not the raised
                // panel, not the confidence wash — so the dimmed waveform shows
                // through and the box reads EMPTY (the line has a hole there,
                // made by `PitchPlayedLine.make` itself). ⚠️ Asked BEFORE
                // `isEdited`: a cleared note is an edited one, and the tuned
                // accent must not be drawn on a note that plays silence.
                if selected {
                    selectedClearedRings.addPath(shape)
                } else {
                    context.stroke(shape, with: .color(DAWTheme.textSecondary.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 1.25, dash: Self.clearedDash))
                }
            case .sound:
                // ⭐ UE-2 — A SOUND: HATCHED AND FAINT, AT A FIXED STRENGTH. ⛔ NOT
                // THE CONFIDENCE WASH: a breath's frames sit near 0.59 (design
                // §1.2), which would draw it as a middling NOTE — a pitch claim
                // the stripes exist to refuse. No opaque plate: the sound's own
                // waveform shows through. The tuned question is the note's
                // (`isPitchEdited`): a moved sound wears `signal` stripes.
                let ink = blob.isPitchEdited ? DAWTheme.signal : DAWTheme.textDim
                context.fill(shape, with: .color(ink.opacity(Self.soundWashOpacity)))
                context.stroke(shape, with: .color(ink.opacity(Self.soundOutlineOpacity)), lineWidth: 1)
                if blob.isPitchEdited {
                    tunedSoundShapes.addPath(shape)
                    Self.addHatch(&tunedSoundHatch, in: rect)
                } else {
                    soundShapes.addPath(shape)
                    Self.addHatch(&soundHatch, in: rect)
                }
                if selected {
                    context.fill(shape,
                                 with: .color(DAWTheme.textPrimary.opacity(Self.selectedWashOpacity)))
                    selectedRings.addPath(shape)
                }
            case .note:
                // ⚠️ **TWO FILLS, AND THE SECOND ONE IS WHY THE BLOB IS VISIBLE
                // AT ALL.** MEASURED by looking at a render: `panelRaised`
                // (#181C27) composited over `background` (#0B0D12) is a delta of
                // ~13 levels — the first pass drew the blobs and they could not
                // be seen, only their hairline could. The opaque base pins the
                // surface, and the NEUTRAL wash on top is what carries the
                // confidence encoding into visible range. Still no accent: a
                // detected note is not a state (Rule 3), and `textDim` is the
                // app's neutral ink, not a colour.
                context.fill(shape, with: .color(DAWTheme.panelRaised))
                // ⛔ **AN EDITED NOTE MUST NOT LOOK LIKE AN UNTOUCHED ONE — A
                // DEFECT I COULD ONLY SEE BY RENDERING ONE.** The first pass drew
                // every blob in the neutral ink at its EDITED position, which is
                // right, and left the picture unable to say WHICH notes had been
                // moved: six identical rectangles, three of them changed. The
                // accent is earned by STATE here, which is the one thing
                // `docs/DESIGN-LANGUAGE.md` Rule 3 allows it for. `signal`, never
                // cyan (playback) and never violet (AI-touched content) — a
                // person tuning their own vocal is neither.
                // ⭐ m23-ap I1 UI hooks item 7: the TUNED green asks the PITCH
                // half (`isPitchEdited` = `!NoteSegment.isPitchIdentity`, the
                // predicate the header badge aggregates), never `isEdited`,
                // which also counts levels: a note that was only turned down is
                // not tuned. Its level says itself on its own plate
                // (`drawBlobLabels`), a clear on its own dashed look above.
                let ink = blob.isPitchEdited ? DAWTheme.signal : DAWTheme.textDim
                context.fill(shape, with: .color(ink.opacity(0.10 + 0.18 * confidence)))
                context.stroke(shape,
                               with: .color(ink.opacity(0.22 + 0.33 * confidence)),
                               lineWidth: 1)
                // I7b — SELECTED: the note is lifted by a white wash, and its
                // ring joins the glowing layer below.
                if selected {
                    context.fill(shape,
                                 with: .color(DAWTheme.textPrimary.opacity(Self.selectedWashOpacity)))
                    selectedRings.addPath(shape)
                }
            }
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
        // UE-2 — the stripes, over every fill and under the selection's glow.
        Self.drawHatch(&context, clip: soundShapes, hatch: soundHatch,
                       ink: DAWTheme.textDim.opacity(Self.soundHatchOpacity))
        Self.drawHatch(&context, clip: tunedSoundShapes, hatch: tunedSoundHatch,
                       ink: DAWTheme.signal.opacity(Self.soundHatchOpacity))
        Self.drawSelectionGlow(&context, rings: selectedRings, clearedRings: selectedClearedRings)
    }

    /// UE-2 — 45° stripes (bottom-left → top-right) across `rect`, appended to
    /// `path`, on an ABSOLUTE x grid: two sounds side by side stripe in step,
    /// and a redraw never slides them. They run past the rounded corners on
    /// purpose — `drawHatch` clips them to the shapes.
    nonisolated static func addHatch(_ path: inout Path, in rect: CGRect,
                                     spacing: CGFloat = PitchEditorSurface.soundHatchSpacing) {
        let height = rect.height
        guard rect.width > 0, height > 0, spacing > 0 else { return }
        // The line through (x0, maxY) and (x0 + height, minY) crosses the rect
        // for x0 in (minX − height, maxX).
        var x0 = (((rect.minX - height) / spacing).rounded(.down)) * spacing
        while x0 < rect.maxX {
            path.move(to: CGPoint(x: x0, y: rect.maxY))
            path.addLine(to: CGPoint(x: x0 + height, y: rect.minY))
            x0 += spacing
        }
    }

    /// UE-2 — stroke `hatch` clipped to `clip`, in ONE layer (one clip, one
    /// stroke however many shapes the paths hold). Shared with the drag
    /// overlay, so a sound being dragged is striped the same way.
    nonisolated static func drawHatch(_ context: inout GraphicsContext, clip: Path,
                                      hatch: Path, ink: Color) {
        guard !hatch.isEmpty else { return }
        context.drawLayer { layer in
            layer.clip(to: clip)
            layer.stroke(hatch, with: .color(ink), lineWidth: 1)
        }
    }

    /// m23-ap I7b — THE SELECTED LOOK'S RING: 2 pt `textPrimary` (white) at
    /// 95 % in the house glow recipe (a tight core shadow and a faint wide
    /// bloom, `PitchEditorCutPreview`'s layer) — solid over a note, dashed over
    /// a cleared one so it stays hollow. "Glow is state": nothing else on this
    /// surface glows at rest, so the selection is the one thing that does.
    private nonisolated static func drawSelectionGlow(_ context: inout GraphicsContext,
                                                      rings: Path, clearedRings: Path) {
        guard !rings.isEmpty || !clearedRings.isEmpty else { return }
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: DAWTheme.textPrimary.opacity(0.6), radius: 4))
            layer.addFilter(.shadow(color: DAWTheme.textPrimary.opacity(0.15), radius: 10))
            layer.stroke(rings, with: .color(DAWTheme.textPrimary.opacity(0.95)), lineWidth: 2)
            layer.stroke(clearedRings, with: .color(DAWTheme.textPrimary.opacity(0.95)),
                         style: StrokeStyle(lineWidth: 2, dash: Self.clearedDash))
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
        // I7b — the state words ("cleared", "Level -6.0 dB") go on small plates
        // in a SECOND pass, so a neighbour's name drawn later can never write
        // over them.
        var cleared: [(rect: CGRect, selected: Bool)] = []
        var levels: [(rect: CGRect, readout: String, nameWidth: CGFloat)] = []
        for blob in ctx.blobs where !ctx.hiddenBlobIDs.contains(blob.id) {
            let rect = ctx.geometry.rect(for: blob)
            if blob.isCleared {
                cleared.append((rect, ctx.selectedIDs.contains(blob.id)))
                continue
            }
            var nameWidth: CGFloat = 0
            // ⛔ UE-2 — A SOUND GETS NO NAME. Its row is BORROWED from the note
            // beside it (design §1.5), so "B3" over a breath is the pitch claim
            // its missing cents already refuse (`NoteBlob.centsReadout`). The
            // stripes say what it is, and the header's legend says it in words
            // (`PitchEditorSoundLook.soundsLegend`) — once, not per sound. A
            // level still reads (below): a level is never invisible.
            if rect.width >= 20, blob.look == .note {
                // ⛔ **THE DRAWN NOTE'S NAME, NOT `noteName` — THE SECOND DEFECT
                // THE RENDER SHOWED.** With the blob drawn at its EDITED pitch, a
                // label carrying the SUNG note put "B3" on a rectangle sitting on
                // the C4 row: the picture contradicted itself, and the label is
                // the part a novice believes. The label names the note this blob
                // IS — on a transposed clip, the transposed note (C-0) — and
                // where it came from is said by the ghost outline, a picture of a
                // measurement rather than a claim in words.
                let name = context.resolve(
                    Text(ctx.geometry.drawnNoteName(for: blob))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        // Item 7: the name wears the tuned green on the SAME
                        // question as the body, `isPitchEdited`.
                        .foregroundColor(blob.isPitchEdited ? DAWTheme.signal : DAWTheme.textSecondary))
                context.draw(name, at: CGPoint(x: rect.minX + 1, y: rect.minY - 1),
                             anchor: .bottomLeading)
                nameWidth = name.measure(in: CGSize(width: 400, height: 40)).width
            }
            if let readout = blob.levelReadout {
                levels.append((rect, readout, nameWidth))
            }
        }
        // ⭐ I7b — "cleared": the menu's own word, INSIDE the hollow box when it
        // fits (the box is empty — its line is hidden — so nothing draws over
        // it), else on a plate in the gutter above, where the name would go. A
        // cleared note trades its name for the word: what matters about a note
        // that plays silence is that it does.
        for (rect, selected) in cleared {
            let word = context.resolve(
                Text(PitchEditorNoteMenu.clearedLabel)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(selected ? DAWTheme.textPrimary : DAWTheme.textSecondary))
            let size = word.measure(in: CGSize(width: 400, height: 40))
            if size.width + 6 <= rect.width, size.height <= rect.height + 1 {
                context.draw(word, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            } else {
                Self.drawStatePlate(&context, text: word, size: size,
                                    at: CGPoint(x: rect.minX, y: rect.minY - 1))
            }
        }
        // ⭐ I7b — A LEVEL IS NEVER INVISIBLE (design §17.3): "Level -6.0 dB" in
        // the clip gain chip's own dress (SF Mono 8 semibold, `playback` cyan —
        // the house ink for a gain readout — on a `panel` plate), after the
        // note's name. `NoteBlob.levelReadout` decides whether there is one;
        // nothing here re-decides it.
        for (rect, readout, nameWidth) in levels {
            let text = context.resolve(
                Text(readout)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(DAWTheme.playback))
            let size = text.measure(in: CGSize(width: 400, height: 40))
            let x = nameWidth > 0 ? rect.minX + 1 + nameWidth + 5 : rect.minX
            Self.drawStatePlate(&context, text: text, size: size, at: CGPoint(x: x, y: rect.minY - 1))
        }
    }

    /// A small state word on a `panel` plate in the gutter above a note,
    /// bottom-left at `origin` — the gain chip's plate.
    private nonisolated static func drawStatePlate(_ context: inout GraphicsContext,
                                                   text: GraphicsContext.ResolvedText,
                                                   size: CGSize, at origin: CGPoint) {
        let plate = CGRect(x: origin.x, y: origin.y - size.height - 1,
                           width: size.width + 6, height: size.height + 2)
        context.fill(Path(roundedRect: plate, cornerRadius: 3), with: .color(DAWTheme.panel.opacity(0.85)))
        context.draw(text, at: CGPoint(x: plate.minX + 3, y: plate.midY), anchor: .leading)
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
            // UE-2 — a SOUND moves as a sound: striped, never a solid note.
            Self.drawMoving(&context, rect: live, isSound: draft.isUnpitched)

            // m23-ap I4 — EVERY OTHER NOTE OF A GROUP DRAG, drawn the same way
            // (ghost, connector, moving note) at the one delta they share. The
            // readout stays on the pressed note: the delta is one number.
            for member in draft.members {
                let memberGhost = geometry.rect(
                    startSeconds: member.startSeconds, endSeconds: member.endSeconds,
                    centreMidi: member.ghostMidi(clipPitchShiftSemitones: draft.clipPitchShiftSemitones))
                let memberLive = geometry.rect(
                    startSeconds: member.startSeconds, endSeconds: member.endSeconds,
                    centreMidi: member.targetMidi(clipPitchShiftSemitones: draft.clipPitchShiftSemitones))
                context.stroke(Path(roundedRect: memberGhost,
                                    cornerRadius: min(4, memberGhost.height / 3)),
                               with: .color(DAWTheme.textDim.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if abs(memberLive.midY - memberGhost.midY) > 1 {
                    var link = Path()
                    link.move(to: CGPoint(x: memberGhost.midX, y: memberGhost.midY))
                    link.addLine(to: CGPoint(x: memberLive.midX, y: memberLive.midY))
                    context.stroke(link, with: .color(DAWTheme.signal.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                Self.drawMoving(&context, rect: memberLive, isSound: member.isUnpitched)
            }

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
            // UE-1 — the label is the draft's own (`overlayLabel`): a note's
            // name and cents exactly as before; a SOUND carries no note name.
            // UE-2 — and not §1.7's whole sentence, which is ~500 pt over a
            // breath a few dozen wide: the two-word tag ("No pitch",
            // `PitchEditorReadout.unpitchedSoundTag`), while the palette's
            // readout slot carries the sentence.
            if let text = draft.overlayLabel {
                context.draw(
                    Text(text)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(DAWTheme.signal),
                    at: CGPoint(x: live.midX, y: live.minY - 3), anchor: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    /// One MOVING blob in `signal`, the accent the gesture earns: a note's
    /// plate, or — UE-2 — a SOUND's stripes, so a breath being dragged never
    /// turns into a solid note for the length of the gesture. Brighter than
    /// the surface's resting sound (it is being changed right now), with the
    /// same solid 1.5 pt edge as a moving note.
    private nonisolated static func drawMoving(_ context: inout GraphicsContext,
                                               rect: CGRect, isSound: Bool) {
        let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.height / 3))
        if isSound {
            var hatch = Path()
            PitchEditorSurface.addHatch(&hatch, in: rect)
            context.fill(shape, with: .color(DAWTheme.signal.opacity(0.10)))
            PitchEditorSurface.drawHatch(&context, clip: shape, hatch: hatch,
                                         ink: DAWTheme.signal.opacity(0.75))
        } else {
            context.fill(shape, with: .color(DAWTheme.panelRaised))
            context.fill(shape, with: .color(DAWTheme.signal.opacity(0.30)))
        }
        context.stroke(shape, with: .color(DAWTheme.signal.opacity(0.85)), lineWidth: 1.5)
    }
}

// MARK: - The Wobble tool's layer (m23-ap C5a-4b)

/// The Wobble tool's own layer, over the surface: THE DOT on the note the tool
/// can grab under the pointer (with its drawn TIP), and during a drag the KNOB
/// and the note's stretch of the DRAFT line. Nothing here decides anything:
/// the dot, the tip and the knob's note are the model's (`wobbleDot`,
/// `wobble`), the line is `draftLineSegments`, and the words the palette says
/// live in the palette's one SF Mono slot (the UE-2 law: a sentence never rides
/// the pointer, and the slot never wraps).
///
/// ⭐ **THE DOT.** 10 pt (`PitchWobbleGesture.dotDiameter`) at the blob's top
/// centre, in `signal` ink with the house glow — a state the pointer earned
/// (Rule 3), never cyan (playback) or violet (AI-touched content): a person
/// shaping their own voice is neither. It grabs within 12 pt, drawn nowhere.
///
/// ⭐ **THE TIP IS DRAWN, NEVER A TOOLTIP** (unpitched design §4, V13: a tooltip
/// is invisible to `view.capture`): a small plate above the dot, the user's own
/// words. It is anchored to the NOTE, which does not move, and clamped into the
/// part of the content a person can SEE (`visible`, the scrollers' measured
/// window) — clamping it to the content-wide Canvas would not be clamping it to
/// the screen (the UE-2 lesson).
///
/// ⭐ **THE BLOB IS NOT HIDDEN DURING A WOBBLE DRAG** (a pitch drag hides its
/// blob because the drag overlay redraws it on another row; a wobble never
/// moves the note). Only its stretch of line leaves the surface
/// (`PitchEditorModel.draftSpans`) and is drawn here, so the line is drawn
/// once, in one place.
struct PitchEditorWobbleOverlay: View, Equatable {
    var geometry: PitchEditorGeometry
    /// The dot to draw with its tip (hover, or the note a click just stepped).
    var dot: PitchEditorWobbleDot?
    /// The knob of the drag in flight: the pressed note's dot centre.
    var knob: CGPoint?
    /// The dragged note's stretch of the DRAFT played line.
    var draftLine: [[CGPoint]] = []
    var lineIsEstimate: Bool = false
    /// What the scrollers show, content space — the tip is kept inside it.
    var visible: CGRect

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.geometry == b.geometry && a.dot == b.dot && a.knob == b.knob
            && a.draftLine == b.draftLine && a.lineIsEstimate == b.lineIsEstimate
            && a.visible == b.visible
    }

    var body: some View {
        let dot = dot
        let knob = knob
        let draftLine = draftLine
        let estimate = lineIsEstimate
        let visible = visible
        return Canvas { @Sendable context, _ in
            // The draft line first, so the knob sits on top of it.
            PitchEditorSurface.drawPlayedLine(&context, lines: draftLine, estimate: estimate)
            if let knob {
                Self.drawDot(&context, at: knob, pressed: true)
            }
            if let dot {
                Self.drawDot(&context, at: dot.centre, pressed: false)
                Self.drawTip(&context, text: dot.tip.text, dot: dot.centre,
                             blob: dot.blobRect, visible: visible)
            }
        }
        .allowsHitTesting(false)
    }

    /// The dot, in the house glow recipe (a tight same-colour shadow and a
    /// faint wide bloom around a full-opacity core). Pressed (the knob of a
    /// drag in flight) it gains a ring, so "I am holding it" reads apart from
    /// "I could grab it".
    private nonisolated static func drawDot(_ context: inout GraphicsContext, at centre: CGPoint,
                                            pressed: Bool) {
        let radius = PitchWobbleGesture.dotDiameter / 2
        let disc = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                          width: radius * 2, height: radius * 2))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: DAWTheme.signal.opacity(0.6), radius: 6))
            layer.addFilter(.shadow(color: DAWTheme.signal.opacity(0.15), radius: 20))
            layer.fill(disc, with: .color(DAWTheme.signal))
        }
        // A dark hairline keeps the dot legible where it sits on the bright line.
        context.stroke(disc, with: .color(DAWTheme.background.opacity(0.7)), lineWidth: 1)
        if pressed {
            let ring = radius + 3
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - ring, y: centre.y - ring,
                                                  width: ring * 2, height: ring * 2)),
                           with: .color(DAWTheme.signal.opacity(0.7)), lineWidth: 1.5)
        }
    }

    /// The tip's plate: above the dot when it fits in what the scrollers show,
    /// else below the note; slid sideways to stay inside it.
    private nonisolated static func drawTip(_ context: inout GraphicsContext, text: String,
                                            dot: CGPoint, blob: CGRect, visible: CGRect) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(DAWTheme.textPrimary))
        let size = resolved.measure(in: CGSize(width: 800, height: 40))
        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let width = size.width + 2 * padX
        let height = size.height + 2 * padY
        let gap = PitchWobbleGesture.dotDiameter / 2 + 5
        var y = dot.y - gap - height
        if y < visible.minY + 2 { y = blob.maxY + 5 }
        var x = dot.x - width / 2
        if visible.width > width + 8 {
            x = min(max(x, visible.minX + 4), visible.maxX - width - 4)
        }
        let plate = CGRect(x: x, y: y, width: width, height: height)
        context.fill(Path(roundedRect: plate, cornerRadius: 4),
                     with: .color(DAWTheme.panel.opacity(0.94)))
        context.stroke(Path(roundedRect: plate, cornerRadius: 4),
                       with: .color(DAWTheme.signal.opacity(0.45)), lineWidth: 1)
        context.draw(resolved, at: CGPoint(x: plate.midX, y: plate.midY), anchor: .center)
    }
}

// MARK: - The Voice tool's layer (W7-NTU U3)

/// W7-NTU U3 — THE VOICE TOOL'S LAYER (natural tuning §1(f) item 2, R22). For
/// every note whose Voice is not as sung: a thin horizontal bar INSIDE its
/// blob, off the blob's centre by the value (up is brighter; the UI's ±6 reach
/// the blob's edges, `PitchEditorVoiceMark.offsetFraction`), and an SF Mono
/// chip under the note ("Deeper 2.0", `PitchEditorVoiceMark.chip`).
///
/// ⭐ **`signal` INK, NEVER AMBER (R22).** Amber on a note in this editor means
/// "the render could not apply this" (the unresolved outline), and a Voice is
/// a person's own shaping, not a refusal. Not cyan (playback) and not violet
/// (nothing here is AI-made). The note being DRAGGED earns the glow and the
/// chip's ring (glow is earned by state, `docs/DESIGN-LANGUAGE.md` Rule 3);
/// a note at rest wears neither.
///
/// The blob is not hidden and never moves: a Voice changes how a note sounds,
/// not where it sits, so this layer only draws on top of it. The marks are the
/// model's (`PitchEditorModel.voiceMarks`), drawn and echoed from one value.
struct PitchEditorVoiceOverlay: View, Equatable {
    var marks: [PitchEditorVoiceMark]
    /// The content's size: a chip that would fall off the bottom goes above
    /// its note instead, and none is drawn past either side.
    var contentSize: CGSize

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.marks == b.marks && a.contentSize == b.contentSize
    }

    var body: some View {
        let marks = marks
        let size = contentSize
        return Canvas { @Sendable context, _ in
            // Every bar first, then every chip, so a chip is never drawn under
            // a neighbour's bar.
            for mark in marks { Self.drawBar(&context, mark: mark) }
            for mark in marks { Self.drawChip(&context, mark: mark, contentSize: size) }
        }
        .allowsHitTesting(false)
    }

    /// The bar, inset from the blob's ends, on a dark hairline so it reads on
    /// the tuned green of a pitch-edited note.
    private nonisolated static func drawBar(_ context: inout GraphicsContext,
                                            mark: PitchEditorVoiceMark) {
        let rect = mark.blobRect.standardized
        guard rect.width >= 4, rect.height >= 3 else { return }
        let inset = min(2, rect.width / 4)
        let half = max(0, rect.height / 2 - 1.5)
        let y = rect.midY - CGFloat(mark.offsetFraction) * half
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: y))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: y))
        context.stroke(path, with: .color(DAWTheme.background.opacity(0.75)),
                       style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        let line = StrokeStyle(lineWidth: 1.5, lineCap: .round)
        if mark.isLive {
            // The house glow recipe (the Wobble dot's): a tight same-colour
            // shadow around a full-opacity core.
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: DAWTheme.signal.opacity(0.6), radius: 5))
                layer.stroke(path, with: .color(DAWTheme.signal), style: line)
            }
        } else {
            context.stroke(path, with: .color(DAWTheme.signal), style: line)
        }
    }

    /// The chip: SF Mono 8 semibold in `signal`, on the `panel` plate the
    /// note's other state words wear (`drawStatePlate`'s dress), in the gutter
    /// UNDER the note (its name and level sit above it).
    private nonisolated static func drawChip(_ context: inout GraphicsContext,
                                             mark: PitchEditorVoiceMark, contentSize: CGSize) {
        let text = context.resolve(
            Text(mark.chip)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(DAWTheme.signal))
        let size = text.measure(in: CGSize(width: 400, height: 40))
        let rect = mark.blobRect.standardized
        let width = size.width + 6
        let height = size.height + 2
        var y = rect.maxY + 2
        if y + height > contentSize.height { y = rect.minY - 2 - height }
        let x = min(max(rect.minX, 0), max(0, contentSize.width - width))
        let plate = CGRect(x: x, y: y, width: width, height: height)
        context.fill(Path(roundedRect: plate, cornerRadius: 3),
                     with: .color(DAWTheme.panel.opacity(0.85)))
        if mark.isLive {
            context.stroke(Path(roundedRect: plate, cornerRadius: 3),
                           with: .color(DAWTheme.signal.opacity(0.55)), lineWidth: 1)
        }
        context.draw(text, at: CGPoint(x: plate.minX + 3, y: plate.midY), anchor: .leading)
    }
}

// MARK: - The freehand brush's layer (m23-ap C5b-4b)

/// m23-ap C5b-4b — THE BRUSH'S LAYER (design 2026-09-24 timing-and-freehand
/// §5.5): the band, "a faint band 2R wide [that] follows the pointer while ⌘ is
/// held, showing where a stroke would act", and during a stroke the touched
/// notes' stretch of the DRAFT played line, with a glowing tip at the pointer.
/// Its own layer, for `PitchEditorDragOverlay`'s reason: the surface below is
/// untouched during a stroke, and nothing drawn here is committed.
///
/// ⭐ **THE BAND DRAWS THE KERNEL.** Its fill is the raised cosine the stroke
/// weights every sample with (`PitchShapeBrush.weight`: full at the centre,
/// ZERO at both edges), so what a person sees fade out at the band's edges IS
/// what the brush does there, never a flat box that claims an even reach.
/// `signal` ink, the edit accent, earned by the act of editing (Rule 3) —
/// never cyan (playback) and never violet (nothing here is AI-made). A band
/// the press would REFUSE (an estimate line, a sound) is `textDim` with dashed
/// edges, and the palette's help says why.
///
/// ⚠️ **NOTHING HERE ALLOCATES PER DRAW BEYOND THE PATHS:** the three band
/// looks' gradient stops are built once (`hoverStops` / `strokeStops` /
/// `refusedStops`), and `Gradient(stops:)` wraps that same buffer, so a stroke
/// redrawing at pointer rate re-uses them.
struct PitchEditorBrushOverlay: View, Equatable {
    var band: PitchEditorBrushBand
    /// The touched notes' stretch of the DRAFT played line; empty on a hover.
    var draftLine: [[CGPoint]] = []
    var lineIsEstimate: Bool = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.band == b.band && a.draftLine == b.draftLine && a.lineIsEstimate == b.lineIsEstimate
    }

    var body: some View {
        let band = band
        let draftLine = draftLine
        let estimate = lineIsEstimate
        return Canvas { @Sendable context, _ in
            Self.drawBand(&context, band)
            // The draft line over the band, so the band never veils it.
            PitchEditorSurface.drawPlayedLine(&context, lines: draftLine, estimate: estimate)
            if band.isStroking { Self.drawTip(&context, at: band.point) }
        }
        .allowsHitTesting(false)
    }

    /// The raised cosine (`0.5 · (1 + cos(π · Δ/R))`, Δ/R = −1 … 1) sampled at
    /// nine even stops across the band, as `ink` at `peak` × that weight: the
    /// kernel drawn. `Gradient.Stop` is `Sendable` (`Gradient` is not), so the
    /// stops are what is kept.
    private nonisolated static func kernelStops(_ ink: Color, peak: Double) -> [Gradient.Stop] {
        (0...8).map { step in
            let fraction = Double(step) / 8 * 2 - 1
            let weight = 0.5 * (1 + cos(.pi * fraction))
            return Gradient.Stop(color: ink.opacity(peak * weight), location: Double(step) / 8)
        }
    }

    /// One set of stops per look, built once: ⌘ held (hover), a stroke in
    /// flight (a touch brighter: it is acting), and a press that would be
    /// refused (neutral ink).
    private nonisolated static let hoverStops = kernelStops(DAWTheme.signal, peak: 0.12)
    private nonisolated static let strokeStops = kernelStops(DAWTheme.signal, peak: 0.18)
    private nonisolated static let refusedStops = kernelStops(DAWTheme.textDim, peak: 0.10)

    private nonisolated static func drawBand(_ context: inout GraphicsContext, _ band: PitchEditorBrushBand) {
        let rect = band.rect
        let refused = band.refusal != nil
        let stops = refused ? refusedStops : (band.isStroking ? strokeStops : hoverStops)
        context.fill(Path(rect), with: .linearGradient(Gradient(stops: stops),
                                                      startPoint: CGPoint(x: rect.minX, y: rect.midY),
                                                      endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
        // The reach's two edges, as hairlines, so the WIDTH reads even where
        // the fill has faded to nothing.
        var edges = Path()
        edges.move(to: CGPoint(x: rect.minX, y: rect.minY))
        edges.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        edges.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        edges.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.stroke(edges,
                       with: .color(refused ? DAWTheme.textDim.opacity(0.45) : DAWTheme.signal.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: refused ? [3, 3] : []))
    }

    /// The pen tip at the pointer, in the house glow recipe (a full-opacity
    /// core, a tight same-colour shadow, a faint wide bloom): the one glowing
    /// thing on the layer, because it is the one thing ACTING.
    private nonisolated static func drawTip(_ context: inout GraphicsContext, at point: CGPoint) {
        let radius: CGFloat = 3.5
        let disc = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                          width: radius * 2, height: radius * 2))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: DAWTheme.signal.opacity(0.6), radius: 6))
            layer.addFilter(.shadow(color: DAWTheme.signal.opacity(0.15), radius: 20))
            layer.fill(disc, with: .color(DAWTheme.signal))
        }
        context.stroke(disc, with: .color(DAWTheme.background.opacity(0.7)), lineWidth: 1)
    }
}

/// m23-ap C5b-4b — the brush's one view hook, one modifier for
/// `PitchEditorSelectionWiring`'s reason (the body's chain is at the type
/// checker's limit): the notes a stroke draws on leave the surface's line for
/// the overlay's draft stretch as the stroke reaches them, and come back at
/// its release or its Escape (`PitchEditorModel.draftSpans`).
private struct PitchEditorBrushWiring: ViewModifier {
    let model: PitchEditorModel
    let refreshPlayedSegments: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: model.brush?.touchedNoteIDs) { _, _ in refreshPlayedSegments() }
    }
}

// MARK: - The selection's wiring (m23-ap interaction batch I4)

/// The note selection's two directions across the pane's bridge, as ONE
/// modifier on the pane's body.
///
/// IN: ⌘A (routed by `SelectAllMenuPolicy` to `.pitchEditorNotes`), the debug
/// tier's clear, and a ⌫ or Edit ▸ Delete the app routed to the notes
/// (`DeleteSurface.pitchEditorNotes`) — since I7b that CLEARS them, through the
/// same model action the right-click Clear runs. None carries `initial:`, so a
/// pane that appears later never replays an old request.
///
/// OUT: the two facts the app's key policies read — on CHANGE only (the bridge
/// compares too), so a pointer tick never invalidates the ⌫ gate or the ⌘A
/// item; `initial: true`, so a pane that opens reports its truth at once — and
/// the surface report the echo reads the selection from, whenever the
/// selection's identity (`selectionToken`) moves.
private struct PitchEditorSelectionWiring: ViewModifier {
    let model: PitchEditorModel
    let interaction: PitchEditorInteractionBridge?
    let reportSurface: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: interaction?.selectAllNonce) { _, _ in model.selectAll() }
            .onChange(of: interaction?.clearSelectionNonce) { _, _ in model.clearSelection() }
            .onChange(of: interaction?.deleteNonce) { _, _ in model.performNoteAction(.clear) }
            .onChange(of: model.selection.isEmpty, initial: true) { _, empty in
                interaction?.report(hasNoteSelection: !empty)
            }
            .onChange(of: model.blobs.count, initial: true) { _, count in
                interaction?.report(drawnNoteCount: count)
            }
            .onChange(of: model.selectionToken) { _, _ in reportSurface() }
            // UE-2 — the selection's KINDS, for Edit ▸ Delete's noun ("Clear
            // Selected Sounds"). On the token: a selected id's kind cannot
            // change under it, so only a selection change can move this.
            .onChange(of: model.selectionToken, initial: true) { _, _ in
                interaction?.report(selectionKinds: model.selectionKinds)
            }
    }
}

/// m23-ap C5a-4b — the Wobble tool's view hooks, one modifier for
/// `PitchEditorSelectionWiring`'s reason (the body's chain is at the type
/// checker's limit):
///
/// - a wobble drag's note leaves the surface's line for the overlay's draft
///   stretch on its first promoted tick, and comes back at the release
///   (`PitchEditorModel.draftSpans`);
/// - `debug.pitchEditor`'s per-note wobble readings, read on demand from this
///   pane's model, installed and removed token-guarded like the surface report.
private struct PitchEditorWobbleWiring: ViewModifier {
    let model: PitchEditorModel
    let chrome: PitchEditorChromeLedger?
    let token: UUID
    let refreshPlayedSegments: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: model.wobble?.isDragging) { _, _ in refreshPlayedSegments() }
            .onAppear {
                let model = model
                chrome?.installWobbleReadings(token: token) { model.wobbleReadingsReport() }
            }
            .onDisappear { chrome?.removeWobbleReadings(token: token) }
    }
}

/// m23-ap I1 UI hooks — the pane's two audition STOP doors that are view
/// events (the RT review's H5: a slowed clip plays up to 6 SOURCE seconds,
/// stretched, so a way to silence it matters). The other two are Escape
/// (`PitchEditorModel.handleEscapeKey`) and the transport's Stop
/// (`ProjectStore.stop`). One modifier, for `PitchEditorSelectionWiring`'s
/// reason: the body's chain stays inside what the type checker can solve.
///
///  • **The pane going away** — closed, or switched to another clip (it is
///    mounted under `.id(clip.id)`, so a switch REMOVES this pane and mounts a
///    new one). ⚠️ Its OWN `.onDisappear`, never folded into `cancelDrag`: a
///    stop is not a cancel, and `cancelDrag` also runs on every click's
///    release, which must not silence the note the press just played.
///  • **The switch turning off** while a note sounds (`auditionEnabled`, the
///    header's HEAR switch or `debug.panelLayout`). Turning it ON plays
///    nothing.
private struct PitchEditorAuditionWiring: ViewModifier {
    let model: PitchEditorModel
    let auditionEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onDisappear { model.stopAudition() }
            .onChange(of: auditionEnabled) { _, on in
                if !on { model.stopAudition() }
            }
    }
}

// MARK: - The rubber band (m23-ap interaction batch I4)

/// The pitch editor's rubber band — the roll's `marqueeBandView` look, on
/// purpose: it is the same gesture on a different surface, and one meaning has
/// one look (docs/DESIGN-LANGUAGE.md). Cyan is active state and it glows only
/// while the band is live. Hit-test-inert, so it can never eat the drag that is
/// drawing it. The rect is the model's (`PitchEditorBand.rect`) — nothing here
/// decides what it touches.
struct PitchEditorBandView: View {
    var rect: CGRect

    var body: some View {
        if rect.width > 0, rect.height > 0 {
            RoundedRectangle(cornerRadius: 2)
                .fill(DAWTheme.playback.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(DAWTheme.playback.opacity(0.85), lineWidth: 1))
                .glow(DAWTheme.playback, radius: 6, intensity: 0.35)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - The cut line (m23-ap C3, redrawn by interaction batch I3)

/// Where the knife would land, and whether it may (design 2026-09-24
/// interaction batch §6). Drawn whenever the Split tool is live and the pointer
/// is on the surface. The user asked for "a vertical line for visual feedback
/// when I want to cut it"; the C3 preview was a 1 pt tick as tall as the note,
/// shown only over a note, and it was missed.
///
/// Three layers, bottom to top, each earned (docs/DESIGN-LANGUAGE.md Rule 3):
///  1. A CONTENT-HEIGHT HAIRLINE at the pointer, `textSecondary` at 40 %, with
///     NO glow — the hover-ghost-line rule: a hover hint must never be
///     confusable with the cyan playhead. Alone (`.noNote`) it says "move onto
///     a note".
///  2. Over the note, a 2 pt SEGMENT (the note ±6 pt) with the house glow:
///     `signal` where the knife would cut, `PanelRefusalLine`'s amber
///     (`DAWTheme.record`) where it would refuse — the colour of the outcome it
///     predicts.
///  3. The LABEL, SF Mono 9 ("Cut · 240 ms | 310 ms" / "Too close to the
///     edge"), on a plate ABOVE THE NOTE — below it at the top edge, clamped
///     sideways, never clipped (`PitchEditorCutLine.labelFrame`; the
///     orchestrator's ruling on §6, which put it at the content's top edge).
///
/// ⚠️ **NOTHING HERE DECIDES ANYTHING.** The verdict, the note's rect and the
/// words all arrive in `line`, from `PitchEditorModel.cutLine(at:)`, whose
/// verdict is the knife's own (`splitNote` switches over the same function).
/// The hover amber is a PREDICTION: nothing is refused, and no
/// `PanelRefusalLine` appears, until the click.
///
/// ⭐ Its own view and its own Canvas, for the drag overlay's reason: a pointer
/// tick redraws two strokes and a label here, never the surface below.
struct PitchEditorCutPreview: View, Equatable {
    var line: PitchEditorCutLine
    var contentSize: CGSize

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.contentSize == b.contentSize
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): value captures only, computed before the closure.
        let line = line
        let size = contentSize
        return Canvas { @Sendable context, _ in
            Self.draw(&context, line: line, size: size)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// The accent a verdict earns, or `nil` for the bare hairline.
    nonisolated static func accent(for verdict: PitchEditorCutVerdict) -> Color? {
        switch verdict {
        case .cut: return DAWTheme.signal
        case .tooCloseToEdge: return DAWTheme.record
        case .noNote: return nil
        }
    }

    nonisolated static func draw(_ context: inout GraphicsContext,
                                 line: PitchEditorCutLine, size: CGSize) {
        // 1 — the hairline, the full content height, no glow.
        var hairline = Path()
        hairline.move(to: CGPoint(x: line.x, y: 0))
        hairline.addLine(to: CGPoint(x: line.x, y: size.height))
        context.stroke(hairline, with: .color(DAWTheme.textSecondary.opacity(0.40)), lineWidth: 1)

        guard let ink = accent(for: line.verdict),
              let span = line.segmentSpan(contentHeight: size.height) else { return }

        // 2 — the segment over the note, in the house glow recipe (a tight core
        // shadow plus a faint wide bloom — `View.glow`), inside its own layer so
        // the shadows fall on this stroke alone.
        var segment = Path()
        segment.move(to: CGPoint(x: line.x, y: span.lowerBound))
        segment.addLine(to: CGPoint(x: line.x, y: span.upperBound))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: ink.opacity(0.6), radius: 4))
            layer.addFilter(.shadow(color: ink.opacity(0.15), radius: 10))
            layer.stroke(segment, with: .color(ink), lineWidth: 2)
        }

        // 3 — the label: measured here, placed by the model's rule.
        guard let words = line.verdict.label else { return }
        let text = context.resolve(
            Text(words)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(ink))
        let measured = text.measure(in: size)
        let plate = CGSize(width: ceil(measured.width) + 8, height: ceil(measured.height) + 4)
        guard let frame = line.labelFrame(labelSize: plate, contentSize: size) else { return }
        let shape = Path(roundedRect: frame, cornerRadius: 3)
        context.fill(shape, with: .color(DAWTheme.panel.opacity(0.92)))
        context.stroke(shape, with: .color(ink.opacity(0.35)), lineWidth: 0.5)
        context.draw(text, at: CGPoint(x: frame.midX, y: frame.midY), anchor: .center)
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
    /// The help the slot DRAWS: the engaged tool's, or — m23-ap C5b-4b, while
    /// ⌘ is held or a stroke is in flight — the brush's
    /// (`PitchEditorModel.paletteHelp`). Handed in, and reported to the ledger
    /// from the same value, so the drawn words and the echoed words are one.
    var help: String
    /// The live drag's readout, or nil. m23-ap C5a-4b: in the Wobble tool,
    /// the wobble's line (`PitchEditorModel.wobbleReadout`) — the same ONE
    /// SF Mono slot, so a wobble sentence never rides the pointer (UE-2).
    var dragReadout: String?
    /// C5a-4b — the readout is the RED state (design §9.2: a heard rate above
    /// what plays cleanly after a clip-speed change): `clip` ink, not `signal`.
    var readoutIsWarning: Bool = false
    /// A refusal to show, or nil.
    var refusal: String?
    /// C-0 — the one sentence about the LINE (design §4.4), or nil: still
    /// matching it to the sound, or a way it cannot be the sound.
    var lineCaption: PitchEditorLineCaption? = nil
    /// W7-NTU §1(f) item 4 — the far-move hint, or nil
    /// (`PitchEditorModel.farMoveHint`). Handed in, and reported to the ledger
    /// from the same value.
    var farMoveHint: String? = nil
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
            // W7-NTU §1(f) item 4 — ADVICE, NOT A WARNING: the move was taken,
            // nothing was refused, so secondary ink and no triangle (the
            // `.progress` caption's dress, without its spinner). It appears
            // after a release, never mid-drag, so the line it adds never moves
            // a row under the pointer.
            if let farMoveHint {
                Text(farMoveHint)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: PitchEditorPaletteLayout.spacing) {
                ForEach(PitchEditorTool.allCases) { candidate in
                    let active = candidate == tool
                    Button { onSelect(candidate) } label: {
                        HStack(spacing: PitchEditorPaletteLayout.slotInnerSpacing) {
                            Image(systemName: candidate.symbolName)
                                .font(.system(size: PitchEditorPaletteLayout.slotIconSize, weight: .medium))
                            Text(candidate.label)
                                .font(.system(size: PitchEditorPaletteLayout.slotLabelSize, weight: .medium))
                        }
                        // The ACTIVE slot wears `signal` — an accent earned by
                        // state, which is the one thing Rule 3 allows it for.
                        // An inactive slot is neutral ink on the raised panel:
                        // a tool you are not using is not a state.
                        .foregroundStyle(active ? DAWTheme.signal : DAWTheme.textSecondary)
                        .padding(.horizontal, PitchEditorPaletteLayout.slotHorizontalPadding)
                        .padding(.vertical, PitchEditorPaletteLayout.slotVerticalPadding)
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
                // W7-NTU — TWO LINES IN A BOX OF FIXED HEIGHT
                // (`PitchEditorPaletteLayout.helpLineLimit` / `helpHeight`):
                // the Wobble help beside its hover readout needs two lines at
                // the 1208 pt floor, and the box is the same height with one
                // line or two, so the row never moves the notes above it.
                // `PitchEditorPaletteFitTests` measures the fit.
                Text(help)
                    .font(.system(size: PitchEditorPaletteLayout.helpFontSize))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(PitchEditorPaletteLayout.helpLineLimit)
                    .frame(height: PitchEditorPaletteLayout.helpHeight, alignment: .leading)
                Spacer(minLength: 0)
                // The live readout sits with the palette, in SF Mono, so a
                // number that changes sixty times a second has ONE home on
                // screen and never re-lays the pane out as it grows a digit.
                if let dragReadout {
                    // UE-2 — ONE LINE, ALWAYS. A sound's readout is §1.7's
                    // sentence (~94 characters, ~560 pt), not "+100 cents". ⛔ It
                    // must never WRAP: a palette that grows a line on press
                    // shrinks the surface above it, and every row moves under
                    // the pointer mid-drag. So it takes its width FIRST
                    // (`layoutPriority`: the tool help, which says how to start
                    // a drag that has already started, truncates before it) and
                    // truncates at its tail only when even that is not enough.
                    Text(dragReadout)
                        .font(.system(size: PitchEditorPaletteLayout.readoutFontSize, weight: .semibold,
                                      design: .monospaced))
                        .foregroundStyle(readoutIsWarning ? DAWTheme.clip : DAWTheme.signal)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, PitchEditorPaletteLayout.horizontalPadding)
        .padding(.vertical, PitchEditorPaletteLayout.verticalPadding)
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
///
/// m23-ap I2 — **THE PINCH RIDES THE APP TOO**, with a SCALE and no step:
/// `timeScale` carries the scale a pinch tick asks for
/// (`PitchEditorPinch.tick`, the gesture-start scale × the cumulative
/// magnification) to `AppModel.setPitchEditorTimeScale`. Still no slot write
/// here, and still one funnel after it: the slot's `onChange` re-pins the
/// scroll for every driver alike.
enum PitchEditorZoomCommand: Sendable {
    case timeIn, timeOut, pitchIn, pitchOut, reset
    /// A continuous TIME scale (pixels per beat) — the pinch.
    case timeScale(CGFloat)
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
    /// UE-1 — "Find sounds with no pitch": the app's funnel to the store's
    /// merge verb (`AppModel.findUnpitchedSoundsFromEditor` →
    /// `ProjectStore.findUnpitchedSounds`, one "Find Sounds" undo step),
    /// answering with what the line should say. Offered only while
    /// `PitchEditorModel.offersFindSounds`; called only by `runFindSounds`,
    /// after the model said yes (`beginFindSounds`).
    var onFindSounds: @MainActor () async -> PitchEditorFindSoundsOutcome
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
    /// render is re-keyed per tick and never lands, so the transport plays a
    /// stale version of the vocal for the whole drag (its previous render, since
    /// p2-ren Stage A; silence after a stretch change or a failed render).
    var onCommitNoteEdit: (PitchEditorCommit) -> Void
    /// C4 — both axes. See `PitchEditorZoomCommand`.
    var onZoom: (PitchEditorZoomCommand) -> Void
    /// The spy seam (`p2-c`'s `debug.pitchEditor`). Optional so a preview and an
    /// offscreen harness stay one-liners.
    var chrome: PitchEditorChromeLedger?
    /// m23-ap p2-del — bumped by the app each time it swallows a DELETE key
    /// because this pane is open (`AppModel.pitchEditorDeleteKeyNonce`), so ⌫
    /// cannot delete the clip shown here. The pane answers by drawing the
    /// policy's hint on its own refusal line (`PitchEditorModel.refuseDeleteKey`).
    ///
    /// ⚠️ **THIS PANE DOES NOT HANDLE ⌫ ITSELF, AND MUST NOT** (design P6: keys
    /// route through app policies, never raw handlers; `DeleteKeySiteTests` pins
    /// exactly three `.onKeyPress` delete mounts). The DECISION is
    /// `DeleteMenuPolicy`'s; this is only the pane being told to explain it.
    ///
    /// Defaults to 0 so a preview and an offscreen harness stay one-liners. A
    /// value that never changes shows nothing: `.onChange` skips the initial
    /// value, so a pane rebuilt on a clip switch cannot inherit a stale hint.
    var deleteKeyHintNonce: Int
    /// m23-ap interaction batch I6a — ESCAPE on this pane, handed to the app's
    /// ONE Escape decision (`AppModel.handleEditorEscape`, wired by
    /// `ContentView`, exactly as the roll's `onEscape` is) through the model's
    /// I4 seam (`PitchEditorModel.handleEscapeKey`).
    ///
    /// ⭐ I4 — IT IS HANDED THE PANE'S TWO FACTS (is a gesture live, is anything
    /// selected) AND RETURNS THE LADDER'S RUNG (`EditorEscapeLadder`): the app
    /// resolves it once and applies `.exitMaximize` itself; the model applies
    /// the pane's own two rungs. Defaults to `.pass` ("not mine") so a preview
    /// and an offscreen harness stay one-liners.
    var onEscape: (_ gestureLive: Bool, _ hasSelection: Bool) -> EditorEscapeRung
    /// m23-ap interaction batch I0 — the pane's one channel to everything outside
    /// it (`PitchEditorInteractionBridge`, app-held): OUT, the surface it reports
    /// (where its scrollers are looking, the notes as drawn, the press in flight)
    /// for `debug.pitchEditor`; IN, the debug tier's staged steps and the Escape
    /// request, applied through the SAME callbacks a real event runs. Optional so
    /// a preview and an offscreen harness stay one-liners.
    var interaction: PitchEditorInteractionBridge?
    /// m23-ap I1 UI hooks — HEAR THE NOTE: every audition request the pane's
    /// model makes (a press, a drag step, a stop), handed to the app's router
    /// (`AppModel.routePitchEditorAudition`), which calls the store's doors with
    /// the switch as their `enabled:`.
    ///
    /// ⛔ **THE VIEW NEVER CALLS THIS**, for `onCommitNoteEdit`'s reason: it is
    /// installed on the model at mount and the model is its only caller, so
    /// `PitchEditorModelTests` counts the real cadence — one request per press,
    /// one per change of the drag's offset, never one per pointer tick.
    var onAudition: (PitchEditorAuditionRequest) -> Void
    /// The router's audition line (`PitchEditorAuditionRouter.line`): "Preparing
    /// your note…" while a release waits for its render, and the shortfalls
    /// (the wait ran out, the track is muted). Drawn on the state row.
    var auditionLine: PitchEditorLineCaption?
    /// m23-ap I5 — the app's snap IN FORCE (`AppModel.effectiveClipSnap`, the
    /// roll's own input): ON or OFF for the playhead's placement, whose division
    /// is the model's own 1/16 (`PitchEditorModel.placementGrid`). Kept current
    /// on the model as it changes.
    var appSnap: ClipSnap
    /// m23-ap I5 — PLACE THE PLAYHEAD: a project beat, snapped and clamped by the
    /// model (`PitchEditorModel.placementBeat`). The app installs
    /// `store.seek(toBeats:)`.
    ///
    /// ⛔ **THE VIEW NEVER CALLS THIS**, for `onCommitNoteEdit`'s reason: it is
    /// installed on the model at mount and the model is its only caller — the
    /// ruler's ticks call `model.placePlayhead`, a ⌘-click on empty surface
    /// reaches it through `model.releasePress` — so `PitchEditorModelTests`'
    /// seek spy counts the real cadence.
    var onSeek: (Double) -> Void
    /// m23-ap I5 — FOLLOW THE PLAYHEAD: the app-held runtime
    /// (`AppModel.pitchEditorFollow`, the `pianoRollFollow` twin) that survives
    /// this pane's `.id(clip.id)` rebuild, driven by the ONE persisted
    /// `layout.followPlayhead` flag. `nil` (a preview, a harness) follows nothing.
    var follow: FollowPlayheadModel?
    /// Whether the transport is playing — follow turns pages only then (m23-c2).
    var isPlaying: Bool
    /// m23-ap I5-F1 — the PROJECT's meter map (`transport.meterMap`), so the time
    /// ruler numbers the SONG's bars, the ones the transport and the arrange
    /// ruler count (`PitchEditorSongRuler`). `beatsPerBar` above stays for the
    /// off-clip cue's "N BARS" distance.
    var meterMap: MeterMap
    /// p2-ren Stage B″(c) — what the clip's node is playing right now
    /// (`ProjectStore.renderAudible`), polled by the app while this pane is open
    /// (`AppModel.pollPitchEditorRenderAudible`); `nil` when the engine cannot
    /// say. Only `.preview` draws anything (`PitchEditorRenderCaption`).
    var renderAudible: ClipRenderAudible?

    @State private var model: PitchEditorModel
    /// ⭐ THE O(frames) SNAPSHOT — the played line on screen, with the dragged
    /// note's stretch cut out while a drag is in flight. See
    /// `PitchEditorDrawContext`.
    @State private var playedSegments: [[CGPoint]] = []
    /// Where the pointer is, for the cut line. `nil` off the surface.
    @State private var hoverPoint: CGPoint?
    /// m23-ap I5 — whether ⌘ is down RIGHT NOW, for the playhead affordance (the
    /// `.verticalBar` cursor and the ghost line over empty surface). The hover
    /// reader and the cursor's tracking area are driven by pointer MOVEMENT, so
    /// neither sees a key press; the roll's `commandHeld`, for the same reason.
    @State private var commandHeld = false
    /// The `.flagsChanged` monitor behind `commandHeld`, alive ONLY while the
    /// pointer is over the surface. Three teardowns, the roll's (`flagsMonitor`):
    /// the pointer leaving, `.onDisappear`, and an idempotent start.
    @State private var flagsMonitor: Any?
    /// Key focus on the pane (I6a) — what makes its ESCAPE mount eligible at
    /// all. The roll's idiom exactly (`PianoRollView.isFocused`): focusable,
    /// asserted on appear, no focus ring.
    @FocusState private var isFocused: Bool
    /// I0 — WHERE THE SCROLLERS ARE LOOKING, as MEASURED by the four readers
    /// below: the offset per axis, the viewport per axis, the laid-out content.
    /// The value every zoom re-pin measures its old offset from, and the one the
    /// bridge echoes. Changes on a scroll, a resize or a zoom — never on a
    /// transport tick.
    @State private var viewport = PitchEditorViewport.unmeasured
    /// I0 — the offset the pane's WRITERS are asking for, with one nonce per axis
    /// so a repeat of the same target still applies (the roll's
    /// `followTargetX`/`followNonce` and `verticalTargetY`/`verticalNonce` pairs).
    @State private var scrollTarget = CGPoint.zero
    @State private var horizontalScrollNonce = 0
    @State private var verticalScrollNonce = 0
    /// m23-ap I2 — the live pinch's anchor, captured on its FIRST tick
    /// (`PitchEditorPinch.tick`) and cleared on its end; `nil` whenever no pinch
    /// is live. `repinTimeZoom` hands it to the ONE re-pin, so every scale change
    /// a pinch makes holds the beat that was under the pointer when it began.
    ///
    /// ⚠️ **A STALE ONE WOULD HIJACK EVERY LATER ZOOM, NOT ONLY THE NEXT PINCH.**
    /// `repinTimeZoom` serves all the drivers, so an anchor left behind by a
    /// `MagnifyGesture.onEnded` that never fired would also anchor the next
    /// button press or ⌘± on the old pointer. Cleared on `onDisappear` as well,
    /// and echoed as `debug.pitchEditor`'s `pinch.live` so it can be seen. The
    /// real fix is a gesture-generation token, shared with the roll's
    /// `zoomAnchorBase` (follow-up I2-F3), not a fork of the idiom here.
    @State private var pinchAnchor: PitchEditorZoomAnchor?
    /// m23-ap I6b — the LIVE pointer of the drag in flight, as the held repeat
    /// needs it: viewport-local, so each tick rebuilds the content point from
    /// the OBSERVED offset (`EdgeAutoScroll.HeldPoint`, never integrated), and
    /// when it last moved. Written ONLY by `liveDragChanged`, so a staged step
    /// can never leave a pointer for the clock to hold.
    @State private var heldEdgePoint: EdgeAutoScroll.HeldPoint?
    @State private var lastPointerEventAt: ContinuousClock.Instant?
    /// When this press's last edge step ran, for the growth's `dt`
    /// (`PitchEditorModel.edgeStepSeconds`). `nil` before its first.
    @State private var lastEdgeStepAt: ContinuousClock.Instant?
    /// The held-pointer repeat clock (the roll's m25-r shape): alive only while
    /// a live, travelled drag pushes. Three teardowns: `dragEnded`,
    /// `.onDisappear`, and an idempotent start.
    @State private var edgeRepeatTask: Task<Void, Never>?
    /// Identifies THIS pane instance to the bridge, so an outgoing pane's
    /// teardown cannot blank the incoming one's report on a clip switch (the
    /// roll's `reportToken`, for the race measured there).
    @State private var reportToken = UUID()

    private static let rulerWidth: CGFloat = 52
    /// I0 — the two scrollers' named coordinate spaces (the readers measure the
    /// content's leading edge in them) and the writers' marker ids.
    private static let horizontalScrollSpace = "pitchEditorHorizontalScroll"
    private static let verticalScrollSpace = "pitchEditorVerticalScroll"
    private static let horizontalMarkerID = "pitchEditorHorizontalScrollMarker"
    private static let verticalMarkerID = "pitchEditorVerticalScrollMarker"

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
         chrome: PitchEditorChromeLedger? = nil,
         deleteKeyHintNonce: Int = 0,
         onEscape: @escaping (_ gestureLive: Bool, _ hasSelection: Bool) -> EditorEscapeRung
             = { _, _ in .pass },
         interaction: PitchEditorInteractionBridge? = nil,
         onAudition: @escaping (PitchEditorAuditionRequest) -> Void = { _ in },
         auditionLine: PitchEditorLineCaption? = nil,
         appSnap: ClipSnap = .beat,
         onSeek: @escaping (Double) -> Void = { _ in },
         follow: FollowPlayheadModel? = nil,
         isPlaying: Bool = false,
         onFindSounds: @escaping @MainActor () async -> PitchEditorFindSoundsOutcome
             = { .refused("Finding sounds is not available here.") },
         // I5-F1 — NOT defaulted: a default would be a hard-coded 4/4 reaching
         // the ruler from any future call site with the compiler silent.
         meterMap: MeterMap,
         renderAudible: ClipRenderAudible? = nil) {
        self.clip = clip
        self.meterMap = meterMap
        self.renderAudible = renderAudible
        self.onFindSounds = onFindSounds
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
        self.deleteKeyHintNonce = deleteKeyHintNonce
        self.onEscape = onEscape
        self.interaction = interaction
        self.onAudition = onAudition
        self.auditionLine = auditionLine
        self.appSnap = appSnap
        self.onSeek = onSeek
        self.follow = follow
        self.isPlaying = isPlaying
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
        // I1 UI hooks — the AUDITION seam, installed the same way, once. See
        // `onAudition`.
        model.onAudition = onAudition
        // I5 — the SEEK seam and the snap it places with, installed the same
        // way, once. See `onSeek`.
        model.onSeek = onSeek
        model.appSnap = appSnap
        // UE-2 — the app-held memory of a Find-sounds DECLINE, so a pane rebuilt
        // on the same table shows the button WITH its last answer.
        model.findSoundsMemory = interaction?.findSoundsMemory
        _model = State(initialValue: model)
    }

    var body: some View {
        // B″(c) — one count per evaluation (the ledger is non-observable, so a
        // write here invalidates nothing).
        let _ = chrome?.countBodyEvaluation()
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DAWTheme.hairline)
            editorBody
            Divider().overlay(DAWTheme.hairline)
            palette
        }
        .background(DAWTheme.panel)
        // m23-ap interaction batch I6a — KEY FOCUS, so ESCAPE can reach this
        // pane: `.onKeyPress` runs only for the focused view or its ancestors,
        // and without focus the mount below would never fire. The roll's idiom
        // exactly (`PianoRollView`: `.focusable()`, `.focused`, asserted on
        // appear). `.focusEffectDisabled()`: no focus ring — the arrange scope
        // already disables it for this whole subtree (`ArrangeDeleteKey`); it is
        // said here too so the pane is right on its own (a harness, a preview).
        //
        // ⚠️ ⌫ IS NOT AFFECTED BY THIS FOCUS. The pane still claims no delete key
        // (`DeleteKeySiteTests` pins three claimants). ⌫ is answered by the app's
        // `NSEvent` monitor (`AppModel.handleKeyDownEvent` →
        // `DeleteKeyMonitorRouting` → `handleDeleteKey` → the `.pitchEditorOpen`
        // refusal and this pane's hint), which treats only a TEXT responder as
        // typing — the same classification under which ⌫ deletes notes while the
        // equally focusable roll holds focus (m23-cf-3).
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // ESCAPE (I6a) → the model's I4 seam → the app's ONE decision
        // (`AppModel.handleEditorEscape`: leave the maximized mode). `.ignored`
        // unless that decision consumed it, so outside the mode the pane claims
        // nothing new and Escape propagates exactly as before — the roll's rule.
        //
        // ⚠️ m34-k (LANDED): this mount rides SwiftUI focus, and that route was
        // MEASURED latched dead after any text field is dismissed (a track or
        // marker rename) until a clip is clicked. So the app's key monitor now
        // hands Escape to this pane through `interaction.escapeNonce` (the
        // watcher below) whenever the pane has something to take down, and
        // swallows it — this mount sees only an Escape the monitor passed on,
        // and asks the same ladder, so the two cannot double-fire. The first
        // statement is this mount's own delivery counter: it stays FLAT for a
        // monitor-routed press, which is how a probe tells the routes apart.
        .onKeyPress(.escape) {
            chrome?.recordEscapeMountHit()
            return model.handleEscapeKey(appDecision: onEscape) ? .handled : .ignored
        }
        .onAppear { isFocused = true }
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
        // ⭐⭐ I0 — AND THE NO-JUMP RULE RIDES HERE, ON THE SLOT'S CHANGE, NOT ON
        // ITS DRIVERS (the roll's m25-b-3 funnel): the zoom buttons, ⌘+/⌘−/⌘0,
        // `debug.panelLayout` and the pinch (I2, via `onZoom(.timeScale)`) all
        // write this ONE slot, so the change is the only event they share and
        // no driver can forget the re-pin. Before I0 the scale changed under an
        // offset that stayed put in points, and the view jumped about the
        // clip's start.
        .onChange(of: layout.pitchEditorPPB) { oldPPB, ppb in
            model.geometry.pixelsPerBeat = ppb
            repinTimeZoom(oldPPB: oldPPB, newPPB: ppb)
        }
        // C4's other axis. One slot, read here, and the ruler sidebar reads the
        // SAME geometry — so the two columns cannot drift a fraction of a row.
        // I0: its own re-pin, holding the centre row — a row height moves no
        // beat→x mapping, so the two funnels never recompute each other's axis.
        // I6c: the model re-fills the pitch window for the new row height
        // FIRST, so the re-pin clamps against the new content, and it is handed
        // the old window because the fill can move the window's top.
        .onChange(of: layout.pitchEditorRowHeight) { oldHeight, height in
            let oldWindow = model.geometry.midiRange
            model.setRowHeight(height)
            repinRowZoom(oldRowHeight: oldHeight, newRowHeight: height, oldMidiRange: oldWindow)
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
        // m23-ap p2-del — the app swallowed a ⌫ because this pane is open; say
        // why, on the palette's refusal line (the `PanelRefusalLine` slot every
        // refusal in this pane already uses). The ledger picks the words up
        // through `.onChange(of: model.refusal)` below, so `debug.pitchEditor`'s
        // `refusalText` shows what was drawn.
        .onChange(of: deleteKeyHintNonce) { _, _ in
            model.refuseDeleteKey()
        }
        // ⚠️ `DragGesture.onEnded` DOES NOT FIRE when the window resigns key or
        // the pane is torn down. A draft left behind would become a phantom
        // baseline for the next gesture on the next clip.
        .onDisappear { model.cancelDrag() }
        // I2 — `MagnifyGesture.onEnded` is no more guaranteed than the drag's,
        // and an anchor left behind would steer every later zoom (see
        // `pinchAnchor`). Its own modifier: the line above is pinned verbatim.
        .onDisappear { pinchEnded() }
        // I5 — a hover exit is not guaranteed when the pane is torn down under
        // the pointer (a clip switch rebuilds it), so the ⌘ monitor goes here too.
        .onDisappear { stopFlagsMonitor() }
        // I6b — teardown 2 of 3: a clip switch rebuilds the pane with no
        // guaranteed `onEnded`, and a clock must not outlive its pane.
        .onDisappear { stopEdgeRepeat() }
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
        .onChange(of: model.geometry) { _, _ in
            refreshPlayedSegments()
            reportSurface()   // I0 — the notes as drawn moved with it
        }
        .onChange(of: model.drag?.movingSegmentIDs) { _, _ in refreshPlayedSegments() }
        // C5a-4b — the Wobble tool's two view hooks (one modifier, so this
        // chain stays inside what the type checker can solve).
        .modifier(PitchEditorWobbleWiring(model: model, chrome: chrome, token: reportToken,
                                          refreshPlayedSegments: { refreshPlayedSegments() }))
        // C5b-4b — the brush's view hook, the same way.
        .modifier(PitchEditorBrushWiring(model: model, refreshPlayedSegments: { refreshPlayedSegments() }))
        .onAppear { recordPlayedLine() }
        .onChange(of: model.state) { _, _ in recordPlayedLine() }
        // m23-ap interaction batch I0 — the bridge, both directions.
        // OUT: the surface as measured and drawn, on exactly the events that
        // move it (a scroll/resize/zoom through the readers, the notes changing).
        .onChange(of: viewport) { _, _ in reportSurface() }
        .onChange(of: model.blobs) { _, _ in reportSurface() }
        // I2 — a pinch's START and END move nothing else the report watches
        // (a real `onEnded` changes only the anchor), and `pinch.live` must not
        // read a pinch that is over.
        .onChange(of: pinchAnchor) { _, _ in reportSurface() }
        .onAppear { reportSurface() }
        // Token-guarded: a clip switch's teardown cannot blank the incoming
        // pane's report (the roll's measured race, `clearSurface(from:)`).
        .onDisappear { interaction?.clearSurface(from: reportToken) }
        // IN: a staged step, applied through the same callbacks a real event
        // runs, then acknowledged; and the Escape request. Neither carries
        // `initial:`, so a pane that appears later never replays an old one.
        .onChange(of: interaction?.stageNonce) { _, _ in applyStagedStep() }
        .onChange(of: interaction?.escapeNonce) { _, _ in
            // The pane's own Escape path — the model's I4 seam, then the app's
            // one decision — exactly as the key mount runs it, minus the
            // mount's delivery counter (that measures the SwiftUI route). Two
            // producers: the debug tier's `escape` act and, since m34-k, the
            // app's KEY MONITOR — the route a real Escape takes when this pane
            // has something to take down.
            _ = model.handleEscapeKey(appDecision: onEscape)
        }
        // m23-ap I4 — the selection, both directions (one modifier, so this
        // chain stays inside what the type checker can solve).
        .modifier(PitchEditorSelectionWiring(model: model, interaction: interaction,
                                             reportSurface: { reportSurface() }))
        // m23-ap I1 UI hooks (H5) — the pane going away and the switch turning
        // off stop a sounding note audition.
        .modifier(PitchEditorAuditionWiring(model: model, auditionEnabled: layout.auditionEnabled))
    }

    // MARK: I0 — the bridge (interaction batch §3 item 6)

    /// Everything the pane reports about its surface — MEASURED (`viewport`,
    /// from the readers) or DRAWN (`noteRects`: the very `rect(for:)` the Canvas
    /// fills), never a re-derivation. Built only when reported, never in `body`.
    private var surfaceReport: PitchEditorSurfaceReport {
        PitchEditorSurfaceReport(
            viewport: viewport,
            // I7b — each note's clear and level beside its rect, from the
            // SAME blob the Canvas drew it from.
            // UE-1 — and its ORIGIN (a sound is `unpitched`) and the sentence
            // a sound prints instead of cents, from that same blob.
            // UE-2 — and the LOOK the Canvas switches on (`NoteBlob.look`).
            noteRects: model.blobs.map {
                PitchEditorNoteRect(id: $0.id, rect: model.rect(for: $0),
                                    cleared: $0.isCleared, levelDb: $0.amplitudeDb,
                                    levelReadout: $0.levelReadout,
                                    origin: $0.origin.rawValue,
                                    soundReadout: $0.soundReadout,
                                    look: $0.look.rawValue)
            },
            press: model.press.current,
            lastRelease: model.lastRelease,
            // I4 — the model's OWN selection and band, never re-derived.
            selection: PitchEditorSelectionReport(ids: model.selection,
                                                  token: model.selectionToken,
                                                  summary: model.selectionSummary),
            band: model.band.map { PitchEditorBandReport(rect: $0.rect, hits: $0.hits,
                                                         additive: $0.additive) },
            // I7b — the right-click menu as it would open at the hover point,
            // from the one call the menu itself is built from.
            noteMenu: model.noteMenu(at: hoverPoint),
            // I6c — the pitch window as laid out, and the notes' own window it
            // was filled from, straight from the model.
            pitchWindow: PitchEditorWindowReport(laidOut: model.geometry.midiRange,
                                                 fitted: model.fittedMidiRange,
                                                 rowHeight: model.geometry.rowHeight,
                                                 availableHeight: model.availableHeight),
            // I2 — the very anchor the re-pin is handed, never re-derived.
            pinchAnchor: pinchAnchor,
            // I5 — the geometry the playhead is drawn through, and what the
            // model last ASKED the transport for, straight from the model.
            geometry: model.geometry,
            placementCount: model.placementCount,
            lastPlacementBeat: model.lastPlacementBeat,
            // I6b — the clock, the growth and the last edge, and the dragged
            // note where the overlay draws it (the overlay's own call).
            autoscroll: PitchEditorAutoScrollReport(
                armed: edgeRepeatTask != nil,
                grownRows: model.edgeGrownRows,
                lastSide: model.lastEdge,
                dragRect: model.drag.map {
                    model.geometry.rect(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                                        centreMidi: $0.targetMidi)
                }),
            // UE-1 — "Find sounds with no pitch" as the header draws it: the
            // model's own offer and line, never re-derived.
            findSounds: PitchEditorFindSoundsReport(offered: model.offersFindSounds,
                                                    line: model.findSoundsLine))
    }

    private func reportSurface() {
        interaction?.reportSurface(token: reportToken, surfaceReport)
    }

    /// ONE staged step from the debug tier (`debug.pitchEditor {act:…}`), run
    /// through the SAME code a real event runs — the hover reader's write, the
    /// drag gesture's two callbacks, the palette's action, the writers — then
    /// acknowledged with the surface it left (the m23-e echo-seam law: the seam
    /// answers only after the step went THROUGH the view).
    ///
    /// ⚠️ A staged `drag`/`release` continues the staged PRESS: it is handed
    /// that press's own origin as its start, which is what a live
    /// `DragGesture` does (`startLocation` is fixed for a gesture's life). With
    /// no press in flight it does nothing — the debug handler refuses that
    /// shape before it gets here, so this guard is the second line, not the
    /// first.
    private func applyStagedStep() {
        guard let interaction, let step = interaction.stagedStep else { return }
        switch step {
        case .hover(let point):
            hoverPoint = point
        case .hoverEnd:
            hoverPoint = nil
        case .press(let point, let chord):
            dragChanged(start: point, location: point, chord: chord)
        case .drag(let point, let chord):
            if let origin = model.press.current?.origin {
                dragChanged(start: origin, location: point, chord: chord)
            }
        case .release(let point, let chord):
            if let origin = model.press.current?.origin {
                dragEnded(start: origin, location: point, chord: chord)
            }
        case .tool(let tool):
            selectTool(tool)
        case .scroll(let x, let y):
            scroll(toX: x, y: y)
        case .noteMenu(let action, let point):
            // I7b — the right-click menu's OWN function: a synthetic event
            // cannot open a context menu (m23-g1), so the debug tier runs what
            // the chosen item runs.
            runNoteMenu(action, at: point)
        case .pinch(let startLocation, let magnification):
            // I2 — the `MagnifyGesture`'s own two functions: a synthetic event
            // cannot reach a gesture either (m23-g1).
            pinchChanged(startLocation: startLocation, magnification: magnification)
        case .pinchEnd:
            pinchEnded()
        case .ruler(let x, let chord):
            // I5 — the time ruler's OWN tick function, with the ruler-local x a
            // real tick carries: the scroll offset is added inside it, once.
            rulerTick(x: x, option: chord.option)
        case .findSounds:
            // UE-1 — the header button's OWN function: a synthetic event
            // cannot press a button either (m23-g1).
            runFindSounds()
        case .keys(let chord):
            // C5b-4b — what the `.flagsChanged` monitor writes, from a step:
            // a synthetic step carries no `NSEvent.modifierFlags`.
            commandHeld = chord.command
        case .singer(let act):
            // W7-NTU U1 — the header group's OWN function (`runSinger`), the
            // one its controls' callbacks call: a synthetic event cannot press
            // a SwiftUI control (m23-g1).
            runSinger(act)
        }
        interaction.acknowledgeStage(token: reportToken, surfaceReport)
    }

    // MARK: I0 — the viewport: readers, writers, re-pin (interaction batch §3 items 2–4)

    /// The HORIZONTAL reader — the roll's `gridScrollReader` idiom: a background
    /// of the surface's content (never hit-tested) that reads the content's
    /// leading x in the horizontal scroller's named space (its negation is the
    /// live offset) and the content's laid-out size. Writes only on change.
    private var horizontalScrollReader: some View {
        GeometryReader { geo in
            let leadingX = geo.frame(in: .named(Self.horizontalScrollSpace)).minX
            let size = geo.size
            Color.clear
                .onChange(of: leadingX, initial: true) { _, newValue in
                    viewport.offset.x = -newValue
                    // I5 — ground truth for follow, the roll's `gridScrollReader`
                    // rule: the ONLY place this pane learns where its scroller
                    // sits, so it is where a MANUAL scroll is detected.
                    // `followDrives`, not the raw flag: off-clip, or with a pinch
                    // owning the scroll, follow issues nothing and must not blame
                    // the user (or the pinch) for moving it.
                    follow?.reportOffset(-newValue, isEnabled: followDrives,
                                         isPlaying: isPlaying,
                                         contentWidth: model.geometry.contentWidth,
                                         viewportWidth: viewport.viewportSize.width)
                }
                .onChange(of: size, initial: true) { _, newValue in
                    viewport.contentSize = newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// The VERTICAL reader — the same idiom on the pitch axis (the roll's
    /// `editorVerticalScrollReader`): a background of the vertical scroller's
    /// content, reading its top y in that scroller's named space.
    private var verticalScrollReader: some View {
        GeometryReader { geo in
            let topY = geo.frame(in: .named(Self.verticalScrollSpace)).minY
            Color.clear
                .onChange(of: topY, initial: true) { _, newValue in
                    viewport.offset.y = -newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// The horizontal scroller's VISIBLE width — a background of the scroller
    /// itself, outside its content, so this is the box and not the clip.
    private var horizontalViewportReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width, initial: true) { _, newValue in
                    viewport.viewportSize.width = newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// The vertical scroller's VISIBLE height, read the same way (the roll's
    /// `editorHeightReader`).
    ///
    /// m23-ap I6c: it is also the height the pitch window is FILLED to. The
    /// model grows the window by whole rows to use it (`PitchEditorRange.filled`),
    /// so a maximized or tall pane has no dead band under its grid. No layout
    /// loop: this scroller's height comes from the pane's own frame minus the
    /// header and palette, never from its content.
    private var verticalViewportReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.height, initial: true) { _, newValue in
                    viewport.viewportSize.height = newValue
                    model.setAvailableHeight(newValue)
                }
        }
        .allowsHitTesting(false)
    }

    /// The HORIZONTAL writer's anchor — the roll's `followMarker` idiom: a 1 pt,
    /// layout-real, hit-inert marker whose LEADING edge sits at `scrollTarget.x`,
    /// so `scrollTo(…, anchor: .leading)` lands the viewport's edge exactly on it.
    /// Real frames, never `.offset`: `scrollTo` reads a true layout position.
    private var horizontalMarker: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: max(0, scrollTarget.x), height: 1)
            Color.clear.frame(width: 1, height: 1).id(Self.horizontalMarkerID)
        }
        .allowsHitTesting(false)
    }

    /// The VERTICAL writer's anchor, whose TOP edge sits at `scrollTarget.y`.
    ///
    /// ⚠️⚠️ **MOUNTED ON THE PITCH RULER, AND THAT PLACEMENT IS THE SAFETY
    /// ARGUMENT** (the roll's `verticalJumpMarker`, on its keyboard gutter). The
    /// vertical `ScrollViewReader` must wrap BOTH scrollers (the horizontal one is
    /// inside the vertical one), and a reader resolves `scrollTo` against every
    /// scroll view in it that can see the id. The ruler is a SIBLING of the
    /// horizontal scroller, so only the vertical scroller resolves this id — and
    /// being vertical-only, it has no x for the `.top` anchor's 0.5 to disturb.
    /// It never exceeds the ruler's height because every writer clamps
    /// (`PitchEditorViewport.clamped`, and the re-pins clamp to the NEW content).
    private var verticalMarker: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 1, height: max(0, scrollTarget.y))
            Color.clear.frame(width: 1, height: 1).id(Self.verticalMarkerID)
        }
        .allowsHitTesting(false)
    }

    /// THE WRITERS' one entry for a plain scroll (the staged `scroll` step):
    /// either axis, clamped to where the content can actually go, one nonce per
    /// axis that was asked. The zoom re-pins below set their targets
    /// themselves, because they clamp against the NEW content, which the
    /// measured `viewport` has not seen yet.
    private func scroll(toX x: CGFloat?, y: CGFloat?) {
        let target = viewport.clamped(CGPoint(x: x ?? viewport.offset.x, y: y ?? viewport.offset.y))
        if x != nil {
            scrollTarget.x = target.x
            horizontalScrollNonce &+= 1
        }
        if y != nil {
            scrollTarget.y = target.y
            verticalScrollNonce &+= 1
        }
    }

    /// THE NO-JUMP RULE ON THE TIME AXIS. Anchor: a live pinch's POINTER (I2),
    /// else the playhead if it is inside this clip and in frame, else the
    /// viewport centre — measured at the OLD scale INSIDE
    /// `PitchEditorViewport.timeZoomOffset`, whatever scale the geometry handed
    /// in already carries (its doc names the trap).
    ///
    /// No re-pin, no write: an unchanged scale, an unmeasured viewport, and —
    /// I0-F — a new content that FITS the viewport (one position, and a
    /// `scrollTo` there is what left the horizontal reader stale).
    private func repinTimeZoom(oldPPB: CGFloat, newPPB: CGFloat) {
        guard let x = viewport.timeZoomOffset(
            geometry: model.geometry, oldPPB: oldPPB, newPPB: newPPB,
            playheadProjectBeat: positionBeats,
            // I2 — the pinch's gesture-start anchor (`PitchEditorZoomAnchor`,
            // captured from `startLocation` on its first tick), so the whole
            // pinch holds the POINTER's beat. `nil` for every other driver.
            pointerAnchor: pinchAnchor) else { return }
        scrollTarget.x = x
        horizontalScrollNonce &+= 1
    }

    // MARK: I2 — the pinch (interaction batch §5)

    /// ONE pinch tick — the `MagnifyGesture`'s `onChanged` and the debug tier's
    /// staged `pinch` step both land here, so the staged gate drives the same
    /// code a trackpad does.
    ///
    /// It asks the APP for a scale and nothing else (`onZoom(.timeScale)`): the
    /// slot's `onChange` → `repinTimeZoom` → `pinchAnchor` issues the offset,
    /// the one writer of the scroll for every driver (`PianoRollView.gridPinch`'s
    /// rule; an earlier sketch there had the pinch scroll too, and the two
    /// writers raced).
    ///
    /// ⚠️ `startLocation` IS CONTENT SPACE — the gesture hangs on the surface
    /// inside the horizontal scroller, the space the drag and the hover report
    /// in — and it is frozen at gesture start, which is the second reason the
    /// anchor is captured once (`PitchEditorPinch.tick`).
    ///
    /// ⚠️ **TWO RESIDUALS, INHERITED FROM THE ROLL AND NAMED THERE**
    /// (`PianoRollView.gridPinch`): the LAST tick's scale change may reach the
    /// slot's `onChange` after `pinchEnded` cleared the anchor, and that one
    /// tick then anchors on the playhead/centre — bounded by one magnification
    /// step; and a DROPPED `onEnded` leaves a stale anchor (see `pinchAnchor`).
    /// A two-finger PAN during a pinch is overridden by the re-pin for the
    /// gesture's life, as on the roll.
    private func pinchChanged(startLocation: CGPoint, magnification: CGFloat) {
        onEngage()   // m23-al — ⌘+/⌘−/⌘0 follow the pinch to this pane
        // No zoom while a press, a note drag or a band is live: a zoom
        // mid-press moves what is under the press, and the router decided
        // what the press is at its first tick (a delegated default).
        guard model.press.current == nil else { return }
        let tick = PitchEditorPinch.tick(anchor: pinchAnchor, viewport: viewport,
                                         startLocation: startLocation,
                                         currentPPB: layout.pitchEditorPPB,
                                         magnification: magnification)
        pinchAnchor = tick.anchor
        onZoom(.timeScale(tick.ppb))
    }

    /// The pinch ended (or the pane went away): the next pinch captures afresh,
    /// and the other zoom drivers anchor on the playhead/centre again.
    private func pinchEnded() {
        pinchAnchor = nil
    }

    // MARK: I5 — the time ruler (interaction batch §8)

    /// ONE tick of the time ruler — its drag's `onChanged` (click jumps, drag
    /// scrubs) and the debug tier's staged `ruler` step both land here.
    ///
    /// ⚠️⚠️ **THE ONE PLACE THE SCROLL OFFSET MEETS A PLAYHEAD PLACEMENT.** The
    /// ruler is a sibling row ABOVE the scrollers and does not scroll, so its x
    /// is VIEWPORT space; the model's producer takes CONTENT space, and the
    /// offset is added here and nowhere else. The ⌘-click on the surface is
    /// already content space and adds nothing (the roll's `scrubDrag` warning,
    /// one surface over). The view never calls `onSeek`: the model seeks.
    ///
    /// The offset is `shownOffsetX` — the SAME value the ruler row draws with —
    /// never the raw measured `offset.x`, which can hold a position the
    /// scroller is not at (that property's warning: measured, a click landed 28
    /// beats late).
    private func rulerTick(x: CGFloat, option: Bool) {
        onEngage()   // m23-al — placing the playhead here engages this pane
        model.placePlayhead(atContentX: x + viewport.shownOffsetX, snapBypassed: option)
        reportSurface()
    }

    // MARK: I5 — follow the playhead (interaction batch §8, design risk 9)

    /// The playhead's CONTENT x, or `nil` when the transport sits outside this
    /// clip (no line is drawn there; `OffClipEdgeCue` says which way it went) —
    /// through the geometry's one beat→x mapping, the one the line is drawn with.
    private var followLineX: CGFloat? {
        model.geometry.isInsideClip(projectBeat: positionBeats)
            ? model.geometry.x(forProjectBeat: positionBeats) : nil
    }

    /// Whether follow is actually DRIVING this pane now: the ONE flag, a line to
    /// keep in frame, and NO PINCH LIVE. ⭐ Design risk 9 — zoom and follow must
    /// not fight over the scroll: while a pinch is live its re-pin owns the
    /// offset (I2), so follow stands down for the gesture's life, and because the
    /// manual-scroll detector reads this same predicate, the pinch's own scrolls
    /// re-baseline it rather than suspending follow as if the user had dragged.
    private var followDrives: Bool {
        layout.followPlayhead && followLineX != nil && pinchAnchor == nil
    }

    /// One transport tick's follow — the THIRD writer of `scrollTarget.x`, beside
    /// `scroll(toX:y:)` and the zoom re-pin. They cannot interleave: the re-pin
    /// runs on the scale's change, follow on the transport's, and follow issues
    /// nothing while a pinch owns the scroll (`followDrives`) or when the page
    /// has not turned (`FollowPlayhead.pageOffset`'s nil). A zoom during
    /// playback re-baselines the detector through the geometry change, never
    /// suspends it.
    private func followTick() {
        guard let follow, let lineX = followLineX else { return }
        guard let target = follow.target(
            isEnabled: followDrives, isPlaying: isPlaying, playheadX: lineX,
            viewportWidth: viewport.viewportSize.width,
            contentWidth: model.geometry.contentWidth,
            currentOffset: viewport.offset.x) else { return }
        scrollTarget.x = target
        horizontalScrollNonce &+= 1
    }

    // MARK: I5 — the ⌘ affordance (interaction batch §8)

    /// The ghost line: where a ⌘-click at the pointer would put the playhead —
    /// the model's `placesPlayhead` (the router's and the click table's own
    /// answer) and its ONE placement producer, so the line sits exactly where the
    /// click will seek. `commandHeld` is tested FIRST, the roll's short-circuit:
    /// this runs on every transport tick, and the hit test behind
    /// `placesPlayhead` is not free.
    @ViewBuilder
    private func playheadGhost(height: CGFloat) -> some View {
        if commandHeld, model.press.current == nil, let point = hoverPoint,
           model.placesPlayhead(at: point, modifiers: [.command]) {
            let beat = model.placementBeat(atContentX: point.x,
                                           snapBypassed: NSEvent.modifierFlags.contains(.option))
            Rectangle()
                .fill(DAWTheme.textSecondary.opacity(0.35))
                .frame(width: 1, height: height)
                .offset(x: model.geometry.x(forProjectBeat: beat))
                .allowsHitTesting(false)
        }
    }

    /// The roll's `startFlagsMonitor`, including its first line: entering the
    /// surface with ⌘ ALREADY down produces no `.flagsChanged` event, so the
    /// current flags are read at start.
    private func startFlagsMonitor() {
        commandHeld = NSEvent.modifierFlags.contains(.command)
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            commandHeld = event.modifierFlags.contains(.command)
            return event
        }
    }

    /// Removes the monitor and drops the affordance; safe with none installed.
    private func stopFlagsMonitor() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        commandHeld = false
    }

    /// THE NO-JUMP RULE ON THE PITCH AXIS: the centre row holds, clamped to this
    /// pane's own NEW content height (`PitchEditorViewport.rowZoomOffset` says
    /// why that is not the roll's function).
    private func repinRowZoom(oldRowHeight: CGFloat, newRowHeight: CGFloat,
                              oldMidiRange: ClosedRange<Double>) {
        guard let y = viewport.rowZoomOffset(geometry: model.geometry,
                                             oldRowHeight: oldRowHeight,
                                             newRowHeight: newRowHeight,
                                             oldMidiRange: oldMidiRange) else { return }
        scrollTarget.y = y
        verticalScrollNonce &+= 1
    }

    private func refreshPlayedSegments() {
        // I4 — every moving note's stretch leaves the surface (one span for a
        // one-note drag, where this is `playedLineSegments(excluding:)` verbatim).
        playedSegments = model.playedLineSegments(excludingAll: model.draftSpans)
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
        // C5a-4b — the Wobble tool's line: the press in flight's, else the
        // dot's note's (hover, or the note a dot click just stepped). ONE call,
        // shared with the surface's dot (`wobbleDot`) and the ledger.
        let dot = model.wobbleDot(at: wobbleHover)
        let wobbleReadout = model.wobbleReadout(dot: dot)
        // C5b-4b — the brush's band, and the help that goes with it: ONE
        // answer each, shared with the surface and the ledger.
        let band = model.brushBand(at: hoverPoint, commandHeld: commandHeld)
        let help = model.paletteHelp(commandHeld: commandHeld, band: band)
        // W7-NTU U3 — the Voice tool's line: the press in flight's note, else
        // the note under the pointer. ONE call, shared with the ledger.
        let voiceReadout = model.voiceReadout(hover: hoverPoint)
        // …and the marks the surface draws, so the ledger re-reports them when
        // the STORE hands a Voice back after a release (the draft is gone by
        // then, and the line may not change).
        let voiceMarks = model.voiceMarks
        let readout = model.drag?.readout ?? model.brush?.readout ?? voiceReadout ?? wobbleReadout?.text
        let refusal = model.refusal
        // C-0 — the SAME value `recordPlayedLine` reports to the ledger.
        let lineCaption = model.lineCaption
        // W7-NTU §1(f) item 4 — ONE call, shared with the ledger.
        let farMoveHint = model.farMoveHint(formantPreserve: clip.formantPreserve)
        PitchEditorToolPalette(
            tool: tool,
            help: help,
            dragReadout: readout,
            readoutIsWarning: model.drag == nil && model.brush == nil && wobbleReadout?.isWarning == true,
            refusal: refusal,
            lineCaption: lineCaption,
            farMoveHint: farMoveHint,
            onSelect: { chosen in selectTool(chosen) })
            .onAppear { recordInteraction() }
            .onChange(of: model.tool) { _, _ in recordInteraction() }
            .onChange(of: model.drag) { _, _ in recordInteraction() }
            .onChange(of: model.refusal) { _, _ in recordInteraction() }
            .onChange(of: model.commitCount) { _, _ in recordInteraction() }
            // C5a-4b — a wobble tick, and the dot or its tip changing under the
            // pointer, move what this slot says: report them, or the echo
            // answers with the previous step's words.
            .onChange(of: model.wobble) { _, _ in recordInteraction() }
            .onChange(of: dot) { _, _ in recordInteraction() }
            // C5b-4b — a stroke tick, the band following the pointer, and the
            // help turning over with ⌘ move what the palette says: report them.
            .onChange(of: model.brush) { _, _ in recordInteraction() }
            .onChange(of: band) { _, _ in recordInteraction() }
            .onChange(of: help) { _, _ in recordInteraction() }
            // W7-NTU U3 — a Voice tick, and the note under the pointer
            // changing, move what this slot says: report them.
            .onChange(of: model.voiceDrag) { _, _ in recordInteraction() }
            .onChange(of: voiceReadout) { _, _ in recordInteraction() }
            .onChange(of: voiceMarks) { _, _ in recordInteraction() }
            // W7-NTU §1(f) item 4 — the hint comes and goes with the STORED
            // table (a read-back, an undo, the voice-size amount), not with a
            // gesture: report it when it changes.
            .onChange(of: farMoveHint) { _, _ in recordInteraction() }
    }

    /// C5a-4b × C5b-4b — the point the Wobble tool's DOT answers to: the hover,
    /// except while ⌘ is held, when a press on the note (dot included) is the
    /// BRUSH (`PitchEditorGestureRouter`) and a dot promising a wobble step
    /// would lie. The palette, the surface and the ledger all read it.
    private var wobbleHover: CGPoint? { commandHeld ? nil : hoverPoint }

    /// ⚠️ **`dragReadout` IS "" WHEN THERE IS NO DRAG AND NEVER "+0 cents".**
    /// Those are different facts: the second would be a claim that a note moved
    /// by an amount `PitchEditorReadout`'s ±12.90-cent floor says nobody can
    /// measure.
    ///
    /// C5a-4b — the Wobble tool's slot, dot and press ride the same report, from
    /// the same two calls the palette and the surface draw with.
    private func recordInteraction() {
        let dot = model.wobbleDot(at: wobbleHover)
        let wobbleReadout = model.wobbleReadout(dot: dot)
        // C5b-4b — the band and the help, from the SAME two calls the palette
        // and the surface draw with.
        let band = model.brushBand(at: hoverPoint, commandHeld: commandHeld)
        let paletteHelp = model.paletteHelp(commandHeld: commandHeld, band: band)
        // W7-NTU U3 — the Voice line and marks, from the SAME calls the
        // palette and the surface draw with.
        let voiceReadout = model.voiceReadout(hover: hoverPoint)
        chrome?.recordWobble(dot: dot, draft: model.wobble, readout: wobbleReadout)
        chrome?.recordBrush(band: band, draft: model.brush, commandHeld: commandHeld)
        chrome?.recordVoice(marks: model.voiceMarks, draft: model.voiceDrag, readout: voiceReadout)
        chrome?.recordInteraction(
            toolKey: model.tool.rawValue,
            paletteLabels: PitchEditorTool.allCases.map(\.label),
            toolHelp: paletteHelp,
            dragReadout: model.drag?.readout ?? model.brush?.readout ?? voiceReadout
                ?? wobbleReadout?.text ?? "",
            refusalText: model.refusal ?? "",
            farMoveHint: model.farMoveHint(formantPreserve: clip.formantPreserve) ?? "",
            commitCount: model.commitCount)
    }

    // MARK: The gestures (m23-ap C1 + C3)

    /// ⛔⛔ **NOTHING IN HERE COMMITS.** The model owns the cadence (§8.2): a
    /// tick updates a draft, and only `endPitchDrag`/`splitNote` can emit. This
    /// function existing without a single store call is the point of it.
    ///
    /// I0 — **WHAT THE PRESS IS, IS DECIDED ONCE** (design §3 item 5): the model's
    /// tracker asks `PitchEditorGestureRouter` on the gesture's first tick and
    /// never again, so nothing that moves under the press point mid-gesture (a
    /// zoom, a table read-back) can turn it into something else. `start` and
    /// `location` are the gesture's CONTENT-space points (`DragGesture.Value
    /// .startLocation`/`.location`), which is what lets a staged step drive this
    /// exact code with coordinates and no `DragGesture.Value`.
    private func dragChanged(start: CGPoint, location: CGPoint, chord: PitchEditorChord) {
        let tick = model.trackPress(start: start, location: location,
                                    modifiers: chord.clickModifiers)
        if tick.isFirst {
            onEngage()
            reportSurface()
            lastEdgeStepAt = nil   // I6b — a new press measures its own dt
        }
        // A press on a note becomes a PITCH DRAG only once it has travelled
        // `PitchEditorGestureRouter.slop`. Released inside it, the press is a
        // CLICK (`dragEnded`), and a click must not retune the note — before I0
        // the drag began at mouse-down, so a click on a note sung off the grid
        // snapped it to the nearest semitone and committed that.
        //
        // I4 — and it drags the SELECTION: an unselected note is selected first
        // (alone, or added with ⇧/⌘ held at the press), and every other selected
        // note rides along at the same delta. A lone selected note is the
        // one-note drag, unchanged. A travelled press on EMPTY surface is a band,
        // which the model's `trackPress` above already drew and applied.
        if tick.didPromote, case .noteDrag(let id) = tick.kind,
           let blob = model.blobs.first(where: { $0.id == id }) {
            model.beginSelectionPitchDrag(on: blob)
            reportSurface()
        }
        // C5a-4b — THE WOBBLE TOOL. The model began its session on the first
        // tick (or refused and abandoned the press); every tick hands it the
        // whole translation from the PRESS and ⌥ as held now, and it does
        // nothing until the press is past the slop — so a dot click steps from
        // the stored note, and the slop costs a drag nothing.
        if model.wobble != nil {
            model.updateWobbleDrag(translation: CGSize(width: location.x - start.x,
                                                       height: location.y - start.y),
                                   fine: chord.option)
        }
        // W7-NTU U3 — THE VOICE TOOL, the Wobble tool's shape: the model began
        // the draft on the first tick (or refused a sound and abandoned the
        // press); every tick hands it the whole vertical travel from the PRESS
        // and ⌥ as held now, and it does nothing until the press is past the
        // slop, so a click and a double-click leave the value alone.
        if model.voiceDrag != nil {
            model.updateVoiceDrag(translationHeight: Double(location.y - start.y), fine: chord.option)
        }
        // I6b — THE EDGE, per event (and per held tick, which comes through
        // here): scroll, or grow the window at the wall. BEFORE the pitch update
        // so this event's update reads the grown window. A band is driven by
        // `trackPress` above and pushes here too; nothing else does.
        applyEdgeStep(at: location)
        guard model.drag != nil else { return }
        // ⌥ = free movement, no snap (§7.3 C1). Read at the tick rather than
        // from the gesture value, which carries no modifiers — the
        // `ControllerLaneStrip` idiom, already shipped one surface over. The
        // translation is the whole distance from the PRESS, so the slop costs
        // the note nothing: it lands where it would have.
        model.updatePitchDrag(translationHeight: location.y - start.y, free: chord.option)
    }

    /// The ONE place a gesture can produce a store write.
    ///
    /// I0 — what the release DOES is the press's own answer
    /// (`PitchEditorModel.releasePress` → `PitchEditorReleaseAction`), decided by
    /// the kind routed at its first tick — never by whichever tool is engaged at
    /// mouse-up, which is what the `switch model.tool` here used to ask.
    private func dragEnded(start: CGPoint, location: CGPoint, chord: PitchEditorChord) {
        // I6b — teardown 1 of 3, FIRST: nothing below may be observed by a
        // clock still ticking against a press that has ended.
        stopEdgeRepeat()
        let action = model.releasePress(start: start, location: location,
                                        modifiers: chord.clickModifiers,
                                        snapBypassed: chord.option,
                                        clickCount: chord.clickCount)
        defer { reportSurface() }
        guard state.drawsNotes else {
            model.cancelDrag()
            return
        }
        onEngage()
        switch action {
        case .endNoteDrag:
            // The model emits at most one commit, and none at all when the note
            // finished where it started.
            _ = model.endPitchDrag()
        case .cut(let pressPoint):
            // The cut lands where the click BEGAN, not where it ended: a cut is
            // a click, and a hand that slipped two points during it did not
            // mean to move the knife.
            _ = model.splitNote(at: pressPoint)
        case .endWobble:
            // C5a-4b — the wobble drag ended: at most one commit, none for a
            // gesture that plays like the stored note (T10).
            _ = model.endWobbleDrag()
        case .wobbleStep(let id, let bigger):
            // C5a-4b — a click on the dot: one step, one commit (or none at a
            // cap), and the dot's tip stays up to say what the store kept.
            _ = model.stepWobble(segmentID: id, bigger: bigger)
        case .endBrush:
            // C5b-4b — the stroke ended: ONE commit for every note it drew on
            // (one undo step), none for a stroke that changed nothing.
            _ = model.endBrush()
        case .endFormantDrag:
            // W7-NTU U3 — the Voice drag ended: at most one commit, none for a
            // drag that ends on the stored value.
            _ = model.endVoiceDrag()
        case .formantReset(let id):
            // W7-NTU U3 — a double-click in the Voice tool: the note back as
            // sung, one commit, none when it already is.
            _ = model.resetVoice(segmentID: id)
        case .click, .endBand, .nothing:
            // I4 — ACTED ON ALREADY, in `releasePress` above: a click resolved
            // the house click table (select / toggle / deselect), a band landed
            // its final selection. Neither writes anything. I5 — ⌘ on empty
            // (`.click(.positionPlayhead)`) was placed there too: the MODEL
            // seeks, at the press's start, with ⌥ as the snap bypass. Nothing
            // may be left behind: no draft was begun, and the press is over.
            model.cancelDrag()
        }
    }

    // MARK: I6b — autoscroll at the pane's edge (interaction batch §9)

    /// THE LIVE POINTER'S WRAPPER — the drag gesture's `onChanged`, and the
    /// ONLY writer of the held pointer and of the clock. The staged seam calls
    /// `dragChanged` directly and so can never arm a clock: it has no pointer
    /// that can be held (the roll's `applyGesture` rule).
    ///
    /// ⚠️ The pointer and the offset are read as a PAIR off the same layout,
    /// and the offset is the SHOWN one (clamped), the value every tick rebuilds
    /// from: a raw reading can hold a position the scroller is not at
    /// (`PitchEditorViewport.shownOffsetX`), and a pair that mixed the two
    /// would put the held pointer that far away.
    private func liveDragChanged(_ value: DragGesture.Value) {
        heldEdgePoint = EdgeAutoScroll.HeldPoint(pointer: value.location, origin: value.startLocation,
                                                 currentOffset: viewport.clamped(viewport.offset))
        lastPointerEventAt = ContinuousClock.now
        dragChanged(start: value.startLocation, location: value.location, chord: .current)
        // ⚠️ ARMED ONLY ONCE THE PRESS HAS TRAVELLED, with its draft or band
        // live (`edgePushAxes` is empty before promotion). A press on a note
        // that happens to sit in the band would otherwise repeat at 60 Hz into
        // a runaway scroll-and-move (the roll's hazard, `applyGesture`).
        setEdgeRepeat(running: !model.edgePushAxes.isEmpty)
    }

    /// ONE edge step, per pointer event and per held tick: the model decides
    /// (and grows the window when that is the answer); this only writes the
    /// scroll it asks for. Reached by staged drags too, which is what lets the
    /// staging gate drive growth.
    private func applyEdgeStep(at pointer: CGPoint) {
        let now = ContinuousClock.now
        let dt = PitchEditorModel.edgeStepSeconds(sinceLastStep: lastEdgeStepAt.map { now - $0 })
        lastEdgeStepAt = now
        let step = model.edgeStep(pointer: pointer, viewport: viewport, dt: dt)
        if let x = step.scrollX {
            // A band's x goes through FOLLOW, as the roll's does: a scroll follow
            // did not ask for stands it down during playback, like a trackpad's.
            if let follow { follow.scrollExternally(to: x) } else { scroll(toX: x, y: nil) }
        }
        if let y = step.scrollY {
            if step.grownRows > 0 {
                // The BOTTOM grew: reveal it against the NEW content height, which
                // the measured viewport has not seen yet, so not `scroll(toX:y:)`
                // (it would clamp to the old bottom and reveal nothing).
                scrollTarget.y = y
                verticalScrollNonce &+= 1
            } else {
                scroll(toX: nil, y: y)
            }
        }
    }

    /// Starts or stops the held-pointer repeat. Idempotent, so the per-event
    /// call cannot stack a second clock (the roll's `setEdgeRepeat`).
    private func setEdgeRepeat(running: Bool) {
        guard running != (edgeRepeatTask != nil) else { return }
        guard running else {
            edgeRepeatTask?.cancel()
            edgeRepeatTask = nil
            return
        }
        edgeRepeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: PianoRollEdgeRepeat.interval)
                guard !Task.isCancelled else { return }
                repeatHeldEdge()
            }
        }
    }

    /// The clock and the held pointer go together — `dragEnded` and
    /// `.onDisappear` both call this.
    private func stopEdgeRepeat() {
        setEdgeRepeat(running: false)
        heldEdgePoint = nil
        lastPointerEventAt = nil
        lastEdgeStepAt = nil
    }

    /// ONE held tick: a pointer still for `PianoRollEdgeRepeat.holdDelay` in a
    /// band, rebuilt from the OBSERVED offset and fed through `dragChanged`, the
    /// very funnel a real event takes. It GATES on the model
    /// (`edgePushAxes`), which is what covers Escape: the model ends the drag,
    /// the axes go empty, and the tick does nothing until the release tears
    /// the clock down.
    private func repeatHeldEdge() {
        let axes = model.edgePushAxes
        guard !axes.isEmpty, let held = heldEdgePoint, let since = lastPointerEventAt,
              PianoRollEdgeRepeat.isHeld(sinceLastPointerEvent: ContinuousClock.now - since),
              let tick = EdgeAutoScroll.tick(held: held, observedOffset: viewport.clamped(viewport.offset),
                                             viewport: viewport.viewportSize,
                                             content: viewport.contentSize, axes: axes)
        else { return }
        dragChanged(start: held.origin, location: tick.location, chord: .current)
    }

    // MARK: I7b — the right-click menu (interaction batch §10)

    /// THE ONE MENU FOR NOTES: "Clear Note" / "Clear 3 Notes", and "Restore …"
    /// when a target is cleared — titles and enabled states from the model
    /// (`noteMenu(at:)` → `PitchEditorNoteMenu`), SHOWN but disabled with
    /// nothing to act on. Every item runs `runNoteMenu`, and nothing else.
    @ViewBuilder
    private func noteContextMenu(_ items: [PitchEditorNoteMenu.Item], at point: CGPoint?) -> some View {
        ForEach(items) { item in
            Button(item.title) { runNoteMenu(item.action, at: point) }
                .disabled(!item.isEnabled)
        }
    }

    /// ⭐ **THE MENU'S ONE FUNCTION** — every item's, and the debug tier's
    /// staged `noteMenu` step's. The right-click's selection half again (the
    /// catcher normally did it at mouse-down; this makes the action right even
    /// if it did not), then the SAME model action ⌫ and Edit ▸ Delete reach
    /// through the bridge (`PitchEditorModel.performNoteAction`). One undo step,
    /// one journal entry, whichever door.
    private func runNoteMenu(_ action: PitchEditorNoteMenu.Action, at point: CGPoint?) {
        onEngage()
        if let point { model.selectForContextMenu(at: point) }
        model.performNoteAction(action)
    }

    // MARK: UE-1 — Find sounds with no pitch

    /// ⭐ **THE BUTTON'S ONE FUNCTION** — the header button's, and the debug
    /// tier's staged `findSounds` step's. The MODEL decides whether to run
    /// (`beginFindSounds`: not twice at once, and a table the store would
    /// refuse is refused in words without asking it); the APP runs the store's
    /// verb (`onFindSounds`); the model says what came back
    /// (`finishFindSounds`). Nothing here reaches the store itself.
    ///
    /// ⚠️ The merged table reaches this pane the ordinary way, through
    /// `clip.pitchEdits` → `syncStoredNoteTable`, so the sounds appear and the
    /// button (which is offered only while the table has none) goes away.
    private func runFindSounds() {
        onEngage()
        guard model.beginFindSounds() else { return }
        let find = onFindSounds
        let model = model
        Task { @MainActor in
            model.finishFindSounds(await find())
        }
    }

    /// A palette slot was pressed. ONE action for the palette's buttons and the
    /// debug tier's staged `tool` step, so a gate switches tools through exactly
    /// these three lines.
    private func selectTool(_ chosen: PitchEditorTool) {
        onEngage()
        model.tool = chosen
        model.clearRefusal()
        // C5a-4b — a dot click's tip belongs to the tool it was clicked in.
        model.clearWobbleTip()
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
        // I7b-2 — the clip badge, resolved ONCE: the capsule below draws
        // `badge.title` and the ledger is handed this same value.
        let badge = PitchEditorClipBadge.resolve(clip)
        // W7-NTU U1 — the "Sound like the singer" group, resolved ONCE, from
        // the CLIP's stored stretch and transpose (the consonant rule's own
        // inputs, never the geometry's derived ratio): drawn from and reported
        // from this same value. nil while there are no notes to tune.
        let singer = model.offersSingerGroup
            ? model.singerGroup(stretchRatio: clip.stretchRatio,
                                clipSemitones: clip.pitchShiftSemitones)
            : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(clip.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                if let badge {
                    // ⭐ SAY THAT THE CLIP IS TUNED, IN WORDS. Since C-0 the line
                    // IS the corrected one (it is what the render will play),
                    // so the picture does change when a preset lands — but a
                    // gentle preset moves most notes by less than a row, and a
                    // novice who pressed it must not have to read a few pixels
                    // of line to learn that the tuner did anything. The badge
                    // is the sentence; the line is the evidence.
                    //
                    // I7b-2 — AND SAY IT TRUTHFULLY. "TUNING APPLIED" only when
                    // a pitch moved (`Clip.hasTuningEdits`); a clip whose only
                    // edits clear notes or change their level reads "NOTES
                    // EDITED" (`PitchEditorClipBadge`), in neutral ink.
                    clipBadge(badge)
                }
                Spacer(minLength: 0)
                auditionToggle
                zoomCluster
                maximizeToggle
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DAWTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Close the note editor")
            }

            HStack(spacing: 10) {
                statusLine(status)
                // I4 — "3 notes selected": what a novice needs to trust a
                // selection they cannot always see (notes off-screen, a band
                // that grazed one). Resolved by the model, drawn verbatim.
                // I7b — in the SELECTION's ink (white), not `signal`: green on
                // this pane means "tuned", and the words must match the ring.
                if let selected = model.selectionSummary {
                    Text(selected)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DAWTheme.textPrimary)
                }
                // m23-ap I1 UI hooks — HONEST WAITING, on the state row: what
                // the router says about hearing the note, drawn in words (the
                // state-line law: never a spinner alone, never silence).
                if let auditionLine {
                    auditionLineView(auditionLine)
                }
                // UE-1 — what the last "Find sounds with no pitch" press came
                // back with, in words (never silent: finding nothing says so).
                if let findSoundsLine = model.findSoundsLine {
                    findSoundsLineView(findSoundsLine)
                }
                // p2-ren Stage B″(c) — "you are hearing a quick preview", in
                // the status line's quiet dress: not a warning (nothing
                // refused) and not a spinner (the clip's shimmer already means
                // "rendering"). Gone the moment the exact render plays.
                if let renderCaption = PitchEditorRenderCaption.text(for: renderAudible) {
                    Text(renderCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(DAWTheme.textDim)
                }
            }
            .onAppear {
                chrome?.recordAuditionLine(auditionLine)
                chrome?.recordRenderCaption(PitchEditorRenderCaption.text(for: renderAudible))
            }
            .onChange(of: auditionLine) { _, now in chrome?.recordAuditionLine(now) }
            // B″(c) — the ledger gets the caption the row just drew, from the
            // SAME call, so `debug.pitchEditor`'s `chrome.renderCaption` is the
            // screen and not a second reading of the engine.
            .onChange(of: renderAudible) { _, now in
                chrome?.recordRenderCaption(PitchEditorRenderCaption.text(for: now))
            }
            // UE-1 — a Find Sounds answer lands asynchronously and moves nothing
            // else the surface report watches until its merge arrives. Here, on
            // the row that draws the line, and NOT on the body's modifier chain,
            // which is at the type checker's limit (measured: one more
            // `.onChange` there failed to type-check in reasonable time).
            .onChange(of: model.findSoundsLine) { _, _ in reportSurface() }
            // The OFFER flips with the stored table, which can arrive without
            // moving a blob (the first commit stores the seed itself), so the
            // report the staged step and the echo read would lag the button.
            .onChange(of: model.offersFindSounds) { _, _ in reportSurface() }

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            presetsAndSinger(presets, singer: singer)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // ⚠️ **TWO TRIGGERS, AND THE SECOND ONE IS THE EASY ONE TO MISS.**
        // `status` alone is not enough: applying a preset puts the TUNING
        // APPLIED badge on screen while the status line goes on saying "Found 5
        // notes.". A ledger keyed only on the status would then report
        // `tuningApplied: false` about a badge a person can see, which is
        // precisely the "the echo agrees with itself and with nothing on
        // screen" failure this seam exists to prevent — and it is the one
        // transition a `debug.pitchEditor` gate will press first.
        //
        // ⚠️ I7b-2 — **THE SECOND TRIGGER IS THE BADGE ITSELF, NOT A PREDICATE
        // UNDER IT.** It used to be `clip.hasPitchEdits`. Clear a note (NOTES
        // EDITED) and then apply a preset (TUNING APPLIED): the face swaps while
        // `hasPitchEdits` stays true, so that trigger would never fire and the
        // spy would go on reporting the face that is gone.
        .onAppear {
            recordChrome(status: status, caption: caption, presets: presets, badge: badge)
        }
        .onChange(of: status) { _, _ in
            recordChrome(status: status, caption: caption, presets: presets, badge: badge)
        }
        .onChange(of: badge) { _, now in
            recordChrome(status: status, caption: caption, presets: presets, badge: now)
        }
        // UE-2 — THE THIRD TRIGGER: the legend gains its stripes line when a
        // Find-sounds merge lands, and neither the status nor the badge need
        // move for that — the ledger would report a caption that is gone.
        .onChange(of: caption) { _, now in
            recordChrome(status: status, caption: now, presets: presets, badge: badge)
        }
    }

    /// The clip badge's face (I7b-2). ONE capsule for both words — the
    /// geometry TUNING APPLIED always had — so they read as one family and only
    /// the ink differs. `signal` green is this pane's "tuned" colour (a tuned
    /// note's accent, the tuner's success) and only `.tuningApplied` earns it.
    /// A clip whose edits are clears and levels wears the neutral secondary
    /// ink: not `playback` cyan (an active state), not violet (AI-touched),
    /// not amber (nothing here is a warning).
    private func clipBadge(_ badge: PitchEditorClipBadge) -> some View {
        let ink = Self.clipBadgeInk(badge)
        return Text(badge.title)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(ink.opacity(0.14), in: Capsule())
    }

    private static func clipBadgeInk(_ badge: PitchEditorClipBadge) -> Color {
        switch badge {
        case .tuningApplied: DAWTheme.signal
        case .notesEdited: DAWTheme.textSecondary
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
    ///
    /// m23-ap I2 — and the PINCH is written down beside the TIME buttons it
    /// stands in for, in the group title's ink, one line: a gesture nobody is
    /// told about is a gesture a novice never finds. Drawn, never a tooltip
    /// (design §5), and reported to the ledger as drawn.
    @ViewBuilder
    private var zoomCluster: some View {
        let pinchHint = PitchEditorZoomHint.pinchTime
        HStack(spacing: 6) {
            Text(pinchHint)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
                .fixedSize()
                .onAppear { chrome?.recordZoomHint(pinchHint) }
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

    /// MAXIMIZE / RESTORE (m23-ap interaction batch I6a) — the roll's toggle
    /// (`PianoRollView.maximizeToggle`, m25-b-1) on this pane, with the SAME
    /// tested faces (`EditorMaximize.toggleSymbol/toggleHelp/
    /// toggleAccessibilityLabel`) and the SAME write
    /// (`layout.setEditorMaximized`). The mode is ONE persisted slot, and it
    /// already sizes this pane (`ContentView.editorPaneFraction`); only the
    /// door was missing. The other two exits are the roll's too: Escape (the
    /// mount on this pane's body) and dragging the splitter.
    ///
    /// ⭐ **IN THIS HEADER'S GRAMMAR, NOT THE ROLL'S CHIP.** The close control
    /// beside it is a bare 10 pt glyph in `textSecondary`; the roll's 22×22
    /// `panelRaised` chip next to it would read as a different kind of control.
    /// So at rest it is that same bare glyph — neutral, because a door you have
    /// not opened is not a state — on a 20×18 hit target. Maximized, it wears the
    /// roll's earned state: `playback` cyan, a faint cyan plate and the glow
    /// (Rule 3: cyan is "active"; never violet, nothing here is AI-touched).
    /// It sits BEFORE close, as in the roll: "make it big / put it away" are one
    /// family of pane action.
    private var maximizeToggle: some View {
        let maximized = layout.editorMaximized
        return Button {
            // m23-al R10 — the maximize funnel, for the roll's reason:
            // maximizing is the strongest statement that THIS pane is where the
            // user works, so ⌘+/⌘−/⌘0 must follow it here.
            onEngage()
            layout.setEditorMaximized(!maximized)
        } label: {
            Image(systemName: EditorMaximize.toggleSymbol(maximized: maximized))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(maximized ? DAWTheme.playback : DAWTheme.textSecondary)
                .frame(width: 20, height: 18)
                .background(maximized ? DAWTheme.playback.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .glow(DAWTheme.playback, radius: 5, intensity: maximized ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .help(EditorMaximize.toggleHelp(maximized: maximized))
        .accessibilityLabel(EditorMaximize.toggleAccessibilityLabel(maximized: maximized))
        // The spy seam: the face the header DREW, beside the store's own value
        // in `debug.pitchEditor` — two instruments that must agree.
        .onAppear { recordMaximizeToggle(maximized) }
        .onChange(of: layout.editorMaximized) { _, now in recordMaximizeToggle(now) }
    }

    private func recordMaximizeToggle(_ maximized: Bool) {
        chrome?.recordMaximizeToggle(maximized: maximized,
                                     symbol: EditorMaximize.toggleSymbol(maximized: maximized))
    }

    /// HEAR — the note-audition switch (m23-ap I1 UI hooks, item 6). It writes
    /// `PanelLayoutStore.auditionEnabled`, the ONE switch the piano roll's drag
    /// and gutter sounds and musical typing's preview already read, and its help
    /// says so (`PitchEditorAuditionToggle.help`). The roll has no visible
    /// switch to copy, so this is the switch's first face.
    ///
    /// The FOLLOW chip's grammar, one family of "a mode you can leave on": an
    /// SF Mono caps label beside a glyph, neutral `textDim` on `panelRaised`
    /// when off (Rule 3: no accent at rest), `playback` cyan with a faint plate
    /// and the glow when on — cyan because on means "you will HEAR this", the
    /// playback ink. Never green (tuned) and never violet (AI-touched).
    private var auditionToggle: some View {
        let on = layout.auditionEnabled
        return Button {
            onEngage()
            layout.setAuditionEnabled(!on)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: PitchEditorAuditionToggle.symbol(on: on))
                    .font(.system(size: 9, weight: .bold))
                Text(PitchEditorAuditionToggle.title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(on ? DAWTheme.playback : DAWTheme.textDim)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(on ? DAWTheme.playback.opacity(0.14) : DAWTheme.panelRaised,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .glow(DAWTheme.playback, radius: 5, intensity: on ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .help(PitchEditorAuditionToggle.help(on: on))
        .accessibilityLabel(PitchEditorAuditionToggle.accessibilityLabel(on: on))
        // The spy seam: the face and the help the header DREW, beside the
        // store's own `auditionEnabled` in `debug.pitchEditor`.
        .onAppear { recordAuditionToggle(on) }
        .onChange(of: layout.auditionEnabled) { _, now in recordAuditionToggle(now) }
    }

    private func recordAuditionToggle(_ on: Bool) {
        chrome?.recordAuditionToggle(on: on,
                                     symbol: PitchEditorAuditionToggle.symbol(on: on),
                                     help: PitchEditorAuditionToggle.help(on: on))
    }

    /// UE-1 — the Find Sounds line in the state row's dress, the audition
    /// line's rule: WORKING is a mini spinner beside secondary ink (nothing
    /// refused); DONE is plain secondary ink (an answer, sounds added or none
    /// to add); a SHORTFALL (a guard declined, the store refused) is
    /// `PanelRefusalLine`. UE-2 — KEPT, and looked at: amber only where the
    /// press asked for something that did not happen (R22's rule), never for a
    /// wait or for "none found". A decline outlives the pane
    /// (`PitchEditorFindSoundsMemory`), and an "Added" line leaves with Undo.
    @ViewBuilder
    private func findSoundsLineView(_ line: PitchEditorFindSoundsLine) -> some View {
        switch line.kind {
        case .shortfall:
            PanelRefusalLine(message: line.text)
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(line.text)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textSecondary)
            }
        case .done:
            Text(line.text)
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textSecondary)
        }
    }

    /// The audition line (`PitchEditorAuditionRouter.line`), in the state
    /// row's own dress: PROGRESS ("Preparing your note…") is a mini spinner
    /// beside secondary ink, never amber — nothing refused; a SHORTFALL (the
    /// wait ran out, the track is muted) is `PanelRefusalLine`, because the
    /// thing the user asked for did not happen.
    @ViewBuilder
    private func auditionLineView(_ line: PitchEditorLineCaption) -> some View {
        switch line.kind {
        case .shortfall:
            PanelRefusalLine(message: line.text)
        case .progress:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(line.text)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textSecondary)
            }
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

    /// One reporting call site, fed the SAME `let`s the header drew from —
    /// the badge included (I7b-2): what is reported is the value the capsule
    /// drew, never a second reading of the clip.
    private func recordChrome(status: String, caption: String,
                              presets: [PitchCorrectionPreset],
                              badge: PitchEditorClipBadge?) {
        chrome?.record(statusKey: state.statusKey, statusText: status, caption: caption,
                       presetLabels: presets.map(\.displayName),
                       presetSummaries: presets.map(\.summary),
                       noteCount: model.blobs.count,
                       badge: badge)
    }

    /// §5.5.4's honest label for the blob-opacity encoding. Drawn only when
    /// there are blobs to explain — a legend for an empty surface is noise.
    /// The header's legend (`PitchEditorSoundLook.legend`): the confidence
    /// line, and — UE-2 — what the STRIPES mean while at least one sound is
    /// drawn striped (a cleared sound is drawn cleared, and needs no legend).
    private var confidenceLegend: String {
        PitchEditorSoundLook.legend(drawsNotes: state.drawsNotes,
                                    drawsSounds: model.blobs.contains { $0.look == .sound })
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
    /// UE-2 — the "TUNE THIS VOCAL" row's fixed height: the Find-sounds chip's
    /// (10 pt text, 2 pt vertical padding), so the chip never re-lays the pane.
    private static let tuneRowHeight: CGFloat = 18

    /// W7-NTU U1 — the preset chips and, when there are notes, the header
    /// group "Sound like the singer" (natural tuning X9): beside the chips
    /// when the header holds both, else below them
    /// (`PitchEditorPresetsAndSingerLayout`, the one rule). The ledger gets the
    /// group the view was handed and the two frames the layout produced.
    private func presetsAndSinger(_ presets: [PitchCorrectionPreset],
                                  singer: PitchEditorSingerGroup?) -> some View {
        PitchEditorPresetsAndSingerLayout {
            presetRow(presets)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    chrome?.recordPresetsFrame($0)
                }
            if let singer {
                singerGroupView(singer)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        chrome?.recordSingerFrame($0)
                    }
                    .onDisappear { chrome?.recordSingerFrame(nil) }
            }
        }
        .onAppear { chrome?.recordSingerGroup(singer) }
        .onChange(of: singer) { _, now in chrome?.recordSingerGroup(now) }
    }

    /// The group's gestures, each handed to the model, which decides what a
    /// press is and commits ONCE per gesture (`PitchEditorModel`'s "Sound
    /// like the singer" section).
    private func singerGroupView(_ group: PitchEditorSingerGroup) -> some View {
        PitchEditorSingerGroupView(
            group: group,
            onVoiceTrack: { fraction, fine in runSinger(.voiceTrack(fraction: fraction, fine: fine)) },
            onVoiceRelease: { runSinger(.voiceRelease) },
            onUpdate: { runSinger(.update) },
            onToggleConsonants: { runSinger(.consonants) },
            onPickSlides: { step in runSinger(.slides(step)) })
    }

    /// ONE home for what each control of the group does: the group view's
    /// callbacks and the debug tier's staged `singer` step both land here, so
    /// a gate presses exactly what a hand presses. `onEngage` claims the
    /// editor's keyboard scope once per gesture, as a preset chip does.
    private func runSinger(_ act: PitchEditorSingerAct) {
        switch act {
        case .voiceTrack(let fraction, let fine):
            if model.voiceSizePress == nil { onEngage() }
            model.trackVoiceSize(atFraction: fraction, fine: fine)
        case .voiceRelease:
            model.releaseVoiceSize()
        case .update:
            onEngage()
            model.updateToNaturalTuning()
        case .consonants:
            onEngage()
            model.toggleConsonants()
        case .slides(let step):
            onEngage()
            model.pickSlides(step)
        }
    }

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
                    // I7b — the SAME sentence as the clip menu's Remove Tuning
                    // (one operation, one help line): it also brings back every
                    // cleared note, and says how many.
                    .help(PitchEditorNoteMenu.removeTuningHelp(
                        clearedNoteCount: clip.pitchEdits?.segments.filter(\.isCleared).count ?? 0))
                }
                // UE-1 — "Find sounds with no pitch", for a STORED table made
                // before sounds existed (unpitched design §1.6, F-stale). Beside
                // Remove tuning for that button's reason: it acts on this
                // clip's note table, next to the chips that write it. Offered
                // only while the table holds no sound; held (disabled) while a
                // press is being answered.
                // UE-2 — ITS LOOK: an ADD affordance (it adds sounds to the
                // table), so Rule 3's neutral chrome — `textPrimary` on the
                // raised chip with a hairline, the preset chips' own dress,
                // no accent and no glow at rest. Not "Remove tuning"'s bare
                // secondary text: that one takes away, this one adds, and a
                // quiet grey phrase read as a caption, not a door. Held, it
                // dims; the state row beside the status says why it is held.
                if model.offersFindSounds || model.isFindingSounds {
                    Button { runFindSounds() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 9, weight: .semibold))
                            Text(PitchEditorFindSounds.label)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(DAWTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(DAWTheme.panelRaised, in: Capsule())
                        .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isFindingSounds)
                    .opacity(model.isFindingSounds ? 0.45 : 1)
                    .help(PitchEditorFindSounds.help)
                    .accessibilityLabel(PitchEditorFindSounds.label)
                }
                Spacer(minLength: 0)
            }
            // UE-2 — ONE HEIGHT WITH OR WITHOUT THE CHIP. Seen by looking: the
            // chip is ~6 pt taller than this row's words, so the row grew when
            // the button came back (Undo) and shrank when a merge hid it, and
            // every row of the surface below jumped with it. Pinned to the
            // chip's height, the offer can come and go without moving a note.
            .frame(height: Self.tuneRowHeight)
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
            hiddenBlobIDs: Set(model.drag?.movingSegmentIDs ?? []),
            selectedIDs: model.selection,
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

    /// m23-ap I5 — the TIME RULER stacked above the scrollers: a SIBLING ROW,
    /// never an overlay on them. Design §8 drew it as an overlay with an 18 pt
    /// top inset on the surface; in this pane the vertical scroller wraps the
    /// pitch sidebar and the horizontal scroller together, so an inset would
    /// move the vertical writer's marker, the vertical reader and I6c's
    /// available-height fill. A row above them leaves all three untouched —
    /// the vertical viewport simply measures 18 pt shorter.
    private var editorBody: some View {
        VStack(spacing: 0) {
            rulerRow
            editorScrollers
        }
        // I5 — FOLLOW, driven from the TRANSPORT observation path, never from a
        // geometry callback (m17-b: a `scrollTo` inside a layout transaction does
        // not durably move the scroller) — the roll's `followTick` placement.
        .onChange(of: positionBeats) { _, _ in followTick() }
        // The gate's simulated POINTER scroll (`debug.followPlayhead
        // {simulateUserScroll, surface:"pitchEditor"}`): through the writers,
        // with no expectation registered, so the detector sees what a real
        // trackpad scroll reports.
        .onChange(of: follow?.externalScrollNonce) { _, _ in
            if let follow { scroll(toX: follow.externalScrollX, y: nil) }
        }
    }

    /// The time ruler (interaction batch §8): the roll's `scrubStrip` shape —
    /// a corner over the pitch sidebar, then the band as the BACKGROUND of the
    /// hit area (`PianoRollScrubRulerBand`, whose body must stay an overlay; see
    /// its header). Click jumps, drag scrubs, playing or stopped, every tick
    /// through `rulerTick` — the one place the scroll offset is added. Shown in
    /// EVERY state: where the transport is, is a fact about the project, not
    /// about this detection (the playhead's own rule).
    private var rulerRow: some View {
        HStack(spacing: 0) {
            // The pitch sidebar's corner: no seek here, the band's ground so the
            // row reads as one strip.
            DAWTheme.panelRaised
                .frame(width: Self.rulerWidth)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DAWTheme.gridEmphasis)
                        .frame(height: PianoRollScrubRuler.groundHairline)
                }
                .allowsHitTesting(false)
            Color.clear
                .frame(maxWidth: .infinity)
                .background {
                    PianoRollScrubRulerBand(
                        lengthBeats: clip.lengthBeats,
                        beatsPerBar: beatsPerBar,
                        pixelsPerBeat: model.geometry.pixelsPerBeat,
                        // The roll's `gridDrawnWidth` rule: never shorter than
                        // the viewport beside it.
                        contentWidth: max(model.geometry.contentWidth, viewport.viewportSize.width),
                        // The offset the scroller can SHOW, the one `rulerTick`
                        // adds — never the raw reading (see `shownOffsetX`).
                        scrollX: viewport.shownOffsetX,
                        positionBeats: positionBeats,
                        clipStartBeat: clip.startBeat,
                        // I5-F1 — numbered in the SONG's bars, not the clip's.
                        songMeter: meterMap)
                }
                .contentShape(Rectangle())
                // `.verticalBar`, the transport family (design §8) — not the
                // roll's legacy `resizeLeftRight`.
                .hoverCursor(.verticalBar)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            DragCursor.set(.verticalBar)
                            // ⌥ read live per tick, the roll's `snapBypassHeld`.
                            rulerTick(x: value.location.x,
                                      option: NSEvent.modifierFlags.contains(.option))
                        }
                        .onEnded { _ in DragCursor.clear() })
                .help("Click or drag to move the playhead. Hold ⌥ to place it between grid lines.")
        }
        .frame(height: PianoRollScrubRuler.height)
        // The app's snap can change while the pane is open (the toolbar chip);
        // the model places with the value in force.
        .onChange(of: appSnap) { _, now in model.appSnap = now }
    }

    @ViewBuilder
    private var editorScrollers: some View {
        let ctx = drawContext
        // I3 — RESOLVED ONCE, then drawn, cursored and reported from the SAME
        // value: the line is the model's (`cutLine(at:)`, whose verdict the knife
        // switches over), so what is drawn, what the echo says and what a click
        // would do cannot come apart here.
        let cutLine = model.cutLine(at: hoverPoint)
        let cursor = model.surfaceCursor
        // I7b — the right-click menu, RESOLVED HERE from the hover point: SwiftUI
        // builds a `.contextMenu`'s items when this body runs, before the click
        // lands, so the titles must already name the notes the click will act
        // on (the unselected note under the pointer alone, else the selection).
        let noteMenu = model.noteMenu(at: hoverPoint)
        // C5a-4b — the dot and the knob, resolved once from the model and drawn
        // from the SAME values the echo reports (`recordInteraction`).
        let wobbleDot = model.wobbleDot(at: wobbleHover)
        let wobbleKnob = model.wobbleKnob
        // C5b-4b — the brush band, resolved once and drawn from the SAME value
        // the palette's help and the echo read.
        let brushBand = model.brushBand(at: hoverPoint, commandHeld: commandHeld)
        // W7-NTU U3 — the Voice marks, resolved once and drawn from the SAME
        // value the echo reports (`recordInteraction`).
        let voiceMarks = model.voiceMarks
        let cue = PianoRollPlayhead.offClipCue(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
        // VERTICAL scroll wraps BOTH columns, so the ruler and the surface can
        // never scroll apart; the HORIZONTAL scroll is nested inside and moves
        // the surface alone, which is what keeps the ruler pinned.
        //
        // I0 — THE WRITERS' READERS, SCOPED THE ROLL'S WAY. The vertical
        // `ScrollViewReader` necessarily spans both axes (the horizontal scroller
        // is inside it); what keeps that safe is WHERE its marker is mounted —
        // on the ruler, see `verticalMarker`. The horizontal one wraps ONLY the
        // horizontal scroller: a reader resolves `scrollTo` against every scroll
        // view in it, and `.leading` carries a y of 0.5, so a reader spanning both
        // would re-centre the pitch axis on every horizontal write.
        ScrollViewReader { verticalProxy in
        ScrollView(.vertical) {
            HStack(spacing: 0) {
                PitchRulerSidebar(geometry: ctx.geometry, width: Self.rulerWidth)
                    // I0 — the vertical writer's anchor. An overlay, so the
                    // ruler's own layout is untouched.
                    .overlay(alignment: .topLeading) { verticalMarker }
                ScrollViewReader { horizontalProxy in
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
                        // I5 — where a ⌘-click here would put it.
                        playheadGhost(height: ctx.geometry.contentHeight)
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
                        // C5a-4b — THE WOBBLE TOOL'S LAYER: the dot and its
                        // drawn tip, and during a drag the knob and the note's
                        // stretch of the draft line (`PitchEditorWobbleOverlay`).
                        if wobbleDot != nil || wobbleKnob != nil {
                            PitchEditorWobbleOverlay(
                                geometry: ctx.geometry, dot: wobbleDot, knob: wobbleKnob,
                                draftLine: wobbleKnob == nil ? [] : model.draftLineSegments,
                                lineIsEstimate: ctx.lineIsEstimate,
                                visible: CGRect(origin: viewport.clamped(viewport.offset),
                                                size: viewport.viewportSize))
                                .equatable()
                                .frame(width: max(1, ctx.geometry.contentWidth),
                                       height: ctx.geometry.contentHeight)
                        }
                        // C5b-4b — THE BRUSH'S LAYER: the band while ⌘ is held
                        // over a note (or a stroke is in flight), and during a
                        // stroke its notes' stretch of the draft line.
                        if let brushBand {
                            PitchEditorBrushOverlay(
                                band: brushBand,
                                draftLine: model.brush == nil ? [] : model.draftLineSegments,
                                lineIsEstimate: ctx.lineIsEstimate)
                                .equatable()
                                .frame(width: max(1, ctx.geometry.contentWidth),
                                       height: ctx.geometry.contentHeight)
                        }
                        // W7-NTU U3 — THE VOICE TOOL'S LAYER: each note's
                        // Voice bar and chip, only while the Voice tool is
                        // engaged (`PitchEditorVoiceOverlay`).
                        if !voiceMarks.isEmpty {
                            PitchEditorVoiceOverlay(
                                marks: voiceMarks,
                                contentSize: CGSize(width: max(1, ctx.geometry.contentWidth),
                                                    height: ctx.geometry.contentHeight))
                                .equatable()
                                .frame(width: max(1, ctx.geometry.contentWidth),
                                       height: ctx.geometry.contentHeight)
                        }
                        // I4 — THE RUBBER BAND, the roll's look exactly (one
                        // meaning, one look): only while a band is live.
                        if let band = model.band {
                            PitchEditorBandView(rect: band.rect)
                        }
                        // I3 — THE CUT LINE, whenever the Split tool is live and
                        // the pointer is on the surface; nothing is decided here.
                        if let cutLine {
                            PitchEditorCutPreview(
                                line: cutLine,
                                contentSize: CGSize(width: max(1, ctx.geometry.contentWidth),
                                                    height: ctx.geometry.contentHeight))
                                .equatable()
                        }
                    }
                    .frame(width: max(1, ctx.geometry.contentWidth),
                           height: ctx.geometry.contentHeight)
                    // I0 — the horizontal writer's anchor, and the horizontal
                    // reader (offset + content size), both in content space.
                    .overlay(alignment: .topLeading) { horizontalMarker }
                    .background { horizontalScrollReader }
                    // I7b — a RIGHT-CLICK selects the note under it BEFORE the
                    // menu opens (the brief's rule for this pane): an AppKit
                    // monitor that claims nothing, handing the press point —
                    // content space — to the model's own rule.
                    .background {
                        PitchEditorContextClickCatcher(onContextClick: { model.selectForContextMenu(at: $0) })
                    }
                    .contentShape(Rectangle())
                    // C1 + C3. `minimumDistance: 0` so a scissors CLICK is a
                    // gesture too — otherwise a cut would need a wiggle. I0: the
                    // callbacks take plain points, so a staged step runs them too.
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // I6b — the live wrapper: the held pointer and
                                // the clock, then `dragChanged` as before.
                                liveDragChanged(value)
                            }
                            .onEnded { value in
                                dragEnded(start: value.startLocation, location: value.location,
                                          chord: .current)
                            })
                    // I2 — PINCH TO ZOOM TIME, anchored at the pointer. The
                    // roll's shape (`PianoRollView`: `.gesture(gridDrag)` then
                    // `.simultaneousGesture(gridPinch)`), on the SAME content
                    // view as the drag so `startLocation` is content space.
                    // Simultaneous, so it never steals the drag's routing; a
                    // pinch is two fingers, so the two do not fight. Both
                    // callbacks only forward: the staged `pinch` step runs the
                    // same two functions.
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                pinchChanged(startLocation: value.startLocation,
                                             magnification: value.magnification)
                            }
                            .onEnded { _ in pinchEnded() })
                    // I7b — THE ONE MENU FOR NOTES (design §10 "UI (I7b)",
                    // §17.4). The surface already declares its content shape
                    // above (a `Canvas` contributes no hit region, and without
                    // one a `.contextMenu` never opens — the m23-cf law).
                    .contextMenu { noteContextMenu(noteMenu, at: hoverPoint) }
                    // I3 — the Split tool's pointer: the crosshair, the "precise
                    // place" family (design §6), from the model. Paired with the
                    // hover reader below as the roll pairs its own (`PianoRollView`
                    // grid), so the overlay and the reader see the same content
                    // space; the token re-asks when the tool changes under a still
                    // pointer. The overlay is hit-transparent (`HoverCursor`:
                    // `.allowsHitTesting(false)` + a nil `hitTest`), so the knife's
                    // gesture above still gets every click.
                    // I5 — and ⌘ over empty surface wears the transport's
                    // `.verticalBar` (the ruler's cursor): a click there places
                    // the playhead. The token re-asks on ⌘'s edge, which no
                    // pointer movement reports.
                    .hoverCursor(resolve: { point in
                                     model.surfaceCursor(at: point,
                                                         modifiers: commandHeld ? [.command] : [])
                                 },
                                 refresh: (cursor == nil ? 0 : 1) + (commandHeld ? 2 : 0))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hoverPoint = point
                            startFlagsMonitor()   // I5 — idempotent
                        case .ended:
                            hoverPoint = nil
                            stopFlagsMonitor()
                        }
                    }
                    // The spy seam: the VERY line drawn above, reported to the
                    // ledger `debug.pitchEditor.cutPreview` reads — never a
                    // re-derivation of it.
                    .onChange(of: cutLine) { _, drawn in chrome?.recordCutLine(drawn) }
                }
                .coordinateSpace(name: Self.horizontalScrollSpace)
                // I0 — the visible width (the box, not the clip).
                .background { horizontalViewportReader }
                // I0 — THE HORIZONTAL WRITER. Never animated — a re-pin must not
                // glide. The deferred re-issue is the m17-b DURABILITY rule: a
                // `scrollTo` not re-issued on a fresh main-actor turn moves layout
                // without updating the scroller's own position, and the next
                // forced re-render (`view.capture`'s `cacheDisplay`, a resize)
                // jumps back to the stale value.
                .onChange(of: horizontalScrollNonce) { _, _ in
                    horizontalProxy.scrollTo(Self.horizontalMarkerID, anchor: .leading)
                    Task { @MainActor in
                        horizontalProxy.scrollTo(Self.horizontalMarkerID, anchor: .leading)
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
            }
            .frame(height: ctx.geometry.contentHeight, alignment: .top)
            // I0 — the vertical reader: the content's top in the vertical
            // scroller's named space.
            .background { verticalScrollReader }
        }
        .coordinateSpace(name: Self.verticalScrollSpace)
        // I0 — the visible height, and THE VERTICAL WRITER (the same
        // non-animated, deferred-re-issue shape as the horizontal one).
        .background { verticalViewportReader }
        .onChange(of: verticalScrollNonce) { _, _ in
            verticalProxy.scrollTo(Self.verticalMarkerID, anchor: .top)
            Task { @MainActor in
                verticalProxy.scrollTo(Self.verticalMarkerID, anchor: .top)
            }
        }
        }
        // m23-al: the ONE engagement funnel for this pane. A click here is what
        // makes ⌘+/⌘−/⌘0 reach this surface instead of the arrange; the latch's
        // change-guard is what makes calling it freely safe.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onEngage() })
        .background(DAWTheme.background)
    }
}

// MARK: - The right-click's selection half (m23-ap interaction batch I7b)

/// Selects the note under a RIGHT-CLICK (or a ⌃-click, AppKit's other way to
/// ask for a context menu) BEFORE the menu opens — so the note a person
/// right-clicked lights up as the selection while its menu is showing.
///
/// ⭐ **WHY AN APPKIT MONITOR AND NOT A GESTURE.** `.contextMenu` hands its
/// builder no click location, and a SwiftUI gesture sees left-button presses
/// only. `EQScrollCatcher`'s shape (the EQ plot's scroll-wheel surface): a
/// transparent NSView that HIT-TESTS TO NIL — the surface's drag, band and
/// hover keep every event — and listens through a local monitor scoped to its
/// own window and its own VISIBLE rect (never the part of the content scrolled
/// out under the ruler). The event is always returned untouched, so the menu
/// opens exactly as it would have.
///
/// ⚠️ NOT PROVEN HEADLESSLY, and not by the staging gate either: an unbundled
/// staging binary cannot open a context menu from a synthetic event (m23-g1).
/// `PitchEditorModelTests` proves the RULE it calls (`selectForContextMenu`);
/// what this adds — AppKit delivering a right mouse-down to the monitor before
/// the menu is built — is inferred from the EQ catcher, which ships the same
/// mechanism for a different event.
private struct PitchEditorContextClickCatcher: NSViewRepresentable {
    /// The press point, in the surface's CONTENT space.
    var onContextClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onContextClick = onContextClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onContextClick = onContextClick
    }

    final class CatcherView: NSView {
        var onContextClick: (CGPoint) -> Void = { _ in }
        private var monitor: Any?

        /// Top-left origin, so a converted point IS the surface's content space
        /// — the space its `DragGesture` and hover reader report in (this view
        /// is a background of that content, sized to it).
        override var isFlipped: Bool { true }

        /// NEVER claims mouse events — the right-click arrives via the monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
                [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let asksForMenu = event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
                guard asksForMenu else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.visibleRect.contains(location) else { return event }
                self.onContextClick(location)
                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

// MARK: - The live chord (m23-ap interaction batch I0)

extension PitchEditorChord {
    /// The chord held RIGHT NOW, for a real pointer event: ⇧/⌘ through the app's
    /// ONE click-chord mapping (`ArrangeClickModifiers.from`, which is why caps
    /// lock or fn can never turn a click into a toggle here either), ⌥ read the
    /// way the C1 drag has always read it.
    ///
    /// NOT PROVEN HEADLESSLY, for `ArrangeClickModifiers.current`'s reason: a
    /// `DragGesture.Value` carries no modifiers, so this reads the global state
    /// at the tick. A staged step passes its chord EXPLICITLY instead, so a gate
    /// proves the decisions made WITH a chord, not this one line of plumbing.
    ///
    /// W7-NTU U3 — and the click count, for the Voice tool's double-click, off
    /// the event being handled. The DECISION (read it only for a left
    /// mouse-down or mouse-up, since `NSEvent.clickCount` raises on any other
    /// event) is `PitchEditorChord.clickCount(eventType:readClickCount:)`,
    /// tested with real `NSEvent`s. What stays NOT PROVEN HEADLESSLY is this
    /// line's premise, that `NSApp.currentEvent` is the mouse-up when the
    /// gesture ends: a staged release passes `clicks` instead. Main actor:
    /// `NSApp` is, and every caller is a gesture callback of the view.
    @MainActor
    static var current: PitchEditorChord {
        let flags = NSEvent.modifierFlags
        let click = ArrangeClickModifiers.from(flags)
        let event = NSApp.currentEvent
        let clicks = PitchEditorChord.clickCount(eventType: event.map { UInt($0.type.rawValue) },
                                                 readClickCount: { event?.clickCount ?? 1 })
        return PitchEditorChord(shift: click.contains(.shift),
                                command: click.contains(.command),
                                option: flags.contains(.option),
                                clickCount: clicks)
    }
}
