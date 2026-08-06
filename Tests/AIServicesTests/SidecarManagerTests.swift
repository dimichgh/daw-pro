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

// MARK: - m23-bb: stop() must agree with status() about what "the sidecar" is

/// Synthetic process tables for the pure planning tests. Command lines are the
/// REAL ones this machine produces — `uv run --no-sync acestep-api` and
/// `.../python3 .../acestep-api` (no separator between "ace" and "step"), plus
/// the `/bin/bash <dir>/run.sh` launcher `SidecarManager.start()` spawns.
private enum FakeProcessTables {
    static let acestepDir = "/Users/tester/daw-pro/scripts/ace-step"

    /// The topology m23-bb's own report records: a launcher, the `uv run`
    /// supervisor under it, and the python child that actually holds the
    /// listening socket (and the ~75 GB).
    static let acestepTree = SidecarProcessDiscovery.Snapshot(entries: [
        .init(pid: 99, ppid: 1, args: "/bin/bash \(acestepDir)/run.sh"),
        .init(pid: 100, ppid: 99, args: "uv run --no-sync acestep-api"),
        .init(pid: 101, ppid: 100, args: "/Users/tester/.venv/bin/python3 /Users/tester/.venv/bin/acestep-api"),
        .init(pid: 4242, ppid: 1, args: "/usr/sbin/cupsd -l"),
    ])

    /// The same tree, but with THIS process (pid 500) sitting where the
    /// launcher's parent would be — the shape that would let an ancestor climb
    /// walk into DAW Pro itself.
    static let acestepTreeUnderSelf = SidecarProcessDiscovery.Snapshot(entries: [
        .init(pid: 500, ppid: 1, args: "/Users/tester/ace-step-checkout/.build/debug/DAWApp"),
        .init(pid: 99, ppid: 500, args: "/bin/bash \(acestepDir)/run.sh"),
        .init(pid: 100, ppid: 99, args: "uv run --no-sync acestep-api"),
        .init(pid: 101, ppid: 100, args: "/Users/tester/.venv/bin/python3 /Users/tester/.venv/bin/acestep-api"),
    ])
}

/// ACE-Step's identity predicate, spelled the way `SidecarManager` spells it.
/// The predicate itself lives in `SidecarStop.Identity` (shared with the RVC
/// sidecar, m23-bb-1); this is only a local shorthand so the assertions below
/// stay about the RULE rather than about the call syntax.
private func looksLikeACEStep(args: String, acestepDirPath: String?) -> Bool {
    SidecarStop.Identity.aceStep(directoryPath: acestepDirPath).matches(args: args)
}

@Suite("SidecarStop.resolvePlan (ACE-Step) — m23-bb routing (pure/headless)")
struct SidecarManagerStopPlanTests {
    // MARK: The floor rule — never route to "not running" while the probe answers

