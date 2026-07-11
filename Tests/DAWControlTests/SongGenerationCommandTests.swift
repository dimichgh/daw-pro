import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Test double for `SongGenerating` — lets the control-protocol layer be
/// exercised (routing, param shape, response encoding, error translation)
/// without a real sidecar/network call. Real HTTP/wire-parsing behavior is
/// covered by AIServicesTests/ACEStepClientTests.
actor FakeSongGenerator: SongGenerating {
    var generateResult: Result<SongGenerationSubmission, Error> = .success(
        SongGenerationSubmission(jobID: "fake-job-1", state: .queued, queuePosition: 1))
    var statusResult: Result<SongGenerationStatus, Error> = .success(
        SongGenerationStatus(jobID: "fake-job-1", state: .queued))

    private(set) var lastRequest: SongGenerationRequest?
    private(set) var lastStatusJobID: String?
    private(set) var generateCalls = 0
    private(set) var statusCalls = 0

    func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
        generateCalls += 1
        lastRequest = request
        return try generateResult.get()
    }

    func generationStatus(jobID: String) async throws -> SongGenerationStatus {
        statusCalls += 1
        lastStatusJobID = jobID
        return try statusResult.get()
    }

    func setGenerateResult(_ result: Result<SongGenerationSubmission, Error>) { generateResult = result }
    func setStatusResult(_ result: Result<SongGenerationStatus, Error>) { statusResult = result }

    // MARK: M6 (iii-c) stems/Lego — scripted like the two calls above.

    var extractResult: Result<StemGenerationSubmission, Error> = .success(
        StemGenerationSubmission(jobID: "fake-stems-1", state: .queued, trackNames: []))
    var legoResult: Result<StemGenerationSubmission, Error> = .success(
        StemGenerationSubmission(jobID: "fake-lego-1", state: .queued, trackNames: []))
    private(set) var lastExtractRequest: StemExtractionRequest?
    private(set) var lastLegoRequest: LegoGenerationRequest?

    func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
        lastExtractRequest = request
        return try extractResult.get()
    }

    func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
        lastLegoRequest = request
        return try legoResult.get()
    }

    func setExtractResult(_ result: Result<StemGenerationSubmission, Error>) { extractResult = result }
    func setLegoResult(_ result: Result<StemGenerationSubmission, Error>) { legoResult = result }

    // MARK: M6 (v-a) repaint — scripted like the calls above.

    var repaintResult: Result<SongGenerationSubmission, Error> = .success(
        SongGenerationSubmission(jobID: "fake-repaint-1", state: .queued))
    private(set) var lastRepaintRequest: RepaintRequest?

    func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission {
        lastRepaintRequest = request
        return try repaintResult.get()
    }

    func setRepaintResult(_ result: Result<SongGenerationSubmission, Error>) { repaintResult = result }
}

/// Control-protocol coverage for M6 (ii) `ai.generateSong` / `ai.generationStatus`.
/// The M6 (i) `SidecarCommandTests` suite already covers `ai.sidecarStatus`/
/// `Start`/`Stop`; this suite adds the two generation routes, including the
/// `ACEStepError.sidecarUnreachable` -> `SidecarManager.status().message`
/// translation described in `CommandRouter.translateSongGeneratorError`.
@MainActor
@Suite("AI song generation — control protocol (M6 ii)")
struct SongGenerationCommandTests {
    private func makeRouter(
        songGenerator: FakeSongGenerator = FakeSongGenerator(),
        sidecarManager: FakeSidecarManager = FakeSidecarManager()
    ) -> CommandRouter {
        makeRouterAndStore(songGenerator: songGenerator, sidecarManager: sidecarManager).0
    }

