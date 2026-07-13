import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Engine fake for M5 (iv-d) `render.measureLoudness`/`render.bounce`/
/// `render.stems`: `renderOffline` returns a controllable stub buffer
/// (default: a non-silent 997 Hz calibration tone, spec §7 iv-a) regardless
/// of the requested track subset — sufficient for control-layer route,
/// validation, and response-shape coverage. Real audio correctness (subset
/// parity under forced PDC targets, Σ-stems-≡-mixdown) is proven by
/// OfflineBufferRenderTests/StemNullTests (iv-b/iv-c) and the live E2E
/// script; this fake never touches AVFoundation.
@MainActor
final class FakeRenderEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    /// Every `renderOffline` call (measureLoudness/bounce/each stem pass)
    /// returns this buffer, regardless of the requested tracks/window — good
    /// enough to prove routing/validation/response shape without a real
    /// engine. Tests swap it (`.tone`/`.silence`) per scenario.
    var renderOfflineStub = FakeRenderEngine.tone(dBFS: -20)
    private(set) var renderOfflineCalls: [[UUID: Int]?] = []

    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        renderOfflineCalls.append(forcedCompensationTargets)
        return renderOfflineStub
    }

    private(set) var writtenFiles: [URL] = []

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        writtenFiles.append(url)
        return AudioFileInfo(
            durationSeconds: audio.sampleRate > 0 ? Double(audio.frameCount) / audio.sampleRate : 0,
            sampleRate: audio.sampleRate, channelCount: audio.channelData.count)
    }

    /// A stereo 997 Hz sine at `dBFS` (BS.1770-4's calibration frequency,
    /// spec §7 iv-a — the −0.691 gate offset cancels K-weighting gain there,
    /// so `integratedLufs`/`truePeakDbtp` land close to `dBFS`); non-silent
    /// so happy-path responses carry real, checkable numbers.
    static func tone(dBFS: Double, seconds: Double = 1.0, sampleRate: Double = 48_000) -> RenderedAudio {
        let amplitude = pow(10.0, dBFS / 20.0)
        let frameCount = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            samples[i] = Float(amplitude * sin(2.0 * Double.pi * 997.0 * Double(i) / sampleRate))
        }
        return RenderedAudio(sampleRate: sampleRate, channelData: [samples, samples])
    }

    /// Digital silence — below the −70 LUFS gate (the `bounceSilent` fixture).
    static func silence(seconds: Double = 1.0, sampleRate: Double = 48_000) -> RenderedAudio {
        let frameCount = Int(seconds * sampleRate)
        let samples = [Float](repeating: 0, count: frameCount)
        return RenderedAudio(sampleRate: sampleRate, channelData: [samples, samples])
    }
}