    /// ⭐ THE m23-bb TEST. The exact reported combination: the health probe
    /// says the sidecar is up, the pidfile holds a dead pid. The old code took
    /// its stale-pidfile branch, deleted the pidfile, said "was not running",
    /// and left the sidecar running.
    ///
    /// Asserted at the PLAN level on purpose: a message-only test passes
    /// against the broken code, because ".notRunning"'s wording is legitimate
    /// — it is the ROUTING that was wrong.
    @Test("probe healthy + STALE pidfile never resolves to .notRunning (the reported bug)")
    func healthyProbeWithStalePidfileNeverRoutesToNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: 28524, pidfilePidAlive: false,
            port: 8001, portLookup: .nothingListening,
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: nil)))
        if case .notRunning = plan {
            Issue.record("resolved to \(plan) while the health probe says the sidecar is answering")
        }
    }

    @Test("probe healthy + NO pidfile at all never resolves to .notRunning")
    func healthyProbeWithNoPidfileNeverRoutesToNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .nothingListening,
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: nil)))
        if case .notRunning = plan {
            Issue.record("resolved to \(plan) while the health probe says the sidecar is answering")
        }
    }

    @Test("""
        a port that ANSWERS but doesn't parse as ACE-Step's envelope still counts as answering \
        — never .notRunning
        """)
    func unparsableButRespondingNeverRoutesToNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .respondingButUnparsable, pidfilePid: 28524, pidfilePidAlive: false,
            port: 8001, portLookup: .nothingListening,
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: nil)))
        if case .notRunning = plan {
            Issue.record("resolved to \(plan) while something is answering on the sidecar's port")
        }
    }

    // MARK: The genuinely-correct existing behaviour, preserved

    @Test("probe unreachable + stale pidfile -> .notRunning(.stalePidfile) (that message IS right here)")
    func unreachableProbeWithStalePidfileIsNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 28524, pidfilePidAlive: false, port: 8001,
            identity: .aceStep(directoryPath: nil)))
        #expect(plan == .notRunning(.stalePidfile(pid: 28524)))
    }

    @Test("probe unreachable + no pidfile -> .notRunning(.noPidfile)")
    func unreachableProbeWithNoPidfileIsNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: nil, pidfilePidAlive: false, port: 8001,
            identity: .aceStep(directoryPath: nil)))
        #expect(plan == .notRunning(.noPidfile))
    }

    @Test("""
        live pidfile pid + probe unreachable -> terminate via the pidfile: a sidecar still BOOTING \
        has bound no port yet and must stay stoppable
        """)
    func livePidfileStillWinsWhileBooting() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 99, pidfilePidAlive: true, port: 8001,
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        #expect(plan == .terminate(pid: 99, discovery: .pidfile))
    }

    @Test("live pidfile pid whose command line is UNREADABLE fails OPEN — still terminated")
    func unreadableArgsOnThePidfilePathFailsOpen() {
        // Empty snapshot: `ps` gave us nothing, so identity is UNKNOWN. Unknown
        // must not read as "not ours" on the path that has always worked.
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 99, pidfilePidAlive: true, port: 8001,
            snapshot: .init(), selfPid: 500,
            identity: .aceStep(directoryPath: nil)))
        #expect(plan == .terminate(pid: 99, discovery: .pidfile))
    }

    // MARK: Port fallback — the fix

    @Test("""
        probe healthy + stale pidfile + an ACE-Step process on the port -> terminate it, climbing \
        from the LISTENING CHILD to the top of its own tree
        """)
    func portFallbackClimbsToTheTopOfTheSidecarTree() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: 28524, pidfilePidAlive: false,
            port: 8001, portLookup: .listeners([101]),
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        // 101 (python, holds the socket) -> 100 (uv run) -> 99 (run.sh launcher).
        #expect(plan == .terminate(pid: 99, discovery: .port(8001)))
    }

    @Test("both parent and child showing up in the port lookup collapse to ONE target")
    func duplicateListenersCollapseToOneTarget() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .listeners([100, 101]),
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        #expect(plan == .terminate(pid: 99, discovery: .port(8001)))
    }

    // MARK: Refusals — a pid from a port is not necessarily ours

    @Test("an unidentifiable process on the port is REFUSED, never signalled")
    func unidentifiedListenerIsRefused() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .listeners([4242]),
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        #expect(plan == .refuse(.listenerNotIdentified(
            port: 8001, pid: 4242, args: "/usr/sbin/cupsd -l")))
    }

    @Test("a process on the port with NO readable command line is refused (fails CLOSED here)")
    func unreadableArgsOnThePortPathFailsClosed() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .listeners([7777]),
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        #expect(plan == .refuse(.listenerNotIdentified(
            port: 8001, pid: 7777, args: "command line unavailable")))
    }

    @Test("THIS process holding the port is refused — stop() may never signal DAW Pro itself")
    func selfOnThePortIsRefused() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .listeners([500]),
            snapshot: FakeProcessTables.acestepTreeUnderSelf, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        #expect(plan == .refuse(.listenerIsThisProcess(port: 8001, pid: 500)))
    }

    @Test("""
        the ancestor climb STOPS at this process — a checkout path containing 'ace-step' must not \
        let the climb walk into DAW Pro
        """)
    func climbNeverWalksIntoThisProcess() {
        // pid 500's own command line contains "ace-step" (checkout path), so
        // the identity predicate alone would happily climb into it.
        #expect(looksLikeACEStep(
            args: "/Users/tester/ace-step-checkout/.build/debug/DAWApp",
            acestepDirPath: FakeProcessTables.acestepDir))
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .listeners([101]),
            snapshot: FakeProcessTables.acestepTreeUnderSelf, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        // Climbs 101 -> 100 -> 99, then STOPS: 99's parent is this process.
        #expect(plan == .terminate(pid: 99, discovery: .port(8001)))
    }

    @Test("two independent ACE-Step trees on one port -> refuse rather than guess")
    func multipleCandidatesAreRefused() {
        let snapshot = SidecarProcessDiscovery.Snapshot(entries: [
            .init(pid: 100, ppid: 1, args: "uv run --no-sync acestep-api"),
            .init(pid: 200, ppid: 1, args: "uv run --no-sync acestep-api"),
        ])
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .listeners([100, 200]),
            snapshot: snapshot, selfPid: 500,
            identity: .aceStep(directoryPath: nil)))
        #expect(plan == .refuse(.multipleCandidates(port: 8001, pids: [100, 200])))
    }

    @Test("port lookup that could not be RUN is refused distinctly from 'nothing is listening'")
    func discoveryUnavailableIsItsOwnRefusal() {
        let unavailable = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .unavailable("lsof is not available"),
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: nil)))
        #expect(unavailable == .refuse(.discoveryUnavailable(port: 8001, detail: "lsof is not available")))

        let empty = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8001, portLookup: .nothingListening,
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: nil)))
        #expect(empty == .refuse(.noListenerFound(port: 8001)))
    }

    @Test("a base URL with no derivable port is refused, never silently defaulted to 8001")
    func portUnknownIsRefused() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false, port: nil,
            identity: .aceStep(directoryPath: nil)))
        #expect(plan == .refuse(.portUnknown))
    }

    // MARK: A live pidfile pointing at a STRANGER (pid reuse)

    @Test("live pidfile pid that is provably NOT ours + probe answering -> falls through to the port")
    func foreignLivePidfileFallsThroughToPortDiscovery() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: 4242, pidfilePidAlive: true,
            port: 8001, portLookup: .listeners([101]),
            snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        #expect(plan == .terminate(pid: 99, discovery: .port(8001)))
    }

    @Test("live pidfile pid that is provably NOT ours + probe unreachable -> notRunning, nothing signalled")
    func foreignLivePidfileWithNoSidecarIsNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 4242, pidfilePidAlive: true,
            port: 8001, snapshot: FakeProcessTables.acestepTree, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        #expect(plan == .notRunning(.foreignPidfile(pid: 4242, args: "/usr/sbin/cupsd -l")))
    }

    @Test("a pidfile holding THIS process's own pid is never signalled")
    func pidfilePointingAtSelfIsNeverSignalled() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 500, pidfilePidAlive: true,
            port: 8001, snapshot: FakeProcessTables.acestepTreeUnderSelf, selfPid: 500,
            identity: .aceStep(directoryPath: FakeProcessTables.acestepDir)))
        if case .terminate(let pid, _) = plan {
            Issue.record("resolved to terminate pid \(pid) — that is this very process")
        }
    }
}

