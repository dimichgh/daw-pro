import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// W9-PANFIX — the fixes the independent review of m39-panlaw-new (W9-PLRT) asked for.
//
// R1  An offline render takes the song's pan rule as an INPUT. The store captures the rule ONCE per operation and hands
//     it to every pass through the pan-carrying seam; the engine's cached rule is the LIVE graph's and never reaches an
//     export. (Before: `AudioEngine.renderOffline` read its cache after awaiting the stretch cache, so a New Project
//     pressed during `render.stems` rendered the rest of a SAVED song on the new rule.)
// R2  New songs: the five built-in templates that pan, measured on both rules (loudness AND true peak). Always on:
//     jazz-combo (the hottest) in a new song, 4 bars, loudness pinned. The 8-bar table: PANLAW_TEMPLATES=1.
// R4  Two live gaps where a new song's knob was not applied: the idle instrument strip's delay-compensation drain, and
//     a quantum with no host time on a strip that has a schedule.
// R5  Project boundaries push the rule to the engine's cache only; the attach push keeps its parameter pass.
// R8  The track meter reads post-pan in a new song: measured.
//
// Nonisolated suites over `@MainActor` helpers and `@MainActor` test functions (no new `@MainActor` suite).

private struct PanFixError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Shared rig

@MainActor
enum PanFixRig {
    /// A scratch folder that the test removes.
    static func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-panfix-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A named store whose every on-disk home is inside `dir` (never the real Application Support).
    static func store(_ name: String, in dir: URL, tracks: [Track] = [],
                      panLaw: PanLaw = PanLaw.savedSongDefault) -> ProjectStore {
        let store = ProjectStore(projectName: name, tracks: tracks, panLaw: panLaw)
        store.crashRecovery.directory = dir.appendingPathComponent("crash", isDirectory: true)
        store.crashRecovery.clock = { Date(timeIntervalSince1970: 1_000) }
        store.autosaveRecoveryDirectory = dir.appendingPathComponent("recovery", isDirectory: true)
        store.generationImportsDirectory = dir.appendingPathComponent("generations", isDirectory: true)
        return store
    }

    /// Two audio tracks panned by the KNOB (so dropping the rule would change a new song's render).
    static func pannedPair() -> [Track] {
        [Track(name: "Left Gtr", kind: .audio, pan: -0.5,
               clips: [Clip(name: "l", startBeat: 0, lengthBeats: 4)]),
         Track(name: "Right Gtr", kind: .audio, pan: 0.5,
               clips: [Clip(name: "r", startBeat: 0, lengthBeats: 4)])]
    }

    /// The same pair with both knobs centred.
    static func centredPair() -> [Track] {
        pannedPair().map { var track = $0; track.pan = 0; return track }
    }

    static func outcome(_ body: @MainActor () async throws -> Void) async -> String {
        do {
            try await body()
            return "served"
        } catch ProjectError.engineUnavailable {
            return "engineUnavailable"
        } catch {
            return "other: \(error)"
        }
    }
}

/// A double that implements the PAN-CARRYING render requirements (R1) and every older one. Each pan-carrying call
/// records the rule it was handed; an older requirement counts as a LEGACY call, so a store site left on an older seam
/// is named rather than averaged away. It also records the pan-rule pushes and the boundary order (R5).
@MainActor
final class PanLawRenderSpy: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    private(set) var renderLaws: [PanLaw] = []
    private(set) var legacyCalls = 0
    var events: [String] = []
    /// Runs ONCE, inside the first pan-carrying render, then clears: "New Project pressed mid-export".
    var duringFirstRender: (@MainActor () -> Void)?
    /// Runs ONCE, inside the compensation probe, then clears: "New Project pressed while the plan is probed".
    var duringPlan: (@MainActor () -> Void)?

    private static let audio: RenderedAudio = {
        let tone = (0..<48_000).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        return RenderedAudio(sampleRate: 48_000, channelData: [tone, tone])
    }()
    private static let info = AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) { events.append("tracksDidChange") }
    func projectWillReplace() { events.append("projectWillReplace") }
    func panLawChanged(_ law: PanLaw) { events.append("panLawChanged(\(law.rawValue))") }
    func setPanLaw(_ law: PanLaw) { events.append("setPanLaw(\(law.rawValue))") }
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

    func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int] {
        if let hook = duringPlan { duringPlan = nil; hook() }
        return [:]
    }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double, to url: URL) async throws -> AudioFileInfo {
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
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        legacyCalls += 1
        return Self.audio
    }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
        legacyCalls += 1
        return Self.info
    }

    func renderOffline(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        legacyCalls += 1
        return Self.audio
    }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
        legacyCalls += 1
        return Self.info
    }

    func renderOffline(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap, panLaw: PanLaw,
                       masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        renderLaws.append(panLaw)
        if let hook = duringFirstRender { duringFirstRender = nil; hook() }
        return Self.audio
    }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap, panLaw: PanLaw,
                       masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
        renderLaws.append(panLaw)
        if let hook = duringFirstRender { duringFirstRender = nil; hook() }
        return Self.info
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo { Self.info }
}

/// A conformer written before R1: it implements only the oldest render requirements, so every newer one reaches it
/// through the protocol's extension defaults. Counts what it serves.
@MainActor
final class PanLawLegacyOnlyEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    private(set) var served = 0
    /// The pan-rule pushes it hears: it implements only the FULL push, so a cache-only boundary push reaches it
    /// through the protocol default.
    private(set) var panLawPushes: [PanLaw] = []

    func panLawChanged(_ law: PanLaw) { panLawPushes.append(law) }

    private static let audio: RenderedAudio = {
        let tone = (0..<48_000).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        return RenderedAudio(sampleRate: 48_000, channelData: [tone, tone])
    }()

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
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double, to url: URL) async throws -> AudioFileInfo {
        served += 1
        return AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
    }

    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        served += 1
        return Self.audio
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
    }
}

// MARK: - R1 + R5

@Suite("W9-PANFIX R1/R5: an export takes the song's pan rule as an input; boundaries push the rule cache-only",
       .serialized)
struct PanLawFixSeamTests {

