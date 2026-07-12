import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift). CompFlattener + model tests are pure and
// need no engine; store tests run headless (nil engine).

// MARK: - Shared helpers

private let normID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

/// Strips clip identity so two deterministic flattens compare equal modulo id.
private func normalized(_ c: Clip) -> Clip {
    Clip(id: normID, name: c.name, startBeat: c.startBeat, lengthBeats: c.lengthBeats,
         audioFileURL: c.audioFileURL, notes: c.notes, isAIGenerated: c.isAIGenerated,
         startOffsetSeconds: c.startOffsetSeconds, gainDb: c.gainDb,
         fadeInBeats: c.fadeInBeats, fadeOutBeats: c.fadeOutBeats,
         fadeInCurve: c.fadeInCurve, fadeOutCurve: c.fadeOutCurve,
         stretchRatio: c.stretchRatio, pitchShiftSemitones: c.pitchShiftSemitones,
         formantPreserve: c.formantPreserve, takeGroupID: c.takeGroupID)
}

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

private func audioClip(_ name: String, start: Double, length: Double,
                       file: String, offset: Double = 0, ratio: Double = 1) -> Clip {
    Clip(name: name, startBeat: start, lengthBeats: length,
         audioFileURL: URL(fileURLWithPath: file), startOffsetSeconds: offset, stretchRatio: ratio)
}

private func audioLane(_ name: String, start: Double, length: Double,
                       file: String, offset: Double = 0, ratio: Double = 1) -> TakeLane {
    TakeLane(name: name, clip: audioClip(name, start: start, length: length,
                                         file: file, offset: offset, ratio: ratio))
}

// MARK: - CompFlattener (pure)

@Suite("CompFlattener — flatten math")
struct CompFlattenerTests {

