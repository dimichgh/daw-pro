import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Minimal engine stub for the per-effect latency forwarders: everything is
/// inert except `effectLatencySamples`, which answers from a canned table —
/// pins the store→router→wire plumbing while DAWControl itself stays
/// engine-free (the real 240 @ 48 kHz is measured in DAWEngineTests).
@MainActor
final class StubLatencyEngine: AudioEngineControlling {
    var latencyByEffect: [UUID: Int] = [:]

    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?

    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    var recordPermission: RecordPermission { .granted }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}

    func effectLatencySamples(trackID: UUID, effectID: UUID) -> Int {
        latencyByEffect[effectID] ?? 0
    }
}

/// Control-protocol coverage for M4 (ii) FX insert chains: fx.add returning an
/// effectId, fx.setParam name validation and silent clamping, fx.describe's
/// schema shape, fx.reorder index clamping, and the resolved `effects` array on
/// the snapshot. Reuses `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("FX insert chains — control protocol")
struct FXCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, name: String, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "add-\(name)", command: "track.add",
            params: ["name": .string(name), "kind": .string(kind)]
        ))
        return UUID(uuidString: response.result?["id"]?.stringValue ?? "")!
    }

    private func addEffect(_ router: CommandRouter, trackID: UUID) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "fx-add", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("gain")]
        ))
        return UUID(uuidString: response.result?["effectId"]?.stringValue ?? "")!
    }

    @Test("fx.add returns an effectId and the resolved chain")
    func fxAddCommandReturnsEffectId() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("gain")]
        ))
        #expect(response.ok)
        let effectID = try #require(response.result?["effectId"]?.stringValue)
        #expect(UUID(uuidString: effectID) != nil)
        let effects = try #require(response.result?["effects"]?.arrayValue)
        #expect(effects.count == 1)
        #expect(effects.first?["id"]?.stringValue == effectID)
        #expect(effects.first?["kind"]?.stringValue == "gain")
        #expect(effects.first?["isBypassed"]?.boolValue == false)
        #expect(effects.first?["params"]?["gainLinear"]?.doubleValue == 1)
        // Headless (no engine injected): the latency forwarder reports 0.
        #expect(effects.first?["latencySamples"]?.doubleValue == 0)
    }

    @Test("per-effect latencySamples forwards the live engine value to the wire")
    func effectLatencyForwardsEngineValueToWire() async throws {
        let (router, store) = makeRouter()
        let engine = StubLatencyEngine()
        store.engine = engine
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let gainID = await addEffect(router, trackID: trackID)
        let limiterResponse = await router.handle(ControlRequest(
            id: "add-limiter", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("limiter")]
        ))
        let limiterID = try #require(
            UUID(uuidString: limiterResponse.result?["effectId"]?.stringValue ?? ""))
        // The engine reports the limiter's 5 ms lookahead (240 @ 48 kHz — the
        // real value is measured against the live chain in DAWEngineTests).
        engine.latencyByEffect = [limiterID: 240]

        // fx mutation results carry the forwarded per-effect value…
        let bypassResponse = await router.handle(ControlRequest(
            id: "1", command: "fx.setBypass",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(gainID.uuidString), "bypassed": .bool(false)]
        ))
        #expect(bypassResponse.ok)
        let effects = try #require(bypassResponse.result?["effects"]?.arrayValue)
        #expect(effects.first(where: { $0["id"]?.stringValue == gainID.uuidString })?[
            "latencySamples"]?.doubleValue == 0)
        #expect(effects.first(where: { $0["id"]?.stringValue == limiterID.uuidString })?[
            "latencySamples"]?.doubleValue == 240)

        // …and so does every project.snapshot.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        let snapshotEffects = try #require(vox["effects"]?.arrayValue)
        #expect(snapshotEffects.first(where: { $0["id"]?.stringValue == limiterID.uuidString })?[
            "latencySamples"]?.doubleValue == 240)
        #expect(snapshotEffects.first(where: { $0["id"]?.stringValue == gainID.uuidString })?[
            "latencySamples"]?.doubleValue == 0)
    }

    @Test("fx.setParam rejects an unknown parameter name with the exact error")
    func fxSetParamRejectsUnknownName() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "name": .string("bogus"), "value": .number(1)]
        ))
        #expect(!response.ok)
        #expect(response.error == "unknown parameter 'bogus' for gain effect — valid: gainLinear")
    }

    @Test("fx.setParam clamps an out-of-range value silently")
    func fxSetParamClampsValue() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "name": .string("gainLinear"), "value": .number(100)]
        ))
        #expect(response.ok)
        // gainLinear range is 0...4 — 100 clamps to 4.
        #expect(response.result?["effects"]?.arrayValue?.first?["params"]?["gainLinear"]?.doubleValue == 4)
    }

    @Test("fx.describe lists the gain schema from the spec table")
    func fxDescribeListsGainSchema() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["kind": .string("gain")]
        ))
        #expect(response.ok)
        let kinds = try #require(response.result?["kinds"]?.arrayValue)
        #expect(kinds.count == 1)
        let gain = try #require(kinds.first)
        #expect(gain["kind"]?.stringValue == "gain")
        let param = try #require(gain["params"]?.arrayValue?.first)
        #expect(param["name"]?.stringValue == "gainLinear")
        #expect(param["min"]?.doubleValue == 0)
        #expect(param["max"]?.doubleValue == 4)
        #expect(param["default"]?.doubleValue == 1)
        #expect(param["unit"]?.stringValue == "linear")
    }

    @Test("fx.describe lists all nine built-in kinds plus audioUnit with full schemas")
    func fxDescribeListsAllNineKinds() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "fx.describe"))
        #expect(response.ok)
        let kinds = try #require(response.result?["kinds"]?.arrayValue)
        #expect(kinds.compactMap { $0["kind"]?.stringValue }
                == ["gain", "eq", "compressor", "limiter",
                    "reverb", "delay", "saturator", "gate", "chorus", "audioUnit"])
        // AU params are not on the generic surface in v0 — empty schema.
        #expect(kinds.last?["params"]?.arrayValue?.isEmpty == true)

        func paramNames(_ kind: String) -> [String] {
            kinds.first(where: { $0["kind"]?.stringValue == kind })?["params"]?
                .arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        }
        #expect(paramNames("eq") == [
            "lowShelfFreq", "lowShelfGainDb",
            "peak1Freq", "peak1GainDb", "peak1Q",
            "peak2Freq", "peak2GainDb", "peak2Q",
            "highShelfFreq", "highShelfGainDb",
        ])
        #expect(paramNames("compressor") == [
            "thresholdDb", "ratio", "attackMs", "releaseMs", "kneeDb", "makeupDb",
        ])
        #expect(paramNames("limiter") == ["ceilingDb", "releaseMs"])
        #expect(paramNames("reverb") == ["roomSize", "damping", "mix", "preDelayMs", "width"])
        #expect(paramNames("delay") == ["timeMs", "feedback", "mix", "pingPong", "highCutHz"])
        #expect(paramNames("saturator") == ["driveDb", "mix", "outputDb"])
        #expect(paramNames("gate") == ["thresholdDb", "attackMs", "holdMs", "releaseMs"])
        #expect(paramNames("chorus") == ["rateHz", "depthMs", "mix"])

        // Spot-check schema fields per unit family.
        let eq = try #require(kinds.first(where: { $0["kind"]?.stringValue == "eq" }))
        let lowShelf = try #require(eq["params"]?.arrayValue?.first)
        #expect(lowShelf["min"]?.doubleValue == 20)
        #expect(lowShelf["max"]?.doubleValue == 2_000)
        #expect(lowShelf["default"]?.doubleValue == 100)
        #expect(lowShelf["unit"]?.stringValue == "Hz")
        let comp = try #require(kinds.first(where: { $0["kind"]?.stringValue == "compressor" }))
        let ratio = try #require(comp["params"]?.arrayValue?[1])
        #expect(ratio["unit"]?.stringValue == "ratio")
        #expect(ratio["min"]?.doubleValue == 1 && ratio["max"]?.doubleValue == 20)
        let limiter = try #require(kinds.first(where: { $0["kind"]?.stringValue == "limiter" }))
        let ceiling = try #require(limiter["params"]?.arrayValue?.first)
        #expect(ceiling["unit"]?.stringValue == "dB")
        #expect(ceiling["default"]?.doubleValue == -1)
    }

    @Test("fx.add + fx.setParam work for the new kinds; unknown kind lists all nine")
    func fxAddAndSetParamWorkForNewKinds() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        // fx.add with initial eq params: resolved wire params carry the boost.
        let addResponse = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("eq"),
                     "params": .object(["peak1GainDb": .number(12), "peak1Freq": .number(1_000)])]
        ))
        #expect(addResponse.ok)
        let effectID = try #require(addResponse.result?["effectId"]?.stringValue)
        let eqParams = try #require(addResponse.result?["effects"]?.arrayValue?.first?["params"])
        #expect(eqParams["peak1GainDb"]?.doubleValue == 12)
        #expect(eqParams["peak1Freq"]?.doubleValue == 1_000)
        #expect(eqParams["lowShelfFreq"]?.doubleValue == 100)  // resolved defaults emitted

        // fx.setParam on the eq clamps through the spec range (gain −24…+24).
        let setResponse = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("lowShelfGainDb"), "value": .number(-99)]
        ))
        #expect(setResponse.ok)
        #expect(setResponse.result?["effects"]?.arrayValue?.first?["params"]?["lowShelfGainDb"]?
            .doubleValue == -24)

        // Unknown kind error enumerates every kind (derived from Kind.allCases).
        let badKind = await router.handle(ControlRequest(
            id: "3", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("phaser")]
        ))
        #expect(!badKind.ok)
        #expect(badKind.error == "unknown effect kind 'phaser' — use "
                + "gain|eq|compressor|limiter|reverb|delay|saturator|gate|chorus|audioUnit")

        // The remaining kinds add and expose their resolved params on the wire.
        for (kind, expected) in [("compressor", "thresholdDb"), ("limiter", "ceilingDb"),
                                 ("reverb", "roomSize"), ("delay", "timeMs"),
                                 ("saturator", "driveDb"), ("gate", "thresholdDb"),
                                 ("chorus", "rateHz")] {
            let response = await router.handle(ControlRequest(
                id: "add-\(kind)", command: "fx.add",
                params: ["trackId": .string(trackID.uuidString), "kind": .string(kind)]
            ))
            #expect(response.ok)
            let effect = try #require(response.result?["effects"]?.arrayValue?.last)
            #expect(effect["kind"]?.stringValue == kind)
            #expect(effect["params"]?[expected]?.doubleValue != nil)
        }
    }

    @Test("fx.reorder clamps an out-of-range index to the tail")
    func fxReorderClampsIndex() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let a = await addEffect(router, trackID: trackID)
        let b = await addEffect(router, trackID: trackID)
        let c = await addEffect(router, trackID: trackID)

        // Move a to a wildly out-of-range index — it clamps to the last slot.
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.reorder",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(a.uuidString), "index": .number(999)]
        ))
        #expect(response.ok)
        let ids = response.result?["effects"]?.arrayValue?.compactMap { $0["id"]?.stringValue }
        #expect(ids == [b.uuidString, c.uuidString, a.uuidString])
    }

    @Test("project.snapshot carries the resolved effects array on every track")
    func snapshotCarriesEffectsArray() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)

        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        let tracks = try #require(response.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        let effects = try #require(vox["effects"]?.arrayValue)
        #expect(effects.count == 1)
        let fx = try #require(effects.first)
        #expect(fx["id"]?.stringValue == effectID.uuidString)
        #expect(fx["kind"]?.stringValue == "gain")
        #expect(fx["isBypassed"]?.boolValue == false)
        #expect(fx["params"]?["gainLinear"]?.doubleValue == 1)
        // Headless (no engine injected): the latency forwarder reports 0.
        #expect(fx["latencySamples"]?.doubleValue == 0)
    }
}
