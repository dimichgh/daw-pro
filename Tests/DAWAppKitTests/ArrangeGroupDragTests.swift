import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m23-g2 — the arrange GROUP DRAG, tested as the COMPOSITION the app actually
/// runs: `ArrangeGroupDrag.plan` (snap the anchor once, derive a rigid delta)
/// feeding `ProjectStore.moveClips` (clamp the whole group, land every clip).
///
/// WHY THE COMPOSITION AND NOT THE PIECES: the defect this item exists to
/// prevent — a group WELDED together because each clip's absolute start was
/// snapped independently — lives in neither piece alone. `moveClips` never
/// snaps, so a store-only test of a hardcoded delta passes against the broken
/// implementation too; `plan` never touches the other clips, so a plan-only
/// test cannot see the welding either. Only wiring them together discriminates,
/// which is why the headline test lives here rather than in `DAWCoreTests`.
///
/// Every discriminating test below carries a VALIDITY LEG that runs the
/// REJECTED implementation — per-clip `ClipEdit.movedStartBeat` into
/// `ProjectStore.moveClip`, which is literally what the arrange did before g2 —
/// and asserts it produces a DIFFERENT, wrong answer on the same fixture. A
/// green test whose fixture cannot tell the two apart is decorative (m23-d).
@MainActor
@Suite("Arrange group drag (m23-g2)")
struct ArrangeGroupDragTests {

    private func meter(_ bpb: Int = 4) -> MeterMap {
        MeterMap(constant: TimeSignature(beatsPerBar: bpb))
    }