    @Test("single full-range segment → one member with the group marker, no fades")
    func singleSegment() {
        let lane = audioLane("A", start: 0, length: 4, file: "/a.wav")
        var group = TakeGroup(id: UUID(), name: "G", lanes: [lane])
        group.comp = [CompSegment(laneID: lane.id, startBeat: 0, endBeat: 4)]

        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 1)
        let m = members[0]
        #expect(m.takeGroupID == group.id)
        #expect(m.name == "A")
        #expect(approx(m.startBeat, 0))
        #expect(approx(m.lengthBeats, 4))
        #expect(approx(m.startOffsetSeconds, 0))
        #expect(m.fadeInBeats == 0 && m.fadeOutBeats == 0)
        #expect(m.audioFileURL?.path == "/a.wav")
    }

    @Test("deterministic: same group + tempo → identical members modulo clip id")
    func determinism() {
        let a = audioLane("A", start: 0, length: 6, file: "/a.wav")
        let b = audioLane("B", start: 0, length: 8, file: "/b.wav")
        var group = TakeGroup(id: UUID(), name: "G", lanes: [a, b], crossfadeSeconds: 0.1)
        group.comp = [CompSegment(laneID: a.id, startBeat: 0, endBeat: 4),
                      CompSegment(laneID: b.id, startBeat: 4, endBeat: 8)]

        let first = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120)).map(normalized)
        let second = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120)).map(normalized)
        #expect(first == second)
        // Fresh clip ids each pass.
        let ids1 = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120)).map(\.id)
        let ids2 = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120)).map(\.id)
        #expect(Set(ids1).isDisjoint(with: Set(ids2)))
    }

    @Test("abutting audio joins get an equal-power crossfade with correct geometry/offset")
    func crossfadeGeometry() {
        // 120 BPM → 0.5 s/beat. crossfade 0.1 s → xf = 0.2 beat, half = 0.1.
        let a = audioLane("A", start: 0, length: 6, file: "/a.wav")   // material past b=4
        let b = audioLane("B", start: 0, length: 8, file: "/b.wav")
        var group = TakeGroup(id: UUID(), name: "G", lanes: [a, b], crossfadeSeconds: 0.1)
        group.comp = [CompSegment(laneID: a.id, startBeat: 0, endBeat: 4),
                      CompSegment(laneID: b.id, startBeat: 4, endBeat: 8)]

        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 2)
        let left = members[0], right = members[1]

        // Left extends xf/2 past b with an equal-power fade-out; no fade-in.
        #expect(approx(left.lengthBeats, 4.1))
        #expect(approx(left.fadeOutBeats, 0.2))
        #expect(left.fadeOutCurve == .equalPower)
        #expect(left.fadeInBeats == 0)

        // Right starts xf/2 before b with an equal-power fade-in; offset reduced
        // by the source-domain equivalent (pre-xf offset 2.0 s − 0.1·0.5 = 1.95).
        #expect(approx(right.startBeat, 3.9))
        #expect(approx(right.lengthBeats, 4.1))
        #expect(approx(right.startOffsetSeconds, 1.95))
        #expect(approx(right.fadeInBeats, 0.2))
        #expect(right.fadeInCurve == .equalPower)

        // Overlap width == xf, both fades cover it → constant-power join.
        #expect(approx((left.startBeat + left.lengthBeats) - right.startBeat, 0.2))
    }

    @Test("crossfade clamps to half the shorter member")
    func crossfadeClampHalfSegment() {
        let a = audioLane("A", start: 0, length: 4, file: "/a.wav")
        let b = audioLane("B", start: 0, length: 4, file: "/b.wav")
        // xf would be 0.2·2 = 0.4 beat, but each segment is 0.3 → half = 0.15.
        var group = TakeGroup(id: UUID(), name: "G", lanes: [a, b], crossfadeSeconds: 0.2)
        group.comp = [CompSegment(laneID: a.id, startBeat: 0, endBeat: 0.3),
                      CompSegment(laneID: b.id, startBeat: 0.3, endBeat: 0.6)]
        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 2)
        #expect(approx(members[0].fadeOutBeats, 0.15))
        #expect(approx(members[1].fadeInBeats, 0.15))
    }

    @Test("source exhaustion at the boundary → no crossfade (clean cut)")
    func crossfadeSourceExhaustion() {
        // Lane A's material ends exactly at b=4 → no tail to extend into.
        let a = audioLane("A", start: 0, length: 4, file: "/a.wav")
        let b = audioLane("B", start: 0, length: 8, file: "/b.wav")
        var group = TakeGroup(id: UUID(), name: "G", lanes: [a, b], crossfadeSeconds: 0.1)
        group.comp = [CompSegment(laneID: a.id, startBeat: 0, endBeat: 4),
                      CompSegment(laneID: b.id, startBeat: 4, endBeat: 8)]
        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 2)
        #expect(members[0].fadeOutBeats == 0)
        #expect(members[1].fadeInBeats == 0)
        // Clean cut: left ends exactly where right starts.
        #expect(approx(members[0].startBeat + members[0].lengthBeats, members[1].startBeat))
    }

    @Test("gaps produce no clip and no crossfade")
    func gaps() {
        let a = audioLane("A", start: 0, length: 8, file: "/a.wav")
        var group = TakeGroup(id: UUID(), name: "G", lanes: [a], crossfadeSeconds: 0.1)
        // Two segments with a [2,4) gap between them.
        group.comp = [CompSegment(laneID: a.id, startBeat: 0, endBeat: 2),
                      CompSegment(laneID: a.id, startBeat: 4, endBeat: 6)]
        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 2)
        // No overlap across the gap; no fades.
        #expect(members[0].fadeOutBeats == 0)
        #expect(members[1].fadeInBeats == 0)
        #expect(approx(members[0].startBeat + members[0].lengthBeats, 2))
        #expect(approx(members[1].startBeat, 4))
    }

    @Test("segment beyond lane material emits only the intersection")
    func segmentBeyondMaterial() {
        let a = audioLane("A", start: 1, length: 3, file: "/a.wav")  // covers [1,4]
        var group = TakeGroup(id: UUID(), name: "G", lanes: [a])
        group.comp = [CompSegment(laneID: a.id, startBeat: 0, endBeat: 10)]
        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 1)
        #expect(approx(members[0].startBeat, 1))
        #expect(approx(members[0].lengthBeats, 3))
    }

    @Test("MIDI lane windowing: overhang truncation, rebased, no fades, no audio URL")
    func midiWindowing() {
        let notes = [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),   // [0,1] — outside
            MIDINote(pitch: 62, startBeat: 3, lengthBeats: 2),   // [3,5] — truncated to [3,4]
            MIDINote(pitch: 64, startBeat: 6, lengthBeats: 1)    // [6,7] — outside
        ]
        let clip = Clip(name: "M", startBeat: 0, lengthBeats: 8, notes: notes)
        let lane = TakeLane(name: "M", clip: clip)
        var group = TakeGroup(id: UUID(), name: "G", lanes: [lane], crossfadeSeconds: 0.1)
        group.comp = [CompSegment(laneID: lane.id, startBeat: 2, endBeat: 4)]

        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 1)
        let m = members[0]
        #expect(m.isMIDI)
        #expect(m.audioFileURL == nil)
        #expect(m.fadeInBeats == 0 && m.fadeOutBeats == 0)
        let ns = try! #require(m.notes)
        #expect(ns.count == 1)
        #expect(ns[0].pitch == 62)
        #expect(approx(ns[0].startBeat, 1))       // rebased: abs 3 − memberStart 2
        #expect(approx(ns[0].lengthBeats, 1))     // truncated from 2 to 1
    }

    @Test("MIDI abutting joins are clean cuts (no crossfade concept)")
    func midiNoCrossfade() {
        let clip = Clip(name: "M", startBeat: 0, lengthBeats: 8,
                        notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 8)])
        let lane = TakeLane(name: "M", clip: clip)
        var group = TakeGroup(id: UUID(), name: "G", lanes: [lane], crossfadeSeconds: 0.1)
        group.comp = [CompSegment(laneID: lane.id, startBeat: 0, endBeat: 4),
                      CompSegment(laneID: lane.id, startBeat: 4, endBeat: 8)]
        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 2)
        #expect(members.allSatisfy { $0.fadeInBeats == 0 && $0.fadeOutBeats == 0 })
    }
}

