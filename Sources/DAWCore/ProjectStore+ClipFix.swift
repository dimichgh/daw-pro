import Foundation

/// Clip vocal-fix flow store operations (M6 v-b, design §3). Two explicit,
/// caller-driven steps mirroring the settled `ai.generateSong`/`import`
/// shape:
///
/// 1. `fixClipRegion` — validates, bounces a DRY as-heard window of the target
///    material (region ± context, clamped), submits the repaint via the
///    additive `GenerationImporting.submitRepaint` seam, and registers an
///    in-memory `PendingClipFix`. NO project mutation, no undo entry.
/// 2. `importClipFix` — fetches the finished audio, revalidates the target
///    (move-rebase or `clipFixStale`), and lands the repaint as a violet take
///    LANE comped in over exactly the fix region — one `performEdit("AI Fix
///    Take")`, so a single undo restores the plain clip (or previous comp).
///
/// The store owns bounce+submit+import orchestration so the SwiftUI app (v-b-2)
/// and the control protocol converge on the SAME methods. DAWCore stays
/// AI-free: the AI hop rides the `GenerationImporting` seam, the audio hop
/// rides `AudioEngineControlling.renderOffline`.
@MainActor
extension ProjectStore {

    // MARK: - Submit

    /// Submits an AI repaint of `[startBeat, endBeat)` (absolute timeline beats)
    /// inside the target clip. Bounces a dry, as-heard window (region ± context
    /// clamped) rendered at project tempo with the source clip's stretch/gain
    /// baked in, so the file↔timeline mapping is the identity. Returns a
    /// placement echo; poll `ai.generationStatus`, then `importClipFix(jobID:)`.
    /// A retake is the same call again without `seed`.
    @discardableResult
    public func fixClipRegion(
        trackId: UUID, clipId: UUID,
        startBeat: Double, endBeat: Double,
        prompt: String? = nil, lyrics: String? = nil,
        mode: ClipFixMode = .balanced, strength: Double? = nil,
        seed: Int? = nil, contextSeconds: Double = 10.0,
        model: String? = nil
    ) async throws -> ClipFixSubmission {
        // 1. Fail early, before an expensive bounce (the seam + engine must exist).
        guard let generationSource else { throw ProjectError.generationSourceUnavailable }
        guard let engine else { throw ProjectError.engineUnavailable }

        // 2. Locate the track + clip; reject MIDI (audio clips only). Bus/
        //    instrument targets are rejected implicitly — audio clips only live
        //    on audio tracks.
        guard let t = tracks.firstIndex(where: { $0.id == trackId }) else {
            throw ProjectError.trackNotFound(trackId)
        }
        guard let clip = tracks[t].clips.first(where: { $0.id == clipId }) else {
            throw ProjectError.clipNotFound(clipId)
        }
        guard !clip.isMIDI else { throw ProjectError.clipFixRequiresAudioClip(clipId) }

        let tempoMap = transport.tempoMap

        // 3. Resolve the target flavor, its span, and the clips that go into the
        //    bounce (D1). Plain clip → just that clip with fades STRIPPED (so the
        //    bounce matches what the lane sounds like POST-grouping, when the
        //    flattener zeroes fades). Comp member → the group's CURRENT
        //    materialized members (the as-heard comp, member crossfades kept),
        //    span = group range.
        let target: PendingFixTarget
        let spanStart: Double
        let spanEnd: Double
        let bounceClips: [Clip]
        if let groupID = clip.takeGroupID {
            guard let g = tracks[t].takeGroups.firstIndex(where: { $0.id == groupID }) else {
                // A member clip must reference a live group.
                throw ProjectError.takeGroupNotFound
            }
            let range = tracks[t].takeGroups[g].rangeBeats
            spanStart = range.lowerBound
            spanEnd = range.upperBound
            bounceClips = tracks[t].clips.filter { $0.takeGroupID == groupID }
            target = .group(id: groupID, frozenRangeStart: spanStart, frozenRangeEnd: spanEnd)
        } else {
            spanStart = clip.startBeat
            spanEnd = clip.startBeat + clip.lengthBeats
            var dry = clip
            dry.fadeInBeats = 0
            dry.fadeOutBeats = 0
            dry.fadeInCurve = .linear
            dry.fadeOutCurve = .linear
            bounceClips = [dry]
            target = .clip(id: clipId, fingerprint: ClipGeometryFingerprint(of: clip))
        }

        // 4. Validate the region (built at throw time — the invalidClipEdit
        //    precedent): non-empty, inside the span, and at least 0.1 s long
        //    (sub-latent-frame windows can't change anything).
        guard endBeat > startBeat else {
            throw ProjectError.invalidClipEdit(
                "fix region is empty — endBeat (\(endBeat)) must be greater than startBeat (\(startBeat))")
        }
        guard startBeat >= spanStart - Self.beatEpsilon,
              endBeat <= spanEnd + Self.beatEpsilon else {
            throw ProjectError.invalidClipEdit(
                "fix region [\(startBeat), \(endBeat)] beats lies outside the target span "
                + "[\(spanStart), \(spanEnd)] — pick a region inside the clip")
        }
        let regionSeconds = tempoMap.seconds(from: startBeat, to: endBeat)
        guard regionSeconds >= 0.1 else {
            throw ProjectError.invalidClipEdit(
                "fix region is only \(String(format: "%.3f", regionSeconds)) s — too short to "
                + "repaint (minimum 0.1 s); widen the region")
        }

        // 5. Clamp context and compute the window + file-domain seconds (D3).
        let context = contextSeconds.clamped(to: 1...60)
        // Inverse integral anchored at the region start (m12-b, design row
        // 28) — the context pad is a wall-clock quantity.
        let contextBeats = tempoMap.beat(from: startBeat, elapsedSeconds: context) - startBeat
        let window = ClipFixPlanner.window(
            regionStart: startBeat, regionEnd: endBeat,
            spanStart: spanStart, spanEnd: spanEnd, contextBeats: contextBeats)
        let windowStartBeat = window.start
        let windowEndBeat = window.end
        let bounceSeconds = tempoMap.seconds(from: windowStartBeat, to: windowEndBeat)
        let repaintStartSeconds = tempoMap.seconds(from: windowStartBeat, to: startBeat)
        let repaintEndSeconds = tempoMap.seconds(from: windowStartBeat, to: endBeat)

        // 6. Render the DRY window into a SYNTHETIC single track (D1): unity
        //    volume/pan, no inserts/sends/automation (zero-latency plan), master
        //    untouched, duration = exact window seconds (NO +2 s mixdown tail —
        //    the file must map 1:1 onto the timeline window). Written to a
        //    transient temp WAV (the ACE-Step client stages its own sidecar
        //    copy, v-a behavior).
        let syntheticTrack = Track(name: "AI Fix Bounce", kind: .audio, clips: bounceClips)
        // STEM class (m13-d, design §2): region material for the repaint is
        // dry by contract ("master untouched") — never mastered, never
        // master-lane-faded (m15-c).
        let rendered = try await engine.renderOffline(
            tracks: [syntheticTrack], tempoMap: tempoMap, masterVolume: 1,
            masterEffects: [],
            masterAutomation: [],
            fromBeat: windowStartBeat, durationSeconds: bounceSeconds,
            forcedCompensationTargets: nil)
        let bounceURL = Self.fixBounceDestination()
        _ = try engine.writeAudioFile(rendered, to: bounceURL)

        // 7. Submit the repaint (sidecar-unreachable actionable messages already
        //    exist in the client and surface verbatim).
        let receipt = try await generationSource.submitRepaint(ClipRepaintRequest(
            sourceAudioPath: bounceURL.path,
            startSeconds: repaintStartSeconds,
            endSeconds: repaintEndSeconds,
            prompt: prompt, lyrics: lyrics, mode: mode,
            strength: strength, seed: seed, model: model))

        // 8. Register the pending fix and return the echo. No project mutation,
        //    no undo entry — submit is a pure side-effect job (D5).
        pendingClipFixes[receipt.jobID] = PendingClipFix(
            jobID: receipt.jobID, trackID: trackId, target: target,
            windowStartBeat: windowStartBeat,
            windowLengthBeats: windowEndBeat - windowStartBeat,
            regionStartBeat: startBeat, regionEndBeat: endBeat,
            mapRevision: mapRevision, regionBPM: tempoMap.bpm(atBeat: startBeat),
            submittedAt: Date())

        return ClipFixSubmission(
            jobID: receipt.jobID, state: "queued", queuePosition: receipt.queuePosition,
            windowStartBeat: windowStartBeat, windowEndBeat: windowEndBeat,
            regionStartBeat: startBeat, regionEndBeat: endBeat,
            repaintStartSeconds: repaintStartSeconds, repaintEndSeconds: repaintEndSeconds,
            bouncePath: bounceURL.path)
    }

