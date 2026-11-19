import CoreGraphics
import Foundation
import DAWCore

// m39-w4-3 — THE ACCENT ROW of the step grid, headless.
// `docs/design/2026-10-07-loop-drum-depth.md` §3.5.
//
// One row under the drum rows, labelled "Accent". Click a column and every hit
// that starts in it plays harder; click it again and they go back. Mouse-only,
// like the rest of the grid (the m23-cq-1 scoping rule: no keyboard here).
//
// NOTHING NEW IS STORED (§3.6). An accent IS a note velocity: the row reads the
// velocities of the hits in a column and writes them. So an accent survives
// save, undo, copy and export with no new field, and an old project opens
// exactly as it did.
//
// ⛔ THE ROW READS AGAINST `NoteEntryDefaults.accentVelocity` (127), NEVER
// AGAINST THE KIT'S `accentThreshold`. The threshold is 100 by default and a
// hand-entered hit is born at `drumVelocity` (100 until the user's L1 pick), so
// a row that read the threshold would light EVERY column the moment the user
// placed a hit: an Accent row that says everything is accented says nothing.
// The gate plants exactly that (design §9.2, `m39-w4-3`).

/// What one column of the Accent row shows.
public enum StepAccentState: String, Sendable, Equatable, CaseIterable {
    /// No hit starts in this column: there is nothing to accent.
    case empty
    /// Hits, none of them accented.
    case off
    /// Some hits accented and some not (for example one row's velocity was
    /// edited in the piano roll): a half state, never a guess either way.
    case mixed
    /// Every hit in the column is accented.
    case on
}

/// One drawn column of the Accent row. Only columns with hits are listed.
public struct StepAccentColumn: Sendable, Equatable {
    public let step: Int
    public let state: StepAccentState

    public init(step: Int, state: StepAccentState) {
        self.step = step
        self.state = state
    }
}

public enum StepAccent {

    /// True when this grid draws an Accent row: drum grids only (the rows came
    /// from `DrumLaneMap`). A melodic grid has no accent bus and no "column of
    /// hits" to lift together, so it has no row.
    nonisolated public static func hasRow(_ geometry: StepSequencerGeometry) -> Bool {
        geometry.drumLanes != nil
    }

    /// The column under a content-space x, or nil outside the grid: the Accent
    /// row's hit test. It asks the grid's ONE hit test (`cell(at:)`, on the
    /// first row), so the row cannot address a column the grid does not draw.
    nonisolated public static func step(atX x: CGFloat,
                                        geometry: StepSequencerGeometry) -> Int? {
        geometry.cell(at: CGPoint(x: x, y: 0))?.step
    }

    /// The hits whose ONSET falls in column `step`, on any row. The same onset
    /// rule (and the same "only pitches with a row, only columns that exist")
    /// as `StepSequencerEdit.fills`, so a column the grid draws lit is exactly
    /// the column the Accent row reads.
    nonisolated public static func hits(in notes: [MIDINote], step: Int,
                                        geometry: StepSequencerGeometry) -> [MIDINote] {
        guard step >= 0, step < geometry.stepCount else { return [] }
        let pitches = Set(geometry.lanes.map(\.pitch))
        return notes.filter {
            pitches.contains($0.pitch) && geometry.stepIndex(forBeat: $0.startBeat) == step
        }
    }

    /// Whether ONE hit is accented: at or above `entry.accentVelocity`. The one
    /// comparison every read below goes through (see the ⛔ above for why it is
    /// the constant and not the kit's threshold).
    nonisolated public static func isAccented(
        _ note: MIDINote, entry: NoteEntryDefaults.Values = .shipped
    ) -> Bool {
        note.velocity >= entry.accentVelocity
    }

    /// The one rule from counts to a state.
    nonisolated static func classify(hits: Int, accented: Int) -> StepAccentState {
        if hits == 0 { return .empty }
        if accented == 0 { return .off }
        return accented == hits ? .on : .mixed
    }

