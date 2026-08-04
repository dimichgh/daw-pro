import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

// m23-y: what a click on a TRACK HEADER does to the arrange selection.
//
// The whole rule lives in `ArrangeTrackSelection` precisely so it can be pinned
// here — `DAWApp` has no test target, so anything decided inside the SwiftUI
// `body` or the `AppModel` handler would be invisible to `Tests/`.

@Suite("ArrangeTrackSelection")
struct ArrangeTrackSelectionTests {

    // MARK: Fixtures

    private func clip(_ id: UUID, at beat: Double = 0, midi: Bool = false) -> Clip {
        Clip(id: id, name: "c", startBeat: beat, lengthBeats: 2,
             notes: midi ? [] : nil)
    }

    private func track(_ clipIDs: [UUID], name: String = "T") -> Track {
        Track(name: name, kind: .instrument,
              clips: clipIDs.enumerated().map { clip($0.element, at: Double($0.offset) * 4) })
    }

    /// INV1/INV2 on `ArrangeSelection`, re-checked after every mutation this
    /// suite performs — the header path reaches the selection through the same
    /// invariants the clip path does, and a set mutator is exactly where they
    /// would break.
    private func expectInvariants(_ s: ArrangeSelection, _ where_: String = #function) {
        if let focus = s.focusID {
            #expect(s.contains(focus), "INV1 violated in \(where_)")
        }
        if s.isEmpty {
            #expect(s.focusID == nil, "INV2 violated in \(where_)")
        }
    }

    // MARK: clipIDs(on:)

    // 1.
    @Test("clipIDs is exactly the track's own clips — not the project's")
    func clipIDsIsPerTrack() {
        let a = UUID(), b = UUID(), c = UUID()
        let t1 = track([a, b])
        let t2 = track([c])
        #expect(ArrangeTrackSelection.clipIDs(on: t1) == [a, b])
        #expect(ArrangeTrackSelection.clipIDs(on: t2) == [c])
        // The discriminating half: t1's answer must not contain t2's clip. A
        // rule that returned every clip in the project passes the first two
        // assertions on a one-track fixture and fails only this one.
        #expect(!ArrangeTrackSelection.clipIDs(on: t1).contains(c))
    }

    // 2.
    @Test("a track with no clips answers the empty set, not nil")
    func clipIDsEmptyTrack() {
        #expect(ArrangeTrackSelection.clipIDs(on: track([])).isEmpty)
    }

    // 3. Structural, and the reason there is no take-lane predicate to get wrong:
    //    an un-flattened take lives on `TakeGroup.lanes[].clip` and is NEVER a
    //    member of `track.clips`, so it cannot reach a header click at all.
    @Test("take-LANE clips are structurally excluded (they are not in track.clips)")
    func takeLaneClipsExcluded() {
        let visible = UUID()
        let hidden = UUID()
        let groupID = UUID()
        let laneClip = clip(hidden, at: 0)
        let group = TakeGroup(id: groupID, name: "G",
                              lanes: [TakeLane(name: "Take 1", clip: laneClip)],
                              comp: [], crossfadeSeconds: 0)
        var t = Track(name: "T", kind: .audio, clips: [clip(visible)])
        t.takeGroups = [group]

        let ids = ArrangeTrackSelection.clipIDs(on: t)
        #expect(ids == [visible])
        #expect(!ids.contains(hidden), "a take LANE clip must never be selectable from the header")
    }

    // MARK: Plain click — replace

