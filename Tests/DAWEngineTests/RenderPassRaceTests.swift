import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-render-pass-race (W9-RACE). A multi-pass export waits between its passes (the compensation probe, each render,
// each loudness measure), and the main actor is free while it waits, so a user or a second agent can press New or
// Open in the middle of one. Two rules follow:
//
//  (a) `renderStems` finishes as the song that was open when Export was pressed. Every pass (each stem, "00 Mixdown"
//      and the mastered sibling) renders that song's tempo map, meter map, pan rule and master volume, and the
//      mastered sibling its master chain, master volume lane and master modulation. The reply's `masterChain` honesty
//      field describes that song too.
//  (b) `bounceTrackInPlace` never lands its track in another song. When the song changed while it rendered, it writes
//      no file, adds nothing, and refuses with a sentence that says nothing was added.
//
// Song A differs from a fresh song AND from saved song B on every input above, so a pass that re-reads any of them
// after an await is named. A NO-switch control runs beside every switch, so the expectations themselves are checked.
// The byte gate (RACE_GATE_DIR, RACE_PHASE) renders a NO-switch export through a real `AudioEngine`, twice, and
// compares it with the capture taken before the change.
//
// Nonisolated suite over `@MainActor` helpers and `@MainActor` test functions (no new `@MainActor` suite), the
// `PanLawFixTests` pattern.

/// Every song-level input one offline render was handed (the track list is per pass, so it is not part of it).
struct RenderPassRaceInputs: Equatable, CustomStringConvertible {
    var tempoMap: TempoMap
    var meterMap: MeterMap
    var panLaw: PanLaw
    var masterVolume: Double
    var masterEffects: [EffectDescriptor]
    var masterAutomation: [AutomationLane]
    var masterModulationSources: [ModulationSource]
    var masterModulationRoutes: [ModulationRoute]

    var description: String {
        "tempo \(tempoMap.segments.map(\.bpm)) meter \(meterMap.changes.map { "\($0.beatsPerBar)/\($0.beatUnit)" }) "
            + "rule \(panLaw.rawValue) master \(masterVolume) chain \(masterEffects.map(\.kind.rawValue)) "
            + "lanes \(masterAutomation.count) mod \(masterModulationSources.count)/\(masterModulationRoutes.count)"
    }
}

/// A double that records every pan-carrying render's song-level inputs, counts file writes, and can press New/Open
/// from inside the compensation probe or the first render. An older render requirement counts as a LEGACY call.
@MainActor
final class RenderPassRaceSpy: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    private(set) var passes: [RenderPassRaceInputs] = []
    private(set) var legacyCalls = 0
    private(set) var writes = 0
    private(set) var hooksRun = 0
    /// Runs ONCE, inside the compensation probe, then clears.
    var duringPlan: (@MainActor () -> Void)?
    /// Runs ONCE, inside the first pan-carrying render, then clears.
    var duringFirstRender: (@MainActor () -> Void)?

    private static let audio: RenderedAudio = {
        let tone = (0..<48_000).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        return RenderedAudio(sampleRate: 48_000, channelData: [tone, tone])
    }()
    /// One second, so a landed clip's length in beats is the tempo in beats per second.
    private static let info = AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)

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

    func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int] {
        if let hook = duringPlan { duringPlan = nil; hooksRun += 1; hook() }
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
        passes.append(RenderPassRaceInputs(
            tempoMap: tempoMap, meterMap: meterMap, panLaw: panLaw, masterVolume: masterVolume,
            masterEffects: masterEffects, masterAutomation: masterAutomation,
            masterModulationSources: masterModulationSources, masterModulationRoutes: masterModulationRoutes))
        if let hook = duringFirstRender { duringFirstRender = nil; hooksRun += 1; hook() }
        return Self.audio
    }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap, panLaw: PanLaw,
                       masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL, format: DeliveryFormat) async throws -> AudioFileInfo {
        passes.append(RenderPassRaceInputs(
            tempoMap: tempoMap, meterMap: meterMap, panLaw: panLaw, masterVolume: masterVolume,
            masterEffects: masterEffects, masterAutomation: masterAutomation,
            masterModulationSources: masterModulationSources, masterModulationRoutes: masterModulationRoutes))
        if let hook = duringFirstRender { duringFirstRender = nil; hooksRun += 1; hook() }
        return Self.info
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        writes += 1
        return Self.info
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL, format: DeliveryFormat) throws -> AudioFileInfo {
        writes += 1
        return Self.info
    }
}

