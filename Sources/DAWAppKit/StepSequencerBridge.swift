import CoreGraphics
import Foundation
import Observation

/// The step sequencer's state that OUTLIVES a clip switch, plus the debug-tier
/// seam that lets a gate drive the surface (m23-cq-1).
///
/// WHY A BRIDGE OBJECT rather than `@State` inside the editor view — the same
/// three reasons `PianoRollNoteSelectionBridge` gives, and one of its own:
///
///  - **The editor view is recreated on every clip switch** (`.id(clip.id)`), so
///    a `@State` mode would drop the user back into the piano roll every time
///    they clicked the next drum clip — precisely the workflow this surface
///    exists to serve.
///  - **The staging seam must drive the SAME path the mouse drives.** A
///    view-local flag would light for the pointer and stay dark for the seam,
///    which is the m23-an lesson written down after a chip that the seam could
///    not reach.
///  - **The view's `PianoRollModel` is `@State private`** — nothing outside can
///    read the draft or reach in to toggle a cell. This object is the only
///    channel, in either direction.
///
/// ⚠️ **SESSION STATE, NEVER PERSISTED AND NEVER PROJECT DATA.** The mode is not
/// a `PanelLayoutStore` dimension on purpose: every sticky dimension is a leak
/// class that changes a gate's verdict in a later cycle (the m23-be/bf/bg
/// finding — pin to app defaults, never to ambient), and "which editor was I in
/// last week" is not worth one. The chip is one click, and a fresh launch always
/// resolves from the TRACK (`ClipEditorModePolicy`), which is the honest default.
@MainActor
@Observable
public final class StepSequencerBridge {

    // MARK: - State the user (or the seam) sets

    /// The mode the user picked this session, or nil while the track's kind
    /// still decides. Read through `mode(isDrumKit:)`, never directly by a view.
    public private(set) var modeOverride: ClipEditorMode?

    /// The step size the Pro picker offers. Simple locks to 1/16
    /// (`StepSequencerGeometry.effectiveResolution`), so this is the PICKED
    /// value and never the effective one — flipping to Simple and back restores
    /// it (the `ClipSnap` rule).
    public private(set) var pickedResolution: SnapResolution = StepSequencerGeometry.fallbackResolution

    /// Bumped per staged toggle so the view's `.onChange` fires even when the
    /// same cell is asked for twice — a gate MUST be able to toggle one cell on
    /// and then off, and those are two requests carrying identical payloads (the
    /// `externalScrollNonce` / `deleteNonce` reason).
    public private(set) var toggleNonce = 0

    /// The cell the staged toggle names. `@ObservationIgnored` because the nonce
    /// is what observers watch; a second observable property would fire a second
    /// update for one request.
    @ObservationIgnored public private(set) var stagedCell: StepCell?

    // MARK: - State the DRAWING LAYER reports back

    /// The mode the pane is ACTUALLY showing.
    ///
    /// ⚠️ Written ONLY by the grid view's report and its teardown — never by
    /// `setMode`. A seam that echoed its own input would agree with itself while
    /// the pane showed something else (the m23-o2 `widthSource` failure), and a
    /// build that kept the value and drew nothing would leave every headless
    /// test and every echo leg green (m23-v, measured).
    public private(set) var reportedMode: ClipEditorMode = .notes

    /// The lanes the grid drew, in drawn order (top row first).
    public private(set) var reportedLanes: [StepSequencerLane] = []
    /// The columns the grid drew.
    public private(set) var reportedStepCount = 0
    /// Beats per column as the grid resolved it (density-locked in Simple).
    public private(set) var reportedStepBeats: Double = 0
    /// The filled cells the grid drew, sorted step-major — the pattern itself,
    /// with the weight and the latency each box was drawn at.
    public private(set) var reportedFills: [StepCellFill] = []

    /// The filled cells alone, for a caller that only needs the pattern.
    public var reportedFilledCells: [StepCell] { reportedFills.map(\.cell) }
    /// The cell geometry the grid drew at, so a probe computes a click point
    /// from the app's own numbers rather than from a hardcoded 30×24 (the
    /// `ArrangeLaneGeometry` ladder rule).
    public private(set) var reportedRowHeight: CGFloat = 0
    public private(set) var reportedStepWidth: CGFloat = 0
    /// m23-ap I5-F4 — where the drawn columns sit on the SONG's grid: how far
    /// the clip's first beat sits past column 0's line (0 on a line), the song
    /// beat column 0 starts at, and the columns the grid drew as bar lines with
    /// their SONG bar numbers. Without these a probe could not say where an
    /// off-grid clip's boxes are, nor compare the step grid's bars with the roll's.
    public private(set) var reportedPhaseBeats: Double = 0
    public private(set) var reportedFirstStepSongBeat: Double = 0
    public private(set) var reportedBarMarks: [StepBarMark] = []

