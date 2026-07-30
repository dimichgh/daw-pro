import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for the m23-m2 output-format params —
/// `bitDepth` / `container` on `render.bounce`, `render.mixdown` and
/// `render.stems`: routing, field-named validation, the omitted-when-default
/// response echo, and the honest refusal an engine that cannot honour a format
/// produces.
///
/// Scope discipline: the double below records URLs and formats — it writes no
/// files, so nothing here asserts an on-disk format. That belongs to
/// `DeliveryFormatRenderTests` against the real `AudioEngine`, and asserting it
/// here would pass on an implementation that never plumbed the parameter.
@MainActor
final class FormatFakeRenderEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    private(set) var written: [(url: URL, format: DeliveryFormat)] = []
    private(set) var mixdowns: [(url: URL, format: DeliveryFormat)] = []

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
        mixdowns.append((url, .default))
        return AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000,
                             channelCount: 2)
    }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
        mixdowns.append((url, format))
        return AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000,
                             channelCount: 2)
    }

    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        FakeRenderEngine.tone(dBFS: -20)
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        written.append((url, .default))
        return AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL,
                        format: DeliveryFormat) throws -> AudioFileInfo {
        written.append((url, format))
        return AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
    }
}

@MainActor
@Suite("Render output format — control protocol (m23-m2)")
struct RenderOutputFormatCommandTests {

    private func makeRouter(engine: some AudioEngineControlling)
        -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    /// One master-input track, added over the wire (the store's `tracks`
    /// setter is not public) — `render.stems` needs a partition to write.
    private func addLeadTrack(_ router: CommandRouter) async {
        _ = await router.handle(ControlRequest(
            id: "a", command: "track.add",
            params: ["kind": .string("audio"), "name": .string("Lead")]))
    }

    // MARK: - Routing + echo

