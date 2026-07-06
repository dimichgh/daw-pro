import Foundation
import Network
import Testing
@testable import AIServices

/// Minimal in-process HTTP responder for exercising `SidecarManager`'s health
/// probe without a real ACE-Step process: accepts a TCP connection, ignores
/// the request entirely (our probe only ever does `GET /health`), and writes
/// back one canned HTTP response. Bound to `127.0.0.1:0` (ephemeral port) so
/// parallel test runs never collide.
final class StubHealthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stub-health-server")
    private var listener: NWListener?
    private let responseData: Data
    private(set) var port: UInt16 = 0

    /// `HTTP/1.1 200 OK` wrapping `json` in ACE-Step's own `/health` envelope
    /// shape (`{"data": {...}}` — verified against
    /// `acestep/api/http/model_service_routes.py`).
    static func healthyResponse(
        version: String = "1.0", ditModel: String = "acestep-v15-xl-turbo",
        lmModel: String = "acestep-5Hz-lm-4B"
    ) -> Data {
        httpResponse(
            body: """
            {"data":{"status":"ok","service":"ACE-Step API","version":"\(version)", \
            "models_initialized":true,"llm_initialized":true,"loaded_model":"\(ditModel)", \
            "loaded_lm_model":"\(lmModel)"},"code":200,"error":null}
            """)
    }

    /// Valid JSON, but missing the `data` envelope our probe requires —
    /// exercises the "malformed" branch distinctly from "unreachable".
    static func malformedResponse() -> Data {
        httpResponse(body: #"{"unexpected":"shape"}"#)
    }

    private static func httpResponse(status: Int = 200, body: String) -> Data {
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 \(status) OK\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + bodyData
    }

    init(responseData: Data) {
        self.responseData = responseData
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.respond(on: connection)
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
            throw AIServiceError.malformedResponse("stub health server failed to start")
        }
        self.listener = listener
    }

    private func respond(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, _ in
            guard let self else { return }
            connection.send(
                content: self.responseData,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Allocates a loopback port, then frees it immediately — nothing is
    /// listening afterward, so a probe against it deterministically sees
    /// "connection refused" (used for the unreachable/notInstalled/
    /// installedNotRunning test cases).
    static func unusedLoopbackPort() throws -> UInt16 {
        let server = StubHealthServer(responseData: Data())
        try server.start()
        let port = server.port
        server.stop()
        return port
    }
}

@Suite("SidecarManager — status mapping (M6 i)")
struct SidecarManagerStatusTests {
    private func baseURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    @Test("200 + well-formed JSON -> healthy, with version/model info")
    func healthyMapsToHealthy() async throws {
        let server = StubHealthServer(responseData: StubHealthServer.healthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = SidecarManager(configuration: .init(
            baseURL: baseURL(port: server.port), acestepDir: nil))
        let status = await manager.status()

        #expect(status.state == .healthy)
        #expect(status.version == "1.0")
        #expect(status.ditModel == "acestep-v15-xl-turbo")
        #expect(status.lmModel == "acestep-5Hz-lm-4B")
        #expect(!status.message.isEmpty)
    }

    @Test("200 + malformed JSON (no data envelope) -> error")
    func malformedMapsToError() async throws {
        let server = StubHealthServer(responseData: StubHealthServer.malformedResponse())
        try server.start()
        defer { server.stop() }

        let manager = SidecarManager(configuration: .init(
            baseURL: baseURL(port: server.port), acestepDir: nil))
        let status = await manager.status()

        #expect(status.state == .error)
        #expect(status.version == nil)
        #expect(!status.message.isEmpty)
    }

    @Test("connection refused, no install marker -> notInstalled")
    func connectionRefusedWithoutMarkerMapsToNotInstalled() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = SidecarManager(configuration: .init(
            baseURL: baseURL(port: port), acestepDir: tempDir))
        let status = await manager.status()

        #expect(status.state == .notInstalled)
        #expect(status.message.localizedCaseInsensitiveContains("install.sh"))
    }

    @Test("connection refused, install marker present -> installedNotRunning")
    func connectionRefusedWithMarkerMapsToInstalledNotRunning() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Data("{}".utf8).write(to: tempDir.appendingPathComponent(".install-state.json"))

        let manager = SidecarManager(configuration: .init(
            baseURL: baseURL(port: port), acestepDir: tempDir))
        let status = await manager.status()

        #expect(status.state == .installedNotRunning)
        #expect(status.message.localizedCaseInsensitiveContains("ai.sidecarStart"))
    }

    @Test("unresolvable directory (no env override) -> notInstalled, never crashes")
    func unresolvableDirectoryMapsToNotInstalled() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        let manager = SidecarManager(configuration: .init(
            baseURL: baseURL(port: port), acestepDir: nil))
        let status = await manager.status()
        #expect(status.state == .notInstalled)
    }
}

