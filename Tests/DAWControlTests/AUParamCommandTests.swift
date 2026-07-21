import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// Wire surface of the hosted-AU parameter pair `au.describeParams` /
/// `au.setParam` (design-au-parameter-surface §4): full error taxonomy +
/// response shapes against a FAKE engine that mimics the real engine's
/// contract (page slicing, clamp + read-back echo, `HostedAUParameterError`
/// refusals) — the real-tree truths live in DAWEngine's
/// AUParameterSurfaceTests. The fake makes the opaque-tree case deterministic
/// (no system AU guarantees an empty tree).
@MainActor
private final class AUParamFakeEngine: AudioEngineControlling {
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

    // MARK: - The parameter-surface fake

    /// false ⇒ no `.ready` instance (describe nil / set .noHostedAU — the
    /// store then names `instrumentStatus`/`effectStatus`).
    var hosted = true
    /// false ⇒ a healthy AU with a nil tree (opaque state).
    var hasTree = true
    /// The fake tree, in stable order.
    var parameters: [HostedAUParameterInfo] = []
    var instrumentStatus: AudioUnitTrackStatus?
    var effectStatus: AudioUnitTrackStatus?
    /// What the wire actually asked for (paging-clamp assertions).
    var lastDescribe: (offset: Int, maxParams: Int, addresses: [String]?)?
    var lastTarget: HostedAUTarget?

    func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus? { instrumentStatus }
    func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus? { effectStatus }

    func describeHostedAUParameters(_ target: HostedAUTarget, offset: Int,
                                    maxParams: Int, addresses: [String]?) throws
        -> HostedAUParameterPage? {
        lastTarget = target
        lastDescribe = (offset, maxParams, addresses)
        guard hosted else { return nil }
        guard hasTree else {
            return HostedAUParameterPage(hasParameterTree: false, totalCount: 0,
                                         offset: 0, truncated: false, parameters: [])
        }
        if let addresses {
            var hits: [HostedAUParameterInfo] = []
            var unknown: [String] = []
            for address in addresses {
                if let hit = parameters.first(where: { $0.address == address }) {
                    hits.append(hit)
                } else {
                    unknown.append(address)
                }
            }
            return HostedAUParameterPage(hasParameterTree: true, totalCount: parameters.count,
                                         offset: 0, truncated: false,
                                         parameters: hits, unknownAddresses: unknown)
        }
        let start = min(max(offset, 0), parameters.count)
        let end = min(start + min(max(maxParams, 1), 4_096), parameters.count)
        let page = Array(parameters[start..<end])
        return HostedAUParameterPage(hasParameterTree: true, totalCount: parameters.count,
                                     offset: start,
                                     truncated: start + page.count < parameters.count,
                                     parameters: page)
    }

    func setHostedAUParameter(_ target: HostedAUTarget, address: String,
                              value: Double) throws -> HostedAUParameterInfo {
        lastTarget = target
        guard hosted else { throw HostedAUParameterError.noHostedAU }
        guard value.isFinite else { throw HostedAUParameterError.nonFiniteValue }
        guard UInt64(address) != nil else {
            throw HostedAUParameterError.invalidAddress(address)
        }
        guard hasTree else { throw HostedAUParameterError.noParameterTree }
        guard let index = parameters.firstIndex(where: { $0.address == address }) else {
            throw HostedAUParameterError.unknownAddress(address)
        }
        guard parameters[index].writable else {
            throw HostedAUParameterError.notWritable(parameters[index].identifier)
        }
        // Silent clamp + read-back echo — the real engine's contract.
        parameters[index].value = min(max(value, parameters[index].minValue),
                                      parameters[index].maxValue)
        return parameters[index]
    }
}

@MainActor
@Suite("CommandRouter — hosted-AU parameter surface")
struct AUParamCommandTests {
    private static let delayComponent = AudioUnitComponentID(
        type: "aufx", subType: "dely", manufacturer: "appl")
    private static let dlsComponent = AudioUnitComponentID(
        subType: "dls ", manufacturer: "appl")

