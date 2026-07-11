import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for the M6 (v-b) clip vocal-fix flow:
/// `ai.fixClipRegion` (submit) + `ai.importClipFix` (land) — routing over a
/// real `ProjectStore` with a stub render engine + `FakeSongGenerator` (no real
/// sidecar/network), field-named param validation, the DAWControl adapter's
/// `ClipRepaintRequest` → `RepaintRequest` field mapping, and error
/// translation. The store-side geometry/comp behavior is proven headless by
/// `DAWCoreTests/ClipFixTests`.
@MainActor
@Suite("AI clip fix — control protocol (M6 v-b)")
struct ClipFixCommandTests {
    private func writeTinyWAV() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-fix-cmd-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fix.wav")
        try! Data([0x52, 0x49, 0x46, 0x46]).write(to: url)  // "RIFF" — copyable, existence only
        return url.path
    }

    private func audioTrack(clipLength: Double = 100, midi: Bool = false) -> (Track, Clip) {
        let clip = midi
            ? Clip(name: "M", startBeat: 0, lengthBeats: clipLength, notes: [])
            : Clip(name: "Vox", startBeat: 0, lengthBeats: clipLength,
                   audioFileURL: URL(fileURLWithPath: "/src.wav"))
        let track = Track(name: midi ? "Inst" : "Vox", kind: midi ? .instrument : .audio, clips: [clip])
        return (track, clip)
    }

    /// A router whose store carries `track`, `engine` (held by the CALLER — the
    /// store's `engine` is weak), and a hermetic imports directory. The router
    /// wires the store's generation source over `generator` for us.
    private func makeRouter(
        track: Track,
        engine: FakeRenderEngine,
        generator: FakeSongGenerator = FakeSongGenerator(),
        sidecar: FakeSidecarManager = FakeSidecarManager()
    ) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore(tracks: [track])
        store.engine = engine
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-fix-cmd-dest-\(UUID().uuidString)")
        let router = CommandRouter(store: store, sidecarManager: sidecar, songGenerator: generator)
        return (router, store)
    }

    // MARK: 13 — routing + happy path

    @Test("both commands are canonical")
    func canonical() {
        #expect(CommandRouter.allCommands.contains("ai.fixClipRegion"))
        #expect(CommandRouter.allCommands.contains("ai.importClipFix"))
    }

    @Test("ai.fixClipRegion echoes placement, ai.importClipFix returns the group with 2 lanes")
    func happyPathBothCommands() async throws {
        let (track, clip) = audioTrack()
        let generator = FakeSongGenerator()
        await generator.setRepaintResult(.success(
            SongGenerationSubmission(jobID: "fix-1", state: .queued, queuePosition: 2)))
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(track: track, engine: engine, generator: generator)

        let submit = await router.handle(ControlRequest(
            id: "1", command: "ai.fixClipRegion", params: [
                "trackId": .string(track.id.uuidString),
                "clipId": .string(clip.id.uuidString),
                "startBeat": .number(40), "endBeat": .number(50),
                "contextSeconds": .number(10),
            ]))
        #expect(submit.ok, "ai.fixClipRegion failed: \(submit.error ?? "?")")
        #expect(submit.result?["jobId"]?.stringValue == "fix-1")
        #expect(submit.result?["state"]?.stringValue == "queued")
        #expect(submit.result?["queuePosition"]?.doubleValue == 2)
        #expect(submit.result?["windowStartBeat"]?.doubleValue == 20)
        #expect(submit.result?["windowEndBeat"]?.doubleValue == 70)
        #expect(submit.result?["regionStartBeat"]?.doubleValue == 40)
        #expect(submit.result?["regionEndBeat"]?.doubleValue == 50)
        #expect(submit.result?["repaintStartSeconds"]?.doubleValue == 10)
        #expect(submit.result?["repaintEndSeconds"]?.doubleValue == 15)
        #expect(submit.result?["bouncePath"]?.stringValue?.contains("fix-bounce") == true)

        // Poll surface: script the status as succeeded with a real WAV.
        await generator.setStatusResult(.success(
            SongGenerationStatus(jobID: "fix-1", state: .succeeded, audioPath: writeTinyWAV())))

        let land = await router.handle(ControlRequest(
            id: "2", command: "ai.importClipFix", params: ["jobId": .string("fix-1")]))
        #expect(land.ok, "ai.importClipFix failed: \(land.error ?? "?")")
        #expect(land.result?["laneName"]?.stringValue == "AI Fix 1")
        #expect(land.result?["trackId"]?.stringValue == track.id.uuidString)
        let group = try #require(land.result?["group"])
        #expect(group["lanes"]?.arrayValue?.count == 2)
        #expect(group["comp"]?.arrayValue?.count == 3)
        withExtendedLifetime(engine) {}  // the store holds engine weakly — pin it through the submit
    }

    // MARK: 14 — field-named validation

    @Test("ai.fixClipRegion field-named validation")
    func fixValidation() async throws {
        let (track, clip) = audioTrack()
        // Every case below fails validation BEFORE the store's engine guard, so
        // the (weak, immediately-dropped) engine is never reached.
        let (router, _) = makeRouter(track: track, engine: FakeRenderEngine())
        func fix(_ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "1", command: "ai.fixClipRegion", params: params))
        }
        let base: [String: JSONValue] = [
            "trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString),
            "startBeat": .number(40), "endBeat": .number(50),
        ]

        // Missing startBeat.
        var r = await fix(["trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString),
                           "endBeat": .number(50)])
        #expect(!r.ok && r.error?.contains("startBeat") == true)
        // Non-numeric endBeat.
        r = await fix(["trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString),
                       "startBeat": .number(40), "endBeat": .string("nope")])
        #expect(!r.ok && r.error?.contains("endBeat") == true)
        // endBeat <= startBeat.
        r = await fix(["trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString),
                       "startBeat": .number(50), "endBeat": .number(40)])
        #expect(!r.ok && r.error?.contains("endBeat") == true)
        // Bad mode names the valid values.
        r = await fix(base.merging(["mode": .string("bogus")]) { _, b in b })
        #expect(!r.ok && r.error?.contains("conservative") == true
            && r.error?.contains("balanced") == true && r.error?.contains("aggressive") == true)
        // strength out of range.
        r = await fix(base.merging(["strength": .number(1.5)]) { _, b in b })
        #expect(!r.ok && r.error?.contains("strength") == true)
        // contextSeconds out of range.
        r = await fix(base.merging(["contextSeconds": .number(100)]) { _, b in b })
        #expect(!r.ok && r.error?.contains("contextSeconds") == true)
    }

    @Test("ai.importClipFix requires 'jobId'")
    func importRequiresJobId() async throws {
        let (track, _) = audioTrack()
        let (router, _) = makeRouter(track: track, engine: FakeRenderEngine())
        let r = await router.handle(ControlRequest(id: "1", command: "ai.importClipFix", params: [:]))
        #expect(!r.ok && r.error?.contains("jobId") == true)
    }

    // MARK: 15 — adapter field mapping

    @Test("SongGenerationImportSource.submitRepaint maps every field; crossfade fields left nil")
    func adapterFieldMapping() async throws {
        let generator = FakeSongGenerator()
        await generator.setRepaintResult(.success(
            SongGenerationSubmission(jobID: "job-abc", state: .queued, queuePosition: 7)))
        let source = SongGenerationImportSource(generator: generator)

        let receipt = try await source.submitRepaint(ClipRepaintRequest(
            sourceAudioPath: "/bounce.wav", startSeconds: 3, endSeconds: 9,
            prompt: "clear vocal", lyrics: "[Chorus]\nhold on",
            mode: .aggressive, strength: 0.6, seed: 42, model: "acestep-v15-xl-sft"))

        #expect(receipt.jobID == "job-abc")
        #expect(receipt.queuePosition == 7)

        let repaint = try #require(await generator.lastRepaintRequest)
        #expect(repaint.srcAudioPath == "/bounce.wav")
        #expect(repaint.startSeconds == 3)
        #expect(repaint.endSeconds == 9)
        #expect(repaint.prompt == "clear vocal")
        #expect(repaint.lyrics == "[Chorus]\nhold on")
        #expect(repaint.mode == .aggressive)              // raw-value 1:1 mapping
        #expect(repaint.strength == 0.6)
        #expect(repaint.seed == 42)
        #expect(repaint.model == "acestep-v15-xl-sft")
        // Deliberately nil — the latent-crossfade default + comp splice own joins.
        #expect(repaint.wavCrossfadeSec == nil)
        #expect(repaint.latentCrossfadeFrames == nil)
    }

    // MARK: 16 — error translation

    @Test("ai.fixClipRegion surfaces sidecarUnreachable as the SidecarManager's own message")
    func fixSurfacesSidecarStatus() async throws {
        let (track, clip) = audioTrack()
        let generator = FakeSongGenerator()
        await generator.setRepaintResult(.failure(ACEStepError.sidecarUnreachable("connection refused")))
        let sidecar = FakeSidecarManager()
        await sidecar.setClipFixTestStatus(SidecarStatus(
            state: .installedNotRunning,
            message: "ACE-Step is installed but not running — call ai.sidecarStart."))
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(track: track, engine: engine, generator: generator, sidecar: sidecar)

        let r = await router.handle(ControlRequest(
            id: "1", command: "ai.fixClipRegion", params: [
                "trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString),
                "startBeat": .number(40), "endBeat": .number(50),
            ]))
        #expect(!r.ok)
        #expect(r.error == "ACE-Step is installed but not running — call ai.sidecarStart.")
        withExtendedLifetime(engine) {}  // the store holds engine weakly — pin it through the submit
    }

    @Test("store errors surface verbatim: unknown job / MIDI clip")
    func storeErrorsVerbatim() async throws {
        // Unknown pending job → clipFixJobNotFound message verbatim.
        let (track, _) = audioTrack()
        let (router, _) = makeRouter(track: track, engine: FakeRenderEngine())
        let unknown = await router.handle(ControlRequest(
            id: "1", command: "ai.importClipFix", params: ["jobId": .string("nope")]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no pending clip fix with jobId 'nope'") == true)

        // MIDI clip → clipFixRequiresAudioClip message verbatim (the engine guard
        // passes first, so a live engine is required to reach the MIDI check).
        let (midiTrack, midiClip) = audioTrack(midi: true)
        let engine = FakeRenderEngine()
        let (midiRouter, _) = makeRouter(track: midiTrack, engine: engine)
        let midiResp = await midiRouter.handle(ControlRequest(
            id: "1", command: "ai.fixClipRegion", params: [
                "trackId": .string(midiTrack.id.uuidString), "clipId": .string(midiClip.id.uuidString),
                "startBeat": .number(1), "endBeat": .number(4),
            ]))
        #expect(!midiResp.ok)
        #expect(midiResp.error?.contains("MIDI clip") == true)
        #expect(midiResp.error?.contains("ai.fixClipRegion applies only to audio clips") == true)
        withExtendedLifetime(engine) {}  // the store holds engine weakly — pin it through the submit
    }
}

/// `FakeSidecarManager`'s mutators are `private extension`s scoped per test
/// file (Swift forbids two files declaring the same member on the same type);
/// mirror that pattern with a distinctly-named helper.
private extension FakeSidecarManager {
    func setClipFixTestStatus(_ status: SidecarStatus) { statusToReturn = status }
}
