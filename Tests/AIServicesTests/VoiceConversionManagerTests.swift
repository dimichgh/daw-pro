import Foundation
import Testing
@testable import AIServices

/// `VoiceConversionManager` coverage (m10-p-3) — the `SidecarManagerTests`
/// sibling for the RVC voice-conversion sidecar. Reuses `StubHealthServer`
/// (`SidecarManagerTests.swift`) as-is — its plumbing (accept a connection,
/// ignore the request, reply with one canned response) is entirely generic.
/// Mirrors that suite's discipline: status mapping, start() path resolution
/// (dry-run, headless), stop(), and the M10-b boot-progress honesty tests —
/// minus phase classification, which this sidecar deliberately has none of
/// (see `VoiceConversionStatus.phase`'s doc).
private func rvcHTTPResponse(status: Int = 200, body: String) -> Data {
    let bodyData = Data(body.utf8)
    var header = "HTTP/1.1 \(status) OK\r\n"
    header += "Content-Type: application/json\r\n"
    header += "Content-Length: \(bodyData.count)\r\n"
    header += "Connection: close\r\n\r\n"
    return Data(header.utf8) + bodyData
}

private func rvcHealthyResponse(
    version: String = "0.1.0", engine: String = "Acelogic/Retrieval-based-Voice-Conversion-MLX",
    baseModelPresent: Bool = true, voiceCount: Int = 0
) -> Data {
    rvcHTTPResponse(body: """
        {"data":{"service":"rvc-vc-facade","version":"\(version)","engine":"\(engine)",\
        "baseModelPresent":\(baseModelPresent),"voiceCount":\(voiceCount),"port":8002},\
        "code":0,"error":null}
        """)
}

private func rvcMalformedResponse() -> Data {
    rvcHTTPResponse(body: #"{"unexpected":"shape"}"#)
}

/// m23-fo-2 — `resolveLaunchPlan()` now REFUSES to spawn without the
/// mitigation hook, so every test that reaches a real or dry launch must
/// provide one.
///
/// ⚠️ Written INSIDE the test's own temp dir and pointed at with
/// `mitigationDirOverride`, NEVER left to the sibling default: for an
/// `rvcDir` of `/…/T/rvc-test-<uuid>` the sibling would be the SHARED
/// `/…/T/rvc-mitigation`, so parallel tests would see each other's hook and
/// one test's cleanup would break another's setup.
private func makeMitigationDir(in parent: URL) throws -> URL {
    let dir = parent.appendingPathComponent("rvc-mitigation")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("# stub hook — presence is all resolveLaunchPlan() checks.\n".utf8)
        .write(to: dir.appendingPathComponent("sitecustomize.py"))
    return dir
}

private func rvcConfig(
    baseURL: URL,
    rvcDir: URL?,
    mitigationDir: URL?,
    startupTimeoutSeconds: Double = 30,
    healthPollIntervalSeconds: Double = 0.5,
    dryRun: Bool = false
) -> VoiceConversionManager.Configuration {
    var config = VoiceConversionManager.Configuration(
        baseURL: baseURL,
        rvcDir: rvcDir,
        startupTimeoutSeconds: startupTimeoutSeconds,
        healthPollIntervalSeconds: healthPollIntervalSeconds,
        dryRun: dryRun)
    config.mitigationDirOverride = mitigationDir
    return config
}

@Suite("VoiceConversionManager — status mapping (m10-p-3)")
struct VoiceConversionManagerStatusTests {
    private func baseURL(port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    @Test("200 + well-formed JSON -> healthy, with version/engine/baseModelPresent/voiceCount")
    func healthyMapsToHealthy() async throws {
        let server = StubHealthServer(responseData: rvcHealthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: server.port), rvcDir: nil))
        let status = await manager.status()

        #expect(status.state == .healthy)
        #expect(status.version == "0.1.0")
        #expect(status.engine == "Acelogic/Retrieval-based-Voice-Conversion-MLX")
        #expect(status.baseModelPresent == true)
        #expect(status.voiceCount == 0)
        #expect(status.phase == nil, "no phase classifier exists for this sidecar (v1)")
        #expect(!status.message.isEmpty)
    }

    @Test("200 + malformed JSON (no data envelope) -> error")
    func malformedMapsToError() async throws {
        let server = StubHealthServer(responseData: rvcMalformedResponse())
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: server.port), rvcDir: nil))
        let status = await manager.status()

        #expect(status.state == .error)
        #expect(status.version == nil)
        #expect(!status.message.isEmpty)
    }

    @Test("connection refused, no install marker -> notInstalled")
    func connectionRefusedWithoutMarkerMapsToNotInstalled() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: port), rvcDir: tempDir))
        let status = await manager.status()

        #expect(status.state == .notInstalled)
        #expect(status.message.localizedCaseInsensitiveContains("install.sh"))
    }

    @Test("connection refused, install marker present -> installedNotRunning")
    func connectionRefusedWithMarkerMapsToInstalledNotRunning() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Data("{}".utf8).write(to: tempDir.appendingPathComponent(".install-state.json"))

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: port), rvcDir: tempDir))
        let status = await manager.status()

        #expect(status.state == .installedNotRunning)
        #expect(status.message.localizedCaseInsensitiveContains("vc.sidecarStart"))
    }

    @Test("unresolvable directory (no env override) -> notInstalled, never crashes")
    func unresolvableDirectoryMapsToNotInstalled() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: port), rvcDir: nil))
        let status = await manager.status()
        #expect(status.state == .notInstalled)
    }
}

@Suite("VoiceConversionManager — start() path resolution (dry-run, headless)")
struct VoiceConversionManagerStartTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("no run.sh -> start() throws notInstalled verbatim, points at install.sh")
    func missingRunScriptThrowsNotInstalled() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir, dryRun: true))

        do {
            _ = try await manager.start()
            Issue.record("expected start() to throw")
        } catch let error as SidecarError {
            #expect(error.errorDescription?.localizedCaseInsensitiveContains("install.sh") == true)
        }
    }

    @Test("no rvcDir resolvable -> start() throws notInstalled verbatim")
    func missingDirectoryThrowsNotInstalled() async throws {
        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: nil, dryRun: true))
        do {
            _ = try await manager.start()
            Issue.record("expected start() to throw")
        } catch let error as SidecarError {
            #expect(error.errorDescription?.localizedCaseInsensitiveContains("DAWPRO_RVC_DIR") == true)
        }
    }

    @Test("run.sh present + dry-run -> returns the exact command it would spawn, never launches a process")
    func dryRunReturnsResolvedCommand() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runScript = dir.appendingPathComponent("run.sh")
        try Data("#!/bin/bash\necho stub\n".utf8).write(to: runScript)
        let hookDir = try makeMitigationDir(in: dir)

        let manager = VoiceConversionManager(configuration: rvcConfig(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir,
            mitigationDir: hookDir, dryRun: true))
        let status = try await manager.start()

        #expect(status.state == .starting)
        #expect(status.message.contains("run.sh"))
        #expect(status.message.contains(dir.path))
        #expect(status.message.contains("[dry-run]"))
        // No pidfile should ever be written by THIS type — see the type doc's
        // deviation 1 (run.sh is the pidfile's sole writer) — doubly true in
        // dry-run mode where nothing is even spawned.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".rvc.pid").path))
    }

    @Test("resolveRVCDir() without an override walks up to this repo's Package.swift")
    func resolveLaunchPlanFindsRepoScriptsDir() throws {
        let resolved = VoiceConversionManager.Configuration.resolveRVCDir(environment: [:])
        #expect(resolved?.lastPathComponent == "rvc")
        #expect(resolved?.deletingLastPathComponent().lastPathComponent == "scripts")
    }

    @Test("DAWPRO_RVC_DIR env override wins over the repo walk-up")
    func envOverrideWins() throws {
        let resolved = VoiceConversionManager.Configuration.resolveRVCDir(
            environment: ["DAWPRO_RVC_DIR": "/tmp/some-stub-rvc-dir"])
        #expect(resolved?.path == "/tmp/some-stub-rvc-dir")
    }

    @Test("real (non-dry-run) start() spawning a harmless child never writes a pidfile itself")
    func realStartNeverWritesPidfile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A run.sh that sleeps briefly WITHOUT writing a pidfile of its own —
        // isolates "does VoiceConversionManager.start() write one" from
        // "does the real scripts/rvc/run.sh write one" (proven separately by
        // the live E2E gate).
        try Data("#!/bin/bash\nsleep 1\n".utf8).write(to: dir.appendingPathComponent("run.sh"))
        let hookDir = try makeMitigationDir(in: dir)
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = VoiceConversionManager(configuration: rvcConfig(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            rvcDir: dir, mitigationDir: hookDir,
            startupTimeoutSeconds: 0.3, healthPollIntervalSeconds: 0.1))
        let status = try await manager.start()

        #expect(status.state == .starting)
        #expect(status.pid != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".rvc.pid").path))

        // Best-effort cleanup of the spawned sleep — stop() has nothing to
        // signal (no pidfile), so reap directly by pid.
        if let pid = status.pid {
            kill(pid, SIGKILL)
        }
    }
}