    private static func makeParam(
        address: String = "281474976710659", identifier: String = "delayTime",
        displayName: String = "Delay Time", unit: String = "seconds",
        minValue: Double = 0, maxValue: Double = 2, value: Double = 1,
        writable: Bool = true
    ) -> HostedAUParameterInfo {
        HostedAUParameterInfo(address: address, identifier: identifier,
                              displayName: displayName, keyPath: identifier,
                              unit: unit, minValue: minValue, maxValue: maxValue,
                              value: value, writable: writable, readable: true)
    }

    private func makeSetup() -> (CommandRouter, ProjectStore, AUParamFakeEngine) {
        let store = ProjectStore()
        let engine = AUParamFakeEngine()
        store.engine = engine
        engine.parameters = [Self.makeParam()]
        return (CommandRouter(store: store), store, engine)
    }

    /// An audio track with one hosted-AU insert named "AUDelay".
    private func addDelayInsert(_ store: ProjectStore) throws -> (trackID: UUID, effectID: UUID) {
        let trackID = store.addTrack(kind: .audio).id
        let effect = try store.addEffect(
            toTrack: trackID, kind: .audioUnit,
            audioUnit: AudioUnitConfig(component: Self.delayComponent, name: "AUDelay"))
        return (trackID, effect.id)
    }

    /// An instrument track hosting an AU instrument named "DLSMusicDevice".
    private func addAUInstrumentTrack(_ store: ProjectStore) throws -> UUID {
        let trackID = store.addTrack(kind: .instrument).id
        _ = try store.setInstrument(
            id: trackID,
            audioUnit: AudioUnitConfig(component: Self.dlsComponent, name: "DLSMusicDevice"))
        return trackID
    }

    // MARK: - Canonical list

    @Test("allCommands carries the au.* pair; count moved 139 -> 141 (142 as of m21-d's clip.fitToContent, 143 as of m21-e's clip.analyzeAudio, 144 as of m22-c's mixer.liveLoudness, 148 as of m22-g's reference.*)")
    func commandsAreCanonical() {
        #expect(CommandRouter.allCommands.contains("au.describeParams"))
        #expect(CommandRouter.allCommands.contains("au.setParam"))
        #expect(CommandRouter.allCommands.count == 152)
    }

    // MARK: - au.describeParams shapes