    @Test("render.bounce carries bitDepth/container to the seam and echoes them back")
    func bounceRoutes() async throws {
        let engine = FormatFakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.bounce",
            params: ["path": .string("/tmp/daw-pro-m2/mix"),
                     "durationSeconds": .number(1.0),
                     "bitDepth": .number(24),
                     "container": .string("aiff")]))
        #expect(response.ok, "bounce failed: \(response.error ?? "?")")
        #expect(response.result?["bitDepth"]?.doubleValue == 24)
        #expect(response.result?["container"]?.stringValue == "aiff")
        #expect(response.result?["ditherApplied"]?.boolValue == false)
        #expect(response.result?["path"]?.stringValue == "/tmp/daw-pro-m2/mix.aiff")
        let call = try #require(engine.written.first)
        #expect(call.format.bitDepth == 24)
        #expect(call.format.container == .aiff)
    }

    @Test("render.mixdown carries bitDepth/container to the ENGINE-writes seam")
    func mixdownRoutes() async throws {
        let engine = FormatFakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.mixdown",
            params: ["path": .string("/tmp/daw-pro-m2/raw.wav"),
                     "durationSeconds": .number(1.0),
                     "bitDepth": .number(16),
                     "container": .string("aiff")]))
        #expect(response.ok, "mixdown failed: \(response.error ?? "?")")
        #expect(response.result?["bitDepth"]?.doubleValue == 16)
        #expect(response.result?["container"]?.stringValue == "aiff")
        // The container/extension agreement, over the wire: the caller said
        // ".wav" and asked for AIFF, and the file that lands is AIFF-named.
        #expect(response.result?["path"]?.stringValue == "/tmp/daw-pro-m2/raw.wav.aiff")
        let call = try #require(engine.mixdowns.first)
        #expect(call.format.bitDepth == 16)
        #expect(call.format.container == .aiff)
        #expect(engine.written.isEmpty, "render.mixdown must not route via writeAudioFile")
    }

    @Test("render.stems applies one format to every file of the set")
    func stemsRoute() async throws {
        let engine = FormatFakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        await addLeadTrack(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "render.stems",
            params: ["directory": .string("/tmp/daw-pro-m2/stems"),
                     "durationSeconds": .number(1.0),
                     "includeMixdown": .bool(true),
                     "bitDepth": .number(24),
                     "container": .string("aiff")]))
        #expect(response.ok, "stems failed: \(response.error ?? "?")")
        #expect(response.result?["bitDepth"]?.doubleValue == 24)
        #expect(response.result?["container"]?.stringValue == "aiff")
        #expect(response.result?["ditherApplied"]?.boolValue == false)
        let stemList = try #require(response.result?["stems"]?.arrayValue)
        let stemPath = try #require(stemList.first?["path"]?.stringValue)
        #expect(stemPath.hasSuffix("01 Lead.aiff"), "stem landed at \(stemPath)")
        let mixdownPath = try #require(response.result?["mixdown"]?["path"]?.stringValue)
        #expect(mixdownPath.hasSuffix("00 Mixdown.aiff"))
        #expect(engine.written.allSatisfy { $0.format.container == .aiff })
        #expect(engine.written.allSatisfy { $0.format.bitDepth == 24 })
    }

    // MARK: - Omitted-when-default

    @Test("a default call's response carries NO format keys at all")
    func defaultResponseUnmoved() async throws {
        let engine = FormatFakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        for verb in ["render.bounce", "render.mixdown"] {
            let response = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["path": .string("/tmp/daw-pro-m2/plain"),
                         "durationSeconds": .number(1.0)]))
            #expect(response.ok, "\(verb) failed: \(response.error ?? "?")")
            #expect(response.result?["bitDepth"] == nil, "\(verb) grew a bitDepth key")
            #expect(response.result?["container"] == nil, "\(verb) grew a container key")
            #expect(response.result?["ditherApplied"] == nil, "\(verb) grew a ditherApplied key")
            #expect(response.result?["path"]?.stringValue == "/tmp/daw-pro-m2/plain.wav")
        }
        await addLeadTrack(router)
        let stems = await router.handle(ControlRequest(
            id: "1", command: "render.stems",
            params: ["directory": .string("/tmp/daw-pro-m2/plainstems"),
                     "durationSeconds": .number(1.0)]))
        #expect(stems.ok, "stems failed: \(stems.error ?? "?")")
        #expect(stems.result?["bitDepth"] == nil)
        #expect(stems.result?["container"] == nil)
        #expect(stems.result?["ditherApplied"] == nil)
        let plainStems = try #require(stems.result?["stems"]?.arrayValue)
        let stemPath = try #require(plainStems.first?["path"]?.stringValue)
        #expect(stemPath.hasSuffix("01 Lead.wav"))
    }

    // MARK: - Field-named validation

    @Test("an off-list depth or container is refused by name, on all three verbs")
    func validation() async throws {
        let engine = FormatFakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        await addLeadTrack(router)
        for verb in ["render.bounce", "render.mixdown", "render.stems"] {
            let badDepth = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["durationSeconds": .number(1.0), "bitDepth": .number(20)]))
            #expect(!badDepth.ok, "\(verb) accepted bitDepth 20")
            #expect(badDepth.error?.contains("bitDepth") == true, "\(verb): \(badDepth.error ?? "?")")

            let fractional = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["durationSeconds": .number(1.0), "bitDepth": .number(24.5)]))
            #expect(!fractional.ok, "\(verb) accepted bitDepth 24.5")
            #expect(fractional.error?.contains("bitDepth") == true)

            // A present-but-wrong-typed value must be REJECTED, never parsed
            // to nil: falling back to Float32 WAV after being asked for 24-bit
            // is exactly the silent-mismatch this item closes.
            let stringy = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["durationSeconds": .number(1.0), "bitDepth": .string("24")]))
            #expect(!stringy.ok, "\(verb) silently ignored a string bitDepth")
            #expect(stringy.error?.contains("bitDepth") == true)

            let badContainer = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["durationSeconds": .number(1.0), "container": .string("mp3")]))
            #expect(!badContainer.ok, "\(verb) accepted container mp3")
            #expect(badContainer.error?.contains("container") == true)

            let typedContainer = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["durationSeconds": .number(1.0), "container": .number(2)]))
            #expect(!typedContainer.ok)
            #expect(typedContainer.error?.contains("container") == true)

            // Not a silent alias: the wire vocabulary is exactly what the MCP
            // tool's enum accepts.
            let cased = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["durationSeconds": .number(1.0), "container": .string("WAV")]))
            #expect(!cased.ok, "\(verb) accepted 'WAV'")

            // A typo'd key still rejects as UNKNOWN rather than being ignored.
            let typo = await router.handle(ControlRequest(
                id: "1", command: verb,
                params: ["durationSeconds": .number(1.0), "bitdepth": .number(24)]))
            #expect(!typo.ok, "\(verb) ignored a misspelled key")
            #expect(typo.error?.contains("bitdepth") == true)
        }
        #expect(engine.written.isEmpty, "a rejected format must never write")
        #expect(engine.mixdowns.isEmpty)
    }

    // MARK: - An engine that cannot honour a format says so

    @Test("an engine without format support REFUSES rather than writing the wrong file")
    func legacyEngineRefuses() async throws {
        // `FakeRenderEngine` (m23-m1) implements only the pre-m23-m2 seams —
        // the shape every other double in this repo has.
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)

        let refused = await router.handle(ControlRequest(
            id: "1", command: "render.bounce",
            params: ["durationSeconds": .number(1.0), "bitDepth": .number(24)]))
        #expect(!refused.ok, "a legacy engine silently accepted a 24-bit request")
        #expect(engine.writtenFiles.isEmpty, "nothing may land when the format is refused")

        // ... while the DEFAULT path is entirely unaffected.
        let ok = await router.handle(ControlRequest(
            id: "1", command: "render.bounce",
            params: ["durationSeconds": .number(1.0)]))
        #expect(ok.ok, "default bounce failed: \(ok.error ?? "?")")
        #expect(engine.writtenFiles.count == 1)
    }

    @Test("the wire surface is unmoved: m23-m2 added PARAMS, not verbs")
    func wireCountUnmoved() {
        #expect(CommandRouter.allCommands.count == 165)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w
    }
}