@Suite("VoiceConversionManager — stop()")
struct VoiceConversionManagerStopTests {
    @Test("no pidfile -> installedNotRunning, no-op success (not an error)")
    func noPidfileIsNoopSuccess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".install-state.json"))

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir))
        let status = try await manager.stop()

        #expect(status.state == .installedNotRunning)
    }

    @Test("stale pidfile (dead pid, as run.sh would have written) -> installedNotRunning, pidfile removed")
    func stalePidfileIsCleanedUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidfile = dir.appendingPathComponent(".rvc.pid")
        try Data("99999".utf8).write(to: pidfile)

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir))
        let status = try await manager.stop()

        #expect(status.state == .installedNotRunning)
        #expect(!FileManager.default.fileExists(atPath: pidfile.path))
    }

    @Test("dry-run stop with a pidfile present reports the pid, never signals it, never removes the file")
    func dryRunStopNeverSignals() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("99999".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir, dryRun: true))
        let status = try await manager.stop()

        #expect(status.pid == 99999)
        #expect(status.message.contains("[dry-run]"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".rvc.pid").path))
    }

    @Test("stop() removes a pidfile it never wrote itself (deviation 1 cleanup)")
    func stopRemovesPidfileItNeverWrote() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Simulate run.sh's own pidfile write for a REAL alive process this
        // test spawns and reaps itself (the `stalePidfileIsCleanedUp`
        // precedent, but alive so the SIGTERM path actually runs).
        //
        // ⚠️ m23-bb-1: the child must be launched OUT OF THE CONFIGURED
        // DIRECTORY, because `stop()` now confirms identity before signalling
        // anything. A bare `/bin/sleep 20` is a stranger whose command line
        // names nothing of ours, and refusing to kill it is now the CORRECT
        // behaviour (`.notRunning(.foreignPidfile)`) — see
        // `liveForeignPidfileIsNeverSignalled` below, which pins exactly that.
        let script = dir.appendingPathComponent("run.sh")
        try Data("#!/bin/bash\nsleep 20\n".utf8).write(to: script)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = [script.path]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        try Data("\(child.processIdentifier)".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir, stopTimeoutSeconds: 2))
        let status = try await manager.stop()

        #expect(status.state == .installedNotRunning)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".rvc.pid").path))
        #expect(!child.isRunning)
    }

    /// The other half of the test above, and the reason it had to change: a
    /// live pidfile pid whose command line is READABLE and plainly not ours is
    /// a recycled pid, not our sidecar. Nothing may be signalled.
    @Test("a live pidfile pid that is provably NOT ours is never signalled (pid reuse)")
    func liveForeignPidfileIsNeverSignalled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stranger.arguments = ["20"]
        try stranger.run()
        defer { if stranger.isRunning { kill(stranger.processIdentifier, SIGKILL) } }
        let strangerPid = stranger.processIdentifier
        try Data("\(strangerPid)".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir, stopTimeoutSeconds: 2))
        let status = try await manager.stop()

        #expect(status.state == .installedNotRunning)
        #expect(status.message.contains("unrelated process"), "\(status.message)")
        #expect(kill(strangerPid, 0) == 0, "the foreign process named by the pidfile was signalled")
        kill(strangerPid, SIGKILL)
    }
}

@Suite("VoiceConversionManager.classifyFallbackBoot — pidfile-relaunch decision (m10-p-3, pure/headless)")
struct VoiceConversionManagerClassifyFallbackBootTests {
    @Test("alive pid -> inProgress, started at the pidfile's own modification date")
    func aliveMapsToInProgress() {
        let modifiedAt = Date(timeIntervalSince1970: 1_752_000_000)
        let result = VoiceConversionManager.classifyFallbackBoot(pid: 4242, modifiedAt: modifiedAt, isAlive: true)
        #expect(result == .inProgress(startedAt: modifiedAt, pid: 4242))
    }

    @Test("dead pid -> failedBoot (a lingering pidfile from a boot that already died)")
    func deadMapsToFailedBoot() {
        let result = VoiceConversionManager.classifyFallbackBoot(pid: 4242, modifiedAt: Date(), isAlive: false)
        #expect(result == .failedBoot)
    }
}

@Suite("VoiceConversionManager — status() honesty across the boot window (m10-p-3, real process/pidfile)")
struct VoiceConversionManagerBootProgressTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("""
        fresh manager instance + pidfile pointing at an ALIVE pid (this test process itself) \
        -> status() reports .starting from the pidfile's mtime, NEVER installedNotRunning
        """)
    func pidfileFallbackAliveReportsStarting() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        try Data("\(ownPid)".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!, rvcDir: dir))
        let status = await manager.status()

        #expect(status.state == .starting)
        #expect(status.pid == ownPid)
        #expect(status.phase == nil, "no phase classifier exists for this sidecar (v1)")
        #expect(status.startingForSeconds != nil)
        #expect((status.startingForSeconds ?? -1) >= 0)
        #expect(status.message.localizedCaseInsensitiveContains("starting"))
    }

    @Test("""
        fresh manager instance + pidfile pointing at a DEAD pid \
        -> installedNotRunning, message names the boot as failed
        """)
    func pidfileFallbackDeadReportsFailedBoot() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("99999".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!, rvcDir: dir))
        let status = await manager.status()

        #expect(status.state == .installedNotRunning)
        #expect(status.message.localizedCaseInsensitiveContains("boot"))
        #expect(status.phase == nil)
        #expect(status.startingForSeconds == nil)
    }

    private func writeSleepingRunScript(in dir: URL, seconds: Int = 20) throws {
        try Data("#!/bin/bash\nsleep \(seconds)\n".utf8)
            .write(to: dir.appendingPathComponent("run.sh"))
    }

    @Test("""
        start() timing out leaves the boot tracked — a LATER status() poll still reports \
        .starting with increasing elapsed seconds, never installedNotRunning; stop() then ends it
        """)
    func startTimeoutThenLaterStatusStillReportsStarting() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSleepingRunScript(in: dir)
        let hookDir = try makeMitigationDir(in: dir)
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = VoiceConversionManager(configuration: rvcConfig(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            rvcDir: dir,
            mitigationDir: hookDir,
            startupTimeoutSeconds: 0.4,
            healthPollIntervalSeconds: 0.1))

        let started = try await manager.start()
        #expect(started.state == .starting)
        #expect(started.pid != nil)
        #expect(started.startingForSeconds != nil)
        #expect(started.message.localizedCaseInsensitiveContains("still booting"))

        try await Task.sleep(nanoseconds: 150_000_000)
        let polled = await manager.status()
        #expect(polled.state == .starting)
        #expect(polled.pid == started.pid)
        #expect(polled.startingForSeconds != nil)
        if let first = started.startingForSeconds, let second = polled.startingForSeconds {
            #expect(second >= first)
        }

        // stop() ends the tracked boot cleanly (this manager never wrote the
        // pidfile — seed one ourselves, exactly what run.sh would have done
        // for this same spawned pid, so stop()'s SIGTERM path has something
        // to read).
        if let pid = started.pid {
            try Data("\(pid)".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))
        }
        let stopped = try await manager.stop()
        #expect(stopped.state != .starting)
        let afterStop = await manager.status()
        #expect(afterStop.state != .starting)
    }
}

// MARK: - m23-bb-1: stop() must agree with status() about what "the sidecar" is

/// Synthetic process tables for the pure planning tests. Command lines are the
/// REAL ones `scripts/rvc/run.sh` produces: it ends in
/// `exec "$VENV_PY" "$SCRIPT_DIR/server.py"`, so — unlike ACE-Step's
/// `uv run` -> python topology — there is NO parent/child split and the pid in
/// `.rvc.pid` IS uvicorn.
private enum FakeRVCProcessTables {
    static let rvcDir = "/Users/tester/daw-pro/scripts/rvc"