@Suite("SidecarManager.reconfirmationRefusal — pid reuse between planning and signalling (m23-bb)")
struct SidecarStopReconfirmationTests {
    private let dir = FakeProcessTables.acestepDir

    @Test("a port-discovered target that still identifies is signalled")
    func stillIdentifiedProceeds() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8001), targetPid: 100, targetAliveNow: true,
            argsNow: "uv run --no-sync acestep-api", identity: .aceStep(directoryPath: dir)) == nil)
    }

    @Test("a port-discovered target whose command line CHANGED is refused, not killed")
    func recycledPortTargetIsRefused() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8001), targetPid: 100, targetAliveNow: true,
            argsNow: "/usr/sbin/cupsd -l", identity: .aceStep(directoryPath: dir))
            == .listenerNotIdentified(port: 8001, pid: 100, args: "/usr/sbin/cupsd -l"))
    }

    @Test("a port-discovered target that has become unreadable while ALIVE is refused (fails closed)")
    func unreadablePortTargetIsRefused() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8001), targetPid: 100, targetAliveNow: true,
            argsNow: nil, identity: .aceStep(directoryPath: dir))
            == .listenerNotIdentified(port: 8001, pid: 100, args: "command line unavailable"))
    }

    @Test("a target that already exited needs no re-confirmation — there is nothing to signal")
    func deadTargetNeedsNoReconfirmation() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8001), targetPid: 100, targetAliveNow: false,
            argsNow: nil, identity: .aceStep(directoryPath: dir)) == nil)
    }

    /// The pidfile path keeps its fail-OPEN rule here too, for the same reason
    /// it has it in `resolveStopPlan`: a sidecar still booting has bound no
    /// port, and must stay stoppable even when `ps` tells us nothing.
    @Test("the PIDFILE path is never refused by this guard — unknown identity must not block a boot stop")
    func pidfilePathFailsOpen() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .pidfile, targetPid: 100, targetAliveNow: true,
            argsNow: nil, identity: .aceStep(directoryPath: dir)) == nil)
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .pidfile, targetPid: 100, targetAliveNow: true,
            argsNow: "/usr/sbin/cupsd -l", identity: .aceStep(directoryPath: dir)) == nil)
    }
}

