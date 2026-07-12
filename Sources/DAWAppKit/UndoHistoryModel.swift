import Foundation
import Observation
import DAWCore

/// Headless state machine for the Undo-history panel (m11-b): it turns the
/// store's `UndoHistory` label projection into a single chronological list of
/// clickable ROWS and steps to any of them via REPEATED `ProjectStore.undo()` /
/// `redo()` calls — never touching the journal directly, so the coalescing
/// barrier and the mid-take `transportBusy` guard always apply (the same path
/// Cmd-Z and the `edit.undo`/`edit.redo` wire use). No SwiftUI, no AppKit — the
/// panel view is thin over this and the tests drive it against injected closures
/// (the `QuantizeModel` / `InstrumentPickerModel` precedent: all logic here,
/// testable without a window OR a store).
///
/// Data flows IN through injected providers: `historyProvider` (wired to
/// `ProjectStore.undoHistory()`, read FRESH each access so the list live-updates
/// as edits/undos land) plus one-step `undoStep` / `redoStep` closures (each
/// returns whether a step actually happened, so a jump stops early if a guard
/// refuses). This item adds NO new mutation surface — it only re-drives the
/// existing undo/redo.
///
/// NO VIOLET anywhere — undo history is standard editing chrome, not AI-generated
/// content (docs/DESIGN-LANGUAGE.md Rule 3: violet is AI identity only). Cyan
/// marks only earned active state (the "you are here" marker).
@MainActor
@Observable
public final class UndoHistoryModel {
    // MARK: - Injected providers

    /// The current undo/redo label projection (wired to `ProjectStore.undoHistory()`;
    /// a closure over a fixed value in tests). Read FRESH each access so an undo /
    /// redo / fresh edit is reflected immediately.
    private let historyProvider: () -> UndoHistory
    /// Performs ONE `ProjectStore.undo()` (wired there); returns true iff a step
    /// actually happened (false = nothing to undo, or refused mid-take). A jump
    /// stops on the first false so it never spins on a guard.
    private let undoStep: () -> Bool
    /// Mirror of `undoStep` for `ProjectStore.redo()`.
    private let redoStep: () -> Bool

    public init(
        history: @escaping () -> UndoHistory,
        undoStep: @escaping () -> Bool,
        redoStep: @escaping () -> Bool
    ) {
        self.historyProvider = history
        self.undoStep = undoStep
        self.redoStep = redoStep
    }

    // MARK: - Projection

    /// The live history projection (fresh read).
    public var history: UndoHistory { historyProvider() }

    /// True when there are no edits at all — drives the panel's honest empty state.
    public var isEmpty: Bool {
        let h = history
        return h.undo.isEmpty && h.redo.isEmpty
    }

    // MARK: - Rows (the clickable step plan the panel + tests read)

    /// The direction a history row steps in when clicked.
    public enum Direction: String, Equatable, Sendable { case undo, redo }

    /// One clickable row of the history list: its label, which way it steps, and
    /// exactly how many `undo()`/`redo()` calls clicking it performs. Identifiable
    /// by a direction-prefixed step count (unique within the whole list, since
    /// `stepCount` is 1,2,3… within each direction).
    public struct Row: Identifiable, Equatable, Sendable {
        public let direction: Direction
        public let label: String
        /// How many one-step calls clicking this row runs (undo[i]/redo[j] → i+1 / j+1).
        public let stepCount: Int
        public var id: String { "\(direction == .undo ? "u" : "r")\(stepCount)" }

        public init(direction: Direction, label: String, stepCount: Int) {
            self.direction = direction
            self.label = label
            self.stepCount = stepCount
        }
    }

    /// The REDO rows in DISPLAY order (top → bottom), rendered ABOVE the "you are
    /// here" marker as the dimmed "future". The next redo (`history.redo[0]`) sits
    /// LAST so it's directly ADJACENT to the marker (newest-adjacent-to-marker);
    /// the furthest-future edit is at the very top. Clicking a row runs its
    /// `stepCount` redos (`redo[j]` → j+1).
    public var redoRows: [Row] {
        let redo = history.redo
        // redo[j] needs j+1 redos; reverse for display so redo[0] lands nearest the marker.
        return redo.indices.reversed().map { j in
            Row(direction: .redo, label: redo[j], stepCount: j + 1)
        }
    }

    /// The UNDO rows in DISPLAY order (top → bottom), rendered BELOW the marker.
    /// The next undo (`history.undo[0]`, the most recent edit) sits FIRST so it's
    /// directly adjacent to the marker; older edits descend below it. Clicking a
    /// row runs its `stepCount` undos (`undo[i]` → i+1).
    public var undoRows: [Row] {
        let undo = history.undo
        return undo.indices.map { i in
            Row(direction: .undo, label: undo[i], stepCount: i + 1)
        }
    }

    // MARK: - Stepping

    /// Runs a row's step plan through the injected one-step closures: `stepCount`
    /// undos or redos, stopping early if any step is refused. This is the ONLY
    /// action surface — it re-drives the existing `ProjectStore.undo()`/`redo()`,
    /// never the journal.
    public func step(_ row: Row) {
        let one = row.direction == .undo ? undoStep : redoStep
        for _ in 0..<max(0, row.stepCount) {
            if !one() { break }
        }
    }

    /// Steps to the undo row at display index `i` (== `history.undo[i]`) via i+1
    /// undos. A no-op for a negative or out-of-range index.
    public func stepToUndoIndex(_ i: Int) {
        guard i >= 0, i < history.undo.count else { return }
        step(Row(direction: .undo, label: history.undo[i], stepCount: i + 1))
    }

    /// Steps to the redo row at display index `j` (== `history.redo[j]`) via j+1
    /// redos. A no-op for a negative or out-of-range index.
    public func stepToRedoIndex(_ j: Int) {
        guard j >= 0, j < history.redo.count else { return }
        step(Row(direction: .redo, label: history.redo[j], stepCount: j + 1))
    }
}
