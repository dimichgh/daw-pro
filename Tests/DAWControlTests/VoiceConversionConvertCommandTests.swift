import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Test double for `VoiceConverting` (m10-p-4) — the `FakeVoiceConversionManager`
/// sibling for the RVC facade's convert/train calls (process lifecycle stays a
/// separate concern, mocked separately — the `songGenerator`/`sidecarManager`
/// split precedent). Lets `vc.convertVocals`/`vc.trainVoice` be exercised
/// without a real sidecar/network call. Real HTTP behavior against a stub
/// facade lives in `AIServicesTests/VoiceConversionClientTests`.
actor FakeVoiceConverting: VoiceConverting {
    var convertResult: Result<VoiceConvertResult, Error> = .success(VoiceConvertResult(
        outputPath: "/tmp/converted.wav", voiceId: "base", inputSeconds: 5, engineLoadSeconds: 0.5,
        inferSeconds: 0.135, rtf: 37.0, sampleRate: 40000, realConversion: false,
        note: "base is the untrained generic target"))
    var trainResult: Result<Data, Error> = .failure(VoiceConversionError.requestFailed(
        status: 501, code: "trainingNotYetAvailable",
        message: "contract reserved — training ships with the Voice panel (m10-p-5/p-6)"))

    /// m10-p-5 (`vc.listVoices`): the facade's REAL at-rest shapes —
    /// `/v1/voice/list` is real-user-voices-only (empty until training
    /// ships), and `"base"` lives on its own status endpoint. The command
    /// composes them via `availableVoiceTargets()`.
    var listVoicesResult: Result<[VoiceDescriptor], Error> = .success([])
    var voiceStatusResult: Result<VoiceDescriptor, Error> = .success(VoiceDescriptor(
        id: "base", name: "Base (untrained)", state: "ready", kind: "builtin", trained: false,
        note: "pipeline smoke target — not a real voice"))

    private(set) var convertCalls: [VoiceConvertRequest] = []
    private(set) var trainCalls: [VoiceTrainRequest] = []
    private(set) var listVoicesCalls = 0
    private(set) var voiceStatusCalls: [String] = []

    func listVoices() async throws -> [VoiceDescriptor] {
        listVoicesCalls += 1
        return try listVoicesResult.get()
    }

    func voiceStatus(voiceID: String) async throws -> VoiceDescriptor {
        voiceStatusCalls.append(voiceID)
        return try voiceStatusResult.get()
    }

    func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        convertCalls.append(request)
        return try convertResult.get()
    }

    func train(_ request: VoiceTrainRequest) async throws -> Data {
        trainCalls.append(request)
        return try trainResult.get()
    }
}

