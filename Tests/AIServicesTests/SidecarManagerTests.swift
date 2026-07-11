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

// MARK: - M10-b: honest `.starting` (the beta "loaded-but-not-started" bug)

/// Real excerpts lifted verbatim from `~/Library/Logs/DAWPro/ace-step.log`
/// (the 2026-07-06 08:07 cold-boot and 2026-07-10 01:26 warm-boot sessions),
/// never invented — see `SidecarStartPhase`'s own doc comment.
private enum SampleLogExcerpts {
    static let preparingEnvironment = """
        W0706 08:07:38.376000 83985 torch/distributed/elastic/multiprocessing/redirects.py:29] \
        NOTE: Redirects are currently not supported in Windows or MacOs.
        2026-07-06 08:07:49.862 | WARNING  | acestep.training.trainer:<module>:40 - bitsandbytes \
        not installed. Using standard AdamW.
        [API Server] Using LM model: acestep-5Hz-lm-4B
        INFO:     Started server process [83985]
        """

    static let startingServer = """
        \(preparingEnvironment)
        INFO:     Waiting for application startup.
        2026-07-06 08:07:54.564 | INFO     | acestep.gpu_config:get_gpu_config:846 - macOS MPS \
        detected (107.5 GB unified memory, tier=unlimited).
        INFO:     Application startup complete.
        INFO:     Uvicorn running on http://127.0.0.1:8001 (Press CTRL+C to quit)
        [API Server] Server is ready to accept requests (models not loaded yet)
        """

    static let loadingModels = """
        [API Server] First request received — lazy-loading models...
        [API Server] Initializing models...
        [API Server] CPU offload disabled by default (GPU >= 16GB)
        [Model Download] Model acestep-v15-xl-turbo already exists at /checkpoints/acestep-v15-xl-turbo
        [API Server] Loading primary DiT model: acestep-v15-xl-turbo
        Loading checkpoint shards:   0%|          | 0/4 [00:00<?, ?steps/s]Loading checkpoint shards: \
        100%|##########| 4/4 [00:00<00:00, 50.80steps/s]
        2026-07-06 08:13:14.492 | INFO     | acestep.core.generation.handler.mlx_dit_init:_init_mlx_dit:34 \
        - [MLX-DiT] Native MLX DiT decoder initialized successfully (mx.compile=False).
        2026-07-06 08:13:15.362 | INFO     | acestep.llm_inference:initialize:609 - loading 5Hz LM \
        tokenizer... it may take 80~90s
        """

    /// The log is APPENDED across restarts, never truncated — this excerpt
    /// simulates a tail read early in a NEW boot that still holds the tail
    /// end of the PREVIOUS session (ending in its own "Uvicorn running" /
    /// "Finished server process" lines) followed by the new session's first
    /// few (pre-server) lines. The rightmost/most-recent marker (this
    /// session's "[API Server] Using LM model:") must win, not the stale
    /// "Uvicorn running" left over from the session that just exited.
    static let staleSessionTailFollowedByFreshPreparingEnvironment = """
        INFO:     Uvicorn running on http://127.0.0.1:8001 (Press CTRL+C to quit)
        INFO:     Shutting down
        INFO:     Finished server process [62566]
        W0710 01:26:58.705000 63500 torch/distributed/elastic/multiprocessing/redirects.py:29] \
        NOTE: Redirects are currently not supported in Windows or MacOs.
        2026-07-10 01:26:59.679 | WARNING  | acestep.training.trainer:<module>:40 - bitsandbytes \
        not installed. Using standard AdamW.
        [API Server] Using LM model: acestep-5Hz-lm-4B
        INFO:     Started server process [63500]
        """
}

@Suite("SidecarStartPhase — log-tail classification (M10-b, pure/headless)")
struct SidecarStartPhaseTests {
    @Test("early boot output (pre-uvicorn) -> preparing environment")
    func preparingEnvironmentClassifies() {
        #expect(SidecarStartPhase.classify(logTail: SampleLogExcerpts.preparingEnvironment)
                == "preparing environment…")
    }

    @Test("uvicorn/startup-complete lines -> starting server")
    func startingServerClassifies() {
        #expect(SidecarStartPhase.classify(logTail: SampleLogExcerpts.startingServer)
                == "starting server…")
    }

    @Test("DiT/checkpoint/MLX load lines -> loading models")
    func loadingModelsClassifies() {
        #expect(SidecarStartPhase.classify(logTail: SampleLogExcerpts.loadingModels)
                == "loading models…")
    }

    @Test("unrecognizable text -> nil (banner falls back to a generic line)")
    func unknownTailClassifiesNil() {
        #expect(SidecarStartPhase.classify(logTail: "some unrelated line\nanother one\n") == nil)
    }

    @Test("empty tail -> nil")
    func emptyTailClassifiesNil() {
        #expect(SidecarStartPhase.classify(logTail: "") == nil)
    }

    @Test("a fresh session's early lines outrank a PREVIOUS session's stale tail (log is append-only)")
    func mostRecentMarkerWinsAcrossSessionBoundary() {
        #expect(SidecarStartPhase.classify(
            logTail: SampleLogExcerpts.staleSessionTailFollowedByFreshPreparingEnvironment)
            == "preparing environment…")
    }
}

@Suite("SidecarManager.classifyFallbackBoot — pidfile-relaunch decision (M10-b, pure/headless)")
struct SidecarManagerClassifyFallbackBootTests {
    @Test("alive pid -> inProgress, started at the pidfile's own modification date")
    func aliveMapsToInProgress() {
        let modifiedAt = Date(timeIntervalSince1970: 1_752_000_000)
        let result = SidecarManager.classifyFallbackBoot(pid: 4242, modifiedAt: modifiedAt, isAlive: true)
        #expect(result == .inProgress(startedAt: modifiedAt, pid: 4242))
    }

