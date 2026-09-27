import Foundation
import Testing
@testable import AIServices

/// `SingingSidecarManager` coverage (item p2-sing-c), against the REAL `scripts/sing/run.sh` with
/// `SING_USE_STUB=1` (so it execs `stub_server.py`, never the real engine and never the network),
/// on an ephemeral TEST port, per the gate design §9 names: "spawn, health, the three stop limbs,
/// a stale pidfile, the port-busy refusal, a yield classified as a yield, and a watchdog kill
/// (512 MB cap, 600 MB balloon)".
///
/// Reuses `StubACEStepServer.unusedLoopbackPort()` (`ACEStepClientTests.swift`) rather than adding
/// a fourth private copy of that helper — it does nothing ACE-Step-specific, same as
/// `VoiceConversionClientTests` already reusing it.
///
/// `scriptsDir` is resolved ONCE against the real checkout via
/// `SingingSidecarManager.Configuration.resolveScriptsDir` (this file never writes into
/// `scripts/sing/` — read-only, as required). `runtimeDir` is a FRESH temp directory per test, so
/// no two tests can share a pidfile or an install marker.
private func testScriptsDir() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    return try #require(
        SingingSidecarManager.Configuration.resolveScriptsDir(environment: environment),
        "scripts/sing could not be resolved from this test process — run from inside the daw-pro checkout")
}