@Suite("SidecarStop.Identity.aceStep — identity before any kill (m23-az separator trap)")
struct SidecarProcessIdentityTests {
    /// ⚠️ The regression this test exists for: a pattern requiring a separator
    /// (`ace[-_]step`) matches NEITHER real command line, so it fails CLOSED
    /// and refuses to signal a process it correctly found — measured at m23-az
    /// with a leaked 75 GB sidecar as the price.
    @Test("the REAL ACE-Step command lines have NO separator and must still match")
    func realCommandLinesMatchWithoutASeparator() {
        #expect(looksLikeACEStep(
            args: "uv run --no-sync acestep-api", acestepDirPath: nil))
        #expect(looksLikeACEStep(
            args: "/Users/x/.venv/bin/python3 /Users/x/.venv/bin/acestep-api", acestepDirPath: nil))
    }

    @Test("hyphenated and underscored spellings match too")
    func separatedSpellingsMatch() {
        #expect(looksLikeACEStep(
            args: "/bin/bash /repo/scripts/ace-step/run.sh", acestepDirPath: nil))
        #expect(looksLikeACEStep(args: "python -m ACE_Step.api", acestepDirPath: nil))
    }

    @Test("the configured sidecar directory is a second, independent limb")
    func configuredDirectoryMatches() {
        // A launcher living somewhere that never spells "acestep" at all.
        #expect(looksLikeACEStep(
            args: "/bin/bash /tmp/sidecar-xyz/run.sh", acestepDirPath: "/tmp/sidecar-xyz"))
        #expect(!looksLikeACEStep(
            args: "/bin/bash /tmp/sidecar-xyz/run.sh", acestepDirPath: "/tmp/other"))
    }

    @Test("unrelated processes never match — an empty configured directory must not match everything")
    func unrelatedProcessesDoNotMatch() {
        #expect(!looksLikeACEStep(args: "/usr/sbin/cupsd -l", acestepDirPath: nil))
        #expect(!looksLikeACEStep(
            args: "/usr/bin/python3 -m http.server 8001", acestepDirPath: nil))
        #expect(!looksLikeACEStep(args: "/usr/sbin/cupsd -l", acestepDirPath: ""))
    }
}

@Suite("SidecarManager stop messages — the honesty rule (m23-bb, pure)")
struct SidecarStopMessageTests {
    private let baseURL = URL(string: "http://127.0.0.1:8001")!

    /// Every refusal, exhaustively. A refusal is emitted only when the health
    /// probe says the sidecar is answering, so none of them may claim it is
    /// not running.
    private var allRefusals: [SidecarStop.Refusal] {
        [
            .portUnknown,
            .discoveryUnavailable(port: 8001, detail: "lsof is not available"),
            .noListenerFound(port: 8001),
            .listenerIsThisProcess(port: 8001, pid: 500),
            .listenerNotIdentified(port: 8001, pid: 4242, args: "/usr/sbin/cupsd -l"),
            .multipleCandidates(port: 8001, pids: [100, 200]),
        ]
    }

