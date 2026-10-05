import Foundation
import Testing

@testable import DAWCore

/// m39-g — the WIRE-SHAPE half of the richness pass's neutrality gate.
///
/// `PolySynthRenderIdentityTests` (DAWEngineTests) proves a pre-m39-g project
/// still SOUNDS the same. This suite proves it still LOOKS the same on disk,
/// which is the other half of "additive-optional" and is not implied by the
/// first: a field could default to a musically neutral value and still write a
/// new key into every project file, churning saved documents, breaking byte
/// comparisons in other tooling, and — the one that actually bites — making a
/// file written by this build unreadable to the previous one.
///
/// ⚠️ DELIBERATELY A NEW FILE. `PedalHoldLimitCodableTests` pins the same law
/// for m34-q's field and is read by others as the reference for it; extending
/// it with fifteen more fields would bury the precedent it exists to state.
@Suite("m39-g PolySynth richness — Codable shape")
struct PolySynthRichnessCodableTests {
    /// The key set `PolySynthParams` emitted before m39-g, for a value that
    /// opts into nothing. ⛔ `pedalHoldLimit` is NOT here: it is m34-q's
    /// additive-optional field and nil, so it must not encode either.
    private static let legacyKeys: Set<String> = [
        "waveform", "attack", "decay", "sustain", "release",
        "cutoffHz", "resonance", "gain",
    ]

    /// Every key m39-g may add, paired with a mutation that sets exactly that
    /// one field. Used both for "each adds only itself" and — by exhausting the
    /// list — as the inventory that a sixteenth field cannot silently join.
    private static var richnessFields: [(key: String, set: (inout PolySynthParams) -> Void)] {
        [
        ("unisonVoices", { $0.unisonVoices = 4 }),
        ("unisonDetuneCents", { $0.unisonDetuneCents = 12 }),
        ("unisonStereoSpread", { $0.unisonStereoSpread = 0.7 }),
        ("subLevel", { $0.subLevel = 0.4 }),
        ("subOctave", { $0.subOctave = -2 }),
        ("subWaveform", { $0.subWaveform = .square }),
        ("noiseLevel", { $0.noiseLevel = 0.2 }),
        ("noiseColor", { $0.noiseColor = 0.9 }),
        ("drift", { $0.drift = 0.5 }),
        ("resonanceBoost", { $0.resonanceBoost = 0.8 }),
        ("drive", { $0.drive = 0.6 }),
        ("velocityToCutoff", { $0.velocityToCutoff = 0.5 }),
        ("keyToCutoff", { $0.keyToCutoff = 0.3 }),
        ("voiceJitter", { $0.voiceJitter = 0.25 }),
        ("envelopeCurve", { $0.envelopeCurve = -0.6 }),
        ]
    }

    private static func encodedKeys(_ params: PolySynthParams) throws -> Set<String> {
        let data = try JSONEncoder().encode(params)
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(object as? [String: Any],
                                      "PolySynthParams must encode as a JSON object")
        return Set(dictionary.keys)
    }

    // MARK: - 1. A default value writes no new keys at all

