import CoreGraphics
import Foundation
import Observation
import DAWCore

/// Grid snap resolution for the piano roll, in beats. Values are named
/// musically relative to the quarter-note beat: `bar` = 4 beats, `beat` = 1,
/// `eighth` = 1/2 beat, `sixteenth` = 1/4 beat. `off` disables snapping. Labels
/// are beginner-first ("Bar"/"Beat") for the low resolutions, musical fractions
/// for the fine ones (docs/DESIGN-LANGUAGE.md rule 6).
public enum SnapResolution: String, CaseIterable, Sendable {
    case off
    case bar
    case beat
    case eighth
    case sixteenth

    /// Grid size in beats, or nil when snapping is off.
    public var beats: Double? {
        switch self {
        case .off: nil
        case .bar: 4
        case .beat: 1
        case .eighth: 0.5
        case .sixteenth: 0.25
        }
    }

    /// Chip / menu label.
    public var label: String {
        switch self {
        case .off: "Off"
        case .bar: "Bar"
        case .beat: "Beat"
        case .eighth: "1/8"
        case .sixteenth: "1/16"
        }
    }
}

/// Where inside a note a point landed — used to route a drag to move vs resize.
public enum NoteZone: Sendable, Equatable {
    case body
    case resizeHandle
}

/// All piano-roll geometry and edit logic, kept UI-free so it unit-tests
/// headless (Sources/DAWAppKit) while the SwiftUI views (PianoRollView,
/// KeyboardSidebar, VelocityLane) stay thin over it. Edits mutate a local
/// `draft` array; the view submits `buildSubmission()` through
/// `ProjectStore.setClipNotes` on gesture END only — never per drag tick.
///
/// Coordinate space (content coordinates, before scrolling):
///  - x grows right with beats: `x = beat * pixelsPerBeat`.
///  - y grows down as pitch FALLS: row 0 (top) is pitch 127, so a piano-roll
///    reads high-notes-up like a keyboard on its side.
@MainActor
@Observable
public final class PianoRollModel {
    // MARK: Layout constants

    /// Horizontal scale — no zoom this cycle (docs/DESIGN-LANGUAGE.md defers it).
    public static let defaultPixelsPerBeat: CGFloat = 32
    /// One semitone row's height.
    public static let defaultRowHeight: CGFloat = 14
    /// MIDI pitches 0...127 → 128 rows.
    public static let pitchCount = 128
    /// Grab zone on a note's right edge that means "resize" not "move".
    public static let resizeHandleWidth: CGFloat = 8

    public var pixelsPerBeat: CGFloat
    public var rowHeight: CGFloat

    // MARK: Edit state

    /// The working note list. Every interaction mutates this; the view reads it
    /// to draw and submits it on gesture end.
    public var draft: [MIDINote]
    /// Currently selected note ids.
    public var selection: Set<UUID> = []
    /// Clip length in beats — defines the grid's drawn width.
    public var clipLengthBeats: Double

    /// Per-note snapshot captured at the start of a move drag so each tick maps
    /// the raw translation off the original position (no accumulated drift).
    @ObservationIgnored private var moveBaseline: [UUID: (pitch: Int, startBeat: Double)] = [:]

    public init(
        notes: [MIDINote] = [],
        clipLengthBeats: Double = 4,
        pixelsPerBeat: CGFloat = PianoRollModel.defaultPixelsPerBeat,
        rowHeight: CGFloat = PianoRollModel.defaultRowHeight
    ) {
        self.draft = notes
        self.clipLengthBeats = max(0, clipLengthBeats)
        self.pixelsPerBeat = pixelsPerBeat
        self.rowHeight = rowHeight
    }

    /// Replaces the draft with a clip's notes and clears selection. Called when
    /// the panel switches to a different clip (never mid-gesture).
    public func load(notes: [MIDINote], clipLengthBeats: Double) {
        self.draft = notes
        self.clipLengthBeats = max(0, clipLengthBeats)
        self.selection = []
        self.moveBaseline = [:]
    }

    // MARK: - Geometry

    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    public func beat(forX x: CGFloat) -> Double { Double(x / pixelsPerBeat) }

    /// Top y of a pitch's row. Row 0 (y = 0) is the highest pitch (127).
    public func y(forPitch pitch: Int) -> CGFloat {
        CGFloat(Self.pitchCount - 1 - pitch) * rowHeight
    }

    /// Pitch whose row contains `y`, clamped to 0...127.
    public func pitch(forY y: CGFloat) -> Int {
        let row = Int((y / rowHeight).rounded(.down))
        return (Self.pitchCount - 1 - row).clamped(to: MIDINote.pitchRange)
    }

    /// Full pitch-stack height (all 128 rows).
    public var contentHeight: CGFloat { CGFloat(Self.pitchCount) * rowHeight }

    /// Drawn grid width — the clip length, but never less than the furthest
    /// note end (out-of-clip notes stay visible; the model never trims them).
    public var contentWidth: CGFloat {
        let maxNoteEnd = draft.map(\.endBeat).max() ?? 0
        return CGFloat(max(clipLengthBeats, maxNoteEnd, 1)) * pixelsPerBeat
    }