    @Test("no refusal message ever claims the sidecar is not running")
    func refusalsNeverClaimNotRunning() {
        for refusal in allRefusals {
            let message = SidecarStop.refusalMessage(
                refusal, vocabulary: .aceStep, baseURL: baseURL,
                pidfilePath: "/repo/scripts/ace-step/.ace-step.pid")
            #expect(!message.localizedCaseInsensitiveContains("not running"),
                    "refusal \(refusal) emitted a not-running claim: \(message)")
            #expect(message.localizedCaseInsensitiveContains("still up"),
                    "refusal \(refusal) does not say the sidecar is still up: \(message)")
            #expect(message.contains("127.0.0.1:8001"))
        }
    }

    /// The INVERSE half — without it the test above could pass by emitting
    /// nothing at all, and it would stop discriminating if the phrase were
    /// merely reworded rather than the routing fixed.
    @Test("the genuinely-down messages DO say 'not running' — that wording is correct there")
    func notRunningMessagesStillSayIt() {
        #expect(SidecarStop.notRunningMessage(.noPidfile, vocabulary: .aceStep)
            .localizedCaseInsensitiveContains("not running"))
        #expect(SidecarStop.notRunningMessage(.stalePidfile(pid: 28524), vocabulary: .aceStep)
            .localizedCaseInsensitiveContains("not running"))
        #expect(SidecarStop.notRunningMessage(.foreignPidfile(pid: 4242, args: "/usr/sbin/cupsd -l"), vocabulary: .aceStep)
            .localizedCaseInsensitiveContains("not running"))
        // The two pre-m23-bb messages are preserved verbatim.
        #expect(SidecarStop.notRunningMessage(.noPidfile, vocabulary: .aceStep)
            == "ACE-Step sidecar is not running (no pidfile found).")
        #expect(SidecarStop.notRunningMessage(.stalePidfile(pid: 28524), vocabulary: .aceStep)
            == "ACE-Step sidecar was not running (stale pidfile removed).")
    }

    @Test("a stop that signalled but left the port answering never claims 'not running' either")
    func stillAnsweringMessagesNeverClaimNotRunning() {
        let outcomes: [SidecarStop.TerminationOutcome] = [
            .init(targetPid: 100, targetSurvived: true),
            .init(targetPid: 100, targetRecycled: true),
            .init(targetPid: 100),
        ]
        for outcome in outcomes {
            let message = SidecarStop.stillAnsweringMessage(outcome: outcome, baseURL: baseURL, vocabulary: .aceStep)
            #expect(!message.localizedCaseInsensitiveContains("not running"), "\(message)")
            #expect(message.contains("127.0.0.1:8001"))
        }
        // The three cases are genuinely different stories, not one message.
        #expect(SidecarStop.stillAnsweringMessage(
            outcome: .init(targetPid: 100, targetSurvived: true), baseURL: baseURL, vocabulary: .aceStep)
            != SidecarStop.stillAnsweringMessage(outcome: .init(targetPid: 100), baseURL: baseURL, vocabulary: .aceStep))
    }

    @Test("a successful stop names the child processes it reaped — that is where the 75 GB lives")
    func stoppedMessageAccountsForDescendants() {
        let message = SidecarStop.stoppedMessage(
            outcome: .init(targetPid: 100, descendantsStopped: [101]), discovery: .port(8001), vocabulary: .aceStep)
        #expect(message.contains("101"))
        #expect(message.localizedCaseInsensitiveContains("child process"))

        let survivor = SidecarStop.stoppedMessage(
            outcome: .init(targetPid: 100, descendantsSurvived: [101]), discovery: .pidfile, vocabulary: .aceStep)
        #expect(survivor.contains("⚠️"))
        #expect(survivor.contains("101"))
    }
}

