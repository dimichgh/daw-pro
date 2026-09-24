import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// Wire surface of the hosted-AU preset pair `au.listPresets` /
/// `au.loadPreset` (m23-cw): argument validation, response shapes and the full
/// refusal taxonomy against a FAKE engine that mimics the real engine's
/// contract — the real-AU truths (a load that takes, a refusal that changes
/// nothing, the state-capture round trip) live in DAWEngine's
/// AUPresetSurfaceTests.
///
/// The fake exists for the cases no system AU can be made to produce on
/// demand: a unit with USER presets, a unit that supports them, an ambiguous
/// preset name, and a unit that silently refuses a load. ⚠️ Every Apple
/// built-in on this machine reports `supportsUserPresets == false` with an
/// empty `userPresets`, so the user-preset paths below are exercised HERE and
/// nowhere else — they are contract tests, not evidence about a real plugin.
@MainActor
private final class AUPresetFakeEngine: AudioEngineControlling {
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
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
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

    // MARK: - The preset-surface fake

    /// false ⇒ no `.ready` instance (list nil / load .noHostedAU — the store
    /// then names instrumentStatus/effectStatus).
    var hosted = true
    var hasFactoryPresets = true
    var supportsUserPresets = false
    var factoryPresets: [HostedAUPresetInfo] = [
        HostedAUPresetInfo(number: 0, name: "Small Room"),
        HostedAUPresetInfo(number: 1, name: "Cathedral"),
    ]
    var userPresets: [HostedAUPresetInfo] = []
    var currentPreset: HostedAUCurrentPreset? = HostedAUCurrentPreset(
        number: 0, name: "Small Room", source: .factory)
    /// When set, `loadHostedAUPreset` throws this instead of resolving — the
    /// engine-taxonomy passthrough tests.
    var loadFailure: HostedAUPresetError?
    var lastTarget: HostedAUTarget?
    var lastSelector: HostedAUPresetSelector?

    var instrumentStatus: AudioUnitTrackStatus?
    var effectStatus: AudioUnitTrackStatus?

    func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus? { instrumentStatus }
    func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus? { effectStatus }

    func listHostedAUPresets(_ target: HostedAUTarget) throws -> HostedAUPresetList? {
        lastTarget = target
        guard hosted else { return nil }
        return HostedAUPresetList(hasFactoryPresets: hasFactoryPresets,
                                  supportsUserPresets: supportsUserPresets,
                                  factoryPresets: factoryPresets,
                                  userPresets: userPresets,
                                  currentPreset: currentPreset)
    }

    @discardableResult
    func loadHostedAUPreset(_ target: HostedAUTarget,
                            selector: HostedAUPresetSelector) throws
        -> HostedAUCurrentPreset {
        lastTarget = target
        lastSelector = selector
        guard hosted else { throw HostedAUPresetError.noHostedAU }
        if let loadFailure { throw loadFailure }
        let all = factoryPresets + userPresets
        guard !all.isEmpty else { throw HostedAUPresetError.noPresets }
        let hit: HostedAUPresetInfo
        switch selector {
        case .number(let number):
            guard let found = all.first(where: { $0.number == number }) else {
                throw HostedAUPresetError.unknownPresetNumber(
                    number, available: all.map(\.number))
            }
            hit = found
        case .name(let name):
            guard let found = all.first(where: { $0.name == name })
                ?? all.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                throw HostedAUPresetError.unknownPresetName(name, available: all.map(\.name))
            }
            hit = found
        }
        if hit.number < 0, !supportsUserPresets {
            throw HostedAUPresetError.userPresetsUnsupported(hit.number)
        }
        let source: HostedAUPresetSource =
            factoryPresets.contains(hit) ? .factory
            : (userPresets.contains(hit) ? .user : .unlisted)
        let now = HostedAUCurrentPreset(number: hit.number, name: hit.name, source: source)
        currentPreset = now
        return now
    }
}

@MainActor
@Suite("CommandRouter — hosted-AU preset surface (m23-cw)")
struct AUPresetCommandTests {
    private static let reverbComponent = AudioUnitComponentID(
        type: "aufx", subType: "mrev", manufacturer: "appl")
    private static let dlsComponent = AudioUnitComponentID(
        subType: "dls ", manufacturer: "appl")

