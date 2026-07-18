import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Test double for `VoiceConversionManaging` — the `FakeSidecarManager`
/// twin (`SidecarCommandTests.swift`) for the RVC voice-conversion sidecar.
/// Lets the control-protocol layer be exercised (routing, param shape,
/// response encoding, error surfacing) without touching a real process or
/// network call. Real status-mapping/path-resolution behavior is covered by
/// AIServicesTests/VoiceConversionManagerTests.
actor FakeVoiceConversionManager: VoiceConversionManaging {
    var statusToReturn = VoiceConversionStatus(state: .notInstalled, message: "not installed (fake)")
    var startResult: Result<VoiceConversionStatus, Error> = .success(
        VoiceConversionStatus(state: .healthy, message: "healthy (fake)", voiceCount: 0))
    var stopResult: Result<VoiceConversionStatus, Error> = .success(
        VoiceConversionStatus(state: .installedNotRunning, message: "stopped (fake)"))

    private(set) var statusCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func status() async -> VoiceConversionStatus {
        statusCalls += 1
        return statusToReturn
    }

    func start() async throws -> VoiceConversionStatus {
        startCalls += 1
        return try startResult.get()
    }

    func stop() async throws -> VoiceConversionStatus {
        stopCalls += 1
        return try stopResult.get()
    }
}

