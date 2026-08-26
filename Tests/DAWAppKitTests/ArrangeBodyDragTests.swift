import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

/// m25-k — the arrange body drag's CADENCE: preview on every update, commit
/// exactly once on release.
///
/// USER-REPORTED 2026-08-13: *"just mare mooving across over the clips removes
/// it. It should go into effect only if I drag and drop it over the clip."* The
/// gesture called the real store move on every `.onChanged` frame, so the
/// drop-time overlap policy ran at every INTERMEDIATE position and ate whatever
/// the drag passed over.
///
/// ⚠️ WHAT THIS SUITE IS AND IS NOT. It pins the RULE (`ArrangeBodyDrag`) and the
/// COMPOSITION of that rule with the real store — the two halves that decide
/// whether a crossed clip survives. It cannot pin that `TimelineLanesView`
/// actually uses the rule; that is a wiring fact, and the answer to it is
/// structural rather than asserted: `ArrangeBodyDrag.update` returns Void and
/// the type holds no store reference, so per-frame destruction cannot be
/// reintroduced by editing a call site — it would take a new dependency. The
/// live path is reproducible through `debug.arrangeDrag {phase:"move"|"end"}`.
///
/// ⭐ EVERY SURVIVAL CLAIM HERE CARRIES A POSITIVE CONTROL that replays the OLD
/// per-frame cadence on an identical fixture and watches the clip die. A test
/// that only asserts "the resident is still there" passes just as happily
/// against a drag that never moved at all.
@MainActor
@Suite("Arrange body-drag cadence (m25-k)")
struct ArrangeBodyDragTests {

    // MARK: - Fixture