    /// The launcher has `exec`d away, so pid 77 is both "the pidfile's pid" and
    /// "the process holding the listening socket". `4343` is the trap this
    /// sidecar's identity check exists for: a real, unrelated program whose
    /// name merely contains the letters "rvc".
    static let rvcTree = SidecarProcessDiscovery.Snapshot(entries: [
        .init(pid: 77, ppid: 1,
              args: "\(rvcDir)/runtime/src/.venv/bin/python \(rvcDir)/server.py"),
        .init(pid: 4242, ppid: 1, args: "/usr/sbin/cupsd -l"),
        .init(pid: 4343, ppid: 1, args: "/usr/bin/rvcplayer --input /tmp/take.wav"),
    ])

    /// The shape that would let an ancestor climb walk into DAW Pro itself: the
    /// app is checked out UNDER a directory that the identity predicate's
    /// path-containment limb matches.
    static let selfHazardDir = "/Users/tester/rvc"
    static let rvcTreeUnderSelf = SidecarProcessDiscovery.Snapshot(entries: [
        .init(pid: 500, ppid: 1, args: "\(selfHazardDir)/checkout/.build/debug/DAWApp"),
        .init(pid: 77, ppid: 500,
              args: "\(selfHazardDir)/runtime/src/.venv/bin/python \(selfHazardDir)/server.py"),
    ])
}

@Suite("SidecarStop.Identity.rvc — identity before any kill (m23-bb-1)")
struct RVCProcessIdentityTests {
    private let dir = FakeRVCProcessTables.rvcDir

    @Test("the REAL command lines run.sh produces are identified via the configured directory")
    func realCommandLinesMatch() {
        let identity = SidecarStop.Identity.rvc(directoryPath: dir)
        #expect(identity.matches(args: "\(dir)/runtime/src/.venv/bin/python \(dir)/server.py"))
        #expect(identity.matches(args: "/bin/bash \(dir)/run.sh"))
        // RVC_RUNTIME_DIR can move the interpreter elsewhere; `$SCRIPT_DIR/server.py`
        // still names the configured directory, which is why that limb is primary.
        #expect(identity.matches(args: "/opt/venvs/rvc-mlx/bin/python \(dir)/server.py"))
    }

    /// ⭐ THE REASON RVC's PREDICATE IS NOT A COPY OF ACE's. "ace-step" is a
    /// rare token; "rvc" is three letters that turn up all over a developer's
    /// machine. A bare `/rvc/i` would match EVERY line below — and this command
    /// kills what it matches.
    @Test("a bare 'rvc' substring is NOT enough — none of these unrelated processes match")
    func unrelatedProcessesNeverMatch() {
        for identity in [SidecarStop.Identity.rvc(directoryPath: nil),
                         SidecarStop.Identity.rvc(directoryPath: dir)] {
            #expect(!identity.matches(args: "/usr/bin/rvcplayer --input /tmp/take.wav"))
            #expect(!identity.matches(args: "/opt/myrvc/server.py"))
            #expect(!identity.matches(args: "/usr/bin/python3 -m rvc.server"))
            #expect(!identity.matches(args: "/usr/local/bin/converter --engine=rvc"))
            #expect(!identity.matches(args: "/Users/tester/rvc-tools/index.py"))
            #expect(!identity.matches(args: "/usr/sbin/cupsd -l"))
            #expect(!identity.matches(args: "/usr/bin/python3 -m http.server 8002"))
        }
    }

    /// The narrow pattern limb is a backstop for the case where the configured
    /// spelling of the directory and the one `ps` reports diverge (a symlinked
    /// or non-standardised `DAWPRO_RVC_DIR`). It requires `rvc` as a WHOLE PATH
    /// COMPONENT immediately followed by a file this sidecar actually executes.
    @Test("the pattern limb needs 'rvc' as a path component followed by server.py/run.sh")
    func anchoredPatternLimb() {
        let identity = SidecarStop.Identity.rvc(directoryPath: nil)
        #expect(identity.matches(args: "/private/repo/scripts/rvc/server.py"))
        #expect(identity.matches(args: "/bin/bash /private/repo/scripts/rvc/run.sh"))
        #expect(identity.matches(args: "/x/.venv/bin/python /x/rvc/server.py --reload"))
        // ...and refuses the near-misses.
        #expect(!identity.matches(args: "/private/repo/scripts/myrvc/server.py"))
        #expect(!identity.matches(args: "/private/repo/scripts/rvc/serverpy"))
        #expect(!identity.matches(args: "/private/repo/scripts/rvc/server.py.bak"))
        #expect(!identity.matches(args: "/private/repo/scripts/rvc/install.sh"))
    }

    /// An empty configured directory must not match EVERYTHING — the worst
    /// possible failure mode for a predicate that decides what to kill.
    @Test("an empty configured directory matches nothing")
    func emptyDirectoryMatchesNothing() {
        let identity = SidecarStop.Identity.rvc(directoryPath: "")
        #expect(!identity.matches(args: "/usr/sbin/cupsd -l"))
        #expect(!identity.matches(args: ""))
    }
}

@Suite("SidecarStop.resolvePlan (RVC) — m23-bb-1 routing (pure/headless)")
struct RVCStopPlanTests {
    private let identity = SidecarStop.Identity.rvc(directoryPath: FakeRVCProcessTables.rvcDir)

    // MARK: The floor rule — never route to "not running" while the probe answers

