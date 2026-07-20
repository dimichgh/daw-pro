import Foundation

/// Provider-agnostic capability interfaces. Callers depend on these, never on
/// a concrete vendor, so providers can be swapped from config.

public protocol LyricsGenerating: Sendable {
    /// Returns section-labeled lyrics ([Verse], [Chorus], ...) for the prompt.
    /// The legacy M0 surface — kept for callers that only have a theme/style.
    func generateLyrics(theme: String, style: String?) async throws -> String

    /// M6 lyrics workshop: the richer write/refine surface. Takes a
    /// `LyricsWriteRequest` (theme + optional style + section structure +
    /// project context, or an existing-lyrics/instruction REFINE) and returns
    /// bracketed-structure lyrics plus which provider produced them. A default
    /// implementation bridges to `generateLyrics` for conformers that don't
    /// override it; `AnthropicClient`/`OpenAIClient` DO override, teaching the
    /// bracketed ACE-Step format + singability + weaving in the context.
    func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult
}

public extension LyricsGenerating {
    /// Default bridge so any `LyricsGenerating` gets `writeLyrics` for free (used
    /// by test fakes and any minimal conformer). Concrete provider clients
    /// override this with the full context-aware prompt; the bridge just reuses
    /// the theme/style path and reports the provider as "unknown" (the caller
    /// that resolved a concrete client already knows which one it is).
    func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
        let text = try await generateLyrics(theme: request.prompt, style: request.style)
        return LyricsWriteResult(lyrics: text, provider: "unknown")
    }
}

// MARK: - Lyrics workshop request/result (M6)

/// The project-musical context woven into the lyrics prompt so the words fit the
/// session (key colors the mood, tempo/time-signature shape phrasing/line
/// length, genre sets the vocabulary). Every field is optional — a blank project
/// simply contributes nothing.
public struct LyricsWriteContext: Sendable, Equatable {
    /// Free-text key/scale, e.g. "C Major", "A Minor".
    public var keyScale: String?
    /// Project tempo in BPM.
    public var tempoBPM: Double?
    /// Free-text time signature, e.g. "4/4", "3/4".
    public var timeSignature: String?
    /// Free-text genre/style hint, e.g. "synth-pop", "lofi hip-hop".
    public var genre: String?

    public init(
        keyScale: String? = nil,
        tempoBPM: Double? = nil,
        timeSignature: String? = nil,
        genre: String? = nil
    ) {
        self.keyScale = keyScale
        self.tempoBPM = tempoBPM
        self.timeSignature = timeSignature
        self.genre = genre
    }

    /// True when nothing was supplied (used to skip the context clause entirely).
    public var isEmpty: Bool {
        keyScale.nonEmpty == nil && tempoBPM == nil
            && timeSignature.nonEmpty == nil && genre.nonEmpty == nil
    }
}

/// A lyrics write or refine request for the M6 workshop. WRITE mode: `prompt`
/// (theme, required) + optional `style` + `structure`. REFINE mode: additionally
/// carries `existingLyrics` + `instruction`, which flips the prompt into a
/// revise-these-lyrics task (`isRefine`).
public struct LyricsWriteRequest: Sendable, Equatable {
    /// What the song is about — the theme (required, the one non-optional field).
    public var prompt: String
    /// Optional style/genre guidance, e.g. "90s pop-punk", "slow R&B ballad".
    public var style: String?
    /// Ordered section tags to structure the song, e.g.
    /// `["verse","chorus","verse","chorus","bridge","chorus"]`. Bare names or
    /// already-bracketed forms both work — the prompt builder normalizes them.
    public var structure: [String]
    /// The project's musical context (key/tempo/time-signature/genre).
    public var context: LyricsWriteContext
    /// REFINE mode: the current lyrics to revise. `nil`/blank = WRITE from scratch.
    public var existingLyrics: String?
    /// REFINE mode: how to revise, e.g. "make the chorus more hopeful".
    public var instruction: String?