@Suite("SidecarProcessDiscovery — process-table parsing and tree walks (pure)")
struct SidecarProcessDiscoveryTests {
    @Test("`ps -eo pid,ppid,args` output parses, header skipped, args keep their spaces")
    func parsesRealPsOutput() {
        let snapshot = SidecarProcessDiscovery.parseSnapshot(psOutput: """
              PID  PPID ARGS
                1     0 /sbin/launchd
            49156 49150 uv run --no-sync acestep-api
            49160 49156 /Users/x/.venv/bin/python3 /Users/x/.venv/bin/acestep-api
            """)
        #expect(snapshot.entries.count == 3)
        #expect(snapshot.args(of: 49156) == "uv run --no-sync acestep-api")
        #expect(snapshot.entry(pid: 49160)?.ppid == 49156)
        #expect(snapshot.args(of: 12345) == nil)
    }

    @Test("descendants() is transitive and excludes the root")
    func descendantsAreTransitive() {
        let pids = FakeProcessTables.acestepTree.descendants(of: 99).map(\.pid)
        #expect(pids == [100, 101])
        #expect(FakeProcessTables.acestepTree.descendants(of: 101).isEmpty)
    }

    @Test("ancestors() walks up and stops before pid 1")
    func ancestorsStopAtPidOne() {
        #expect(FakeProcessTables.acestepTree.ancestors(of: 101) == [100, 99])
        #expect(FakeProcessTables.acestepTree.ancestors(of: 99).isEmpty)
    }

    @Test("a cyclic ppid chain terminates instead of hanging")
    func cyclesTerminate() {
        let cyclic = SidecarProcessDiscovery.Snapshot(entries: [
            .init(pid: 10, ppid: 11, args: "a"),
            .init(pid: 11, ppid: 10, args: "b"),
        ])
        #expect(cyclic.ancestors(of: 10) == [11])
        #expect(cyclic.descendants(of: 10).map(\.pid) == [11])
        #expect(cyclic.climb(from: 10, blocked: []) { _ in true } == 11)
    }

    @Test("climb() stops at a blocked parent")
    func climbStopsAtBlocked() {
        #expect(FakeProcessTables.acestepTree.climb(from: 101, blocked: []) { _ in true } == 99)
        #expect(FakeProcessTables.acestepTree.climb(from: 101, blocked: [99]) { _ in true } == 100)
        #expect(FakeProcessTables.acestepTree.climb(from: 101, blocked: []) { $0.pid != 99 } == 100)
    }

    @Test("lsof -t output parses to unique sorted pids")
    func parsesLsofOutput() {
        #expect(SidecarProcessDiscovery.parseListenerPids(lsofOutput: "49160\n49156\n49160\n") == [49156, 49160])
        #expect(SidecarProcessDiscovery.parseListenerPids(lsofOutput: "").isEmpty)
        #expect(SidecarProcessDiscovery.parseListenerPids(lsofOutput: "not-a-pid\n").isEmpty)
    }

    @Test("the port comes from the configured base URL — never hardcoded to 8001")
    func portComesFromTheBaseURL() {
        #expect(SidecarProcessDiscovery.port(of: URL(string: "http://127.0.0.1:8001")!) == 8001)
        #expect(SidecarProcessDiscovery.port(of: URL(string: "http://127.0.0.1:8002")!) == 8002)
        #expect(SidecarProcessDiscovery.port(of: URL(string: "http://127.0.0.1:54321")!) == 54321)
        #expect(SidecarProcessDiscovery.port(of: URL(string: "http://example.test")!) == 80)
        #expect(SidecarProcessDiscovery.port(of: URL(fileURLWithPath: "/tmp/x")) == nil)
    }

    @Test("captureSnapshot() sees this very process, with its real parent and command line")
    func captureSnapshotSeesThisProcess() {
        let snapshot = SidecarProcessDiscovery.captureSnapshot()
        let ownPid = ProcessInfo.processInfo.processIdentifier
        #expect(snapshot.entries.count > 1, "ps returned nothing usable")
        #expect(snapshot.entry(pid: ownPid) != nil, "this process is missing from its own ps snapshot")
        #expect(SidecarProcessDiscovery.args(ofPid: ownPid) != nil)
    }