    /// Router + its store, for the import tests that inspect the resulting
    /// project. The store's imports dir is a temp path so imports stay hermetic.
    private func makeRouterAndStore(
        songGenerator: FakeSongGenerator = FakeSongGenerator(),
        sidecarManager: FakeSidecarManager = FakeSidecarManager()
    ) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-cmd-\(UUID().uuidString)")
        let router = CommandRouter(
            store: store, sidecarManager: sidecarManager, songGenerator: songGenerator)
        return (router, store)
    }

    /// A minimal valid WAV on disk (the "cached" download a succeeded status
    /// would point at). FakeMedia doesn't read it; it only needs to exist.
    private func writeTinyWAV() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gen-cmd-src-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gen.wav")
        var data = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        data.append(Data("RIFF".utf8)); data.append(le32(52)); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); data.append(le32(16)); data.append(le16(1)); data.append(le16(1))
        data.append(le32(48000)); data.append(le32(96000)); data.append(le16(2)); data.append(le16(16))
        data.append(Data("data".utf8)); data.append(le32(16)); data.append(Data(repeating: 0, count: 16))
        try! data.write(to: url)
        return url.path
    }

    @Test("both ai.generateSong/ai.generationStatus are in the canonical command list")
    func commandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("ai.generateSong"))
        #expect(CommandRouter.allCommands.contains("ai.generationStatus"))
    }

    @Test("ai.generateSong requires 'prompt'")
    func generateSongRequiresPrompt() async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "ai.generateSong"))
        #expect(!response.ok)
        #expect(response.error?.contains("prompt") == true)
    }

    @Test("ai.generateSong happy path forwards fields and threads the submission onto the wire")
    func generateSongHappyPath() async throws {
        let generator = FakeSongGenerator()
        await generator.setGenerateResult(.success(
            SongGenerationSubmission(jobID: "job-42", state: .queued, queuePosition: 2)))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generateSong",
            params: [
                "prompt": .string("80s synth-pop, anthemic"),
                "lyrics": .string("[Verse 1]\nhello"),
                "durationSeconds": .number(45),
                "seed": .number(42),
                "bpm": .number(128),
                "keyScale": .string("C Major"),
                "timeSignature": .string("4/4"),
                "vocalLanguage": .string("ja"),
                "guidanceScale": .number(8.5),
                "inferenceSteps": .number(12),
            ]))

        #expect(response.ok, "ai.generateSong failed: \(response.error ?? "?")")
        #expect(response.result?["jobId"]?.stringValue == "job-42")
        #expect(response.result?["state"]?.stringValue == "queued")
        #expect(response.result?["queuePosition"]?.doubleValue == 2)

        let request = await generator.lastRequest
        #expect(request?.prompt == "80s synth-pop, anthemic")
        #expect(request?.lyrics == "[Verse 1]\nhello")
        #expect(request?.durationSeconds == 45)
        #expect(request?.seed == 42)
        #expect(request?.bpm == 128)
        #expect(request?.keyScale == "C Major")
        #expect(request?.timeSignature == "4/4")
        #expect(request?.vocalLanguage == "ja")
        #expect(request?.guidanceScale == 8.5)
        #expect(request?.inferenceSteps == 12)
    }

    @Test("ai.generateSong omits optional fields when not supplied (defaults on SongGenerationRequest)")
    func generateSongMinimalParams() async throws {
        let generator = FakeSongGenerator()
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generateSong", params: ["prompt": .string("lofi beats")]))

        #expect(response.ok)
        let request = await generator.lastRequest
        #expect(request?.prompt == "lofi beats")
        #expect(request?.lyrics == nil)
        #expect(request?.durationSeconds == nil)
        #expect(request?.seed == nil)
        #expect(request?.vocalLanguage == "en")
        #expect(request?.audioFormat == "wav")
    }

    @Test("ai.generateSong surfaces sidecarUnreachable as the SidecarManager's own actionable message")
    func generateSongSurfacesSidecarStatusMessage() async throws {
        let generator = FakeSongGenerator()
        await generator.setGenerateResult(.failure(ACEStepError.sidecarUnreachable("connection refused")))
        let sidecar = FakeSidecarManager()
        await sidecar.setStatus(
            SidecarStatus(state: .installedNotRunning, message: "ACE-Step is installed but not running — call ai.sidecarStart."))
        let router = makeRouter(songGenerator: generator, sidecarManager: sidecar)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generateSong", params: ["prompt": .string("x")]))

        #expect(!response.ok)
        #expect(response.error == "ACE-Step is installed but not running — call ai.sidecarStart.")
        #expect(await sidecar.statusCalls == 1)
    }

    @Test("ai.generateSong surfaces a non-connectivity failure verbatim (job-failed-class errors)")
    func generateSongSurfacesOtherErrorsVerbatim() async throws {
        let generator = FakeSongGenerator()
        await generator.setGenerateResult(.failure(ACEStepError.requestFailed(status: 429, body: "Server busy: queue is full")))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generateSong", params: ["prompt": .string("x")]))

        #expect(!response.ok)
        #expect(response.error?.contains("429") == true)
        #expect(response.error?.contains("queue is full") == true)
    }

    @Test("ai.generationStatus requires 'jobId'")
    func generationStatusRequiresJobID() async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "ai.generationStatus"))
        #expect(!response.ok)
        #expect(response.error?.contains("jobId") == true)
    }

    @Test("ai.generationStatus threads a running status onto the wire, no audioPath yet")
    func generationStatusRunning() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.success(
            SongGenerationStatus(
                jobID: "job-42", state: .running, progress: 0.4, stage: "running",
                statusText: "step 3/8")))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generationStatus", params: ["jobId": .string("job-42")]))

        #expect(response.ok, "ai.generationStatus failed: \(response.error ?? "?")")
        #expect(response.result?["state"]?.stringValue == "running")
        #expect(response.result?["progress"]?.doubleValue == 0.4)
        #expect(response.result?["statusText"]?.stringValue == "step 3/8")
        #expect(response.result?["audioPath"] == nil)
        #expect(await generator.lastStatusJobID == "job-42")
    }

    @Test("ai.generationStatus threads a succeeded status with audioPath onto the wire")
    func generationStatusSucceeded() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.success(
            SongGenerationStatus(
                jobID: "job-42", state: .succeeded, progress: 1.0,
                audioPath: "/tmp/DAWPro/ace-step-generations/job-42.wav")))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generationStatus", params: ["jobId": .string("job-42")]))

        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "succeeded")
        #expect(response.result?["audioPath"]?.stringValue == "/tmp/DAWPro/ace-step-generations/job-42.wav")
    }

    @Test("ai.generationStatus surfaces a job-failed error verbatim")
    func generationStatusJobFailed() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.failure(
            ACEStepError.jobFailed(jobID: "job-42", message: "CUDA out of memory")))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generationStatus", params: ["jobId": .string("job-42")]))

        #expect(!response.ok)
        #expect(response.error?.contains("job-42") == true)
        #expect(response.error?.contains("CUDA out of memory") == true)
    }

    @Test("ai.generationStatus surfaces sidecarUnreachable via the SidecarManager's message too")
    func generationStatusSurfacesSidecarStatusMessage() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.failure(ACEStepError.sidecarUnreachable("timed out")))
        let sidecar = FakeSidecarManager()
        await sidecar.setStatus(SidecarStatus(state: .notInstalled, message: "run scripts/ace-step/install.sh first"))
        let router = makeRouter(songGenerator: generator, sidecarManager: sidecar)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generationStatus", params: ["jobId": .string("job-42")]))

        #expect(!response.ok)
        #expect(response.error == "run scripts/ace-step/install.sh first")
    }

    @Test("ai.generationStatus threads succeeded metas (bpm/genres/keyScale) onto the wire")
    func generationStatusThreadsMetas() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.success(SongGenerationStatus(
            jobID: "job-42", state: .succeeded, progress: 1.0,
            audioPath: "/tmp/x.wav", prompt: "lofi", bpm: 92, durationSeconds: 30,
            genres: "lofi", keyScale: "C Major", timeSignature: "4/4")))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.generationStatus", params: ["jobId": .string("job-42")]))

        #expect(response.ok)
        #expect(response.result?["bpm"]?.doubleValue == 92)
        #expect(response.result?["genres"]?.stringValue == "lofi")
        #expect(response.result?["keyScale"]?.stringValue == "C Major")
        #expect(response.result?["timeSignature"]?.stringValue == "4/4")
    }

    // MARK: - ai.importGeneration (M6 iii-a)

    @Test("ai.importGeneration is in the canonical command list")
    func importIsCanonical() {
        #expect(CommandRouter.allCommands.contains("ai.importGeneration"))
    }

    @Test("ai.importGeneration requires 'jobId'")
    func importRequiresJobID() async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "ai.importGeneration"))
        #expect(!response.ok)
        #expect(response.error?.contains("jobId") == true)
    }

    @Test("ai.importGeneration happy path: AI track+clip land, tempo adopted, ids on the wire")
    func importHappyPath() async throws {
        let generator = FakeSongGenerator()
        let wavPath = writeTinyWAV()
        await generator.setStatusResult(.success(SongGenerationStatus(
            jobID: "job-42", state: .succeeded, progress: 1.0,
            audioPath: wavPath, prompt: "warm lofi", bpm: 92)))
        let (router, store) = makeRouterAndStore(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneration", params: ["jobId": .string("job-42")]))

        #expect(response.ok, "ai.importGeneration failed: \(response.error ?? "?")")
        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let clipId = try #require(response.result?["clipId"]?.stringValue)
        #expect(response.result?["adoptedTempoBPM"]?.doubleValue == 92)  // empty project → adopted
        #expect(store.transport.tempoBPM == 92)

        let track = try #require(store.tracks.first { $0.id.uuidString == trackId })
        #expect(track.isAIGenerated)
        let clip = try #require(track.clips.first { $0.id.uuidString == clipId })
        #expect(clip.isAIGenerated)
    }

    @Test("ai.importGeneration omits adoptedTempoBPM when tempo is left unchanged")
    func importOmitsAdoptedTempoWhenNotAdopted() async throws {
        let generator = FakeSongGenerator()
        let wavPath = writeTinyWAV()
        await generator.setStatusResult(.success(SongGenerationStatus(
            jobID: "job-42", state: .succeeded, progress: 1.0, audioPath: wavPath, bpm: 92)))
        let (router, _) = makeRouterAndStore(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneration",
            params: ["jobId": .string("job-42"), "setProjectTempo": .bool(false)]))

        #expect(response.ok)
        #expect(response.result?["adoptedTempoBPM"] == nil)
    }

    @Test("ai.importGeneration on a still-running job rejects, pointing at ai.generationStatus")
    func importRejectsStillRunning() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.success(SongGenerationStatus(
            jobID: "job-42", state: .running, progress: 0.3)))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneration", params: ["jobId": .string("job-42")]))

        #expect(!response.ok)
        #expect(response.error?.contains("ai.generationStatus") == true)
    }

    @Test("ai.importGeneration on an unknown job surfaces the client's expired-job wording verbatim")
    func importRejectsUnknownJob() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.failure(ACEStepError.jobNotFound("job-gone")))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneration", params: ["jobId": .string("job-gone")]))

        #expect(!response.ok)
        #expect(response.error?.contains("job-gone") == true)
        #expect(response.error?.contains("expired") == true)
    }

    @Test("ai.importGeneration surfaces sidecarUnreachable via the SidecarManager's message")
    func importSurfacesSidecarStatusMessage() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.failure(ACEStepError.sidecarUnreachable("connection refused")))
        let sidecar = FakeSidecarManager()
        await sidecar.setStatus(SidecarStatus(
            state: .installedNotRunning, message: "ACE-Step is installed but not running — call ai.sidecarStart."))
        let router = makeRouter(songGenerator: generator, sidecarManager: sidecar)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneration", params: ["jobId": .string("job-42")]))

        #expect(!response.ok)
        #expect(response.error == "ACE-Step is installed but not running — call ai.sidecarStart.")
    }

    // MARK: - ai.extractStems / ai.legoGenerate / ai.importGeneratedStems (M6 iii-c)

    @Test("all three M6 (iii-c) commands are in the canonical command list")
    func stemsCommandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("ai.extractStems"))
        #expect(CommandRouter.allCommands.contains("ai.legoGenerate"))
        #expect(CommandRouter.allCommands.contains("ai.importGeneratedStems"))
    }

    @Test("ai.extractStems requires 'sourceAudioPath'")
    func extractStemsRequiresSourceAudioPath() async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.extractStems", params: ["trackNames": .array([.string("vocals")])]))
        #expect(!response.ok)
        #expect(response.error?.contains("sourceAudioPath") == true)
    }

    @Test("ai.extractStems requires a non-empty 'trackNames' array")
    func extractStemsRequiresTrackNames() async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.extractStems", params: ["sourceAudioPath": .string("/tmp/mix.wav")]))
        #expect(!response.ok)
        #expect(response.error?.contains("trackNames") == true)

        let emptyResponse = await router.handle(ControlRequest(
            id: "2", command: "ai.extractStems",
            params: ["sourceAudioPath": .string("/tmp/mix.wav"), "trackNames": .array([])]))
        #expect(!emptyResponse.ok)
        #expect(emptyResponse.error?.contains("trackNames") == true)
    }

    @Test("ai.extractStems happy path forwards sourceAudioPath/trackNames/model and threads the submission")
    func extractStemsHappyPath() async throws {
        let generator = FakeSongGenerator()
        await generator.setExtractResult(.success(
            StemGenerationSubmission(jobID: "stems:abc", state: .queued, trackNames: ["vocals", "drums"])))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.extractStems",
            params: [
                "sourceAudioPath": .string("/tmp/mix.wav"),
                "trackNames": .array([.string("vocals"), .string("drums")]),
                "model": .string("acestep-v15-xl-sft"),
            ]))

        #expect(response.ok, "ai.extractStems failed: \(response.error ?? "?")")
        #expect(response.result?["jobId"]?.stringValue == "stems:abc")
        #expect(response.result?["state"]?.stringValue == "queued")
        #expect(response.result?["trackNames"]?.arrayValue?.compactMap(\.stringValue) == ["vocals", "drums"])

        let lastRequest = await generator.lastExtractRequest
        #expect(lastRequest?.sourceAudioPath == "/tmp/mix.wav")
        #expect(lastRequest?.trackNames == ["vocals", "drums"])
        #expect(lastRequest?.model == "acestep-v15-xl-sft")
    }

    @Test("ai.extractStems surfaces sidecarUnreachable as the SidecarManager's own actionable message")
    func extractStemsSurfacesSidecarStatusMessage() async throws {
        let generator = FakeSongGenerator()
        await generator.setExtractResult(.failure(ACEStepError.sidecarUnreachable("connection refused")))
        let sidecar = FakeSidecarManager()
        await sidecar.setStatus(SidecarStatus(
            state: .installedNotRunning, message: "ACE-Step is installed but not running — call ai.sidecarStart."))
        let router = makeRouter(songGenerator: generator, sidecarManager: sidecar)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.extractStems",
            params: ["sourceAudioPath": .string("/tmp/mix.wav"), "trackNames": .array([.string("vocals")])]))

        #expect(!response.ok)
        #expect(response.error == "ACE-Step is installed but not running — call ai.sidecarStart.")
    }

    @Test("ai.legoGenerate requires 'sourceAudioPath', 'globalCaption', and non-empty 'tracks'")
    func legoRequiresFields() async throws {
        let router = makeRouter()

        let missingSource = await router.handle(ControlRequest(
            id: "1", command: "ai.legoGenerate",
            params: ["globalCaption": .string("x"), "tracks": .array([.object(["trackName": .string("bass")])])]))
        #expect(!missingSource.ok)
        #expect(missingSource.error?.contains("sourceAudioPath") == true)

        let missingCaption = await router.handle(ControlRequest(
            id: "2", command: "ai.legoGenerate",
            params: [
                "sourceAudioPath": .string("/tmp/mix.wav"),
                "tracks": .array([.object(["trackName": .string("bass")])]),
            ]))
        #expect(!missingCaption.ok)
        #expect(missingCaption.error?.contains("globalCaption") == true)

        let missingTracks = await router.handle(ControlRequest(
            id: "3", command: "ai.legoGenerate",
            params: ["sourceAudioPath": .string("/tmp/mix.wav"), "globalCaption": .string("x")]))
        #expect(!missingTracks.ok)
        #expect(missingTracks.error?.contains("tracks") == true)

        let badTrackObject = await router.handle(ControlRequest(
            id: "4", command: "ai.legoGenerate",
            params: [
                "sourceAudioPath": .string("/tmp/mix.wav"),
                "globalCaption": .string("x"),
                "tracks": .array([.object(["prompt": .string("no trackName here")])]),
            ]))
        #expect(!badTrackObject.ok)
        #expect(badTrackObject.error?.contains("tracks[0].trackName") == true)
    }

    @Test("ai.legoGenerate happy path forwards global_caption and each track's own local prompt")
    func legoHappyPath() async throws {
        let generator = FakeSongGenerator()
        await generator.setLegoResult(.success(
            StemGenerationSubmission(jobID: "stems:lego-1", state: .queued, trackNames: ["bass"])))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.legoGenerate",
            params: [
                "sourceAudioPath": .string("/tmp/mix.wav"),
                "globalCaption": .string("warm lofi hip-hop, 90 bpm"),
                "tracks": .array([
                    .object(["trackName": .string("bass"), "prompt": .string("round sub bass")]),
                ]),
            ]))

        #expect(response.ok, "ai.legoGenerate failed: \(response.error ?? "?")")
        #expect(response.result?["jobId"]?.stringValue == "stems:lego-1")

        let lastRequest = await generator.lastLegoRequest
        #expect(lastRequest?.sourceAudioPath == "/tmp/mix.wav")
        #expect(lastRequest?.globalCaption == "warm lofi hip-hop, 90 bpm")
        #expect(lastRequest?.tracks == [StemTrackRequest(trackName: "bass", localPrompt: "round sub bass")])
    }

    @Test("ai.importGeneratedStems requires 'jobId'")
    func importStemsRequiresJobID() async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "ai.importGeneratedStems"))
        #expect(!response.ok)
        #expect(response.error?.contains("jobId") == true)
    }

    @Test("ai.importGeneratedStems happy path: N AI tracks+clips land in one edit, tempo adopted, ids on the wire")
    func importStemsHappyPath() async throws {
        let generator = FakeSongGenerator()
        let vocalsWav = writeTinyWAV()
        let drumsWav = writeTinyWAV()
        await generator.setStatusResult(.success(SongGenerationStatus(
            jobID: "stems:job-1", state: .succeeded,
            stems: [
                StemResult(trackName: "vocals", audioPath: vocalsWav, bpm: nil),
                StemResult(trackName: "drums", audioPath: drumsWav, bpm: 96),
            ])))
        let (router, store) = makeRouterAndStore(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneratedStems", params: ["jobId": .string("stems:job-1")]))

        #expect(response.ok, "ai.importGeneratedStems failed: \(response.error ?? "?")")
        let trackEntries = try #require(response.result?["tracks"]?.arrayValue)
        #expect(trackEntries.count == 2)
        #expect(response.result?["adoptedTempoBPM"]?.doubleValue == 96)
        #expect(store.transport.tempoBPM == 96)
        #expect(store.tracks.count == 2)

        let names = Set(trackEntries.compactMap { $0["trackName"]?.stringValue })
        #expect(names == ["vocals", "drums"])
        for entry in trackEntries {
            let trackId = try #require(entry["trackId"]?.stringValue)
            let clipId = try #require(entry["clipId"]?.stringValue)
            let track = try #require(store.tracks.first { $0.id.uuidString == trackId })
            #expect(track.isAIGenerated)
            let clip = try #require(track.clips.first { $0.id.uuidString == clipId })
            #expect(clip.isAIGenerated)
        }
    }

    @Test("ai.importGeneratedStems omits adoptedTempoBPM when tempo is left unchanged")
    func importStemsOmitsAdoptedTempoWhenNotAdopted() async throws {
        let generator = FakeSongGenerator()
        let wavPath = writeTinyWAV()
        await generator.setStatusResult(.success(SongGenerationStatus(
            jobID: "stems:job-1", state: .succeeded,
            stems: [StemResult(trackName: "vocals", audioPath: wavPath, bpm: 96)])))
        let (router, _) = makeRouterAndStore(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneratedStems",
            params: ["jobId": .string("stems:job-1"), "setProjectTempo": .bool(false)]))

        #expect(response.ok)
        #expect(response.result?["adoptedTempoBPM"] == nil)
    }

    @Test("ai.importGeneratedStems on a still-running job rejects, pointing at ai.generationStatus")
    func importStemsRejectsStillRunning() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.success(
            SongGenerationStatus(jobID: "stems:job-1", state: .running, progress: 0.3)))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneratedStems", params: ["jobId": .string("stems:job-1")]))

        #expect(!response.ok)
        #expect(response.error?.contains("ai.generationStatus") == true)
    }

    @Test("ai.importGeneratedStems on an unknown job surfaces the client's expired-job wording verbatim")
    func importStemsRejectsUnknownJob() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.failure(ACEStepError.jobNotFound("stems:gone")))
        let router = makeRouter(songGenerator: generator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneratedStems", params: ["jobId": .string("stems:gone")]))

        #expect(!response.ok)
        #expect(response.error?.contains("stems:gone") == true)
        #expect(response.error?.contains("expired") == true)
    }

    @Test("ai.importGeneratedStems surfaces sidecarUnreachable via the SidecarManager's message")
    func importStemsSurfacesSidecarStatusMessage() async throws {
        let generator = FakeSongGenerator()
        await generator.setStatusResult(.failure(ACEStepError.sidecarUnreachable("connection refused")))
        let sidecar = FakeSidecarManager()
        await sidecar.setStatus(SidecarStatus(
            state: .installedNotRunning, message: "ACE-Step is installed but not running — call ai.sidecarStart."))
        let router = makeRouter(songGenerator: generator, sidecarManager: sidecar)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.importGeneratedStems", params: ["jobId": .string("stems:job-1")]))

        #expect(!response.ok)
        #expect(response.error == "ACE-Step is installed but not running — call ai.sidecarStart.")
    }
}

/// `FakeSidecarManager`'s own mutators are `private extension` (scoped to
/// `SidecarCommandTests.swift`); mirror the same access-control pattern here
/// rather than widening its visibility beyond what M6 (i) intentionally set.
private extension FakeSidecarManager {
    func setStatus(_ status: SidecarStatus) { statusToReturn = status }
}
