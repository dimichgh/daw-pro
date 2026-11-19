import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

/// p2-sing-e part 1: ONE full render → land → undo through the REAL pieces: `SingingSidecarManager` running
/// `scripts/sing/run.sh` with `SING_USE_STUB=1` (the stub facade, never the real engine, never the network)
/// on an ephemeral TEST port, and `SingingSynthesisClient` posting to it.
///
/// ⚠️ The shape the singing-sidecar tests learned to keep (W7-SC, Batch A): ONE manager in this test, no
/// eviction, and no side task polling the manager. The coordinator is the only caller; the test polls the
/// coordinator. The lifecycle coordinator is this test's own (temp storage, never `.shared`), and the
/// sidecar's log goes to the test's temp folder, not `~/Library/Logs`.
@Suite("SingJob — render, land and undo through the real stub sidecar (p2-sing-e)")
struct SingJobStubSidecarTests {

    @Test("the stub sings both lines over HTTP; the take passes the gates, lands as one track, and undoes")
    func stubRenderLandUndo() async throws {
        let root = try SingFixture.tempDir("stub")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let voices = root.appendingPathComponent("voices", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        for dir in [runtime, voices, cacheDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // An install marker with no lock hash: "installed", never "needs an update".
        try Data("{}".utf8).write(to: runtime.appendingPathComponent("install.json"))
        let scripts = try #require(
            SingingSidecarManager.Configuration.resolveScriptsDir(environment: ProcessInfo.processInfo.environment),
            "scripts/sing could not be resolved from this test process")
        let port = try StubACEStepServer.unusedLoopbackPort()
        let base = URL(string: "http://127.0.0.1:\(port)")!

        let lifecycle = ModelLifecycleCoordinator(
            storageDirectory: root.appendingPathComponent("lifecycle", isDirectory: true), settleSeconds: 0)
        var soulx = ModelRegistry.soulxSinger(baseURL: base)
        soulx.idleUnloadSeconds = nil
        await lifecycle.register(soulx, evictor: nil)

        var config = SingingSidecarManager.Configuration(
            baseURL: base, scriptsDir: scripts, runtimeDir: runtime, voicesDir: voices, cacheDir: cacheDir,
            startupTimeoutSeconds: 15, healthPollIntervalSeconds: 0.1, healthProbeTimeoutSeconds: 2,
            stopTimeoutSeconds: 5, lifecycle: lifecycle, logFileURL: root.appendingPathComponent("sing.log"))
        config.testExtraEnvironment = ["SING_USE_STUB": "1", "SING_TEST_HOOKS": "1"]
        config.watchdogReadMemoryPressureCritical = { false }
        let manager = SingingSidecarManager(configuration: config)

        let (store, clipID) = try await MainActor.run { try SingFixture.store(root: root) }
        let tracksBefore = await MainActor.run { store.tracks }
        let coordinator = SingJobCoordinator(
            store: store, engine: manager, synthesizer: SingingSynthesisClient(baseURL: base),
            lifecycle: lifecycle, cache: SingPhraseCache(directory: cacheDir),
            detectPitch: { url in try SingFixture.frames(at: url) },
            transcribe: { _ in "one two three four five six seven eight" },
            configuration: SingJobCoordinator.Configuration(
                outputSampleRate: 48_000, modelPollSeconds: 0.05, enginePollSeconds: 0.05,
                sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                songGeneratorRunsOutside: { false }))

        do {
            let submitted = try await coordinator.submit(SingJobRequest(clipID: clipID))
            let finished = await SingFixture.waitUntil(60) {
                (try? await coordinator.status(jobID: submitted.jobID).phase.isTerminal) ?? false
            }
            let status = try await coordinator.status(jobID: submitted.jobID)
            #expect(finished, "the job reads \(status.phase): \(status.stageText)")
            #expect(status.phase == .done, "\(status.error?.message ?? "") \(status.error?.detail ?? "")")
            #expect(status.renderedUnits == 2)
            #expect(status.engineRestarts == 0)
            #expect(status.retriedUnits.isEmpty)
            let result = try #require(status.result)
            #expect(result.gates.failed.isEmpty, "\(result.gates)")
            #expect(abs(result.gates.lengthSeconds - result.gates.plannedSeconds) <= 0.02,
                    "the stub's 10 ms grid keeps the take within L1's tolerance")
            #expect(result.noteAccuracy?.inTune == true, "the stub sings a sine at every planned pitch")
            #expect(result.wordCheck?.verdict == SingWordCheck.Verdict.clear)

            let track = try #require(await MainActor.run { store.tracks.first { $0.id == result.trackID } })
            let record = try #require(track.sungVocalProvenance)
            #expect(record.engineCommit == "stub", "the provenance is the stub's own /health")
            #expect(record.facadeVersion == 1)
            #expect(record.seed == Int(SingJobRequestBuilder.firstTakeSeed))
            let clip = try #require(track.clips.first)
            let file = try #require(clip.audioFileURL)
            let landed = try SingWAV.read(file)
            #expect(landed.sampleRate == 48_000)
            #expect(abs(Double(landed.frameCount) / 48_000 - result.gates.plannedSeconds) <= 0.02)

            #expect(try await MainActor.run { try store.undo() } == "Land Sung Vocal")
            #expect(await MainActor.run { store.tracks } == tracksBefore, "undo removes the take exactly")
            _ = try await manager.stop()
        } catch {
            _ = try? await manager.stop()
            throw error
        }
    }
}