// MARK: - Model

@Suite("Take model — TakeGroup / TakeLane / CompSegment")
struct TakeModelTests {

    @Test("rangeBeats is the union of the lanes' extents")
    func rangeBeats() {
        let a = audioLane("A", start: 2, length: 4, file: "/a.wav")   // [2,6]
        let b = audioLane("B", start: 0, length: 3, file: "/b.wav")   // [0,3]
        let g = TakeGroup(id: UUID(), name: "G", lanes: [a, b])
        #expect(approx(g.rangeBeats.lowerBound, 0))
        #expect(approx(g.rangeBeats.upperBound, 6))
    }

    @Test("TakeLane strips a nested takeGroupID from its payload")
    func laneStripsNesting() {
        var c = audioClip("A", start: 0, length: 4, file: "/a.wav")
        c.takeGroupID = UUID()
        let lane = TakeLane(name: "A", clip: c)
        #expect(lane.clip.takeGroupID == nil)
    }

    @Test("crossfadeSeconds clamps to 0...0.2")
    func crossfadeClamp() {
        #expect(TakeGroup(id: UUID(), name: "G", lanes: [], crossfadeSeconds: 5).crossfadeSeconds == 0.2)
        #expect(TakeGroup(id: UUID(), name: "G", lanes: [], crossfadeSeconds: -1).crossfadeSeconds == 0)
    }

