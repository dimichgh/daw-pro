import Foundation

/// Take comping store operations (M5 iii-a, spec §3). Every comp mutation
/// deterministically REBUILDS the group's member clips inside `track.clips`
/// (delete all clips with this `takeGroupID`, emit fresh ones via
/// `CompFlattener`) inside one `performEdit` — the engine only ever sees
/// ordinary clips on the existing `tracksDidChange` restart seam.
@MainActor
extension ProjectStore {

    // MARK: - Locating

    /// Locates a take group by track + group id, returning `(trackIndex,
    /// groupIndex)`. Throws `trackNotFound` / `takeGroupNotFound`.
    private func locateGroup(trackID: UUID, groupID: UUID) throws -> (t: Int, g: Int) {
        guard let t = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let g = tracks[t].takeGroups.firstIndex(where: { $0.id == groupID }) else {
            throw ProjectError.takeGroupNotFound
        }
        return (t, g)
    }

    /// Removes a group's current members from `track.clips` and re-emits them
    /// from the group's comp at the current tempo, then notifies the engine.
    /// Internal (not private) so `setTempo`'s re-flatten can call it across files.
    /// MUST run inside a `performEdit` body.
    func rebuildCompMembers(trackIndex t: Int, groupIndex g: Int) {
        let group = tracks[t].takeGroups[g]
        tracks[t].clips.removeAll { $0.takeGroupID == group.id }
        tracks[t].clips.append(contentsOf: CompFlattener.flatten(group, tempoMap: transport.tempoMap))
        engine?.tracksDidChange(tracks)
    }

    // MARK: - Group / comp ops

    /// Forms a group from >= 2 existing OVERLAPPING clips on one track (all audio
    /// or all MIDI; mixed rejected). The clips are REMOVED from `track.clips` and
    /// become lanes (oldest = lane 0, by their `track.clips` order); comp defaults
    /// to the LAST (newest) lane across the full group range (newest wins);
    /// members are rebuilt. One `performEdit("Group Takes")`, no coalescing.
    @discardableResult
    public func groupTakes(trackId: UUID, clipIds: [UUID], name: String? = nil) throws -> TakeGroup {
        guard let t = tracks.firstIndex(where: { $0.id == trackId }) else {
            throw ProjectError.trackNotFound(trackId)
        }
        guard clipIds.count >= 2 else {
            throw ProjectError.cannotGroup("a take group needs at least 2 clips")
        }
        // Resolve to clip indices in track.clips order (oldest = first). A
        // duplicate or unknown id, or a clip already in a group, is rejected.
        var indices: [Int] = []
        var seen = Set<UUID>()
        for id in clipIds {
            guard seen.insert(id).inserted else {
                throw ProjectError.cannotGroup("clip \(id.uuidString) listed twice")
            }
            guard let c = tracks[t].clips.firstIndex(where: { $0.id == id }) else {
                throw ProjectError.clipNotFound(id)
            }
            if tracks[t].clips[c].takeGroupID != nil {
                throw ProjectError.cannotGroup("clip '\(tracks[t].clips[c].name)' already belongs to a take group")
            }
            indices.append(c)
        }
        indices.sort()  // track.clips order = record order = oldest first
        let sourceClips = indices.map { tracks[t].clips[$0] }

        // All audio or all MIDI.
        let midiCount = sourceClips.filter(\.isMIDI).count
        guard midiCount == 0 || midiCount == sourceClips.count else {
            throw ProjectError.cannotGroup("cannot mix audio and MIDI takes in one group")
        }
        // Overlapping: sorted by start, each clip must overlap the running cluster.
        let byStart = sourceClips.sorted { $0.startBeat < $1.startBeat }
        var clusterEnd = byStart[0].startBeat + byStart[0].lengthBeats
        for clip in byStart.dropFirst() {
            guard clip.startBeat < clusterEnd else {
                throw ProjectError.cannotGroup("clips do not overlap — grouping needs overlapping takes")
            }
            clusterEnd = max(clusterEnd, clip.startBeat + clip.lengthBeats)
        }

        let lanes = sourceClips.map { TakeLane(name: $0.name, clip: $0) }
        let groupName = name ?? "\(tracks[t].name) Takes"
        var group = TakeGroup(id: UUID(), name: groupName, lanes: lanes)
        // Default comp: the newest lane (last) across the full range, newest wins.
        let range = group.rangeBeats
        group.comp = [CompSegment(laneID: lanes[lanes.count - 1].id,
                                  startBeat: range.lowerBound, endBeat: range.upperBound)]

        let idsToRemove = Set(clipIds)
        performEdit("Group Takes") {
            tracks[t].clips.removeAll { idsToRemove.contains($0.id) }
            tracks[t].takeGroups.append(group)
            let g = tracks[t].takeGroups.count - 1
            rebuildCompMembers(trackIndex: t, groupIndex: g)
        }
        return tracks[t].takeGroups.first { $0.id == group.id } ?? group
    }

