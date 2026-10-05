import CoreGraphics
import DAWCore
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
// ⭐ **I5 (m23-ap) — THE STAGED RULER x.** Design §3 listed it; it waited for a
// consumer, because a step nothing consumes is a request that silently succeeds
// at nothing. `.ruler(x:_:)` is one tick of the pane's time ruler, handed to the
// ruler's own tick function (`PitchEditorView.rulerTick`), and its x is
// RULER-LOCAL — the viewport's space, because the ruler does not scroll — so a
// staged tick goes through the ONE place the scroll offset is added, exactly as
// a real one does. The surface report carries the geometry and the model's last
// placement, so the echo can show what was asked beside what the transport did.
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
//
// ⭐ **I2 (m23-ap):** a staged `.pinch` / `.pinchEnd` runs the pane's
// `MagnifyGesture` callbacks' own two functions (no synthetic event reaches a
// gesture, m23-g1 again), and the surface report carries the live pinch's
// anchor (`pinchAnchor`) so "captured once" can be read from outside.

/// The chord a pointer event carries, for the pitch editor.
///
/// ⇧/⌘ are the house CLICK chord (`ArrangeClickModifiers`, decided at press by
/// the router and at release by `PianoRollGridPress`); ⌥ is the Move tool's
/// FREE-pitch key, read per tick (C1) — and, since I5, the playhead's SNAP
/// BYPASS on the time ruler and on a ⌘-click on empty surface. The two never
/// meet: neither placement moves a note, and no note drag places the playhead.
/// Kept apart on purpose: the app's
/// `ArrangeClickModifiers.from(_:)` deliberately never maps ⌥, and widening that
/// shared type would change what ⌥-click means on the arrange.
///
/// W7-NTU U3 — `clickCount` is the event's own click count (1 for a click, 2
/// for the second click of a double-click), read only at a RELEASE: the Voice
/// tool's double-click puts a note back as sung. It is not a key, but it
/// rides the same way for the same reason: a `DragGesture.Value` carries
/// neither, so the live pane reads it from the event and a staged step passes
/// it explicitly (`clicks`).
public struct PitchEditorChord: Sendable, Equatable {
    public var shift: Bool
    public var command: Bool
    public var option: Bool
    /// The click count at a release (W7-NTU U3); 1 on every other tick.
    public var clickCount: Int

    public init(shift: Bool = false, command: Bool = false, option: Bool = false,
                clickCount: Int = 1) {
        self.shift = shift
        self.command = command
        self.option = option
        self.clickCount = max(1, clickCount)
    }

    /// No keys held.
    public static let none = PitchEditorChord()

    /// `NSEvent.EventType.leftMouseDown.rawValue` and `.leftMouseUp.rawValue`,
    /// as plain numbers so this module stays AppKit-free (the
    /// `ClipboardResponderRouting` rule: the app converts once, at the
    /// boundary). `PitchEditorVoiceToolTests` binds both to AppKit's own values.
    public static let leftMouseDownEventType: UInt = 1
    public static let leftMouseUpEventType: UInt = 2

    /// W7-NTU (2026-10-04) — THE CLICK COUNT OF THE EVENT BEING HANDLED, the
    /// one decision behind the Voice tool's double-click, here so tests can
    /// drive it with REAL `NSEvent`s (`PitchEditorVoiceToolTests`).
    ///
    /// `eventType` is the raw type of the event being handled (nil: none).
    /// `readClickCount` is called ONLY for a left mouse-down or mouse-up:
    /// `NSEvent.clickCount` is defined for mouse events alone, and reading it
    /// on any other raises, so a key event or a scroll never reaches it. Any
    /// other event, or none, is one click. A count below 1 reads 1.
    ///
    /// The live pane's `PitchEditorChord.current` (DAWApp) hands it
    /// `NSApp.currentEvent`. That THAT event is the mouse-up when SwiftUI's
    /// `DragGesture.onEnded` runs is the one link no headless test reaches: it
    /// needs a running event loop, a window and a real pointer.
    public static func clickCount(eventType: UInt?, readClickCount: () -> Int) -> Int {
        guard let eventType,
              eventType == leftMouseDownEventType || eventType == leftMouseUpEventType
        else { return 1 }
        return max(1, readClickCount())
    }

    /// The click half, for the router and the click table.
    public var clickModifiers: ArrangeClickModifiers {
        var mods: ArrangeClickModifiers = []
        if shift { mods.insert(.shift) }
        if command { mods.insert(.command) }
        return mods
    }
}

