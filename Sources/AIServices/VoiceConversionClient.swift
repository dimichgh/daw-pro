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
///
/// `convert`/`train` are wired to `vc.convertVocals`/`vc.trainVoice` (m10-p-4)
/// through the `VoiceConverting` seam below; `listVoices` joined the seam in
/// m10-p-5 when the Voice panel made voice-listing user-facing (the CLAUDE.md
/// convention then requires a wire command — `vc.listVoices` — and commands
/// route through this protocol so tests can fake them).
public protocol VoiceConverting: Sendable {
    func listVoices() async throws -> [VoiceDescriptor]
    func voiceStatus(voiceID: String) async throws -> VoiceDescriptor
    func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult
    @discardableResult
    func train(_ request: VoiceTrainRequest) async throws -> Data
}

extension VoiceConverting {
    /// The user-facing "what can I convert to" list (m10-p-5), shared by the
    /// wire's `vc.listVoices` AND the Voice panel so the two can never
    /// diverge: the reserved `"base"` smoke target FIRST (fetched from its
    /// own `GET /v1/voice/base/status` endpoint — the facade's `/v1/voice/
    /// list` is real-user-voices-only BY ITS OWN m10-p-2 DESIGN, so base
    /// never appears there), then every real trained voice from the list
    /// endpoint. Descriptor CONTENTS are the facade's own, verbatim — base
    /// arrives honestly self-labeled (`kind:"builtin"`, `trained:false`, its
    /// explanatory note, and a real `state` reflecting whether the smoke
    /// checkpoint is actually on disk) — this helper only composes WHICH
    /// endpoints are read, it never invents or edits a field.
    public func availableVoiceTargets() async throws -> [VoiceDescriptor] {
        let base = try await voiceStatus(voiceID: "base")
        let real = try await listVoices()
        return [base] + real
    }
}