    /// The default structure when a caller doesn't specify one — a familiar
    /// pop shape (verse/chorus × 2 into a bridge and a final chorus).
    public static let defaultStructure = ["verse", "chorus", "verse", "chorus", "bridge", "chorus"]

    public init(
        prompt: String,
        style: String? = nil,
        structure: [String] = LyricsWriteRequest.defaultStructure,
        context: LyricsWriteContext = LyricsWriteContext(),
        existingLyrics: String? = nil,
        instruction: String? = nil
    ) {
        self.prompt = prompt
        self.style = style
        self.structure = structure
        self.context = context
        self.existingLyrics = existingLyrics
        self.instruction = instruction
    }

    /// True when there are existing lyrics to revise (REFINE mode).
    public var isRefine: Bool {
        existingLyrics.nonEmpty != nil
    }
}

/// The result of a lyrics write/refine: the bracketed lyrics and which provider
/// produced them (`AIProviderID.rawValue`, or "unknown" from the default bridge).
public struct LyricsWriteResult: Sendable, Equatable {
    public var lyrics: String
    public var provider: String

    public init(lyrics: String, provider: String) {
        self.lyrics = lyrics
        self.provider = provider
    }
}

/// Builds the shared system + user prompts for a `LyricsWriteRequest`, so both
/// provider clients teach IDENTICAL bracket-format + singability instructions and
/// weave in the same project context (the suites assert the exact substrings).
public enum LyricsPromptBuilder {
    /// Teaches the bracketed ACE-Step format, singability, and the project
    /// context. In REFINE mode it also instructs the model to preserve structure.
    public static func systemPrompt(_ request: LyricsWriteRequest) -> String {
        var parts: [String] = []
        parts.append("""
        You are a professional lyricist working inside a digital audio workstation. \
        Write complete, singable song lyrics a producer will drop straight into a \
        session and feed to a vocal-synthesis engine.
        """)
        parts.append("""
        FORMAT: use ACE-Step's bracketed-structure format. Put each section tag on \
        its own line in lowercase square brackets — [verse], [chorus], [bridge], \
        [outro] — followed by that section's lyric lines, one lyric per line. Use \
        only these bracketed tags for structure and add no other markup.
        """)
        parts.append("""
        SINGABILITY: keep lines economical (roughly 6-10 syllables) and hold a \
        CONSISTENT syllable count across lines of the same section type, so verses \
        scan against each other and every chorus lands the same way. Favor natural \
        word stress and open vowels on the held notes.
        """)
        if let clause = contextClause(request.context) {
            parts.append(clause)
        }
        if request.isRefine {
            parts.append("""
            You are REVISING the lyrics the user provides according to their \
            instruction. Preserve the bracketed section structure unless the \
            instruction explicitly asks you to change it.
            """)
        }
        parts.append("Return ONLY the lyrics — no title, commentary, or explanation.")
        return parts.joined(separator: "\n\n")
    }

    /// The per-request user turn: theme/style/structure for WRITE, or the
    /// existing lyrics + instruction for REFINE.
    public static func userPrompt(_ request: LyricsWriteRequest) -> String {
        var lines: [String] = []
        if request.isRefine {
            lines.append("Here are the current lyrics to revise:")
            lines.append(request.existingLyrics ?? "")
            if let instruction = request.instruction.nonEmpty {
                lines.append("Revision instruction: \(instruction)")
            }
            if !request.prompt.isEmpty {
                lines.append("Keep them about: \(request.prompt)")
            }
            if let style = request.style.nonEmpty {
                lines.append("Style: \(style)")
            }
        } else {
            lines.append("Theme: \(request.prompt)")
            if let style = request.style.nonEmpty {
                lines.append("Style: \(style)")
            }
            let structure = request.structure.isEmpty
                ? LyricsWriteRequest.defaultStructure : request.structure
            lines.append("Song structure, in order: " + structure.map(bracketed).joined(separator: " "))
            lines.append("Write the full lyrics now, following that structure.")
        }
        return lines.joined(separator: "\n")
    }

