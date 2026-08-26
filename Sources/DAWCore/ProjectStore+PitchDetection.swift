import Foundation

/// Pitch-detection store ops (m23-ap-3, the `ProjectStore+Analysis.swift`
/// precedent for a different question — per-frame f0 instead of an
/// aggregate key/tempo read). New domain, own extension file
/// (`ProjectStore.swift` is already 2.3k lines).
@MainActor
extension ProjectStore {

    /// Per-frame pitch detection over an AUDIO clip's current SOURCE window
    /// (m23-ap-3, wiring m23-ap-2b's `PitchTracker`/`SwiftF0PitchTracker`):
    /// forwards to the engine's offline `detectPitch` (content is
    /// SOURCE-domain, the `analyzeClipAudio` convention — this clip's
    /// stretch/pitch is ECHOED in the response, never applied to the
    /// numbers).
    ///
    /// `fromSeconds`/`durationSeconds` are SOURCE-FILE-absolute seconds —
    /// the SAME domain `clip.detectTransients`'s `sourceSeconds` and
    /// `clip.analyzeAudio`'s `windowStartSeconds` already use, deliberately,
    /// so a caller correlating this response against either of those needs
    /// no arithmetic (the m23-de Kiffness sequence: detect transients →
    /// split → detect pitch on a fragment, all on one number line). Omitted
    /// `fromSeconds` defaults to the clip's own window start
    /// (`clip.startOffsetSeconds`); omitted `durationSeconds` defaults to
    /// the rest of the clip's current window (the `audio.profileFile`
    /// idiom). See `PitchDetectionResult`'s header for the full
    /// payload-arithmetic reasoning (what's bounded, what isn't, and why).
    ///
    /// `fromSeconds` OUTSIDE the clip's current window is REJECTED (a
    /// teaching `invalidClipEdit`) — the `FileProfiler` "start past EOF"
    /// convention; `durationSeconds` that runs past the window end is
    /// CLAMPED, not rejected (the SAME file's "last window reads shorter"
    /// convention) — `clipWindowDurationSeconds` in the response makes any
    /// clamp visible rather than silent.
    ///
    /// Rejections, verbatim: a MIDI clip (or, structurally unreachable via
    /// any current mutation, an audio clip with no backing file) →
    /// `pitchDetectionRequiresAudioClip`; the backing file missing on disk
    /// (moved/renamed/deleted since import) → a teaching `invalidClipEdit`
    /// (NOT `audioFileNotFound` — that case's fixed wording is
    /// `audio.profileFile`-specific, "check the path", which would mislead
    /// a caller who passed a `clipId`, never a path); `fromSeconds` outside
    /// the clip's current window → a teaching `invalidClipEdit`; headless /
    /// an engine without the capability → `engineUnavailable` (a detection
    /// is never fabricated, the `analyzeAudioContent` precedent).
    ///
    /// Read-only — no `performEdit`, no undo entry, nothing persisted
    /// (detections are regenerable by definition, the transient-map rule).
    /// NOT result-cached — see `ClipPitchAnalyzer`'s header for why.
    public func detectClipPitch(
        clipId: UUID, fromSeconds: Double? = nil, durationSeconds: Double? = nil,
        confidenceThreshold: Double = PitchDetectionDefaults.defaultConfidenceThreshold,
        silenceFloorDbfs: Double = PitchDetectionDefaults.defaultSilenceFloorDbfs
    ) async throws -> ClipPitchDetection {
        guard let (t, c) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI, let url = clip.audioFileURL else {
            throw ProjectError.pitchDetectionRequiresAudioClip(clipId)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString)'s audio file is missing — expected it at "
                + "\(url.path) (it may have been moved, renamed, or deleted since this "
                + "clip was created)")
        }
        let clipWindowStart = clip.startOffsetSeconds
        let clipWindowDuration = clip.sourceWindowSeconds(tempoMap: transport.tempoMap)
        let requestedFrom = fromSeconds ?? clipWindowStart
        guard requestedFrom >= clipWindowStart,
              requestedFrom < clipWindowStart + clipWindowDuration else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString)'s current window is ["
                + String(format: "%.3f", clipWindowStart) + ", "
                + String(format: "%.3f", clipWindowStart + clipWindowDuration)
                + ") seconds in the source file — 'fromSeconds' "
                + String(format: "%.3f", requestedFrom) + " is outside it")
        }
        let remainingInWindow = (clipWindowStart + clipWindowDuration) - requestedFrom
        let requestedDuration = durationSeconds ?? remainingInWindow
        guard requestedDuration > 0 else {
            throw ProjectError.invalidClipEdit("'durationSeconds' must be > 0")
        }
        let clampedDuration = min(requestedDuration, remainingInWindow)
        guard let engine else { throw ProjectError.engineUnavailable }
        let detection = try await engine.detectPitch(
            inFileAt: url, fromSeconds: requestedFrom, durationSeconds: clampedDuration,
            confidenceThreshold: confidenceThreshold, silenceFloorDbfs: silenceFloorDbfs)
        // Async race (spec §8 risk 7, the analyzeClipAudio precedent):
        // re-locate by id after the await for the stretch/pitch echo. The
        // detection itself is already computed against the window resolved
        // BEFORE the await, so a concurrent edit cannot corrupt the numbers
        // — only the echoed stretch/pitch reflects the clip's state NOW.
        guard let (t2, c2) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let current = tracks[t2].clips[c2]
        return ClipPitchDetection(
            pitch: detection, clipWindowDurationSeconds: clipWindowDuration,
            stretchRatio: current.stretchRatio,
            pitchShiftSemitones: current.pitchShiftSemitones)
    }

    /// Locates a clip by id across every track (extension-local; the
    /// private `locateClip(_:)` in `ProjectStore.swift` is not visible
    /// cross-file — the `analyzeClipAudio`/`transcriptionSource` precedent).
    private func locateClipIndex(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
