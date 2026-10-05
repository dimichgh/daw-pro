import Foundation
import Testing

@testable import DAWCore

/// m39-af — `DynamicEQParams`, its 32-slot table and its DECODER.
///
/// ⛔⛔ **THIS SUITE IS GUARD A OF THE TWO-GUARD RULE, AND IT IS NOT
/// INTERCHANGEABLE WITH THE BYTE GATE.** The tree proved that by plant this
/// cycle: a `?? 0` → `?? 1` on a `Codable` DECODE DEFAULT passed a byte gate
/// over rendered demos (exit 0, MISSED), because the demo harness builds params
/// through `fx.add` → the MEMBERWISE init, so `init(from:)` never runs. Only a
/// decode test can see that half.
///
/// v1's answer is to have no decode default at all: every one of the 32 keys is
/// REQUIRED, so a missing key THROWS rather than silently landing on a value
/// nobody chose. `decodeOfAPartialObjectThrows` is what freezes that property,
/// and it is the assertion that has to be re-thought the first time this kind
/// gains an additive optional (design §10 G2).
///
/// Deliberately NOT `@MainActor` — it touches only DAWCore value types, and
/// `MainActorOccupancySiteTests` Leg C's suite cap has zero slack.
@Suite("m39-af dynamic EQ — params, slots and the decoder")
struct DynamicEQParamsTests {

    // MARK: - The 32 slots