    /// "the track is in key/scale C Major, tempo 120 BPM, 4/4" — nil when the
    /// context carries nothing.
    static func contextClause(_ context: LyricsWriteContext) -> String? {
        guard !context.isEmpty else { return nil }
        var facts: [String] = []
        if let key = context.keyScale.nonEmpty { facts.append("key/scale \(key)") }
        if let tempo = context.tempoBPM { facts.append("tempo \(Int(tempo.rounded())) BPM") }
        if let sig = context.timeSignature.nonEmpty { facts.append("\(sig) time") }
        if let genre = context.genre.nonEmpty { facts.append("genre \(genre)") }
        return "PROJECT CONTEXT: the track is in " + facts.joined(separator: ", ")
            + ". Shape phrasing, line length, and mood to fit."
    }

    /// Normalizes a section tag to `[name]`, tolerating an already-bracketed input.
    static func bracketed(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { return trimmed }
        return "[\(trimmed)]"
    }
}

// MARK: - Lyrics provider selection (M6)

/// Picks the lyrics provider from the key-resolution chain: Anthropic when it has
/// a key (env or Keychain), else OpenAI, else `nil`. Reads PRESENCE only (via
/// `resolveKey`) and never returns or logs the key value — the security invariant
/// the whole KeyStore seam enforces (see `KeyStore.swift`).
public func selectLyricsProvider(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: APIKeyStoring?
) -> AIProviderID? {
    if resolveKey(provider: .anthropic, environment: environment, store: store).value != nil {
        return .anthropic
    }
    if resolveKey(provider: .openai, environment: environment, store: store).value != nil {
        return .openai
    }
    return nil
}

/// Resolves a configured lyrics writer: an `AnthropicClient` (preferred) or an
/// `OpenAIClient`, keyed from the resolution chain, with `baseConfig`'s model IDs
/// / base URLs preserved (so a stub-server suite can retarget it). Throws
/// `AIServiceError.noProviderConfigured` — an actionable, key-value-free error —
/// when neither provider has a key.
public func resolveLyricsWriter(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: APIKeyStoring?,
    config baseConfig: AIConfig = AIConfig()
) throws -> any LyricsGenerating {
    switch selectLyricsProvider(environment: environment, store: store) {
    case .anthropic:
        var config = baseConfig
        config.anthropicKey = resolveKey(provider: .anthropic, environment: environment, store: store).value
        return AnthropicClient(config: config)
    case .openai:
        var config = baseConfig
        config.openAIKey = resolveKey(provider: .openai, environment: environment, store: store).value
        return OpenAIClient(config: config)
    default:
        throw AIServiceError.noProviderConfigured(capability: "lyrics")
    }
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

    // MARK: M6 (iii-c) — stems / Lego

    /// Separate an existing source audio file into the requested named stems
    /// (ACE-Step `task_type = "extract"`). Upstream extracts ONE track per
    /// job (verified: `scripts/ace-step/runtime/src/acestep/core/generation/
    /// handler/task_utils.py` `generate_instruction` — `extract`/`lego` both
    /// format a SINGLE `{TRACK_NAME}` into the instruction, and
    /// `generate_music_request.py`'s `_src_audio_required_tasks` requires one
    /// `src_audio_path` per call), so a conforming implementation submits one
    /// upstream job per `StemExtractionRequest.trackNames` entry and groups
    /// them under ONE composite id it returns here. That id polls through the
    /// SAME `generationStatus` above (one status surface, not a parallel
    /// one) — a succeeded poll's `SongGenerationStatus.stems` carries every
    /// named result once all underlying jobs have finished.
    func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission

    /// Generate new tracks that fit an existing source audio's musical
    /// context (ACE-Step `task_type = "lego"` — "Lego": build a song up one
    /// instrument layer at a time). Each requested track carries its own
    /// local `prompt` (verified wire field: `release_task_param_parser.py`'s
    /// `PARAM_ALIASES["prompt"]`, described upstream as "local/per-track
    /// description for lego SFT") alongside the shared `globalCaption`
    /// (`global_caption` — "full song context"). Same one-upstream-job-per-
    /// track / composite-id / shared-status-surface shape as `extractStems`.
    func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission

    // MARK: M6 (v-a) — Repaint

    /// Re-render a WINDOW of an existing audio file in place (ACE-Step
    /// `task_type = "repaint"`) — a "part swap"/inpainting job. Unlike
    /// `extractStems`/`generateLegoTracks`, upstream's repaint is a SINGLE
    /// job (no per-track fan-out), so a conforming implementation submits
    /// ONE upstream job and returns its RAW job id here; that id polls
    /// through the SAME `generationStatus` above exactly like an ordinary
    /// `generateSong` job (one status surface, not a parallel one) — a
    /// succeeded poll's `audioPath` is the full-length file with the window
    /// repainted. A default implementation below throws an actionable
    /// "unsupported" error for any conformer that doesn't override it (only
    /// `ACEStepClient` does, as of M6 v-a). There is NO separate "retake"
    /// task type upstream — a retake is calling this again on the SAME
    /// window with `RepaintRequest.seed == nil` (a fresh random seed).
    func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission
}

