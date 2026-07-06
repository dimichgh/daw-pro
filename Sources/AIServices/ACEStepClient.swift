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
///   "status", "create_time", "env", "progress": Double, "stage": String
///   ("queued"|"running"|"failed"), "error": String?}`.
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
    /// doc for why this is the documented fetch-once contract).
    private var fetchedAudio: [String: URL] = [:]

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
        default: state = (stage == "running") ? .running : .queued
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
            return SongGenerationStatus(
                jobID: jobID, state: .succeeded, progress: 1.0, stage: stage,
                statusText: statusText, audioPath: localURL.path)
        }

        return SongGenerationStatus(
            jobID: jobID, state: state, progress: asDouble(first["progress"]),
            stage: stage, statusText: statusText, audioPath: nil)
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
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("v1/audio"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: remotePath)]
        guard let url = components.url else {
            throw ACEStepError.malformedResponse(
                "could not build the audio-download URL for job \(jobID)")
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

    private func post(path: String, body: [String: Any]) async throws -> Data {
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = config.requestTimeoutSeconds
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
        /// Where finished audio lands locally, one file per job id.
        public var downloadDirectory: URL

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8001")!,
            apiKey: String? = nil,
            requestTimeoutSeconds: Double = 10,
            audioDownloadTimeoutSeconds: Double = 60,
            downloadDirectory: URL = Configuration.defaultDownloadDirectory()
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.audioDownloadTimeoutSeconds = audioDownloadTimeoutSeconds
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
        }
    }
}
