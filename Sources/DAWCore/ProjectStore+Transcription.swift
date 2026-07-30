import Foundation

/// Speech-to-text source resolution (m23-n2b, `clip.transcribe`). DAWCore
/// stays AI-free (it never imports AIServices, the `voiceConversionSource`
/// precedent in `ProjectStore+VoiceConversion.swift`), so this hands back
/// the plain values `AIServices.WhisperTranscriptionRequest` needs for
/// `CommandRouter` (which already imports both) to assemble.
///
/// New domain, own extension file (`ProjectStore.swift` is already 2.3k
/// lines) — the `ProjectStore+Analysis.swift` precedent.
@MainActor
extension ProjectStore {
    /// One clip's transcription source: which file, which slice of it (in
    /// SOURCE seconds — the domain `Clip.sourceWindowSeconds(tempoMap:)`
    /// already speaks), and where that slice's start sits on the PROJECT
    /// timeline (in beats). Mirrors `WhisperTranscriptionRequest`'s shape
    /// exactly, one field at a time, so the caller assembles that type by a
    /// pure re-labelling — never a second computation.
    public struct ClipTranscriptionSource: Sendable, Equatable {
        public let audioURL: URL
        public let startSeconds: Double
        public let endSeconds: Double
        public let anchorBeat: Double
        public let tempoMap: TempoMap
    }

    /// Resolves `clip.transcribe`'s `clipId` param.
    ///
    /// `audioURL`/`startSeconds`/`endSeconds` come from
    /// `Clip.sourceWindowSeconds(tempoMap:)` — THE single evaluator of how
    /// much of the source file this clip reads (Model.swift) — so this can
    /// never diverge from what the engine itself would play for the clip.
    /// `anchorBeat` is the clip's own `startBeat`: the project beat that
    /// `startSeconds` sits on.
    ///
    /// - Throws: `clipNotFound` for an unknown id; `transcriptionRequiresAudioClip`
    ///   for a MIDI clip (or, structurally unreachable via any current
    ///   mutation, an audio clip with no backing file);
    ///   `transcriptionRequiresUnstretchedClip` when `stretchRatio != 1` —
    ///   see that case's doc comment in `MediaImporting.swift` for why a
    ///   stretched clip is refused rather than mapped.
    public func transcriptionSource(clipId: UUID) throws -> ClipTranscriptionSource {
        guard let (t, c) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI, let audioFileURL = clip.audioFileURL else {
            throw ProjectError.transcriptionRequiresAudioClip(clipId)
        }
        guard clip.stretchRatio == 1 else {
            throw ProjectError.transcriptionRequiresUnstretchedClip(clipId, ratio: clip.stretchRatio)
        }
        let startSeconds = clip.startOffsetSeconds
        let windowSeconds = clip.sourceWindowSeconds(tempoMap: transport.tempoMap)
        return ClipTranscriptionSource(
            audioURL: audioFileURL,
            startSeconds: startSeconds,
            endSeconds: startSeconds + windowSeconds,
            anchorBeat: clip.startBeat,
            tempoMap: transport.tempoMap)
    }

    /// Locates a clip by id across every track (extension-local; the
    /// private `locateClip(_:)` in `ProjectStore.swift` is not visible
    /// cross-file — the `analyzeClipAudio`/audio-quantize precedent).
    private func locateClipIndex(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
