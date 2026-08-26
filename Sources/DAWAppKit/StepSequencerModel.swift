import CoreGraphics
import Foundation
import DAWCore

// The STEP SEQUENCER (m23-cq-1) — a grid over an EXISTING MIDI clip's notes.
// Rows are pitches, columns are steps; clicking an empty cell adds a note and
// clicking a filled one removes it. Everything that DECIDES anything lives in
// this file, headless, because `DAWApp` is an executable target with no test
// target: anything put there is untestable forever.
//
// ⚠️ IT IS A SECOND VIEW OVER ONE NOTE STORE, NOT A SECOND STORE. Every
// function here takes `[MIDINote]` and RETURNS `[MIDINote]`; none of them owns
// an array. The live draft stays `PianoRollModel.draft`, and the write path out
// is the roll's own `commit()` → `ProjectStore.setClipNotes`. Two editors that
// committed by different routes would disagree about a clip and undo would
// differ by which one you had used.

/// Which editor the clip-editor pane is showing (m23-cq-1).
///
/// ⚠️ **NOT a third `EditorSurface` case.** `EditorSurfaceRouter` answers a
/// different question — arrange vs. editor, for ⌘+/⌘−/⌘0 and DELETE routing —
/// and the step sequencer is the SAME pane as the piano roll for every purpose
/// that router serves: it sits in the editor pane, a click inside it engages
/// `.pianoRoll`, and ⌘+ zooms the roll's own zoom slot. Adding a case to that
/// exhaustively-swept enum would make every consumer handle a state that means
/// nothing to it.
public enum ClipEditorMode: String, Sendable, Equatable, CaseIterable {
    /// The piano roll (the shipped editor): draw, drag and resize note pills.
    case notes
    /// The step grid: click a cell to toggle a note on or off.
    case steps

    /// Chip label — uppercase at the draw site, like every other chip pair.
    public var label: String {
        switch self {
        case .notes: "Notes"
        case .steps: "Steps"
        }
    }
}

/// THE ONE HOME for "which editor does this clip open in?" (m23-cq-1).
///
/// A drum-kit track opens in STEPS and everything else opens in NOTES — until
/// the user picks a mode, after which their pick wins for the rest of the
/// session. Two claims worth stating separately:
///
///  - **The drum default is the feature's whole reason to exist.** The item's
///    order was "unblock drums entry": a beginner who adds a Drums track,
///    double-clicks a clip and lands in a piano roll has met exactly the
///    friction this surface removes. A default that never fires unless you
///    already know the chip exists is not a default.
///  - **The override is a plain "the user's pick wins", never a per-clip
///    memory.** Once `override` is non-nil the track's kind stops being read at
///    all, so a user who deliberately opened a drum clip in the piano roll does
///    not get thrown back into the grid by clicking the next drum clip. That is
///    the `ClipSnap.effective(density:picked:)` shape: a pure resolve that never
///    mutates the picked value, so flipping back restores it.
public enum ClipEditorModePolicy {

    /// - Parameters:
    ///   - override: the mode the user picked this session, or nil if they have
    ///     not touched the chip.
    ///   - isDrumKit: `SMFProjectExporter.isDrumKit(track)` — the app's ONE
    ///     predicate for the question, made `public` for this call rather than
    ///     re-expressed here.
    nonisolated public static func resolve(override: ClipEditorMode?,
                                           isDrumKit: Bool) -> ClipEditorMode {
        if let override { return override }
        return isDrumKit ? .steps : .notes
    }
}

/// One row of the step grid: a pitch and the name the user reads for it.
public struct StepSequencerLane: Sendable, Equatable, Identifiable {
    /// MIDI pitch this row writes.
    public let pitch: Int
    /// The row label. A GM percussion name on a drum kit ("Acoustic Snare"),
    /// a scientific pitch name otherwise ("C4"). Never invented: see
    /// `StepSequencerLanes.label(forPitch:isDrumKit:)`.
    public let label: String
    /// True when the label came from the GM percussion key map rather than from
    /// the note-name derivation — the property a probe uses to assert that drum
    /// lanes are NAMED and not numbered.
    public let isNamedPercussion: Bool

