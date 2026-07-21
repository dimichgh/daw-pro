import Foundation
import Testing
@testable import DAWCore

/// m22-a EQ v2 model-layer tests: the additive-optional encoding (nil OMITTED
/// on disk — legacy projects decode AND re-encode byte-compatible, the
/// SamplerZone/sidechainSourceTrackID precedent), clamping/snapping, the
/// resolved nil semantics, and the store's name→field mapping for the new
/// wire names (including the HP/LP enable-materializes-a-corner rule).
@MainActor
@Suite("EQ v2 params — additive encoding + store mapping")
struct EQv2ParamsTests {

    /// A pre-m22-a params payload, exactly as a legacy project stores it.
    private static let legacyJSON = """
        {"lowShelfFreq":100,"lowShelfGainDb":3,"peak1Freq":500,"peak1GainDb":-2,\
        "peak1Q":1.5,"peak2Freq":3000,"peak2GainDb":0,"peak2Q":1,\
        "highShelfFreq":8000,"highShelfGainDb":-4}
        """

    private static let v2Keys = [
        "highPassFreq", "highPassSlopeDbPerOct", "highPassEnabled",
        "lowPassFreq", "lowPassSlopeDbPerOct", "lowPassEnabled",
        "lowShelfQ", "highShelfQ",
        "lowShelfEnabled", "peak1Enabled", "peak2Enabled", "highShelfEnabled",
    ]

    // MARK: - Decode legacy / encode all-nil

    @Test("legacy JSON decodes with every v2 field nil and legacy resolved views")
    func legacyJSONDecodesAllNil() throws {
        let params = try JSONDecoder().decode(EQParams.self, from: Data(Self.legacyJSON.utf8))
        #expect(params.lowShelfGainDb == 3)
        #expect(params.peak1Q == 1.5)
        #expect(params.highPassFreq == nil)
        #expect(params.highPassSlopeDbPerOct == nil)
        #expect(params.highPassEnabled == nil)
        #expect(params.lowPassFreq == nil)
        #expect(params.lowPassSlopeDbPerOct == nil)
        #expect(params.lowPassEnabled == nil)
        #expect(params.lowShelfQ == nil)
        #expect(params.highShelfQ == nil)
        #expect(params.lowShelfEnabled == nil)
        #expect(params.peak1Enabled == nil)
        #expect(params.peak2Enabled == nil)
        #expect(params.highShelfEnabled == nil)
        // The resolved views read exactly the pre-m22-a behavior.
        #expect(!params.resolvedHighPassEnabled)     // HP off
        #expect(!params.resolvedLowPassEnabled)      // LP off
        #expect(params.resolvedHighPassSlope == 12)
        #expect(params.resolvedLowPassSlope == 12)
        #expect(params.resolvedLowShelfQ == EQParams.defaultShelfQ)
        #expect(params.resolvedHighShelfQ == EQParams.defaultShelfQ)
        #expect(params.resolvedLowShelfEnabled)
        #expect(params.resolvedPeak1Enabled)
        #expect(params.resolvedPeak2Enabled)
        #expect(params.resolvedHighShelfEnabled)
        // 1/√2 — the RBJ S = 1 shelf's effective Q, the documented nil default.
        #expect(EQParams.defaultShelfQ == (0.5 as Double).squareRoot())
    }

    @Test("all-nil params encode with NO v2 keys (legacy byte-compat) and round-trip")
    func allNilEncodesWithoutV2Keys() throws {
        let params = EQParams(lowShelfGainDb: 3, peak1GainDb: -2)
        let data = try JSONEncoder().encode(params)
        let json = String(decoding: data, as: UTF8.self)
        for key in Self.v2Keys {
            #expect(!json.contains("\"\(key)\""), "nil \(key) must be OMITTED on disk")
        }
        let decoded = try JSONDecoder().decode(EQParams.self, from: data)
        #expect(decoded == params)

        // Non-nil v2 fields DO travel and round-trip through the clamping init.
        let v2 = EQParams(highPassFreq: 150, highPassSlopeDbPerOct: 24,
                          lowPassFreq: 9_000, lowShelfQ: 2, peak1Enabled: false)
        let v2Decoded = try JSONDecoder().decode(EQParams.self, from: JSONEncoder().encode(v2))
        #expect(v2Decoded == v2)
        #expect(v2Decoded.highPassFreq == 150)
        #expect(v2Decoded.highPassSlopeDbPerOct == 24)
        #expect(v2Decoded.peak1Enabled == false)
        #expect(v2Decoded.highShelfQ == nil)         // untouched stays nil
    }

    // MARK: - Clamp + snap

