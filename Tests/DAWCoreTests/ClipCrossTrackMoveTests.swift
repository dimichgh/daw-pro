import Foundation
import Testing
@testable import DAWCore

/// m23-aj-1 — `ProjectStore.moveClips(ids:byTracks:byBeats:)` and
/// `moveClips(ids:toTrackId:byBeats:)`, the cross-track group-move verb.
///
/// The claims that carry the item are the LANDING POLICY (raw track index, clamp
/// at the ends, refuse an incompatible kind, never skip), the TWO-PHASE mechanic
/// (vacate every crossing mover before landing any, so source and destination
/// sets may overlap), and the fact that it resolves overlap through the SAME
/// choke point the horizontal verb uses rather than a second implementation.
///
/// Design record: `docs/research/design-m23aj-cross-track-move.md`.
@MainActor
@Suite("Cross-track clip move (m23-aj)")
struct ClipCrossTrackMoveTests {

    // MARK: - Fixtures and helpers

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// THE fixture: `[inst A, inst B, inst C, bus D, audio E]`.
    ///
    /// **Load-bearing, do not shorten.** Three consecutive INSTRUMENT tracks give
    /// a group move room to land legally; the BUS at index 3 is what the kind
    /// refusal lands on; the AUDIO track at index 4 is what a runaway `byTracks`
    /// clamps to *before* being kind-checked. A three-track `[inst, inst, bus]`
    /// layout would make the headline group land ON the bus and redden that leg
    /// for entirely the wrong reason.
    private func fixture(clipsOnA: [Clip] = [], clipsOnB: [Clip] = [],
                         clipsOnC: [Clip] = [], clipsOnE: [Clip] = [])
        -> (ProjectStore, [Track]) {
        let tracks = [
            Track(name: "A", kind: .instrument, clips: clipsOnA),
            Track(name: "B", kind: .instrument, clips: clipsOnB),
            Track(name: "C", kind: .instrument, clips: clipsOnC),
            Track(name: "D", kind: .bus),
            Track(name: "E", kind: .audio, clips: clipsOnE),
        ]
        return (ProjectStore(tracks: tracks), tracks)
    }