/// W7-NTU U1 — one control of the header group "Sound like the singer", as
/// the debug tier presses it: the group view's OWN callbacks, run by the pane
/// (`PitchEditorView.applyStagedStep`), because a synthetic event cannot
/// press a SwiftUI control (m23-g1).
public enum PitchEditorSingerAct: Sendable, Equatable {
    /// A press or drag tick on the "Keep voice size" track, at `fraction` of
    /// its width, ⌥ as `fine`.
    case voiceTrack(fraction: Double, fine: Bool)
    /// The track released.
    case voiceRelease
    /// The update line tapped.
    case update
    /// The Consonants switch clicked.
    case consonants
    /// A Slides step clicked.
    case slides(PitchEditorSlideStep)
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
    /// m23-ap I2 — one tick of a pinch: the gesture's START location (content
    /// space, like every point here) and its CUMULATIVE magnification, handed
    /// to the same function `MagnifyGesture.onChanged` calls. The only way to
    /// drive the POINTER-anchored zoom in the live pane: `debug.panelLayout`
    /// moves the same slot but anchors on the playhead or the centre.
    case pinch(CGPoint, CGFloat)
    /// m23-ap I2 — the pinch ended: `MagnifyGesture.onEnded`'s function.
    case pinchEnd
    /// m23-ap I5 — one tick of the TIME RULER at this x, RULER-LOCAL (the
    /// viewport's space: x 0 is the ruler's left edge, whatever the scroll), with
    /// the chord's ⌥ as the snap bypass. Handed to the ruler's own tick function,
    /// so the scroll offset is added where a real tick adds it and nowhere else.
    case ruler(x: CGFloat, PitchEditorChord)
    /// UE-1 — the header's "Find sounds with no pitch" button was pressed:
    /// its OWN function (`PitchEditorView.runFindSounds`). A synthetic event
    /// cannot press a SwiftUI button (m23-g1), so the debug tier runs what the
    /// button runs.
    case findSounds
    /// m23-ap C5b-4b — keys held with the button UP: what the pane's
    /// `.flagsChanged` monitor writes (`PitchEditorView.commandHeld`, whose ⌘
    /// shows the playhead's ghost over empty surface, I5, and the brush band
    /// and help over a note, C5b-4b). A synthetic step carries no
    /// `NSEvent.modifierFlags`, so without this a gate could not show either
    /// affordance; the next real `.flagsChanged` or the pointer leaving the
    /// surface replaces it, exactly as it replaces a real key's.
    case keys(PitchEditorChord)
    /// W7-NTU U1 — a control of the header group "Sound like the singer"
    /// pressed: the group view's own callback (`PitchEditorSingerAct`).
    case singer(PitchEditorSingerAct)

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
        case .pinch: return "pinch"
        case .pinchEnd: return "pinchEnd"
        case .ruler: return "ruler"
        case .findSounds: return "findSounds"
        case .keys: return "keys"
        case .singer: return "singer"
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
    /// UE-1 — where the blob's segment came from (`NoteBlob.origin`, a
    /// `NoteOrigin` raw value: `detected`, `transition` or `unpitched`), so a
    /// staging gate can find the SOUNDS among the drawn notes.
    public var origin: String
    /// UE-1 — §1.7's sentence for a sound (`NoteBlob.soundReadout`), `nil` for
    /// a note.
    public var soundReadout: String?
    /// UE-2 — the look the surface was handed for it (`NoteBlob.look`, a
    /// `PitchEditorBlobLook` raw value: `note`, `sound` or `cleared`) — the
    /// value the Canvas switches on, so a gate reads the look, not a guess.
    public var look: String

    public init(id: UUID, rect: CGRect, cleared: Bool = false, levelDb: Double = 0,
                levelReadout: String? = nil, origin: String = NoteOrigin.detected.rawValue,
                soundReadout: String? = nil, look: String = PitchEditorBlobLook.note.rawValue) {
        self.look = look
        self.id = id
        self.rect = rect
        self.cleared = cleared
        self.levelDb = levelDb
        self.levelReadout = levelReadout
        self.origin = origin
        self.soundReadout = soundReadout
    }
}

/// UE-1 — "Find sounds with no pitch" as the pane holds it: whether the header
/// OFFERS it (`PitchEditorModel.offersFindSounds`), and the line about the last
/// press (`PitchEditorModel.findSoundsLine`), read from the model, never
/// re-derived.
public struct PitchEditorFindSoundsReport: Sendable, Equatable {
    public var offered: Bool
    public var line: PitchEditorFindSoundsLine?

