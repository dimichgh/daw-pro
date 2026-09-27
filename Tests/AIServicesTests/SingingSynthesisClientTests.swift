import Foundation
import Testing
@testable import AIServices

/// `SingingSynthesisClient` coverage (item p2-sing-c). Mirrors
/// `VoiceConversionClientTests`'s shape and REUSES `StubACEStepServer`
/// (`ACEStepClientTests.swift`) as-is for the HTTP-wiring tests — its
/// method/path/body-aware stub plumbing is entirely generic, not
/// ACE-Step-specific (that file's own doc comment says so), so no new
/// in-process stub server is needed here.
///
/// The exhaustive 16-code refusal mapping is tested SEPARATELY, as a pure call
/// to `SingingFacadeError.map(code:status:message:)` with no server at all —
/// faster, and it is genuinely what is being tested (this client's own
/// routing table, cross-checked against `scripts/sing/singlib/refusals.py`'s
/// `HTTP_STATUS`/`ROUTING_STATUS` dictionaries directly, not re-typed from
/// memory). Two HTTP round-trip tests below then prove the status/body
/// actually reach `map` correctly — the wiring, not the table.
private func baseURL(port: UInt16) -> URL {
    URL(string: "http://127.0.0.1:\(port)")!
}

private func makeClient(port: UInt16) -> SingingSynthesisClient {
    SingingSynthesisClient(baseURL: baseURL(port: port), timeoutSeconds: 5)
}

/// A minimal but structurally valid phrase: one note, one word naming it.
private func onePhraseRequest(
    voice: SingingVoiceReference = .builtin(id: "builtin-1"), outputPath: String = "/tmp/out.wav"
) -> SingingPhraseRequest {
    SingingPhraseRequest(
        voice: voice,
        notes: [SingingPhraseNote(startS: 0.0, endS: 0.5, midi: 60)],
        words: [SingingPhraseWord(text: "la", noteIndices: [0])],
        leadS: 0.24, trailS: 0.24, seed: 7, nSteps: 8, cfg: 1.5,
        outputPath: outputPath, outputSampleRate: 24000)
}

/// A response body shaped exactly like `stub_server.py`'s — only the fields
/// `SingingRenderResult`'s doc comment calls common to BOTH the stub and the
/// real facade, and nothing else. Any test that wants a real-facade-only
/// extra adds it on top.
private func stubShapedResponseJSON(outputPath: String = "/tmp/out.wav") -> String {
    """
    {"outputPath":"\(outputPath)","sampleRate":24000,"channels":1,"frames":12000,\
    "durationS":0.5,"peak":0.42,"rms":0.1,"nonFinite":false}
    """
}

// MARK: - The refusal table, exhaustively, with no server at all

@Suite("SingingFacadeError.map — the full refusals.py table (item p2-sing-c)")
struct SingingFacadeErrorMapTests {
    /// One entry per `scripts/sing/singlib/refusals.py`'s `HTTP_STATUS` (14) plus
    /// `ROUTING_STATUS` (2) dictionaries — 16 total, cross-checked against that file
    /// directly (2026-09-27), not retyped from a stale memory of it.
    static let knownCodes: [(code: String, status: Int)] = [
        ("badRequest", 400), ("phraseTooLong", 400), ("notesOverlap", 400),
        ("notesUnsorted", 400), ("wordsDoNotCoverNotes", 400), ("emptyWord", 400),
        ("unknownPhone", 400), ("pathNotAllowed", 403), ("voiceNotFound", 404),
        ("referenceChanged", 409), ("badReference", 422), ("loading", 503),
        ("nonFinite", 500), ("inferenceFailed", 500),
        ("notFound", 404), ("methodNotAllowed", 405),
    ]