    /// ⭐ THE m23-bb-1 TEST. The exact reported combination: the health probe
    /// says the RVC sidecar is up, the pidfile holds a dead pid. The old code
    /// took its stale-pidfile branch, deleted the pidfile, said "was not
    /// running", and left the sidecar running.
    ///
    /// Asserted at the PLAN level on purpose: a message-only test passes
    /// against the broken code, because ".notRunning"'s wording is legitimate —
    /// it is the ROUTING that was wrong.
    @Test("probe healthy + STALE pidfile never resolves to .notRunning (the reported bug)")
    func healthyProbeWithStalePidfileNeverRoutesToNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: 31337, pidfilePidAlive: false,
            port: 8002, portLookup: .nothingListening,
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        if case .notRunning = plan {
            Issue.record("resolved to \(plan) while the health probe says the sidecar is answering")
        }
    }

    @Test("probe healthy + NO pidfile at all never resolves to .notRunning")
    func healthyProbeWithNoPidfileNeverRoutesToNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .nothingListening,
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        if case .notRunning = plan {
            Issue.record("resolved to \(plan) while the health probe says the sidecar is answering")
        }
    }

    @Test("""
        a port that ANSWERS but doesn't parse as the facade's envelope still counts as answering \
        — never .notRunning
        """)
    func unparsableButRespondingNeverRoutesToNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .respondingButUnparsable, pidfilePid: 31337, pidfilePidAlive: false,
            port: 8002, portLookup: .nothingListening,
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        if case .notRunning = plan {
            Issue.record("resolved to \(plan) while something is answering on the sidecar's port")
        }
    }

    // MARK: The genuinely-correct existing behaviour, preserved

    @Test("probe unreachable + stale pidfile -> .notRunning(.stalePidfile) (that message IS right here)")
    func unreachableProbeWithStalePidfileIsNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 31337, pidfilePidAlive: false, port: 8002,
            identity: identity))
        #expect(plan == .notRunning(.stalePidfile(pid: 31337)))
    }

    @Test("probe unreachable + no pidfile -> .notRunning(.noPidfile)")
    func unreachableProbeWithNoPidfileIsNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: nil, pidfilePidAlive: false, port: 8002,
            identity: identity))
        #expect(plan == .notRunning(.noPidfile))
    }

    @Test("""
        live pidfile pid + probe unreachable -> terminate via the pidfile: a sidecar still BOOTING \
        has bound no port yet and must stay stoppable
        """)
    func livePidfileStillWinsWhileBooting() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 77, pidfilePidAlive: true, port: 8002,
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(plan == .terminate(pid: 77, discovery: .pidfile))
    }

    @Test("live pidfile pid whose command line is UNREADABLE fails OPEN — still terminated")
    func unreadableArgsOnThePidfilePathFailsOpen() {
        // Empty snapshot: `ps` gave us nothing, so identity is UNKNOWN. Unknown
        // must not read as "not ours" on the path that has always worked.
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 77, pidfilePidAlive: true, port: 8002,
            snapshot: .init(), selfPid: 500, identity: identity))
        #expect(plan == .terminate(pid: 77, discovery: .pidfile))
    }

    // MARK: Port fallback — the fix

    /// ⭐ THE FIX. Stale pidfile, sidecar answering, and the real process found
    /// by port — which for RVC is the pidfile's own pid, because `run.sh`
    /// `exec`s and there is no supervisor above it to climb to.
    @Test("probe healthy + stale pidfile + the RVC server on the port -> terminate it")
    func portFallbackFindsTheExecdServer() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: 31337, pidfilePidAlive: false,
            port: 8002, portLookup: .listeners([77]),
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(plan == .terminate(pid: 77, discovery: .port(8002)))
    }

    // MARK: Refusals — a pid from a port is not necessarily ours

    /// The `rvcplayer` trap, end to end through the planner: a bare `/rvc/i`
    /// predicate would have resolved this to `.terminate` and killed the user's
    /// unrelated program.
    @Test("an unidentifiable process on the port is REFUSED, never signalled")
    func unidentifiedListenerIsRefused() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .listeners([4343]),
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(plan == .refuse(.listenerNotIdentified(
            port: 8002, pid: 4343, args: "/usr/bin/rvcplayer --input /tmp/take.wav")))
    }

    @Test("a process on the port with NO readable command line is refused (fails CLOSED here)")
    func unreadableArgsOnThePortPathFailsClosed() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .listeners([9999]),
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(plan == .refuse(.listenerNotIdentified(
            port: 8002, pid: 9999, args: "command line unavailable")))
    }

    @Test("THIS process holding the port is refused — stop() may never signal DAW Pro itself")
    func selfOnThePortIsRefused() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .listeners([500]),
            snapshot: FakeRVCProcessTables.rvcTreeUnderSelf, selfPid: 500,
            identity: .rvc(directoryPath: FakeRVCProcessTables.selfHazardDir)))
        #expect(plan == .refuse(.listenerIsThisProcess(port: 8002, pid: 500)))
    }

    @Test("""
        the ancestor climb STOPS at this process — a checkout path under the configured rvc \
        directory must not let the climb walk into DAW Pro
        """)
    func climbNeverWalksIntoThisProcess() {
        let hazard = SidecarStop.Identity.rvc(directoryPath: FakeRVCProcessTables.selfHazardDir)
        // pid 500's own command line contains the configured directory, so the
        // identity predicate alone would happily climb into it.
        #expect(hazard.matches(args: "\(FakeRVCProcessTables.selfHazardDir)/checkout/.build/debug/DAWApp"))
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .listeners([77]),
            snapshot: FakeRVCProcessTables.rvcTreeUnderSelf, selfPid: 500, identity: hazard))
        #expect(plan == .terminate(pid: 77, discovery: .port(8002)))
    }

    @Test("two independent RVC servers on one port -> refuse rather than guess")
    func multipleCandidatesAreRefused() {
        let snapshot = SidecarProcessDiscovery.Snapshot(entries: [
            .init(pid: 77, ppid: 1, args: "/x/.venv/bin/python \(FakeRVCProcessTables.rvcDir)/server.py"),
            .init(pid: 88, ppid: 1, args: "/y/.venv/bin/python \(FakeRVCProcessTables.rvcDir)/server.py"),
        ])
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .listeners([77, 88]),
            snapshot: snapshot, selfPid: 500, identity: identity))
        #expect(plan == .refuse(.multipleCandidates(port: 8002, pids: [77, 88])))
    }

    @Test("port lookup that could not be RUN is refused distinctly from 'nothing is listening'")
    func discoveryUnavailableIsItsOwnRefusal() {
        let unavailable = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .unavailable("lsof is not available"),
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(unavailable == .refuse(.discoveryUnavailable(port: 8002, detail: "lsof is not available")))

        let empty = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false,
            port: 8002, portLookup: .nothingListening,
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(empty == .refuse(.noListenerFound(port: 8002)))
    }

    @Test("a base URL with no derivable port is refused, never silently defaulted to 8002")
    func portUnknownIsRefused() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: nil, pidfilePidAlive: false, port: nil,
            identity: identity))
        #expect(plan == .refuse(.portUnknown))
    }

    // MARK: A live pidfile pointing at a STRANGER (pid reuse)

    @Test("live pidfile pid that is provably NOT ours + probe answering -> falls through to the port")
    func foreignLivePidfileFallsThroughToPortDiscovery() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .healthy, pidfilePid: 4242, pidfilePidAlive: true,
            port: 8002, portLookup: .listeners([77]),
            snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(plan == .terminate(pid: 77, discovery: .port(8002)))
    }

    @Test("live pidfile pid that is provably NOT ours + probe unreachable -> notRunning, nothing signalled")
    func foreignLivePidfileWithNoSidecarIsNotRunning() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 4242, pidfilePidAlive: true,
            port: 8002, snapshot: FakeRVCProcessTables.rvcTree, selfPid: 500, identity: identity))
        #expect(plan == .notRunning(.foreignPidfile(pid: 4242, args: "/usr/sbin/cupsd -l")))
    }

    @Test("a pidfile holding THIS process's own pid is never signalled")
    func pidfilePointingAtSelfIsNeverSignalled() {
        let plan = SidecarStop.resolvePlan(.init(
            probe: .unreachable, pidfilePid: 500, pidfilePidAlive: true,
            port: 8002, snapshot: FakeRVCProcessTables.rvcTreeUnderSelf, selfPid: 500,
            identity: .rvc(directoryPath: FakeRVCProcessTables.selfHazardDir)))
        if case .terminate(let pid, _) = plan {
            Issue.record("resolved to terminate pid \(pid) — that is this very process")
        }
    }
}

@Suite("SidecarStop.reconfirmationRefusal (RVC) — pid reuse between planning and signalling")
struct RVCStopReconfirmationTests {
    private let identity = SidecarStop.Identity.rvc(directoryPath: FakeRVCProcessTables.rvcDir)
    private let liveArgs =
        "\(FakeRVCProcessTables.rvcDir)/runtime/src/.venv/bin/python \(FakeRVCProcessTables.rvcDir)/server.py"

    @Test("a port-discovered target that still identifies is signalled")
    func stillIdentifiedProceeds() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8002), targetPid: 77, targetAliveNow: true,
            argsNow: liveArgs, identity: identity) == nil)
    }

    @Test("a port-discovered target whose command line CHANGED is refused, not killed")
    func recycledPortTargetIsRefused() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8002), targetPid: 77, targetAliveNow: true,
            argsNow: "/usr/sbin/cupsd -l", identity: identity)
            == .listenerNotIdentified(port: 8002, pid: 77, args: "/usr/sbin/cupsd -l"))
    }

    @Test("a port-discovered target that has become unreadable while ALIVE is refused (fails closed)")
    func unreadablePortTargetIsRefused() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8002), targetPid: 77, targetAliveNow: true,
            argsNow: nil, identity: identity)
            == .listenerNotIdentified(port: 8002, pid: 77, args: "command line unavailable"))
    }

    @Test("a target that already exited needs no re-confirmation — there is nothing to signal")
    func deadTargetNeedsNoReconfirmation() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .port(8002), targetPid: 77, targetAliveNow: false,
            argsNow: nil, identity: identity) == nil)
    }

    /// The pidfile path keeps its fail-OPEN rule here too: a sidecar still
    /// booting has bound no port, and must stay stoppable even when `ps` tells
    /// us nothing.
    @Test("the PIDFILE path is never refused by this guard — unknown identity must not block a boot stop")
    func pidfilePathFailsOpen() {
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .pidfile, targetPid: 77, targetAliveNow: true,
            argsNow: nil, identity: identity) == nil)
        #expect(SidecarStop.reconfirmationRefusal(
            discovery: .pidfile, targetPid: 77, targetAliveNow: true,
            argsNow: "/usr/sbin/cupsd -l", identity: identity) == nil)
    }
}

@Suite("RVC stop messages — the honesty rule (m23-bb-1, pure)")
struct RVCStopMessageTests {
    private let baseURL = URL(string: "http://127.0.0.1:8002")!
    private let vocabulary = SidecarStop.Vocabulary.rvc

    private var allRefusals: [SidecarStop.Refusal] {
        [
            .portUnknown,
            .discoveryUnavailable(port: 8002, detail: "lsof is not available"),
            .noListenerFound(port: 8002),
            .listenerIsThisProcess(port: 8002, pid: 500),
            .listenerNotIdentified(port: 8002, pid: 4343, args: "/usr/bin/rvcplayer"),
            .multipleCandidates(port: 8002, pids: [77, 88]),
        ]
    }