public extension SongGenerating {
    /// Default: a conforming provider with no repaint capability of its own
    /// (e.g. `SunoClient`, or a minimal test fake) throws an actionable
    /// "unsupported" error rather than silently no-op-ing or guessing at a
    /// shape it doesn't support — mirrors `LyricsGenerating`'s `writeLyrics`
    /// bridge-default above. `ACEStepClient` overrides this with the real
    /// implementation (M6 v-a).
    func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission {
        throw AIServiceError.notImplemented(
            "repaint is not implemented by this song-generation provider — use the local " +
                "ACE-Step sidecar (ai.repaintAudio) instead."
        )
    }
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

    // MARK: Stems / Lego results (M6 iii-c)
    //
    // Populated ONLY when `jobID` is a composite stems/Lego job id returned
    // by `SongGenerating.extractStems`/`generateLegoTracks`, and only once
    // `state == .succeeded` (every underlying per-track job finished). `nil`
    // for an ordinary single-song job (the M6 ii/iii-a path) — that path is
    // unchanged and keeps reporting its one result via `audioPath` above.

    /// The named per-track results of a finished stems/Lego job — one entry
    /// per requested track name, each with its own fetched-once local audio
    /// path. `nil` unless this poll is for a composite stems/Lego job.
    public var stems: [StemResult]?

    // MARK: Result metadata (M6 iii-a)
    //
    // The remaining fields carry the provider's own analysis of the finished
    // track — for ACE-Step, the succeeded `result` payload's `prompt` sibling
    // and its `metas` object (`bpm`/`duration`/`genres`/`keyscale`/
    // `timesignature`). Every one is populated ONLY on a `.succeeded` poll and
    // ONLY when the provider actually sent that field (all optional, so they
    // are omitted from the wire when nil — a queued/running poll carries none
    // of them). `importGeneration` (via the DAWCore seam) reads them to name
    // the new AI track (`prompt`) and adopt the project tempo (`bpm`).

    /// Original style/caption prompt echoed back by the provider (used to
    /// derive the default "AI: …" track name on import).
    public var prompt: String?
    /// Detected/target tempo in BPM (ACE-Step `metas.bpm`) — the tempo the
    /// project can adopt on import.
    public var bpm: Double?
    /// Actual rendered length in seconds (ACE-Step `metas.duration`).
    public var durationSeconds: Double?
    /// Free-text genre(s) (ACE-Step `metas.genres`; a list is joined with ", ").
    public var genres: String?
    /// Free-text key/scale, e.g. "C Major" (ACE-Step `metas.keyscale`).
    public var keyScale: String?
    /// Free-text time signature, e.g. "4/4" (ACE-Step `metas.timesignature`).
    public var timeSignature: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case state, progress, stage, statusText, audioPath, stems
        case prompt, bpm, durationSeconds, genres, keyScale, timeSignature
    }

    public init(
        jobID: String,
        state: SongGenerationState,
        progress: Double? = nil,
        stage: String? = nil,
        statusText: String? = nil,
        audioPath: String? = nil,
        stems: [StemResult]? = nil,
        prompt: String? = nil,
        bpm: Double? = nil,
        durationSeconds: Double? = nil,
        genres: String? = nil,
        keyScale: String? = nil,
        timeSignature: String? = nil
    ) {
        self.jobID = jobID
        self.state = state
        self.progress = progress
        self.stage = stage
        self.statusText = statusText
        self.audioPath = audioPath
        self.stems = stems
        self.prompt = prompt
        self.bpm = bpm
        self.durationSeconds = durationSeconds
        self.genres = genres
        self.keyScale = keyScale
        self.timeSignature = timeSignature
    }
}

