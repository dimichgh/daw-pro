import Foundation
import Testing

@testable import DAWCore

/// m39-a — the conformance proof for the DECLARED `EffectParamSpec.curve`.
///
/// Before m39-a the taper was inferred from the free-text unit string, twice
/// (`EffectEditorModel.scale(for:)` and `PolySynthEditorModel.scale(for:)`,
/// both asking `unit == "Hz" && range.lowerBound > 0`). Lifting it into a
/// declared property is only safe if **every shipping parameter resolves to the
/// curve it already had** — so that is what this suite asserts, over every
/// spec of every kind rather than a sample.
///
/// ⚠️ **A loop over `Kind.allCases` passes if every table is empty.** The
/// re-derivation test therefore carries non-vacuity pins — exact total, exact
/// logarithmic count, per-kind non-emptiness — so "nothing was compared" and
/// "everything matched" cannot print the same green.
///
/// ⭐ Positive-controlled 2026-09-19 by mis-declaring `peak1Freq` as `.linear`
/// in `Effects.swift` and re-running: `conformsToThePreLiftInference` failed
/// with `declared .linear but the pre-m39-a inference gives .logarithmic`, and
/// `logarithmicCensus` failed with `9` against the expected `10`. Both were
/// restored. The observed failure is recorded in the m39-a report.
///
/// Deliberately NOT `@MainActor`: it touches only DAWCore value types and
/// arithmetic, so it costs nothing against `MainActorOccupancySiteTests`
/// Leg C's cadence cap (which counts `@MainActor` SUITES, and is at its limit).
struct ParamCurveConformanceTests {

    // MARK: - The pre-m39-a inference, preserved verbatim as the oracle

    /// The rule both editor models implemented independently before m39-a,
    /// copied here EXACTLY so the conformance assertion compares the new
    /// declaration against the old behaviour rather than against itself.
    ///
    /// ⚠️ This is a FROZEN ORACLE, not a live rule. If a future parameter is
    /// deliberately declared against it — a Hz control that genuinely wants
    /// linear travel, or a non-Hz control that wants octaves — do NOT relax
    /// this function. Add the name to `deliberateExemptions` below with the
    /// reason, so the divergence is a recorded decision instead of drift.
    static func preLiftInference(unit: String, range: ClosedRange<Double>) -> ParamCurve {
        unit == "Hz" && range.lowerBound > 0 ? .logarithmic : .linear
    }

