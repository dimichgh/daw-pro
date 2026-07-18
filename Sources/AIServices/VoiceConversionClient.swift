import Foundation

/// Thin typed client for the RVC voice-conversion sidecar's stable v1 HTTP
/// contract (m10-p-3 — see `scripts/rvc/README.md`, written by m10-p-2
/// specifically as "the contract doc for p-3"). Coded directly against
/// `scripts/rvc/server.py`'s route source, not guessed.
///
/// Kept separate from `VoiceConversionManager` (process lifecycle), the same
/// split `ACEStepClient`/`SidecarManager` use — different concerns even
/// though both talk to the same sidecar process. That means `health()` below
/// duplicates a small amount of envelope parsing that
/// `VoiceConversionManager.probeHealth()` also does privately; this mirrors
/// the ACE precedent's accepted duplication rather than introducing a new
/// coupling between the two actors that ACE's own design doesn't have
/// either — disclosed, not an oversight.
///
/// IMPORTANT shape note (verified against `server.py`, differs from
/// `ACEStepClient`'s ACE-Step convention): only `GET /health` uses the
/// `{"data": {...}, "code", "error"}` envelope. Every OTHER success response
/// (`/v1/voice/list`, `/v1/voice/{id}/status`, `/v1/voice/convert`) is a RAW,
/// UNWRAPPED JSON body — there is no `data` envelope to unwrap on those
/// calls. Only FAILURE responses (any non-2xx) share one shape across every
/// endpoint: the teaching-error envelope `{"error": {"code", "message"}}`
/// (`scripts/rvc/README.md`'s "Errors are teaching-style" line) — parsed by
/// this type's `teachingError(status:data:)` and surfaced as
/// `VoiceConversionError.requestFailed`.
///
/// `train(_:)` is intentionally thin: `POST /v1/voice/train` has no defined
/// SUCCESS response shape yet (the facade always answers 400 (invalid shape)
/// or 501 `trainingNotYetAvailable` today, by m10-p-2's own deliberate
/// design — training ships with the Voice panel, m10-p-5/p-6). Inventing a
/// success schema now would be guessing, so `train(_:)` returns the raw
/// response `Data` on any future 2xx and throws the teaching error verbatim
/// otherwise — exactly what this roadmap item calls for ("train will surface
/// the facade's 501 teaching error verbatim; that is correct for now").
public actor VoiceConversionClient {
    public let config: Configuration
    private let session: URLSession

    public init(configuration: Configuration = .resolved()) {
        self.config = configuration
        let sessionConfig = URLSessionConfiguration.ephemeral
        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Health

    public func health() async throws -> VoiceConversionHealth {
        let data = try await get(path: "health")
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = parsed["data"] as? [String: Any] else {
            throw VoiceConversionError.malformedResponse("'data' missing/not an object in /health response")
        }
        return VoiceConversionHealth(
            service: inner["service"] as? String,
            version: inner["version"] as? String,
            engine: inner["engine"] as? String,
            baseModelPresent: inner["baseModelPresent"] as? Bool,
            voiceCount: asInt(inner["voiceCount"]),
            port: asInt(inner["port"]))
    }

    // MARK: - Voices

    public func listVoices() async throws -> [VoiceDescriptor] {
        let data = try await get(path: "v1/voice/list")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = object["voices"] as? [[String: Any]] else {
            throw VoiceConversionError.malformedResponse("'voices' missing/not an array in /v1/voice/list response")
        }
        return voices.map(Self.decodeVoiceDescriptor)
    }

    public func voiceStatus(voiceID: String) async throws -> VoiceDescriptor {
        let data = try await get(path: "v1/voice/\(voiceID)/status")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceConversionError.malformedResponse(
                "GET /v1/voice/\(voiceID)/status response is not a JSON object")
        }
        return Self.decodeVoiceDescriptor(object)
    }

    private static func decodeVoiceDescriptor(_ object: [String: Any]) -> VoiceDescriptor {
        VoiceDescriptor(
            id: object["id"] as? String ?? "",
            name: object["name"] as? String ?? "",
            state: object["state"] as? String ?? "",
            hasIndex: object["hasIndex"] as? Bool,
            createdAt: object["createdAt"] as? String,
            kind: object["kind"] as? String,
            trained: object["trained"] as? Bool,
            note: object["note"] as? String)
    }

    // MARK: - Convert (M10-p-4 will wire this behind `vc.convertVocals`)

    public func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        let body: [String: Any] = [
            "inputPath": request.inputPath,
            "voiceId": request.voiceId,
            "pitchSemitones": request.pitchSemitones,
        ]
        let data = try await post(path: "v1/voice/convert", body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceConversionError.malformedResponse("POST /v1/voice/convert response is not a JSON object")
        }
        guard let outputPath = object["outputPath"] as? String, !outputPath.isEmpty else {
            throw VoiceConversionError.malformedResponse("no 'outputPath' in /v1/voice/convert response")
        }
        guard let voiceId = object["voiceId"] as? String,
              let inputSeconds = asDouble(object["inputSeconds"]),
              let engineLoadSeconds = asDouble(object["engineLoadSeconds"]),
              let inferSeconds = asDouble(object["inferSeconds"]),
              let sampleRate = asInt(object["sampleRate"]),
              let realConversion = object["realConversion"] as? Bool
        else {
            throw VoiceConversionError.malformedResponse(
                "/v1/voice/convert response is missing one or more required fields")
        }
        return VoiceConvertResult(
            outputPath: outputPath, voiceId: voiceId, inputSeconds: inputSeconds,
            engineLoadSeconds: engineLoadSeconds, inferSeconds: inferSeconds,
            rtf: asDouble(object["rtf"]), sampleRate: sampleRate, realConversion: realConversion,
            note: object["note"] as? String)
    }

    // MARK: - Train (M10-p-4/p-6 will wire this behind `vc.trainVoice`)

    /// Always throws today (see this type's own doc) — the facade validates
    /// shape then answers a structured 501 `trainingNotYetAvailable`
    /// verbatim via `VoiceConversionError.requestFailed`. Returns the raw
    /// success body on any future 2xx rather than inventing a schema.
    @discardableResult
    public func train(_ request: VoiceTrainRequest) async throws -> Data {
        var body: [String: Any] = ["name": request.name, "datasetDir": request.datasetDir]
        if let voiceId = request.voiceId, !voiceId.isEmpty { body["voiceId"] = voiceId }
        if let epochs = request.epochs { body["epochs"] = epochs }
        return try await post(path: "v1/voice/train", body: body)
    }

    // MARK: - HTTP plumbing

    private func post(path: String, body: [String: Any]) async throws -> Data {
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = config.requestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(urlRequest, pathForErrors: "POST /\(path)")
    }

    private func get(path: String) async throws -> Data {
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = config.requestTimeoutSeconds
        return try await send(urlRequest, pathForErrors: "GET /\(path)")
    }

    private func send(_ urlRequest: URLRequest, pathForErrors: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw VoiceConversionError.sidecarUnreachable(describeConnectionFailure(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw VoiceConversionError.malformedResponse("no HTTP response for \(pathForErrors)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.teachingError(status: http.statusCode, data: data)
        }
        return data
    }

    /// Parses the facade's `{"error": {"code", "message"}}` teaching-error
    /// envelope (verified against every `teaching_error(...)` call site in
    /// `server.py`); falls back to the raw response text if a non-2xx
    /// response doesn't match that shape (e.g. an upstream 5xx from
    /// somewhere other than the facade's own handlers).
    private static func teachingError(status: Int, data: Data) -> VoiceConversionError {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = parsed["error"] as? [String: Any],
              let message = inner["message"] as? String
        else {
            return .requestFailed(
                status: status, code: nil,
                message: String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        }
        return .requestFailed(status: status, code: inner["code"] as? String, message: message)
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

extension VoiceConversionClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var requestTimeoutSeconds: Double

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8002")!,
            requestTimeoutSeconds: Double = 10
        ) {
            self.baseURL = baseURL
            self.requestTimeoutSeconds = requestTimeoutSeconds
        }

        /// `RVC_API_URL` env override wins if set (same variable
        /// `VoiceConversionManager.Configuration.resolved()` reads);
        /// otherwise the standard loopback default. There is no API-key
        /// equivalent to `ACEStepClient`'s `ACESTEP_API_KEY` — the facade
        /// (`scripts/rvc/server.py`) implements no auth of its own.
        public static func resolved(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            var config = Configuration()
            if let override = environment["RVC_API_URL"], let url = URL(string: override) {
                config.baseURL = url
            }
            return config
        }
    }
}

// MARK: - Wire/model types

/// `GET /health`'s `data` payload (`scripts/rvc/server.py`). Distinct from
/// `VoiceConversionStatus` (the `vc.sidecarStatus` control-protocol wire
/// shape, which folds a subset of these same fields into its own richer
/// lifecycle envelope) — this is the client's own direct, unwrapped view.
public struct VoiceConversionHealth: Codable, Sendable, Equatable {
    public var service: String?
    public var version: String?
    public var engine: String?
    public var baseModelPresent: Bool?
    public var voiceCount: Int?
    public var port: Int?

    public init(
        service: String? = nil, version: String? = nil, engine: String? = nil,
        baseModelPresent: Bool? = nil, voiceCount: Int? = nil, port: Int? = nil
    ) {
        self.service = service
        self.version = version
        self.engine = engine
        self.baseModelPresent = baseModelPresent
        self.voiceCount = voiceCount
        self.port = port
    }
}

/// `GET /v1/voice/list` element / `GET /v1/voice/{id}/status` response
/// (`scripts/rvc/server.py`'s `_voice_descriptor`/`_base_descriptor`). The
/// two shapes differ slightly (a real user voice carries `hasIndex`/
/// `createdAt`; the reserved `"base"` builtin instead carries `kind`/
/// `trained`/`note`) — every field below is optional/absent as appropriate
/// rather than forcing one shape onto the other.
public struct VoiceDescriptor: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// `"ready"` (has `model.npz`) / `"needsConversion"` (has `.pth`, not
    /// yet MLX-converted) / `"incomplete"` — real voices only. The `"base"`
    /// descriptor also uses `"ready"`/`"incomplete"` depending on whether the
    /// smoke-target checkpoint is present.
    public var state: String
    /// Real voices only — whether a FAISS `model.index` exists (raises
    /// conversion quality when present).
    public var hasIndex: Bool?
    public var createdAt: String?
    /// `"builtin"` — only present for the reserved `"base"` descriptor.
    public var kind: String?
    /// `false` — only present for `"base"` (never a real, user-trained voice).
    public var trained: Bool?
    /// Human note explaining `"base"` is a pipeline smoke target, not a real
    /// voice — only present for that descriptor.
    public var note: String?

    public init(
        id: String, name: String, state: String, hasIndex: Bool? = nil, createdAt: String? = nil,
        kind: String? = nil, trained: Bool? = nil, note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.hasIndex = hasIndex
        self.createdAt = createdAt
        self.kind = kind
        self.trained = trained
        self.note = note
    }
}