    // 4. THE ROADMAP'S FIRST LEG: selecting a track selects its clips.
    @Test("a plain header click selects exactly that track's clips")
    func plainClickSelectsTheTrack() {
        let a = UUID(), b = UUID(), other = UUID()
        var s = ArrangeSelection()
        s.selectOnly(other)

        let out = ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .none, to: &s)
        #expect(s.ids == [a, b])
        #expect(!s.contains(other), "a plain click REPLACES — a foreign clip must not survive")
        #expect(out.intent == .replace)
        #expect(out.effect == .replace)
        #expect(out.clipIDs == [a, b])
        expectInvariants(s)
    }

    // 5. THE FOCUS DECISION, half one: a header click NEVER ADOPTS a focus.
    //    Plain-clicking the header of a track with one MIDI clip must NOT open
    //    the piano roll on it. `replace(with:)`'s rule — selecting is not opening.
    @Test("a plain header click adopts NO focus, even on a single-clip track")
    func plainClickNeverAdoptsFocus() {
        let only = UUID()
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: track([only]), modifiers: .none, to: &s)
        #expect(s.ids == [only])
        #expect(s.focusID == nil, "a header has no anchor clip — it must not open the note editor")
        expectInvariants(s)
    }

    // 6. THE FOCUS DECISION, half two: a SURVIVING focus is kept. This is what
    //    leaves the piano roll open when you click the header of the track it is
    //    already open on, and it is what discriminates `replace(with:)` from a
    //    loop of `toggle`s (which would adopt, or drop, depending on order).
    @Test("a plain header click KEEPS a focus that survives into the new set")
    func plainClickKeepsSurvivingFocus() {
        let a = UUID(), b = UUID()
        var s = ArrangeSelection()
        s.selectOnly(a)                                  // focus = a
        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .none, to: &s)
        #expect(s.ids == [a, b])
        #expect(s.focusID == a, "the focus is a member of the new set — it survives")
        expectInvariants(s)
    }

    // 7. And a focus that does NOT survive is dropped, not carried as a dangling
    //    id (INV1).
    @Test("a plain header click drops a focus the new set does not contain")
    func plainClickDropsVanishedFocus() {
        let foreign = UUID(), a = UUID()
        var s = ArrangeSelection()
        s.selectOnly(foreign)
        ArrangeTrackSelection.apply(click: track([a]), modifiers: .none, to: &s)
        #expect(s.ids == [a])
        #expect(s.focusID == nil)
        expectInvariants(s)
    }

    // 8. THE ROADMAP'S "zero-clip track selects cleanly" leg, at the unit layer:
    //    a plain click on an empty track CLEARS. It is not guarded, deliberately.
    @Test("a plain click on a zero-clip track clears the selection and the focus")
    func plainClickEmptyTrackClears() {
        let a = UUID()
        var s = ArrangeSelection()
        s.selectOnly(a)
        let out = ArrangeTrackSelection.apply(click: track([]), modifiers: .none, to: &s)
        #expect(s.isEmpty)
        #expect(s.focusID == nil, "the note editor must CLOSE (INV2)")
        #expect(out.effect == .replace)
        #expect(out.clipIDs.isEmpty)
        expectInvariants(s)
    }

    // MARK: Chord click — the all-or-none set toggle

    // 9. THE ROADMAP'S SECOND LEG: shift-clicking a second header ADDS without
    //    dropping the first's clips. Asserted as the exact UNION.
    @Test("⇧ on a second header adds its clips — the exact union, nothing dropped")
    func shiftClickAddsUnion() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .none, to: &s)
        let out = ArrangeTrackSelection.apply(click: track([c, d]), modifiers: .shift, to: &s)
        #expect(s.ids == [a, b, c, d])
        #expect(out.intent == .toggle)
        #expect(out.effect == .add)
        expectInvariants(s)
    }

    // 10. ⌘ is the same chord as ⇧ here, because it is the SAME table
    //     (`ArrangeClickIntent.intent(for:)`) the clip click and the marquee use.
    @Test("⌘ behaves exactly as ⇧ — one shared chord table, not a second one")
    func commandMatchesShift() {
        let a = UUID(), b = UUID()
        var viaShift = ArrangeSelection(), viaCommand = ArrangeSelection()
        viaShift.selectOnly(a)
        viaCommand.selectOnly(a)
        let s1 = ArrangeTrackSelection.apply(click: track([b]), modifiers: .shift, to: &viaShift)
        let s2 = ArrangeTrackSelection.apply(click: track([b]), modifiers: .command, to: &viaCommand)
        #expect(viaShift == viaCommand)
        #expect(s1 == s2)
        #expect(s1.effect == .add)
    }

    // 11. THE CHORD DECISION, and the only test that discriminates it from
    //     `formUnion`: ⇧ on a FULLY-selected header removes exactly that track's
    //     clips and leaves the other track's standing. Under a `formUnion`
    //     resolution this selection would be unchanged (still 4 ids).
    @Test("⇧ on a FULLY-selected header removes exactly that track's clips")
    func shiftClickTogglesOffWhenAllSelected() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let t1 = track([a, b]), t2 = track([c, d])
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: t1, modifiers: .none, to: &s)
        ArrangeTrackSelection.apply(click: t2, modifiers: .shift, to: &s)
        #expect(s.ids == [a, b, c, d])

        let out = ArrangeTrackSelection.apply(click: t1, modifiers: .shift, to: &s)
        #expect(s.ids == [c, d], "exactly t1's clips leave; t2's stand")
        #expect(out.effect == .remove)
        expectInvariants(s)
    }

    // 12. ALL-OR-NONE, the partially-selected case: one clip of the track is
    //     selected, so the chord ADDS the rest rather than inventing a tiebreak.
    @Test("⇧ on a PARTIALLY-selected header adds the rest (all-or-none, no tiebreak)")
    func shiftClickPartialAdds() {
        let a = UUID(), b = UUID(), c = UUID()
        var s = ArrangeSelection()
        s.selectOnly(b)                                   // one of the three
        let out = ArrangeTrackSelection.apply(click: track([a, b, c]),
                                              modifiers: .shift, to: &s)
        #expect(s.ids == [a, b, c])
        #expect(out.effect == .add)
        expectInvariants(s)
    }

    // 13. The round trip: add then remove returns EXACTLY the prior selection,
    //     which is the property a true toggle has and `formUnion` does not.
    @Test("⇧ twice on the same header is a round trip back to the prior selection")
    func shiftClickRoundTrips() {
        let a = UUID(), x = UUID(), y = UUID()
        var s = ArrangeSelection()
        s.selectOnly(a)
        let before = s
        ArrangeTrackSelection.apply(click: track([x, y]), modifiers: .shift, to: &s)
        #expect(s.ids == [a, x, y])
        ArrangeTrackSelection.apply(click: track([x, y]), modifiers: .shift, to: &s)
        #expect(s == before, "a discrete toggle must be its own inverse")
        expectInvariants(s)
    }

    // 14. THE EMPTY-TRACK CHORD, guarded explicitly BEFORE the subset test —
    //     `Set().isSubset(of:)` is vacuously true, so without the guard this
    //     would report `.remove` on a track that has nothing to remove.
    @Test("⇧ on a zero-clip track reports .noClips and changes nothing")
    func shiftClickEmptyTrackIsNoClips() {
        let a = UUID()
        var s = ArrangeSelection()
        s.selectOnly(a)
        let before = s
        let out = ArrangeTrackSelection.apply(click: track([]), modifiers: .shift, to: &s)
        #expect(s == before, "nothing to add, nothing to remove")
        #expect(out.effect == .noClips, "NOT .remove — the vacuous subset must not decide this")
        #expect(out.clipIDs.isEmpty)
        expectInvariants(s)
    }

    // 15. And the empty chord case on an EMPTY selection — both sides empty, the
    //     degenerate corner where a vacuous subset is most tempting.
    @Test("⇧ on a zero-clip track with nothing selected is still .noClips")
    func shiftClickEmptyTrackEmptySelection() {
        var s = ArrangeSelection()
        let out = ArrangeTrackSelection.apply(click: track([]), modifiers: .shift, to: &s)
        #expect(s.isEmpty)
        #expect(out.effect == .noClips)
    }

    // MARK: Focus under the chord path

    // 16. Removing a track whose clips include the FOCUS drops the focus and
    //     leaves the rest selected — `subtract`'s rule, i.e. `toggle`'s rule.
    @Test("toggling OFF a track that holds the focus closes the editor, keeps the rest")
    func toggleOffDropsFocusKeepsRest() {
        let a = UUID(), b = UUID(), c = UUID()
        var s = ArrangeSelection()
        s.selectOnly(a)                                   // focus = a, on t1
        s.toggle(c)                                       // c on t2
        #expect(s.focusID == a)

        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .shift, to: &s)
        // a,b were NOT both selected (b was not), so this ADDS b…
        #expect(s.ids == [a, b, c])
        #expect(s.focusID == a, "adding never steals or drops a focus")

        // …and now they ARE both selected, so a second chord removes them.
        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .shift, to: &s)
        #expect(s.ids == [c])
        #expect(s.focusID == nil, "the focused clip left — the editor closes, c stays selected")
        expectInvariants(s)
    }

    // 17. Removing a track that does NOT hold the focus leaves it untouched.
    @Test("toggling OFF a track that does not hold the focus leaves the focus alone")
    func toggleOffKeepsUnrelatedFocus() {
        let focus = UUID(), x = UUID(), y = UUID()
        var s = ArrangeSelection()
        s.selectOnly(focus)
        ArrangeTrackSelection.apply(click: track([x, y]), modifiers: .command, to: &s)
        #expect(s.ids == [focus, x, y])
        ArrangeTrackSelection.apply(click: track([x, y]), modifiers: .command, to: &s)
        #expect(s.ids == [focus])
        #expect(s.focusID == focus)
        expectInvariants(s)
    }

    // MARK: Composition with the clip path (the semantics' whole point)

    // 18. A mixed track+clip selection is JUST A BIGGER `ids` SET — nothing
    //     remembers a track was involved, so the clip mutators keep working
    //     unchanged over it. This is the property the roadmap's chosen reading
    //     buys, and it is worth pinning rather than assuming.
    @Test("a mixed track+clip selection is an ordinary id set the clip path still owns")
    func mixedSelectionComposes() {
        let a = UUID(), b = UUID(), loose = UUID()
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .none, to: &s)
        s.toggle(loose)                                   // an ordinary clip click
        #expect(s.ids == [a, b, loose])
        #expect(s.focusID == loose, "the CLIP path still adopts when there is no focus")

        // And a clip click can take one of the track's clips back out again.
        s.toggle(a)
        #expect(s.ids == [b, loose])
        expectInvariants(s)
    }

    // 19. Every effect's raw value is a stable wire string — the debug seam echoes
    //     these verbatim, so a rename here silently breaks a gate's assertion.
    @Test("effect raw values are the stable strings the seam echoes")
    func effectRawValues() {
        #expect(ArrangeTrackClickEffect.replace.rawValue == "replace")
        #expect(ArrangeTrackClickEffect.add.rawValue == "add")
        #expect(ArrangeTrackClickEffect.remove.rawValue == "remove")
        #expect(ArrangeTrackClickEffect.noClips.rawValue == "no-clips")
    }
}

