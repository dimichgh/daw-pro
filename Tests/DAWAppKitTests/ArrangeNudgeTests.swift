import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

/// m23-x — the arrow-key NUDGE for arrange clips, tested at two levels.
///
/// PART 1 is the pure step rule (`ArrangeNudge.step`): how far one press moves
/// the selection, for every grid, every modifier, and both directions.
///
/// PART 2 is the COMPOSITION the app actually runs — `ArrangeNudge.step` feeding
/// `ProjectStore.moveClips(ids:byBeats:)` — because the properties this item is
/// gated on live in neither piece alone. `step` never sees a clip, so a
/// step-only test cannot see a weld, a clamp, or an undo entry; `moveClips`
/// never sees a keyboard, so a store-only test of a hardcoded delta passes
/// against a handler that ignores the grid entirely.
///
/// WHAT THESE TESTS CANNOT REACH, stated rather than implied: `DAWApp` has no
/// test target, so `AppModel.handleArrangeNudgeKey` — the four guards, the
/// `effectiveClipSnap` read, the `meterMap.beatsPerBar(atBeat: 0)` read, and the
/// `handled` verdict that decides `.handled` vs `.ignored` — is UNREACHABLE from
/// here. That half is proven by `scripts/gates/m23x-arrow-nudge.mjs` against a
/// real app on staging, in CONTROLLED PAIRS. The `nudge` helper below is a test
/// composition of the same two public pieces the handler routes between; it is
/// deliberately NOT a re-implementation of any rule (it computes no step, no
/// clamp and no position of its own).
///
/// Discriminating tests carry a VALIDITY LEG running the REJECTED design — a
/// nudge that SNAPS each clip to the next gridline instead of translating by a
/// rigid delta — and assert it produces a different, wrong answer on the same
/// fixture (the m23-g2 / m23-d convention: a green test whose fixture cannot
/// tell the two apart is decorative).
@MainActor
@Suite("Arrange arrow-key nudge (m23-x)")
struct ArrangeNudgeTests {

    // MARK: - Fixtures

    /// One instrument track with 2-beat MIDI clips at each of `beats`.
    /// FIXTURE LAW: every start below is chosen so the clips do NOT overlap
    /// before OR after the nudge under test, so no assertion is quietly reading
    /// the overlap resolver's output instead of the nudge's.
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

    private func depth(_ store: ProjectStore) -> Int { store.undoHistory().undo.count }
    private func seq(_ store: ProjectStore) -> Int { store.lastEditEvent?.seq ?? 0 }

    /// The SHIPPED path: ask the ONE step producer, hand the delta to the ONE
    /// position producer. Exactly what `AppModel.handleArrangeNudgeKey` does
    /// once its guards have passed.
    @discardableResult
    private func nudge(_ store: ProjectStore, ids: [UUID],
                       _ direction: ArrangeNudgeDirection,
                       modifiers: TransportKeyModifiers = [],
                       snap: ClipSnap = .bar,
                       beatsPerBar: Int = 4) throws -> ClipsMoveResult? {
        guard let step = ArrangeNudge.step(direction: direction, modifiers: modifiers,
                                           snap: snap, beatsPerBar: beatsPerBar) else {
            return nil
        }
        return try store.moveClips(ids: ids, byBeats: step.deltaBeats)
    }

