import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Test double for `SidecarManaging` — lets the control-protocol layer be
/// exercised (routing, param shape, response encoding, error surfacing)
/// without touching a real process or network call. Real status-mapping/
/// path-resolution behavior is covered by AIServicesTests/SidecarManagerTests.
actor FakeSidecarManager: SidecarManaging {
    var statusToReturn = SidecarStatus(state: .notInstalled, message: "not installed (fake)")
    var startResult: Result<SidecarStatus, Error> = .success(
        SidecarStatus(state: .healthy, message: "healthy (fake)"))
    var stopResult: Result<SidecarStatus, Error> = .success(
        SidecarStatus(state: .installedNotRunning, message: "stopped (fake)"))

    private(set) var statusCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func status() async -> SidecarStatus {
        statusCalls += 1
        return statusToReturn
    }

    func start() async throws -> SidecarStatus {
        startCalls += 1
        return try startResult.get()
    }

    func stop() async throws -> SidecarStatus {
        stopCalls += 1
        return try stopResult.get()
    }
}

/// Control-protocol coverage for M6 (i) `ai.sidecarStatus` / `ai.sidecarStart`
/// / `ai.sidecarStop` — the three routes are thin passthroughs onto
/// `SidecarManaging` (a `FakeSidecarManager` here), so this suite proves
/// routing/param-shape/response-encoding/error-surfacing, not the real
/// ACE-Step process lifecycle (no sidecar install or network needed — the
/// suite stays green headless).
@MainActor
@Suite("AI sidecar — control protocol (M6 i)")
struct SidecarCommandTests {
    private func makeRouter(sidecar: FakeSidecarManager = FakeSidecarManager())
        -> (CommandRouter, FakeSidecarManager)
    {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store, sidecarManager: sidecar), sidecar)
    }

    @Test("all three ai.sidecar* commands are in the canonical command list")
    func commandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("ai.sidecarStatus"))
        #expect(CommandRouter.allCommands.contains("ai.sidecarStart"))
        #expect(CommandRouter.allCommands.contains("ai.sidecarStop"))
    }

    @Test("ai.sidecarStatus threads SidecarStatus onto the wire verbatim")
    func statusThreadsWireShape() async throws {
        let sidecar = FakeSidecarManager()
        await sidecar.setStatus(
            SidecarStatus(
                state: .healthy, message: "running fine", version: "1.0",
                ditModel: "acestep-v15-xl-turbo", lmModel: "acestep-5Hz-lm-4B", pid: 4242))
        let (router, _) = makeRouter(sidecar: sidecar)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.sidecarStatus"))

        #expect(response.ok, "ai.sidecarStatus failed: \(response.error ?? "?")")
        #expect(response.result?["state"]?.stringValue == "healthy")
        #expect(response.result?["message"]?.stringValue == "running fine")
        #expect(response.result?["version"]?.stringValue == "1.0")
        #expect(response.result?["ditModel"]?.stringValue == "acestep-v15-xl-turbo")
        #expect(response.result?["lmModel"]?.stringValue == "acestep-5Hz-lm-4B")
        #expect(response.result?["pid"]?.doubleValue == 4242)
        #expect(await sidecar.statusCalls == 1)
    }

    @Test("ai.sidecarStatus reports notInstalled with an actionable message, no version fields")
    func statusNotInstalledOmitsHealthFields() async throws {
        let sidecar = FakeSidecarManager()
        await sidecar.setStatus(
            SidecarStatus(state: .notInstalled, message: "run scripts/ace-step/install.sh first"))
        let (router, _) = makeRouter(sidecar: sidecar)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.sidecarStatus"))

        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "notInstalled")
        #expect(response.result?["message"]?.stringValue?.contains("install.sh") == true)
        #expect(response.result?["version"] == nil)
        #expect(response.result?["ditModel"] == nil)
    }

    @Test("ai.sidecarStart happy path returns the healthy status")
    func startHappyPath() async throws {
        let sidecar = FakeSidecarManager()
        await sidecar.setStartResult(.success(
            SidecarStatus(state: .healthy, message: "started", version: "1.0")))
        let (router, _) = makeRouter(sidecar: sidecar)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.sidecarStart"))

        #expect(response.ok, "ai.sidecarStart failed: \(response.error ?? "?")")
        #expect(response.result?["state"]?.stringValue == "healthy")
        #expect(await sidecar.startCalls == 1)
    }

    @Test("ai.sidecarStart surfaces a notInstalled failure verbatim as a control error")
    func startNotInstalledSurfacesVerbatim() async throws {
        let sidecar = FakeSidecarManager()
        await sidecar.setStartResult(.failure(
            SidecarError.notInstalled("run scripts/ace-step/install.sh first — no weights found")))
        let (router, _) = makeRouter(sidecar: sidecar)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.sidecarStart"))

        #expect(!response.ok)
        #expect(response.error == "run scripts/ace-step/install.sh first — no weights found")
    }

    @Test("ai.sidecarStop happy path returns installedNotRunning")
    func stopHappyPath() async throws {
        let sidecar = FakeSidecarManager()
        await sidecar.setStopResult(.success(
            SidecarStatus(state: .installedNotRunning, message: "stopped cleanly")))
        let (router, _) = makeRouter(sidecar: sidecar)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.sidecarStop"))

        #expect(response.ok, "ai.sidecarStop failed: \(response.error ?? "?")")
        #expect(response.result?["state"]?.stringValue == "installedNotRunning")
        #expect(await sidecar.stopCalls == 1)
    }

    @Test("ai.sidecarStop surfaces a launch-family error verbatim")
    func stopErrorSurfacesVerbatim() async throws {
        let sidecar = FakeSidecarManager()
        await sidecar.setStopResult(.failure(SidecarError.launchFailed("could not signal pid 123")))
        let (router, _) = makeRouter(sidecar: sidecar)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.sidecarStop"))

        #expect(!response.ok)
        #expect(response.error == "could not signal pid 123")
    }

    @Test("commands take no params and ignore any extras harmlessly")
    func noParamsRequired() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(
            ControlRequest(id: "1", command: "ai.sidecarStatus", params: ["unused": .bool(true)]))
        #expect(response.ok)
    }
}

private extension FakeSidecarManager {
    func setStatus(_ status: SidecarStatus) { statusToReturn = status }
    func setStartResult(_ result: Result<SidecarStatus, Error>) { startResult = result }
    func setStopResult(_ result: Result<SidecarStatus, Error>) { stopResult = result }
}