    public var id: Int { pitch }

    public init(pitch: Int, label: String, isNamedPercussion: Bool) {
        self.pitch = pitch
        self.label = label
        self.isNamedPercussion = isNamedPercussion
    }
}

/// WHICH ROWS THE GRID SHOWS, and what each one is called.
public enum StepSequencerLanes {

    /// The melodic default window when the clip is empty: C3…B4, two octaves
    /// with middle C (60) inside them. Two octaves is the smallest window that
    /// can hold an ordinary bass line or a chord voicing without scrolling, and
    /// anchoring it on middle C puts it where the piano roll opens
    /// (`.defaultScrollAnchor(.center)`), so switching modes does not teleport
    /// the user's pitch view.
    public static let melodicWindow: ClosedRange<Int> = 48...71

    /// The lanes for a clip, HIGH PITCH FIRST (row 0 is the highest note).
    ///
    /// ⚠️ **DESCENDING, the piano roll's axis, and that is a deliberate break
    /// with Logic's step sequencer** (which puts the kick on the top row). This
    /// grid and the note grid are two modes of ONE pane over ONE clip: flipping
    /// the vertical axis between them would move every note under the user's
    /// hand at the moment they toggle the chip. The GM percussion map happens to
    /// ascend kick → snare → hats → toms → cymbals, so descending pitch also
    /// lands the kit in the conventional drum-machine order with the kick at the
    /// bottom, for free and with no special case.
    ///
    /// ⚠️ **EVERY PITCH PRESENT IN THE CLIP GETS A LANE**, whatever the base set
    /// says. A note the grid cannot show is a note the grid cannot delete, and
    /// the toggle is this surface's ONLY deletion path (mouse-only, by design —
    /// no DELETE key here). The union is what makes "every note is reachable"
    /// structural rather than promised: an uncovered GM percussion note (39 hand
    /// clap, 54 tambourine) or a melodic note two octaves above the window still
    /// gets a row, labelled by its note name.
    nonisolated public static func lanes(isDrumKit: Bool, notes: [MIDINote]) -> [StepSequencerLane] {
        var pitches = Set(notes.map(\.pitch))
        if isDrumKit {
            pitches.formUnion(InstrumentFamilyResolver.percussionNotes.map(\.note))
        } else {
            pitches.formUnion(melodicWindow)
        }
        return pitches.sorted(by: >).map { pitch in
            let named = isDrumKit ? InstrumentFamilyResolver.percussionNote(pitch) : nil
            return StepSequencerLane(
                pitch: pitch,
                // `Fundamental.noteName` is the repo's ONE scientific-pitch
                // name (which itself defers to `KeyEstimate.pitchClassesSharp`,
                // the sole pitch-class table) — a private "C#/D#…" array here
                // would be the third home for twelve strings.
                label: named?.gmName ?? Fundamental.noteName(midiNote: pitch),
                isNamedPercussion: named != nil)
        }
    }
}

/// One cell of the grid — a step index and the pitch of its row.
public struct StepCell: Sendable, Hashable, Comparable {
    public let step: Int
    public let pitch: Int

    public init(step: Int, pitch: Int) {
        self.step = step
        self.pitch = pitch
    }

    /// Sorted step-major, then by descending pitch — the order the lanes are
    /// drawn in, so an echoed cell list reads like the grid.
    public static func < (a: StepCell, b: StepCell) -> Bool {
        a.step != b.step ? a.step < b.step : a.pitch > b.pitch
    }
}

/// A filled cell as the grid DRAWS it: which box, how hard the hit, and whether
/// it is latent (an onset at or past the clip end — store-legal, never sounded,
/// so it takes the m19-g ghost treatment rather than the lit one).
public struct StepCellFill: Sendable, Equatable {
    public let cell: StepCell
    /// The loudest velocity in the cell (a cell can hold more than one note).
    public let velocity: Int
    /// True when the engine never sounds this onset (`startBeat >= clip length`,
    /// the strict rule `MIDISchedule.buildEvents` applies).
    public let isLatent: Bool