    @Test("no refusal message ever claims the RVC sidecar is not running")
    func refusalsNeverClaimNotRunning() {
        for refusal in allRefusals {
            let message = SidecarStop.refusalMessage(
                refusal, vocabulary: vocabulary, baseURL: baseURL,
                pidfilePath: "/repo/scripts/rvc/.rvc.pid")
            #expect(!message.localizedCaseInsensitiveContains("not running"),
                    "refusal \(refusal) emitted a not-running claim: \(message)")
            #expect(message.localizedCaseInsensitiveContains("still up"),
                    "refusal \(refusal) does not say the sidecar is still up: \(message)")
            #expect(message.contains("127.0.0.1:8002"))
        }
    }

    /// The INVERSE half — without it the test above could pass by emitting
    /// nothing at all, and it would stop discriminating if the phrase were
    /// merely reworded rather than the routing fixed.
    @Test("the genuinely-down messages DO say 'not running' — that wording is correct there")
    func notRunningMessagesStillSayIt() {
        #expect(SidecarStop.notRunningMessage(.noPidfile, vocabulary: vocabulary)
            == "RVC voice-conversion sidecar is not running (no pidfile found).")
        #expect(SidecarStop.notRunningMessage(.stalePidfile(pid: 31337), vocabulary: vocabulary)
            == "RVC voice-conversion sidecar was not running (stale pidfile removed).")
        #expect(SidecarStop.notRunningMessage(
            .foreignPidfile(pid: 4242, args: "/usr/sbin/cupsd -l"), vocabulary: vocabulary)
            .localizedCaseInsensitiveContains("not running"))
    }

    @Test("a stop that signalled but left the port answering never claims 'not running' either")
    func stillAnsweringMessagesNeverClaimNotRunning() {
        let outcomes: [SidecarStop.TerminationOutcome] = [
            .init(targetPid: 77, targetSurvived: true),
            .init(targetPid: 77, targetRecycled: true),
            .init(targetPid: 77),
        ]
        for outcome in outcomes {
            let message = SidecarStop.stillAnsweringMessage(
                outcome: outcome, baseURL: baseURL, vocabulary: vocabulary)
            #expect(!message.localizedCaseInsensitiveContains("not running"), "\(message)")
            #expect(message.contains("127.0.0.1:8002"))
        }
        // The three cases are genuinely different stories, not one message.
        #expect(SidecarStop.stillAnsweringMessage(
            outcome: .init(targetPid: 77, targetSurvived: true), baseURL: baseURL,
            vocabulary: vocabulary)
            != SidecarStop.stillAnsweringMessage(
                outcome: .init(targetPid: 77), baseURL: baseURL, vocabulary: vocabulary))
    }

    /// ⚠️ THE COST OF SHARING ONE MESSAGE BUILDER between two sidecars: a
    /// mis-wired `Vocabulary` would have `vc.sidecarStop` telling the user to
    /// go and look at ACE-Step. Every RVC message must name only RVC things.
    @Test("no RVC message ever mentions ACE-Step, and the actionable verb is vc.sidecarStop")
    func rvcMessagesNeverLeakACEWording() {
        var messages: [String] = allRefusals.map {
            SidecarStop.refusalMessage(
                $0, vocabulary: vocabulary, baseURL: baseURL,
                pidfilePath: "/repo/scripts/rvc/.rvc.pid")
        }
        messages += [
            SidecarStop.notRunningMessage(.noPidfile, vocabulary: vocabulary),
            SidecarStop.notRunningMessage(.stalePidfile(pid: 31337), vocabulary: vocabulary),
            SidecarStop.stoppedMessage(
                outcome: .init(targetPid: 77), discovery: .pidfile, vocabulary: vocabulary),
            SidecarStop.stillAnsweringMessage(
                outcome: .init(targetPid: 77), baseURL: baseURL, vocabulary: vocabulary),
        ]
        for message in messages {
            #expect(!message.localizedCaseInsensitiveContains("ace-step"), "\(message)")
            #expect(!message.localizedCaseInsensitiveContains("acestep"), "\(message)")
            #expect(!message.contains("ai.sidecarStop"), "\(message)")
            #expect(message.contains("RVC"), "\(message)")
        }
        // The one message that names a verb names OURS.
        #expect(SidecarStop.stillAnsweringMessage(
            outcome: .init(targetPid: 77), baseURL: baseURL, vocabulary: vocabulary)
            .contains("vc.sidecarStop"))
        // ...and the directory hint names OUR env var.
        #expect(SidecarStop.refusalMessage(
            .listenerIsThisProcess(port: 8002, pid: 500), vocabulary: vocabulary,
            baseURL: baseURL, pidfilePath: nil).contains("DAWPRO_RVC_DIR"))
    }
}

@Suite("VoiceConversionManager.stop() — m23-bb-1 end to end (real probe, real port discovery)")
struct VoiceConversionManagerStopHonestyTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ⭐ The reported scenario, reproduced with a real health responder and
    /// real `lsof`/`ps` discovery — no RVC process anywhere, and no model
    /// loaded.
    ///
    /// The listener the probe answers from IS this test process, so the plan
    /// must resolve to a REFUSAL (we never signal ourselves), `stop()` must
    /// THROW rather than return a success-shaped status, and — because a failed
    /// stop must not quietly delete state — the pidfile must survive.
    @Test("healthy probe + stale pidfile: stop() throws an honest error and removes nothing")
    func healthyProbeWithStalePidfileThrowsInsteadOfLying() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidfile = dir.appendingPathComponent(".rvc.pid")
        try Data("99999".utf8).write(to: pidfile)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".install-state.json"))

        let server = StubHealthServer(responseData: rvcHealthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, rvcDir: dir))

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

        // A refusal changes nothing: the pidfile is still there and the sidecar
        // is (correctly) still reported healthy.
        #expect(FileManager.default.fileExists(atPath: pidfile.path))
        #expect(await manager.status().state == .healthy)
    }

    @Test("healthy probe + NO pidfile: stop() still refuses to report 'not running'")
    func healthyProbeWithNoPidfileThrowsInsteadOfLying() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".install-state.json"))

        let server = StubHealthServer(responseData: rvcHealthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, rvcDir: dir))

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

        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stranger.arguments = ["30"]
        try stranger.run()
        defer { if stranger.isRunning { kill(stranger.processIdentifier, SIGKILL) } }
        let strangerPid = stranger.processIdentifier
        try Data("\(strangerPid)".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))

        let server = StubHealthServer(responseData: rvcHealthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, rvcDir: dir))
        let plan = await manager.resolvedStopPlan()

        // Port discovery MUST have run: the refusal names the listener we know
        // is there, not "nothing is listening".
        #expect(plan == .refuse(.listenerIsThisProcess(
            port: server.port, pid: ProcessInfo.processInfo.processIdentifier)))
        #expect(kill(strangerPid, 0) == 0, "the foreign process named by the pidfile was signalled")

        kill(strangerPid, SIGKILL)
    }

    @Test("dry-run against a healthy probe still never claims 'not running', and signals nothing")
    func dryRunStaysHonestAndInert() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidfile = dir.appendingPathComponent(".rvc.pid")
        try Data("99999".utf8).write(to: pidfile)

        let server = StubHealthServer(responseData: rvcHealthyResponse())
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!, rvcDir: dir, dryRun: true))
        let status = try await manager.stop()

        #expect(status.message.contains("[dry-run]"))
        #expect(!status.message.localizedCaseInsensitiveContains("not running"), "\(status.message)")
        #expect(FileManager.default.fileExists(atPath: pidfile.path), "dry-run removed the pidfile")
    }
}

// MARK: - m23-fo-2: the mitigation hook reaches a real user

/// The seam that makes m23-fo's fix actually ship. m23-fo-1 built the hook and
/// proved it cures the saturation (`scripts/gates/m23fo-conversion-stability.mjs`,
/// leg 1 RED / leg 2 GREEN); until this item nothing in the app set the one
/// environment variable that arms it, so no user reached it.
@Suite("VoiceConversionManager.childEnvironment — PYTHONPATH prepend (m23-fo-2, pure)")
struct VoiceConversionChildEnvironmentTests {
    private typealias Config = VoiceConversionManager.Configuration

    @Test("an inherited PYTHONPATH is PREPENDED to, never clobbered")
    func prependsToInherited() {
        let env = Config.childEnvironment(
            base: ["PYTHONPATH": "/user/one:/user/two"],
            voicesDir: "/voices", mitigationDir: "/hook", outDir: "/out")
        #expect(env["PYTHONPATH"] == "/hook:/user/one:/user/two")
    }

