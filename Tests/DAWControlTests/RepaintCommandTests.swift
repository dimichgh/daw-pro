import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for M6 (v-a) `ai.repaintAudio`. Repaint is a
/// SINGLE upstream job (unlike `ai.extractStems`/`ai.legoGenerate`'s
/// N-jobs-under-one-composite-id shape) that returns a plain
/// `SongGenerationSubmission` — the same wire shape as `ai.generateSong` —
/// polled via the already-proven `ai.generationStatus` route
/// (`SongGenerationCommandTests`), so this suite focuses on `ai.repaintAudio`
/// itself: routing, field-named param validation, and error translation,
/// using `FakeSongGenerator` (defined in `SongGenerationCommandTests.swift`)
/// so no real sidecar/network call happens. Real HTTP/wire-parsing behavior
/// is covered by `AIServicesTests/ACEStepRepaintClientTests`.
@MainActor
@Suite("AI repaint — control protocol (M6 v-a)")
struct RepaintCommandTests {
    private func makeRouter(
        songGenerator: FakeSongGenerator = FakeSongGenerator(),
        sidecarManager: FakeSidecarManager = FakeSidecarManager()
    ) -> CommandRouter {
        CommandRouter(store: ProjectStore(), sidecarManager: sidecarManager, songGenerator: songGenerator)
    }