    @Test("listeners() finds a socket this test itself is holding, and none on a freed port")
    func listenersFindsARealSocket() throws {
        let server = StubHealthServer(responseData: StubHealthServer.healthyResponse())
        try server.start()
        defer { server.stop() }

        // POSITIVE CONTROL: the socket demonstrably exists (we are holding it),
        // so `.nothingListening` here would be a broken lookup, not an absence.
        let found = SidecarProcessDiscovery.listeners(onPort: server.port)
        #expect(found == .listeners([ProcessInfo.processInfo.processIdentifier]),
                "lsof did not attribute a socket this process is holding: \(found)")

        let freed = try StubHealthServer.unusedLoopbackPort()
        #expect(SidecarProcessDiscovery.listeners(onPort: freed) == .nothingListening)
    }
}

@Suite("SidecarManager.stop() — m23-bb end to end (real probe, real port discovery)")
struct SidecarManagerStopHonestyTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ⭐ The reported scenario, reproduced with a real health responder and
    /// real `lsof`/`ps` discovery — no ACE-Step process anywhere.
    ///
    /// The listener the probe answers from IS this test process, so the plan
    /// must resolve to a REFUSAL (we never signal ourselves), `stop()` must
    /// THROW rather than return a success-shaped status, and — because a
    /// failed stop must not quietly delete state — the pidfile must survive.
    @Test("healthy probe + stale pidfile: stop() throws an honest error and removes nothing")
    func healthyProbeWithStalePidfileThrowsInsteadOfLying() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidfile = dir.appendingPathComponent(".ace-step.pid")
        try Data("99999".utf8).write(to: pidfile)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".install-state.json"))

        let server = StubHealthServer(responseData: StubHealthServer.healthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, acestepDir: dir))

        // status() and stop() must now agree about what "the sidecar" is.
        #expect(await manager.status().state == .healthy)

        // The EXACT resolved plan, not an inference from message text — and
        // specifically NOT `.noListenerFound`/`.discoveryUnavailable`, either
        // of which would satisfy every honesty assertion while proving that
        // discovery is broken.
        let plan = await manager.resolvedStopPlan()
        #expect(plan == .refuse(.listenerIsThisProcess(
            port: server.port, pid: ProcessInfo.processInfo.processIdentifier)))

        do {
            let status = try await manager.stop()
            Issue.record("""
                stop() returned \(status.state): \(status.message) — it must not succeed while \
                the health probe reports the sidecar healthy
                """)
        } catch let error as SidecarError {
            let message = try #require(error.errorDescription)
            #expect(!message.localizedCaseInsensitiveContains("not running"), "\(message)")
            #expect(message.localizedCaseInsensitiveContains("still up"), "\(message)")
            #expect(message.contains("\(server.port)"), "\(message)")
        }

        // A refusal changes nothing: the pidfile is still there and the
        // sidecar is (correctly) still reported healthy.
        #expect(FileManager.default.fileExists(atPath: pidfile.path))
        #expect(await manager.status().state == .healthy)
    }

    @Test("healthy probe + NO pidfile: stop() still refuses to report 'not running'")
    func healthyProbeWithNoPidfileThrowsInsteadOfLying() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".install-state.json"))

        let server = StubHealthServer(responseData: StubHealthServer.healthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, acestepDir: dir))

        do {
            let status = try await manager.stop()
            Issue.record("stop() returned \(status.state): \(status.message)")
        } catch let error as SidecarError {
            let message = try #require(error.errorDescription)
            #expect(!message.localizedCaseInsensitiveContains("not running"), "\(message)")
        }
    }

    /// ⚠️ The regression this catches is a FACT-GATHERING one, not a planning
    /// one: the planner correctly falls through to port discovery when the
    /// pidfile holds a live but foreign (recycled) pid — but if `stop()` only
    /// looks up the port when the pidfile gave it nothing, that fall-through
    /// can never fire, and the answer degrades to "nothing is listening" while
    /// the sidecar is plainly answering.
    @Test("a live but FOREIGN pidfile pid still reaches port discovery, and the stranger is never signalled")
    func liveForeignPidfileStillReachesPortDiscovery() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real, live, harmless process that is plainly NOT ACE-Step: its
        // command line contains neither "acestep" nor the configured dir.
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stranger.arguments = ["30"]
        try stranger.run()
        defer {
            if stranger.isRunning { kill(stranger.processIdentifier, SIGKILL) }
        }
        let strangerPid = stranger.processIdentifier
        try Data("\(strangerPid)".utf8).write(to: dir.appendingPathComponent(".ace-step.pid"))

        let server = StubHealthServer(responseData: StubHealthServer.healthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, acestepDir: dir))
        let plan = await manager.resolvedStopPlan()

        // Port discovery MUST have run: the refusal names the listener we know
        // is there, not "nothing is listening".
        #expect(plan == .refuse(.listenerIsThisProcess(
            port: server.port, pid: ProcessInfo.processInfo.processIdentifier)))
        // And the stranger in the pidfile is untouched.
        #expect(kill(strangerPid, 0) == 0, "the foreign process named by the pidfile was signalled")

        kill(strangerPid, SIGKILL)
    }

    @Test("dry-run against a healthy probe still never claims 'not running', and signals nothing")
    func dryRunStaysHonestAndInert() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidfile = dir.appendingPathComponent(".ace-step.pid")
        try Data("99999".utf8).write(to: pidfile)

        let server = StubHealthServer(responseData: StubHealthServer.healthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, acestepDir: dir, dryRun: true))
        let status = try await manager.stop()

        #expect(status.message.contains("[dry-run]"))
        #expect(!status.message.localizedCaseInsensitiveContains("not running"), "\(status.message)")
        #expect(FileManager.default.fileExists(atPath: pidfile.path), "dry-run removed the pidfile")
    }
}