@Suite("SidecarManager — start() path resolution (dry-run, headless)")
struct SidecarManagerStartTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("no run.sh -> start() throws notInstalled verbatim, points at install.sh")
    func missingRunScriptThrowsNotInstalled() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, acestepDir: dir, dryRun: true))

        do {
            _ = try await manager.start()
            Issue.record("expected start() to throw")
        } catch let error as SidecarError {
            #expect(error.errorDescription?.localizedCaseInsensitiveContains("install.sh") == true)
        }
    }

    @Test("no acestepDir resolvable -> start() throws notInstalled verbatim")
    func missingDirectoryThrowsNotInstalled() async throws {
        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, acestepDir: nil, dryRun: true))
        do {
            _ = try await manager.start()
            Issue.record("expected start() to throw")
        } catch let error as SidecarError {
            #expect(error.errorDescription?.localizedCaseInsensitiveContains("DAWPRO_ACESTEP_DIR") == true)
        }
    }

    @Test("run.sh present + dry-run -> returns the exact command it would spawn, never launches a process")
    func dryRunReturnsResolvedCommand() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runScript = dir.appendingPathComponent("run.sh")
        try Data("#!/bin/bash\necho stub\n".utf8).write(to: runScript)

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, acestepDir: dir, dryRun: true))
        let status = try await manager.start()

        #expect(status.state == .starting)
        #expect(status.message.contains("run.sh"))
        #expect(status.message.contains(dir.path))
        #expect(status.message.contains("[dry-run]"))
        // No pidfile should ever be written in dry-run mode.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ace-step.pid").path))
    }

    @Test("resolveAcestepDir() without an override walks up to this repo's Package.swift")
    func resolveLaunchPlanFindsRepoScriptsDir() throws {
        // No DAWPRO_ACESTEP_DIR in this synthetic environment: the walk-up
        // heuristic tries the process's current directory first — SwiftPM
        // always runs `swift run`/`swift test` with cwd = the package root
        // — so it should find `scripts/ace-step` from there regardless of
        // which helper binary actually owns argv[0] under the test runner.
        let resolved = SidecarManager.Configuration.resolveAcestepDir(environment: [:])
        #expect(resolved?.lastPathComponent == "ace-step")
        #expect(resolved?.deletingLastPathComponent().lastPathComponent == "scripts")
    }

    @Test("DAWPRO_ACESTEP_DIR env override wins over the repo walk-up")
    func envOverrideWins() throws {
        let resolved = SidecarManager.Configuration.resolveAcestepDir(
            environment: ["DAWPRO_ACESTEP_DIR": "/tmp/some-stub-dir"])
        #expect(resolved?.path == "/tmp/some-stub-dir")
    }
}

@Suite("SidecarManager — stop()")
struct SidecarManagerStopTests {
    @Test("no pidfile -> installedNotRunning, no-op success (not an error)")
    func noPidfileIsNoopSuccess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".install-state.json"))

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, acestepDir: dir))
        let status = try await manager.stop()

        #expect(status.state == .installedNotRunning)
    }

    @Test("stale pidfile (dead pid) -> installedNotRunning, pidfile removed")
    func stalePidfileIsCleanedUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidfile = dir.appendingPathComponent(".ace-step.pid")
        // Pid 99999 is exceedingly unlikely to be a live process in a test
        // sandbox; if this ever flakes, replace with a spawned-then-reaped
        // child pid.
        try Data("99999".utf8).write(to: pidfile)

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, acestepDir: dir))
        let status = try await manager.stop()

        #expect(status.state == .installedNotRunning)
        #expect(!FileManager.default.fileExists(atPath: pidfile.path))
    }

    @Test("dry-run stop with a pidfile present reports the pid, never signals it")
    func dryRunStopNeverSignals() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("99999".utf8).write(to: dir.appendingPathComponent(".ace-step.pid"))

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, acestepDir: dir, dryRun: true))
        let status = try await manager.stop()

        #expect(status.pid == 99999)
        #expect(status.message.contains("[dry-run]"))
        // dry-run must not remove the pidfile either (nothing was actually stopped).
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ace-step.pid").path))
    }
}
