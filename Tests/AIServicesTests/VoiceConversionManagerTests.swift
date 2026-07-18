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

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir, dryRun: true))
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
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            rvcDir: dir, startupTimeoutSeconds: 0.3, healthPollIntervalSeconds: 0.1))
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
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        try Data("\(child.processIdentifier)".utf8).write(to: dir.appendingPathComponent(".rvc.pid"))

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, rvcDir: dir, stopTimeoutSeconds: 2))
        let status = try await manager.stop()

        #expect(status.state == .installedNotRunning)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".rvc.pid").path))
        #expect(!child.isRunning)
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
        let unusedPort = try StubHealthServer.unusedLoopbackPort()

        let manager = VoiceConversionManager(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(unusedPort)")!,
            rvcDir: dir,
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
