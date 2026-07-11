import Foundation
import Network
import Testing
@testable import AIServices

/// In-process HTTP responder for exercising the text providers (`AnthropicClient`
/// / `OpenAIClient` `writeLyrics`) against canned responses without a real cloud
/// call — the text-API sibling of `StubACEStepServer`. Captures the request's
/// METHOD, path, HEADERS, and BODY of the most recent call per route so the
/// suites can pin the exact wire shape (auth header name, model field, and the
/// system-prompt contents). Loopback only.
final class StubTextAPIServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stub-text-api-server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private let stateLock = NSLock()
    private var responses: [String: Data] = [:]
    private var lastBodies: [String: Data] = [:]
    private var lastHeaders: [String: [String: String]] = [:]
    private var callCounts: [String: Int] = [:]

    /// Sets the canned response for a `"<METHOD> <path>"` key (repeats for every
    /// call to that route).
    func setResponse(_ response: Data, forKey key: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        responses[key] = response
    }

    func lastBody(forKey key: String) -> Data? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastBodies[key]
    }

    func lastHeaders(forKey key: String) -> [String: String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastHeaders[key] ?? [:]
    }

    func callCount(forKey key: String) -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return callCounts[key, default: 0]
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
            throw AIServiceError.malformedResponse("stub text API server failed to start")
        }
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// A loopback `AIConfig` pointing both providers at this stub (real base URLs
    /// swapped for `http://127.0.0.1:<port>`), carrying the given keys.
    func config(anthropicKey: String? = nil, openAIKey: String? = nil) -> AIConfig {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        return AIConfig(
            anthropicKey: anthropicKey, openAIKey: openAIKey,
            anthropicBaseURL: base, openAIBaseURL: base)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let parsed = Self.parseRequest(next) {
                self.respond(parsed, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func respond(
        _ parsed: (method: String, path: String, headers: [String: String], body: Data),
        on connection: NWConnection
    ) {
        let key = "\(parsed.method) \(parsed.path)"
        stateLock.lock()
        callCounts[key, default: 0] += 1
        lastBodies[key] = parsed.body
        lastHeaders[key] = parsed.headers
        let response = responses[key] ?? Self.jsonResponse(
            status: 404, #"{"error":"no stub response for \#(key)"}"#)
        stateLock.unlock()
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parseRequest(
        _ data: Data
    ) -> (method: String, path: String, headers: [String: String], body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerString = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let fullPath = parts.count > 1 ? String(parts[1]) : ""
        let path = String(fullPath.split(separator: "?", maxSplits: 1).first ?? Substring(fullPath))

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        return (method, path, headers, Data(data[bodyStart..<(bodyStart + contentLength)]))
    }

    static func jsonResponse(status: Int = 200, _ body: String) -> Data {
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 \(status) OK\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + bodyData
    }

    /// Anthropic `/v1/messages` success body: `{content:[{type:"text",text:...}]}`.
    static func anthropicResponse(_ text: String) -> Data {
        let object: [String: Any] = ["content": [["type": "text", "text": text]]]
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        return jsonResponse(String(data: bytes, encoding: .utf8)!)
    }

    /// OpenAI `/v1/chat/completions` success body.
    static func openAIResponse(_ text: String) -> Data {
        let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": text]]]]
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        return jsonResponse(String(data: bytes, encoding: .utf8)!)
    }
}

// MARK: - Shared request fixtures

private let sampleLyrics = "[verse]\nCity lights below\n[chorus]\nWe rise tonight"

private func writeRequest() -> LyricsWriteRequest {
    LyricsWriteRequest(
        prompt: "driving home at midnight",
        style: "synth-pop",
        structure: ["verse", "chorus", "bridge"],
        context: LyricsWriteContext(keyScale: "C Major", tempoBPM: 120, timeSignature: "4/4"))
}

private func refineRequest() -> LyricsWriteRequest {
    LyricsWriteRequest(
        prompt: "driving home at midnight",
        style: "synth-pop",
        context: LyricsWriteContext(tempoBPM: 128),
        existingLyrics: "[verse]\nold line one\nold line two",
        instruction: "make the chorus more hopeful")
}

/// Reads the outgoing request body as a JSON object.
private func bodyJSON(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("AnthropicClient.writeLyrics — request shape + parse against a stub")
struct AnthropicLyricsTests {
    @Test("posts /v1/messages with x-api-key + anthropic-version, default model, and a bracket/context system prompt")
    func writeRequestShape() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.anthropicResponse(sampleLyrics), forKey: "POST /v1/messages")

        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let result = try await client.writeLyrics(writeRequest())

        #expect(result.lyrics == sampleLyrics)
        #expect(result.provider == "anthropic")
        #expect(server.callCount(forKey: "POST /v1/messages") == 1)

        let headers = server.lastHeaders(forKey: "POST /v1/messages")
        #expect(headers["x-api-key"] == "sk-ant-STUBKEY")
        #expect(headers["anthropic-version"] == "2023-06-01")

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        #expect(body["model"] as? String == "claude-sonnet-5")
        let system = try #require(body["system"] as? String)
        // Teaches the bracketed ACE-Step format...
        #expect(system.contains("[verse]"))
        #expect(system.contains("[chorus]"))
        #expect(system.lowercased().contains("square bracket"))
        // ...and weaves in the provided key/tempo/time-signature context.
        #expect(system.contains("C Major"))
        #expect(system.contains("120 BPM"))
        #expect(system.contains("4/4"))

        // The structure the caller asked for rides the user turn.
        let messages = try #require(body["messages"] as? [[String: Any]])
        let user = try #require(messages.first?["content"] as? String)
        #expect(user.contains("[verse] [chorus] [bridge]"))
        #expect(user.contains("synth-pop"))
    }

    @Test("overriding the model via config sends that model id")
    func modelOverride() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.anthropicResponse(sampleLyrics), forKey: "POST /v1/messages")
        var config = server.config(anthropicKey: "sk-ant-STUBKEY")
        config.anthropicModel = "claude-opus-5"
        let client = AnthropicClient(config: config)
        _ = try await client.writeLyrics(writeRequest())
        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        #expect(body["model"] as? String == "claude-opus-5")
    }

    @Test("refine mode includes the existing lyrics + instruction and a preserve-structure system prompt")
    func refineIncludesExistingLyrics() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.anthropicResponse(sampleLyrics), forKey: "POST /v1/messages")
        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        _ = try await client.writeLyrics(refineRequest())

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        let system = try #require(body["system"] as? String)
        #expect(system.uppercased().contains("REVISING"))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let user = try #require(messages.first?["content"] as? String)
        #expect(user.contains("old line one"))
        #expect(user.contains("make the chorus more hopeful"))
    }

    @Test("an HTTP 401 maps to AIServiceError.requestFailed carrying the status")
    func httpErrorMaps() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(status: 401, #"{"error":"invalid key"}"#),
            forKey: "POST /v1/messages")
        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        await #expect(throws: AIServiceError.self) {
            _ = try await client.writeLyrics(writeRequest())
        }
    }

    @Test("a missing key throws notConfigured before any network call")
    func missingKeyThrows() async throws {
        let client = AnthropicClient(config: AIConfig(anthropicKey: nil))
        await #expect(throws: AIServiceError.self) {
            _ = try await client.writeLyrics(writeRequest())
        }
    }
}

