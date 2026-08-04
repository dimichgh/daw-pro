import Foundation
import Testing
@testable import DAWCore

// m23-am: WHICH clip a refused group delete names, and why that has to be a
// contract rather than an accident.
//
// THE DEFECT. `removeClips` validated inline, so the comp member it named was
// whichever one the CALLER's array reached first. The app's caller hands over
// `Array(Set<UUID>)` — arbitrary, and not even stable across launches, since
// Swift seeds hashing per process. The app anchors its amber refusal bubble on
// the named clip, so the user was told an INNOCENT clip belonged to a take
// group (MEASURED live: 8 clips, comp member at creation index 4, bubble on
// index 3).
//
// WHY THE LEGS BELOW ARE SHAPED THE WAY THEY ARE — this is the trap in testing
// this fix, and it is easy to walk into: **with exactly ONE comp member in the
// set, every possible implementation names it.** The throw fires when that id is
// reached, and it is the only id that can throw, so iteration order is
// unobservable. A single-offender fixture proves the PAYLOAD and says nothing
// about the ORDER. Only >= 2 offenders discriminate — and that is the realistic
// shape anyway, since a materialized comp is routinely several clips, all
// tagged.
//
// Permutations, not repetition, are the instrument. Re-calling with the same Set
// inside one process re-uses one hash seed and gives one answer even under the
// old code; feeding every permutation of an explicit array is fully
// deterministic AND fails loudly on any first-encountered implementation.

@MainActor
@Suite("Group delete — refusal anchor (m23-am)")
struct RemoveClipsRefusalAnchorTests {
    /// The exact user-facing string. BYTE-IDENTICAL is contract: the control
    /// protocol and the MCP surface return it verbatim, `TakeCommandTests` pins
    /// it, and the m23-am payload was added specifically so the UI could learn
    /// the offending clip WITHOUT this wording changing.
    private func message(group: String) -> String {
        "clip belongs to take group '\(group)' — edit the comp (take.setComp) or take.flatten first"
    }

    private func liveIDs(_ store: ProjectStore) -> Set<UUID> {
        Set(store.tracks.flatMap { $0.clips.map(\.id) })
    }