    @Test("describe an effect target: full wire shape with truncated paging")
    func describeEffectTruncatedPage() async throws {
        let (router, store, engine) = makeSetup()
        engine.parameters = [
            Self.makeParam(address: "1", identifier: "a"),
            Self.makeParam(address: "2", identifier: "b"),
            Self.makeParam(address: "3", identifier: "c"),
        ]
        let (trackID, effectID) = try addDelayInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "maxParams": .number(2)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["trackId"]?.stringValue == trackID.uuidString)
        #expect(result["effectId"]?.stringValue == effectID.uuidString)
        #expect(result["componentName"]?.stringValue == "AUDelay")
        #expect(result["hasParameterTree"]?.boolValue == true)
        #expect(result["totalCount"]?.doubleValue == 3)
        #expect(result["offset"]?.doubleValue == 0)
        #expect(result["truncated"]?.boolValue == true)
        #expect(result["unknownAddresses"]?.arrayValue?.isEmpty == true)
        let parameters = try #require(result["parameters"]?.arrayValue)
        #expect(parameters.count == 2)
        let first = try #require(parameters.first)
        #expect(first["address"] == .string("1"))          // decimal STRING, never a number
        #expect(first["identifier"]?.stringValue == "a")
        #expect(first["displayName"]?.stringValue == "Delay Time")
        #expect(first["keyPath"]?.stringValue == "a")
        #expect(first["unit"]?.stringValue == "seconds")
        #expect(first["unitName"] == .null)
        #expect(first["minValue"]?.doubleValue == 0)
        #expect(first["maxValue"]?.doubleValue == 2)
        #expect(first["value"]?.doubleValue == 1)
        #expect(first["writable"]?.boolValue == true)
        #expect(first["readable"]?.boolValue == true)
        #expect(first["valueStrings"] == .null)
        // The engine saw the resolved effect target.
        #expect(engine.lastTarget == .effect(effectID: effectID))
    }

    @Test("describe an instrument target: no effectId key, instrument-flavor target")
    func describeInstrumentTarget() async throws {
        let (router, store, engine) = makeSetup()
        let trackID = try addAUInstrumentTrack(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["effectId"] == nil)                 // omitted, not null
        #expect(result["componentName"]?.stringValue == "DLSMusicDevice")
        #expect(engine.lastTarget == .instrument(trackID: trackID))
        // Paging defaults reached the engine: offset 0, maxParams 512.
        #expect(engine.lastDescribe?.offset == 0)
        #expect(engine.lastDescribe?.maxParams == 512)
    }

    @Test("an AU with no tree answers hasParameterTree:false — success, never an error")
    func describeOpaqueTree() async throws {
        let (router, store, engine) = makeSetup()
        engine.hasTree = false
        let (trackID, effectID) = try addDelayInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["hasParameterTree"]?.boolValue == false)
        #expect(result["totalCount"]?.doubleValue == 0)
        #expect(result["parameters"]?.arrayValue?.isEmpty == true)
    }

    @Test("addresses filter round-trips hits and reports misses in unknownAddresses")
    func describeAddressesFilter() async throws {
        let (router, store, engine) = makeSetup()
        let (trackID, effectID) = try addDelayInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "addresses": .array([.string("281474976710659"), .string("999")])]))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["parameters"]?.arrayValue?.count == 1)
        #expect(result["unknownAddresses"]?.arrayValue == [.string("999")])
        #expect(engine.lastDescribe?.addresses == ["281474976710659", "999"])
    }

    @Test("maxParams clamps silently into 1…4096; offset validates readably")
    func pagingClampAndValidation() async throws {
        let (router, store, engine) = makeSetup()
        let (trackID, effectID) = try addDelayInsert(store)
        let base: [String: JSONValue] = ["trackId": .string(trackID.uuidString),
                                         "effectId": .string(effectID.uuidString)]

        var params = base
        params["maxParams"] = .number(99_999)
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams", params: params))
        #expect(response.ok)
        #expect(engine.lastDescribe?.maxParams == 4_096)   // silent high clamp

        params["maxParams"] = .number(0)
        response = await router.handle(ControlRequest(
            id: "2", command: "au.describeParams", params: params))
        #expect(response.ok)
        #expect(engine.lastDescribe?.maxParams == 1)       // silent low clamp

        params["maxParams"] = .number(2.5)
        response = await router.handle(ControlRequest(
            id: "3", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "'maxParams' must be an integer (default 512; values clamp into 1…4096)")

        params = base
        params["offset"] = .number(-1)
        response = await router.handle(ControlRequest(
            id: "4", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "'offset' must be an integer >= 0")
    }

    @Test("addresses is mutually exclusive with offset/maxParams; entries must be strings")
    func addressesExclusivityAndTypes() async throws {
        let (router, store, _) = makeSetup()
        let (trackID, effectID) = try addDelayInsert(store)
        let base: [String: JSONValue] = ["trackId": .string(trackID.uuidString),
                                         "effectId": .string(effectID.uuidString)]

        var params = base
        params["addresses"] = .array([.string("1")])
        params["offset"] = .number(0)
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "'addresses' is an exact-get filter — pass it OR offset/maxParams paging, not both")

        params = base
        params["addresses"] = .array([.number(7)])
        response = await router.handle(ControlRequest(
            id: "2", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "addresses[0] must be a decimal address string from au.describeParams")

        params = base
        params["addresses"] = .string("1")
        response = await router.handle(ControlRequest(
            id: "3", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "'addresses' must be an array of decimal address strings (see au.describeParams results)")
    }

    @Test("both commands reject unknown parameter keys with the teaching error")
    func rejectsUnknownKeys() async throws {
        let (router, store, _) = makeSetup()
        let (trackID, effectID) = try addDelayInsert(store)
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "adresses": .array([])]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'adresses'") == true)

        response = await router.handle(ControlRequest(
            id: "2", command: "au.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "address": .string("281474976710659"),
                     "value": .number(1), "vaule": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'vaule'") == true)
    }

    // MARK: - au.setParam

    @Test("set clamps silently and echoes the read-back value")
    func setClampAndEcho() async throws {
        let (router, store, engine) = makeSetup()
        let (trackID, effectID) = try addDelayInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "address": .string("281474976710659"),
                     "value": .number(99)]))         // param max is 2 → clamps
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["trackId"]?.stringValue == trackID.uuidString)
        #expect(result["effectId"]?.stringValue == effectID.uuidString)
        let parameter = try #require(result["parameter"])
        #expect(parameter["value"]?.doubleValue == 2)  // the echo is the clamped truth
        #expect(parameter["address"] == .string("281474976710659"))
        #expect(engine.parameters[0].value == 2)
        #expect(engine.lastTarget == .effect(effectID: effectID))
    }

    @Test("set tolerates an exactly-integral JSON number address")
    func setNumberAddressTolerated() async throws {
        let (router, store, engine) = makeSetup()
        engine.parameters = [Self.makeParam(address: "42")]
        let (trackID, effectID) = try addDelayInsert(store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "address": .number(42),
                     "value": .number(0.5)]))
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["parameter"]?["value"]?.doubleValue == 0.5)

        // A fractional number is NOT an address.
        let bad = await router.handle(ControlRequest(
            id: "2", command: "au.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "address": .number(42.5),
                     "value": .number(0.5)]))
        #expect(!bad.ok)
        #expect(bad.error == "'address' must be the decimal string form of the parameter address (see au.describeParams)")
    }

    @Test("set refusals: NaN value, malformed address, unknown address, non-writable, no tree")
    func setErrorTaxonomy() async throws {
        let (router, store, engine) = makeSetup()
        let (trackID, effectID) = try addDelayInsert(store)
        let base: [String: JSONValue] = ["trackId": .string(trackID.uuidString),
                                         "effectId": .string(effectID.uuidString)]

        var params = base
        params["address"] = .string("281474976710659")
        params["value"] = .number(Double.nan)
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.setParam", params: params))
        #expect(!response.ok)
        #expect(response.error == "'value' must be a finite number")

        params["value"] = .number(1)
        params["address"] = .string("not-a-number")
        response = await router.handle(ControlRequest(
            id: "2", command: "au.setParam", params: params))
        #expect(!response.ok)
        #expect(response.error == "'address' must be the decimal string form of the parameter address (see au.describeParams)")

        params["address"] = .string("999")
        response = await router.handle(ControlRequest(
            id: "3", command: "au.setParam", params: params))
        #expect(!response.ok)
        #expect(response.error == "unknown AU parameter address '999' — call au.describeParams to list addresses")

        engine.parameters = [Self.makeParam(writable: false)]
        params["address"] = .string("281474976710659")
        response = await router.handle(ControlRequest(
            id: "4", command: "au.setParam", params: params))
        #expect(!response.ok)
        #expect(response.error == "parameter 'delayTime' is not writable")

        engine.hasTree = false
        response = await router.handle(ControlRequest(
            id: "5", command: "au.setParam", params: params))
        #expect(!response.ok)
        #expect(response.error == "this Audio Unit publishes no parameter tree (opaque state) — use plugin.openUI to edit it visually")
    }

    // MARK: - Target taxonomy (shared by both commands)

    @Test("trackId 'master' rejects: the master chain cannot host AUs")
    func masterRejects() async throws {
        let (router, _, _) = makeSetup()
        let calls: [(command: String, params: [String: JSONValue])] = [
            ("au.describeParams", ["trackId": .string("master")]),
            ("au.setParam", ["trackId": .string("master"),
                             "address": .string("1"), "value": .number(0)]),
        ]
        for call in calls {
            let response = await router.handle(ControlRequest(
                id: "1", command: call.command, params: call.params))
            #expect(!response.ok, "\(call.command)")
            #expect(response.error == "the master chain hosts built-in effects only — AU parameters apply to track inserts",
                    "\(call.command)")
        }
    }

    @Test("unknown track and effect-not-on-track reject with the store wording")
    func unknownTrackAndEffect() async throws {
        let (router, store, _) = makeSetup()
        let ghost = UUID()
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(ghost.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "No track with id \(ghost.uuidString).")

        let (trackID, _) = try addDelayInsert(store)
        let ghostEffect = UUID()
        response = await router.handle(ControlRequest(
            id: "2", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(ghostEffect.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "no effect with id \(ghostEffect.uuidString) on that track")
    }

    @Test("built-in effect kinds reject — AU parameters apply only to Audio Unit effects")
    func builtInEffectRejects() async throws {
        let (router, store, _) = makeSetup()
        let trackID = store.addTrack(kind: .audio).id
        let gain = try store.addEffect(toTrack: trackID, kind: .gain)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(gain.id.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "effect '\(gain.id.uuidString)' is a built-in gain — AU parameters apply only to Audio Unit effects (built-in kinds use fx.setParam)")
    }

    @Test("built-in instruments and non-instrument tracks reject readably")
    func builtInInstrumentAndTrackKindReject() async throws {
        let (router, store, _) = makeSetup()
        // A fresh instrument track defaults to the built-in polySynth.
        let instrumentTrack = store.addTrack(kind: .instrument).id
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(instrumentTrack.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "track '\(instrumentTrack.uuidString)' uses the built-in polySynth instrument — AU parameters apply only to Audio Unit instruments (built-in kinds use track.setInstrument)")

        // An audio track with no effectId has no instrument to target.
        let audioTrack = store.addTrack(kind: .audio).id
        response = await router.handle(ControlRequest(
            id: "2", command: "au.setParam",
            params: ["trackId": .string(audioTrack.uuidString),
                     "address": .string("1"), "value": .number(0)]))
        #expect(!response.ok)
        #expect(response.error == "track '\(audioTrack.uuidString)' is a 'audio' track — AU parameters apply only to Audio Unit instruments (pass effectId to target an insert effect)")
    }

    @Test("a sound-bank instrument redirects to the program-selection surface (LAW L3)")
    func soundBankRedirects() async throws {
        let (router, store, _) = makeSetup()
        let trackID = store.addTrack(kind: .instrument).id
        _ = try store.setInstrument(id: trackID, kind: .soundBank)
        let response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams",
            params: ["trackId": .string(trackID.uuidString)]))
        #expect(!response.ok)
        let message = try #require(response.error)
        #expect(message.contains("uses a sound-bank instrument"))
        #expect(message.contains("instrument.listSoundBankPrograms"))
        #expect(message.contains("track.setInstrument"))
    }

    @Test("a not-ready instance names its status: pending / missing / failed reason / untracked")
    func statusNamingErrors() async throws {
        let (router, store, engine) = makeSetup()
        engine.hosted = false
        let (trackID, effectID) = try addDelayInsert(store)
        let params: [String: JSONValue] = ["trackId": .string(trackID.uuidString),
                                           "effectId": .string(effectID.uuidString)]

        engine.effectStatus = .pending
        var response = await router.handle(ControlRequest(
            id: "1", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready (status: pending) — retry once prepared")

        engine.effectStatus = .missing
        response = await router.handle(ControlRequest(
            id: "2", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready (status: missing)")

        engine.effectStatus = .failed("component exploded")
        response = await router.handle(ControlRequest(
            id: "3", command: "au.setParam",
            params: params.merging(["address": .string("1"), "value": .number(0)]) { $1 }))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready (status: failed: component exploded)")

        engine.effectStatus = nil
        response = await router.handle(ControlRequest(
            id: "4", command: "au.describeParams", params: params))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready — the engine is not hosting this target yet (running headless, or the instance was just released)")

        // The instrument flavor reads the TRACK status seam.
        let instrumentTrack = try addAUInstrumentTrack(store)
        engine.instrumentStatus = .pending
        response = await router.handle(ControlRequest(
            id: "5", command: "au.describeParams",
            params: ["trackId": .string(instrumentTrack.uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "Audio Unit is not ready (status: pending) — retry once prepared")
    }
}