    private func makeSetup() -> (CommandRouter, ProjectStore, AUPresetFakeEngine) {
        let store = ProjectStore()
        let engine = AUPresetFakeEngine()
        store.engine = engine
        return (CommandRouter(store: store), store, engine)
    }

    /// An audio track with one hosted-AU insert named "AUMatrixReverb".
    private func addReverbInsert(_ store: ProjectStore) throws
        -> (trackID: UUID, effectID: UUID) {
        let trackID = store.addTrack(kind: .audio).id
        let effect = try store.addEffect(
            toTrack: trackID, kind: .audioUnit,
            audioUnit: AudioUnitConfig(component: Self.reverbComponent,
                                       name: "AUMatrixReverb"))
        return (trackID, effect.id)
    }

    private func addAUInstrumentTrack(_ store: ProjectStore) throws -> UUID {
        let trackID = store.addTrack(kind: .instrument).id
        _ = try store.setInstrument(
            id: trackID,
            audioUnit: AudioUnitConfig(component: Self.dlsComponent, name: "DLSMusicDevice"))
        return trackID
    }

    // MARK: - Canonical list

    @Test("allCommands carries the au.*Preset pair; count 215 -> 217")
    func commandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("au.listPresets"))
        #expect(CommandRouter.allCommands.contains("au.loadPreset"))
        #expect(CommandRouter.allCommands.count == 240)   // -> 234 at m23-q (clip.autoCorrectPitch/clip.clearPitchEdits/clip.getPitchEdits, appended at the tail) -> 237 at p2-c (view.openPitchEditor next to view.openEditor; clip.setNotePitch/clip.splitNote next to clip.sliceToSampler, NOT at the tail) -> 239 at m39-levels-2 wire (instrument.spreadSlice/instrument.setSpreadDirection, placed next to instrument.describeSampler, NOT at the tail)
        // Placed next to their au.* siblings, NOT at the tail — the m23-ct
        // precedent (a tail append reddened 19 end-relative assertions across
        // 7 files). This pins the placement, not just the presence.
        let all = CommandRouter.allCommands
        guard let index = all.firstIndex(of: "au.listPresets") else {
            Issue.record("au.listPresets is not in allCommands")
            return
        }
        #expect(all[index - 1] == "au.setParam")
        #expect(all[index + 1] == "au.loadPreset")
        #expect(index < all.count - 20, "the preset pair must not sit at the tail")
    }

    // MARK: - au.listPresets

    @Test("list an effect target: full wire shape, factory rows, classified current preset")
    func listEffectTarget() async throws {
        let (router, store, engine) = makeSetup()
        engine.userPresets = [HostedAUPresetInfo(number: -1, name: "My Patch")]
        engine.supportsUserPresets = true
        let (trackID, effectID) = try addReverbInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.listPresets",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["trackId"]?.stringValue == trackID.uuidString)
        #expect(result["effectId"]?.stringValue == effectID.uuidString)
        #expect(result["componentName"]?.stringValue == "AUMatrixReverb")
        #expect(result["hasFactoryPresets"]?.boolValue == true)
        #expect(result["supportsUserPresets"]?.boolValue == true)

        let factory = try #require(result["factoryPresets"]?.arrayValue)
        #expect(factory.count == 2)
        #expect(factory[0]["number"]?.doubleValue == 0)
        #expect(factory[0]["name"]?.stringValue == "Small Room")
        #expect(factory[1]["name"]?.stringValue == "Cathedral")

        let user = try #require(result["userPresets"]?.arrayValue)
        #expect(user.count == 1)
        #expect(user[0]["number"]?.doubleValue == -1)   // user presets are NEGATIVE
        #expect(user[0]["name"]?.stringValue == "My Patch")

        let current = try #require(result["currentPreset"])
        #expect(current["number"]?.doubleValue == 0)
        #expect(current["name"]?.stringValue == "Small Room")
        #expect(current["source"]?.stringValue == "factory")
        #expect(engine.lastTarget == .effect(effectID: effectID))
    }

    @Test("list an instrument target: no effectId key, instrument-flavor target")
    func listInstrumentTarget() async throws {
        let (router, store, engine) = makeSetup()
        let trackID = try addAUInstrumentTrack(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.listPresets",
            params: ["trackId": .string(trackID.uuidString)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["effectId"] == nil)                 // omitted, not null
        #expect(result["componentName"]?.stringValue == "DLSMusicDevice")
        #expect(engine.lastTarget == .instrument(trackID: trackID))
    }

    @Test("an AU with NO presets answers hasFactoryPresets:false — success, never an error")
    func listPresetlessUnit() async throws {
        let (router, store, engine) = makeSetup()
        engine.hasFactoryPresets = false
        engine.factoryPresets = []
        engine.userPresets = []
        // The measured -1/"Untitled" placeholder every preset-less Apple
        // built-in reports.
        engine.currentPreset = HostedAUCurrentPreset(number: -1, name: "Untitled",
                                                     source: .unlisted)
        let (trackID, effectID) = try addReverbInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.listPresets",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["hasFactoryPresets"]?.boolValue == false)
        #expect(result["factoryPresets"]?.arrayValue?.isEmpty == true)
        #expect(result["userPresets"]?.arrayValue?.isEmpty == true)
        #expect(result["currentPreset"]?["source"]?.stringValue == "unlisted")
    }

    @Test("a nil currentPreset serialises as an explicit null, not a missing key")
    func listNullCurrentPreset() async throws {
        let (router, store, engine) = makeSetup()
        engine.currentPreset = nil
        let (trackID, effectID) = try addReverbInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.listPresets",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString)]))
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["currentPreset"] == .null)
    }

    // MARK: - au.loadPreset

    @Test("load by number: the response echoes the engine's READ-BACK")
    func loadByNumber() async throws {
        let (router, store, engine) = makeSetup()
        let (trackID, effectID) = try addReverbInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.loadPreset",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "presetNumber": .number(1)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["trackId"]?.stringValue == trackID.uuidString)
        #expect(result["effectId"]?.stringValue == effectID.uuidString)
        #expect(result["componentName"]?.stringValue == "AUMatrixReverb")
        let preset = try #require(result["preset"])
        #expect(preset["number"]?.doubleValue == 1)
        #expect(preset["name"]?.stringValue == "Cathedral")
        #expect(preset["source"]?.stringValue == "factory")
        #expect(engine.lastSelector == .number(1))
        #expect(engine.lastTarget == .effect(effectID: effectID))
    }

    @Test("load by name reaches the engine as a name selector")
    func loadByName() async throws {
        let (router, store, engine) = makeSetup()
        let (trackID, effectID) = try addReverbInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.loadPreset",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "presetName": .string("Cathedral")]))
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(engine.lastSelector == .name("Cathedral"))
        #expect(response.result?["preset"]?["number"]?.doubleValue == 1)
    }

    @Test("a NEGATIVE presetNumber is legal — user presets are negative by contract")
    func loadNegativeNumberIsLegal() async throws {
        let (router, store, engine) = makeSetup()
        engine.supportsUserPresets = true
        engine.userPresets = [HostedAUPresetInfo(number: -3, name: "My Patch")]
        let (trackID, effectID) = try addReverbInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.loadPreset",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "presetNumber": .number(-3)]))
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(engine.lastSelector == .number(-3))
        let preset = try #require(response.result?["preset"])
        #expect(preset["number"]?.doubleValue == -3)
        #expect(preset["source"]?.stringValue == "user")
    }

    @Test("selector validation: both, neither, non-integer, empty name")
    func selectorValidation() async throws {
        let (router, store, _) = makeSetup()
        let (trackID, effectID) = try addReverbInsert(store)
        let base: [String: JSONValue] = ["trackId": .string(trackID.uuidString),
                                         "effectId": .string(effectID.uuidString)]

        var params = base
        params["presetNumber"] = .number(0)
        params["presetName"] = .string("Cathedral")
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error == "pass 'presetNumber' OR 'presetName', not both — they are two ways to name the same preset")

        response = await router.handle(ControlRequest(
            id: "2", command: "au.loadPreset", params: base))
        #expect(!response.ok)
        #expect(response.error == "one of 'presetNumber' or 'presetName' is required — call au.listPresets to see what this plugin ships")

        params = base
        params["presetNumber"] = .number(1.5)
        response = await router.handle(ControlRequest(
            id: "3", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error == "'presetNumber' must be an integer from au.listPresets (factory presets are >= 0, user presets are < 0)")

        params["presetNumber"] = .string("1")
        response = await router.handle(ControlRequest(
            id: "4", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error?.contains("'presetNumber' must be an integer") == true)

        params = base
        params["presetName"] = .string("")
        response = await router.handle(ControlRequest(
            id: "5", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error == "'presetName' must be a non-empty preset name from au.listPresets")

        params["presetName"] = .number(3)
        response = await router.handle(ControlRequest(
            id: "6", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error?.contains("'presetName' must be a non-empty") == true)
    }

    // MARK: - Engine refusal taxonomy reaches the wire verbatim

    @Test("engine refusals surface as their teaching messages")
    func engineRefusalsPassThrough() async throws {
        let (router, store, engine) = makeSetup()
        let (trackID, effectID) = try addReverbInsert(store)
        let params: [String: JSONValue] = ["trackId": .string(trackID.uuidString),
                                           "effectId": .string(effectID.uuidString),
                                           "presetNumber": .number(0)]

        engine.loadFailure = .noPresets
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error?.contains("publishes no presets") == true)
        #expect(response.error?.contains("plugin.openUI") == true)

        engine.loadFailure = .unknownPresetNumber(99, available: [0, 1])
        response = await router.handle(ControlRequest(
            id: "2", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error == "no preset numbered 99 on this Audio Unit — it publishes 0, 1; call au.listPresets for names")

        engine.loadFailure = .ambiguousPresetName("Default", numbers: [3, 7])
        response = await router.handle(ControlRequest(
            id: "3", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error == "'Default' names 2 different presets on this Audio Unit (numbers 3, 7) — pass presetNumber to choose one")

        engine.loadFailure = .userPresetsUnsupported(-2)
        response = await router.handle(ControlRequest(
            id: "4", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error?.contains("supportsUserPresets:false") == true)

        // THE SILENT-NO-OP GUARD on the wire: a load the unit ignored must
        // arrive as an ERROR, never as a success reporting the old preset.
        engine.loadFailure = .presetDidNotTake(
            requested: HostedAUPresetInfo(number: 4, name: "Plate"),
            observed: "0 'Small Room'")
        response = await router.handle(ControlRequest(
            id: "5", command: "au.loadPreset", params: params))
        #expect(!response.ok)
        #expect(response.error == "the Audio Unit silently refused preset 4 'Plate' — it still reports 0 'Small Room', and nothing was changed")
    }

    @Test("a long available-list is briefed, not dumped")
    func refusalListsAreBriefed() throws {
        // AUDistortion really does ship 22 presets — a wall of numbers buries
        // the instruction that follows them.
        let many = Array(0..<22)
        let message = try #require(
            HostedAUPresetError.unknownPresetNumber(99, available: many).errorDescription)
        #expect(message.contains("(22 total)"))
        #expect(!message.contains("21"), "the tail of a long list must be elided")
        // A SHORT list is printed in full — the briefing must not fire early.
        let short = try #require(
            HostedAUPresetError.unknownPresetNumber(9, available: [0, 1, 2]).errorDescription)
        #expect(short.contains("0, 1, 2"))
        #expect(!short.contains("total)"))
    }

    // MARK: - Target taxonomy (shared with the parameter pair)

    @Test("both preset commands reject unknown parameter keys")
    func rejectsUnknownKeys() async throws {
        let (router, store, _) = makeSetup()
        let (trackID, effectID) = try addReverbInsert(store)
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.listPresets",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "presetNumber": .number(0)]))   // not a listPresets param
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'presetNumber'") == true)

        response = await router.handle(ControlRequest(
            id: "2", command: "au.loadPreset",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "presetNumber": .number(0),
                     "presetNmae": .string("x")]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'presetNmae'") == true)
    }

    @Test("trackId 'master' rejects: the master chain cannot host AUs")
    func masterRejects() async throws {
        let (router, _, _) = makeSetup()
        let calls: [(command: String, params: [String: JSONValue])] = [
            ("au.listPresets", ["trackId": .string("master")]),
            ("au.loadPreset", ["trackId": .string("master"), "presetNumber": .number(0)]),
        ]
        for call in calls {
            let response = await router.handle(ControlRequest(
                id: "1", command: call.command, params: call.params))
            #expect(!response.ok, "\(call.command)")
            #expect(response.error == "the master chain hosts built-in effects only — AU parameters apply to track inserts",
                    "\(call.command)")
        }
    }

    @Test("built-in kinds and sound banks reject through the shared taxonomy")
    func builtInKindsReject() async throws {
        let (router, store, _) = makeSetup()
        let trackID = store.addTrack(kind: .audio).id
        let gain = try store.addEffect(toTrack: trackID, kind: .gain)
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.listPresets",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(gain.id.uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("is a built-in gain") == true)

        // A sound-bank instrument redirects to the program surface (LAW L3):
        // the bank program, not an AU preset, is its source of truth.
        let bankTrack = store.addTrack(kind: .instrument).id
        _ = try store.setInstrument(id: bankTrack, kind: .soundBank)
        response = await router.handle(ControlRequest(
            id: "2", command: "au.loadPreset",
            params: ["trackId": .string(bankTrack.uuidString),
                     "presetNumber": .number(0)]))
        #expect(!response.ok)
        let message = try #require(response.error)
        #expect(message.contains("uses a sound-bank instrument"))
        #expect(message.contains("instrument.listSoundBankPrograms"))
    }

    @Test("a not-ready instance names its status for both commands")
    func statusNamingErrors() async throws {
        let (router, store, engine) = makeSetup()
        engine.hosted = false
        let (trackID, effectID) = try addReverbInsert(store)
        let base: [String: JSONValue] = ["trackId": .string(trackID.uuidString),
                                         "effectId": .string(effectID.uuidString)]

        engine.effectStatus = .pending
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.listPresets", params: base))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready (status: pending) — retry once prepared")

        engine.effectStatus = .failed("component exploded")
        response = await router.handle(ControlRequest(
            id: "2", command: "au.loadPreset",
            params: base.merging(["presetNumber": .number(0)]) { $1 }))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready (status: failed: component exploded)")

        engine.effectStatus = nil
        response = await router.handle(ControlRequest(
            id: "3", command: "au.listPresets", params: base))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready — the engine is not hosting this target yet (running headless, or the instance was just released)")
    }

    // MARK: - The m23-bx-1 law, pinned at the store seam

    @Test("a preset load writes NOTHING to the model — live state stays in the registry")
    func loadDoesNotTouchTheModel() async throws {
        // `ProjectStore.engine` is WEAK — bind the fake, or it deallocates and
        // every call answers "audio engine not available" instead of testing
        // anything. (It cost this test one red run.)
        let (router, store, engine) = makeSetup()
        #expect(store.engine === engine)
        let (trackID, effectID) = try addReverbInsert(store)
        let before = try #require(store.tracks.first { $0.id == trackID })
        let stateBefore = before.effects.first { $0.id == effectID }?.audioUnit?.stateData
        let dirtyBefore = store.isDirty

        let response = await router.handle(ControlRequest(
            id: "1", command: "au.loadPreset",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "presetNumber": .number(1)]))
        #expect(response.ok, "\(response.error ?? "?")")

        // m23-bx-1: a hosted plug-in's live state lives in AUHostRegistry,
        // NEVER in the model. A stateData write here would both go stale and
        // change the registry's prepare identity — forcing a re-instantiate
        // that discards the preset being loaded. Save/render read the live
        // bytes through tracksWithLiveAudioUnitState() instead.
        let after = try #require(store.tracks.first { $0.id == trackID })
        #expect(after.effects.first { $0.id == effectID }?.audioUnit?.stateData == stateBefore)
        #expect(after == before, "au.loadPreset mutated the project model")
        // And no undo entry / no dirty flag — parity with picking a preset in
        // the vendor's own window, which the model never sees either.
        #expect(store.isDirty == dirtyBefore)
    }
}
