import CoreGraphics
import Foundation

// m23-ap interaction batch, item I0 — THE PITCH EDITOR'S INTERACTION BRIDGE.
//
// Design record: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §3
// item 6. `PitchEditorModel` is `@State private` inside `PitchEditorView`, so
// nothing outside the pane can read what it is looking at or reach its pointer
// handling. This is the one channel, in both directions — the
// `PianoRollNoteSelectionBridge` shape (observed nonce in, reported state out),
// app-held so it outlives the pane's `.id(clip.id)` rebuilds.
//
// ⭐ **WHY STAGED STEPS EXIST AT ALL: NOTHING IN THIS TREE CAN DRIVE A REAL
// POINTER** (the m23-g1 law; `PianoRollAutoScroll.swift`'s banner). An offscreen
// window gets no synthetic hover and a synthetic click never reaches a SwiftUI
// gesture inside a scroll view — which is exactly why the I3 lane could not
// show its cut line or its knife in the LIVE pane. A staged step runs the SAME
// view callbacks a real event runs (`dragChanged` / `dragEnded` / the hover
// reader's write), with the chord passed EXPLICITLY because a synthesized step
// carries no `NSEvent.modifierFlags` — the `PianoRollMarqueeStage` convention.
//
// ⚠️ **WHAT IS DELIBERATELY NOT HERE YET, AND WHERE IT GOES.** Design §3 also
// lists a staged ruler x (I5). It has no consumer until I5 builds one, and a
// nonce nothing consumes is a request that silently succeeds at nothing — the
// one failure shape this tree keeps paying for. I5 adds a `.ruler(x:)` case to
// `PitchEditorStagedStep`, a one-line extension of this file.
//
// ⭐ **I4 LANDED ITS THREE (m23-ap I4):** `clearSelectionNonce` and
// `selectAllNonce` beside `escapeNonce` (each consumed by the pane's model the
// same body pass), `deleteNonce` for the ⌫ the app routes to the notes, and the
// two OUT facts the app's policies read — `hasNoteSelection` (⌫) and
// `drawnNoteCount` (⌘A). A band needs no step of its own: it IS a staged press
// on empty space, a drag past the slop, and a release — I0's three steps.
//
// ⭐ **I7b (m23-ap):** `deleteNonce` now CLEARS the selected notes (the pane
// runs `PitchEditorModel.performNoteAction(.clear)`), a staged `.noteMenu`
// step runs the right-click menu's own function (a synthetic event cannot open
// a context menu — the m23-g1 law), and each drawn note reports its `cleared`
// flag and `levelDb` beside its rect, read from the model.

/// The chord a pointer event carries, for the pitch editor.
///
/// ⇧/⌘ are the house CLICK chord (`ArrangeClickModifiers`, decided at press by
/// the router and at release by `PianoRollGridPress`); ⌥ is the Move tool's
/// FREE-pitch key, read per tick (C1). Kept apart on purpose: the app's
/// `ArrangeClickModifiers.from(_:)` deliberately never maps ⌥, and widening that
/// shared type would change what ⌥-click means on the arrange.
public struct PitchEditorChord: Sendable, Equatable {
    public var shift: Bool
    public var command: Bool
    public var option: Bool

    public init(shift: Bool = false, command: Bool = false, option: Bool = false) {
        self.shift = shift
        self.command = command
        self.option = option
    }

    /// No keys held.
    public static let none = PitchEditorChord()

    /// The click half, for the router and the click table.
    public var clickModifiers: ArrangeClickModifiers {
        var mods: ArrangeClickModifiers = []
        if shift { mods.insert(.shift) }
        if command { mods.insert(.command) }
        return mods
    }
}

/// One DEBUG-TIER step staged into the open pane (`debug.pitchEditor {act:…}`).
///
/// Coordinates are the surface's CONTENT space — the space its `DragGesture`
/// and hover reader report in (x from the clip's start, y from the top of the
/// pitch window). A caller derives them from the echo's `notesAsDrawn` rects,
/// never from a guessed scale: both scales are user-zoomable.
public enum PitchEditorStagedStep: Sendable, Equatable {
    /// The pointer is over the surface here — the hover reader's own write.
    case hover(CGPoint)
    /// The pointer left the surface.
    case hoverEnd
    /// Mouse down: the gesture's FIRST tick (zero travel), which routes.
    case press(CGPoint, PitchEditorChord)
    /// A later tick of the staged press, now at this point.
    case drag(CGPoint, PitchEditorChord)
    /// Mouse up here.
    case release(CGPoint, PitchEditorChord)
    /// A palette slot was pressed — the palette button's own three lines.
    case tool(PitchEditorTool)
    /// Scroll to this offset (either axis optional) through the pane's WRITERS,
    /// clamped like every other writer — the gate's stand-in for a trackpad
    /// scroll, the roll's `follow.scrollExternally` precedent.
    case scroll(x: CGFloat?, y: CGFloat?)
    /// m23-ap I7b — a right-click menu item was chosen: the menu's OWN function
    /// (`PitchEditorView.runNoteMenu`), with the right-click's point when there
    /// is one (an unselected note under it is selected first) and `nil` for the
    /// selection as it stands. The stand-in for a context menu no synthetic
    /// event can open (the m23-g1 law).
    case noteMenu(PitchEditorNoteMenu.Action, CGPoint?)

