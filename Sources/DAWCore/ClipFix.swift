import Foundation

/// Clip vocal-fix flow (M6 v-b). Pure, headless value types + a deterministic
/// planner for the window math and the comp splice. DAWCore stays AI/network/
/// engine-free: the AI hop rides the additive `GenerationImporting.submitRepaint`
/// seam, the audio hop rides `AudioEngineControlling.renderOffline`; everything
/// here is `Sendable` data the `@MainActor` store composes.

/// Regeneration intensity for a clip-region AI fix. DAWCore-side mirror of the
/// provider's repaint mode (raw values are the wire contract; the DAWControl
/// adapter maps 1:1 onto AIServices.RepaintMode).
public enum ClipFixMode: String, Codable, Sendable, CaseIterable {
    case conservative, balanced, aggressive
}

/// What the store hands the generation seam to submit (provider-agnostic). The
/// window is expressed in SECONDS within the bounced file (`sourceAudioPath`).
public struct ClipRepaintRequest: Sendable, Equatable {
    public var sourceAudioPath: String
    /// Repaint window WITHIN the bounced file, in seconds.
    public var startSeconds: Double
    public var endSeconds: Double
    public var prompt: String?
    public var lyrics: String?
    public var mode: ClipFixMode
    /// 0…1, consulted upstream in balanced mode only.
    public var strength: Double?
    public var seed: Int?
    public var model: String?

    public init(
        sourceAudioPath: String,
        startSeconds: Double,
        endSeconds: Double,
        prompt: String? = nil,
        lyrics: String? = nil,
        mode: ClipFixMode = .balanced,
        strength: Double? = nil,
        seed: Int? = nil,
        model: String? = nil
    ) {
        self.sourceAudioPath = sourceAudioPath
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.prompt = prompt
        self.lyrics = lyrics
        self.mode = mode
        self.strength = strength
        self.seed = seed
        self.model = model
    }
}

/// Seam receipt (jobID + queue position — the `SongGenerationSubmission` subset
/// DAWCore needs to register a pending fix and echo it).
public struct ClipFixJobReceipt: Sendable, Equatable {
    public var jobID: String
    public var queuePosition: Int?

    public init(jobID: String, queuePosition: Int? = nil) {
        self.jobID = jobID
        self.queuePosition = queuePosition
    }
}

/// Response of `ProjectStore.fixClipRegion` — the placement echo agents/tests
/// assert. Absolute timeline beats + the file-domain repaint window.
public struct ClipFixSubmission: Codable, Sendable, Equatable {
    public var jobID: String
    public var state: String
    public var queuePosition: Int?
    public var windowStartBeat: Double
    public var windowEndBeat: Double
    public var regionStartBeat: Double
    public var regionEndBeat: Double
    public var repaintStartSeconds: Double
    public var repaintEndSeconds: Double
    public var bouncePath: String

    private enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case state, queuePosition
        case windowStartBeat, windowEndBeat, regionStartBeat, regionEndBeat
        case repaintStartSeconds, repaintEndSeconds, bouncePath
    }

    public init(
        jobID: String,
        state: String,
        queuePosition: Int? = nil,
        windowStartBeat: Double,
        windowEndBeat: Double,
        regionStartBeat: Double,
        regionEndBeat: Double,
        repaintStartSeconds: Double,
        repaintEndSeconds: Double,
        bouncePath: String
    ) {
        self.jobID = jobID
        self.state = state
        self.queuePosition = queuePosition
        self.windowStartBeat = windowStartBeat
        self.windowEndBeat = windowEndBeat
        self.regionStartBeat = regionStartBeat
        self.regionEndBeat = regionEndBeat
        self.repaintStartSeconds = repaintStartSeconds
        self.repaintEndSeconds = repaintEndSeconds
        self.bouncePath = bouncePath
    }
}

/// The geometry a plain-clip fix freezes at submit so import can prove the
/// bounced material still matches what the target lane will play (D6). Only a
/// pure `startBeat` delta (a move) is rebasable; any other drift is stale.
public struct ClipGeometryFingerprint: Sendable, Equatable {
    public var startBeat: Double
    public var lengthBeats: Double
    public var startOffsetSeconds: Double
    public var stretchRatio: Double
    public var pitchShiftSemitones: Double
    public var gainDb: Double
    public var gainEnvelope: [ClipGainPoint]

    public init(of clip: Clip) {
        self.startBeat = clip.startBeat
        self.lengthBeats = clip.lengthBeats
        self.startOffsetSeconds = clip.startOffsetSeconds
        self.stretchRatio = clip.stretchRatio
        self.pitchShiftSemitones = clip.pitchShiftSemitones
        self.gainDb = clip.gainDb
        self.gainEnvelope = clip.gainEnvelope
    }

    /// The `startBeat` delta from `self` to `current` when every OTHER field is
    /// unchanged (a pure move — provably safe to rebase, D6), else `nil`
    /// (incompatible drift: trim/re-stretch/re-pitch/re-gain). A delta of `0`
    /// means the geometry is identical.
    public func moveDelta(to current: ClipGeometryFingerprint) -> Double? {
        guard lengthBeats == current.lengthBeats,
              startOffsetSeconds == current.startOffsetSeconds,
              stretchRatio == current.stretchRatio,
              pitchShiftSemitones == current.pitchShiftSemitones,
              gainDb == current.gainDb,
              // The bounce bakes the envelope in (ProjectStore+ClipFix.swift:80),
              // so an envelope edit mid-job is exactly as stale as a gainDb edit.
              gainEnvelope == current.gainEnvelope
        else { return nil }
        return current.startBeat - startBeat
    }
}

