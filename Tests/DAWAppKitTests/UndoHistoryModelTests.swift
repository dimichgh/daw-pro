import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless tests for the Undo-history panel's state machine (m11-b): the DISPLAY
/// ordering of the two row groups (redo above the marker newest-adjacent, undo below
/// newest-adjacent), the per-row STEP PLAN (redo[j]/undo[i] → j+1 / i+1 calls), and
/// that stepping re-drives the injected one-step closures the RIGHT number of times
/// and stops early when a step is refused. Two harnesses: a FIXED-history closure
/// (unambiguous row/plan pins) and a REAL `ProjectStore` (proves a jump performs the
/// exact undo/redo count end-to-end). No window, no wire — the `QuantizeModel`
/// precedent.
@MainActor
@Suite struct UndoHistoryModelTests {

    // MARK: - Fixed-history harness (row + plan pins)

    /// A model over a fixed history plus counting step closures.
    private func fixed(undo: [String], redo: [String]) -> (UndoHistoryModel, Counters) {
        let c = Counters()
        let model = UndoHistoryModel(
            history: { UndoHistory(undo: undo, redo: redo) },
            undoStep: { c.undo += 1; return true },
            redoStep: { c.redo += 1; return true })
        return (model, c)
    }

    final class Counters { var undo = 0; var redo = 0 }

    @Test("redoRows render newest-adjacent-to-marker (redo[0] LAST) with j+1 step counts")
    func redoRowOrder() {
        let (model, _) = fixed(undo: [], redo: ["X", "Y", "Z"])   // X = next redo
        let rows = model.redoRows
        // Display top→bottom: furthest future first, next-redo (X) last (adjacent above marker).
        #expect(rows.map(\.label) == ["Z", "Y", "X"])
        #expect(rows.map(\.stepCount) == [3, 2, 1])
        #expect(rows.allSatisfy { $0.direction == .redo })
        // The row adjacent to the marker is the single next redo.
        #expect(rows.last?.label == "X")
        #expect(rows.last?.stepCount == 1)
    }

    @Test("undoRows render newest-adjacent-to-marker (undo[0] FIRST) with i+1 step counts")
    func undoRowOrder() {
        let (model, _) = fixed(undo: ["C", "B", "A"], redo: [])   // C = next undo (most recent)
        let rows = model.undoRows
        // Display top→bottom: next-undo (C) first (adjacent below marker), older below.
        #expect(rows.map(\.label) == ["C", "B", "A"])
        #expect(rows.map(\.stepCount) == [1, 2, 3])
        #expect(rows.allSatisfy { $0.direction == .undo })
        #expect(rows.first?.label == "C")
        #expect(rows.first?.stepCount == 1)
    }

    @Test("row ids are unique across both groups")
    func rowIDsUnique() {
        let (model, _) = fixed(undo: ["C", "B"], redo: ["X", "Y"])
        let ids = (model.redoRows + model.undoRows).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("isEmpty is true only when both stacks are empty")
    func emptyState() {
        #expect(fixed(undo: [], redo: []).0.isEmpty)
        #expect(!fixed(undo: ["A"], redo: []).0.isEmpty)
        #expect(!fixed(undo: [], redo: ["A"]).0.isEmpty)
    }

    @Test("clicking a row runs exactly stepCount one-step calls in its direction")
    func stepRunsExactCount() {
        let (model, c) = fixed(undo: ["C", "B", "A"], redo: ["X", "Y"])
        model.step(UndoHistoryModel.Row(direction: .undo, label: "A", stepCount: 3))
        #expect(c.undo == 3 && c.redo == 0)
        model.step(UndoHistoryModel.Row(direction: .redo, label: "Y", stepCount: 2))
        #expect(c.undo == 3 && c.redo == 2)
    }

    @Test("stepping stops early when a one-step call is refused")
    func stepStopsEarly() {
        let c = Counters()
        // Refuse after two successful undos (a guard, e.g. recording, kicked in).
        let model = UndoHistoryModel(
            history: { UndoHistory(undo: ["C", "B", "A"], redo: []) },
            undoStep: { c.undo += 1; return c.undo <= 2 },
            redoStep: { c.redo += 1; return true })
        model.step(UndoHistoryModel.Row(direction: .undo, label: "A", stepCount: 3))
        #expect(c.undo == 3)   // three calls made, the third returned false → loop broke
    }

    @Test("out-of-range or negative index step is a no-op")
    func indexGuards() {
        let (model, c) = fixed(undo: ["C", "B"], redo: ["X"])
        model.stepToUndoIndex(5)    // beyond the stack
        model.stepToUndoIndex(-1)
        model.stepToRedoIndex(9)
        #expect(c.undo == 0 && c.redo == 0)
    }

    // MARK: - Real-store harness (end-to-end step count)

    private func overStore(_ store: ProjectStore) -> UndoHistoryModel {
        UndoHistoryModel(
            history: { store.undoHistory() },
            undoStep: { (try? store.undo()) != nil },
            redoStep: { (try? store.redo()) != nil })
    }

    @Test("stepToUndoIndex performs i+1 real undos against the store")
    func realUndoJump() {
        let store = ProjectStore()
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        store.addTrack(name: "C")
        let model = overStore(store)
        // undo[1] == "Add Track 'B'" → 2 undos → only A remains, C and B redoable.
        model.stepToUndoIndex(1)
        #expect(store.tracks.map(\.name) == ["A"])
        let h = model.history
        #expect(h.undo == ["Add Track 'A'"])
        #expect(h.redo == ["Add Track 'B'", "Add Track 'C'"])
    }

    @Test("stepToRedoIndex performs j+1 real redos against the store")
    func realRedoJump() throws {
        let store = ProjectStore()
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        store.addTrack(name: "C")
        try store.undo(); try store.undo(); try store.undo()   // everything undone
        #expect(store.tracks.isEmpty)
        let model = overStore(store)
        // redo = ["Add Track 'A'", "Add Track 'B'", "Add Track 'C'"]; redoIndex 2 → 3 redos.
        model.stepToRedoIndex(2)
        #expect(store.tracks.map(\.name) == ["A", "B", "C"])
        #expect(model.history.redo.isEmpty)
    }
}
