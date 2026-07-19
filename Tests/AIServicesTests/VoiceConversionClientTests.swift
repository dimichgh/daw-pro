import Foundation
import Testing
@testable import AIServices

/// `VoiceConversionClient` coverage (m10-p-3) — the `ACEStepClientTests`
/// sibling for the RVC facade's v1 contract. Reuses `StubACEStepServer`
/// (`ACEStepClientTests.swift`) as-is: its method/path/body-aware stub
/// plumbing is entirely generic, not ACE-Step-specific, so no new stub
/// server is needed. Bodies below are shaped directly from
/// `scripts/rvc/server.py`'s route source (see `VoiceConversionClient`'s own
/// doc comment for the key shape distinction from ACE: only `/health` uses
/// the `{data, code, error}` envelope; every other success response is raw/
/// unwrapped, and every error response shares one teaching-error envelope,
/// `{"error": {"code", "message"}}`).
private func baseURL(port: UInt16) -> URL {
    URL(string: "http://127.0.0.1:\(port)")!
}

private func makeClient(port: UInt16) -> VoiceConversionClient {
    VoiceConversionClient(configuration: .init(baseURL: baseURL(port: port)))
}

@Suite("VoiceConversionClient — health() (m10-p-3)")
struct VoiceConversionClientHealthTests {
    @Test("200 + well-formed data envelope -> VoiceConversionHealth, every field parsed")
    func healthyMapsToHealth() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
                {"data":{"service":"rvc-vc-facade","version":"0.1.0",\
                "engine":"Acelogic/Retrieval-based-Voice-Conversion-MLX",\
                "baseModelPresent":true,"voiceCount":0,"port":8002},"code":0,"error":null}
                """),
            forKey: "GET /health")

        let health = try await makeClient(port: server.port).health()

        #expect(health.service == "rvc-vc-facade")
        #expect(health.version == "0.1.0")
        #expect(health.engine == "Acelogic/Retrieval-based-Voice-Conversion-MLX")
        #expect(health.baseModelPresent == true)
        #expect(health.voiceCount == 0)
        #expect(health.port == 8002)
    }

    @Test("200 + no 'data' envelope -> malformedResponse")
    func malformedThrowsMalformedResponse() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(StubACEStepServer.jsonResponse(#"{"unexpected":"shape"}"#), forKey: "GET /health")

        await #expect(throws: VoiceConversionError.self) {
            _ = try await makeClient(port: server.port).health()
        }
    }

    @Test("connection refused -> sidecarUnreachable")
    func unreachableThrowsSidecarUnreachable() async throws {
        let port = try StubACEStepServer.unusedLoopbackPort()
        do {
            _ = try await makeClient(port: port).health()
            Issue.record("expected health() to throw")
        } catch let error as VoiceConversionError {
            guard case .sidecarUnreachable = error else {
                Issue.record("expected .sidecarUnreachable, got \(error)")
                return
            }
        }
    }
}

@Suite("VoiceConversionClient — voices (m10-p-3)")
struct VoiceConversionClientVoicesTests {
    @Test("GET /v1/voice/list -> real voices decoded, hasIndex/createdAt carried")
    func listVoicesDecodesRealVoices() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
                {"voices":[{"id":"my-voice","name":"My Voice","state":"ready",\
                "hasIndex":true,"createdAt":"2026-07-17T00:00:00Z"}]}
                """),
            forKey: "GET /v1/voice/list")

        let voices = try await makeClient(port: server.port).listVoices()

        #expect(voices.count == 1)
        #expect(voices[0].id == "my-voice")
        #expect(voices[0].name == "My Voice")
        #expect(voices[0].state == "ready")
        #expect(voices[0].hasIndex == true)
        #expect(voices[0].createdAt == "2026-07-17T00:00:00Z")
        #expect(voices[0].kind == nil, "real voices never carry the builtin-only 'kind' field")
    }

    @Test("GET /v1/voice/list -> empty until training ships (m10-p-5/p-6)")
    func listVoicesEmptyByDefault() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(StubACEStepServer.jsonResponse(#"{"voices":[]}"#), forKey: "GET /v1/voice/list")

        let voices = try await makeClient(port: server.port).listVoices()
        #expect(voices.isEmpty)
    }

    @Test("GET /v1/voice/base/status -> the reserved builtin descriptor shape (kind/trained/note)")
    func voiceStatusBaseDescriptor() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
                {"id":"base","name":"Base (untrained smoke target)","state":"ready",\
                "kind":"builtin","trained":false,"note":"generic Applio base synthesizer"}
                """),
            forKey: "GET /v1/voice/base/status")

        let descriptor = try await makeClient(port: server.port).voiceStatus(voiceID: "base")

        #expect(descriptor.id == "base")
        #expect(descriptor.kind == "builtin")
        #expect(descriptor.trained == false)
        #expect(descriptor.note != nil)
        #expect(descriptor.hasIndex == nil, "the builtin descriptor never carries hasIndex/createdAt")
    }

    @Test("GET /v1/voice/{unknown}/status -> requestFailed(404, unknownVoice), teaching message verbatim")
    func voiceStatusUnknownVoiceTeaches() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(
                status: 404,
                #"{"error":{"code":"unknownVoice","message":"no voice named 'ghost' exists. List real voices with GET /v1/voice/list"}}"#),
            forKey: "GET /v1/voice/ghost/status")

        do {
            _ = try await makeClient(port: server.port).voiceStatus(voiceID: "ghost")
            Issue.record("expected voiceStatus to throw")
        } catch let error as VoiceConversionError {
            guard case .requestFailed(let status, let code, let message) = error else {
                Issue.record("expected .requestFailed, got \(error)")
                return
            }
            #expect(status == 404)
            #expect(code == "unknownVoice")
            #expect(message.contains("no voice named 'ghost'"))
        }
    }
}

@Suite("VoiceConversionClient — convert() (m10-p-3)")
struct VoiceConversionClientConvertTests {
    @Test("POST /v1/voice/convert happy path -> VoiceConvertResult decoded, request body shaped correctly")
    func convertHappyPathDecodesResult() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
                {"outputPath":"/tmp/out.wav","voiceId":"base","inputSeconds":5.0,\
                "engineLoadSeconds":0.5,"inferSeconds":0.135,"rtf":37.13,"sampleRate":40000,\
                "realConversion":false,"note":"base is the untrained generic target"}
                """),
            forKey: "POST /v1/voice/convert")

        let result = try await makeClient(port: server.port).convert(
            VoiceConvertRequest(inputPath: "/tmp/in.wav", voiceId: "base", pitchSemitones: 2))

        #expect(result.outputPath == "/tmp/out.wav")
        #expect(result.voiceId == "base")
        #expect(result.inputSeconds == 5.0)
        #expect(result.sampleRate == 40000)
        #expect(result.realConversion == false)
        #expect(result.note != nil)

        let sentBody = server.lastBody(forKey: "POST /v1/voice/convert")
        let sentJSON = try #require(sentBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(sentJSON["inputPath"] as? String == "/tmp/in.wav")
        #expect(sentJSON["voiceId"] as? String == "base")
        #expect(sentJSON["pitchSemitones"] as? Int == 2)
    }

    @Test("POST /v1/voice/convert on a not-ready voice -> requestFailed(409, voiceNotReady) verbatim")
    func convertVoiceNotReadySurfacesVerbatim() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(
                status: 409,
                #"{"error":{"code":"voiceNotReady","message":"voice 'x' exists but has no MLX model (model.npz) yet"}}"#),
            forKey: "POST /v1/voice/convert")

        do {
            _ = try await makeClient(port: server.port).convert(
                VoiceConvertRequest(inputPath: "/tmp/in.wav", voiceId: "x"))
            Issue.record("expected convert() to throw")
        } catch let error as VoiceConversionError {
            guard case .requestFailed(let status, let code, let message) = error else {
                Issue.record("expected .requestFailed, got \(error)")
                return
            }
            #expect(status == 409)
            #expect(code == "voiceNotReady")
            #expect(message.contains("model.npz"))
        }
    }
}

