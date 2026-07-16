import Foundation

/// `SongGenerating` client for the local ACE-Step-1.5 sidecar's job-queue REST
/// API (M6 ii — see docs/research/2026-07-05-ace-step-local-song-generation.md
/// and the sidecar lifecycle in `SidecarManager.swift`, M6 i).
///
/// Shapes below are coded directly against the upstream FastAPI route source
/// (`scripts/ace-step/runtime/src/acestep/api/http/{release_task,query_result}
/// _route.py`, `release_task_request_builder.py`, `query_result_service.py`,
/// `audio_route.py`, and the shared envelope in `api_server.py`'s
/// `_wrap_response`), not guessed:
///
/// - `POST /release_task` — submits a job. Every response (success or not)
///   is wrapped `{"data": <payload>, "code": Int, "error": String?,
///   "timestamp", "extra"}`. On success `data` is
///   `{"task_id": String, "status": "queued", "queue_position": Int}`.
/// - `POST /query_result` — body `{"task_id_list": [String]}`; `data` is an
///   array with one item per requested id: `{"task_id", "status": Int (0
///   queued/running, 1 succeeded, 2 failed), "progress_text"?: String,
///   "result": String}` — NOTE `result` is itself a JSON-ENCODED STRING
///   (double-encoded, a legacy-compatibility quirk), decoding to a
///   single-element array. For a succeeded job that element is
///   `{"file": <sidecar-local path>, "status", "create_time", "env",
///   "prompt", "lyrics", "metas": {...}}` (no `stage`/`progress`/`error`
///   keys). For a queued/running/failed job it is instead `{"file": "",
///   "status", "create_time", "env", "progress": Double, "stage": String,
///   "error": String?}`. NOTE on `stage` (measured live at the m17-h gate,
///   2026-07-16): the route source reads like a "queued"|"running"|"failed"
///   enum, but a REAL mid-render job carries rich pipeline text there
///   ("Phase 1: Generating CoT metadata (once for all items)...",
///   "Generating music (batch size: 2)...") with `progress` advancing 0→1 —
///   the queued/running mapping below is coded against that measured
///   behavior, not the apparent enum.
/// - `GET /v1/audio?path=<sidecar-local path>` — streams the finished audio
///   file's bytes; 403 if the path is outside the sidecar's allowed temp
///   directory, 404 if missing.
/// - Auth is OFF by default (loopback sidecar, no `ACESTEP_API_KEY` set); when
///   configured upstream, requests carry `Authorization: Bearer <key>`
///   (verified in `acestep/api/http/auth.py`).
///
/// ASSUMPTION: `key_scale`/`time_signature` are free-text fields upstream
/// (no enumerated value list found in the route/parser code) — we pass
/// whatever string the caller supplies through verbatim.
public actor ACEStepClient: SongGenerating {
    public let config: Configuration

    /// Per-job cache of already-downloaded audio so a job's audio is fetched
    /// from `GET /v1/audio` at most once (see the `SongGenerating` protocol
    /// doc for why this is the documented fetch-once contract). Keyed by the
    /// RAW upstream task id — a stems/Lego sub-job's own task id, same as an
    /// ordinary song job's `jobID` (both come straight from `/release_task`'s
    /// `task_id`), so this cache serves both paths uniformly.
    private var fetchedAudio: [String: URL] = [:]

    /// Composite stems/Lego job id → its underlying per-track upstream jobs
    /// (M6 iii-c). `extractStems`/`generateLegoTracks` populate this;
    /// `generationStatus` consults it FIRST to route a composite id through
    /// the aggregate poller instead of treating it as a single upstream job.
    /// In-memory only (like `fetchedAudio`) — a composite id does not survive
    /// a process restart, same limitation as the sidecar's own ~24h job
    /// retention.
    private var stemJobs: [String: [StemSubJob]] = [:]

    private struct StemSubJob {
        var trackName: String
        var taskID: String
    }

    /// Stems/Lego default DiT model (M6 iii-c-real). Upstream's turbo tier
    /// (the sidecar's default `ACESTEP_CONFIG_PATH` load) excludes
    /// `extract`/`lego` from `TASK_TYPES_TURBO` — but the job router does NOT
    /// reject a request for them; `job_model_selection.py`'s
    /// `select_generation_handler` just logs "Model 'X' not found in [...],
    /// using primary" and SILENTLY runs the job on primary/turbo anyway
    /// (unproven quality for these task types). Defaulting an unset
    /// `StemExtractionRequest`/`LegoGenerationRequest.model` to the BASE/SFT
    /// tier here — paired with `ensureStemsModelLoaded` actually loading it
    /// into slot 2 before the first `/release_task` — closes that gap
    /// instead of relying on upstream's silent substitution. An explicit
    /// caller-supplied `model` always wins over this default.
    public static let defaultStemsModel = "acestep-v15-xl-sft"

    /// Per-instance cache of DiT model names already confirmed available for
    /// stems/Lego work (loaded as of the last `GET /v1/model_inventory` check, or
    /// just-initialized via `POST /v1/init`) — so repeat stems/Lego jobs
    /// against the SAME model don't re-check the sidecar on every submit.
    /// In-memory only (like `stemJobs`/`fetchedAudio`): a fresh client
    /// instance (e.g. after a process restart) starts this empty and
    /// re-checks once.
    private var ensuredStemsModels: Set<String> = []

    private let session: URLSession

    public init(configuration: Configuration = .resolved()) {
        self.config = configuration
        let sessionConfig = URLSessionConfiguration.ephemeral
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - SongGenerating

    public func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
        let data = try await post(path: "release_task", body: releaseTaskBody(for: request))
        guard let payload = try parseEnvelope(data) as? [String: Any] else {
            throw ACEStepError.malformedResponse("'data' in /release_task response is not an object")
        }
        guard let jobID = payload["task_id"] as? String, !jobID.isEmpty else {
            throw ACEStepError.malformedResponse("no 'task_id' in /release_task response")
        }
        let stateText = payload["status"] as? String
        return SongGenerationSubmission(
            jobID: jobID,
            state: SongGenerationState(rawValue: stateText ?? "queued") ?? .queued,
            queuePosition: asInt(payload["queue_position"])
        )
    }

    public func generationStatus(jobID: String) async throws -> SongGenerationStatus {
        // Composite stems/Lego ids are a client-side construction — route
        // them through the aggregate poller BEFORE asking upstream (upstream
        // has never heard of the composite id itself, only its underlying
        // per-track task ids).
        if let subJobs = stemJobs[jobID] {
            return try await stemsGenerationStatus(jobID: jobID, subJobs: subJobs)
        }
        return try await singleJobStatus(jobID: jobID)
    }

    /// The M6 (ii) single-song poll, unchanged — also reused internally to
    /// poll each stems/Lego sub-job by its own raw upstream task id.
    private func singleJobStatus(jobID: String) async throws -> SongGenerationStatus {
        let data = try await post(path: "query_result", body: ["task_id_list": [jobID]])
        guard let items = try parseEnvelope(data) as? [[String: Any]] else {
            throw ACEStepError.malformedResponse("'data' in /query_result response is not an array")
        }
        guard let item = items.first(where: { ($0["task_id"] as? String) == jobID }) ?? items.first else {
            throw ACEStepError.jobNotFound(jobID)
        }

        guard let resultText = item["result"] as? String,
              let resultData = resultText.data(using: .utf8),
              let resultArray = try? JSONSerialization.jsonObject(with: resultData) as? [[String: Any]]
        else {
            throw ACEStepError.malformedResponse(
                "could not parse the nested 'result' payload for job \(jobID)")
        }
        guard let first = resultArray.first else {
            // Legacy-compatible "unknown task id" shape: an empty `result`
            // array with no store record at all (see `collect_query_results`'
            // else branch) — the id was never submitted, or its record has
            // aged out (jobs are retained ~24h server-side).
            throw ACEStepError.jobNotFound(jobID)
        }

        let statusInt = asInt(first["status"]) ?? 0
        let stage = first["stage"] as? String
        let state: SongGenerationState
        switch statusInt {
        case 1: state = .succeeded
        case 2: state = .failed
        default:
            // MEASURED LIVE (m17-h gate, 2026-07-16): mid-render the sidecar's
            // `stage` is NOT the "queued"/"running" enum the route source
            // suggested — it carries rich pipeline text ("Phase 1: Generating
            // CoT metadata (once for all items)...", "Generating music (batch
            // size: 2)...") while `progress` advances 0→1. The old literal
            // `stage == "running"` check left every real job reading "queued"
            // for its whole render — the exact "does not really show progress"
            // complaint. A status-0 job is RUNNING when the stage is any
            // non-queued text OR progress has moved; only a literal "queued"
            // stage (or no movement at all) still means waiting.
            let progress = asDouble(first["progress"]) ?? 0
            let stageSaysWaiting = (stage ?? "queued").isEmpty || stage == "queued"
            state = (!stageSaysWaiting || progress > 0) ? .running : .queued
        }

        let statusText = item["progress_text"] as? String

        if state == .failed {
            let message = (first["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? statusText
                ?? "the sidecar reported failure without an error detail"
            throw ACEStepError.jobFailed(jobID: jobID, message: message)
        }

        if state == .succeeded {
            guard let remoteFile = first["file"] as? String, !remoteFile.isEmpty else {
                throw ACEStepError.malformedResponse(
                    "succeeded job \(jobID) has no audio file path in its result")
            }
            let localURL = try await fetchAudioOnce(jobID: jobID, remotePath: remoteFile)
            // Surface the result's `metas` (bpm/duration/genres/keyscale/
            // timesignature) and the echoed `prompt` — the succeeded payload
            // already carries them (M6 iii-a). Each stays nil if upstream
            // omitted it, so a metas-less sidecar build reports a bare
            // succeeded status unchanged.
            let metas = first["metas"] as? [String: Any]
            return SongGenerationStatus(
                jobID: jobID, state: .succeeded, progress: 1.0, stage: stage,
                statusText: statusText, audioPath: localURL.path,
                prompt: nonEmptyString(first["prompt"]),
                bpm: asDouble(metas?["bpm"]),
                durationSeconds: asDouble(metas?["duration"]),
                genres: metaText(metas?["genres"]),
                keyScale: metaText(metas?["keyscale"]),
                timeSignature: metaText(metas?["timesignature"]))
        }

        return SongGenerationStatus(
            jobID: jobID, state: state, progress: asDouble(first["progress"]),
            stage: stage, statusText: statusText, audioPath: nil)
    }

    // MARK: - Stems / Lego (M6 iii-c)

    public func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
        try await submitStemJob(
            taskType: "extract",
            sourceAudioPath: request.sourceAudioPath,
            model: request.model,
            globalCaption: nil,
            tracks: request.trackNames.map { StemTrackRequest(trackName: $0) })
    }

    public func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
        try await submitStemJob(
            taskType: "lego",
            sourceAudioPath: request.sourceAudioPath,
            model: request.model,
            globalCaption: request.globalCaption,
            tracks: request.tracks)
    }

    /// Shared submit path for extract/lego: stages the source audio inside
    /// the sidecar's temp-dir allowlist ONCE, ensures the target model is
    /// actually loaded on the sidecar (M6 iii-c-real —
    /// `ensureStemsModelLoaded`, run BEFORE the first `/release_task` below),
    /// then submits one `POST /release_task` per requested track (upstream
    /// is single-track-per-job for both task types — see the
    /// `Providers.swift` type-group doc), collecting the resulting task ids
    /// under one composite id this client manufactures and tracks in
    /// `stemJobs`.
    private func submitStemJob(
        taskType: String,
        sourceAudioPath: String,
        model: String?,
        globalCaption: String?,
        tracks: [StemTrackRequest]
    ) async throws -> StemGenerationSubmission {
        guard !tracks.isEmpty else {
            throw ACEStepError.malformedResponse("no track names requested for a '\(taskType)' job")
        }
        let stagedSource = try stageSourceAudioForUpload(at: sourceAudioPath)

        // Explicit request.model always wins; nil/empty falls back to the
        // BASE/SFT default (see `defaultStemsModel`'s doc for why turbo is
        // never an acceptable silent default for these task types).
        let effectiveModel = (model?.isEmpty == false) ? model! : Self.defaultStemsModel
        try await ensureStemsModelLoaded(effectiveModel)

        var subJobs: [StemSubJob] = []
        subJobs.reserveCapacity(tracks.count)
        for track in tracks {
            var body: [String: Any] = [
                "task_type": taskType,
                "src_audio_path": stagedSource.path,
                "track_name": track.trackName,
                // Upstream saves mp3 (48 kHz, 128k) unless asked for wav —
                // same deliberate override as the generateSong path.
                "audio_format": "wav",
                "model": effectiveModel,
            ]
            if let globalCaption, !globalCaption.isEmpty { body["global_caption"] = globalCaption }
            if let localPrompt = track.localPrompt, !localPrompt.isEmpty { body["prompt"] = localPrompt }

            let data = try await post(path: "release_task", body: body)
            guard let payload = try parseEnvelope(data) as? [String: Any] else {
                throw ACEStepError.malformedResponse(
                    "'data' in /release_task response is not an object (track '\(track.trackName)')")
            }
            guard let taskID = payload["task_id"] as? String, !taskID.isEmpty else {
                throw ACEStepError.malformedResponse(
                    "no 'task_id' in /release_task response for track '\(track.trackName)'")
            }
            subJobs.append(StemSubJob(trackName: track.trackName, taskID: taskID))
        }

        let compositeID = "stems:\(UUID().uuidString)"
        stemJobs[compositeID] = subJobs
        return StemGenerationSubmission(jobID: compositeID, state: .queued, trackNames: tracks.map(\.trackName))
    }

    // MARK: - Repaint (M6 v-a)

    /// Submits a SINGLE upstream repaint job (unlike `extractStems`/
    /// `generateLegoTracks`, there is no per-track fan-out — see the
    /// `Providers.swift` type-group doc) and returns its raw upstream job
    /// id; it polls through `generationStatus` exactly like an ordinary
    /// `generateSong` job (not routed through `stemJobs` — no composite id
    /// is manufactured here). Repaint supports both the turbo (primary) and
    /// sft tiers upstream, so — unlike `submitStemJob` — this does NOT call
    /// `ensureStemsModelLoaded`; a `nil` `RepaintRequest.model` is simply
    /// omitted from the wire, letting the sidecar's primary handler serve it.
    public func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission {
        let stagedSource = try stageSourceAudioForUpload(at: request.srcAudioPath)

        var body: [String: Any] = [
            "task_type": "repaint",
            "src_audio_path": stagedSource.path,
            "repainting_start": request.startSeconds,
            "repaint_mode": request.mode.rawValue,
            // Upstream saves mp3 (48 kHz, 128k) unless asked for wav — same
            // deliberate override as generateSong/submitStemJob.
            "audio_format": "wav",
        ]
        if let endSeconds = request.endSeconds { body["repainting_end"] = endSeconds }
        if let prompt = request.prompt, !prompt.isEmpty { body["prompt"] = prompt }
        if let lyrics = request.lyrics, !lyrics.isEmpty { body["lyrics"] = lyrics }
        if let strength = request.strength { body["repaint_strength"] = strength }
        if let wavCrossfadeSec = request.wavCrossfadeSec {
            body["repaint_wav_crossfade_sec"] = wavCrossfadeSec
        }
        if let latentCrossfadeFrames = request.latentCrossfadeFrames {
            body["repaint_latent_crossfade_frames"] = latentCrossfadeFrames
        }
        // Explicit seed → deterministic (use_random_seed false); no seed →
        // an explicit use_random_seed true (never left to an implicit
        // upstream default) so a retake — the same call with seed omitted —
        // is unambiguously "fresh random seed" on the wire.
        if let seed = request.seed {
            body["seed"] = seed
            body["use_random_seed"] = false
        } else {
            body["use_random_seed"] = true
        }
        if let model = request.model, !model.isEmpty { body["model"] = model }

        let data = try await post(path: "release_task", body: body)
        guard let payload = try parseEnvelope(data) as? [String: Any] else {
            throw ACEStepError.malformedResponse("'data' in /release_task response is not an object (repaint)")
        }
        guard let jobID = payload["task_id"] as? String, !jobID.isEmpty else {
            throw ACEStepError.malformedResponse("no 'task_id' in /release_task response (repaint)")
        }
        let stateText = payload["status"] as? String
        return SongGenerationSubmission(
            jobID: jobID,
            state: SongGenerationState(rawValue: stateText ?? "queued") ?? .queued,
            queuePosition: asInt(payload["queue_position"]))
    }

    /// Ensures `model` is actually loaded on the sidecar before a stems/Lego
    /// job's first `/release_task` (M6 iii-c-real) — without this, an
    /// unloaded/unmatched `model` name causes upstream's job router to
    /// silently fall back to the primary/turbo handler (see
    /// `defaultStemsModel`'s doc). Checks `GET /v1/model_inventory`'s per-model
    /// `is_loaded` flag first: this is true already whether `model` is the
    /// PRIMARY (slot 1) load OR a slot 2/3 model loaded by an earlier call,
    /// so either case is a no-op here. Only when neither is true does this
    /// issue `POST /v1/init {model, slot: 2}` — always slot 2 (slot 3 is
    /// reserved for other future needs), awaited with
    /// `config.modelInitTimeoutSeconds` since a multi-GB DiT load can take
    /// minutes, not the fast-call timeout the rest of this client uses. A
    /// successful check or init is cached in `ensuredStemsModels` for the
    /// lifetime of this client instance so repeat jobs against the same
    /// model skip both calls entirely.
    private func ensureStemsModelLoaded(_ model: String) async throws {
        if ensuredStemsModels.contains(model) { return }

        let loadedModelNames = try await fetchLoadedModelNames()
        if loadedModelNames.contains(model) {
            ensuredStemsModels.insert(model)
            return
        }

        do {
            let data = try await post(
                path: "v1/init",
                body: ["model": model, "slot": 2],
                timeoutSeconds: config.modelInitTimeoutSeconds)
            _ = try parseEnvelope(data)
        } catch ACEStepError.requestFailed(let status, let detail) where status == 400 {
            // Verified upstream (`model_service_routes.py`'s `/v1/init`):
            // this 400 means slot 2's handler was never constructed because
            // ACESTEP_CONFIG_PATH2 wasn't set when the sidecar process
            // started — `scripts/ace-step/run.sh` now exports it by default,
            // but an already-running sidecar started before that change (or
            // with the env var explicitly cleared) won't have picked it up.
            throw ACEStepError.modelSlotUnavailable(model: model, detail: detail)
        }
        ensuredStemsModels.insert(model)
    }

    /// `GET /v1/model_inventory` — the DiT model inventory's per-model `is_loaded`
    /// flags, collected into the set of currently-loaded model names (across
    /// whichever of the up-to-3 handler slots are populated). Used by
    /// `ensureStemsModelLoaded` to decide whether a `POST /v1/init` is even
    /// necessary. NOT `/v1/models`: on the real server that path is shadowed
    /// by an OpenAI-compat route returning `{"object":"list","data":[]}`
    /// (found live at the iii-c-real gate) — `/v1/model_inventory` is
    /// upstream's own "non-OpenRouter internal endpoint" for this envelope.
    private func fetchLoadedModelNames() async throws -> Set<String> {
        let data = try await get(path: "v1/model_inventory")
        guard let payload = try parseEnvelope(data) as? [String: Any] else {
            throw ACEStepError.malformedResponse("'data' in /v1/model_inventory response is not an object")
        }
        guard let models = payload["models"] as? [[String: Any]] else {
            throw ACEStepError.malformedResponse("'data.models' in /v1/model_inventory response is not an array")
        }
        var loaded: Set<String> = []
        for entry in models {
            guard let name = entry["name"] as? String, !name.isEmpty else { continue }
            if (entry["is_loaded"] as? Bool) == true {
                loaded.insert(name)
            }
        }
        return loaded
    }

    /// Aggregates the per-track polls of a composite stems/Lego job into one
    /// `SongGenerationStatus`: `.running` (averaged progress) while any
    /// sub-job hasn't succeeded yet, `.succeeded` with every named result in
    /// `stems` once all have. A sub-job that fails upstream fails the WHOLE
    /// composite job by throwing (never a silent partial result), naming
    /// which track failed.
    private func stemsGenerationStatus(jobID: String, subJobs: [StemSubJob]) async throws -> SongGenerationStatus {
        var results: [StemResult] = []
        var progressSum = 0.0
        var allSucceeded = true

        for subJob in subJobs {
            let status: SongGenerationStatus
            do {
                status = try await singleJobStatus(jobID: subJob.taskID)
            } catch let error as ACEStepError {
                if case .jobFailed(_, let message) = error {
                    throw ACEStepError.jobFailed(
                        jobID: jobID, message: "track '\(subJob.trackName)' failed: \(message)")
                }
                throw error
            }
            switch status.state {
            case .succeeded:
                guard let audioPath = status.audioPath else {
                    throw ACEStepError.malformedResponse(
                        "succeeded track '\(subJob.trackName)' has no audio file path in its result")
                }
                results.append(StemResult(
                    trackName: subJob.trackName, audioPath: audioPath,
                    bpm: status.bpm, durationSeconds: status.durationSeconds))
                progressSum += 1.0
            case .queued, .running:
                allSucceeded = false
                progressSum += status.progress ?? 0.0
            case .failed:
                // singleJobStatus throws for a failed job — never returns
                // this case as a value (see its own doc).
                allSucceeded = false
            }
        }

        let progress = subJobs.isEmpty ? 1.0 : progressSum / Double(subJobs.count)
        guard allSucceeded else {
            return SongGenerationStatus(jobID: jobID, state: .running, progress: progress, stage: "running")
        }
        return SongGenerationStatus(jobID: jobID, state: .succeeded, progress: 1.0, stems: results)
    }

    /// Copies `path` into a fresh file under THIS PROCESS's system temp
    /// directory so the sidecar's `validate_audio_path` allowlist (verified:
    /// `release_task_audio_paths.py` — accepts a `src_audio_path` only if its
    /// realpath resolves inside the SIDECAR's own `tempfile.gettempdir()`)
    /// accepts it. ASSUMPTION: loopback-only — this only works because the
    /// sidecar (spawned by `SidecarManager` with no explicit `environment`
    /// override, so it inherits this process's `$TMPDIR`) and this client run
    /// on the same machine as the same user, sharing `$TMPDIR`; there is no
    /// remote-upload path here by design (see docs/AI-INTEGRATIONS.md).
    /// Always copies (rather than reusing an already-in-temp path as-is) so
    /// callers can hand in ANY readable local path, including a project's own
    /// media files outside temp entirely.
    private func stageSourceAudioForUpload(at path: String) throws -> URL {
        let sourceURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ACEStepError.malformedResponse("source audio file does not exist: \(path)")
        }
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DAWPro/ace-step-uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let staged = stagingDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: sourceURL, to: staged)
        return staged
    }

    // MARK: - Request building

    private func releaseTaskBody(for request: SongGenerationRequest) -> [String: Any] {
        var body: [String: Any] = [
            "prompt": request.prompt,
            "vocal_language": request.vocalLanguage,
            "audio_format": request.audioFormat,
        ]
        if let lyrics = request.lyrics, !lyrics.isEmpty {
            body["lyrics"] = lyrics
        }
        if let durationSeconds = request.durationSeconds {
            body["audio_duration"] = durationSeconds
        }
        if let seed = request.seed {
            body["seed"] = seed
            body["use_random_seed"] = false
        }
        if let bpm = request.bpm {
            body["bpm"] = bpm
        }
        if let keyScale = request.keyScale {
            body["key_scale"] = keyScale
        }
        if let timeSignature = request.timeSignature {
            body["time_signature"] = timeSignature
        }
        if let guidanceScale = request.guidanceScale {
            body["guidance_scale"] = guidanceScale
        }
        if let inferenceSteps = request.inferenceSteps {
            body["inference_steps"] = inferenceSteps
        }
        return body
    }

    // MARK: - Audio retrieval

    private func fetchAudioOnce(jobID: String, remotePath: String) async throws -> URL {
        if let cached = fetchedAudio[jobID] {
            return cached
        }
        // Upstream's succeeded `result.file` is a PRE-BUILT relative URL
        // ("/v1/audio?path=%2F…", already percent-encoded) — request it
        // directly. Only a bare filesystem path gets wrapped in /v1/audio
        // here. Wrapping the pre-built form again double-encodes it and the
        // sidecar 403s the literal "/v1/audio?path=…" as a path — found by
        // the first REAL generation gate; the stub's raw-path shape hid it.
        let url: URL
        if remotePath.hasPrefix("/v1/") {
            guard let direct = URL(string: remotePath, relativeTo: config.baseURL)?.absoluteURL
            else {
                throw ACEStepError.malformedResponse(
                    "could not build the audio-download URL for job \(jobID)")
            }
            url = direct
        } else {
            var components = URLComponents(
                url: config.baseURL.appendingPathComponent("v1/audio"),
                resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: remotePath)]
            guard let built = components.url else {
                throw ACEStepError.malformedResponse(
                    "could not build the audio-download URL for job \(jobID)")
            }
            url = built
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = config.audioDownloadTimeoutSeconds
        applyAuth(&urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ACEStepError.sidecarUnreachable(describeConnectionFailure(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ACEStepError.malformedResponse("no HTTP response fetching audio for job \(jobID)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ACEStepError.requestFailed(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        }

        try FileManager.default.createDirectory(
            at: config.downloadDirectory, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: remotePath).pathExtension
        let destination = config.downloadDirectory
            .appendingPathComponent(jobID)
            .appendingPathExtension(ext.isEmpty ? "wav" : ext)
        try data.write(to: destination, options: .atomic)
        fetchedAudio[jobID] = destination
        return destination
    }

    // MARK: - HTTP plumbing

    /// `timeoutSeconds` defaults to `config.requestTimeoutSeconds` (the fast
    /// JSON calls); `ensureStemsModelLoaded` overrides it with
    /// `config.modelInitTimeoutSeconds` for `POST /v1/init`, which can block
    /// for minutes loading a DiT checkpoint.
    private func post(path: String, body: [String: Any], timeoutSeconds: Double? = nil) async throws -> Data {
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds ?? config.requestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&urlRequest)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ACEStepError.sidecarUnreachable(describeConnectionFailure(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ACEStepError.malformedResponse("no HTTP response for POST /\(path)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ACEStepError.requestFailed(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        }
        return data
    }

    private func get(path: String) async throws -> Data {
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = config.requestTimeoutSeconds
        applyAuth(&urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ACEStepError.sidecarUnreachable(describeConnectionFailure(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ACEStepError.malformedResponse("no HTTP response for GET /\(path)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ACEStepError.requestFailed(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        }
        return data
    }

    private func applyAuth(_ urlRequest: inout URLRequest) {
        if let apiKey = config.apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Unwraps ACE-Step's `_wrap_response` envelope (`{"data", "code",
    /// "error", "timestamp", "extra"}`), surfacing a carried `error` string
    /// as a request failure and otherwise returning `data` (an `Any` — a
    /// dictionary for `/release_task`, an array for `/query_result`).
    private func parseEnvelope(_ data: Data) throws -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ACEStepError.malformedResponse("top-level response is not a JSON object")
        }
        if let message = object["error"] as? String, !message.isEmpty {
            throw ACEStepError.requestFailed(status: asInt(object["code"]) ?? 0, body: message)
        }
        guard let inner = object["data"] else {
            throw ACEStepError.malformedResponse("response has no 'data' field")
        }
        return inner
    }

    private func describeConnectionFailure(_ error: Error) -> String {
        (error as? URLError)?.localizedDescription ?? error.localizedDescription
    }

    private func asInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func asDouble(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    /// A trimmed, non-empty string or nil — so an empty `""` (ACE-Step's
    /// placeholder for "not set") never surfaces as a present-but-blank field.
    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads a free-text `metas` field that upstream sends as EITHER a string
    /// or a list of strings (genres in particular): a scalar passes through,
    /// a list is joined with ", ". Empty/absent → nil.
    private func metaText(_ value: Any?) -> String? {
        if let string = value as? String { return nonEmptyString(string) }
        if let list = value as? [Any] {
            let parts = list.compactMap { nonEmptyString($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        return nil
    }
}

extension ACEStepClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        /// Bearer token sent when the sidecar has `ACESTEP_API_KEY` set
        /// (`nil` — the default for a local loopback sidecar — sends none).
        public var apiKey: String?
        /// Timeout for the fast JSON calls (`/release_task`, `/query_result`).
        public var requestTimeoutSeconds: Double
        /// Timeout for `GET /v1/audio` — bigger since it streams file bytes,
        /// though still generous headroom since this is loopback-only.
        public var audioDownloadTimeoutSeconds: Double
        /// Timeout for `POST /v1/init` (M6 iii-c-real) — on-demand loading of
        /// a multi-GB DiT checkpoint into a handler slot can take MINUTES
        /// (disk read + device transfer), unlike the fast JSON calls above,
        /// so this gets its own generous, separately configurable budget.
        public var modelInitTimeoutSeconds: Double
        /// Where finished audio lands locally, one file per job id.
        public var downloadDirectory: URL

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8001")!,
            apiKey: String? = nil,
            requestTimeoutSeconds: Double = 10,
            audioDownloadTimeoutSeconds: Double = 60,
            modelInitTimeoutSeconds: Double = 600,
            downloadDirectory: URL = Configuration.defaultDownloadDirectory()
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.audioDownloadTimeoutSeconds = audioDownloadTimeoutSeconds
            self.modelInitTimeoutSeconds = modelInitTimeoutSeconds
            self.downloadDirectory = downloadDirectory
        }

        /// `ACE_STEP_URL` env override (documented in docs/AI-INTEGRATIONS.md)
        /// wins if set; otherwise the standard loopback default. Mirrors
        /// `SidecarManager.Configuration.resolved()`'s env-first pattern.
        public static func resolved(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            var config = Configuration()
            if let override = environment["ACE_STEP_URL"], let url = URL(string: override) {
                config.baseURL = url
            }
            if let key = environment["ACESTEP_API_KEY"], !key.isEmpty {
                config.apiKey = key
            }
            return config
        }

        public static func defaultDownloadDirectory() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "DAWPro/ace-step-generations", isDirectory: true)
        }
    }
}

public enum ACEStepError: Error, LocalizedError, Equatable {
    /// The sidecar could not be reached at all (connection refused/timed
    /// out/etc.) — distinct from an HTTP error response. `CommandRouter`
    /// intercepts this case specifically and replaces the message with
    /// `SidecarManager`'s own state-specific guidance (point at
    /// `ai.sidecarStart`, or `install.sh` if never installed) rather than
    /// surfacing the raw connection error.
    case sidecarUnreachable(String)
    case requestFailed(status: Int, body: String)
    case malformedResponse(String)
    case jobFailed(jobID: String, message: String)
    case jobNotFound(String)
    /// `POST /v1/init {model, slot: 2}` (M6 iii-c-real, `ensureStemsModelLoaded`)
    /// came back with the upstream 400 that means slot 2's handler was never
    /// constructed — `ACESTEP_CONFIG_PATH2` wasn't set on the RUNNING sidecar
    /// process (verified: `model_init_service.py`'s `_resolve_slot`).
    /// `scripts/ace-step/run.sh` now exports it by default, but a sidecar
    /// already running from before that change (or a hand-launched one with
    /// it explicitly unset) won't have picked it up without a restart.
    case modelSlotUnavailable(model: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .sidecarUnreachable(let detail):
            return "ACE-Step sidecar is not reachable (\(detail)) — call ai.sidecarStart " +
                "(check ai.sidecarStatus first if you're not sure it's installed)."
        case .requestFailed(let status, let body):
            return "ACE-Step sidecar request failed (HTTP \(status)): \(body.prefix(500))"
        case .malformedResponse(let detail):
            return "could not parse the ACE-Step sidecar's response: \(detail)"
        case .jobFailed(let jobID, let message):
            return "ACE-Step generation job \(jobID) failed: \(message)"
        case .jobNotFound(let jobID):
            return "no ACE-Step generation job with id '\(jobID)' — it may have expired " +
                "(jobs are retained ~24h) or the id is wrong; call ai.generateSong to start a new one."
        case .modelSlotUnavailable(let model, let detail):
            return "ACE-Step could not load model '\(model)' into slot 2 for extract/lego (\(detail)) — " +
                "the sidecar process needs to be RESTARTED to pick up ACESTEP_CONFIG_PATH2 " +
                "(scripts/ace-step/run.sh now exports it by default; an already-running sidecar " +
                "started before this change won't have the slot until it restarts). Call " +
                "ai.sidecarStop then ai.sidecarStart."
        }
    }
}
