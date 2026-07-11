import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for M6 `ai.writeLyrics`. Drives the router against a
/// fake `LyricsGenerating` writer (injected via `CommandRouter(lyricsWriter:)`)
/// so routing, field-named validation, project-context defaulting, refine
/// threading, response shape, and the no-provider error path are all exercised
/// without a real cloud call. Provider/request-shape wire behavior itself is
/// covered by AIServicesTests/LyricsWriterTests.
@MainActor
@Suite("AI lyrics writing — control protocol (M6)")
struct WriteLyricsCommandTests {
    /// Records the request it was handed and returns a scripted result (or throws).
    actor FakeLyricsWriter: LyricsGenerating {
        struct StubError: Error, LocalizedError { var errorDescription: String? }
        var result: Result<LyricsWriteResult, Error> = .success(
            LyricsWriteResult(lyrics: "[verse]\nstub", provider: "anthropic"))
        private(set) var lastRequest: LyricsWriteRequest?

        func generateLyrics(theme: String, style: String?) async throws -> String { "legacy" }
        func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
            lastRequest = request
            return try result.get()
        }
        func setResult(_ result: Result<LyricsWriteResult, Error>) { self.result = result }
    }

    /// Router wired to `writer`, with the store's tempo/time-signature preset so
    /// the context-defaulting assertions have distinctive values to read.
    private func makeRouter(
        writer: FakeLyricsWriter = FakeLyricsWriter(),
        provider: (@MainActor () throws -> any LyricsGenerating)? = nil,
        tempo: Double = 96
    ) -> CommandRouter {
        let store = ProjectStore()
        try? store.setTempo(tempo)
        return CommandRouter(store: store, lyricsWriter: provider ?? { writer })
    }

    @Test("ai.writeLyrics is on the canonical command list")
    func isCanonical() {
        #expect(CommandRouter.allCommands.contains("ai.writeLyrics"))
    }

    @Test("requires 'prompt'")
    func requiresPrompt() async {
        let response = await makeRouter().handle(ControlRequest(id: "1", command: "ai.writeLyrics"))
        #expect(!response.ok)
        #expect(response.error?.contains("prompt") == true)
    }

    @Test("happy path forwards fields and returns {lyrics, provider}")
    func happyPath() async throws {
        let writer = FakeLyricsWriter()
        await writer.setResult(.success(LyricsWriteResult(lyrics: "[verse]\nCity lights", provider: "anthropic")))
        let router = makeRouter(writer: writer)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.writeLyrics",
            params: [
                "prompt": .string("driving home"),
                "style": .string("synth-pop"),
                "structure": .array([.string("verse"), .string("chorus"), .string("outro")]),
            ]))
        #expect(response.ok, "failed: \(response.error ?? "?")")
        #expect(response.result?["lyrics"]?.stringValue == "[verse]\nCity lights")
        #expect(response.result?["provider"]?.stringValue == "anthropic")

        let request = try #require(await writer.lastRequest)
        #expect(request.prompt == "driving home")
        #expect(request.style == "synth-pop")
        #expect(request.structure == ["verse", "chorus", "outro"])
        #expect(request.isRefine == false)
    }

    @Test("context defaults from the current project's tempo/time-signature when omitted")
    func contextDefaultsFromProject() async throws {
        let writer = FakeLyricsWriter()
        let router = makeRouter(writer: writer, tempo: 96)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.writeLyrics", params: ["prompt": .string("theme only")]))
        #expect(response.ok, "failed: \(response.error ?? "?")")

        let request = try #require(await writer.lastRequest)
        #expect(request.context.tempoBPM == 96)          // adopted from the project
        #expect(request.context.timeSignature == "4/4")  // default transport meter
        // Default structure applied when the caller omits one.
        #expect(request.structure == LyricsWriteRequest.defaultStructure)
    }

    @Test("an explicit context field wins over the project default")
    func explicitContextWins() async throws {
        let writer = FakeLyricsWriter()
        let router = makeRouter(writer: writer, tempo: 96)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.writeLyrics",
            params: [
                "prompt": .string("t"),
                "context": .object([
                    "keyScale": .string("A Minor"),
                    "tempoBPM": .number(140),
                    "genre": .string("dream pop"),
                ]),
            ]))
        #expect(response.ok, "failed: \(response.error ?? "?")")

        let request = try #require(await writer.lastRequest)
        #expect(request.context.keyScale == "A Minor")
        #expect(request.context.tempoBPM == 140)         // explicit wins
        #expect(request.context.genre == "dream pop")
        #expect(request.context.timeSignature == "4/4")  // still filled from project
    }

    @Test("refine mode threads existingLyrics + instruction")
    func refineMode() async throws {
        let writer = FakeLyricsWriter()
        await writer.setResult(.success(LyricsWriteResult(lyrics: "[verse]\nrevised", provider: "openai")))
        let router = makeRouter(writer: writer)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.writeLyrics",
            params: [
                "prompt": .string("the sea"),
                "existingLyrics": .string("[verse]\nold line"),
                "instruction": .string("make it wistful"),
            ]))
        #expect(response.ok, "failed: \(response.error ?? "?")")
        #expect(response.result?["provider"]?.stringValue == "openai")

        let request = try #require(await writer.lastRequest)
        #expect(request.isRefine == true)
        #expect(request.existingLyrics == "[verse]\nold line")
        #expect(request.instruction == "make it wistful")
    }

    @Test("a non-array structure is a field-named error")
    func structureTypeValidation() async {
        let response = await makeRouter().handle(ControlRequest(
            id: "1", command: "ai.writeLyrics",
            params: ["prompt": .string("t"), "structure": .string("verse")]))
        #expect(!response.ok)
        #expect(response.error?.contains("structure") == true)
    }

    @Test("an empty structure array is rejected")
    func emptyStructureRejected() async {
        let response = await makeRouter().handle(ControlRequest(
            id: "1", command: "ai.writeLyrics",
            params: ["prompt": .string("t"), "structure": .array([])]))
        #expect(!response.ok)
        #expect(response.error?.contains("structure") == true)
    }

    @Test("a non-numeric context.tempoBPM is a field-named error")
    func contextTypeValidation() async {
        let response = await makeRouter().handle(ControlRequest(
            id: "1", command: "ai.writeLyrics",
            params: [
                "prompt": .string("t"),
                "context": .object(["tempoBPM": .string("fast")]),
            ]))
        #expect(!response.ok)
        #expect(response.error?.contains("tempoBPM") == true)
    }

    @Test("no configured provider surfaces the actionable no-key error over the wire")
    func noProviderActionable() async {
        let router = makeRouter(provider: {
            throw AIServiceError.noProviderConfigured(capability: "lyrics")
        })
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.writeLyrics", params: ["prompt": .string("t")]))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("Settings"))
        #expect(error.contains("⌘,"))
        #expect(error.contains("ai.providerStatus"))
    }
}
