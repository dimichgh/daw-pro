import Foundation
import Testing
@testable import DAWCore

/// m23-h — `ProjectStore.reorderTrack(id:toIndex:)`, the ONE ordering verb
/// behind the arrange header drag, the `track.reorder` wire command and the
/// `track_reorder` MCP tool.
///
/// The gate legs this suite carries, and why each is here rather than assumed:
///   • BOTH directions. Remove-then-insert is correct up AND down, but new code
///     need not be, and an up-only fixture is the classic half-pass — a
///     down-move is the one that depends on the removal shifting the tail.
///   • ONE undo step asserted by history DEPTH DELTA, not by "the order looks
///     restored" (the m23-g1 vacuity sharpening): a multi-edit implementation
///     can still end up looking right after N undos.
///   • Save/load round trip — the persisted `[TrackDocument]` array order is
///     the ONLY carrier, so a reorder that never reaches the document is
///     invisible in memory and lost on reopen.
///   • Clips, sends, output routing, sidechain keys and automation survive
///     untouched. The roadmap's orientation established these are UUID-keyed
///     and so cannot break — this pins that they in fact don't, cheaply.
///   • Mid-recording is ALLOWED. That is the deliberate omission of
///     `requireRoutingMutationAllowed`, and a future "consistency" edit that
///     copies `removeTrack`'s guard would fail here with a reason attached.
@MainActor
@Suite("Track reorder (m23-h)")
struct TrackReorderTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-reorder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Four named tracks in a known order: A, B, C, D.
    private func fixture() -> (ProjectStore, [Track]) {
        let store = ProjectStore()
        let tracks = ["A", "B", "C", "D"].map { store.addTrack(name: $0, kind: .audio) }
        return (store, tracks)
    }

    private func names(_ store: ProjectStore) -> [String] { store.tracks.map(\.name) }

    // MARK: - Index semantics, both directions

    @Test("a DOWN move lands the track AT the requested final index")
    func downMoveUsesFinalIndexSemantics() throws {
        let (store, tracks) = fixture()
        // A (index 0) -> index 2. FINAL-index semantics (the reorderEffect
        // convention): A ends up AT 2, i.e. B, C, A, D. Under SwiftUI's
        // `onMove` PRE-removal convention the same call would land A at 1, so
        // this assert is the one that discriminates the two conventions.
        let landed = try store.reorderTrack(id: tracks[0].id, toIndex: 2)
        #expect(landed == 2)
        #expect(names(store) == ["B", "C", "A", "D"])
        #expect(store.tracks[2].id == tracks[0].id)
    }

    @Test("an UP move lands the track AT the requested final index")
    func upMoveUsesFinalIndexSemantics() throws {
        let (store, tracks) = fixture()
        let landed = try store.reorderTrack(id: tracks[3].id, toIndex: 1)
        #expect(landed == 1)
        #expect(names(store) == ["A", "D", "B", "C"])
        #expect(store.tracks[1].id == tracks[3].id)
    }

    @Test("a one-step move down, the case a down-drag actually produces")
    func downMoveByOne() throws {
        let (store, tracks) = fixture()
        #expect(try store.reorderTrack(id: tracks[1].id, toIndex: 2) == 2)
        #expect(names(store) == ["A", "C", "B", "D"])
    }

    @Test("moving to the last index lands last; moving to 0 lands first")
    func movesToBothEnds() throws {
        let (store, tracks) = fixture()
        #expect(try store.reorderTrack(id: tracks[0].id, toIndex: 3) == 3)
        #expect(names(store) == ["B", "C", "D", "A"])
        #expect(try store.reorderTrack(id: tracks[0].id, toIndex: 0) == 0)
        #expect(names(store) == ["A", "B", "C", "D"])
    }

    // MARK: - Clamping / no-op / not-found

    @Test("an out-of-range index CLAMPS instead of throwing (the reorderEffect rule)")
    func outOfRangeIndexClamps() throws {
        let (store, tracks) = fixture()
        #expect(try store.reorderTrack(id: tracks[0].id, toIndex: 99) == 3)
        #expect(names(store) == ["B", "C", "D", "A"])
        #expect(try store.reorderTrack(id: tracks[0].id, toIndex: -7) == 0)
        #expect(names(store) == ["A", "B", "C", "D"])
    }

    @Test("a same-index move is a silent no-op: no reorder, no undo step, not dirty")
    func sameIndexIsANoOp() throws {
        let (store, tracks) = fixture()
        try store.saveProject(to: tempDir().appendingPathComponent("Clean").path)
        #expect(!store.isDirty)
        let depthBefore = store.undoHistory().undo.count

        #expect(try store.reorderTrack(id: tracks[2].id, toIndex: 2) == 2)

        #expect(names(store) == ["A", "B", "C", "D"])
        #expect(store.undoHistory().undo.count == depthBefore)
        // A no-op reorder is not an unsaved change — it never enters performEdit,
        // so it cannot mark the project dirty either.
        #expect(!store.isDirty)
    }

    @Test("a clamped move that resolves to the CURRENT index is also a no-op")
    func clampedToCurrentIndexIsANoOp() throws {
        let (store, tracks) = fixture()
        let depthBefore = store.undoHistory().undo.count
        // D is already last; clamping 99 -> 3 == its own index.
        #expect(try store.reorderTrack(id: tracks[3].id, toIndex: 99) == 3)
        #expect(store.undoHistory().undo.count == depthBefore)
        #expect(names(store) == ["A", "B", "C", "D"])
    }

    @Test("an unknown track id throws trackNotFound and moves nothing")
    func unknownTrackThrows() throws {
        let (store, _) = fixture()
        let ghost = UUID()
        do {
            _ = try store.reorderTrack(id: ghost, toIndex: 0)
            Issue.record("expected trackNotFound")
        } catch let error as ProjectError {
            guard case .trackNotFound(let id) = error else {
                Issue.record("expected trackNotFound, got \(error)")
                return
            }
            #expect(id == ghost)
        }
        #expect(names(store) == ["A", "B", "C", "D"])
    }

    @Test("reordering the only track is a no-op, not a crash")
    func singleTrackIsSafe() throws {
        let store = ProjectStore()
        let only = store.addTrack(name: "Solo", kind: .audio)
        #expect(try store.reorderTrack(id: only.id, toIndex: 5) == 0)
        #expect(store.tracks.map(\.id) == [only.id])
    }

    // MARK: - Atomicity (history DEPTH, not appearance)

    @Test("a whole reorder is ONE undo step — asserted by history depth delta")
    func reorderIsExactlyOneUndoStep() throws {
        let (store, tracks) = fixture()
        let depthBefore = store.undoHistory().undo.count

        try store.reorderTrack(id: tracks[0].id, toIndex: 3)

        // DEPTH, not "the order looks restored after undo": an implementation
        // that removed and re-added (or moved one slot at a time) would leave
        // the order looking right after enough undos while stacking N entries.
        #expect(store.undoHistory().undo.count == depthBefore + 1)
        #expect(store.undoHistory().undo.first == "Move Track 'A'")
        #expect(store.undoLabel == "Move Track 'A'")

        _ = try store.undo()
        #expect(names(store) == ["A", "B", "C", "D"])
        #expect(store.undoHistory().undo.count == depthBefore)
        _ = try store.redo()
        #expect(names(store) == ["B", "C", "D", "A"])
        #expect(store.undoHistory().undo.count == depthBefore + 1)
    }

    @Test("ONE undo restores the order — a second undo reaches the edit BEFORE it")
    func oneUndoIsEnough() throws {
        let (store, tracks) = fixture()
        _ = store.renameTrack(id: tracks[1].id, name: "Bass")
        try store.reorderTrack(id: tracks[3].id, toIndex: 0)
        #expect(names(store) == ["D", "A", "Bass", "C"])

        _ = try store.undo()                                  // undoes the reorder ONLY
        #expect(names(store) == ["A", "Bass", "C", "D"])
        _ = try store.undo()                                  // now the rename
        #expect(names(store) == ["A", "B", "C", "D"])
    }

    // MARK: - Persistence

    @Test("the new order survives a save/open round trip")
    func orderRoundTripsThroughDawproj() throws {
        let dir = tempDir()
        let (store, tracks) = fixture()
        try store.reorderTrack(id: tracks[0].id, toIndex: 2)
        #expect(names(store) == ["B", "C", "A", "D"])

        let path = dir.appendingPathComponent("Reordered").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        #expect(reopened.tracks.map(\.name) == ["B", "C", "A", "D"])
        #expect(reopened.tracks.map(\.id) == [tracks[1].id, tracks[2].id,
                                              tracks[0].id, tracks[3].id])
    }

    // MARK: - Everything else is untouched

    @Test("clips, sends, output routing, sidechain keys and automation all survive")
    func reorderDisturbsNothingElse() throws {
        let store = ProjectStore()
        let bus = store.addTrack(name: "Reverb", kind: .bus)
        let gtr = store.addTrack(name: "Gtr", kind: .audio)
        let drums = store.addTrack(name: "Drums", kind: .audio)

        try store.setTrackOutput(id: gtr.id, busID: bus.id)
        let send = try store.addSend(toTrack: drums.id, busID: bus.id, level: 0.4)
        let comp = try store.addEffect(toTrack: gtr.id, kind: .compressor)
        _ = try store.setSidechain(trackID: gtr.id, effectID: comp.id, sourceTrackID: drums.id)
        let lane = try store.addAutomationLane(trackID: gtr.id, target: .volume)
        _ = try store.setAutomationPoints(
            trackID: gtr.id, laneID: lane.id,
            points: [AutomationPoint(beat: 0, value: 0.2),
                     AutomationPoint(beat: 4, value: 0.9)])
        let clip = try store.addMIDIClip(
            toTrack: store.addTrack(name: "Keys", kind: .instrument).id,
            atBeat: 8, lengthBeats: 4)

        // The bus is at index 0; drag it to the END, under every source that
        // feeds it — the arrangement most likely to expose an order-indexed
        // routing assumption.
        try store.reorderTrack(id: bus.id, toIndex: 3)
        #expect(store.tracks.map(\.name) == ["Gtr", "Drums", "Keys", "Reverb"])

        let reGtr = try #require(store.tracks.first { $0.id == gtr.id })
        let reDrums = try #require(store.tracks.first { $0.id == drums.id })
        #expect(reGtr.outputBusID == bus.id)
        #expect(reDrums.sends.map(\.id) == [send.id])
        #expect(reDrums.sends[0].destinationBusID == bus.id)
        #expect(reDrums.sends[0].level == 0.4)
        #expect(reGtr.effects.map(\.id) == [comp.id])
        #expect(reGtr.effects[0].sidechainSourceTrackID == drums.id)
        #expect(reGtr.automation.map(\.id) == [lane.id])
        #expect(reGtr.automation[0].points.map(\.beat) == [0, 4])
        let reKeys = try #require(store.tracks.first { $0.name == "Keys" })
        #expect(reKeys.clips.map(\.id) == [clip.id])
        #expect(reKeys.clips[0].startBeat == 8)
    }

    // MARK: - The deliberate absence of the routing guard

    @Test("a reorder is ALLOWED mid-take — it is audio-inert, unlike removeTrack")
    func reorderIsLegalWhileRecording() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let a = store.addTrack(name: "A", kind: .audio)
        let b = store.addTrack(name: "B", kind: .audio)
        try store.setTrackArm(id: a.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        // Permitted: nothing about a permutation reaches the render graph
        // (every engine map is UUID-keyed; reconcile's signature is a
        // dictionary), so refusing it would cost the user an edit for nothing.
        #expect(try store.reorderTrack(id: b.id, toIndex: 0) == 0)
        #expect(names(store) == ["B", "A"])

        // …while the announce-class sibling still refuses, so this test cannot
        // pass by the guard having been dropped everywhere.
        #expect(throws: ProjectError.self) { try store.removeTrack(id: b.id) }
    }

    @Test("the engine is told about the new order exactly once per reorder")
    func engineIsNotifiedOnce() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let a = store.addTrack(name: "A", kind: .audio)
        store.addTrack(name: "B", kind: .audio)
        engine.clearCalls()

        try store.reorderTrack(id: a.id, toIndex: 1)
        #expect(engine.calls == [.tracksDidChange(count: 2)])

        // A no-op reorder tells the engine nothing at all.
        engine.clearCalls()
        try store.reorderTrack(id: a.id, toIndex: 1)
        #expect(engine.calls.isEmpty)
    }
}
