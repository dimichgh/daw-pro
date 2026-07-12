import Foundation
import Testing
@testable import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m11-b `edit.history`: the read-only projection of
/// the labeled undo/redo stacks that backs the history panel. Pins the wire shape,
/// the NEWEST-FIRST ordering contract (both directions), the empty state, that a
/// coalesced scrub folds to one entry over the wire, and that a wire undo round-trip
/// moves labels between the two stacks in the right order. The journal mechanics
/// themselves are pinned in DAWCore's `UndoHistoryProjectionTests`; here we pin the
/// wire surface. Adds NO mutation surface — stepping stays `edit.undo`/`edit.redo`.
@MainActor
@Suite("Edit history — control protocol")
struct EditHistoryCommandTests {

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store), store)
    }

    private func history(_ router: CommandRouter, id: String = "1") async -> JSONValue? {
        let response = await router.handle(ControlRequest(id: id, command: "edit.history"))
        #expect(response.ok)
        return response.result
    }

    private func labels(_ result: JSONValue?, _ key: String) -> [String] {
        result?[key]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    @Test("allCommands advertises edit.history")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("edit.history"))
    }

    @Test("edit.history on an empty session returns empty lists and both flags false")
    func emptyHistory() async {
        let (router, _) = makeRouter()
        let result = await history(router)
        #expect(labels(result, "undo").isEmpty)
        #expect(labels(result, "redo").isEmpty)
        #expect(result?["canUndo"]?.boolValue == false)
        #expect(result?["canRedo"]?.boolValue == false)
    }

    @Test("edit.history takes no params — a bare call succeeds")
    func noParamsRequired() async {
        let (router, store) = makeRouter()
        store.addTrack(name: "A")
        let response = await router.handle(ControlRequest(id: "1", command: "edit.history"))
        #expect(response.ok)
        #expect(response.error == nil)
    }

    @Test("edit.history is NEWEST-FIRST and undo[0] is what edit.undo reverses next")
    func newestFirst() async throws {
        let (router, store) = makeRouter()
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        try store.setTempo(140)   // newest edit
        let result = await history(router)
        #expect(labels(result, "undo") == ["Set Tempo", "Add Track 'B'", "Add Track 'A'"])
        #expect(labels(result, "redo").isEmpty)
        #expect(result?["canUndo"]?.boolValue == true)
        #expect(result?["canRedo"]?.boolValue == false)
        // undo[0] matches the snapshot's top-of-stack undoLabel.
        let snap = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        #expect(snap.result?["undoLabel"]?.stringValue == "Set Tempo")
    }

    @Test("a coalesced same-key scrub folds to ONE entry over the wire")
    func coalescingFoldsToOne() async {
        let (router, store) = makeRouter()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        store.setMasterVolume(0.4)
        clock = clock.advanced(by: .milliseconds(300))   // inside the 800 ms window
        store.setMasterVolume(0.8)                        // same key → coalesces
        let result = await history(router)
        #expect(labels(result, "undo") == ["Set Master Volume"])
    }

    @Test("two wire undos move labels to redo in newest-first order")
    func wireUndoMovesToRedo() async throws {
        let (router, store) = makeRouter()
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        store.addTrack(name: "C")

        // Undo twice over the wire (the real edit.undo path — barrier + guards apply).
        _ = await router.handle(ControlRequest(id: "u1", command: "edit.undo"))  // reverses C
        _ = await router.handle(ControlRequest(id: "u2", command: "edit.undo"))  // reverses B

        let result = await history(router, id: "h")
        #expect(labels(result, "undo") == ["Add Track 'A'"])
        // redo[0] = the NEXT redo (B, most recently undone); C sits below it.
        #expect(labels(result, "redo") == ["Add Track 'B'", "Add Track 'C'"])
        #expect(result?["canUndo"]?.boolValue == true)
        #expect(result?["canRedo"]?.boolValue == true)

        // A wire redo pulls B back onto undo, newest-first preserved.
        _ = await router.handle(ControlRequest(id: "r1", command: "edit.redo"))
        let after = await history(router, id: "h2")
        #expect(labels(after, "undo") == ["Add Track 'B'", "Add Track 'A'"])
        #expect(labels(after, "redo") == ["Add Track 'C'"])
    }
}