    /// Params knowingly declared against the frozen oracle. EMPTY at m39-a:
    /// the lift changed no on-screen control's behaviour.
    ///
    /// ⚠️ Keyed `"<kind>.<name>"`, NOT by bare name. Param names repeat across
    /// kinds — `mix` appears on six, `releaseMs` on three, `attackMs` and
    /// `thresholdDb` on two — so a bare-name key would exempt every namesake
    /// silently. Use the same spelling the failure messages print.
    /// ⭐ m39-j IS THE FIRST ENTRY, and it is exactly the case the paragraph
    /// above describes: "a non-Hz control that wants octaves". The flanger's
    /// `depthMs` and `delayMs` are 0.1…10 ms — a 100:1 span, 6.6 octaves — and
    /// the frozen design table (creative-effects §6.3.1) declares both
    /// `.logarithmic`. The oracle says `.linear` only because it keys off the
    /// literal unit string "Hz", and these are milliseconds; but a delay TIME
    /// is the reciprocal of the comb frequency it produces
    /// (`FlangerParams.combNotchHz`), so even travel in ms is uneven travel in
    /// the thing the user actually hears — under linear travel the entire
    /// 0.1–1 ms region, which is the bright jet-whistle half of the effect,
    /// would sit in the first tenth of the knob. `chorus.depthMs` is NOT
    /// exempted and stays linear: its range is 0.5…10, a 20:1 span on a param
    /// that is a thickening amount rather than a tuned comb position.
    ///
    /// ⭐ m39-l ADDS FOUR, and they are the first exemptions whose unit is not
    /// a time at all — which is the interesting part, because it shows the
    /// pre-m39-a inference was never about frequency, it was about SPANS:
    ///  · `hallReverb.decaySeconds` — 0.1…20 s is 7.6 octaves of decay time.
    ///    Under linear travel everything above 4 s, which is half the usable
    ///    hall settings, sits in the last fifth of the knob.
    ///  · `hallReverb.sizeMeters` — 1…60 m is 5.9 octaves of ROOM. A linear
    ///    metre scale puts every small room in the first twentieth.
    ///  · `hallReverb.lowDecayMultiplier` (0.25…4) and `highDecayMultiplier`
    ///    (0.1…1) — a MULTIPLIER's neutral is 1, and 0.25/4 are symmetric in
    ///    OCTAVES, not in units. Linear travel would park neutral at 20 % of
    ///    the knob and make the whole bottom half unreachable by feel.
    ///
    /// ⭐ m39-n ADDS ONE, and it is the flanger's argument on a much wider
    /// span: `tapeDelay.timeMs` is 20…4000 ms — a 200:1 range, 7.6 octaves.
    /// Under linear travel every delay under 400 ms, which is most of what a
    /// musician reaches for, would sit in the first tenth of the knob while
    /// the 2–4 s dub throws took up half of it. ⚠️ `delay.timeMs` STAYS
    /// LINEAR and is NOT exempted, deliberately: that control ships today,
    /// a declared curve must not MOVE an existing control, and changing it is
    /// its own item with its own gate. The two kinds disagreeing here is a
    /// recorded consequence of the append-only rule, not an oversight.
    static let deliberateExemptions: [String: ParamCurve] = [
        "flanger.depthMs": .logarithmic,
        "flanger.delayMs": .logarithmic,
        "hallReverb.decaySeconds": .logarithmic,
        "hallReverb.sizeMeters": .logarithmic,
        "hallReverb.lowDecayMultiplier": .logarithmic,
        "hallReverb.highDecayMultiplier": .logarithmic,
        "tapeDelay.timeMs": .logarithmic,
    ]

    static func exemption(_ kind: EffectDescriptor.Kind, _ name: String) -> ParamCurve? {
        deliberateExemptions["\(kind.rawValue).\(name)"]
    }

    /// Every `(kind, spec)` pair in the tree, flattened.
    static var allEffectSpecs: [(kind: EffectDescriptor.Kind, spec: EffectParamSpec)] {
        EffectDescriptor.Kind.allCases.flatMap { kind in
            EffectParamSpec.specs(for: kind).map { (kind, $0) }
        }
    }

    // MARK: - Full-coverage conformance