// MARK: - Stems / Lego (M6 iii-c)
//
// Upstream facts verified against `scripts/ace-step/runtime/src/acestep`
// (READ-ONLY, never edited) source, not guessed:
//  - `constants.py`: `TASK_TYPES_BASE` includes "extract"/"lego"/"complete";
//    `TASK_TYPES_TURBO` does NOT — these are BASE-model-only capabilities.
//    RESOLVED (M6 iii-c-real, was an ASSUMPTION-FLAG here): a freshly
//    started sidecar's primary handler loads only the turbo tier
//    (`ACESTEP_CONFIG_PATH=acestep-v15-xl-turbo` by default). Upstream does
//    NOT reject `task_type=extract`/`lego` on turbo, though — verified
//    against `api/job_model_selection.py`'s `select_generation_handler`, an
//    unmatched/unloaded `model` name just logs "using primary" and SILENTLY
//    runs the job on turbo anyway (unproven quality for these task types).
//    `ACEStepClient` closes this gap itself rather than leaving it to the
//    caller: `StemExtractionRequest`/`LegoGenerationRequest.model` left
//    `nil` defaults to `ACEStepClient.defaultStemsModel`
//    (`"acestep-v15-xl-sft"`, already downloaded by `install.sh`), and the
//    client ensures that model is actually loaded (via `POST /v1/init` into
//    slot 2, `scripts/ace-step/run.sh` now sets `ACESTEP_CONFIG_PATH2` so
//    that slot exists to init into) before the job's first `/release_task`.
//  - `constants.py` `TRACK_NAMES`: the fixed stem vocabulary — "woodwinds",
//    "brass", "fx", "synth", "strings", "percussion", "keyboard", "guitar",
//    "bass", "drums", "backing_vocals", "vocals". Not re-enumerated as a
//    Swift enum here (the sidecar is authoritative on validity — hardcoding
//    would silently drift); `trackName` is a free string.
//  - `core/generation/handler/task_utils.py` (`generate_instruction`) and
//    `core/generation/handler/generate_music_request.py`
//    (`_src_audio_required_tasks`): both "extract" and "lego" are
//    SINGLE-track-per-job upstream and both REQUIRE `src_audio_path` — Lego
//    generates a new track conditioned on existing source audio, it is not a
//    from-scratch per-track generator. To produce N stems/tracks a client
//    submits N `/release_task` calls against the SAME source audio.
//  - `api/http/release_task_param_parser.py` `PARAM_ALIASES`: wire field
//    names `task_type`, `track_name`, `track_classes`, `global_caption`,
//    `prompt` (the LOCAL per-track description), `src_audio_path`, `model`.
//  - `api/http/release_task_audio_paths.py` `validate_audio_path`: accepts
//    `src_audio_path` only if its realpath resolves inside the SIDECAR
//    process's own system temp directory (`tempfile.gettempdir()`), or a
//    relative path with no ".." traversal — an absolute path outside temp is
//    a 400. This is the "temp-dir allowlist" — see `ACEStepClient`'s staging
//    step for how the client satisfies it (loopback-only: sidecar + client
//    share the same machine/user, so `$TMPDIR` matches).

/// One named track requested from a stems/Lego job.
public struct StemTrackRequest: Sendable, Equatable {
    /// One of ACE-Step's fixed track-name vocabulary (see the type-group doc
    /// above), e.g. "vocals", "drums", "bass".
    public var trackName: String
    /// Lego only: this track's own local description (upstream's `prompt`
    /// field — "local/per-track description for lego SFT"). Ignored for
    /// extraction, where the track already exists in the source audio.
    public var localPrompt: String?