    /// Replaces the comp wholesale (the `setClipNotes` / `setAutomationPoints`
    /// whole-array precedent). Validates known lane ids, `end > start`, and
    /// non-overlap; then sorts and clamps each segment to the group range
    /// (empties dropped — gaps are legal). Rebuilds members. Coalesces under
    /// `take.comp:<groupId>` (a comp-paint drag = one undo step).
    @discardableResult
    public func setCompSegments(trackId: UUID, groupId: UUID, segments: [CompSegment]) throws -> TakeGroup {
        let (t, g) = try locateGroup(trackID: trackId, groupID: groupId)
        let laneIDs = Set(tracks[t].takeGroups[g].lanes.map(\.id))
        for seg in segments {
            guard laneIDs.contains(seg.laneID) else {
                throw ProjectError.invalidComp("comp references unknown take \(seg.laneID.uuidString)")
            }
            guard seg.endBeat > seg.startBeat else {
                throw ProjectError.invalidComp("comp segment end must be after its start")
            }
        }
        let sorted = segments.sorted { $0.startBeat < $1.startBeat }
        for i in sorted.indices.dropFirst() where sorted[i].startBeat < sorted[i - 1].endBeat {
            throw ProjectError.invalidComp("comp segments overlap — segments must be non-overlapping")
        }
        // Clamp to the group range; drop segments that collapse to empty.
        let range = tracks[t].takeGroups[g].rangeBeats
        let clamped: [CompSegment] = sorted.compactMap { seg in
            let s = max(seg.startBeat, range.lowerBound)
            let e = min(seg.endBeat, range.upperBound)
            guard e > s else { return nil }
            return CompSegment(laneID: seg.laneID, startBeat: s, endBeat: e)
        }
        performEdit("Set Comp", key: "take.comp:\(groupId.uuidString)") {
            tracks[t].takeGroups[g].comp = clamped
            rebuildCompMembers(trackIndex: t, groupIndex: g)
        }
        return tracks[t].takeGroups[g]
    }

    /// Sugar for a quick take swap: comp becomes one full-range segment on this
    /// lane. Implemented via `setCompSegments`, so it shares the
    /// `take.comp:<groupId>` coalescing key.
    @discardableResult
    public func selectTake(trackId: UUID, groupId: UUID, laneId: UUID) throws -> TakeGroup {
        let (t, g) = try locateGroup(trackID: trackId, groupID: groupId)
        guard tracks[t].takeGroups[g].lanes.contains(where: { $0.id == laneId }) else {
            throw ProjectError.laneNotFound
        }
        let range = tracks[t].takeGroups[g].rangeBeats
        return try setCompSegments(trackId: trackId, groupId: groupId,
                                   segments: [CompSegment(laneID: laneId,
                                                          startBeat: range.lowerBound,
                                                          endBeat: range.upperBound)])
    }

    /// Deletes a take (lane). Rejected while any comp segment references the lane
    /// (`laneInUse`) and when it is the last lane (`invalidComp`). Rebuilds
    /// members. `performEdit("Delete Take")`, no coalescing.
    @discardableResult
    public func removeTakeLane(trackId: UUID, groupId: UUID, laneId: UUID) throws -> TakeGroup {
        let (t, g) = try locateGroup(trackID: trackId, groupID: groupId)
        guard tracks[t].takeGroups[g].lanes.contains(where: { $0.id == laneId }) else {
            throw ProjectError.laneNotFound
        }
        guard tracks[t].takeGroups[g].lanes.count > 1 else {
            throw ProjectError.invalidComp(
                "cannot delete the last take in a group — use take.flatten to dissolve the group")
        }
        guard !tracks[t].takeGroups[g].comp.contains(where: { $0.laneID == laneId }) else {
            throw ProjectError.laneInUse
        }
        performEdit("Delete Take") {
            tracks[t].takeGroups[g].lanes.removeAll { $0.id == laneId }
            rebuildCompMembers(trackIndex: t, groupIndex: g)
        }
        return tracks[t].takeGroups[g]
    }

