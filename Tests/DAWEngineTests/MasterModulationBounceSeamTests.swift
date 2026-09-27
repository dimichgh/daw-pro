import Foundation
import Testing
@testable import DAWCore

/// m39-e-2 — the engine seam. `AudioEngineControlling` gained two render
/// requirements that carry the MASTER strip's modulation, ADDITIVELY: every
/// double written before them implements only the old pair and inherits a
/// protocol-extension default. These gates pin what that default does, and use
/// it to pin each store call site's render class without rendering a sample.
///
///  · Nothing that could change the render (no source, an unrouted source, a
///    disabled route) → the default FORWARDS to the old requirement: every
///    existing double, and every project without master modulation, behaves
///    exactly as before.
///  · An enabled master route → the default REFUSES (`engineUnavailable`)
///    instead of dropping it, the m23-m2 precedent: the defect m39-e-2 closes
///    is master modulation silently missing from a render.
///  · Through the store, a legacy-only engine therefore still renders every
///    STEM-class file of a project whose master strip is modulated (they carry
///    none) and refuses every MASTERED one (they carry it) — so a call site
///    that passed the wrong class would flip one of these legs.
///
/// Nonisolated suite (the `MainActorOccupancySiteTests` Leg C cap is full);
/// the tests that touch the store hop to the main actor.
@Suite("Master modulation — the engine seam's default (m39-e-2)")
struct MasterModulationBounceSeamTests {