/// Control-protocol coverage for m10-p-4 `vc.convertVocals` / `vc.trainVoice`
/// — the pipeline-glue commands that turn a `VoiceConverting` call (a
/// `FakeVoiceConverting` here) into project material via
/// `ProjectStore.importConvertedVoice` (real store logic — undo/AI-flag/
/// stable-copy behavior itself is covered by
/// `DAWCoreTests/VoiceConversionImportTests`). This suite proves routing,
/// param shape (including the exactly-one-of `clipId`/`path` law), response
/// encoding, and error-surfacing — no sidecar install or network needed.
@MainActor
@Suite("Voice conversion — convert/train control protocol (m10-p-4)")
struct VoiceConversionConvertCommandTests {
    /// Writes a minimal valid PCM16 mono WAV to a fresh temp file — stands in
    /// for the RVC facade's `outputPath` (a real header keeps the fixture
    /// honest; `FakeMedia` never actually reads it, but `importConvertedVoice`
    /// DOES check the file exists on disk before importing).
    private func writeTinyWAV(name: String = "converted.wav") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-cmd-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var data = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        data.append(Data("RIFF".utf8)); data.append(le32(36 + 16)); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); data.append(le32(16)); data.append(le16(1)); data.append(le16(1))
        data.append(le32(48000)); data.append(le32(96000)); data.append(le16(2)); data.append(le16(16))
        data.append(Data("data".utf8)); data.append(le32(16))
        data.append(Data(repeating: 0, count: 16))
        try data.write(to: url)
        return url
    }

    private func makeStore() -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-cmd-dest-\(UUID().uuidString)")
        return store
    }

    private func makeRouter(
        store: ProjectStore? = nil,
        voiceConverting: FakeVoiceConverting = FakeVoiceConverting(),
        voiceConversion: FakeVoiceConversionManager = FakeVoiceConversionManager()
    ) -> (CommandRouter, FakeVoiceConverting) {
        let router = CommandRouter(
            store: store ?? makeStore(),
            voiceConversionManager: voiceConversion,
            voiceConverting: voiceConverting)
        return (router, voiceConverting)
    }

    @Test("both vc.convertVocals and vc.trainVoice are in the canonical command list")
    func commandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("vc.convertVocals"))
        #expect(CommandRouter.allCommands.contains("vc.trainVoice"))
    }

    @Test("adding the convert/train pair left every vc.sidecar*/ai.sidecar* name untouched")
    func siblingNamesUnchanged() {
        #expect(CommandRouter.allCommands.contains("vc.sidecarStatus"))
        #expect(CommandRouter.allCommands.contains("vc.sidecarStart"))
        #expect(CommandRouter.allCommands.contains("vc.sidecarStop"))
        #expect(CommandRouter.allCommands.contains("ai.sidecarStatus"))
    }

    // MARK: - vc.convertVocals: happy paths

    @Test("path form: happy path imports a new AI-flagged track + clip, response shape complete")
    func convertVocalsPathFormHappyPath() async throws {
        let wav = try writeTinyWAV()
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.success(VoiceConvertResult(
            outputPath: wav.path, voiceId: "base", inputSeconds: 5, engineLoadSeconds: 0.5,
            inferSeconds: 0.135, rtf: 37.13, sampleRate: 40000, realConversion: false,
            note: "base is the untrained generic target")))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["path": .string(wav.path), "voiceId": .string("base")]))

        #expect(response.ok, "vc.convertVocals failed: \(response.error ?? "?")")
        #expect(response.result?["outputPath"]?.stringValue == wav.path)
        #expect(response.result?["realConversion"]?.boolValue == false)
        #expect(response.result?["inputSeconds"]?.doubleValue == 5)
        #expect(response.result?["inferSeconds"]?.doubleValue == 0.135)
        #expect(response.result?["rtf"]?.doubleValue == 37.13)
        #expect(response.result?["sampleRate"]?.doubleValue == 40000)
        #expect(response.result?["note"]?.stringValue == "base is the untrained generic target")
        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let clipId = try #require(response.result?["clipId"]?.stringValue)
        #expect(UUID(uuidString: trackId) != nil)
        #expect(UUID(uuidString: clipId) != nil)
        // engineLoadSeconds/voiceId are deliberately NOT in the response shape
        // (m10-p-4 design) — only trackId/clipId/outputPath/realConversion/
        // inputSeconds/inferSeconds/rtf?/sampleRate/note?.
        #expect(response.result?["engineLoadSeconds"] == nil)
        #expect(response.result?["voiceId"] == nil)

        let calls = await converting.convertCalls
        #expect(calls.count == 1)
        #expect(calls[0].inputPath == wav.path)
        #expect(calls[0].voiceId == "base")
        #expect(calls[0].pitchSemitones == 0, "an omitted pitchSemitones defaults to 0")
    }

    @Test("path form: an absent rtf/note stay omitted on the wire, not null")
    func convertVocalsOmitsAbsentOptionalFields() async throws {
        let wav = try writeTinyWAV()
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.success(VoiceConvertResult(
            outputPath: wav.path, voiceId: "my-voice", inputSeconds: 3, engineLoadSeconds: 0,
            inferSeconds: 0.05, rtf: nil, sampleRate: 40000, realConversion: true, note: nil)))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["path": .string(wav.path), "voiceId": .string("my-voice")]))

        #expect(response.ok, "vc.convertVocals failed: \(response.error ?? "?")")
        #expect(response.result?["rtf"] == nil)
        #expect(response.result?["note"] == nil)
    }

    @Test("path form: an empty trackName resolves to 'Voice: <voiceId>'")
    func convertVocalsDefaultsTrackName() async throws {
        let wav = try writeTinyWAV()
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.success(VoiceConvertResult(
            outputPath: wav.path, voiceId: "my-voice", inputSeconds: 3, engineLoadSeconds: 0,
            inferSeconds: 0.05, rtf: nil, sampleRate: 40000, realConversion: true, note: nil)))
        let store = makeStore()
        let (router, _) = makeRouter(store: store, voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["path": .string(wav.path), "voiceId": .string("my-voice")]))

        #expect(response.ok)
        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let track = try #require(store.tracks.first { $0.id.uuidString == trackId })
        #expect(track.name == "Voice: my-voice")
    }

    @Test("clipId form: resolves the clip's backing audio and its own start beat as the default atBeat")
    func convertVocalsClipIdFormResolvesSource() async throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let sourceURL = URL(fileURLWithPath: "/tmp/some-vocal-stem.wav")
        let sourceClip = try store.importAudio(url: sourceURL, toTrack: track.id, atBeat: 16)

        let wav = try writeTinyWAV(name: "converted-clip.wav")
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.success(VoiceConvertResult(
            outputPath: wav.path, voiceId: "base", inputSeconds: 1, engineLoadSeconds: 0,
            inferSeconds: 0.02, rtf: nil, sampleRate: 40000, realConversion: false, note: "smoke")))
        let (router, _) = makeRouter(store: store, voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["clipId": .string(sourceClip.id.uuidString), "voiceId": .string("base")]))

        #expect(response.ok, "vc.convertVocals failed: \(response.error ?? "?")")
        let calls = await converting.convertCalls
        #expect(calls.count == 1)
        #expect(calls[0].inputPath == sourceURL.path, "the clip's FULL backing recording is what gets converted")

        let clipId = try #require(response.result?["clipId"]?.stringValue)
        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let newTrack = try #require(store.tracks.first { $0.id.uuidString == trackId })
        let newClip = try #require(newTrack.clips.first { $0.id.uuidString == clipId })
        #expect(newClip.startBeat == 16, "defaults atBeat to the source clip's own start beat")
    }

    @Test("an explicit atBeat overrides the clipId-derived default")
    func convertVocalsExplicitAtBeatOverridesClipDefault() async throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let sourceClip = try store.importAudio(
            url: URL(fileURLWithPath: "/tmp/some-vocal-stem.wav"), toTrack: track.id, atBeat: 16)
        let wav = try writeTinyWAV(name: "converted-clip2.wav")
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.success(VoiceConvertResult(
            outputPath: wav.path, voiceId: "base", inputSeconds: 1, engineLoadSeconds: 0,
            inferSeconds: 0.02, rtf: nil, sampleRate: 40000, realConversion: false, note: nil)))
        let (router, _) = makeRouter(store: store, voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: [
                "clipId": .string(sourceClip.id.uuidString), "voiceId": .string("base"),
                "atBeat": .number(4),
            ]))

        #expect(response.ok)
        let clipId = try #require(response.result?["clipId"]?.stringValue)
        let trackId = try #require(response.result?["trackId"]?.stringValue)
        let newTrack = try #require(store.tracks.first { $0.id.uuidString == trackId })
        let newClip = try #require(newTrack.clips.first { $0.id.uuidString == clipId })
        #expect(newClip.startBeat == 4)
    }

    @Test("explicit pitchSemitones forwards through unchanged, not re-validated client-side")
    func convertVocalsForwardsPitchSemitones() async throws {
        let wav = try writeTinyWAV()
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.success(VoiceConvertResult(
            outputPath: wav.path, voiceId: "base", inputSeconds: 1, engineLoadSeconds: 0,
            inferSeconds: 0.02, rtf: nil, sampleRate: 40000, realConversion: false, note: nil)))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: [
                "path": .string(wav.path), "voiceId": .string("base"), "pitchSemitones": .number(-7),
            ]))

        #expect(response.ok, "vc.convertVocals failed: \(response.error ?? "?")")
        let calls = await converting.convertCalls
        #expect(calls[0].pitchSemitones == -7)
    }

    // MARK: - vc.convertVocals: param-shape rejections

    @Test("exactly-one-of: passing both clipId and path is rejected before any convert call")
    func convertVocalsRejectsBothClipIdAndPath() async throws {
        let converting = FakeVoiceConverting()
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: [
                "clipId": .string(UUID().uuidString), "path": .string("/tmp/x.wav"),
                "voiceId": .string("base"),
            ]))

        #expect(!response.ok)
        #expect(response.error?.contains("not both") == true)
        #expect(await converting.convertCalls.isEmpty)
    }

    @Test("exactly-one-of: passing neither clipId nor path is rejected")
    func convertVocalsRejectsNeitherClipIdNorPath() async throws {
        let converting = FakeVoiceConverting()
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals", params: ["voiceId": .string("base")]))

        #expect(!response.ok)
        #expect(await converting.convertCalls.isEmpty)
    }

    @Test("a relative path is rejected as not absolute")
    func convertVocalsRejectsRelativePath() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["path": .string("relative/vocal.wav"), "voiceId": .string("base")]))
        #expect(!response.ok)
        #expect(response.error == "'path' must be an absolute path")
    }

    @Test("a MIDI clip's id is rejected with the store's teaching error, naming vc.convertVocals")
    func convertVocalsRejectsMIDIClip() async throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id)
        let (router, _) = makeRouter(store: store)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["clipId": .string(clip.id.uuidString), "voiceId": .string("base")]))

        #expect(!response.ok)
        #expect(response.error?.contains("vc.convertVocals") == true)
        #expect(response.error?.contains("MIDI clip") == true)
    }

    @Test("vc.convertVocals rejects unknown params")
    func convertVocalsRejectsUnknownParams() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["path": .string("/tmp/x.wav"), "voiceId": .string("base"), "bogus": .bool(true)]))
        #expect(!response.ok)
    }

    // MARK: - vc.convertVocals: error surfacing

    @Test("the facade's own teaching error (e.g. voiceNotReady) surfaces verbatim")
    func convertVocalsSurfacesFacadeErrorVerbatim() async throws {
        let wav = try writeTinyWAV()
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.failure(VoiceConversionError.requestFailed(
            status: 409, code: "voiceNotReady",
            message: "voice 'x' exists but has no MLX model (model.npz) yet")))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["path": .string(wav.path), "voiceId": .string("x")]))

        #expect(!response.ok)
        #expect(response.error?.contains("model.npz") == true)
    }

    @Test("an unreachable sidecar is translated to the manager's own actionable status message")
    func convertVocalsTranslatesSidecarUnreachable() async throws {
        let wav = try writeTinyWAV()
        let converting = FakeVoiceConverting()
        await converting.setConvertResult(.failure(VoiceConversionError.sidecarUnreachable("connection refused")))
        let voiceConversion = FakeVoiceConversionManager()
        await voiceConversion.stubStatus(
            VoiceConversionStatus(state: .installedNotRunning, message: "call vc.sidecarStart first"))
        let (router, _) = makeRouter(voiceConverting: converting, voiceConversion: voiceConversion)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.convertVocals",
            params: ["path": .string(wav.path), "voiceId": .string("base")]))

        #expect(!response.ok)
        #expect(response.error == "call vc.sidecarStart first")
    }

    // MARK: - vc.trainVoice

    @Test("shape passes through to the client verbatim (name/datasetDir/voiceId/epochs)")
    func trainVoiceForwardsRequestShape() async throws {
        let converting = FakeVoiceConverting()
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.trainVoice",
            params: [
                "name": .string("My Voice"), "datasetDir": .string("/tmp/dataset"),
                "voiceId": .string("custom"), "epochs": .number(50),
            ]))

        #expect(!response.ok, "today the facade always answers 501 — this is not a success path")
        let calls = await converting.trainCalls
        #expect(calls.count == 1)
        #expect(calls[0].name == "My Voice")
        #expect(calls[0].datasetDir == "/tmp/dataset")
        #expect(calls[0].voiceId == "custom")
        #expect(calls[0].epochs == 50)
    }

    @Test("the facade's 501 trainingNotYetAvailable teaching error reaches the wire verbatim")
    func trainVoiceSurfaces501Verbatim() async throws {
        let converting = FakeVoiceConverting()
        await converting.setTrainResult(.failure(VoiceConversionError.requestFailed(
            status: 501, code: "trainingNotYetAvailable",
            message: "contract reserved — training ships with the Voice panel (m10-p-5/p-6)")))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.trainVoice",
            params: ["name": .string("My Voice"), "datasetDir": .string("/tmp/dataset")]))

        #expect(!response.ok)
        #expect(response.error?.contains("trainingNotYetAvailable") == true)
        #expect(response.error?.contains("m10-p-5/p-6") == true)
    }

    @Test("a future 2xx success passes the raw JSON body through unchanged")
    func trainVoicePassesThroughFutureSuccess() async throws {
        let converting = FakeVoiceConverting()
        let rawBody = #"{"voiceId":"custom","state":"queued"}"#.data(using: .utf8)!
        await converting.setTrainResult(.success(rawBody))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.trainVoice",
            params: ["name": .string("My Voice"), "datasetDir": .string("/tmp/dataset")]))

        #expect(response.ok, "vc.trainVoice failed: \(response.error ?? "?")")
        #expect(response.result?["voiceId"]?.stringValue == "custom")
        #expect(response.result?["state"]?.stringValue == "queued")
    }

    @Test("an omitted voiceId/epochs are never sent as stray keys")
    func trainVoiceOmitsUnsetOptionalFields() async throws {
        let converting = FakeVoiceConverting()
        let (router, _) = makeRouter(voiceConverting: converting)

        _ = await router.handle(ControlRequest(
            id: "1", command: "vc.trainVoice",
            params: ["name": .string("My Voice"), "datasetDir": .string("/tmp/dataset")]))

        let calls = await converting.trainCalls
        #expect(calls.count == 1)
        #expect(calls[0].voiceId == nil)
        #expect(calls[0].epochs == nil)
    }

    @Test("a relative datasetDir is rejected as not absolute")
    func trainVoiceRejectsRelativeDatasetDir() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.trainVoice",
            params: ["name": .string("My Voice"), "datasetDir": .string("relative/dir")]))
        #expect(!response.ok)
        #expect(response.error == "'datasetDir' must be an absolute path")
    }

    @Test("vc.trainVoice rejects unknown params")
    func trainVoiceRejectsUnknownParams() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.trainVoice",
            params: ["name": .string("x"), "datasetDir": .string("/tmp/x"), "bogus": .bool(true)]))
        #expect(!response.ok)
    }
}

private extension FakeVoiceConverting {
    func setConvertResult(_ result: Result<VoiceConvertResult, Error>) { convertResult = result }
    func setTrainResult(_ result: Result<Data, Error>) { trainResult = result }
}

/// File-scoped helper for `FakeVoiceConversionManager` (declared in
/// `VoiceConversionCommandTests.swift`) — that file's own `setStatus` helper
/// is `private` (file-scoped), so this file needs its own. `statusToReturn`
/// itself is internal (not private) on the actor, so this is a thin,
/// same-module wrapper, not a new seam.
private extension FakeVoiceConversionManager {
    func stubStatus(_ status: VoiceConversionStatus) { statusToReturn = status }
}