// m23-y, the TAKE-COMP consequence a track header click makes newly reachable.
//
// WHY THIS IS HERE AND NOT IN THE STAGING GATE: the fixture is UNBUILDABLE FROM
// THE WIRE. `take.group` needs ≥2 OVERLAPPING clips on a track and every clip
// verb resolves overlaps on the way in — MEASURED at this cycle, not inherited:
// the m23-y gate asked for MIDI clips at beats 0 and 1 with length 4 and
// `take.group` answered "clips do not overlap — grouping needs overlapping
// takes". (m23-x recorded the same law from the other direction.) So the gate
// carries this as an honest skip and the FACT is measured here, against the
// store directly, the way `RemoveClipsTests` builds its comp member.
//
// WHAT IS NEW HERE, versus `RemoveClipsTests.compMemberRefusesWhole`: that test
// proves the refusal on ONE track, which is the store's own contract. This
// measures the SHAPE A HEADER CLICK PRODUCES — the comp member arrives inside a
// whole track's id set, mixed with ordinary clips on a DIFFERENT track — and it
// pins the SURVIVOR SET, which is a separate fact from m23-w's unknown-id
// all-or-nothing (a different throw path).
@MainActor
@Suite("ArrangeTrackSelection — take-comp interaction")
struct ArrangeTrackSelectionTakeCompTests {
    private func liveIDs(_ store: ProjectStore) -> Set<UUID> {
        Set(store.tracks.flatMap { $0.clips.map(\.id) })
    }