    /// Stable machine tag for the echo.
    public var key: String {
        switch self {
        case .hover: return "hover"
        case .hoverEnd: return "hoverEnd"
        case .press: return "press"
        case .drag: return "drag"
        case .release: return "release"
        case .tool: return "tool"
        case .scroll: return "scroll"
        case .noteMenu: return "noteMenu"
        }
    }
}

/// One note as the surface DREW it: its id and its rectangle in content space
/// (`PitchEditorModel.rect(for:)`, the rect the Canvas fills). The staged
/// hover/press target these — derived from the drawing, never re-computed.
public struct PitchEditorNoteRect: Sendable, Equatable {
    public var id: UUID
    public var rect: CGRect
    /// m23-ap I7b — the note is drawn CLEARED (`NoteBlob.isCleared`).
    public var cleared: Bool
    /// m23-ap I7b — the note's level, dB (`NoteBlob.amplitudeDb`), 0 = as sung.
    public var levelDb: Double
    /// m23-ap I7b — the level readout the surface draws for it
    /// (`NoteBlob.levelReadout`), or `nil` when it draws none.
    public var levelReadout: String?

    public init(id: UUID, rect: CGRect, cleared: Bool = false, levelDb: Double = 0,
                levelReadout: String? = nil) {
        self.id = id
        self.rect = rect
        self.cleared = cleared
        self.levelDb = levelDb
        self.levelReadout = levelReadout
    }
}

/// The pane's NOTE SELECTION as its model holds it (m23-ap I4) — what
/// `debug.pitchEditor`'s `selection {ids, count, token}` echo reads. Copied from
/// `PitchEditorModel.selection` / `.selectionToken`, never re-derived.
public struct PitchEditorSelectionReport: Sendable, Equatable {
    /// The selected notes — `NoteSegment.id`s.
    public var ids: Set<UUID>
    /// The selection's identity (`PitchEditorModel.selectionToken`): re-minted
    /// on every real change, so two reads with the same token saw the same
    /// selection. `nil` only when no pane is reporting.
    public var token: UUID?
    /// The status line's words for it (`PitchEditorModel.selectionSummary`),
    /// verbatim — `nil` when nothing is selected.
    public var summary: String?

    public init(ids: Set<UUID> = [], token: UUID? = nil, summary: String? = nil) {
        self.ids = ids
        self.token = token
        self.summary = summary
    }
}

/// A rubber band in flight on the pane (m23-ap I4), as the model holds it
/// (`PitchEditorModel.band`) — `nil` in the report when none is live.
public struct PitchEditorBandReport: Sendable, Equatable {
    /// The band as drawn, normalized, in content space.
    public var rect: CGRect
    /// The notes it touches right now.
    public var hits: Set<UUID>
    /// Whether ⇧/⌘ made it union onto the selection it armed with.
    public var additive: Bool

    public init(rect: CGRect, hits: Set<UUID>, additive: Bool) {
        self.rect = rect
        self.hits = hits
        self.additive = additive
    }
}

/// The pitch window as the pane LAID IT OUT (m23-ap I6c): `debug.pitchEditor`'s
/// `pitchWindow` echo. Copied from the pane's model, never re-derived:
/// `laidOut` is `PitchEditorGeometry.midiRange` (what every row, clamp and label
/// reads), `fitted` is `PitchEditorModel.fittedMidiRange` (the notes' own window
/// it was grown from), and `availableHeight` is the pane height it was filled
/// to.
public struct PitchEditorWindowReport: Sendable, Equatable {
    public var laidOut: ClosedRange<Double>
    public var fitted: ClosedRange<Double>
    public var rowHeight: CGFloat
    public var availableHeight: CGFloat

    public init(laidOut: ClosedRange<Double>, fitted: ClosedRange<Double>,
                rowHeight: CGFloat, availableHeight: CGFloat) {
        self.laidOut = laidOut
        self.fitted = fitted
        self.rowHeight = rowHeight
        self.availableHeight = availableHeight
    }
}