    @Test("a default PolySynthParams still encodes EXACTLY the pre-m39-g key set")
    func defaultEncodesOnlyLegacyKeys() throws {
        let keys = try Self.encodedKeys(PolySynthParams())
        #expect(keys == Self.legacyKeys, """
            a default PolySynthParams no longer writes the pre-m39-g key set. \
            Unexpected: \(keys.subtracting(Self.legacyKeys).sorted()); \
            missing: \(Self.legacyKeys.subtracting(keys).sorted()). \
            A field that encodes when nobody set it churns every project on disk.
            """)
    }

    /// ⭐ POSITIVE CONTROL FOR THE TEST ABOVE. `encodedKeys` returning the
    /// legacy set is only meaningful if it CAN return more — a key-set
    /// comparison that never sees a new key is indistinguishable from one that
    /// compares nothing.
    @Test("CONTROL: the key-set probe does detect an added key")
    func keySetProbeCanSeeANewKey() throws {
        var params = PolySynthParams()
        params.drift = 0.5
        let keys = try Self.encodedKeys(params)
        #expect(keys.contains("drift"),
                "control failed: the probe cannot see a key that is definitely present")
        #expect(keys != Self.legacyKeys,
                "control failed: the probe reports the legacy set even for a field that was set")
    }

    // MARK: - 2. Each field adds exactly its own key

    @Test("each richness field, set alone, adds exactly one key — its own")
    func eachFieldAddsOnlyItsOwnKey() throws {
        for field in Self.richnessFields {
            var params = PolySynthParams()
            field.set(&params)
            let keys = try Self.encodedKeys(params)
            let added = keys.subtracting(Self.legacyKeys)
            #expect(added == [field.key], """
                setting \(field.key) alone encoded \(added.sorted()) instead of just \
                ["\(field.key)"]. Either the key is misnamed or a neighbouring field \
                acquired a non-nil default.
                """)
        }
    }

    @Test("all fifteen fields set together encode all fifteen keys and nothing more")
    func allFieldsTogetherEncodeTheFullSet() throws {
        var params = PolySynthParams()
        for field in Self.richnessFields { field.set(&params) }
        let keys = try Self.encodedKeys(params)
        let expected = Self.legacyKeys.union(Self.richnessFields.map(\.key))
        #expect(keys == expected, """
            the full richness set encoded \(keys.sorted()), expected \(expected.sorted()).
            """)
    }

    // MARK: - 3. Legacy JSON decodes with every new field nil and neutral

    /// Byte-for-byte the shape a pre-m39-g build wrote. ⛔ Do not "modernise"
    /// this literal — its value is that it was NOT produced by today's encoder.
    private static let legacyJSON = """
        {"waveform":"square","attack":0.01,"decay":0.2,"sustain":0.5,
         "release":0.3,"cutoffHz":4000,"resonance":0.4,"gain":0.9}
        """

    @Test("pre-m39-g JSON decodes with every new field nil, and every accessor neutral")
    func legacyJSONDecodesToNeutral() throws {
        let params = try JSONDecoder().decode(
            PolySynthParams.self, from: Data(Self.legacyJSON.utf8))

        // The legacy fields survive unchanged — if these moved, the neutrality
        // of the new ones would be beside the point.
        #expect(params.waveform == .square)
        #expect(params.cutoffHz == 4_000)
        #expect(params.resonance == 0.4)
        #expect(params.pedalHoldLimit == nil)

        // Absent key → nil. Fifteen times, because "some of them" is not the law.
        #expect(params.unisonVoices == nil)
        #expect(params.unisonDetuneCents == nil)
        #expect(params.unisonStereoSpread == nil)
        #expect(params.subLevel == nil)
        #expect(params.subOctave == nil)
        #expect(params.subWaveform == nil)
        #expect(params.noiseLevel == nil)
        #expect(params.noiseColor == nil)
        #expect(params.drift == nil)
        #expect(params.resonanceBoost == nil)
        #expect(params.drive == nil)
        #expect(params.velocityToCutoff == nil)
        #expect(params.keyToCutoff == nil)
        #expect(params.voiceJitter == nil)
        #expect(params.envelopeCurve == nil)

        // ⭐ AND nil RESOLVES TO NEUTRAL. This is the assertion that actually
        // protects the sound: `nil` meaning "off" is a property of the
        // `effective*` accessors, not of the optional, and the engine only ever
        // reads the accessors.
        #expect(params.effectiveUnisonVoices == 1)
        #expect(params.effectiveUnisonDetuneCents == 0)
        #expect(params.effectiveUnisonStereoSpread == 0)
        #expect(params.effectiveSubLevel == 0)
        #expect(params.effectiveNoiseLevel == 0)
        #expect(params.effectiveDrift == 0)
        #expect(params.effectiveResonanceBoost == 0)
        #expect(params.effectiveDrive == 0)
        #expect(params.effectiveVelocityToCutoff == 0)
        #expect(params.effectiveKeyToCutoff == 0)
        #expect(params.effectiveVoiceJitter == 0)
        #expect(params.effectiveEnvelopeCurve == 0)

        // `effectiveQ` at zero boost must be the pre-m39-g expression exactly,
        // or `resonanceBoost` would have re-voiced every stored patch.
        #expect(params.effectiveQ == 0.5 + 0.4 * 9.5)
    }

    @Test("a full round trip preserves every field, including the distinction nil ≠ 0")
    func roundTripPreservesNilVersusZero() throws {
        var params = PolySynthParams()
        for field in Self.richnessFields { field.set(&params) }
        params.drive = 0            // explicitly zero, NOT absent
        params.voiceJitter = nil    // explicitly absent

        let decoded = try JSONDecoder().decode(
            PolySynthParams.self, from: JSONEncoder().encode(params))
        #expect(decoded == params, "PolySynthParams must survive a JSON round trip unchanged")
        #expect(decoded.drive == 0, "an explicit 0 must not decay into nil")
        #expect(decoded.voiceJitter == nil, "an absent field must not acquire a value")

        let keys = try Self.encodedKeys(params)
        #expect(keys.contains("drive"), "an explicit 0 must still be written")
        #expect(!keys.contains("voiceJitter"), "a nil field must not be written")
    }

    // MARK: - 4. The tolerant-enum law (m20-g / m34-s / m34-w)

    @Test("an unknown subWaveform from a future build decodes to nil, not a failure")
    func unknownSubWaveformDecodesTolerantly() throws {
        let json = """
            {"waveform":"saw","attack":0.01,"decay":0.2,"sustain":0.5,"release":0.3,
             "cutoffHz":4000,"resonance":0.4,"gain":0.9,
             "subWaveform":"wavetableFromTheFuture","subLevel":0.4,"drift":0.25}
            """
        let params = try JSONDecoder().decode(PolySynthParams.self, from: Data(json.utf8))
        #expect(params.subWaveform == nil,
                "an unrecognised waveform must resolve to nil, not abort the decode")
        // ⭐ THE POINT OF THE LAW: the neighbours survive. A strict decode here
        // would make the WHOLE project unopenable because of one unknown string.
        #expect(params.subLevel == 0.4, "a sibling field must be unaffected by the unknown enum")
        #expect(params.drift == 0.25)
        #expect(params.effectiveSubWaveform == .sine, "nil must fall back to the neutral waveform")
    }

    /// ⭐ POSITIVE CONTROL for the test above: the tolerant path must still
    /// ACCEPT a value it knows, or "decodes to nil" would be trivially true.
    @Test("CONTROL: a KNOWN subWaveform string decodes to that waveform")
    func knownSubWaveformDecodes() throws {
        let json = """
            {"waveform":"saw","attack":0.01,"decay":0.2,"sustain":0.5,"release":0.3,
             "cutoffHz":4000,"resonance":0.4,"gain":0.9,"subWaveform":"square"}
            """
        let params = try JSONDecoder().decode(PolySynthParams.self, from: Data(json.utf8))
        #expect(params.subWaveform == .square,
                "control failed: the tolerant decoder rejects a value it should know")
    }

    // MARK: - 5. Decode clamps — the memory-safety boundary

    /// ⛔⛔ `Codable`'s SYNTHESISED `init(from:)` assigns stored properties
    /// directly and never calls the clamping memberwise init. `unisonVoices`
    /// indexes a FIXED heap allocation on the render thread, so an unclamped
    /// value out of a hand-edited or future-build file is an out-of-bounds
    /// write, not a wrong sound. This is why `PolySynthParams` has a custom
    /// decoder at all.
    @Test("an out-of-range unisonVoices in JSON is clamped by the decoder, not trusted")
    func outOfRangeValuesAreClampedOnDecode() throws {
        let json = """
            {"waveform":"saw","attack":0.01,"decay":0.2,"sustain":0.5,"release":0.3,
             "cutoffHz":4000,"resonance":0.4,"gain":0.9,
             "unisonVoices":9999,"subOctave":-99,"drive":42.0,"envelopeCurve":-17.5}
            """
        let params = try JSONDecoder().decode(PolySynthParams.self, from: Data(json.utf8))
        #expect(params.unisonVoices == PolySynthParams.maxUnisonVoices, """
            an out-of-range unisonVoices survived decoding. The render thread indexes a \
            fixed allocation with this number.
            """)
        #expect(params.subOctave == PolySynthParams.subOctaveRange.lowerBound)
        #expect(params.drive == PolySynthParams.driveRange.upperBound)
        #expect(params.envelopeCurve == PolySynthParams.envelopeCurveRange.lowerBound)
    }

    /// ⭐ POSITIVE CONTROL: the decoder must pass an IN-range value through
    /// untouched, or "clamped" could just mean "overwritten".
    @Test("CONTROL: an in-range value decodes unchanged")
    func inRangeValuesSurviveDecode() throws {
        let json = """
            {"waveform":"saw","attack":0.01,"decay":0.2,"sustain":0.5,"release":0.3,
             "cutoffHz":4000,"resonance":0.4,"gain":0.9,
             "unisonVoices":5,"drive":0.35,"envelopeCurve":0.25}
            """
        let params = try JSONDecoder().decode(PolySynthParams.self, from: Data(json.utf8))
        #expect(params.unisonVoices == 5, "control failed: the decoder mangles a valid value")
        #expect(params.drive == 0.35)
        #expect(params.envelopeCurve == 0.25)
    }

    // MARK: - 6. The document layer carries it without per-field plumbing

    @Test("InstrumentDocument round-trips the richness fields through PolySynthParams' own Codable")
    func instrumentDocumentCarriesTheNewFields() throws {
        var params = PolySynthParams()
        for field in Self.richnessFields { field.set(&params) }
        let descriptor = InstrumentDescriptor(kind: .polySynth, polySynth: params)

        let document = InstrumentDocument(from: descriptor, mediaRefs: [:])
        let decoded = try JSONDecoder().decode(
            InstrumentDocument.self, from: JSONEncoder().encode(document))

        // The point: `InstrumentDocument` names no richness field anywhere. It
        // encodes `polySynth` whole, so the fields ride along for free — this
        // test is what makes that claim checkable rather than assumed.
        #expect(decoded.polySynth == params,
                "InstrumentDocument must carry PolySynthParams verbatim, field-by-field")
        #expect(decoded.polySynth.unisonVoices == 4)
        #expect(decoded.polySynth.subWaveform == .square)
        #expect(decoded.polySynth.envelopeCurve == -0.6)
    }

    @Test("a DEFAULT InstrumentDocument adds no richness keys to its polySynth payload")
    func defaultInstrumentDocumentStaysLegacyShaped() throws {
        let document = InstrumentDocument(
            from: InstrumentDescriptor(kind: .polySynth, polySynth: PolySynthParams()),
            mediaRefs: [:])
        let data = try JSONEncoder().encode(document)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try #require(object as? [String: Any])
        let payload = try #require(root["polySynth"] as? [String: Any],
                                   "InstrumentDocument must still nest a polySynth object")
        #expect(Set(payload.keys) == Self.legacyKeys, """
            a default instrument document's polySynth payload gained keys: \
            \(Set(payload.keys).subtracting(Self.legacyKeys).sorted()).
            """)
    }
}