/// Control-protocol coverage for m10-p-3 `vc.sidecarStatus` / `vc.sidecarStart`
/// / `vc.sidecarStop` — the three routes are thin passthroughs onto
/// `VoiceConversionManaging` (a `FakeVoiceConversionManager` here), so this
/// suite proves routing/param-shape/response-encoding/error-surfacing, not
/// the real RVC facade process lifecycle (no sidecar install or network
/// needed — the suite stays green headless). Mirrors `SidecarCommandTests`
/// (the `ai.sidecar*` precedent) discipline exactly, including the
/// not-installed/not-running matrix, for the additive second sidecar.
@MainActor
@Suite("Voice-conversion sidecar — control protocol (m10-p-3)")
struct VoiceConversionCommandTests {
    private func makeRouter(voiceConversion: FakeVoiceConversionManager = FakeVoiceConversionManager())
        -> (CommandRouter, FakeVoiceConversionManager)
    {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store, voiceConversionManager: voiceConversion), voiceConversion)
    }

    @Test("all three vc.sidecar* commands are in the canonical command list")
    func commandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("vc.sidecarStatus"))
        #expect(CommandRouter.allCommands.contains("vc.sidecarStart"))
        #expect(CommandRouter.allCommands.contains("vc.sidecarStop"))
    }

    @Test("adding vc.sidecar* left every ai.sidecar* name untouched (additive guarantee)")
    func aiSidecarNamesUnchanged() {
        #expect(CommandRouter.allCommands.contains("ai.sidecarStatus"))
        #expect(CommandRouter.allCommands.contains("ai.sidecarStart"))
        #expect(CommandRouter.allCommands.contains("ai.sidecarStop"))
    }

    @Test("vc.sidecarStatus threads VoiceConversionStatus onto the wire verbatim")
    func statusThreadsWireShape() async throws {
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.setStatus(
            VoiceConversionStatus(
                state: .healthy, message: "running fine", version: "0.1.0",
                engine: "Acelogic/Retrieval-based-Voice-Conversion-MLX", baseModelPresent: true,
                voiceCount: 0, pid: 4242))
        let (router, _) = makeRouter(voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(id: "1", command: "vc.sidecarStatus"))

        #expect(response.ok, "vc.sidecarStatus failed: \(response.error ?? "?")")
        #expect(response.result?["state"]?.stringValue == "healthy")
        #expect(response.result?["message"]?.stringValue == "running fine")
        #expect(response.result?["version"]?.stringValue == "0.1.0")
        #expect(response.result?["engine"]?.stringValue == "Acelogic/Retrieval-based-Voice-Conversion-MLX")
        #expect(response.result?["baseModelPresent"]?.boolValue == true)
        #expect(response.result?["voiceCount"]?.doubleValue == 0)
        #expect(response.result?["pid"]?.doubleValue == 4242)
        #expect(await voiceConversion.statusCalls == 1)
    }

    @Test("vc.sidecarStatus reports notInstalled with an actionable message, no health fields")
    func statusNotInstalledOmitsHealthFields() async throws {
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.setStatus(
            VoiceConversionStatus(state: .notInstalled, message: "run scripts/rvc/install.sh first"))
        let (router, _) = makeRouter(voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(id: "1", command: "vc.sidecarStatus"))

        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "notInstalled")
        #expect(response.result?["message"]?.stringValue?.contains("install.sh") == true)
        #expect(response.result?["version"] == nil)
        #expect(response.result?["engine"] == nil)
        #expect(response.result?["voiceCount"] == nil)
    }

    @Test("vc.sidecarStatus reports installedNotRunning naming vc.sidecarStart")
    func statusInstalledNotRunningNamesStart() async throws {
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.setStatus(
            VoiceConversionStatus(
                state: .installedNotRunning,
                message: "RVC voice-conversion sidecar is installed but not running — call vc.sidecarStart."))
        let (router, _) = makeRouter(voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(id: "1", command: "vc.sidecarStatus"))

        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "installedNotRunning")
        #expect(response.result?["message"]?.stringValue?.contains("vc.sidecarStart") == true)
    }

    @Test("vc.sidecarStart happy path returns the healthy status")
    func startHappyPath() async throws {
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.setStartResult(.success(
            VoiceConversionStatus(state: .healthy, message: "started", version: "0.1.0", voiceCount: 0)))
        let (router, _) = makeRouter(voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(id: "1", command: "vc.sidecarStart"))

        #expect(response.ok, "vc.sidecarStart failed: \(response.error ?? "?")")
        #expect(response.result?["state"]?.stringValue == "healthy")
        #expect(await voiceConversion.startCalls == 1)
    }

    @Test("vc.sidecarStart surfaces a notInstalled failure verbatim as a control error")
    func startNotInstalledSurfacesVerbatim() async throws {
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.setStartResult(.failure(
            SidecarError.notInstalled("run scripts/rvc/install.sh first — no engine found")))
        let (router, _) = makeRouter(voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(id: "1", command: "vc.sidecarStart"))

        #expect(!response.ok)
        #expect(response.error == "run scripts/rvc/install.sh first — no engine found")
    }

    @Test("vc.sidecarStart rejects unknown params")
    func startRejectsUnknownParams() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(
            ControlRequest(id: "1", command: "vc.sidecarStart", params: ["bogus": .bool(true)]))
        #expect(!response.ok)
    }

    @Test("vc.sidecarStop happy path returns installedNotRunning")
    func stopHappyPath() async throws {
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.setStopResult(.success(
            VoiceConversionStatus(state: .installedNotRunning, message: "stopped cleanly")))
        let (router, _) = makeRouter(voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(id: "1", command: "vc.sidecarStop"))

        #expect(response.ok, "vc.sidecarStop failed: \(response.error ?? "?")")
        #expect(response.result?["state"]?.stringValue == "installedNotRunning")
        #expect(await voiceConversion.stopCalls == 1)
    }

    @Test("vc.sidecarStop surfaces a launch-family error verbatim")
    func stopErrorSurfacesVerbatim() async throws {
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.setStopResult(.failure(SidecarError.launchFailed("could not signal pid 123")))
        let (router, _) = makeRouter(voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(id: "1", command: "vc.sidecarStop"))

        #expect(!response.ok)
        #expect(response.error == "could not signal pid 123")
    }

    @Test("vc.sidecarStop rejects unknown params")
    func stopRejectsUnknownParams() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(
            ControlRequest(id: "1", command: "vc.sidecarStop", params: ["bogus": .bool(true)]))
        #expect(!response.ok)
    }

    @Test("vc.sidecarStatus takes no params and ignores any extras harmlessly")
    func statusNoParamsRequired() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(
            ControlRequest(id: "1", command: "vc.sidecarStatus", params: ["unused": .bool(true)]))
        #expect(response.ok)
    }
}

private extension FakeVoiceConversionManager {
    func setStatus(_ status: VoiceConversionStatus) { statusToReturn = status }
    func setStartResult(_ result: Result<VoiceConversionStatus, Error>) { startResult = result }
    func setStopResult(_ result: Result<VoiceConversionStatus, Error>) { stopResult = result }
}