    // MARK: - Import

    /// Lands a finished clip fix as a violet take LANE comped in over exactly
    /// the requested region. One `performEdit("AI Fix Take")`. The pending
    /// record is consumed on SUCCESS only; every error path keeps it (retryable,
    /// or kept for inspection until a project switch).
    @discardableResult
    public func importClipFix(jobID: String) async throws -> ClipFixImportResult {
        // 1. Pending lookup — an unknown job is actionable (re-submit).
        guard let pending = pendingClipFixes[jobID] else {
            throw ProjectError.clipFixJobNotFound(jobID)
        }
        guard let generationSource else { throw ProjectError.generationSourceUnavailable }

        // 2. Fetch the finished audio — identical to importGeneration steps 1–2.
        let result = try await generationSource.fetchGeneration(jobID: jobID)
        guard let audioPath = result.audioPath, !audioPath.isEmpty else {
            throw ProjectError.generationNotReady(jobID: jobID, state: result.state)
        }
        let sourceURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ProjectError.generationAudioMissing(audioPath)
        }

        // 3. Copy the repainted WAV into a stable home (the iii-a helper, with a
        //    "fix-" key). The file outlives undo (recording-take file model).
        let stableURL = try copyGeneratedAudioToStableLocation(from: sourceURL, jobID: "fix-\(jobID)")