@Suite("SidecarManager.stop() — the child process is what holds the memory (m23-bb)")
struct SidecarManagerStopDescendantTests {
    /// A launcher that spawns a REAL, harmless, longer-lived grandchild, so
    /// the parent/child topology m23-bb reports (`pid 49156 -> python 49160`)
    /// is reproduced without ACE-Step: killing only the pidfile's pid leaves
    /// the child alive and reparented to pid 1 — measured directly, and the
    /// reason the descendant set must be captured BEFORE signalling.
    @Test("stop() reaps the child the sidecar spawned, not just the pid in the pidfile")
    func stopReapsTheSpawnedChild() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("#!/bin/bash\nsleep 45\n".utf8).write(to: dir.appendingPathComponent("run.sh"))
        let logURL = dir.appendingPathComponent("ace-step.log")
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = SidecarManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            acestepDir: dir,
            logFileURL: logURL,
            startupTimeoutSeconds: 0.4,
            healthPollIntervalSeconds: 0.1,
            stopTimeoutSeconds: 1.0))

        let started = try await manager.start()
        let parentPid = try #require(started.pid)

        // POSITIVE CONTROL: the grandchild must actually exist before this
        // test can claim anything about reaping it.
        var child: SidecarProcessDiscovery.Entry?
        for _ in 0..<20 {
            child = SidecarProcessDiscovery.captureSnapshot().descendants(of: parentPid).first
            if child != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let childEntry = try #require(child, "the launcher never spawned a child to reap")
        #expect(childEntry.args.contains("sleep"))

        let stopped = try await manager.stop()

        // THE assertion. Before m23-bb, `stop()` signalled only the pidfile's
        // pid; this grandchild outlived it, reparented to pid 1.
        #expect(kill(childEntry.pid, 0) != 0, """
            the child (pid \(childEntry.pid), \(childEntry.args)) survived stop() — on a real \
            sidecar that is the process holding ~75 GB
            """)
        #expect(stopped.message.contains("\(childEntry.pid)"),
                "the reaped child is not accounted for in the message: \(stopped.message)")
        // The launcher is deliberately checked through `ps` rather than
        // `kill(pid, 0)`: it is a direct child of the TEST process, so it can
        // linger briefly as a zombie, and `kill -0` succeeds on a zombie.
        // A zombie's `ps` args read `(bash)`, never the script path.
        #expect(SidecarProcessDiscovery.args(ofPid: parentPid)?.contains("run.sh") != true,
                "the launcher (pid \(parentPid)) is still running its script after stop()")
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
