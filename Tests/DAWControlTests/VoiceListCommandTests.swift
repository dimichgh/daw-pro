import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for m10-p-5 `vc.listVoices` — the one wire
/// addition the Voice panel item carries (the panel made voice-listing
/// user-facing, so the CLAUDE.md convention requires a command + MCP tool +
/// test). A thin passthrough onto `VoiceConverting.listVoices()` (a
/// `FakeVoiceConverting` here — declared in
/// `VoiceConversionConvertCommandTests.swift`), so this suite proves routing,
/// the no-params shape, VERBATIM descriptor encoding, and error surfacing —
/// no sidecar install or network needed. Real HTTP behavior lives in
/// AIServicesTests/VoiceConversionClientTests (stub facade).
@MainActor
@Suite("Voice list — control protocol (m10-p-5)")
struct VoiceListCommandTests {
    private func makeRouter(
        voiceConverting: FakeVoiceConverting = FakeVoiceConverting(),
        voiceConversion: FakeVoiceConversionManager = FakeVoiceConversionManager()
    ) -> (CommandRouter, FakeVoiceConverting) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let router = CommandRouter(
            store: store,
            voiceConversionManager: voiceConversion,
            voiceConverting: voiceConverting)
        return (router, voiceConverting)
    }

    @Test("vc.listVoices is in the canonical command list; count moved 132 -> 133")
    func commandIsCanonical() {
        #expect(CommandRouter.allCommands.contains("vc.listVoices"))
        #expect(CommandRouter.allCommands.count == 133)
    }

    @Test("adding vc.listVoices left every existing vc.*/ai.sidecar* name untouched")
    func siblingNamesUnchanged() {
        for name in ["vc.sidecarStatus", "vc.sidecarStart", "vc.sidecarStop",
                     "vc.convertVocals", "vc.trainVoice",
                     "ai.sidecarStatus", "ai.sidecarStart", "ai.sidecarStop"] {
            #expect(CommandRouter.allCommands.contains(name), "\(name) missing")
        }
    }

    @Test("composes base (from its own status endpoint) FIRST + the real list, descriptors verbatim")
    func returnsDescriptorsVerbatim() async throws {
        let converting = FakeVoiceConverting()
        // The facade's REAL split (m10-p-2 design): /v1/voice/list is
        // real-user-voices-only; "base" comes from /v1/voice/base/status.
        await converting.setVoiceStatusResult(.success(
            VoiceDescriptor(id: "base", name: "Base (untrained)", state: "ready",
                            kind: "builtin", trained: false,
                            note: "pipeline smoke target — not a real voice")))
        await converting.setListVoicesResult(.success([
            VoiceDescriptor(id: "my-voice", name: "My Voice", state: "ready",
                            hasIndex: true, createdAt: "2026-07-19T00:00:00Z"),
        ]))
        let (router, fake) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(response.ok, "vc.listVoices failed: \(response.error ?? "?")")
        let voices = try #require(response.result?["voices"]?.arrayValue)
        #expect(voices.count == 2)
        // The reserved "base" smoke target FIRST, verbatim (its distinct fields).
        #expect(voices[0]["id"]?.stringValue == "base")
        #expect(voices[0]["name"]?.stringValue == "Base (untrained)")
        #expect(voices[0]["state"]?.stringValue == "ready")
        #expect(voices[0]["kind"]?.stringValue == "builtin")
        #expect(voices[0]["trained"]?.boolValue == false)
        #expect(voices[0]["note"]?.stringValue == "pipeline smoke target — not a real voice")
        // A real voice's distinct fields, verbatim; absent optionals are
        // OMITTED (Codable nil-skip), never fabricated.
        #expect(voices[1]["id"]?.stringValue == "my-voice")
        #expect(voices[1]["hasIndex"]?.boolValue == true)
        #expect(voices[1]["createdAt"]?.stringValue == "2026-07-19T00:00:00Z")
        #expect(voices[1]["kind"] == nil)
        #expect(voices[1]["note"] == nil)
        #expect(voices[0]["hasIndex"] == nil)
        // Exactly one call to each endpoint, base's from ITS status route.
        let listCalls = await fake.listVoicesCalls
        let statusCalls = await fake.voiceStatusCalls
        #expect(listCalls == 1)
        #expect(statusCalls == ["base"])
    }

    @Test("no params: an unknown key is rejected with the teaching error, client never called")
    func rejectsUnknownParams() async throws {
        let (router, fake) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: ["bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("bogus") == true, "the unknown key is named verbatim")
        let calls = await fake.listVoicesCalls
        #expect(calls == 0, "a rejected request must never reach the client")
    }

    @Test("unreachable sidecar surfaces the manager's actionable message, never a bare connection error")
    func unreachableSurfacesManagerMessage() async throws {
        let converting = FakeVoiceConverting()
        await converting.setVoiceStatusResult(.failure(
            VoiceConversionError.sidecarUnreachable("Could not connect to the server.")))
        await converting.setListVoicesResult(.failure(
            VoiceConversionError.sidecarUnreachable("Could not connect to the server.")))
        let manager = FakeVoiceConversionManager()
        await manager.setStatusForList(VoiceConversionStatus(
            state: .installedNotRunning,
            message: "RVC voice-conversion sidecar is installed but not running — call vc.sidecarStart."))
        let (router, _) = makeRouter(voiceConverting: converting, voiceConversion: manager)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(!response.ok)
        #expect(response.error == "RVC voice-conversion sidecar is installed but not running — call vc.sidecarStart.")
    }

    @Test("a facade teaching error (non-connection) passes through verbatim")
    func facadeErrorPassesThroughVerbatim() async throws {
        let converting = FakeVoiceConverting()
        await converting.setListVoicesResult(.failure(VoiceConversionError.requestFailed(
            status: 500, code: "voiceStoreUnreadable", message: "voice store directory is unreadable")))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(!response.ok)
        #expect(response.error?.contains("voiceStoreUnreadable") == true)
        #expect(response.error?.contains("voice store directory is unreadable") == true)
    }

    @Test("the at-rest truth (no trained voices yet) is exactly the base smoke target, not an empty lie")
    func atRestListIsJustBase() async throws {
        // The fakes' defaults ARE the facade's at-rest shapes: an empty real
        // list + the base status descriptor.
        let (router, _) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(response.ok)
        let voices = try #require(response.result?["voices"]?.arrayValue)
        #expect(voices.count == 1)
        #expect(voices[0]["id"]?.stringValue == "base")
        #expect(voices[0]["kind"]?.stringValue == "builtin")
    }
}

/// File-scoped setters (the `stubStatus` precedent in
/// `VoiceConversionConvertCommandTests.swift` — that file's helpers are
/// `private`, so this file carries its own thin same-module wrappers).
private extension FakeVoiceConverting {
    func setListVoicesResult(_ result: Result<[VoiceDescriptor], Error>) { listVoicesResult = result }
    func setVoiceStatusResult(_ result: Result<VoiceDescriptor, Error>) { voiceStatusResult = result }
}

private extension FakeVoiceConversionManager {
    func setStatusForList(_ status: VoiceConversionStatus) { statusToReturn = status }
}
