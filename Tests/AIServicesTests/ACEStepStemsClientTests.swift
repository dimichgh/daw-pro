import Foundation
import Testing
@testable import AIServices

/// `ACEStepClient` coverage for M6 (iii-c): stem extraction and Lego
/// per-track generation. Reuses `StubACEStepServer`/`ACEStepFixtures` from
/// `ACEStepClientTests.swift` (same stub-sidecar plumbing) — extract/lego are
/// SINGLE-track-per-job upstream (verified against
/// `scripts/ace-step/runtime/src/acestep/core/generation/handler/
/// task_utils.py` and `generate_music_request.py`), so a "stems" request
/// fans out into N `/release_task` calls grouped under one composite job id
/// that polls through the SAME `generationStatus` used for ordinary songs.
@Suite("ACEStepClient — stems / Lego against a stub sidecar (M6 iii-c)")
struct ACEStepStemsClientTests {
    private func makeClient(port: UInt16, downloadDirectory: URL) -> ACEStepClient {
        ACEStepClient(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            downloadDirectory: downloadDirectory))
    }

    private func makeTempDownloadDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-stems-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A tiny real WAV on disk to hand in as `sourceAudioPath` — the client
    /// must be able to read/copy an ACTUAL file to stage it.
    private func writeSourceWAV() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-stems-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mix.wav")
        try ACEStepFixtures.tinyWAV().write(to: url)
        return url
    }

    // MARK: - extractStems

    @Test("extractStems submits one /release_task per track name, all against the staged source path")
    func extractStemsSubmitsOnePerTrack() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        // Already loaded as the primary model — ensureStemsModelLoaded should
        // find it via GET /v1/model_inventory and skip POST /v1/init entirely.
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-sft"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals"), forKey: "POST /release_task")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-drums"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        let submission = try await client.extractStems(
            StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals", "drums"]))

        #expect(submission.state == .queued)
        #expect(submission.trackNames == ["vocals", "drums"])
        #expect(submission.jobID.hasPrefix("stems:"))
        #expect(server.callCount(forKey: "POST /release_task") == 2)

        let bodyData = try #require(server.lastBody(forKey: "POST /release_task"))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["task_type"] as? String == "extract")
        #expect(body["track_name"] as? String == "drums")
        // REAL-gate regression (iii-c-real): omitting audio_format made
        // upstream return 128k mp3 stems — must always request wav.
        #expect(body["audio_format"] as? String == "wav")
        // M6 iii-c-real: a nil request.model defaults to the client's own
        // stems default on the wire (never omitted, and never turbo).
        #expect(body["model"] as? String == "acestep-v15-xl-sft")
        // The staged path must resolve inside the system temp directory (the
        // sidecar's own allowlist — release_task_audio_paths.py), never the
        // caller's original path verbatim.
        let stagedPath = try #require(body["src_audio_path"] as? String)
        let systemTemp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        #expect(URL(fileURLWithPath: stagedPath).resolvingSymlinksInPath().path.hasPrefix(systemTemp))
        #expect(stagedPath != source.path)
        #expect(FileManager.default.fileExists(atPath: stagedPath))
        #expect(body["global_caption"] == nil)
        #expect(body["prompt"] == nil)
    }

    @Test("ensureStemsModelLoaded skips /v1/init when GET /v1/model_inventory already reports the target model loaded")
    func initSkippedWhenModelAlreadyLoaded() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-sft"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        _ = try await client.extractStems(
            StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals"]))

        #expect(server.callCount(forKey: "GET /v1/model_inventory") == 1)
        #expect(server.callCount(forKey: "POST /v1/init") == 0)
    }

    @Test("ensureStemsModelLoaded calls /v1/init with slot 2 and the target model when not loaded, and caches success across a second job")
    func initCalledWhenModelNotLoadedThenCachedForRepeatJobs() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        // Only turbo (the primary) is loaded — the sft default is not.
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-turbo"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(
            ACEStepFixtures.initModelAccepted(model: "acestep-v15-xl-sft", slot: 2),
            forKey: "POST /v1/init")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals-1"), forKey: "POST /release_task")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals-2"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        _ = try await client.extractStems(
            StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals"]))

        #expect(server.callCount(forKey: "GET /v1/model_inventory") == 1)
        #expect(server.callCount(forKey: "POST /v1/init") == 1)
        let initBodyData = try #require(server.lastBody(forKey: "POST /v1/init"))
        let initBody = try #require(try JSONSerialization.jsonObject(with: initBodyData) as? [String: Any])
        #expect(initBody["model"] as? String == "acestep-v15-xl-sft")
        #expect(initBody["slot"] as? Int == 2)

        // A second job against the SAME (now-ensured) model must not
        // re-check the inventory or re-init.
        _ = try await client.extractStems(
            StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals"]))
        #expect(server.callCount(forKey: "GET /v1/model_inventory") == 1)
        #expect(server.callCount(forKey: "POST /v1/init") == 1)
    }

    @Test("an explicit model overrides the client's stems default, on the wire and for the /v1/init check")
    func explicitModelOverridesDefaultAndDrivesInit() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-turbo"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(
            ACEStepFixtures.initModelAccepted(model: "acestep-v15-custom", slot: 2),
            forKey: "POST /v1/init")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        _ = try await client.extractStems(StemExtractionRequest(
            sourceAudioPath: source.path, trackNames: ["vocals"], model: "acestep-v15-custom"))

        let bodyData = try #require(server.lastBody(forKey: "POST /release_task"))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "acestep-v15-custom")

        let initBodyData = try #require(server.lastBody(forKey: "POST /v1/init"))
        let initBody = try #require(try JSONSerialization.jsonObject(with: initBodyData) as? [String: Any])
        #expect(initBody["model"] as? String == "acestep-v15-custom")
        #expect(initBody["slot"] as? Int == 2)
    }

    @Test("a 400 'slot not available' from /v1/init surfaces an actionable restart-the-sidecar error")
    func initSlotUnavailableSurfacesActionableError() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-turbo"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(ACEStepFixtures.initSlotUnavailable(slot: 2), forKey: "POST /v1/init")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        do {
            _ = try await client.extractStems(
                StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals"]))
            Issue.record("expected extractStems to throw when slot 2 isn't available")
        } catch let error as ACEStepError {
            guard case .modelSlotUnavailable(let model, let detail) = error else {
                Issue.record("expected .modelSlotUnavailable, got \(error)")
                return
            }
            #expect(model == "acestep-v15-xl-sft")
            #expect(detail.contains("ACESTEP_CONFIG_PATH2"))
            #expect(error.errorDescription?.contains("RESTARTED") == true)
            #expect(error.errorDescription?.contains("ai.sidecarStart") == true)
        }
        #expect(server.callCount(forKey: "POST /release_task") == 0)
    }

    @Test("extractStems rejects an empty track-name list without contacting the sidecar")
    func extractStemsRejectsEmptyTrackNames() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        do {
            _ = try await client.extractStems(
                StemExtractionRequest(sourceAudioPath: source.path, trackNames: []))
            Issue.record("expected extractStems to throw for an empty track list")
        } catch let error as ACEStepError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
        #expect(server.callCount(forKey: "POST /release_task") == 0)
    }

    @Test("extractStems throws when the source audio file does not exist")
    func extractStemsRejectsMissingSourceFile() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.extractStems(StemExtractionRequest(
                sourceAudioPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav",
                trackNames: ["vocals"]))
            Issue.record("expected extractStems to throw for a missing source file")
        } catch let error as ACEStepError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
        #expect(server.callCount(forKey: "POST /release_task") == 0)
    }

    // MARK: - generateLegoTracks

    @Test("generateLegoTracks forwards global_caption and each track's own local prompt")
    func legoForwardsGlobalCaptionAndLocalPrompts() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-sft"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-bass"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        let submission = try await client.generateLegoTracks(LegoGenerationRequest(
            sourceAudioPath: source.path,
            globalCaption: "warm lofi hip-hop, 90 bpm",
            tracks: [StemTrackRequest(trackName: "bass", localPrompt: "round sub bass, laid back")],
            model: "acestep-v15-xl-sft"))

        #expect(submission.trackNames == ["bass"])
        let bodyData = try #require(server.lastBody(forKey: "POST /release_task"))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["task_type"] as? String == "lego")
        #expect(body["track_name"] as? String == "bass")
        #expect(body["global_caption"] as? String == "warm lofi hip-hop, 90 bpm")
        #expect(body["prompt"] as? String == "round sub bass, laid back")
        #expect(body["model"] as? String == "acestep-v15-xl-sft")
        #expect(body["audio_format"] as? String == "wav")
    }

    // MARK: - generationStatus on a composite stems/Lego job

    @Test("generationStatus on a composite job stays 'running' until every track has succeeded")
    func compositeStatusRunningUntilAllSucceeded() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-sft"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals"), forKey: "POST /release_task")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-drums"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()
        let submission = try await client.extractStems(
            StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals", "drums"]))

        // The composite poller re-queries EVERY sub-job on EVERY poll (each
        // sub-job's own status can change independently), so two overall
        // polls issue FOUR POST /query_result calls in strict order
        // [vocals, drums, vocals, drums] against the stub's single shared
        // FIFO queue for that key — enqueue all of them upfront, in that
        // exact call order (vocals succeeds on both polls; drums is running
        // on the first, succeeded on the second). `fetchAudioOnce`'s
        // fetch-once cache means vocals' GET /v1/audio is hit only once
        // despite being polled twice.
        server.enqueue(
            ACEStepFixtures.queryResultSucceeded(taskID: "task-vocals", remoteFile: "/sidecar/tmp/vocals.wav"),
            forKey: "POST /query_result")
        server.enqueue(
            ACEStepFixtures.queryResultRunning(taskID: "task-drums", progress: 0.5, logLine: "step 4/8"),
            forKey: "POST /query_result")
        server.enqueue(
            ACEStepFixtures.queryResultSucceeded(taskID: "task-vocals", remoteFile: "/sidecar/tmp/vocals.wav"),
            forKey: "POST /query_result")
        server.enqueue(
            ACEStepFixtures.queryResultSucceeded(taskID: "task-drums", remoteFile: "/sidecar/tmp/drums.wav"),
            forKey: "POST /query_result")
        server.enqueue(
            StubACEStepServer.httpResponse(contentType: "audio/wav", bodyData: ACEStepFixtures.tinyWAV()),
            forKey: "GET /v1/audio")
        server.enqueue(
            StubACEStepServer.httpResponse(contentType: "audio/wav", bodyData: ACEStepFixtures.tinyWAV()),
            forKey: "GET /v1/audio")

        let midStatus = try await client.generationStatus(jobID: submission.jobID)
        #expect(midStatus.state == .running)
        #expect(midStatus.stems == nil)
        // averaged progress: vocals=1.0, drums=0.5 -> 0.75
        #expect(midStatus.progress == 0.75)
        #expect(server.callCount(forKey: "GET /v1/audio") == 1)  // only vocals fetched so far

        let finalStatus = try await client.generationStatus(jobID: submission.jobID)
        #expect(finalStatus.state == .succeeded)
        #expect(finalStatus.progress == 1.0)
        let stems = try #require(finalStatus.stems)
        #expect(Set(stems.map(\.trackName)) == ["vocals", "drums"])
        for stem in stems {
            #expect(FileManager.default.fileExists(atPath: stem.audioPath))
        }
        // vocals' audio was fetched once on the first poll, reused (not
        // re-fetched) on the second; drums' audio fetched once here.
        #expect(server.callCount(forKey: "GET /v1/audio") == 2)
    }

    @Test("succeeded stem result.file as a PRE-BUILT /v1/audio URL is requested verbatim for every track")
    func compositeStatusPinsPrebuiltAudioURLsPerTrack() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-sft"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals"), forKey: "POST /release_task")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-drums"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()
        let submission = try await client.extractStems(
            StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals", "drums"]))

        let vocalsPrebuilt = "/v1/audio?path=%2Fsidecar%2Ftmp%2Fvocals.wav"
        let drumsPrebuilt = "/v1/audio?path=%2Fsidecar%2Ftmp%2Fdrums.wav"
        server.enqueue(
            ACEStepFixtures.queryResultSucceeded(taskID: "task-vocals", remoteFile: vocalsPrebuilt),
            forKey: "POST /query_result")
        server.enqueue(
            ACEStepFixtures.queryResultSucceeded(taskID: "task-drums", remoteFile: drumsPrebuilt),
            forKey: "POST /query_result")
        server.enqueue(
            StubACEStepServer.httpResponse(contentType: "audio/wav", bodyData: ACEStepFixtures.tinyWAV()),
            forKey: "GET /v1/audio")
        server.enqueue(
            StubACEStepServer.httpResponse(contentType: "audio/wav", bodyData: ACEStepFixtures.tinyWAV()),
            forKey: "GET /v1/audio")

        let status = try await client.generationStatus(jobID: submission.jobID)
        #expect(status.state == .succeeded)
        let stems = try #require(status.stems)
        #expect(stems.count == 2)
        // Both pre-built targets must have been requested VERBATIM (never
        // re-wrapped/double-encoded) — the same regression class M6 (ii)
        // pinned for the single-song path, now proven per-track too.
        #expect(server.callCount(forKey: "GET /v1/audio") == 2)
    }

    @Test("a failed track fails the whole composite job, naming which track failed")
    func compositeStatusFailsWholeJobOnAnyTrackFailure() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.modelInventory(loadedModelNames: ["acestep-v15-xl-sft"]),
            forKey: "GET /v1/model_inventory")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-vocals"), forKey: "POST /release_task")
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-drums"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()
        let submission = try await client.extractStems(
            StemExtractionRequest(sourceAudioPath: source.path, trackNames: ["vocals", "drums"]))

        server.enqueue(
            ACEStepFixtures.queryResultFailed(taskID: "task-vocals", error: "CUDA out of memory"),
            forKey: "POST /query_result")

        do {
            _ = try await client.generationStatus(jobID: submission.jobID)
            Issue.record("expected generationStatus to throw when a stem track failed")
        } catch let error as ACEStepError {
            guard case .jobFailed(let jobID, let message) = error else {
                Issue.record("expected .jobFailed, got \(error)")
                return
            }
            #expect(jobID == submission.jobID)
            #expect(message.contains("vocals"))
            #expect(message.contains("CUDA out of memory"))
        }
    }

    @Test("an unknown composite job id (never submitted) falls through to jobNotFound like an ordinary job")
    func unknownCompositeJobIDFallsThroughToJobNotFound() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            StubACEStepServer.jsonResponse("""
            {"data":[{"task_id":"stems:nope","result":"[]","status":0}], \
            "code":200,"error":null,"timestamp":1720000000000,"extra":null}
            """),
            forKey: "POST /query_result")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.generationStatus(jobID: "stems:nope")
            Issue.record("expected generationStatus to throw for an unknown composite job id")
        } catch let error as ACEStepError {
            guard case .jobNotFound(let jobID) = error else {
                Issue.record("expected .jobNotFound, got \(error)")
                return
            }
            #expect(jobID == "stems:nope")
        }
    }
}