    /// A real (tiny) file on disk so `ai.repaintAudio`'s existence check
    /// passes — the command validates `sourcePath` itself, independent of
    /// the (faked-out) song generator.
    private func writeSourceFile() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repaint-cmd-src-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mix.wav")
        try! Data([0x52, 0x49, 0x46, 0x46]).write(to: url)  // "RIFF" — contents unchecked, only existence matters
        return url.path
    }

    @Test("ai.repaintAudio is in the canonical command list")
    func commandIsCanonical() {
        #expect(CommandRouter.allCommands.contains("ai.repaintAudio"))
    }

    @Test("ai.repaintAudio requires 'sourcePath'")
    func requiresSourcePath() async throws {
        let router = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio", params: ["start": .number(0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("sourcePath") == true)
    }

    @Test("ai.repaintAudio rejects a 'sourcePath' that does not exist on disk")
    func rejectsMissingSourceFile() async throws {
        let router = makeRouter()
        let missingPath = "/tmp/definitely-not-here-\(UUID().uuidString).wav"
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(missingPath), "start": .number(0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("sourcePath") == true)
        #expect(response.error?.contains(missingPath) == true)
    }

    @Test("ai.repaintAudio requires 'start'")
    func requiresStart() async throws {
        let router = makeRouter()
        let sourcePath = writeSourceFile()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio", params: ["sourcePath": .string(sourcePath)]))
        #expect(!response.ok)
        #expect(response.error?.contains("start") == true)
    }

    @Test("ai.repaintAudio rejects a negative 'start'")
    func rejectsNegativeStart() async throws {
        let router = makeRouter()
        let sourcePath = writeSourceFile()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(-1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("start") == true)
    }

    @Test("ai.repaintAudio rejects an 'end' that is not greater than 'start'")
    func rejectsEndNotGreaterThanStart() async throws {
        let router = makeRouter()
        let sourcePath = writeSourceFile()

        let equalResponse = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(10), "end": .number(10)]))
        #expect(!equalResponse.ok)
        #expect(equalResponse.error?.contains("end") == true)

        let lessResponse = await router.handle(ControlRequest(
            id: "2", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(10), "end": .number(5)]))
        #expect(!lessResponse.ok)
        #expect(lessResponse.error?.contains("end") == true)
    }

    @Test("ai.repaintAudio rejects an unknown 'mode', naming the valid values")
    func rejectsUnknownMode() async throws {
        let router = makeRouter()
        let sourcePath = writeSourceFile()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(0), "mode": .string("bogus")]))
        #expect(!response.ok)
        #expect(response.error?.contains("mode") == true)
        #expect(response.error?.contains("conservative") == true)
        #expect(response.error?.contains("balanced") == true)
        #expect(response.error?.contains("aggressive") == true)
    }

    @Test("ai.repaintAudio rejects a 'strength' outside 0...1")
    func rejectsStrengthOutOfRange() async throws {
        let router = makeRouter()
        let sourcePath = writeSourceFile()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(0), "strength": .number(1.5)]))
        #expect(!response.ok)
        #expect(response.error?.contains("strength") == true)
    }

    @Test("ai.repaintAudio rejects a negative 'wavCrossfadeSec'")
    func rejectsNegativeWavCrossfadeSec() async throws {
        let router = makeRouter()
        let sourcePath = writeSourceFile()
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(0), "wavCrossfadeSec": .number(-0.1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("wavCrossfadeSec") == true)
    }

    @Test("ai.repaintAudio minimal params: defaults on RepaintRequest (mode balanced, no end/prompt/etc.)")
    func minimalParamsDefaults() async throws {
        let generator = FakeSongGenerator()
        let router = makeRouter(songGenerator: generator)
        let sourcePath = writeSourceFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(3)]))

        #expect(response.ok, "ai.repaintAudio failed: \(response.error ?? "?")")
        let request = await generator.lastRepaintRequest
        #expect(request?.srcAudioPath == sourcePath)
        #expect(request?.startSeconds == 3)
        #expect(request?.endSeconds == nil)
        #expect(request?.prompt == nil)
        #expect(request?.lyrics == nil)
        #expect(request?.mode == .balanced)
        #expect(request?.strength == nil)
        #expect(request?.wavCrossfadeSec == nil)
        #expect(request?.seed == nil)
        #expect(request?.model == nil)
    }

    @Test("ai.repaintAudio happy path forwards every field and threads the submission onto the wire")
    func happyPathForwardsFields() async throws {
        let generator = FakeSongGenerator()
        await generator.setRepaintResult(.success(
            SongGenerationSubmission(jobID: "job-repaint-99", state: .queued, queuePosition: 1)))
        let router = makeRouter(songGenerator: generator)
        let sourcePath = writeSourceFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: [
                "sourcePath": .string(sourcePath),
                "start": .number(8),
                "end": .number(24),
                "prompt": .string("driving rock drums, tighter groove"),
                "lyrics": .string("[Chorus]\nhold the line"),
                "mode": .string("aggressive"),
                "strength": .number(0.65),
                "wavCrossfadeSec": .number(0.25),
                "seed": .number(777),
                "model": .string("acestep-v15-xl-sft"),
            ]))

        #expect(response.ok, "ai.repaintAudio failed: \(response.error ?? "?")")
        #expect(response.result?["jobId"]?.stringValue == "job-repaint-99")
        #expect(response.result?["state"]?.stringValue == "queued")
        #expect(response.result?["queuePosition"]?.doubleValue == 1)

        let request = await generator.lastRepaintRequest
        #expect(request?.srcAudioPath == sourcePath)
        #expect(request?.startSeconds == 8)
        #expect(request?.endSeconds == 24)
        #expect(request?.prompt == "driving rock drums, tighter groove")
        #expect(request?.lyrics == "[Chorus]\nhold the line")
        #expect(request?.mode == .aggressive)
        #expect(request?.strength == 0.65)
        #expect(request?.wavCrossfadeSec == 0.25)
        #expect(request?.seed == 777)
        #expect(request?.model == "acestep-v15-xl-sft")
    }

    @Test("ai.repaintAudio surfaces sidecarUnreachable as the SidecarManager's own actionable message")
    func surfacesSidecarStatusMessage() async throws {
        let generator = FakeSongGenerator()
        await generator.setRepaintResult(.failure(ACEStepError.sidecarUnreachable("connection refused")))
        let sidecar = FakeSidecarManager()
        await sidecar.setRepaintTestStatus(SidecarStatus(
            state: .installedNotRunning, message: "ACE-Step is installed but not running — call ai.sidecarStart."))
        let router = makeRouter(songGenerator: generator, sidecarManager: sidecar)
        let sourcePath = writeSourceFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(0)]))

        #expect(!response.ok)
        #expect(response.error == "ACE-Step is installed but not running — call ai.sidecarStart.")
    }

    @Test("ai.repaintAudio surfaces a non-connectivity failure verbatim (job-failed-class errors)")
    func surfacesOtherErrorsVerbatim() async throws {
        let generator = FakeSongGenerator()
        await generator.setRepaintResult(.failure(
            ACEStepError.requestFailed(status: 429, body: "Server busy: queue is full")))
        let router = makeRouter(songGenerator: generator)
        let sourcePath = writeSourceFile()

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.repaintAudio",
            params: ["sourcePath": .string(sourcePath), "start": .number(0)]))

        #expect(!response.ok)
        #expect(response.error?.contains("429") == true)
        #expect(response.error?.contains("queue is full") == true)
    }
}

/// `FakeSidecarManager`'s own mutators are `private extension`, scoped to
/// `SidecarCommandTests.swift`/`SongGenerationCommandTests.swift` — mirror
/// the same access-control pattern here with a distinctly-named helper
/// (Swift doesn't allow two `private extension`s in different files to
/// declare the same member name on the same type).
private extension FakeSidecarManager {
    func setRepaintTestStatus(_ status: SidecarStatus) { statusToReturn = status }
}
