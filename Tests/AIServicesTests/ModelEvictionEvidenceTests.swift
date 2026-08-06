import Darwin
import Foundation
import Testing

@testable import AIServices

/// THE POSITIVE CONTROL FOR "UNLOADED" — m23-dl §7.3.
///
/// The roadmap's own warning for this item is that `kill -0` succeeds on a
/// zombie and `ps` reports ~1 GB for a ~75 GB hold, so *"it unloaded"* must be an
/// **observation**, and the check must be shown to be capable of **failing**. A
/// verification that has only ever been run against an already-stopped process
/// proves nothing.
///
/// So this suite stands a real process up on an ephemeral port, answers
/// ACE-Step's own `/health` envelope from it, and runs the SAME evidence
/// gatherer that judges a real eviction — first while the helper is **alive**
/// (it must say FAILED) and then after the real `SidecarStop` path has taken it
/// down (it must say stopped).
///
/// ⚠️⚠️ **ACE-STEP IS NEVER STARTED.** The helper is `python3 -m http.server`
/// serving a file called `health`; the port is ephemeral and is never
/// 8001/8002/17600. Nothing here loads a model, and the ~80 GB sidecar is not
/// touched.
///
/// The design's version of this test also has the helper hold 2 GiB. That is
/// **dropped**: step 5 of §7.3 forbids asserting any threshold on the memory
/// figures (they are corroboration, never authority — asserting them is how a
/// suite starts failing because somebody opened Chrome), so the allocation would
/// cost 2 GiB of the developer's machine to feed an assertion that is not
/// allowed to exist.
@Suite(
    "Eviction evidence — real process, positive control (m23-dl §7.3)",
    .serialized, .timeLimit(.minutes(1)))
struct ModelEvictionEvidenceTests {

    /// Both helpers must exist or the suite is skipped rather than failing for a
    /// reason that has nothing to do with the code under test.
    static var toolingAvailable: Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
        else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Builds a throwaway sidecar directory whose `run.sh` stands up an HTTP
    /// responder on `port`, in the SAME parent→child topology ACE-Step has
    /// (`/bin/bash run.sh` → a python child that actually holds the socket).
    /// That topology is the point: the pidfile records the bash parent, and the
    /// child is what must also be accounted for.
    static func makeHelperDirectory(port: UInt16) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23dl-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // ACE-Step's real `/health` envelope shape, so the manager's own
        // unmodified probe parses it.
        try Data("""
            {"data":{"status":"ok","service":"ACE-Step API","version":"test", \
            "models_initialized":true,"llm_initialized":true, \
            "loaded_model":"stub-dit","loaded_lm_model":"stub-lm"},"code":200,"error":null}
            """.utf8).write(to: directory.appendingPathComponent("health"))

        // NOT `exec`: bash must survive as the parent so the process tree has a
        // real descendant to capture. `--directory` keeps the child's command
        // line naming our directory, so the identity predicate matches it too.
        try Data("""
            #!/bin/bash
            /usr/bin/python3 -m http.server \(port) --bind 127.0.0.1 \
            --directory "\(directory.path)" >/dev/null 2>&1 &
            wait

            """.utf8).write(to: directory.appendingPathComponent("run.sh"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent(".install-state.json"))
        return directory
    }

    static func kill(tree pids: [Int32]) {
        // Pid-exact only, never `pkill`/`killall`.
        for pid in pids where pid > 1 { _ = Darwin.kill(pid, SIGKILL) }
    }