    /// ⛔ **THE SLOT ORDER IS THE WHOLE TEST**, pinned against LITERALS rather
    /// than re-derived from the same generator the source uses — a derivation
    /// would restate the code instead of checking it.
    ///
    /// `DynamicEQEffect.storeAutomatedParam` switches on these exact positions,
    /// in a different module, with no compiler rule comparing the two tables. A
    /// lane that lands outside that switch's `(0...31)` guard is SILENTLY INERT.
    @Test("the 32 slots are band-major and frozen: slot = (band−1)·8 + p")
    func slotOrderIsFrozen() {
        #expect(EffectParamSpec.specs(for: .dynamicEQ).map(\.name) == [
            "band1Mode", "band1Freq", "band1Q", "band1ThresholdDb",
            "band1Ratio", "band1RangeDb", "band1AttackMs", "band1ReleaseMs",
            "band2Mode", "band2Freq", "band2Q", "band2ThresholdDb",
            "band2Ratio", "band2RangeDb", "band2AttackMs", "band2ReleaseMs",
            "band3Mode", "band3Freq", "band3Q", "band3ThresholdDb",
            "band3Ratio", "band3RangeDb", "band3AttackMs", "band3ReleaseMs",
            "band4Mode", "band4Freq", "band4Q", "band4ThresholdDb",
            "band4Ratio", "band4RangeDb", "band4AttackMs", "band4ReleaseMs",
        ])
        #expect(DynamicEQParams.slotCount == 32)
        #expect(DynamicEQParams.bandCount == 4)
        #expect(DynamicEQParams.paramsPerBand == 8)
    }

    /// The name↔field home must agree with the schema, or `fx.setParam` and
    /// `fx.describe` are describing different surfaces.
    @Test("paramNames IS the spec table's name list, and every name round-trips a value")
    func nameHomeAgreesWithTheSchema() {
        let specNames = EffectParamSpec.specs(for: .dynamicEQ).map(\.name)
        #expect(DynamicEQParams.paramNames == specNames)

        // Every name must READ and WRITE, and a write must be visible to the
        // read — the two halves are separate switches and could disagree.
        var p = DynamicEQParams()
        for (index, name) in DynamicEQParams.paramNames.enumerated() {
            #expect(p.value(forParamName: name) != nil, "\(name) is not readable")
            // A distinct in-range probe per slot, so a switch arm that wrote the
            // WRONG field (band2Q into band2Freq, say) is caught rather than
            // hidden by every band sharing a value.
            let spec = EffectParamSpec.specs(for: .dynamicEQ)[index]
            let probe = spec.range.lowerBound
                + (spec.range.upperBound - spec.range.lowerBound)
                * (0.11 + 0.02 * Double(index % 7))
            let wrote = p.setValue(probe, forParamName: name)
            #expect(wrote, "\(name) is not writable")
            #expect(p.value(forParamName: name) == probe,
                    "\(name) read back \(String(describing: p.value(forParamName: name)))")
        }
        // …and each write landed on its OWN field: all 32 still hold their probe.
        for (index, name) in DynamicEQParams.paramNames.enumerated() {
            let spec = EffectParamSpec.specs(for: .dynamicEQ)[index]
            let probe = spec.range.lowerBound
                + (spec.range.upperBound - spec.range.lowerBound)
                * (0.11 + 0.02 * Double(index % 7))
            #expect(p.value(forParamName: name) == probe,
                    "\(name) was overwritten by a later slot — two arms share a field")
        }
        // ⭐ NEGATIVE CONTROL: the accessors must be able to say NO, or every
        // assertion above is evidence of nothing.
        #expect(p.value(forParamName: "band5Mode") == nil)
        #expect(p.value(forParamName: "mix") == nil)
        let badName = p.setValue(1, forParamName: "band0Freq")
        let emptyName = p.setValue(1, forParamName: "")
        #expect(badName == false)
        #expect(emptyName == false)
    }

    /// ⛔ RANGES ARE MIRRORED FROM EXISTING CONSTANTS, NEVER RE-SPELLED. A
    /// second spelling of the same range is how two controls in one tree come
    /// to disagree.
    @Test("every range is the SAME OBJECT as the constant it mirrors")
    func rangesAreMirroredNotRespelled() {
        #expect(DynamicEQParams.freqRange == EQParams.peakFreqRange)
        #expect(DynamicEQParams.qRange == EQParams.qRange)
        #expect(DynamicEQParams.rangeDbRange == EQParams.gainDbRange)
        #expect(DynamicEQParams.thresholdRange == CompressorParams.thresholdRange)
        #expect(DynamicEQParams.ratioRange == CompressorParams.ratioRange)
        #expect(DynamicEQParams.attackRange == CompressorParams.attackRange)
        #expect(DynamicEQParams.releaseRange == CompressorParams.releaseRange)
        // …and the SCHEMA carries those same ranges, per band — the check that
        // actually matters, since `fx.setParam` clamps against the schema.
        let specs = EffectParamSpec.specs(for: .dynamicEQ)
        for band in 0..<4 {
            #expect(specs[band * 8 + 1].range == EQParams.peakFreqRange)
            #expect(specs[band * 8 + 2].range == EQParams.qRange)
            #expect(specs[band * 8 + 3].range == CompressorParams.thresholdRange)
            #expect(specs[band * 8 + 4].range == CompressorParams.ratioRange)
            #expect(specs[band * 8 + 5].range == EQParams.gainDbRange)
            #expect(specs[band * 8 + 6].range == CompressorParams.attackRange)
            #expect(specs[band * 8 + 7].range == CompressorParams.releaseRange)
        }
        // The knee is FIXED at the compressor's own default rather than exposed.
        #expect(DynamicEQParams.kneeDb == 6)
        let names = specs.map(\.name)
        #expect(names.contains { $0.hasSuffix("KneeDb") } == false)
        // …and there is deliberately no `mix` and no per-band static gain.
        #expect(names.contains("mix") == false)
        #expect(names.contains { $0.hasSuffix("GainDb") } == false)
    }

    // MARK: - Defaults

    /// ⛔ A FRESHLY ADDED DYNAMIC EQ DOES NOTHING, AND THAT IS THE PROPERTY THE
    /// WHOLE TRANSPARENCY NULL LEANS ON. Not "does nothing audible" — every
    /// band's section is not even stepped.
    @Test("every band defaults to mode 0 = OFF, and the defaults match the schema")
    func defaultsAreOffAndMatchTheSchema() {
        let p = DynamicEQParams()
        #expect(p.band1Mode == 0)
        #expect(p.band2Mode == 0)
        #expect(p.band3Mode == 0)
        #expect(p.band4Mode == 0)
        // The centres are spread so the four cards read left to right like an EQ.
        #expect([p.band1Freq, p.band2Freq, p.band3Freq, p.band4Freq]
                == [120, 500, 3_000, 8_000])
        #expect(DynamicEQParams.defaultFreq(band: 1) == 120)
        #expect(DynamicEQParams.defaultFreq(band: 4) == 8_000)
        // ⭐ The struct's defaults and the SCHEMA's defaults must agree, or
        // `fx.describe` teaches a value `fx.add` does not produce.
        for (index, spec) in EffectParamSpec.specs(for: .dynamicEQ).enumerated() {
            let name = DynamicEQParams.paramNames[index]
            #expect(p.value(forParamName: name) == spec.defaultValue,
                    Comment(rawValue: "\(name): struct default "
                        + "\(String(describing: p.value(forParamName: name))) "
                        + "vs schema default \(spec.defaultValue)"))
        }
    }

    // MARK: - Clamping and the NaN traps

    @Test("out-of-range values clamp on init rather than reaching the render path")
    func initClamps() {
        let p = DynamicEQParams(
            band1Mode: 9, band1Freq: 1e9, band1Q: -4, band1ThresholdDb: 40,
            band1Ratio: 1e6, band1RangeDb: -500, band1AttackMs: 0, band1ReleaseMs: 1e9,
            band2Mode: -3, band2Freq: 0.0001, band2Q: 1e6, band2ThresholdDb: -1e6,
            band2Ratio: -5, band2RangeDb: 500, band2AttackMs: 1e9, band2ReleaseMs: 0)
        #expect(p.band1Mode == 2)                                   // snapped, not clamped-then-raw
        #expect(p.band1Freq == EQParams.peakFreqRange.upperBound)
        #expect(p.band1Q == EQParams.qRange.lowerBound)
        #expect(p.band1ThresholdDb == CompressorParams.thresholdRange.upperBound)
        #expect(p.band1Ratio == CompressorParams.ratioRange.upperBound)
        #expect(p.band1RangeDb == EQParams.gainDbRange.lowerBound)
        #expect(p.band1AttackMs == CompressorParams.attackRange.lowerBound)
        #expect(p.band1ReleaseMs == CompressorParams.releaseRange.upperBound)
        #expect(p.band2Mode == 0)
        #expect(p.band2Freq == EQParams.peakFreqRange.lowerBound)
        #expect(p.band2Q == EQParams.qRange.upperBound)
        #expect(p.band2ThresholdDb == CompressorParams.thresholdRange.lowerBound)
        #expect(p.band2Ratio == CompressorParams.ratioRange.lowerBound)
        #expect(p.band2RangeDb == EQParams.gainDbRange.upperBound)
        #expect(p.band2AttackMs == CompressorParams.attackRange.upperBound)
        #expect(p.band2ReleaseMs == CompressorParams.releaseRange.lowerBound)
    }

    /// ⚠️ `clamped(to:)` on a NaN RETURNS THE NaN, and `mode` reaches an `Int()`
    /// conversion that TRAPS on one. Reaching this assertion at all is half the
    /// test — a trap would crash the process, not fail an expectation.
    @Test("non-finite input never reaches a field and never traps")
    func nonFiniteIsGuarded() {
        let p = DynamicEQParams(
            band1Mode: .nan, band1Freq: .nan, band1Q: .infinity,
            band1ThresholdDb: -.infinity, band1Ratio: .nan, band1RangeDb: .nan,
            band1AttackMs: .nan, band1ReleaseMs: .signalingNaN)
        for name in DynamicEQParams.paramNames {
            let v = p.value(forParamName: name)
            #expect(v?.isFinite == true, "\(name) is \(String(describing: v))")
        }
        // ⭐ EVERY non-finite field falls back to its DECLARED DEFAULT, and
        // INFINITY IS TREATED THE SAME AS NaN RATHER THAN CLAMPED TO THE END OF
        // THE RANGE. That is deliberate and it matches `CompressorEffect`'s
        // `p.detectorFreqHz.isFinite ? … : 6_500`: the guard is `isFinite`, not
        // `isNaN`, because an infinity is as much "no value the user asked for"
        // as a NaN is, and silently reading it as "the loudest/widest possible"
        // would be inventing an intent from a broken number.
        #expect(p.band1Mode == 0)
        #expect(p.band1Freq == 120)
        #expect(p.band1Ratio == 4)
        #expect(p.band1RangeDb == -6)
        #expect(p.band1Q == 2)
        #expect(p.band1ThresholdDb == -18)
        #expect(p.band1AttackMs == 10)
        #expect(p.band1ReleaseMs == 100)
        // ⭐ NEGATIVE CONTROL: an in-range FINITE value in the same call is NOT
        // rewritten, so the fallbacks above are a guard and not "the init
        // ignores its arguments".
        let control = DynamicEQParams(band1Mode: .nan, band1Freq: 777, band1Q: 3.5)
        #expect(control.band1Freq == 777)
        #expect(control.band1Q == 3.5)
        #expect(control.band1Mode == 0)
    }

    @Test("mode(at:) snaps, clamps and never traps")
    func modeSnapping() {
        #expect(DynamicEQParams.mode(at: 0) == .off)
        #expect(DynamicEQParams.mode(at: 1) == .above)
        #expect(DynamicEQParams.mode(at: 2) == .below)
        #expect(DynamicEQParams.mode(at: 0.4) == .off)
        #expect(DynamicEQParams.mode(at: 0.6) == .above)
        #expect(DynamicEQParams.mode(at: 1.6) == .below)
        #expect(DynamicEQParams.mode(at: 99) == .below)
        #expect(DynamicEQParams.mode(at: -99) == .off)
        // ⚠️ NON-FINITE FALLS BACK TO `.off`, INCLUDING +INFINITY — the guard is
        // `isFinite`, not `isNaN`, and the fallback is the SAFE state rather
        // than the clamped end of the range. The `ClipperParams.mode(at:)`
        // precedent, same shape.
        #expect(DynamicEQParams.mode(at: .nan) == .off)
        #expect(DynamicEQParams.mode(at: .infinity) == .off)
        #expect(DynamicEQParams.mode(at: -.infinity) == .off)
        // The raw values are the WIRE numbers and are frozen.
        #expect(DynamicEQParams.Mode.off.rawValue == 0)
        #expect(DynamicEQParams.Mode.above.rawValue == 1)
        #expect(DynamicEQParams.Mode.below.rawValue == 2)
        #expect(DynamicEQParams.Mode.allCases.count == 3)
    }

    // MARK: - ⛔⛔ GUARD A: the decoder

    @Test("⭐ decode(encode(defaults)) equals the defaults, FIELD BY FIELD, all 32")
    func defaultsRoundTripFieldByField() throws {
        let original = DynamicEQParams()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(original)
        let back = try JSONDecoder().decode(DynamicEQParams.self, from: bytes)
        #expect(back == original)
        // Field by field as well as wholesale, so a failure NAMES the field.
        for name in DynamicEQParams.paramNames {
            #expect(back.value(forParamName: name) == original.value(forParamName: name),
                    "\(name) did not survive the round trip")
        }
        // …and the encoding really does carry all 32 keys, or the round trip
        // above could be passing because both sides defaulted identically.
        let object = try #require(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object.count == 32, "encoded keys: \(object.keys.sorted())")
        #expect(Set(object.keys) == Set(DynamicEQParams.paramNames))
    }

    @Test("a NON-DEFAULT value in every one of the 32 fields survives the round trip")
    func nonDefaultRoundTrip() throws {
        // Distinct per field, so a decoder that read one key into another field
        // is caught rather than hidden by repeated values.
        var original = DynamicEQParams()
        let specs = EffectParamSpec.specs(for: .dynamicEQ)
        for (index, name) in DynamicEQParams.paramNames.enumerated() {
            let spec = specs[index]
            let v = spec.range.lowerBound
                + (spec.range.upperBound - spec.range.lowerBound)
                * (0.13 + 0.021 * Double(index))
            let wrote = original.setValue(v, forParamName: name)
            #expect(wrote, "\(name) is not writable")
        }
        // Route through the clamping init so `mode` is snapped — a fixture whose
        // value the init rewrites would compare equal for the wrong reason.
        original = DynamicEQParams(
            band1Mode: original.band1Mode, band1Freq: original.band1Freq,
            band1Q: original.band1Q, band1ThresholdDb: original.band1ThresholdDb,
            band1Ratio: original.band1Ratio, band1RangeDb: original.band1RangeDb,
            band1AttackMs: original.band1AttackMs, band1ReleaseMs: original.band1ReleaseMs,
            band2Mode: original.band2Mode, band2Freq: original.band2Freq,
            band2Q: original.band2Q, band2ThresholdDb: original.band2ThresholdDb,
            band2Ratio: original.band2Ratio, band2RangeDb: original.band2RangeDb,
            band2AttackMs: original.band2AttackMs, band2ReleaseMs: original.band2ReleaseMs,
            band3Mode: original.band3Mode, band3Freq: original.band3Freq,
            band3Q: original.band3Q, band3ThresholdDb: original.band3ThresholdDb,
            band3Ratio: original.band3Ratio, band3RangeDb: original.band3RangeDb,
            band3AttackMs: original.band3AttackMs, band3ReleaseMs: original.band3ReleaseMs,
            band4Mode: original.band4Mode, band4Freq: original.band4Freq,
            band4Q: original.band4Q, band4ThresholdDb: original.band4ThresholdDb,
            band4Ratio: original.band4Ratio, band4RangeDb: original.band4RangeDb,
            band4AttackMs: original.band4AttackMs, band4ReleaseMs: original.band4ReleaseMs)
        #expect(original != DynamicEQParams(), "the fixture must not BE the defaults")

        let bytes = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(DynamicEQParams.self, from: bytes)
        for name in DynamicEQParams.paramNames {
            #expect(back.value(forParamName: name) == original.value(forParamName: name),
                    "\(name) did not survive")
        }
    }

    /// ⭐⭐ **THE ASSERTION THAT FREEZES v1's "NO DECODE DEFAULT" PROPERTY.** A
    /// missing key must THROW. The day this kind gains an additive optional,
    /// this test changes — and that is exactly the moment the design names for
    /// re-running the non-interchangeability plant in both directions, because
    /// that is when a byte gate first becomes blind to something (§10 G2).
    @Test("⛔ a JSON object missing ANY of the 32 keys THROWS — there is no `??` to drift")
    func decodeOfAPartialObjectThrows() throws {
        let complete = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(DynamicEQParams())) as? [String: Any]
        var object = try #require(complete)
        #expect(object.count == 32)

        // ⭐ POSITIVE CONTROL FIRST: the COMPLETE object decodes. Without this,
        // "it threw" would be evidence of nothing — a broken fixture throws too.
        let whole = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Never.self) {
            _ = try JSONDecoder().decode(DynamicEQParams.self, from: whole)
        }

        // Then every key, one at a time. All 32, not a sample: a `decodeIfPresent`
        // that crept onto one field would survive a spot check.
        for name in DynamicEQParams.paramNames {
            var partial = object
            partial.removeValue(forKey: name)
            #expect(partial.count == 31)
            let data = try JSONSerialization.data(withJSONObject: partial)
            #expect(throws: (any Error).self, "dropping \"\(name)\" decoded instead of throwing") {
                _ = try JSONDecoder().decode(DynamicEQParams.self, from: data)
            }
        }

        // An EMPTY object throws too (the degenerate case of the same rule).
        object.removeAll()
        let empty = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DynamicEQParams.self, from: empty)
        }
    }

    /// The other half of the decoder's contract: it routes through the CLAMPING
    /// init, so an out-of-range number on disk cannot reach the render path.
    /// ⚠️ This is the property that would be lost by using synthesized
    /// `Codable`, which is why this kind has a hand-written `init(from:)`
    /// despite having no `??` in it.
    @Test("decoding CLAMPS, so a hand-edited project file cannot smuggle a bad value in")
    func decodeClamps() throws {
        let json = Data("""
        {"band1Mode":7,"band1Freq":999999,"band1Q":-5,"band1ThresholdDb":50,\
        "band1Ratio":9999,"band1RangeDb":-9999,"band1AttackMs":0,"band1ReleaseMs":999999,\
        "band2Mode":0,"band2Freq":500,"band2Q":2,"band2ThresholdDb":-18,\
        "band2Ratio":4,"band2RangeDb":-6,"band2AttackMs":10,"band2ReleaseMs":100,\
        "band3Mode":0,"band3Freq":3000,"band3Q":2,"band3ThresholdDb":-18,\
        "band3Ratio":4,"band3RangeDb":-6,"band3AttackMs":10,"band3ReleaseMs":100,\
        "band4Mode":0,"band4Freq":8000,"band4Q":2,"band4ThresholdDb":-18,\
        "band4Ratio":4,"band4RangeDb":-6,"band4AttackMs":10,"band4ReleaseMs":100}
        """.utf8)
        let p = try JSONDecoder().decode(DynamicEQParams.self, from: json)
        #expect(p.band1Mode == 2)
        #expect(p.band1Freq == EQParams.peakFreqRange.upperBound)
        #expect(p.band1Q == EQParams.qRange.lowerBound)
        #expect(p.band1ThresholdDb == CompressorParams.thresholdRange.upperBound)
        #expect(p.band1Ratio == CompressorParams.ratioRange.upperBound)
        #expect(p.band1RangeDb == EQParams.gainDbRange.lowerBound)
        #expect(p.band1AttackMs == CompressorParams.attackRange.lowerBound)
        #expect(p.band1ReleaseMs == CompressorParams.releaseRange.upperBound)
        // ⭐ NEGATIVE CONTROL: the in-range band 2 came through UNCHANGED, so
        // the clamping above is a clamp and not "the decoder ignores the file".
        #expect(p.band2Freq == 500)
        #expect(p.band2ThresholdDb == -18)
        #expect(p.band2ReleaseMs == 100)
    }

    // MARK: - The schema's teaching surface

    /// Every param carries a `note:`. On a 32-param kind whose `Q` deliberately
    /// does NOT mean what `.eq`'s means, the notes are the only place a user or
    /// an agent learns that — the design makes this mitigation mandatory, not
    /// optional.
    @Test("every one of the 32 specs carries a note, and the Q caveat names its numbers")
    func everySpecTeaches() {
        let specs = EffectParamSpec.specs(for: .dynamicEQ)
        for spec in specs {
            let note = spec.note ?? ""
            #expect(note.isEmpty == false, "\(spec.name) has no note")
            #expect(note.count > 80, "\(spec.name)'s note is too short to teach anything")
        }
        // The mandated Q mitigation, on every band, WITH the measured numbers —
        // a caveat with no number is an opinion.
        for band in 1...4 {
            let note = specs.first { $0.name == "band\(band)Q" }?.note ?? ""
            #expect(note.contains("eq.peak1Q"), "band\(band)Q must name the EQ's Q")
            #expect(note.contains("704"), "band\(band)Q must carry the measured width")
            #expect(note.contains("498"), "band\(band)Q must carry the EQ's measured width")
        }
        // The shared-budget warning is carried ONCE, on band 1's mode — the
        // whole table arrives in one `fx.describe` response.
        let budgetCarriers = specs.filter { ($0.note ?? "").contains("64-entry cap") }
        #expect(budgetCarriers.map(\.name) == ["band1Mode"])
        // And the `below`-on-silence surprise is stated on every mode, because
        // that is the control it belongs to.
        for band in 1...4 {
            let mode = specs.first { $0.name == "band\(band)Mode" }
            #expect((mode?.note ?? "").contains("-180 dBFS"),
                    "band\(band)Mode must state what `below` does to silence")
        }
    }
}