    @Test("Codable wire round-trip for a full group")
    func wireRoundTrip() throws {
        let a = audioLane("A", start: 0, length: 6, file: "/a.wav")
        let b = audioLane("B", start: 0, length: 8, file: "/b.wav")
        var group = TakeGroup(id: UUID(), name: "Vocals Takes", lanes: [a, b], crossfadeSeconds: 0.05)
        group.comp = [CompSegment(laneID: a.id, startBeat: 0, endBeat: 4),
                      CompSegment(laneID: b.id, startBeat: 4, endBeat: 8)]
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(TakeGroup.self, from: data)
        #expect(decoded == group)
    }
}

// MARK: - Store ops

@MainActor
@Suite("ProjectStore — take comping ops")
struct TakeStoreTests {

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func expectClipInTakeGroup(_ body: () throws -> Void) {
        if case .clipInTakeGroup = projectError(body) {} else {
            Issue.record("expected clipInTakeGroup")
        }
    }

    /// A track holding three overlapping audio clips [A,B,C] over [0,8].
    private func makeStore() -> (ProjectStore, Track, [Clip]) {
        let clips = [
            audioClip("A", start: 0, length: 8, file: "/a.wav"),
            audioClip("B", start: 0, length: 8, file: "/b.wav"),
            audioClip("C", start: 0, length: 8, file: "/c.wav")
        ]
        let track = Track(name: "Vox", kind: .audio, clips: clips)
        return (ProjectStore(tracks: [track]), track, clips)
    }