    /// Dissolves the group: its current members stay as ORDINARY clips
    /// (`takeGroupID` cleared, full editability restored); non-comped lane
    /// material is DISCARDED (the files remain on disk / in media). The escape
    /// hatch out of member protection. `performEdit("Flatten Takes")`. Returns
    /// the freed clips.
    @discardableResult
    public func flattenTakeGroup(trackId: UUID, groupId: UUID) throws -> [Clip] {
        let (t, g) = try locateGroup(trackID: trackId, groupID: groupId)
        let groupIDValue = tracks[t].takeGroups[g].id
        var freed: [Clip] = []
        performEdit("Flatten Takes") {
            for c in tracks[t].clips.indices where tracks[t].clips[c].takeGroupID == groupIDValue {
                tracks[t].clips[c].takeGroupID = nil
                freed.append(tracks[t].clips[c])
            }
            tracks[t].takeGroups.remove(at: g)
            engine?.tracksDidChange(tracks)
        }
        return freed
    }

    /// Shifts the WHOLE group (lanes + comp + members) so its range starts at
    /// `toStartBeat` (clamped >= 0). Rebuilds members. Coalesces under
    /// `take.move:<groupId>` (a drag = one undo step).
    @discardableResult
    public func moveTakeGroup(trackId: UUID, groupId: UUID, toStartBeat: Double) throws -> TakeGroup {
        let (t, g) = try locateGroup(trackID: trackId, groupID: groupId)
        let target = max(0, toStartBeat)
        let delta = target - tracks[t].takeGroups[g].rangeBeats.lowerBound
        guard delta != 0 else { return tracks[t].takeGroups[g] }
        performEdit("Move Takes", key: "take.move:\(groupId.uuidString)") {
            for l in tracks[t].takeGroups[g].lanes.indices {
                tracks[t].takeGroups[g].lanes[l].clip.startBeat =
                    max(0, tracks[t].takeGroups[g].lanes[l].clip.startBeat + delta)
            }
            for s in tracks[t].takeGroups[g].comp.indices {
                tracks[t].takeGroups[g].comp[s].startBeat += delta
                tracks[t].takeGroups[g].comp[s].endBeat += delta
            }
            rebuildCompMembers(trackIndex: t, groupIndex: g)
        }
        return tracks[t].takeGroups[g]
    }

    // MARK: - Recording integration (auto-group)

    /// Auto-groups a just-finished AUDIO take against whatever already sits on
    /// its track (M5 iii-b, spec §3). Called once per armed audio track from
    /// `finishTake`'s single `performEdit("Record Take N")` — this function
    /// mutates `tracks` directly (no `performEdit` of its own; nesting one
    /// would split the recording into two undo entries) and shares the
    /// `rebuildCompMembers` seam with the explicit `take.*` commands. AUDIO
    /// ONLY: non-loop MIDI re-recording is unaffected (explicit `take.group`
    /// still works on MIDI clips). Loop-cycle recording (m15-b) fans its
    /// audio slices through here IN CYCLE ORDER — slice 2 overlapping slice 1
    /// is exactly case 2, slices 3..N are case 1 — and lands its MIDI cycle
    /// lanes via `landLoopMIDITakeLanes` below.
    ///
    /// Three cases, checked in order:
    /// 1. `newClip`'s range overlaps an EXISTING take group's range on this
    ///    track → append a lane, comp := that lane's full range (newest wins).
    /// 2. Else it overlaps one or more plain (non-member) AUDIO clips → those
    ///    clips become lanes (oldest first, by `track.clips` order) plus
    ///    `newClip` as the newest lane; comp := the newest lane's full range.
    /// 3. Else → returns `false` (caller appends `newClip` as an ordinary
    ///    clip, exactly today's behavior).
    ///
    /// Returns `true` when `newClip` was consumed into a take group (the
    /// caller must NOT also append it to `track.clips`).
    @discardableResult
    func autoGroupRecordedTake(trackIndex t: Int, newClip: Clip) -> Bool {
        let newStart = newClip.startBeat
        let newEnd = newClip.startBeat + newClip.lengthBeats

        // Case 1: overlaps an existing group's range → append a lane.
        if let g = tracks[t].takeGroups.firstIndex(where: { group in
            let r = group.rangeBeats
            return newStart < r.upperBound && newEnd > r.lowerBound
        }) {
            let lane = TakeLane(name: newClip.name, clip: newClip)
            tracks[t].takeGroups[g].lanes.append(lane)
            let range = tracks[t].takeGroups[g].rangeBeats
            tracks[t].takeGroups[g].comp = [
                CompSegment(laneID: lane.id, startBeat: range.lowerBound, endBeat: range.upperBound),
            ]
            rebuildCompMembers(trackIndex: t, groupIndex: g)
            return true
        }

        // Case 2: overlaps one or more plain (non-member) AUDIO clips →
        // groupTakes semantics, inline (no nested performEdit). Oldest-first
        // by `track.clips` order, exactly the explicit `groupTakes` ordering.
        let overlappingIDs: [UUID] = tracks[t].clips.indices.compactMap { i in
            let c = tracks[t].clips[i]
            guard c.takeGroupID == nil, !c.isMIDI else { return nil }
            let cEnd = c.startBeat + c.lengthBeats
            return (newStart < cEnd && newEnd > c.startBeat) ? c.id : nil
        }
        guard !overlappingIDs.isEmpty else { return false }
        let idsToRemove = Set(overlappingIDs)
        let existingClips = tracks[t].clips.filter { idsToRemove.contains($0.id) }

        var lanes = existingClips.map { TakeLane(name: $0.name, clip: $0) }
        let newLane = TakeLane(name: newClip.name, clip: newClip)
        lanes.append(newLane)
        var group = TakeGroup(id: UUID(), name: "\(tracks[t].name) Takes", lanes: lanes)
        let range = group.rangeBeats
        group.comp = [CompSegment(laneID: newLane.id, startBeat: range.lowerBound, endBeat: range.upperBound)]

        tracks[t].clips.removeAll { idsToRemove.contains($0.id) }
        tracks[t].takeGroups.append(group)
        rebuildCompMembers(trackIndex: t, groupIndex: tracks[t].takeGroups.count - 1)
        return true
    }

