import Foundation

/// Wire report for one `take.autoAlign` run (M6 v-d). Codable so the control
/// response IS this struct (wire-never-drifts rule). `offsetMs` is the
/// measured candidate-minus-reference offset (positive = the take was late);
/// applying moves the take by MINUS that offset.
public struct TakeAlignmentReport: Codable, Sendable, Equatable {
    /// Measured offset in milliseconds (median-refined, sub-millisecond).
    public var offsetMs: Double
    /// The same offset converted to beats at the current tempo — exactly what
    /// the apply step subtracted from the lane's `startBeat`.
    public var offsetBeats: Double
    /// Candidate onsets that locked onto a reference onset.
    public var matchedOnsets: Int
    /// Reference-lane onsets found in the overlap window.
    public var referenceOnsets: Int
    /// Candidate-lane onsets found in the overlap window.
    public var candidateOnsets: Int
    /// `matchedOnsets / max(1, min(referenceOnsets, candidateOnsets))`, 0...1.
    public var confidence: Double
    /// True when the lane was (or already sat) aligned by this call; false for
    /// an `apply: false` dry run.
    public var applied: Bool

    public init(offsetMs: Double, offsetBeats: Double, matchedOnsets: Int,
                referenceOnsets: Int, candidateOnsets: Int, confidence: Double, applied: Bool) {
        self.offsetMs = offsetMs
        self.offsetBeats = offsetBeats
        self.matchedOnsets = matchedOnsets
        self.referenceOnsets = referenceOnsets
        self.candidateOnsets = candidateOnsets
        self.confidence = confidence
        self.applied = applied
    }
}

/// Take micro-alignment store op (M6 v-d). AI-generated takes (the "AI Fix N"
/// lanes from `importClipFix`) can land with phrasing a hair early/late vs the
/// recorded performance; this nudges a take lane by a bounded micro-offset so
/// its onsets lock to the group's FIRST lane (the original material — AI Fix
/// groups are built reference-first). Onset detection reuses the ONE shared
/// engine detector (`detectTransients`, content-key cached) that powers
/// `clip.detectTransients` / `clip.quantizeAudio` — no duplicate DSP.
@MainActor
extension ProjectStore {