    @Test("HP/LP corners clamp to their ranges; slopes snap to 12 or 24")
    func clampAndSnap() {
        #expect(EQParams(highPassFreq: 5).highPassFreq == 20)
        #expect(EQParams(highPassFreq: 5_000).highPassFreq == 1_000)
        #expect(EQParams(lowPassFreq: 100).lowPassFreq == 1_000)
        #expect(EQParams(lowPassFreq: 96_000).lowPassFreq == 20_000)
        #expect(EQParams(highPassSlopeDbPerOct: 17).highPassSlopeDbPerOct == 12)
        #expect(EQParams(highPassSlopeDbPerOct: 18).highPassSlopeDbPerOct == 24)
        #expect(EQParams(lowPassSlopeDbPerOct: 96).lowPassSlopeDbPerOct == 24)
        #expect(EQParams(lowShelfQ: 0.01).lowShelfQ == 0.1)
        #expect(EQParams(highShelfQ: 99).highShelfQ == 18)
        // nil stays nil through the init (off must survive re-construction).
        let untouched = EQParams()
        #expect(untouched.highPassFreq == nil && untouched.lowPassFreq == nil)
    }

    // MARK: - Store mapping (the fx.setParam path)

    @Test("legacy-name edits keep every v2 field nil (projects stay byte-compatible)")
    func legacyEditsKeepV2Nil() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let eq = try store.addEffect(toTrack: t.id, kind: .eq)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "peak1GainDb", value: 6)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "lowShelfFreq", value: 150)
        let params = try #require(store.tracks[0].effects[0].eq)
        #expect(params.peak1GainDb == 6 && params.lowShelfFreq == 150)
        #expect(params.highPassFreq == nil)
        #expect(params.lowPassFreq == nil)
        #expect(params.lowShelfQ == nil && params.highShelfQ == nil)
        #expect(params.lowShelfEnabled == nil && params.peak1Enabled == nil)
        #expect(params.peak2Enabled == nil && params.highShelfEnabled == nil)
        #expect(params.highPassEnabled == nil && params.lowPassEnabled == nil)
        #expect(params.highPassSlopeDbPerOct == nil && params.lowPassSlopeDbPerOct == nil)
    }

    @Test("v2 names map onto their fields; setting an HP/LP corner activates it")
    func v2NamesMapOntoFields() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let eq = try store.addEffect(toTrack: t.id, kind: .eq)
        func params() -> EQParams { store.tracks[0].effects[0].resolvedEQ }

        // Setting the corner turns the filter on.
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "highPassFreq", value: 250)
        #expect(params().highPassFreq == 250)
        #expect(params().resolvedHighPassEnabled)

        // Slope snaps through the store too (spec range is 12…24 continuous).
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id,
                                     name: "highPassSlopeDbPerOct", value: 20)
        #expect(params().highPassSlopeDbPerOct == 24)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id,
                                     name: "highPassSlopeDbPerOct", value: 13)
        #expect(params().highPassSlopeDbPerOct == 12)

        // Bypassing keeps the corner; re-enabling restores it.
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "highPassEnabled", value: 0)
        #expect(params().highPassFreq == 250)
        #expect(params().highPassEnabled == false)
        #expect(!params().resolvedHighPassEnabled)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "highPassEnabled", value: 1)
        #expect(params().resolvedHighPassEnabled && params().highPassFreq == 250)

        // Enabling an LP that never had a corner materializes the spec default
        // (20 kHz) so the toggle is never a silent no-op.
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "lowPassEnabled", value: 1)
        #expect(params().lowPassFreq == 20_000)
        #expect(params().resolvedLowPassEnabled)

        // Shelf Q + per-band bypass binaries (≥ 0.5 = on, the pingPong rule).
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "lowShelfQ", value: 2.5)
        #expect(params().lowShelfQ == 2.5)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "peak2Enabled", value: 0.4)
        #expect(params().peak2Enabled == false)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "peak2Enabled", value: 0.7)
        #expect(params().peak2Enabled == true)
    }

    @Test("v2 fields round-trip through a .dawproj bundle; legacy fields untouched")
    func v2RoundTripsThroughBundle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eqv2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let eq = try store.addEffect(toTrack: t.id, kind: .eq)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "highPassFreq", value: 120)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id,
                                     name: "highPassSlopeDbPerOct", value: 24)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "highShelfQ", value: 1.4)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "peak1Enabled", value: 0)
        let path = dir.appendingPathComponent("EQv2").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reParams = try #require(
            reopened.tracks.first(where: { $0.name == "Vox" })?.effects.first?.eq)
        #expect(reParams.highPassFreq == 120)
        #expect(reParams.highPassSlopeDbPerOct == 24)
        #expect(reParams.highShelfQ == 1.4)
        #expect(reParams.peak1Enabled == false)
        // Untouched v2 fields come back nil, not defaulted-in.
        #expect(reParams.lowPassFreq == nil)
        #expect(reParams.lowShelfQ == nil)
        #expect(reParams.peak2Enabled == nil)
    }
}
