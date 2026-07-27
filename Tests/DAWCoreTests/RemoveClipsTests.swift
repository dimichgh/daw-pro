import Foundation
import Testing
@testable import DAWCore

// m23-g1: `ProjectStore.removeClips(ids:)` — group delete as ONE undo step.
//
// The whole point of this verb is a property the type system cannot express, so
// it is asserted here directly against the journal: N clips vanish in ONE
// journal entry, and ONE undo brings all N back. The trap it exists to avoid is
// documented on the verb — `performEdit` is NOT re-entrant, so a loop of
// `removeClip` calls inside an outer `performEdit` would journal N+1 times.

@MainActor
@Suite("Group delete — removeClips")
struct RemoveClipsTests {
    /// Two instrument tracks with 2 and 1 MIDI clips: a MIXED-TRACK fixture, which
    /// is the case a per-track implementation gets wrong.
    private func fixture() throws -> (store: ProjectStore, a: [Clip], b: [Clip]) {
        let store = ProjectStore()
        let t1 = store.addTrack(name: "One", kind: .instrument)
        let t2 = store.addTrack(name: "Two", kind: .instrument)
        let a1 = try store.addMIDIClip(toTrack: t1.id, name: "A1", atBeat: 0, lengthBeats: 4)
        let a2 = try store.addMIDIClip(toTrack: t1.id, name: "A2", atBeat: 8, lengthBeats: 4)
        let b1 = try store.addMIDIClip(toTrack: t2.id, name: "B1", atBeat: 4, lengthBeats: 4)
        return (store, [a1, a2], [b1])
    }

    private func clipIDs(_ store: ProjectStore) -> Set<UUID> {
        Set(store.tracks.flatMap { $0.clips.map(\.id) })
    }

    // 1. THE HEADLINE CLAIM, asserted on the journal rather than on vibes.
    @Test("three clips across two tracks delete in exactly ONE undo step")
    func atomicity() throws {
        let (store, a, b) = try fixture()
        let targets = [a[0].id, a[1].id, b[0].id]
        let depthBefore = store.undoHistory().undo.count

        let removed = try store.removeClips(ids: targets)

        #expect(removed.count == 3)
        #expect(clipIDs(store).isEmpty)
        let history = store.undoHistory()
        // EXACTLY one new entry — not three, not four.
        #expect(history.undo.count == depthBefore + 1)
        #expect(history.undo.first == "Delete 3 Clips")

        // ONE undo restores ALL THREE, each back on its own track.
        try store.undo()
        #expect(clipIDs(store) == Set(targets))
        #expect(store.tracks[0].clips.count == 2)
        #expect(store.tracks[1].clips.count == 1)
        #expect(store.undoHistory().undo.count == depthBefore)

        // And redo removes all three again, still as one step.
        try store.redo()
        #expect(clipIDs(store).isEmpty)
        #expect(store.undoHistory().undo.count == depthBefore + 1)
    }

    // 2. Geometry survives the round trip — an undo that restored the clips at the
    //    wrong beats would satisfy test 1's id check and still be broken.
    @Test("undo restores start beats, lengths, and track membership")
    func restoresGeometry() throws {
        let (store, a, b) = try fixture()
        try store.removeClips(ids: [a[0].id, a[1].id, b[0].id])
        try store.undo()

        #expect(store.tracks[0].clips.map(\.startBeat) == [0, 8])
        #expect(store.tracks[0].clips.map(\.lengthBeats) == [4, 4])
        #expect(store.tracks[0].clips.map(\.name) == ["A1", "A2"])
        #expect(store.tracks[1].clips.map(\.startBeat) == [4])
        #expect(store.tracks[1].clips.map(\.name) == ["B1"])
    }

    // 3. THE CALIBRATION TEST: this is what a loop of `removeClip` would fail.
    //    Kept separate from test 1 so a regression names itself.
    @Test("the label is the group label, never the single-clip one")
    func label() throws {
        let (store, a, _) = try fixture()
        try store.removeClips(ids: [a[0].id, a[1].id])
        #expect(store.undoLabel == "Delete 2 Clips")
        #expect(store.undoLabel != "Remove Clip 'A2'")

        // Singular still reads as a group delete (countable, and distinct from
        // `removeClip`'s label) so the two paths are never confusable.
        let (store2, c, _) = try fixture()
        try store2.removeClips(ids: [c[0].id])
        #expect(store2.undoLabel == "Delete 1 Clip")
    }