    public init(cell: StepCell, velocity: Int, isLatent: Bool) {
        self.cell = cell
        self.velocity = velocity
        self.isLatent = isLatent
    }
}

/// The grid's geometry: how many columns, how tall the rows, and where every
/// cell is. Built once per render from the clip + the chosen step resolution, so
/// the drawing, the hit test and the edit can never disagree about what a cell
/// is (the `ArrangeMarquee` "takes the resolved bands as input" property).
public struct StepSequencerGeometry: Sendable, Equatable {

    /// One row's height. Taller than the roll's 14 pt semitone row on purpose:
    /// a step grid has ~17 rows, not 128, and the row carries a readable name.
    public static let defaultRowHeight: CGFloat = 24
    /// One step column's width. Sized so a 16-step bar (1/16 steps in 4/4) is
    /// ~480 pt — the whole bar readable at the default window without scrolling.
    public static let defaultStepWidth: CGFloat = 30
    /// The lane-name gutter. Wider than the roll's 54 pt keyboard because it
    /// carries prose ("Acoustic Snare"), not a two-glyph key name.
    public static let laneGutterWidth: CGFloat = 108

    /// The step size the grid falls back to when the caller's resolution has no
    /// grid at all (`SnapResolution.off`). A step grid IS a grid — "off" is not
    /// a state this surface can render — and 1/16 is the drum-programming
    /// default the picker opens on.
    public static let fallbackResolution: SnapResolution = .sixteenth

    public let lanes: [StepSequencerLane]
    /// Beats per step column (`SnapResolution.beats`, with `off` mapped to
    /// `fallbackResolution`).
    public let stepBeats: Double
    /// Number of step columns drawn.
    public let stepCount: Int
    public let rowHeight: CGFloat
    public let stepWidth: CGFloat
    /// The clip's own length in beats — the boundary past which a step is
    /// LATENT (the engine sounds an onset only while `startBeat < length`,
    /// strict). Drawn as the roll's out-of-clip shade.
    public let clipLengthBeats: Double
    /// Beats per bar of the meter governing this clip — the column emphasis, so
    /// a 3/4 clip groups its steps in threes.
    public let beatsPerBar: Int

    /// Where the lane stack opens when the grid is taller than the pane.
    ///
    /// ⚠️ **MEASURED, NOT REASONED.** A 17-lane kit is 424 pt tall and the
    /// editor pane at the default window is ~390 pt, so the first capture of
    /// this surface opened on **Ride Cymbal 2 … Pedal Hi-Hat with the kick, the
    /// snare and the closed hat all below the fold** — a drum grid whose whole
    /// reason to exist is a kick/snare/hat pattern, showing none of the three
    /// until you scroll. Rows run high-pitch-first (the piano roll's axis) and
    /// the GM map puts the common kit at the BOTTOM, so a drum grid opens at
    /// the bottom.
    ///
    /// A melodic grid opens CENTRED instead — its window is two octaves around
    /// middle C, which is exactly where the piano roll opens
    /// (`.defaultScrollAnchor(.center)`), so switching modes does not teleport
    /// the user's pitch view.
    public let opensAtBottom: Bool

    /// Builds the geometry for a clip.
    ///
    /// ⚠️ **THE STEP COUNT COVERS EVERY NOTE, not just the clip.** It is the
    /// clip length OR the furthest note ONSET, whichever is later — the
    /// `PianoRollModel.contentWidth` rule, for the `StepSequencerLanes.lanes`
    /// reason: a note left beyond the clip end by a trim is store-legal, latent,
    /// and would otherwise be un-toggleable from the only surface that can
    /// delete without the keyboard. It is the onset (not the end) because a
    /// cell IS an onset: extending for a tail would add columns nothing can
    /// ever fill.
    nonisolated public static func make(
        isDrumKit: Bool,
        notes: [MIDINote],
        clipLengthBeats: Double,
        resolution: SnapResolution,
        beatsPerBar: Int,
        rowHeight: CGFloat = StepSequencerGeometry.defaultRowHeight,
        stepWidth: CGFloat = StepSequencerGeometry.defaultStepWidth
    ) -> StepSequencerGeometry {
        let step = stepBeats(for: resolution)
        let length = max(0, clipLengthBeats)
        let furthestOnset = notes.map(\.startBeat).max() ?? 0
        let span = max(length, furthestOnset + step)
        let count = max(1, Int((span / step - 1e-9).rounded(.up)))
        return StepSequencerGeometry(
            lanes: StepSequencerLanes.lanes(isDrumKit: isDrumKit, notes: notes),
            stepBeats: step,
            stepCount: count,
            rowHeight: rowHeight,
            stepWidth: stepWidth,
            clipLengthBeats: length,
            beatsPerBar: max(1, beatsPerBar),
            opensAtBottom: isDrumKit)
    }

