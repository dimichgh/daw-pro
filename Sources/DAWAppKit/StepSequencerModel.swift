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
    ///   - isDrumKit: true when the clip's track has drum rows,
    ///     `DrumLaneMap.lanes(for:) != nil` (m39-w4-2). Before that item it was
    ///     `SMFProjectExporter.isDrumKit(track)`, which a `pads` drum machine
    ///     answers "no" (it is not a General MIDI kit), so a new Drum Machine
    ///     opened in the piano roll. The export predicate stays the export's.
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
    /// The row label. A GM percussion name on a GM drum kit ("Acoustic
    /// Snare"), a drum name on our drum machine ("Kick"), a scientific pitch
    /// name otherwise ("C4"). Never invented: see
    /// `StepSequencerLanes.lanes(drumLanes:notes:)`.
    public let label: String
    /// True when the label came from the instrument's drum rows (`DrumLaneMap`:
    /// the GM percussion key map, or the drum machine's voice names) rather than
    /// from the note-name derivation — the property a probe uses to assert that
    /// drum lanes are NAMED and not numbered.
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
    ///
    /// m39-w4-2 — THE ROWS COME FROM `DrumLaneMap.lanes(for:)`, the one home
    /// for "which rows does a drum instrument have". `drumLanes` nil means a
    /// melodic track: the window above. Otherwise its rows, each labelled by
    /// the map (the GM names on a percussion bank, "Kick" … "Cymbal" on our
    /// drum machine in either note layout), plus every present pitch.
    nonisolated public static func lanes(drumLanes: [DrumLane]?,
                                         notes: [MIDINote]) -> [StepSequencerLane] {
        var pitches = Set(notes.map(\.pitch))
        var drumLabels: [Int: String] = [:]
        if let drumLanes {
            for lane in drumLanes where drumLabels[lane.note] == nil {
                drumLabels[lane.note] = lane.label
            }
            pitches.formUnion(drumLanes.map(\.note))
        } else {
            pitches.formUnion(melodicWindow)
        }
        return pitches.sorted(by: >).map { pitch in
            let named = drumLabels[pitch]
            return StepSequencerLane(
                pitch: pitch,
                // `Fundamental.noteName` is the repo's ONE scientific-pitch
                // name (which itself defers to `KeyEstimate.pitchClassesSharp`,
                // the sole pitch-class table) — a private "C#/D#…" array here
                // would be the third home for twelve strings.
                label: named ?? Fundamental.noteName(midiNote: pitch),
                isNamedPercussion: named != nil)
        }
    }

    /// The pre-m39-w4-2 form: `true` is the General MIDI percussion bank's 17
    /// rows (`DrumLaneMap.generalMIDIPercussionLanes`), `false` the melodic
    /// window. Kept for its callers; the view feeds the lane map itself.
    nonisolated public static func lanes(isDrumKit: Bool, notes: [MIDINote]) -> [StepSequencerLane] {
        lanes(drumLanes: isDrumKit ? DrumLaneMap.generalMIDIPercussionLanes : nil, notes: notes)
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

    /// The most step columns one grid draws: 2^20 (m23-ap I5-F4 round 4). At the
    /// finest step (1/64 note = 1/16 beat) that is 65,536 beats, about 9.1
    /// hours at 120 BPM; at the 1/16-note default, 36 hours. Only a note or a
    /// clip end further out than that reaches it, and the grid then stops at
    /// this column: those notes stay in the clip and in the piano roll. Before
    /// it, such a clip asked for billions of columns (or trapped `Int(_:)`).
    public static let maximumStepCount = 1 << 20

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
    /// Beats per bar of the meter the clip STARTS in — `stepsPerBar`, and the
    /// rule that a step as long as a bar draws no bar emphasis. Where the bar
    /// lines ARE comes from `meterMap` (m23-ap I5-F4), so a meter change inside
    /// the clip re-spaces them.
    public let beatsPerBar: Int

    // MARK: Where the columns sit on the SONG's grid (m23-ap I5-F4)

    /// The clip's first beat on the song timeline.
    public let clipStartBeat: Double
    /// The song's ONE meter map — which columns start a bar, and that bar's
    /// number (the song's, never counted from the clip).
    public let meterMap: MeterMap
    /// How far the clip's first beat sits past the song grid line column 0
    /// starts on, in beats — EXACTLY 0 when the clip starts on a line
    /// (`SongGridPhase`), which is what keeps every on-grid column bit-identical
    /// to the pre-I5-F4 grid. Otherwise column 0 is a PARTIAL column: its left
    /// part (`0 ..< clipStartX`) is before the clip and is shaded out.
    public let phaseBeats: Double
    /// The song beat column 0 starts at (`clipStartBeat − phaseBeats`): a line
    /// the piano roll draws.
    public let firstStepSongBeat: Double
    /// Column 0's index on the song's step lattice (column k starts at song
    /// beat `(firstStepIndex + k) / stepsPerWholeBeat`). INTEGER so beat and
    /// bar lines are found by exact arithmetic, never from a float song beat —
    /// a triplet column that starts ON beat 1 reads 0.9999999999999999 and
    /// would miss it. 0 when `stepsPerWholeBeat` is nil.
    let firstStepIndex: Int
    /// Steps in one whole beat when a beat is an exact number of steps — every
    /// resolution but Bar (1/2ⁿ, and the 1/3 and 1/6 triplets) — else nil.
    let stepsPerWholeBeat: Int?

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

    /// The drum rows this grid was built from (`DrumLaneMap.lanes(for:)` of the
    /// clip's track), or nil for a melodic grid. m39-w4-3: kept so the toggle's
    /// entry velocity (`NoteEntryDefaults`) and the Accent row
    /// (`StepAccent.hasRow`) read the SAME lane list the rows came from. A
    /// grid whose rows are drum rows cannot mint a melodic-default note.
    public let drumLanes: [DrumLane]?

    /// Builds the geometry for a clip, ON THE SONG'S GRID (m23-ap I5-F4).
    ///
    /// ⭐ **THE COLUMNS ARE THE SONG'S GRID CELLS, NOT THE CLIP'S.** I5-F2/F3 put
    /// the piano roll's lines and every note edit on the song's grid; this grid
    /// used to cut its columns from the clip's first beat, so on a clip that
    /// starts off a line (a clip at 2.1 under 1/16) no column edge was a line
    /// the roll draws, and a toggled box wrote a note between them. Column 0
    /// now starts on the song line at or before the clip's first beat
    /// (`phaseBeats` before it), every column edge is a song line, bar emphasis
    /// and bar numbers are the SONG's (`meterMap`), and a Bar-sized column is
    /// one bar of the meter the clip starts in (the I5-F3 ruling: `.bar` is
    /// meter-aware). For a clip that starts on a line every position this
    /// geometry answers is bit-identical to before; bar numbers are the song's
    /// on every clip, as the roll's ruler has been since I5-F2.
    ///
    /// ⚠️ **THE STEP COUNT COVERS EVERY NOTE, not just the clip.** It is the
    /// clip length OR the furthest note ONSET, whichever is later — the
    /// `PianoRollModel.contentWidth` rule, for the `StepSequencerLanes.lanes`
    /// reason: a note left beyond the clip end by a trim is store-legal, latent,
    /// and would otherwise be un-toggleable from the only surface that can
    /// delete without the keyboard. It is the onset (not the end) because a
    /// cell IS an onset: extending for a tail would add columns nothing can
    /// ever fill. The partial column 0 of an off-grid clip adds `phaseBeats`.
    ///
    /// m39-w4-2: the rows come from the drum lane map (`DrumLaneMap.lanes(for:)`
    /// of the clip's track, nil for a melodic track), and any drum grid opens at
    /// the bottom, where its kick is.
    nonisolated public static func make(
        drumLanes: [DrumLane]?,
        notes: [MIDINote],
        clipLengthBeats: Double,
        resolution: SnapResolution,
        songGrid: PianoRollSongGrid.Context,
        rowHeight: CGFloat = StepSequencerGeometry.defaultRowHeight,
        stepWidth: CGFloat = StepSequencerGeometry.defaultStepWidth
    ) -> StepSequencerGeometry {
        let start = songGrid.clipStartBeat.isFinite ? max(0, songGrid.clipStartBeat) : 0
        let meterMap = songGrid.meterMap
        let placement = columnPlacement(clipStartBeat: start, resolution: resolution,
                                        meterMap: meterMap)
        let step = placement.stepBeats
        let phase = placement.phaseBeats
        let length = max(0, clipLengthBeats)
        let furthestOnset = notes.map(\.startBeat).max() ?? 0
        let span = max(length, furthestOnset + step)
        // TOTAL (m23-ap I5-F4 round 4): the count stays a Double until it is
        // known to fit. `Int(_:)` trapped on an infinite span and on a note 2^63
        // or more steps in (~2.4e18 beats at 1/16). Past `maximumStepCount` the
        // grid stops there; every smaller count is the one it was before.
        let rawCount = ((span + phase) / step - 1e-9).rounded(.up)
        let count = rawCount < Double(Self.maximumStepCount)
            ? max(1, Int(rawCount)) : Self.maximumStepCount
        let firstStepSongBeat = start - phase
        // TOTAL (m23-ap I5-F4 round 3): the song-step lattice is exact integer
        // arithmetic, so it exists only while a Double holds every step index
        // exactly (below 2^53). Past that (a clip ~1e15 beats out) `Int` would
        // trap soon after, at 2^63, which a clip.addMIDI far enough out reached.
        // The geometry drops the lattice there, as a Bar-sized step does: no
        // song emphasis, and nothing asks the meter map about a beat that far.
        let lattice = wholeBeatDivisor(step).flatMap { perBeat -> (index: Int, perBeat: Int)? in
            let index = (firstStepSongBeat * Double(perBeat)).rounded()
            guard index.magnitude < 9_007_199_254_740_992 else { return nil }
            return (Int(index), perBeat)
        }
        return StepSequencerGeometry(
            lanes: StepSequencerLanes.lanes(drumLanes: drumLanes, notes: notes),
            stepBeats: step,
            stepCount: count,
            rowHeight: rowHeight,
            stepWidth: stepWidth,
            clipLengthBeats: length,
            beatsPerBar: max(1, meterMap.beatsPerBar(atBeat: start)),
            clipStartBeat: start,
            meterMap: meterMap,
            phaseBeats: phase,
            firstStepSongBeat: firstStepSongBeat,
            firstStepIndex: lattice?.index ?? 0,
            stepsPerWholeBeat: lattice?.perBeat,
            opensAtBottom: drumLanes != nil,
            drumLanes: drumLanes)
    }

    /// The pre-m39-w4-2 form: `isDrumKit` true is the General MIDI percussion
    /// bank's rows (`DrumLaneMap.generalMIDIPercussionLanes`), false the
    /// melodic window. Forwards to the lane-map `make`, so it is the old
    /// geometry for both.
    nonisolated public static func make(
        isDrumKit: Bool,
        notes: [MIDINote],
        clipLengthBeats: Double,
        resolution: SnapResolution,
        songGrid: PianoRollSongGrid.Context,
        rowHeight: CGFloat = StepSequencerGeometry.defaultRowHeight,
        stepWidth: CGFloat = StepSequencerGeometry.defaultStepWidth
    ) -> StepSequencerGeometry {
        make(drumLanes: isDrumKit ? DrumLaneMap.generalMIDIPercussionLanes : nil,
             notes: notes, clipLengthBeats: clipLengthBeats, resolution: resolution,
             songGrid: songGrid, rowHeight: rowHeight, stepWidth: stepWidth)
    }

    /// The pre-I5-F4 signature: a clip whose first beat is the song's beat 0, in
    /// one meter of `beatsPerBar`. Forwards to the song-grid `make`, whose phase
    /// is exactly 0 there — so this is the old geometry, bit for bit.
    nonisolated public static func make(
        isDrumKit: Bool,
        notes: [MIDINote],
        clipLengthBeats: Double,
        resolution: SnapResolution,
        beatsPerBar: Int,
        rowHeight: CGFloat = StepSequencerGeometry.defaultRowHeight,
        stepWidth: CGFloat = StepSequencerGeometry.defaultStepWidth
    ) -> StepSequencerGeometry {
        make(isDrumKit: isDrumKit, notes: notes, clipLengthBeats: clipLengthBeats,
             resolution: resolution,
             songGrid: PianoRollSongGrid.Context(
                clipStartBeat: 0,
                meterMap: MeterMap(constant: TimeSignature(beatsPerBar: beatsPerBar))),
             rowHeight: rowHeight, stepWidth: stepWidth)
    }

    /// Beats per step for a resolution — `off` has no grid, so it takes the
    /// 1/16 fallback rather than silently drawing one column per beat.
    ///
    /// The NOMINAL size: `.bar` reads 4 here. A built geometry replaces it with
    /// one bar of the meter the clip starts in (`columnPlacement`), so read
    /// `stepBeats` off the geometry, never this, to know what was drawn.
    nonisolated public static func stepBeats(for resolution: SnapResolution) -> Double {
        resolution.beats ?? (fallbackResolution.beats ?? 0.25)
    }

    /// How wide a column is and how far the clip's first beat sits past the
    /// song line column 0 starts on (m23-ap I5-F4).
    ///
    /// - Every resolution but Bar: `SongGridPhase.phase` — the roll's own phase,
    ///   from the song's beat 0 (the non-bar lines the roll draws are uniform
    ///   from there whatever the meter, because every bar starts on a whole beat).
    /// - Bar: one bar of the meter the clip starts in, measured from the song's
    ///   bar line at or before the clip's first beat. In one meter that is
    ///   `start mod beatsPerBar`, the roll's `.bar` snap exactly. Across a meter
    ///   change a column stays one bar of the STARTING meter — uniform columns
    ///   cannot re-space, so past the change they drift off the drawn bars.
    nonisolated static func columnPlacement(clipStartBeat start: Double,
                                            resolution: SnapResolution,
                                            meterMap: MeterMap) -> (stepBeats: Double, phaseBeats: Double) {
        guard resolution == .bar else {
            let step = stepBeats(for: resolution)
            return (step, SongGridPhase.phase(of: start, step: step))
        }
        let tolerance = SongGridPhase.onGridTolerance
        var line = meterMap.beat(ofBar: meterMap.barBeat(atBeat: start).bar)
        var step = Double(meterMap.beatsPerBar(atBeat: line))
        // A start a nanobeat short of the next bar line counts as ON it.
        if line + step - start < tolerance {
            line += step
            step = Double(meterMap.beatsPerBar(atBeat: line))
        }
        let phase = start - line
        return (step, phase < tolerance ? 0 : phase)
    }

    /// Steps in one whole beat when a beat is an exact number of steps, else
    /// nil (a Bar-sized step, or anything longer than a beat).
    nonisolated static func wholeBeatDivisor(_ step: Double) -> Int? {
        guard step > 0, step <= 1 else { return nil }
        let divisor = (1 / step).rounded()
        guard divisor >= 1, abs(divisor * step - 1) < 1e-9 else { return nil }
        return Int(divisor)
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

    /// Clip-local beat a step column starts at: a song grid line. NEGATIVE for
    /// the partial column 0 of an off-grid clip (its line is before the clip's
    /// first beat); a note toggled there lands on the clip's first beat
    /// (`StepSequencerEdit.toggle`). With `phaseBeats` exactly 0 this is the
    /// pre-I5-F4 `step · stepBeats`, bit for bit.
    public func beat(forStep step: Int) -> Double { Double(step) * stepBeats - phaseBeats }

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
    ///
    /// m23-ap I5-F4: columns are cut on the SONG's lines, so the beat is shifted
    /// by `phaseBeats` first (exactly 0 for a clip on a line).
    public func stepIndex(forBeat beat: Double) -> Int {
        let scaled = (beat + phaseBeats) / stepBeats
        // TOTAL (m23-ap I5-F4 round 4): `Int(_:)` trapped on a beat that is not
        // a number or infinite, and on one 2^63 or more steps out. Such a beat is
        // in no column: answer a step every caller already reads as outside the
        // grid (`fills` keeps 0..<stepCount, `notes(in:cell:)` compares with a
        // real column). Every beat that worked before takes the unchanged path.
        guard scaled.magnitude < 9_223_372_036_854_775_808.0 else {   // 2^63
            return scaled > 0 ? Int.max : Int.min
        }
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

    /// True when a step column starts a SONG bar — the emphasized gridline, and
    /// the column the SF Mono bar number is drawn over (m23-ap I5-F4: the
    /// song's bar lines through `meterMap`, the ones the roll draws — never
    /// every `stepsPerBar` from the clip's first beat).
    ///
    /// Found by exact integer arithmetic on the song's step lattice: the column
    /// must start a whole song beat, and that beat must start a bar. A step as
    /// long as a bar (or a whole-beat step in a one-beat meter) draws no bar
    /// emphasis, as before — `stepsPerBar` is 0 there.
    public func isBarStart(step: Int) -> Bool {
        guard stepsPerBar > 0, let perBeat = stepsPerWholeBeat else { return false }
        let songStep = firstStepIndex + step
        guard songStep >= 0, songStep % perBeat == 0 else { return false }
        return meterMap.barBeat(atBeat: Double(songStep / perBeat)).beatInBar < 0.001
    }

    /// True when a step column starts a whole SONG beat — the mid-weight
    /// gridline that makes a 16-step bar countable in fours.
    public func isBeatStart(step: Int) -> Bool {
        guard stepsPerBeat > 0 else { return false }
        let songStep = firstStepIndex + step
        return songStep >= 0 && songStep % stepsPerBeat == 0
    }

    /// The song beat a step column starts at — exact whenever it is a whole
    /// beat (integer arithmetic on the step lattice), so a bar lookup can never
    /// fall a hair short of the bar line it names.
    public func songBeat(forStep step: Int) -> Double {
        guard let perBeat = stepsPerWholeBeat else {
            return firstStepSongBeat + Double(step) * stepBeats
        }
        let songStep = firstStepIndex + step
        if songStep % perBeat == 0 { return Double(songStep / perBeat) }
        return Double(songStep) / Double(perBeat)
    }

    /// The columns that start a SONG bar, left to right, each with its song bar
    /// number — the step ruler's labels, derived from `isBarStart` so the ruler
    /// and the emphasized gridlines read ONE predicate.
    public var barMarks: [StepBarMark] {
        (0..<stepCount).compactMap { step in
            isBarStart(step: step) ? StepBarMark(step: step, bar: barNumber(forStep: step)) : nil
        }
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
    /// roll's three bands). Shifted by the partial column 0 (m23-ap I5-F4).
    public var clipEndX: CGFloat { CGFloat((clipLengthBeats + phaseBeats) / stepBeats) * stepWidth }

    /// x of the clip's first beat — 0 for a clip on a line; inside column 0 for
    /// an off-grid clip, whose part left of it is BEFORE the clip and takes the
    /// same out-of-clip shade as the tail (m23-ap I5-F4).
    public var clipStartX: CGFloat { CGFloat(phaseBeats / stepBeats) * stepWidth }

    /// The transport playhead's x in this grid's content space, or nil while
    /// the transport sits outside the clip — `PianoRollPlayhead.lineX` on the
    /// step scale, moved right by the partial column 0 so the line crosses the
    /// column holding the beat it is on (m23-ap I5-F4).
    public func playheadX(position: Double, lengthBeats: Double) -> CGFloat? {
        PianoRollPlayhead.lineX(position: position, clipStartBeat: clipStartBeat,
                                lengthBeats: lengthBeats,
                                pixelsPerBeat: stepWidth / CGFloat(stepBeats))
            .map { $0 + clipStartX }
    }

    /// One-based SONG bar a step column starts in — the SF Mono column readout.
    /// m23-ap I5-F4: the song's bar (a clip on bar 3 reads 3, as the roll's
    /// ruler and the transport do), never counted from the clip's first beat.
    public func barNumber(forStep step: Int) -> Int {
        meterMap.barBeat(atBeat: songBeat(forStep: step)).bar + 1
    }
}

/// A column that starts a song bar, and that bar's number — one step-ruler
/// label (m23-ap I5-F4). Echoed by `debug.stepSequencer` so a gate can compare
/// the step grid's bars with the roll's.
public struct StepBarMark: Sendable, Equatable {
    public let step: Int
    public let bar: Int

    public init(step: Int, bar: Int) {
        self.step = step
        self.bar = bar
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

    /// The MELODIC entry velocity, kept as a name for its readers. m39-w4-3: a
    /// toggled-on note's velocity no longer comes from here — `toggle` asks
    /// `NoteEntryDefaults` (through `StepAccent.entryVelocity`) with the grid's
    /// own lane list, the SAME function `PianoRollModel.addNote` asks, so a note
    /// authored in either editor sounds identically BY CONSTRUCTION rather than
    /// because two literals agreed. (Per-note velocity is edited in the roll's
    /// velocity lane; the step grid's one velocity gesture is the Accent row.)
    public static let defaultVelocity = NoteEntryDefaults.melodicVelocity

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
    /// A toggled-ON note takes the step's start beat, ONE step of length and the
    /// entry velocity — the same "one grid cell, entry velocity" default the
    /// roll's double-click add applies (`PianoRollModel.addNote` +
    /// `defaultLength(for:)`), so the two editors author identical notes.
    ///
    /// **The round trip that matters**: toggle a cell on, then off, and the
    /// array returns to its original content (the append is removed and nothing
    /// else is touched). Toggling an EXISTING note off and on again is lossy in
    /// the two ways `notes(in:cell:)` documents — an unsnapped onset returns
    /// snapped, a custom length returns one step, a flam returns as one note.
    ///
    /// m23-ap I5-F4: the step's start is a SONG grid line. The partial column 0
    /// of an off-grid clip has its line BEFORE the clip's first beat, so its
    /// note lands ON the clip's first beat — clamped at 0, the I5-F3 "notes
    /// clamp at 0 only" rule the roll's own add follows — and still sits in
    /// column 0, so the round trip holds there too.
    ///
    /// m39-w4-3: the new note's velocity is the track's ENTRY velocity
    /// (`NoteEntryDefaults`, read with `geometry.drumLanes`, so a drum grid
    /// mints the drum default), or the accent when the column is fully
    /// accented on a drum grid (`StepAccent.entryVelocity`). `entry` is for
    /// tests holding a fixture constant; the app uses `.shipped`.
    nonisolated public static func toggle(notes: [MIDINote], cell: StepCell,
                                          geometry: StepSequencerGeometry,
                                          entry: NoteEntryDefaults.Values = .shipped) -> ToggleOutcome {
        let occupants = self.notes(in: notes, cell: cell, geometry: geometry)
        if occupants.isEmpty {
            let note = MIDINote(
                pitch: cell.pitch,
                velocity: StepAccent.entryVelocity(notes: notes, step: cell.step,
                                                   geometry: geometry, entry: entry),
                startBeat: max(0, geometry.beat(forStep: cell.step)),
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

// MARK: - "Start from a beat" (m39-w4-10 UI)

/// One entry of the "Start from a beat" menu: a ready-made drum beat from
/// `DrumPatternLibrary`, by the name a beginner reads.
public struct StepBeatChoice: Sendable, Equatable, Identifiable {
    /// The beat's id ("basicRock"): what the store is asked to write.
    public let id: String
    /// The menu item ("Basic Rock").
    public let name: String
    /// The beat's one-line description, shown as the item's help text.
    public let help: String

    public init(id: String, name: String, help: String) {
        self.id = id
        self.name = name
        self.help = help
    }
}

/// What picking a beat did, as the line(s) the step grid shows under its menu.
public struct StepBeatOutcome: Sendable, Equatable {
    /// True when the clip now holds the beat (the pick changed something, so it
    /// engages the editor pane like every other edit).
    public let changed: Bool
    /// The result line first, then each warning; or the refusal, verbatim.
    public let lines: [String]
    /// True when a line needs attention: a drum left out, an off-bar start, or
    /// a refusal. The grid draws it in the warning colour.
    public let isWarning: Bool

    public init(changed: Bool, lines: [String], isWarning: Bool) {
        self.changed = changed
        self.lines = lines
        self.isWarning = isWarning
    }

    /// Nothing happened and there is nothing to say (the parent wired no store).
    public static let nothing = StepBeatOutcome(changed: false, lines: [], isWarning: false)
}

/// THE ONE HOME for the step grid's "Start from a beat" offer (design
/// `docs/design/2026-10-07-loop-drum-depth.md` §8, last bullet; §10.2 L2).
///
/// ⛔ OFFERED ONLY ON AN EMPTY DRUM CLIP. "Drum" is the step grid's own drum
/// predicate, `drumLanes != nil` (`DrumLaneMap.lanes(for:)`, the same answer
/// that opens the clip in Steps and draws its drum rows). "Empty" is no note at
/// all, a latent one past the clip's end included: the beat never mixes into
/// or replaces anything the user wrote. The store refuses a non-empty clip too
/// (`ProjectStore.fillDrumPattern`), so a stale click cannot overwrite.
///
/// ⭐ THE MENU LISTS EVERY BEAT IN LIBRARY ORDER, so the first item is the
/// user's L2 pick (Basic Rock, eighth-note hats). It never re-sorts.
///
/// The view only draws this and hands the chosen id to its parent; the notes are
/// worked out and written by the store, which knows the track's instrument. The
/// drum rows alone cannot: a General MIDI kit's rows leave out its side stick
/// and hand clap (`DrumLaneMap.generalMIDIPercussionLanes`).
public enum StepStartFromBeat {

    /// The menu's title, on its chip.
    public static let menuTitle = "Start from a beat"
    /// The words before the chip on an empty drum clip.
    public static let emptyPrompt = "This clip is empty. Click the boxes to add hits, or"
    /// The chip's help text.
    public static let menuHelp = "Fill this empty clip with a ready-made drum beat. You can change any "
        + "step afterwards, and Undo takes the whole beat back."

    /// The beats to offer, in library order, or nil when the menu does not
    /// belong here (not a drum clip, or the clip already has notes).
    nonisolated public static func choices(drumLanes: [DrumLane]?,
                                           notes: [MIDINote]) -> [StepBeatChoice]? {
        guard drumLanes != nil, notes.isEmpty else { return nil }
        return DrumPatternLibrary.patterns.map {
            StepBeatChoice(id: $0.id, name: $0.name, help: $0.summary)
        }
    }

    /// Runs the store write and turns what it answered into the lines the grid
    /// shows: the result line and every warning, or the refusal sentence
    /// verbatim (the view holds the words, never the reason).
    nonisolated public static func outcome(
        _ write: () throws -> DrumPatternFillResult) -> StepBeatOutcome {
        do {
            let result = try write()
            return StepBeatOutcome(changed: true, lines: [result.summary] + result.warnings,
                                   isWarning: !result.warnings.isEmpty)
        } catch {
            let sentence = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return StepBeatOutcome(changed: false, lines: [sentence], isWarning: true)
        }
    }
}