    /// One instrument track with 2-beat MIDI clips at each of `beats`.
    private func store(clipsAt beats: [Double]) throws -> (ProjectStore, UUID, [Clip]) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        var clips: [Clip] = []
        for beat in beats {
            clips.append(try store.addMIDIClip(
                toTrack: track.id, name: "C\(beat)", atBeat: beat, lengthBeats: 2,
                notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)]))
        }
        return (store, track.id, clips)
    }

    private func start(_ store: ProjectStore, _ id: UUID) -> Double? {
        store.tracks.flatMap(\.clips).first { $0.id == id }?.startBeat
    }

    /// The SHIPPED path: plan once off the anchor, translate the group rigidly.
    @discardableResult
    private func groupDrag(_ store: ProjectStore, anchor: Clip, ids: [UUID],
                           rawDeltaBeats: Double, snap: ClipSnap,
                           meterMap: MeterMap) throws -> ClipsMoveResult {
        let anchorCurrent = start(store, anchor.id) ?? anchor.startBeat
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: anchor.startBeat, anchorCurrentStart: anchorCurrent,
            rawDragDeltaBeats: rawDeltaBeats, snap: snap, meterMap: meterMap)
        return try store.moveClips(ids: ids, byBeats: plan.deltaBeats)
    }

    /// The REJECTED path, kept only as a validity instrument: snap EACH clip's
    /// own absolute start and move it there — i.e. `applyDrag`'s pre-g2 `.body`
    /// case applied to every member of a selection.
    private func perClipDrag(_ store: ProjectStore, trackID: UUID, clips: [Clip],
                             rawDeltaBeats: Double, snap: ClipSnap,
                             meterMap: MeterMap) throws {
        for clip in clips {
            let target = ClipEdit.movedStartBeat(
                originalStart: clip.startBeat, dragDeltaBeats: rawDeltaBeats,
                snap: snap, meterMap: meterMap)
            _ = try store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: target)
        }
    }

    // MARK: - The headline discriminator

    // 1.
    @Test("SUB-GRID PHASE: clips at 0 and 2.5 under BAR snap keep their 2.5-beat gap")
    func subGridPhaseSurvivesTheDrag() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 2.5])
        // Anchor = the clip under the pointer = the one at 0. A 3.4-beat raw
        // drag snaps the ANCHOR to bar 1 (beat 4), so the whole group moves +4.
        try groupDrag(store, anchor: clips[0], ids: clips.map(\.id),
                      rawDeltaBeats: 3.4, snap: .bar, meterMap: meter())

        #expect(start(store, clips[0].id) == 4)
        #expect(start(store, clips[1].id) == 6.5)
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! == 2.5)
    }

    // 2.
    @Test("VALIDITY LEG: per-clip snapping WELDS that same pair onto one beat")
    func perClipSnappingWeldsThePair() throws {
        let (store, trackID, clips) = try self.store(clipsAt: [0, 2.5])
        // THE WELD ITSELF: 0 + 3.4 → 4 and 2.5 + 3.4 = 5.9 → 4. Both clips are
        // sent to the SAME barline, which is the whole defect.
        #expect(ClipEdit.movedStartBeat(originalStart: 0, dragDeltaBeats: 3.4,
                                        snap: .bar, meterMap: meter()) == 4)
        #expect(ClipEdit.movedStartBeat(originalStart: 2.5, dragDeltaBeats: 3.4,
                                        snap: .bar, meterMap: meter()) == 4)

        try perClipDrag(store, trackID: trackID, clips: clips,
                        rawDeltaBeats: 3.4, snap: .bar, meterMap: meter())
        // And what the weld COSTS, once the no-silent-overlap policy resolves
        // two clips sent to one beat: the first clip is trimmed from 2 beats to
        // half a beat and shoved to 5.5, the second sits at 4. The 2.5-beat gap
        // the user arranged has become a 1.5-beat one in the opposite direction,
        // and 75% of a clip is gone. Test 1 therefore discriminates — the same
        // fixture gives a materially different answer under the rejected
        // implementation.
        #expect(start(store, clips[1].id) == 4)
        #expect(start(store, clips[0].id) == 5.5)
        let damaged = try #require(store.tracks.flatMap(\.clips).first { $0.id == clips[0].id })
        #expect(damaged.lengthBeats == 0.5)
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! != 2.5)
    }

    // 3.
    @Test("the ANCHOR is the clip under the pointer — dragging the OFF-grid one still keeps the gap")
    func anchorIsTheGrabbedClip() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 2.5])
        // Same pair, but the pointer is on the OFF-GRID clip. Its start snaps:
        // 2.5 + 3.4 = 5.9 → bar 4, so the group moves by 4 - 2.5 = +1.5.
        try groupDrag(store, anchor: clips[1], ids: clips.map(\.id),
                      rawDeltaBeats: 3.4, snap: .bar, meterMap: meter())
        #expect(start(store, clips[1].id) == 4)      // the ANCHOR is on the grid
        #expect(start(store, clips[0].id) == 1.5)    // the other keeps its offset
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! == 2.5)
    }

    // MARK: - The clamp, and what it costs

    // 4.
    @Test("beat-0 clamp: OFFSETS WIN OVER SNAP — the anchor lands off-grid, the gap survives")
    func clampBeatsSnap() throws {
        let (store, _, clips) = try self.store(clipsAt: [1.5, 6])
        // Anchor = the clip at 6, dragged 5 beats left: 6 - 5 = 1 → bar snap → 0,
        // i.e. a requested delta of -6. The leftmost sits at 1.5, so the group
        // can only travel -1.5.
        let result = try groupDrag(store, anchor: clips[1], ids: clips.map(\.id),
                                   rawDeltaBeats: -5, snap: .bar, meterMap: meter())
        #expect(result.requestedDeltaBeats == -6)
        #expect(result.effectiveDeltaBeats == -1.5)
        #expect(result.clamped)
        #expect(start(store, clips[0].id) == 0)      // leftmost exactly on 0
        #expect(start(store, clips[1].id) == 4.5)    // anchor OFF the bar grid
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! == 4.5)
    }

    // 5.
    @Test("VALIDITY LEG: per-clip clamping stacks that same pair at 0")
    func perClipClampStacks() throws {
        let (store, trackID, clips) = try self.store(clipsAt: [1.5, 6])
        try perClipDrag(store, trackID: trackID, clips: clips,
                        rawDeltaBeats: -5, snap: .bar, meterMap: meter())
        // 1.5 - 5 → floored to 0 → bar snap → 0;  6 - 5 = 1 → bar snap → 0.
        // Both at 0, so the second removes the first: a 4.5-beat gap deleted
        // along with a clip.
        #expect(start(store, clips[0].id) == nil)
        #expect(start(store, clips[1].id) == 0)
    }

    // MARK: - `plan` itself

    // 6.
    @Test("plan snaps the ANCHOR's ABSOLUTE start, exactly once")
    func planSnapsTheAnchorAbsolutely() {
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: 2.5, anchorCurrentStart: 2.5, rawDragDeltaBeats: 3.4,
            snap: .bar, meterMap: meter())
        #expect(plan.snappedAnchorStart == 4)
        #expect(plan.deltaBeats == 1.5)
        // Nothing about the OTHER selected clips can enter this decision — the
        // signature does not admit them. That is what makes per-clip snapping
        // structurally unreachable from the shipped path, rather than merely
        // absent from it.
    }

    // 7.
    @Test("plan is SELF-CORRECTING: it asks only for the part not already applied")
    func planIsIncremental() {
        // Mid-drag: origin 0, the group has already travelled +4, and the same
        // raw translation is reported again.
        let again = ArrangeGroupDrag.plan(
            anchorOriginalStart: 0, anchorCurrentStart: 4, rawDragDeltaBeats: 4,
            snap: .bar, meterMap: meter())
        #expect(again.deltaBeats == 0)
        // Pulled further out.
        let further = ArrangeGroupDrag.plan(
            anchorOriginalStart: 0, anchorCurrentStart: 4, rawDragDeltaBeats: 8,
            snap: .bar, meterMap: meter())
        #expect(further.deltaBeats == 4)
        // Pulled back past the origin.
        let back = ArrangeGroupDrag.plan(
            anchorOriginalStart: 8, anchorCurrentStart: 12, rawDragDeltaBeats: -4,
            snap: .bar, meterMap: meter())
        #expect(back.deltaBeats == -8)
    }

    // 8.
    @Test("a clamped drag pulled back out lands where an unclamped one would")
    func clampIsNotRemembered() throws {
        let (store, _, clips) = try self.store(clipsAt: [2, 6])
        let anchor = clips[1]
        // Shove left into the wall.
        try groupDrag(store, anchor: anchor, ids: clips.map(\.id),
                      rawDeltaBeats: -20, snap: .off, meterMap: meter())
        #expect(start(store, clips[0].id) == 0)
        #expect(start(store, clips[1].id) == 4)
        // Now pull right to +6 from the ORIGIN, in one more update of the SAME
        // drag. The group must land as if the clamp had never happened.
        try groupDrag(store, anchor: anchor, ids: clips.map(\.id),
                      rawDeltaBeats: 6, snap: .off, meterMap: meter())
        #expect(start(store, clips[0].id) == 8)
        #expect(start(store, clips[1].id) == 12)
    }

    // 9.
    @Test("snap OFF passes the raw drag straight through, still floored at 0")
    func snapOffIsRaw() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 2.5])
        try groupDrag(store, anchor: clips[0], ids: clips.map(\.id),
                      rawDeltaBeats: 3.4, snap: .off, meterMap: meter())
        #expect(start(store, clips[0].id) == 3.4)
        #expect(start(store, clips[1].id) == 5.9)
    }

    // 10.
    @Test("a whole live drag — many updates — is ONE undo step that restores everything")
    func liveDragIsOneUndoStep() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 2.5, 9])
        let anchor = clips[0]
        let before = store.undoHistory().undo.count
        // A drag ramping from 0.4 to 8.4 beats of raw translation, bar-snapped:
        // the anchor crosses barlines 0 → 0 → 4 → 4 → 8.
        for raw in [0.4, 1.9, 3.4, 5.4, 7.4, 8.4] {
            try groupDrag(store, anchor: anchor, ids: clips.map(\.id),
                          rawDeltaBeats: raw, snap: .bar, meterMap: meter())
        }
        #expect(start(store, clips[0].id) == 8)
        #expect(start(store, clips[1].id) == 10.5)
        #expect(start(store, clips[2].id) == 17)
        #expect(store.undoHistory().undo.count - before == 1)

        _ = try store.undo()
        #expect(start(store, clips[0].id) == 0)
        #expect(start(store, clips[1].id) == 2.5)
        #expect(start(store, clips[2].id) == 9)
        #expect(store.undoHistory().undo.count == before)
    }

    // 11.
    @Test("a NON-CONTIGUOUS group drag leaves the innocent clip between the movers intact")
    func nonContiguousDragIsSafe() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 8, 16])
        let innocent = clips[1]
        // FIXTURE COMPUTED, NOT GUESSED: the bar grid is 4 beats, so a +4 move
        // of the anchor at 0 needs a raw translation in [2, 6) — `round(r/4)*4`
        // is 0 below 2. (An earlier draft used 1.6, which snapped to 0 and made
        // this a no-op that would still have "passed" every survivor check.)
        try groupDrag(store, anchor: clips[0], ids: [clips[0].id, clips[2].id],
                      rawDeltaBeats: 2.6, snap: .bar, meterMap: meter())
        #expect(start(store, clips[0].id) == 4)
        #expect(start(store, clips[2].id) == 20)
        let survivor = try #require(store.tracks.flatMap(\.clips).first { $0.id == innocent.id })
        #expect(survivor.startBeat == 8)
        #expect(survivor.lengthBeats == 2)
        #expect(survivor.notes?.count == 1)
    }

    // 12.
    @Test("meter-aware: a BAR-snapped anchor drag into a 6/8 section snaps on ITS barlines")
    func meterAwareAnchorSnap() throws {
        // 4/4 up to beat 16, then 6/8 (bpb 6): barlines 0,4,8,12,16,22,28…
        let map = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 6, beatUnit: 8),
        ])
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: 12, anchorCurrentStart: 12, rawDragDeltaBeats: 9,
            snap: .bar, meterMap: map)
        #expect(plan.snappedAnchorStart == 22)
        #expect(plan.deltaBeats == 10)
    }

    // MARK: - "Was this drag reduced?" — the two stages (m23-g2 round 2)

    // WHAT THESE TESTS CAN AND CANNOT PROVE, stated so nobody reads them as more
    // than they are. `ArrangeGroupDragOutcome.clamped` — the union the debug echo
    // publishes — lives in `DAWApp` and is unreachable from here. These legs pin
    // the two INPUTS to that union (`Plan.flooredAtZero` and
    // `ClipsMoveResult.clamped`) and, critically, pin WHICH stage fires for each
    // fixture. They deliberately do NOT recompute the union: a test-local
    // `a || b` would be a SECOND producer of the very quantity under test, free
    // to agree with the app by luck (the m23-f finding). The app's actual
    // wiring is proven end-to-end by `scripts/gates/m23g2-group-drag.mjs` P8.

    // 13.
    @Test("ANCHOR-SYMMETRY: identical geometry reports the SAME reduction from either grab")
    func reductionIsNotAnchorDependent() throws {
        // The defect this exists to prevent, exactly as it was measured on a
        // live staging app in independent verification: clips at 4 and 12,
        // both selected, dragged -10 with snap OFF. Both grabs land the group
        // at 0 and 8 with an effective delta of -4 — but only ONE of them
        // reached the wall via the store.
        func run(anchorIndex: Int) throws -> (starts: [Double?], plan: ArrangeGroupDrag.Plan,
                                              result: ClipsMoveResult) {
            let (store, _, clips) = try self.store(clipsAt: [4, 12])
            let anchor = clips[anchorIndex]
            let plan = ArrangeGroupDrag.plan(
                anchorOriginalStart: anchor.startBeat, anchorCurrentStart: anchor.startBeat,
                rawDragDeltaBeats: -10, snap: .off, meterMap: meter())
            let result = try store.moveClips(ids: clips.map(\.id), byBeats: plan.deltaBeats)
            return ([start(store, clips[0].id), start(store, clips[1].id)], plan, result)
        }
        let left = try run(anchorIndex: 0)    // grab the LEFTMOST
        let right = try run(anchorIndex: 1)   // grab the RIGHTMOST

        // The geometry is identical — this was never in doubt and is the reason
        // the contradictory report was so easy to miss.
        #expect(left.starts.map { $0 ?? -1 } == [0, 8])
        #expect(right.starts.map { $0 ?? -1 } == [0, 8])
        #expect(left.result.effectiveDeltaBeats == -4)
        #expect(right.result.effectiveDeltaBeats == -4)

        // Grabbing the LEFTMOST: the gesture floor absorbs the reduction
        // (4 - 10 = -6 → floored to 0 → delta -4), so the store is asked for
        // exactly what it can do and honestly reports NO clamp.
        #expect(left.plan.flooredAtZero)
        #expect(left.result.clamped == false)
        #expect(left.result.requestedDeltaBeats == -4)

        // Grabbing the RIGHTMOST: the anchor lands at 12 - 10 = 2, well above
        // the floor, so the whole reduction happens in the STORE.
        #expect(right.plan.flooredAtZero == false)
        #expect(right.result.clamped)
        #expect(right.result.requestedDeltaBeats == -10)

        // The point, in one line: NEITHER stage's flag answers "was this drag
        // reduced?" on its own. Each is false in one of two runs that produced
        // byte-identical results.
        #expect(left.plan.flooredAtZero != right.plan.flooredAtZero)
        #expect(left.result.clamped != right.result.clamped)
    }

    // 14.
    @Test("a downward SNAP is not a clamp — reaching beat 0 by grid reports neither flag")
    func snappingDownToZeroIsNotAClamp() throws {
        // THE OVER-CORRECTION GUARD. The tempting broad predicate — "the landing
        // ended up below what was asked for" — would report a clamp here, and
        // it would be wrong: the anchor is pulled to 0 by the BAR GRID, not by
        // any floor. One clip at 1.5, dragged -0.5: 1.5 - 0.5 = 1.0, never
        // negative, and `.bar` snaps 1.0 → 0.
        let (store, _, clips) = try self.store(clipsAt: [1.5])
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: 1.5, anchorCurrentStart: 1.5, rawDragDeltaBeats: -0.5,
            snap: .bar, meterMap: meter())
        #expect(plan.snappedAnchorStart == 0)
        #expect(plan.deltaBeats == -1.5)
        #expect(plan.flooredAtZero == false)   // the floor NEVER engaged

        let result = try store.moveClips(ids: clips.map(\.id), byBeats: plan.deltaBeats)
        // minStart is 1.5 and the delta is exactly -1.5, so the store has
        // nothing to clamp either. The clip legitimately reaches 0 with no
        // reduction anywhere, and the union must stay FALSE.
        #expect(result.clamped == false)
        #expect(start(store, clips[0].id) == 0)
    }

    // 15.
    @Test("at the wall: a drag that moves NOTHING still reports the reduction")
    func wallNoOpStillReportsTheFloor() throws {
        // The cleanest demonstration that the reduction no longer requires a
        // STORE clamp to be visible. The group is already flush against beat 0;
        // a further left shove is refused by the gesture floor before the store
        // is asked for anything at all.
        let (store, _, clips) = try self.store(clipsAt: [0, 4])
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: 0, anchorCurrentStart: 0, rawDragDeltaBeats: -2,
            snap: .off, meterMap: meter())
        #expect(plan.flooredAtZero)
        #expect(plan.deltaBeats == 0)          // nothing left to ask for

        let result = try store.moveClips(ids: clips.map(\.id), byBeats: plan.deltaBeats)
        #expect(result.effectiveDeltaBeats == 0)
        #expect(result.clamped == false)       // the store's zero-delta guard
        #expect(start(store, clips[0].id) == 0)
        #expect(start(store, clips[1].id) == 4)
        // So the ONLY evidence the user was refused travel is the gesture flag.
        // Before round 2 the echo reported `clamped: false` here, i.e. "your
        // drag was applied in full", for a drag that did nothing.
    }
}