    /// Tags a clip as a comp member the way the store models one, and gives its
    /// track a take group by that id so the message names the GROUP (not the
    /// clip's own name, which is `requireNotCompMember`'s fallback).
    private func tag(_ store: ProjectStore, track t: Int, clip: UUID,
                     group: UUID, named name: String) {
        if !store.tracks[t].takeGroups.contains(where: { $0.id == group }) {
            store.tracks[t].takeGroups.append(
                TakeGroup(id: group, name: name, lanes: [], comp: []))
        }
        let index = store.tracks[t].clips.firstIndex { $0.id == clip }!
        store.tracks[t].clips[index].takeGroupID = group
    }

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil } catch let e as ProjectError { return e } catch { return nil }
    }

    /// Every ordering of `items` — the only way to prove the answer does not
    /// depend on the caller's order.
    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var out: [[T]] = []
        for (i, item) in items.enumerated() {
            var rest = items
            rest.remove(at: i)
            for tail in permutations(rest) { out.append([item] + tail) }
        }
        return out
    }

    // 1. THE DISCRIMINATING LEG. Two comp members on ONE track; the answer must
    //    be the LOWER CLIP INDEX for all 120 orderings of the 5 ids. A
    //    first-encountered implementation names the other member for roughly
    //    half of them.
    @Test("two comp members on one track: the LOWER clip index is named, whatever order the caller passes")
    func twoOffendersOneTrackDeterministic() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Takes", kind: .instrument)
        var clips: [Clip] = []
        for i in 0..<5 {
            clips.append(try store.addMIDIClip(toTrack: t.id, name: "C\(i)",
                                               atBeat: Double(i) * 4, lengthBeats: 2))
        }
        let group = UUID()
        // Indices 1 and 3 — neither first nor last, so "named the first id" and
        // "named the last id" both fail.
        tag(store, track: 0, clip: clips[1].id, group: group, named: "TAKES A")
        tag(store, track: 0, clip: clips[3].id, group: group, named: "TAKES A")

        let ids = clips.map(\.id)
        #expect(permutations(ids).count == 120)
        var named = Set<UUID>()
        for order in permutations(ids) {
            let err = projectError { try store.removeClips(ids: order) }
            let e = try #require(err)
            let anchor = try #require(e.refusalAnchorClipID)
            named.insert(anchor)
            #expect(e.errorDescription == message(group: "TAKES A"))
        }
        #expect(named == [clips[1].id],
                "one answer for every caller order, and it is the lower clip index")
        #expect(liveIDs(store).count == 5, "still all-or-nothing — nothing was removed")
    }

    // 2. TRACK INDEX OUTRANKS CLIP INDEX. Offender on track 0 at clip index 2,
    //    offender on track 1 at clip index 0. A clip-index-only sort would name
    //    the track-1 clip; track-then-clip names the track-0 one.
    @Test("across tracks: track index outranks clip index")
    func trackIndexOutranksClipIndex() throws {
        let store = ProjectStore()
        let t0 = store.addTrack(name: "T0", kind: .instrument)
        let t1 = store.addTrack(name: "T1", kind: .instrument)
        var a: [Clip] = []
        for i in 0..<3 {
            a.append(try store.addMIDIClip(toTrack: t0.id, name: "A\(i)",
                                           atBeat: Double(i) * 4, lengthBeats: 2))
        }
        let b0 = try store.addMIDIClip(toTrack: t1.id, name: "B0", atBeat: 0, lengthBeats: 2)
        let group = UUID()
        tag(store, track: 0, clip: a[2].id, group: group, named: "TAKES B")
        tag(store, track: 1, clip: b0.id, group: UUID(), named: "TAKES C")

        // Caller order puts the track-1 offender FIRST, so anything that reports
        // the first offender it meets names the wrong one.
        let err = projectError { try store.removeClips(ids: [b0.id, a[0].id, a[2].id, a[1].id]) }
        let e = try #require(err)
        #expect(e.refusalAnchorClipID == a[2].id)
        #expect(e.errorDescription == message(group: "TAKES B"))
        #expect(liveIDs(store).count == 4)
    }

    // 3. CLIP INDEX, NOT START BEAT — the choice `refusalOrder` documents, pinned
    //    on a track where they disagree. `Track.clips` is insertion-ordered
    //    (`addMIDIClip` appends), so creating the beat-100 clip first puts it at
    //    index 0 while the beat-0 clip sits at index 1.
    @Test("ordering is by CLIP INDEX, not by start beat")
    func orderIsIndexNotBeat() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "T", kind: .instrument)
        let late = try store.addMIDIClip(toTrack: t.id, name: "LATE", atBeat: 100, lengthBeats: 2)
        let early = try store.addMIDIClip(toTrack: t.id, name: "EARLY", atBeat: 0, lengthBeats: 2)
        #expect(store.tracks[0].clips.map(\.name) == ["LATE", "EARLY"],
                "fixture premise: index order is NOT beat order here")

        let group = UUID()
        tag(store, track: 0, clip: late.id, group: group, named: "TAKES D")
        tag(store, track: 0, clip: early.id, group: group, named: "TAKES D")

        for order in permutations([late.id, early.id]) {
            let e = try #require(projectError { try store.removeClips(ids: order) })
            #expect(e.refusalAnchorClipID == late.id,
                    "index 0 wins even though it starts 100 beats later")
        }
    }

    // 4. THE PRECEDENCE THIS CHANGE INTRODUCED, stated so it is contract rather
    //    than accident: every id is LOCATED before any is validated, so an
    //    unknown id refuses first whichever way round the caller passes them.
    //    Before m23-am this was input-order dependent.
    @Test("clipNotFound beats clipInTakeGroup, in BOTH caller orders")
    func notFoundOutranksTakeGroup() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "T", kind: .instrument)
        let ordinary = try store.addMIDIClip(toTrack: t.id, atBeat: 0, lengthBeats: 2)
        let member = try store.addMIDIClip(toTrack: t.id, atBeat: 4, lengthBeats: 2)
        tag(store, track: 0, clip: member.id, group: UUID(), named: "TAKES E")
        let ghost = UUID()

        for order in [[member.id, ghost, ordinary.id], [ghost, member.id, ordinary.id]] {
            let e = try #require(projectError { try store.removeClips(ids: order) })
            if case .clipNotFound(let id) = e {
                #expect(id == ghost)
            } else {
                Issue.record("expected clipNotFound, got \(e)")
            }
            // And the deliberate narrowness of the accessor: a clip that is not
            // in the project is not something a bubble can be anchored to.
            #expect(e.refusalAnchorClipID == nil)
        }
        #expect(liveIDs(store).count == 2)
    }

    // 5. ALL-OR-NOTHING ACROSS TWO TRACKS, with the id assertion the m23-g1 suite
    //    could not make. The offender is on the SECOND track, so the ordinary
    //    clips spared on the first are the ones a user would have expected to go.
    @Test("a comp member on track 2 refuses the whole two-track delete and names itself")
    func allOrNothingAcrossTracks() throws {
        let store = ProjectStore()
        let t0 = store.addTrack(name: "Ordinary", kind: .instrument)
        let t1 = store.addTrack(name: "Takes", kind: .instrument)
        let o0 = try store.addMIDIClip(toTrack: t0.id, name: "O0", atBeat: 0, lengthBeats: 2)
        let o1 = try store.addMIDIClip(toTrack: t0.id, name: "O1", atBeat: 4, lengthBeats: 2)
        let k0 = try store.addMIDIClip(toTrack: t1.id, name: "K0", atBeat: 0, lengthBeats: 2)
        let member = try store.addMIDIClip(toTrack: t1.id, name: "K1", atBeat: 4, lengthBeats: 2)
        tag(store, track: 1, clip: member.id, group: UUID(), named: "PROBE TAKES")

        let before = liveIDs(store)
        let depthBefore = store.undoHistory().undo.count
        let e = try #require(projectError {
            try store.removeClips(ids: [o0.id, o1.id, k0.id, member.id])
        })
        #expect(e.refusalAnchorClipID == member.id)
        #expect(e.errorDescription == message(group: "PROBE TAKES"))
        #expect(liveIDs(store) == before, "all-or-nothing preserved — not one clip left")
        #expect(store.tracks[0].clips.count == 2, "the OTHER track's clips are spared too")
        #expect(store.undoHistory().undo.count == depthBefore, "no history step")
    }

    // 6. The single-clip case is UNCHANGED — the id the store names is the clip
    //    the user acted on, so the app's new "error id beats focus id" rule is a
    //    no-op there rather than a behaviour change.
    @Test("a one-clip refusal names that clip")
    func singleClipUnchanged() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "T", kind: .instrument)
        let member = try store.addMIDIClip(toTrack: t.id, atBeat: 0, lengthBeats: 2)
        tag(store, track: 0, clip: member.id, group: UUID(), named: "TAKES F")

        let e = try #require(projectError { try store.removeClips(ids: [member.id]) })
        #expect(e.refusalAnchorClipID == member.id)
        #expect(e.errorDescription == message(group: "TAKES F"))
    }

    // 7. The message is contract; the payload rides beside it, never inside it.
    //    A UUID leaking into the wording would break every consumer that pins the
    //    string, which is exactly why this leg compares the WHOLE string rather
    //    than `contains`.
    @Test("the m23-am payload does not change the message text")
    func messageStaysByteIdentical() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "T", kind: .instrument)
        let member = try store.addMIDIClip(toTrack: t.id, atBeat: 0, lengthBeats: 2)
        let group = UUID()
        tag(store, track: 0, clip: member.id, group: group, named: "PROBE TAKES")

        let e = try #require(projectError { try store.removeClips(ids: [member.id]) })
        #expect(e.errorDescription
                == "clip belongs to take group 'PROBE TAKES' — edit the comp (take.setComp) or take.flatten first")
        #expect(e.errorDescription?.contains(member.id.uuidString) == false)
        #expect(e.errorDescription?.contains(group.uuidString) == false)
    }

    // 8. `refusalOrder` itself, directly — the ONE home for the ordering rule,
    //    proven independent of any fixture so a future caller adopting it knows
    //    what it promises.
    @Test("refusalOrder sorts by track index, then clip index")
    func refusalOrderIsTotalAndStable() {
        let input = [(track: 2, clip: 0), (track: 0, clip: 5), (track: 1, clip: 1),
                     (track: 0, clip: 1), (track: 1, clip: 0)]
        let sorted = ProjectStore.refusalOrder(input)
        #expect(sorted.map { [$0.track, $0.clip] }
                == [[0, 1], [0, 5], [1, 0], [1, 1], [2, 0]])
    }
}