    /// The REJECTED design, kept ONLY as a validity instrument: snap each clip's
    /// own absolute start to the next gridline in the arrow's direction. This is
    /// what "the nudge snaps to the grid" would mean, and it is the shape the
    /// m23-x filing asked to be decided EXPLICITLY rather than assumed.
    private func snapToGridlineNudge(_ store: ProjectStore, trackID: UUID, clips: [Clip],
                                     _ direction: ArrangeNudgeDirection,
                                     snap: ClipSnap, beatsPerBar: Int = 4) throws {
        let grid = snap.gridBeats(beatsPerBar: beatsPerBar) ?? 1
        for clip in clips {
            let current = start(store, clip.id) ?? clip.startBeat
            let target = direction == .right
                ? (current / grid + 1).rounded(.down) * grid
                : max(0, ((current / grid) - 1).rounded(.up) * grid)
            _ = try store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: target)
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // MARK: - PART 1: the step rule
    // ══════════════════════════════════════════════════════════════════════

    // 1.
    @Test("A bare press steps by the GRID IN FORCE, for every ClipSnap division")
    func bareStepIsTheGrid() throws {
        // FIXTURE LAW — the table is `ClipSnap.gridBeats`'s own contract,
        // written out longhand rather than derived by calling it (a table that
        // called the function under test would agree with any implementation).
        let table: [(ClipSnap, Double)] = [
            (.bar, 4), (.beat, 1), (.half, 0.5),
            (.quarter, 0.25), (.eighth, 0.125), (.sixteenth, 0.0625),
        ]
        for (snap, expected) in table {
            let right = ArrangeNudge.step(direction: .right, modifiers: [],
                                          snap: snap, beatsPerBar: 4)
            #expect(right?.magnitudeBeats == expected, "\(snap.rawValue) magnitude")
            #expect(right?.deltaBeats == expected, "\(snap.rawValue) right delta")
            #expect(right?.source == .grid, "\(snap.rawValue) source")

            let left = ArrangeNudge.step(direction: .left, modifiers: [],
                                         snap: snap, beatsPerBar: 4)
            // The magnitude is ALWAYS positive; only the delta carries the sign.
            #expect(left?.magnitudeBeats == expected, "\(snap.rawValue) left magnitude")
            #expect(left?.deltaBeats == -expected, "\(snap.rawValue) left delta")
        }
    }

    // 2.
    @Test("BAR follows the meter: 4 beats in 4/4, 3 in 3/4, 7 in 7/8")
    func barStepFollowsTheMeter() {
        #expect(ArrangeNudge.step(direction: .right, modifiers: [], snap: .bar,
                                  beatsPerBar: 4)?.magnitudeBeats == 4)
        #expect(ArrangeNudge.step(direction: .right, modifiers: [], snap: .bar,
                                  beatsPerBar: 3)?.magnitudeBeats == 3)
        #expect(ArrangeNudge.step(direction: .right, modifiers: [], snap: .bar,
                                  beatsPerBar: 7)?.magnitudeBeats == 7)
        // ⇧ is a bar too, so it tracks the meter identically.
        #expect(ArrangeNudge.step(direction: .right, modifiers: .shift, snap: .sixteenth,
                                  beatsPerBar: 3)?.magnitudeBeats == 3)
    }

    // 3.
    @Test("SNAP OFF does NOT kill the arrow key — it falls back to one beat")
    func snapOffFallsBackToOneBeat() {
        // The failure this pins: an implementation that returned `nil` (or 0)
        // for `.off` would make ← / → silently dead exactly when the user has
        // opted out of the grid, which is indistinguishable from a broken key.
        #expect(ClipSnap.off.gridBeats(beatsPerBar: 4) == nil)   // the nil this covers
        let step = ArrangeNudge.step(direction: .right, modifiers: [], snap: .off,
                                     beatsPerBar: 4)
        #expect(step?.magnitudeBeats == 1)
        #expect(step?.deltaBeats == 1)
        #expect(step?.source == .gridOffFallback)
        #expect(ArrangeNudge.step(direction: .left, modifiers: [], snap: .off,
                                  beatsPerBar: 7)?.deltaBeats == -1)
    }

    // 4.
    @Test("⌥ is the FINE step — 1/32 beat, whatever the grid says")
    func optionIsTheFineStep() {
        for snap in ClipSnap.allCases {
            let step = ArrangeNudge.step(direction: .right, modifiers: .option,
                                         snap: snap, beatsPerBar: 4)
            #expect(step?.magnitudeBeats == 1.0 / 32.0, "under \(snap.rawValue)")
            #expect(step?.source == .fine, "under \(snap.rawValue)")
        }
        #expect(ArrangeNudge.fineBeats == 0.03125)
        // FINER THAN THE FINEST GRID — the reason ⌥ exists. The picker bottoms
        // out at 1/16 beat, so a ⌥ nudge reaches a position no grid can express.
        #expect(ArrangeNudge.fineBeats < ClipSnap.sixteenth.gridBeats(beatsPerBar: 4)!)
        // DECLARED, NOT SHARED (see `ArrangeNudge.fineBeats`): the same number as
        // the store's trim floor today, deliberately not sourced from it. If this
        // ever fails, ONE of the two moved and they were never meant to be tied.
        #expect(ArrangeNudge.fineBeats == ProjectStore.minClipLengthBeats)
    }

    // 5.
    @Test("⇧ is the COARSE step — one bar, whatever the grid says")
    func shiftIsTheCoarseStep() {
        for snap in ClipSnap.allCases {
            let step = ArrangeNudge.step(direction: .left, modifiers: .shift,
                                         snap: snap, beatsPerBar: 4)
            #expect(step?.magnitudeBeats == 4, "under \(snap.rawValue)")
            #expect(step?.deltaBeats == -4, "under \(snap.rawValue)")
            #expect(step?.source == .bar, "under \(snap.rawValue)")
        }
    }

    // 6.
    @Test("⌥ BEATS ⇧ when both are held — the smaller move is the recoverable one")
    func optionWinsOverShift() {
        let both = ArrangeNudge.step(direction: .right, modifiers: [.option, .shift],
                                     snap: .bar, beatsPerBar: 4)
        #expect(both?.magnitudeBeats == ArrangeNudge.fineBeats)
        #expect(both?.source == .fine)
        // Not vacuous: the two chords disagree, so this leg is choosing between
        // two live answers rather than restating one.
        #expect(ArrangeNudge.step(direction: .right, modifiers: .shift, snap: .bar,
                                  beatsPerBar: 4)?.magnitudeBeats == 4)
    }

    // 7.
    @Test("⌘ and ⌃ chords PASS THROUGH — they belong to the system, not to us")
    func commandAndControlPassThrough() {
        for mods: TransportKeyModifiers in [.command, .control,
                                            [.command, .option], [.control, .shift],
                                            [.command, .shift], [.command, .control]] {
            for direction in ArrangeNudgeDirection.allCases {
                #expect(ArrangeNudge.step(direction: direction, modifiers: mods,
                                          snap: .bar, beatsPerBar: 4) == nil,
                        "\(direction.rawValue) under \(mods.rawValue)")
            }
        }
        // The controlled half: strip ⌘/⌃ and the SAME call answers, so the legs
        // above measure the chord refusal and not something broken upstream.
        #expect(ArrangeNudge.step(direction: .right, modifiers: [.option, .shift],
                                  snap: .bar, beatsPerBar: 4) != nil)
    }

    // 8.
    @Test("Direction is the ONLY source of sign, and the two are exact opposites")
    func directionIsTheOnlySignSource() {
        #expect(ArrangeNudgeDirection.left.sign == -1)
        #expect(ArrangeNudgeDirection.right.sign == 1)
        for snap in ClipSnap.allCases {
            let l = ArrangeNudge.step(direction: .left, modifiers: [], snap: snap,
                                      beatsPerBar: 5)!
            let r = ArrangeNudge.step(direction: .right, modifiers: [], snap: snap,
                                      beatsPerBar: 5)!
            #expect(l.deltaBeats == -r.deltaBeats, "under \(snap.rawValue)")
            #expect(l.magnitudeBeats == r.magnitudeBeats, "under \(snap.rawValue)")
            #expect(l.source == r.source, "under \(snap.rawValue)")
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // MARK: - PART 2: the composition (step → moveClips)
    // ══════════════════════════════════════════════════════════════════════

    // 9.
    @Test("HEADLINE: an OFF-GRID clip TRANSLATES, it does not snap to a gridline")
    func offGridClipTranslatesRigidly() throws {
        // Clips at 0 (ON the bar grid) and 2.5 (deliberately OFF it) — the only
        // fixture shape that can see the difference. Under `.bar`, one press right.
        let (store, _, clips) = try self.store(clipsAt: [0, 2.5])
        let result = try nudge(store, ids: clips.map(\.id), .right, snap: .bar)

        #expect(result?.effectiveDeltaBeats == 4)
        #expect(start(store, clips[0].id) == 4)
        #expect(start(store, clips[1].id) == 6.5)     // 2.5 + 4, still off-grid
        #expect(start(store, clips[1].id)! - start(store, clips[0].id)! == 2.5)
    }

    // 10.
    @Test("VALIDITY LEG: snap-to-gridline WELDS that pair onto beat 4 and shreds both clips")
    func snapToGridlineNudgeIsRejectedForCause() throws {
        let (store, trackID, clips) = try self.store(clipsAt: [0, 2.5])

        // THE WELD ITSELF, stated before the run: "the next gridline to the
        // right" of 0 is 4, and "the next gridline to the right" of 2.5 is ALSO
        // 4. Two clips at different sub-grid phases are sent to ONE beat — the
        // exact defect m23-g2 was spent making unreachable, re-introduced by the
        // keyboard if the nudge snapped instead of translating.
        let grid = ClipSnap.bar.gridBeats(beatsPerBar: 4)!
        #expect((0.0 / grid + 1).rounded(.down) * grid == 4)
        #expect((2.5 / grid + 1).rounded(.down) * grid == 4)

        try snapToGridlineNudge(store, trackID: trackID, clips: clips, .right, snap: .bar)

        // AND WHAT THE WELD COSTS once the no-silent-overlap policy resolves two
        // clips sent to one beat, derived step by step:
        //   C0 moves first, 0 → [4,6), which overlaps C2.5's [2.5,4.5) — so
        //   C2.5 is trimmed to [2.5,4), length 1.5.
        //   C2.5 then moves to [4,5.5), which overlaps C0's [4,6) — so C0's HEAD
        //   is cut and it becomes [5.5,6), length 0.5.
        let c0 = store.tracks.flatMap(\.clips).first { $0.id == clips[0].id }!
        let c1 = store.tracks.flatMap(\.clips).first { $0.id == clips[1].id }!
        #expect(c0.startBeat == 5.5)
        #expect(c0.lengthBeats == 0.5)      // 75% of the clip is gone
        #expect(c1.startBeat == 4)
        #expect(c1.lengthBeats == 1.5)
        // The 2.5-beat gap the user arranged is now −1.5: the clips have swapped
        // order. Test 9 therefore DISCRIMINATES — same fixture, and the shipped
        // rule leaves both clips 2 beats long at 4 and 6.5.
        #expect(c1.startBeat - c0.startBeat == -1.5)
    }

    // 11.
    @Test("VALIDITY LEG: snap-to-gridline is also NON-UNIFORM under key repeat")
    func snapToGridlineNudgeStuttersUnderRepeat() throws {
        // The second, independent reason the delta design won. An off-grid clip's
        // FIRST press under snap-to-gridline travels a different distance from
        // every press after it — a stutter the user feels when holding the key.
        let (store, trackID, clips) = try self.store(clipsAt: [2.5])
        try snapToGridlineNudge(store, trackID: trackID, clips: clips, .right, snap: .bar)
        #expect(start(store, clips[0].id) == 4)        // travelled 1.5
        try snapToGridlineNudge(store, trackID: trackID, clips: clips, .right, snap: .bar)
        #expect(start(store, clips[0].id) == 8)        // travelled 4

        // The SHIPPED rule travels the same distance every time, from the same start.
        let (store2, _, clips2) = try self.store(clipsAt: [2.5])
        try nudge(store2, ids: [clips2[0].id], .right, snap: .bar)
        #expect(start(store2, clips2[0].id) == 6.5)    // travelled 4
        try nudge(store2, ids: [clips2[0].id], .right, snap: .bar)
        #expect(start(store2, clips2[0].id) == 10.5)   // travelled 4
    }

    // 12.
    @Test("A 3-CLIP nudge is ONE edit.history step, and every offset survives")
    func threeClipNudgeIsOneStep() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 4, 9.5])
        let ids = clips.map(\.id)
        let d0 = depth(store), s0 = seq(store)

        let result = try nudge(store, ids: ids, .right, snap: .bar)

        #expect(depth(store) == d0 + 1)
        #expect(seq(store) == s0 + 1)
        #expect(result?.effectiveDeltaBeats == 4)
        #expect(start(store, ids[0]) == 4)
        #expect(start(store, ids[1]) == 8)
        #expect(start(store, ids[2]) == 13.5)
        // Offsets, restated as the gaps the user arranged: 4 and 5.5.
        #expect(start(store, ids[1])! - start(store, ids[0])! == 4)
        #expect(start(store, ids[2])! - start(store, ids[1])! == 5.5)
        // ONE label, and it is the countable group one — a loop of three
        // single moves would read "Move Clip 'C0'" three times.
        #expect(store.undoHistory().undo.first == "Move 3 Clips")
    }

    // 13.
    @Test("KEY REPEAT: 5 presses inside the 800 ms window are ONE undo entry, and seq PROVES all five landed")
    func repeatedNudgesCoalesceToOneEntry() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 4])
        let ids = clips.map(\.id)
        // INJECTED CLOCK, never the wall clock: `UndoJournal.coalescingWindow` is
        // 800 ms and `lastMergedAt` is refreshed on every merge, so a test that
        // depended on real elapsed time would be a flake source whether or not it
        // passed today.
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        clock = clock.advanced(by: .seconds(5))     // clear of the fixture's edits
        let d0 = depth(store), s0 = seq(store)

        for _ in 0..<5 {
            try nudge(store, ids: ids, .right, snap: .bar)
            clock = clock.advanced(by: .milliseconds(100))   // 5 presses over 500 ms
        }

        // THE VACUITY TRAP, closed with three independent instruments. Depth
        // alone cannot tell "five presses folded into one entry" from "one press
        // landed and four were silently dropped" — both give depth + 1.
        #expect(depth(store) == d0 + 1, "five presses, ONE undo entry")
        // `performEdit` ticks `editEventSeq` for COALESCED edits too, so this is
        // the count of presses that actually reached the store.
        #expect(seq(store) == s0 + 5, "all five presses actually landed")
        // And the geometry: five bars of travel, offsets intact.
        #expect(start(store, ids[0]) == 20)
        #expect(start(store, ids[1]) == 24)

        // ONE undo restores everything the burst did — the point of coalescing.
        _ = try store.undo()
        #expect(start(store, ids[0]) == 0)
        #expect(start(store, ids[1]) == 4)
    }

    // 14.
    @Test("A press OUTSIDE the window starts a SECOND entry (the window is real)")
    func nudgesOutsideTheWindowDoNotCoalesce() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 4])
        let ids = clips.map(\.id)
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        clock = clock.advanced(by: .seconds(5))
        let d0 = depth(store), s0 = seq(store)

        try nudge(store, ids: ids, .right, snap: .bar)
        clock = clock.advanced(by: .milliseconds(900))       // > the 800 ms window
        try nudge(store, ids: ids, .right, snap: .bar)

        #expect(depth(store) == d0 + 2, "two entries, not one")
        #expect(seq(store) == s0 + 2)
        #expect(start(store, ids[0]) == 8)
        // Two entries means two undos — the second gives back only ONE press.
        _ = try store.undo()
        #expect(start(store, ids[0]) == 4)
    }

    // 15.
    @Test("A press after UNDO starts a FRESH entry — the coalescing barrier holds")
    func nudgeAfterUndoDoesNotFoldOntoTheRestoredTop() throws {
        // WHY THIS FIXTURE IS CONVOLUTED, and why the obvious version is vacuous:
        // "nudge, undo, nudge, expect depth 1" proves nothing, because the undo
        // leaves the stack EMPTY and any fresh edit gives depth 1 regardless of
        // the barrier. The barrier is only observable when the entry the undo
        // UNCOVERS has the same key and is still inside the window — i.e. when a
        // fold is otherwise exactly what would happen.
        let (store, _, clips) = try self.store(clipsAt: [0, 4])
        let both = clips.map(\.id), one = [clips[0].id]
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        clock = clock.advanced(by: .seconds(5))
        let d0 = depth(store)

        try nudge(store, ids: both, .right, snap: .bar)       // E1, key = both
        clock = clock.advanced(by: .milliseconds(100))
        try nudge(store, ids: one, .right, snap: .bar)        // E2, key = one clip
        #expect(depth(store) == d0 + 2, "different selections do not fold")

        _ = try store.undo()                                          // pops E2, uncovers E1
        #expect(depth(store) == d0 + 1)
        clock = clock.advanced(by: .milliseconds(100))        // E1 is 200 ms old: INSIDE

        try nudge(store, ids: both, .right, snap: .bar)       // same key as E1
        #expect(depth(store) == d0 + 2,
                "the barrier forced a fresh entry; without it this folds into E1")
    }

    // 16.
    @Test("PARTIAL beat-0 clamp: the group stops at the wall TOGETHER, offsets intact")
    func partialClampPreservesRelativeOffsets() throws {
        // FIXTURE ARITHMETIC, computed before the assertions: leftmost at 2, a
        // 4-beat step left. `moveClips` clamps the WHOLE GROUP to
        // max(-4, -2) = -2, so every clip moves -2 and the leftmost lands on
        // exactly 0. A PER-CLIP `max(0, ...)` would pin the leftmost at 0 while
        // the others travelled the full -4, silently shrinking both gaps.
        let (store, _, clips) = try self.store(clipsAt: [2, 6, 9.5])
        let ids = clips.map(\.id)
        let d0 = depth(store), s0 = seq(store)

        let result = try nudge(store, ids: ids, .left, snap: .bar)

        #expect(result?.requestedDeltaBeats == -4)
        #expect(result?.effectiveDeltaBeats == -2)
        #expect(result?.clamped == true)
        #expect(start(store, ids[0]) == 0)
        #expect(start(store, ids[1]) == 4)
        #expect(start(store, ids[2]) == 7.5)
        // The gaps the user arranged — 4 and 3.5 — survive the wall.
        #expect(start(store, ids[1])! - start(store, ids[0])! == 4)
        #expect(start(store, ids[2])! - start(store, ids[1])! == 3.5)
        // A clamped-but-non-zero nudge is still ONE real edit.
        #expect(depth(store) == d0 + 1)
        #expect(seq(store) == s0 + 1)
    }

    // 17.
    @Test("FULL clamp at the wall journals NOTHING — and the next press still moves")
    func fullClampIsInertThenReleases() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 4])
        let ids = clips.map(\.id)
        let d0 = depth(store), s0 = seq(store)

        let blocked = try nudge(store, ids: ids, .left, snap: .bar)

        #expect(blocked?.requestedDeltaBeats == -4)
        #expect(blocked?.effectiveDeltaBeats == 0)
        #expect(blocked?.clamped == true)
        // `moveClips` returns BEFORE `performEdit` on a zero effective delta, so
        // a fully-clamped press adds no undo entry AND no seq tick. Both are
        // asserted because both are the instruments every other leg here reads —
        // a leg that did not know this would misread a wall as a dead handler.
        #expect(depth(store) == d0, "no undo entry for a press that moved nothing")
        #expect(seq(store) == s0, "and no edit event either")
        #expect(start(store, ids[0]) == 0)

        // THE CONTROLLED HALF (the K2b/K2e idiom): the SAME composition then
        // moves, so the assertions above measured the wall and not a corpse.
        try nudge(store, ids: ids, .right, snap: .bar)
        #expect(start(store, ids[0]) == 4)
        #expect(start(store, ids[1]) == 8)
        #expect(depth(store) == d0 + 1)
        #expect(seq(store) == s0 + 1)
    }

    // 18.
    @Test("⌥ reaches BETWEEN the finest gridlines — a position no snap can express")
    func fineNudgeReachesOffGridPositions() throws {
        let (store, _, clips) = try self.store(clipsAt: [0])
        try nudge(store, ids: [clips[0].id], .right, modifiers: .option, snap: .sixteenth)

        #expect(start(store, clips[0].id) == 0.03125)
        // The point of the fine step: 1/32 beat lies EXACTLY midway between two
        // 1/16 gridlines, so the finest grid the picker offers cannot express
        // this position at all — it rounds away (up, since Swift's `.rounded()`
        // breaks the .5 tie away from zero; the direction is incidental, the
        // inability to represent it is the point).
        #expect(ClipSnap.sixteenth.snap(beat: 0.03125, beatsPerBar: 4) != 0.03125)
        #expect(ClipSnap.sixteenth.snap(beat: 0.03125, beatsPerBar: 4) == 0.0625)

        // And a fine press back is exact — the delta is symmetric, so ⌥→ ⌥← is
        // a round trip and not a slow drift.
        try nudge(store, ids: [clips[0].id], .left, modifiers: .option, snap: .sixteenth)
        #expect(start(store, clips[0].id) == 0)
    }

    // 19.
    @Test("With snapping OFF a nudge moves exactly one beat and stays off-grid")
    func snapOffNudgeKeepsThePhase() throws {
        let (store, _, clips) = try self.store(clipsAt: [2.5])
        try nudge(store, ids: [clips[0].id], .right, snap: .off)
        #expect(start(store, clips[0].id) == 3.5)
        try nudge(store, ids: [clips[0].id], .left, snap: .off)
        #expect(start(store, clips[0].id) == 2.5)
    }

    // 20.
    @Test("A mixed-track selection keeps its CROSS-TRACK offsets (one delta, all clips)")
    func mixedTrackSelectionKeepsOffsets() throws {
        let store = ProjectStore()
        let a = store.addTrack(kind: .instrument)
        let b = store.addTrack(kind: .instrument)
        let ca = try store.addMIDIClip(toTrack: a.id, name: "A", atBeat: 1.5,
                                       lengthBeats: 2, notes: [])
        let cb = try store.addMIDIClip(toTrack: b.id, name: "B", atBeat: 6,
                                       lengthBeats: 2, notes: [])
        let d0 = depth(store)

        try nudge(store, ids: [ca.id, cb.id], .right, snap: .beat)

        #expect(start(store, ca.id) == 2.5)
        #expect(start(store, cb.id) == 7)
        #expect(start(store, cb.id)! - start(store, ca.id)! == 4.5)
        #expect(depth(store) == d0 + 1, "still ONE edit across two tracks")
    }

    // 21.
    @Test("A ⌘/⌃ chord never reaches the store — nothing moves, nothing is journaled")
    func refusedChordIsAFullNoOp() throws {
        let (store, _, clips) = try self.store(clipsAt: [0, 4])
        let ids = clips.map(\.id)
        let d0 = depth(store), s0 = seq(store)

        let refused = try nudge(store, ids: ids, .right, modifiers: .command, snap: .bar)

        #expect(refused == nil)
        #expect(depth(store) == d0)
        #expect(seq(store) == s0)
        #expect(start(store, ids[0]) == 0)
        // Controlled half: drop the ⌘ and the same call moves the clips.
        try nudge(store, ids: ids, .right, snap: .bar)
        #expect(start(store, ids[0]) == 4)
    }
}