@MainActor
enum RenderPassRaceRig {
    /// What lands in the middle of the export.
    enum Change: String, CaseIterable {
        case none, newSong, openSong
    }

    /// Where it lands: inside the compensation probe (before any pass), or inside the first render (between passes).
    enum Moment: String, CaseIterable {
        case duringPlan, duringFirstRender
    }

    static let tempoA = TempoMap(constantBPM: 92)
    static let meterA = MeterMap(constant: TimeSignature(beatsPerBar: 3, beatUnit: 4))
    static let tempoB = TempoMap(constantBPM: 140)
    static let meterB = MeterMap(constant: TimeSignature(beatsPerBar: 7, beatUnit: 8))

    static func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-race-\(label)-\(UUID().uuidString)", isDirectory: true)
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

    /// Two audio tracks, panned (the spy renders nothing, so the clips need no media).
    static func pannedPair() -> [Track] {
        [Track(name: "Left Gtr", kind: .audio, pan: -0.5,
               clips: [Clip(name: "l", startBeat: 0, lengthBeats: 4)]),
         Track(name: "Right Gtr", kind: .audio, pan: 0.5,
               clips: [Clip(name: "r", startBeat: 0, lengthBeats: 4)])]
    }

    /// Two polySynth tracks, panned, with notes: real audio through a real engine, no media files.
    static func synthPair() -> [Track] {
        func notes(_ root: Int) -> [MIDINote] {
            (0..<4).map { MIDINote(pitch: root + 4 * $0, velocity: 100, startBeat: Double($0), lengthBeats: 0.75) }
        }
        return [Track(name: "Lead", kind: .instrument, pan: -0.4,
                      clips: [Clip(name: "lead", startBeat: 0, lengthBeats: 4, notes: notes(60))],
                      instrument: InstrumentDescriptor(kind: .polySynth)),
                Track(name: "Pad", kind: .instrument, pan: 0.6,
                      clips: [Clip(name: "pad", startBeat: 0, lengthBeats: 4, notes: notes(48))],
                      instrument: InstrumentDescriptor(kind: .polySynth))]
    }

    /// Song A: a saved song that differs from a fresh song AND from song B on every song-level render input.
    static func songA(in dir: URL, tracks: [Track]) throws -> ProjectStore {
        let store = store("RACE song A", in: dir, tracks: tracks)
        try store.setTempoMap(tempoA, meterMap: meterA)
        store.setMasterVolume(0.8)
        try store.addMasterEffect(kind: .limiter)
        let lane = try store.addMasterAutomationLane(target: .volume)
        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [AutomationPoint(beat: 0, value: 0.9),
                                                                          AutomationPoint(beat: 4, value: 0.6)])
        let lfo = try store.addModulationSource(on: .master, kind: .lfo).source
        _ = try store.addModulationRoute(on: .master, sourceID: lfo.id, target: .volume, depth: -0.3)
        return store
    }

    /// Song B, saved to disk for the Open case: another tempo, meter, rule, master volume and master chain.
    static func saveSongB(in dir: URL) throws -> URL {
        let store = store("RACE song B", in: dir, panLaw: .equalPower)
        try store.setTempoMap(tempoB, meterMap: meterB)
        store.setMasterVolume(1.3)
        try store.addMasterEffect(kind: .compressor)
        let url = dir.appendingPathComponent("RACE song B.dawproj")
        _ = try store.saveProject(to: url.path)
        return url
    }

    /// The inputs `store` hands a render NOW: STEM class (no master chain, lane or modulation) or MASTERED class.
    static func inputs(of store: ProjectStore, mastered: Bool) -> RenderPassRaceInputs {
        RenderPassRaceInputs(
            tempoMap: store.transport.tempoMap, meterMap: store.transport.meterMap, panLaw: store.panLaw,
            masterVolume: store.masterVolume,
            masterEffects: mastered ? store.masterEffects : [],
            masterAutomation: mastered ? store.masterAutomation : [],
            masterModulationSources: mastered ? store.masterModulationSources : [],
            masterModulationRoutes: mastered ? store.masterModulationRoutes : [])
    }

    /// Arms `change` at `moment` on `spy`. The hook records the store's undo/dirty state right after the switch.
    static func arm(_ change: Change, at moment: Moment, spy: RenderPassRaceSpy, store: ProjectStore,
                    songB: URL, afterSwitch: @escaping @MainActor (Bool, Bool) -> Void) {
        let hook: @MainActor () -> Void
        switch change {
        case .none:
            return
        case .newSong:
            hook = {
                try? store.newProject(discardChanges: true)
                afterSwitch(store.isDirty, store.canUndo)
            }
        case .openSong:
            hook = {
                _ = try? store.openProject(at: songB.path, discardChanges: true)
                afterSwitch(store.isDirty, store.canUndo)
            }
        }
        switch moment {
        case .duringPlan: spy.duringPlan = hook
        case .duringFirstRender: spy.duringFirstRender = hook
        }
    }
}