/// Everything the pane reports about its surface, for `debug.pitchEditor`.
/// Ground truth from the view — never the seam's own input echoed back.
public struct PitchEditorSurfaceReport: Sendable, Equatable {
    /// Where the scrollers are looking — MEASURED by the view's readers.
    public var viewport: PitchEditorViewport
    /// The notes as drawn.
    public var noteRects: [PitchEditorNoteRect]
    /// The press in flight, or `nil`.
    public var press: PitchEditorPress?
    /// What the last release did, or `nil` before any.
    public var lastRelease: PitchEditorReleaseAction?
    /// The hover point the cut line is resolved at, or `nil` off the surface.
    public var hoverPoint: CGPoint?
    /// I4 — the note selection, as the model holds it.
    public var selection: PitchEditorSelectionReport
    /// I4 — the rubber band in flight, or `nil`.
    public var band: PitchEditorBandReport?
    /// I7b — the right-click menu as the pane would build it at the reported
    /// hover point (`PitchEditorModel.noteMenu(at:)`): its titles and enabled
    /// states, which no synthetic event can open a menu to read.
    public var noteMenu: [PitchEditorNoteMenu.Item]
    /// I6c — the pitch window as laid out, or `nil` when no pane is reporting.
    public var pitchWindow: PitchEditorWindowReport?

    public init(viewport: PitchEditorViewport = .unmeasured, noteRects: [PitchEditorNoteRect] = [],
                press: PitchEditorPress? = nil, lastRelease: PitchEditorReleaseAction? = nil,
                hoverPoint: CGPoint? = nil,
                selection: PitchEditorSelectionReport = PitchEditorSelectionReport(),
                band: PitchEditorBandReport? = nil,
                noteMenu: [PitchEditorNoteMenu.Item] = [],
                pitchWindow: PitchEditorWindowReport? = nil) {
        self.viewport = viewport
        self.noteRects = noteRects
        self.press = press
        self.lastRelease = lastRelease
        self.hoverPoint = hoverPoint
        self.selection = selection
        self.band = band
        self.noteMenu = noteMenu
        self.pitchWindow = pitchWindow
    }

    /// No pane is reporting.
    public static let empty = PitchEditorSurfaceReport()
}

/// The app-held channel between the pitch editor pane and everything outside it.
@MainActor
@Observable
public final class PitchEditorInteractionBridge {

    // MARK: OUT — reported by the pane

    /// REPORTED BY THE PANE: whether it holds a NOTE selection — the ⌫
    /// predicate's input (`AppModel.pitchEditorWouldConsumeKey` →
    /// `DeleteMenuPolicy`'s `.pitchEditorNotes` surface, the
    /// `pianoRollWouldConsumeKey` shape: transition-reported, observable, never
    /// focus). Written by the pane whenever its model's selection empties or
    /// fills (m23-ap I4) — never per pointer tick.
    public private(set) var hasNoteSelection = false

    /// REPORTED BY THE PANE: how many notes it DRAWS — ⌘A's input
    /// (`SelectAllMenuPolicy`'s `pitchEditorNoteCount`, m23-ap I4). Observable,
    /// because a `Commands` body must re-evaluate the item when it moves; and
    /// written on CHANGE only (`report(drawnNoteCount:)` compares first), so it
    /// moves when detection lands or the stored table changes, never per tick.
    public private(set) var drawnNoteCount = 0

    /// The surface as the pane last reported it. `@ObservationIgnored`, the
    /// `PianoRollNoteSelectionBridge.surface` reason: it moves on every scroll
    /// and pointer tick, and an observable write at that rate would invalidate
    /// every reader of this bridge — including, from I4, a keyboard gate.
    @ObservationIgnored public private(set) var surface: PitchEditorSurfaceReport = .empty

    /// Bumped on every surface report — a CLOCK a bounded wait can stand on
    /// after a staged scroll, whose landing arrives through the readers.
    @ObservationIgnored public private(set) var surfaceSeq = 0

    /// Bumped by the pane AFTER it has applied a staged step — the seam's proof
    /// that the step went THROUGH the view (the m23-e echo-seam law). Never bumped
    /// by a routine report, so a relayout cannot satisfy a wait standing on a
    /// staged step.
    @ObservationIgnored public private(set) var stageAckSeq = 0

    /// Which pane INSTANCE's report is standing — see `clearSurface(from:)`.
    @ObservationIgnored private var surfaceReporter: UUID?

    // MARK: IN — asked of the pane

