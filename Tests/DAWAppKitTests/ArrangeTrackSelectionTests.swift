import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

// m23-y: what a click on a TRACK HEADER does to the arrange selection.
//
// The whole rule lives in `ArrangeTrackSelection` precisely so it can be pinned
// here — `DAWApp` has no test target, so anything decided inside the SwiftUI
// `body` or the `AppModel` handler would be invisible to `Tests/`.
//
// ═══ m25-l-1 DEFECT ② — THE PLAIN CLICK'S MEANING CHANGED (USER RULING) ═══════
//
// 2026-08-13, the user hands-on: *"when I click on track with clips, all clips
// got selected which is not expected."* A PLAIN header click is now a CURSOR
// MOVE — it names the active track and CLEARS the clip selection; ⇧/⌘ keeps the
// set behaviour this suite was written for.
//
// ⚠️ **THE OLD BEHAVIOUR WAS DELIBERATE, NOT A BUG.** It was documented, argued
// for, and matches Logic Pro. What changed is the world: m25-l-3 made a header
// click THE way to choose a paste destination, so a navigational gesture also
// armed the next ⌫ with every clip on the track. The argument is in
// `ArrangeTrackSelection`'s banner.
//
// ⚠️ **NOTHING THIS SUITE PINNED WAS DELETED.** Tests whose SUBJECT was the set
// behaviour had their INPUT moved one modifier over (plain → ⇧) and kept their
// ASSERTIONS verbatim; each carries a note saying so. Tests whose subject WAS the
// plain click were re-authored and say what they used to claim. If you are here
// because a test reads oddly: it was decided, not drifted.

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

    // MARK: Plain click — THE CURSOR (m25-l-1 defect ②)

    // 4. ⭐ **THE RULING, AND THE ONE TEST THE CHANGE EXISTS FOR.**
    //
    //    ⚠️ **RE-AUTHORED 2026-08-13 BY USER RULING — this test used to assert the
    //    OPPOSITE**, under the name `plainClickSelectsTheTrack` and the title "a
    //    plain header click selects exactly that track's clips". That was the
    //    roadmap's first leg for m23-y, it was a deliberate design, and Logic Pro
    //    behaves the same way. The user reversed it hands-on: *"when I click on
    //    track with clips, all clips got selected which is not expected"* — after
    //    m25-l-3 made a header click THE way to choose a paste destination, so the
    //    gesture that aims a ⌘V also armed the next ⌫ with the whole track.
    //
    //    THE OLD ASSERTION IS NOT DELETED. It lives one modifier over, in
    //    `shiftClickSelectsTheTrack` directly below.
    //
    //    ⛔ THE HALF THAT MUST NOT BREAK is asserted here too: a plain click STILL
    //    names the active track. Paste-to-selected-track (m25-l-3, the user's own
    //    reported bug) reads exactly this field, so a plain click degraded to a
    //    pure no-op would silently break the feature this ruling depends on.
    //    Swept across every chord in `ArrangeActiveTrackTests`.
    @Test("a plain header click selects NOTHING and names the active track (USER RULING 2026-08-13)")
    func plainClickSelectsNothingAndNamesTheTrack() {
        let a = UUID(), b = UUID(), other = UUID()
        let t = track([a, b])
        var s = ArrangeSelection()
        s.selectOnly(other)

        let out = ArrangeTrackSelection.apply(click: t, modifiers: .none, to: &s)
        #expect(s.isEmpty, "a plain header click is a CURSOR MOVE — it selects nothing")
        #expect(!s.contains(a), "not even the clicked track's own clips")
        #expect(!s.contains(b))
        #expect(!s.contains(other), "and the previous selection is CLEARED, not left standing")
        #expect(out.intent == .replace)
        #expect(out.effect == .replace, "the effect case and its wire string are unchanged")
        #expect(out.clipIDs == [a, b],
                "clipIDs still reports what is ON the track — it is the feedback predicate's clip-count proxy, not a claim about what the click acted on")
        #expect(out.activeTrackID == t.id, "⛔ the constraint: a plain click still names the cursor")
        expectInvariants(s)
    }

    // 4b. **#4's OLD ASSERTION, ONE MODIFIER OVER.** Selecting a whole track is a
    //     capability the ruling PRESERVED rather than removed — it now needs ⇧/⌘.
    //     Both chords swept, because both must reach it.
    @Test("⇧/⌘ on a header selects exactly that track's clips — the capability the ruling kept")
    func shiftClickSelectsTheTrack() {
        for mods in [ArrangeClickModifiers.shift, .command] {
            let a = UUID(), b = UUID(), c = UUID()
            var s = ArrangeSelection()
            let out = ArrangeTrackSelection.apply(click: track([a, b]), modifiers: mods, to: &s)
            #expect(s.ids == [a, b])
            #expect(!s.contains(c), "and nothing else in the project")
            #expect(out.intent == .toggle)
            #expect(out.effect == .add)
            #expect(out.clipIDs == [a, b])
            expectInvariants(s)
        }
    }

    // 4c. …and "exactly this track's clips and nothing else" is still reachable
    //     from a NON-empty selection, in two clicks: plain (clears + activates)
    //     then ⇧ (adds them all). This is the composition that makes the ruling a
    //     restriction on ONE gesture rather than the loss of a capability, so it
    //     is asserted rather than merely claimed in the banner.
    @Test("plain-then-⇧ on the same header reaches EXACTLY that track's clips in two clicks")
    func plainThenShiftIsolatesTheTrack() {
        let a = UUID(), b = UUID(), foreign = UUID()
        let t = track([a, b])
        var s = ArrangeSelection()
        s.selectOnly(foreign)

        ArrangeTrackSelection.apply(click: t, modifiers: .none, to: &s)
        let out = ArrangeTrackSelection.apply(click: t, modifiers: .shift, to: &s)
        #expect(s.ids == [a, b])
        #expect(!s.contains(foreign))
        #expect(out.effect == .add)
        expectInvariants(s)
    }

    // 5. THE FOCUS DECISION, half one: a header click NEVER ADOPTS a focus.
    //    ⇧-clicking the header of a track with one MIDI clip must NOT open the
    //    piano roll on it. The set paths' rule — SELECTING IS NOT OPENING.
    //
    //    ⚠️ INPUT RESTATED AT m25-l-1 DEFECT ② (USER RULING 2026-08-13): this drove
    //    a PLAIN click, which no longer selects anything at all. The ASSERTION is
    //    untouched — the rule is "a SET path adopts no focus", and it is now
    //    proved on the branch that still builds a set (`formUnion`).
    @Test("a ⇧ header click adopts NO focus, even on a single-clip track")
    func shiftClickNeverAdoptsFocus() {
        let only = UUID()
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: track([only]), modifiers: .shift, to: &s)
        #expect(s.ids == [only])
        #expect(s.focusID == nil, "a header has no anchor clip — it must not open the note editor")
        expectInvariants(s)
    }

    // 6. THE FOCUS DECISION, half two: a SURVIVING focus is kept. This is what
    //    leaves the piano roll open when you click the header of the track it is
    //    already open on — the roll-vs-arrange DELETE arbitration documented at
    //    `AppModel.clickTrack`.
    //
    //    ⚠️ INPUT RESTATED AT DEFECT ②, AND THE RESTATEMENT IS THE POINT: the
    //    arbitration used to be reachable from a PLAIN click (`replace(with:)`
    //    keeps a member focus). A plain click now empties the selection, so INV2
    //    drops the focus and the roll CLOSES — see `plainClickClosesAnOpenRoll`.
    //    The arbitration survives behind ⇧, which is what this pins.
    @Test("a ⇧ header click KEEPS a focus that survives into the new set")
    func shiftClickKeepsSurvivingFocus() {
        let a = UUID(), b = UUID()
        var s = ArrangeSelection()
        s.selectOnly(a)                                  // focus = a
        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .shift, to: &s)
        #expect(s.ids == [a, b])
        #expect(s.focusID == a, "the focus is a member of the new set — it survives")
        expectInvariants(s)
    }

    // 7. The other side of #6, and a USER-VISIBLE consequence of the ruling: a
    //    PLAIN click closes an open piano roll, wherever its clip lives.
    //
    //    ⚠️ RE-AUTHORED AT DEFECT ②. This used to be "a plain header click drops a
    //    focus the new set does not contain", pinning `replace(with:)`'s INV1
    //    restoration THROUGH the header path. The header path no longer reaches
    //    that branch with a non-empty set; the mutator's own rule is still pinned
    //    directly in `ArrangeSelectionTests` (`replace(with:)`'s surviving- and
    //    vanished-focus pair), so no coverage was lost — only the route to it.
    //    What is asserted here now is the fact a user can see.
    @Test("a plain header click closes an open piano roll — on this track or another")
    func plainClickClosesAnOpenRoll() {
        let a = UUID(), foreign = UUID()
        // (i) the focus is on ANOTHER track…
        var s = ArrangeSelection()
        s.selectOnly(foreign)
        ArrangeTrackSelection.apply(click: track([a]), modifiers: .none, to: &s)
        #expect(s.isEmpty)
        #expect(s.focusID == nil, "the note editor closes (INV2)")
        expectInvariants(s)

        // (ii) …and on the CLICKED track, which is where it used to survive.
        var s2 = ArrangeSelection()
        s2.selectOnly(a)
        ArrangeTrackSelection.apply(click: track([a]), modifiers: .none, to: &s2)
        #expect(s2.isEmpty)
        #expect(s2.focusID == nil,
                "before the ruling `replace(with:)` kept this focus and the roll stayed open")
        expectInvariants(s2)
    }

    // 8. THE ROADMAP'S "zero-clip track selects cleanly" leg, at the unit layer:
    //    a plain click on an empty track CLEARS. It is not guarded, deliberately.
    //
    //    ⚠️ UNCHANGED BY DEFECT ②, AND THAT IS EVIDENCE, NOT LUCK: the ruling made
    //    the plain branch behave at EVERY clip count the way it already behaved at
    //    zero, so this test passes verbatim. If it ever needs editing, the plain
    //    branch has stopped being a strict generalisation of what shipped.
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
    //
    //    ⚠️ SETUP RESTATED AT DEFECT ②: the FIRST click is now ⇧ too, because a
    //    plain one would build no base. The assertion is untouched.
    @Test("⇧ on a second header adds its clips — the exact union, nothing dropped")
    func shiftClickAddsUnion() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .shift, to: &s)
        let out = ArrangeTrackSelection.apply(click: track([c, d]), modifiers: .shift, to: &s)
        #expect(s.ids == [a, b, c, d])
        #expect(out.intent == .toggle)
        #expect(out.effect == .add)
        expectInvariants(s)
    }

    // 10. ⌘ is the same chord as ⇧ here, because it is the SAME table
    //     (`ArrangeClickIntent.intent(for:)`) the clip click and the marquee use.
    //
    //     ⚠️ ONE `track` INSTANCE FOR BOTH CHORDS (changed at m25-l-1). It used to
    //     call `track([b])` twice, which built two DISTINCT tracks that happened
    //     to hold the same clip id — invisible while the outcome carried no track
    //     identity, and a false failure the moment it carried `activeTrackID`.
    //     Clicking ONE track with two chords is also what the test's sentence
    //     actually claims, so the whole-value comparison below gets STRONGER
    //     rather than weaker: it now also asserts that the chord does not change
    //     WHICH track the click makes active.
    @Test("⌘ behaves exactly as ⇧ — one shared chord table, not a second one")
    func commandMatchesShift() {
        let a = UUID(), b = UUID()
        let clicked = track([b])
        var viaShift = ArrangeSelection(), viaCommand = ArrangeSelection()
        viaShift.selectOnly(a)
        viaCommand.selectOnly(a)
        let s1 = ArrangeTrackSelection.apply(click: clicked, modifiers: .shift, to: &viaShift)
        let s2 = ArrangeTrackSelection.apply(click: clicked, modifiers: .command, to: &viaCommand)
        #expect(viaShift == viaCommand)
        #expect(s1 == s2)
        #expect(s1.effect == .add)
    }

    // 11. THE CHORD DECISION, and the only test that discriminates it from
    //     `formUnion`: ⇧ on a FULLY-selected header removes exactly that track's
    //     clips and leaves the other track's standing. Under a `formUnion`
    //     resolution this selection would be unchanged (still 4 ids).
    //
    //     ⚠️ SETUP RESTATED AT DEFECT ②: both setup clicks are ⇧ now (a plain one
    //     would build no base). The assertions are untouched.
    @Test("⇧ on a FULLY-selected header removes exactly that track's clips")
    func shiftClickTogglesOffWhenAllSelected() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let t1 = track([a, b]), t2 = track([c, d])
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: t1, modifiers: .shift, to: &s)
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
    //
    //     ⚠️ SETUP RESTATED AT DEFECT ②: the header click is ⇧ (a plain one selects
    //     nothing to compose with). The assertions are untouched.
    @Test("a mixed track+clip selection is an ordinary id set the clip path still owns")
    func mixedSelectionComposes() {
        let a = UUID(), b = UUID(), loose = UUID()
        var s = ArrangeSelection()
        ArrangeTrackSelection.apply(click: track([a, b]), modifiers: .shift, to: &s)
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

        // Two header clicks, ⇧ on both. ⚠️ RESTATED AT m25-l-1 DEFECT ②: the first
        // used to be PLAIN, which built the base set. A plain click now selects
        // nothing (USER RULING 2026-08-13), so building a two-track union takes
        // two chords. The union asserted below, and everything after it, is
        // unchanged.
        var selection = ArrangeSelection()
        ArrangeTrackSelection.apply(click: store.tracks[0], modifiers: .shift, to: &selection)
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
    //
    //     ⚠️ SETUP RESTATED AT DEFECT ② with #20's, for #20's reason. Assertions
    //     untouched.
    @Test("CONTROL: the same union without the comp member deletes in ONE step")
    func withoutTheCompMemberItDeletes() throws {
        let store = ProjectStore()
        let takeTrack = store.addTrack(name: "Takes", kind: .instrument)
        let ordinary = store.addTrack(name: "Ordinary", kind: .instrument)
        _ = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 0, lengthBeats: 2)
        _ = try store.addMIDIClip(toTrack: takeTrack.id, atBeat: 4, lengthBeats: 2)
        _ = try store.addMIDIClip(toTrack: ordinary.id, atBeat: 0, lengthBeats: 2)

        var selection = ArrangeSelection()
        ArrangeTrackSelection.apply(click: store.tracks[0], modifiers: .shift, to: &selection)
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
    //
    //     ⚠️ SETUP RESTATED AT DEFECT ② with #20's, for #20's reason. Assertions
    //     untouched — including the no-focus premise, which `formUnion` upholds
    //     exactly as `replace(with:)` did.
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
        ArrangeTrackSelection.apply(click: store.tracks[0], modifiers: .shift, to: &selection)
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
