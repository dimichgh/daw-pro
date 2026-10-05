import Foundation
import Testing
@testable import DAWCore

/// m39-y — `TransientShaperParams`: the clamping, the decoding, and the three
/// LAWS that live in DAWCore so the DSP, the notes, the tests and the wire
/// cannot disagree about them.
///
/// ⛔ **L2 IS THE LEG THAT MAKES THE WIRE CONTRACT ENFORCEABLE.** The INDEX of a
/// spec in `EffectParamSpec.specs(for: .transientShaper)` IS the automation slot
/// number, permanently. It asserts the order POSITIONALLY, by literal, so
/// swapping two slots reddens — a set-comparison or a name lookup would not.
@Suite("Transient shaper params — clamping, decoding, and the three laws (m39-y)")
struct TransientShaperParamsTests {

    // MARK: - L1: clamping and decoding

    @Test("L1a — every field clamps to its DECLARED range, in both directions")
    func initClampsEveryField() {
        let high = TransientShaperParams(attackDb: 500, sustainDb: 500, attackMs: 5_000,
                                         sustainMs: 50_000, outputDb: 500, mix: 9)
        #expect(high.attackDb == 20)
        #expect(high.sustainDb == 20)
        #expect(high.attackMs == 50)
        #expect(high.sustainMs == 1_000)
        #expect(high.outputDb == 24)
        #expect(high.mix == 1)

        let low = TransientShaperParams(attackDb: -500, sustainDb: -500, attackMs: -1,
                                        sustainMs: 0, outputDb: -500, mix: -9)
        #expect(low.attackDb == -20)
        #expect(low.sustainDb == -20)
        #expect(low.attackMs == 0.1)
        #expect(low.sustainMs == 20)
        #expect(low.outputDb == -24)
        #expect(low.mix == 0)
    }

    /// `clamped(to:)` on a NaN returns the NaN — both comparisons inside
    /// `min(max(…))` are false against NaN — so the guard has to be a separate
    /// `isFinite` test AHEAD of the clamp, not the clamp itself. These values
    /// reach `exp`, `log10`, `pow` and the interpolation accumulators on the
    /// render thread, where one NaN silences the strip permanently.
    @Test("L1b — NaN and infinity fall back to the DEFAULT, not through the clamp")
    func nonFiniteFallsBackToDefault() {
        let nan = TransientShaperParams(
            attackDb: .nan, sustainDb: .nan, attackMs: .nan,
            sustainMs: .nan, outputDb: .nan, mix: .nan)
        #expect(nan == TransientShaperParams())
        let inf = TransientShaperParams(
            attackDb: .infinity, sustainDb: -.infinity, attackMs: .infinity,
            sustainMs: -.infinity, outputDb: .infinity, mix: -.infinity)
        #expect(inf == TransientShaperParams())
        #expect(nan.attackDb.isFinite && nan.attackMs.isFinite && nan.mix.isFinite)
    }