    /// ASKED OF THE PANE: run this pane's Escape path (`PitchEditorModel
    /// .handleEscapeKey`, the I4 ladder's seam, then the app's one decision) —
    /// without a keystroke, and without counting as a delivery to the key mount
    /// (`PitchEditorChromeLedger.escapeMountHits` measures THAT route, m34-k).
    /// Two producers: the debug tier's `escape` act, and (m34-k) the app's KEY
    /// MONITOR, which hands a real Escape here whenever it predicts the pane has
    /// something to take down (`EscapeKeyMonitorRouting.route`).
    public private(set) var escapeNonce = 0

    /// ASKED OF THE PANE: select every note it draws (m23-ap I4) — Edit ▸
    /// Select All / ⌘A, routed by `SelectAllMenuPolicy` to `.pitchEditorNotes`.
    /// ⚠️ **A USER ROUTE, NOT THE DEBUG STAGING NONCE**: `stageNonce` carries the
    /// debug tier's synthetic pointer, and a keystroke must not ride a debug
    /// seam (`PianoRollNoteSelectionBridge.selectAllNonce`'s rule).
    public private(set) var selectAllNonce = 0

    /// ASKED OF THE PANE: clear its note selection (m23-ap I4) — the debug
    /// tier's `clearSelection` act, and any outside surface that must drop the
    /// pane's selection without a keystroke. Esc does NOT ride this: the pane's
    /// own Escape path clears through the ladder (`EditorEscapeLadder`).
    public private(set) var clearSelectionNonce = 0

    /// ASKED OF THE PANE: a ⌫ or an Edit ▸ Delete the app routed to its NOTES
    /// (`DeleteSurface.pitchEditorNotes`). m23-ap I4 answered it with a refusal
    /// line; since I7b the pane CLEARS the selected notes — the one action its
    /// right-click Clear runs too (`PitchEditorModel.performNoteAction(.clear)`).
    public private(set) var deleteNonce = 0

    /// STAGED FOR THE PANE by the debug tier. The view watches the nonce, so a
    /// repeat of an identical step still applies.
    public private(set) var stageNonce = 0
    /// The step. `@ObservationIgnored`: the nonce is what observers watch.
    @ObservationIgnored public private(set) var stagedStep: PitchEditorStagedStep?

    public init() {}

    // MARK: Pane → bridge

    /// The pane's selection report (I4). Writes only on a CHANGE, so an
    /// unchanged report invalidates no reader (the ⌫ gate is one).
    public func report(hasNoteSelection: Bool) {
        guard self.hasNoteSelection != hasNoteSelection else { return }
        self.hasNoteSelection = hasNoteSelection
    }

    /// The pane's drawn-note count (I4). Writes only on a CHANGE, for the
    /// reason above — ⌘A's `Commands` body reads it.
    public func report(drawnNoteCount: Int) {
        guard self.drawnNoteCount != drawnNoteCount else { return }
        self.drawnNoteCount = drawnNoteCount
    }

    /// THE SURFACE, as drawn. `token` identifies the reporting pane INSTANCE.
    public func reportSurface(token: UUID, _ report: PitchEditorSurfaceReport) {
        surfaceReporter = token
        surface = report
        surfaceSeq &+= 1
    }

    /// The pane applied the staged step (and reports the surface it left).
    public func acknowledgeStage(token: UUID, _ report: PitchEditorSurfaceReport) {
        reportSurface(token: token, report)
        stageAckSeq &+= 1
    }

    /// THE PANE WENT AWAY. Token-guarded for the reason
    /// `PianoRollNoteSelectionBridge.clearSurface(from:)` gives, measured there:
    /// a clip switch tears one pane down and stands another up in an order
    /// SwiftUI does not promise, so a teardown clears only its OWN report.
    public func clearSurface(from token: UUID) {
        guard surfaceReporter == token else { return }
        surfaceReporter = nil
        surface = .empty
        report(hasNoteSelection: false)
        report(drawnNoteCount: 0)
        surfaceSeq &+= 1
    }

    // MARK: Outside → pane

    /// Ask the open pane to run its Escape path. Inert with no pane mounted.
    public func requestEscape() { escapeNonce &+= 1 }

    /// Ask the open pane to select every note it draws (⌘A). Inert with no
    /// pane mounted — the view watches without `initial:`.
    public func requestSelectAll() { selectAllNonce &+= 1 }

    /// Ask the open pane to clear its note selection. Inert with no pane.
    public func requestClearSelection() { clearSelectionNonce &+= 1 }

    /// Hand the open pane a ⌫ (or Edit ▸ Delete) the app routed to its notes —
    /// the pane clears them. Inert with no pane.
    public func requestDelete() { deleteNonce &+= 1 }

    /// Stage one step into the open pane. Inert with no pane mounted — the view
    /// watches without `initial:`, so a pane that appears later never replays it.
    public func stage(_ step: PitchEditorStagedStep) {
        stagedStep = step
        stageNonce &+= 1
    }
}