    /// Beats per step for a resolution — `off` has no grid, so it takes the
    /// 1/16 fallback rather than silently drawing one column per beat.
    nonisolated public static func stepBeats(for resolution: SnapResolution) -> Double {
        resolution.beats ?? (fallbackResolution.beats ?? 0.25)
    }

    /// The resolutions the STEP picker offers: every `SnapResolution` that has a
    /// grid. `off` is excluded because it names the absence of the thing this
    /// surface is made of — reuse of the app's ONE grid vocabulary, minus the
    /// one case that cannot be rendered.
    nonisolated public static var pickableResolutions: [SnapResolution] {
        SnapResolution.allCases.filter { $0.beats != nil }
    }

    /// Simple locks the step grid to 1/16 and hides the picker; Pro honours the
    /// pick. The `ClipSnap.effective(density:picked:)` shape — pure, and it
    /// never mutates the picked value, so flipping back to Pro restores it.
    ///
    /// This is what keeps the panel's SIMPLE/PRO chip from becoming the
    /// do-nothing toggle the design language forbids while the sequencer is the
    /// visible band.
    nonisolated public static func effectiveResolution(density: PanelDensity,
                                                       picked: SnapResolution) -> SnapResolution {
        density == .simple ? fallbackResolution : picked
    }

    // MARK: - Geometry

    public var contentWidth: CGFloat { CGFloat(stepCount) * stepWidth }
    public var contentHeight: CGFloat { CGFloat(lanes.count) * rowHeight }
    public var contentSize: CGSize { CGSize(width: contentWidth, height: contentHeight) }

    /// Clip-local beat a step column starts at.
    public func beat(forStep step: Int) -> Double { Double(step) * stepBeats }

    /// x of a step column's leading edge, in content coordinates.
    public func x(forStep step: Int) -> CGFloat { CGFloat(step) * stepWidth }

    /// Top y of a lane row, in content coordinates.
    public func y(forLane index: Int) -> CGFloat { CGFloat(index) * rowHeight }

    /// The step column a clip-local beat falls in.
    ///
    /// ⚠️ **THE EPSILON IS LOAD-BEARING, NOT DEFENSIVE ROUNDING.** A triplet
    /// grid's step is 1/3 or 1/6 of a beat, and `(2.0/3.0) / (1.0/3.0)` is
    /// 1.9999999999999998 in binary floating point: a plain `floor` puts the
    /// note that starts exactly ON step 2 into step 1, so the sequencer would
    /// draw a note one column left of where the roll draws it and the toggle
    /// round-trip would break on every triplet grid. Anything within a
    /// millionth of a boundary belongs to that boundary.
    public func stepIndex(forBeat beat: Double) -> Int {
        let scaled = beat / stepBeats
        let nearest = scaled.rounded()
        if abs(scaled - nearest) < 1e-6 { return Int(nearest) }
        return Int(scaled.rounded(.down))
    }

    /// Row index of a pitch, or nil when no lane carries it.
    public func laneIndex(ofPitch pitch: Int) -> Int? {
        lanes.firstIndex { $0.pitch == pitch }
    }

    /// A cell's rectangle in content coordinates.
    public func cellRect(step: Int, lane index: Int) -> CGRect {
        CGRect(x: x(forStep: step), y: y(forLane: index), width: stepWidth, height: rowHeight)
    }