    public init(trackName: String, localPrompt: String? = nil) {
        self.trackName = trackName
        self.localPrompt = localPrompt
    }
}

/// Separate an existing audio file into named stems (ACE-Step
/// `task_type = "extract"`). See the type-group doc above: upstream extracts
/// ONE track per job, so a conforming client submits one upstream job per
/// `trackNames` entry, all against the same `sourceAudioPath`.
public struct StemExtractionRequest: Sendable, Equatable {
    /// Local filesystem path to the existing mixed-down audio to separate.
    public var sourceAudioPath: String
    /// Stem names to extract, e.g. `["vocals", "drums", "bass"]`.
    public var trackNames: [String]
    /// DiT model to request (upstream `model`), e.g. `"acestep-v15-xl-sft"`
    /// — extract/lego need a BASE-tier model (see the ASSUMPTION-FLAG in the
    /// type-group doc above). `nil`/empty does NOT hit the sidecar's own
    /// default — `ACEStepClient` substitutes its own stems default instead
    /// (currently `ACEStepClient.defaultStemsModel`, `"acestep-v15-xl-sft"`)
    /// and ensures that model is actually loaded before submitting (M6
    /// iii-c-real), because the sidecar's own default is turbo, which does
    /// not officially support these task types and upstream would otherwise
    /// silently run the job on it anyway. Set this explicitly to override
    /// the client's default with a different model name.
    public var model: String?

    public init(sourceAudioPath: String, trackNames: [String], model: String? = nil) {
        self.sourceAudioPath = sourceAudioPath
        self.trackNames = trackNames
        self.model = model
    }
}

/// Generate new tracks that fit an existing source audio's musical context
/// (ACE-Step `task_type = "lego"`), each described by a shared
/// `globalCaption` (upstream "full song context") plus its own local
/// prompt. Same one-upstream-job-per-track shape as `StemExtractionRequest`.
public struct LegoGenerationRequest: Sendable, Equatable {
    /// Local filesystem path to the existing audio the new tracks must fit.
    public var sourceAudioPath: String
    /// Shared song-level description (upstream `global_caption`).
    public var globalCaption: String
    /// The tracks to generate, each with its own local prompt.
    public var tracks: [StemTrackRequest]
    /// DiT model to request — see `StemExtractionRequest.model` (same
    /// nil-means-the-client's-stems-default, currently
    /// `ACEStepClient.defaultStemsModel`, behavior).
    public var model: String?

    public init(
        sourceAudioPath: String, globalCaption: String, tracks: [StemTrackRequest], model: String? = nil
    ) {
        self.sourceAudioPath = sourceAudioPath
        self.globalCaption = globalCaption
        self.tracks = tracks
        self.model = model
    }
}

/// Submission response for a stems/Lego job. `jobID` is a COMPOSITE id (the
/// client's own construction, grouping N real upstream task ids) that polls
/// through `SongGenerating.generationStatus` exactly like an ordinary song
/// job — one status surface, not a parallel one (see the protocol doc).
public struct StemGenerationSubmission: Codable, Sendable, Equatable {
    public var jobID: String
    public var state: SongGenerationState
    /// Track names accepted into this job, in submission order.
    public var trackNames: [String]

    enum CodingKeys: String, CodingKey {
        case jobID = "jobId"
        case state
        case trackNames
    }

    public init(jobID: String, state: SongGenerationState, trackNames: [String]) {
        self.jobID = jobID
        self.state = state
        self.trackNames = trackNames
    }
}

/// One named result inside a succeeded stems/Lego job's
/// `SongGenerationStatus.stems`.
public struct StemResult: Codable, Sendable, Equatable {
    public var trackName: String
    /// Local filesystem path to this track's fetched-once finished audio.
    public var audioPath: String
    /// Detected/target tempo in BPM, when the provider reports one for this
    /// track (ACE-Step `metas.bpm`, per sub-job — may differ track to track).
    public var bpm: Double?
    /// Rendered length in seconds, when reported (ACE-Step `metas.duration`).
    public var durationSeconds: Double?