private func makeTempRuntimeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sing-manager-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A short-lived helper process, waited-out synchronously (near-instant: `/usr/bin/true` exits
/// immediately) — for tests that need a pid PROVABLY dead before the manager ever looks at it.
private func spawnAndWaitForExit() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

private func testConfiguration(
    port: UInt16, runtimeDir: URL, scriptsDir: URL, extraEnvironment: [String: String] = [:]
) -> SingingSidecarManager.Configuration {
    var config = SingingSidecarManager.Configuration(
        baseURL: URL(string: "http://127.0.0.1:\(port)")!,
        scriptsDir: scriptsDir, runtimeDir: runtimeDir,
        startupTimeoutSeconds: 15, healthPollIntervalSeconds: 0.1, healthProbeTimeoutSeconds: 2,
        stopTimeoutSeconds: 5)
    config.testExtraEnvironment = ["SING_USE_STUB": "1", "SING_TEST_HOOKS": "1"]
        .merging(extraEnvironment) { _, new in new }
    return config
}

/// A minimal but structurally valid phrase, the voice id the stub itself registers
/// (`stub_server.py`'s `_write_placeholder_voice` writes `builtin-1`) — reused from the render
/// client's own test file's shape, restated here since these are two different test targets'
/// files and Swift Testing has no shared-fixture import convention in this codebase (the
/// `StubACEStepServer`/`unusedLoopbackPort` precedent is reuse-by-visibility, not by design, and
/// this helper is much smaller than that server).
private func onePhraseRequest(outputPath: String) -> SingingPhraseRequest {
    SingingPhraseRequest(
        voice: .builtin(id: "builtin-1"),
        notes: [SingingPhraseNote(startS: 0.0, endS: 0.5, midi: 60)],
        words: [SingingPhraseWord(text: "la", noteIndices: [0])],
        leadS: 0.1, trailS: 0.1, seed: 7, nSteps: 4, cfg: 1.5,
        outputPath: outputPath, outputSampleRate: 24000)
}

// MARK: - Spawn + health

@Suite("SingingSidecarManager — spawn + health, against the real stub (item p2-sing-c)")
struct SingingSidecarManagerSpawnTests {
    @Test("start() reaches .healthy; status() agrees; pid is set and alive")
    func spawnReachesHealthy() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        let manager = SingingSidecarManager(
            configuration: testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        do {
            let started = try await manager.start()
            #expect(started.state == .healthy)
            let pid = try #require(started.pid)
            #expect(kill(pid, 0) == 0, "the reported pid must actually be alive")

            let polled = await manager.status()
            #expect(polled.state == .healthy)
            #expect(polled.pid == pid)
            #expect(polled.facadeVersion != nil, "a healthy stub reports the facade's own health fields")

            try await manager.stop()
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }

    @Test("start() while already healthy is a no-op that returns the same healthy status")
    func startWhileAlreadyHealthyIsANoOp() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        let manager = SingingSidecarManager(
            configuration: testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        do {
            let first = try await manager.start()
            let second = try await manager.start()
            #expect(first.pid == second.pid, "a second start() must not spawn a new process")
            try await manager.stop()
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }
}

// MARK: - Stop: the three limbs, and stop() vs evictWithoutCoordinator() classification

@Suite("SingingSidecarManager — stop, the three evidence limbs (item p2-sing-c)")
struct SingingSidecarManagerStopTests {
    @Test("evictWithoutCoordinator() against a real spawned stub satisfies all three ModelStopEvidence limbs")
    func evictionSatisfiesAllThreeLimbs() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        let manager = SingingSidecarManager(
            configuration: testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        do {
            let started = try await manager.start()
            let pid = try #require(started.pid)
            // Positive control on the SAME probe the limb below relies on: prove `kill(pid, 0)`
            // reads ALIVE before asserting it reads DEAD after.
            #expect(kill(pid, 0) == 0, "sanity: the spawned pid answers alive before eviction")

            let evidence = try await manager.evictWithoutCoordinator()

            #expect(evidence.portFree, "limb 1 (port): \(evidence.portLookupDetail ?? "no detail")")
            #expect(evidence.probeUnreachable, "limb 2 (health probe)")
            #expect(evidence.treePidsAliveAfter.isEmpty, "limb 3 (tree pids): \(evidence.treePidsAliveAfter)")
            #expect(evidence.stopped, "all three limbs together")
            #expect(kill(pid, 0) != 0, "the spawned pid must actually be dead, not just reported so")
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }

    @Test("stop() classifies as .explicit")
    func explicitStopClassifiesAsExplicit() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        let manager = SingingSidecarManager(
            configuration: testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        do {
            _ = try await manager.start()
            try await manager.stop()
            let classification = await manager.lastStopClassification()
            #expect(classification == .explicit)
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }

    @Test("evictWithoutCoordinator() classifies as .evictedByCoordinator — the yield, classified as a yield")
    func evictionClassifiesAsEvictedByCoordinator() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        let manager = SingingSidecarManager(
            configuration: testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        do {
            _ = try await manager.start()
            let evidence = try await manager.evictWithoutCoordinator()
            #expect(evidence.stopped)
            let classification = await manager.lastStopClassification()
            #expect(classification == .evictedByCoordinator, "got \(String(describing: classification))")
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }

    @Test("a fresh manager that has done nothing reports no classification at all (nil, not a guess)")
    func neverStartedHasNoClassification() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        let manager = SingingSidecarManager(
            configuration: testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        let classification = await manager.lastStopClassification()
        #expect(classification == nil)
    }
}

// MARK: - Stale pidfile

@Suite("SingingSidecarManager — a stale pidfile does not block start() (item p2-sing-c)")
struct SingingSidecarManagerStalePidfileTests {
    @Test("a pidfile naming a PROVABLY DEAD pid is cleared by run.sh, and start() still reaches .healthy")
    func stalePidfileIsClearedAndStartSucceeds() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runDir = dir.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let deadPid = try spawnAndWaitForExit()
        #expect(kill(deadPid, 0) != 0, "sanity: the helper process is really gone before the real test")
        try Data("\(deadPid)\n".utf8).write(to: runDir.appendingPathComponent("sing.pid"))

        let port = try StubACEStepServer.unusedLoopbackPort()
        let manager = SingingSidecarManager(
            configuration: testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        do {
            let started = try await manager.start()
            #expect(started.state == .healthy)
            #expect(started.pid != deadPid, "the NEW process must have its own pid, not the stale one")
            try await manager.stop()
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }
}

// MARK: - Port-busy refusal

@Suite("SingingSidecarManager — start() refuses a foreign port (item p2-sing-c)")
struct SingingSidecarManagerPortBusyTests {
    @Test("start() throws SidecarError.launchFailed when something else already holds the target port")
    func startRefusesWhenPortIsForeign() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stranger = StubACEStepServer()
        try stranger.start()
        defer { stranger.stop() }

        let manager = SingingSidecarManager(
            configuration: testConfiguration(
                port: stranger.port, runtimeDir: dir, scriptsDir: try testScriptsDir()))
        do {
            _ = try await manager.start()
            Issue.record("expected start() to throw")
        } catch let error as SidecarError {
            guard case .launchFailed(let message) = error else {
                Issue.record("expected .launchFailed, got \(error)")
                return
            }
            #expect(message.contains("already in use"))
        }
        // Nothing was ever spawned by the manager on this path -- `stranger`'s own `defer` is the
        // only cleanup needed; asserting that explicitly here would just restate `defer`'s job.
    }
}

// MARK: - Watchdog kill

@Suite("SingingSidecarManager — the runaway watchdog (item p2-sing-c, design §2.6/§9's gate)")
struct SingingSidecarManagerWatchdogTests {
    @Test("a 512 MB cap against the stub's 600 MB balloon fault kills the tree; classified .watchdog; pid actually dead")
    func watchdogKillsOverCap() async throws {
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        var config = testConfiguration(
            port: port, runtimeDir: dir, scriptsDir: try testScriptsDir(),
            extraEnvironment: ["SING_STUB_FAULT": "balloon"])
        // 512 MB, per the design's own gate text — the stub balloons to 600 MB (in 64 MiB steps
        // every 50 ms, `stub_server.py`'s own doc comment), so this cap is crossed in well under
        // 1 s of a render call landing. `SING_STUB_BALLOON_HOLD_S` is left at its 60 s default on
        // purpose: the watchdog kills the tree long before the hold would ever finish, so the
        // hold's own length is not this test's clock.
        config.watchdogCapBytes = 512 * 1_048_576
        config.watchdogPollIntervalSeconds = 0.1

        let manager = SingingSidecarManager(configuration: config)
        do {
            let started = try await manager.start()
            let pid = try #require(started.pid)

            // The balloon only grows on a RENDER call, never at boot (SB's measured finding,
            // confirmed again directly against `stub_server.py`'s source here) -- `builtin-1` is
            // the placeholder voice id the stub itself registers, and `run/stub-voices` is an
            // ALWAYS-allowed root regardless of SING_ALLOWED_ROOTS (`stub_server.py`'s own
            // `roots_from_env(..., always=[voices_dir])`), so this request needs no extra
            // allowed-roots configuration to reach validation.
            let outputPath = dir.appendingPathComponent("run/stub-voices/watchdog-out.wav").path
            let client = SingingSynthesisClient(baseURL: config.baseURL, timeoutSeconds: 30)
            do {
                _ = try await client.renderPhrase(onePhraseRequest(outputPath: outputPath))
                // Not itself a failure: it would mean the render completed before the watchdog
                // fired, and the assertions below are what actually decide this test.
            } catch {
                // EXPECTED, ordinarily: the tree is SIGKILLed mid-response, so the render's own
                // HTTP call dies too -- that is the watchdog working, not a test bug.
            }

            let deadline = Date().addingTimeInterval(20)
            var classification: SingingStopReason?
            while Date() < deadline {
                classification = await manager.lastStopClassification()
                if classification != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .watchdog(let detail)? = classification else {
                Issue.record("expected .watchdog(detail:), got \(String(describing: classification))")
                _ = try? await manager.stop()
                return
            }
            #expect(detail.localizedCaseInsensitiveContains("cap"), "got: \(detail)")
            #expect(detail.localizedCaseInsensitiveContains("footprint"), "got: \(detail)")
            #expect(kill(pid, 0) != 0, "the tree must actually be dead, not just classified as killed")
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }

    @Test("an injected footprint sampler under the cap never kills — the pure decide() loop, exercised end to end")
    func underCapNeverKills() async throws {
        // Deliberately does NOT use the real stub's balloon at all: an injected sampler that
        // always reports a small, constant footprint proves the watchdog's LOOP (arm, sample,
        // sleep, re-sample) runs and stays quiet, independent of whatever the real facade's RSS
        // happens to be on this machine. `Configuration.watchdogSampleFootprintBytes` is exactly
        // the seam the design's gate names as INJECTABLE for this reason.
        let dir = try makeTempRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let port = try StubACEStepServer.unusedLoopbackPort()
        var config = testConfiguration(port: port, runtimeDir: dir, scriptsDir: try testScriptsDir())
        config.watchdogCapBytes = 512 * 1_048_576
        config.watchdogPollIntervalSeconds = 0.05
        config.watchdogSampleFootprintBytes = { _ in 10 * 1_048_576 }   // constant 10 MB, well under cap

        let manager = SingingSidecarManager(configuration: config)
        do {
            _ = try await manager.start()
            // Long enough for several samples at the 50 ms poll interval -- proof the loop ran,
            // not just that nothing happened because nothing looked.
            try await Task.sleep(nanoseconds: 600_000_000)
            let classification = await manager.lastStopClassification()
            #expect(classification == nil, "an under-cap footprint must never classify a kill")
            let status = await manager.status()
            #expect(status.state == .healthy, "the sidecar must still be up")
            try await manager.stop()
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }
}