    // 20. THE MEASUREMENT. A track holding one comp member + two ordinary clips,
    //     plus two ordinary clips on a SECOND track. Select both tracks the way
    //     two header clicks would, then group-delete.
    //
    //     MEASURED RESULT: the WHOLE batch is refused. `ProjectStore.removeClips`
    //     locates and validates EVERY id past `requireNotCompMember` before it
    //     mutates anything, so ONE comp member anywhere in the union spares
    //     EVERY clip — including the ordinary ones on the other track, which the
    //     user never went near a take group to select.
    @Test("a comp member anywhere in a track-header union refuses the WHOLE delete")
    func compMemberInHeaderUnionRefusesEverything() throws {
        let store = ProjectStore()
        let takeTrack = store.addTrack(name: "Takes", kind: .instrument)
        let ordinary = store.addTrack(name: "Ordinary", kind: .instrument)
        let free1 = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 0, lengthBeats: 2)
        let member = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 4, lengthBeats: 2)
        let free2 = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 8, lengthBeats: 2)
        let o1 = try store.addMIDIClip(toTrack: ordinary.id, atBeat: 0, lengthBeats: 2)
        let o2 = try store.addMIDIClip(toTrack: ordinary.id, atBeat: 4, lengthBeats: 2)

        // Mark one clip a comp member exactly as `RemoveClipsTests` does — the
        // only way to reach this state without a recording session.
        let index = store.tracks[0].clips.firstIndex { $0.id == member.id }!
        store.tracks[0].clips[index].takeGroupID = UUID()

        // Two header clicks: plain on the take track, ⇧ on the ordinary one.
        var selection = ArrangeSelection()
        ArrangeTrackSelection.apply(click: store.tracks[0], modifiers: .none, to: &selection)
        ArrangeTrackSelection.apply(click: store.tracks[1], modifiers: .shift, to: &selection)
        #expect(selection.ids == [free1.id, member.id, free2.id, o1.id, o2.id])

        let before = liveIDs(store)
        let depthBefore = store.undoHistory().undo.count
        #expect(throws: ProjectError.self) {
            try store.removeClips(ids: Array(selection.ids))
        }

        // THE SURVIVOR SET, which is the fact worth having: EVERYTHING survives.
        #expect(liveIDs(store) == before, "all-or-nothing — not one clip left")
        // The surprising half — a user would report this as a bug: the ordinary
        // clips on the OTHER track are spared too.
        #expect(store.tracks[1].clips.count == 2)
        #expect(store.undoHistory().undo.count == depthBefore, "no history step")
    }

    // 21. The CONTROL half, without which #20 cannot distinguish "refused
    //     because of the comp member" from "this delete never worked".
    @Test("CONTROL: the same union without the comp member deletes in ONE step")
    func withoutTheCompMemberItDeletes() throws {
        let store = ProjectStore()
        let takeTrack = store.addTrack(name: "Takes", kind: .instrument)
        let ordinary = store.addTrack(name: "Ordinary", kind: .instrument)
        _ = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 0, lengthBeats: 2)
        _ = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 4, lengthBeats: 2)
        _ = try store.addMIDIClip(toTrack: ordinary.id, atBeat: 0, lengthBeats: 2)

        var selection = ArrangeSelection()
        ArrangeTrackSelection.apply(click: store.tracks[0], modifiers: .none, to: &selection)
        ArrangeTrackSelection.apply(click: store.tracks[1], modifiers: .shift, to: &selection)
        #expect(selection.count == 3)

        let depthBefore = store.undoHistory().undo.count
        let removed = try store.removeClips(ids: Array(selection.ids))
        #expect(removed.count == 3)
        #expect(liveIDs(store).isEmpty)
        #expect(store.undoHistory().undo.count == depthBefore + 1)

        try store.undo()
        #expect(liveIDs(store).count == 3, "one undo restores the whole union")
    }

    // 22. m23-am — WHAT THE USER IS SHOWN when #20 refuses. #20 pinned the
    //     survivor set; this pins the bubble's anchor, end to end through the two
    //     pieces the app wires together: the store names the offender, and
    //     `ArrangeRefusalAnchor` turns that into the clip the bubble hangs on.
    //
    //     A header click adopts NO FOCUS (`focusID` is nil below, asserted), so
    //     before m23-am this fell through to `Set.first` over the whole union and
    //     could name any of the five clips. TWO comp members on purpose: with one,
    //     every implementation names it and the leg proves nothing about order.
    @Test("a refused header-union delete anchors on the FIRST comp member, not an innocent clip")
    func refusalAnchorsOnTheOffender() throws {
        let store = ProjectStore()
        let takeTrack = store.addTrack(name: "Takes", kind: .instrument)
        let ordinary = store.addTrack(name: "Ordinary", kind: .instrument)
        let free1 = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 0, lengthBeats: 2)
        let member1 = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 4, lengthBeats: 2)
        let free2 = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 8, lengthBeats: 2)
        let member2 = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 12, lengthBeats: 2)
        _ = try store.addMIDIClip(toTrack: ordinary.id, atBeat: 0, lengthBeats: 2)

        let group = UUID()
        store.tracks[0].takeGroups.append(
            TakeGroup(id: group, name: "PROBE TAKES", lanes: [], comp: []))
        for id in [member1.id, member2.id] {
            let index = store.tracks[0].clips.firstIndex { $0.id == id }!
            store.tracks[0].clips[index].takeGroupID = group
        }

        var selection = ArrangeSelection()
        ArrangeTrackSelection.apply(click: store.tracks[0], modifiers: .none, to: &selection)
        ArrangeTrackSelection.apply(click: store.tracks[1], modifiers: .shift, to: &selection)
        #expect(selection.focusID == nil, "a header click adopts no focus — the item's premise")

        // Exactly what `AppModel.deleteArrangeSelection` hands the store and the
        // anchor: the store's own iteration order, filtered to the selection.
        let liveOrdered = store.tracks.flatMap { $0.clips.map(\.id) }
        let orderedTargets = liveOrdered.filter(selection.ids.contains)
        var thrown: (any Error)?
        do { _ = try store.removeClips(ids: Array(selection.ids)) } catch { thrown = error }
        let error = try #require(thrown)

        let anchor = ArrangeRefusalAnchor.resolve(error: error, focusID: selection.focusID,
                                                  orderedTargets: orderedTargets)
        #expect(anchor == member1.id, "the first comp member in track-then-clip order")
        #expect(anchor != free1.id)
        #expect(anchor != free2.id)
        #expect(anchor != member2.id, "deterministic, not merely 'some offender'")
        #expect((error as? ProjectError)?.errorDescription
                == "clip belongs to take group 'PROBE TAKES' — edit the comp (take.setComp) or take.flatten first")
    }
}
