import Foundation
import Testing
@testable import DAWCore

/// m23-g2 — `ProjectStore.moveClips(ids:byBeats:)`, the group-move verb behind
/// the arrange's multi-selection drag.
///
/// The two claims that carry the item are the WHOLE-GROUP beat-0 clamp
/// (offsets survive hitting the wall) and the NON-CONTIGUOUS overlap pass (a
/// group holding clips at bar 1 and bar 9 must not trim the innocent clip at
/// bar 5). The gesture-side claim — snap the ANCHOR once, never each clip —
/// lives in `ArrangeGroupDragTests` because it needs both this verb and
/// `ArrangeGroupDrag`, and it is only a real discriminator as a composition.
@MainActor
@Suite("Group clip move (m23-g2)")
struct ClipGroupMoveTests {

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// One instrument track holding 4-beat MIDI clips at each of `beats`, each
    /// carrying one note so a trim is OBSERVABLE as data loss and not merely as
    /// a length change.
    private func store(clipsAt beats: [Double]) throws -> (ProjectStore, UUID, [Clip]) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        var clips: [Clip] = []
        for beat in beats {
            clips.append(try store.addMIDIClip(
                toTrack: track.id, name: "C\(Int(beat))", atBeat: beat, lengthBeats: 4,
                notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)]))
        }
        return (store, track.id, clips)
    }

    private func start(_ store: ProjectStore, _ id: UUID) -> Double? {
        store.tracks.flatMap(\.clips).first { $0.id == id }?.startBeat
    }

    private func clip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap(\.clips).first { $0.id == id }
    }

    private func undoDepth(_ store: ProjectStore) -> Int { store.undoHistory().undo.count }

    // MARK: - Rigidity

    // 1.
    @Test("a group translates RIGIDLY — every offset survives the move exactly")
    func rigidTranslation() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        let result = try store.moveClips(ids: clips.map(\.id), byBeats: 4)

        #expect(result.effectiveDeltaBeats == 4)
        #expect(!result.clamped)
        #expect(start(store, clips[0].id) == 4)
        #expect(start(store, clips[1].id) == 12)
        #expect(start(store, clips[2].id) == 20)
        // The gaps are the point, not the absolute landings.
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! == 8)
        #expect(start(store, clips[2].id)! - start(store, clips[1].id)! == 8)
    }

    // 2.
    @Test("SUB-GRID PHASE survives — clips at 0 and 2.5 keep their 2.5-beat gap")
    func subGridPhaseSurvives() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 2.5])
        // The gesture would derive this delta by snapping the ANCHOR's absolute
        // start ONCE (bar grid, 4 beats): 0 + 3.4 → 4, so delta = 4. The verb
        // itself takes the delta and nothing else, which is what makes a
        // per-clip snap unreachable from here.
        _ = try store.moveClips(ids: clips.map(\.id), byBeats: 4)
        #expect(start(store, clips[0].id) == 4)
        #expect(start(store, clips[1].id) == 6.5)
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! == 2.5)
    }

    // 3.
    @Test("MIXED-TRACK selection preserves cross-track offsets under one delta")
    func mixedTrackOffsets() throws {
        let store = ProjectStore()
        let a = store.addTrack(kind: .instrument)
        let b = store.addTrack(kind: .instrument)
        let x = try store.addMIDIClip(toTrack: a.id, atBeat: 0, lengthBeats: 4)
        let y = try store.addMIDIClip(toTrack: b.id, atBeat: 3, lengthBeats: 4)

        _ = try store.moveClips(ids: [x.id, y.id], byBeats: 5)
        #expect(start(store, x.id) == 5)
        #expect(start(store, y.id) == 8)
        #expect(start(store, y.id)! - start(store, x.id)! == 3)
    }

    // MARK: - The whole-group beat-0 clamp

    // 4.
    @Test("WHOLE-GROUP beat-0 clamp: the leftmost lands on 0 and every offset survives")
    func wholeGroupClamp() throws {
        let (store, _, clips) = try self.store(clipsAt: [2, 6, 20])
        let result = try store.moveClips(ids: clips.map(\.id), byBeats: -10)

        #expect(result.requestedDeltaBeats == -10)
        #expect(result.effectiveDeltaBeats == -2)   // limited by the leftmost start
        #expect(result.clamped)
        #expect(start(store, clips[0].id) == 0)
        #expect(start(store, clips[1].id) == 4)
        #expect(start(store, clips[2].id) == 18)
    }

    // 5.
    @Test("VALIDITY LEG: the per-clip clamp this verb replaces WOULD have welded the group")
    func perClipClampWouldWeld() throws {
        // Calibrates test 4: it only discriminates if the naive alternative
        // gives a DIFFERENT answer on this fixture. `moveClip`'s per-clip
        // `max(0, toStartBeat)` — correct for one clip — collapses 2 and 6 onto
        // 0 and 0 here, i.e. welds a 4-beat gap shut and stacks two clips.
        let originals: [Double] = [2, 6, 20]
        let perClip = originals.map { max(0, $0 - 10) }
        #expect(perClip == [0, 0, 10])
        #expect(perClip[1] - perClip[0] == 0)   // the 4-beat gap is GONE
        // …whereas the whole-group clamp keeps it.
        let (store, _, clips) = try self.store(clipsAt: originals)
        _ = try store.moveClips(ids: clips.map(\.id), byBeats: -10)
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! == 4)
    }

    // 6.
    @Test("a group already at 0 refuses to move further left, and moves nothing")
    func clampAtWallIsANoOp() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8])
        let depth = undoDepth(store)
        let result = try store.moveClips(ids: clips.map(\.id), byBeats: -4)

        #expect(result.effectiveDeltaBeats == 0)
        #expect(result.clamped)
        #expect(start(store, clips[0].id) == 0)
        #expect(start(store, clips[1].id) == 8)
        #expect(undoDepth(store) == depth)   // nothing journalled for a no-op
    }

    // MARK: - The non-contiguous data-loss guard (the hazard the item exists for)

    // 7.
    @Test("NON-CONTIGUOUS group: the innocent clip BETWEEN two movers is untouched")
    func nonContiguousLeavesInnocentAlone() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        let innocent = clips[1]
        // Select the OUTER two only. A union window would be [2, 22) — which
        // fully covers the innocent clip at [8, 12) and would REMOVE it,
        // notes and all. Per-mover windows are [2,6) and [18,22), and neither
        // touches it.
        let result = try store.moveClips(ids: [clips[0].id, clips[2].id], byBeats: 2)

        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        let survivor = try #require(clip(store, innocent.id))
        #expect(survivor.startBeat == 8)
        #expect(survivor.lengthBeats == 4)
        #expect(survivor.notes?.count == 1)
        #expect(survivor.notes?.first?.pitch == 60)
        #expect(survivor.notes?.first?.lengthBeats == 2)
    }

    // 8.
    @Test("VALIDITY LEG: a UNION window over the same group would have destroyed it")
    func unionWindowWouldDestroyInnocent() throws {
        // Calibrates test 7 by running the rejected implementation through the
        // real choke point. If this passed harmlessly, test 7 would prove
        // nothing about the union hazard.
        let (store, trackID, clips) = try self.store(clipsAt: [0, 8, 16])
        let track = try #require(store.tracks.first { $0.id == trackID })
        let moved = track.clips.map { c -> Clip in
            guard c.id == clips[0].id || c.id == clips[2].id else { return c }
            var copy = c
            copy.startBeat += 2
            return copy
        }
        let union = ProjectStore.resolvingOverlaps(
            in: moved, activeIDs: [clips[0].id, clips[2].id],
            start: 2, end: 22, tempoMap: store.transport.tempoMap)
        #expect(union.removedIDs == [clips[1].id])
        #expect(union.clips.count == 2)   // the innocent clip is GONE
    }

    // 9.
    @Test("a mover that DOES land on a resident trims it, and says so")
    func moverTrimsWhatItLandsOn() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        // Move the clip at 0 by +6 → [6, 10), overlapping the resident's head
        // [8, 12). Trimming what you land on is the store's NORMAL behaviour
        // (m13-b) — the g2 defect was only ever trimming what you DON'T.
        let result = try store.moveClips(ids: [clips[0].id], byBeats: 6)
        #expect(result.trimmedClipIDs == [clips[1].id])
        #expect(result.removedClipIDs.isEmpty)
        let trimmed = try #require(clip(store, clips[1].id))
        #expect(trimmed.startBeat == 10)
        #expect(trimmed.lengthBeats == 2)
    }

    // 10.
    @Test("a mover that fully covers a resident REMOVES it, once, not twice")
    func removalReportedOnce() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        // Movers at 0 and 16 shifted +8 land on [8,12) and [24,28). The first
        // exactly covers the resident.
        let result = try store.moveClips(ids: [clips[0].id, clips[2].id], byBeats: 8)
        #expect(result.removedClipIDs == [clips[1].id])
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(clip(store, clips[1].id) == nil)
    }

    // MARK: - Order independence

    // 11.
    @Test("ORDER-INDEPENDENT: reversing the id order yields a BYTE-IDENTICAL clip array")
    func orderIndependent() throws {
        // The ids are FIXED across both runs. Rebuilding the fixture through
        // `addMIDIClip` would mint fresh UUIDs each time, and then a `[Clip] ==
        // [Clip]` comparison could never hold — which is not a weaker test, it
        // is a test of nothing.
        // Note ids too: `MIDINote.init` mints a fresh UUID, so without a fixed
        // one the two fixtures differ in note identity before anything moves.
        let ids = (0..<4).map { _ in UUID() }
        let noteIDs = (0..<4).map { _ in UUID() }
        func fixture() -> ProjectStore {
            let clips = zip(zip(ids, noteIDs), [0.0, 8, 16, 24]).map { pair, beat in
                Clip(id: pair.0, name: "C\(Int(beat))", startBeat: beat, lengthBeats: 4,
                     notes: [MIDINote(id: pair.1, pitch: 60, startBeat: 0, lengthBeats: 2)])
            }
            return ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: clips)])
        }
        // Non-trivial on purpose: mover 0 → [6,10) trims the resident at 8's
        // head, mover 16 → [22,26) covers mover 24's OLD slot (which is itself
        // a mover, so it must be EXEMPT from that pass), and mover 24 → [30,34).
        let moving = [ids[0], ids[2], ids[3]]

        let forwardStore = fixture()
        _ = try forwardStore.moveClips(ids: moving, byBeats: 6)
        let backwardStore = fixture()
        _ = try backwardStore.moveClips(ids: moving.reversed(), byBeats: 6)

        #expect(forwardStore.tracks[0].clips == backwardStore.tracks[0].clips)
        // …and the run is not vacuous: something actually happened to the
        // resident, so an order-dependent implementation had room to differ.
        #expect(forwardStore.tracks[0].clips.count == 4)
        #expect(forwardStore.tracks[0].clips.first { $0.id == ids[1] }?.startBeat == 10)
    }

    // 12.
    @Test("ORDER-INDEPENDENT even when the movers OVERLAP EACH OTHER (a crossfade pair)")
    func orderIndependentWithOverlappingMovers() throws {
        // The case where per-mover passes are NOT naturally order-independent,
        // and therefore the ONLY case in which sorting them earns its keep.
        //
        // Resident S = [10, 20). Movers A = [0, 3) and B = [2, 4) overlap each
        // OTHER by a beat — which only a sanctioned m11-d crossfade produces,
        // and which no store add path can build (hence the model-level fixture,
        // the m23-g1 unbuildable-fixture law). Moved +10 they land on [10, 13)
        // and [12, 14). Run A's pass first and S is head-trimmed twice to
        // [14, 20); run B's first and S is tail-trimmed to [10, 12) and then
        // FULLY COVERED by A — removed outright. Sorting by landing start does
        // not make one of those more principled than the other; it makes the
        // result independent of the order the caller happened to pass ids in.
        let ids = (0..<3).map { _ in UUID() }
        func fixture() -> ProjectStore {
            let url = URL(fileURLWithPath: "/tmp/X.wav")
            let clips = [
                Clip(id: ids[0], name: "A", startBeat: 0, lengthBeats: 3, audioFileURL: url),
                Clip(id: ids[1], name: "B", startBeat: 2, lengthBeats: 2, audioFileURL: url),
                Clip(id: ids[2], name: "S", startBeat: 10, lengthBeats: 10, audioFileURL: url),
            ]
            return ProjectStore(tracks: [Track(name: "Audio", kind: .audio, clips: clips)])
        }
        let forwardStore = fixture()
        _ = try forwardStore.moveClips(ids: [ids[0], ids[1]], byBeats: 10)
        let backwardStore = fixture()
        _ = try backwardStore.moveClips(ids: [ids[1], ids[0]], byBeats: 10)

        #expect(forwardStore.tracks[0].clips == backwardStore.tracks[0].clips)
        // Non-vacuous: the two orders really do have different outcomes
        // available, so agreement here is the sort working, not the fixture
        // being inert. The sorted (A-first) outcome keeps S as [14, 20).
        let survivor = try #require(forwardStore.tracks[0].clips.first { $0.id == ids[2] })
        #expect(survivor.startBeat == 14)
        #expect(survivor.lengthBeats == 6)
    }

    // 13.
    @Test("movers never trim EACH OTHER, even when one lands where another was")
    func moversAreMutuallyExempt() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 4, 8])
        // +4 marches each clip onto the slot its right-hand neighbour vacates.
        let result = try store.moveClips(ids: clips.map(\.id), byBeats: 4)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(start(store, clips[0].id) == 4)
        #expect(start(store, clips[1].id) == 8)
        #expect(start(store, clips[2].id) == 12)
        #expect(store.tracks[0].clips.count == 3)
    }

    // MARK: - Atomicity

    // 13.
    @Test("a 3-clip move is ONE undo step — asserted by DEPTH, not by 'the clips moved'")
    func oneUndoStep() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        let before = undoDepth(store)
        _ = try store.moveClips(ids: clips.map(\.id), byBeats: 4)

        // DEPTH is the only assertion that discriminates: at m23-g1 a mutation
        // that looped the single-clip verb still left the clips in the right
        // place and still redid correctly — only the depth changed.
        #expect(undoDepth(store) - before == 1)
        #expect(store.undoHistory().undo.first == "Move 3 Clips")
        _ = try store.undo()
        #expect(start(store, clips[0].id) == 0)
        #expect(start(store, clips[1].id) == 8)
        #expect(start(store, clips[2].id) == 16)
        #expect(undoDepth(store) == before)
    }

    // 14.
    @Test("ONE undo restores the movers AND every resident trim folded into it")
    func undoRestoresResidentTrims() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        let before = undoDepth(store)
        _ = try store.moveClips(ids: [clips[0].id, clips[2].id], byBeats: 8)
        #expect(clip(store, clips[1].id) == nil)
        #expect(undoDepth(store) - before == 1)

        _ = try store.undo()
        let restored = try #require(clip(store, clips[1].id))
        #expect(restored.startBeat == 8)
        #expect(restored.lengthBeats == 4)
        #expect(restored.notes?.count == 1)
        #expect(start(store, clips[0].id) == 0)
        #expect(start(store, clips[2].id) == 16)
    }

    // 15.
    @Test("a live DRAG's many updates coalesce to ONE entry (selection-stable key)")
    func dragCoalesces() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        let before = undoDepth(store)
        // What a drag emits: one call per pointer event, each asking only for
        // the part not yet applied.
        for _ in 0..<6 { _ = try store.moveClips(ids: clips.map(\.id), byBeats: 1) }
        #expect(start(store, clips[0].id) == 6)
        #expect(undoDepth(store) - before == 1)
        _ = try store.undo()
        #expect(start(store, clips[0].id) == 0)
    }

    // 16.
    @Test("a DIFFERENT selection does NOT coalesce into the previous group's entry")
    func differentSelectionsDoNotCoalesce() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        let before = undoDepth(store)
        _ = try store.moveClips(ids: [clips[0].id, clips[1].id], byBeats: 1)
        _ = try store.moveClips(ids: [clips[0].id, clips[2].id], byBeats: 1)
        #expect(undoDepth(store) - before == 2)
    }

    // 17.
    @Test("a ONE-clip group journals moveClip's label and key VERBATIM")
    func singleClipJournalIsUnchanged() throws {
        let (store, trackID, clips) = try self.store(clipsAt: [0])
        let before = undoDepth(store)
        _ = try store.moveClips(ids: [clips[0].id], byBeats: 4)
        // The arrange routes EVERY drag through this verb, so a single-clip drag
        // must keep reading exactly as it did before m23-g2 in the Edit menu.
        #expect(store.undoHistory().undo.first == "Move Clip 'C0'")
        #expect(undoDepth(store) - before == 1)
        // …and it coalesces with `moveClip`'s own key, proving the key matches
        // rather than merely looking similar.
        _ = try store.moveClip(trackId: trackID, clipId: clips[0].id, toStartBeat: 8)
        #expect(undoDepth(store) - before == 1)
        #expect(start(store, clips[0].id) == 8)
    }

    // MARK: - Validation / refusal

    // 18.
    @Test("a comp member in the set refuses WHOLE — the project is untouched")
    func compMemberRefusesWhole() throws {
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 62, startBeat: 0, lengthBeats: 1)])
        let track = Track(name: "Keys", kind: .instrument, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let ordinary = try store.addMIDIClip(toTrack: track.id, atBeat: 32, lengthBeats: 4)
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })

        let snapshot = store.tracks
        let depth = undoDepth(store)
        let err = projectError {
            _ = try store.moveClips(ids: [ordinary.id, member.id], byBeats: 4)
        }
        if case .clipInTakeGroup? = err {} else {
            Issue.record("expected clipInTakeGroup, got \(String(describing: err))")
        }
        // VALIDATE-FIRST: the ordinary clip listed BEFORE the comp member must
        // not have moved. A mutate-as-you-go implementation would have moved it.
        #expect(store.tracks == snapshot)
        #expect(start(store, ordinary.id) == 32)
        #expect(undoDepth(store) == depth)
    }

    // 19.
    @Test("an unknown id throws clipNotFound and moves nothing")
    func unknownIDRefusesWhole() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8])
        let snapshot = store.tracks
        let err = projectError {
            _ = try store.moveClips(ids: [clips[0].id, UUID()], byBeats: 4)
        }
        if case .clipNotFound? = err {} else {
            Issue.record("expected clipNotFound, got \(String(describing: err))")
        }
        #expect(store.tracks == snapshot)
    }

    // 20.
    @Test("an empty id set is a no-op that journals nothing")
    func emptySetIsANoOp() throws {
        let (store, _, _) = try self.store(clipsAt: [0, 8])
        let snapshot = store.tracks
        let depth = undoDepth(store)
        let result = try store.moveClips(ids: [], byBeats: 4)
        #expect(result.clips.isEmpty)
        #expect(result.effectiveDeltaBeats == 0)
        #expect(!result.clamped)
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
    }

    // 21.
    @Test("duplicate ids collapse — a clip listed twice moves ONCE")
    func duplicateIDsCollapse() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8])
        let result = try store.moveClips(
            ids: [clips[0].id, clips[0].id, clips[1].id], byBeats: 4)
        #expect(result.clips.count == 2)
        #expect(start(store, clips[0].id) == 4)
        #expect(start(store, clips[1].id) == 12)
    }

    // 22.
    @Test("a ZERO delta mutates nothing — a sanctioned crossfade overlap survives it")
    func zeroDeltaDoesNotDisturbASanctionedOverlap() throws {
        // A drag emits many events before it crosses a grid line. If those ran
        // the overlap pass at the clip's CURRENT position, a legitimately
        // overlapping pair — the sanctioned m11-d crossfade — would be trimmed
        // away by a gesture that moved nothing.
        //
        // FIXTURE NOTE (the m23-g1 unbuildable-fixture law): the overlap is
        // constructed at the MODEL level, not through `crossfadeClips`. The
        // store's own add path cannot produce overlapping clips at all (every
        // route goes through `resolvingOverlaps`), and `crossfadeClips` on
        // freshly-imported adjacent clips refuses with `crossfadeNeedsMaterial`
        // because neither has audio before its start to extend into the fade.
        // What is under test here is the ZERO-DELTA GUARD, and any overlapping
        // pair exercises it — including one loaded from a saved project, which
        // is how a real crossfaded pair reaches the store.
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     audioFileURL: URL(fileURLWithPath: "/tmp/A.wav"), fadeOutBeats: 1)
        let b = Clip(name: "B", startBeat: 3, lengthBeats: 4,
                     audioFileURL: URL(fileURLWithPath: "/tmp/B.wav"), fadeInBeats: 1)
        let store = ProjectStore(tracks: [Track(name: "Audio", kind: .audio, clips: [a, b])])
        let snapshot = store.tracks
        let depth = undoDepth(store)
        #expect(snapshot[0].clips.count == 2)   // the overlap really is there

        let result = try store.moveClips(ids: [b.id], byBeats: 0)
        #expect(result.effectiveDeltaBeats == 0)
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)

        // VALIDITY LEG: the guard is not vacuous — a NON-zero delta on the same
        // pair does run the overlap pass and does trim the partner, so "nothing
        // happened" above is the guard working, not the fixture being inert.
        let moved = try store.moveClips(ids: [b.id], byBeats: 0.5)
        #expect(moved.trimmedClipIDs == [a.id])
    }
}