    @Test("ours goes FIRST — sitecustomize must resolve to our file, not one further down")
    func oursIsFirst() {
        let env = Config.childEnvironment(
            base: ["PYTHONPATH": "/someone/elses/sitecustomize/home"],
            voicesDir: "/voices", mitigationDir: "/hook", outDir: "/out")
        #expect(env["PYTHONPATH"]?.hasPrefix("/hook:") == true)
    }

    @Test("no inherited PYTHONPATH -> set to ours alone, with no stray separator")
    func setsWhenAbsent() {
        let env = Config.childEnvironment(
            base: [:], voicesDir: "/voices", mitigationDir: "/hook", outDir: "/out")
        #expect(env["PYTHONPATH"] == "/hook")
    }

    /// PRESENT BUT EMPTY is a different dictionary state from ABSENT, and a
    /// real one (`export PYTHONPATH=` in a shell profile). A naive join would
    /// produce `/hook:` — a trailing empty entry, which Python reads as the
    /// CURRENT DIRECTORY and would silently put the facade's cwd on sys.path.
    @Test("inherited PYTHONPATH of \"\" -> ours alone, never a trailing colon")
    func emptyInheritedProducesNoTrailingColon() {
        let env = Config.childEnvironment(
            base: ["PYTHONPATH": ""], voicesDir: "/voices", mitigationDir: "/hook", outDir: "/out")
        #expect(env["PYTHONPATH"] == "/hook")
        #expect(env["PYTHONPATH"]?.hasSuffix(":") == false)
    }

    @Test("nil mitigationDir leaves an inherited PYTHONPATH EXACTLY as it was")
    func nilMitigationDirLeavesInheritedUntouched() {
        let env = Config.childEnvironment(
            base: ["PYTHONPATH": "/user/one"], voicesDir: "/voices", mitigationDir: nil,
            outDir: "/out")
        #expect(env["PYTHONPATH"] == "/user/one")
    }

    @Test("nil mitigationDir does not INVENT a PYTHONPATH where there was none")
    func nilMitigationDirDoesNotInvent() {
        let env = Config.childEnvironment(
            base: [:], voicesDir: "/voices", mitigationDir: nil, outDir: "/out")
        #expect(env["PYTHONPATH"] == nil)
    }

    @Test("an empty-string mitigationDir is treated as absent, not joined in")
    func emptyMitigationDirIsAbsent() {
        let env = Config.childEnvironment(
            base: ["PYTHONPATH": "/user/one"], voicesDir: "/voices", mitigationDir: "",
            outDir: "/out")
        #expect(env["PYTHONPATH"] == "/user/one")
    }

    @Test("RVC_VOICES_DIR is still set (m23-di-2a must not regress)")
    func stillSetsVoicesDir() {
        let env = Config.childEnvironment(
            base: [:], voicesDir: "/voices/here", mitigationDir: "/hook", outDir: "/out")
        #expect(env["RVC_VOICES_DIR"] == "/voices/here")
    }

    // MARK: - m23-fp: RVC_OUT_DIR

    @Test("RVC_OUT_DIR is set from outDir (m23-fp — the facade stops writing into the fence)")
    func setsOutDir() {
        let env = Config.childEnvironment(
            base: [:], voicesDir: "/voices", mitigationDir: "/hook", outDir: "/app/out")
        #expect(env["RVC_OUT_DIR"] == "/app/out")
    }

    /// `Path("")` is `.` in Python, and the facade `chdir`s to `SRC_DIR` INSIDE
    /// the fence — so setting the variable to an empty string would be strictly
    /// worse than not setting it. Unreachable in practice; pinned so it stays
    /// unreachable.
    @Test("an empty outDir leaves RVC_OUT_DIR ABSENT, never set to \"\"")
    func emptyOutDirLeavesVariableAbsent() {
        let env = Config.childEnvironment(
            base: [:], voicesDir: "/voices", mitigationDir: "/hook", outDir: "")
        #expect(env["RVC_OUT_DIR"] == nil)
    }

    @Test("an inherited RVC_OUT_DIR is REPLACED — ours is authoritative")
    func inheritedOutDirIsReplaced() {
        let env = Config.childEnvironment(
            base: ["RVC_OUT_DIR": "/somewhere/else"], voicesDir: "/voices",
            mitigationDir: "/hook", outDir: "/app/out")
        #expect(env["RVC_OUT_DIR"] == "/app/out")
    }

    /// The whole reason this merges onto the inherited environment instead of
    /// assigning a fresh dictionary: a child with no PATH/HOME is broken in
    /// ways that look nothing like their cause.
    @Test("the rest of the inherited environment survives the merge")
    func preservesTheRestOfTheEnvironment() {
        let env = Config.childEnvironment(
            base: ["PATH": "/usr/bin", "HOME": "/Users/tester", "ANTHROPIC_API_KEY": "sk-x"],
            voicesDir: "/voices", mitigationDir: "/hook", outDir: "/out")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/tester")
        #expect(env["ANTHROPIC_API_KEY"] == "sk-x")
    }
}

/// m23-fp — the gap `childEnvironment` tests alone CANNOT close: the merge rule
/// can be perfect while the spawner arms it with the wrong paths. This is the
/// one expression `spawnAndPoll` now uses, so what these assert is what the
/// facade is actually launched with.
@Suite("VoiceConversionManager.spawnEnvironment — what the spawner really arms (m23-fp)")
struct VoiceConversionSpawnEnvironmentTests {
    private typealias Config = VoiceConversionManager.Configuration

    @Test("RVC_OUT_DIR is armed with VoiceConversionOutput.sidecarOutputDirectory")
    func armsOutDirWithTheAppOwnedPath() {
        let env = Config(rvcDir: URL(fileURLWithPath: "/repo/scripts/rvc"))
            .spawnEnvironment(base: [:])
        #expect(env["RVC_OUT_DIR"] == VoiceConversionOutput.sidecarOutputDirectory.path)
    }

    /// The whole point of the variable. If this ever fails, shipped conversions
    /// are writing wavs inside the read-only checkout again.
    @Test("RVC_OUT_DIR points OUTSIDE the read-only scripts/rvc fence")
    func outDirIsOutsideTheFence() throws {
        let env = Config(rvcDir: URL(fileURLWithPath: "/repo/scripts/rvc"))
            .spawnEnvironment(base: [:])
        let outDir = try #require(env["RVC_OUT_DIR"])
        #expect(!outDir.contains("scripts/rvc"), "\(outDir)")
        #expect(outDir.contains("/DAWPro/VoiceConversions/"), "\(outDir)")
    }

    @Test("RVC_VOICES_DIR and PYTHONPATH are still armed (m23-di-2a / m23-fo-2 must not regress)")
    func stillArmsTheOlderTwo() {
        let env = Config(rvcDir: URL(fileURLWithPath: "/repo/scripts/rvc"))
            .spawnEnvironment(base: ["PYTHONPATH": "/user/one"])
        #expect(env["RVC_VOICES_DIR"] == VoiceModelImport.voicesDirectory.path)
        #expect(env["PYTHONPATH"] == "/repo/scripts/rvc-mitigation:/user/one")
    }

    @Test("the inherited environment still survives (no fresh dictionary)")
    func preservesInherited() {
        let env = Config(rvcDir: URL(fileURLWithPath: "/repo/scripts/rvc"))
            .spawnEnvironment(base: ["PATH": "/usr/bin", "HOME": "/Users/tester"])
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/Users/tester")
    }

    /// `spawnEnvironment` resolves directory URLs; it must not CREATE either of
    /// them (the facade `mkdir`s `RVC_OUT_DIR` itself, and the capture home is
    /// created on first capture). A spawner that mkdirs as a side effect would
    /// leave directories behind on every dry run and every refused launch.
    @Test("computing the environment creates no directories")
    func createsNothing() {
        // Stated as "unchanged", not "absent": this machine may legitimately
        // already have the directory from real use, and an assertion that only
        // holds on a fresh machine is not an assertion.
        let target = VoiceConversionOutput.sidecarOutputDirectory.path
        let existedBefore = FileManager.default.fileExists(atPath: target)
        _ = Config(rvcDir: URL(fileURLWithPath: "/repo/scripts/rvc")).spawnEnvironment(base: [:])
        _ = Config(rvcDir: URL(fileURLWithPath: "/repo/scripts/rvc")).spawnEnvironment(base: [:])
        #expect(FileManager.default.fileExists(atPath: target) == existedBefore)
    }
}