    /// ⭐ THE R1 GATE. A SAVED song (original rule) exports stems; the FIRST pass presses New Project (the main actor
    /// is free between passes, so a user or a second agent can). Every pass must still render the rule the export
    /// started with. A store that read its rule per pass would hand the later passes the new song's rule.
    @Test("R1: New Project pressed during a multi-pass export — every pass still gets the rule the export captured")
    @MainActor
    func newProjectMidExportKeepsTheCapturedRule() async throws {
        let dir = try PanFixRig.scratch("r1-flip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = PanLawRenderSpy()
        let store = PanFixRig.store("PANFIX R1 saved song", in: dir, tracks: PanFixRig.pannedPair())
        store.engine = engine
        #expect(store.panLaw == .balance, "control: the export starts on a saved song's rule")
        engine.duringFirstRender = { try? store.newProject(discardChanges: true) }
        _ = try await store.renderStems(toDirectory: dir.appendingPathComponent("stems").path,
                                        durationSeconds: 1, includeMixdown: true, includeMasteredMixdown: true)
        print("[PANFIX] R1 stems with New Project after pass 1: laws \(engine.renderLaws.map(\.rawValue)), "
              + "store now \(store.panLaw.rawValue), legacy \(engine.legacyCalls)")
        #expect(store.panLaw == .equalPower, "control: New Project really flipped the store mid-export")
        #expect(engine.renderLaws.count == 4, "2 stems + 00 Mixdown + the mastered sibling")
        #expect(engine.renderLaws.allSatisfy { $0 == .balance },
                "a pass after New Project rendered the saved song on another rule: \(engine.renderLaws)")
        #expect(engine.legacyCalls == 0, "a pass crossed a seam that cannot carry the rule")

        // The same race through bounce-in-place, whose one render waits on the compensation probe first.
        let bouncer = PanFixRig.store("PANFIX R1 saved song bounce", in: dir, tracks: PanFixRig.pannedPair())
        let spy = PanLawRenderSpy()
        bouncer.engine = spy
        let source = bouncer.tracks[0].id
        spy.duringPlan = { try? bouncer.newProject(discardChanges: true) }
        // m39-render-pass-race: the bounce belongs to the song that closed, so it must REFUSE rather than land its
        // track in the new song (`RenderPassRaceTests` drives every switch and moment).
        var bounceRefusal: (any Error)?
        do {
            _ = try await bouncer.bounceTrackInPlace(trackId: source, durationSeconds: 1, muteSource: false)
        } catch {
            bounceRefusal = error
        }
        #expect(bouncer.panLaw == .equalPower, "control: New Project landed during the probe")
        #expect(spy.renderLaws == [.balance], "bounce-in-place rendered on a rule it did not start with")
        #expect(bouncer.tracks.isEmpty, "bounce-in-place landed in the NEW song: \(bouncer.tracks.map(\.name))")
        #expect(bounceRefusal is ProjectError,
                "a bounce whose song closed must refuse: \(String(describing: bounceRefusal))")
    }

    /// Every store session render crosses the PAN-CARRYING seam with the song's rule, and none reaches an older
    /// requirement. Each site is driven on its own and must add its own record.
    @Test("R1: every store render hands the engine the song's rule through the pan-carrying seam (new and saved songs)")
    @MainActor
    func everyStoreRenderCarriesTheRule() async throws {
        let dir = try PanFixRig.scratch("r1-sites")
        defer { try? FileManager.default.removeItem(at: dir) }
        for newSong in [true, false] {
            let engine = PanLawRenderSpy()
            let store = PanFixRig.store("PANFIX R1 sites", in: dir)
            store.engine = engine
            if newSong { try store.newProject(discardChanges: true) }
            store.tracks = PanFixRig.pannedPair()
            var instrument = Track(name: "Synth", kind: .instrument, pan: 0.3,
                                   clips: [Clip(name: "n", startBeat: 0, lengthBeats: 4,
                                                notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 0,
                                                                 lengthBeats: 1)])],
                                   instrument: InstrumentDescriptor(kind: .polySynth))
            instrument.volume = 0.8
            store.tracks.append(instrument)
            let expected: PanLaw = newSong ? .equalPower : .balance
            #expect(store.panLaw == expected)
            func path(_ name: String) -> String { dir.appendingPathComponent("\(UUID().uuidString)-\(name)").path }
            var calls: [String: Int] = [:]
            var outcomes: [String: String] = [:]
            func drive(_ site: String, _ body: @MainActor () async throws -> Void) async {
                let before = engine.renderLaws.count
                outcomes[site] = await PanFixRig.outcome(body)
                calls[site] = engine.renderLaws.count - before
            }
            await drive("measureLoudness") { _ = try await store.measureLoudness(durationSeconds: 1) }
            await drive("renderBounce") { _ = try await store.renderBounce(toPath: path("b.wav"), durationSeconds: 1) }
            await drive("renderMixdown") { _ = try await store.renderMixdown(toPath: path("m.wav"), durationSeconds: 1) }
            await drive("renderStems+00+mastered") {
                _ = try await store.renderStems(toDirectory: path("s"), durationSeconds: 1, includeMixdown: true,
                                                includeMasteredMixdown: true)
            }
            await drive("probeInstrumentLiveness") { _ = try await store.probeInstrumentLiveness(trackId: instrument.id) }
            await drive("bounceTrackInPlace") {
                _ = try await store.bounceTrackInPlace(trackId: store.tracks[0].id, durationSeconds: 1,
                                                       muteSource: false)
            }
            print("[PANFIX] R1 sites (\(newSong ? "new" : "saved") song): \(calls.sorted { $0.key < $1.key }) "
                  + "outcomes \(outcomes.values.filter { $0 != "served" }) laws "
                  + "\(Set(engine.renderLaws.map(\.rawValue))) legacy \(engine.legacyCalls)")
            // The liveness probe analyses what it gets back; the spy's tone is not a ladder, so only its CALL counts.
            #expect(outcomes.filter { $0.key != "probeInstrumentLiveness" }.values.allSatisfy { $0 == "served" },
                    "\(outcomes)")
            #expect(calls["measureLoudness"] == 1)
            #expect(calls["renderBounce"] == 1)
            #expect(calls["renderMixdown"] == 1)
            #expect(calls["renderStems+00+mastered"] == 5, "3 stems + 00 Mixdown + the mastered sibling")
            #expect(calls["probeInstrumentLiveness"] == 1)
            #expect(calls["bounceTrackInPlace"] == 1)
            #expect(engine.renderLaws.allSatisfy { $0 == expected }, "\(engine.renderLaws)")
            #expect(engine.legacyCalls == 0, "a store render still crosses a seam without the rule")
        }
    }

    /// The protocol default for an engine written before R1: it forwards when dropping the rule cannot change the
    /// render (the original rule, or no knob off centre) and REFUSES otherwise, before anything renders.
    @Test("R1: an engine that cannot carry the rule REFUSES a new song with a panned knob and serves everything else")
    @MainActor
    func legacyEngineRefusesADroppedRule() async throws {
        let dir = try PanFixRig.scratch("r1-legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        func sessionRenders(_ store: ProjectStore) async -> [String: String] {
            func path(_ name: String) -> String { dir.appendingPathComponent("\(UUID().uuidString)-\(name)").path }
            var result: [String: String] = [:]
            result["loudness"] = await PanFixRig.outcome { _ = try await store.measureLoudness(durationSeconds: 1) }
            result["bounce"] = await PanFixRig.outcome {
                _ = try await store.renderBounce(toPath: path("b.wav"), durationSeconds: 1)
            }
            result["mixdown"] = await PanFixRig.outcome {
                _ = try await store.renderMixdown(toPath: path("m.wav"), durationSeconds: 1)
            }
            result["stems"] = await PanFixRig.outcome {
                _ = try await store.renderStems(toDirectory: path("s"), durationSeconds: 1, includeMixdown: true)
            }
            result["bounceInPlace"] = await PanFixRig.outcome {
                _ = try await store.bounceTrackInPlace(trackId: store.tracks[0].id, durationSeconds: 1,
                                                       muteSource: false)
            }
            return result
        }
        // (a) A NEW song with a knob off centre: dropping the rule would change the bytes → refused, nothing served.
        let refusing = PanLawLegacyOnlyEngine()
        let newSong = PanFixRig.store("PANFIX R1 legacy new", in: dir)
        newSong.engine = refusing
        try newSong.newProject(discardChanges: true)
        newSong.tracks = PanFixRig.pannedPair()
        let refused = await sessionRenders(newSong)
        print("[PANFIX] R1 legacy engine, new song + panned knob: \(refused.sorted { $0.key < $1.key }), "
              + "served \(refusing.served)")
        #expect(refused.values.allSatisfy { $0 == "engineUnavailable" }, "\(refused)")
        #expect(refusing.served == 0, "a refused render must refuse BEFORE anything renders")

        // (b) The same new song with every knob centred: the rules agree → served.
        let centred = PanLawLegacyOnlyEngine()
        let newCentred = PanFixRig.store("PANFIX R1 legacy centred", in: dir)
        newCentred.engine = centred
        try newCentred.newProject(discardChanges: true)
        newCentred.tracks = PanFixRig.centredPair()
        let servedCentred = await sessionRenders(newCentred)
        #expect(servedCentred.values.allSatisfy { $0 == "served" }, "\(servedCentred)")
        #expect(centred.served > 0)

        // (c) A SAVED song with panned knobs: the original rule is what an older engine renders → served.
        let saved = PanLawLegacyOnlyEngine()
        let savedSong = PanFixRig.store("PANFIX R1 legacy saved", in: dir, tracks: PanFixRig.pannedPair())
        savedSong.engine = saved
        let servedSaved = await sessionRenders(savedSong)
        #expect(servedSaved.values.allSatisfy { $0 == "served" }, "\(servedSaved)")
        #expect(saved.served > 0)
        #expect(OfflinePanLawSeam.lawChangesRender(.equalPower, tracks: PanFixRig.pannedPair()))
        #expect(!OfflinePanLawSeam.lawChangesRender(.equalPower, tracks: PanFixRig.centredPair()))
        #expect(!OfflinePanLawSeam.lawChangesRender(.balance, tracks: PanFixRig.pannedPair()))
    }

    /// ⭐ The ENGINE side of R1: the render follows the rule it is HANDED, never the engine's cached (live) rule.
    @Test("R1: AudioEngine renders the rule it is handed, not its cached live rule (both directions, real renders)")
    @MainActor
    func engineRendersTheArgumentNotTheCache() async throws {
        let tracks = try PanLawRig.strip("mono", knob: 0.4, lane: nil)
        func render(_ engine: AudioEngine, _ law: PanLaw) async throws -> [[Float]] {
            try await engine.renderOffline(
                tracks: tracks, tempoMap: PanLawRig.tempoMap, meterMap: MeterMap(constant: TimeSignature()),
                panLaw: law, masterVolume: 1, masterEffects: [], masterAutomation: [],
                masterModulationSources: [], masterModulationRoutes: [],
                fromBeat: 0, durationSeconds: PanLawRig.seconds, forcedCompensationTargets: nil).channelData
        }
        let newCache = AudioEngine()
        newCache.panLawChanged(.equalPower)
        let oldCache = AudioEngine()
        #expect(newCache.panLaw == .equalPower && oldCache.panLaw == .balance, "control: the two caches differ")
        let savedOnNewCache = try await render(newCache, .balance)
        let savedOnOldCache = try await render(oldCache, .balance)
        let newOnOldCache = try await render(oldCache, .equalPower)
        let newOnNewCache = try await render(newCache, .equalPower)
        let a = PanLawRig.differing(savedOnNewCache, savedOnOldCache)
        let b = PanLawRig.differing(newOnOldCache, newOnNewCache)
        let axis = PanLawRig.differing(savedOnOldCache, newOnOldCache)
        print("[PANFIX] R1 engine: saved rule on new cache vs old cache differing = \(a); new rule on old vs new "
              + "cache = \(b); control saved vs new rule = \(axis)")
        #expect(a == 0, "the engine rendered its cache, not the saved song's rule it was handed")
        #expect(b == 0, "the engine rendered its cache, not the new song's rule it was handed")
        #expect(axis > 0, "control: the two rules render differently on this strip")
        #expect(TestSignals.peak(savedOnOldCache[0] + savedOnOldCache[1], in: 0..<96_000) > 0.05, "silent render")

        // An entry point that cannot carry the rule renders the ORIGINAL rule — never the cache.
        let legacy = try await newCache.renderOffline(
            tracks: tracks, tempoMap: PanLawRig.tempoMap, meterMap: MeterMap(constant: TimeSignature()),
            masterVolume: 1, masterEffects: [], masterAutomation: [],
            masterModulationSources: [], masterModulationRoutes: [],
            fromBeat: 0, durationSeconds: PanLawRig.seconds, forcedCompensationTargets: nil).channelData
        #expect(PanLawRig.differing(legacy, savedOnOldCache) == 0,
                "the rule-less entry point read the engine's cached rule")
        withExtendedLifetime((newCache, oldCache)) {}
    }

    /// R5: a project boundary pushes the rule cache-only (`setPanLaw`), BEFORE the tracks whose pass moves the knobs;
    /// attaching an engine keeps the pass (`panLawChanged`).
    @Test("R5: New / Open / Recover push the rule cache-only before the tracks; attaching keeps the parameter pass")
    @MainActor
    func boundariesPushTheRuleCacheOnly() async throws {
        let dir = try PanFixRig.scratch("r5")
        defer { try? FileManager.default.removeItem(at: dir) }
        func check(_ events: [String], push: String, _ label: String) {
            let pushAt = events.firstIndex(of: push)
            let tracksAt = events.lastIndex(of: "tracksDidChange")
            #expect(pushAt != nil, "\(label): no cache-only push \(push) in \(events)")
            #expect(!events.contains { $0.hasPrefix("panLawChanged") }, "\(label): a boundary ran the full pass")
            if let pushAt, let tracksAt { #expect(pushAt < tracksAt, "\(label): the rule landed after the tracks") }
        }
        // Attach.
        let spy = PanLawRenderSpy()
        let store = PanFixRig.store("PANFIX R5", in: dir)
        store.engine = spy
        #expect(spy.events.contains("panLawChanged(balance)"), "attaching keeps the full push: \(spy.events)")
        #expect(!spy.events.contains { $0.hasPrefix("setPanLaw") })
        // New.
        spy.events = []
        try store.newProject(discardChanges: true)
        check(spy.events, push: "setPanLaw(equalPower)", "New")
        // Open a saved song (no key → the original rule).
        let saver = PanFixRig.store("PANFIX R5 saved", in: dir)
        saver.addTrack(name: "Old")
        let bundle = dir.appendingPathComponent("PANFIX R5 Saved Song.dawproj").path
        _ = try saver.saveProject(to: bundle)
        spy.events = []
        _ = try store.openProject(at: bundle, discardChanges: true)
        #expect(store.panLaw == .balance, "control: the open happened")
        check(spy.events, push: "setPanLaw(balance)", "Open")
        // Recover a crashed NEW song.
        let crashed = PanFixRig.store("PANFIX R5 crashed", in: dir)
        try crashed.newProject(discardChanges: true)
        _ = crashed.beginCrashDetection()
        crashed.addTrack(name: "Unsaved")
        await crashed.autosaveTick()
        let relaunched = PanFixRig.store("PANFIX R5 relaunched", in: dir)
        let recoverSpy = PanLawRenderSpy()
        relaunched.engine = recoverSpy
        #expect(relaunched.beginCrashDetection(), "control: the first session's lock reads as a crash")
        recoverSpy.events = []
        _ = try relaunched.recoverFromAutosave(accept: true)
        #expect(relaunched.panLaw == .equalPower, "control: the recovery happened")
        check(recoverSpy.events, push: "setPanLaw(equalPower)", "Recover")

        // An engine that implements only the full push still hears every boundary (the protocol default forwards).
        let legacy = PanLawLegacyOnlyEngine()
        let plain = PanFixRig.store("PANFIX R5 plain spy", in: dir)
        plain.engine = legacy
        try plain.newProject(discardChanges: true)
        #expect(legacy.panLawPushes == [.balance, .equalPower], "\(legacy.panLawPushes)")
    }

    /// R5 on the real engine: the cache-only push moves the cache and the live graph's rule, and NO knob; the
    /// following parameter pass moves the knob.
    @Test("R5: AudioEngine.setPanLaw is cache-only; the next tracksDidChange moves the knob; panLawChanged keeps its pass")
    @MainActor
    func engineCacheOnlyPush() throws {
        let engine = AudioEngine()
        let track = Track(name: "R5 knob", kind: .audio, pan: 0.4)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.automationRenderer(forTrack: track.id), "no strip was built")
        #expect(renderer.currentStaticPan == 0, "the original rule publishes 0")
        engine.setPanLaw(.equalPower)
        #expect(engine.panLaw == .equalPower && engine.graph.panLaw == .equalPower)
        #expect(renderer.currentStaticPan == 0, "a cache-only push ran a parameter pass")
        engine.tracksDidChange([track])
        let after = try #require(engine.graph.automationRenderer(forTrack: track.id))
        #expect(after.currentStaticPan == 0.4, "the following pass must hand the knob to the stage")
        engine.panLawChanged(.balance)
        #expect(after.currentStaticPan == 0, "the full push runs its own pass")
    }
}