@Suite("VoiceConversionClient — train() (m10-p-3, always throws today)")
struct VoiceConversionClientTrainTests {
    @Test("POST /v1/voice/train -> the facade's 501 trainingNotYetAvailable teaching error, verbatim")
    func trainSurfaces501Verbatim() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(
                status: 501,
                #"{"error":{"code":"trainingNotYetAvailable","message":"contract reserved — training ships with the Voice panel (m10-p-5/p-6)"}}"#),
            forKey: "POST /v1/voice/train")

        do {
            _ = try await makeClient(port: server.port).train(
                VoiceTrainRequest(name: "My Voice", datasetDir: "/tmp/dataset"))
            Issue.record("expected train() to throw")
        } catch let error as VoiceConversionError {
            guard case .requestFailed(let status, let code, let message) = error else {
                Issue.record("expected .requestFailed, got \(error)")
                return
            }
            #expect(status == 501)
            #expect(code == "trainingNotYetAvailable")
            #expect(message.contains("m10-p-5/p-6"))
        }

        let sentBody = server.lastBody(forKey: "POST /v1/voice/train")
        let sentJSON = try #require(sentBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(sentJSON["name"] as? String == "My Voice")
        #expect(sentJSON["datasetDir"] as? String == "/tmp/dataset")
        #expect(sentJSON["voiceId"] == nil, "an omitted voiceId is never sent as a stray key")
        #expect(sentJSON["epochs"] == nil, "an omitted epochs is never sent as a stray key")
    }

    @Test("POST /v1/voice/train shape-invalid request -> the facade's 400 datasetNotFound, verbatim")
    func trainSurfacesShapeErrorVerbatim() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(
                status: 400,
                #"{"error":{"code":"datasetNotFound","message":"datasetDir '/nope' is not a directory"}}"#),
            forKey: "POST /v1/voice/train")

        do {
            _ = try await makeClient(port: server.port).train(
                VoiceTrainRequest(name: "My Voice", datasetDir: "/nope", voiceId: "custom", epochs: 50))
            Issue.record("expected train() to throw")
        } catch let error as VoiceConversionError {
            guard case .requestFailed(let status, let code, _) = error else {
                Issue.record("expected .requestFailed, got \(error)")
                return
            }
            #expect(status == 400)
            #expect(code == "datasetNotFound")
        }

        let sentBody = server.lastBody(forKey: "POST /v1/voice/train")
        let sentJSON = try #require(sentBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(sentJSON["voiceId"] as? String == "custom")
        #expect(sentJSON["epochs"] as? Int == 50)
    }
}

@Suite("VoiceConversionClient — Configuration timeouts (m10-p-4)")
struct VoiceConversionClientTimeoutConfigTests {
    @Test("convertTimeoutSeconds defaults to >= 300s, separate from and without inflating requestTimeoutSeconds")
    func convertGetsALongTimeoutWithoutSlowingFastCalls() {
        let config = VoiceConversionClient.Configuration()
        // vc.convertVocals: real conversion can legitimately take minutes
        // (m10-p-2 measured ~37x real time plus a cold-engine load).
        #expect(config.convertTimeoutSeconds >= 300)
        // health/list/status/train must NOT inherit convert's long timeout —
        // train answers today's 400/501 fast, by design (see `train(_:)`'s
        // own doc), and health/list/status are polled frequently.
        #expect(config.requestTimeoutSeconds == 10)
    }
}
