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

    /// m39-ad. The saturator's new `oversampling` knob and the three DERIVED
    /// fields every `fx.add` / `fx.setParam` result echoes beside it.
    ///
    /// ⛔⛔ **`latencySamples` IS THE ONE THAT MATTERS AND IT IS NOT A CONSTANT
    /// ON THIS KIND** — 0 at factor 1, 32 at 2/4 — where `.clipper`'s is a
    /// constant 32 at every factor. An agent that carries the clipper's habit
    /// across will be wrong, which is exactly why the number is on the wire
    /// rather than only in the source. (The engine-level proof that the PDC plan
    /// FOLLOWS this number lives in `PDCWiringTests`; this pins the wire.)
    @Test("m39-ad: the saturator echoes resolvedOversampling, latencySamples and aliasRejectionDb")
    func saturatorEchoesOversamplingDerivations() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Bass", kind: "audio")

        // 1. A freshly added saturator — the DEFAULT, which must be factor 1
        //    and must cost NOTHING.
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("saturator")]))
        #expect(added.ok)
        let fresh = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(fresh["oversampling"]?.doubleValue == 1)
        #expect(fresh["resolvedOversampling"]?.doubleValue == 1)
        #expect(fresh["latencySamples"]?.doubleValue == 0, Comment(rawValue:
            "a freshly added saturator reported "
            + "\(fresh["latencySamples"]?.doubleValue ?? -1) samples of latency on the wire — "
            + "at the default it must be 0, or every existing project shifts in time"))
        #expect(fresh["aliasRejectionDb"]?.doubleValue == -OversamplerDesign.stopbandAttenuationDb)
        let effectID = try #require(added.result?["effectId"]?.stringValue)

        // 2. Turn it up: the latency moves WITH the knob, on the wire.
        for (requested, resolved, latency) in [(4.0, 4.0, 32.0), (2.0, 2.0, 32.0),
                                               // ⚠️ 3 SNAPS UP to 4 — the stored
                                               // value is NOT snapped, the
                                               // resolved one is.
                                               (3.0, 4.0, 32.0), (1.0, 1.0, 0.0)] {
            let set = await router.handle(ControlRequest(
                id: "2", command: "fx.setParam",
                params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                         "name": .string("oversampling"), "value": .number(requested)]))
            #expect(set.ok)
            let params = try #require(set.result?["effects"]?.arrayValue?.first?["params"])
            #expect(params["oversampling"]?.doubleValue == requested, Comment(rawValue:
                "the STORED value must come back unsnapped (the phaser.stages precedent)"))
            #expect(params["resolvedOversampling"]?.doubleValue == resolved, Comment(rawValue:
                "requested \(requested) resolved to "
                + "\(params["resolvedOversampling"]?.doubleValue ?? -1), expected \(resolved)"))
            #expect(params["latencySamples"]?.doubleValue == latency, Comment(rawValue:
                "requested \(requested) reported "
                + "\(params["latencySamples"]?.doubleValue ?? -1) samples, expected \(latency)"))
        }

        // 3. project.snapshot reports them through the SAME effectParamsJSON.
        _ = await router.handle(ControlRequest(
            id: "3", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("oversampling"), "value": .number(4)]))
        let snapshot = await router.handle(ControlRequest(id: "4", command: "project.snapshot"))
        let track = try #require(snapshot.result?["tracks"]?.arrayValue?
            .first { $0["id"]?.stringValue == trackID.uuidString })
        let snapFX = try #require(track["effects"]?.arrayValue?.first?["params"])
        #expect(snapFX["resolvedOversampling"]?.doubleValue == 4)
        #expect(snapFX["latencySamples"]?.doubleValue == 32)

        // ⭐ CONTROL: the CLIPPER's identically named param must report a
        // CONSTANT 32, including at factor 1. If these two kinds ever agree at
        // factor 1, one of the two designs has been "harmonised" into a bug.
        let clip = await router.handle(ControlRequest(
            id: "5", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("clipper"),
                     "params": .object(["oversampling": .number(1)])]))
        #expect(clip.ok)
        let clipParams = try #require(clip.result?["effects"]?.arrayValue?.last?["params"])
        #expect(clipParams["resolvedOversampling"]?.doubleValue == 1)
        #expect(clipParams["latencySamples"]?.doubleValue == 32, Comment(rawValue:
            "the clipper reported \(clipParams["latencySamples"]?.doubleValue ?? -1) at factor 1 "
            + "— its latency is a CONSTANT 32 by design, because its factor is automatable"))
    }

    /// m39-ac-2 — THE 2026-09-20 RULING, ON THE WIRE: a clipper added with no
    /// params starts at 1× (off) — it used to start at 4× — on a track AND on
    /// the master, and `fx.describe` reports 1 as the default. The PROJECT-FILE
    /// half (a clipper already saved keeps its 4×, decoded and rendered from a
    /// verbatim pre-ruling document) lives in `ClipperDefaultOversamplingTests`.
    @Test("m39-ac-2: a clipper added over the wire starts at 1×, track and master, and fx.describe says 1")
    func clipperAddedOverTheWireStartsAtOne() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Drums", kind: "audio")

        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("clipper")]))
        #expect(added.ok)
        let params = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(params["oversampling"]?.doubleValue == 1, Comment(rawValue:
            "a new clipper reported oversampling "
            + "\(params["oversampling"]?.doubleValue ?? -1) — the ruling says it starts OFF (1)"))
        #expect(params["resolvedOversampling"]?.doubleValue == 1)
        // ⭐ INVARIANCE CONTROL: the ruling moved the FACTOR, not the design —
        // the clipper's latency is still a constant 32 at every factor.
        #expect(params["latencySamples"]?.doubleValue == 32)
        // …and the 1 is IN THE MODEL, explicitly — not a nil that some later
        // default could reinterpret (that nil is what an OLD clipper looks like).
        let track = try #require(store.tracks.first { $0.id == trackID })
        #expect(track.effects.first?.clipper?.oversampling == 1)

        let master = await router.handle(ControlRequest(
            id: "2", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("clipper")]))
        #expect(master.ok)
        let masterID = try #require(master.result?["effectId"]?.stringValue)
        let masterParams = try #require(master.result?["effects"]?.arrayValue?
            .first { $0["id"]?.stringValue == masterID }?["params"])
        #expect(masterParams["oversampling"]?.doubleValue == 1)
        #expect(store.masterEffects.last?.clipper?.oversampling == 1)

        let described = await router.handle(ControlRequest(
            id: "3", command: "fx.describe", params: ["kind": .string("clipper")]))
        #expect(described.ok)
        let specs = try #require(described.result?["kinds"]?.arrayValue?.first?["params"]?
            .arrayValue)
        let oversampling = try #require(specs.first { $0["name"]?.stringValue == "oversampling" })
        #expect(oversampling["default"]?.doubleValue == 1)
        // The note tells an agent BOTH halves: new ones start at 1, saved ones keep 4.
        let note = try #require(oversampling["note"]?.stringValue)
        #expect(note.contains("NEWLY ADDED CLIPPER"))
        #expect(note.contains("ALREADY SAVED"))
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
                    "tapeDelay", "stereoWidth", "phaser", "transientShaper", "freqShifter",
                    "clipper", "dynamicEQ", "audioUnit"])
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
        // m39-ae appends the DE-ESSER's three in slots 7…9, for the same
        // reason and with a longer history behind it: `.compressor` has been
        // shipped since M4 (iii), so an insertion anywhere in this list would
        // silently repoint every automation lane on every saved project.
        #expect(paramNames("compressor") == [
            "thresholdDb", "ratio", "attackMs", "releaseMs", "kneeDb", "makeupDb", "mix",
            "detectorMode", "detectorFreqHz", "detectorQ",
        ])
        // m23-ch appends truePeak in slot 2 — ceilingDb/releaseMs keep 0/1.
        #expect(paramNames("limiter") == ["ceilingDb", "releaseMs", "truePeak"])
        #expect(paramNames("reverb") == ["roomSize", "damping", "mix", "preDelayMs", "width"])
        // The five legacy params stay in slots 0…4 (automation slot
        // stability); the m22-f tempo-sync params are APPENDED.
        #expect(paramNames("delay") == ["timeMs", "feedback", "mix", "pingPong", "highCutHz",
                                        "sync", "division"])
        // m39-ad APPENDS oversampling — the three legacy slots (0…2) keep their
        // indices, which on a SHIPPED kind is the difference between adding a
        // control and silently repointing every saved automation lane.
        #expect(paramNames("saturator") == ["driveDb", "mix", "outputDb", "oversampling"])
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
        // ⚠️ THE BOGUS NAME WAS `phaser` UNTIL m39-o SHIPPED ONE. A test whose
        // "definitely not a kind" fixture becomes a kind does not fail
        // gracefully — it asserts the wrong branch entirely. `wobbulator` is
        // chosen to be un-shippable: it is not an effect anyone builds.
        let badKind = await router.handle(ControlRequest(
            id: "3", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("wobbulator")]
        ))
        #expect(!badKind.ok)
        #expect(badKind.error == "unknown effect kind 'wobbulator' — use "
                + "gain|eq|compressor|limiter|reverb|delay|saturator|gate|chorus|"
                + "bassEnhancer|bitCrusher|djFilter|ringMod|flanger|hallReverb|tapeDelay|"
                + "stereoWidth|phaser|transientShaper|freqShifter|clipper|dynamicEQ|"
                + "audioUnit")
        // POSITIVE CONTROL on the rename: the name that USED to be the bogus
        // one is now a real kind, and must be ACCEPTED.
        let nowReal = await router.handle(ControlRequest(
            id: "3b", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("phaser")]
        ))
        #expect(nowReal.ok)

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
            "tapeDelay": "timeMs", "stereoWidth": "width", "phaser": "centerHz",
            "transientShaper": "attackDb", "freqShifter": "shiftHz",
            "clipper": "ceilingDb",
            // m39-af. `band1Freq` rather than `band1Mode`, deliberately: the
            // probe below asserts the param is PRESENT in the wire result, and
            // a mode of 0 would be present-and-zero either way, so a frequency
            // is the probe that can tell "the field is there" from "the field
            // decoded to nothing".
            "dynamicEQ": "band1Freq",
        ]
        let censusKinds = EffectDescriptor.Kind.allCases
            .map(\.rawValue)
            .filter { $0 != "audioUnit" }
        // Non-vacuity: if `allCases` ever stops enumerating, the loop below would
        // pass by doing nothing at all.
        #expect(censusKinds.count >= 21)
        let uncovered = censusKinds.filter { expectedParam[$0] == nil }
        #expect(uncovered.isEmpty, "kinds with no entry in this census: \(uncovered) — add one rather than widening the filter; a kind with no wire probe is how a param surface ships untested")
        // ⚠️ ONE FRESH TRACK PER KIND. The census is 18 kinds and a track holds
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

    /// m39-af — the `.dynamicEQ` kind end-to-end on the wire, at the size that
    /// makes it worth its own leg: **THIRTY-TWO params**, the largest table in
    /// the tree by 45 %, declared in `EffectParamSpec.specs` and accepted by a
    /// separate path in `ProjectStore.applyEffectParam`. The `hallReverb`
    /// bijection above is the shape; this is the same gate at a size where a
    /// single mistyped band number would be invisible to a reviewer.
    ///
    /// ⭐ Like every other built-in this kind ships **ZERO new commands**:
    /// `fx.add` parses the kind through `EffectDescriptor.Kind(rawValue:)` and
    /// `fx.setParam`/`fx.describe` are name-driven off `specs(for:)`, so
    /// `doc-count-drift` must read the same totals after this item as before.
    @Test("m39-af: all 32 dynamicEQ params are settable, no undeclared one is, names echo")
    func dynamicEQDescribeAndSetAgree() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let addResponse = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("dynamicEQ")]
        ))
        #expect(addResponse.ok, "fx.add refused dynamicEQ: \(addResponse.error ?? "")")
        let effectID = try #require(addResponse.result?["effectId"]?.stringValue)

        let declared = EffectParamSpec.specs(for: .dynamicEQ)
        #expect(declared.count == 32)

        // → every DECLARED name is accepted, takes a value, and reads back.
        for (index, spec) in declared.enumerated() {
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
            // ⚠️ `bandNMode` is SNAPPED, so it does not echo the raw 0.37-of-range
            // value — the `phaser.stages` precedent. Every other param echoes
            // exactly what was set.
            // ⚠ EVERY param echoes EXACTLY what was set, `bandNMode`
            // INCLUDED: `fx.setParam` CLAMPS to the declared range but does NOT
            // SNAP a discrete value — the `phaser.stages` precedent, where a
            // stored 3 renders as 4. The snapped truth reaches the wire through
            // the additive `bandNModeLabel` echo asserted below, and reaches the
            // render thread through `DynamicEQParams.mode(at:)`. A test that
            // expected a snapped ECHO here would be asserting behaviour this
            // tree deliberately does not have.
            #expect(abs((echoed ?? .nan) - value) < 1e-9,
                    Comment(rawValue: "'\(spec.name)' echoed \(echoed ?? .nan), not the "
                        + "\(value) that was set"))
        }

        // ⭐ AND EVERY WRITE LANDED ON ITS OWN FIELD. Thirty-two near-identical
        // names across four near-identical bands is exactly where a `band2Q`
        // arm that writes `band3Q` hides — and each write above would still
        // "echo" correctly, because the echo re-reads after the write. The
        // proof has to be that all 32 hold their distinct values AT ONCE.
        let final = await router.handle(ControlRequest(
            id: "final", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("band1Q"), "value": .number(6.5)]
        ))
        #expect(final.ok)
        let params = try #require(final.result?["effects"]?.arrayValue?.first?["params"])
        for (index, spec) in declared.enumerated() {
            guard spec.name != "band1Q" else { continue }
            let want = spec.range.lowerBound
                + (spec.range.upperBound - spec.range.lowerBound) * 0.37
            let got = params[spec.name]?.doubleValue
            #expect(abs((got ?? .nan) - want) < 1e-9,
                    Comment(rawValue: "'\(spec.name)' holds \(got ?? .nan) not \(want) "
                        + "(index \(index)) — two name arms share a field"))
        }
        #expect(params["band1Q"]?.doubleValue == 6.5)

        // → the accepted set is NO LARGER: the refusal message lists it.
        let bogus = await router.handle(ControlRequest(
            id: "bogus", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("peak1Freq"), "value": .number(500)]
        ))
        #expect(!bogus.ok, "`peak1Freq` belongs to the OTHER EQ kind and must be refused")
        let expectedMessage = "unknown parameter 'peak1Freq' for dynamicEQ effect — valid: "
            + declared.map(\.name).joined(separator: ", ")
        #expect(try #require(bogus.error) == expectedMessage,
                "the refusal message and the spec table disagree: \(bogus.error ?? "")")

        // → `fx.describe` reports the SAME thirty-two, in the SAME order, each
        //   with its teaching note.
        let describe = await router.handle(ControlRequest(
            id: "describe", command: "fx.describe",
            params: ["kind": .string("dynamicEQ")]
        ))
        #expect(describe.ok)
        let described = describe.result?["kinds"]?.arrayValue?.first?["params"]?.arrayValue
        #expect(described?.compactMap { $0["name"]?.stringValue } == declared.map(\.name))
        #expect(described?.allSatisfy { ($0["note"]?.stringValue?.count ?? 0) > 80 } == true,
                "a dynamicEQ param reached fx.describe with no teaching note")

        // → the ADDITIVE human echoes: a snapped mode LABEL per band, plus the
        //   two constants an agent would otherwise have to read out of source.
        #expect(params["band1ModeLabel"]?.stringValue == "above")
        #expect(params["band4ModeLabel"]?.stringValue == "above")
        #expect(params["latencySamples"]?.doubleValue == 0)
        #expect(params["kneeDb"]?.doubleValue == DynamicEQParams.kneeDb)
    }

    /// ⛔ m39-af — **THE DISPLAY NAME IS "Dynamic EQ", NOT "DynamicEQ".** The
    /// store's `effectDisplayName` has a `default:` arm that title-cases the raw
    /// value, so WITHOUT an explicit case this kind ships as "DynamicEQ" in
    /// every undo label — a cosmetic-looking bug the compiler, the insert-label
    /// budget sweep and `effect-kind-surface.mjs` all pass. That arm's own
    /// comment predicts this exact failure by name, and m39-y and m39-ac each
    /// hit it.
    @Test("m39-af: the undo label reads 'Dynamic EQ', not the camelCase raw value")
    func dynamicEQUndoLabelIsSpelledOut() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("dynamicEQ")]
        ))
        #expect(response.ok)
        let label = await store.undoLabel
        #expect(label == "Add Dynamic EQ to 'Vox'",
                Comment(rawValue: "undo label is \(label ?? "nil") — the default: arm shipped "
                    + "the camelCase raw value"))
        // ⭐ POSITIVE CONTROL: a kind that DOES rely on the default arm still
        // reads correctly, so the assertion above is about the explicit case
        // rather than about the label machinery being broken.
        let control = await router.handle(ControlRequest(
            id: "2", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("chorus")]
        ))
        #expect(control.ok)
        let controlLabel = await store.undoLabel
        #expect(controlLabel == "Add Chorus to 'Vox'")
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
        // ⭐ m39-f-3 FIXED the gap this comment used to document: every flanger
        // param is `modulatable: .yes` in `EffectParamSpec` (pinned by
        // `ModulationTests.flangerVerdictsMatch`), and `fx.describe` now puts
        // that verdict on the wire for every kind — this was the pre-existing,
        // separately-filed gap `mod.describeKinds` had claimed fixed while
        // `fx.describe` still omitted it. The behavioural pin (the wire verdict
        // equals what a real `mod.addRoute` does) lives in
        // `DescribeVerdictsCommandTests`, not repeated per-kind here.
        #expect(params.allSatisfy { $0["modulatable"]?.stringValue == "yes" })

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

    /// ⭐⭐ m39-y — THE SAME TEST FOR THE SAME REASON, AND IT IS NOT A COPY OF
    /// THE ONE ABOVE. `.transientShaper` echoes THREE derived keys, one
    /// per-instance and two CONSTANT, and the constants are the ones most likely
    /// to be mis-documented: `fullShapeDifferentialDb` is what makes
    /// `attackDb: +6` mean anything at all ("up to +6 dB, reached at a 12 dB
    /// differential"), and `detectorFloorDb` is the answer to "why did nothing
    /// happen on my quiet stem". Both are claimed in `fxKindSchema`, in the MCP
    /// README, in `fx_describe`'s own description and in two param notes — five
    /// places, which is exactly the shape that shipped a FALSE wire claim in
    /// three places at once on 2026-09-19. Both halves are asserted: PRESENT
    /// where they are, ABSENT from `fx.describe`, where none of that prose may
    /// claim they live.
    @Test("m39-y: transientShaper rides the generic fx verbs — defaults, three derived echoes, none of them in fx.describe")
    func transientShaperRidesTheGenericFXSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Drums", kind: "audio")

        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString),
                     "kind": .string("transientShaper")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let defaults = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(defaults["attackDb"]?.doubleValue == 0)
        #expect(defaults["sustainDb"]?.doubleValue == 0)
        #expect(defaults["attackMs"]?.doubleValue == 5)
        #expect(defaults["sustainMs"]?.doubleValue == 200)
        #expect(defaults["outputDb"]?.doubleValue == 0)
        #expect(defaults["mix"]?.doubleValue == 1)

        // The derived echo, read through its ONE HOME rather than re-derived
        // here — that is how the record and the source come to disagree while
        // both look right. 0.28927 × 5 ms = 1.446 ms of full punch at defaults.
        let window = try #require(defaults["attackWindowMs"]?.doubleValue)
        #expect(abs(window - TransientShaperParams.attackWindowMs(attackMs: 5)) < 1e-12)
        #expect(abs(window - 1.446) < 0.001,
                "the 'about 0.29 times' the notes quote is not what the wire carries")
        // The two CONSTANT echoes, whose whole job is to let an agent answer
        // "what does +6 promise?" and "why is nothing happening?" off the wire.
        #expect(defaults["fullShapeDifferentialDb"]?.doubleValue == 12)
        #expect(defaults["detectorFloorDb"]?.doubleValue == -70)

        // `attackWindowMs` TRACKS, so it is derived rather than a constant
        // somebody pasted in: 30 ms gives 8.678 ms, the figure the tests and the
        // demo both quote.
        let longer = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("attackMs"), "value": .number(30)]))
        #expect(longer.ok)
        let moved = try #require(longer.result?["effects"]?.arrayValue?.first?["params"])
        let movedWindow = try #require(moved["attackWindowMs"]?.doubleValue)
        #expect(abs(movedWindow - 8.678) < 0.001,
                "attackWindowMs \(movedWindow) did not follow attackMs")
        // …and the two CONSTANTS did NOT move, which is what proves they are
        // constants rather than three numbers derived from the same input.
        #expect(moved["fullShapeDifferentialDb"]?.doubleValue == 12)
        #expect(moved["detectorFloorDb"]?.doubleValue == -70)

        // ⭐ THE HALF THE PROSE IS MOST LIKELY TO GET WRONG: `fx.describe`
        // carries the SCHEMA and no values, so NONE of the three keys is there,
        // and no param is named for them either.
        let describe = await router.handle(ControlRequest(
            id: "3", command: "fx.describe",
            params: ["kind": .string("transientShaper")]))
        #expect(describe.ok)
        let kindObject = try #require(describe.result?["kinds"]?.arrayValue?.first)
        for key in ["attackWindowMs", "fullShapeDifferentialDb", "detectorFloorDb"] {
            #expect(kindObject[key] == nil,
                    Comment(rawValue: "fx.describe must not carry \(key) — the prose says it does not"))
        }
        #expect(kindObject["params"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
                == ["attackDb", "sustainDb", "attackMs", "sustainMs", "outputDb", "mix"])
        // Positive control for the three `== nil` claims above: the SAME lookup
        // shape finds something that IS there, so the absences are real rather
        // than a mistyped key path.
        #expect(kindObject["kind"]?.stringValue == "transientShaper")

        // ⛔ NOT A COMPRESSOR: `threshold`/`thresholdDb`/`ratio` are refused
        // rather than quietly dropped. An agent that reaches for a compressor's
        // vocabulary must be told, not silently ignored.
        for missing in ["threshold", "thresholdDb", "ratio", "kneeDb"] {
            let refused = await router.handle(ControlRequest(
                id: "4", command: "fx.setParam",
                params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                         "name": .string(missing), "value": .number(1)]))
            #expect(!refused.ok,
                    Comment(rawValue: "\(missing) must not be accepted on transientShaper — it has no threshold, deliberately"))
        }

        // Legal on the master chain, like every built-in.
        let master = await router.handle(ControlRequest(
            id: "5", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("transientShaper"),
                     "params": .object(["attackDb": .number(6), "attackMs": .number(30)])]))
        #expect(master.ok)
        let masterParams = try #require(master.result?["effects"]?.arrayValue?.last?["params"])
        #expect(masterParams["attackDb"]?.doubleValue == 6)
        #expect(abs((masterParams["attackWindowMs"]?.doubleValue ?? 0) - 8.678) < 0.001)
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

    /// m39-o — the `.phaser` kind on the wire. Three things at once, because
    /// all three are places this tree has been bitten before:
    ///
    /// ⭐ **WHICH VERB CARRIES THE DERIVED FIELDS.** `notchCount` and
    /// `firstNotchHz` are built by `effectParamsJSON`, so they ride
    /// `fx.add`, `fx.setParam` and `project.snapshot` — and are **ABSENT from
    /// `fx.describe`**, which is a per-kind SCHEMA with no instance and no
    /// values. This is the `wowCents` / `channelPeakDb` shape and it has
    /// already produced one wrong sentence of prose in this repo. Both halves
    /// are asserted, and the `== nil` half carries a positive control so it
    /// cannot pass because the key path was mistyped.
    ///
    /// ⭐ **`stages` IS THE ONE SETTER WHOSE ECHO IS NOT ITS INPUT.** It snaps
    /// to an EVEN count, because an odd chain would put its last phase
    /// crossing exactly at Nyquist, where it cannot be heard or measured. A
    /// caller sending 7 gets 8 back. That is deliberate, and a caller that
    /// believed its own value had stuck would mis-read every subsequent
    /// reading, so the snap is proven ON THE WIRE and not only in the law.
    ///
    /// ⭐ **§12 gate 6 — the describe/settable bijection**, the `hallReverb`
    /// leg's shape: every declared name is SET and read back, and the refusal
    /// message for a bogus name is PARSED to prove the accepted set is not
    /// larger than the declared one either.
    @Test("m39-o: phaser rides the generic fx verbs — derived notches, the even-stage snap, the bijection")
    func phaserRidesTheGenericFXSurface() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Sweep", kind: "audio")

        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("phaser")]))
        #expect(added.ok)
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let defaults = try #require(added.result?["effects"]?.arrayValue?.first?["params"])
        #expect(defaults["rateHz"]?.doubleValue == 0.5)
        #expect(defaults["centerHz"]?.doubleValue == 300)
        #expect(defaults["depthOctaves"]?.doubleValue == 3)
        #expect(defaults["stages"]?.doubleValue == 6)
        #expect(defaults["feedback"]?.doubleValue == 0.5)
        #expect(defaults["mix"]?.doubleValue == 0.5)
        #expect(defaults["stereoPhaseDeg"]?.doubleValue == 90)

        // The derived echoes, read through their ONE HOME rather than
        // re-derived here — plus the hard numbers the notes and the MCP text
        // quote, so a change to the law that keeps both sides consistent still
        // reddens something.
        let count = try #require(defaults["notchCount"]?.doubleValue)
        let firstNotch = try #require(defaults["firstNotchHz"]?.doubleValue)
        #expect(count == Double(PhaserParams.notchCount(stages: 6)))
        #expect(count == 3, "six sections make THREE notches, not six")
        #expect(abs(firstNotch - PhaserParams.firstNotchHzAtSweepFloor(
            centerHz: 300, stages: 6)) < 1e-9)
        #expect(abs(firstNotch - 80.385) < 0.01,
                "the quoted default is not what the wire carries")

        // ⭐ THE SNAP, ON THE WIRE: 7 is accepted and answered with 8. The
        // caller's number is NOT what comes back, and both derived fields move
        // with it — `notchCount` up to four, `firstNotchHz` DOWN, because a
        // longer chain reaches its first 180° crossing further below the
        // corner (tan(π/16) = 0.199 against tan(π/12) = 0.268).
        let odd = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID),
                     "name": .string("stages"), "value": .number(7)]))
        #expect(odd.ok, "an odd stage count is SNAPPED, never refused")
        let snapped = try #require(odd.result?["effects"]?.arrayValue?.first?["params"])
        #expect(snapped["stages"]?.doubleValue == 8,
                "stages 7 must come back as 8 — the caller's value is not the stored one")
        #expect(snapped["notchCount"]?.doubleValue == 4)
        let movedNotch = try #require(snapped["firstNotchHz"]?.doubleValue)
        #expect(abs(movedNotch - 59.674) < 0.01)
        #expect(movedNotch < firstNotch,
                "more sections must move the LOWEST notch down, not up")
        // …and the field that does not depend on `stages` did not move, which
        // is what proves these are two independent derivations rather than one
        // number echoed twice.
        #expect(snapped["centerHz"]?.doubleValue == 300)

        // ⭐ THE HALF AN AGENT GETS WRONG: `fx.describe` is the SCHEMA, so
        // neither derived key is there — and no PARAM is named `notchCount`
        // either.
        let describe = await router.handle(ControlRequest(
            id: "3", command: "fx.describe", params: ["kind": .string("phaser")]))
        #expect(describe.ok)
        let kindObject = try #require(describe.result?["kinds"]?.arrayValue?.first)
        #expect(kindObject["notchCount"] == nil,
                "fx.describe must not carry an instance value")
        #expect(kindObject["firstNotchHz"] == nil,
                "fx.describe must not carry an instance value")
        // Positive control for the two `== nil` claims: the SAME lookup shape,
        // on the SAME object, finds something that IS there — so the absences
        // are real rather than a mistyped key path.
        #expect(kindObject["kind"]?.stringValue == "phaser")
        #expect(kindObject["params"]?.arrayValue?.isEmpty == false)

        // → §12 gate 6: the declared set and the SETTABLE set are the same set.
        let declared = EffectParamSpec.specs(for: .phaser)
        #expect(declared.count == 7)
        #expect(kindObject["params"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
                == declared.map(\.name))
        for (index, spec) in declared.enumerated() {
            let value = spec.range.lowerBound
                + (spec.range.upperBound - spec.range.lowerBound) * 0.37
            let response = await router.handle(ControlRequest(
                id: "set-\(index)", command: "fx.setParam",
                params: ["trackId": .string(trackID.uuidString),
                         "effectId": .string(effectID),
                         "name": .string(spec.name), "value": .number(value)]))
            #expect(response.ok, "fx.setParam refused the declared name '\(spec.name)'")
            let echoed = response.result?["effects"]?.arrayValue?.first?["params"]?[spec.name]?
                .doubleValue
            #expect(echoed != nil, "'\(spec.name)' is declared but absent from the wire echo")
            // `stages` is the ONE param whose echo is legitimately not its
            // input; it is compared against the snap law instead, so this loop
            // cannot be made to pass by a setter that silently drops values.
            let expected = spec.name == "stages"
                ? Double(PhaserParams.snappedStages(value))
                : value
            #expect(abs((echoed ?? .nan) - expected) < 1e-9,
                    "'\(spec.name)' echoed \(echoed ?? .nan), not \(expected)")
        }

        // → and the accepted set is NO LARGER: the refusal names the valid set,
        // and it is parsed rather than eyeballed. `delayMs` is the FLANGER's
        // param — the kind this one is most likely to be confused with — so a
        // switch arm that fell through to the flanger's would be caught here.
        let bogus = await router.handle(ControlRequest(
            id: "bogus", command: "fx.setParam",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID),
                     "name": .string("delayMs"), "value": .number(4)]))
        #expect(!bogus.ok, "`delayMs` belongs to the flanger and must be refused on a phaser")
        let message = try #require(bogus.error)
        #expect(message == "unknown parameter 'delayMs' for phaser effect — valid: "
                + declared.map(\.name).joined(separator: ", "),
                "the refusal message and the spec table disagree: \(message)")

        // Legal on the master chain, like every built-in, and the derived
        // fields follow params supplied AT ADD TIME rather than the defaults.
        let master = await router.handle(ControlRequest(
            id: "5", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("phaser"),
                     "params": .object(["centerHz": .number(500), "stages": .number(12)])]))
        #expect(master.ok)
        let masterParams = try #require(master.result?["effects"]?.arrayValue?.last?["params"])
        #expect(masterParams["centerHz"]?.doubleValue == 500)
        #expect(masterParams["stages"]?.doubleValue == 12)
        #expect(masterParams["notchCount"]?.doubleValue == 6)
        #expect(abs((masterParams["firstNotchHz"]?.doubleValue ?? 0) - 500
                    * PhaserParams.notchRatio(stages: 12, index: 0)) < 1e-9)
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
        // m39-f-3: `modulatable` IS on `fx.describe`'s per-param object now.
        // `position`'s verdict lives in `EffectParamSpec` and is pinned by
        // `ModulationTests.djFilterVerdictsMatch`; this just confirms the same
        // fact reaches the wire.
        #expect(params[0]["modulatable"]?.stringValue == "yes")
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

    /// m39-w4-4 — THE UNLOCK (W9-UNLOCK, 2026-10-11). This test was the PIN
    /// `w44StepDivisionStillRefusesOnTheWire` ("stepDivision still refuses on
    /// mod.addSource AND mod.setSource"); the unlock FLIPPED it on purpose,
    /// after m39-d-cr12 made live equal the bounce and G8
    /// (`StepDivisionG8Tests`) measured it for a synced source. The LFO's
    /// `syncDivision` still refuses (`tempoSyncRefusesOnTheWire` above).
    @Test("m39-w4-4 unlock: stepDivision is ACCEPTED on mod.addSource AND mod.setSource, kept by later edits, cleared by null; '1/17' and a number refuse, listing every value")
    func w44StepDivisionIsAcceptedOnTheWire() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Beat", kind: "audio")
        func setSource(_ sourceID: String, _ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(
                id: "w44-set", command: "mod.setSource",
                params: ["trackId": .string(trackID.uuidString), "sourceId": .string(sourceID),
                         "params": .object(params)]))
        }
        func division(_ response: ControlResponse) -> String? {
            response.result?["source"]?["params"]?["stepDivision"]?.stringValue
        }
        let note = try #require(TempoSync.inertRateNote(
            for: .stepSequencer(StepSequencerSourceParams(stepDivision: "1/16"))))

        // addSource with the division alone: accepted, stored, and told that rateHz is now inert.
        let added = await addModSource(router, trackID: trackID.uuidString, kind: "stepSequencer",
                                       params: ["stepDivision": .string("1/16")])
        #expect(added.ok, "\(added.error ?? "")")
        #expect(division(added) == "1/16")
        let addWarnings = added.result?["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(addWarnings == ["\(ModulationWarning.paramIgnored): \(note)"])
        let addedID = try #require(added.result?["sourceId"]?.stringValue)

        // setSource {steps}: KEEPS the division (before the unlock this rebuilt it with stepDivision nil) and
        // repeats no warning.
        let kept = await setSource(addedID, ["steps": .array([.number(0), .number(1), .number(0)])])
        #expect(kept.ok)
        #expect(division(kept) == "1/16", "an edit that does not name stepDivision must not un-sync the source")
        #expect((kept.result?["warnings"]?.arrayValue ?? []).isEmpty)

        // setSource syncs a plain source, and null runs it free again.
        let plain = await addModSource(router, trackID: trackID.uuidString, kind: "stepSequencer")
        let plainID = try #require(plain.result?["sourceId"]?.stringValue)
        let synced = await setSource(plainID, ["stepDivision": .string("1/8t")])
        #expect(synced.ok && division(synced) == "1/8t")
        let cleared = await setSource(plainID, ["stepDivision": .null])
        #expect(cleared.ok && division(cleared) == nil)
        #expect((cleared.result?["warnings"]?.arrayValue ?? []).isEmpty)

        // Anything else refuses, listing the values that work, and changes nothing.
        let before = try store.modulationState(of: .track(trackID)).sources
        let bad = await setSource(addedID, ["stepDivision": .string("1/17")])
        #expect(!bad.ok)
        let message = bad.error ?? ""
        #expect(message.contains("stepDivision") && message.contains("1/16") && message.contains("1/32t"),
                "\(message)")
        let badAdd = await addModSource(router, trackID: trackID.uuidString, kind: "stepSequencer",
                                        params: ["stepDivision": .number(16)])
        #expect(!badAdd.ok && (badAdd.error ?? "").contains("1/16"))
        #expect(try store.modulationState(of: .track(trackID)).sources == before)
        let model = try store.modulationState(of: .track(trackID)).sources.compactMap { source -> String? in
            guard case .stepSequencer(let step) = source.params else { return nil }
            return step.stepDivision ?? "free"
        }
        #expect(model == ["1/16", "free"])
        print("[measured] W9-UNLOCK wire: add \(division(added) ?? "nil") warned \(addWarnings.count), "
              + "steps edit kept \(division(kept) ?? "nil"), set \(division(synced) ?? "nil"), null "
              + "\(division(cleared) ?? "nil"); '1/17' refused: \(message.prefix(90))")
    }

    /// m39-w4-4e (W9-UNLOCK): `mod.describe` says what a synced source does,
    /// in the words the setter used (design §4.4).
    @Test("m39-w4-4e: mod.describe gives a synced source a tempoSync block — stepDivision, stepsPerBar at the meter in force (16 in 4/4, 12 after a 3/4 change), the restart sentence, and the setter's rateHz sentence verbatim; a free source has none")
    func w44ModDescribeReportsTempoSync() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Gate", kind: "audio")
        let added = await addModSource(router, trackID: trackID.uuidString, kind: "stepSequencer",
                                       params: ["stepDivision": .string("1/16"),
                                                "steps": .array([.number(1), .number(0), .number(0)])])
        let addedID = try #require(added.result?["sourceId"]?.stringValue)
        let warning = try #require(added.result?["warnings"]?.arrayValue?.first?.stringValue)
        let free = await addModSource(router, trackID: trackID.uuidString, kind: "stepSequencer")
        let freeID = try #require(free.result?["sourceId"]?.stringValue)
        let route = await router.handle(ControlRequest(
            id: "route", command: "mod.addRoute",
            params: ["trackId": .string(trackID.uuidString), "sourceId": .string(addedID),
                     "target": .object(["type": .string("volume")]), "depth": .number(-0.25)]))
        #expect(route.ok)
        let map = await router.handle(ControlRequest(
            id: "map", command: "tempo.setMap",
            params: ["segments": .array([.object(["startBeat": .number(0), "bpm": .number(120)])]),
                     "meterChanges": .array([
                        .object(["startBeat": .number(0), "beatsPerBar": .number(4), "beatUnit": .number(4)]),
                        .object(["startBeat": .number(16), "beatsPerBar": .number(3), "beatUnit": .number(4)]),
                     ])]))
        #expect(map.ok, "\(map.error ?? "")")
        func sources(atBeat beat: Double) async throws -> [String: [String: JSONValue]] {
            let described = await router.handle(ControlRequest(
                id: "d", command: "mod.describe",
                params: ["trackId": .string(trackID.uuidString), "atBeat": .number(beat)]))
            #expect(described.ok)
            let strips = try #require(described.result?["strips"]?.arrayValue)
            let list = try #require(strips.first?["sources"]?.arrayValue)
            var result: [String: [String: JSONValue]] = [:]
            for entry in list {
                guard let object = entry.objectValue, let id = object["id"]?.stringValue else { continue }
                result[id] = object
            }
            return result
        }
        let at4 = try await sources(atBeat: 4)
        let sync4 = try #require(at4[addedID]?["tempoSync"]?.objectValue)
        #expect(sync4["stepDivision"]?.stringValue == "1/16")
        #expect(sync4["stepsPerBar"]?.doubleValue == 16)
        #expect(sync4["meter"]?.stringValue == "4/4")
        let restart = sync4["restart"]?.stringValue ?? ""
        #expect(restart.contains("starts again from step 1 at every time-signature change"), "\(restart)")
        #expect(restart.contains("does not line up"), "3 steps of 1/16 in a 4/4 bar: \(restart)")
        #expect(warning == "\(ModulationWarning.paramIgnored): \(sync4["rateHzNote"]?.stringValue ?? "<none>")",
                "describe must repeat the setter's sentence verbatim")
        #expect(at4[freeID] != nil && at4[freeID]?["tempoSync"] == nil, "a free source carries no tempoSync")
        let at17 = try await sources(atBeat: 17)
        let sync17 = try #require(at17[addedID]?["tempoSync"]?.objectValue)
        #expect(sync17["stepsPerBar"]?.doubleValue == 12)
        #expect(sync17["meter"]?.stringValue == "3/4")
        #expect((sync17["restart"]?.stringValue ?? "").contains("plays 4 times per bar"))
        print("[measured] W9-UNLOCK describe tempoSync @4: \(sync4["stepsPerBar"]?.doubleValue ?? -1) per bar "
              + "(\(sync4["meter"]?.stringValue ?? "?")), @17: \(sync17["stepsPerBar"]?.doubleValue ?? -1) "
              + "(\(sync17["meter"]?.stringValue ?? "?"))")
    }

    // MARK: - m39-w4-4c (W8-W44G) — mod.describe reads a SYNCED step source the way the render does
    //
    // Appended here, not in a new suite: `CommandRouter` is main-actor isolated
    // and the @MainActor suite cap is spent. The DAWCore closed form these
    // reach is pinned bit for bit against the render evaluator in
    // `Tests/DAWEngineTests/ModDescribeClockAgreementTests.swift`.

    /// A track with ONE step source routed to volume, its `stepDivision` written
    /// the way these tests were first built: by hand (the wire now accepts
    /// `stepDivision`, so this is just one more way to reach a synced project).
    /// The project is saved with a FREE source, the key is added to
    /// `project.json`, and the file is reopened. Returns the router,
    /// the store, the track and the scratch folder (the caller removes it).
    private func w44gHandEditedSyncedStep(steps: [Double], division: String)
        async throws -> (router: CommandRouter, store: ProjectStore, trackID: UUID, folder: URL) {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Gate", kind: "audio")
        let tempo = await router.handle(ControlRequest(
            id: "tempo", command: "transport.setTempo", params: ["bpm": .number(90)]))
        #expect(tempo.ok)
        let source = await addModSource(router, trackID: trackID.uuidString, kind: "stepSequencer",
                                        params: ["steps": .array(steps.map { .number($0) })])
        #expect(source.ok)
        let sourceID = try #require(source.result?["sourceId"]?.stringValue)
        let route = await router.handle(ControlRequest(
            id: "route", command: "mod.addRoute",
            params: ["trackId": .string(trackID.uuidString), "sourceId": .string(sourceID),
                     "target": .object(["type": .string("volume")]), "depth": .number(-0.25)]))
        #expect(route.ok)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("w44g-synced-step-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = try store.saveProject(to: folder.appendingPathComponent("Synced Gate").path)
        let json = URL(fileURLWithPath: saved.path).appendingPathComponent("project.json")
        var edits = 0
        func addDivision(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["kind"] as? String == "stepSequencer", object["steps"] != nil {
                    object["stepDivision"] = division
                    edits += 1
                }
                return object.mapValues(addDivision)
            }
            if let array = value as? [Any] { return array.map(addDivision) }
            return value
        }
        let edited = addDivision(try JSONSerialization.jsonObject(with: Data(contentsOf: json)))
        #expect(edits == 1, "exactly one step source's params in the saved file")
        try JSONSerialization.data(withJSONObject: edited).write(to: json)
        _ = try store.openProject(at: saved.path, discardChanges: true)
        let state = try store.modulationState(of: .track(trackID))
        guard case .stepSequencer(let params) = try #require(state.sources.first).params else {
            Issue.record("the reopened source is not a step source")
            return (router, store, trackID, folder)
        }
        #expect(params.stepDivision == division, "the hand edit reached the project")
        #expect(state.routes.count == 1)
        return (router, store, trackID, folder)
    }

    private func w44gDescribe(_ router: CommandRouter, trackID: UUID, atBeat beat: Double)
        async throws -> [String: JSONValue] {
        let described = await router.handle(ControlRequest(
            id: "d", command: "mod.describe",
            params: ["trackId": .string(trackID.uuidString), "atBeat": .number(beat)]))
        #expect(described.ok)
        let strips = try #require(described.result?["strips"]?.arrayValue)
        let effective = try #require(strips.first?["effective"]?.arrayValue)
        return try #require(effective.first?.objectValue)
    }

    @Test("m39-w4-4c: mod.describe reads a hand-edited SYNCED [1,0] 1/16 at 90 BPM on the beat — step 1 (0) at beat 0.25, where rateHz free-running said 1")
    func modDescribeSyncedStepReadsTheMusicalClock() async throws {
        // Control first: the SAME source before the hand edit runs free at
        // rateHz 4, and describe says 1 at beat 0.25 (0.667 of a 1/4 s step).
        let (freeRouter, _) = makeRouter()
        let freeTrack = await addTrack(freeRouter, name: "Free", kind: "audio")
        _ = await freeRouter.handle(ControlRequest(
            id: "tempo", command: "transport.setTempo", params: ["bpm": .number(90)]))
        let freeSource = await addModSource(freeRouter, trackID: freeTrack.uuidString, kind: "stepSequencer",
                                            params: ["steps": .array([.number(1), .number(0)])])
        let freeSourceID = try #require(freeSource.result?["sourceId"]?.stringValue)
        _ = await freeRouter.handle(ControlRequest(
            id: "route", command: "mod.addRoute",
            params: ["trackId": .string(freeTrack.uuidString), "sourceId": .string(freeSourceID),
                     "target": .object(["type": .string("volume")]), "depth": .number(-0.25)]))
        _ = await freeRouter.handle(ControlRequest(id: "play", command: "transport.play"))
        let freeEntry = try await w44gDescribe(freeRouter, trackID: freeTrack, atBeat: 0.25)
        #expect(freeEntry["sourceValue"]?.doubleValue == 1, "what describe reported before the fix")

        let (router, store, trackID, folder) = try await w44gHandEditedSyncedStep(steps: [1, 0], division: "1/16")
        defer { try? FileManager.default.removeItem(at: folder) }

        // Stopped: neutral, like the render (§7.8).
        #expect(!store.transport.isPlaying)
        let stopped = try await w44gDescribe(router, trackID: trackID, atBeat: 0.25)
        #expect(stopped["sourceValue"]?.doubleValue == 0)

        let play = await router.handle(ControlRequest(id: "play", command: "transport.play"))
        #expect(play.ok && store.transport.isPlaying)
        let onStep1 = try await w44gDescribe(router, trackID: trackID, atBeat: 0.25)
        let onStep0 = try await w44gDescribe(router, trackID: trackID, atBeat: 0.5)
        let value1 = try #require(onStep1["sourceValue"]?.doubleValue)
        let value0 = try #require(onStep0["sourceValue"]?.doubleValue)
        print("[measured] m39-w4-4c wire describe, synced [1,0] 1/16 @90: beat 0.25 → \(value1), 0.5 → \(value0); "
              + "free-running control at 0.25 → \(freeEntry["sourceValue"]?.doubleValue ?? .nan)")
        #expect(abs(value1) < 1e-9, "beat 0.25 is step 1 of a 1/16 pattern")
        #expect(abs(value0 - 1) < 1e-9, "beat 0.5 wraps to step 0")
        #expect(onStep1["sourceValueNote"] == nil, "the envelope follower's sentence must not label a step source")
        // The modulated value follows the source: step 1 (0) leaves the knob alone.
        #expect(onStep1["modulatedValue"]?.doubleValue == onStep1["baseValue"]?.doubleValue)
        #expect(onStep0["modulatedValue"]?.doubleValue != onStep0["baseValue"]?.doubleValue)

        // ONE HOME: at every probed beat (on the grid, between, and inside the
        // 2 ms trailing ramp) describe reports exactly the DAWCore closed form.
        let state = try store.modulationState(of: .track(trackID))
        guard case .stepSequencer(let params) = try #require(state.sources.first).params else {
            Issue.record("not a step source")
            return
        }
        var beats: [Double] = [0.2485, 0.2475, 0.7485, 3.9985]
        var k = 0
        while k < 48 { beats.append(Double(k) * 0.0625 + 0.01); k += 1 }
        var mismatches = 0
        var ramps = 0
        for beat in beats {
            let entry = try await w44gDescribe(router, trackID: trackID, atBeat: beat)
            let reported = try #require(entry["sourceValue"]?.doubleValue)
            let home = try #require(ModulationMath.syncedStepValue(
                params, atBeat: beat, tempoMap: store.transport.tempoMap,
                meterMap: store.transport.meterMap, sampleRate: 48_000))
            if reported.bitPattern != home.bitPattern { mismatches += 1 }
            if reported > 1e-9 && reported < 1 - 1e-9 { ramps += 1 }
        }
        #expect(mismatches == 0)
        #expect(ramps >= 2, "the probe set reaches inside the trailing edge")
    }

    @Test("m39-w4-4c: mod.describe restarts a synced pattern at a meter change — [1,0,0] at 1/4 reads step 0 at beat 16 after 4/4 → 3/4")
    func modDescribeSyncedStepRestartsAtAMeterChange() async throws {
        let (router, store, trackID, folder) = try await w44gHandEditedSyncedStep(steps: [1, 0, 0], division: "1/4")
        defer { try? FileManager.default.removeItem(at: folder) }
        let play = await router.handle(ControlRequest(id: "play", command: "transport.play"))
        #expect(play.ok && store.transport.isPlaying)
        // Control: one 4/4 meter — beat 16 is 16 mod 3 = step 1.
        let constant = try await w44gDescribe(router, trackID: trackID, atBeat: 16)
        #expect(abs(try #require(constant["sourceValue"]?.doubleValue)) < 1e-9)

        let meter = await router.handle(ControlRequest(
            id: "meter", command: "tempo.setMap",
            params: ["segments": .array([.object(["startBeat": .number(0), "bpm": .number(90)])]),
                     "meterChanges": .array([
                        .object(["startBeat": .number(0), "beatsPerBar": .number(4), "beatUnit": .number(4)]),
                        .object(["startBeat": .number(16), "beatsPerBar": .number(3), "beatUnit": .number(4)]),
                     ])]))
        #expect(meter.ok, "\(meter.error ?? "")")
        #expect(store.transport.meterMap.changes.count == 2)
        var readings: [Double] = []
        for beat in [15.0, 16, 17, 18, 19] {
            let entry = try await w44gDescribe(router, trackID: trackID, atBeat: beat)
            readings.append(try #require(entry["sourceValue"]?.doubleValue))
        }
        print("[measured] m39-w4-4c wire describe, [1,0,0] 1/4, 4/4 → 3/4 at 16: beats 15…19 → \(readings)")
        let expected: [Double] = [1, 1, 0, 0, 1]
        for (got, want) in zip(readings, expected) { #expect(abs(got - want) < 1e-9) }
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

    // MARK: - m27-f: fx.getParams (read-only)

    private func undoSnapshot(_ store: ProjectStore) -> (labels: [String], redo: [String], canUndo: Bool, dirty: Bool) {
        let history = store.undoHistory()
        return (history.undo, history.redo, store.canUndo, store.isDirty)
    }

    @Test("m27-f: fx.getParams answers with the same chain fx.setBypass returns, and echoes effectId")
    func fxGetParamsMatchesMutationReply() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)
        let tid = JSONValue.string(trackID.uuidString)
        let eid = JSONValue.string(effectID.uuidString)

        let set = await router.handle(ControlRequest(
            id: "1", command: "fx.setParam",
            params: ["trackId": tid, "effectId": eid, "name": .string("gainLinear"), "value": .number(2)]))
        #expect(set.ok)
        let read = await router.handle(ControlRequest(
            id: "2", command: "fx.getParams", params: ["trackId": tid, "effectId": eid]))
        #expect(read.ok)
        #expect(read.result?["effectId"]?.stringValue == effectID.uuidString)
        #expect(read.result?["trackId"]?.stringValue == trackID.uuidString)
        // Same encoder, so the chain is value-for-value what the write reported.
        #expect(read.result?["effects"] == set.result?["effects"])
        let effect = try #require(read.result?["effects"]?.arrayValue?.first)
        #expect(effect["kind"]?.stringValue == "gain")
        #expect(effect["params"]?["gainLinear"]?.doubleValue == 2)
        #expect(effect["isBypassed"]?.boolValue == false)
    }

    @Test("m27-f: fx.getParams adds no undo entry, no dirty mark; the control (fx.setBypass) does")
    func fxGetParamsIsReadOnly() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)
        let master = await router.handle(ControlRequest(
            id: "m", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("gain")]))
        let masterEffectID = try #require(master.result?["effectId"]?.stringValue)
        let engine = StubLatencyEngine()
        store.engine = engine

        let before = undoSnapshot(store)
        #expect(!before.labels.isEmpty, "the setup edits must be on the stack, or the comparison proves nothing")
        let seqBefore = store.lastEditEvent?.seq
        for _ in 0..<3 {
            let a = await router.handle(ControlRequest(
                id: "r", command: "fx.getParams",
                params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID.uuidString)]))
            #expect(a.ok)
            let b = await router.handle(ControlRequest(
                id: "r", command: "fx.getParams",
                params: ["trackId": .string("master"), "effectId": .string(masterEffectID)]))
            #expect(b.ok)
        }
        let after = undoSnapshot(store)
        #expect(after.labels == before.labels)
        #expect(after.redo == before.redo)
        #expect(after.canUndo == before.canUndo)
        #expect(after.dirty == before.dirty)
        #expect(store.lastEditEvent?.seq == seqBefore)

        // POSITIVE CONTROL: a real bypass change does grow the stack (so the
        // equality above could have failed). MEASURED while writing this: a
        // false->false setBypass on THIS tree journals nothing (performEdit
        // skips a no-op), so the control uses a real change (true).
        let bypass = await router.handle(ControlRequest(
            id: "b", command: "fx.setBypass",
            params: ["trackId": .string(trackID.uuidString),
                     "effectId": .string(effectID.uuidString), "bypassed": .bool(true)]))
        #expect(bypass.ok)
        #expect(undoSnapshot(store).labels != before.labels)
    }

    @Test("m27-f: fx.getParams refuses unknown track / effect with fx.setBypass's own sentences")
    func fxGetParamsRefusalsMatchSetBypass() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID)
        let ghostTrack = UUID().uuidString
        let ghostEffect = UUID().uuidString

        func both(_ track: String, _ effect: String) async -> (String?, String?) {
            let read = await router.handle(ControlRequest(
                id: "g", command: "fx.getParams",
                params: ["trackId": .string(track), "effectId": .string(effect)]))
            let write = await router.handle(ControlRequest(
                id: "s", command: "fx.setBypass",
                params: ["trackId": .string(track), "effectId": .string(effect), "bypassed": .bool(true)]))
            #expect(!read.ok && !write.ok)
            return (read.error, write.error)
        }
        let t = await both(ghostTrack, effectID.uuidString)
        #expect(t.0 != nil && t.0 == t.1)
        let e = await both(trackID.uuidString, ghostEffect)
        #expect(e.0 != nil && e.0 == e.1)
        let m = await both("master", ghostEffect)
        #expect(m.0 != nil && m.0 == m.1)

        let extra = await router.handle(ControlRequest(
            id: "x", command: "fx.getParams",
            params: ["trackId": .string(trackID.uuidString), "effectId": .string(effectID.uuidString),
                     "bypassed": .bool(true)]))
        #expect(!extra.ok)
    }

}