    // 4. Two successive group deletes must NOT coalesce (no `key:` on the edit) —
    //    the failure mode opposite to test 1, and just as wrong.
    @Test("successive group deletes are separate undo steps")
    func noCoalescing() throws {
        let (store, a, b) = try fixture()
        let depthBefore = store.undoHistory().undo.count
        try store.removeClips(ids: [a[0].id, a[1].id])
        try store.removeClips(ids: [b[0].id])
        #expect(store.undoHistory().undo.count == depthBefore + 2)

        try store.undo()
        #expect(clipIDs(store) == Set([b[0].id]))
        try store.undo()
        #expect(clipIDs(store).count == 3)
    }

    // 5. All-or-nothing: an unknown id refuses the WHOLE call, mutating nothing.
    @Test("an unknown id throws and leaves every clip in place")
    func unknownIDRefusesWhole() throws {
        let (store, a, b) = try fixture()
        let depthBefore = store.undoHistory().undo.count
        #expect(throws: ProjectError.self) {
            try store.removeClips(ids: [a[0].id, UUID(), b[0].id])
        }
        #expect(clipIDs(store).count == 3)
        #expect(store.undoHistory().undo.count == depthBefore)
    }

    // 6. All-or-nothing, the case that actually happens: one take-comp member in
    //    the set refuses everything. A partial delete inside a single journal
    //    entry would be worse than a refusal — the undo would look complete while
    //    the edit never was.
    @Test("a comp member in the set refuses the whole delete")
    func compMemberRefusesWhole() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Comp", kind: .instrument)
        let free = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 2)
        let member = try store.addMIDIClip(toTrack: track.id, atBeat: 4, lengthBeats: 2)
        // Mark the second clip as a take-group member the way the store models it.
        let groupID = UUID()
        let index = store.tracks[0].clips.firstIndex { $0.id == member.id }!
        store.tracks[0].clips[index].takeGroupID = groupID

        let depthBefore = store.undoHistory().undo.count
        #expect(throws: ProjectError.self) {
            try store.removeClips(ids: [free.id, member.id])
        }
        #expect(clipIDs(store).count == 2)
        #expect(store.undoHistory().undo.count == depthBefore)
    }

    // 7. Degenerate inputs journal nothing (so an empty selection can never make
    //    the undo stack grow — the gate's own non-vacuity check depends on this).
    @Test("an empty id list is a no-op that journals nothing")
    func emptyIsNoOp() throws {
        let (store, _, _) = try fixture()
        let depthBefore = store.undoHistory().undo.count
        let removed = try store.removeClips(ids: [])
        #expect(removed.isEmpty)
        #expect(store.undoHistory().undo.count == depthBefore)
        #expect(clipIDs(store).count == 3)
    }

    // 8. Duplicate ids collapse — three copies of one id is a 1-clip delete, not a
    //    "Delete 3 Clips" that removed one, and never an index-out-of-range.
    @Test("duplicate ids collapse to one removal")
    func duplicatesCollapse() throws {
        let (store, a, _) = try fixture()
        let removed = try store.removeClips(ids: [a[0].id, a[0].id, a[0].id])
        #expect(removed.count == 1)
        #expect(store.undoLabel == "Delete 1 Clip")
        #expect(clipIDs(store).count == 2)
    }

    // 9. Descending-index removal within a track, proved on a track where the
    //    ascending order would corrupt: 3 clips, delete the first and last.
    @Test("removing several clips from ONE track keeps the survivors intact")
    func multipleFromOneTrack() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "One", kind: .instrument)
        let c0 = try store.addMIDIClip(toTrack: track.id, name: "C0", atBeat: 0, lengthBeats: 2)
        let c1 = try store.addMIDIClip(toTrack: track.id, name: "C1", atBeat: 4, lengthBeats: 2)
        let c2 = try store.addMIDIClip(toTrack: track.id, name: "C2", atBeat: 8, lengthBeats: 2)

        try store.removeClips(ids: [c0.id, c2.id])
        #expect(store.tracks[0].clips.map(\.name) == ["C1"])
        #expect(store.tracks[0].clips[0].id == c1.id)

        try store.undo()
        #expect(store.tracks[0].clips.map(\.name) == ["C0", "C1", "C2"])
    }
}