    /// The grid instance whose report is currently standing, or nil when no grid
    /// is mounted. Never observable — it is the reporters' own bookkeeping, not
    /// state any view or echo reads (see `reportNoGrid(from:)`).
    @ObservationIgnored private var lastReporter: UUID?

    /// Bumped on every report — the seam's proof that a staged change has been
    /// THROUGH the view (the m23-e echo-seam law: an echo that reports state the
    /// caller just changed must wait for the view to confirm, or it answers with
    /// the PREVIOUS call's state and stale-GREENs a gate).
    public private(set) var reportSeq = 0

    public init() {}

    // MARK: - Resolution

    /// The mode to show for a clip on a track of this kind.
    public func mode(isDrumKit: Bool) -> ClipEditorMode {
        ClipEditorModePolicy.resolve(override: modeOverride, isDrumKit: isDrumKit)
    }

    /// The step size the grid actually draws at, given the panel's density.
    public func effectiveResolution(density: PanelDensity) -> SnapResolution {
        StepSequencerGeometry.effectiveResolution(density: density, picked: pickedResolution)
    }

    // MARK: - Mutators (the chips and the seam share these)

    /// The user (or the seam) picked a mode. Latches the override, so the
    /// track's kind stops deciding from here on.
    public func setMode(_ mode: ClipEditorMode) { modeOverride = mode }

    /// The user (or the seam) picked a step size.
    public func setResolution(_ resolution: SnapResolution) { pickedResolution = resolution }

    /// Ask the visible grid to toggle a cell — the ONLY way anything outside can
    /// reach the editor's private draft. Inert with no grid mounted, like every
    /// other nonce in this tree.
    public func stageToggle(_ cell: StepCell) {
        stagedCell = cell
        toggleNonce += 1
    }

    // MARK: - Reports (called BY the drawing layer)

    /// The grid drew this. Called from the same view that hosts the Canvas, off
    /// the same value the Canvas is given, so removing the layer removes the
    /// reporter with it.
    ///
    /// - Parameter token: identifies the reporting grid INSTANCE. See
    ///   `reportNoGrid(from:)` — this is what makes a clip switch safe.
    ///
    /// The three song-grid fields (m23-ap I5-F4) default to a clip on a line at
    /// the song's start, so an older caller reads as exactly that; the grid view
    /// passes all three from the geometry it drew.
    public func report(token: UUID,
                       lanes: [StepSequencerLane], stepCount: Int, stepBeats: Double,
                       fills: [StepCellFill], rowHeight: CGFloat, stepWidth: CGFloat,
                       phaseBeats: Double = 0, firstStepSongBeat: Double = 0,
                       barMarks: [StepBarMark] = []) {
        lastReporter = token
        reportedMode = .steps
        reportedLanes = lanes
        reportedStepCount = stepCount
        reportedStepBeats = stepBeats
        reportedFills = fills
        reportedRowHeight = rowHeight
        reportedStepWidth = stepWidth
        reportedPhaseBeats = phaseBeats
        reportedFirstStepSongBeat = firstStepSongBeat
        reportedBarMarks = barMarks
        reportSeq &+= 1
    }

    /// THE GRID WENT AWAY — the pane switched back to the piano roll, or the
    /// editor closed. Load-bearing for the same reason
    /// `PianoRollNoteSelectionBridge.clear()` is: a latched lane set would let
    /// the seam answer with a grid nothing is drawing, and every diagnosis made
    /// through that echo would be wrong.
    ///
    /// ⚠️ **THE TOKEN IS WHY A CLIP SWITCH DOES NOT BLANK A LIVE GRID.** The
    /// editor is rebuilt on `.id(clip.id)`, so switching from one drum clip to
    /// the next tears down one grid and stands up another — and SwiftUI does not
    /// promise which of the two runs first (the m23-x measurement of exactly
    /// this race between an outgoing `.onDisappear` and an incoming `.onAppear`,
    /// one file over). A teardown clears only while the LAST report was its own:
    /// the incoming grid's report supersedes the outgoing grid's clear whichever
    /// order they arrive in.
    public func reportNoGrid(from token: UUID) {
        guard lastReporter == token else { return }
        lastReporter = nil
        reportedMode = .notes
        reportedLanes = []
        reportedStepCount = 0
        reportedStepBeats = 0
        reportedFills = []
        reportedRowHeight = 0
        reportedStepWidth = 0
        reportedPhaseBeats = 0
        reportedFirstStepSongBeat = 0
        reportedBarMarks = []
        reportSeq &+= 1
    }
}
