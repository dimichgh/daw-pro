import DAWCore
import AIServices

/// Adapts AIServices' `SongGenerating` to DAWCore's `GenerationImporting` seam
/// so `ProjectStore.importGeneration` (M6 iii-a) can reach a finished job's
/// local audio + metas WITHOUT DAWCore depending on AIServices/networking —
/// the same bridge role `AudioFileImporter` plays for `MediaImporting`.
///
/// The seam IS the status poll: a succeeded job already carries a fetched
/// `audioPath` (the client downloaded it once on the first succeeded poll) and
/// the upstream `metas` DAW Pro adopts on import. So this is a thin re-poll +
/// field copy; an unknown/expired/failed job THROWS the client's own
/// `ACEStepError` (jobNotFound/jobFailed), which the router surfaces verbatim.
struct SongGenerationImportSource: GenerationImporting {
    let generator: any SongGenerating

    func fetchGeneration(jobID: String) async throws -> GeneratedSongResult {
        let status = try await generator.generationStatus(jobID: jobID)
        return GeneratedSongResult(
            state: status.state.rawValue,
            audioPath: status.audioPath,
            prompt: status.prompt,
            bpm: status.bpm,
            durationSeconds: status.durationSeconds,
            genres: status.genres,
            keyScale: status.keyScale,
            timeSignature: status.timeSignature)
    }

    /// M6 (iii-c): the multi-result sibling — SAME status poll
    /// (`generationStatus` handles a composite stems/Lego job id
    /// transparently, see `ACEStepClient`), just reading `stems` instead of
    /// `audioPath`.
    func fetchGenerationStems(jobID: String) async throws -> GeneratedStemsResult {
        let status = try await generator.generationStatus(jobID: jobID)
        let stems = (status.stems ?? []).map {
            GeneratedStem(
                trackName: $0.trackName, audioPath: $0.audioPath,
                bpm: $0.bpm, durationSeconds: $0.durationSeconds)
        }
        return GeneratedStemsResult(state: status.state.rawValue, stems: stems)
    }

    /// M6 (v-b): the AI hop of the clip vocal-fix flow — maps DAWCore's
    /// provider-agnostic `ClipRepaintRequest` onto AIServices' `RepaintRequest`
    /// and submits ONE repaint job (a single jobId, polled through the ordinary
    /// `generationStatus` surface exactly like v-a `ai.repaintAudio`).
    func submitRepaint(_ request: ClipRepaintRequest) async throws -> ClipFixJobReceipt {
        var repaint = RepaintRequest(srcAudioPath: request.sourceAudioPath,
                                     startSeconds: request.startSeconds)
        repaint.endSeconds = request.endSeconds
        repaint.prompt = request.prompt
        repaint.lyrics = request.lyrics
        repaint.mode = RepaintMode(rawValue: request.mode.rawValue) ?? .balanced
        repaint.strength = request.strength
        repaint.seed = request.seed
        repaint.model = request.model
        // wavCrossfadeSec / latentCrossfadeFrames deliberately left nil: the
        // upstream latent-crossfade default (≈0.4 s) is the boundary-quality
        // mechanism, and the comp splice + 10 ms take crossfade own the
        // timeline-side joins — a WAV crossfade would double-smear the seam.
        let submission = try await generator.repaintAudio(repaint)
        return ClipFixJobReceipt(jobID: submission.jobID, queuePosition: submission.queuePosition)
    }
}