    @Test("L1c — a PARTIAL JSON object decodes with per-field defaults, and an out-of-range value in JSON is clamped on the way in")
    func partialDecodeUsesPerFieldDefaults() throws {
        let json = Data(#"{"attackDb": 9}"#.utf8)
        let decoded = try JSONDecoder().decode(TransientShaperParams.self, from: json)
        #expect(decoded.attackDb == 9)
        #expect(decoded.sustainDb == 0)
        #expect(decoded.attackMs == 5)
        #expect(decoded.sustainMs == 200)
        #expect(decoded.outputDb == 0)
        #expect(decoded.mix == 1)

        let wild = Data(#"{"attackDb": 99, "sustainMs": 1, "mix": 4}"#.utf8)
        let clamped = try JSONDecoder().decode(TransientShaperParams.self, from: wild)
        #expect(clamped.attackDb == 20)
        #expect(clamped.sustainMs == 20)
        #expect(clamped.mix == 1)
    }

    @Test("L1d — an empty object decodes to exactly the defaults, and a round trip is stable")
    func emptyObjectAndRoundTrip() throws {
        let empty = try JSONDecoder().decode(
            TransientShaperParams.self, from: Data("{}".utf8))
        #expect(empty == TransientShaperParams())

        let source = TransientShaperParams(attackDb: -7.5, sustainDb: 11.25, attackMs: 0.4,
                                           sustainMs: 750, outputDb: -3.5, mix: 0.6)
        let data = try JSONEncoder().encode(source)
        let back = try JSONDecoder().decode(TransientShaperParams.self, from: data)
        #expect(back == source)
    }

    // MARK: - L2: the FROZEN parameter order

    /// ⛔⛔ ORDER IS FROZEN AND APPEND-ONLY FOREVER: the array index IS the
    /// automation slot. Asserted POSITIONALLY against literals so that swapping
    /// two entries reddens — which a name-keyed lookup would not.
    @Test("L2 — exactly SIX specs, in the frozen slot order, with the declared range / default / unit / curve / verdict")
    func specsAreSixInTheFrozenOrder() {
        let specs = EffectParamSpec.specs(for: .transientShaper)
        #expect(specs.count == 6)
        guard specs.count == 6 else { return }

        #expect(specs[0].name == "attackDb")
        #expect(specs[0].range == -20...20)
        #expect(specs[0].defaultValue == 0)
        #expect(specs[0].unit == "dB")
        #expect(specs[0].curve == .linear)
        #expect(specs[0].modulatable == .yes)

        #expect(specs[1].name == "sustainDb")
        #expect(specs[1].range == -20...20)
        #expect(specs[1].defaultValue == 0)
        #expect(specs[1].unit == "dB")
        #expect(specs[1].curve == .linear)
        #expect(specs[1].modulatable == .yes)

        #expect(specs[2].name == "attackMs")
        #expect(specs[2].range == 0.1...50)
        #expect(specs[2].defaultValue == 5)
        #expect(specs[2].unit == "ms")
        #expect(specs[2].curve == .logarithmic)
        #expect(specs[2].modulatable == .yes)

        #expect(specs[3].name == "sustainMs")
        #expect(specs[3].range == 20...1_000)
        #expect(specs[3].defaultValue == 200)
        #expect(specs[3].unit == "ms")
        #expect(specs[3].curve == .logarithmic)
        #expect(specs[3].modulatable == .yes)

        #expect(specs[4].name == "outputDb")
        #expect(specs[4].range == -24...24)
        #expect(specs[4].defaultValue == 0)
        #expect(specs[4].unit == "dB")
        #expect(specs[4].curve == .linear)
        #expect(specs[4].modulatable == .yes)

        #expect(specs[5].name == "mix")
        #expect(specs[5].range == 0...1)
        #expect(specs[5].defaultValue == 1)
        #expect(specs[5].unit == "linear")
        #expect(specs[5].curve == .linear)
        #expect(specs[5].modulatable == .yes)
    }

    /// Every spec's default must actually round-trip through the clamping init —
    /// a default outside its own declared range would make a freshly added
    /// insert differ from what `fx.describe` promises.
    @Test("L2b — the DEFAULTS in the spec table are exactly the struct's own defaults")
    func specDefaultsMatchTheStruct() {
        let specs = EffectParamSpec.specs(for: .transientShaper)
        let params = TransientShaperParams()
        let byName = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0.defaultValue) })
        #expect(byName["attackDb"] == params.attackDb)
        #expect(byName["sustainDb"] == params.sustainDb)
        #expect(byName["attackMs"] == params.attackMs)
        #expect(byName["sustainMs"] == params.sustainMs)
        #expect(byName["outputDb"] == params.outputDb)
        #expect(byName["mix"] == params.mix)
        for spec in specs {
            #expect(spec.range.contains(spec.defaultValue),
                    "\(spec.name)'s default \(spec.defaultValue) is outside its own range")
        }
    }

    /// `paramValue(named:)` is the exact inverse of `ProjectStore.applyEffectParam`'s
    /// name→field map, over the SAME wire names. A name in the spec table with no
    /// arm here reads back nil and `fx.setParam`'s echo would lie.
    @Test("L2c — every spec name is readable back through paramValue(named:)")
    func everySpecNameIsReadable() {
        let params = TransientShaperParams(attackDb: 3, sustainDb: -4, attackMs: 12,
                                           sustainMs: 333, outputDb: 5, mix: 0.25)
        let descriptor = EffectDescriptor(kind: .transientShaper, transientShaper: params)
        for spec in EffectParamSpec.specs(for: .transientShaper) {
            #expect(descriptor.paramValue(spec.name) != nil,
                    "\(spec.name) is in the spec table but paramValue(named:) returns nil")
        }
        #expect(descriptor.paramValue("attackDb") == 3)
        #expect(descriptor.paramValue("sustainDb") == -4)
        #expect(descriptor.paramValue("attackMs") == 12)
        #expect(descriptor.paramValue("sustainMs") == 333)
        #expect(descriptor.paramValue("outputDb") == 5)
        #expect(descriptor.paramValue("mix") == 0.25)
        #expect(descriptor.paramValue("threshold") == nil)  // NOT a compressor
    }

    // MARK: - The three laws

    /// ⛔ THE NORMALISATION. `attackDb: +6` promises "up to +6 dB", reached only
    /// at a full 12 dB differential.
    @Test("Law 1 — shapedFraction is 0 at no differential, 0.5 at half, 1 at full and SATURATES above it")
    func shapedFractionLaw() {
        let full = TransientShaperParams.fullShapeDifferentialDb
        #expect(full == 12.0)
        #expect(TransientShaperParams.shapedFraction(differentialDb: 0) == 0)
        #expect(TransientShaperParams.shapedFraction(differentialDb: -5) == 0)
        #expect(abs(TransientShaperParams.shapedFraction(differentialDb: 6) - 0.5) < 1e-12)
        #expect(TransientShaperParams.shapedFraction(differentialDb: 12) == 1)
        #expect(TransientShaperParams.shapedFraction(differentialDb: 200) == 1)
        // "No answer", not "very large".
        // "No answer", not "very large" — the same convention every other law
        // in DAWCore uses for a non-finite input. Unreachable from the render
        // path (the numerator is finite and the denominator is floored at
        // `detectorFloorLinear`), and pinned so it stays that way.
        #expect(TransientShaperParams.shapedFraction(differentialDb: .nan) == 0)
        #expect(TransientShaperParams.shapedFraction(differentialDb: .infinity) == 0)
        #expect(TransientShaperParams.shapedFraction(differentialDb: -.infinity) == 0)
    }

    /// ⭐ DERIVED, NOT ASSERTED — and this leg re-derives it INDEPENDENTLY rather
    /// than restating `0.2893`, which would only prove the constant equals
    /// itself. Full shaping needs `A/f ≤ 10^(−12/20)`; for a symmetric one-pole
    /// lag `A(t) = 1 − e^(−t/τ)` that holds while `t ≤ τ·ln(1/(1 − 10^(−12/20)))`.
    @Test("Law 2 — attackWindowMs is the INDEPENDENTLY DERIVED 0.28927 × attackMs")
    func attackWindowLaw() {
        let ratioAtFullShaping = pow(10.0, -TransientShaperParams.fullShapeDifferentialDb / 20.0)
        let derived = log(1.0 / (1.0 - ratioAtFullShaping))
        print("[measured] m39-y full-shape window fraction: derived \(derived), "
              + "shipped \(TransientShaperParams.fullShapeWindowFraction)")
        #expect(abs(derived - TransientShaperParams.fullShapeWindowFraction) < 1e-12)
        #expect(abs(derived - 0.28927) < 1e-4)

        #expect(abs(TransientShaperParams.attackWindowMs(attackMs: 5) - 5 * derived) < 1e-12)
        #expect(abs(TransientShaperParams.attackWindowMs(attackMs: 30) - 8.678) < 1e-3)
        // Clamped and guarded like everything else that reaches the wire.
        #expect(TransientShaperParams.attackWindowMs(attackMs: 9_999)
                == TransientShaperParams.attackWindowMs(attackMs: 50))
        #expect(TransientShaperParams.attackWindowMs(attackMs: .nan)
                == TransientShaperParams.attackWindowMs(attackMs: 5))
    }

    /// ⛔ THE COEFFICIENT CONVENTION, shared verbatim with `CompressorEffect`:
    /// the envelope covers 63.2 % of a step in EXACTLY the stated milliseconds.
    /// Verified by actually running the recurrence, not by restating `exp`.
    @Test("Law 3 — a one-pole at τ ms reaches 63.2 % of a step in exactly τ ms")
    func onePoleCoefficientLaw() {
        let rate = 48_000.0
        let ms = 10.0
        let coeff = TransientShaperParams.onePoleCoefficient(ms: ms, sampleRate: rate)
        var env = 0.0
        let steps = Int(ms * 0.001 * rate)
        var index = 0
        while index < steps {
            env = coeff * env + (1.0 - coeff) * 1.0
            index += 1
        }
        print("[measured] m39-y one-pole at 10 ms reached \(env) after 10 ms "
              + "(theory 0.632121)")
        #expect(abs(env - 0.6321205588) < 1e-4)

        // Guards: these reach the render thread.
        #expect(TransientShaperParams.onePoleCoefficient(ms: .nan, sampleRate: rate) == 0)
        #expect(TransientShaperParams.onePoleCoefficient(ms: 0, sampleRate: rate) == 0)
        #expect(TransientShaperParams.onePoleCoefficient(ms: 5, sampleRate: 0) == 0)
        #expect(TransientShaperParams.onePoleCoefficient(ms: 5, sampleRate: .nan) == 0)
    }

    @Test("The detector floor has ONE home and its linear form agrees with its dB form")
    func detectorFloorHasOneHome() {
        #expect(TransientShaperParams.detectorFloorDb == -70.0)
        #expect(abs(TransientShaperParams.detectorFloorLinear - 3.16227766e-4) < 1e-10)
        #expect(abs(20 * log10(TransientShaperParams.detectorFloorLinear)
                    - TransientShaperParams.detectorFloorDb) < 1e-10)
        // Both amounts can reach 20 and would otherwise sum to 40.
        #expect(TransientShaperParams.maxShapeDb == 24.0)
        #expect(TransientShaperParams.fastAttackMs == 0.05)
        #expect(TransientShaperParams.fastReleaseMs == 5.0)
    }

    /// The predicate the byte/bit gates depend on: the DEFAULTS are the
    /// bit-exact-dry setting, and moving any one of the four multiplicative
    /// params leaves it.
    @Test("isBitExactDry is true at the defaults and false the moment anything moves")
    func bitExactDryPredicate() {
        #expect(TransientShaperParams().isBitExactDry)
        #expect(!TransientShaperParams(attackDb: 0.001).isBitExactDry)
        #expect(!TransientShaperParams(sustainDb: -0.001).isBitExactDry)
        #expect(!TransientShaperParams(outputDb: 0.001).isBitExactDry)
        #expect(!TransientShaperParams(mix: 0.999).isBitExactDry)
        // The two TIME constants do not affect it: with both amounts at 0 there
        // is nothing for a window width to scale.
        #expect(TransientShaperParams(attackMs: 40, sustainMs: 900).isBitExactDry)
    }
}