    /// A note's rectangle in content coordinates. A minimum drawn width keeps a
    /// very short note clickable.
    public func rect(for note: MIDINote) -> CGRect {
        CGRect(
            x: x(forBeat: note.startBeat),
            y: y(forPitch: note.pitch),
            width: max(3, CGFloat(note.lengthBeats) * pixelsPerBeat),
            height: rowHeight
        )
    }

    // MARK: - Snap

    /// Snaps `beat` to the nearest grid line (>= 0). `off` passes the value
    /// through (still floored at 0).
    public func snap(beat: Double, resolution: SnapResolution) -> Double {
        guard let grid = resolution.beats, grid > 0 else { return max(0, beat) }
        return max(0, (beat / grid).rounded() * grid)
    }

    /// Length a freshly-added note gets, and the floor a resize can't go below:
    /// one grid cell, or 1 beat when snapping is off.
    public func defaultLength(for resolution: SnapResolution) -> Double {
        resolution.beats ?? 1.0
    }

    // MARK: - Hit testing

    /// Topmost note under `point` and which zone was hit, or nil for empty grid.
    /// The right `resizeHandleWidth` of a note (when it's wide enough to have a
    /// distinct body) is the resize handle; everything else is the body.
    public func hitTest(_ point: CGPoint) -> (id: UUID, zone: NoteZone)? {
        // Reverse so a later-drawn (visually on top) note wins an overlap.
        for note in draft.reversed() {
            let r = rect(for: note)
            guard r.contains(point) else { continue }
            if r.width > Self.resizeHandleWidth * 1.5,
               point.x >= r.maxX - Self.resizeHandleWidth {
                return (note.id, .resizeHandle)
            }
            return (note.id, .body)
        }
        return nil
    }

    // MARK: - Draft edits

    /// Adds a note at a snapped position with a one-grid-cell length and default
    /// velocity 100. Returns the new note (already in the draft).
    @discardableResult
    public func addNote(atBeat beat: Double, pitch: Int, resolution: SnapResolution) -> MIDINote {
        let note = MIDINote(
            pitch: pitch.clamped(to: MIDINote.pitchRange),
            velocity: 100,
            startBeat: snap(beat: beat, resolution: resolution),
            lengthBeats: defaultLength(for: resolution)
        )
        draft.append(note)
        return note
    }

    /// Snapshots the selected notes' positions for a move drag. Call once at
    /// drag start, then `moveSelection` each tick.
    public func beginMove() {
        moveBaseline = [:]
        for note in draft where selection.contains(note.id) {
            moveBaseline[note.id] = (note.pitch, note.startBeat)
        }
    }

    /// Moves every note in the move baseline by a raw (unsnapped) beat/pitch
    /// delta off its captured start. Start snaps to the grid and clamps to >= 0;
    /// pitch clamps to 0...127. Length and velocity are preserved.
    public func moveSelection(deltaBeats: Double, deltaPitch: Int, resolution: SnapResolution) {
        for (id, base) in moveBaseline {
            guard let index = draft.firstIndex(where: { $0.id == id }) else { continue }
            let note = draft[index]
            let newPitch = (base.pitch + deltaPitch).clamped(to: MIDINote.pitchRange)
            let newStart = snap(beat: max(0, base.startBeat + deltaBeats), resolution: resolution)
            draft[index] = MIDINote(
                id: id, pitch: newPitch, velocity: note.velocity,
                startBeat: newStart, lengthBeats: note.lengthBeats
            )
        }
    }

    /// Resizes a note's right edge to a snapped end beat. Length can't fall
    /// below one grid cell (`defaultLength`); the start is untouched.
    public func resizeNote(id: UUID, toEndBeat endBeat: Double, resolution: SnapResolution) {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return }
        let note = draft[index]
        let snappedEnd = snap(beat: endBeat, resolution: resolution)
        let minLength = defaultLength(for: resolution)
        let length = max(minLength, snappedEnd - note.startBeat)
        draft[index] = MIDINote(
            id: id, pitch: note.pitch, velocity: note.velocity,
            startBeat: note.startBeat, lengthBeats: length
        )
    }

    /// Sets a note's velocity (clamped to 1...127 by `MIDINote`).
    public func setVelocity(id: UUID, velocity: Int) {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return }
        let note = draft[index]
        draft[index] = MIDINote(
            id: id, pitch: note.pitch, velocity: velocity,
            startBeat: note.startBeat, lengthBeats: note.lengthBeats
        )
    }

    /// Removes the selected notes and clears the selection.
    public func deleteSelection() {
        guard !selection.isEmpty else { return }
        draft.removeAll { selection.contains($0.id) }
        selection = []
    }

    // MARK: - Selection

    public func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    /// Selects exactly `id`, clearing any other selection.
    public func selectOnly(_ id: UUID) { selection = [id] }

    /// Adds/removes `id` from the selection (shift-click).
    public func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public func clearSelection() { selection = [] }

    // MARK: - Submission

    /// The draft to hand to `ProjectStore.setClipNotes` on gesture end. The
    /// store re-clamps and canonically orders, so the model returns as-is.
    public func buildSubmission() -> [MIDINote] { draft }
}