    /// The cell under a content-space point, or nil outside the grid. The ONE
    /// hit test: the click gesture and the staging seam both route through it,
    /// so a probe cannot address a cell the mouse could not.
    public func cell(at point: CGPoint) -> StepCell? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let step = Int((point.x / stepWidth).rounded(.down))
        let row = Int((point.y / rowHeight).rounded(.down))
        guard step >= 0, step < stepCount, row >= 0, row < lanes.count else { return nil }
        return StepCell(step: step, pitch: lanes[row].pitch)
    }

    /// True when a step column starts a bar — the emphasized gridline, and the
    /// column the SF Mono step number is drawn over.
    public func isBarStart(step: Int) -> Bool {
        stepsPerBar > 0 && step % stepsPerBar == 0
    }

    /// True when a step column starts a whole beat — the mid-weight gridline
    /// that makes a 16-step bar countable in fours.
    public func isBeatStart(step: Int) -> Bool {
        stepsPerBeat > 0 && step % stepsPerBeat == 0
    }

    /// Steps in one beat, rounded — 0 when a step is longer than a beat (Bar,
    /// Beat resolutions), which is the "no sub-beat emphasis" case.
    public var stepsPerBeat: Int {
        let raw = 1.0 / stepBeats
        guard raw >= 1.5 else { return 0 }
        return Int(raw.rounded())
    }

    /// Steps in one bar — the bar-line stride.
    public var stepsPerBar: Int {
        let raw = Double(beatsPerBar) / stepBeats
        guard raw >= 1.5 else { return 0 }
        return Int(raw.rounded())
    }

    /// x of the clip end — everything right of it is latent (the m19-g out-of-
    /// clip shade, drawn at the same 0.28 + `gridEmphasis` hairline as the
    /// roll's three bands).
    public var clipEndX: CGFloat { CGFloat(clipLengthBeats / stepBeats) * stepWidth }

    /// One-based bar number a step falls in — the SF Mono column readout.
    public func barNumber(forStep step: Int) -> Int {
        guard stepsPerBar > 0 else { return step + 1 }
        return step / stepsPerBar + 1
    }
}

/// THE TOGGLE: the whole edit vocabulary of this surface, as pure functions over
/// a note array.
///
/// ⚠️ **ONE GESTURE IS BOTH ENTRY AND DELETION, and that is the reason this
/// surface was safe to build now.** The app WAS sitting on an undiagnosed
/// keyboard-routing report (m23-cf: a bare DELETE reported dead on notes and
/// clips), and a second keyboard-driven editor on top of it would have compounded
/// the failure. Click-to-toggle needs no key at all — which INVERTED the risk:
/// the sequencer is a working note-deletion route that did not depend on the
/// broken key.
///
/// ⭐ **m23-cf IS FIXED as of 2026-08-12 — user-confirmed by hand ("we fixed
/// delete button, it works ok"). The instruction that used to close this
/// paragraph — "must re-derive the m23-cf question first" — IS DISCHARGED and
/// must not be re-quoted as a blocker.** A shortcut here is now an ordinary
/// design decision about this surface, judged on its own merits.
public enum StepSequencerEdit {

    /// Velocity a toggled-on note gets — the SAME default `PianoRollModel.addNote`
    /// uses, so a note authored in either editor sounds identically. (Velocity is
    /// editable in the roll's velocity lane; the step grid deliberately has no
    /// velocity gesture in v1.)
    public static let defaultVelocity = 100

    /// What a toggle did.
    public struct ToggleOutcome: Sendable, Equatable {
        /// The note array AFTER the toggle — hand this to
        /// `PianoRollModel.replaceDraft` and commit it.
        public let notes: [MIDINote]
        /// The note a toggle-ON created, or nil when the toggle removed.
        public let added: MIDINote?
        /// The notes a toggle-OFF removed (plural — see `notes(in:cell:)`).
        public let removed: [MIDINote]

        /// True when the cell is filled after the toggle.
        public var isFilledAfter: Bool { added != nil }
    }