@Suite("m39-render-pass-race: a multi-pass export finishes as the song it started in; a bounce never lands in another song",
       .serialized)
struct RenderPassRaceTests {

    /// (a) THE STEMS GATE. Song A exports 2 stems + "00 Mixdown" + the mastered sibling. New (or Open of song B) lands
    /// inside the probe or inside the first render. Every pass must still render song A's inputs.
    @Test("Stems: New or Open mid-export - every pass renders the original song's tempo, meter, rule, master volume and master chain")
    @MainActor
    func stemsFinishAsTheSongTheyStartedIn() async throws {
        let dir = try RenderPassRaceRig.scratch("stems")
        defer { try? FileManager.default.removeItem(at: dir) }
        let songB = try RenderPassRaceRig.saveSongB(in: dir)
        for change in RenderPassRaceRig.Change.allCases {
            for moment in RenderPassRaceRig.Moment.allCases {
                let label = "\(change.rawValue)@\(moment.rawValue)"
                let store = try RenderPassRaceRig.songA(in: dir, tracks: RenderPassRaceRig.pannedPair())
                let spy = RenderPassRaceSpy()
                store.engine = spy
                let stemClass = RenderPassRaceRig.inputs(of: store, mastered: false)
                let masteredClass = RenderPassRaceRig.inputs(of: store, mastered: true)
                // Controls: song A really carries every input the passes must keep.
                #expect(stemClass.tempoMap == RenderPassRaceRig.tempoA, "\(label) control: \(stemClass)")
                #expect(stemClass.meterMap == RenderPassRaceRig.meterA, "\(label) control: \(stemClass)")
                #expect(stemClass.panLaw == .balance && stemClass.masterVolume == 0.8, "\(label) control")
                #expect(masteredClass.masterEffects.map(\.kind) == [.limiter], "\(label) control")
                #expect(masteredClass.masterAutomation.count == 1, "\(label) control")
                #expect(masteredClass.masterModulationSources.count == 1, "\(label) control")
                #expect(masteredClass.masterModulationRoutes.count == 1, "\(label) control")

                RenderPassRaceRig.arm(change, at: moment, spy: spy, store: store, songB: songB) { _, _ in }
                let result = try await store.renderStems(
                    toDirectory: dir.appendingPathComponent("stems-\(label)").path, durationSeconds: 1,
                    includeMixdown: true, includeMasteredMixdown: true)
                let now = RenderPassRaceRig.inputs(of: store, mastered: true)
                print("[RACE] stems \(label): passes \(spy.passes.map(\.description)) | store now \(now)")

                // Controls: the switch really landed, and it really moved every input.
                #expect(spy.hooksRun == (change == .none ? 0 : 1), "\(label): the switch did not land")
                if change != .none {
                    #expect(now.tempoMap != stemClass.tempoMap, "\(label) control: the tempo did not move")
                    #expect(now.meterMap != stemClass.meterMap, "\(label) control: the meter did not move")
                    #expect(now.masterVolume != stemClass.masterVolume, "\(label) control: master volume")
                    #expect(now.masterEffects != masteredClass.masterEffects, "\(label) control: master chain")
                }
                // The gate: 2 stems + 00 Mixdown on the STEM class, then the mastered sibling, all of song A.
                #expect(spy.passes.count == 4, "\(label): 2 stems + 00 Mixdown + the mastered sibling")
                for (index, pass) in spy.passes.dropLast().enumerated() {
                    #expect(pass == stemClass, "\(label) pass \(index + 1) rendered another song: \(pass)")
                }
                #expect(spy.passes.last == masteredClass,
                        "\(label) mastered sibling rendered another song: \(String(describing: spy.passes.last))")
                #expect(result.masterChain == "excluded",
                        "\(label): the honesty field describes another song: \(String(describing: result.masterChain))")
                #expect(result.stems.count == 2 && result.mixdown != nil && result.masteredMixdown != nil,
                        "\(label): the full set landed")
                #expect(spy.legacyCalls == 0, "\(label): a pass crossed a seam without the rule")
            }
        }
    }

    /// (b) THE BOUNCE GATE. Song A bounces its first track in place. New (or Open of song B) lands inside the probe or
    /// inside the render. Nothing may land in the song that is open now: no track, no file, no undo step, no dirty
    /// flag, and the reply is a refusal that says so.
    @Test("Bounce in place: New or Open while it renders - no file, nothing lands in the other song, and a clear refusal")
    @MainActor
    func bounceNeverLandsInAnotherSong() async throws {
        let dir = try RenderPassRaceRig.scratch("bounce")
        defer { try? FileManager.default.removeItem(at: dir) }
        let songB = try RenderPassRaceRig.saveSongB(in: dir)
        for change in RenderPassRaceRig.Change.allCases {
            for moment in RenderPassRaceRig.Moment.allCases {
                let label = "\(change.rawValue)@\(moment.rawValue)"
                let store = try RenderPassRaceRig.songA(in: dir, tracks: RenderPassRaceRig.pannedPair())
                let spy = RenderPassRaceSpy()
                store.engine = spy
                let stemClass = RenderPassRaceRig.inputs(of: store, mastered: false)
                let source = store.tracks[0].id
                var stateAfterSwitch: (dirty: Bool, undo: Bool)?
                RenderPassRaceRig.arm(change, at: moment, spy: spy, store: store, songB: songB) {
                    stateAfterSwitch = ($0, $1)
                }
                var reply: BounceInPlaceResult?
                var refusal: (any Error)?
                do {
                    reply = try await store.bounceTrackInPlace(trackId: source, durationSeconds: 1, muteSource: true)
                } catch {
                    refusal = error
                }
                let sentence = (refusal as? LocalizedError)?.errorDescription
                print("[RACE] bounce \(label): tracks \(store.tracks.map(\.name)) writes \(spy.writes) "
                      + "passes \(spy.passes.map(\.description)) refusal \(sentence ?? "none")")
                #expect(spy.passes == [stemClass], "\(label): the render did not use the original song's inputs")
                #expect(spy.legacyCalls == 0, "\(label)")

                if change == .none {
                    // Control: with no switch the bounce lands exactly as before.
                    #expect(refusal == nil, "\(label): \(String(describing: refusal))")
                    #expect(spy.writes == 1, "\(label)")
                    #expect(store.tracks.map(\.name) == ["Left Gtr", "Left Gtr (Bounced)", "Right Gtr"], "\(label)")
                    #expect(store.tracks.first?.isMuted == true, "\(label): the source is muted")
                    // 1 s at song A's 92 BPM is 92/60 beats: the landed length uses the tempo it rendered at.
                    let length = reply?.clip.lengthBeats ?? -1
                    #expect(abs(length - 92.0 / 60.0) < 1e-9, "\(label): clip length \(length) beats")
                    continue
                }
                #expect(spy.hooksRun == 1, "\(label): the switch did not land")
                #expect(store.tracks.allSatisfy { !$0.name.hasSuffix("(Bounced)") },
                        "\(label): the bounce landed in the other song: \(store.tracks.map(\.name))")
                #expect(store.tracks.count == 0, "\(label): the other song gained a track: \(store.tracks.map(\.name))")
                #expect(spy.writes == 0, "\(label): a bounce file was written for a song that is closed")
                #expect(reply == nil, "\(label): the reply claims a landing")
                #expect(refusal is ProjectError, "\(label): no refusal: \(String(describing: refusal))")
                #expect(sentence?.contains("nothing was added") == true, "\(label): \(sentence ?? "no sentence")")
                if let stateAfterSwitch {
                    #expect(store.isDirty == stateAfterSwitch.dirty, "\(label): the other song was marked changed")
                    #expect(store.canUndo == stateAfterSwitch.undo, "\(label): the other song gained an undo step")
                } else {
                    Issue.record("\(label): the hook did not record the state after the switch")
                }
            }
        }
    }

    /// THE BYTE GATE (env-gated). A NO-switch export of song A (2 polySynth stems + "00 Mixdown" + the mastered
    /// sibling, then bounce in place) through a real `AudioEngine`, rendered TWICE into `<phase>` and
    /// `<phase>-repeat`. Every phase but `before` must equal the `before` capture byte for byte.
    @Test("Byte gate: a NO-switch stems + mastered + bounce-in-place export is byte-identical across the change (RACE_GATE_DIR, RACE_PHASE)",
          .enabled(if: !(ProcessInfo.processInfo.environment["RACE_GATE_DIR"] ?? "").isEmpty))
    @MainActor
    func noSwitchExportIsByteIdentical() async throws {
        let environment = ProcessInfo.processInfo.environment
        let gate = URL(fileURLWithPath: try #require(environment["RACE_GATE_DIR"]), isDirectory: true)
        let phase = environment["RACE_PHASE"] ?? "check"
        let scratch = try RenderPassRaceRig.scratch("gate")
        defer { try? FileManager.default.removeItem(at: scratch) }

        func renderSet(into out: URL) async throws -> [String] {
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let engine = AudioEngine()
            let store = try RenderPassRaceRig.songA(in: scratch, tracks: RenderPassRaceRig.synthPair())
            store.engine = engine
            let stems = try await store.renderStems(toDirectory: out.appendingPathComponent("stems").path,
                                                    durationSeconds: 3, includeMixdown: true,
                                                    includeMasteredMixdown: true)
            #expect(stems.masterChain == "excluded")
            let bounce = try await store.bounceTrackInPlace(trackId: store.tracks[0].id, durationSeconds: 3,
                                                            muteSource: false)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: bounce.file),
                                             to: out.appendingPathComponent("bounce-in-place.wav"))
            withExtendedLifetime(engine) {}
            let files = try FileManager.default.subpathsOfDirectory(atPath: out.path)
                .filter { $0.hasSuffix(".wav") }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for file in files {
                let channels = try TestSignals.readFile(out.appendingPathComponent(file))
                let peak = channels.map { $0.map(abs).max() ?? 0 }.max() ?? 0
                print("[RACE] gate \(out.lastPathComponent) \(file): peak \(peak)")
                #expect(peak > 1e-3, "\(file) is silent: the gate would compare silence")
                #expect(channels.allSatisfy { $0.allSatisfy { $0.isFinite } }, "\(file) has a NaN or Inf")
            }
            return files
        }

        let first = gate.appendingPathComponent(phase, isDirectory: true)
        let repeatRun = gate.appendingPathComponent("\(phase)-repeat", isDirectory: true)
        let files = try await renderSet(into: first)
        let repeatFiles = try await renderSet(into: repeatRun)
        #expect(files.count == 5, "2 stems + 00 Mixdown + 00 Mastered Mix + the bounce: \(files)")
        #expect(files == repeatFiles)
        func bytes(_ root: URL, _ file: String) -> Data? { try? Data(contentsOf: root.appendingPathComponent(file)) }
        let repeatEqual = files.filter { bytes(first, $0) != nil && bytes(first, $0) == bytes(repeatRun, $0) }.count
        print("[RACE] gate \(phase) vs \(phase)-repeat: \(repeatEqual) of \(files.count) byte-identical")
        #expect(repeatEqual == files.count, "the export is not deterministic, so a byte gate cannot judge it")
        if phase != "before" {
            let before = gate.appendingPathComponent("before", isDirectory: true)
            let beforeFiles = (try? FileManager.default.subpathsOfDirectory(atPath: before.path))?
                .filter { $0.hasSuffix(".wav") }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } ?? []
            let equal = files.filter { bytes(first, $0) != nil && bytes(first, $0) == bytes(before, $0) }
            print("[RACE] gate \(phase) vs before: n \(files.count) vs \(beforeFiles.count), "
                  + "\(equal.count) byte-identical, differ \(files.filter { !equal.contains($0) })")
            #expect(beforeFiles == files, "the file sets differ: before \(beforeFiles) now \(files)")
            #expect(equal.count == files.count, "a NO-switch export changed bytes")
        }
    }
}