        // 4. Resolve + revalidate the target (D6) → a rebase delta or clipFixStale.
        guard let t = tracks.firstIndex(where: { $0.id == pending.trackID }) else {
            throw ProjectError.clipFixStale(
                "the track for this fix no longer exists — submit again with ai.fixClipRegion")
        }
        // Map compare (m12-d, design row 29): the cheap `mapRevision` integer
        // — any map mutation (scalar tempo, tempo.setMap, undo/redo) climbs it,
        // so a mismatch means the bounced material's beats↔seconds mapping no
        // longer lines up. The error keeps the bpm-at-region numbers agents
        // already parse (frozen `regionBPM` → current).
        guard mapRevision == pending.mapRevision else {
            let was = pending.regionBPM
            let now = transport.tempoMap.bpm(atBeat: pending.regionStartBeat)
            throw ProjectError.clipFixStale(
                "the project tempo changed (\(was) → \(now) BPM) since this "
                + "fix was requested — the bounced material no longer lines up; submit again with ai.fixClipRegion")
        }
        let plan = try resolveClipFixPlan(pending, trackIndex: t)
        let delta: Double
        switch plan {
        case .createGroup(_, let d): delta = d
        case .appendToGroup(_, let d): delta = d
        }
        let fixRegionStart = pending.regionStartBeat + delta
        let fixRegionEnd = pending.regionEndBeat + delta

