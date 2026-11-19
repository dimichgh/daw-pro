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

    // MARK: - m39-w4-4a (W8-W44F): the METER crosses the same seam (W8-W44R N1)

    /// A double implementing the meter-carrying requirements (m39-w4-4a) AND
    /// every older render requirement, recording each meter map it is handed.
    /// A store call site left on an older requirement shows up as a LEGACY
    /// call, not as a missing record.
    @MainActor
    final class MeterSpyEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var recordPermission: RecordPermission = .granted
        private(set) var meterMaps: [MeterMap] = []
        private(set) var legacyCalls = 0

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

        /// One second of a 1 kHz tone: enough program for every measurement
        /// the store runs after a render.
        private static let audio: RenderedAudio = {
            let tone = (0..<48_000).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
            return RenderedAudio(sampleRate: 48_000, channelData: [tone, tone])
        }()
        private static let info = AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)

        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            legacyCalls += 1
            return Self.info
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            legacyCalls += 1
            return Self.audio
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                           masterModulationSources: [ModulationSource],
                           masterModulationRoutes: [ModulationRoute],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            legacyCalls += 1
            return Self.audio
        }

        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                           masterModulationSources: [ModulationSource],
                           masterModulationRoutes: [ModulationRoute],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
            legacyCalls += 1
            return Self.info
        }

        func renderOffline(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap,
                           masterVolume: Double,
                           masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                           masterModulationSources: [ModulationSource],
                           masterModulationRoutes: [ModulationRoute],
                           fromBeat: Double, durationSeconds: Double,
                           forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
            meterMaps.append(meterMap)
            return Self.audio
        }

        func renderMixdown(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap,
                           masterVolume: Double,
                           masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                           masterModulationSources: [ModulationSource],
                           masterModulationRoutes: [ModulationRoute],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
            meterMaps.append(meterMap)
            return Self.info
        }

        func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo { Self.info }
    }

    /// A hand-edited project (written before the wire accepted `stepDivision`;
    /// it still loads the same way): a drum-machine track whose fader rides a TEMPO-SYNCED 1/4
    /// `[1, 0, 0]` step source, an audio track, and the meter 4/4 → 3/4 at bar 5.
    @MainActor
    private static func w44fSyncedProject(engine: any AudioEngineControlling) throws -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        let source = ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, 0, 0], stepDivision: "1/4")))
        var drums = Track(name: "Drums", kind: .instrument,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       notes: [MIDINote(pitch: 36, velocity: 100, startBeat: 0,
                                                        lengthBeats: 1)])],
                          instrument: InstrumentDescriptor(kind: .drumSynth))
        drums.modulationSources = [source]
        drums.modulationRoutes = [ModulationRoute(sourceID: source.id, target: .volume, depth: -0.5)]
        store.tracks = [drums,
                        Track(name: "A", kind: .audio, clips: [Clip(name: "a", startBeat: 0, lengthBeats: 4)])]
        try store.setTempoMap(TempoMap(constantBPM: 120), meterMap: try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4),
        ]))
        return store
    }

    /// ⭐ T-N1a, the spy leg: EVERY store session render hands the engine
    /// `transport.meterMap` through the meter-carrying seam, and none reaches
    /// an older requirement. Each site is driven separately and must add its
    /// own record, so a site left on the old seam is named, not averaged away.
    @Test("m39-w4-4a T-N1a: every store session render hands the engine transport.meterMap through the meter-carrying seam")
    @MainActor
    func w44fStoreRendersCarryTheMeterMap() async throws {
        let engine = MeterSpyEngine()
        let store = try Self.w44fSyncedProject(engine: engine)
        let expected = store.transport.meterMap
        #expect(expected.changes.count == 2, "the fixture's meter change must have landed")
        let drums = store.tracks[0].id
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-w44f-spy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

        var reached: [(site: String, calls: Int, outcome: String)] = []
        func drive(_ site: String, _ body: @MainActor () async throws -> Void) async {
            let before = engine.meterMaps.count
            let outcome = await Self.outcome(body)
            reached.append((site, engine.meterMaps.count - before, outcome))
        }
        await drive("measureLoudness") { _ = try await store.measureLoudness(durationSeconds: 1) }
        await drive("renderBounce") { _ = try await store.renderBounce(toPath: path("b.wav"), durationSeconds: 1) }
        await drive("renderMixdown") { _ = try await store.renderMixdown(toPath: path("m.wav"), durationSeconds: 1) }
        await drive("renderStems+00") {
            _ = try await store.renderStems(toDirectory: path("s1"), durationSeconds: 1, includeMixdown: true)
        }
        await drive("renderStems+mastered") {
            _ = try await store.renderStems(toDirectory: path("s2"), durationSeconds: 1,
                                            includeMasteredMixdown: true)
        }
        await drive("probeInstrumentLiveness") { _ = try await store.probeInstrumentLiveness(trackId: drums) }
        await drive("bounceTrackInPlace") {
            _ = try await store.bounceTrackInPlace(trackId: drums, durationSeconds: 1, muteSource: false)
        }
        print("[measured] W44F T-N1a spy: " + reached.map { "\($0.site) \($0.calls) (\($0.outcome))" }
            .joined(separator: ", ") + "; legacy calls \(engine.legacyCalls); every map == transport's: "
            + "\(engine.meterMaps.allSatisfy { $0 == expected })")
        let calls = Dictionary(uniqueKeysWithValues: reached.map { ($0.site, $0.calls) })
        #expect(calls["measureLoudness"] == 1)
        #expect(calls["renderBounce"] == 1)
        #expect(calls["renderMixdown"] == 1)
        #expect(calls["renderStems+00"] == 3, "2 stems + the 00 Mixdown reference")
        #expect(calls["renderStems+mastered"] == 3, "2 stems + the mastered sibling")
        #expect(calls["probeInstrumentLiveness"] == 1)
        #expect(calls["bounceTrackInPlace"] == 1)
        #expect(engine.meterMaps.allSatisfy { $0 == expected }, "a render was handed a meter that is not the project's")
        #expect(engine.legacyCalls == 0, "a store render still crosses a meter-less seam")
    }

    /// ⭐ T-N1a, the refusal leg: a legacy-only engine REFUSES a project whose
    /// render depends on the meter it cannot carry (a meter change AND an
    /// enabled route to a tempo-synced source), before anything renders, and
    /// FORWARDS whenever dropping the meter cannot change the render: no meter
    /// change, a disabled route, a free-running step source. A synced route on
    /// the MASTER refuses exactly the MASTERED renders (the STEM class carries
    /// no master modulation), which also pins each site's render class.
    @Test("m39-w4-4a T-N1a: a legacy-only engine REFUSES a meter it cannot carry when a synced source is routed, and forwards whenever the meter cannot change the render")
    @MainActor
    func w44fLegacyOnlyEngineRefusesADroppedMeter() async throws {
        let engine = LegacyOnlyEngine()
        let store = try Self.w44fSyncedProject(engine: engine)
        let drums = store.tracks[0].id
        let meter = store.transport.meterMap
        #expect(meter.changes.count == 2)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-w44f-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func path(_ name: String) -> String { dir.appendingPathComponent("\(UUID().uuidString)-\(name)").path }
        func sessionRenders() async -> [String: String] {
            var result: [String: String] = [:]
            result["loudness"] = await Self.outcome { _ = try await store.measureLoudness(durationSeconds: 1) }
            result["bounce"] = await Self.outcome {
                _ = try await store.renderBounce(toPath: path("b.wav"), durationSeconds: 1)
            }
            result["mixdown"] = await Self.outcome {
                _ = try await store.renderMixdown(toPath: path("m.wav"), durationSeconds: 1)
            }
            result["stems"] = await Self.outcome {
                _ = try await store.renderStems(toDirectory: path("s"), durationSeconds: 1, includeMixdown: true)
            }
            result["liveness"] = await Self.outcome { _ = try await store.probeInstrumentLiveness(trackId: drums) }
            return result
        }
        let allRefused = ["loudness": "engineUnavailable", "bounce": "engineUnavailable",
                          "mixdown": "engineUnavailable", "stems": "engineUnavailable",
                          "liveness": "engineUnavailable"]

        // (a) Meter change + enabled synced route: refused, before anything rendered.
        let refused = await sessionRenders()
        let bounceInPlace = await Self.outcome {
            _ = try await store.bounceTrackInPlace(trackId: drums, durationSeconds: 1, muteSource: false)
        }
        let rendersAfterRefusal = (engine.legacyRenders, engine.legacyMixdowns)

        // (b) A disabled route is inert: served.
        store.tracks[0].modulationRoutes[0].enabled = false
        let disabled = await sessionRenders()
        store.tracks[0].modulationRoutes[0].enabled = true

        // (c) A free-running step source (no `stepDivision`) has no clock: served.
        let synced = store.tracks[0].modulationSources[0].params
        store.tracks[0].modulationSources[0].params = .stepSequencer(StepSequencerSourceParams(steps: [1, 0, 0]))
        let freeRunning = await sessionRenders()
        store.tracks[0].modulationSources[0].params = synced

        // (d) A synced route on the MASTER only: MASTERED refused, STEM served.
        store.tracks[0].modulationRoutes[0].enabled = false
        let masterSource = ModulationSource(kind: .stepSequencer, params: synced)
        store.masterModulationSources = [masterSource]
        store.masterModulationRoutes = [ModulationRoute(sourceID: masterSource.id, target: .volume, depth: -0.5)]
        let masterOnly = await sessionRenders()
        store.masterModulationSources = []
        store.masterModulationRoutes = []
        store.tracks[0].modulationRoutes[0].enabled = true

        // (e) The same project with the meter change removed: served.
        try store.setTempoMap(TempoMap(constantBPM: 120), meterMap: MeterMap(constant: TimeSignature()))
        let noMeterChange = store.transport.meterMap.changes.count
        let constant = await sessionRenders()

        print("[measured] W44F T-N1a legacy-only engine: meter change + synced route \(refused.sorted(by: { $0.key < $1.key })), "
              + "bounce-in-place \(bounceInPlace), legacy renders/mixdowns after the refusals "
              + "\(rendersAfterRefusal); route disabled \(disabled.sorted(by: { $0.key < $1.key })); free-running "
              + "\(freeRunning.sorted(by: { $0.key < $1.key })); master synced route only "
              + "\(masterOnly.sorted(by: { $0.key < $1.key })); meter change removed (\(noMeterChange) change) "
              + "\(constant.sorted(by: { $0.key < $1.key }))")
        #expect(refused == allRefused)
        #expect(bounceInPlace == "engineUnavailable")
        #expect(rendersAfterRefusal.0 == 0, "a refusal must come before anything renders")
        #expect(rendersAfterRefusal.1 == 0)
        // Served: everything but the liveness probe, whose own ladder analysis of
        // this double's two-sample audio may refuse, but never for the meter.
        for (label, outcomes) in [("route disabled", disabled), ("free-running", freeRunning),
                                  ("no meter change", constant)] {
            for site in ["loudness", "bounce", "mixdown", "stems"] {
                #expect(outcomes[site] == "served", "\(label): \(site) → \(outcomes[site] ?? "nil")")
            }
            #expect(outcomes["liveness"] != "engineUnavailable", "\(label): the liveness probe was refused")
        }
        #expect(masterOnly["loudness"] == "engineUnavailable")
        #expect(masterOnly["bounce"] == "engineUnavailable")
        #expect(masterOnly["mixdown"] == "engineUnavailable")
        #expect(masterOnly["stems"] == "served", "stems carry no master modulation (STEM class)")
        #expect(masterOnly["liveness"] != "engineUnavailable", "the probe carries no master modulation")
        #expect(noMeterChange == 1)
    }
}