    private func midi(_ name: String, at beat: Double, length: Double = 4,
                      id: UUID = UUID()) -> Clip {
        Clip(id: id, name: name, startBeat: beat, lengthBeats: length,
             notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)])
    }

    private func audio(_ name: String, at beat: Double, length: Double = 4,
                       id: UUID = UUID()) -> Clip {
        Clip(id: id, name: name, startBeat: beat, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-m23aj.wav"))
    }

    private func trackIndex(_ store: ProjectStore, of clipID: UUID) -> Int? {
        store.tracks.firstIndex { $0.clips.contains { $0.id == clipID } }
    }

    private func clip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap(\.clips).first { $0.id == id }
    }

    private func copies(_ store: ProjectStore, _ id: UUID) -> Int {
        store.tracks.flatMap(\.clips).filter { $0.id == id }.count
    }

    private func undoDepth(_ store: ProjectStore) -> Int { store.undoHistory().undo.count }

    // 0.
    @Test("FIXTURE PIN: the track order and kinds every other leg reasons about")
    func fixtureShape() {
        let (store, _) = fixture()
        #expect(store.tracks.map(\.name) == ["A", "B", "C", "D", "E"])
        #expect(store.tracks.map(\.kind) == [.instrument, .instrument, .instrument, .bus, .audio])
    }

    // MARK: - The eligibility predicates (design step 1)

    // P1.
    @Test("canHold is decided by CONTENT: the full clip-kind x track-kind matrix")
    func canHoldMatrix() {
        let midiClip = midi("m", at: 0)
        let audioClip = audio("a", at: 0)
        let inst = Track(name: "i", kind: .instrument)
        let aud = Track(name: "a", kind: .audio)
        let bus = Track(name: "b", kind: .bus)

        #expect(inst.canHold(midiClip))
        #expect(!inst.canHold(audioClip))
        #expect(!aud.canHold(midiClip))
        #expect(aud.canHold(audioClip))
        // A bus holds NO clips at all — one fact, not two.
        #expect(!bus.canHold(midiClip))
        #expect(!bus.canHold(audioClip))

        // The two halves stay separately addressable so they can diverge.
        #expect(inst.canHoldMIDIClips && !inst.canHoldAudioClips)
        #expect(aud.canHoldAudioClips && !aud.canHoldMIDIClips)
        #expect(!bus.canHoldMIDIClips && !bus.canHoldAudioClips)
    }

    // P2.
    @Test("duplicateClip's audio rule, rewritten onto canHoldAudioClips — CONTROLLED PAIR")
    func duplicateAudioRuleUnchanged() throws {
        // FAILURE half: an audio clip still cannot land on an instrument track.
        let source = audio("A", at: 0)
        let (store, tracks) = fixture(clipsOnE: [source])
        let err = projectError {
            _ = try store.duplicateClip(clipId: source.id, toStartBeat: 0, toTrackId: tracks[0].id)
        }
        guard case .trackKindUnsupported(let kind)? = err else {
            Issue.record("expected trackKindUnsupported, got \(String(describing: err))")
            return
        }
        #expect(kind == .instrument)

        // SUCCESS half: …and it still CAN land on an audio track. Without this,
        // an inverted `canHoldAudioClips` (`kind != .audio`) would still throw on
        // the instrument track and pass the failure half alone.
        let dup = try store.duplicateClip(clipId: source.id, toStartBeat: 16,
                                          toTrackId: tracks[4].id)
        #expect(dup.clip.startBeat == 16)
        #expect(trackIndex(store, of: dup.clip.id) == 4)
    }

    // MARK: - The two clamps as pure functions (design step 3)

    // C1.
    @Test("clampedTrackDelta: in range, top wall, bottom wall, zero, empty track list")
    func trackDeltaClamp() {
        // In range: a group on tracks 1...2 of a 5-track project moving down 1.
        #expect(ProjectStore.clampedTrackDelta(requested: 1, minTrackIndex: 1,
                                               maxTrackIndex: 2, trackCount: 5) == (1, false))
        // Top wall: the TOPMOST mover decides for the whole group.
        #expect(ProjectStore.clampedTrackDelta(requested: -3, minTrackIndex: 1,
                                               maxTrackIndex: 2, trackCount: 5) == (-1, true))
        // Bottom wall: the BOTTOMMOST mover decides for the whole group.
        #expect(ProjectStore.clampedTrackDelta(requested: 9, minTrackIndex: 1,
                                               maxTrackIndex: 2, trackCount: 5) == (2, true))
        // Already at both ends: the only legal delta is 0.
        #expect(ProjectStore.clampedTrackDelta(requested: 1, minTrackIndex: 0,
                                               maxTrackIndex: 4, trackCount: 5) == (0, true))
        // Zero is never a clamp.
        #expect(ProjectStore.clampedTrackDelta(requested: 0, minTrackIndex: 1,
                                               maxTrackIndex: 2, trackCount: 5) == (0, false))
        // Degenerate: no tracks at all. NOT reachable from the verb — an empty
        // `unique` returns at phase 0b, and a non-empty one implies a track
        // exists — so these two rows keep the function TOTAL, nothing more.
        #expect(ProjectStore.clampedTrackDelta(requested: 2, minTrackIndex: 0,
                                               maxTrackIndex: 0, trackCount: 0) == (0, true))
        #expect(ProjectStore.clampedTrackDelta(requested: 0, minTrackIndex: 0,
                                               maxTrackIndex: 0, trackCount: 0) == (0, false))
    }

    // C2.
    @Test("clampedTrackDelta NEVER inverts the sign and never searches past a wall")
    func trackDeltaClampNeverInverts() {
        // lower <= 0 <= upper for any in-range sources, so a downward request can
        // never come back negative and vice versa.
        for requested in -9...9 {
            for minIdx in 0...4 {
                for maxIdx in minIdx...4 {
                    let (effective, _) = ProjectStore.clampedTrackDelta(
                        requested: requested, minTrackIndex: minIdx,
                        maxTrackIndex: maxIdx, trackCount: 5)
                    #expect(effective * requested >= 0)          // no sign inversion
                    #expect(abs(effective) <= abs(requested))    // never overshoots
                    #expect(minIdx + effective >= 0)
                    #expect(maxIdx + effective <= 4)
                }
            }
        }
    }

    // C3.
    @Test("clampedGroupBeatDelta is the hoisted beat-0 clamp, unchanged in meaning")
    func beatDeltaClamp() {
        #expect(ProjectStore.clampedGroupBeatDelta(requested: 4, minStart: 2) == (4, false))
        #expect(ProjectStore.clampedGroupBeatDelta(requested: -10, minStart: 2) == (-2, true))
        #expect(ProjectStore.clampedGroupBeatDelta(requested: -2, minStart: 2) == (-2, false))
        #expect(ProjectStore.clampedGroupBeatDelta(requested: 0, minStart: 0) == (0, false))
    }

    // C4.
    @Test("moveClipsAcrossLabel: all four rows, and the byte-exact 'did not cross' row")
    func labelRows() {
        // Did not cross → the HORIZONTAL label, byte for byte, so the Edit menu
        // does not depend on which API the caller reached for.
        #expect(ProjectStore.moveClipsAcrossLabel(count: 1, singleName: "Loop",
                                                  destination: .unchanged)
                == ProjectStore.moveClipsLabel(count: 1, singleName: "Loop"))
        #expect(ProjectStore.moveClipsAcrossLabel(count: 3, singleName: "Loop",
                                                  destination: .unchanged)
                == ProjectStore.moveClipsLabel(count: 3, singleName: "Loop"))
        #expect(ProjectStore.moveClipsAcrossLabel(count: 1, singleName: "Loop",
                                                  destination: .single("Drums"))
                == "Move Clip 'Loop' to 'Drums'")
        #expect(ProjectStore.moveClipsAcrossLabel(count: 3, singleName: "Loop",
                                                  destination: .single("Drums"))
                == "Move 3 Clips to 'Drums'")
        #expect(ProjectStore.moveClipsAcrossLabel(count: 3, singleName: "Loop",
                                                  destination: .several)
                == "Move 3 Clips Across Tracks")
    }

    // MARK: - 1/2. The headline case, and the source/destination overlap

    /// Two movers whose beat windows OVERLAP EACH OTHER, on adjacent tracks, so
    /// that moving down 1 makes track B simultaneously vacated (by Y) and landed
    /// on (by X). If X's overlap pass ran while Y was still there, Y would be
    /// trimmed — which is what legs 1 and 2 exist to catch.
    private func overlappingPair() -> (ProjectStore, [Track], Clip, Clip) {
        let x = midi("X", at: 0, length: 4)
        let y = midi("Y", at: 2, length: 4)
        let (store, tracks) = fixture(clipsOnA: [x], clipsOnB: [y])
        return (store, tracks, x, y)
    }

    // 1.
    @Test("HEADLINE: a group spanning 2 tracks moves down 1 in ONE journal entry, offsets intact")
    func headlineGroupMovesDownOne() throws {
        let (store, tracks, x, y) = overlappingPair()
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], byTracks: 1)

        #expect(result.requestedTrackDelta == 1)
        #expect(result.effectiveTrackDelta == 1)
        #expect(!result.clampedTracks)
        #expect(!result.clamped)
        #expect(result.effectiveDeltaBeats == 0)

        // Both landed, on the tracks the raw-index axis predicts.
        #expect(trackIndex(store, of: x.id) == 1)
        #expect(trackIndex(store, of: y.id) == 2)
        // The relative TRACK offset survived — that is the rigidity claim.
        // `#require`, never `!`: a force-unwrap here CRASHES the whole test
        // PROCESS when the leg fails, which silently truncates the red set every
        // later leg belongs to (measured — it masked four legs under a mutation).
        let xTrack = try #require(trackIndex(store, of: x.id))
        let yTrack = try #require(trackIndex(store, of: y.id))
        #expect(yTrack - xTrack == 1)
        // The relative BEAT offsets are untouched by a pure vertical move.
        #expect(clip(store, x.id)?.startBeat == 0)
        #expect(clip(store, y.id)?.startBeat == 2)

        #expect(result.landings == [
            ClipLanding(clipID: x.id, fromTrackID: tracks[0].id, toTrackID: tracks[1].id),
            ClipLanding(clipID: y.id, fromTrackID: tracks[1].id, toTrackID: tracks[2].id),
        ])

        // ONE journal entry. "The clips moved" cannot discriminate this from a
        // LOOP of single moves — only the depth can.
        #expect(undoDepth(store) - depth == 1)
        #expect(store.undoHistory().undo.first == "Move 2 Clips Across Tracks")
    }

    // 2.
    @Test("SOURCE AND DESTINATION OVERLAP: movers do not trim each other")
    func vacateAllBeforeLandingAny() throws {
        let (store, _, x, y) = overlappingPair()
        // Calibration: the two windows really do overlap, so a per-track
        // remove-then-add loop WOULD have trimmed Y when X landed on B.
        #expect(x.startBeat < y.startBeat + y.lengthBeats)
        #expect(y.startBeat < x.startBeat + x.lengthBeats)

        let result = try store.moveClips(ids: [x.id, y.id], byTracks: 1)

        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        // Y kept its full geometry AND its notes — a trim is data loss, not just
        // a length change.
        #expect(clip(store, y.id)?.lengthBeats == 4)
        #expect(clip(store, y.id)?.notes?.count == 1)
        // Each clip exists exactly once: never on two tracks, never on none.
        #expect(copies(store, x.id) == 1)
        #expect(copies(store, y.id) == 1)
        #expect(store.tracks.flatMap(\.clips).count == 2)
    }

    // MARK: - 3/4. All-or-nothing refusals

    // 3.
    @Test("ALL-OR-NOTHING on KIND: one mover landing on the bus refuses the WHOLE move")
    func kindRefusalIsWhole() throws {
        let x = midi("X", at: 0)
        let y = midi("Y", at: 0)
        let z = midi("Z", at: 0)
        let (store, _) = fixture(clipsOnA: [x], clipsOnB: [y], clipsOnC: [z])

        let snapshot = store.tracks
        let depth = undoDepth(store)
        let err = projectError { _ = try store.moveClips(ids: [x.id, y.id, z.id], byTracks: 1) }

        guard case .midiClipsRequireInstrumentTrack(let kind)? = err else {
            Issue.record("expected midiClipsRequireInstrumentTrack, got \(String(describing: err))")
            return
        }
        #expect(kind == .bus)
        // The WHOLE array, not just the offending clip: X and Y precede Z and a
        // mutate-as-you-go implementation would already have moved them.
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
    }

    // 3b.
    @Test("an AUDIO clip landing on a non-audio track throws trackKindUnsupported")
    func audioKindRefusal() throws {
        let a = audio("A", at: 0)
        let (store, _) = fixture(clipsOnE: [a])
        let snapshot = store.tracks
        // E is index 4; -1 lands on the bus at index 3.
        let err = projectError { _ = try store.moveClips(ids: [a.id], byTracks: -1) }
        guard case .trackKindUnsupported(let kind)? = err else {
            Issue.record("expected trackKindUnsupported, got \(String(describing: err))")
            return
        }
        #expect(kind == .bus)
        #expect(store.tracks == snapshot)
    }

    // 4.
    @Test("ALL-OR-NOTHING on COMP: a take member in the set refuses the WHOLE move")
    func compMemberRefusesWhole() throws {
        let t1 = midi("T1", at: 0, length: 8)
        let t2 = midi("T2", at: 0, length: 8)
        let ordinary = midi("Ord", at: 32)
        let (store, tracks) = fixture(clipsOnA: [t1, t2, ordinary])
        _ = try store.groupTakes(trackId: tracks[0].id, clipIds: [t1.id, t2.id])
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })

        let snapshot = store.tracks
        let depth = undoDepth(store)
        // The ORDINARY clip is listed FIRST, so a mutate-as-you-go implementation
        // would already have moved it by the time it reached the member.
        let err = projectError {
            _ = try store.moveClips(ids: [ordinary.id, member.id], byTracks: 1)
        }
        if case .clipInTakeGroup? = err {} else {
            Issue.record("expected clipInTakeGroup, got \(String(describing: err))")
        }
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
    }

    // MARK: - 5/6. The vertical clamps

    // 5.
    @Test("TOP CLAMP: a group already touching track 0 clamps to nothing, no throw, no undo slot")
    func topClamp() throws {
        let (store, tracks, x, y) = overlappingPair()
        let snapshot = store.tracks
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], byTracks: -1)

        #expect(result.requestedTrackDelta == -1)
        #expect(result.effectiveTrackDelta == 0)
        #expect(result.clampedTracks)
        #expect(result.landings.allSatisfy { $0.fromTrackID == $0.toTrackID })
        #expect(result.landings.map(\.fromTrackID) == [tracks[0].id, tracks[1].id])
        // A no-op must not consume an undo slot, must not touch the project, and
        // must not mark it dirty — it never enters `performEdit` at all. (Undo
        // DEPTH alone cannot see this: `performEdit` already skips journaling a
        // value-neutral body, so only `isDirty` distinguishes "returned before the
        // edit" from "ran an edit that happened to change nothing".)
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
        #expect(!store.isDirty)
    }

    // 5b.
    @Test("NO-OP RETURNS BEFORE THE OVERLAP PASS: a clamped press does not trim a crossfade partner")
    func clampedNoOpDoesNotTrimNeighbour() throws {
        // The reason phase 2d is not an optimisation. M and N overlap on purpose
        // — the shape a sanctioned audio crossfade pair has. A held ↑ at the top
        // of the track list emits this gesture repeatedly, and running the overlap
        // pass at M's CURRENT position would eat N a little more each press.
        let mover = midi("M", at: 0, length: 4)
        let neighbour = midi("N", at: 2, length: 4)
        let (store, _) = fixture(clipsOnA: [mover, neighbour])
        let snapshot = store.tracks
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [mover.id], byTracks: -1)

        #expect(result.effectiveTrackDelta == 0)
        #expect(result.clampedTracks)
        // N is NOT a mover, so nothing exempts it from a pass that should never
        // have run: without the phase-2d return it would be trimmed to [4, 6).
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(clip(store, neighbour.id)?.startBeat == 2)
        #expect(clip(store, neighbour.id)?.lengthBeats == 4)
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
        #expect(!store.isDirty)
    }

    // 6a.
    @Test("BOTTOM CLAMP: symmetric — an audio clip on the last track clamps to nothing")
    func bottomClamp() throws {
        let a = audio("A", at: 0)
        let (store, tracks) = fixture(clipsOnE: [a])
        let snapshot = store.tracks
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [a.id], byTracks: 5)

        #expect(result.requestedTrackDelta == 5)
        #expect(result.effectiveTrackDelta == 0)
        #expect(result.clampedTracks)
        #expect(result.landings == [ClipLanding(clipID: a.id, fromTrackID: tracks[4].id,
                                                toTrackID: tracks[4].id)])
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
        #expect(!store.isDirty)
    }

    // 6b.
    @Test("CLAMP FIRST, KIND-CHECK SECOND: byTracks 99 clamps to the AUDIO track, then refuses")
    func clampBeforeKindCheck() throws {
        let m = midi("M", at: 0)
        let (store, _) = fixture(clipsOnA: [m])
        let snapshot = store.tracks

        let err = projectError { _ = try store.moveClips(ids: [m.id], byTracks: 99) }

        guard case .midiClipsRequireInstrumentTrack(let kind)? = err else {
            Issue.record("expected midiClipsRequireInstrumentTrack, got \(String(describing: err))")
            return
        }
        // THE discriminator: `.audio` (index 4, the clamped landing) and NOT
        // `.bus` (index 3, which a searching/stepping implementation would have
        // stopped at) and NOT an out-of-range error (which checking before
        // clamping would have produced). A bare `if case ...` without binding the
        // payload passes for all three.
        #expect(kind == .audio)
        #expect(store.tracks == snapshot)
    }

    // 6c.
    @Test("the clamp does NOT search: a landing 1 track down is refused where 2 down is accepted")
    func clampNeverSearches() throws {
        // `[audio A0, inst 1, audio 2, inst 3]` — §2.7's own example.
        let a = audio("A", at: 0)
        let store = ProjectStore(tracks: [
            Track(name: "A0", kind: .audio, clips: [a]),
            Track(name: "I1", kind: .instrument),
            Track(name: "A2", kind: .audio),
            Track(name: "I3", kind: .instrument),
        ])
        // 1 down lands on an instrument track → refused. No search rescues it.
        let err = projectError { _ = try store.moveClips(ids: [a.id], byTracks: 1) }
        guard case .trackKindUnsupported? = err else {
            Issue.record("expected trackKindUnsupported, got \(String(describing: err))")
            return
        }
        #expect(trackIndex(store, of: a.id) == 0)
        // 2 down lands on an audio track → accepted. Both answers are right; no
        // search bridges them.
        _ = try store.moveClips(ids: [a.id], byTracks: 2)
        #expect(trackIndex(store, of: a.id) == 2)
    }

    // MARK: - 7. The SAME overlap path, not a second one

    // 7.
    @Test("SAME OVERLAP PATH: an identical window through moveClip and through the cross-track verb agree")
    func sameOverlapPathAsMoveClip() throws {
        // The two stores hold clips with the SAME ids and the SAME values, so the
        // resident can be compared as a WHOLE `Clip`. Asserting the trim rule
        // twice would be weaker than asserting the two paths agree.
        // Built ONCE and reused as VALUES, so even the MIDI note ids match: any
        // difference the comparison reports is then a difference the two CODE
        // PATHS produced, not one the fixture minted.
        let resident = Clip(
            name: "R", startBeat: 0, lengthBeats: 8,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2),
                    MIDINote(pitch: 62, startBeat: 4, lengthBeats: 2),
                    MIDINote(pitch: 64, startBeat: 6.5, lengthBeats: 1)],
            startOffsetSeconds: 0.25, gainDb: -3,
            fadeInBeats: 1, fadeOutBeats: 2, fadeInCurve: .equalPower,
            gainEnvelope: [ClipGainPoint(beat: 0, gainDb: 0),
                           ClipGainPoint(beat: 7, gainDb: -6)],
            controllerLanes: [MIDIControllerLane(
                type: .cc(controller: 1),
                points: [MIDIControllerPoint(beat: 0, value: 10),
                         MIDIControllerPoint(beat: 5, value: 100)])])
        let mover = midi("M", at: 12, length: 4)
        let residentID = resident.id
        let moverID = mover.id

        // Path 1 — SAME track, through `moveClip`: the mover lands at beat 6.
        let sameTrack = ProjectStore(tracks: [
            Track(name: "One", kind: .instrument, clips: [resident, mover]),
        ])
        let sameResult = try sameTrack.moveClip(trackId: sameTrack.tracks[0].id,
                                                clipId: moverID, toStartBeat: 6)

        // Path 2 — CROSS track: the mover starts on a different track and lands on
        // the resident's track at the same beat 6 (12 - 6), one track down.
        let crossTrack = ProjectStore(tracks: [
            Track(name: "Src", kind: .instrument, clips: [mover]),
            Track(name: "Dst", kind: .instrument, clips: [resident]),
        ])
        let crossResult = try crossTrack.moveClips(ids: [moverID], byTracks: 1, byBeats: -6)

        let residentA = try #require(sameTrack.tracks[0].clips.first { $0.id == residentID })
        let residentB = try #require(crossTrack.tracks[1].clips.first { $0.id == residentID })
        // Whole-value equality: start, length, startOffsetSeconds, surviving
        // notes, fades + curves, gain envelope and controller lanes all at once.
        #expect(residentA == residentB)
        // Calibration: the resident really WAS edited, so equality is not the
        // trivial "neither path did anything".
        #expect(residentA.lengthBeats == 6)
        #expect(residentA.notes?.count == 2)
        #expect(sameResult.trimmedClipIDs == [residentID])
        #expect(crossResult.trimmedClipIDs == [residentID])
        #expect(crossResult.removedClipIDs.isEmpty)
        // And the mover itself landed identically in both.
        #expect(clip(sameTrack, moverID) == clip(crossTrack, moverID))
    }

    // MARK: - 8. Take members on the destination STACK

    // 8.
    @Test("take members on the DESTINATION are exempt: the mover STACKS over them")
    func destinationTakeMembersStack() throws {
        let t1 = midi("T1", at: 0, length: 8)
        let t2 = midi("T2", at: 0, length: 8)
        let mover = midi("M", at: 0, length: 4)
        let (store, tracks) = fixture(clipsOnA: [mover], clipsOnB: [t1, t2])
        _ = try store.groupTakes(trackId: tracks[1].id, clipIds: [t1.id, t2.id])
        let membersBefore = store.tracks[1].clips.filter { $0.takeGroupID != nil }
        #expect(!membersBefore.isEmpty)

        let result = try store.moveClips(ids: [mover.id], byTracks: 1)

        // Inherited verbatim from `duplicateClip`: comp members intentionally
        // stack rather than being trimmed.
        let membersAfter = store.tracks[1].clips.filter { $0.takeGroupID != nil }
        #expect(membersAfter == membersBefore)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(trackIndex(store, of: mover.id) == 1)
        // The mover really does overlap them — otherwise the exemption is untested.
        #expect(membersBefore.contains { $0.startBeat < 4 && $0.startBeat + $0.lengthBeats > 0 })
    }

    // MARK: - 9. The combined (diagonal) move

    // 9a.
    @Test("COMBINED: down 1 and along 4 in ONE journal entry, both axes applied")
    func combinedMove() throws {
        let x = midi("X", at: 0)
        let y = midi("Y", at: 8)
        let (store, _) = fixture(clipsOnA: [x], clipsOnB: [y])
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], byTracks: 1, byBeats: 4)

        #expect(result.effectiveTrackDelta == 1)
        #expect(result.effectiveDeltaBeats == 4)
        #expect(trackIndex(store, of: x.id) == 1)
        #expect(trackIndex(store, of: y.id) == 2)
        #expect(clip(store, x.id)?.startBeat == 4)
        #expect(clip(store, y.id)?.startBeat == 12)
        // ONE undo step for a diagonal gesture — the reason `byBeats` rides along.
        #expect(undoDepth(store) - depth == 1)
    }

    // 9b.
    @Test("COMBINED with the BEAT-0 wall: the vertical move still happens, offsets survive")
    func combinedMoveHitsBeatWall() throws {
        let x = midi("X", at: 0)
        let y = midi("Y", at: 8)
        let (store, _) = fixture(clipsOnA: [x], clipsOnB: [y])
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], byTracks: 1, byBeats: -8)

        #expect(result.clamped)                 // the horizontal request was reduced
        #expect(result.effectiveDeltaBeats == 0)
        #expect(!result.clampedTracks)          // …and the vertical one was NOT
        #expect(result.effectiveTrackDelta == 1)
        // Both axes report independently, and the group kept BOTH sets of offsets.
        #expect(clip(store, x.id)?.startBeat == 0)
        #expect(clip(store, y.id)?.startBeat == 8)
        #expect(trackIndex(store, of: x.id) == 1)
        #expect(trackIndex(store, of: y.id) == 2)
        #expect(undoDepth(store) - depth == 1)
    }

    // MARK: - 10/11/12. The `.toTrack` shape

    // 10.
    @Test("toTrack COLLAPSES a 2-track group onto one track in ONE journal entry")
    func toTrackCollapses() throws {
        let x = midi("X", at: 0)
        let y = midi("Y", at: 8)
        let (store, tracks) = fixture(clipsOnA: [x], clipsOnB: [y])
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], toTrackId: tracks[2].id)

        #expect(result.landings.allSatisfy { $0.toTrackID == tracks[2].id })
        #expect(result.landings.map(\.fromTrackID) == [tracks[0].id, tracks[1].id])
        // A destination-shaped move has NO delta — reporting 0 would be
        // indistinguishable from "the clamp reduced it to nothing".
        #expect(result.requestedTrackDelta == nil)
        #expect(result.effectiveTrackDelta == nil)
        #expect(!result.clampedTracks)
        #expect(trackIndex(store, of: x.id) == 2)
        #expect(trackIndex(store, of: y.id) == 2)
        // Relative BEAT offsets survive; relative TRACK offsets are destroyed BY
        // CONSTRUCTION, which is what "collapses" means.
        let xStart = try #require(clip(store, x.id)?.startBeat)
        let yStart = try #require(clip(store, y.id)?.startBeat)
        #expect(yStart - xStart == 8)
        #expect(undoDepth(store) - depth == 1)
        #expect(store.undoHistory().undo.first == "Move 2 Clips to 'C'")
    }

    // 11.
    @Test("toTrack VALIDATES ITS DESTINATION even when ids is empty — controlled pair")
    func toTrackValidatesWithEmptyIDs() throws {
        let (store, tracks) = fixture()
        let depth = undoDepth(store)

        // Failure half: an unknown track id refuses immediately rather than
        // succeeding silently, so an agent that typo'd learns at once.
        let err = projectError { _ = try store.moveClips(ids: [], toTrackId: UUID()) }
        if case .trackNotFound? = err {} else {
            Issue.record("expected trackNotFound, got \(String(describing: err))")
        }

        // Success half: the SAME empty-ids call with a KNOWN track is a pure
        // no-op. Without it the failure half could be about emptiness.
        let ok = try store.moveClips(ids: [], toTrackId: tracks[0].id)
        #expect(ok.clips.isEmpty)
        #expect(ok.landings.isEmpty)
        #expect(undoDepth(store) == depth)

        // `.byTracks` with empty ids is a pure no-op too — an `Int` cannot be
        // invalid, so there is nothing to validate.
        let byTracks = try store.moveClips(ids: [], byTracks: 3)
        #expect(byTracks.requestedTrackDelta == 3)
        #expect(byTracks.effectiveTrackDelta == 0)
        #expect(byTracks.clips.isEmpty)
        #expect(undoDepth(store) == depth)
    }

    // 12.
    @Test("ARRAY SLOTS: a mover already on the destination keeps its slot; arrivals append")
    func arraySlotsSurvive() throws {
        let resident = midi("R", at: 20)
        let staying = midi("S", at: 8)
        let arriving = midi("T", at: 0)
        // Destination track B holds [S, R] in that order; S is a MOVER already on
        // the destination and must not be shuffled to the end just because its
        // sibling arrived.
        let (store, tracks) = fixture(clipsOnA: [arriving], clipsOnB: [staying, resident])

        let result = try store.moveClips(ids: [arriving.id, staying.id], toTrackId: tracks[1].id)

        #expect(store.tracks[1].clips.map(\.name) == ["S", "R", "T"])
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        // The mover that did not change track still reports a landing (from == to).
        #expect(result.landings.contains(ClipLanding(clipID: staying.id,
                                                     fromTrackID: tracks[1].id,
                                                     toTrackID: tracks[1].id)))
        // …and `clips` comes back in the CALLER's unique id order, not array order.
        #expect(result.clips.map(\.id) == [arriving.id, staying.id])
    }

    // MARK: - 13. Agreement with the horizontal verb

    // 13.
    @Test("EQUIVALENCE: byTracks 0 produces exactly what moveClips(ids:byBeats:) produces")
    func zeroTrackDeltaMatchesHorizontalVerb() throws {
        // Both stores are built from the SAME `Track` VALUES (same track ids, same
        // clip ids), so `tracks` is directly comparable afterwards.
        let x = midi("X", at: 4)
        let y = midi("Y", at: 6)
        let resident = midi("R", at: 8)
        let shape = [
            Track(id: UUID(), name: "A", kind: .instrument, clips: [x, resident]),
            Track(id: UUID(), name: "B", kind: .instrument, clips: [y]),
        ]
        let horizontal = ProjectStore(tracks: shape)
        let vertical = ProjectStore(tracks: shape)

        let h = try horizontal.moveClips(ids: [x.id, y.id], byBeats: 3)
        let v = try vertical.moveClips(ids: [x.id, y.id], byTracks: 0, byBeats: 3)

        #expect(horizontal.tracks == vertical.tracks)
        #expect(h.effectiveDeltaBeats == v.effectiveDeltaBeats)
        #expect(h.clamped == v.clamped)
        #expect(h.trimmedClipIDs == v.trimmedClipIDs)
        #expect(h.removedClipIDs == v.removedClipIDs)
        #expect(h.clips == v.clips)
        // Calibration: the run really did resolve an overlap, so the equality is
        // not "both did nothing".
        #expect(!h.trimmedClipIDs.isEmpty)
        // Same journal label (the `.unchanged` row) AND the same coalescing key,
        // so a horizontal press and a vertical press fold into ONE undo entry.
        #expect(horizontal.undoHistory().undo.first == vertical.undoHistory().undo.first)
        let depth = undoDepth(vertical)
        _ = try vertical.moveClips(ids: [x.id, y.id], byBeats: 1)
        #expect(undoDepth(vertical) == depth)
    }

    // MARK: - 14. Mixed audio + MIDI — the controlled pair

    // 14.
    @Test("MIXED-KIND group: 2 tracks down succeeds, 1 track down refuses — CONTROLLED PAIR")
    func mixedKindControlledPair() throws {
        // `[audio, inst, audio, inst]` — the one layout where a mixed group CAN
        // move vertically, so the failure half can only be about KINDS.
        func store() -> (ProjectStore, Clip, Clip) {
            let a = audio("A", at: 0)
            let m = midi("M", at: 0)
            let s = ProjectStore(tracks: [
                Track(name: "A0", kind: .audio, clips: [a]),
                Track(name: "I1", kind: .instrument, clips: [m]),
                Track(name: "A2", kind: .audio),
                Track(name: "I3", kind: .instrument),
            ])
            return (s, a, m)
        }

        // SUCCESS half: 2 down lines both kinds up (audio 0→2, MIDI 1→3).
        let (ok, okAudio, okMIDI) = store()
        let depth = undoDepth(ok)
        let result = try ok.moveClips(ids: [okAudio.id, okMIDI.id], byTracks: 2)
        #expect(result.effectiveTrackDelta == 2)
        #expect(trackIndex(ok, of: okAudio.id) == 2)
        #expect(trackIndex(ok, of: okMIDI.id) == 3)
        #expect(undoDepth(ok) - depth == 1)

        // FAILURE half: 1 down does not (audio 0→1 is an instrument track).
        let (bad, badAudio, badMIDI) = store()
        let snapshot = bad.tracks
        let err = projectError { _ = try bad.moveClips(ids: [badAudio.id, badMIDI.id], byTracks: 1) }
        guard case .trackKindUnsupported(let kind)? = err else {
            Issue.record("expected trackKindUnsupported, got \(String(describing: err))")
            return
        }
        #expect(kind == .instrument)
        #expect(bad.tracks == snapshot)
    }

    // MARK: - Contract carry-overs

    // 15.
    @Test("an unknown id throws clipNotFound and moves nothing; duplicates collapse")
    func unknownIDAndDuplicates() throws {
        let (store, _, x, y) = overlappingPair()
        let snapshot = store.tracks
        let err = projectError { _ = try store.moveClips(ids: [x.id, UUID()], byTracks: 1) }
        if case .clipNotFound? = err {} else {
            Issue.record("expected clipNotFound, got \(String(describing: err))")
        }
        #expect(store.tracks == snapshot)

        // Duplicates collapse: the result lists each clip once, and the clip does
        // not move twice.
        let result = try store.moveClips(ids: [x.id, x.id, y.id], byTracks: 1)
        #expect(result.clips.map(\.id) == [x.id, y.id])
        #expect(result.landings.count == 2)
        #expect(trackIndex(store, of: x.id) == 1)
    }

    // 16.
    @Test("IDENTITY is preserved — this is a MOVE, so `reidentified` is not on the path")
    func identityAndPayloadTravel() throws {
        let m = Clip(name: "M", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)],
                     gainDb: -4, fadeInBeats: 1, fadeOutBeats: 1,
                     gainEnvelope: [ClipGainPoint(beat: 0, gainDb: 0),
                                    ClipGainPoint(beat: 3, gainDb: -8)],
                     controllerLanes: [MIDIControllerLane(
                        type: .cc(controller: 1),
                        points: [MIDIControllerPoint(beat: 0, value: 5),
                                 MIDIControllerPoint(beat: 2, value: 90)])])
        let (store, _) = fixture(clipsOnA: [m])

        _ = try store.moveClips(ids: [m.id], byTracks: 2, byBeats: 4)

        let moved = try #require(clip(store, m.id))
        #expect(moved.id == m.id)                       // a fresh id would break every selection
        #expect(moved.startBeat == 4)                   // the ONLY field that changed
        #expect(moved.name == m.name)
        #expect(moved.notes == m.notes)
        #expect(moved.gainDb == m.gainDb)
        #expect(moved.fadeInBeats == m.fadeInBeats)
        #expect(moved.fadeOutBeats == m.fadeOutBeats)
        #expect(moved.gainEnvelope == m.gainEnvelope)
        #expect(moved.controllerLanes == m.controllerLanes)
    }

    // 17.
    @Test("UNDO restores the whole cross-track move, including the resident trim, in ONE step")
    func undoRestoresEverything() throws {
        let mover = midi("M", at: 0, length: 4)
        let resident = midi("R", at: 2, length: 8)
        let (store, _) = fixture(clipsOnA: [mover], clipsOnB: [resident])
        let before = store.tracks

        let result = try store.moveClips(ids: [mover.id], byTracks: 1)
        #expect(result.trimmedClipIDs == [resident.id])
        #expect(trackIndex(store, of: mover.id) == 1)

        _ = try store.undo()
        #expect(store.tracks == before)
    }

    // 18.
    @Test("a single-clip cross-track move labels the DESTINATION and coalesces on the moveClip key")
    func singleClipLabelAndKey() throws {
        let m = midi("M", at: 0)
        let (store, _) = fixture(clipsOnA: [m])
        let depth = undoDepth(store)

        _ = try store.moveClips(ids: [m.id], byTracks: 1)
        #expect(store.undoHistory().undo.first == "Move Clip 'M' to 'B'")
        #expect(undoDepth(store) - depth == 1)

        // The key is `moveClipsKey(ids:)` UNCHANGED, so a second press on the same
        // selection folds into the SAME entry rather than costing a second undo.
        _ = try store.moveClips(ids: [m.id], byTracks: 1)
        #expect(trackIndex(store, of: m.id) == 2)
        #expect(undoDepth(store) - depth == 1)
    }

    // MARK: - 19..23. The MANUFACTURED collision (phase 2b', design §18)

    // 19. Was an ORCHESTRATOR PROBE, deliberately red; REWRITTEN under the §18.3
    // ruling rather than deleted or loosened. The case `.toTrack` can create and
    // the horizontal verb structurally cannot: two movers from DIFFERENT tracks
    // collapsing onto the SAME beats. Both are in `activeIDs`, and `activeIDs`
    // members are exempt from trimming each other, so before the fix the two
    // ORDINARY clips silently stacked — the no-silent-overlap invariant
    // (m11-d/m13-b) failing inside the verb built to route through its choke
    // point. Policy (b): refuse the WHOLE move before any mutation.
    //
    // "They do not overlap afterwards" would NOT pin this — policy (a) (movers
    // trimming each other) satisfies that too, and (a) is what §18.6 rejected
    // because it decides which of the user's own clips dies by `uuidString`.
    @Test("COLLAPSE COLLISION: two movers manufacturing an overlap REFUSE the whole move")
    func collapseCollisionRefusesWholeMove() throws {
        let x = midi("X", at: 0)
        let y = midi("Y", at: 0)          // same beats, different source track
        let (store, tracks) = fixture(clipsOnA: [x], clipsOnB: [y])

        let snapshot = store.tracks
        let depth = undoDepth(store)
        let err = projectError {
            _ = try store.moveClips(ids: [x.id, y.id], toTrackId: tracks[2].id)
        }

        guard case .clipsWouldOverlapOnDestination(let f, let fn, let s, let sn)? = err else {
            Issue.record("expected clipsWouldOverlapOnDestination, got \(String(describing: err))")
            return
        }
        // The ORDER, not just the set: `checkOrder` is (source track, source
        // clip), X is on track 0 and Y on track 1, so X is `first`. Accepting
        // either orientation would silently permit `resolvingGroupOverlaps`'
        // landing sort (start, then `uuidString`), which §18.6(2) refuses to put
        // anything user-visible on.
        #expect(f == x.id)
        #expect(fn == "X")
        #expect(s == y.id)
        #expect(sn == "Y")
        // Ids are in the payload BECAUSE names are not unique — the message must
        // stay actionable when both clips are called the same thing.
        #expect(err?.errorDescription?.contains(x.id.uuidString) == true)
        #expect(err?.errorDescription?.contains(y.id.uuidString) == true)
        // Refused WHOLE and BEFORE any mutation: the entire array, not just the
        // two movers, and no undo slot consumed.
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
        #expect(!store.isDirty)
    }

    // 20. Was an ORCHESTRATOR PROBE, deliberately red; REWRITTEN under §18.3. The
    // same defect reached WITHOUT the colliding mover ever crossing. X already
    // sits on the destination, so it is non-crossing and keeps its array slot —
    // but it is still in `activeIDs` for that destination, so the arriving Y
    // cannot trim it. THIS is the leg a check that copies phase 2b's
    // `where crossing[i]` filter fails (§18.4(i)); everything else passes under
    // that bug.
    @Test("COLLAPSE COLLISION: a NON-CROSSING mover on the destination collides too")
    func collapseCollisionIncludesNonCrossingMover() throws {
        let x = midi("X", at: 0)          // already on C, the destination
        let y = midi("Y", at: 0)          // on B, will cross onto C
        let (store, tracks) = fixture(clipsOnB: [y], clipsOnC: [x])

        let snapshot = store.tracks
        let depth = undoDepth(store)
        let err = projectError {
            _ = try store.moveClips(ids: [x.id, y.id], toTrackId: tracks[2].id)
        }

        guard case .clipsWouldOverlapOnDestination(let f, let fn, let s, let sn)? = err else {
            Issue.record("expected clipsWouldOverlapOnDestination, got \(String(describing: err))")
            return
        }
        // Y is reported FIRST even though the CALLER listed X first: Y is on
        // track 1 and X on track 2, so `checkOrder` visits Y first. Caller order
        // and report order DISAGREE here, which is what makes this leg the
        // determinism witness rather than an accident of argument order.
        #expect(f == y.id)
        #expect(fn == "Y")
        #expect(s == x.id)
        #expect(sn == "X")
        #expect(store.tracks == snapshot)
        #expect(undoDepth(store) == depth)
        #expect(!store.isDirty)
    }

    // 21.
    @Test("ABUTMENT SUCCEEDS: [0,4) and [4,8) from two source tracks collapse onto one")
    func abuttingMoversCollapseSuccessfully() throws {
        // THE `<` vs `<=` witness, and the only one in the suite: with a relaxed
        // interval test this legal collapse is refused and nothing else notices.
        // Half-open windows that touch at a shared edge are ADJACENT, not
        // overlapping — `resolveOverlap`'s own rule (ProjectStore.swift:4686-4687).
        let x = midi("X", at: 0, length: 4)
        let y = midi("Y", at: 4, length: 4)
        let (store, tracks) = fixture(clipsOnA: [x], clipsOnB: [y])
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], toTrackId: tracks[2].id)

        #expect(trackIndex(store, of: x.id) == 2)
        #expect(trackIndex(store, of: y.id) == 2)
        #expect(clip(store, x.id)?.startBeat == 0)
        #expect(clip(store, y.id)?.startBeat == 4)
        #expect(clip(store, x.id)?.lengthBeats == 4)
        #expect(clip(store, y.id)?.lengthBeats == 4)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(undoDepth(store) - depth == 1)
    }

    // 22.
    @Test("CROSS-SOURCE, NON-COLLIDING: differing source tracks ALONE must not refuse")
    func crossSourceNonCollidingStillCollapses() throws {
        // The controlled half of leg 19: same two source tracks, same
        // destination, only the beats differ. This is leg 10's geometry, kept
        // HERE for locality beside the refusal it controls rather than as new
        // coverage — §18.1's reusable lesson is that leg 10 was disjoint, so it
        // could never have seen the collision in the first place.
        let x = midi("X", at: 0)
        let y = midi("Y", at: 8)
        let (store, tracks) = fixture(clipsOnA: [x], clipsOnB: [y])
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], toTrackId: tracks[2].id)

        #expect(trackIndex(store, of: x.id) == 2)
        #expect(trackIndex(store, of: y.id) == 2)
        #expect(clip(store, x.id)?.startBeat == 0)
        #expect(clip(store, y.id)?.startBeat == 8)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(undoDepth(store) - depth == 1)
    }

    // 23.
    @Test("GRANDFATHER (.toTrack): a sanctioned crossfade pair is NOT a manufactured collision")
    func grandfatheredCrossfadePairOnToTrack() throws {
        // THE QUALIFIER WITNESS (`sources[i] != sources[j]`), on the `.toTrack`
        // path. P and Q overlap ALREADY — the shape a sanctioned audio crossfade
        // pair has (ProjectStore.swift:4028-4032) — and the move does not
        // manufacture that, it carries it along rigidly. Both movers share
        // destination E, so phase 2b' RUNS on this pair and the same-source
        // qualifier is the only thing letting it through. Without this leg,
        // policy (b) is indistinguishable from "refuse ANY mover overlap".
        //
        // Track E (index 4) is the fixture's ONE audio track, and that is
        // load-bearing: A/C are INSTRUMENT tracks, so an audio pair aimed at them
        // would be refused by phase 2b's kind check before 2b' is ever reached
        // and this leg would redden for entirely the wrong reason.
        //
        // `byBeats: 4` is load-bearing too: both movers are non-crossing, so with
        // a zero beat delta phase 2d would return before `performEdit` and this
        // would prove nothing about a real edit.
        let p = audio("P", at: 0, length: 4)
        let q = audio("Q", at: 3, length: 4)
        let (store, tracks) = fixture(clipsOnE: [p, q])
        // Calibration: they really do overlap before the move.
        #expect(p.startBeat < q.startBeat + q.lengthBeats)
        #expect(q.startBeat < p.startBeat + p.lengthBeats)
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [p.id, q.id], toTrackId: tracks[4].id, byBeats: 4)

        #expect(clip(store, p.id)?.startBeat == 4)
        #expect(clip(store, q.id)?.startBeat == 7)
        // Rigid: the crossfade geometry survives intact, so the pair is still a
        // crossfade pair afterwards.
        #expect(clip(store, p.id)?.lengthBeats == 4)
        #expect(clip(store, q.id)?.lengthBeats == 4)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(undoDepth(store) - depth == 1)
    }

    // 24.
    @Test("GRANDFATHER (byTracks): the crossfade pair carried DOWN a track, still whole")
    func grandfatheredCrossfadePairOnByTracks() throws {
        // THE SAME QUALIFIER WITNESS on the OTHER path, and it is the one that
        // matters in production: this is the gesture m23-aj-3's ↑/↓ nudge emits.
        // Drop the qualifier and the nudge refuses to move a crossfaded pair at
        // ALL — a straight regression against a configuration the tree calls
        // legal today (§18.4(ii)).
        //
        // LEG-LOCAL `[audio, audio]` fixture, following leg 14's precedent: the
        // shared fixture has exactly ONE audio track, so `byTracks: +1` from it
        // clamps to a no-op and `-1` lands on the bus. Neither is a real
        // cross-track carry.
        let p = audio("P", at: 0, length: 4)
        let q = audio("Q", at: 3, length: 4)
        let store = ProjectStore(tracks: [
            Track(name: "A0", kind: .audio, clips: [p, q]),
            Track(name: "A1", kind: .audio),
        ])
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [p.id, q.id], byTracks: 1)

        #expect(trackIndex(store, of: p.id) == 1)
        #expect(trackIndex(store, of: q.id) == 1)
        #expect(clip(store, p.id)?.startBeat == 0)
        #expect(clip(store, q.id)?.startBeat == 3)
        #expect(clip(store, p.id)?.lengthBeats == 4)
        #expect(clip(store, q.id)?.lengthBeats == 4)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(undoDepth(store) - depth == 1)
    }

    // 25.
    @Test("byTracks NEVER REFUSES: genuinely overlapping movers from two tracks still carry down")
    func byTracksCannotManufactureACollision() throws {
        // INJECTIVITY, AS A MEASUREMENT rather than a comment (§18.5(1)):
        // `destination = source + effectiveTrackDelta` with a single whole-group
        // `Int` is injective on source track index, so two movers share a
        // destination IFF they shared a source. Phase 2b' EVALUATES here and can
        // never REFUSE here.
        //
        // A DIFFERENT WITNESS FROM LEGS 23/24, AND NEITHER SUBSUMES THE OTHER:
        // those two reach the same-source qualifier and are let through BY it;
        // this pair is excluded EARLIER, by the `destinations[i] == destinations[j]`
        // filter, and never consults the qualifier at all. Deleting the qualifier
        // leaves this leg green; deleting the destination filter leaves 23/24
        // green.
        //
        // Deliberately legs 1/2's geometry (X [0,4) on A, Y [2,6) on B — they
        // really do overlap), retained here as the named injectivity witness;
        // legs 1/2 assert rigidity and the vacate-before-land mechanic, not this.
        let (store, _, x, y) = overlappingPair()
        #expect(x.startBeat < y.startBeat + y.lengthBeats)
        #expect(y.startBeat < x.startBeat + x.lengthBeats)
        let depth = undoDepth(store)

        let result = try store.moveClips(ids: [x.id, y.id], byTracks: 1)

        #expect(trackIndex(store, of: x.id) == 1)
        #expect(trackIndex(store, of: y.id) == 2)
        #expect(clip(store, x.id)?.startBeat == 0)
        #expect(clip(store, y.id)?.startBeat == 2)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(undoDepth(store) - depth == 1)
    }

    // 26.
    @Test("errorDescription for clipsWouldOverlapOnDestination is pinned BYTE-EXACT (the m23-aj-2 debt)")
    func collapseCollisionErrorDescriptionIsByteExact() throws {
        // m23-aj-1's leg 19 (above) only asserts that both UUIDs APPEAR in the
        // message — it never pins the surrounding wording. That is deliberately
        // owed to m23-aj-2: the control protocol and MCP surface this string
        // VERBATIM (no wire-side mapping, `Commands.swift`'s blanket
        // `LocalizedError` arm), so a future rewording of the sentence would
        // drift the contract silently unless SOMETHING in the tree compares it
        // character-for-character. This is that something. Fixed UUIDs (not
        // `UUID()`) are what make a byte-exact literal possible at all.
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let x = midi("X", at: 0, id: firstID)
        let y = midi("Y", at: 0, id: secondID)          // same beats, different source track
        let (store, tracks) = fixture(clipsOnA: [x], clipsOnB: [y])

        let err = projectError {
            _ = try store.moveClips(ids: [x.id, y.id], toTrackId: tracks[2].id)
        }

        guard case .clipsWouldOverlapOnDestination? = err else {
            Issue.record("expected clipsWouldOverlapOnDestination, got \(String(describing: err))")
            return
        }
        // Byte-exact against `MediaImporting.swift`'s `errorDescription` for
        // this case, built from the SAME literal fragments so a future edit to
        // either side shows up as a diff here rather than a silent drift.
        let expected = "clips 'X' (11111111-1111-1111-1111-111111111111) and 'Y'"
            + " (22222222-2222-2222-2222-222222222222) would overlap on the destination track — moving several tracks'"
            + " clips onto one track needs them at different beats (move them one at a time, or use"
            + " clip.moveManyByTracks to keep them on separate tracks)"
        #expect(err?.errorDescription == expected)
    }
}