// MARK: - R4

/// Writes a constant level to every channel: what reaches the delay-compensation ring is then known exactly.
private final class PanFixConstantInstrument: InstrumentRendering {
    let level: Float
    init(level: Float) { self.level = level }
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>, renderStart: Int64, frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        for buffer in output {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var i = 0
            while i < frameCount { data[i] = level; i += 1 }
        }
    }
    func reset() {}
}

@Suite("W9-PANFIX R4: the knob stage on the two live paths that skipped it")
struct PanLawFixLiveGapTests {
    static func gains(_ p: Double) -> (l: Float, r: Float) {
        let theta = (p + 1) * (Double.pi / 4)
        return (Float(2.0.squareRoot() * cos(theta)), Float(2.0.squareRoot() * sin(theta)))
    }

    /// R4a. An instrument strip with NO effects that sits idle (stopped, nothing held) drains the last
    /// `compensationSamples` of its delay-compensation ring. The ring holds audio from BEFORE the knob stage, so in a
    /// new song that tail used to play centred.
    @Test("R4a: an idle instrument strip with no effects drains its delay-compensation tail through the knob stage")
    @MainActor
    func idleDrainPansTheKnob() throws {
        func run(stagePan: Double) throws -> (rolling: [[Float]], drain: [[Float]], drainSilent: Bool) {
            let instrument = PanFixConstantInstrument(level: 0.25)
            let renderer = InstrumentRenderer(instrument: instrument, sampleRate: 48_000)
            renderer.compensation.setTarget(240)
            renderer.automation.publishStaticPan(stagePan)
            renderer.publish(MIDIEventSchedule(generation: 1, mode: .offline, sampleRate: 48_000, events: []))
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            buffer.frameLength = 512
            var sampleTime = 0.0
            func pull() throws -> ([[Float]], Bool) {
                var stamp = AudioTimeStamp()
                stamp.mSampleTime = sampleTime
                stamp.mFlags = .sampleTimeValid
                var silence = ObjCBool(false)
                let status = renderer.renderQuantum(timestamp: &stamp, frameCount: 512,
                                                    audioBufferList: buffer.mutableAudioBufferList,
                                                    isSilence: &silence)
                #expect(status == noErr)
                sampleTime += 512
                let data = try #require(buffer.floatChannelData)
                return ((0..<2).map { Array(UnsafeBufferPointer(start: data[$0], count: 512)) }, silence.boolValue)
            }
            var rolling: [[Float]] = []
            for _ in 0..<16 { rolling = try pull().0 }   // settles the ring's 0 → 240 retarget
            renderer.publish(nil)                        // stopped: the idle path from here on
            let (drain, silent) = try pull()
            return (rolling, drain, silent)
        }
        let g = Self.gains(0.4)
        let new = try run(stagePan: 0.4)
        #expect(!new.drainSilent, "control: the ring was not inert, so the drain path ran")
        #expect(new.rolling[0][100] == 0.25 * g.l && new.rolling[1][100] == 0.25 * g.r,
                "control: while it plays, the strip pans (\(new.rolling[0][100]), \(new.rolling[1][100]))")
        print("[PANFIX] R4a drain frame 0: L \(new.drain[0][0]) R \(new.drain[1][0]) (panned: \(0.25 * g.l) / "
              + "\(0.25 * g.r)); frame 300: L \(new.drain[0][300]) R \(new.drain[1][300])")
        #expect((0..<240).allSatisfy { new.drain[0][$0] == 0.25 * g.l && new.drain[1][$0] == 0.25 * g.r },
                "the drained tail plays centred: it skipped the knob stage")
        #expect((240..<512).allSatisfy { new.drain[0][$0] == 0 && new.drain[1][$0] == 0 }, "the drain ends")
        // A song on the original rule publishes 0: the drain is untouched, bit for bit.
        let old = try run(stagePan: 0)
        #expect((0..<240).allSatisfy { old.drain[0][$0] == 0.25 && old.drain[1][$0] == 0.25 },
                "the original rule's drain must not change")
    }

    /// R4b. On a strip that has ANY schedule (here a fader lane), a live quantum without a valid host time cannot be
    /// placed on the timeline and returns early. It must still pan the knob when no lane and no route own pan.
    @Test("R4b: a live quantum with no host time still pans the knob on a strip with a schedule (no pan lane, no route)")
    @MainActor
    func noHostTimeQuantumPansTheKnob() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let data = try #require(buffer.floatChannelData)
        func run(_ renderer: AutomationRenderer) -> [[Float]] {
            for c in 0..<2 { for i in 0..<256 { data[c][i] = 0.5 } }
            var stamp = AudioTimeStamp()   // no `.hostTimeValid`
            renderer.apply(bufferList: buffer.mutableAudioBufferList, frameCount: 256, timestamp: &stamp)
            return (0..<2).map { Array(UnsafeBufferPointer(start: data[$0], count: 256)) }
        }
        func schedule(pan: Bool) -> AutomationSchedule {
            let points = [AutomationBreakpoint(sampleTime: 0, value: 1, holdsSegment: true),
                          AutomationBreakpoint(sampleTime: 96_000, value: 1, holdsSegment: false)]
            return AutomationSchedule(generation: 1, mode: .live(anchorHostTime: 1 << 33), sampleRate: 48_000,
                                      volumePoints: pan ? [] : points, panPoints: pan ? points : [])
        }
        let g = Self.gains(0.4)
        let faderLane = AutomationRenderer()
        faderLane.publish(schedule(pan: false))
        faderLane.publishStaticPan(0.4)
        let out = run(faderLane)
        print("[PANFIX] R4b no-host-time quantum, fader lane + knob 0.4: L \(out[0][0]) R \(out[1][0]) "
              + "(panned: \(0.5 * g.l) / \(0.5 * g.r))")
        #expect((0..<256).allSatisfy { out[0][$0] == 0.5 * g.l && out[1][$0] == 0.5 * g.r },
                "the knob played centred on a quantum with no host time")
        // The original rule publishes 0: untouched.
        let original = AutomationRenderer()
        original.publish(schedule(pan: false))
        original.publishStaticPan(0)
        #expect(run(original).allSatisfy { $0.allSatisfy { $0 == 0.5 } }, "the original rule must not change")
        // A pan LANE owns pan: the knob stage stays out of that quantum (it leaves audio alone, as before).
        let panLane = AutomationRenderer()
        panLane.publish(schedule(pan: true))
        panLane.publishStaticPan(0.4)
        #expect(run(panLane).allSatisfy { $0.allSatisfy { $0 == 0.5 } }, "the knob stage ran under a pan lane")
    }
}

