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
                    "bitCrusher", "djFilter", "ringMod", "flanger", "hallReverb",
                    "tapeDelay", "stereoWidth", "audioUnit"])
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

        // m39-a MCP close (2026-09-19): `curve` rides every paramObj now,
        // additively — an agent driving `lowShelfFreq`/EQ frequencies needs
        // to know the travel is logarithmic (even steps in OCTAVES), not
        // linear-Hz, or a computed sweep buries the low half of the range in
        // its first tenth.
        #expect(lowShelf["curve"]?.stringValue == "logarithmic")  // lowShelfFreq
        #expect(hpFreq["curve"]?.stringValue == "logarithmic")
        #expect(lpFreq["curve"]?.stringValue == "logarithmic")
        #expect(ratio["curve"]?.stringValue == "linear")
        #expect(ceiling["curve"]?.stringValue == "linear")
        #expect(hpSlope["curve"]?.stringValue == "linear")  // dB/oct, not Hz
        // Pin the claim ACROSS KINDS, not just EQ — `ParamCurveConformanceTests`
        // proves every Hz-unit param in the whole tree is logarithmic (and vice
        // versa); this wire-level check confirms that declaration actually
        // reaches `fx.describe`'s payload for a non-EQ kind too.
        let delay = try #require(kinds.first(where: { $0["kind"]?.stringValue == "delay" }))
        let highCutHz = try #require(
            delay["params"]?.arrayValue?.first { $0["name"]?.stringValue == "highCutHz" })
        #expect(highCutHz["unit"]?.stringValue == "Hz")
        #expect(highCutHz["curve"]?.stringValue == "logarithmic")
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
                + "bassEnhancer|bitCrusher|djFilter|ringMod|flanger|hallReverb|tapeDelay|"
                + "stereoWidth|audioUnit")

        // Every kind adds and exposes its resolved params on the wire.
        //
        // ⭐⭐ THIS IS A CENSUS, NOT A LIST — and it was a list until 2026-09-19,
        // when `.tapeDelay` was found missing from it. A hand-maintained array
        // READS like "every kind is covered" while silently omitting whichever
        // one nobody remembered to append: this tree's named characteristic
        // failure, in a test whose whole job is to prevent it.
        //
        // The fix is structural. `Kind.allCases` drives the loop, and a kind
        // with no entry in `expectedParam` FAILS here rather than being skipped,
        // so adding a kind without adding its probe cannot go unnoticed.
        // `audioUnit` is excluded deliberately — it hosts a third-party plugin
        // and has no param surface of our own to assert.
        let expectedParam: [String: String] = [
            "gain": "gainLinear", "eq": "peak1Freq", "compressor": "thresholdDb",
            "limiter": "ceilingDb", "reverb": "roomSize", "delay": "timeMs",
            "saturator": "driveDb", "gate": "thresholdDb", "chorus": "rateHz",
            "bassEnhancer": "crossoverHz", "bitCrusher": "bits", "djFilter": "position",
            "ringMod": "carrierHz", "flanger": "rateHz", "hallReverb": "sizeMeters",
            "tapeDelay": "timeMs", "stereoWidth": "width",
        ]
        let censusKinds = EffectDescriptor.Kind.allCases
            .map(\.rawValue)
            .filter { $0 != "audioUnit" }
        // Non-vacuity: if `allCases` ever stops enumerating, the loop below would
        // pass by doing nothing at all.
        #expect(censusKinds.count >= 17)
        let uncovered = censusKinds.filter { expectedParam[$0] == nil }
        #expect(uncovered.isEmpty, "kinds with no entry in this census: \(uncovered) — add one rather than widening the filter; a kind with no wire probe is how a param surface ships untested")
        // ⚠️ ONE FRESH TRACK PER KIND. The census is 17 kinds and a track holds
        // at most 16 effects, so piling them onto `trackID` makes the LAST kinds
        // fail with "effect chain is full" — which is a cap artifact, not a wire
        // defect, and would be read as one. (Measured: this is exactly what
        // happened when the census first replaced the hand-written list.)
        for kind in censusKinds {
            guard let expected = expectedParam[kind] else { continue }
            let kindTrack = await addTrack(router, name: "census-\(kind)", kind: "audio")
            let response = await router.handle(ControlRequest(
                id: "add-\(kind)", command: "fx.add",
                params: ["trackId": .string(kindTrack.uuidString), "kind": .string(kind)]
            ))
            #expect(response.ok)
            let effect = try #require(response.result?["effects"]?.arrayValue?.last)
            #expect(effect["kind"]?.stringValue == kind)
            #expect(effect["params"]?[expected]?.doubleValue != nil)
        }
    }

    /// m39-l — §12 gate 6, the DESCRIBE/SETTABLE BIJECTION, as a BEHAVIOURAL
    /// gate rather than a source-shape one. `.hallReverb` has FOURTEEN params
    /// and they are declared in `EffectParamSpec.specs` but ACCEPTED by a
    /// hand-written `switch` in `ProjectStore.applyEffectParam` — two lists,
    /// no compiler connection. A param present in one and missing from the
    /// other is exactly this tree's named characteristic failure: the record
    /// says X, the source says Y, and nothing compares them.
    ///
    /// ⭐ The comparison is made through the RUNNING ROUTER, not by reading
    /// source: every declared name is SET and read back, and the refusal
    /// message for a bogus name is parsed to prove the accepted set is not
    /// larger either. A test that greps cannot catch a divergence between what
    /// the source declares and what the running app does.
    @Test("m39-l: every declared hallReverb param is settable, and no undeclared one is")
    func hallReverbDescribeAndSetAgree() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Strings", kind: "audio")
        let addResponse = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("hallReverb")]
        ))
        #expect(addResponse.ok)
        let effectID = try #require(addResponse.result?["effectId"]?.stringValue)

        let declared = EffectParamSpec.specs(for: .hallReverb)
        #expect(declared.count == 14)

        // → every DECLARED name is accepted, takes a value, and reads back.
        for (index, spec) in declared.enumerated() {
            // A value inside the range that is NOT the default, so "it took"
            // cannot be confused with "it was already there".
            let value = spec.range.lowerBound
                + (spec.range.upperBound - spec.range.lowerBound) * 0.37
            let response = await router.handle(ControlRequest(
                id: "set-\(index)", command: "fx.setParam",
                params: ["trackId": .string(trackID.uuidString),
                         "effectId": .string(effectID),
                         "name": .string(spec.name), "value": .number(value)]
            ))
            #expect(response.ok, "fx.setParam refused the declared name '\(spec.name)'")
            let echoed = response.result?["effects"]?.arrayValue?.first?["params"]?[spec.name]?
                .doubleValue
            #expect(echoed != nil, "'\(spec.name)' is declared but absent from the wire echo")
            #expect(abs((echoed ?? .nan) - value) < 1e-9,
                    "'\(spec.name)' echoed \(echoed ?? .nan), not the \(value) that was set")
        }

        // → and the accepted set is NO LARGER: the refusal message lists it.
        let bogus = await router.handle(ControlRequest(
            id: "bogus", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("roomSize"), "value": .number(0.5)]
        ))
        #expect(!bogus.ok, "`roomSize` belongs to the OTHER reverb kind and must be refused")
        let message = try #require(bogus.error)
        let expectedMessage = "unknown parameter 'roomSize' for hallReverb effect — valid: "
            + declared.map(\.name).joined(separator: ", ")
        #expect(message == expectedMessage,
                "the refusal message and the spec table disagree: \(message)")

        // → and `fx.describe` reports the SAME fourteen, in the SAME order.
        let describe = await router.handle(ControlRequest(
            id: "describe", command: "fx.describe",
            params: ["kind": .string("hallReverb")]
        ))
        #expect(describe.ok)
        let described = describe.result?["kinds"]?.arrayValue?.first?["params"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue }
        #expect(described == declared.map(\.name), """
                fx.describe reports \(described ?? []) but the spec table says \
                \(declared.map(\.name))
                """)

        // → the two ADDITIVE human echoes are present and correct, read
        // through the one home rather than re-derived here.
        let snapshot = await router.handle(ControlRequest(
            id: "snap", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("sizeMeters"), "value": .number(24)]
        ))
        #expect(snapshot.ok)
        let params = try #require(snapshot.result?["effects"]?.arrayValue?.first?["params"])
        #expect(params["freezeOn"]?.boolValue != nil, "freezeOn is missing from the echo")
        let arrival = try #require(params["firstArrivalMs"]?.doubleValue)
        let preDelay = try #require(params["preDelayMs"]?.doubleValue)
        let expected = HallReverbParams.firstArrivalSeconds(sizeMeters: 24,
                                                            preDelayMs: preDelay) * 1_000
        #expect(abs(arrival - expected) < 1e-6,
                "firstArrivalMs \(arrival) is not the closed form \(expected)")
    }

    /// m39-i — the `.djFilter` kind end-to-end on the wire. The point that is
    /// NOT obvious and is worth a test rather than an assumption: this kind
    /// ships **ZERO new commands** (design rule 6.0.11). It rides `fx.add` /
    /// `fx.setParam` / `fx.describe` exactly like every other built-in, which
    /// is why `doc-count-drift` must read the SAME command total after this
    /// item as before it.
    @Test("m39-i: djFilter rides the generic fx verbs — defaults, clamping, slope snap, master")
    func djFilterRidesTheGenericFXSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Sweep", kind: "audio")

        // A fresh insert echoes the frozen defaults — a dry, 24 dB/oct filter
        // with a detent. `position: 0` is the bit-exact bypass.
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("djFilter")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let defaults = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(defaults["position"]?.doubleValue == 0)
        #expect(defaults["resonance"]?.doubleValue == 0.25)
        #expect(defaults["slopeDbPerOct"]?.doubleValue == 24)
        #expect(defaults["deadZoneWidth"]?.doubleValue == 0.04)
        #expect(defaults["resonanceTrack"]?.doubleValue == 0)

        // The bipolar range clamps at BOTH ends and says so in `warnings` —
        // the clamp-and-warn contract, checked on the negative end because a
        // naive `max(0, …)` clamp would pass a positive-only check.
        let clamped = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("position"), "value": .number(-9)]))
        #expect(clamped.ok)
        #expect(clamped.result?["effects"]?.arrayValue?.first?["params"]?["position"]?
            .doubleValue == -1)
        #expect(clamped.result?["warnings"]?.arrayValue?.isEmpty == false)

        // 17 dB/oct is not a slope this filter has. It SNAPS to 12 (nearer),
        // and the wire reports the snapped value rather than the request — the
        // `eq` slope precedent, and the difference between "accepted" and
        // "applied".
        let snapped = await router.handle(ControlRequest(
            id: "3", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("slopeDbPerOct"), "value": .number(17)]))
        #expect(snapped.ok)
        #expect(snapped.result?["effects"]?.arrayValue?.first?["params"]?["slopeDbPerOct"]?
            .doubleValue == 12)

        // An unknown param name is refused, not silently ignored.
        let unknown = await router.handle(ControlRequest(
            id: "4", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("cutoffHz"), "value": .number(500)]))
        #expect(!unknown.ok)

        // And it is legal on the master chain (a built-in kind, so the
        // built-ins-only rule admits it).
        let master = await router.handle(ControlRequest(
            id: "5", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("djFilter"),
                     "params": .object(["position": .number(0.4)])]))
        #expect(master.ok)
        #expect(master.result?["effects"]?.arrayValue?.first?["params"]?["position"]?
            .doubleValue == 0.4)
    }

    /// m39-m — the `.ringMod` kind end-to-end on the wire, and the same
    /// ZERO-NEW-COMMANDS contract (design rule 6.0.11). What is NOT obvious
    /// here and is therefore tested rather than assumed: `waveform` is a
    /// numeric-but-DISCRETE param, so the wire must report the SNAPPED index
    /// rather than the 1.7 the caller sent, and it carries an additive
    /// `waveformLabel` echo so an agent never keeps its own copy of the
    /// 0/1/2/3 mapping (the `delay.divisionLabel` precedent).
    @Test("m39-m: ringMod rides the generic fx verbs — defaults, clamping, waveform snap, master")
    func ringModRidesTheGenericFXSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Clang", kind: "audio")

        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("ringMod")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let defaults = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(defaults["carrierHz"]?.doubleValue == 440)
        #expect(defaults["mix"]?.doubleValue == 0.5)
        #expect(defaults["waveform"]?.doubleValue == 0)
        #expect(defaults["waveformLabel"]?.stringValue == "Sine")
        #expect(defaults["inputHighCutHz"]?.doubleValue == 20_000)
        #expect(defaults["stereoSpreadDeg"]?.doubleValue == 0)

        // Clamp-and-warn at the LOW end of a logarithmic range — a range whose
        // floor is 0.5, where a naive `max(0, …)` guard would pass silently.
        let clamped = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("carrierHz"), "value": .number(0.01)]))
        #expect(clamped.ok)
        #expect(clamped.result?["effects"]?.arrayValue?.first?["params"]?["carrierHz"]?
            .doubleValue == 0.5)
        #expect(clamped.result?["warnings"]?.arrayValue?.isEmpty == false)

        // 1.7 is not a waveform. It SNAPS to 2 (square) and the wire reports
        // the snapped value AND its label — the difference between "accepted"
        // and "applied".
        let snapped = await router.handle(ControlRequest(
            id: "3", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("waveform"), "value": .number(1.7)]))
        #expect(snapped.ok)
        let snappedParams = try #require(
            snapped.result?["effects"]?.arrayValue?.first?["params"])
        #expect(snappedParams["waveform"]?.doubleValue == 2)
        #expect(snappedParams["waveformLabel"]?.stringValue == "Square")
        // ⚠️ AND THE OTHER FIELDS SURVIVED THE SNAP. `waveform` is applied by
        // REBUILDING the params through the clamping init, which is exactly
        // the shape that drops every other field if the rebuild is incomplete.
        #expect(snappedParams["carrierHz"]?.doubleValue == 0.5)

        // An unknown param name is refused, not silently ignored.
        let unknown = await router.handle(ControlRequest(
            id: "4", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("depth"), "value": .number(0.5)]))
        #expect(!unknown.ok)

        // And it is legal on the master chain (a built-in kind).
        let master = await router.handle(ControlRequest(
            id: "5", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("ringMod"),
                     "params": .object(["carrierHz": .number(80), "mix": .number(0.3)])]))
        #expect(master.ok)
        #expect(master.result?["effects"]?.arrayValue?.first?["params"]?["carrierHz"]?
            .doubleValue == 80)
    }

    /// The teaching text is part of the capability. For a ring modulator the
    /// two things an agent CANNOT infer are where the sidebands land and that
    /// the fold-back is deliberate — without the second, an agent hearing
    /// clangorous tones will "fix" the effect's defining character.
    @Test("m39-m: fx.describe teaches the ringMod surface — slots, curves, the fold-back note")
    func ringModDescribeCarriesItsTeaching() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["kind": .string("ringMod")]))
        #expect(response.ok)
        let params = try #require(response.result?["kinds"]?.arrayValue?.first?["params"]?
            .arrayValue)
        #expect(params.compactMap { $0["name"]?.stringValue }
                == ["carrierHz", "mix", "waveform", "inputHighCutHz", "stereoSpreadDeg"])
        // Both frequency params take the multiplicative taper; the rest do not.
        #expect(params[0]["curve"]?.stringValue == "logarithmic")
        #expect(params[3]["curve"]?.stringValue == "logarithmic")
        #expect(params[1]["curve"]?.stringValue == "linear")
        #expect(params[4]["curve"]?.stringValue == "linear")
        // THE law: what a ring modulator actually produces.
        let carrierNote = try #require(params[0]["note"]?.stringValue)
        #expect(carrierNote.contains("|f - carrier|"),
                "the sideband law is not in the note text")
        #expect(carrierNote.contains("f + carrier"))
        // ⚠️ §6.4.2's required sentence, in words a novice can act on: the
        // fold-back is the sound, and here is the knob for less of it.
        let cutNote = try #require(params[3]["note"]?.stringValue)
        #expect(cutNote.contains("FOLDS BACK"))
        #expect(cutNote.contains("4000"),
                "the note does not name an actionable value for a cleaner result")
        // And the non-obvious tremolo fact, which is the first thing a user
        // trying a 2 Hz carrier will otherwise report as a bug. ⚠️ The rate
        // depends on `mix` — MEASURED in `RingModTests` L4f after an earlier
        // draft of this note asserted the doubled rate unconditionally and the
        // rendered demo read 2.00 Hz at the default mix.
        #expect(carrierNote.contains("TREMOLO"))
        #expect(carrierNote.contains("DOUBLED pulse"))
        #expect(carrierNote.contains("at mix 0.5 (the default) or lower it pulses at the carrier rate"))
    }

    /// m39-j — the `.flanger` kind end-to-end on the wire, and the same
    /// ZERO-NEW-COMMANDS contract (design rule 6.0.11). What is NOT obvious
    /// here and is therefore tested rather than assumed: `feedback` is the
    /// only built-in param whose range CROSSES ZERO, so the wire has to carry
    /// a negative value intact in both directions — and the params object
    /// carries an additive `firstNotchHzAtSweepFloor` echo so an agent never
    /// keeps its own copy of the 1/(2·delay) law (the `waveformLabel` /
    /// `divisionLabel` precedent).
    @Test("m39-j: flanger rides the generic fx verbs — defaults, negative feedback, notch echo")
    func flangerRidesTheGenericFXSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Jet", kind: "audio")

        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("flanger")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let defaults = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(defaults["rateHz"]?.doubleValue == 0.3)
        #expect(defaults["depthMs"]?.doubleValue == 3)
        #expect(defaults["delayMs"]?.doubleValue == 1.0)
        #expect(defaults["feedback"]?.doubleValue == 0.5)
        #expect(defaults["mix"]?.doubleValue == 0.5)
        #expect(defaults["stereoPhaseDeg"]?.doubleValue == 90)
        // The derived echo, read through `FlangerParams.combNotchHz` rather
        // than re-derived on the wire: at the 1.0 ms default the first notch
        // is at 500 Hz.
        #expect(defaults["firstNotchHzAtSweepFloor"]?.doubleValue == 500)

        // ⭐ THE NEGATIVE HALF, in both directions. A `max(0, …)` anywhere on
        // the path — in the clamp, in the JSON, in the model — deletes half
        // this effect and reports success, which is the shape this tree fails
        // in. -0.72 is in range, so it must arrive VERBATIM and with NO
        // warning; -5 is out of range, so it must clamp to the NEGATIVE
        // bound, not to zero.
        let negative = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("feedback"), "value": .number(-0.72)]))
        #expect(negative.ok)
        #expect(negative.result?["effects"]?.arrayValue?.first?["params"]?["feedback"]?
            .doubleValue == -0.72)
        #expect(negative.result?["warnings"]?.arrayValue?.isEmpty != false,
                "an in-range negative feedback must not be reported as clamped")

        let clampedLow = await router.handle(ControlRequest(
            id: "3", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("feedback"), "value": .number(-5)]))
        #expect(clampedLow.ok)
        #expect(clampedLow.result?["effects"]?.arrayValue?.first?["params"]?["feedback"]?
            .doubleValue == -0.95)
        #expect(clampedLow.result?["warnings"]?.arrayValue?.isEmpty == false)

        // The notch echo TRACKS `delayMs`, so it is derived rather than a
        // constant someone pasted in: 0.1 ms puts the first notch at 5 kHz.
        let moved = await router.handle(ControlRequest(
            id: "4", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("delayMs"), "value": .number(0.1)]))
        #expect(moved.ok)
        #expect(moved.result?["effects"]?.arrayValue?.first?["params"]?[
            "firstNotchHzAtSweepFloor"]?.doubleValue == 5_000)

        // An unknown param name is refused, not silently ignored. ⚠️ `depth`
        // is the plausible wrong spelling here (the real name is `depthMs`).
        let unknown = await router.handle(ControlRequest(
            id: "5", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("depth"), "value": .number(0.5)]))
        #expect(!unknown.ok)

        // And it is legal on the master chain (a built-in kind).
        let master = await router.handle(ControlRequest(
            id: "6", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("flanger"),
                     "params": .object(["feedback": .number(-0.4), "rateHz": .number(2)])]))
        #expect(master.ok)
        #expect(master.result?["effects"]?.arrayValue?.first?["params"]?["feedback"]?
            .doubleValue == -0.4)
    }

    /// The teaching text is part of the capability. For a flanger the things
    /// an agent CANNOT infer are that the sweep is UPWARD-ONLY from `delayMs`
    /// (so a big `depthMs` is safe rather than broken), and that `feedback`
    /// changes LEVEL as well as character — without the second, an A/B between
    /// two feedback settings is a level comparison wearing a tone comparison's
    /// clothes.
    @Test("m39-j: fx.describe teaches the flanger surface — slots, curves, the upward sweep")
    func flangerDescribeCarriesItsTeaching() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["kind": .string("flanger")]))
        #expect(response.ok)
        let params = try #require(response.result?["kinds"]?.arrayValue?.first?["params"]?
            .arrayValue)
        #expect(params.compactMap { $0["name"]?.stringValue }
                == ["rateHz", "depthMs", "delayMs", "feedback", "mix", "stereoPhaseDeg"])
        // ⭐ THREE logarithmic params, and two of them are NOT in Hz — the
        // millisecond controls take the multiplicative taper because a delay
        // TIME is the reciprocal of the comb frequency it produces, which is
        // the deliberate exemption `ParamCurveConformanceTests` records.
        #expect(params[0]["curve"]?.stringValue == "logarithmic")
        #expect(params[1]["curve"]?.stringValue == "logarithmic")
        #expect(params[2]["curve"]?.stringValue == "logarithmic")
        // `feedback` crosses zero, so `.logarithmic` is structurally invalid
        // on it (log of a negative number) — the `djFilter.position` shape.
        #expect(params[3]["curve"]?.stringValue == "linear")
        #expect(params[3]["min"]?.doubleValue == -0.95)
        #expect(params[3]["max"]?.doubleValue == 0.95)
        // ⚠️ NOT ASSERTED HERE, AND THE ABSENCE IS THE FINDING: every flanger
        // param is `modulatable: .yes` in `EffectParamSpec` (pinned by
        // `ModulationTests.flangerVerdictsMatch`), but `fx.describe` does NOT
        // put `modulatable` on the wire for ANY kind — the param object above
        // carries name/min/max/default/unit/curve/note and nothing else. That
        // is a pre-existing, separately-filed gap (`mod.describeKinds` claims
        // the verdict exists while `fx.describe` omits it), not something
        // m39-j introduced, and it is deliberately not widened here because
        // adding the key changes the wire shape for all fourteen kinds at
        // once. This comment exists so the next reader does not mistake the
        // missing assertion for a missing verdict.
        #expect(params.allSatisfy { $0["modulatable"] == nil })

        // ⛔ The §6.3.2 decision, in the note a novice actually reads.
        let depthNote = try #require(params[1]["note"]?.stringValue)
        #expect(depthNote.contains("UPWARD"),
                "the note does not say which way the sweep moves")
        #expect(depthNote.contains("never goes below the floor"))
        // The comb law, with an actionable number rather than a formula alone.
        let delayNote = try #require(params[2]["note"]?.stringValue)
        #expect(delayNote.contains("1 / (2 * delay)"))
        #expect(delayNote.contains("500 Hz"),
                "the note does not name where the default actually puts the notch")
        // ⚠️ The honest one: feedback is a LEVEL control as well as a tone one.
        let feedbackNote = try #require(params[3]["note"]?.stringValue)
        #expect(feedbackNote.contains("LEVEL WARNING"))
        #expect(feedbackNote.contains("(1 - mix) + mix / (1 - feedback)"),
                "the level arithmetic is not stated, so an agent cannot predict it")
        #expect(feedbackNote.contains("NEGATIVE"))
    }

    /// m39-n — the `.tapeDelay` kind on the wire, and specifically **WHICH
    /// VERB CARRIES THE DERIVED CENTS**.
    ///
    /// ⭐⭐ THIS TEST EXISTS BECAUSE THE PROSE GOT IT WRONG FIRST. `wowCents`
    /// and `flutterCents` are built by `effectParamsJSON`, which feeds the
    /// `effects[].params` object of `fx.add`, `fx.setParam` and
    /// `project.snapshot`. `fx.describe` is a different shape entirely —
    /// per-KIND schemas, no instance, no values — so an agent told "call
    /// fx.describe for wowCents" gets `ok: true` with the key absent and
    /// concludes the readout does not exist. That is this tree's
    /// characteristic failure (a valid-looking answer to the wrong question),
    /// and the flanger's own `firstNotchHzAtSweepFloor` sentence still says
    /// the same wrong thing. Both halves are asserted below: present where it
    /// is, ABSENT where the prose used to claim it was.
    ///
    /// And the free-ms contract: this kind ships with NO `sync` and NO
    /// `division`, so a caller that assumes every delay is syncable is refused
    /// rather than silently ignored.
    @Test("m39-n: tapeDelay rides the generic fx verbs — defaults, derived cents, no sync")
    func tapeDelayRidesTheGenericFXSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Tape", kind: "audio")

        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("tapeDelay")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let defaults = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(defaults["timeMs"]?.doubleValue == 350)
        #expect(defaults["feedback"]?.doubleValue == 0.4)
        #expect(defaults["mix"]?.doubleValue == 0.3)
        #expect(defaults["wowDepthMs"]?.doubleValue == 2.5)
        #expect(defaults["wowRateHz"]?.doubleValue == 0.8)
        #expect(defaults["flutterDepthMs"]?.doubleValue == 0.25)
        #expect(defaults["saturationDrive"]?.doubleValue == 0.3)
        #expect(defaults["highCutHz"]?.doubleValue == 6_000)

        // The derived echoes, read through their ONE HOME rather than
        // re-derived here: 10.84 cents of wow and 12.87 of flutter at the
        // defaults.
        let wow = try #require(defaults["wowCents"]?.doubleValue)
        let flutter = try #require(defaults["flutterCents"]?.doubleValue)
        #expect(abs(wow - TapeDelayParams.wowCents(depthMs: 2.5, rateHz: 0.8)) < 1e-9)
        #expect(abs(flutter - TapeDelayParams.flutterCents(depthMs: 0.25)) < 1e-9)
        #expect(abs(wow - 10.84) < 0.01, "the quoted default is not what the wire carries")

        // They TRACK, so they are derived rather than two constants somebody
        // pasted in: doubling the depth roughly doubles the deviation.
        let deeper = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("wowDepthMs"), "value": .number(5.0)]))
        #expect(deeper.ok)
        let movedParams = try #require(deeper.result?["effects"]?.arrayValue?.first?["params"])
        let movedWow = try #require(movedParams["wowCents"]?.doubleValue)
        #expect(movedWow > 1.95 * wow && movedWow < 2.0 * wow,
                "wowCents \(movedWow) did not follow wowDepthMs")
        // …and the OTHER derived field did not move, which is what proves the
        // two are independent rather than one number echoed twice.
        #expect(movedParams["flutterCents"]?.doubleValue == flutter)

        // ⭐ THE HALF THE PROSE GOT WRONG: `fx.describe` carries the SCHEMA and
        // no values, so neither derived key is there — and no param is named
        // `wowCents` either. A reader who only saw the assertions above would
        // reasonably believe `fx.describe` has them.
        let describe = await router.handle(ControlRequest(
            id: "3", command: "fx.describe", params: ["kind": .string("tapeDelay")]))
        #expect(describe.ok)
        let kindObject = try #require(describe.result?["kinds"]?.arrayValue?.first)
        #expect(kindObject["wowCents"] == nil, "fx.describe must not carry an instance value")
        #expect(kindObject["params"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
                == ["timeMs", "feedback", "mix", "wowDepthMs", "wowRateHz",
                    "flutterDepthMs", "saturationDrive", "highCutHz"])
        // Positive control for the two `== nil` claims above: the SAME lookup
        // shape finds something that IS there, so the absences are real rather
        // than a mistyped key path.
        #expect(kindObject["kind"]?.stringValue == "tapeDelay")

        // ⛔ FREE-MS ONLY. `sync` and `division` are `delay`'s, and asking for
        // them here is refused rather than quietly dropped.
        for missing in ["sync", "division"] {
            let refused = await router.handle(ControlRequest(
                id: "4", command: "fx.setParam",
                params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                         "name": .string(missing), "value": .number(1)]))
            #expect(!refused.ok, Comment(rawValue: "\(missing) must not be accepted on tapeDelay"))
        }

        // Legal on the master chain, like every built-in.
        let master = await router.handle(ControlRequest(
            id: "5", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("tapeDelay"),
                     "params": .object(["wowDepthMs": .number(8), "wowRateHz": .number(3)])]))
        #expect(master.ok)
        let masterParams = try #require(master.result?["effects"]?.arrayValue?.last?["params"])
        #expect(masterParams["wowDepthMs"]?.doubleValue == 8)
        #expect(abs((masterParams["wowCents"]?.doubleValue ?? 0) - 125.845) < 0.01,
                "the maximum the notes quote is not what the wire carries")
    }

    /// m23-dj — the `.stereoWidth` kind on the wire, and the SAME
    /// which-verb-carries-the-derived-field question `wowCents` raised above.
    /// `channelPeakDb`/`channelNotchDb` are the per-channel ripple `spread`
    /// costs; they are built by `effectParamsJSON` and therefore ride
    /// `fx.add`, `fx.setParam` and `project.snapshot` — NOT `fx.describe`,
    /// which is a per-kind schema with no instance and no values.
    ///
    /// ⚠️ Without this test the two derived keys appeared in NO test at all:
    /// `grep -rn channelPeakDb Tests/` found only the pure-arithmetic unit
    /// test of the closed form in `DAWCoreTests`, which cannot see whether
    /// `effectParamsJSON` ever emits it.
    @Test("m23-dj: stereoWidth rides the generic fx verbs — defaults, derived ripple, no mix")
    func stereoWidthRidesTheGenericFXSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Wide", kind: "audio")

        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("stereoWidth")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let defaults = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(defaults["width"]?.doubleValue == 1)
        #expect(defaults["spread"]?.doubleValue == 0.3)
        #expect(defaults["bassMonoHz"]?.doubleValue == 120)
        #expect(defaults["bassMonoAmount"]?.doubleValue == 1)

        // The derived ripple, read through its ONE HOME rather than re-derived
        // here: +2.2789 / −3.0975 dB at the default spread, the figures the
        // notes and the MCP text both quote.
        let peak = try #require(defaults["channelPeakDb"]?.doubleValue)
        let notch = try #require(defaults["channelNotchDb"]?.doubleValue)
        #expect(abs(peak - StereoWidthParams.channelPeakDb(spread: 0.3)) < 1e-9)
        #expect(abs(notch - StereoWidthParams.channelNotchDb(spread: 0.3)) < 1e-9)
        #expect(abs(peak - 2.2789) < 0.001, "the quoted default is not what the wire carries")
        #expect(abs(notch + 3.0975) < 0.001)

        // They TRACK `spread`, so they are derived rather than two constants
        // somebody pasted in — and at spread 1 the notch is a COMPLETE NULL,
        // which the prose calls out and the floor reports as −120.
        let wider = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("spread"), "value": .number(1.0)]))
        #expect(wider.ok)
        let movedParams = try #require(wider.result?["effects"]?.arrayValue?.first?["params"])
        #expect(abs((movedParams["channelPeakDb"]?.doubleValue ?? 0) - 6.0206) < 0.001)
        #expect(movedParams["channelNotchDb"]?.doubleValue == -120,
                "a complete null must report the documented floor, not -inf or NaN")
        // …and the field that does NOT depend on spread did not move.
        #expect(movedParams["width"]?.doubleValue == 1)

        // ⭐ THE HALF AN AGENT GETS WRONG: `fx.describe` carries the SCHEMA and
        // no values, so neither derived key is there — and no PARAM is named
        // `channelPeakDb` either.
        let describe = await router.handle(ControlRequest(
            id: "3", command: "fx.describe", params: ["kind": .string("stereoWidth")]))
        #expect(describe.ok)
        let kindObject = try #require(describe.result?["kinds"]?.arrayValue?.first)
        #expect(kindObject["channelPeakDb"] == nil, "fx.describe must not carry an instance value")
        #expect(kindObject["params"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
                == ["width", "spread", "bassMonoHz", "bassMonoAmount"])
        // Positive control for the `== nil` claim: the same lookup shape finds
        // something that IS there.
        #expect(kindObject["kind"]?.stringValue == "stereoWidth")

        // ⛔ NO `mix` ON THIS KIND — asking for one is refused rather than
        // quietly dropped, because a dry/wet blend on a mid/side widener is
        // algebraically just another `width`.
        let refused = await router.handle(ControlRequest(
            id: "4", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("mix"), "value": .number(0.5)]))
        #expect(!refused.ok, "mix must not be accepted on stereoWidth")

        // Legal on the master chain, like every built-in — and this is the
        // chain it is most often wanted on.
        let master = await router.handle(ControlRequest(
            id: "5", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("stereoWidth"),
                     "params": .object(["spread": .number(0.6), "bassMonoHz": .number(90)])]))
        #expect(master.ok)
        let masterParams = try #require(master.result?["effects"]?.arrayValue?.last?["params"])
        #expect(masterParams["spread"]?.doubleValue == 0.6)
        #expect(masterParams["bassMonoHz"]?.doubleValue == 90)
        #expect(abs((masterParams["channelPeakDb"]?.doubleValue ?? 0) - 4.0824) < 0.001,
                "the derived ripple must follow the params the caller supplied at add time")
    }

    /// The teaching text is part of the capability: an agent that cannot work
    /// out where the corner sits from `fx.describe` alone is guessing, and the
    /// cutoff law has exactly one home for that reason.
    @Test("m39-i: fx.describe teaches the djFilter surface — slots, curves, the cutoff law")
    func djFilterDescribeCarriesItsTeaching() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["kind": .string("djFilter")]))
        #expect(response.ok)
        let params = try #require(response.result?["kinds"]?.arrayValue?.first?["params"]?
            .arrayValue)
        #expect(params.compactMap { $0["name"]?.stringValue }
                == ["position", "resonance", "slopeDbPerOct", "deadZoneWidth",
                    "resonanceTrack"])
        // `position` crosses zero, so `.logarithmic` is structurally invalid on
        // it and the taper MUST read linear — the log-ness lives in the note.
        #expect(params[0]["curve"]?.stringValue == "linear")
        // ⚠️ `modulatable` is NOT on `fx.describe`'s per-param object today —
        // verified here rather than assumed, because the first draft of this
        // test asserted it and failed. The verdicts live in `EffectParamSpec`
        // and are pinned by `ModulationTests.djFilterVerdictsMatch`; surfacing
        // them on this verb is a separate, additive decision and is NOT part
        // of m39-i.
        #expect(params[0]["modulatable"] == nil)
        let positionNote = try #require(params[0]["note"]?.stringValue)
        #expect(positionNote.contains("high-pass"))
        #expect(positionNote.contains("low-pass"))
        #expect(positionNote.contains("20000"), "the cutoff law is not in the note text")
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

    // MARK: - m39-e — the nine mod.* verbs
    //
    // ⚠️ These live in THIS suite rather than a new one: the
    // `MainActorOccupancySiteTests` Leg C census is AT its 380 cap with zero
    // slack, and `CommandRouter` is main-actor isolated so a new suite would
    // have to be too. `mod.*` addresses the same strips through the same
    // `parseFXTarget` vocabulary as `fx.*`, so this is the honest home.

    private func addModSource(_ router: CommandRouter, trackID: String,
                              kind: String,
                              params: [String: JSONValue] = [:]) async -> ControlResponse {
        var request: [String: JSONValue] = ["trackId": .string(trackID), "kind": .string(kind)]
        if !params.isEmpty { request["params"] = .object(params) }
        return await router.handle(ControlRequest(id: "mod-add-source",
                                                  command: "mod.addSource", params: request))
    }

    @Test("m39-e: addSource → addRoute → describe reports the source's value, the base and the MODULATED value")
    func modulationDescribeReportsTheEffectiveValue() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "macro",
                                        params: ["value": .number(1)])
        #expect(source.ok)
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)

        let route = await router.handle(ControlRequest(
            id: "r", command: "mod.addRoute",
            params: ["trackId": .string(trackID.uuidString),
                     "sourceId": .string(sourceID),
                     "target": .object(["type": .string("volume")]),
                     "depth": .number(-0.25)]))
        #expect(route.ok)
        #expect(route.result?["routeId"]?.stringValue != nil)

        let described = await router.handle(ControlRequest(
            id: "d", command: "mod.describe",
            params: ["trackId": .string(trackID.uuidString)]))
        #expect(described.ok)
        let strips = try #require(described.result?["strips"]?.arrayValue)
        #expect(strips.count == 1)
        let effective = try #require(strips[0]["effective"]?.arrayValue)
        #expect(effective.count == 1)
        #expect(effective[0]["sourceValue"]?.doubleValue == 1)
        #expect(effective[0]["baseValue"]?.doubleValue == 1)
        // depth -0.25 × the 48 dB window = -12 dB = 0.2512 linear.
        let modulated = try #require(effective[0]["modulatedValue"]?.doubleValue)
        print("[measured] m39-e wire describe — base 1.0, macro 1.0 at depth -0.25 → "
              + "\(modulated)")
        #expect(abs(20 * log10(modulated) + 12) < 0.01)
    }

    @Test("m39-e: mod.setMacro refuses a non-macro source by NAMING its actual kind")
    func setMacroRefusesTheWrongKind() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "lfo")
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)
        let response = await router.handle(ControlRequest(
            id: "m", command: "mod.setMacro",
            params: ["trackId": .string(trackID.uuidString),
                     "sourceId": .string(sourceID), "value": .number(0.5)]))
        #expect(!response.ok)
        let message = response.error ?? ""
        #expect(message.contains("macro"))
        #expect(message.contains("lfo"), "the refusal must name the source's ACTUAL kind")
    }

    @Test("m39-e §7.4: refusals name a REASON an agent can branch on — discrete, controlPlaneOnly, sendLevelUnsupported, noInstrument")
    func refusalTaxonomyNamesItsReason() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "lfo")
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)

        func refuse(_ target: JSONValue) async -> String {
            let response = await router.handle(ControlRequest(
                id: "x", command: "mod.addRoute",
                params: ["trackId": .string(trackID.uuidString),
                         "sourceId": .string(sourceID), "target": target,
                         "depth": .number(0.5)]))
            #expect(!response.ok)
            return response.error ?? ""
        }
        // A boolean effect param — discrete.
        let discrete = await refuse(.object(["type": .string("effectParam"),
                                             "effectId": .string(effectID.uuidString),
                                             "param": .string("invertPolarity")]))
        #expect(discrete.contains("discrete"))
        // `.sendLevel` — refused at the store today, and with no render-side
        // send stage to compose into.
        let send = await refuse(.object(["type": .string("sendLevel"),
                                         "sendId": .string(UUID().uuidString)]))
        #expect(send.contains("sendLevelUnsupported"))
        // An instrument param on an AUDIO track — there is no instrument.
        let noInstrument = await refuse(.object(["type": .string("instrumentParam"),
                                                 "param": .string("cutoffHz")]))
        #expect(noInstrument.contains("noInstrument"))
        print("[measured] m39-e refusals — discrete: \(discrete.prefix(60))… | "
              + "send: \(send.prefix(50))… | instrument: \(noInstrument.prefix(50))…")
    }

    @Test("m39-e §7.4: delay.sync is refused as controlPlaneOnly, NOT as discrete — an agent branches on the reason")
    func delaySyncRefusalUsesItsOwnReason() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let delayResponse = await router.handle(ControlRequest(
            id: "fx", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("delay")]))
        let delayID = try #require(delayResponse.result?["effectId"]?.stringValue)
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "lfo")
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)
        let response = await router.handle(ControlRequest(
            id: "x", command: "mod.addRoute",
            params: ["trackId": .string(trackID.uuidString),
                     "sourceId": .string(sourceID),
                     "target": .object(["type": .string("effectParam"),
                                        "effectId": .string(delayID),
                                        "param": .string("sync")]),
                     "depth": .number(0.5)]))
        #expect(!response.ok)
        let message = response.error ?? ""
        #expect(message.contains("controlPlaneOnly"))
        #expect(!message.contains("discrete"))
    }

    @Test("m39-e §7.1: mod.removeSource CASCADES its routes and NAMES every one it removed")
    func removeSourceCascadesAndNamesWhatItCascaded() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "lfo")
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)
        var routeIDs: [String] = []
        for target in [JSONValue.object(["type": .string("volume")]),
                       JSONValue.object(["type": .string("pan")])] {
            let response = await router.handle(ControlRequest(
                id: "r", command: "mod.addRoute",
                params: ["trackId": .string(trackID.uuidString),
                         "sourceId": .string(sourceID), "target": target,
                         "depth": .number(-0.2)]))
            routeIDs.append(try #require(response.result?["routeId"]?.stringValue))
        }
        let removed = await router.handle(ControlRequest(
            id: "rm", command: "mod.removeSource",
            params: ["trackId": .string(trackID.uuidString),
                     "sourceId": .string(sourceID)]))
        #expect(removed.ok)
        let cascaded = try #require(removed.result?["removedRouteIds"]?.arrayValue)
            .compactMap(\.stringValue)
        #expect(Set(cascaded) == Set(routeIDs),
                "a silent cascade is how a caller ends up with a model it did not predict")
        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.modulationSources.isEmpty)
        #expect(track.modulationRoutes.isEmpty)
    }

    @Test("m39-e §7.5: an out-of-range depth CLAMPS AND WARNS; a bipolar source on volume warns about the ceiling")
    func depthClampsAndVolumeCeilingWarns() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "lfo")
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)
        let response = await router.handle(ControlRequest(
            id: "r", command: "mod.addRoute",
            params: ["trackId": .string(trackID.uuidString),
                     "sourceId": .string(sourceID),
                     "target": .object(["type": .string("volume")]),
                     "depth": .number(5)]))
        #expect(response.ok, "clamp and warn, never reject — the fx.setParam precedent")
        #expect(response.result?["route"]?["depth"]?.doubleValue == 1)
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
            .compactMap(\.stringValue)
        #expect(warnings.contains { $0.hasPrefix("modulationDepthClamped") })
        // A BIPOLAR source at unity clips its upper half — the tremolo that is
        // not a tremolo. The warning names the idiom that works instead.
        #expect(warnings.contains { $0.hasPrefix("modulationVolumeCeiling") })
        print("[measured] m39-e wire warnings: \(warnings.map { $0.prefix(34) })")
    }

    @Test("m39-e §7.2.1: syncDivision refuses through the WIRE, naming m39-c")
    func tempoSyncRefusesOnTheWire() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let response = await addModSource(router, trackID: trackID.uuidString, kind: "lfo",
                                          params: ["syncDivision": .string("1/8")])
        #expect(!response.ok)
        let message = response.error ?? ""
        #expect(message.contains("m39-c"))
        #expect(message.contains("rateHz"), "the refusal must name what DOES work")
    }

    @Test("m39-e §7.1: mod.describeKinds carries the depth law AND the polarity convention")
    func describeKindsCarriesTheTeachingAnAgentNeeds() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "k", command: "mod.describeKinds", params: [:]))
        #expect(response.ok)
        let polarity = try #require(response.result?["polarity"]?.stringValue)
        // §7.2.0's amendment — the reader most likely to get a gate backwards
        // is an agent reading the tool surface, so this is where it must live.
        #expect(polarity.contains("[0,1,0,1]"))
        #expect(polarity.contains("OFFSET"))
        let depthLaw = try #require(response.result?["depthLaw"]?.stringValue)
        #expect(depthLaw.contains("octave"))
        #expect(depthLaw.contains("8.81"), "the worked example, verbatim")
        let kinds = try #require(response.result?["kinds"]?.arrayValue)
        #expect(kinds.count == 4)
        // `trigger` was REJECTED: there is nothing to trigger.
        let names = kinds.compactMap { $0["kind"]?.stringValue }
        #expect(Set(names) == ["lfo", "stepSequencer", "envelopeFollower", "macro"])
    }

    @Test("m39-e §7.4: lanes and modulated effect params share one 64-slot budget, and modulation REFUSES past it rather than dropping silently")
    func combinedTrackBudgetRefusesRatherThanDropping() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "lfo")
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)
        var eqIDs: [UUID] = []
        for _ in 0..<5 {
            let eq = await router.handle(ControlRequest(
                id: "fx", command: "fx.add",
                params: ["trackId": .string(trackID.uuidString), "kind": .string("eq")]))
            let raw = try #require(eq.result?["effectId"]?.stringValue)
            eqIDs.append(try #require(UUID(uuidString: raw)))
        }
        let names = EffectParamSpec.specs(for: .eq)
            .filter { $0.modulatable != .refused }.map(\.name)
        // (effectID, param) pairs, distinct, in a stable order.
        let slots = eqIDs.flatMap { id in names.map { (id, $0) } }
        #expect(slots.count > ModulationLimits.maxRoutes,
                "the fixture must be able to cross the cap, or the test is vacuous")

        // 63 AUTOMATION lanes, each with a point — an empty lane is not built,
        // so it must not be counted either.
        for (effectID, name) in slots.prefix(63) {
            let lane = try store.addAutomationLane(
                trackID: trackID, target: .effectParam(effectID: effectID, paramName: name))
            _ = try store.setAutomationPoints(trackID: trackID, laneID: lane.id,
                                              points: [AutomationPoint(beat: 0, value: 0)])
        }

        func route(_ pair: (UUID, String), depth: Double = 0.1) async -> ControlResponse {
            await router.handle(ControlRequest(
                id: "r", command: "mod.addRoute",
                params: ["trackId": .string(trackID.uuidString),
                         "sourceId": .string(sourceID),
                         "target": .object(["type": .string("effectParam"),
                                            "effectId": .string(pair.0.uuidString),
                                            "param": .string(pair.1)]),
                         "depth": .number(depth)]))
        }

        // Modulating an ALREADY-AUTOMATED param costs no extra slot — 63 + 0.
        let free = await route(slots[0], depth: 0.2)
        #expect(free.ok, Comment(rawValue: free.error ?? ""))

        // The 64th distinct param fits exactly.
        let sixtyFourth = await route(slots[63])
        #expect(sixtyFourth.ok, Comment(rawValue: sixtyFourth.error ?? ""))

        // The 65th does not, and the refusal NAMES both contributors — "the cap"
        // alone would not tell a caller which of the two things to remove.
        let over = await route(slots[64])
        #expect(!over.ok)
        let message = over.error ?? ""
        print("[measured] m39-e combined budget: \(message.prefix(200))")
        #expect(message.contains("automation lane"))
        #expect(message.contains("modulated effect parameter"))
        #expect(message.contains("64"))

        // Nothing was silently dropped: the store holds exactly what it accepted.
        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.modulationRoutes.count == 2)
        #expect(track.automation.count == 63)
    }

}
