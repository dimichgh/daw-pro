import Foundation
import Network
import Testing
@testable import AIServices

/// Minimal in-process HTTP responder for exercising `ACEStepClient` against
/// canned upstream shapes without a real ACE-Step process — the multi-route,
/// multi-call sibling of `SidecarManagerTests.StubHealthServer` (same
/// NWListener plumbing, extended to actually parse method/path/body and
/// serve a QUEUE of responses per route, since a generation round-trip needs
/// several distinct calls: submit, poll x N, fetch audio).
///
/// Responses are keyed by `"<METHOD> <path>"` (query string stripped). Each
/// key holds a FIFO queue; once only one response remains queued for a key,
/// that response repeats for all further calls (models "job stays succeeded
/// once it succeeds").
final class StubACEStepServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stub-acestep-server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private let stateLock = NSLock()
    private var responseQueues: [String: [Data]] = [:]
    private var callCounts: [String: Int] = [:]
    private var lastBodies: [String: Data] = [:]

    func enqueue(_ response: Data, forKey key: String) {
        stateLock.lock()
        responseQueues[key, default: []].append(response)
        stateLock.unlock()
    }

    func callCount(forKey key: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return callCounts[key, default: 0]
    }

    /// The most recent request body received for `key` (e.g. `"POST
    /// /release_task"`), for asserting outgoing field names/values.
    func lastBody(forKey key: String) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastBodies[key]
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
                semaphore.signal()
            }
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 2) == .success, port != 0 else {
            listener.cancel()
            throw ACEStepError.malformedResponse("stub ACE-Step server failed to start")
        }
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let (requestLine, body) = Self.parseRequest(next) {
                self.respond(requestLine: requestLine, body: body, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func respond(requestLine: String, body: Data, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let fullPath = parts.count > 1 ? String(parts[1]) : ""
        let path = String(fullPath.split(separator: "?", maxSplits: 1).first ?? Substring(fullPath))
        let key = "\(method) \(path)"

        stateLock.lock()
        callCounts[key, default: 0] += 1
        lastBodies[key] = body
        let response: Data
        if var queued = responseQueues[key], !queued.isEmpty {
            response = queued.count > 1 ? queued.removeFirst() : queued[0]
            responseQueues[key] = queued
        } else {
            response = Self.httpResponse(
                status: 404, contentType: "application/json",
                bodyData: Data(#"{"error":"no stub response queued for \#(key)"}"#.utf8))
        }
        stateLock.unlock()

        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Parses a buffered HTTP/1.1 request; `nil` while more bytes are needed.
    private static func parseRequest(_ data: Data) -> (requestLine: String, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerString = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1)
            if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(fields[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        return (requestLine, Data(data[bodyStart..<(bodyStart + contentLength)]))
    }

    static func httpResponse(status: Int = 200, contentType: String, bodyData: Data) -> Data {
        var header = "HTTP/1.1 \(status) OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + bodyData
    }

    static func jsonResponse(status: Int = 200, _ body: String) -> Data {
        httpResponse(status: status, contentType: "application/json", bodyData: Data(body.utf8))
    }

    /// Allocates a loopback port, then frees it immediately (see
    /// `StubHealthServer.unusedLoopbackPort()`) — a probe against it
    /// deterministically sees connection-refused.
    static func unusedLoopbackPort() throws -> UInt16 {
        let server = StubACEStepServer()
        try server.start()
        let port = server.port
        server.stop()
        return port
    }
}

// MARK: - Canned upstream response bodies

/// Bodies verified against `acestep/api_server.py` (`_wrap_response`),
/// `acestep/api/http/release_task_route.py`, and
/// `acestep/api/http/query_result_service.py`. Built via `JSONSerialization`
/// (not hand-interpolated strings) so the `result` field's DOUBLE JSON
/// encoding (a legacy-compatibility quirk: it's a JSON-encoded STRING nested
/// inside the outer JSON) is always correctly escaped, including characters
/// like the newline in a `[Verse 1]\n...` lyric that a naive quote-only
/// string-replace would corrupt.
private enum ACEStepFixtures {
    private static func envelope(data: Any) -> Data {
        let object: [String: Any] = [
            "data": data,
            "code": 200,
            "error": NSNull(),
            "timestamp": 1_720_000_000_000,
            "extra": NSNull(),
        ]
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        return StubACEStepServer.httpResponse(contentType: "application/json", bodyData: bytes)
    }

    private static func queryResultItem(
        taskID: String, progressText: String?, resultItems: [[String: Any]], status: Int
    ) -> [String: Any] {
        let resultBytes = try! JSONSerialization.data(withJSONObject: resultItems)
        var item: [String: Any] = [
            "task_id": taskID,
            "result": String(data: resultBytes, encoding: .utf8)!,
            "status": status,
        ]
        if let progressText { item["progress_text"] = progressText }
        return item
    }

    static func releaseTaskAccepted(taskID: String, queuePosition: Int = 1) -> Data {
        envelope(data: ["task_id": taskID, "status": "queued", "queue_position": queuePosition])
    }

    static func queryResultQueued(taskID: String) -> Data {
        let inner: [[String: Any]] = [[
            "file": "", "wave": "", "status": 0, "create_time": 1_720_000_000, "env": "development",
            "prompt": "", "lyrics": "", "metas": [String: Any](),
            "progress": 0.0, "stage": "queued", "error": NSNull(),
        ]]
        let item = queryResultItem(
            taskID: taskID, progressText: "waiting in queue", resultItems: inner, status: 0)
        return envelope(data: [item])
    }

    static func queryResultRunning(taskID: String, progress: Double, logLine: String) -> Data {
        let inner: [[String: Any]] = [[
            "file": "", "wave": "", "status": 0, "create_time": 1_720_000_000, "env": "development",
            "prompt": "", "lyrics": "", "metas": [String: Any](),
            "progress": progress, "stage": "running", "error": NSNull(),
        ]]
        let item = queryResultItem(taskID: taskID, progressText: logLine, resultItems: inner, status: 0)
        return envelope(data: [item])
    }

    static func queryResultSucceeded(taskID: String, remoteFile: String) -> Data {
        let inner: [[String: Any]] = [[
            "file": remoteFile, "wave": "", "status": 1, "create_time": 1_720_000_005,
            "env": "development", "prompt": "a song", "lyrics": "[Verse 1]\nhello",
            "metas": [
                "bpm": 120, "duration": 30.0, "genres": "pop",
                "keyscale": "C Major", "timesignature": "4/4",
            ] as [String: Any],
        ]]
        let item = queryResultItem(taskID: taskID, progressText: "done", resultItems: inner, status: 1)
        return envelope(data: [item])
    }

    static func queryResultFailed(taskID: String, error: String) -> Data {
        let inner: [[String: Any]] = [[
            "file": "", "wave": "", "status": 2, "create_time": 1_720_000_000, "env": "development",
            "prompt": "", "lyrics": "", "metas": [String: Any](),
            "progress": 0.4, "stage": "failed", "error": error,
        ]]
        let item = queryResultItem(taskID: taskID, progressText: "failed", resultItems: inner, status: 2)
        return envelope(data: [item])
    }

    /// A minimal-but-valid PCM16 mono WAV file (44-byte header + a handful
    /// of silent samples) — enough to prove byte-exact retrieval, not a
    /// claim about audio content.
    static func tinyWAV() -> Data {
        var data = Data()
        let sampleRate: UInt32 = 48000
        let numSamples: UInt32 = 8
        let byteRate = sampleRate * 2
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        data.append(Data("RIFF".utf8))
        data.append(le32(36 + numSamples * 2))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.append(le32(16))
        data.append(le16(1)) // PCM
        data.append(le16(1)) // mono
        data.append(le32(sampleRate))
        data.append(le32(byteRate))
        data.append(le16(2)) // block align
        data.append(le16(16)) // bits per sample
        data.append(Data("data".utf8))
        data.append(le32(numSamples * 2))
        for _ in 0..<numSamples { data.append(le16(0)) }
        return data
    }
}

@Suite("ACEStepClient — song generation against a stub sidecar (M6 ii)")
struct ACEStepClientTests {
    private func makeClient(port: UInt16, downloadDirectory: URL) -> ACEStepClient {
        ACEStepClient(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            downloadDirectory: downloadDirectory))
    }

    private func makeTempDownloadDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-client-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("generateSong submits and returns the upstream task id/queue position")
    func submitHappyPath() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.releaseTaskAccepted(taskID: "job-abc", queuePosition: 3),
            forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let submission = try await client.generateSong(SongGenerationRequest(prompt: "80s synth-pop"))

        #expect(submission.jobID == "job-abc")
        #expect(submission.state == .queued)
        #expect(submission.queuePosition == 3)
    }

    @Test("generationStatus progresses queued -> running -> succeeded, fetching audio once on success")
    func fullPollProgression() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        let downloadDir = try makeTempDownloadDir()
        defer { try? FileManager.default.removeItem(at: downloadDir) }

        let remoteFile = "/sidecar/tmp/job-progress.wav"
        server.enqueue(ACEStepFixtures.queryResultQueued(taskID: "job-progress"), forKey: "POST /query_result")
        server.enqueue(
            ACEStepFixtures.queryResultRunning(taskID: "job-progress", progress: 0.4, logLine: "step 3/8"),
            forKey: "POST /query_result")
        server.enqueue(
            ACEStepFixtures.queryResultSucceeded(taskID: "job-progress", remoteFile: remoteFile),
            forKey: "POST /query_result")
        let wav = ACEStepFixtures.tinyWAV()
        server.enqueue(
            StubACEStepServer.httpResponse(contentType: "audio/wav", bodyData: wav),
            forKey: "GET /v1/audio")

        let client = makeClient(port: server.port, downloadDirectory: downloadDir)

        let queuedStatus = try await client.generationStatus(jobID: "job-progress")
        #expect(queuedStatus.state == .queued)
        #expect(queuedStatus.audioPath == nil)

        let runningStatus = try await client.generationStatus(jobID: "job-progress")
        #expect(runningStatus.state == .running)
        #expect(runningStatus.progress == 0.4)
        #expect(runningStatus.statusText == "step 3/8")
        #expect(runningStatus.audioPath == nil)

        let succeededStatus = try await client.generationStatus(jobID: "job-progress")
        #expect(succeededStatus.state == .succeeded)
        #expect(succeededStatus.progress == 1.0)
        let audioPath = try #require(succeededStatus.audioPath)
        #expect(FileManager.default.fileExists(atPath: audioPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: audioPath)) == wav)
        #expect(server.callCount(forKey: "GET /v1/audio") == 1)

        // Polling again after success reuses the cached local path without a
        // second GET /v1/audio call (the documented fetch-once contract).
        let secondSucceededStatus = try await client.generationStatus(jobID: "job-progress")
        #expect(secondSucceededStatus.audioPath == audioPath)
        #expect(server.callCount(forKey: "GET /v1/audio") == 1)
    }

    @Test("generationStatus throws jobFailed with the upstream error detail, not a bare 'failed' state")
    func jobFailedMapsToThrownError() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.queryResultFailed(taskID: "job-bad", error: "CUDA out of memory"),
            forKey: "POST /query_result")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.generationStatus(jobID: "job-bad")
            Issue.record("expected generationStatus to throw for a failed job")
        } catch let error as ACEStepError {
            guard case .jobFailed(let jobID, let message) = error else {
                Issue.record("expected .jobFailed, got \(error)")
                return
            }
            #expect(jobID == "job-bad")
            #expect(message == "CUDA out of memory")
            #expect(error.errorDescription?.contains("job-bad") == true)
            #expect(error.errorDescription?.contains("CUDA out of memory") == true)
        }
    }

    @Test("connection refused (sidecar not running) maps to sidecarUnreachable")
    func connectionRefusedMapsToSidecarUnreachable() async throws {
        let port = try StubACEStepServer.unusedLoopbackPort()
        let client = makeClient(port: port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.generateSong(SongGenerationRequest(prompt: "test"))
            Issue.record("expected generateSong to throw when the sidecar is unreachable")
        } catch let error as ACEStepError {
            guard case .sidecarUnreachable = error else {
                Issue.record("expected .sidecarUnreachable, got \(error)")
                return
            }
            #expect(error.errorDescription?.contains("ai.sidecarStart") == true)
        }
    }

    @Test("malformed top-level JSON from /release_task maps to malformedResponse")
    func malformedTopLevelJSONMapsToMalformedResponse() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.httpResponse(contentType: "text/plain", bodyData: Data("not json at all".utf8)),
            forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.generateSong(SongGenerationRequest(prompt: "test"))
            Issue.record("expected generateSong to throw on malformed JSON")
        } catch let error as ACEStepError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test("malformed nested 'result' string from /query_result maps to malformedResponse")
    func malformedNestedResultMapsToMalformedResponse() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
            {"data":[{"task_id":"job-weird","result":"not-json","status":0,"progress_text":"?"}], \
            "code":200,"error":null,"timestamp":1720000000000,"extra":null}
            """),
            forKey: "POST /query_result")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.generationStatus(jobID: "job-weird")
            Issue.record("expected generationStatus to throw on a malformed nested result")
        } catch let error as ACEStepError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test("unknown job id (never submitted / expired) maps to jobNotFound")
    func unknownJobIDMapsToJobNotFound() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
            {"data":[{"task_id":"job-unknown","result":"[]","status":0}], \
            "code":200,"error":null,"timestamp":1720000000000,"extra":null}
            """),
            forKey: "POST /query_result")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.generationStatus(jobID: "job-unknown")
            Issue.record("expected generationStatus to throw for an unknown job id")
        } catch let error as ACEStepError {
            guard case .jobNotFound(let jobID) = error else {
                Issue.record("expected .jobNotFound, got \(error)")
                return
            }
            #expect(jobID == "job-unknown")
        }
    }

    @Test("release_task body carries the caller's generation knobs with ACE-Step's own field names")
    func releaseTaskBodyFieldNames() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "job-fields"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        var request = SongGenerationRequest(prompt: "anthemic pop-punk", lyrics: "[Verse 1]\nhello")
        request.durationSeconds = 45
        request.seed = 42
        request.bpm = 128
        request.keyScale = "C Major"
        request.timeSignature = "4/4"
        request.guidanceScale = 8.5
        request.inferenceSteps = 12
        _ = try await client.generateSong(request)

        #expect(server.callCount(forKey: "POST /release_task") == 1)
        let bodyData = try #require(server.lastBody(forKey: "POST /release_task"))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        // Field names verified against release_task_request_builder.py's
        // `build_generate_music_request` — ACE-Step's own snake_case wire
        // names, not our Swift camelCase property names.
        #expect(body["prompt"] as? String == "anthemic pop-punk")
        #expect(body["lyrics"] as? String == "[Verse 1]\nhello")
        #expect(body["audio_duration"] as? Double == 45)
        #expect(body["seed"] as? Int == 42)
        #expect(body["use_random_seed"] as? Bool == false)
        #expect(body["bpm"] as? Int == 128)
        #expect(body["key_scale"] as? String == "C Major")
        #expect(body["time_signature"] as? String == "4/4")
        #expect(body["guidance_scale"] as? Double == 8.5)
        #expect(body["inference_steps"] as? Int == 12)
        #expect(body["vocal_language"] as? String == "en")
        #expect(body["audio_format"] as? String == "wav")
    }
}