/// `POST /v1/voice/convert` request body. `pitchSemitones` must be in
/// `[-24, 24]` (the facade's own `pitchOutOfRange` teaching error covers an
/// out-of-range value — not re-validated client-side, so the facade's exact
/// wording always reaches the caller).
public struct VoiceConvertRequest: Sendable, Equatable {
    public var inputPath: String
    public var voiceId: String
    public var pitchSemitones: Int

    public init(inputPath: String, voiceId: String, pitchSemitones: Int = 0) {
        self.inputPath = inputPath
        self.voiceId = voiceId
        self.pitchSemitones = pitchSemitones
    }
}

/// `POST /v1/voice/convert` success response.
public struct VoiceConvertResult: Codable, Sendable, Equatable {
    public var outputPath: String
    public var voiceId: String
    public var inputSeconds: Double
    public var engineLoadSeconds: Double
    public var inferSeconds: Double
    /// Real-time factor (`inputSeconds / inferSeconds`) — nil if the facade
    /// couldn't compute it (a zero/near-zero `inferSeconds`).
    public var rtf: Double?
    public var sampleRate: Int
    /// `false` only for `voiceId == "base"` — the untrained smoke target,
    /// never a real conversion to a user's own voice.
    public var realConversion: Bool
    /// Present only for the `"base"` smoke target, explaining it is not a
    /// real voice conversion.
    public var note: String?
}

