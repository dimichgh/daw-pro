import Foundation
import Testing
@testable import AIServices

/// `ACEStepClient` coverage for M6 (v-a): repaint — re-rendering a WINDOW of
/// an existing audio file in place. Reuses `StubACEStepServer`/
/// `ACEStepFixtures` from `ACEStepClientTests.swift` (same stub-sidecar
/// plumbing the stems suite reuses). Unlike extract/lego (M6 iii-c), repaint
/// is a SINGLE upstream job — no per-track fan-out, no composite job id, no
/// stems-style model ensure-load — so its raw job id polls through the
/// ordinary single-job `generationStatus` path used by `generateSong`.
@Suite("ACEStepClient — repaint against a stub sidecar (M6 v-a)")
struct ACEStepRepaintClientTests {
    private func makeClient(port: UInt16, downloadDirectory: URL) -> ACEStepClient {
        ACEStepClient(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            downloadDirectory: downloadDirectory))
    }

    private func makeTempDownloadDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-repaint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A tiny real WAV on disk to hand in as `srcAudioPath` — the client must
    /// be able to read/copy an ACTUAL file to stage it.
    private func writeSourceWAV() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ace-step-repaint-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mix.wav")
        try ACEStepFixtures.tinyWAV().write(to: url)
        return url
    }

    @Test("repaintAudio submits ONE /release_task and returns the raw upstream job id (no composite prefix)")
    func repaintSubmitsSingleJobAndReturnsRawID() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(
            ACEStepFixtures.releaseTaskAccepted(taskID: "task-repaint-1", queuePosition: 2),
            forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        let submission = try await client.repaintAudio(
            RepaintRequest(srcAudioPath: source.path, startSeconds: 8))

        #expect(submission.jobID == "task-repaint-1")
        #expect(!submission.jobID.hasPrefix("stems:"))
        #expect(submission.state == .queued)
        #expect(submission.queuePosition == 2)
        #expect(server.callCount(forKey: "POST /release_task") == 1)
        // Repaint works on the sidecar's default turbo tier (unlike
        // extract/lego) — no model-inventory check, no on-demand /v1/init.
        #expect(server.callCount(forKey: "GET /v1/model_inventory") == 0)
        #expect(server.callCount(forKey: "POST /v1/init") == 0)
    }

    @Test("release_task body carries repaint's wire shape with upstream's own field names and defaults")
    func repaintBodyDefaults() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-repaint-defaults"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        _ = try await client.repaintAudio(RepaintRequest(srcAudioPath: source.path, startSeconds: 12.5))

        let bodyData = try #require(server.lastBody(forKey: "POST /release_task"))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["task_type"] as? String == "repaint")
        #expect(body["repainting_start"] as? Double == 12.5)
        // Defaults: mode "balanced" is ALWAYS sent (it has a real Swift
        // default, unlike the other knobs below); everything else the
        // caller left unset is OMITTED so the sidecar's own default applies.
        #expect(body["repaint_mode"] as? String == "balanced")
        #expect(body["repainting_end"] == nil)
        #expect(body["prompt"] == nil)
        #expect(body["lyrics"] == nil)
        #expect(body["repaint_strength"] == nil)
        #expect(body["repaint_wav_crossfade_sec"] == nil)
        #expect(body["repaint_latent_crossfade_frames"] == nil)
        #expect(body["model"] == nil)
        // No seed -> an EXPLICIT use_random_seed true (never left to an
        // implicit upstream default), and no 'seed' key.
        #expect(body["use_random_seed"] as? Bool == true)
        #expect(body["seed"] == nil)
        // REAL-gate regression class (same as generateSong/submitStemJob):
        // omitting audio_format made upstream return 128k mp3 — must always
        // request wav.
        #expect(body["audio_format"] as? String == "wav")
        // The staged path must resolve inside the system temp directory (the
        // sidecar's own allowlist), never the caller's original path verbatim.
        let stagedPath = try #require(body["src_audio_path"] as? String)
        let systemTemp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        #expect(URL(fileURLWithPath: stagedPath).resolvingSymlinksInPath().path.hasPrefix(systemTemp))
        #expect(stagedPath != source.path)
        #expect(FileManager.default.fileExists(atPath: stagedPath))
    }

    @Test("release_task body forwards every optional repaint knob when the caller sets it")
    func repaintBodyFullKnobs() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-repaint-full"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        var request = RepaintRequest(srcAudioPath: source.path, startSeconds: 4)
        request.endSeconds = 20
        request.prompt = "driving rock drums, tighter groove"
        request.lyrics = "[Chorus]\nhold the line"
        request.mode = .aggressive
        request.strength = 0.65
        request.wavCrossfadeSec = 0.25
        request.latentCrossfadeFrames = 16
        request.seed = 777
        request.model = "acestep-v15-xl-sft"
        _ = try await client.repaintAudio(request)

        let bodyData = try #require(server.lastBody(forKey: "POST /release_task"))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["repainting_start"] as? Double == 4)
        #expect(body["repainting_end"] as? Double == 20)
        #expect(body["prompt"] as? String == "driving rock drums, tighter groove")
        #expect(body["lyrics"] as? String == "[Chorus]\nhold the line")
        #expect(body["repaint_mode"] as? String == "aggressive")
        #expect(body["repaint_strength"] as? Double == 0.65)
        #expect(body["repaint_wav_crossfade_sec"] as? Double == 0.25)
        #expect(body["repaint_latent_crossfade_frames"] as? Int == 16)
        #expect(body["model"] as? String == "acestep-v15-xl-sft")
        // Explicit seed -> deterministic pair, pinned both ways.
        #expect(body["seed"] as? Int == 777)
        #expect(body["use_random_seed"] as? Bool == false)
        #expect(body["audio_format"] as? String == "wav")
    }

    @Test("an explicit 'conservative' mode is passed through verbatim (not silently normalized to balanced)")
    func repaintModeConservativePassesThrough() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-repaint-conservative"), forKey: "POST /release_task")

        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())
        let source = try writeSourceWAV()

        var request = RepaintRequest(srcAudioPath: source.path, startSeconds: 0)
        request.mode = .conservative
        _ = try await client.repaintAudio(request)

        let bodyData = try #require(server.lastBody(forKey: "POST /release_task"))
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["repaint_mode"] as? String == "conservative")
    }

    @Test("repaintAudio throws when the source audio file does not exist")
    func repaintRejectsMissingSourceFile() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        let client = makeClient(port: server.port, downloadDirectory: try makeTempDownloadDir())

        do {
            _ = try await client.repaintAudio(RepaintRequest(
                srcAudioPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav", startSeconds: 0))
            Issue.record("expected repaintAudio to throw for a missing source file")
        } catch let error as ACEStepError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
        #expect(server.callCount(forKey: "POST /release_task") == 0)
    }

    @Test("a repaint job's id polls through the ORDINARY single-job generationStatus path, full wav on success")
    func repaintJobPollsThroughOrdinaryStatusPath() async throws {
        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(ACEStepFixtures.releaseTaskAccepted(taskID: "task-repaint-poll"), forKey: "POST /release_task")

        let downloadDir = try makeTempDownloadDir()
        let client = makeClient(port: server.port, downloadDirectory: downloadDir)
        let source = try writeSourceWAV()
        let submission = try await client.repaintAudio(
            RepaintRequest(srcAudioPath: source.path, startSeconds: 5, endSeconds: 15))
        #expect(submission.state == .queued)

        // Both poll responses must be queued UP FRONT (the stub's FIFO-per-key
        // queue only advances past the current head once a SECOND item is
        // already waiting — see StubACEStepServer's own doc) before either
        // `generationStatus` call below.
        let wav = ACEStepFixtures.tinyWAV()
        server.enqueue(
            ACEStepFixtures.queryResultRunning(taskID: "task-repaint-poll", progress: 0.5, logLine: "step 4/8"),
            forKey: "POST /query_result")
        server.enqueue(
            ACEStepFixtures.queryResultSucceeded(taskID: "task-repaint-poll", remoteFile: "/sidecar/tmp/repainted.wav"),
            forKey: "POST /query_result")
        server.enqueue(
            StubACEStepServer.httpResponse(contentType: "audio/wav", bodyData: wav),
            forKey: "GET /v1/audio")

        let runningStatus = try await client.generationStatus(jobID: submission.jobID)
        #expect(runningStatus.state == .running)
        #expect(runningStatus.stems == nil)  // never routed through the composite/stems poller

        let succeededStatus = try await client.generationStatus(jobID: submission.jobID)
        #expect(succeededStatus.state == .succeeded)
        let audioPath = try #require(succeededStatus.audioPath)
        #expect(FileManager.default.fileExists(atPath: audioPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: audioPath)) == wav)
    }
}