public actor VoiceConversionClient: VoiceConverting {
    public let config: Configuration
    private let session: URLSession

    // MARK: m23-fp state — the convert gate, the sequence, the instrument

    /// True while one conversion holds the gate (see `acquireConvertGate()`).
    private var convertGateHeld = false
    /// FIFO of conversions parked waiting for the gate.
    private var convertGateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Strictly increasing, per client instance — the human-readable ordering
    /// part of a capture's file name. NOT a uniqueness key (see
    /// `VoiceConversionOutput.captureFileName`).
    private var captureSequence = 0
    /// How many conversions are currently between "POST issued" and "output
    /// captured".
    private var convertsInFlight = 0
    /// The highest value `convertsInFlight` has ever reached — the instrument
    /// for the gate's one claim, and the reason that claim is testable without
    /// timing. It must be `1` after ANY number of concurrent `convert(_:)`
    /// calls; a `2` means some conversion was issued while an earlier output
    /// was still uncaptured, which is exactly the window the facade overwrites
    /// its own file in. Internal on purpose: `@testable` reaches it, nothing
    /// shipped depends on it.
    private(set) var maxConvertsInFlight = 0

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

    // MARK: - Convert (m10-p-4: wired behind `vc.convertVocals`)

    /// BLOCKING — the facade's `POST /v1/voice/convert` is synchronous and
    /// measured at ~37x real time (m10-p-2), so a multi-minute source clip
    /// can take a while even before the engine-load cold-start cost. Uses
    /// `config.convertTimeoutSeconds` (default 300s) rather than the fast
    /// `config.requestTimeoutSeconds` every other call on this client uses
    /// (health/list/status/train all stay fast) — the `ACEStepClient.post`
    /// per-call `timeoutSeconds` override precedent (`POST /v1/init`'s
    /// `modelInitTimeoutSeconds`), not a second client instance.
    ///
    /// ## m23-fp — the returned `outputPath` is OURS, not the facade's
    ///
    /// The facade overwrites its own output within a wall-clock second
    /// (`VoiceConversionOutput`'s doc has the measurement and the full
    /// reasoning), so this call COPIES the file it is told about into
    /// `config.captureDirectory` and returns THAT path. The facade's own path
    /// is preserved, unaltered, in `VoiceConvertResult.sidecarOutputPath` for
    /// diagnostics — but nothing downstream may read it.
    ///
    /// ⚠️ **Wire-visible meaning change:** `vc.convertVocals`'s `outputPath`
    /// response field now names this app's copy. Same field, same type, no
    /// rename and nothing removed — but a caller that previously correlated
    /// that string with a file in `scripts/rvc/runtime/out/` will not find it
    /// there any more. That is the fix, not a side effect.
    ///
    /// The whole POST-parse-copy sequence runs under a gate that admits ONE
    /// conversion at a time, so a second conversion cannot be issued while an
    /// earlier output is still uncaptured. That is what makes the copy safe
    /// rather than merely likely: `_engine_lock` serialises the facade, so
    /// while we hold the gate there is no other conversion in existence to
    /// overwrite the file underneath us.
    ///
    /// ⚠️ **Honest limit of that guarantee — it is per client INSTANCE.** The
    /// app builds exactly one `VoiceConversionClient` and shares it with the
    /// control router (`DAWProApp.swift:3212`/`:3574`), so the wire and the
    /// Voice panel are covered by one gate. A second instance, or a second
    /// process (a gate run, a script) converting against the same sidecar, is
    /// NOT — no in-process lock can cover that, and nothing here pretends to.
    public func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        await acquireConvertGate()
        defer { releaseConvertGate() }
        return try await performConvert(request)
    }

    private func performConvert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        convertsInFlight += 1
        maxConvertsInFlight = max(maxConvertsInFlight, convertsInFlight)
        defer { convertsInFlight -= 1 }

        let body: [String: Any] = [
            "inputPath": request.inputPath,
            "voiceId": request.voiceId,
            "pitchSemitones": request.pitchSemitones,
        ]
        let data = try await post(
            path: "v1/voice/convert", body: body, timeoutSeconds: config.convertTimeoutSeconds)
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
        // m23-fp — copy NOW, before the gate is released and another
        // conversion may be issued. Throws rather than falling back to
        // `outputPath`: handing back a path known to be overwritable is the
        // failure this item exists to end.
        captureSequence += 1
        let captured = try VoiceConversionOutput.capture(
            sidecarPath: outputPath,
            voiceId: voiceId,
            sequence: captureSequence,
            into: config.captureDirectory)
        return VoiceConvertResult(
            outputPath: captured.path, sidecarOutputPath: outputPath, voiceId: voiceId,
            inputSeconds: inputSeconds,
            engineLoadSeconds: engineLoadSeconds, inferSeconds: inferSeconds,
            rtf: asDouble(object["rtf"]), sampleRate: sampleRate, realConversion: realConversion,
            note: object["note"] as? String)
    }

    // MARK: - The convert gate (m23-fp)

    /// Admits one conversion at a time, FIFO.
    ///
    /// An `actor` alone does NOT give this: `convert(_:)` suspends at its
    /// `await` on the network, and the actor is re-entrant across that
    /// suspension, so without this gate a second call would happily issue its
    /// POST while the first conversion's output sat uncaptured on disk. The
    /// classic actor-mutex shape — the `withCheckedContinuation` closure runs
    /// synchronously, still on the actor, so appending the waiter cannot race
    /// the check above it.
    ///
    /// Deliberately NOT an unstructured `Task` chain: parking the CALLER keeps
    /// `convert(_:)` structured, so cancelling the caller still cancels the
    /// underlying `URLSession` request exactly as it did before this existed.
    private func acquireConvertGate() async {
        if !convertGateHeld {
            convertGateHeld = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            convertGateWaiters.append(continuation)
        }
    }

    /// Hands the gate to the next waiter, or drops it if there is none.
    ///
    /// Note that `convertGateHeld` stays `true` when a waiter is resumed —
    /// ownership is transferred, never released and re-taken, so a third
    /// caller arriving in between cannot jump the queue. Always reached: the
    /// call site is a `defer`, so a throwing conversion releases the gate too.
    private func releaseConvertGate() {
        if convertGateWaiters.isEmpty {
            convertGateHeld = false
        } else {
            convertGateWaiters.removeFirst().resume()
        }
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

    /// `timeoutSeconds` defaults to `config.requestTimeoutSeconds` (the fast
    /// JSON calls); `convert(_:)` overrides it with `config.convertTimeoutSeconds`
    /// for `POST /v1/voice/convert`, which can run for minutes on a real
    /// source clip (the `ACEStepClient.post` `POST /v1/init` precedent).
    private func post(path: String, body: [String: Any], timeoutSeconds: Double? = nil) async throws -> Data {
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds ?? config.requestTimeoutSeconds
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
        /// Timeout for the fast JSON calls (`/health`, `/v1/voice/list`,
        /// `/v1/voice/{id}/status`, `/v1/voice/train` — the facade answers
        /// train fast today, always a 400/501 shape/contract error; see
        /// `train(_:)`'s own doc). Unchanged from m10-p-3.
        public var requestTimeoutSeconds: Double
        /// Timeout for `POST /v1/voice/convert` ONLY (m10-p-4) — real
        /// conversion runs ~37x real time (m10-p-2 measurement) plus a
        /// cold-engine load, so a multi-minute source clip can legitimately
        /// take minutes. Deliberately generous and deliberately NOT shared
        /// with `requestTimeoutSeconds`, so health/list/status/train stay
        /// fast-timeout even while a convert call is slow — the
        /// `ACEStepClient.Configuration.modelInitTimeoutSeconds` precedent
        /// for "one call on this client legitimately needs its own budget".
        public var convertTimeoutSeconds: Double
        /// m23-fp — where `convert(_:)` copies the facade's output to, and
        /// therefore what its returned `outputPath` names.
        ///
        /// Defaults to the app-owned `VoiceConversionOutput.directory`.
        /// Injectable so tests capture into a temp directory instead of the
        /// real profile; there is deliberately NO environment override for it
        /// — `AppDirectories` already relocates the whole profile through
        /// `DAWPRO_PROFILE_ROOT`, and a second, narrower variable would be one
        /// more thing that can be set inconsistently.
        public var captureDirectory: URL

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8002")!,
            requestTimeoutSeconds: Double = 10,
            convertTimeoutSeconds: Double = 300,
            captureDirectory: URL = VoiceConversionOutput.directory
        ) {
            self.baseURL = baseURL
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.convertTimeoutSeconds = convertTimeoutSeconds
            self.captureDirectory = captureDirectory
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
    /// ⚠️ **Since m23-fp this is THIS APP'S copy, not the facade's file.**
    /// `VoiceConversionClient.convert(_:)` copies the facade's output into
    /// `Configuration.captureDirectory` the moment it parses the response,
    /// because the facade overwrites its own output within a wall-clock second
    /// (`VoiceConversionOutput`). Everything downstream — `vc.convertVocals`'s
    /// wire response, `ProjectStore.importConvertedVoice`, the Voice panel —
    /// consumes this path.
    public var outputPath: String
    /// The facade's OWN `outputPath`, verbatim, for diagnostics only (m23-fp).
    ///
    /// Never open this file: by the time anyone reads it, a later conversion
    /// in the same wall-clock second may have overwritten it — that is the
    /// entire defect. Nil for a `VoiceConvertResult` built by a fake/test that
    /// never talked to a facade.
    public var sidecarOutputPath: String?
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

    /// m10-p-4 addition (the `VoiceConversionHealth`/`VoiceDescriptor`
    /// precedent in this same file, and `SongGenerationSubmission`'s in
    /// `Providers.swift`): an explicit public init, since the auto-
    /// synthesized memberwise init a bare `public struct` gets is only
    /// `internal` — callers outside AIServices (DAWControl's fakes for
    /// `VoiceConverting`) need to construct one without `@testable import`.
    public init(
        outputPath: String, sidecarOutputPath: String? = nil, voiceId: String,
        inputSeconds: Double, engineLoadSeconds: Double,
        inferSeconds: Double, rtf: Double? = nil, sampleRate: Int, realConversion: Bool,
        note: String? = nil
    ) {
        self.outputPath = outputPath
        self.sidecarOutputPath = sidecarOutputPath
        self.voiceId = voiceId
        self.inputSeconds = inputSeconds
        self.engineLoadSeconds = engineLoadSeconds
        self.inferSeconds = inferSeconds
        self.rtf = rtf
        self.sampleRate = sampleRate
        self.realConversion = realConversion
        self.note = note
    }
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
    /// m23-fp — the conversion itself succeeded, but this app could not take
    /// its own copy of the output, so the only path it could return is one the
    /// facade may overwrite at any moment. Deliberately an ERROR rather than a
    /// fallback: a silently-returned colliding path is what this case exists
    /// to prevent.
    ///
    /// ⚠️ Added at m23-fp. Nothing switches exhaustively over this enum
    /// outside `errorDescription` below (checked: `VoicePanelModel` has a
    /// `default`, `CommandRouter.translateVoiceConversionError` uses an `if
    /// case`), so no call site silently changed meaning.
    case outputCaptureFailed(String)

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
        case .outputCaptureFailed(let detail):
            return "the voice conversion finished, but its audio could not be copied into this "
                + "app's own storage (\(detail)) — the sidecar reuses output filenames within "
                + "one second, so the file it wrote cannot be trusted to survive; free up disk "
                + "space or check permissions on the DAWPro/VoiceConversions folder, then "
                + "convert again."
        }
    }
}