        // 5. Build the fix lane clip (D3 field list, beats shifted by delta) and
        //    perform the single edit (mirroring autoGroupRecordedTake's inline,
        //    no-nested-performEdit discipline). tracksDidChange fires inside
        //    rebuildCompMembers.
        let groupID: UUID
        let laneID: UUID
        let laneName: String
        switch plan {
        case .createGroup(let clipIndex, _):
            let original = tracks[t].clips[clipIndex]
            let originalLane = TakeLane(name: original.name, clip: original)
            laneName = Self.nextFixName(in: [originalLane])
            let fixLane = TakeLane(name: laneName,
                                   clip: fixLaneClip(named: laneName, at: pending.windowStartBeat + delta,
                                                     lengthBeats: pending.windowLengthBeats, url: stableURL))
            var group = TakeGroup(name: "\(tracks[t].name) Takes", lanes: [originalLane, fixLane])
            let range = group.rangeBeats
            // Base comp = the original lane across the whole range, then splice
            // the fix region onto the fix lane (fix-region-only, D4).
            group.comp = ClipFixPlanner.splice(
                [CompSegment(laneID: originalLane.id, startBeat: range.lowerBound, endBeat: range.upperBound)],
                regionStart: fixRegionStart, regionEnd: fixRegionEnd, laneID: fixLane.id)
            groupID = group.id
            laneID = fixLane.id
            let originalID = original.id
            performEdit("AI Fix Take") {
                tracks[t].clips.removeAll { $0.id == originalID }
                tracks[t].takeGroups.append(group)
                rebuildCompMembers(trackIndex: t, groupIndex: tracks[t].takeGroups.count - 1)
            }
        case .appendToGroup(let groupIndex, _):
            laneName = Self.nextFixName(in: tracks[t].takeGroups[groupIndex].lanes)
            let fixLane = TakeLane(name: laneName,
                                   clip: fixLaneClip(named: laneName, at: pending.windowStartBeat + delta,
                                                     lengthBeats: pending.windowLengthBeats, url: stableURL))
            groupID = tracks[t].takeGroups[groupIndex].id
            laneID = fixLane.id
            performEdit("AI Fix Take") {
                tracks[t].takeGroups[groupIndex].lanes.append(fixLane)
                tracks[t].takeGroups[groupIndex].comp = ClipFixPlanner.splice(
                    tracks[t].takeGroups[groupIndex].comp,
                    regionStart: fixRegionStart, regionEnd: fixRegionEnd, laneID: fixLane.id)
                rebuildCompMembers(trackIndex: t, groupIndex: groupIndex)
            }
        }