// MARK: - R8: the track meter

@MainActor
private final class PanFixMeterLog {
    var frames: [MeterFrame] = []
}

@MainActor
enum PanFixMeters {
    nonisolated static let seconds = 4.0

    /// A 4 s source (the gate's 1.5 s files leave too few meter frames: the offline tap delivers ~0.1 s each):
    /// mono = 1 kHz at amplitude 0.5; stereo = left 440 Hz at 0.5, right 660 Hz at 0.3 (the gate's signals).
    static func source(channels: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-panfix-meter-\(ProcessInfo.processInfo.processIdentifier)-\(channels)ch.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate = PanLawRig.sampleRate
        let count = Int((seconds + 0.5) * rate)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { throw PanFixError("meter source buffer") }
        buffer.frameLength = AVAudioFrameCount(count)
        var frame = 0
        while frame < count {
            let t = Double(frame) / rate
            if channels == 1 {
                data[0][frame] = Float(0.5 * sin(2 * Double.pi * 1_000 * t))
            } else {
                data[0][frame] = Float(0.5 * sin(2 * Double.pi * 440 * t))
                data[1][frame] = Float(0.3 * sin(2 * Double.pi * 660 * t))
            }
            frame += 1
        }
        try file.write(from: buffer)
        return url
    }

    /// One audio strip of `kind` ("mono" / "stereo") whose clip covers the whole render, panned by the KNOB.
    static func strip(_ kind: String, knob: Double) throws -> Track {
        let url = try source(channels: kind == "mono" ? 1 : 2)
        return Track(name: "R8 \(kind)", kind: .audio, pan: knob,
                     clips: [Clip(name: "R8 \(kind) clip", startBeat: 0, lengthBeats: seconds * 2, audioFileURL: url)])
    }

    struct Reading: CustomStringConvertible {
        var peakDb: Double
        var rmsDb: Double
        var frames: Int
        var description: String { String(format: "peak %.3f dB, rms %.3f dB (%d tap frames)", peakDb, rmsDb, frames) }
    }

    /// The strip's METER (the per-track tap on its mixer, `PlaybackGraph.installMeterTap`) over the steady part of
    /// a one-strip offline roll (the `OfflineRenderer.beginSession` order).
    static func read(_ tracks: [Track], track id: UUID, law: PanLaw) async throws -> Reading {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine, graphRate: PanLawRig.sampleRate)
        graph.panLaw = law
        guard let format = AVAudioFormat(standardFormatWithSampleRate: PanLawRig.sampleRate, channels: 2) else {
            throw PanFixError("format")
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        _ = engine.mainMixerNode
        let log = PanFixMeterLog()
        graph.meterSink = { trackID, frame in
            if trackID == id { log.frames.append(frame) }
        }
        _ = graph.reconcile(tracks: tracks)
        graph.armOfflineAutomation(fromBeat: 0, tempoMap: PanLawRig.tempoMap)
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        try engine.start()
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        graph.scheduleAll(fromBeat: 0, tempoMap: PanLawRig.tempoMap, cause: .offlineRender)
        graph.startAllPlayers(at: nil)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else { throw PanFixError("buffer") }
        var rendered = 0
        while rendered < Int(seconds * PanLawRig.sampleRate) {
            let status = try engine.renderOffline(512, to: buffer)
            guard status == .success else { throw PanFixError("render status \(status.rawValue)") }
            rendered += Int(buffer.frameLength)
        }
        engine.stop()
        // Tap frames hop to the main actor as queued tasks, so under a parallel run they arrive late: wait until
        // at least 5 have landed AND the count has held still for 0.5 s (20 s at most).
        var previous = -1
        var unchanged = 0
        var rounds = 0
        while (unchanged < 10 || log.frames.count < 5) && rounds < 400 {
            try await Task.sleep(for: .milliseconds(50))
            rounds += 1
            if log.frames.count == previous { unchanged += 1 } else { unchanged = 0; previous = log.frames.count }
        }
        // The clip is one steady tone over the whole render, so every tap frame but the first (the player's start)
        // and the last reads the same: the MEDIAN of the inner frames, independent of the tap's size and of how
        // many frames a loaded machine delivered in time.
        let inner = Array(log.frames.dropFirst().dropLast())
        guard inner.count >= 3 else { throw PanFixError("only \(log.frames.count) meter frames arrived") }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        let peak = median(inner.map(\.peak))
        let rms = median(inner.map(\.rms))
        withExtendedLifetime(graph) {}
        return Reading(peakDb: PanLawRig.dB(peak), rmsDb: PanLawRig.dB(rms), frames: log.frames.count)
    }
}

@Suite("W9-PANFIX R8: a new song's track meter reads after the pan", .serialized)
struct PanLawFixMeterTests {
    /// Always on and deterministic: WHERE the knob acts relative to the strip's meter, which taps the strip
    /// mixer's OUTPUT (`PlaybackGraph.installMeterTap`). A saved song pans at the mixer node (where it joins the
    /// mix: after the tap); a new song pans in the knob stage, before the mixer (so before the tap).
    @Test("R8: a saved song pans the knob after the strip's meter tap (mixer node); a new song before it (knob stage)")
    @MainActor
    func knobSitsBeforeTheMeterInANewSong() throws {
        for law in [PanLaw.balance, .equalPower] {
            let engine = AVAudioEngine()
            let graph = PlaybackGraph(engine: engine, graphRate: PanLawRig.sampleRate)
            graph.panLaw = law
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: PanLawRig.sampleRate, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            _ = engine.mainMixerNode
            let track = Track(name: "R8 knob", kind: .audio, pan: 0.5)
            _ = graph.reconcile(tracks: [track])
            graph.applyParameters(tracks: [track], playheadBeat: 0)
            let mixer = try #require(graph.stripMixer(forTrack: track.id))
            let stage = try #require(graph.automationRenderer(forTrack: track.id))
            print("[PANFIX] R8 placement \(law.rawValue): mixer node pan \(mixer.pan), knob stage \(stage.currentStaticPan)")
            if law == .balance {
                #expect(mixer.pan == 0.5 && stage.currentStaticPan == 0, "a saved song pans at the node, after the tap")
            } else {
                #expect(mixer.pan == 0 && stage.currentStaticPan == 0.5, "a new song pans in the stage, before the tap")
            }
        }
    }

    /// Measured, not fixed: in a song on the original rule the strip's meter reads BEFORE the knob (the mixer node
    /// pans where it joins the mix); in a new song the knob stage pans before the meter. The meter's PEAK is the
    /// loudest channel, so a hard-panned part reads higher; its RMS pools both channels, which the automation rule
    /// keeps constant.
    /// ENV-GATED (`PANFIX_R8=1`): it reads the real meter, whose frames reach the main actor as queued tasks.
    @Test("R8 measure: a panned track's meter in a new song vs a saved song (mono + stereo, p = 1.0 and 0.5; PANFIX_R8=1)",
          .enabled(if: ProcessInfo.processInfo.environment["PANFIX_R8"] == "1"))
    @MainActor
    func meterReadsAfterThePan() async throws {
        var rows: [String] = []
        for kind in ["mono", "stereo"] {
            let centre = try PanFixMeters.strip(kind, knob: 0)
            let c = try await PanFixMeters.read([centre], track: centre.id, law: .balance)
            #expect(c.peakDb > -30, "control: the meter saw the signal (\(c))")
            for p in [1.0, 0.5] {
                let track = try PanFixMeters.strip(kind, knob: p)
                let old = try await PanFixMeters.read([track], track: track.id, law: .balance)
                let new = try await PanFixMeters.read([track], track: track.id, law: .equalPower)
                let row = String(format: "%@ p=%.1f: saved song %@ | new song %@ | new - saved: peak %+.3f dB, rms %+.3f dB",
                                 kind, p, old.description, new.description,
                                 new.peakDb - old.peakDb, new.rmsDb - old.rmsDb)
                rows.append(row)
                print("[PANFIX] R8 meter \(row)")
                // Saved songs: the meter reads before the knob, so it matches the centred strip.
                #expect(abs(old.peakDb - c.peakDb) < 0.01, "a saved song's meter moved with the knob: \(row)")
                if kind == "mono" {
                    let want = 20 * log10(2.0.squareRoot() * sin((p + 1) * Double.pi / 4))
                    #expect(abs((new.peakDb - old.peakDb) - want) < 0.05, "mono peak delta vs the rule's \(want): \(row)")
                    #expect(abs(new.rmsDb - old.rmsDb) < 0.05, "mono pooled RMS should not move: \(row)")
                }
            }
        }
        print("[PANFIX] R8 summary:\n" + rows.joined(separator: "\n"))
    }
}

// MARK: - R2: the five built-in templates that pan, in a new song

/// The fixed audition patterns of design §8.8, MIRRORED from `DemoRender`'s harness-only `Audition` (an executable
/// target, so it cannot be imported): the same roles, the same notes, so these numbers compare with TPL-4's.
private enum PanFixAudition {
    enum Role: String { case drums, bass, chords, pad, phrase }