    @Test(
        "A live responder FAILS the check; the real stop path then passes it",
        .enabled(if: ModelEvictionEvidenceTests.toolingAvailable))
    func evictionEvidenceCanFailAndCanPass() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        #expect(port != 8001 && port != 8002 && port != 17600,
                "the ephemeral port must never collide with a real sidecar or the control port")
        let directory = try Self.makeHelperDirectory(port: port)
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let manager = SidecarManager(configuration: .init(
            baseURL: baseURL,
            acestepDir: directory,
            logFileURL: directory.appendingPathComponent("helper.log"),
            startupTimeoutSeconds: 20,
            healthPollIntervalSeconds: 0.25,
            healthProbeTimeoutSeconds: 2,
            stopTimeoutSeconds: 5))

        var spawnedPids: [Int32] = []
        defer { Self.kill(tree: spawnedPids) }

        // Stand it up through the manager's own unmodified `start()`.
        let started = try await manager.start()
        #expect(started.state == .healthy || started.state == .starting)

        var healthy = false
        for _ in 0..<40 where !healthy {
            if await manager.status().state == .healthy { healthy = true; break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try #require(healthy, "the stub responder never became healthy on port \(port)")

        // Resolve the real tree: the bash parent from the pidfile, plus the
        // python child that actually holds the socket.
        let pidfile = directory.appendingPathComponent(".ace-step.pid")
        let parentPid = try #require(
            Int32((try String(contentsOf: pidfile, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        let snapshot = SidecarProcessDiscovery.captureSnapshot()
        let descendants = snapshot.descendants(of: parentPid).map(\.pid)
        spawnedPids = [parentPid] + descendants
        #expect(!descendants.isEmpty,
                "the fixture must reproduce the parent→child topology; got none")

        // ⭐⭐ STEP 2 — THE POSITIVE CONTROL. The verification is run against a
        // process that is demonstrably up, and it MUST report failure. Without
        // this, every "it unloaded" assertion in the item is vacuous.
        let live = ModelStopEvidence.gather(
            baseURL: baseURL, probeAnswering: true,
            capturedTreePids: spawnedPids, detail: "nothing was stopped")
        #expect(live.portFree == false, "lsof must see the listener that is demonstrably there")
        #expect(live.probeUnreachable == false)
        #expect(!live.treePidsAliveAfter.isEmpty)
        #expect(live.stopped == false, "THE POSITIVE CONTROL: the check must be able to fail")
        // And the port it is talking about is the one we bound.
        #expect(SidecarProcessDiscovery.port(of: baseURL) == port)

        // STEP 3-4 — stop it through the REAL `SidecarStop` path, via the
        // `ModelEvicting` conformance the coordinator will use.
        let evidence = try await manager.evictWithoutCoordinator()
        #expect(evidence.portFree, "port \(port) is still held: \(evidence.portLookupDetail ?? "")")
        #expect(evidence.probeUnreachable)
        #expect(evidence.treePidsAliveAfter.isEmpty,
                "pids still alive from the PRE-KILL captured tree: \(evidence.treePidsAliveAfter)")
        #expect(evidence.stopped)
        // The captured tree really did include the child — otherwise the limb
        // above passed by looking at nothing.
        for pid in spawnedPids {
            #expect(Darwin.kill(pid, 0) != 0, "pid \(pid) survived the stop")
        }
    }

    @Test(
        "The coordinator's report carries the evidence AND bumps the nonce",
        .enabled(if: ModelEvictionEvidenceTests.toolingAvailable))
    func coordinatorReportsRealEvictionEvidence() async throws {
        let port = try StubHealthServer.unusedLoopbackPort()
        let directory = try Self.makeHelperDirectory(port: port)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let manager = SidecarManager(configuration: .init(
            baseURL: baseURL, acestepDir: directory,
            logFileURL: directory.appendingPathComponent("helper.log"),
            startupTimeoutSeconds: 20, healthPollIntervalSeconds: 0.25,
            healthProbeTimeoutSeconds: 2, stopTimeoutSeconds: 5))

        var spawnedPids: [Int32] = []
        defer { Self.kill(tree: spawnedPids) }
        _ = try await manager.start()
        var healthy = false
        for _ in 0..<40 where !healthy {
            if await manager.status().state == .healthy { healthy = true; break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try #require(healthy)
        let pidfile = directory.appendingPathComponent(".ace-step.pid")
        if let parent = Int32((try String(contentsOf: pidfile, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)) {
            spawnedPids = [parent]
                + SidecarProcessDiscovery.captureSnapshot().descendants(of: parent).map(\.pid)
        }

        // ⚠️ The MEMORY sampler stays stubbed even here. The eviction is real,
        // but §4.4 makes the memory figures corroboration that may never fail a
        // verb, so a real sampler would buy nothing and would make the admission
        // step depend on the developer's open applications (F2).
        let machine = MachineStub(availableGiB: 110, at: Date(timeIntervalSince1970: 1_770_000_000))
        let coordinator = ModelLifecycleCoordinator(
            sampleMemory: { machine.snapshot }, now: { machine.now },
            storageDirectory: storage, settleSeconds: 0)
        let descriptor = ModelDescriptor(
            id: .aceStep, displayName: "ACE-Step song generation", baseURL: baseURL,
            seededHoldBytes: 34 << 30, seededHoldProvenance: "measured in a test",
            estimatedHoldBytes: 34 << 30, estimatedHoldProvenance: "estimated in a test")
        await coordinator.register(descriptor, evictor: manager)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        machine.setAvailable(giB: 70)
        await coordinator.admitted(ticket, healthy: true)
        machine.setAvailable(giB: 110)

        let report = await coordinator.unload(.aceStep, reason: .explicit)
        #expect(report.stopped)
        #expect(report.evidence.portFree)
        #expect(report.evidence.probeUnreachable)
        #expect(report.evidence.treePidsAliveAfter.isEmpty)
        // Step 5: PRESENT and finite; NO threshold is asserted.
        #expect(report.evidence.expectedHoldBytes == 40 << 30)
        #expect([MemoryVerdict.returned, .partial, .inconclusive, .notAHold]
            .contains(report.evidence.memoryVerdict))
        // Step 6.
        #expect(report.evidence.generationAfter > report.evidence.generationBefore)
        #expect(await coordinator.residency().models
            .first { $0.modelID == .aceStep }?.resident == false)
    }
}
