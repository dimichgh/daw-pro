import Foundation
import Testing
import AIServices
@testable import DAWAppKit

/// Headless tests for the M6 Lyrics Workshop state machine: write/refine
/// lifecycle, the busy gate, error surfacing (including the no-provider case),
/// structure-chip editing, apply-into-Sketchpad, and project-context threading.
/// Drives `LyricsWorkshopModel` against a scripted fake `LyricsGenerating` — no
/// window, no engine, no network (the `SketchpadModelTests` precedent).
@MainActor
@Suite struct LyricsWorkshopModelTests {

    // MARK: - Fakes

    /// A scriptable `LyricsGenerating`: `writeLyrics` records the request it was
    /// handed and returns the next scripted outcome (or throws). An actor so it's
    /// `Sendable` across the model's awaits. It records EVERY request so the
    /// context/refine-threading assertions can read them back.
    actor FakeWriter: LyricsGenerating {
        struct StubError: Error, LocalizedError { var errorDescription: String? }

        private var outcomes: [Result<LyricsWriteResult, Error>] = []
        private(set) var requests: [LyricsWriteRequest] = []

        func script(_ outcomes: [Result<LyricsWriteResult, Error>]) { self.outcomes = outcomes }
        func lastRequest() -> LyricsWriteRequest? { requests.last }
        func requestCount() -> Int { requests.count }

        func generateLyrics(theme: String, style: String?) async throws -> String {
            "unused legacy path"
        }

        func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
            requests.append(request)
            guard !outcomes.isEmpty else {
                return LyricsWriteResult(lyrics: "[verse]\ndefault", provider: "anthropic")
            }
            return try outcomes.removeFirst().get()
        }
    }

    private func makeModel(
        writer: FakeWriter = FakeWriter(),
        makeWriter: (@MainActor () throws -> any LyricsGenerating)? = nil,
        context: LyricsWriteContext = LyricsWriteContext(),
        onApply: @escaping @MainActor (String) -> Void = { _ in }
    ) -> LyricsWorkshopModel {
        LyricsWorkshopModel(
            makeWriter: makeWriter ?? { writer },
            contextProvider: { context },
            applier: onApply)
    }

    private func result(_ lyrics: String, _ provider: String = "anthropic") -> LyricsWriteResult {
        LyricsWriteResult(lyrics: lyrics, provider: provider)
    }

    // MARK: - Write

    @Test func writeFillsDraftAndProvider() async {
        let writer = FakeWriter()
        await writer.script([.success(result("[verse]\nCity lights", "anthropic"))])
        let model = makeModel(writer: writer)
        model.theme = "driving home at midnight"
        await model.write()
        #expect(model.state == .idle)
        #expect(model.draft == "[verse]\nCity lights")
        #expect(model.lastProvider == "anthropic")
    }

    @Test func writeIsBlockedByABlankTheme() async {
        let writer = FakeWriter()
        let model = makeModel(writer: writer)
        model.theme = "   "
        #expect(!model.canWrite)
        await model.write()
        #expect(await writer.requestCount() == 0)
        #expect(model.draft.isEmpty)
    }

    @Test func writeThreadsThemeStyleStructureAndContext() async {
        let writer = FakeWriter()
        await writer.script([.success(result("[verse]\nx"))])
        let context = LyricsWriteContext(keyScale: "A Minor", tempoBPM: 128, timeSignature: "3/4", genre: "dream pop")
        let model = makeModel(writer: writer, context: context)
        model.theme = "letting go"
        model.style = "dream pop ballad"
        model.setStructureForCapture(["verse", "chorus", "outro"])
        await model.write()

        let request = await writer.lastRequest()
        #expect(request?.prompt == "letting go")
        #expect(request?.style == "dream pop ballad")
        #expect(request?.structure == ["verse", "chorus", "outro"])
        #expect(request?.context == context)
        #expect(request?.isRefine == false)
        #expect(request?.existingLyrics == nil)
    }

    @Test func writeReadsContextFreshEachCall() async {
        // A mutable box the context closure reads — proves the model pulls context
        // at write time, not at init (a tempo change between writes must land).
        final class Box: @unchecked Sendable { var tempo: Double = 100 }
        let box = Box()
        let writer = FakeWriter()
        await writer.script([.success(result("a")), .success(result("b"))])
        let model = LyricsWorkshopModel(
            makeWriter: { writer },
            contextProvider: { LyricsWriteContext(tempoBPM: box.tempo) },
            applier: { _ in })
        model.theme = "t"
        await model.write()
        box.tempo = 140
        model.theme = "t2"
        await model.write()
        #expect(await writer.lastRequest()?.context.tempoBPM == 140)
    }

    // MARK: - Refine

    @Test func refineSendsExistingLyricsAndInstruction() async {
        let writer = FakeWriter()
        await writer.script([
            .success(result("[verse]\nfirst draft")),
            .success(result("[verse]\nrevised", "openai")),
        ])
        let model = makeModel(writer: writer)
        model.theme = "the sea"
        await model.write()
        #expect(model.draft == "[verse]\nfirst draft")

        model.refineInstruction = "make it wistful"
        #expect(model.canRefine)
        await model.refine()

        let request = await writer.lastRequest()
        #expect(request?.isRefine == true)
        #expect(request?.existingLyrics == "[verse]\nfirst draft")
        #expect(request?.instruction == "make it wistful")
        #expect(model.draft == "[verse]\nrevised")
        #expect(model.lastProvider == "openai")
    }

    @Test func refineIsBlockedWithoutADraftOrInstruction() async {
        let writer = FakeWriter()
        let model = makeModel(writer: writer)
        // No draft yet.
        model.refineInstruction = "do something"
        #expect(!model.canRefine)
        await model.refine()
        #expect(await writer.requestCount() == 0)
    }

    // MARK: - Failure

    @Test func writeFailureSurfacesTheMessage() async {
        let writer = FakeWriter()
        await writer.script([.failure(FakeWriter.StubError(errorDescription: "provider request failed (HTTP 401)"))])
        let model = makeModel(writer: writer)
        model.theme = "anything"
        await model.write()
        #expect(model.state == .failed("provider request failed (HTTP 401)"))
        #expect(model.draft.isEmpty)
    }

    @Test func noProviderConfiguredFailsWithTheActionableMessage() async {
        // makeWriter throws (the no-key case) — surfaces as .failed, not a crash.
        let model = makeModel(makeWriter: {
            throw AIServiceError.noProviderConfigured(capability: "lyrics")
        })
        model.theme = "anything"
        await model.write()
        guard case .failed(let message) = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        #expect(message.contains("Settings"))
        #expect(message.contains("ai.providerStatus"))
    }

    @Test func aFailedDraftCanBeRetriedIntoSuccess() async {
        let writer = FakeWriter()
        await writer.script([
            .failure(FakeWriter.StubError(errorDescription: "blip")),
            .success(result("[verse]\nrecovered")),
        ])
        let model = makeModel(writer: writer)
        model.theme = "retry me"
        await model.write()
        #expect(model.state == .failed("blip"))
        await model.write()
        #expect(model.state == .idle)
        #expect(model.draft == "[verse]\nrecovered")
    }

    // MARK: - Apply

    @Test func applyHandsTheDraftToTheSketchpad() async {
        final class Sink: @unchecked Sendable { var received: String? }
        let sink = Sink()
        let writer = FakeWriter()
        await writer.script([.success(result("[verse]\nlanded"))])
        let model = makeModel(writer: writer, onApply: { sink.received = $0 })
        model.theme = "landing"
        #expect(!model.canApply)
        await model.write()
        #expect(model.canApply)
        model.apply()
        #expect(sink.received == "[verse]\nlanded")
    }

    @Test func applyIsANoOpWithoutADraft() {
        final class Sink: @unchecked Sendable { var received: String? }
        let sink = Sink()
        let model = makeModel(onApply: { sink.received = $0 })
        model.apply()
        #expect(sink.received == nil)
    }

    // MARK: - Structure chips

    @Test func structureAddRemoveMove() {
        let model = makeModel()
        model.setStructureForCapture(["verse", "chorus"])
        model.addSection("bridge")
        #expect(model.structure == ["verse", "chorus", "bridge"])
        model.addSection("   ")   // blank ignored
        #expect(model.structure == ["verse", "chorus", "bridge"])
        model.removeSection(at: 1)
        #expect(model.structure == ["verse", "bridge"])
        model.removeSection(at: 9)   // out of bounds ignored
        #expect(model.structure == ["verse", "bridge"])
        model.moveSection(from: 0, to: 1)
        #expect(model.structure == ["bridge", "verse"])
        model.resetStructure()
        #expect(model.structure == LyricsWriteRequest.defaultStructure)
    }

    // MARK: - Busy gate

    @Test func busyBlocksConcurrentWrites() async {
        // A writer that parks on a continuation until released — lets the test
        // observe the .writing state and confirm a second write is refused.
        actor GateWriter: LyricsGenerating {
            private var continuation: CheckedContinuation<Void, Never>?
            private(set) var calls = 0
            func generateLyrics(theme: String, style: String?) async throws -> String { "" }
            func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
                calls += 1
                await withCheckedContinuation { self.continuation = $0 }
                return LyricsWriteResult(lyrics: "[verse]\ndone", provider: "anthropic")
            }
            func release() { continuation?.resume(); continuation = nil }
            func callCount() -> Int { calls }
        }
        let gate = GateWriter()
        let model = makeModel(makeWriter: { gate })
        model.theme = "parked"

        async let first: Void = model.write()
        // Spin until the model reports .writing (the parked call has started).
        while model.state != .writing { await Task.yield() }
        #expect(model.isBusy)
        #expect(!model.canWrite)

        // A second write while busy is refused (no extra provider call).
        await model.write()
        #expect(await gate.callCount() == 1)

        await gate.release()
        await first
        #expect(model.state == .idle)
        #expect(model.draft == "[verse]\ndone")
    }
}