@Suite("VoiceConversionManager.Configuration — mitigation paths (m23-fo-2, pure)")
struct VoiceConversionMitigationPathTests {
    private typealias Config = VoiceConversionManager.Configuration

    @Test("default is the SIBLING of rvcDir, so the two cannot be misconfigured apart")
    func siblingByDefault() {
        let config = Config(rvcDir: URL(fileURLWithPath: "/repo/scripts/rvc"))
        #expect(config.mitigationDirURL?.path == "/repo/scripts/rvc-mitigation")
        #expect(config.mitigationModuleURL?.path == "/repo/scripts/rvc-mitigation/sitecustomize.py")
    }

    @Test("DAWPRO_RVC_MITIGATION_DIR wins over the sibling default")
    func envOverrideWins() {
        let config = Config.resolved(environment: [
            "DAWPRO_RVC_DIR": "/repo/scripts/rvc",
            "DAWPRO_RVC_MITIGATION_DIR": "/elsewhere/hook",
        ])
        #expect(config.mitigationDirURL?.path == "/elsewhere/hook")
    }

    @Test("an EMPTY DAWPRO_RVC_MITIGATION_DIR is ignored, not honoured as a path")
    func emptyOverrideIgnored() {
        let config = Config.resolved(environment: [
            "DAWPRO_RVC_DIR": "/repo/scripts/rvc",
            "DAWPRO_RVC_MITIGATION_DIR": "",
        ])
        #expect(config.mitigationDirURL?.path == "/repo/scripts/rvc-mitigation")
    }

    @Test("nil rvcDir and no override -> nil, exactly like logFileURL")
    func nilWhenUnresolvable() {
        let config = Config(rvcDir: nil)
        #expect(config.mitigationDirURL == nil)
        #expect(config.mitigationModuleURL == nil)
    }

    @Test("the repo's real hook is where the sibling rule says it is")
    func realRepoLayoutSatisfiesTheSiblingRule() throws {
        let rvcDir = try #require(Config.resolveRVCDir(environment: [:]))
        let config = Config(rvcDir: rvcDir)
        let hook = try #require(config.mitigationModuleURL)
        #expect(FileManager.default.fileExists(atPath: hook.path),
                "expected the shipped hook at \(hook.path)")
    }
}

@Suite("VoiceConversionManager — refuses to spawn without the hook (m23-fo-2)")
struct VoiceConversionHookGuardTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvc-hookguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("run.sh present but the hook file missing -> resolveLaunchPlan() throws, naming it")
    func missingHookThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("#!/bin/bash\n".utf8).write(to: dir.appendingPathComponent("run.sh"))
        let emptyHookDir = dir.appendingPathComponent("no-hook-here")
        try FileManager.default.createDirectory(at: emptyHookDir, withIntermediateDirectories: true)

        var config = VoiceConversionManager.Configuration(rvcDir: dir)
        config.mitigationDirOverride = emptyHookDir

        #expect(throws: SidecarError.self) { _ = try config.resolveLaunchPlan() }
        do {
            _ = try config.resolveLaunchPlan()
        } catch let error as SidecarError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("sitecustomize.py"))
            #expect(text.localizedCaseInsensitiveContains("m23-fo"))
            #expect(text.contains(emptyHookDir.path), "the message must name the path it looked at")
        }
    }

    @Test("hook present -> resolveLaunchPlan() succeeds and still plans bash run.sh")
    func hookPresentPlansNormally() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("#!/bin/bash\n".utf8).write(to: dir.appendingPathComponent("run.sh"))
        let hookDir = try makeMitigationDir(in: dir)

        var config = VoiceConversionManager.Configuration(rvcDir: dir)
        config.mitigationDirOverride = hookDir
        let plan = try config.resolveLaunchPlan()

        #expect(plan.executableURL.path == "/bin/bash")
        #expect(plan.arguments == [dir.appendingPathComponent("run.sh").path])
    }

    /// ⭐ `resolveLaunchPlan()` is called at `start()`'s `:196`, BEFORE the
    /// `dryRun` branch — so the DRY RUN THROWS TOO. A dry run that answers
    /// "would launch X" when the real thing would refuse is a lie, and being
    /// believed is the only thing a dry run is for.
    @Test("the DRY-RUN path throws too, rather than describing a launch that would be refused")
    func dryRunAlsoThrows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("#!/bin/bash\n".utf8).write(to: dir.appendingPathComponent("run.sh"))
        let emptyHookDir = dir.appendingPathComponent("no-hook-here")
        try FileManager.default.createDirectory(at: emptyHookDir, withIntermediateDirectories: true)

        let manager = VoiceConversionManager(configuration: rvcConfig(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir,
            mitigationDir: emptyHookDir, dryRun: true))
        do {
            _ = try await manager.start()
            Issue.record("expected the dry run to throw, not to describe a refused launch")
        } catch let error as SidecarError {
            #expect(error.errorDescription?.localizedCaseInsensitiveContains("m23-fo") == true)
        }
    }
}

@Suite("VoiceConversionManager.classifyMitigation — the tri-state (m23-fo-2, pure)")
struct VoiceConversionMitigationClassifierTests {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test("200 + enginePatched true -> TRUE")
    func patchedIsTrue() {
        let result = VoiceConversionManager.classifyMitigation(
            statusCode: 200,
            body: body(#"{"data":{"enginePatched":true,"clearCacheCalls":7},"code":0}"#))
        #expect(result.active == true)
        #expect(result.detail?.contains("7") == true)
    }

    /// ⭐ FALSE PATH 1 — the server answered and the route is not there. This
    /// is the "started by hand, never got our PYTHONPATH" case, and it is a
    /// POSITIVE answer, not an absence of one.
    @Test("404 -> FALSE (an unhooked facade), never nil")
    func notFoundIsFalse() {
        let result = VoiceConversionManager.classifyMitigation(statusCode: 404, body: Data())
        #expect(result.active == false)
        #expect(result.detail?.contains("404") == true)
    }

    /// ⭐ FALSE PATH 2 — the hook IS loaded but its engine patch failed. The
    /// hook is deliberately fail-safe (it never fails the facade's boot), so
    /// this is reachable in production; `gate_m23fo_mechanism.py` phase G
    /// exercises exactly this shape. Reporting `true` here would tell a user
    /// they are protected when they are not.
    @Test("200 + enginePatched FALSE -> FALSE, carrying the hook's own reason")
    func loadedButUnpatchedIsFalse() {
        let result = VoiceConversionManager.classifyMitigation(
            statusCode: 200,
            body: body("""
                {"data":{"enginePatched":false,"error":"mlx.core has no clear_cache"},"code":0}
                """))
        #expect(result.active == false)
        #expect(result.detail?.contains("clear_cache") == true)
    }

    @Test("the two FALSE paths are distinguishable by mitigationDetail")
    func theTwoFalsePathsDiffer() {
        let unhooked = VoiceConversionManager.classifyMitigation(statusCode: 404, body: Data())
        let broken = VoiceConversionManager.classifyMitigation(
            statusCode: 200,
            body: body(#"{"data":{"enginePatched":false,"error":"boom"},"code":0}"#))
        #expect(unhooked.active == false)
        #expect(broken.active == false)
        #expect(unhooked.detail != broken.detail)
    }

    @Test("no response at all (timeout / transport error) -> NIL, never false")
    func unreachableIsNil() {
        let result = VoiceConversionManager.classifyMitigation(statusCode: nil, body: nil)
        #expect(result.active == nil)
        #expect(result.detail != nil, "nil must still explain itself")
    }

    @Test("a non-404 error status -> NIL (we did not find out)")
    func serverErrorIsNil() {
        let result = VoiceConversionManager.classifyMitigation(statusCode: 500, body: Data())
        #expect(result.active == nil)
    }

    @Test("200 with an unparseable body -> NIL")
    func unparseableIsNil() {
        let result = VoiceConversionManager.classifyMitigation(
            statusCode: 200, body: body("not json at all"))
        #expect(result.active == nil)
    }

    /// ABSENT is not FALSE. Something else answering this path is not our
    /// route reporting a failed patch, and guessing `false` would put an
    /// accusatory warning in `message` on the strength of an assumption.
    @Test("200 in the right envelope but WITHOUT enginePatched -> NIL, not false")
    func missingFieldIsNil() {
        let result = VoiceConversionManager.classifyMitigation(
            statusCode: 200, body: body(#"{"data":{"service":"something-else"},"code":0}"#))
        #expect(result.active == nil)
    }

    @Test("only a KNOWN-unprotected facade gets the warning message, and it names m23-fo")
    func warningOnlyWhenKnownFalse() {
        let warned = VoiceConversionManager.healthyMessage(mitigationActive: false)
        #expect(warned.localizedCaseInsensitiveContains("m23-fo"))
        #expect(warned.localizedCaseInsensitiveContains("vc.sidecarStart"),
                "the message must say what to DO, per the design language")
        #expect(!VoiceConversionManager.healthyMessage(mitigationActive: true)
            .localizedCaseInsensitiveContains("m23-fo"))
        // nil says nothing: we did not find out, and a warning invented from
        // ignorance is its own dishonesty.
        #expect(!VoiceConversionManager.healthyMessage(mitigationActive: nil)
            .localizedCaseInsensitiveContains("m23-fo"))
    }
}

@Suite("VoiceConversionManager.status() — threads the tri-state onto the wire (m23-fo-2)")
struct VoiceConversionMitigationStatusTests {
    private func baseURL(port: UInt16) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    @Test("a hooked facade -> healthy, mitigationActive true, no warning in the message")
    func hookedFacadeReportsTrue() async throws {
        let server = StubHealthServer(responseData: Data(), routes: [
            "/health": rvcHealthyResponse(),
            "/v1/_dawpro/mitigation": StubHealthServer.mitigationResponse(clearCacheCalls: 12),
        ])
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: server.port), rvcDir: nil))
        let status = await manager.status()

        #expect(status.state == .healthy)
        #expect(status.mitigationActive == true)
        #expect(status.mitigationDetail?.contains("12") == true)
        #expect(!status.message.localizedCaseInsensitiveContains("m23-fo"))
    }

