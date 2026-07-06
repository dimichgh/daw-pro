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
        let store = ProjectStore()
        store.media = FakeMedia()
        return CommandRouter(store: store, sidecarManager: sidecarManager, songGenerator: songGenerator)
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
}

/// `FakeSidecarManager`'s own mutators are `private extension` (scoped to
/// `SidecarCommandTests.swift`); mirror the same access-control pattern here
/// rather than widening its visibility beyond what M6 (i) intentionally set.
private extension FakeSidecarManager {
    func setStatus(_ status: SidecarStatus) { statusToReturn = status }
}