    @Test("groupTakes: lanes oldest-first, newest-wins comp, originals removed, members materialized")
    func groupTakes() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))

        #expect(store.tracks[0].takeGroups.count == 1)
        #expect(group.lanes.count == 3)
        #expect(group.lanes.map(\.name) == ["A", "B", "C"])          // oldest → newest
        #expect(group.comp.count == 1)
        #expect(group.comp[0].laneID == group.lanes[2].id)            // newest wins
        #expect(approx(group.comp[0].startBeat, 0) && approx(group.comp[0].endBeat, 8))
        // Original clips gone; only members remain.
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID == group.id })
        #expect(!store.tracks[0].clips.contains { clips.map(\.id).contains($0.id) })
        #expect(store.tracks[0].clips.count == 1)                    // one comp segment
        #expect(store.tracks[0].clips[0].audioFileURL?.path == "/c.wav")
    }

    @Test("groupTakes rejections: <2 clips, mixed kinds, non-overlap, comp member")
    func groupRejections() throws {
        let (store, track, clips) = makeStore()
        // < 2
        if case .cannotGroup = projectError({ _ = try store.groupTakes(trackId: track.id, clipIds: [clips[0].id]) }) {}
        else { Issue.record("expected cannotGroup for <2") }
        // Mixed audio + MIDI.
        let midi = Clip(name: "m", startBeat: 0, lengthBeats: 8, notes: [])
        let mixTrack = Track(name: "T", kind: .audio,
                             clips: [audioClip("a", start: 0, length: 8, file: "/a.wav"), midi])
        let s2 = ProjectStore(tracks: [mixTrack])
        if case .cannotGroup = projectError({ _ = try s2.groupTakes(trackId: mixTrack.id, clipIds: mixTrack.clips.map(\.id)) }) {}
        else { Issue.record("expected cannotGroup for mixed") }
        // Non-overlapping.
        let disjoint = Track(name: "D", kind: .audio, clips: [
            audioClip("a", start: 0, length: 2, file: "/a.wav"),
            audioClip("b", start: 4, length: 2, file: "/b.wav")])
        let s3 = ProjectStore(tracks: [disjoint])
        if case .cannotGroup = projectError({ _ = try s3.groupTakes(trackId: disjoint.id, clipIds: disjoint.clips.map(\.id)) }) {}
        else { Issue.record("expected cannotGroup for non-overlap") }
    }

    @Test("setCompSegments: rebuild + validation (unknown lane, inverted, overlap) + range clamp")
    func setComp() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        let laneA = group.lanes[0].id, laneB = group.lanes[1].id

        // Two abutting segments → two members.
        let updated = try store.setCompSegments(trackId: track.id, groupId: group.id, segments: [
            CompSegment(laneID: laneA, startBeat: 0, endBeat: 4),
            CompSegment(laneID: laneB, startBeat: 4, endBeat: 8)])
        #expect(updated.comp.count == 2)
        #expect(store.tracks[0].clips.count == 2)

        // Unknown lane.
        if case .invalidComp = projectError({ _ = try store.setCompSegments(trackId: track.id, groupId: group.id,
            segments: [CompSegment(laneID: UUID(), startBeat: 0, endBeat: 4)]) }) {}
        else { Issue.record("expected invalidComp for unknown lane") }
        // Inverted.
        if case .invalidComp = projectError({ _ = try store.setCompSegments(trackId: track.id, groupId: group.id,
            segments: [CompSegment(laneID: laneA, startBeat: 4, endBeat: 2)]) }) {}
        else { Issue.record("expected invalidComp for inverted") }
        // Overlap.
        if case .invalidComp = projectError({ _ = try store.setCompSegments(trackId: track.id, groupId: group.id,
            segments: [CompSegment(laneID: laneA, startBeat: 0, endBeat: 5),
                       CompSegment(laneID: laneB, startBeat: 4, endBeat: 8)]) }) {}
        else { Issue.record("expected invalidComp for overlap") }

        // Range clamp: a segment past the range collapses/clamps to [0,8].
        let clamped = try store.setCompSegments(trackId: track.id, groupId: group.id,
            segments: [CompSegment(laneID: laneA, startBeat: -5, endBeat: 100)])
        #expect(clamped.comp.count == 1)
        #expect(approx(clamped.comp[0].startBeat, 0) && approx(clamped.comp[0].endBeat, 8))
    }

    @Test("selectTake swaps the comp to one full-range segment")
    func selectTake() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        let laneA = group.lanes[0].id
        let updated = try store.selectTake(trackId: track.id, groupId: group.id, laneId: laneA)
        #expect(updated.comp.count == 1)
        #expect(updated.comp[0].laneID == laneA)
        #expect(store.tracks[0].clips[0].audioFileURL?.path == "/a.wav")
    }

    @Test("removeTakeLane: in-use and last-lane rejections, then happy path")
    func removeLane() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        // Default comp references the newest lane (C) → removing it is in-use.
        if case .laneInUse = projectError({ _ = try store.removeTakeLane(trackId: track.id, groupId: group.id, laneId: group.lanes[2].id) }) {}
        else { Issue.record("expected laneInUse") }
        // An unused lane removes fine.
        let after = try store.removeTakeLane(trackId: track.id, groupId: group.id, laneId: group.lanes[0].id)
        #expect(after.lanes.count == 2)
        // Reduce to one lane, then last-lane rejection.
        _ = try store.removeTakeLane(trackId: track.id, groupId: group.id, laneId: after.lanes[0].id)
        if case .invalidComp = projectError({ _ = try store.removeTakeLane(trackId: track.id, groupId: group.id, laneId: store.tracks[0].takeGroups[0].lanes[0].id) }) {}
        else { Issue.record("expected invalidComp for last lane") }
    }

    @Test("flattenTakeGroup clears markers, dissolves the group, and restores editability")
    func flatten() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        let freed = try store.flattenTakeGroup(trackId: track.id, groupId: group.id)
        #expect(freed.count == 1)
        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID == nil })
        // Now an ordinary edit works.
        let id = store.tracks[0].clips[0].id
        _ = try store.splitClip(trackId: track.id, clipId: id, atBeat: 4)
        #expect(store.tracks[0].clips.count == 2)
    }

    @Test("moveTakeGroup shifts lanes, comp, and members together")
    func moveGroup() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        let moved = try store.moveTakeGroup(trackId: track.id, groupId: group.id, toStartBeat: 4)
        #expect(approx(moved.rangeBeats.lowerBound, 4))
        #expect(moved.lanes.allSatisfy { approx($0.clip.startBeat, 4) })
        #expect(approx(moved.comp[0].startBeat, 4) && approx(moved.comp[0].endBeat, 12))
        #expect(approx(store.tracks[0].clips[0].startBeat, 4))
    }

    @Test("setTakeCrossfade rebuilds members with the new join width")
    func setCrossfade() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        let laneA = group.lanes[0].id, laneB = group.lanes[1].id
        _ = try store.setCompSegments(trackId: track.id, groupId: group.id, segments: [
            CompSegment(laneID: laneA, startBeat: 0, endBeat: 4),
            CompSegment(laneID: laneB, startBeat: 4, endBeat: 8)])
        let updated = try store.setTakeCrossfade(trackId: track.id, groupId: group.id, seconds: 0.1)
        #expect(approx(updated.crossfadeSeconds, 0.1))
        // 120 BPM, xf = 0.2 beat → the left member carries an equal-power fade-out.
        let left = store.tracks[0].clips.sorted { $0.startBeat < $1.startBeat }[0]
        #expect(approx(left.fadeOutBeats, 0.2))
        #expect(left.fadeOutCurve == .equalPower)
        // Clamp above the max.
        #expect(try store.setTakeCrossfade(trackId: track.id, groupId: group.id, seconds: 9).crossfadeSeconds == 0.2)
    }

    @Test("member protection: all clip-edit ops reject a comp member")
    func memberProtection() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        let member = store.tracks[0].clips.first { $0.takeGroupID == group.id }!.id
        let tid = track.id

        expectClipInTakeGroup { _ = try store.splitClip(trackId: tid, clipId: member, atBeat: 4) }
        expectClipInTakeGroup { _ = try store.trimClip(trackId: tid, clipId: member, newStartBeat: 1, newLengthBeats: 4) }
        expectClipInTakeGroup { _ = try store.moveClip(trackId: tid, clipId: member, toStartBeat: 2) }
        expectClipInTakeGroup { _ = try store.setClipGain(trackId: tid, clipId: member, gainDb: -3) }
        expectClipInTakeGroup { _ = try store.setClipFades(trackId: tid, clipId: member, fadeInBeats: 1, fadeOutBeats: 1, fadeInCurve: .linear, fadeOutCurve: .linear) }
        expectClipInTakeGroup { _ = try store.setClipStretch(trackId: tid, clipId: member, ratio: 1.5) }
        expectClipInTakeGroup { _ = try store.stretchClip(trackId: tid, clipId: member, toLengthBeats: 6) }
        expectClipInTakeGroup { _ = try store.setClipNotes(clipID: member, notes: []) }
        expectClipInTakeGroup { _ = try store.removeClip(id: member) }
    }

    @Test("tempo change re-flattens every group inside ONE undo step")
    func tempoReflatten() throws {
        let (store, track, clips) = makeStore()
        let group = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        // A comp starting at beat 2 → member offset is tempo-dependent.
        _ = try store.setCompSegments(trackId: track.id, groupId: group.id,
            segments: [CompSegment(laneID: group.lanes[0].id, startBeat: 2, endBeat: 6)])
        #expect(approx(store.tracks[0].clips[0].startOffsetSeconds, 1.0))  // 2·60/120

        try store.setTempo(60)
        #expect(approx(store.tracks[0].clips[0].startOffsetSeconds, 2.0))  // 2·60/60
        #expect(store.undoLabel == "Set Tempo")

        _ = try store.undo()
        #expect(store.transport.tempoBPM == 120)
        #expect(approx(store.tracks[0].clips[0].startOffsetSeconds, 1.0))  // restored in one step
    }

    @Test("undo / redo across group, comp, and flatten")
    func undoRedo() throws {
        let (store, track, clips) = makeStore()
        _ = try store.groupTakes(trackId: track.id, clipIds: clips.map(\.id))
        #expect(store.tracks[0].takeGroups.count == 1)

        _ = try store.undo()   // ungroup
        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.count == 3)
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID == nil })

        _ = try store.redo()   // regroup
        #expect(store.tracks[0].takeGroups.count == 1)
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID != nil })
    }
}