    @Test("Every known code maps to its own named case, message carried verbatim",
          arguments: knownCodes)
    func knownCodeMapsToNamedCase(entry: (code: String, status: Int)) {
        let error = SingingFacadeError.map(code: entry.code, status: entry.status, message: "m \(entry.code)")
        let expected: SingingFacadeError
        switch entry.code {
        case "badRequest": expected = .badRequest("m \(entry.code)")
        case "phraseTooLong": expected = .phraseTooLong("m \(entry.code)")
        case "notesOverlap": expected = .notesOverlap("m \(entry.code)")
        case "notesUnsorted": expected = .notesUnsorted("m \(entry.code)")
        case "wordsDoNotCoverNotes": expected = .wordsDoNotCoverNotes("m \(entry.code)")
        case "emptyWord": expected = .emptyWord("m \(entry.code)")
        case "unknownPhone": expected = .unknownPhone("m \(entry.code)")
        case "pathNotAllowed": expected = .pathNotAllowed("m \(entry.code)")
        case "voiceNotFound": expected = .voiceNotFound("m \(entry.code)")
        case "referenceChanged": expected = .referenceChanged("m \(entry.code)")
        case "badReference": expected = .badReference("m \(entry.code)")
        case "loading": expected = .loading("m \(entry.code)")
        case "nonFinite": expected = .nonFinite("m \(entry.code)")
        case "inferenceFailed": expected = .inferenceFailed("m \(entry.code)")
        case "notFound": expected = .notFound("m \(entry.code)")
        case "methodNotAllowed": expected = .methodNotAllowed("m \(entry.code)")
        default:
            Issue.record("test table has a code \(entry.code) with no expected-case arm")
            return
        }
        #expect(error == expected)
    }

    @Test("Exactly 16 known codes — this table cannot silently shrink")
    func tableSizeIsSixteen() {
        // The anti-vacuity check for the parametrized test above: if `knownCodes`
        // ever lost an entry, every remaining `@Test` invocation could still pass
        // while coverage quietly shrank. Pin the count against refusals.py's own
        // documented total (14 + 2).
        #expect(Self.knownCodes.count == 16)
    }

    @Test("An unrecognised code -> .unrecognizedRefusal, status/code/message all carried")
    func unknownCodeIsUnrecognizedRefusal() {
        let error = SingingFacadeError.map(code: "somethingNew", status: 418, message: "teapot")
        #expect(error == .unrecognizedRefusal(status: 418, code: "somethingNew", message: "teapot"))
    }

    @Test("A nil code (no 'error' key at all) -> .unrecognizedRefusal with code nil")
    func nilCodeIsUnrecognizedRefusalWithNilCode() {
        let error = SingingFacadeError.map(code: nil, status: 500, message: "no code sent")
        #expect(error == .unrecognizedRefusal(status: 500, code: nil, message: "no code sent"))
    }
}

// MARK: - HTTP wiring: status/body actually reach the mapper and the decoder