    public init(trackName: String, audioPath: String, bpm: Double? = nil, durationSeconds: Double? = nil) {
        self.trackName = trackName
        self.audioPath = audioPath
        self.bpm = bpm
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Repaint (M6 v-a)
//
// Upstream facts verified against `scripts/ace-step/runtime/src/acestep`
// (READ-ONLY, never edited) source, not guessed:
//  - `constants.py`: `TASK_TYPES_TURBO = ["text2music", "repaint", "cover",
//    "cover-nofsq"]` — repaint works on BOTH the turbo (primary, the
//    sidecar's default load) and sft tiers, UNLIKE extract/lego (base-model
//    only, see the type-group doc above). A `nil` `RepaintRequest.model`
//    therefore does NOT trigger `ACEStepClient`'s stems-style default
//    substitution/ensure-load — it is passed straight through, letting the
//    sidecar's primary handler serve it.
//  - `api/http/release_task_models.py`: `task_type: "repaint"`,
//    `src_audio_path` (REQUIRED — staged into the shared temp-dir allowlist
//    exactly like `StemExtractionRequest.sourceAudioPath`),
//    `repainting_start: float = 0.0` (seconds), `repainting_end:
//    Optional[float]`, `repaint_mode: "conservative"|"balanced"|
//    "aggressive"` (default "balanced"), `repaint_strength: float 0.0-1.0`
//    (consulted only in "balanced" mode), `repaint_wav_crossfade_sec: float
//    = 0.0`, `repaint_latent_crossfade_frames: int = 10` (25 Hz frames, 10
//    ~= 0.4s), plus the usual `prompt`/`lyrics`/`use_random_seed`/`seed`.
//  - There is NO upstream "retake" task type — see the `repaintAudio`
//    protocol doc above for how a retake is expressed.

/// How strongly ACE-Step-1.5 regenerates a repainted window (upstream
/// `repaint_mode`, verified in `release_task_models.py`).
public enum RepaintMode: String, Sendable, Equatable, CaseIterable {
    /// Stays closest to the original audio in the window.
    case conservative
    /// The default trade-off; `RepaintRequest.strength` is only consulted
    /// upstream when the mode is `.balanced`.
    case balanced
    /// Most freely reimagines the window.
    case aggressive
}

/// Re-render a window of an existing audio file in place (ACE-Step
/// `task_type = "repaint"`). See the type-group doc above for the verified
/// wire shape and why `model` behaves differently here than on
/// `StemExtractionRequest`/`LegoGenerationRequest`.
public struct RepaintRequest: Sendable, Equatable {
    /// Local filesystem path to the existing audio file whose window gets
    /// repainted. Staged into the sidecar's temp-dir allowlist exactly like
    /// `StemExtractionRequest.sourceAudioPath` — any readable local path works.
    public var srcAudioPath: String
    /// Start of the window to repaint, in seconds from the top of the file.
    public var startSeconds: Double
    /// End of the window, in seconds; `nil` repaints from `startSeconds` to
    /// the end of the file (upstream `repainting_end: Optional[float]`).
    public var endSeconds: Double?
    /// Style/caption text guiding the repainted window; `nil` reuses the
    /// source's own musical context.
    public var prompt: String?
    /// Section-labeled lyrics for the repainted window, when it carries
    /// vocals; `nil`/blank leaves the window's vocal content to the model.
    public var lyrics: String?
    /// How strongly to regenerate the window. Defaults to `.balanced`,
    /// matching upstream's own default.
    public var mode: RepaintMode
    /// 0.0-1.0; ONLY consulted by upstream when `mode == .balanced`. `nil`
    /// lets the sidecar pick its own default.
    public var strength: Double?
    /// Crossfade applied at the window edges in the rendered WAV, in
    /// seconds. `nil` lets upstream's own default (0.0 — no crossfade) apply.
    public var wavCrossfadeSec: Double?
    /// Crossfade applied at the window edges in the latent diffusion space,
    /// in 25 Hz frames (10 frames ~= 0.4s). `nil` lets upstream's own
    /// default (10 frames) apply.
    public var latentCrossfadeFrames: Int?
    /// Deterministic seed; `nil` = a fresh random seed each call — the
    /// mechanism for a "retake" (see the `repaintAudio` protocol doc).
    public var seed: Int?
    /// DiT model override; `nil` lets the sidecar's primary (turbo) handler
    /// serve the job — repaint supports both tiers (see the type-group doc
    /// above), so no stems-style default substitution happens here.
    public var model: String?

    public init(
        srcAudioPath: String,
        startSeconds: Double,
        endSeconds: Double? = nil,
        prompt: String? = nil,
        lyrics: String? = nil,
        mode: RepaintMode = .balanced,
        strength: Double? = nil,
        wavCrossfadeSec: Double? = nil,
        latentCrossfadeFrames: Int? = nil,
        seed: Int? = nil,
        model: String? = nil
    ) {
        self.srcAudioPath = srcAudioPath
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.prompt = prompt
        self.lyrics = lyrics
        self.mode = mode
        self.strength = strength
        self.wavCrossfadeSec = wavCrossfadeSec
        self.latentCrossfadeFrames = latentCrossfadeFrames
        self.seed = seed
        self.model = model
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
        body: [String: Any],
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> (Data, Int) {
        let request = try makeRequest(to: url, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AIServiceError.requestFailed(status: status, body: errorBodyText(data))
        }
        return (data, status)
    }

    /// Builds the outgoing `POST` request `postJSON` sends — split out (not
    /// `private`) so a test can pin the `timeoutSeconds` wiring directly,
    /// without a live network call. `timeoutSeconds == nil` leaves
    /// `URLRequest`'s own 60s default `timeoutInterval` untouched, matching
    /// every caller that predates the copilot-turn timeout.
    static func makeRequest(
        to url: URL,
        headers: [String: String],
        body: [String: Any],
        timeoutSeconds: TimeInterval? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let timeoutSeconds {
            request.timeoutInterval = timeoutSeconds
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.malformedResponse("top-level JSON is not an object")
        }
        return object
    }

    /// Formats a non-2xx response body for `AIServiceError.requestFailed`.
    /// When the body is JSON shaped like a provider error envelope
    /// (Anthropic's `{"type":"error","error":{"type","message"}}`, OpenAI's
    /// `{"error":{"type","message"}}`, or a bare `{"error":"..."}` string)
    /// this extracts the vendor's own type/message so callers see e.g.
    /// "overloaded_error: Overloaded" instead of a raw JSON blob. Falls back
    /// to the raw body text (the previous behavior) when it isn't
    /// recognizable as an error envelope.
    static func errorBodyText(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = errorEnvelopeMessage(object) {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
    }

    /// Detects a provider error envelope in an already-parsed JSON object and
    /// formats "type: message" (or whichever of the two the provider sent).
    /// Returns `nil` when `object` doesn't look like an error at all. Used
    /// both by `postJSON`'s non-2xx path above (via `errorBodyText`) and by
    /// each text-completion client's defensive check for an error envelope
    /// that arrives on a 2xx status — a shape none of them should silently
    /// misparse as "missing content" (see `AnthropicClient.complete`,
    /// `OpenAIClient`'s `chat`, and the Copilot providers' `parseReply`).
    static func errorEnvelopeMessage(_ object: [String: Any]) -> String? {
        let looksLikeError = (object["type"] as? String) == "error" || object["error"] != nil
        guard looksLikeError else { return nil }
        if let errorObject = object["error"] as? [String: Any] {
            let type = errorObject["type"] as? String
            let message = errorObject["message"] as? String
            switch (type, message) {
            case let (.some(type), .some(message)): return "\(type): \(message)"
            case (nil, .some(let message)): return message
            case (.some(let type), nil): return type
            default: break
            }
        }
        if let errorString = object["error"] as? String, !errorString.isEmpty {
            return errorString
        }
        return "unknown provider error"
    }
}