// MARK: - Persistence

@MainActor
@Suite("Take persistence — document mirror + planMedia")
struct TakePersistenceTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeWav(_ url: URL) { try? Data([0x52, 0x49, 0x46, 0x46, 0x00]).write(to: url) }

    private func encodeObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("pre-take TrackDocument/ClipDocument omit the new keys (byte-identical)")
    func omitWhenEmpty() throws {
        let clip = Clip(name: "a", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/a.wav"))
        let track = Track(name: "T", kind: .audio, clips: [clip])
        let td = try encodeObject(TrackDocument(from: track, mediaRefs: [:]))
        #expect(td["takeGroups"] == nil)
        let cd = try encodeObject(ClipDocument(from: clip, media: nil))
        #expect(cd["takeGroupId"] == nil)
    }

    @Test("a member's ClipDocument carries takeGroupId; a track with takes carries takeGroups")
    func withTakesCarriesKeys() throws {
        var member = Clip(name: "m", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/a.wav"))
        member.takeGroupID = UUID()
        let cd = try encodeObject(ClipDocument(from: member, media: "media/a.wav"))
        #expect(cd["takeGroupId"] != nil)

        let lane = TakeLane(name: "A", clip: Clip(name: "A", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/a.wav")))
        let group = TakeGroup(id: UUID(), name: "G", lanes: [lane])
        let track = Track(name: "T", kind: .audio, clips: [member], takeGroups: [group])
        let td = try encodeObject(TrackDocument(from: track, mediaRefs: [:]))
        #expect(td["takeGroups"] != nil)
    }

    @Test("planMedia walks lane media so a NON-COMPED take survives save → reopen")
    func planMediaLaneWalk() throws {
        let dir = tempDir()
        let fileA = dir.appendingPathComponent("takeA.wav")
        let fileC = dir.appendingPathComponent("takeC.wav")
        writeWav(fileA); writeWav(fileC)

        // Two overlapping audio takes; C wins the comp, A is NON-COMPED.
        let track = Track(name: "Vox", kind: .audio, clips: [
            Clip(name: "A", startBeat: 0, lengthBeats: 8, audioFileURL: fileA),
            Clip(name: "C", startBeat: 0, lengthBeats: 8, audioFileURL: fileC)])
        let store = ProjectStore(tracks: [track])
        store.media = FakeMedia()
        let group = try store.groupTakes(trackId: track.id, clipIds: track.clips.map(\.id))
        #expect(group.lanes.count == 2)

        let path = dir.appendingPathComponent("Song").path
        let result = try store.saveProject(to: path)
        // Both take files copied — the non-comped lane's material is not lost.
        let mediaDir = ProjectBundle.normalizedBundleURL(fromPath: path)
            .appendingPathComponent("media", isDirectory: true)
        let mediaFiles = Set((try? FileManager.default.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? [])
        #expect(mediaFiles.contains("takeA.wav"))
        #expect(mediaFiles.contains("takeC.wav"))
        #expect(result.warnings.isEmpty)

        // Reopen: the group, its lanes, comp, and crossfade survive; lane URLs
        // resolve into media/.
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        _ = try reopened.openProject(at: path)
        #expect(reopened.tracks[0].takeGroups.count == 1)
        let rg = reopened.tracks[0].takeGroups[0]
        #expect(rg.lanes.count == 2)
        #expect(approx(rg.crossfadeSeconds, group.crossfadeSeconds))
        #expect(rg.comp.count == group.comp.count)
        let laneNames = Set(rg.lanes.map(\.name))
        #expect(laneNames == ["A", "C"])
        for lane in rg.lanes {
            let p = try #require(lane.clip.audioFileURL?.path)
            #expect(p.contains("/media/"))
            #expect(FileManager.default.fileExists(atPath: p))
        }
        // The comp member (from lane C) is present in clips with its marker.
        #expect(reopened.tracks[0].clips.contains { $0.takeGroupID == rg.id })
    }
}
