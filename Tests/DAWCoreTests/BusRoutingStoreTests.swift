import Foundation
import Testing
@testable import DAWCore

/// Headless store-level coverage for M4 (i) bus routing & sends: defaults,
/// validation (exact ProjectError cases, no state change, no journal entry),
/// send-level undo coalescing, and bus-deletion rerouting under one undo step.
@MainActor
@Suite("Bus routing & sends — ProjectStore")
struct BusRoutingStoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func track(_ store: ProjectStore, _ id: UUID) -> Track {
        store.tracks.first(where: { $0.id == id })!
    }

    @Test("a new track defaults to master with no sends")
    func trackDefaultsToMasterWithNoSends() {
        let store = ProjectStore()
        let t = store.addTrack(name: "Gtr", kind: .audio)
        #expect(track(store, t.id).outputBusID == nil)
        #expect(track(store, t.id).sends == [])
    }

    @Test("setOutput to a non-bus destination throws notABus and changes nothing")
    func setOutputRejectsNonBusDestination() throws {
        let store = ProjectStore()
        let source = store.addTrack(name: "Gtr", kind: .audio)
        let notABus = store.addTrack(name: "Keys", kind: .audio)
        let depth = store.journal.undoStack.count

        let error = projectError { try store.setTrackOutput(id: source.id, busID: notABus.id) }
        guard case .notABus(let id) = try #require(error) else {
            Issue.record("expected notABus, got \(String(describing: error))"); return
        }
        #expect(id == notABus.id)
        #expect(track(store, source.id).outputBusID == nil)          // unchanged
        #expect(store.journal.undoStack.count == depth)               // no journal entry
    }

    @Test("setOutput on a bus throws busRoutingFixed and changes nothing")
    func setOutputOnBusThrowsBusRoutingFixed() throws {
        let store = ProjectStore()
        let busA = store.addTrack(name: "Reverb", kind: .bus)
        let busB = store.addTrack(name: "Delay", kind: .bus)
        let depth = store.journal.undoStack.count

        let error = projectError { try store.setTrackOutput(id: busA.id, busID: busB.id) }
        guard case .busRoutingFixed = try #require(error) else {
            Issue.record("expected busRoutingFixed, got \(String(describing: error))"); return
        }
        #expect(track(store, busA.id).outputBusID == nil)
        #expect(store.journal.undoStack.count == depth)
    }

    @Test("addSend refuses a duplicate destination and changes nothing")
    func addSendRefusesDuplicateDestination() throws {
        let store = ProjectStore()
        let bus = store.addTrack(name: "Reverb", kind: .bus)
        let source = store.addTrack(name: "Gtr", kind: .audio)
        _ = try store.addSend(toTrack: source.id, busID: bus.id, level: 0.5)
        let depth = store.journal.undoStack.count

        let error = projectError { _ = try store.addSend(toTrack: source.id, busID: bus.id) }
        guard case .duplicateSend(let id) = try #require(error) else {
            Issue.record("expected duplicateSend, got \(String(describing: error))"); return
        }
        #expect(id == bus.id)
        #expect(track(store, source.id).sends.count == 1)             // unchanged
        #expect(store.journal.undoStack.count == depth)               // no journal entry
    }

    @Test("two send-level edits inside the window coalesce to one undo step")
    func sendLevelEditsCoalesceToOneUndoStep() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let bus = store.addTrack(name: "Reverb", kind: .bus)
        let source = store.addTrack(name: "Gtr", kind: .audio)
        let send = try store.addSend(toTrack: source.id, busID: bus.id, level: 1)
        let depth = store.journal.undoStack.count

        _ = try store.setSendLevel(trackID: source.id, sendID: send.id, level: 0.5)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setSendLevel(trackID: source.id, sendID: send.id, level: 0.25)

        // One coalesced step, current level is the last write.
        #expect(store.journal.undoStack.count == depth + 1)
        #expect(track(store, source.id).sends.first?.level == 0.25)

        // A single undo restores the ORIGINAL level (coalescing keeps the first
        // before-state), not just the previous plateau.
        try store.undo()
        #expect(track(store, source.id).sends.first?.level == 1)
    }

    @Test("removing a bus reroutes orphans and one undo restores everything")
    func removingABusReroutesAndOneUndoRestores() throws {
        let store = ProjectStore()
        let bus = store.addTrack(name: "Reverb", kind: .bus)
        let routed = store.addTrack(name: "Gtr", kind: .audio)
        let sender = store.addTrack(name: "Vox", kind: .audio)
        try store.setTrackOutput(id: routed.id, busID: bus.id)
        let send = try store.addSend(toTrack: sender.id, busID: bus.id, level: 0.5)

        #expect(store.removeTrack(id: bus.id))
        #expect(!store.tracks.contains(where: { $0.id == bus.id }))
        #expect(track(store, routed.id).outputBusID == nil)          // orphan output → master
        #expect(track(store, sender.id).sends.isEmpty)               // send dropped

        // ONE undo restores the bus, the routing, and the send together.
        try store.undo()
        #expect(store.tracks.contains(where: { $0.id == bus.id }))
        #expect(track(store, routed.id).outputBusID == bus.id)
        let restored = track(store, sender.id).sends
        #expect(restored.count == 1)
        #expect(restored.first?.id == send.id)
        #expect(restored.first?.destinationBusID == bus.id)
        #expect(restored.first?.level == 0.5)
    }
}