    static func role(of spec: TemplateTrack) -> Role? {
        guard spec.kind == .instrument else { return nil }
        let label = (spec.key + " " + spec.name).lowercased()
        let instrument = spec.instrument ?? .default
        switch instrument.kind {
        case .drumSynth:
            return .drums
        case .soundBank:
            guard let bank = instrument.soundBank else { return .phrase }
            if bank.bankMSB == 120 { return .drums }
            if label.contains("rhythm") || label.contains("skank") { return .chords }
            switch bank.program {
            case 32...39: return .bass
            case 0...23: return .chords
            case 48...55, 88...95: return .pad
            default: return .phrase
            }
        case .polySynth:
            if label.contains("bass") { return .bass }
            if label.contains("pad") { return .pad }
            return .chords
        case .sampler, .audioUnit, .testTone:
            return .phrase
        }
    }

    static let roots = [36, 33, 29, 31]
    static let triads = [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
    static let tune: [(Double, Int, Double, Int)] = [
        (0, 64, 1, 100), (1, 67, 1, 80), (2, 72, 2, 110),
        (4, 69, 1.5, 90), (5.5, 67, 0.5, 70), (6, 64, 2, 100),
        (8, 65, 1, 85), (9, 69, 1, 75), (10, 72, 1, 105), (11, 69, 1, 80),
        (12, 67, 2, 110), (14, 62, 1, 75), (15, 59, 1, 90),
    ]

    static func notes(for role: Role, bars: Int) -> [MIDINote] {
        var notes: [MIDINote] = []
        for bar in 0..<bars {
            let o = Double(bar * 4)
            let chord = bar % 4
            switch role {
            case .drums:
                for beat in [0.0, 2.0] {
                    notes.append(MIDINote(pitch: 36, velocity: 110, startBeat: o + beat, lengthBeats: 0.25))
                }
                for beat in [1.0, 3.0] {
                    notes.append(MIDINote(pitch: 38, velocity: 105, startBeat: o + beat, lengthBeats: 0.25))
                }
                for step in 0..<7 {
                    notes.append(MIDINote(pitch: 42, velocity: step % 2 == 0 ? 90 : 75,
                                          startBeat: o + Double(step) * 0.5, lengthBeats: 0.25))
                }
                notes.append(MIDINote(pitch: 46, velocity: 85, startBeat: o + 3.5, lengthBeats: 0.5))
                if bar % 4 == 0 {
                    notes.append(MIDINote(pitch: 49, velocity: 100, startBeat: o, lengthBeats: 1))
                }
            case .bass:
                let root = roots[chord]
                notes.append(MIDINote(pitch: root, velocity: 100, startBeat: o, lengthBeats: 1.5))
                notes.append(MIDINote(pitch: root, velocity: 100, startBeat: o + 1.5, lengthBeats: 1.0))
                notes.append(MIDINote(pitch: root, velocity: 100, startBeat: o + 3, lengthBeats: 0.9))
            case .chords:
                for beat in [0.0, 2.0] {
                    for pitch in triads[chord] {
                        notes.append(MIDINote(pitch: pitch, velocity: 90, startBeat: o + beat, lengthBeats: 1.9))
                    }
                }
            case .pad:
                for pitch in triads[chord] {
                    notes.append(MIDINote(pitch: pitch, velocity: 85, startBeat: o, lengthBeats: 3.95))
                }
            case .phrase:
                guard bar % 4 == 0 else { continue }
                for (beat, pitch, length, velocity) in tune where Double(bar * 4) + beat < Double(bars * 4) {
                    notes.append(MIDINote(pitch: pitch, velocity: velocity, startBeat: o + beat,
                                          lengthBeats: length * 0.95))
                }
            }
        }
        return notes
    }
}

@MainActor
enum PanFixTemplates {
    /// The built-in templates whose tracks carry a knob pan (re-censused 2026-10-11 over the 10 template files:
    /// acoustic-folk ±0.4, jazz-combo −0.4/+0.4/+0.2, reggae-riddim ±0.4, rock-band ±0.6, soul-blues ±0.4).
    nonisolated static let panned = ["acoustic-folk", "jazz-combo", "reggae-riddim", "rock-band", "soul-blues"]

    struct Part {
        var key: String
        var pan: Double
        var rmsDb: Double
        var truePeakDbtp: Double?
    }

    struct Band {
        var id: String
        var storeLaw: PanLaw
        var bpm: Double
        var integratedLufs: Double?
        var truePeakDbtp: Double?
        var seconds: Double
        var parts: [Part]
        /// Every template track that got an audition clip, by key.
        var played: [String]
    }

    /// A built-in template applied as the picker applies it — in a NEW song (`newProject()`, the real birth path)
    /// or in a song on the original rule — at its song form's default tempo, with the §8.8 audition (`bars` bars) on
    /// every part, measured by the app's own meter (`measureLoudness`: BS.1770 integrated + 4x true peak) through a
    /// REAL engine.
    /// - `parts`: also render each PANNED part as a stem, as the positive control that it really sounded.
    /// - `silence`: the key of one part that gets NO audition clip — what a sound bank that failed to load sounds
    ///   like (a silent strip). nil in every real measurement; the loudness pin's sensitivity test and its plant.
    static func band(_ id: String, newSong: Bool, parts: Bool, bars: Int, silence: String? = nil,
                     dir: URL) async throws -> Band {
        let store = PanFixRig.store("PANFIX R2 \(id) \(newSong ? "new" : "saved")", in: dir)
        let engine = AudioEngine()
        store.engine = engine
        if newSong { try store.newProject(discardChanges: true) }
        guard let entry = BuiltInTemplateCatalog.load().templates.first(where: { $0.id == id }) else {
            throw PanFixError("no built-in template \(id)")
        }
        let bpm = entry.template.songForm.flatMap { SongSkeletonCatalog.genre(named: $0)?.defaultTempoBPM } ?? 120
        try store.setTempo(bpm)
        let result = try store.applyTemplate(entry.template)
        var pannedTracks: [(key: String, pan: Double, id: UUID)] = []
        var played: [String] = []
        for spec in entry.template.tracks {
            guard let trackID = result.tracks.first(where: { $0.key == spec.key })?.id,
                  let role = PanFixAudition.role(of: spec) else { continue }
            if spec.pan != 0 { pannedTracks.append((spec.key, spec.pan, trackID)) }
            if spec.key == silence { continue }
            _ = try store.addMIDIClip(toTrack: trackID, name: "Audition (\(role.rawValue))", atBeat: 0,
                                      lengthBeats: Double(bars * 4),
                                      notes: PanFixAudition.notes(for: role, bars: bars))
            played.append(spec.key)
        }
        let measured = try await store.measureLoudness()
        var partRows: [Part] = []
        if parts {
            let stemsDir = dir.appendingPathComponent("\(id)-\(newSong ? "new" : "saved")-stems", isDirectory: true)
            let stems = try await store.renderStems(toDirectory: stemsDir.path, trackIds: pannedTracks.map(\.id))
            for stem in stems.stems {
                guard let part = pannedTracks.first(where: { $0.id == stem.trackId }) else { continue }
                let channels = try TestSignals.readFile(URL(fileURLWithPath: stem.path))
                let all = channels.flatMap { $0 }
                let rms = (all.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(all.count, 1))).squareRoot()
                partRows.append(Part(key: part.key, pan: part.pan, rmsDb: 20 * log10(max(rms, 1e-12)),
                                     truePeakDbtp: stem.measurement.truePeakDbtp))
            }
        }
        withExtendedLifetime(engine) {}
        return Band(id: id, storeLaw: store.panLaw, bpm: bpm,
                    integratedLufs: measured.measurement.integratedLufs,
                    truePeakDbtp: measured.measurement.truePeakDbtp,
                    seconds: measured.durationSeconds, parts: partRows, played: played)
    }
}

@Suite("W9-PANFIX R2: the built-in templates that pan, in a new song", .serialized)
struct PanLawFixTemplateTests {
    /// The true-peak ceiling the template gate holds every built-in to (design §8.8 / TPL-4: ≤ −1 dBTP).
    static let ceilingDbtp = -1.0
    /// How far a pinned loudness may move. The renders are deterministic (two runs agreed to 12 digits), so this
    /// is room for a toolchain change, not for noise.
    static let lufsTolerance = 0.5
    /// The 8-bar table, measured 2026-10-11 by W9-PANFIX (two runs identical to 12 digits): integrated LUFS on
    /// the saved-song rule and on the new-song rule.
    static let pins8Bar: [String: (saved: Double, new: Double)] = [
        "acoustic-folk": (saved: -17.961, new: -17.317),
        "jazz-combo": (saved: -16.694, new: -15.823),
        "reggae-riddim": (saved: -18.712, new: -18.209),
        "rock-band": (saved: -16.702, new: -15.544),
        "soul-blues": (saved: -17.797, new: -17.412),
    ]

    /// The always-on pin's loudness: jazz-combo, 4 bars, a NEW song. Measured 2026-10-11 by W9-PANFIX, twice,
    /// identical to the last digit (-15.903641306975082 LUFS, -1.7649 dBTP).
    static let jazz4BarNewSongLufs = -15.904