        // 6. Consume the pending record — success only.
        pendingClipFixes[jobID] = nil
        return ClipFixImportResult(trackID: pending.trackID, groupID: groupID,
                                   laneID: laneID, laneName: laneName)
    }

    // MARK: - Import resolution

    /// How a pending fix lands: create a new group from a still-plain clip, or
    /// append a lane to an existing group (a comp-member target, or a SECOND
    /// plain-clip fix whose original was already consumed into a group). Carries
    /// the uniform-move rebase delta (D6).
    private enum ClipFixPlan {
        case createGroup(clipIndex: Int, delta: Double)
        case appendToGroup(groupIndex: Int, delta: Double)
    }

    /// Resolves + revalidates a pending fix against the CURRENT project (D6).
    /// Throws `clipFixStale` (with a message naming what changed) when the
    /// bounced material can no longer land cleanly.
    private func resolveClipFixPlan(_ pending: PendingClipFix, trackIndex t: Int) throws -> ClipFixPlan {
        switch pending.target {
        case .group(let id, let frozenStart, let frozenEnd):
            // The group id is the stable anchor (member clip ids churn on every
            // comp rebuild). Comp edits during the job are fine — the splice
            // applies to the current comp.
            guard let gi = tracks[t].takeGroups.firstIndex(where: { $0.id == id }) else {
                throw ProjectError.clipFixStale(
                    "the take group for this fix no longer exists — it may have been flattened; "
                    + "submit again with ai.fixClipRegion")
            }
            let range = tracks[t].takeGroups[gi].rangeBeats
            let frozenLength = frozenEnd - frozenStart
            let currentLength = range.upperBound - range.lowerBound
            // A uniform shift (moveTakeGroup) keeps the length; any other range
            // change reshapes it (trimmed/added/removed lanes, shrunk range).
            guard abs(currentLength - frozenLength) < Self.beatEpsilon else {
                throw ProjectError.clipFixStale(
                    "the take group's range changed since this fix was requested "
                    + "(was \(frozenLength) beats long, now \(currentLength)) — the fix region no "
                    + "longer lines up; submit again with ai.fixClipRegion")
            }
            return .appendToGroup(groupIndex: gi, delta: range.lowerBound - frozenStart)

        case .clip(let id, let fingerprint):
            // Still a plain clip → create a group from it + the fix lane.
            if let ci = tracks[t].clips.firstIndex(where: { $0.id == id && $0.takeGroupID == nil }) {
                let current = ClipGeometryFingerprint(of: tracks[t].clips[ci])
                guard let d = fingerprint.moveDelta(to: current) else {
                    throw ProjectError.clipFixStale(Self.clipFixStaleMessage(from: fingerprint, to: current))
                }
                return .createGroup(clipIndex: ci, delta: d)
            }
            // A FIRST fix already consumed this plain clip into a group — its
            // lane payload keeps the clip id + geometry, so a SECOND queued fix
            // composes as another lane in the same group.
            if let gi = tracks[t].takeGroups.firstIndex(where: { g in
                g.lanes.contains { $0.clip.id == id }
            }), let lane = tracks[t].takeGroups[gi].lanes.first(where: { $0.clip.id == id }) {
                let current = ClipGeometryFingerprint(of: lane.clip)
                guard let d = fingerprint.moveDelta(to: current) else {
                    throw ProjectError.clipFixStale(Self.clipFixStaleMessage(from: fingerprint, to: current))
                }
                return .appendToGroup(groupIndex: gi, delta: d)
            }
            throw ProjectError.clipFixStale(
                "the original clip no longer exists — it may have been deleted or flattened; "
                + "submit again with ai.fixClipRegion")
        }
    }

    // MARK: - Helpers

    /// Tolerance for beat-domain equality/containment checks.
    private static let beatEpsilon = 1e-9

    /// The take-lane clip for a fix payload (D3): rate 1.0 / offset 0 / gain 0 /
    /// no fades, violet (AI-generated), at the window position.
    private func fixLaneClip(named name: String, at startBeat: Double,
                             lengthBeats: Double, url: URL) -> Clip {
        Clip(
            name: name,
            startBeat: startBeat,
            lengthBeats: lengthBeats,
            audioFileURL: url,
            isAIGenerated: true,
            startOffsetSeconds: 0,
            gainDb: 0,
            fadeInBeats: 0, fadeOutBeats: 0,
            fadeInCurve: .linear, fadeOutCurve: .linear,
            stretchRatio: 1, pitchShiftSemitones: 0, formantPreserve: false)
    }

    /// Next `"AI Fix N"` name for a group — `N = 1 + count(lanes whose name
    /// hasPrefix "AI Fix")` (the "Record Take N" per-scope counter precedent).
    private static func nextFixName(in lanes: [TakeLane]) -> String {
        "AI Fix \(1 + lanes.filter { $0.name.hasPrefix("AI Fix") }.count)"
    }

    /// Builds the `clipFixStale` message for a plain-clip fingerprint that
    /// drifted beyond a pure move — naming exactly what changed.
    private static func clipFixStaleMessage(from old: ClipGeometryFingerprint,
                                            to new: ClipGeometryFingerprint) -> String {
        var changes: [String] = []
        if old.lengthBeats != new.lengthBeats {
            changes.append("length (\(old.lengthBeats) → \(new.lengthBeats) beats)")
        }
        if old.startOffsetSeconds != new.startOffsetSeconds {
            changes.append("trim offset (\(old.startOffsetSeconds) → \(new.startOffsetSeconds) s)")
        }
        if old.stretchRatio != new.stretchRatio {
            changes.append("time-stretch (\(old.stretchRatio)× → \(new.stretchRatio)×)")
        }
        if old.pitchShiftSemitones != new.pitchShiftSemitones {
            changes.append("pitch shift (\(old.pitchShiftSemitones) → \(new.pitchShiftSemitones) semitones)")
        }
        if old.gainDb != new.gainDb {
            changes.append("gain (\(old.gainDb) → \(new.gainDb) dB)")
        }
        if old.gainEnvelope != new.gainEnvelope {
            changes.append("gain envelope (\(old.gainEnvelope.count) → \(new.gainEnvelope.count) points)")
        }
        let what = changes.isEmpty ? "geometry" : changes.joined(separator: ", ")
        return "the original clip's \(what) changed since this fix was requested — the bounced "
            + "material no longer lines up; submit again with ai.fixClipRegion"
    }

    /// Transient bounce destination: `NSTemporaryDirectory()/DAWPro/fix-bounce-
    /// <uuid8>.wav` (the `bounceDestination` policy with a fix prefix).
    private static func fixBounceDestination() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("fix-bounce-\(UUID().uuidString.prefix(8)).wav")
    }
}
