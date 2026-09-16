import Foundation
import Testing
@testable import DAWCore

/// m38-a — the SCHEMA half of the gain insert's polarity (phase) invert: the
/// flag's default, its wire spec slot, the store's binary snap, and above all
/// BACKWARD COMPATIBILITY. Every project saved before m38-a stores
/// `gain: {gainLinear}` with no `invertPolarity` key; those files must keep
/// decoding, and must decode to the non-inverted behaviour they were mixed
/// against.
///
/// The DSP half — the null test and its deliberate failure control — lives in
/// `DAWEngineTests/GainPolarityRenderTests`; the store's name->field mapping
/// is pinned in `EffectChainStoreTests`, the suite that owns that surface.
///
/// NOT `@MainActor`: every leg here is pure value-type schema/Codable work, so
/// the suite genuinely does not need the actor (m23-aw cadence — the honest way
/// to not spend a main-actor suite is to not need one).
@Suite("m38-a gain polarity — params, schema, persistence")
struct GainPolarityParamsTests {

    // MARK: - Default OFF

    @Test("invertPolarity defaults OFF everywhere a gain insert can come from")
    func defaultsOff() {
        #expect(GainParams().invertPolarity == false)
        #expect(GainParams(gainLinear: 2).invertPolarity == false)
        #expect(EffectDescriptor(kind: .gain).resolvedGain.invertPolarity == false)
        // The spec table's default is the struct's default — a card or an
        // agent reading `fx.describe` must not be told a different story.
        let spec = EffectParamSpec.specs(for: .gain).first { $0.name == "invertPolarity" }
        #expect(spec?.defaultValue == 0)
        #expect(spec?.range == 0...1)
        #expect(spec?.unit == "linear")
    }

    @Test("gainRange is UNWIDENED — polarity is a switch, not a negative gain")
    func gainRangeUnchanged() {
        // The design decision, pinned: a signed range would make 0 an awkward
        // midpoint of a control whose 0 already means silence, and would fuse
        // "turn it down" with "flip it". Widening this is the change this
        // param exists to avoid.
        #expect(GainParams.gainRange == 0...16)
        #expect(GainParams(gainLinear: -1).gainLinear == 0)
        #expect(GainParams(gainLinear: -1, invertPolarity: true).gainLinear == 0)
    }

    // MARK: - Slot order (automation stability)

    @Test("invertPolarity is APPENDED at slot 1 — gainLinear never moves")
    func specSlotOrder() {
        let names = EffectParamSpec.specs(for: .gain).map(\.name)
        #expect(names == ["gainLinear", "invertPolarity"])
        // Automation lanes address params by spec INDEX; moving slot 0 would
        // silently repoint every saved gain lane in every existing project.
        #expect(names.firstIndex(of: "gainLinear") == 0)
    }

    @Test("the invertPolarity note teaches what the number cannot")
    func specNoteTeaches() throws {
        let spec = try #require(
            EffectParamSpec.specs(for: .gain).first { $0.name == "invertPolarity" })
        let note = try #require(spec.note)
        #expect(note.contains("-1"))
        #expect(note.contains("null"))
        // A novice needs to be told this does NOT change how one track sounds
        // alone — otherwise the control reads as broken.
        #expect(note.lowercased().contains("alone"))
    }

    // MARK: - Backward compatibility (the load-bearing leg)

    @Test("a pre-m38-a gain JSON with NO invertPolarity key decodes to false")
    func legacyJSONDecodesToFalse() throws {
        // Byte-for-byte the shape `ProjectStore` wrote before m38-a.
        let legacy = Data(#"{"gainLinear":2.5}"#.utf8)
        let params = try JSONDecoder().decode(GainParams.self, from: legacy)
        #expect(params.gainLinear == 2.5)
        #expect(params.invertPolarity == false, "an older project must load NON-inverted")
        // …and it is `==` to the same params constructed fresh, so nothing
        // downstream can distinguish a loaded legacy insert from a new one.
        #expect(params == GainParams(gainLinear: 2.5))
    }

    @Test("an EMPTY gain object still decodes to unity, non-inverted")
    func emptyJSONDecodesToDefaults() throws {
        let params = try JSONDecoder().decode(GainParams.self, from: Data("{}".utf8))
        #expect(params == GainParams())
        #expect(params.gainLinear == 1)
        #expect(params.invertPolarity == false)
    }

    @Test("decoding routes through the CLAMPING init, polarity and all")
    func decodeClamps() throws {
        let hot = Data(#"{"gainLinear":100,"invertPolarity":true}"#.utf8)
        let params = try JSONDecoder().decode(GainParams.self, from: hot)
        #expect(params.gainLinear == 16, "the clamp must survive the new key")
        #expect(params.invertPolarity)
    }

    @Test("invertPolarity round-trips through encode/decode")
    func roundTrip() throws {
        for flag in [false, true] {
            let original = GainParams(gainLinear: 0.5, invertPolarity: flag)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(GainParams.self, from: data) == original)
        }
    }
}