    /// ⭐ THE HOLE THIS CLOSES: `start()` returns early when the sidecar is
    /// already healthy, so an app attaching to a hand-started `run.sh` never
    /// sets PYTHONPATH — and this message is the user's ONLY signal.
    @Test("an UNHOOKED facade (404) -> mitigationActive FALSE and the message says so")
    func unhookedFacadeReportsFalseAndWarns() async throws {
        let server = StubHealthServer(responseData: Data(), routes: [
            "/health": rvcHealthyResponse(),
            // no mitigation route at all -> the stub 404s it
        ])
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: server.port), rvcDir: nil))
        let status = await manager.status()

        #expect(status.state == .healthy, "an unhooked sidecar is still a RUNNING sidecar")
        #expect(status.mitigationActive == false, "404 is a POSITIVE answer, not nil")
        #expect(status.message.localizedCaseInsensitiveContains("m23-fo"))
    }

    @Test("a hook whose engine patch failed -> FALSE and warned, even though it answers 200")
    func brokenHookReportsFalse() async throws {
        let server = StubHealthServer(responseData: Data(), routes: [
            "/health": rvcHealthyResponse(),
            "/v1/_dawpro/mitigation": StubHealthServer.mitigationResponse(
                enginePatched: false, error: "mlx.core has no clear_cache in version None"),
        ])
        try server.start()
        defer { server.stop() }

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: server.port), rvcDir: nil))
        let status = await manager.status()

        #expect(status.mitigationActive == false)
        #expect(status.mitigationDetail?.contains("clear_cache") == true)
        #expect(status.message.localizedCaseInsensitiveContains("m23-fo"))
    }

    /// A facade that ACCEPTS the mitigation request and never answers.
    private func hungMitigationServer() throws -> StubHealthServer {
        let server = StubHealthServer(
            responseData: Data(),
            routes: ["/health": rvcHealthyResponse()],
            stallPaths: ["/v1/_dawpro/mitigation"])
        try server.start()
        return server
    }

    private func statusCost(port: UInt16, timeout: Double) async
        -> (status: VoiceConversionStatus, elapsed: Double) {
        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: port), rvcDir: nil,
            healthProbeTimeoutSeconds: timeout))
        let started = DispatchTime.now()
        let status = await manager.status()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds
            - started.uptimeNanoseconds) / 1_000_000_000
        return (status, elapsed)
    }

    /// ⭐ THE BRANCH THE OTHER TESTS CANNOT REACH. Every `nil` above arrives by
    /// connection-REFUSED — an instant transport error. This one arrives by
    /// TIMEOUT, which is the case the `nil` arm's doc comment actually claims
    /// to handle. Three claims, in descending order of how firmly this test
    /// can hold them:
    ///
    /// 1. HONESTY (deterministic). A hung probe is IGNORANCE: `nil`, no
    ///    verdict, no warning. A `false` here would accuse a facade that may
    ///    well be hooked, and the accusation is user-visible text.
    /// 2. NOT-A-DEMOTION (deterministic). A hung SIDE probe must not turn a
    ///    healthy sidecar into an unhealthy one. Asserted explicitly, because
    ///    `mitigationActive == nil` is ALSO what every non-healthy status
    ///    returns — without the `.healthy` check, claim 1 would pass
    ///    vacuously on a status that never reached the mitigation probe.
    /// 3. BOUNDEDNESS (loose, on purpose). `status()` gained a second round
    ///    trip, so a hang is the one case that can add latency. The ceiling
    ///    below catches the regression that actually matters — a probe with NO
    ///    bound, i.e. URLSession's ~60 s default — and nothing finer.
    ///
    /// ⚠️ WHY NOTHING FINER: two tighter spellings were written, measured, and
    /// REMOVED. (a) `elapsed < 2.5 × timeout` passed at 1.05 s in isolation and
    /// FAILED at 3.35 s in the full suite. (b) A two-budget differential
    /// (0.5 s vs 3.0 s, expecting ≈2.5 s of separation) passed in isolation
    /// with delta ≈ 2.5 s and failed in the full suite with delta **−0.44 s** —
    /// the 0.5 s-budget probe took ~3.5 s while the 3.0 s one took ~3.06 s.
    /// Under 545 parallel suites, wall clock here measures the scheduler, not
    /// our code, and the noise does not cancel. The precise claim "the budget
    /// we configure is the budget the request gets" is therefore verified
    /// MANUALLY (isolated run: 1.05 s for a 1.0 s budget; hardcoding the
    /// interval to 5.0 s collapsed the differential to −0.02 s) and is NOT
    /// asserted here. Do not re-tighten this without re-measuring under load.
    @Test("a HUNG mitigation route -> still healthy, nil (never a positive false), bounded")
    func hungMitigationRouteStaysNil() async throws {
        let server = try hungMitigationServer()
        defer { server.stop() }

        let (status, elapsed) = await statusCost(port: server.port, timeout: 1.0)

        #expect(status.state == .healthy, "a hung SIDE probe must not demote the sidecar")
        #expect(status.mitigationActive == nil, "a hang is ignorance, never a positive FALSE")
        let detail = try #require(status.mitigationDetail)
        #expect(detail.localizedCaseInsensitiveContains("did not complete"),
                "the detail must NAME the unknown, not leave it blank: \(detail)")
        #expect(!detail.contains("404") && !detail.contains("no m23-fo mitigation hook"),
                "a hang must not borrow the 404 branch's accusation: \(detail)")
        #expect(!status.message.localizedCaseInsensitiveContains("m23-fo"),
                "no warning may be invented from a probe that never answered")
        #expect(elapsed < 30,
                "a hung mitigation probe ran \(elapsed)s against a 1s budget — unbounded?")
    }

    @Test("the fields are ADDITIVE — a non-healthy status leaves them nil, no wire change")
    func nonHealthyLeavesFieldsNil() async throws {
        let unusedPort = try StubHealthServer.unusedLoopbackPort()
        let manager = VoiceConversionManager(configuration: .init(
            baseURL: baseURL(port: unusedPort), rvcDir: nil))
        let status = await manager.status()

        #expect(status.state != .healthy)
        #expect(status.mitigationActive == nil)
        #expect(status.mitigationDetail == nil)
    }

    @Test("the new fields survive a Codable round trip (they reach MCP verbatim)")
    func codableRoundTrip() throws {
        let original = VoiceConversionStatus(
            state: .healthy, message: "m", mitigationActive: false,
            mitigationDetail: "unhooked")
        let decoded = try JSONDecoder().decode(
            VoiceConversionStatus.self, from: JSONEncoder().encode(original))
        #expect(decoded.mitigationActive == false)
        #expect(decoded.mitigationDetail == "unhooked")
        #expect(decoded == original)
    }
}