    /// The notes occupying a cell.
    ///
    /// ⚠️ **ONSET SEMANTICS, and the consequences are named rather than hidden.**
    /// A note occupies the cell its ONSET falls in — that is what a step
    /// sequencer means by a step, and it is what makes the grid readable as a
    /// pattern. Two consequences a caller must know:
    ///
    ///  - A note LONGER than one step still occupies exactly one cell. Toggling
    ///    that cell off removes the whole note, length and all — the grid cannot
    ///    show a length it has no column for, and half-deleting a note would be
    ///    worse than deleting it.
    ///  - Several notes can share a cell (a flam authored in the roll, two notes
    ///    a few ticks apart). Toggling off removes ALL of them, so the cell is
    ///    honestly empty afterwards; toggling on again returns ONE note. That is
    ///    lossy, it is the only self-consistent answer for a surface whose cell
    ///    is a boolean, and it is documented rather than silently rounded.
    nonisolated public static func notes(in notes: [MIDINote], cell: StepCell,
                                         geometry: StepSequencerGeometry) -> [MIDINote] {
        notes.filter {
            $0.pitch == cell.pitch && geometry.stepIndex(forBeat: $0.startBeat) == cell.step
        }
    }

    /// Every filled cell, with what the grid needs to DRAW it — the primitive.
    /// `filledCells` derives from this rather than walking the notes a second
    /// time: two walks of one array are two homes for "is this cell on".
    ///
    /// Notes on a pitch with no lane cannot appear here; `StepSequencerLanes`
    /// gives every present pitch a lane precisely so that set is empty.
    nonisolated public static func fills(notes: [MIDINote],
                                         geometry: StepSequencerGeometry) -> [StepCellFill] {
        let pitches = Set(geometry.lanes.map(\.pitch))
        var byCell: [StepCell: Int] = [:]
        for note in notes where pitches.contains(note.pitch) {
            let step = geometry.stepIndex(forBeat: note.startBeat)
            guard step >= 0, step < geometry.stepCount else { continue }
            let cell = StepCell(step: step, pitch: note.pitch)
            // A flam (two notes in one cell) draws at the LOUDER one's weight —
            // the cell is one box, and the quieter hit must not make the pattern
            // read softer than it sounds.
            byCell[cell] = max(byCell[cell] ?? 0, note.velocity)
        }
        return byCell.keys.sorted().map { cell in
            StepCellFill(
                cell: cell,
                velocity: byCell[cell] ?? StepSequencerEdit.defaultVelocity,
                isLatent: geometry.beat(forStep: cell.step) >= geometry.clipLengthBeats)
        }
    }

    /// Every filled cell.
    nonisolated public static func filledCells(notes: [MIDINote],
                                               geometry: StepSequencerGeometry) -> Set<StepCell> {
        Set(fills(notes: notes, geometry: geometry).map(\.cell))
    }

    /// Toggles a cell: removes the notes in it, or adds one when it is empty.
    ///
    /// A toggled-ON note takes the step's start beat, ONE step of length and
    /// `defaultVelocity` — the same "one grid cell, velocity 100" default the
    /// roll's double-click add applies (`PianoRollModel.addNote` +
    /// `defaultLength(for:)`), so the two editors author identical notes.
    ///
    /// **The round trip that matters**: toggle a cell on, then off, and the
    /// array returns to its original content (the append is removed and nothing
    /// else is touched). Toggling an EXISTING note off and on again is lossy in
    /// the two ways `notes(in:cell:)` documents — an unsnapped onset returns
    /// snapped, a custom length returns one step, a flam returns as one note.
    nonisolated public static func toggle(notes: [MIDINote], cell: StepCell,
                                          geometry: StepSequencerGeometry) -> ToggleOutcome {
        let occupants = self.notes(in: notes, cell: cell, geometry: geometry)
        if occupants.isEmpty {
            let note = MIDINote(
                pitch: cell.pitch,
                velocity: defaultVelocity,
                startBeat: geometry.beat(forStep: cell.step),
                lengthBeats: geometry.stepBeats)
            return ToggleOutcome(notes: notes + [note], added: note, removed: [])
        }
        let doomed = Set(occupants.map(\.id))
        return ToggleOutcome(
            notes: notes.filter { !doomed.contains($0.id) },
            added: nil,
            removed: occupants)
    }
}
