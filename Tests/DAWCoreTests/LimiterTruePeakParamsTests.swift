import Foundation
import Testing
@testable import DAWCore

/// m23-ch — the SCHEMA half of the limiter's opt-in true-peak mode: the flag's
/// default, its wire spec slot, and above all BACKWARD COMPATIBILITY. Every
/// project saved before m23-ch stores `limiter: {ceilingDb, releaseMs}` with
/// no `truePeak` key; those files must keep decoding, and must decode to the
/// sample-peak behaviour they were mixed against. A user's real session is on
/// disk right now with `ceilingDb: -3` and that exact shape.
///
/// The DSP half lives in `DAWEngineTests/LimiterTruePeakTests`.
@MainActor
@Suite("m23-ch limiter true-peak — params, schema, persistence")
struct LimiterTruePeakParamsTests {

    // MARK: - Default OFF

    @Test("truePeak defaults OFF everywhere a limiter can come from")
    func defaultsOff() {
        #expect(LimiterParams().truePeak == false)
        #expect(LimiterParams(ceilingDb: -3).truePeak == false)
        #expect(LimiterParams(ceilingDb: -1, releaseMs: 50).truePeak == false)
        #expect(EffectDescriptor(kind: .limiter).resolvedLimiter.truePeak == false)
        // The spec table's default is the struct's default — a card or an
        // agent reading `fx.describe` must not be told a different story.
        let spec = EffectParamSpec.specs(for: .limiter).first { $0.name == "truePeak" }
        #expect(spec?.defaultValue == 0)
        #expect(spec?.range == 0...1)
        #expect(spec?.unit == "linear")
    }

    // MARK: - Slot order (automation stability)

    @Test("truePeak is APPENDED at slot 2 — ceilingDb and releaseMs never move")
    func specSlotOrder() {
        let names = EffectParamSpec.specs(for: .limiter).map(\.name)
        #expect(names == ["ceilingDb", "releaseMs", "truePeak"])
        // Automation lanes address params by spec INDEX; moving 0/1 would
        // silently repoint every saved limiter lane in every existing project.
        #expect(names.firstIndex(of: "ceilingDb") == 0)
        #expect(names.firstIndex(of: "releaseMs") == 1)
    }

    // MARK: - Backward compatibility (the load-bearing leg)

    @Test("a pre-m23-ch limiter JSON with NO truePeak key decodes to false")
    func legacyJSONDecodesToFalse() throws {
        // Byte-for-byte the shape `ProjectStore` wrote before m23-ch, at the
        // user's own ceiling.
        // These are the LITERAL bytes in a real user session on disk
        // (edm-trance-by-codex-sol-max.dawproj, savedAt 2026-08-04T22:56:23Z,
        // masterEffects[1].limiter), transcribed here so the regression is
        // pinned by the file that motivated m23-ch rather than by a guess.
        let legacy = Data(#"{"ceilingDb":-3,"releaseMs":120}"#.utf8)
        let params = try JSONDecoder().decode(LimiterParams.self, from: legacy)
        #expect(params.ceilingDb == -3)
        #expect(params.releaseMs == 120)
        #expect(params.truePeak == false, "an older project must load as SAMPLE peak")
        // …and it is `==` to the same params constructed fresh, so nothing
        // downstream sees a spurious change (the engine's `apply` is
        // change-gated on exactly this equality).
        #expect(params == LimiterParams(ceilingDb: -3, releaseMs: 120))
    }

    @Test("a whole legacy effect descriptor (limiter nested) still decodes")
    func legacyDescriptorDecodes() throws {
        let legacy = Data("""
            {"id":"6B2C7C6E-1B1E-4E36-9A0F-2E1D4C5A7B90","kind":"limiter",\
            "isBypassed":false,"limiter":{"ceilingDb":-3,"releaseMs":120}}
            """.utf8)
        let descriptor = try JSONDecoder().decode(EffectDescriptor.self, from: legacy)
        #expect(descriptor.kind == .limiter)
        #expect(descriptor.resolvedLimiter.ceilingDb == -3)
        #expect(descriptor.resolvedLimiter.releaseMs == 120)
        #expect(descriptor.resolvedLimiter.truePeak == false)
    }

    @Test("truePeak round-trips through encode → decode in both states")
    func roundTrips() throws {
        for flag in [false, true] {
            let original = LimiterParams(ceilingDb: -1.5, releaseMs: 120, truePeak: flag)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(LimiterParams.self, from: data)
            #expect(decoded == original)
            #expect(decoded.truePeak == flag)
            // The key IS written (a synthesized encoder emits every property),
            // so a newer file read by an older build simply ignores it.
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains("truePeak"))
        }
    }

    // MARK: - The generic fx surface carries it (no new wire verb)

    @Test("setEffectParam drives truePeak through the SAME generic path as ceilingDb")
    func setsThroughTheGenericParamPath() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try store.addEffect(toTrack: track.id, kind: .limiter)

        func limiter() -> LimiterParams {
            store.tracks[0].effects[0].resolvedLimiter
        }
        #expect(limiter().truePeak == false)
        _ = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                     name: "truePeak", value: 1)
        #expect(limiter().truePeak == true)
        // The ≥ 0.5 snap, the house convention for every binary param.
        _ = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                     name: "truePeak", value: 0.7)
        #expect(limiter().truePeak == true)
        _ = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                     name: "truePeak", value: 0.4)
        #expect(limiter().truePeak == false)
        // Out-of-range clamps rather than erroring (the spec-range contract).
        _ = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                     name: "truePeak", value: 99)
        #expect(limiter().truePeak == true)
        // The ceiling is untouched by any of it.
        #expect(limiter().ceilingDb == -1)
    }

    @Test("the master mastering limiter takes truePeak and survives save → reopen")
    func masterChainPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("limiter-tp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Mastered").path

        let store = ProjectStore()
        let limiter = try store.addMasterEffect(kind: .limiter)
        _ = try store.setMasterEffectParam(effectID: limiter.id, name: "ceilingDb", value: -1)
        _ = try store.setMasterEffectParam(effectID: limiter.id, name: "truePeak", value: 1)
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        _ = try reopened.openProject(at: path)
        let reloaded = try #require(reopened.masterEffects.first?.resolvedLimiter)
        #expect(reloaded.ceilingDb == -1)
        #expect(reloaded.truePeak == true, "the true-peak mode must ride in the file")
    }
}
