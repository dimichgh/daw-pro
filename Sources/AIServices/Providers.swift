import Foundation

/// Provider-agnostic capability interfaces. Callers depend on these, never on
/// a concrete vendor, so providers can be swapped from config.

public protocol LyricsGenerating: Sendable {
    /// Returns section-labeled lyrics ([Verse], [Chorus], ...) for the prompt.
    func generateLyrics(theme: String, style: String?) async throws -> String
}

/// Reshaped for M6 (ii): song generation is an ASYNC JOB (ACE-Step generation
/// against the local sidecar commonly takes minutes — see `ACEStepClient`),
/// so the protocol is submit-then-poll rather than a single request/response
/// call. `ACEStepClient` is the primary implementation; `SunoClient` is a
/// dormant cloud fallback (see docs/AI-INTEGRATIONS.md) adapted minimally to
/// this shape — its `generationStatus` is not implemented (no verified Suno
/// polling endpoint exists) rather than guessing at one.
public protocol SongGenerating: Sendable {
    /// Submit a generation job. Returns immediately with the provider's job
    /// id and its initial state — callers poll `generationStatus` from here.
    func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission

    /// Poll a previously submitted job. Implementations that support local
    /// audio retrieval (currently `ACEStepClient`) fetch the finished audio
    /// to a local file THE FIRST TIME a poll observes `state == .succeeded`
    /// and report its path via `audioPath`; subsequent polls of the same job
    /// return the same cached path without re-downloading. A job that has
    /// failed upstream is surfaced by THROWING (never returned as a
    /// `.failed`-state value) so callers get one unambiguous error path.
    func generationStatus(jobID: String) async throws -> SongGenerationStatus
}

/// Provider-agnostic song-generation request. Fields beyond `prompt`/`lyrics`
/// are optional generation knobs; a provider that doesn't support a given
/// knob (e.g. `SunoClient`, whose API shape is unverified) simply ignores it
/// — see each conformance for exactly what it forwards.
public struct SongGenerationRequest: Sendable, Equatable {
    /// Style/caption text — genre, mood, instrumentation, era, production
    /// style, vocal character, e.g. "80s synth-pop, anthemic, driving bass".
    public var prompt: String
    /// Section-labeled lyrics in the bracketed-structure format, e.g.
    /// `"[Verse 1]\nWalking home in the rain\n[Chorus]\nWe rise together"`.
    /// `nil` (or blank) requests an INSTRUMENTAL track.
    public var lyrics: String?
    /// Target length in seconds. `nil` lets the provider pick its own
    /// default (ACE-Step: 30s). ACE-Step's documented stable range is
    /// roughly 30-240s (10-600s is technically accepted but longer takes
    /// show more structural drift per its own docs).
    public var durationSeconds: Double?
    /// Deterministic seed for reproducible output; `nil` = a fresh random
    /// seed each call. Provide the same seed + request to reproduce a prior
    /// render.
    public var seed: Int?
    /// Target tempo in BPM (ACE-Step's documented range is roughly 30-300).
    public var bpm: Int?
    /// Free-text key/scale hint, e.g. `"C Major"`, `"A Minor"`.
    public var keyScale: String?
    /// Free-text time-signature hint, e.g. `"4/4"`, `"3/4"`.
    public var timeSignature: String?
    /// ISO-ish language code for sung vocals, e.g. `"en"`, `"ja"`, `"es"`.
    public var vocalLanguage: String
    /// Diffusion classifier-free-guidance scale — higher follows the
    /// prompt/lyrics more strictly at some cost to naturalness (ACE-Step
    /// default 7.0).
    public var guidanceScale: Double?
    /// Diffusion sampling steps — more steps can improve quality at the cost
    /// of generation time (ACE-Step's turbo default is 8, distilled from 50).
    public var inferenceSteps: Int?
    /// Output container/codec requested from the provider. Defaults to
    /// `"wav"` here (NOTE: this overrides ACE-Step's own upstream default of
    /// `"mp3"` — DAW Pro imports/renders in lossless formats, so we ask for
    /// lossless at the source rather than transcode).
    public var audioFormat: String

    public init(
        prompt: String,
        lyrics: String? = nil,
        durationSeconds: Double? = nil,
        seed: Int? = nil,
        bpm: Int? = nil,
        keyScale: String? = nil,
        timeSignature: String? = nil,
        vocalLanguage: String = "en",
        guidanceScale: Double? = nil,
        inferenceSteps: Int? = nil,
        audioFormat: String = "wav"
    ) {
        self.prompt = prompt
        self.lyrics = lyrics
        self.durationSeconds = durationSeconds
        self.seed = seed
        self.bpm = bpm
        self.keyScale = keyScale
        self.timeSignature = timeSignature
        self.vocalLanguage = vocalLanguage
        self.guidanceScale = guidanceScale
        self.inferenceSteps = inferenceSteps
        self.audioFormat = audioFormat
    }
}

/// Clean, provider-agnostic job states — mapped from whatever the concrete
/// provider's wire status looks like (see `ACEStepClient` for ACE-Step's own
/// `queued`/`running`/`succeeded`/`failed` -> here mapping).
public enum SongGenerationState: String, Codable, Sendable, Equatable {
    case queued
    case running
    case succeeded
    case failed
}

/// Response to a fresh `generateSong` submission.
public struct SongGenerationSubmission: Codable, Sendable, Equatable {
    public var jobID: String
    public var state: SongGenerationState
    /// Position in the provider's queue, when it reports one (ACE-Step
    /// always does on submission; `nil` for providers that don't).
    public var queuePosition: Int?

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case state
        case queuePosition
    }

    public init(jobID: String, state: SongGenerationState, queuePosition: Int? = nil) {
        self.jobID = jobID
        self.state = state
        self.queuePosition = queuePosition
    }
}

/// Response to a `generationStatus` poll (never returned for a failed job —
/// see the protocol doc).
public struct SongGenerationStatus: Codable, Sendable, Equatable {
    public var jobID: String
    public var state: SongGenerationState
    /// 0...1 when the provider reports it; `1.0` once `state == .succeeded`.
    public var progress: Double?
    /// Provider-reported coarse stage text (ACE-Step: "queued"/"running").
    public var stage: String?
    /// Provider-reported human-readable progress line, when available (e.g.
    /// ACE-Step's last worker log line) — informational only.
    public var statusText: String?
    /// Local filesystem path to the finished audio, populated once
    /// `state == .succeeded` (see the protocol doc re: fetch-once caching).
    public var audioPath: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case state, progress, stage, statusText, audioPath
    }

    public init(
        jobID: String,
        state: SongGenerationState,
        progress: Double? = nil,
        stage: String? = nil,
        statusText: String? = nil,
        audioPath: String? = nil
    ) {
        self.jobID = jobID
        self.state = state
        self.progress = progress
        self.stage = stage
        self.statusText = statusText
        self.audioPath = audioPath
    }
}

public protocol ImageGenerating: Sendable {
    /// Returns raw PNG data.
    func generateImage(prompt: String, size: String) async throws -> Data
}

// MARK: - Shared HTTP plumbing

enum HTTP {
    static func postJSON(
        to url: URL,
        headers: [String: String],
        body: [String: Any]
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIServiceError.requestFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            )
        }
        return (data, status)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.malformedResponse("top-level JSON is not an object")
        }
        return object
    }
}