    /// ⭐ The always-on pin: jazz-combo, the hottest panned template in a new song (-1.76 dBTP), 4 bars. It is on
    /// the new rule, stays under the template gate's ceiling, and its loudness is pinned ±0.5 LU — so a part that
    /// goes silent (a sound bank that failed to load) turns this RED instead of passing quieter: measured, one
    /// silent part moves the band 0.74 (drums) to 1.67 LU (trumpet). The five-template, 8-bar table is the
    /// env-gated test below.
    @Test("R2 pin: jazz-combo in a NEW song, 4 bars: new rule, <= -1 dBTP, loudness pinned +-0.5 LU")
    @MainActor
    func jazzComboInANewSong() async throws {
        let dir = try PanFixRig.scratch("r2-pin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let band = try await PanFixTemplates.band("jazz-combo", newSong: true, parts: false, bars: 4, silence: nil,
                                                  dir: dir)
        let peak = band.truePeakDbtp ?? -999
        let lufs = band.integratedLufs ?? -999
        print("[PANFIX] R2 pin jazz-combo 4 bars NEW: rule \(band.storeLaw.rawValue), \(lufs) LUFS "
              + "(pin \(Self.jazz4BarNewSongLufs)), \(peak) dBTP; parts \(band.played)")
        #expect(band.storeLaw == .equalPower, "a template in a new song must be on the new rule")
        #expect(band.played == ["drums", "bass", "piano", "trumpet", "guitar"], "control: every part was given notes")
        #expect(peak <= Self.ceilingDbtp, "\(peak) dBTP is over the template gate's ceiling")
        #expect(abs(lufs - Self.jazz4BarNewSongLufs) <= Self.lufsTolerance,
                "\(lufs) LUFS vs the pinned \(Self.jazz4BarNewSongLufs): a part went silent, or the voicing moved")
    }

    /// The full table (env-gated, `PANLAW_TEMPLATES=1`): every panned template, 8 bars, on BOTH rules — the rule,
    /// every panned part heard, ≤ −1 dBTP, and the loudness pinned to the table above ±0.5 LU. Then jazz-combo at
    /// 4 bars in a new song (the always-on pin's fixture) rendered TWICE (determinism), and once more with each
    /// part silenced in turn: how far one missing part moves the band (the pin's sensitivity). With
    /// `PANLAW_TEMPLATES_DIR` set it also writes `<dir>/r2.json`.
    @Test("R2 table: 5 panned templates x both rules, 8 bars: rule, parts heard, <= -1 dBTP, loudness pinned (PANLAW_TEMPLATES=1)",
          .enabled(if: ProcessInfo.processInfo.environment["PANLAW_TEMPLATES"] == "1"))
    @MainActor
    func measureBothRules() async throws {
        let dir = try PanFixRig.scratch("r2-measure")
        defer { try? FileManager.default.removeItem(at: dir) }
        var rows: [[String: Any]] = []
        for id in PanFixTemplates.panned {
            let pin = try #require(Self.pins8Bar[id], "no loudness pin for \(id)")
            for newSong in [false, true] {
                let started = Date()
                let band = try await PanFixTemplates.band(id, newSong: newSong, parts: true, bars: 8, dir: dir)
                let elapsed = Date().timeIntervalSince(started)
                let lufs = band.integratedLufs ?? -999
                let peak = band.truePeakDbtp ?? -999
                let want = newSong ? pin.new : pin.saved
                print("[PANFIX] R2 \(id) \(newSong ? "NEW" : "SAVED") (\(band.storeLaw.rawValue), \(band.bpm) BPM, "
                      + "\(band.seconds) s): \(lufs) LUFS (pin \(want)), \(peak) dBTP; "
                      + "parts \(band.parts.map { "\($0.key)@\($0.pan): \($0.rmsDb) dBFS rms, \($0.truePeakDbtp ?? -999) dBTP" }); "
                      + "wall \(elapsed) s")
                rows.append([
                    "template": id, "song": newSong ? "new" : "saved", "rule": band.storeLaw.rawValue,
                    "bpm": band.bpm, "seconds": band.seconds,
                    "integratedLufs": lufs, "truePeakDbtp": peak, "wallSeconds": elapsed,
                    "parts": band.parts.map { ["key": $0.key, "pan": $0.pan, "rmsDb": $0.rmsDb,
                                               "truePeakDbtp": $0.truePeakDbtp ?? -999] as [String: Any] },
                ])
                #expect(band.storeLaw == (newSong ? .equalPower : .balance))
                #expect(!band.parts.isEmpty && band.parts.allSatisfy { $0.rmsDb > -45 },
                        "\(id): a panned part did not sound")
                #expect(peak <= Self.ceilingDbtp, "\(id) \(newSong ? "new" : "saved"): \(peak) dBTP")
                #expect(abs(lufs - want) <= Self.lufsTolerance,
                        "\(id) \(newSong ? "new" : "saved"): \(lufs) LUFS vs the pinned \(want)")
            }
        }

        // The always-on pin's fixture: jazz-combo, 4 bars, a new song — twice, then with each part silenced.
        let first = try await PanFixTemplates.band("jazz-combo", newSong: true, parts: false, bars: 4, dir: dir)
        let second = try await PanFixTemplates.band("jazz-combo", newSong: true, parts: false, bars: 4, dir: dir)
        let base = first.integratedLufs ?? -999
        print("[PANFIX] R2 jazz-combo 4 bars NEW, run 1: \(base) LUFS, \(first.truePeakDbtp ?? -999) dBTP; "
              + "run 2: \(second.integratedLufs ?? -999) LUFS, \(second.truePeakDbtp ?? -999) dBTP; parts \(first.played)")
        #expect(first.integratedLufs == second.integratedLufs && first.truePeakDbtp == second.truePeakDbtp,
                "the 4-bar jazz-combo render is not deterministic")
        #expect(abs(base - Self.jazz4BarNewSongLufs) <= Self.lufsTolerance, "the always-on pin no longer matches")
        var sweep: [[String: Any]] = []
        for key in first.played {
            let silenced = try await PanFixTemplates.band("jazz-combo", newSong: true, parts: false, bars: 4,
                                                          silence: key, dir: dir)
            let lufs = silenced.integratedLufs ?? -999
            print("[PANFIX] R2 jazz-combo 4 bars NEW with \(key) silent: \(lufs) LUFS (\(lufs - base) LU), "
                  + "\(silenced.truePeakDbtp ?? -999) dBTP; outside +-\(Self.lufsTolerance) LU: "
                  + "\(abs(lufs - base) > Self.lufsTolerance)")
            sweep.append(["silenced": key, "integratedLufs": lufs, "deltaLu": lufs - base,
                          "truePeakDbtp": silenced.truePeakDbtp ?? -999])
            #expect(abs(lufs - base) > Self.lufsTolerance,
                    "the always-on pin cannot see \(key) go silent (\(lufs - base) LU)")
        }
        if let out = ProcessInfo.processInfo.environment["PANLAW_TEMPLATES_DIR"], !out.isEmpty {
            let report: [String: Any] = ["rows": rows, "jazz4Bar": ["run1": base, "run2": second.integratedLufs ?? -999,
                                                                    "truePeakDbtp": first.truePeakDbtp ?? -999],
                                         "jazz4BarSilenced": sweep]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: out), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("r2.json"))
        }
    }
}


// MARK: - W9-PFRT P2: no DAWCore offline render can drop the song's pan rule (source census)

/// W9-PFRT P2. `AudioEngine`'s rule-less render overloads render the ORIGINAL rule (`.balance`). A DAWCore render that
/// reached one would export a NEW song on the old rule, silently: the defect class W9-PLRT R1 closed. The R1 spy gate
/// (`everyStoreRenderCarriesTheRule`) covers only the operations it drives; this census covers every call in the
/// module's source, so a future render (freeze, render-selection, an analysis pass) cannot land on the old seam.
///
/// THE METHOD (the `NaturalTuningHandEditCensusTests` precedent: a source scan, comments cut, with a self-test):
///  1. Every `.swift` file under `Sources/DAWCore` is read, and each line's comment is cut (`code(_:)`).
///  2. Every `renderOffline(` / `renderMixdown(` token is classified. After `func` it is a DECLARATION (skipped);
///     after a `.` it is a call on a RECEIVER (`engine.`, `engine?.`, …); otherwise it is BARE.
///  3. A receiver call's argument list is paren-matched from its `(` to the `)` that closes it (every site is
///     multi-line), and it must name `panLaw:`.
///  4. BARE calls are the protocol extension's own forwarding chain: the refusing defaults in `EngineProtocol.swift`,
///     which ARE the conformer-side gate (`OfflinePanLawSeam`). They are counted; a bare call in any other file is red
///     until it is classified here.
/// Positive control: the carrying set holds every store session render and the two synthetic renders P2 moved, by
/// file. Scanner self-test: `scannerClassifiesAFixture`. Byte leg: `movedCallIsByteIdentical`.
@Suite("W9-PFRT P2: no DAWCore offline render can drop the song's pan rule (source census)")
struct PanLawRenderCensusTests {
    struct Call: CustomStringConvertible {
        let file: String
        let line: Int
        let callee: String
        let carriesRule: Bool
        var description: String { "\(file):\(line) \(callee)(\(carriesRule ? "panLaw:" : "NO panLaw:"))" }
    }

    struct Scan {
        var files = 0
        /// Calls on a receiver: each must carry the rule.
        var calls: [Call] = []
        /// Receiver-less calls (the protocol's forwarding chain).
        var bare: [Call] = []
        /// Calls whose argument list never closed: a scanner fault, never a pass.
        var unclosed: [String] = []
    }

    /// The pan-carrying calls the census must SEE (the positive control), by file under `Sources/DAWCore`: every
    /// store session render (W9-PLRT R1) and the two synthetic renders W9-PFRT P2 moved.
    static let knownCarrying: [String: Int] = [
        "ProjectStore+Render.swift": 5,                 // measureLoudness, renderBounce, the three stem passes
        "ProjectStore+Bounce.swift": 1,                 // bounce in place
        "ProjectStore+TimbreLiveness.swift": 1,         // the instrument liveness probe
        "ProjectStore.swift": 1,                        // renderMixdown
        "ProjectStore+ClipFix.swift": 1,                // W9-PFRT P2: the AI-fix region bounce
        "ProjectStore+ClipVoiceConversion.swift": 1,    // W9-PFRT P2: the voice-conversion source
    ]