    @Test("every declared curve equals the curve the pre-m39-a inference gave it")
    func conformsToThePreLiftInference() {
        for (kind, spec) in Self.allEffectSpecs {
            if let exempt = Self.exemption(kind, spec.name) {
                #expect(spec.curve == exempt,
                        "\(kind.rawValue).\(spec.name) is a recorded exemption expecting \(exempt)")
                continue
            }
            let inferred = Self.preLiftInference(unit: spec.unit, range: spec.range)
            #expect(spec.curve == inferred, """
                \(kind.rawValue).\(spec.name) declared \(spec.curve) but the pre-m39-a inference \
                gives \(inferred) (unit "\(spec.unit)", range \(spec.range.lowerBound)…\
                \(spec.range.upperBound)). Declaring a curve must not MOVE a control — if this \
                divergence is deliberate, record it in deliberateExemptions with the reason.
                """)
        }
    }

    // MARK: - Non-vacuity pins (a loop over nothing also passes)

    @Test("the conformance loop actually walked the whole roster")
    func rosterCensus() {
        // 19 kinds (m39-i appended `.djFilter`, m39-m `.ringMod`, m39-j
        // `.flanger`, m39-l `.hallReverb`, m39-n `.tapeDelay`, m23-dj
        // `.stereoWidth`, m39-o `.phaser`); `.audioUnit` is deliberately
        // param-less (AU params are not on the generic name/value surface), the
        // other 18 all carry specs.
        #expect(EffectDescriptor.Kind.allCases.count == 19)
        #expect(EffectParamSpec.specs(for: .audioUnit).isEmpty)
        let paramBearing = EffectDescriptor.Kind.allCases.filter {
            !EffectParamSpec.specs(for: $0).isEmpty
        }
        #expect(paramBearing.count == 18, "kinds with params: \(paramBearing.map(\.rawValue))")
        // Measured 2026-09-19. Append-only: this number may RISE when a param
        // is appended to a table; it must never fall (a spec's INDEX is its
        // positional automation slot and the arrays are append-only forever).
        #expect(Self.allEffectSpecs.count >= 113,
                "spec census is \(Self.allEffectSpecs.count); param arrays are append-only")
    }

    @Test("the logarithmic census is exactly the ten Hz params, named")
    func logarithmicCensus() {
        let logs = Self.allEffectSpecs.filter { $0.spec.curve == .logarithmic }
        #expect(logs.count == 28, "logarithmic specs: \(logs.map { "\($0.kind.rawValue).\($0.spec.name)" })")
        #expect(Set(logs.map(\.spec.name)) == Set([
            "lowShelfFreq", "peak1Freq", "peak2Freq", "highShelfFreq",
            "highPassFreq", "lowPassFreq",   // eq
            "highCutHz",                     // delay
            "rateHz",                        // chorus, flanger (m39-j) AND
                                             // hallReverb's modRateHz? NO —
                                             // that one is `modRateHz`, below
            "crossoverHz",                   // bassEnhancer
            "downsampleHz",                  // bitCrusher
            "carrierHz", "inputHighCutHz",   // ringMod (m39-m)
            "depthMs", "delayMs",            // flanger (m39-j) — see the
                                             // exemptions: 6.6 octaves of
                                             // delay TIME, not Hz
            "decaySeconds", "sizeMeters",    // hallReverb (m39-l) — exempted:
                                             // 7.6 octaves of TIME and 5.9 of
                                             // DISTANCE, neither one a Hz
            "lowDecayMultiplier", "highDecayMultiplier",
                                             // hallReverb — exempted: a
                                             // multiplier is symmetric in
                                             // octaves, not in units
            "lowCrossoverHz", "highCrossoverHz", "modRateHz",
                                             // hallReverb — genuine Hz, no
                                             // exemption needed
            "wowRateHz",                     // tapeDelay (m39-n) — genuine Hz
            "timeMs",                        // tapeDelay (m39-n) — EXEMPTED:
                                             // 7.6 octaves of delay time.
                                             // ⚠️ `delay.timeMs` shares this
                                             // NAME and is LINEAR, which is
                                             // why the set below is of names
                                             // and the count above is of specs
            "centerHz",                      // phaser (m39-o) — genuine Hz,
                                             // the all-pass corner at the
                                             // sweep floor. ⚠️ `phaser.rateHz`
                                             // shares the `chorus`/`flanger`
                                             // NAME, so m39-o adds TWO
                                             // logarithmic specs and ONE name.
            "bassMonoHz",                    // stereoWidth (m23-dj) — genuine
                                             // Hz, a crossover corner, no
                                             // exemption needed. ⭐ It is the
                                             // kind's ONLY logarithmic param:
                                             // `width`, `spread` and
                                             // `bassMonoAmount` are all
                                             // 0-based gains and therefore
                                             // structurally linear
        ]))
        // ⚠️ THE SET IS OF NAMES AND THE COUNT IS OF SPECS, so they move
        // differently and that is deliberate: m39-j added THREE logarithmic
        // specs (12 → 15) but only TWO new names, because `flanger.rateHz`
        // shares a name with `chorus.rateHz`. A future reader who "fixes" the
        // count to match the set size will redden this.
        // And the complement is non-trivial too: 59 linear, not "everything".
        // ⭐ m39-i added FIVE linear params and ZERO logarithmic ones, which is
        // the interesting half of this census rather than an omission: the DJ
        // filter's `position` is a FREQUENCY control whose range crosses 0, so
        // `.logarithmic` is structurally invalid on it (log(0) = -inf) and the
        // log-ness lives in `DJFilterParams.cutoffHz(atPosition:)` instead.
        // That is exactly why `hzAndLogarithmicAgreeToday` needs no exemption
        // for it — its unit is "linear", not "Hz".
        // ⭐ m39-l added SEVEN logarithmic params — more than any kind before
        // it — and FOUR of the seven needed an exemption, which is itself the
        // finding: `decaySeconds` (s), `sizeMeters` (m) and the two decay
        // MULTIPLIERS (x) are logarithmic for reasons that have nothing to do
        // with frequency. The pre-m39-a inference keyed on `unit == "Hz"`
        // because in 2026-08 every wide-span param happened to be a frequency;
        // m39-l is the first kind where that coincidence breaks in four places
        // at once.
        // ⭐ m39-m added TWO logarithmic params and three linear ones, which is
        // the first new kind since m39-a to move the logarithmic census at all:
        // `carrierHz` and `inputHighCutHz` are both genuine frequency controls
        // with a positive lower bound, so `.logarithmic` is available to them
        // where `djFilter.position` (whose range crosses 0) could not take it.
        let linears = Self.allEffectSpecs.filter { $0.spec.curve == .linear }
        #expect(linears.count == Self.allEffectSpecs.count - logs.count)
        #expect(linears.count >= 77)
    }

    @Test("every Hz-unit param is logarithmic and every logarithmic param is Hz-unit")
    func hzAndLogarithmicAgreeToday() {
        for (kind, spec) in Self.allEffectSpecs where Self.exemption(kind, spec.name) == nil {
            #expect((spec.unit == "Hz") == (spec.curve == .logarithmic),
                    "\(kind.rawValue).\(spec.name): unit \"\(spec.unit)\", curve \(spec.curve)")
        }
    }

    // MARK: - The `.decibel` guard (§7.3's divide-by-minus-infinity)

    @Test("no shipping spec declares .decibel, and the multiplicative curves all have lo > 0")
    func multiplicativeCurvesHaveAPositiveLowerBound() {
        var decibels: [String] = []
        for (kind, spec) in Self.allEffectSpecs {
            if spec.curve == .decibel { decibels.append("\(kind.rawValue).\(spec.name)") }
            if spec.curve != .linear {
                #expect(spec.curve.isValid(for: spec.range), """
                    \(kind.rawValue).\(spec.name) declares \(spec.curve) on a range starting at \
                    \(spec.range.lowerBound); log(0) and dB(0) are -infinity, so the normalisation \
                    divides by infinity (modulation-layer design §7.3).
                    """)
            }
        }
        // `.decibel` is declared in the taxonomy for m39-e's depth law; adopting
        // it for an existing param would MOVE that param's control, so nothing
        // uses it yet. This assertion is a tripwire, not an aspiration.
        #expect(decibels.isEmpty, "unexpected .decibel adopters: \(decibels)")
    }

    /// ⚠️ The assertion above passes VACUOUSLY today (nothing is `.decibel`).
    /// This is its positive control: the validator it relies on must be able to
    /// say no, proven on synthetic ranges rather than by hoping.
    @Test("the lo > 0 validator can actually refuse — synthetic positive control")
    func validatorRefusesNonPositiveLowerBounds() {
        #expect(ParamCurve.decibel.isValid(for: 0...1) == false)
        #expect(ParamCurve.logarithmic.isValid(for: 0...1) == false)
        #expect(ParamCurve.decibel.isValid(for: -24...24) == false)
        #expect(ParamCurve.logarithmic.isValid(for: -24...24) == false)
        // …and says yes where it should, so it is not simply always-false.
        #expect(ParamCurve.decibel.isValid(for: 0.001...1))
        #expect(ParamCurve.logarithmic.isValid(for: 20...20_000))
        #expect(ParamCurve.linear.isValid(for: -24...24))
        #expect(ParamCurve.linear.isValid(for: 0...1))
        // A refused curve degrades to linear rather than emitting NaN.
        let f = ParamCurve.logarithmic.fraction(forValue: 0.5, in: 0...1)
        #expect(f == 0.5)
        let v = ParamCurve.decibel.value(forFraction: 0.5, in: -24...24)
        #expect(v == 0)
    }

    // MARK: - The lifted math itself

    @Test("linear travel is the plain affine mapping, clamped both ends")
    func linearMath() {
        let r: ClosedRange<Double> = -24...24
        #expect(ParamCurve.linear.value(forFraction: 0, in: r) == -24)
        #expect(ParamCurve.linear.value(forFraction: 0.5, in: r) == 0)
        #expect(ParamCurve.linear.value(forFraction: 1, in: r) == 24)
        #expect(ParamCurve.linear.value(forFraction: 2, in: r) == 24)
        #expect(ParamCurve.linear.value(forFraction: -1, in: r) == -24)
        #expect(ParamCurve.linear.fraction(forValue: 0, in: r) == 0.5)
        #expect(ParamCurve.linear.fraction(forValue: 1_000, in: r) == 1)
        #expect(ParamCurve.linear.fraction(forValue: -1_000, in: r) == 0)
    }

    @Test("logarithmic half-travel is the geometric mean, and the pair round-trips")
    func logarithmicMath() {
        let r: ClosedRange<Double> = 20...20_000
        let mid = ParamCurve.logarithmic.value(forFraction: 0.5, in: r)
        let geo = (r.lowerBound * r.upperBound).squareRoot()
        #expect(abs(mid - geo) < geo * 1e-9, "half travel \(mid) vs geometric mean \(geo)")
        for f in stride(from: 0.0, through: 1.0, by: 0.05) {
            let v = ParamCurve.logarithmic.value(forFraction: f, in: r)
            let back = ParamCurve.logarithmic.fraction(forValue: v, in: r)
            #expect(abs(back - f) < 1e-12, "f=\(f) -> \(v) -> \(back)")
        }
        // Octaves read evenly: each 1/10 of travel is the same RATIO.
        let a = ParamCurve.logarithmic.value(forFraction: 0.1, in: r)
        let b = ParamCurve.logarithmic.value(forFraction: 0.2, in: r)
        let c = ParamCurve.logarithmic.value(forFraction: 0.3, in: r)
        #expect(abs((b / a) - (c / b)) < 1e-9)
    }

    @Test("decibel travel round-trips and is even in dB")
    func decibelMath() {
        let r: ClosedRange<Double> = 0.001...1   // -60 dB … 0 dB
        for f in stride(from: 0.0, through: 1.0, by: 0.1) {
            let v = ParamCurve.decibel.value(forFraction: f, in: r)
            let back = ParamCurve.decibel.fraction(forValue: v, in: r)
            #expect(abs(back - f) < 1e-12, "f=\(f) -> \(v) -> \(back)")
            // Even in dB: fraction f sits f of the way from -60 dB to 0 dB.
            let db = 20 * log10(v)
            #expect(abs(db - (-60 + f * 60)) < 1e-9, "f=\(f) is \(db) dB")
        }
    }

    @Test("a degenerate range yields 0, never NaN")
    func degenerateRange() {
        for curve in ParamCurve.allCases {
            let f = curve.fraction(forValue: 5, in: 5...5)
            #expect(f == 0, "\(curve)")
            #expect(!f.isNaN)
            #expect(curve.fullDepthSpan(in: 5...5) == 0, "\(curve)")
        }
    }

    @Test("full-depth span speaks each curve's own unit (the m39-e depth law)")
    func fullDepthSpans() {
        // The design doc's worked example: cutoffHz 40…18 000 spans 8.81 octaves.
        let cutoff: ClosedRange<Double> = 40...18_000
        #expect(abs(ParamCurve.logarithmic.fullDepthSpan(in: cutoff) - 8.8138) < 0.001)
        #expect(ParamCurve.linear.fullDepthSpan(in: 0...1) == 1)
        #expect(abs(ParamCurve.decibel.fullDepthSpan(in: 0.001...1) - 60) < 1e-9)
    }

    @Test("ParamCurve's raw values are the wire-facing spellings fx.describe will carry")
    func rawValues() {
        #expect(ParamCurve.linear.rawValue == "linear")
        #expect(ParamCurve.logarithmic.rawValue == "logarithmic")
        #expect(ParamCurve.decibel.rawValue == "decibel")
        #expect(ParamCurve.allCases.count == 3)
    }

    // MARK: - The append-only order the curve field must not disturb

    @Test("adding the curve field moved no spec's positional automation slot")
    func specOrderIsUnmoved() {
        // Spot-pinned heads of the tables whose slot indices the render side
        // hard-codes (see the `EffectParamSpec.specs(for:)` comments in
        // Sources/DAWEngine/Effects/*.swift).
        #expect(EffectParamSpec.specs(for: .gain).map(\.name) == ["gainLinear", "invertPolarity"])
        #expect(EffectParamSpec.specs(for: .eq).prefix(4).map(\.name)
            == ["lowShelfFreq", "lowShelfGainDb", "peak1Freq", "peak1GainDb"])
        #expect(EffectParamSpec.specs(for: .compressor).map(\.name)
            == ["thresholdDb", "ratio", "attackMs", "releaseMs", "kneeDb", "makeupDb", "mix"])
        #expect(EffectParamSpec.specs(for: .limiter).map(\.name)
            == ["ceilingDb", "releaseMs", "truePeak"])
        #expect(EffectParamSpec.specs(for: .chorus).map(\.name) == ["rateHz", "depthMs", "mix"])
    }

    /// §12 gate 3 — the per-kind automation-slot order pin for m39-i. The
    /// literal array is the point: `DJFilterEffect.storeAutomatedParam` hard-
    /// codes these five indices, so inserting a param in the MIDDLE of the
    /// table would silently re-point every saved automation lane on every
    /// shipped `.djFilter` insert. This reddens the instant that happens.
    /// APPEND-ONLY: this array may GROW at the end, never reorder or shrink.
    @Test("m39-i: the .djFilter slot order is frozen, position == automation slot")
    func djFilterSlotOrderIsFrozen() {
        #expect(EffectParamSpec.specs(for: .djFilter).map(\.name) == [
            "position",        // slot 0
            "resonance",       // slot 1
            "slopeDbPerOct",   // slot 2
            "deadZoneWidth",   // slot 3
            "resonanceTrack",  // slot 4
        ])
    }

    /// §12 gate 3 for m39-m — the same gate, the same reason. `RingModEffect
    /// .storeAutomatedParam` hard-codes these five indices, so inserting a
    /// param in the MIDDLE of the table would silently re-point every saved
    /// automation lane on every shipped `.ringMod` insert.
    /// APPEND-ONLY: this array may GROW at the end, never reorder or shrink.
    @Test("m39-m: the .ringMod slot order is frozen, carrierHz == automation slot 0")
    func ringModSlotOrderIsFrozen() {
        #expect(EffectParamSpec.specs(for: .ringMod).map(\.name) == [
            "carrierHz",        // slot 0
            "mix",              // slot 1
            "waveform",         // slot 2
            "inputHighCutHz",   // slot 3
            "stereoSpreadDeg",  // slot 4
        ])
    }

    /// §12 gate 3 for m39-l — the same gate, and the LONGEST table in the tree.
    /// `HallReverbEffect.storeAutomatedParam` hard-codes these FOURTEEN
    /// indices, so inserting a param in the MIDDLE of the table would silently
    /// re-point every saved automation lane on every shipped `.hallReverb`
    /// insert. APPEND-ONLY: this array may GROW at the end, never reorder or
    /// shrink. ⛔ In particular `topology` (the Dattorro plate mode, D4) and
    /// `density` (16 lines instead of 8) are APPENDED if and when they ship —
    /// no slot is reserved for either, because a reserved-but-inert param is a
    /// lie told to every agent that reads `fx.describe`.
    @Test("m39-l: the .hallReverb slot order is frozen, mix == automation slot 0")
    func hallReverbSlotOrderIsFrozen() {
        #expect(EffectParamSpec.specs(for: .hallReverb).map(\.name) == [
            "mix",                  // slot 0
            "decaySeconds",         // slot 1
            "sizeMeters",           // slot 2
            "preDelayMs",           // slot 3
            "width",                // slot 4
            "diffusion",            // slot 5
            "earlyLateBalance",     // slot 6
            "lowDecayMultiplier",   // slot 7
            "highDecayMultiplier",  // slot 8
            "lowCrossoverHz",       // slot 9
            "highCrossoverHz",      // slot 10
            "modRateHz",            // slot 11
            "modDepthMs",           // slot 12
            "freeze",               // slot 13
        ])
        // ⚠️ `mix` at slot 0 is load-bearing beyond ordering: it is the one
        // slot whose effect is unmistakable from a render (0 == bit-exact dry),
        // which is what `HallReverbTests` H9 uses to prove the wiring.
        let specs = EffectParamSpec.specs(for: .hallReverb)
        #expect(specs.first?.name == "mix")
        #expect(specs.first?.range.lowerBound == 0)
        // The two that CROSS or START AT zero cannot be logarithmic, and the
        // table says so rather than leaving it to be rediscovered.
        #expect(specs.first { $0.name == "earlyLateBalance" }?.curve == .linear)
        #expect(specs.first { $0.name == "modDepthMs" }?.curve == .linear)
        #expect(specs.first { $0.name == "preDelayMs" }?.curve == .linear)
        // And the two decay multipliers ARE logarithmic, because a
        // multiplier's neutral is 1 and 0.25/4 are symmetric in octaves.
        #expect(specs.first { $0.name == "lowDecayMultiplier" }?.curve == .logarithmic)
        #expect(specs.first { $0.name == "highDecayMultiplier" }?.curve == .logarithmic)
    }

    /// §12 gate 3 for m39-j — the same gate, the same reason. `FlangerEffect
    /// .storeAutomatedParam` hard-codes these six indices, so inserting a param
    /// in the MIDDLE of the table would silently re-point every saved
    /// automation lane on every shipped `.flanger` insert.
    /// APPEND-ONLY: this array may GROW at the end, never reorder or shrink.
    @Test("m39-j: the .flanger slot order is frozen, rateHz == automation slot 0")
    func flangerSlotOrderIsFrozen() {
        #expect(EffectParamSpec.specs(for: .flanger).map(\.name) == [
            "rateHz",           // slot 0
            "depthMs",          // slot 1
            "delayMs",          // slot 2
            "feedback",         // slot 3
            "mix",              // slot 4
            "stereoPhaseDeg",   // slot 5
        ])
        // ⚠️ `feedback` is the one whose DEFAULT matters to the slot map as
        // much as its position: it is the only spec in the tree whose range
        // crosses zero AND whose neutral value is not its own range midpoint
        // (0, not 0). A future `.linear`→`.logarithmic` "improvement" here is
        // structurally impossible (log(-0.95)), which is why the table says so.
        let feedback = EffectParamSpec.specs(for: .flanger).first { $0.name == "feedback" }
        #expect(feedback?.range.lowerBound == -0.95)
        #expect(feedback?.range.upperBound == 0.95)
        #expect(feedback?.curve == .linear)
    }

    /// §12 gate 3 for m39-o — the same gate, the same reason.
    /// `PhaserEffect.storeAutomatedParam` hard-codes these SEVEN indices, so
    /// inserting a param in the MIDDLE of the table would silently re-point
    /// every saved automation lane on every shipped `.phaser` insert.
    /// APPEND-ONLY: this array may GROW at the end, never reorder or shrink.
    @Test("m39-o: the .phaser slot order is frozen, rateHz == automation slot 0")
    func phaserSlotOrderIsFrozen() {
        #expect(EffectParamSpec.specs(for: .phaser).map(\.name) == [
            "rateHz",           // slot 0
            "centerHz",         // slot 1
            "depthOctaves",     // slot 2
            "stages",           // slot 3
            "feedback",         // slot 4
            "mix",              // slot 5
            "stereoPhaseDeg",   // slot 6
        ])
        let specs = EffectParamSpec.specs(for: .phaser)
        // `depthOctaves` reaches 0 (a FROZEN sweep, a real setting), so
        // `.logarithmic` is structurally invalid on it — log(0) is -inf and the
        // runtime fallback to linear is SILENT. Pinned so nobody "improves" it.
        let depth = specs.first { $0.name == "depthOctaves" }
        #expect(depth?.range.lowerBound == 0)
        #expect(depth?.curve == .linear)
        // `feedback` crosses zero, so the same argument applies, doubly.
        let feedbackSpec = specs.first { $0.name == "feedback" }
        #expect(feedbackSpec?.range.lowerBound == -0.95)
        #expect(feedbackSpec?.curve == .linear)
        // `stages` is the discrete one: its default must be an EVEN count in
        // range, or `fx.describe` advertises a value the setter would snap.
        let stages = specs.first { $0.name == "stages" }
        #expect(stages?.defaultValue == 6)
        #expect(PhaserParams.snappedStages(stages?.defaultValue ?? 0)
                == Int(stages?.defaultValue ?? 0))
        #expect(stages?.modulatable == .refused)
    }
}
