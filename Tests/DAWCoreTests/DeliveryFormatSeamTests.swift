import Foundation
import Testing
@testable import DAWCore

/// m23-m2 format plumbing at the STORE→ENGINE seams, headless.
///
/// Scope discipline, stated because it is the sharpest hazard in this item:
/// these tests assert the URL the store hands the engine, the format value it
/// hands alongside it, and the response echo. They assert NOTHING about what
/// lands on disk — a double cannot know. On-disk format is asserted against the
/// real `AudioEngine` in `DeliveryFormatRenderTests`; an on-disk assertion made
/// through a double would pass on an implementation that never plumbs the
/// parameter at all, because the protocol-extension default silently forwards
/// to the legacy writer.
@MainActor
@Suite("Delivery format — store→engine seams (m23-m2)")
struct DeliveryFormatSeamTests {

    /// Records BOTH format-aware seams. Implementing them is the point: a
    /// double that does not (see `LegacyOnlyEngine` below) refuses instead.
    final class FormatRecordingEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted

        var stub = RenderedAudio(sampleRate: 48_000, channelData: [[0.1, 0.2], [0.1, 0.2]])
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
            stub
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

    /// A double that implements ONLY the pre-m23-m2 seams — the shape every
    /// existing test double in this repo has.
    final class LegacyOnlyEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted
        private(set) var legacyWrites: [URL] = []
        private(set) var legacyMixdowns: [URL] = []

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
            legacyMixdowns.append(url)
            return AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000,
                                 channelCount: 2)
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            RenderedAudio(sampleRate: 48_000, channelData: [[0.1], [0.1]])
        }

        func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
            legacyWrites.append(url)
            return AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
        }
    }

    private func makeStore(_ engine: some AudioEngineControlling) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [Track(name: "T", kind: .audio,
                              clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])]
        return store
    }

    // MARK: - The format reaches BOTH seams

    @Test("render.bounce hands the engine the resolved format and a matching URL")
    func bounceSeam() async throws {
        let engine = FormatRecordingEngine()
        let store = makeStore(engine)
        let result = try await store.renderBounce(toPath: "/tmp/daw-pro-seam/mix.wav",
                                                  durationSeconds: 1,
                                                  bitDepth: 24, container: "aiff")
        #expect(engine.written.count == 1)
        let call = try #require(engine.written.first)
        #expect(call.format.bitDepth == 24)
        #expect(call.format.container == .aiff)
        // The URL the ENGINE receives already carries the container's
        // extension — the extension is what selects the container, so it
        // cannot be decided anywhere else.
        #expect(call.url.path == "/tmp/daw-pro-seam/mix.wav.aiff")
        #expect(result.path == call.url.path)
        #expect(result.bitDepth == 24)
        #expect(result.container == "aiff")
        #expect(result.ditherApplied == false)
    }

    @Test("render.mixdown hands the engine the resolved format — the second seam")
    func mixdownSeam() async throws {
        let engine = FormatRecordingEngine()
        let store = makeStore(engine)
        let result = try await store.renderMixdown(toPath: "/tmp/daw-pro-seam/raw",
                                                   durationSeconds: 1,
                                                   bitDepth: 16, container: "aiff")
        #expect(engine.written.isEmpty, "render.mixdown must NOT go through writeAudioFile")
        let call = try #require(engine.mixdowns.first)
        #expect(call.format.bitDepth == 16)
        #expect(call.format.container == .aiff)
        #expect(call.url.path == "/tmp/daw-pro-seam/raw.aiff")
        #expect(result.path == call.url.path)
        #expect(result.bitDepth == 16)
        #expect(result.container == "aiff")
    }

    @Test("the default path still reaches the seams as .default, unchanged")
    func defaultSeam() async throws {
        let engine = FormatRecordingEngine()
        let store = makeStore(engine)
        let bounce = try await store.renderBounce(toPath: "/tmp/daw-pro-seam/plain",
                                                  durationSeconds: 1)
        #expect(try #require(engine.written.first).format == .default)
        #expect(bounce.path == "/tmp/daw-pro-seam/plain.wav")
        #expect(bounce.bitDepth == nil && bounce.container == nil
                && bounce.ditherApplied == nil)

        let mixdown = try await store.renderMixdown(toPath: "/tmp/daw-pro-seam/plainraw",
                                                    durationSeconds: 1)
        #expect(try #require(engine.mixdowns.first).format == .default)
        #expect(mixdown.path == "/tmp/daw-pro-seam/plainraw.wav")
        #expect(mixdown.bitDepth == nil && mixdown.container == nil)
    }

    // MARK: - The protocol-extension default REFUSES rather than discards

    @Test("a legacy-only engine keeps the default path AND refuses a real format")
    func legacyEngineRefusesNonDefaultFormat() async throws {
        let engine = LegacyOnlyEngine()
        let store = makeStore(engine)

        // Additive-seam proof: an engine written before m23-m2 still compiles
        // and still renders the default path.
        let bounce = try await store.renderBounce(toPath: "/tmp/daw-pro-seam/legacy",
                                                  durationSeconds: 1)
        #expect(bounce.path == "/tmp/daw-pro-seam/legacy.wav")
        #expect(engine.legacyWrites.count == 1)
        _ = try await store.renderMixdown(toPath: "/tmp/daw-pro-seam/legacyraw",
                                          durationSeconds: 1)
        #expect(engine.legacyMixdowns.count == 1)

        // ... and it REFUSES a format it cannot honour instead of silently
        // writing Float32 WAV while the response claims 24-bit AIFF. This is
        // the whole reason the extension default is not a silent forward.
        await #expect(throws: ProjectError.self) {
            _ = try await store.renderBounce(toPath: "/tmp/daw-pro-seam/nope",
                                             durationSeconds: 1, bitDepth: 24)
        }
        await #expect(throws: ProjectError.self) {
            _ = try await store.renderMixdown(toPath: "/tmp/daw-pro-seam/nope",
                                              durationSeconds: 1, container: "aiff")
        }
        #expect(engine.legacyWrites.count == 1, "the refused bounce must not have written")
        #expect(engine.legacyMixdowns.count == 1, "the refused mixdown must not have written")
    }
}
