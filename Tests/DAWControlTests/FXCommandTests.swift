import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Minimal engine stub for the per-effect latency + gain-reduction
/// forwarders: everything is inert except `effectLatencySamples` and the
/// m22-e `effectGainReductionDb` pair, which answer from canned tables —
/// pins the store→router→wire plumbing while DAWControl itself stays
/// engine-free (the real measurements live in DAWEngineTests).
@MainActor
final class StubLatencyEngine: AudioEngineControlling {
    var latencyByEffect: [UUID: Int] = [:]
    /// m22-e: nil (missing key) = this effect has no GR meter — the wire
    /// must OMIT `gainReductionDb`, never fabricate a 0.
    var gainReductionByEffect: [UUID: Double] = [:]
    var masterGainReductionByEffect: [UUID: Double] = [:]

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
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
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

    func effectGainReductionDb(trackID: UUID, effectID: UUID) -> Double? {
        gainReductionByEffect[effectID]
    }

    func masterEffectGainReductionDb(effectID: UUID) -> Double? {
        masterGainReductionByEffect[effectID]
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
        // Headless (no engine injected): the latency forwarder reports 0,
        // and the m22-e GR key is OMITTED — no engine means no live meter,
        // and a fabricated 0 would read like a resting one.
        #expect(effects.first?["latencySamples"]?.doubleValue == 0)
        #expect(effects.first?["gainReductionDb"] == nil)
    }