@Suite("AnthropicClient.complete — content-block parsing hardening (thinking/tool_use/error envelopes)")
struct AnthropicCompleteParsingTests {
    @Test("a thinking block before the text block is skipped; the text block's text is returned")
    func thinkingBlockThenText() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"content":[
                    {"type":"thinking","thinking":"quietly reasoning about the request..."},
                    {"type":"text","text":"Hello there"}
                ],"stop_reason":"end_turn"}
                """#),
            forKey: "POST /v1/messages")
        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let text = try await client.complete(system: "sys", user: "hi")
        #expect(text == "Hello there")
    }

    @Test("a redacted_thinking block before the text block is skipped too")
    func redactedThinkingBlockThenText() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"content":[
                    {"type":"redacted_thinking","data":"opaque"},
                    {"type":"text","text":"Hello there"}
                ],"stop_reason":"end_turn"}
                """#),
            forKey: "POST /v1/messages")
        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let text = try await client.complete(system: "sys", user: "hi")
        #expect(text == "Hello there")
    }

    @Test("two text blocks are joined with a newline")
    func twoTextBlocksJoined() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"{"content":[{"type":"text","text":"Line one"},{"type":"text","text":"Line two"}],"stop_reason":"end_turn"}"#),
            forKey: "POST /v1/messages")
        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let text = try await client.complete(system: "sys", user: "hi")
        #expect(text == "Line one\nLine two")
    }

    @Test("an error envelope (e.g. 529 overloaded_error) throws with the API's own type/message, never 'missing content[0].text'")
    func errorEnvelopeSurfacesAPIMessage() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                status: 529,
                #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            forKey: "POST /v1/messages")
        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        do {
            _ = try await client.complete(system: "sys", user: "hi")
            Issue.record("expected complete to throw")
        } catch let error as AIServiceError {
            let message = try #require(error.errorDescription)
            #expect(message.contains("overloaded_error"))
            #expect(message.contains("Overloaded"))
            #expect(!message.contains("missing content[0].text"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("content with only tool_use/thinking blocks (no text) throws an informative error naming the block types and stop_reason")
    func onlyToolUseAndThinkingThrowsInformatively() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"content":[
                    {"type":"thinking","thinking":"..."},
                    {"type":"tool_use","id":"call_1","name":"lookup","input":{}}
                ],"stop_reason":"tool_use"}
                """#),
            forKey: "POST /v1/messages")
        let client = AnthropicClient(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        do {
            _ = try await client.complete(system: "sys", user: "hi")
            Issue.record("expected complete to throw")
        } catch let error as AIServiceError {
            guard case .malformedResponse(let detail) = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
            #expect(detail.contains("thinking"))
            #expect(detail.contains("tool_use"))
            #expect(detail.contains("stop_reason"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite("OpenAIClient — message.content parsing hardening (null/array content, refusal)")
struct OpenAICompleteParsingTests {
    @Test("content: null with a refusal surfaces the refusal text, not a generic parse error")
    func nullContentWithRefusalSurfaces() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"choices":[{"message":{"role":"assistant","content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}
                """#),
            forKey: "POST /v1/chat/completions")
        let client = OpenAIClient(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        do {
            _ = try await client.generateLyrics(theme: "midnight drive", style: nil)
            Issue.record("expected generateLyrics to throw")
        } catch let error as AIServiceError {
            let message = try #require(error.errorDescription)
            #expect(message.contains("I can't help with that."))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("message.content as an array of text parts is extracted and joined")
    func arrayContentExtracted() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"choices":[{"message":{"role":"assistant","content":[
                    {"type":"text","text":"Part one"},
                    {"type":"text","text":"Part two"}
                ]},"finish_reason":"stop"}]}
                """#),
            forKey: "POST /v1/chat/completions")
        let client = OpenAIClient(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        let text = try await client.generateLyrics(theme: "midnight drive", style: nil)
        #expect(text == "Part one\nPart two")
    }

    @Test("an error envelope on a 2xx status still surfaces the API's own message")
    func errorEnvelopeSurfacesAPIMessage() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"{"error":{"type":"invalid_request_error","message":"bad request shape"}}"#),
            forKey: "POST /v1/chat/completions")
        let client = OpenAIClient(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        do {
            _ = try await client.generateLyrics(theme: "midnight drive", style: nil)
            Issue.record("expected generateLyrics to throw")
        } catch let error as AIServiceError {
            let message = try #require(error.errorDescription)
            #expect(message.contains("invalid_request_error"))
            #expect(message.contains("bad request shape"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite("OpenAIClient.writeLyrics — request shape + parse against a stub")
struct OpenAILyricsTests {
    @Test("posts /v1/chat/completions with Bearer auth, default model, and a bracket/context system prompt")
    func writeRequestShape() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.openAIResponse(sampleLyrics), forKey: "POST /v1/chat/completions")

        let client = OpenAIClient(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        let result = try await client.writeLyrics(writeRequest())

        #expect(result.lyrics == sampleLyrics)
        #expect(result.provider == "openai")
        #expect(server.callCount(forKey: "POST /v1/chat/completions") == 1)

        let headers = server.lastHeaders(forKey: "POST /v1/chat/completions")
        #expect(headers["authorization"] == "Bearer sk-openai-STUBKEY")

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/chat/completions"))
        #expect(body["model"] as? String == "gpt-4o")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        let system = try #require(messages[0]["content"] as? String)
        #expect(system.contains("[chorus]"))
        #expect(system.lowercased().contains("square bracket"))
        #expect(system.contains("C Major"))
        #expect(system.contains("120 BPM"))
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.contains("[verse] [chorus] [bridge]"))
    }

    @Test("refine mode includes the existing lyrics + instruction")
    func refineIncludesExistingLyrics() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.openAIResponse(sampleLyrics), forKey: "POST /v1/chat/completions")
        let client = OpenAIClient(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        _ = try await client.writeLyrics(refineRequest())

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/chat/completions"))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.contains("old line one"))
        #expect(user.contains("make the chorus more hopeful"))
    }

    @Test("an HTTP 500 maps to AIServiceError.requestFailed")
    func httpErrorMaps() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(status: 500, #"{"error":"server"}"#),
            forKey: "POST /v1/chat/completions")
        let client = OpenAIClient(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        await #expect(throws: AIServiceError.self) {
            _ = try await client.writeLyrics(writeRequest())
        }
    }
}

@Suite("Lyrics provider selection — Anthropic first, OpenAI fallback, else actionable error")
struct LyricsProviderSelectionTests {
    @Test("Anthropic is preferred when both keys are present")
    func anthropicFirst() {
        let store = InMemoryKeyStore([.anthropic: "sk-ant-A", .openai: "sk-openai-B"])
        #expect(selectLyricsProvider(environment: [:], store: store) == .anthropic)
    }

    @Test("falls back to OpenAI when only OpenAI has a key")
    func openAIFallback() {
        let store = InMemoryKeyStore([.openai: "sk-openai-B"])
        #expect(selectLyricsProvider(environment: [:], store: store) == .openai)
    }

    @Test("env keys select the same way as stored keys")
    func envSelects() {
        #expect(selectLyricsProvider(environment: ["ANTHROPIC_API_KEY": "sk-ant-env"], store: nil) == .anthropic)
        #expect(selectLyricsProvider(environment: ["OPENAI_API_KEY": "sk-openai-env"], store: nil) == .openai)
    }

    @Test("nothing configured selects no provider")
    func noneSelected() {
        #expect(selectLyricsProvider(environment: [:], store: InMemoryKeyStore()) == nil)
    }

    @Test("resolveLyricsWriter returns the concrete provider client, keyed from the chain")
    func resolvesConcreteClient() throws {
        let anthropicWriter = try resolveLyricsWriter(
            environment: [:], store: InMemoryKeyStore([.anthropic: "sk-ant-A"]))
        #expect(anthropicWriter is AnthropicClient)

        let openAIWriter = try resolveLyricsWriter(
            environment: [:], store: InMemoryKeyStore([.openai: "sk-openai-B"]))
        #expect(openAIWriter is OpenAIClient)
    }

    @Test("no provider configured throws an actionable error that names Settings + ai.providerStatus and leaks no key")
    func noneThrowsActionable() {
        let store = InMemoryKeyStore()
        let env = ["ANTHROPIC_API_KEY": ""]   // present-but-empty is NOT configured
        do {
            _ = try resolveLyricsWriter(environment: env, store: store)
            Issue.record("expected resolveLyricsWriter to throw")
        } catch let error as AIServiceError {
            guard case .noProviderConfigured = error else {
                Issue.record("expected .noProviderConfigured, got \(error)")
                return
            }
            let message = try! #require(error.errorDescription)
            #expect(message.contains("Settings"))
            #expect(message.contains("⌘,"))
            #expect(message.contains("ai.providerStatus"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
