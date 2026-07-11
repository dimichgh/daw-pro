import Foundation

/// Suno song/vocal generation client — a DORMANT cloud fallback (ACE-Step's
/// local sidecar, via `ACEStepClient`, is the primary `SongGenerating`
/// implementation as of M6). Kept compiling against the reshaped
/// submit/poll protocol with a MINIMAL adaptation, not a full re-verification:
///
/// TODO(verify): the official Suno API endpoint shape, auth, and commercial
/// terms are UNVERIFIED — a standing research item in docs/AI-INTEGRATIONS.md
/// (as of 2026-07-05, no official public Suno API exists at all — see
/// docs/research/2026-07-05-ace-step-local-song-generation.md §8(d)). Base
/// URL and paths are configurable so this adapter can track a real API (or a
/// replacement provider) if/when one ships.
public struct SunoClient: SongGenerating {
    let config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    /// ACE-Step-specific knobs on `request` (duration/seed/bpm/key/etc.) are
    /// NOT forwarded — Suno's request shape for them is unverified, so we
    /// only send what the existing best-effort implementation already sent.
    public func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
        guard let key = config.sunoKey else {
            throw AIServiceError.notConfigured("SUNO_API_KEY")
        }
        var body: [String: Any] = ["prompt": request.prompt]
        if let lyrics = request.lyrics {
            body["lyrics"] = lyrics
        }
        let (data, _) = try await HTTP.postJSON(
            to: config.sunoBaseURL.appendingPathComponent("generate"),
            headers: ["Authorization": "Bearer \(key)"],
            body: body
        )
        let object = try HTTP.json(data)
        // Defensive parsing: accept common id/status field spellings until the
        // real schema is confirmed.
        let jobID = (object["id"] ?? object["job_id"] ?? object["taskId"]) as? String
        guard let jobID else {
            throw AIServiceError.malformedResponse("no job id in response")
        }
        let stateText = (object["status"] as? String) ?? "queued"
        let state = SongGenerationState(rawValue: stateText) ?? .queued
        return SongGenerationSubmission(jobID: jobID, state: state)
    }

    /// Not implemented: there is no verified Suno job-status polling
    /// endpoint (see the type doc above). Throws rather than guessing at a
    /// shape, per house rule (never a silent/fabricated success).
    public func generationStatus(jobID: String) async throws -> SongGenerationStatus {
        throw AIServiceError.notImplemented(
            "Suno job-status polling is not implemented — its API shape is unverified and this " +
                "provider is a dormant fallback (see docs/AI-INTEGRATIONS.md). Use the local " +
                "ACE-Step sidecar (ai.generateSong / ai.generationStatus) instead."
        )
    }

    // MARK: M6 (iii-c) — stems / Lego
    //
    // Minimal adaptation only: there is no verified Suno stem-separation or
    // multi-track-generation API (ACE-Step's local sidecar is the only
    // implementation of these task types today). Both throw rather than
    // guessing at a shape, per house rule (never a silent/fabricated result).

    public func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
        throw AIServiceError.notImplemented(
            "Suno stem extraction is not implemented — this provider is a dormant fallback " +
                "(see docs/AI-INTEGRATIONS.md). Use the local ACE-Step sidecar (ai.extractStems) instead."
        )
    }

    public func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
        throw AIServiceError.notImplemented(
            "Suno per-track (Lego) generation is not implemented — this provider is a dormant " +
                "fallback (see docs/AI-INTEGRATIONS.md). Use the local ACE-Step sidecar (ai.legoGenerate) instead."
        )
    }
}