    @Test("per-effect gainReductionDb forwards the live engine value to the wire (m22-e)")
    func effectGainReductionForwardsEngineValueToWire() async throws {
        let (router, store) = makeRouter()
        let engine = StubLatencyEngine()
        store.engine = engine
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let gainID = await addEffect(router, trackID: trackID)  // kind gain: no GR meter
        let compResponse = await router.handle(ControlRequest(
            id: "add-comp", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("compressor")]
        ))
        let compID = try #require(
            UUID(uuidString: compResponse.result?["effectId"]?.stringValue ?? ""))
        // The engine reports 4.2 dB of live held-peak reduction for the
        // compressor and NOTHING for the gain insert (the real ballistics
        // are measured against the live effects in DAWEngineTests).
        engine.gainReductionByEffect = [compID: 4.2]

        // fx mutation results carry the additive per-effect field…
        let bypassResponse = await router.handle(ControlRequest(
            id: "1", command: "fx.setBypass",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(gainID.uuidString), "bypassed": .bool(false)]
        ))
        #expect(bypassResponse.ok)
        let effects = try #require(bypassResponse.result?["effects"]?.arrayValue)
        #expect(effects.first(where: { $0["id"]?.stringValue == compID.uuidString })?[
            "gainReductionDb"]?.doubleValue == 4.2)
        // …OMITTED (not 0) for kinds without a meter.
        #expect(effects.first(where: { $0["id"]?.stringValue == gainID.uuidString })?[
            "gainReductionDb"] == nil)

        // …and so does every project.snapshot (the meter/analysis poll path
        // agents already re-orient from).
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        let snapshotEffects = try #require(vox["effects"]?.arrayValue)
        #expect(snapshotEffects.first(where: { $0["id"]?.stringValue == compID.uuidString })?[
            "gainReductionDb"]?.doubleValue == 4.2)
        #expect(snapshotEffects.first(where: { $0["id"]?.stringValue == gainID.uuidString })?[
            "gainReductionDb"] == nil)
    }

    @Test("master-chain gainReductionDb rides masterEffects on results and snapshots (m22-e)")
    func masterEffectGainReductionForwardsToWire() async throws {
        let (router, store) = makeRouter()
        let engine = StubLatencyEngine()
        store.engine = engine
        let addResponse = await router.handle(ControlRequest(
            id: "add-master-limiter", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("limiter")]
        ))
        #expect(addResponse.ok)
        let limiterID = try #require(
            UUID(uuidString: addResponse.result?["effectId"]?.stringValue ?? ""))
        engine.masterGainReductionByEffect = [limiterID: 2.5]

        // Master fx mutation result (the masterFxResult shape)…
        let bypassResponse = await router.handle(ControlRequest(
            id: "1", command: "fx.setBypass",
            params: ["trackId": .string("master"),
                     "effectId": .string(limiterID.uuidString), "bypassed": .bool(false)]
        ))
        #expect(bypassResponse.ok)
        let effects = try #require(bypassResponse.result?["effects"]?.arrayValue)
        #expect(effects.first(where: { $0["id"]?.stringValue == limiterID.uuidString })?[
            "gainReductionDb"]?.doubleValue == 2.5)

        // …and the snapshot's top-level masterEffects.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let masterEffects = try #require(snapshot.result?["masterEffects"]?.arrayValue)
        #expect(masterEffects.first(where: { $0["id"]?.stringValue == limiterID.uuidString })?[
            "gainReductionDb"]?.doubleValue == 2.5)
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
        // m38-a: the sentence lists the WHOLE spec table, so it grew a name.
        #expect(response.error
            == "unknown parameter 'bogus' for gain effect — valid: gainLinear, invertPolarity")
    }

    @Test("fx.setParam clamps an out-of-range value — and SAYS SO (m27-c)")
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
        // gainLinear range is 0...16 (m27-c raised it from 0...4) — 100 clamps to 16.
        #expect(response.result?["effects"]?.arrayValue?.first?["params"]?["gainLinear"]?.doubleValue == 16)
        // m27-c: the clamp is no longer silent. Still `ok` — warning, not
        // rejection, because fx_set_param's shipped description promises
        // clamping rather than erroring.
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.count == 1)
        let sentence = try #require(warnings.first?.stringValue)
        #expect(sentence == "gainLinear was clamped to its maximum 16 — you asked for 100, "
                + "and this control accepts 0 to 16.")
    }

    @Test("m27-c: a value inside the range clamps nothing, so `warnings` is ABSENT")
    func fxSetParamInRangeCarriesNoWarnings() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)

        // 5.045 — the value the m27-c measurement needed, and one the OLD
        // 0...4 range would have clamped. It must pass through untouched AND
        // announce nothing: an always-present `warnings` key would read as a
        // warning on every ordinary call, which is how a field becomes noise.
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString),
                     "name": .string("gainLinear"), "value": .number(5.045)]
        ))
        #expect(response.ok)
        #expect(response.result?["effects"]?.arrayValue?.first?["params"]?["gainLinear"]?
            .doubleValue == 5.045)
        #expect(response.result?["warnings"] == nil)
    }

    @Test("m27-c: the clamp notice reaches the MASTER chain too, and names the minimum")
    func fxSetParamClampNoticeOnMasterChain() async throws {
        let (router, _) = makeRouter()
        let addResponse = await router.handle(ControlRequest(
            id: "add", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("gain")]
        ))
        let effectID = try #require(addResponse.result?["effectId"]?.stringValue)

        // Below the floor — the other side of the clamp, so the sentence
        // cannot be hard-coded to say "maximum".
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.setParam",
            params: ["trackId": .string("master"),
                     "effectId": .string(effectID),
                     "name": .string("gainLinear"), "value": .number(-3)]
        ))
        #expect(response.ok)
        #expect(response.result?["trackId"]?.stringValue == "master")
        let sentence = try #require(response.result?["warnings"]?.arrayValue?.first?.stringValue)
        #expect(sentence == "gainLinear was clamped to its minimum 0 — you asked for -3, "
                + "and this control accepts 0 to 16.")
    }

    @Test("m27-c: the notice is GENERIC — a clamped compressor ratio warns the same way")
    func fxSetParamClampNoticeIsNotGainSpecific() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Bus", kind: "audio")
        let addResponse = await router.handle(ControlRequest(
            id: "add", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("compressor")]
        ))
        let effectID = try #require(addResponse.result?["effectId"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("ratio"), "value": .number(999)]
        ))
        #expect(response.ok)
        let sentence = try #require(response.result?["warnings"]?.arrayValue?.first?.stringValue)
        #expect(sentence.hasPrefix("ratio was clamped to its maximum "))
        #expect(sentence.contains("you asked for 999"))
    }

    @Test("m27-c: fx.add's seeded params warn when they are clamped")
    func fxAddSeededParamsWarnOnClamp() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        // The natural one-call authoring path: add a gain insert already set
        // to a level. It clamps through the same store call fx.setParam uses,
        // so it had the same silent lie.
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("gain"),
                     "params": .object(["gainLinear": .number(40)])]
        ))
        #expect(response.ok)
        #expect(response.result?["effects"]?.arrayValue?.first?["params"]?["gainLinear"]?
            .doubleValue == 16)
        let sentence = try #require(response.result?["warnings"]?.arrayValue?.first?.stringValue)
        #expect(sentence.contains("gainLinear was clamped to its maximum 16"))

        // …and an in-range seed stays quiet.
        let quiet = await router.handle(ControlRequest(
            id: "2", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("gain"),
                     "params": .object(["gainLinear": .number(12)])]
        ))
        #expect(quiet.ok)
        #expect(quiet.result?["warnings"] == nil)
    }

    // MARK: - m38-a polarity: NO new command, NO new tool

    @Test("m38-a: polarity reaches the wire through the EXISTING fx verbs")
    func polarityRidesTheGenericParamSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Snare Btm", kind: "audio")

        // 1. fx.add SEEDS it — the one-call authoring path, no new verb.
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("gain"),
                     "params": .object(["gainLinear": .number(1),
                                        "invertPolarity": .number(1)])]
        ))
        #expect(added.ok)
        let seeded = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(seeded["invertPolarity"]?.doubleValue == 1)
        #expect(seeded["gainLinear"]?.doubleValue == 1)
        // An in-range binary seed clamps nothing, so it stays quiet.
        #expect(added.result?["warnings"] == nil)
        let effectID = try #require(added.result?["effectId"]?.stringValue)

        // 2. fx.setParam RIDES it — same generic name/value surface.
        let off = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("invertPolarity"), "value": .number(0)]
        ))
        #expect(off.ok)
        #expect(off.result?["effects"]?.arrayValue?.first?["params"]?["invertPolarity"]?
            .doubleValue == 0)

        // 3. …and setting the GAIN does not disarm it (the read-modify-write).
        _ = await router.handle(ControlRequest(
            id: "3", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("invertPolarity"), "value": .number(1)]
        ))
        let gained = await router.handle(ControlRequest(
            id: "4", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("gainLinear"), "value": .number(2)]
        ))
        let params = try #require(gained.result?["effects"]?.arrayValue?.first?["params"])
        #expect(params["gainLinear"]?.doubleValue == 2)
        #expect(params["invertPolarity"]?.doubleValue == 1)

        // 4. project.snapshot reports it through the SAME effectParamsJSON.
        let snapshot = await router.handle(ControlRequest(id: "5", command: "project.snapshot"))
        let track = try #require(snapshot.result?["tracks"]?.arrayValue?
            .first { $0["id"]?.stringValue == trackID.uuidString })
        let snapFX = try #require(track["effects"]?.arrayValue?.first?["params"])
        #expect(snapFX["invertPolarity"]?.doubleValue == 1)
    }

    @Test("m38-a: fx.describe reports invertPolarity with its type and default")
    func fxDescribeReportsPolarity() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["kind": .string("gain")]
        ))
        #expect(response.ok)
        let specs = try #require(response.result?["kinds"]?.arrayValue?.first?["params"]?
            .arrayValue)
        // APPENDED: gainLinear keeps automation slot 0.
        #expect(specs.count == 2)
        #expect(specs.first?["name"]?.stringValue == "gainLinear")
        let polarity = try #require(specs.last)
        #expect(polarity["name"]?.stringValue == "invertPolarity")
        #expect(polarity["min"]?.doubleValue == 0)
        #expect(polarity["max"]?.doubleValue == 1)
        #expect(polarity["default"]?.doubleValue == 0)
        #expect(polarity["unit"]?.stringValue == "linear")
        // The note is the ONE home for what a bare 0…1 cannot carry: this is
        // the Ø switch, it is binary, and it is what a null test needs.
        let note = try #require(polarity["note"]?.stringValue)
        #expect(note.contains("null"))
        #expect(note.contains("0.5"))
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
        #expect(param["max"]?.doubleValue == 16)   // m27-c: raised from 4
        #expect(param["default"]?.doubleValue == 1)
        #expect(param["unit"]?.stringValue == "linear")
        // m27-c: the ceiling is only half the fix — `note` is the ONE home
        // that teaches why it is that wide and what it costs, and every
        // client reads it through this verb.
        let note = try #require(param["note"]?.stringValue)
        #expect(note.contains("+24.08 dB"))
        #expect(note.contains("clipping"))
        #expect(note.contains("warnings"))
    }

    // m23-n2h: `fx.describe` used to be one of 26 verbs that never called
    // `rejectUnknownKeys` at all — an unknown key was silently ignored. The
    // allowed set is exactly {kind}; both the omit-kind and valid-kind
    // success paths are already pinned above/below, so this only needs the
    // rejection pin.
    @Test("fx.describe rejects an unknown param")
    func fxDescribeRejectsUnknownParam() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error == "fx.describe: unknown parameter 'bogus' — valid keys are 'kind'")
    }

    /// The count in this name is DELIBERATELY absent: it used to say "nine",
    /// and m23-p1's tenth built-in made the name lie while the body still
    /// passed. The expectation below is the list itself — read that, not a
    /// number in a title.
    @Test("fx.describe lists every built-in kind plus audioUnit with full schemas")
    func fxDescribeListsEveryBuiltInKind() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "fx.describe"))
        #expect(response.ok)
        let kinds = try #require(response.result?["kinds"]?.arrayValue)
        #expect(kinds.compactMap { $0["kind"]?.stringValue }
                == ["gain", "eq", "compressor", "limiter",
                    "reverb", "delay", "saturator", "gate", "chorus", "bassEnhancer",
                    "bitCrusher", "audioUnit"])
        // AU params are not on the generic surface in v0 — empty schema.
        #expect(kinds.last?["params"]?.arrayValue?.isEmpty == true)

        func paramNames(_ kind: String) -> [String] {
            kinds.first(where: { $0["kind"]?.stringValue == kind })?["params"]?
                .arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        }
        // The ten legacy params stay in slots 0…9 (automation slot stability);
        // the m22-a EQ v2 params are APPENDED.
        #expect(paramNames("eq") == [
            "lowShelfFreq", "lowShelfGainDb",
            "peak1Freq", "peak1GainDb", "peak1Q",
            "peak2Freq", "peak2GainDb", "peak2Q",
            "highShelfFreq", "highShelfGainDb",
            "highPassFreq", "highPassSlopeDbPerOct", "highPassEnabled",
            "lowShelfQ", "lowShelfEnabled", "peak1Enabled", "peak2Enabled",
            "highShelfQ", "highShelfEnabled",
            "lowPassFreq", "lowPassSlopeDbPerOct", "lowPassEnabled",
        ])
        // m23-ck appends mix in slot 6 — the six original params keep 0…5.
        #expect(paramNames("compressor") == [
            "thresholdDb", "ratio", "attackMs", "releaseMs", "kneeDb", "makeupDb", "mix",
        ])
        // m23-ch appends truePeak in slot 2 — ceilingDb/releaseMs keep 0/1.
        #expect(paramNames("limiter") == ["ceilingDb", "releaseMs", "truePeak"])
        #expect(paramNames("reverb") == ["roomSize", "damping", "mix", "preDelayMs", "width"])
        // The five legacy params stay in slots 0…4 (automation slot
        // stability); the m22-f tempo-sync params are APPENDED.
        #expect(paramNames("delay") == ["timeMs", "feedback", "mix", "pingPong", "highCutHz",
                                        "sync", "division"])
        #expect(paramNames("saturator") == ["driveDb", "mix", "outputDb"])
        #expect(paramNames("gate") == ["thresholdDb", "attackMs", "holdMs", "releaseMs"])
        #expect(paramNames("chorus") == ["rateHz", "depthMs", "mix"])
        // m32-e: the two boolean switches ride the numeric surface as 0/1 (the
        // truePeak precedent), so an agent never has to guess a type.
        #expect(paramNames("bitCrusher")
                == ["bits", "downsampleHz", "antiAlias", "dither", "mix"])

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

        // m22-a: the v2 EQ params teach their hidden semantics via `note`;
        // legacy params carry none (the key is omitted, additive shape).
        let eqParams = try #require(eq["params"]?.arrayValue)
        let hpFreq = try #require(eqParams.first { $0["name"]?.stringValue == "highPassFreq" })
        #expect(hpFreq["min"]?.doubleValue == 20)
        #expect(hpFreq["max"]?.doubleValue == 1_000)
        #expect(hpFreq["unit"]?.stringValue == "Hz")
        #expect(hpFreq["note"]?.stringValue?.contains("OFF") == true)
        let hpSlope = try #require(
            eqParams.first { $0["name"]?.stringValue == "highPassSlopeDbPerOct" })
        #expect(hpSlope["min"]?.doubleValue == 12 && hpSlope["max"]?.doubleValue == 24)
        #expect(hpSlope["unit"]?.stringValue == "dB/oct")
        #expect(hpSlope["note"]?.stringValue?.contains("12 or 24") == true)
        let lpFreq = try #require(eqParams.first { $0["name"]?.stringValue == "lowPassFreq" })
        #expect(lpFreq["min"]?.doubleValue == 1_000 && lpFreq["max"]?.doubleValue == 20_000)
        let shelfQ = try #require(eqParams.first { $0["name"]?.stringValue == "lowShelfQ" })
        #expect(shelfQ["default"]?.doubleValue == 0.7071067811865476)
        let bandOn = try #require(eqParams.first { $0["name"]?.stringValue == "peak1Enabled" })
        #expect(bandOn["min"]?.doubleValue == 0 && bandOn["max"]?.doubleValue == 1)
        #expect(bandOn["default"]?.doubleValue == 1)
        #expect(bandOn["note"]?.stringValue?.contains("bypasses") == true)
        #expect(lowShelf["note"] == nil)  // legacy params: note omitted
    }

    @Test("fx.setParam drives the EQ v2 params: activation, snap, bypass, resolved echo")
    func fxSetParamDrivesEQv2() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let addResponse = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("eq")]))
        let effectID = try #require(addResponse.result?["effectId"]?.stringValue)

        func setParam(_ name: String, _ value: Double) async -> JSONValue? {
            let response = await router.handle(ControlRequest(
                id: "set-\(name)", command: "fx.setParam",
                params: ["trackId": .string(trackID.uuidString),
                         "effectId": .string(effectID),
                         "name": .string(name), "value": .number(value)]))
            #expect(response.ok)
            return response.result?["effects"]?.arrayValue?.first?["params"]
        }

        // Fresh EQ: the resolved wire params show HP/LP off at the range edges.
        let fresh = try #require(addResponse.result?["effects"]?.arrayValue?.first?["params"])
        #expect(fresh["highPassEnabled"]?.doubleValue == 0)
        #expect(fresh["highPassFreq"]?.doubleValue == 20)
        #expect(fresh["lowPassEnabled"]?.doubleValue == 0)
        #expect(fresh["lowPassFreq"]?.doubleValue == 20_000)
        #expect(fresh["lowShelfQ"]?.doubleValue == 0.7071067811865476)
        #expect(fresh["peak1Enabled"]?.doubleValue == 1)

        // Setting a corner ACTIVATES the filter; the echo is resolved.
        let afterFreq = try #require(await setParam("highPassFreq", 150))
        #expect(afterFreq["highPassFreq"]?.doubleValue == 150)
        #expect(afterFreq["highPassEnabled"]?.doubleValue == 1)

        // Slope snaps to 12/24 through the numeric wire.
        let afterSlope = try #require(await setParam("highPassSlopeDbPerOct", 19))
        #expect(afterSlope["highPassSlopeDbPerOct"]?.doubleValue == 24)

        // Bypass keeps the corner; the resolved enabled flag reads 0.
        let afterBypass = try #require(await setParam("highPassEnabled", 0))
        #expect(afterBypass["highPassEnabled"]?.doubleValue == 0)
        #expect(afterBypass["highPassFreq"]?.doubleValue == 150)

        // Per-band bypass + shelf Q ride the same generic path.
        let afterBand = try #require(await setParam("highShelfEnabled", 0))
        #expect(afterBand["highShelfEnabled"]?.doubleValue == 0)
        let afterQ = try #require(await setParam("highShelfQ", 1.4))
        #expect(afterQ["highShelfQ"]?.doubleValue == 1.4)

        // Out-of-range corners clamp silently (the spec-range rule).
        let clamped = try #require(await setParam("lowPassFreq", 100))
        #expect(clamped["lowPassFreq"]?.doubleValue == 1_000)
        #expect(clamped["lowPassEnabled"]?.doubleValue == 1)  // setting it activated it
    }

    // Name carries no count on purpose — see fxDescribeListsEveryBuiltInKind.
    @Test("fx.add + fx.setParam work for the new kinds; unknown kind lists every kind")
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
                + "gain|eq|compressor|limiter|reverb|delay|saturator|gate|chorus|"
                + "bassEnhancer|bitCrusher|audioUnit")

        // The remaining kinds add and expose their resolved params on the wire.
        for (kind, expected) in [("compressor", "thresholdDb"), ("limiter", "ceilingDb"),
                                 ("reverb", "roomSize"), ("delay", "timeMs"),
                                 ("saturator", "driveDb"), ("gate", "thresholdDb"),
                                 ("chorus", "rateHz"), ("bassEnhancer", "crossoverHz"),
                                 ("bitCrusher", "bits")] {
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

    // Regression (m12-f): the snapshot serializer never surfaced the
    // sidechain key — an agent reading project.snapshot saw a keyed gate as
    // unkeyed. Keyed effects carry `sidechainSourceTrackId`; unkeyed omit it.
    @Test("snapshot surfaces sidechainSourceTrackId on keyed effects only")
    func snapshotCarriesSidechainKey() async throws {
        let (router, store) = makeRouter()
        let kickID = await addTrack(router, name: "Kick", kind: "audio")
        let padID = await addTrack(router, name: "Pad", kind: "audio")
        let gateResponse = await router.handle(ControlRequest(
            id: "add-gate", command: "fx.add",
            params: ["trackId": .string(padID.uuidString), "kind": .string("gate")]
        ))
        let gateID = try #require(
            UUID(uuidString: gateResponse.result?["effectId"]?.stringValue ?? ""))
        _ = try store.setSidechain(trackID: padID, effectID: gateID, sourceTrackID: kickID)

        let snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let pad = try #require(tracks.first(where: { $0["id"]?.stringValue == padID.uuidString }))
        let keyed = try #require(pad["effects"]?.arrayValue?.first)
        #expect(keyed["sidechainSourceTrackId"]?.stringValue == kickID.uuidString)

        // Clearing the key removes the field entirely (omit-when-nil).
        _ = try store.setSidechain(trackID: padID, effectID: gateID, sourceTrackID: nil)
        let snapshot2 = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks2 = try #require(snapshot2.result?["tracks"]?.arrayValue)
        let pad2 = try #require(tracks2.first(where: { $0["id"]?.stringValue == padID.uuidString }))
        let cleared = try #require(pad2["effects"]?.arrayValue?.first)
        #expect(cleared["sidechainSourceTrackId"] == nil)
    }

    // MARK: - m22-f delay tempo sync (additive params, zero new commands)

    @Test("fx.describe teaches the delay's sync + division semantics (m22-f)")
    func fxDescribeTeachesDelayTempoSync() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["kind": .string("delay")]))
        #expect(response.ok)
        let params = try #require(response.result?["kinds"]?.arrayValue?.first?["params"]?
            .arrayValue)

        let sync = try #require(params.first { $0["name"]?.stringValue == "sync" })
        #expect(sync["min"]?.doubleValue == 0 && sync["max"]?.doubleValue == 1)
        #expect(sync["default"]?.doubleValue == 0)
        #expect(sync["unit"]?.stringValue == "linear")
        #expect(sync["note"]?.stringValue?.contains("tempo") == true)
        #expect(sync["note"]?.stringValue?.contains("Not automatable") == true)

        let division = try #require(params.first { $0["name"]?.stringValue == "division" })
        #expect(division["unit"]?.stringValue == "beats")
        #expect(division["default"]?.doubleValue == 1)  // 1 beat = 1/4
        // Bounds are the enum's own beat lengths: 1/32t … 1/1d.
        #expect(division["min"]?.doubleValue == NoteDivision.thirtySecondTriplet.beats)
        #expect(division["max"]?.doubleValue == 6)
        let note = try #require(division["note"]?.stringValue)
        #expect(note.contains("1/8d") && note.contains("triplet") && note.contains("dotted"))
        #expect(note.contains("Not automatable"))

        // timeMs teaches the sync interaction (the derived-time formula).
        let timeMs = try #require(params.first { $0["name"]?.stringValue == "timeMs" })
        #expect(timeMs["note"]?.stringValue?.contains("division × 60000") == true)
    }

    @Test("delay sync/division ride fx.add + fx.setParam; the echo resolves tokens (m22-f)")
    func delayTempoSyncParamsRoundTripOnTheWire() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Wet", kind: "audio")

        // A fresh delay reads the resolved defaults: unsynced, 1/4.
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("delay")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let fresh = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(fresh["sync"]?.doubleValue == 0)
        #expect(fresh["division"]?.doubleValue == 1)
        #expect(fresh["divisionLabel"]?.stringValue == "1/4")

        // fx.setParam picks the new names up through the existing path.
        _ = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("sync"), "value": .number(1)]))
        // 0.7 beats snaps to the NEAREST division: 1/4t (0.6667), not 1/8d.
        let snapped = await router.handle(ControlRequest(
            id: "3", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("division"), "value": .number(0.7)]))
        #expect(snapped.ok)
        let params = try #require(snapped.result?["effects"]?.arrayValue?.first?["params"])
        #expect(params["sync"]?.doubleValue == 1)
        #expect(params["division"]?.doubleValue == NoteDivision.quarterTriplet.beats)
        #expect(params["divisionLabel"]?.stringValue == "1/4t")
        // The stored fallback never moves on the wire: timeMs stays put.
        #expect(params["timeMs"]?.doubleValue == 350)

        // fx.add accepts them as initial params too (numeric-only surface).
        let master = await router.handle(ControlRequest(
            id: "4", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("delay"),
                     "params": .object(["sync": .number(1), "division": .number(0.75)])]))
        #expect(master.ok)
        let masterParams = try #require(master.result?["effects"]?.arrayValue?.first?["params"])
        #expect(masterParams["sync"]?.doubleValue == 1)
        #expect(masterParams["divisionLabel"]?.stringValue == "1/8d")
    }
}