    /// Lands a loop-cycle MIDI take (m15-b, design-m15b §4): N ≥ 2 cycle-lane
    /// clips as ONE all-MIDI take group — the small explicit lander (all-MIDI
    /// groups are legal; `groupTakes` rejects only MIXED). The non-loop v0
    /// MIDI stacking policy is untouched: only loop takes route here. Mirrors
    /// `autoGroupRecordedTake`'s case 1 for re-records (lanes append to an
    /// existing overlapping group — the comping workflow), else forms a new
    /// group. Comp := the newest lane across the full range (newest wins).
    /// MUST run inside a `performEdit` body (no nested edit — a loop take
    /// stays ONE undo step).
    func landLoopMIDITakeLanes(trackIndex t: Int, laneClips: [Clip]) {
        guard !laneClips.isEmpty else { return }
        let newLanes = laneClips.map { TakeLane(name: $0.name, clip: $0) }
        let newStart = laneClips.map(\.startBeat).min() ?? 0
        let newEnd = laneClips.map { $0.startBeat + $0.lengthBeats }.max() ?? newStart

        // Case 1 analog: the take overlaps an existing group's range → append
        // every cycle lane; comp := the newest appended lane.
        if let g = tracks[t].takeGroups.firstIndex(where: { group in
            let r = group.rangeBeats
            return newStart < r.upperBound && newEnd > r.lowerBound
        }) {
            tracks[t].takeGroups[g].lanes.append(contentsOf: newLanes)
            let range = tracks[t].takeGroups[g].rangeBeats
            tracks[t].takeGroups[g].comp = [
                CompSegment(laneID: newLanes[newLanes.count - 1].id,
                            startBeat: range.lowerBound, endBeat: range.upperBound),
            ]
            rebuildCompMembers(trackIndex: t, groupIndex: g)
            return
        }

        var group = TakeGroup(id: UUID(), name: "\(tracks[t].name) Takes", lanes: newLanes)
        let range = group.rangeBeats
        group.comp = [CompSegment(laneID: newLanes[newLanes.count - 1].id,
                                  startBeat: range.lowerBound, endBeat: range.upperBound)]
        tracks[t].takeGroups.append(group)
        rebuildCompMembers(trackIndex: t, groupIndex: tracks[t].takeGroups.count - 1)
    }

    /// Sets the join crossfade width (seconds, clamped to
    /// `TakeGroup.crossfadeSecondsRange`); rebuilds members. Coalesces under
    /// `take.xf:<groupId>`.
    @discardableResult
    public func setTakeCrossfade(trackId: UUID, groupId: UUID, seconds: Double) throws -> TakeGroup {
        let (t, g) = try locateGroup(trackID: trackId, groupID: groupId)
        let clamped = seconds.clamped(to: TakeGroup.crossfadeSecondsRange)
        performEdit("Set Take Crossfade", key: "take.xf:\(groupId.uuidString)") {
            tracks[t].takeGroups[g].crossfadeSeconds = clamped
            rebuildCompMembers(trackIndex: t, groupIndex: g)
        }
        return tracks[t].takeGroups[g]
    }
}