@Suite("SingingSynthesisClient.renderPhrase — HTTP wiring (item p2-sing-c)")
struct SingingSynthesisClientRenderTests {
    @Test("200 + stub-shaped body (only the common fields) decodes fully; every real-facade-only field is nil")
    func stubShapedResponseDecodesWithoutTheRealFacadesExtras() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(stubShapedResponseJSON()), forKey: "POST /v1/sing/phrase")

        let result = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())

        #expect(result.outputPath == "/tmp/out.wav")
        #expect(result.sampleRate == 24000)
        #expect(result.channels == 1)
        #expect(result.frames == 12000)
        #expect(result.durationS == 0.5)
        #expect(result.peak == 0.42)
        #expect(result.rms == 0.1)
        #expect(result.nonFinite == false)
        // The doc comment's own claim, checked rather than trusted: a stub-shaped
        // body (no real-facade-only keys at all) must still decode successfully,
        // with every optional real-facade-only field reading back nil.
        #expect(result.samples24k == nil)
        #expect(result.seed == nil)
        #expect(result.nSteps == nil)
        #expect(result.cfg == nil)
        #expect(result.outputSha256 == nil)
        #expect(result.pcmSha256 == nil)
        #expect(result.inferSeconds == nil)
        #expect(result.rtf == nil)
        #expect(result.mpsDriverBytes == nil)
    }

    @Test("Real-facade-shaped body (every extra present) decodes every optional field too")
    func realFacadeShapedResponseDecodesEveryOptionalField() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
                {"outputPath":"/tmp/out.wav","sampleRate":24000,"channels":1,"frames":12000,\
                "durationS":0.5,"peak":0.42,"rms":0.1,"nonFinite":false,"samples24k":12000,\
                "seed":7,"nSteps":8,"cfg":1.5,"outputSha256":"abc123","pcmSha256":"def456",\
                "inferSeconds":2.1,"rtf":4.2,"mpsDriverBytes":1048576}
                """),
            forKey: "POST /v1/sing/phrase")

        let result = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())

        #expect(result.samples24k == 12000)
        #expect(result.seed == 7)
        #expect(result.nSteps == 8)
        #expect(result.cfg == 1.5)
        #expect(result.outputSha256 == "abc123")
        #expect(result.pcmSha256 == "def456")
        #expect(result.inferSeconds == 2.1)
        #expect(result.rtf == 4.2)
        #expect(result.mpsDriverBytes == 1_048_576)
    }

    @Test("The sent request body matches schema.py's shape exactly, for a builtin voice")
    func sentBodyShapedCorrectlyForBuiltinVoice() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(stubShapedResponseJSON()), forKey: "POST /v1/sing/phrase")

        _ = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())

        let sentBody = server.lastBody(forKey: "POST /v1/sing/phrase")
        let json = try #require(sentBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(json["facadeVersion"] as? Int == 1)
        let voice = try #require(json["voice"] as? [String: Any])
        #expect(voice["id"] as? String == "builtin-1")
        #expect(voice["referencePath"] == nil, "a builtin voice never sends the own-voice fields")
        let phrase = try #require(json["phrase"] as? [String: Any])
        let notes = try #require(phrase["notes"] as? [[String: Any]])
        #expect(notes.count == 1)
        #expect(notes[0]["midi"] as? Int == 60)
        #expect(notes[0]["startS"] as? Double == 0.0)
        #expect(notes[0]["endS"] as? Double == 0.5)
        let words = try #require(phrase["words"] as? [[String: Any]])
        #expect(words.count == 1)
        #expect(words[0]["text"] as? String == "la")
        #expect(words[0]["noteIndices"] as? [Int] == [0])
        #expect(json["leadS"] as? Double == 0.24)
        #expect(json["trailS"] as? Double == 0.24)
        #expect((json["seed"] as? NSNumber)?.uint64Value == 7)
        #expect(json["nSteps"] as? Int == 8)
        #expect(json["cfg"] as? Double == 1.5)
        #expect(json["outputPath"] as? String == "/tmp/out.wav")
        #expect(json["outputSampleRate"] as? Int == 24000)
    }

    @Test("The sent request body carries an own voice's reference + prompt window + labels")
    func sentBodyShapedCorrectlyForOwnVoice() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(stubShapedResponseJSON()), forKey: "POST /v1/sing/phrase")

        let ownVoice = SingingVoiceReference.own(
            id: "my-voice", referencePath: "/voices/mine/ref.wav", referenceSha256: "deadbeef",
            windowStartS: 1.0, windowEndS: 4.5,
            notes: [SingingPromptNote(startS: 0, endS: 1, midi: 62, word: "hey", continues: false)],
            promptLabelOffset: 3)

        _ = try await makeClient(port: server.port).renderPhrase(onePhraseRequest(voice: ownVoice))

        let sentBody = server.lastBody(forKey: "POST /v1/sing/phrase")
        let json = try #require(sentBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        let voice = try #require(json["voice"] as? [String: Any])
        #expect(voice["id"] as? String == "my-voice")
        #expect(voice["referencePath"] as? String == "/voices/mine/ref.wav")
        #expect(voice["referenceSha256"] as? String == "deadbeef")
        #expect(voice["promptLabelOffset"] as? Int == 3)
        let prompt = try #require(voice["prompt"] as? [String: Any])
        #expect(prompt["windowStartS"] as? Double == 1.0)
        #expect(prompt["windowEndS"] as? Double == 4.5)
        let promptNotes = try #require(prompt["notes"] as? [[String: Any]])
        #expect(promptNotes.count == 1)
        #expect(promptNotes[0]["word"] as? String == "hey")
        #expect(promptNotes[0]["continues"] as? Bool == false)
    }

    @Test("HTTP 400 badRequest -> SingingFacadeError.badRequest, message verbatim")
    func httpBadRequestMapsThroughToBadRequestCase() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(
                status: 400, #"{"error":"badRequest","message":"unknown key 'bogus'"}"#),
            forKey: "POST /v1/sing/phrase")

        do {
            _ = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())
            Issue.record("expected renderPhrase to throw")
        } catch let error as SingingFacadeError {
            guard case .badRequest(let message) = error else {
                Issue.record("expected .badRequest, got \(error)")
                return
            }
            #expect(message.contains("bogus"))
        }
    }

    @Test("HTTP 503 loading -> SingingFacadeError.loading (the model is still loading)")
    func httpLoadingMapsThroughToLoadingCase() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(
                status: 503, #"{"error":"loading","message":"the model is still loading"}"#),
            forKey: "POST /v1/sing/phrase")

        do {
            _ = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())
            Issue.record("expected renderPhrase to throw")
        } catch let error as SingingFacadeError {
            guard case .loading = error else {
                Issue.record("expected .loading, got \(error)")
                return
            }
        }
    }

    @Test("A refusal code this client does not recognise -> .unrecognizedRefusal, never silently swallowed")
    func unrecognizedRefusalCodeSurfacesDistinctly() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse(
                status: 507, #"{"error":"someFutureCode","message":"a code this client predates"}"#),
            forKey: "POST /v1/sing/phrase")

        do {
            _ = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())
            Issue.record("expected renderPhrase to throw")
        } catch let error as SingingFacadeError {
            guard case .unrecognizedRefusal(let status, let code, let message) = error else {
                Issue.record("expected .unrecognizedRefusal, got \(error)")
                return
            }
            #expect(status == 507)
            #expect(code == "someFutureCode")
            #expect(message.contains("predates"))
        }
    }

    @Test("HTTP 200 with a body missing a required field -> .malformedResponse, never a silent partial decode")
    func missingRequiredFieldIsMalformedResponse() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        // No "frames" key.
        server.enqueue(
            StubACEStepServer.jsonResponse("""
                {"outputPath":"/tmp/out.wav","sampleRate":24000,"channels":1,\
                "durationS":0.5,"peak":0.42,"rms":0.1,"nonFinite":false}
                """),
            forKey: "POST /v1/sing/phrase")

        do {
            _ = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())
            Issue.record("expected renderPhrase to throw")
        } catch let error as SingingFacadeError {
            guard case .malformedResponse(let message) = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
            #expect(message.contains("frames"))
        }
    }

    @Test("A 200 body that is not JSON at all -> .malformedResponse")
    func nonJSONBodyIsMalformedResponse() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.httpResponse(status: 200, contentType: "text/plain", bodyData: Data("not json".utf8)),
            forKey: "POST /v1/sing/phrase")

        await #expect(throws: SingingFacadeError.self) {
            _ = try await makeClient(port: server.port).renderPhrase(onePhraseRequest())
        }
    }

    @Test("Connection refused (nothing listening) -> .transport, names sing.sidecarStatus")
    func connectionRefusedIsTransportError() async throws {
        let port = try StubACEStepServer.unusedLoopbackPort()
        do {
            _ = try await makeClient(port: port).renderPhrase(onePhraseRequest())
            Issue.record("expected renderPhrase to throw")
        } catch let error as SingingFacadeError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
            #expect(error.errorDescription?.contains("sing.sidecarStatus") == true)
        }
    }
}