    /// The repo root, from this file's path (the `repoSource` idiom).
    static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var hops = 0
        while hops < 6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir = dir.deletingLastPathComponent()
            hops += 1
        }
        return nil
    }

    /// A line with its comment cut. A line that starts `//` is empty, and a trailing `//` comment is dropped, so a doc
    /// that NAMES a call (or `panLaw:`) is not one.
    static func code(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("//") { return "" }
        if let comment = line.range(of: "//") { return String(line[..<comment.lowerBound]) }
        return line
    }

    /// Classifies every render call in one file's text into `result`.
    static func scan(_ text: String, file: String, into result: inout Scan) throws {
        let source = text.components(separatedBy: "\n").map(code).joined(separator: "\n") as NSString
        let token = try NSRegularExpression(pattern: #"(\bfunc\s+)?(\.)?\b(renderOffline|renderMixdown)\s*\("#)
        let open = UInt16(UInt8(ascii: "(")), close = UInt16(UInt8(ascii: ")"))
        let newline = UInt16(UInt8(ascii: "\n"))
        for match in token.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            if match.range(at: 1).location != NSNotFound { continue }       // a declaration
            let callee = source.substring(with: match.range(at: 3))
            var line = 1
            var index = 0
            while index < match.range.location {
                if source.character(at: index) == newline { line += 1 }
                index += 1
            }
            // Paren-match from the call's `(`, the match's last character.
            let start = match.range.location + match.range.length
            var depth = 0
            var cursor = start - 1
            var end: Int?
            while cursor < source.length {
                let unit = source.character(at: cursor)
                if unit == open { depth += 1 }
                if unit == close {
                    depth -= 1
                    if depth == 0 { end = cursor; break }
                }
                cursor += 1
            }
            guard let end else {
                result.unclosed.append("\(file):\(line) \(callee)")
                continue
            }
            let arguments = source.substring(with: NSRange(location: start, length: end - start))
            let call = Call(file: file, line: line, callee: callee, carriesRule: arguments.contains("panLaw:"))
            if match.range(at: 2).location != NSNotFound {
                result.calls.append(call)
            } else {
                result.bare.append(call)
            }
        }
    }

    @Test("P2: the census scanner classifies a fixture exactly: declaration, rule-less, carrying, bare, comment-only panLaw:")
    func scannerClassifiesAFixture() throws {
        let fixture = """
            public func renderOffline(tracks: [Track]) async throws {}
            let a = try await engine.renderOffline(
                tracks: t, tempoMap: m, // panLaw: named only in a comment
                masterVolume: 1)
            let b = try await engine?.renderMixdown(
                tracks: t, meterMap: mm, panLaw: law,
                masterVolume: gain(1, (2)), to: url)
            return try await renderOffline(tracks: t)
            """
        var result = Scan()
        try Self.scan(fixture, file: "Fixture.swift", into: &result)
        #expect(result.calls.map(\.line) == [2, 5], "\(result.calls)")
        #expect(result.calls.map(\.callee) == ["renderOffline", "renderMixdown"])
        #expect(result.calls.map(\.carriesRule) == [false, true],
                "a comment that names panLaw: must not count, and a nested paren must not end the list early")
        #expect(result.bare.map(\.line) == [8], "\(result.bare)")
        #expect(result.unclosed.isEmpty)
    }

    @Test("P2: every offline render called on a receiver in Sources/DAWCore names panLaw: (the census sees the carrying sites)")
    func noRuleLessRenderInDAWCore() throws {
        let root = try #require(Self.repoRoot(), "could not locate the repo from \(#filePath)")
        let core = root.appendingPathComponent("Sources/DAWCore", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
        var result = Scan()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.files += 1
            let relative = url.path.components(separatedBy: "/Sources/DAWCore/").last ?? url.lastPathComponent
            try Self.scan(String(contentsOf: url, encoding: .utf8), file: relative, into: &result)
        }
        let ruleLess = result.calls.filter { !$0.carriesRule }
        let carrying = result.calls.filter(\.carriesRule)
        print("[PFRT P2] census of Sources/DAWCore: \(result.files) files; \(carrying.count) pan-carrying, "
              + "\(ruleLess.count) rule-less, \(result.bare.count) bare (the protocol's forwarding chain), "
              + "\(result.unclosed.count) unclosed")
        for call in result.calls + result.bare { print("[PFRT P2]   \(call)") }
        #expect(result.files >= 100, "the scan did not see the module (\(result.files) files)")
        #expect(result.unclosed.isEmpty, "argument lists that never closed: \(result.unclosed)")
        #expect(ruleLess.isEmpty, """
            DAWCore renders that cannot carry the song's pan rule: \(ruleLess). A rule-less overload renders the \
            ORIGINAL rule (.balance), so a new song would export on the old rule. Use the pan-carrying overload with \
            the rule captured beside the tracks (or `.balance` stated, for a centred synthetic track).
            """)
        // Positive control: the census SEES the pan-carrying calls, including the two P2 moved.
        var found: [String: Int] = [:]
        for call in carrying { found[call.file, default: 0] += 1 }
        for (file, count) in Self.knownCarrying.sorted(by: { $0.key < $1.key }) {
            #expect((found[file] ?? 0) >= count,
                    "control: \(file) carries \(count) pan-carrying call(s); the census found \(found[file] ?? 0)")
        }
        #expect(carrying.count >= Self.knownCarrying.values.reduce(0, +))
        // Bare calls: the protocol's forwarding chain, and nowhere else.
        let stray = result.bare.filter { $0.file != "EngineProtocol.swift" }
        #expect(stray.isEmpty, "a receiver-less render outside the protocol's forwarding chain: \(stray); classify it")
        #expect(!result.bare.isEmpty, "control: the protocol's forwarding chain is invisible to the scan")
    }

    /// The move's byte claim, MEASURED. On the real engine, through the existential the store calls, the pan-carrying
    /// call with the stated inputs renders the same bytes as the rule-less call it replaced, for a centred synthetic
    /// track built the way both call sites build theirs. And the rule cannot move it (`.equalPower` gives the same
    /// bytes), which is why `.balance` is the honest statement for a synthetic render.
    @Test("P2: the moved call renders exactly the bytes of the rule-less call it replaced (real engine, centred synthetic track)")
    @MainActor
    func movedCallIsByteIdentical() async throws {
        let (mono, stereo) = try PanLawRig.sources()
        let engine = AudioEngine()
        let seam: any AudioEngineControlling = engine
        for (label, url) in [("mono", mono), ("stereo", stereo)] {
            let synthetic = Track(name: "AI Fix Bounce", kind: .audio,
                                  clips: [PanLawGate.clip("pfrt.p2.\(label)", url)])
            let replaced = try await seam.renderOffline(
                tracks: [synthetic], tempoMap: PanLawRig.tempoMap, masterVolume: 1,
                masterEffects: [], masterAutomation: [],
                fromBeat: 0, durationSeconds: PanLawRig.seconds, forcedCompensationTargets: nil).channelData
            func moved(_ law: PanLaw) async throws -> [[Float]] {
                try await seam.renderOffline(
                    tracks: [synthetic], tempoMap: PanLawRig.tempoMap,
                    meterMap: MeterMap(constant: TimeSignature()), panLaw: law,
                    masterVolume: 1, masterEffects: [], masterAutomation: [],
                    masterModulationSources: [], masterModulationRoutes: [],
                    fromBeat: 0, durationSeconds: PanLawRig.seconds, forcedCompensationTargets: nil).channelData
            }
            let balance = try await moved(.balance)
            let equalPower = try await moved(.equalPower)
            let moveDiff = PanLawRig.differing(replaced, balance)
            let ruleDiff = PanLawRig.differing(balance, equalPower)
            print("[PFRT P2] \(label) synthetic render: replaced vs moved differing = \(moveDiff); "
                  + "moved .balance vs .equalPower differing = \(ruleDiff); frames \(balance.first?.count ?? 0)")
            #expect(moveDiff == 0, "\(label): the moved call does not render the bytes of the call it replaced")
            #expect(ruleDiff == 0, "\(label): the rule moved a centred synthetic render")
            #expect(TestSignals.peak(balance[0] + balance[1], in: 0..<96_000) > 0.05, "\(label): silent render")
        }
        withExtendedLifetime(engine) {}
    }
}

// MARK: - W9-PFRT P3a: the applyGainRamp `while` rewrite is bit-identical to the `for` loops it replaced

/// W9-PFRT P3a. W9-PANFIX rewrote `AutomationRenderer.applyGainRamp`'s `for … in` loops as `while` loops (the render
/// path's no-Range law). The saved-song byte gate has no volume lane, so this compares the rewrite against the ORIGINAL
/// body, kept here verbatim as the reference, on seeded random data. Cases: both arms (ramp, flat), the unity skip, an
/// odd quantum, a one-frame quantum, a mono buffer, a buffer shorter than the quantum, and quanta straddling
/// breakpoints and a held segment. `applyGainRamp` is private, so the subject is driven through `apply` on an OFFLINE,
/// volume-only schedule (no pan lane, no route, knob 0: the pan stage returns before touching audio). The reference is
/// handed exactly the values `apply` hands it: `AutomationSchedule.value` at the quantum's two ends, on the same
/// breakpoints, with `step` over `frameCount`.
@Suite("W9-PFRT P3a: applyGainRamp's while loops are bit-identical to the original for loops")
struct PanLawFixGainRampIdentityTests {
    /// The ORIGINAL `applyGainRamp` body, VERBATIM: `git show e7e4d24:Sources/DAWEngine/Automation/AutomationRenderer.swift`,
    /// lines 427-445. Its Range loops are the POINT (this is the reference the rewrite must match); test code, never
    /// the render path.
    static func reference(gainStart: Double, gainEnd: Double,
                          buffers: UnsafeMutableAudioBufferListPointer,
                          frameCount: Int) {
        guard gainStart.isFinite, gainEnd.isFinite else { return }
        if gainStart == 1.0, gainEnd == 1.0 { return }  // whole-quantum unity: skip
        let step = (gainEnd - gainStart) / Double(frameCount)
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
            if gainStart == gainEnd {
                let gain = Float(gainStart)
                for frame in 0..<frames { data[frame] *= gain }
            } else {
                for frame in 0..<frames {
                    data[frame] *= Float(gainStart + step * Double(frame))
                }
            }
        }
    }

    /// SplitMix64: a fixed seed reproduces a red exactly.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Uniform samples in [-1, 1), with about one in 17 replaced by a value a gain must treat identically on both
    /// paths: signed zeros, subnormals, the extremes, ±1.
    static func fill(_ buffer: AVAudioPCMBuffer, seed: UInt64) throws {
        let data = try #require(buffer.floatChannelData)
        // Subnormals by bit pattern: a decimal literal below Float's normal range warns as it rounds.
        let specials: [Float] = [0, -0.0, Float(bitPattern: 0x0001_16C2), -Float(bitPattern: 0x0020_AAAA),
                                 .leastNonzeroMagnitude, 3.0e38, -1e30, 1, -1]
        var rng = SplitMix64(state: seed)
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<Int(buffer.frameCapacity) {
                let r = rng.next()
                data[channel][index] = r % 17 == 0
                    ? specials[Int((r >> 8) % UInt64(specials.count))]
                    : Float(Double(r >> 11) / Double(UInt64(1) << 53) * 2 - 1)
            }
        }
    }

    struct Case {
        let name: String
        let points: [AutomationBreakpoint]
        let frames: Int
        let quanta: Int
        let channels: Int
        /// The buffer's frameLength (its `mDataByteSize`); shorter than `frames` exercises the `min` guard.
        let length: Int
    }

    static func point(_ t: Int64, _ v: Double, hold: Bool = false) -> AutomationBreakpoint {
        AutomationBreakpoint(sampleTime: t, value: v, holdsSegment: hold)
    }

    static let cases: [Case] = [
        Case(name: "ramp 0.2->0.9", points: [point(0, 0.2), point(96_000, 0.9)],
             frames: 512, quanta: 8, channels: 2, length: 512),
        Case(name: "flat 0.5", points: [point(0, 0.5), point(96_000, 0.5)],
             frames: 512, quanta: 4, channels: 2, length: 512),
        Case(name: "unity 1.0", points: [point(0, 1), point(96_000, 1)],
             frames: 512, quanta: 2, channels: 2, length: 512),
        Case(name: "straddles + hold, odd quantum, mono",
             points: [point(0, 0), point(700, 1.6, hold: true), point(1_500, 0.3), point(2_600, 1)],
             frames: 509, quanta: 7, channels: 1, length: 509),
        Case(name: "buffer shorter than the quantum", points: [point(0, 1.8), point(4_096, 0.1)],
             frames: 512, quanta: 4, channels: 2, length: 300),
        Case(name: "one-frame quanta", points: [point(0, 0.25), point(3, 1.75)],
             frames: 1, quanta: 6, channels: 2, length: 1),
    ]

    @Test("P3a: apply's volume stage (while loops) matches the original for-loop body bit for bit, every arm")
    @MainActor
    func whileRewriteIsBitIdentical() throws {
        var arms = (ramp: 0, flat: 0, unity: 0)
        var moved = 0
        for (caseIndex, spec) in Self.cases.enumerated() {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                                    channels: AVAudioChannelCount(spec.channels)))
            let schedule = AutomationSchedule(generation: 1, mode: .offline, sampleRate: 48_000,
                                              volumePoints: spec.points, panPoints: [])
            let renderer = AutomationRenderer()
            renderer.publish(schedule)
            var cursor = -1
            var differing = 0
            for quantum in 0..<spec.quanta {
                let seed = UInt64(caseIndex * 1_000 + quantum + 1)
                func buffer() throws -> AVAudioPCMBuffer {
                    let made = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                             frameCapacity: AVAudioFrameCount(spec.frames)))
                    made.frameLength = AVAudioFrameCount(spec.length)
                    try Self.fill(made, seed: seed)
                    return made
                }
                let subject = try buffer()
                let expected = try buffer()
                let input = try buffer()
                var stamp = AudioTimeStamp()
                stamp.mSampleTime = Double(quantum * spec.frames)
                stamp.mFlags = .sampleTimeValid
                renderer.apply(bufferList: subject.mutableAudioBufferList, frameCount: spec.frames, timestamp: &stamp)
                let renderStart = Int64(quantum * spec.frames)
                let gainStart = AutomationSchedule.value(at: renderStart, points: schedule.volumePoints,
                                                         cursor: &cursor)
                let gainEnd = AutomationSchedule.value(at: renderStart + Int64(spec.frames),
                                                       points: schedule.volumePoints, cursor: &cursor)
                Self.reference(gainStart: gainStart, gainEnd: gainEnd,
                               buffers: UnsafeMutableAudioBufferListPointer(expected.mutableAudioBufferList),
                               frameCount: spec.frames)
                if gainStart == 1, gainEnd == 1 { arms.unity += 1 } else if gainStart == gainEnd { arms.flat += 1 }
                else { arms.ramp += 1 }
                let s = try #require(subject.floatChannelData)
                let e = try #require(expected.floatChannelData)
                let i = try #require(input.floatChannelData)
                for channel in 0..<spec.channels {
                    for index in 0..<spec.frames {
                        if s[channel][index].bitPattern != e[channel][index].bitPattern { differing += 1 }
                        if s[channel][index].bitPattern != i[channel][index].bitPattern { moved += 1 }
                    }
                }
            }
            print("[PFRT P3a] \(spec.name): \(spec.quanta) quanta x \(spec.frames) frames x \(spec.channels) ch, "
                  + "differing from the for-loop reference = \(differing)")
            #expect(differing == 0, "\(spec.name): the while rewrite differs from the original for loops")
            withExtendedLifetime(schedule) {}
        }
        print("[PFRT P3a] arms reached: ramp \(arms.ramp), flat \(arms.flat), unity \(arms.unity); "
              + "samples the stage changed \(moved)")
        #expect(arms.ramp > 0 && arms.flat > 0 && arms.unity > 0, "control: every arm ran (\(arms))")
        #expect(moved > 0, "control: the stage changed nothing, so the identity proves nothing")
    }
}

// MARK: - W9-PFRT P4: the store's protocol call reaches AudioEngine's pan-carrying render

/// W9-PFRT P4. `engineRendersTheArgumentNotTheCache` calls the CONCRETE engine (static dispatch), so it cannot see a
/// mis-bound witness: the store's `any AudioEngineControlling` call landing on the protocol's REFUSING default instead
/// of `AudioEngine`'s implementation (a label drift would do it, and it would still compile). This goes through the
/// existential, as every store render does, on the one render the default would refuse: a new song with a panned knob.
@Suite("W9-PFRT P4: the store's protocol call reaches AudioEngine's pan-carrying render, not the refusing default")
struct PanLawFixWitnessTests {
    @Test("P4: through any AudioEngineControlling, a new song with a panned knob is SERVED by AudioEngine's own render")
    @MainActor
    func protocolCallReachesTheEngine() async throws {
        let tracks = try PanLawRig.strip("mono", knob: 0.4, lane: nil)
        #expect(OfflinePanLawSeam.lawChangesRender(.equalPower, tracks: tracks),
                "control: the protocol's default would REFUSE this render, so serving it proves the witness")
        let engine = AudioEngine()
        let seam: any AudioEngineControlling = engine
        func render(_ law: PanLaw) async throws -> [[Float]] {
            try await seam.renderOffline(
                tracks: tracks, tempoMap: PanLawRig.tempoMap, meterMap: MeterMap(constant: TimeSignature()),
                panLaw: law, masterVolume: 1, masterEffects: [], masterAutomation: [],
                masterModulationSources: [], masterModulationRoutes: [],
                fromBeat: 0, durationSeconds: PanLawRig.seconds, forcedCompensationTargets: nil).channelData
        }
        let viaProtocol = try await render(.equalPower)
        let direct = try await engine.renderOffline(
            tracks: tracks, tempoMap: PanLawRig.tempoMap, meterMap: MeterMap(constant: TimeSignature()),
            panLaw: .equalPower, masterVolume: 1, masterEffects: [], masterAutomation: [],
            masterModulationSources: [], masterModulationRoutes: [],
            fromBeat: 0, durationSeconds: PanLawRig.seconds, forcedCompensationTargets: nil).channelData
        let saved = try await render(.balance)
        let same = PanLawRig.differing(viaProtocol, direct)
        let axis = PanLawRig.differing(viaProtocol, saved)
        print("[PFRT P4] existential .equalPower vs concrete .equalPower differing = \(same); "
              + "existential .equalPower vs .balance differing = \(axis)")
        #expect(same == 0, "the protocol call landed on an implementation other than AudioEngine's pan-carrying render")
        #expect(axis > 0, "control: the two rules render this strip differently")
        #expect(TestSignals.peak(viaProtocol[0] + viaProtocol[1], in: 0..<96_000) > 0.05, "silent render")

        // The store: `store.engine` IS the existential. AudioEngine serves a new song with this knob; the same store
        // call on an engine that has only the older requirements is refused, so "served" discriminates.
        let dir = try PanFixRig.scratch("p4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PanFixRig.store("PANFIX P4", in: dir, tracks: tracks, panLaw: .equalPower)
        store.engine = engine
        let served = await PanFixRig.outcome { _ = try await store.measureLoudness(durationSeconds: 1) }
        let legacyStore = PanFixRig.store("PANFIX P4 legacy", in: dir, tracks: tracks, panLaw: .equalPower)
        let legacy = PanLawLegacyOnlyEngine()
        legacyStore.engine = legacy
        let refused = await PanFixRig.outcome { _ = try await legacyStore.measureLoudness(durationSeconds: 1) }
        print("[PFRT P4] store (new song, knob 0.4): AudioEngine \(served); legacy-only engine \(refused)")
        #expect(served == "served", "the store's protocol call did not reach AudioEngine's pan-carrying render")
        #expect(refused == "engineUnavailable", "control: the refusing default no longer refuses this render")
        withExtendedLifetime((engine, legacy)) {}
    }
}