    /// One instrument track holding 4-beat MIDI clips at each of `beats`, each
    /// carrying one note — so a trim is OBSERVABLE as data loss and not merely
    /// as a length change (the `ClipGroupMoveTests` fixture, same reasoning).
    private func store(clipsAt beats: [Double]) throws -> (ProjectStore, [Clip]) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        var clips: [Clip] = []
        for beat in beats {
            clips.append(try store.addMIDIClip(
                toTrack: track.id, name: "C\(Int(beat))", atBeat: beat, lengthBeats: 4,
                notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)]))
        }
        return (store, clips)
    }

    private func clip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap(\.clips).first { $0.id == id }
    }

    /// Runs the gesture the way the SHIPPED view runs it: preview on every
    /// intermediate translation (touching nothing), then one commit.
    ///
    /// The commit half mirrors `AppModel.dragArrangeClips` — `ArrangeGroupDrag`
    /// plans the rigid delta, `ProjectStore.moveClips` applies it — because that
    /// composition is what the property is about. Reproducing the plan here
    /// rather than calling `AppModel` is forced: `AppModel` lives in the DAWApp
    /// executable target and no test target can import it.
    @discardableResult
    private func dragThrough(_ store: ProjectStore, anchor: Clip,
                             selection: Set<UUID>, path: [Double],
                             snap: ClipSnap = .off) throws -> ClipsMoveResult? {
        var drag = ArrangeBodyDrag(anchorClipID: anchor.id,
                                   anchorOriginalStart: anchor.startBeat)
        for delta in path {
            drag.update(rawDragDeltaBeats: delta)
            // The preview, in full: it asks the SAME two producers the commit
            // will and writes nothing. `plannedGroupBeatDelta` is the store's own
            // non-mutating clamp query.
            let anchorNow = clip(store, anchor.id)?.startBeat ?? anchor.startBeat
            let plan = ArrangeGroupDrag.plan(
                anchorOriginalStart: anchor.startBeat, anchorCurrentStart: anchorNow,
                rawDragDeltaBeats: delta, snap: snap, meterMap: store.transport.meterMap)
            _ = store.plannedGroupBeatDelta(ids: Array(selection), byBeats: plan.deltaBeats)
        }
        guard let commit = drag.commit() else { return nil }
        let anchorNow = clip(store, anchor.id)?.startBeat ?? anchor.startBeat
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: commit.anchorOriginalStart, anchorCurrentStart: anchorNow,
            rawDragDeltaBeats: commit.rawDragDeltaBeats,
            snap: snap, meterMap: store.transport.meterMap)
        return try store.moveClips(ids: Array(selection), byBeats: plan.deltaBeats)
    }

    /// THE POSITIVE CONTROL — the pre-m25-k cadence: commit EVERY frame.
    private func dragThroughDestructively(_ store: ProjectStore, anchor: Clip,
                                          selection: Set<UUID>, path: [Double],
                                          snap: ClipSnap = .off) throws {
        for delta in path {
            let anchorNow = clip(store, anchor.id)?.startBeat ?? anchor.startBeat
            let plan = ArrangeGroupDrag.plan(
                anchorOriginalStart: anchor.startBeat, anchorCurrentStart: anchorNow,
                rawDragDeltaBeats: delta, snap: snap, meterMap: store.transport.meterMap)
            _ = try store.moveClips(ids: Array(selection), byBeats: plan.deltaBeats)
        }
    }

    // MARK: - The rule

    // 1.
    @Test("update() previews only — the commit carries the FINAL translation, never a sum")
    func commitCarriesFinalDelta() {
        let id = UUID()
        var drag = ArrangeBodyDrag(anchorClipID: id, anchorOriginalStart: 4)
        for delta in [1.0, 2.0, 3.0, 7.5, 12.0] { drag.update(rawDragDeltaBeats: delta) }

        let commit = drag.commit()
        #expect(commit?.anchorClipID == id)
        #expect(commit?.anchorOriginalStart == 4)
        // 12, not 25.5 — SwiftUI's `translation` is already measured from the
        // gesture's start, so accumulating updates would double-count the drag.
        #expect(commit?.rawDragDeltaBeats == 12)
    }

    // 2.
    @Test("commit() fires exactly ONCE — a release delivered twice moves the clip once")
    func commitIsIdempotent() {
        var drag = ArrangeBodyDrag(anchorClipID: UUID(), anchorOriginalStart: 0)
        drag.update(rawDragDeltaBeats: 8)

        #expect(drag.commit() != nil)
        #expect(drag.isSpent)
        // `clipDrag` and `stretchDrag` share this state and can both receive the
        // release; a second commit would journal the move twice, which the
        // `clip.move` coalescing key would hide in the undo stack.
        #expect(drag.commit() == nil)
        #expect(drag.commit() == nil)
    }

    // 3.
    @Test("a spent drag ignores further updates — no zombie gesture keeps previewing")
    func spentDragIgnoresUpdates() {
        var drag = ArrangeBodyDrag(anchorClipID: UUID(), anchorOriginalStart: 0)
        drag.update(rawDragDeltaBeats: 8)
        _ = drag.commit()
        drag.update(rawDragDeltaBeats: 99)

        #expect(drag.rawDragDeltaBeats == 8)
    }

    // 4.
    @Test("cancel() commits NOTHING — a swallowed gesture must not reach the store")
    func cancelCommitsNothing() {
        var drag = ArrangeBodyDrag(anchorClipID: UUID(), anchorOriginalStart: 0)
        drag.update(rawDragDeltaBeats: 16)
        drag.cancel()

        #expect(drag.isSpent)
        #expect(drag.commit() == nil)
    }

    // MARK: - THE REGRESSION (the user's bug)

    // 5.
    @Test("a drag whose PATH crosses a clip but LANDS clear of it leaves that clip untouched")
    func crossedClipSurvives() throws {
        // Mover at [0,4); an innocent resident at [8,12); the drop at [16,20).
        // The path runs the mover straight through the resident.
        let (store, clips) = try self.store(clipsAt: [0, 8])
        let mover = clips[0], resident = clips[1]
        let path = [2.0, 4, 6, 8, 9, 10, 11, 12, 14, 16]

        try dragThrough(store, anchor: mover, selection: [mover.id], path: path)

        #expect(clip(store, mover.id)?.startBeat == 16)
        // The whole item, in three lines.
        #expect(clip(store, resident.id)?.startBeat == 8)
        #expect(clip(store, resident.id)?.lengthBeats == 4)
        #expect(clip(store, resident.id)?.notes?.count == 1)
    }

    // 6.
    @Test("POSITIVE CONTROL: the OLD per-frame cadence destroys that same crossed clip")
    func crossedClipDiesUnderTheOldCadence() throws {
        let (store, clips) = try self.store(clipsAt: [0, 8])
        let mover = clips[0], resident = clips[1]
        let path = [2.0, 4, 6, 8, 9, 10, 11, 12, 14, 16]

        try dragThroughDestructively(store, anchor: mover, selection: [mover.id], path: path)

        // Same destination…
        #expect(clip(store, mover.id)?.startBeat == 16)
        // …and the user's report: the clip they merely passed over is GONE.
        // If this ever stops failing to find the resident, test 5 has stopped
        // discriminating and is passing vacuously.
        #expect(clip(store, resident.id) == nil)
    }

    // 7.
    @Test("the whole drag is ONE undo step — a preview journals nothing")
    func oneUndoStep() throws {
        let (store, clips) = try self.store(clipsAt: [0, 8])
        let mover = clips[0]
        let before = store.undoHistory().undo.count

        try dragThrough(store, anchor: mover, selection: [mover.id],
                        path: [2.0, 4, 6, 8, 10, 12, 14, 16])

        #expect(store.undoHistory().undo.count == before + 1)
        // …and it reverses the whole gesture, not its last frame.
        try store.undo()
        #expect(clip(store, mover.id)?.startBeat == 0)
    }

    // MARK: - THE CONVERSE (the fix must not over-correct)

    // 8.
    @Test("a drag that LANDS fully covering a clip still REMOVES it — drop-time overwrite stays")
    func landingOnTopStillRemoves() throws {
        // Mover [0,4) dropped exactly onto resident [8,12).
        let (store, clips) = try self.store(clipsAt: [0, 8])
        let mover = clips[0], resident = clips[1]

        try dragThrough(store, anchor: mover, selection: [mover.id], path: [4.0, 6, 8])

        #expect(clip(store, mover.id)?.startBeat == 8)
        #expect(clip(store, resident.id) == nil)
    }

    // 9.
    @Test("a drag that LANDS partly over a clip still TRIMS it")
    func landingPartlyOverStillTrims() throws {
        // Mover [0,4) dropped at [10,14): the resident [8,12) keeps its head and
        // its trailing edge trims to the mover's left edge (`moveClips` policy).
        let (store, clips) = try self.store(clipsAt: [0, 8])
        let mover = clips[0], resident = clips[1]

        let result = try dragThrough(store, anchor: mover, selection: [mover.id],
                                     path: [3.0, 6, 10])

        #expect(clip(store, mover.id)?.startBeat == 10)
        #expect(clip(store, resident.id)?.startBeat == 8)
        #expect(clip(store, resident.id)?.lengthBeats == 2)
        #expect(result?.trimmedClipIDs == [resident.id])
    }

    // MARK: - The group

    // 10.
    @Test("a GROUP drag previews and commits as one — offsets survive, innocents between survive")
    func groupDragKeepsOffsetsAndSpares() throws {
        // Movers at 0 and 16; an innocent at 8, strictly between them, which no
        // mover ever LANDS on. Destination: +24, so both movers sweep across it.
        let (store, clips) = try self.store(clipsAt: [0, 8, 16])
        let a = clips[0], innocent = clips[1], b = clips[2]

        try dragThrough(store, anchor: a, selection: [a.id, b.id],
                        path: [4.0, 8, 12, 16, 20, 24])

        #expect(clip(store, a.id)?.startBeat == 24)
        #expect(clip(store, b.id)?.startBeat == 40)
        #expect(clip(store, innocent.id)?.startBeat == 8)
        #expect(clip(store, innocent.id)?.lengthBeats == 4)
    }

    // MARK: - The preview's own honesty

    // 11.
    @Test("the previewed delta is the one the commit achieves — including at the beat-0 wall")
    func previewMatchesCommitAtTheWall() throws {
        let (store, clips) = try self.store(clipsAt: [4, 12])
        let ids: Set<UUID> = [clips[0].id, clips[1].id]

        // Ask to travel far past beat 0. The gesture's own anchor floor absorbs
        // part of it; the store's whole-group clamp answers for the rest.
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: 4, anchorCurrentStart: 4, rawDragDeltaBeats: -100,
            snap: .off, meterMap: store.transport.meterMap)
        let planned = store.plannedGroupBeatDelta(ids: Array(ids), byBeats: plan.deltaBeats)

        // The query MOVED NOTHING…
        #expect(clip(store, clips[0].id)?.startBeat == 4)
        #expect(clip(store, clips[1].id)?.startBeat == 12)

        // …and the commit lands exactly where the preview promised.
        let result = try store.moveClips(ids: Array(ids), byBeats: plan.deltaBeats)
        #expect(result.effectiveDeltaBeats == planned.effective)
        #expect(result.clamped == planned.clamped)
        #expect(clip(store, clips[0].id)?.startBeat == 0)
        #expect(clip(store, clips[1].id)?.startBeat == 8)
    }

    // MARK: - The SECOND axis (m25-l-2)

    /// Three instrument lanes. The MOVER sits on lane 0 at beat 0; lanes 1 and 2
    /// each hold a 4-beat resident at beat 8, so a drag that travels +8 beats and
    /// down 2 rows LANDS on lane 2's resident and merely PASSES OVER lane 1's.
    /// Every clip carries a note, so a casualty is observable as data loss.
    private func laddered() throws -> (ProjectStore, mover: Clip, residents: [Clip]) {
        let store = ProjectStore()
        let lanes = (0..<3).map { _ in store.addTrack(kind: .instrument) }
        let mover = try store.addMIDIClip(
            toTrack: lanes[0].id, name: "mover", atBeat: 0, lengthBeats: 4,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)])
        let residents = try [lanes[1], lanes[2]].map {
            try store.addMIDIClip(
                toTrack: $0.id, name: "resident", atBeat: 8, lengthBeats: 4,
                notes: [MIDINote(pitch: 72, startBeat: 0, lengthBeats: 2)])
        }
        return (store, mover, residents)
    }

    private func row(_ store: ProjectStore, _ id: UUID) -> Int? {
        store.tracks.firstIndex { $0.clips.contains { $0.id == id } }
    }

    /// The gesture as SHIPPED, both axes: preview every frame (touching nothing),
    /// commit once through the cross-track verb.
    @discardableResult
    private func dragThroughLanes(_ store: ProjectStore, anchor: Clip,
                                  selection: Set<UUID>,
                                  path: [(beats: Double, rows: Int)]) throws
        -> ClipsTrackMoveResult? {
        var drag = ArrangeBodyDrag(anchorClipID: anchor.id,
                                   anchorOriginalStart: anchor.startBeat)
        for frame in path {
            drag.update(rawDragDeltaBeats: frame.beats, requestedTrackDelta: frame.rows)
            // The preview asks; it never writes. Both axes, same frame.
            _ = ArrangeVerticalDrag.effectiveDelta(
                requested: frame.rows, movingClipIDs: selection, tracks: store.tracks)
            _ = store.plannedGroupBeatDelta(ids: Array(selection), byBeats: frame.beats)
        }
        guard let commit = drag.commit() else { return nil }
        let rows = ArrangeVerticalDrag.effectiveDelta(
            requested: commit.requestedTrackDelta, movingClipIDs: selection,
            tracks: store.tracks)
        return try store.moveClips(ids: Array(selection), byTracks: rows,
                                   byBeats: commit.rawDragDeltaBeats)
    }

    // 12.
    @Test("the vertical request travels with the drag — commit carries the LAST row, never a sum")
    func commitCarriesTheFinalRow() {
        let id = UUID()
        var drag = ArrangeBodyDrag(anchorClipID: id, anchorOriginalStart: 0)
        drag.update(rawDragDeltaBeats: 2, requestedTrackDelta: 1)
        drag.update(rawDragDeltaBeats: 5, requestedTrackDelta: 2)
        drag.update(rawDragDeltaBeats: 9, requestedTrackDelta: 3)
        let commit = drag.commit()
        // 3, not 1 + 2 + 3 — the row is derived from the ABSOLUTE row under the
        // pointer, so accumulating it would multiply the user's intent.
        #expect(commit?.requestedTrackDelta == 3)
        #expect(commit?.rawDragDeltaBeats == 9)
    }

    // 13.
    @Test("a cancelled cross-track drag commits no row at all")
    func cancelledCrossTrackDragCommitsNothing() {
        let id = UUID()
        var drag = ArrangeBodyDrag(anchorClipID: id, anchorOriginalStart: 0)
        drag.update(rawDragDeltaBeats: 4, requestedTrackDelta: 2)
        drag.cancel()
        #expect(drag.commit() == nil)
    }

    // 14.
    @Test("a drag with no vertical request is unchanged — the same-track path is untouched")
    func noVerticalRequestLeavesTheSameTrackPathAlone() {
        let id = UUID()
        var drag = ArrangeBodyDrag(anchorClipID: id, anchorOriginalStart: 0)
        drag.update(rawDragDeltaBeats: 4)
        #expect(drag.requestedTrackDelta == 0)
        #expect(drag.commit()?.requestedTrackDelta == 0)
    }

    /// ⭐⭐ **THE WHOLE POINT OF THIS ITEM RIDING m25-k's SPLIT.** A cross-lane
    /// drag passes over EVERY lane between its start and its landing. If the
    /// land-time overlap policy ran per frame, each of those lanes would be
    /// resolved against — the m25-k defect with a wider blast radius.
    // 15.
    @Test("a drag PASSING OVER a lane leaves that lane's clips untouched")
    func passingOverALaneLeavesItUntouched() throws {
        let (store, mover, residents) = try laddered()
        try dragThroughLanes(store, anchor: mover, selection: [mover.id],
                             path: [(2, 0), (5, 1), (8, 1), (8, 2)])

        #expect(row(store, mover.id) == 2)
        #expect(clip(store, mover.id)?.startBeat == 8)
        // Lane 1 was crossed, never dropped on — its clip is whole.
        #expect(clip(store, residents[0].id)?.lengthBeats == 4)
        #expect(clip(store, residents[0].id)?.notes?.count == 1)
        // Lane 2 was LANDED on, fully covered — drop-time overwrite still applies.
        #expect(clip(store, residents[1].id) == nil)
    }

    /// THE POSITIVE CONTROL — without it the test above cannot tell "the split
    /// works" from "nothing was ever at risk on that lane". This is the naive
    /// per-frame cross-track cadence: every frame moves the clip to the row the
    /// pointer is over, so every intermediate lane gets the landing treatment.
    // 16.
    @Test("POSITIVE CONTROL: a per-frame cross-track cadence eats the lane it passes over")
    func perFrameCrossTrackCadenceEatsThePassedLane() throws {
        let (store, mover, residents) = try laddered()
        let path: [(beats: Double, rows: Int)] = [(2, 0), (5, 1), (8, 1), (8, 2)]
        for frame in path {
            let here = row(store, mover.id) ?? 0
            _ = try store.moveClips(ids: [mover.id], byTracks: frame.rows - here,
                                    byBeats: frame.beats - (clip(store, mover.id)?.startBeat ?? 0))
        }
        // BOTH residents die — the crossed one as well as the landed-on one.
        #expect(clip(store, residents[0].id) == nil)
        #expect(clip(store, residents[1].id) == nil)
    }

    /// The vertical twin of `previewedDeltaIsTheCommittedDelta`: the number the
    /// ghost draws is the number the drop achieves, at the bottom wall too.
    // 17.
    @Test("the previewed row is the one the commit achieves — including at the last lane")
    func previewedRowIsTheCommittedRow() throws {
        let (store, mover, _) = try laddered()
        // Ask to travel far past the last lane; the whole-group clamp answers.
        let previewed = ArrangeVerticalDrag.effectiveDelta(
            requested: 99, movingClipIDs: [mover.id], tracks: store.tracks)
        #expect(previewed == 2)
        // The query MOVED NOTHING…
        #expect(row(store, mover.id) == 0)
        // …and the commit lands exactly where the preview promised.
        let result = try store.moveClips(ids: [mover.id], byTracks: previewed)
        #expect(result.effectiveTrackDelta == previewed)
        #expect(result.clampedTracks == false)   // the gesture pre-clamped it
        #expect(row(store, mover.id) == 2)
    }
}
