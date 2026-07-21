import Foundation

/// Imported-audio content analysis store ops (m21-e,
/// design-clip-analyze-audio §4). New domains live in extension files
/// (ProjectStore.swift is 2.3k lines); this one is analysis, not quantize.
@MainActor
extension ProjectStore {

    /// Key / tempo / spectral-balance / level analysis of an AUDIO clip's
    /// CURRENT source window `[startOffsetSeconds, +sourceWindowSeconds)`
    /// (m21-e): forwards to the engine's offline `analyzeAudioContent`
    /// (content-key cached per file + window, async because analysis is),
    /// then attaches the clip's stretch/pitch echo and — for non-identity
    /// clips — the derived `playback` projection. Results are SOURCE-domain;
    /// the projection is derived, never measured.
    ///
    /// Rejections, verbatim: a MIDI clip → `analysisRequiresAudioClip`;
    /// unknown id → `clipNotFound`; a window shorter than 1 s → a teaching
    /// `invalidClipEdit`; headless (no engine) → `engineUnavailable`. Clip
    /// validation comes FIRST (the `detectClipTransients` ordering) so
    /// headless callers get the actionable rejection. The clip is RE-LOCATED
    /// after the await (spec §8 risk 7): deleted mid-analysis →
    /// `clipNotFound`; window edits mid-flight are harmless — the result
    /// matches the requested window, and the echo reflects the clip's
    /// current stretch/pitch.
    ///
    /// Read-only — no `performEdit`, no undo entry, nothing persisted
    /// (analyses are regenerable by definition, the transient-map rule).
    public func analyzeClipAudio(clipId: UUID) async throws -> ClipAudioAnalysisResult {
        guard let (t, c) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI else {
            throw ProjectError.analysisRequiresAudioClip(clipId)
        }
        guard let url = clip.audioFileURL else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString) has no audio file to analyze")
        }
        let windowStart = clip.startOffsetSeconds
        let windowDuration = clip.sourceWindowSeconds(tempoMap: transport.tempoMap)
        guard windowDuration >= 1.0 else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString) window is "
                + String(format: "%.2f", windowDuration)
                + " s — too short to analyze (needs >= 1.0 s; tempo needs >= 6 s)")
        }
        guard let engine else { throw ProjectError.engineUnavailable }
        let analysis = try await engine.analyzeAudioContent(
            inFileAt: url, windowStartSeconds: windowStart,
            windowDurationSeconds: windowDuration)
        // Async race (spec §8 risk 7): re-locate by id after the await.
        guard let (t2, c2) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let current = tracks[t2].clips[c2]
        return ClipAudioAnalysisResult(
            analysis: analysis,
            stretchRatio: current.stretchRatio,
            pitchShiftSemitones: current.pitchShiftSemitones,
            playback: Self.playbackProjection(
                analysis: analysis, stretchRatio: current.stretchRatio,
                pitchShiftSemitones: current.pitchShiftSemitones))
    }

    /// The derived playback block (design §4): nil for identity clips
    /// (omitted on the wire). bpm scales by 1/stretchRatio (a 2× stretch
    /// halves the sounding tempo); the key transposes by the pitch shift
    /// only when the shift is integral within ±0.01 semitones — a
    /// fractional shift lands between named keys, and nil is the honest
    /// encoding.
    private static func playbackProjection(
        analysis: AudioContentAnalysis, stretchRatio: Double,
        pitchShiftSemitones: Double
    ) -> ClipPlaybackProjection? {
        guard stretchRatio != 1 || pitchShiftSemitones != 0 else { return nil }
        let bpm = stretchRatio > 0
            ? analysis.tempo.bpm.map { $0 / stretchRatio } : nil
        var tonic: String?
        var mode: String?
        let rounded = pitchShiftSemitones.rounded()
        if abs(pitchShiftSemitones - rounded) <= 0.01,
           let index = KeyEstimate.pitchClassesSharp.firstIndex(of: analysis.key.tonic) {
            let shifted = (((index + Int(rounded)) % 12) + 12) % 12
            tonic = KeyEstimate.pitchClassesSharp[shifted]
            mode = analysis.key.mode
        }
        return ClipPlaybackProjection(bpm: bpm, keyTonic: tonic, keyMode: mode)
    }

    /// Locates a clip by id across every track (extension-local; the private
    /// `locateClip(_:)` in ProjectStore.swift is not visible cross-file).
    private func locateClipIndex(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