/// Control-protocol coverage for M5 (iv-d) `render.measureLoudness` /
/// `render.bounce` / `render.stems` (spec §4.4, §7 iv-d): happy paths,
/// field-named param validation, store rejections surfaced verbatim, and
/// response shapes matching the model's own Codable (`LoudnessMeasureResult`
/// / `BounceResult` / `StemExportResult`, wire-never-drifts). `render.mixdown`
/// is untouched — covered by its own existing tests.
@MainActor
@Suite("Render commands — control protocol (M5 iv-d)")
struct RenderCommandTests {
    private func makeRouter(engine: FakeRenderEngine? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    // MARK: - render.measureLoudness

    @Test("happy path: non-silent tone measures, writes nothing to disk")
    func measureLoudnessHappyPath() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.measureLoudness",
            params: ["durationSeconds": .number(1.0)]))
        #expect(response.ok, "measureLoudness failed: \(response.error ?? "?")")
        let integrated = try #require(response.result?["measurement"]?["integratedLufs"]?.doubleValue)
        let truePeak = try #require(response.result?["measurement"]?["truePeakDbtp"]?.doubleValue)
        #expect(abs(integrated - (-20)) < 0.5, "integrated ≈ -20 LUFS (got \(integrated))")
        #expect(abs(truePeak - (-20)) < 0.5, "true peak ≈ -20 dBTP (got \(truePeak))")
        #expect(response.result?["durationSeconds"]?.doubleValue == 1.0)
        #expect(response.result?["sampleRate"]?.doubleValue == 48_000)
        #expect(engine.writtenFiles.isEmpty, "measureLoudness must write nothing to disk")
    }

    @Test("fromBeat/durationSeconds are field-named validated")
    func measureLoudnessValidation() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let badFromBeat = await router.handle(ControlRequest(
            id: "1", command: "render.measureLoudness", params: ["fromBeat": .number(-1)]))
        #expect(!badFromBeat.ok)
        #expect(badFromBeat.error?.contains("'fromBeat' must be >= 0") == true)

        let badDuration = await router.handle(ControlRequest(
            id: "2", command: "render.measureLoudness", params: ["durationSeconds": .number(0)]))
        #expect(!badDuration.ok)
        #expect(badDuration.error?.contains("'durationSeconds' must be > 0") == true)
        #expect(engine.renderOfflineCalls.isEmpty, "invalid params never reach the engine")
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func measureLoudnessHeadless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.measureLoudness", params: ["durationSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    // MARK: - render.bounce

    @Test("happy path (no target): report.input == report.output, no gain applied")
    func bounceHappyPathNoTarget() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.bounce", params: ["durationSeconds": .number(1.0)]))
        #expect(response.ok, "bounce failed: \(response.error ?? "?")")
        #expect(response.result?["report"]?["appliedGainDb"]?.doubleValue == 0)
        #expect(response.result?["report"]?["limitedByCeiling"]?.boolValue == false)
        #expect(response.result?["report"]?["truePeakCeilingDbtp"]?.doubleValue == -1.0)
        // Omitted target never appears on the wire (nil is honest omission).
        #expect(response.result?["report"]?["lufsTarget"] == nil)
        let inputLufs = response.result?["report"]?["input"]?["integratedLufs"]?.doubleValue
        let outputLufs = response.result?["report"]?["output"]?["integratedLufs"]?.doubleValue
        #expect(inputLufs == outputLufs)
        #expect(response.result?["path"]?.stringValue?.isEmpty == false)
        #expect(response.result?["channels"]?.doubleValue == 2)
        #expect(engine.writtenFiles.count == 1)
    }

    @Test("lufsTarget normalizes toward the target")
    func bounceNormalizesToTarget() async throws {
        let engine = FakeRenderEngine()   // stub input ≈ -20 LUFS
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.bounce",
            params: ["durationSeconds": .number(1.0), "lufsTarget": .number(-14)]))
        #expect(response.ok, "bounce failed: \(response.error ?? "?")")
        let gain = try #require(response.result?["report"]?["appliedGainDb"]?.doubleValue)
        #expect(abs(gain - 6) < 0.5, "gain ≈ +6 dB toward -14 from ≈-20 (got \(gain))")
        #expect(response.result?["report"]?["limitedByCeiling"]?.boolValue == false)
        let outputLufs = try #require(response.result?["report"]?["output"]?["integratedLufs"]?.doubleValue)
        #expect(abs(outputLufs - (-14)) < 0.5, "output ≈ -14 LUFS (got \(outputLufs))")
        #expect(response.result?["report"]?["lufsTarget"]?.doubleValue == -14)
    }

    @Test("true-peak ceiling clamps the gain honestly (limitedByCeiling)")
    func bounceCeilingClamp() async throws {
        let engine = FakeRenderEngine()
        engine.renderOfflineStub = FakeRenderEngine.tone(dBFS: -1)   // hot input
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.bounce",
            params: ["durationSeconds": .number(1.0), "lufsTarget": .number(0),
                     "truePeakCeilingDb": .number(-3)]))
        #expect(response.ok, "bounce failed: \(response.error ?? "?")")
        #expect(response.result?["report"]?["limitedByCeiling"]?.boolValue == true)
        let outputTP = try #require(response.result?["report"]?["output"]?["truePeakDbtp"]?.doubleValue)
        #expect(outputTP <= -2.9, "output true peak respects the -3 dBTP ceiling (got \(outputTP))")
        let outputLufs = try #require(response.result?["report"]?["output"]?["integratedLufs"]?.doubleValue)
        #expect(outputLufs < 0, "achieved loudness falls short of the target when clamped (got \(outputLufs))")
    }

    @Test("bounceSilent thrown verbatim on gated-silent program + a target; succeeds all-nil without one")
    func bounceSilentProgram() async throws {
        let engine = FakeRenderEngine()
        engine.renderOfflineStub = FakeRenderEngine.silence()
        let (router, _) = makeRouter(engine: engine)

        let withTarget = await router.handle(ControlRequest(
            id: "1", command: "render.bounce",
            params: ["durationSeconds": .number(1.0), "lufsTarget": .number(-14)]))
        #expect(!withTarget.ok)
        #expect(withTarget.error == "program is silent below the -70 LUFS gate — cannot loudness-normalize")

        let withoutTarget = await router.handle(ControlRequest(
            id: "2", command: "render.bounce", params: ["durationSeconds": .number(1.0)]))
        #expect(withoutTarget.ok, "silent measure-only bounce should succeed: \(withoutTarget.error ?? "?")")
        #expect(withoutTarget.result?["report"]?["input"]?["integratedLufs"] == nil)
        #expect(withoutTarget.result?["report"]?["output"]?["integratedLufs"] == nil)
    }

    @Test("lufsTarget/truePeakCeilingDb range validation is field-named")
    func bounceRangeValidation() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        for bad in [5.0, -80.0] {
            let response = await router.handle(ControlRequest(
                id: "1", command: "render.bounce",
                params: ["durationSeconds": .number(1.0), "lufsTarget": .number(bad)]))
            #expect(!response.ok)
            #expect(response.error?.contains("'lufsTarget' must be between -70 and 0") == true)
        }
        for bad in [5.0, -25.0] {
            let response = await router.handle(ControlRequest(
                id: "2", command: "render.bounce",
                params: ["durationSeconds": .number(1.0), "truePeakCeilingDb": .number(bad)]))
            #expect(!response.ok)
            #expect(response.error?.contains("'truePeakCeilingDb' must be between -20 and 0") == true)
        }
        #expect(engine.renderOfflineCalls.isEmpty, "invalid params never reach the engine")
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func bounceHeadless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.bounce", params: ["durationSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    // MARK: - render.stems

    @Test("happy path: one stem per direct track, measured, forced under one shared plan")
    func stemsHappyPath() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let addA = await router.handle(ControlRequest(
            id: "a", command: "track.add", params: ["kind": .string("audio"), "name": .string("Guitar")]))
        let addB = await router.handle(ControlRequest(
            id: "b", command: "track.add", params: ["kind": .string("instrument"), "name": .string("Keys")]))
        #expect(addA.ok && addB.ok)

        let response = await router.handle(ControlRequest(
            id: "1", command: "render.stems", params: ["durationSeconds": .number(1.0)]))
        #expect(response.ok, "stems failed: \(response.error ?? "?")")
        let stems = try #require(response.result?["stems"]?.arrayValue)
        #expect(stems.count == 2)
        #expect(stems[0]["name"]?.stringValue == "Guitar")
        #expect(stems[0]["kind"]?.stringValue == "track")
        #expect(stems[0]["path"]?.stringValue?.hasSuffix("01 Guitar.wav") == true)
        #expect(stems[1]["path"]?.stringValue?.hasSuffix("02 Keys.wav") == true)
        #expect(stems[0]["measurement"]?["integratedLufs"]?.doubleValue != nil)
        #expect(response.result?["mixdown"] == nil)
        #expect(response.result?["channels"]?.doubleValue == 2)
        #expect(response.result?["directory"]?.stringValue?.isEmpty == false)
        // One renderOffline pass per stem, every one forced under the SAME
        // (once-probed) full-session compensation plan.
        #expect(engine.renderOfflineCalls.count == 2)
    }

    @Test("includeMixdown adds a 00 Mixdown.wav reference pass")
    func stemsIncludeMixdown() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        _ = await router.handle(ControlRequest(
            id: "a", command: "track.add", params: ["kind": .string("audio")]))
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.stems",
            params: ["durationSeconds": .number(1.0), "includeMixdown": .bool(true)]))
        #expect(response.ok, "stems failed: \(response.error ?? "?")")
        #expect(response.result?["mixdown"]?["path"]?.stringValue?.hasSuffix("00 Mixdown.wav") == true)
        #expect(response.result?["mixdown"]?["measurement"]?["integratedLufs"]?.doubleValue != nil)
        #expect(engine.renderOfflineCalls.count == 2, "1 stem pass + 1 mixdown pass")
    }

    @Test("bus-routed trackId rejects stemNotMasterInput verbatim")
    func stemsBusRoutedRejection() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let bus = await router.handle(ControlRequest(
            id: "bus", command: "track.add", params: ["kind": .string("bus"), "name": .string("Drum Bus")]))
        let busID = try #require(bus.result?["id"]?.stringValue)
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio"), "name": .string("Snare")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let routeResponse = await router.handle(ControlRequest(
            id: "r", command: "track.setOutput",
            params: ["trackId": .string(trackID), "busId": .string(busID)]))
        #expect(routeResponse.ok)

        let response = await router.handle(ControlRequest(
            id: "1", command: "render.stems",
            params: ["durationSeconds": .number(1.0), "trackIds": .array([.string(trackID)])]))
        #expect(!response.ok)
        #expect(response.error == "'Snare' is routed to bus 'Drum Bus' — its signal is part of that bus's stem")
    }

    @Test("trackIds elements are per-index validated; a non-array trackIds is field-named")
    func stemsTrackIDsValidation() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let badElement = await router.handle(ControlRequest(
            id: "1", command: "render.stems",
            params: ["durationSeconds": .number(1.0), "trackIds": .array([.string("not-a-uuid")])]))
        #expect(!badElement.ok)
        #expect(badElement.error == "trackIds[0] is not a valid UUID")

        let notArray = await router.handle(ControlRequest(
            id: "2", command: "render.stems",
            params: ["durationSeconds": .number(1.0), "trackIds": .string("nope")]))
        #expect(!notArray.ok)
        #expect(notArray.error == "'trackIds' must be an array of track id strings")
        #expect(engine.renderOfflineCalls.isEmpty, "invalid params never reach the engine")
    }

    @Test("empty project surfaces nothingToRender verbatim")
    func stemsNothingToRender() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.stems", params: ["durationSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error
            == "nothing to render — no clips found in the render range; "
            + "add clips or pass an explicit durationSeconds")
    }

    @Test("fromBeat/durationSeconds are field-named validated")
    func stemsValidation() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        _ = await router.handle(ControlRequest(
            id: "a", command: "track.add", params: ["kind": .string("audio")]))
        let badFromBeat = await router.handle(ControlRequest(
            id: "1", command: "render.stems",
            params: ["durationSeconds": .number(1.0), "fromBeat": .number(-1)]))
        #expect(!badFromBeat.ok)
        #expect(badFromBeat.error?.contains("'fromBeat' must be >= 0") == true)

        let badDuration = await router.handle(ControlRequest(
            id: "2", command: "render.stems", params: ["durationSeconds": .number(0)]))
        #expect(!badDuration.ok)
        #expect(badDuration.error?.contains("'durationSeconds' must be > 0") == true)
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func stemsHeadless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.stems", params: ["durationSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("all three render.* commands are registered")
    func commandsRegistered() {
        #expect(CommandRouter.allCommands.contains("render.measureLoudness"))
        #expect(CommandRouter.allCommands.contains("render.bounce"))
        #expect(CommandRouter.allCommands.contains("render.stems"))
    }
}