    /// Measures (and by default corrects) the micro-offset between a take lane
    /// and its group's reference lane. Reference = lane 0; `laneID` = the take
    /// to align (aligning lane 0 against itself is rejected). Onsets are
    /// detected per FILE on the engine, mapped to timeline seconds through
    /// each lane clip's window at the current tempo/stretch (the
    /// `detectClipTransients` mapping), and filtered to the OVERLAP of the two
    /// lanes' spans. `TakeAligner` grid-searches ±`searchWindowMs` and
    /// median-refines the winner.
    ///
    /// `apply: true` → the lane moves by −offset (its onsets land ON the
    /// reference) inside ONE `performEdit("Align Take")` on the same
    /// lane-startBeat + `rebuildCompMembers` machinery `take.move` uses — a
    /// single undo restores the old position. A measured offset of exactly 0
    /// skips the no-op edit (the `moveTakeGroup` delta-0 precedent).
    /// `apply: false` → dry-run preview: no mutation, no undo entry.
    ///
    /// Rejections, verbatim: unknown ids → `trackNotFound` /
    /// `takeGroupNotFound` / `laneNotFound`; lane 0 as the target or a MIDI /
    /// file-less lane → `invalidComp` (message built at throw time); headless
    /// → `engineUnavailable`; a non-positive window → `invalidClipEdit`;
    /// non-overlapping lanes or fewer than 2 matched onsets →
    /// `alignmentInconclusive` (counts + what to try next, built at throw
    /// time); an apply whose earlier-move exceeds the lane's headroom before
    /// beat 0 → `alignmentWouldCrossTimelineStart` (required move + headroom
    /// + take.move advice, built at throw time) — NEVER a silent clamp.
    /// The group/lane are RE-LOCATED after the detection awaits
    /// (deleted mid-detect → the not-found errors; detection is per-file, so
    /// geometry edits during the await are harmless — mapping uses the
    /// CURRENT geometry).
    @discardableResult
    public func autoAlignTake(trackID: UUID, groupID: UUID, laneID: UUID,
                              searchWindowMs: Double = 150,
                              apply: Bool = true) async throws -> TakeAlignmentReport {
        guard searchWindowMs > 0 else {
            throw ProjectError.invalidClipEdit(
                "cannot align with searchWindowMs \(searchWindowMs) — must be > 0")
        }
        // 1. Validate BEFORE the (potentially slow) detection — an agent gets
        //    the actionable error without waiting on analysis.
        let (t, g) = try locateGroup(trackID: trackID, groupID: groupID)
        let (refURL, candURL) = try alignmentLaneURLs(trackIndex: t, groupIndex: g, laneID: laneID)
        guard let engine else { throw ProjectError.engineUnavailable }

        // 2. Detect onsets in both lanes' files (shared detector, content-key
        //    cached; sensitivity 0.5 — the detectClipTransients default).
        let refMarkers = try await engine.detectTransients(inFileAt: refURL, sensitivity: 0.5)
        let candMarkers = try await engine.detectTransients(inFileAt: candURL, sensitivity: 0.5)

        // 3. Re-locate by id after the awaits (the spec §8 risk-7 precedent),
        //    then map onsets through the CURRENT geometry at the CURRENT tempo.
        let (t2, g2) = try locateGroup(trackID: trackID, groupID: groupID)
        _ = try alignmentLaneURLs(trackIndex: t2, groupIndex: g2, laneID: laneID)
        let refClip = tracks[t2].takeGroups[g2].lanes[0].clip
        guard let l2 = tracks[t2].takeGroups[g2].lanes.firstIndex(where: { $0.id == laneID }) else {
            throw ProjectError.laneNotFound
        }
        let candClip = tracks[t2].takeGroups[g2].lanes[l2].clip
        let tempo = transport.tempoBPM
        let secPerBeat = 60.0 / tempo

        // Overlap of the two lanes' spans, in timeline seconds (half-open).
        let overlapStart = max(refClip.startBeat, candClip.startBeat) * secPerBeat
        let overlapEnd = min(refClip.startBeat + refClip.lengthBeats,
                             candClip.startBeat + candClip.lengthBeats) * secPerBeat
        guard overlapEnd > overlapStart else {
            throw ProjectError.alignmentInconclusive(
                "the take and the reference lane do not overlap on the timeline — nothing to "
                + "align; move the take into range with take.move, then align again")
        }
        let refOnsets = timelineOnsetSeconds(clip: refClip, markers: refMarkers, tempoBPM: tempo)
            .filter { $0 >= overlapStart && $0 < overlapEnd }
        let candOnsets = timelineOnsetSeconds(clip: candClip, markers: candMarkers, tempoBPM: tempo)
            .filter { $0 >= overlapStart && $0 < overlapEnd }

        // 4. Align. nil = inconclusive — never guess (v-d rule).
        guard let result = TakeAligner.align(
            referenceOnsets: refOnsets, candidateOnsets: candOnsets,
            searchWindowSeconds: searchWindowMs / 1000.0) else {
            throw ProjectError.alignmentInconclusive(
                "fewer than \(TakeAligner.minimumMatches) onsets matched between the take and the "
                + "reference (reference lane has \(refOnsets.count) onsets in the overlap, the take "
                + "has \(candOnsets.count)) — try a bigger searchWindowMs (up to 500), or nudge the "
                + "take manually with take.move")
        }

        // 5. Apply (or preview). Seconds → beats at the current tempo; the
        //    lane moves by MINUS the measured offset, take.move-style.
        let offsetBeats = result.offsetSeconds * tempo / 60.0
        if apply, offsetBeats != 0 {
            let currentStart = tracks[t2].takeGroups[g2].lanes[l2].clip.startBeat
            let newStart = currentStart - offsetBeats
            // Timeline-start guard (v-d verification fix): a positive offset
            // can need more headroom than the lane has before beat 0. A clamp
            // would silently mis-align while still reporting applied — throw
            // instead; `applied: true` MUST mean the take now sits aligned.
            // Deficits under `alignBeatEpsilon` are FP noise (a lane whose
            // headroom exactly equals the offset), not real clamping — those
            // snap to 0.
            guard newStart >= -Self.alignBeatEpsilon else {
                throw ProjectError.alignmentWouldCrossTimelineStart(
                    "aligning this take means moving it "
                    + "\(String(format: "%.1f", result.offsetSeconds * 1000)) ms "
                    + "(\(String(format: "%.4f", offsetBeats)) beats) earlier, but it starts at beat "
                    + "\(String(format: "%.4f", currentStart)) — only "
                    + "\(String(format: "%.1f", currentStart * secPerBeat * 1000)) ms of headroom "
                    + "before the timeline start; move the group to a later position first "
                    + "(take.move), then align again")
            }
            performEdit("Align Take") {
                tracks[t2].takeGroups[g2].lanes[l2].clip.startBeat = max(0, newStart)
                rebuildCompMembers(trackIndex: t2, groupIndex: g2)
            }
        }
        return TakeAlignmentReport(
            offsetMs: result.offsetSeconds * 1000.0,
            offsetBeats: offsetBeats,
            matchedOnsets: result.matchedOnsets,
            referenceOnsets: result.referenceOnsets,
            candidateOnsets: result.candidateOnsets,
            confidence: result.confidence,
            applied: apply)
    }