    /// A double implementing ONLY the pre-m39-e-2 render seams — the shape of
    /// every test double in this repo (`DeliveryFormatSeamTests.LegacyOnlyEngine`).
    @MainActor
    final class LegacyOnlyEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted
        private(set) var legacyRenders = 0
        private(set) var legacyMixdowns = 0

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
            legacyMixdowns += 1
            return AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000,
                                 channelCount: 2)
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            legacyRenders += 1
            return RenderedAudio(sampleRate: 48_000, channelData: [[0.1, 0.2], [0.1, 0.2]])
        }

        func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
        }
    }

    private static let lfo = ModulationSource(
        kind: .lfo, params: .lfo(LFOSourceParams(waveform: .sine, rateHz: 2, bipolar: false)))

    /// The master-strip states the default must tell apart.
    private static func routes(enabled: Bool) -> [ModulationRoute] {
        [ModulationRoute(sourceID: lfo.id, target: .volume, depth: -0.5, enabled: enabled)]
    }

    @MainActor
    private static func render(_ engine: any AudioEngineControlling,
                               sources: [ModulationSource],
                               routes: [ModulationRoute]) async throws -> RenderedAudio {
        try await engine.renderOffline(
            tracks: [], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            masterEffects: [], masterAutomation: [],
            masterModulationSources: sources, masterModulationRoutes: routes,
            fromBeat: 0, durationSeconds: 1, forcedCompensationTargets: nil)
    }

    @MainActor
    private static func mixdown(_ engine: any AudioEngineControlling,
                                sources: [ModulationSource],
                                routes: [ModulationRoute]) async throws -> AudioFileInfo {
        try await engine.renderMixdown(
            tracks: [], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            masterEffects: [], masterAutomation: [],
            masterModulationSources: sources, masterModulationRoutes: routes,
            fromBeat: 0, durationSeconds: 1,
            to: URL(fileURLWithPath: "/tmp/daw-pro-m39e2-seam/never-written.wav"),
            format: .default)
    }

    /// What a call did: "served", "engineUnavailable", or any other error by
    /// name — so a refusal for the WRONG reason (say `nothingToRender`) fails.
    @MainActor
    private static func outcome(_ body: @MainActor () async throws -> Void) async -> String {
        do {
            try await body()
            return "served"
        } catch ProjectError.engineUnavailable {
            return "engineUnavailable"
        } catch {
            return "other: \(error)"
        }
    }

    @Test("a legacy-only engine forwards when nothing could change the render: no source, an unrouted source, a disabled route")
    @MainActor
    func legacyEngineForwardsInertMasterModulation() async throws {
        let engine = LegacyOnlyEngine()
        let inertStates: [(String, [ModulationSource], [ModulationRoute])] = [
            ("none", [], []),
            ("unrouted source", [Self.lfo], []),
            ("disabled route", [Self.lfo], Self.routes(enabled: false)),
        ]
        for (label, sources, routes) in inertStates {
            let before = engine.legacyRenders
            let audio = try await Self.render(engine, sources: sources, routes: routes)
            #expect(engine.legacyRenders == before + 1, "\(label): the render must reach the old seam")
            #expect(audio.channelData == [[0.1, 0.2], [0.1, 0.2]], "\(label): the old seam's audio, unchanged")
            let mixdownsBefore = engine.legacyMixdowns
            _ = try await Self.mixdown(engine, sources: sources, routes: routes)
            #expect(engine.legacyMixdowns == mixdownsBefore + 1, "\(label): the mixdown must reach the old seam")
        }
    }

    @Test("a legacy-only engine REFUSES an enabled master route instead of silently dropping it")
    @MainActor
    func legacyEngineRefusesLiveMasterModulation() async throws {
        let engine = LegacyOnlyEngine()
        let render = await Self.outcome {
            _ = try await Self.render(engine, sources: [Self.lfo], routes: Self.routes(enabled: true))
        }
        let mixdown = await Self.outcome {
            _ = try await Self.mixdown(engine, sources: [Self.lfo], routes: Self.routes(enabled: true))
        }
        print("[measured] m39-e-2 legacy-only engine with an enabled master route: "
              + "renderOffline → \(render), renderMixdown → \(mixdown)")
        #expect(render == "engineUnavailable")
        #expect(mixdown == "engineUnavailable")
        // Refused BEFORE anything rendered: the old seam was never reached, so
        // nothing was produced that silently lacks the modulation.
        #expect(engine.legacyRenders == 0)
        #expect(engine.legacyMixdowns == 0)
    }

    /// Each store call site's render class, read off the seam: with a master
    /// route in the project, a legacy-only engine refuses exactly the MASTERED
    /// renders and serves every STEM-class one.
    @Test("store call sites: MASTERED renders carry master modulation (refused here), STEM renders carry none (served)")
    @MainActor
    func storeCallSitesDeclareTheirRenderClass() async throws {
        let engine = LegacyOnlyEngine()
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [
            Track(name: "A", kind: .audio, clips: [Clip(name: "a", startBeat: 0, lengthBeats: 4)]),
            Track(name: "B", kind: .audio, clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4)]),
        ]
        let macro = try store.addModulationSource(on: .master, kind: .macro,
                                                  params: ["value": .number(0.5)]).source
        try store.addModulationRoute(on: .master, sourceID: macro.id, target: .volume, depth: -0.5)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m39e2-seam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

        // STEM class: served, because those renders pass no master modulation.
        let stems = await Self.outcome {
            _ = try await store.renderStems(toDirectory: path("stems"), durationSeconds: 1,
                                            includeMixdown: true)
        }
        #expect(stems == "served")
        #expect(engine.legacyRenders == 3, "2 stems + the 00 Mixdown reference")

        // MASTERED class: each refused, for exactly this reason.
        let bounce = await Self.outcome {
            _ = try await store.renderBounce(toPath: path("b.wav"), durationSeconds: 1)
        }
        let loudness = await Self.outcome {
            _ = try await store.measureLoudness(durationSeconds: 1)
        }
        let mixdown = await Self.outcome {
            _ = try await store.renderMixdown(toPath: path("m.wav"), durationSeconds: 1)
        }
        let mastered = await Self.outcome {
            _ = try await store.renderStems(toDirectory: path("stems2"), durationSeconds: 1,
                                            includeMasteredMixdown: true)
        }
        print("[measured] m39-e-2 store call sites vs a legacy-only engine, master route ON: "
              + "stems \(stems), bounce \(bounce), measureLoudness \(loudness), "
              + "mixdown \(mixdown), stems+masteredMix \(mastered)")
        #expect(bounce == "engineUnavailable")
        #expect(loudness == "engineUnavailable")
        #expect(mixdown == "engineUnavailable")
        #expect(mastered == "engineUnavailable")
        // That last export's two stem passes (STEM, served) ran before its
        // mastered sibling was refused — the documented order (mastered LAST).
        #expect(engine.legacyRenders == 5)
        #expect(engine.legacyMixdowns == 0)

        // STEM class again: bounce-in-place is served (and runs last, because
        // it adds a track).
        let landed = await Self.outcome {
            _ = try await store.bounceTrackInPlace(trackId: store.tracks[0].id,
                                                   durationSeconds: 1, muteSource: false)
        }
        #expect(landed == "served")
        #expect(engine.legacyRenders == 6)

        // CONTROL: with the route DISABLED every MASTERED render goes through
        // the old seam — the refusals above were about the route, not this double.
        let route = try #require(store.masterModulationRoutes.first)
        try store.setModulationRouteDepth(on: .master, routeID: route.id, enabled: false)
        let bounceOff = await Self.outcome {
            _ = try await store.renderBounce(toPath: path("b2.wav"), durationSeconds: 1)
        }
        let loudnessOff = await Self.outcome {
            _ = try await store.measureLoudness(durationSeconds: 1)
        }
        let mixdownOff = await Self.outcome {
            _ = try await store.renderMixdown(toPath: path("m2.wav"), durationSeconds: 1)
        }
        #expect(bounceOff == "served")
        #expect(loudnessOff == "served")
        #expect(mixdownOff == "served")
        #expect(engine.legacyRenders == 8)
        #expect(engine.legacyMixdowns == 1)
    }
}