    /// The state of a set of hits, read against `entry.accentVelocity`.
    nonisolated public static func state(
        of hits: [MIDINote],
        entry: NoteEntryDefaults.Values = .shipped
    ) -> StepAccentState {
        classify(hits: hits.count,
                 accented: hits.reduce(0) { $0 + (isAccented($1, entry: entry) ? 1 : 0) })
    }

    /// The state of column `step`.
    nonisolated public static func state(
        notes: [MIDINote], step: Int, geometry: StepSequencerGeometry,
        entry: NoteEntryDefaults.Values = .shipped
    ) -> StepAccentState {
        state(of: hits(in: notes, step: step, geometry: geometry), entry: entry)
    }

    /// Every column with hits, ascending by step: what the row draws. Empty on
    /// a grid with no Accent row. One walk of the notes, so a long clip costs
    /// one pass, not one pass per column.
    nonisolated public static func columns(
        notes: [MIDINote], geometry: StepSequencerGeometry,
        entry: NoteEntryDefaults.Values = .shipped
    ) -> [StepAccentColumn] {
        guard hasRow(geometry) else { return [] }
        let pitches = Set(geometry.lanes.map(\.pitch))
        var tally: [Int: (hits: Int, accented: Int)] = [:]
        for note in notes where pitches.contains(note.pitch) {
            let step = geometry.stepIndex(forBeat: note.startBeat)
            guard step >= 0, step < geometry.stepCount else { continue }
            var t = tally[step] ?? (0, 0)
            t.hits += 1
            if isAccented(note, entry: entry) { t.accented += 1 }
            tally[step] = t
        }
        return tally.keys.sorted().map { step in
            let t = tally[step] ?? (0, 0)
            return StepAccentColumn(step: step, state: classify(hits: t.hits, accented: t.accented))
        }
    }

    /// CLICK AN ACCENT CELL. Returns the note array after the click, or nil
    /// when the click changes nothing (no Accent row on this grid, or no hit in
    /// the column) so the caller does not commit an empty undo step.
    ///
    /// - `off` or `mixed`: every hit in the column goes to `accentVelocity`.
    /// - `on`: every hit goes back to `drumVelocity`. ⚠️ This discards a custom
    ///   velocity a hit had before it was accented (design §3.5: "sets them back
    ///   to `drumVelocity`"); the velocity lane in the piano roll is the place
    ///   for per-hit dynamics.
    ///
    /// Only velocities change: ids, pitches, onsets and lengths are kept, and
    /// notes in other columns are untouched. The caller hands the result to
    /// `PianoRollModel.replaceDraft` and the roll's ONE `commit()`, so a click
    /// is one undo step.
    nonisolated public static func toggle(
        notes: [MIDINote], step: Int, geometry: StepSequencerGeometry,
        entry: NoteEntryDefaults.Values = .shipped
    ) -> [MIDINote]? {
        guard hasRow(geometry) else { return nil }
        let column = hits(in: notes, step: step, geometry: geometry)
        guard !column.isEmpty else { return nil }
        let target = state(of: column, entry: entry) == .on
            ? entry.drumVelocity : entry.accentVelocity
        let ids = Set(column.map(\.id))
        return notes.map { note in
            guard ids.contains(note.id) else { return note }
            return MIDINote(id: note.id, pitch: note.pitch, velocity: target,
                            startBeat: note.startBeat, lengthBeats: note.lengthBeats)
        }
    }

    /// The velocity a hit toggled ON in column `step` is born at: the accent
    /// when the column is fully accented on a drum grid (design §3.5: "a note
    /// toggled on in an accented column is born at 127"), else the track's
    /// entry default (`NoteEntryDefaults`, from the same lane list the rows
    /// came from). A mixed column is not "accented", so a new hit there is
    /// born at the drum default.
    nonisolated public static func entryVelocity(
        notes: [MIDINote], step: Int, geometry: StepSequencerGeometry,
        entry: NoteEntryDefaults.Values = .shipped
    ) -> Int {
        if hasRow(geometry),
           state(notes: notes, step: step, geometry: geometry, entry: entry) == .on {
            return entry.accentVelocity
        }
        return entry.velocity(drumLanes: geometry.drumLanes)
    }
}