    // MARK: - Helpers

    /// FP-noise tolerance for the timeline-start headroom guard (the ClipFix
    /// `beatEpsilon` policy): a computed new start within this of 0 is an
    /// exact-headroom alignment, not a real clamp.
    private static let alignBeatEpsilon = 1e-9

    /// Validates the reference/candidate lane pair and returns both audio
    /// URLs. Shared by the pre-detection fast path and the post-await
    /// revalidation (same checks, same verbatim errors both times).
    private func alignmentLaneURLs(trackIndex t: Int, groupIndex g: Int,
                                   laneID: UUID) throws -> (reference: URL, candidate: URL) {
        let lanes = tracks[t].takeGroups[g].lanes
        guard let l = lanes.firstIndex(where: { $0.id == laneID }) else {
            throw ProjectError.laneNotFound
        }
        guard l != 0 else {
            throw ProjectError.invalidComp(
                "take '\(lanes[0].name)' is the group's first lane — the alignment reference "
                + "itself; pick a later take to align against it")
        }
        let reference = lanes[0]
        let candidate = lanes[l]
        for lane in [reference, candidate] where lane.clip.isMIDI {
            throw ProjectError.invalidComp(
                "take '\(lane.name)' is a MIDI take — take.autoAlign applies only to audio "
                + "takes (MIDI notes already carry their onsets)")
        }
        guard let refURL = reference.clip.audioFileURL else {
            throw ProjectError.invalidComp(
                "take '\(reference.name)' has no audio file to analyze")
        }
        guard let candURL = candidate.clip.audioFileURL else {
            throw ProjectError.invalidComp(
                "take '\(candidate.name)' has no audio file to analyze")
        }
        return (reference: refURL, candidate: candURL)
    }

    /// Maps a lane clip's source-file onset markers to TIMELINE seconds
    /// through the clip's window at `tempoBPM` — the `detectClipTransients`
    /// mapping (`beat = startBeat + (t − windowStart) · stretchRatio ·
    /// tempo/60`) restated in seconds. Half-open window filter (an onset at
    /// the clip's end boundary belongs to the material after it).
    private func timelineOnsetSeconds(clip: Clip, markers: [TransientMarker],
                                      tempoBPM: Double) -> [Double] {
        let windowStart = clip.startOffsetSeconds
        let windowEnd = windowStart + clip.sourceWindowSeconds(tempoBPM: tempoBPM)
        let clipStartSeconds = clip.startBeat * 60.0 / tempoBPM
        return markers
            .filter { $0.timeSeconds >= windowStart && $0.timeSeconds < windowEnd }
            .map { clipStartSeconds + ($0.timeSeconds - windowStart) * clip.stretchRatio }
    }

    /// Locates a take group by track + group id (extension-local; the private
    /// `locateGroup` in ProjectStore+Takes.swift is not visible cross-file).
    /// Throws `trackNotFound` / `takeGroupNotFound`.
    private func locateGroup(trackID: UUID, groupID: UUID) throws -> (t: Int, g: Int) {
        guard let t = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let g = tracks[t].takeGroups.firstIndex(where: { $0.id == groupID }) else {
            throw ProjectError.takeGroupNotFound
        }
        return (t, g)
    }
}