    @Test("dead pid -> failedBoot (a lingering pidfile from a boot that already died)")
    func deadMapsToFailedBoot() {
        let result = SidecarManager.classifyFallbackBoot(
            pid: 4242, modifiedAt: Date(), isAlive: false)
        #expect(result == .failedBoot)
    }
}

@Suite("SidecarManager — status() honesty across the boot window (M10-b, real process/pidfile)")
struct SidecarManagerBootProgressTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Fresh-actor pidfile fallback (simulates an app relaunch mid-boot)

    @Test("""
        fresh manager instance + pidfile pointing at an ALIVE pid (this test process itself) \
        -> status() reports .starting from the pidfile's mtime, NEVER installedNotRunning
        """)
    func pidfileFallbackAliveReportsStarting() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("ace-step.log")
        try Data(SampleLogExcerpts.loadingModels.utf8).write(to: logURL)
        // This TEST process is certainly alive for the test's duration — a
        // real pid liveness check with no process to spawn/reap.
        let ownPid = ProcessInfo.processInfo.processIdentifier
        try Data("\(ownPid)".utf8).write(to: dir.appendingPathComponent(".ace-step.pid"))
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        // A FRESH manager — no in-memory `startedAt` — exercising the pidfile
        // fallback exclusively (requirement 1's relaunch-mid-boot case).
        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            acestepDir: dir, logFileURL: logURL))
        let status = await manager.status()

        #expect(status.state == .starting)
        #expect(status.pid == ownPid)
        #expect(status.phase == "loading models…")
        #expect(status.startingForSeconds != nil)
        #expect((status.startingForSeconds ?? -1) >= 0)
        #expect(status.message.localizedCaseInsensitiveContains("starting"))
    }

    @Test("""
        fresh manager instance + pidfile pointing at a DEAD pid \
        -> installedNotRunning, message names the boot as failed and points at the log
        """)
    func pidfileFallbackDeadReportsFailedBoot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("ace-step.log")
        // Pid 99999 is exceedingly unlikely to be a live process in a test
        // sandbox (the `stalePidfileIsCleanedUp` precedent above).
        try Data("99999".utf8).write(to: dir.appendingPathComponent(".ace-step.pid"))
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            acestepDir: dir, logFileURL: logURL))
        let status = await manager.status()

        #expect(status.state == .installedNotRunning)
        #expect(status.message.localizedCaseInsensitiveContains("boot"))
        #expect(status.message.contains(logURL.path))
        #expect(status.phase == nil)
        #expect(status.startingForSeconds == nil)
    }

    // MARK: Real start()/status()/stop() round-trip

    /// A `run.sh` that spawns a REAL, harmless, longer-lived child (a plain
    /// `sleep`) so `start()`'s process-liveness check and `stop()`'s SIGTERM
    /// path exercise an actual pid — never a stub. It never listens on a
    /// health port, so `start()` reliably times out without a real ACE-Step
    /// server, exactly reproducing the beta report's shape (process up,
    /// health not yet reachable).
    private func writeSleepingRunScript(in dir: URL, seconds: Int = 20) throws {
        try Data("#!/bin/bash\nsleep \(seconds)\n".utf8)
            .write(to: dir.appendingPathComponent("run.sh"))
    }

    @Test("""
        start() timing out leaves the boot tracked — a LATER status() poll still reports \
        .starting (with a phase + increasing elapsed seconds), never installedNotRunning; \
        stop() then cleanly ends it
        """)
    func startTimeoutThenLaterStatusStillReportsStarting() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSleepingRunScript(in: dir)
        let logURL = dir.appendingPathComponent("ace-step.log")
        // Pre-seed the log with a recognizable phase marker: `start()` opens
        // the log for WRITING but seeks to the END first (never truncates),
        // so this content survives and is what the timeout read sees (the
        // spawned `sleep` never writes anything of its own).
        try Data(SampleLogExcerpts.loadingModels.utf8).write(to: logURL)
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            acestepDir: dir,
            logFileURL: logURL,
            startupTimeoutSeconds: 0.4,
            healthPollIntervalSeconds: 0.1))

        let started = try await manager.start()
        #expect(started.state == .starting)
        #expect(started.pid != nil)
        #expect(started.phase == "loading models…")
        #expect(started.startingForSeconds != nil)
        // Health-aware timeout message: names the log path, doesn't read as
        // a hard failure ("did not report healthy" + "still loading", not
        // "call ai.sidecarStart").
        #expect(started.message.contains(logURL.path))
        #expect(started.message.localizedCaseInsensitiveContains("loading"))

        // THE bug this fixes: a poll made AFTER start() has already returned
        // (the beta user re-checking the panel) must still see .starting —
        // never installedNotRunning telling them to call ai.sidecarStart
        // again, since the process is already up and still booting.
        try await Task.sleep(nanoseconds: 150_000_000)
        let polled = await manager.status()
        #expect(polled.state == .starting)
        #expect(polled.pid == started.pid)
        #expect(polled.startingForSeconds != nil)
        if let first = started.startingForSeconds, let second = polled.startingForSeconds {
            #expect(second >= first)
        }

        // stop() ends the tracked boot cleanly (clearing rule c) and reaps
        // the real spawned process — verified by a subsequent status() no
        // longer reporting .starting.
        let stopped = try await manager.stop()
        #expect(stopped.state != .starting)
        let afterStop = await manager.status()
        #expect(afterStop.state != .starting)
    }
}