/// The frozen target descriptor of an in-flight fix (D6). A plain-clip submit
/// freezes the clip id + fingerprint; a comp-member submit freezes the GROUP id
/// (member clip ids churn on every comp rebuild) + its range.
public enum PendingFixTarget: Sendable, Equatable {
    case clip(id: UUID, fingerprint: ClipGeometryFingerprint)
    case group(id: UUID, frozenRangeStart: Double, frozenRangeEnd: Double)
}

/// One in-flight fix job (in-memory only; NOT persisted — a pending fix does
/// not survive relaunch, documented v0 cut).
public struct PendingClipFix: Sendable, Equatable, Identifiable {
    public var id: String { jobID }
    public var jobID: String
    public var trackID: UUID
    public var target: PendingFixTarget
    public var windowStartBeat: Double
    public var windowLengthBeats: Double
    public var regionStartBeat: Double
    public var regionEndBeat: Double
    /// Tempo/meter map REVISION frozen at submit (m12-d, design row 29) — a
    /// mid-job map change breaks the bounced material's beats↔seconds mapping
    /// (no safe rebase). The staleness check is now this one integer instead of
    /// a whole-map equality: `store.mapRevision` climbs on every map mutation
    /// (undo/redo included), so import rejects with `clipFixStale` whenever it
    /// no longer matches. `regionBPM` is the tempo at the region start frozen at
    /// submit, kept only to render the "was → now BPM" teaching error.
    public var mapRevision: UInt64
    public var regionBPM: Double
    public var submittedAt: Date

    public init(
        jobID: String,
        trackID: UUID,
        target: PendingFixTarget,
        windowStartBeat: Double,
        windowLengthBeats: Double,
        regionStartBeat: Double,
        regionEndBeat: Double,
        mapRevision: UInt64,
        regionBPM: Double,
        submittedAt: Date
    ) {
        self.jobID = jobID
        self.trackID = trackID
        self.target = target
        self.windowStartBeat = windowStartBeat
        self.windowLengthBeats = windowLengthBeats
        self.regionStartBeat = regionStartBeat
        self.regionEndBeat = regionEndBeat
        self.mapRevision = mapRevision
        self.regionBPM = regionBPM
        self.submittedAt = submittedAt
    }
}

/// Result of `ProjectStore.importClipFix`.
public struct ClipFixImportResult: Sendable, Equatable {
    public var trackID: UUID
    public var groupID: UUID
    public var laneID: UUID
    public var laneName: String

    public init(trackID: UUID, groupID: UUID, laneID: UUID, laneName: String) {
        self.trackID = trackID
        self.groupID = groupID
        self.laneID = laneID
        self.laneName = laneName
    }
}

/// Pure planner: context-window math + comp splice. Deterministic, no store
/// access — the whole geometric contract of the clip-fix flow is testable here.
public enum ClipFixPlanner {
    /// Empties thinner than this (in beats) collapse to nothing.
    static let emptyBeats = 1e-9

    /// Clamped context window (D3): `[regionStart − context, regionEnd +
    /// context]` clamped to `[spanStart, spanEnd]`.
    public static func window(regionStart: Double, regionEnd: Double,
                              spanStart: Double, spanEnd: Double,
                              contextBeats: Double) -> (start: Double, end: Double) {
        let start = max(spanStart, regionStart - contextBeats)
        let end = min(spanEnd, regionEnd + contextBeats)
        return (start, end)
    }

    /// Replaces `[regionStart, regionEnd)` in `comp` with a single segment on
    /// `laneID`. Existing segments are trimmed at the region edges; a segment
    /// spanning the whole region splits in two; segments fully inside are
    /// dropped; empties (< `emptyBeats`) are dropped. Output is sorted and
    /// non-overlapping. Gaps stay legal.
    public static func splice(_ comp: [CompSegment],
                              regionStart: Double, regionEnd: Double,
                              laneID: UUID) -> [CompSegment] {
        var result: [CompSegment] = []
        for seg in comp {
            // Left remainder, before the region.
            if seg.startBeat < regionStart {
                let leftEnd = min(seg.endBeat, regionStart)
                if leftEnd - seg.startBeat > emptyBeats {
                    result.append(CompSegment(laneID: seg.laneID,
                                              startBeat: seg.startBeat, endBeat: leftEnd))
                }
            }
            // Right remainder, after the region.
            if seg.endBeat > regionEnd {
                let rightStart = max(seg.startBeat, regionEnd)
                if seg.endBeat - rightStart > emptyBeats {
                    result.append(CompSegment(laneID: seg.laneID,
                                              startBeat: rightStart, endBeat: seg.endBeat))
                }
            }
        }
        // The fix segment itself (only when non-empty).
        if regionEnd - regionStart > emptyBeats {
            result.append(CompSegment(laneID: laneID, startBeat: regionStart, endBeat: regionEnd))
        }
        return result.sorted { $0.startBeat < $1.startBeat }
    }
}