/// `POST /v1/voice/train` request body. `"base"` is rejected for both `name`
/// and `voiceId` by the facade's own `reservedVoiceId` teaching error (the
/// reserved smoke-target id can never be trained over).
public struct VoiceTrainRequest: Sendable, Equatable {
    public var name: String
    public var datasetDir: String
    public var voiceId: String?
    public var epochs: Int?

    public init(name: String, datasetDir: String, voiceId: String? = nil, epochs: Int? = nil) {
        self.name = name
        self.datasetDir = datasetDir
        self.voiceId = voiceId
        self.epochs = epochs
    }
}

public enum VoiceConversionError: Error, LocalizedError, Equatable {
    /// The sidecar could not be reached at all — mirrors `ACEStepError
    /// .sidecarUnreachable`; `CommandRouter` would similarly re-probe
    /// `voiceConversionManager.status()` for the precise next step once a
    /// later roadmap item wires `vc.convertVocals`/`vc.trainVoice`.
    case sidecarUnreachable(String)
    /// Any non-2xx response — `code` is the facade's own symbolic error code
    /// (e.g. `"unknownVoice"`, `"trainingNotYetAvailable"`) when the teaching
    /// envelope parsed, nil when it didn't (an unexpected non-facade error).
    case requestFailed(status: Int, code: String?, message: String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .sidecarUnreachable(let detail):
            return "RVC voice-conversion sidecar is not reachable (\(detail)) — call vc.sidecarStart "
                + "(check vc.sidecarStatus first if you're not sure it's installed)."
        case .requestFailed(let status, let code, let message):
            let codePrefix = code.map { "\($0): " } ?? ""
            return "RVC voice-conversion sidecar request failed (HTTP \(status)): \(codePrefix)\(message)"
        case .malformedResponse(let detail):
            return "could not parse the RVC voice-conversion sidecar's response: \(detail)"
        }
    }
}