    public init(offered: Bool = false, line: PitchEditorFindSoundsLine? = nil) {
        self.offered = offered
        self.line = line
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

/// m23-ap I6b — the edge autoscroll as the pane holds it: `debug.pitchEditor`'s
/// `autoscroll` echo. From the pane's own state, never re-derived.
public struct PitchEditorAutoScrollReport: Sendable, Equatable {
    /// The held-pointer repeat clock is running. Only a LIVE pointer arms it,
    /// so a staged step always reads `false` here: the echo's control leg.
    public var armed: Bool
    /// Rows the window grew by during the press in flight, or the last one
    /// (`PitchEditorModel.edgeGrownRows`).
    public var grownRows: Int
    /// The edge the last edge step acted at, or `nil` (`PitchEditorModel.lastEdge`).
    public var lastSide: PitchEditorEdge?
    /// The dragged note's rect as the drag overlay draws it (the pressed note
    /// at `targetMidi`, the overlay's own `geometry.rect(startSeconds:…)` call),
    /// or `nil` with no drag: what "the note stays under the pointer" is read
    /// from. Content space, like every rect here.
    public var dragRect: CGRect?

    public init(armed: Bool = false, grownRows: Int = 0, lastSide: PitchEditorEdge? = nil,
                dragRect: CGRect? = nil) {
        self.armed = armed
        self.grownRows = grownRows
        self.lastSide = lastSide
        self.dragRect = dragRect
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
    /// I2 — the live pinch's anchor as the pane holds it (captured on the
    /// pinch's first tick), or `nil` when no pinch is live. Identical across a
    /// pinch's ticks is what "captured once" looks like from outside; non-nil
    /// with no pinch under way is the stale anchor the pane's doc warns about.
    public var pinchAnchor: PitchEditorZoomAnchor?
    /// I5 — the geometry the pane draws with (the playhead's one beat→x
    /// mapping, `PitchEditorGeometry.x(forProjectBeat:)`), so the echo places
    /// the transport's position through it instead of re-deriving a scale.
    /// `nil` when no pane is reporting.
    public var geometry: PitchEditorGeometry?
    /// I5 — how many playhead placements the pane's model has asked for
    /// (`PitchEditorModel.placementCount`), and the project beat the last one
    /// asked for (`nil` before any): what was ASKED, for the echo to set beside
    /// the transport's position, which is what the store DID.
    public var placementCount: Int
    public var lastPlacementBeat: Double?
    /// I6b — the edge autoscroll: the clock, the growth, the last edge, and
    /// the dragged note's drawn rect.
    public var autoscroll: PitchEditorAutoScrollReport
    /// UE-1 — "Find sounds with no pitch": offered or not, and its line.
    public var findSounds: PitchEditorFindSoundsReport = PitchEditorFindSoundsReport()

    public init(viewport: PitchEditorViewport = .unmeasured, noteRects: [PitchEditorNoteRect] = [],
                press: PitchEditorPress? = nil, lastRelease: PitchEditorReleaseAction? = nil,
                hoverPoint: CGPoint? = nil,
                selection: PitchEditorSelectionReport = PitchEditorSelectionReport(),
                band: PitchEditorBandReport? = nil,
                noteMenu: [PitchEditorNoteMenu.Item] = [],
                pitchWindow: PitchEditorWindowReport? = nil,
                pinchAnchor: PitchEditorZoomAnchor? = nil,
                geometry: PitchEditorGeometry? = nil,
                placementCount: Int = 0,
                lastPlacementBeat: Double? = nil,
                autoscroll: PitchEditorAutoScrollReport = PitchEditorAutoScrollReport(),
                findSounds: PitchEditorFindSoundsReport = PitchEditorFindSoundsReport()) {
        self.findSounds = findSounds
        self.viewport = viewport
        self.noteRects = noteRects
        self.press = press
        self.lastRelease = lastRelease
        self.hoverPoint = hoverPoint
        self.selection = selection
        self.band = band
        self.noteMenu = noteMenu
        self.pitchWindow = pitchWindow
        self.pinchAnchor = pinchAnchor
        self.geometry = geometry
        self.placementCount = placementCount
        self.lastPlacementBeat = lastPlacementBeat
        self.autoscroll = autoscroll
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

    /// UE-2 — REPORTED BY THE PANE: what KINDS its selection holds
    /// (`PitchEditorModel.selectionKinds`) — the Edit menu Clear title's noun
    /// (`DeleteMenuPolicy`'s `pitchEditorSelectionKinds`: "Clear Selected
    /// Sounds"). Observable, because a `Commands` body must re-title the item;
    /// written on CHANGE only, on a selection change, never per pointer tick.
    public private(set) var selectionKinds: Set<PitchEditorNoteMenu.Kind> = []

    /// UE-2 — each clip's last Find-sounds DECLINE, held HERE because this
    /// bridge outlives the pane's `.id(clip.id)` rebuilds
    /// (`PitchEditorFindSoundsMemory`). The pane's model is handed it once.
    public let findSoundsMemory = PitchEditorFindSoundsMemory()

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

    /// UE-2 — the selection's kinds. Writes only on a CHANGE, for the reason
    /// above — Edit ▸ Delete's `Commands` body reads it.
    public func report(selectionKinds: Set<PitchEditorNoteMenu.Kind>) {
        guard self.selectionKinds != selectionKinds else { return }
        self.selectionKinds = selectionKinds
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
        report(selectionKinds: [])
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
