import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless built-in insert EFFECT EDITOR model (m17-a): the
/// spec-driven rows the generic card renders, the fraction↔value slider mapping
/// (log for frequencies), clamping, presentation (labels/readouts/accent), and —
/// the load-bearing part — APPLY-PATH IDENTITY with the wire: driven against a
/// REAL `ProjectStore`, every param name of every built-in kind round-trips
/// through `setEffectParam`/`setMasterEffectParam` (the exact methods
/// `fx.setParam` calls) and reads back through the model's kind-keyed reader.
@Suite("EffectEditorModel")
@MainActor
struct EffectEditorModelTests {

    // MARK: - Fixtures

    /// A model bound to a real store's track-chain methods — the same closures
    /// `AppModel` injects (UI == wire by construction).
    private static func makeStoreBacked(_ store: ProjectStore) -> EffectEditorModel {
        EffectEditorModel(
            descriptor: { trackID, effectID in
                if let trackID {
                    return store.tracks.first { $0.id == trackID }?
                        .effects.first { $0.id == effectID }
                }
                return store.masterEffects.first { $0.id == effectID }
            },
            apply: { trackID, effectID, name, value in
                if let trackID {
                    _ = try store.setEffectParam(
                        trackID: trackID, effectID: effectID, name: name, value: value)
                } else {
                    _ = try store.setMasterEffectParam(
                        effectID: effectID, name: name, value: value)
                }
            },
            setBypassed: { trackID, effectID, bypassed in
                if let trackID {
                    try store.setEffectBypassed(
                        trackID: trackID, effectID: effectID, bypassed: bypassed)
                } else {
                    try store.setMasterEffectBypassed(effectID: effectID, bypassed: bypassed)
                }
            })
    }

    /// Every built-in (non-AU) kind — the card's whole v1 coverage.
    private static let builtInKinds = EffectDescriptor.Kind.allCases.filter { $0 != .audioUnit }

    /// A test value for a spec that is guaranteed to differ from its default
    /// and to survive the store's param normalization (pingPong rounds, so the
    /// bounds — exactly representable — are the safe probes).
    private static func probeValue(for spec: EffectParamSpec) -> Double {
        spec.defaultValue == spec.range.lowerBound
            ? spec.range.upperBound : spec.range.lowerBound
    }

    // MARK: - G1: spec-driven rows

    @Test("rows are generated from the spec table for every built-in kind")
    func rowsFollowSpecs() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let model = Self.makeStoreBacked(store)
        // ≥3 kinds explicitly, then the full sweep (eq = 10 legacy + 12 m22-a;
        // compressor = 6 legacy + m23-ck's mix + m39-ae's THREE de-ess params;
        // limiter = 2 + m23-ch's truePeak). These counts are DELIBERATELY
        // literal — the sweep below proves rows follow the schema, and only a
        // literal catches a schema row that vanished.
        for (kind, count) in [(EffectDescriptor.Kind.eq, 22), (.compressor, 10), (.limiter, 3)] {
            let fx = try! store.addEffect(toTrack: track.id, kind: kind)
            model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
            #expect(model.specs.count == count, "\(kind) row count")
            #expect(model.specs.map(\.name) == EffectParamSpec.specs(for: kind).map(\.name),
                    "\(kind) rows must be the fx.describe schema, in schema order")
        }
        // ⚠️ EACH SWEEP INSERT IS REMOVED AGAIN, and that is load-bearing
        // rather than tidy: `ProjectStore.maxEffectsPerChain` is 16, this test
        // already spent 3 slots above, and m39-j's `.flanger` took the kind
        // roster to 14 built-ins — 3 + 14 = 17, which threw `chainFull(16)`
        // through a `try!` and CRASHED THE WHOLE TEST PROCESS mid-run rather
        // than failing one test. (The run reported no totals at all, which is
        // a worse failure than a red leg.) Holding the chain at length 4
        // decouples this fixture from the roster size permanently.
        for kind in Self.builtInKinds {
            let fx = try! store.addEffect(toTrack: track.id, kind: kind)
            model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
            #expect(!model.specs.isEmpty, "\(kind) must render at least one row")
            // A fresh insert reads its defaults through the reader.
            for spec in model.specs {
                #expect(model.value(for: spec) == spec.defaultValue,
                        "\(kind).\(spec.name) fresh value must be the spec default")
            }
            try! store.removeEffect(trackID: track.id, effectID: fx.id)
        }
        // Non-vacuity: the sweep ran over the WHOLE roster, and the chain is
        // back to the three explicit inserts it started the sweep with.
        #expect(Self.builtInKinds.count >= 14)
        #expect(store.tracks[0].effects.count == 3)
    }

    @Test("a closed or vanished target yields no rows and no descriptor")
    func closedYieldsNothing() {
        let store = ProjectStore()
        let model = Self.makeStoreBacked(store)
        #expect(model.descriptor == nil)
        #expect(model.specs.isEmpty)
        // Point it at a never-existing effect: still honest nothing.
        model.prepare(trackID: nil, effectID: UUID(), targetLabel: "on Master")
        #expect(model.descriptor == nil)
        #expect(model.specs.isEmpty)
        model.clear()
        #expect(model.target == nil)
        #expect(model.targetLabel.isEmpty)
    }

    // MARK: - G1: clamp

    @Test("set clamps out-of-range values to the spec range before applying")
    func setClamps() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .compressor)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        let threshold = model.specs.first { $0.name == "thresholdDb" }!
        model.set(name: "thresholdDb", value: -999)
        #expect(model.value(for: threshold) == threshold.range.lowerBound)
        model.set(name: "thresholdDb", value: 999)
        #expect(model.value(for: threshold) == threshold.range.upperBound)
        #expect(model.lastErrorMessage == nil)
        // An unknown name is a silent no-op model-side (the row list can never
        // offer one — specs are the single source of truth).
        model.set(name: "nope", value: 1)
        #expect(model.lastErrorMessage == nil)
    }

    // MARK: - G1: apply-path identity with the wire (real store, all kinds)

    @Test("every param of every kind round-trips through the store on a track chain")
    func trackChainRoundTrip() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let model = Self.makeStoreBacked(store)
        for kind in Self.builtInKinds {
            let fx = try! store.addEffect(toTrack: track.id, kind: kind)
            model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
            for spec in model.specs {
                let probe = Self.probeValue(for: spec)
                model.set(name: spec.name, value: probe)
                #expect(model.value(for: spec) == probe,
                        "\(kind).\(spec.name) did not round-trip via setEffectParam")
            }
            // Same reason as `rowsFollowSpecs`: 14 built-ins against a
            // 16-insert cap is two kinds from a `chainFull` crash, and the
            // crash takes the whole process rather than one leg.
            try! store.removeEffect(trackID: track.id, effectID: fx.id)
        }
        #expect(store.tracks[0].effects.isEmpty)
    }

    @Test("every param of every kind round-trips on the MASTER chain")
    func masterChainRoundTrip() {
        let store = ProjectStore()
        let model = Self.makeStoreBacked(store)
        for kind in Self.builtInKinds {
            let fx = try! store.addMasterEffect(kind: kind)
            model.prepare(trackID: nil, effectID: fx.id, targetLabel: "on Master")
            for spec in model.specs {
                let probe = Self.probeValue(for: spec)
                model.set(name: spec.name, value: probe)
                #expect(model.value(for: spec) == probe,
                        "master \(kind).\(spec.name) did not round-trip via setMasterEffectParam")
            }
            try! store.removeMasterEffect(effectID: fx.id)
        }
        #expect(store.masterEffects.isEmpty)
    }

    @Test("the reader's names are exactly the fx.describe schema names, per kind")
    func readerCoversSchema() {
        for kind in Self.builtInKinds {
            // ⚠️ `newlyAdded`, not a bare `EffectDescriptor(kind:)` (m39-ac-2): a
            // brand-new insert is what `ProjectStore.addEffect` builds, and for
            // `.clipper` that is NOT a bare descriptor — a bare clipper is what a
            // pre-ruling project saved, and it reads the LEGACY 4× (below).
            let fresh = EffectDescriptor.newlyAdded(kind: kind)
            for spec in EffectParamSpec.specs(for: kind) {
                #expect(EffectEditorModel.paramValue(spec.name, in: fresh) == spec.defaultValue,
                        "\(kind).\(spec.name) must read its default off a fresh descriptor")
            }
            #expect(EffectEditorModel.paramValue("notAParam", in: fresh) == nil)
        }
        // m39-ac-2: the ONE deliberate gap between "fresh" and "bare". A clipper
        // carrying no params is an untouched PRE-RULING clipper, and the card must
        // show the 4× it is rendering at, not the new default it never had.
        let bareClipper = EffectDescriptor(kind: .clipper)
        #expect(EffectEditorModel.paramValue("oversampling", in: bareClipper)
                == ClipperParams.legacyOversampling)
        #expect(ClipperParams.legacyOversampling != ClipperParams.defaultOversampling)
        // AU descriptors are off this surface entirely (v1).
        let au = EffectDescriptor(kind: .audioUnit)
        #expect(EffectEditorModel.paramValue("gainLinear", in: au) == nil)
    }

    @Test("bypass toggles through the injected store method")
    func bypassToggle() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .reverb)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        #expect(model.isBypassed == false)
        model.toggleBypass()
        #expect(model.isBypassed == true)
        #expect(store.tracks[0].effects[0].isBypassed == true)
        model.toggleBypass()
        #expect(model.isBypassed == false)
    }

    // MARK: - Slider mapping

    @Test("Hz params map logarithmically; everything else stays linear")
    func sliderScale() {
        let eqSpecs = EffectParamSpec.specs(for: .eq)
        let freq = eqSpecs.first { $0.name == "peak1Freq" }!
        #expect(EffectEditorModel.scale(for: freq) == .logarithmic)
        let gain = eqSpecs.first { $0.name == "peak1GainDb" }!
        #expect(EffectEditorModel.scale(for: gain) == .linear)

        // Log midpoint = geometric mean of the bounds.
        let mid = EffectEditorModel.value(forFraction: 0.5, spec: freq)
        let geo = (freq.range.lowerBound * freq.range.upperBound).squareRoot()
        #expect(abs(mid - geo) < geo * 1e-9)
        // Invertible both ways, ends exact.
        #expect(EffectEditorModel.fraction(forValue: freq.range.lowerBound, spec: freq) == 0)
        #expect(EffectEditorModel.fraction(forValue: freq.range.upperBound, spec: freq) == 1)
        let f = EffectEditorModel.fraction(forValue: mid, spec: freq)
        #expect(abs(f - 0.5) < 1e-9)

        // Linear midpoint = arithmetic mean.
        let linMid = EffectEditorModel.value(forFraction: 0.5, spec: gain)
        let mean = (gain.range.lowerBound + gain.range.upperBound) / 2
        #expect(abs(linMid - mean) < 1e-9)
        // Fractions clamp.
        #expect(EffectEditorModel.value(forFraction: -1, spec: gain) == gain.range.lowerBound)
        #expect(EffectEditorModel.value(forFraction: 2, spec: gain) == gain.range.upperBound)
    }

    /// m39-a — the VALUE-level half of the conformance proof.
    ///
    /// `ParamCurveConformanceTests` (DAWCoreTests) proves every DECLARED curve
    /// equals the one the old `unit == "Hz"` inference produced. That is the
    /// declaration; this is the SLIDER. For every shipping param of every kind
    /// it re-computes the pre-m39-a inline formula — the exact arithmetic that
    /// stood at `EffectEditorModel.swift:458,470` before the lift — and
    /// requires the delegating implementation to return bit-for-bit the same
    /// number at eleven points of travel. If any on-screen control moved, this
    /// reddens.
    @Test("m39-a: every slider lands on the same value it did before the taper lift")
    func taperLiftMovesNoSlider() {
        // The pre-lift bodies, verbatim.
        func legacyValue(_ f: Double, _ spec: EffectParamSpec) -> Double {
            let lo = spec.range.lowerBound, hi = spec.range.upperBound
            let f = f.clamped(to: 0...1)
            if spec.unit == "Hz" && lo > 0 { return lo * pow(hi / lo, f) }
            return lo + f * (hi - lo)
        }
        func legacyFraction(_ v: Double, _ spec: EffectParamSpec) -> Double {
            let lo = spec.range.lowerBound, hi = spec.range.upperBound
            guard hi > lo else { return 0 }
            let v = v.clamped(to: spec.range)
            if spec.unit == "Hz" && lo > 0 {
                return (log(v / lo) / log(hi / lo)).clamped(to: 0...1)
            }
            return (v - lo) / (hi - lo)
        }

        // ⚠️ THE ORACLE ONLY BINDS PARAMS THAT EXISTED BEFORE THE LIFT. A
        // param declared against it AFTER m39-a cannot have "moved an
        // on-screen control", because it had none. m39-j's `flanger.depthMs`
        // and `flanger.delayMs` are the first two: both are 0.1…10 ms — 6.6
        // octaves — and both take `.logarithmic` deliberately, because a delay
        // TIME is the reciprocal of the comb frequency the user actually
        // hears. The DAWCore home for that decision, with the full reasoning,
        // is `ParamCurveConformanceTests.deliberateExemptions`.
        //
        // ⭐ THE DIVERGENCE IS DERIVED AND THEN PINNED, rather than skipped by
        // name: anything whose declared curve disagrees with the oracle is
        // collected below and the SET is asserted. So a third divergence
        // reddens this test instead of slipping through a hand-written skip
        // list, and the two lists cannot drift apart silently.
        var divergent: Set<String> = []
        // m27-r: the ONE knob that DELIBERATELY left the oracle. The gain
        // utility's `gainLinear` still DECLARES `.linear` (so `divergent`
        // cannot see it), but its knob now takes the editor-only power taper
        // that puts unity at half travel. Derived from the editor's own
        // predicate and then PINNED, the same way as `divergent`, so a taper
        // that leaks onto a second knob reddens here.
        var editorTapered: Set<String> = []
        var checked = 0
        for kind in EffectDescriptor.Kind.allCases {
            for spec in EffectParamSpec.specs(for: kind) {
                if EffectEditorModel.usesGainTravelTaper(spec) {
                    editorTapered.insert("\(kind.rawValue).\(spec.name)")
                    continue
                }
                let oracleIsLogarithmic = spec.unit == "Hz" && spec.range.lowerBound > 0
                if (spec.curve == .logarithmic) != oracleIsLogarithmic {
                    divergent.insert("\(kind.rawValue).\(spec.name)")
                    continue
                }
                for step in 0...10 {
                    let f = Double(step) / 10
                    let lifted = EffectEditorModel.value(forFraction: f, spec: spec)
                    #expect(lifted == legacyValue(f, spec),
                            "\(kind.rawValue).\(spec.name) at f=\(f): \(lifted) vs \(legacyValue(f, spec))")
                    #expect(EffectEditorModel.fraction(forValue: lifted, spec: spec)
                            == legacyFraction(lifted, spec),
                            "\(kind.rawValue).\(spec.name) inverse at f=\(f)")
                    checked += 1
                }
                // Out-of-range both sides still clamps identically.
                #expect(EffectEditorModel.value(forFraction: -5, spec: spec) == legacyValue(-5, spec))
                #expect(EffectEditorModel.value(forFraction: 5, spec: spec) == legacyValue(5, spec))
                #expect(EffectEditorModel.fraction(forValue: -1e9, spec: spec)
                        == legacyFraction(-1e9, spec))
                #expect(EffectEditorModel.fraction(forValue: 1e9, spec: spec)
                        == legacyFraction(1e9, spec))
            }
        }
        // The recorded divergences, and ONLY those. An unexpected name here
        // means a param was declared against the frozen oracle without the
        // decision being written down.
        // ⭐ m39-l ADDED FOUR, and every one has a written reason in
        // `deliberateExemptions`: `decaySeconds` (7.6 octaves of TIME),
        // `sizeMeters` (5.9 octaves of DISTANCE) and the two decay
        // MULTIPLIERS (symmetric in octaves, not in units). They are the first
        // exemptions whose unit is neither Hz nor ms, which is the finding
        // rather than an oversight: the pre-m39-a inference keyed on
        // `unit == "Hz"` because in 2026-08 every wide-span param happened to
        // be a frequency.
        // ⭐ m39-n ADDED ONE: `tapeDelay.timeMs`, 20…4000 ms — 7.6 octaves of
        // delay time, the flanger's argument on a much wider span. ⚠️ Note
        // that `delay.timeMs` is NOT here: it ships today and a declared curve
        // must not MOVE an existing control, so the two kinds deliberately
        // disagree about the same parameter name.
        // ⭐ m39-y ADDED TWO, both TIME constants and both with a written
        // reason: `transientShaper.attackMs` (0.1…50 ms = 8.97 octaves, the
        // widest span of any exemption so far, with the musically useful third
        // under 5 ms) and `transientShaper.sustainMs` (20…1000 ms = 5.64
        // octaves). ⚠️ `compressor.attackMs` and `gate.attackMs` are NOT here
        // and stay LINEAR: they ship today and a declared curve must not MOVE
        // an existing control — the same deliberate cross-kind disagreement
        // `delay.timeMs` vs `tapeDelay.timeMs` already records.
        #expect(divergent == ["flanger.depthMs", "flanger.delayMs",
                              "hallReverb.decaySeconds", "hallReverb.sizeMeters",
                              "hallReverb.lowDecayMultiplier",
                              "hallReverb.highDecayMultiplier",
                              "tapeDelay.timeMs",
                              "transientShaper.attackMs",
                              "transientShaper.sustainMs"],
                Comment(rawValue: "params declared against the pre-m39-a oracle: "
                    + "\(divergent.sorted()) — each needs an entry in "
                    + "ParamCurveConformanceTests.deliberateExemptions with its reason"))
        // …and the two that ARE exempt still behave as `.logarithmic` sliders
        // rather than silently falling back to linear.
        let depth = EffectParamSpec.specs(for: .flanger).first { $0.name == "depthMs" }!
        let mid = EffectEditorModel.value(forFraction: 0.5, spec: depth)
        #expect(abs(mid - (0.1 * 10).squareRoot()) < 1e-12,
                "half travel on flanger.depthMs is \(mid), not the geometric mean")
        #expect(editorTapered == ["gain.gainLinear"],
                "knobs that left the oracle on purpose: \(editorTapered.sorted())")
        // Non-vacuity: a loop over an empty roster would also pass silently.
        // 64 specs x 11 travel points, measured 2026-09-19; append-only.
        #expect(checked >= 704, "only \(checked) travel points compared")
    }

    // MARK: - Presentation

    @Test("row labels humanize the wire name and drop the redundant unit token")
    func labels() {
        func label(_ kind: EffectDescriptor.Kind, _ name: String) -> String {
            let spec = EffectParamSpec.specs(for: kind).first { $0.name == name }!
            return EffectEditorModel.label(for: spec)
        }
        #expect(label(.gain, "gainLinear") == "Gain")
        #expect(label(.eq, "lowShelfFreq") == "Low Shelf Freq")
        #expect(label(.eq, "peak1GainDb") == "Peak 1 Gain")
        #expect(label(.eq, "peak2Q") == "Peak 2 Q")
        #expect(label(.compressor, "thresholdDb") == "Threshold")
        #expect(label(.compressor, "ratio") == "Ratio")
        #expect(label(.compressor, "attackMs") == "Attack")
        #expect(label(.limiter, "ceilingDb") == "Ceiling")
        #expect(label(.reverb, "roomSize") == "Room Size")
        #expect(label(.reverb, "preDelayMs") == "Pre Delay")
        #expect(label(.delay, "pingPong") == "Ping Pong")
        #expect(label(.delay, "highCutHz") == "High Cut")
        #expect(label(.chorus, "rateHz") == "Rate")
    }

    @Test("readouts format deterministically per unit")
    func readouts() {
        func spec(_ kind: EffectDescriptor.Kind, _ name: String) -> EffectParamSpec {
            EffectParamSpec.specs(for: kind).first { $0.name == name }!
        }
        let db = EffectEditorModel.readout(value: -18, spec: spec(.compressor, "thresholdDb"))
        #expect(db.text == "-18.0" && db.unit == "dB")
        let hzLow = EffectEditorModel.readout(value: 500, spec: spec(.eq, "peak1Freq"))
        #expect(hzLow.text == "500" && hzLow.unit == "Hz")
        // Sub-10 Hz rates keep decimals — 0.8 must never read as "1".
        let hzRate = EffectEditorModel.readout(value: 0.8, spec: spec(.chorus, "rateHz"))
        #expect(hzRate.text == "0.80" && hzRate.unit == "Hz")
        let hzHigh = EffectEditorModel.readout(value: 3_000, spec: spec(.eq, "peak2Freq"))
        #expect(hzHigh.text == "3.00" && hzHigh.unit == "kHz")
        let msFine = EffectEditorModel.readout(value: 2.5, spec: spec(.gate, "attackMs"))
        #expect(msFine.text == "2.5" && msFine.unit == "ms")
        let msCoarse = EffectEditorModel.readout(value: 350, spec: spec(.delay, "timeMs"))
        #expect(msCoarse.text == "350" && msCoarse.unit == "ms")
        let ratio = EffectEditorModel.readout(value: 4, spec: spec(.compressor, "ratio"))
        #expect(ratio.text == "4.0:1" && ratio.unit.isEmpty)
        // 0…1 amount params read as % (report Actionable-5) — see the
        // dedicated percent/toggle/gain tests below for the full sweep.
        let linear = EffectEditorModel.readout(value: 0.35, spec: spec(.reverb, "mix"))
        #expect(linear.text == "35" && linear.unit == "%")
        // Q stays a raw bandwidth number — NOT a percentage.
        let q = EffectEditorModel.readout(value: 1, spec: spec(.eq, "peak1Q"))
        #expect(q.text == "1.00" && q.unit.isEmpty)
        // Long ms values cross to seconds (the Hz→kHz crossover's twin).
        let sec = EffectEditorModel.readout(value: 1_500, spec: spec(.delay, "timeMs"))
        #expect(sec.text == "1.50" && sec.unit == "s")
    }

    @Test("0…1 amount params read as percentages; wire values stay fractions")
    func percentReadouts() {
        func spec(_ kind: EffectDescriptor.Kind, _ name: String) -> EffectParamSpec {
            EffectParamSpec.specs(for: kind).first { $0.name == name }!
        }
        // Every mix-type amount across the kinds.
        for (kind, name) in [
            (EffectDescriptor.Kind.reverb, "roomSize"), (.reverb, "damping"),
            (.reverb, "width"), (.reverb, "mix"), (.delay, "feedback"),
            (.delay, "mix"), (.saturator, "mix"), (.chorus, "mix"),
        ] {
            #expect(EffectEditorModel.isPercentParam(spec(kind, name)),
                    "\(kind).\(name) must read as %")
        }
        // NOT percentages: Q (0.1…18), linear gain (0…4, reads dB), pingPong
        // (a toggle), and every non-linear unit.
        #expect(!EffectEditorModel.isPercentParam(spec(.eq, "peak1Q")))
        #expect(!EffectEditorModel.isPercentParam(spec(.gain, "gainLinear")))
        #expect(!EffectEditorModel.isPercentParam(spec(.delay, "pingPong")))
        #expect(!EffectEditorModel.isPercentParam(spec(.compressor, "thresholdDb")))
        // Formatting: whole percent, no decimals.
        let half = EffectEditorModel.readout(value: 0.5, spec: spec(.chorus, "mix"))
        #expect(half.text == "50" && half.unit == "%")
        let feedback = EffectEditorModel.readout(value: 0.95, spec: spec(.delay, "feedback"))
        #expect(feedback.text == "95" && feedback.unit == "%")
        let zero = EffectEditorModel.readout(value: 0, spec: spec(.reverb, "mix"))
        #expect(zero.text == "0" && zero.unit == "%")
        let full = EffectEditorModel.readout(value: 1, spec: spec(.reverb, "width"))
        #expect(full.text == "100" && full.unit == "%")
    }

    @Test("the gain utility reads its dB equivalent; the wire keeps linear")
    func gainReadsDbEquivalent() {
        let spec = EffectParamSpec.specs(for: .gain)[0]
        let unity = EffectEditorModel.readout(value: 1, spec: spec)
        #expect(unity.text == "0.0" && unity.unit == "dB")
        let double = EffectEditorModel.readout(value: 2, spec: spec)
        #expect(double.text == "6.0" && double.unit == "dB")
        let half = EffectEditorModel.readout(value: 0.5, spec: spec)
        #expect(half.text == "-6.0" && half.unit == "dB")
        // Zero gain is honest silence, not a math error.
        let silent = EffectEditorModel.readout(value: 0, spec: spec)
        #expect(silent.text == "-∞" && silent.unit == "dB")
    }

    @Test("only level/gain-flavored params take the cyan accent")
    func accentClassification() {
        let eq = EffectParamSpec.specs(for: .eq)
        #expect(EffectEditorModel.isLevelParam(eq.first { $0.name == "lowShelfGainDb" }!))
        #expect(!EffectEditorModel.isLevelParam(eq.first { $0.name == "lowShelfFreq" }!))
        #expect(!EffectEditorModel.isLevelParam(eq.first { $0.name == "peak1Q" }!))
        let gain = EffectParamSpec.specs(for: .gain)
        #expect(EffectEditorModel.isLevelParam(gain[0]))   // gainLinear
        let reverb = EffectParamSpec.specs(for: .reverb)
        #expect(!EffectEditorModel.isLevelParam(reverb.first { $0.name == "mix" }!))
    }

    // MARK: - Grouped knob layout (the 2026-07-19 knob-vs-slider report §6)

    @Test("groups cover every spec of every kind exactly once")
    func groupsCoverSpecsExactlyOnce() {
        for kind in Self.builtInKinds {
            let grouped = EffectEditorModel.groups(for: kind).flatMap { $0.items.map(\.spec.name) }
            let schema = EffectParamSpec.specs(for: kind).map(\.name)
            #expect(Set(grouped) == Set(schema), "\(kind): grouped set must equal the schema set")
            #expect(grouped.count == schema.count, "\(kind): no param may appear twice")
            // Every item's spec is the schema's own row (ranges/defaults can
            // never fork — the table stores names only).
            for group in EffectEditorModel.groups(for: kind) {
                for item in group.items {
                    #expect(EffectParamSpec.specs(for: kind).contains(item.spec))
                    #expect(!item.label.isEmpty)
                }
            }
        }
        #expect(EffectEditorModel.groups(for: .audioUnit).isEmpty)
    }

    @Test("section composition and order are pinned per kind")
    func groupCompositionPerKind() {
        func layout(_ kind: EffectDescriptor.Kind) -> [(String, [String])] {
            EffectEditorModel.groups(for: kind).map { ($0.title, $0.items.map(\.spec.name)) }
        }
        func matches(_ actual: [(String, [String])], _ expected: [(String, [String])]) -> Bool {
            actual.count == expected.count && zip(actual, expected).allSatisfy {
                $0.0 == $1.0 && $0.1 == $1.1
            }
        }
        // m38-a: the polarity Ø switch joins the trim on the single card.
        #expect(matches(layout(.gain), [("", ["gainLinear", "invertPolarity"])]))
        #expect(matches(layout(.eq), [
            ("HIGH PASS", ["highPassFreq", "highPassSlopeDbPerOct", "highPassEnabled"]),
            ("LOW SHELF", ["lowShelfFreq", "lowShelfGainDb", "lowShelfQ", "lowShelfEnabled"]),
            ("PEAK 1", ["peak1Freq", "peak1GainDb", "peak1Q", "peak1Enabled"]),
            ("PEAK 2", ["peak2Freq", "peak2GainDb", "peak2Q", "peak2Enabled"]),
            ("HIGH SHELF", ["highShelfFreq", "highShelfGainDb", "highShelfQ", "highShelfEnabled"]),
            ("LOW PASS", ["lowPassFreq", "lowPassSlopeDbPerOct", "lowPassEnabled"]),
        ]))
        #expect(matches(layout(.compressor), [
            // m39-ae: DE-ESS is FIRST — signal-flow order, because the detector
            // filter is upstream of the threshold that reads it. It is also the
            // one section on this card a novice cannot name from the parameter
            // names alone, which is why it gets spelled-out labels.
            ("DE-ESS", ["detectorMode", "detectorFreqHz", "detectorQ"]),
            ("TRIGGER", ["thresholdDb", "ratio", "kneeDb"]),
            ("TIME", ["attackMs", "releaseMs"]),
            // m23-ck: the parallel dry/wet blend joins OUTPUT after makeup.
            ("OUTPUT", ["makeupDb", "mix"]),
        ]))
        #expect(matches(layout(.limiter), [
            ("TIME", ["releaseMs"]),
            ("OUTPUT", ["ceilingDb", "truePeak"]),
        ]))
        #expect(matches(layout(.reverb), [
            ("CHARACTER", ["roomSize", "damping", "width"]),
            ("TIME", ["preDelayMs"]),
            ("OUTPUT", ["mix"]),
        ]))
        #expect(matches(layout(.delay), [
            // m22-f: SYNC + DIVISION join TIME (knob · toggle · menu picker).
            ("TIME", ["timeMs", "sync", "division"]),
            ("REPEATS", ["feedback", "pingPong", "highCutHz"]),
            ("OUTPUT", ["mix"]),
        ]))
        #expect(matches(layout(.saturator), [
            // m39-ad: CHARACTER joins between DRIVE and OUTPUT, carrying
            // `oversampling` under the clipper's own "Quality" label — the same
            // control on the same primitive, so it reads the same on both cards.
            ("DRIVE", ["driveDb"]),
            ("CHARACTER", ["oversampling"]),
            ("OUTPUT", ["mix", "outputDb"]),
        ]))
        #expect(matches(layout(.gate), [
            ("TRIGGER", ["thresholdDb"]),
            ("TIME", ["attackMs", "holdMs", "releaseMs"]),
        ]))
        #expect(matches(layout(.chorus), [
            ("MODULATION", ["rateHz", "depthMs"]),
            ("OUTPUT", ["mix"]),
        ]))
        // EQ band knobs read short — the band prefix lives in the header.
        let eq = EffectEditorModel.groups(for: .eq)
        #expect(eq[0].items.map(\.label) == ["Freq", "Slope", "On"])
        #expect(eq[1].items.map(\.label) == ["Freq", "Gain", "Q", "On"])
        #expect(eq[2].items.map(\.label) == ["Freq", "Gain", "Q", "On"])
    }

    @Test("an OUTPUT group, where present, is always the LAST section")
    func outputGroupIsLast() {
        for kind in Self.builtInKinds {
            let groups = EffectEditorModel.groups(for: kind)
            if let outputIndex = groups.firstIndex(where: { $0.title == "OUTPUT" }) {
                #expect(outputIndex == groups.count - 1,
                        "\(kind): OUTPUT must be the final section")
            }
        }
    }

    // MARK: - Knob fill style (unipolar sweep vs bipolar center-out)

    @Test("only genuinely zero-spanning params are bipolar; anchors match")
    func knobStyles() {
        var bipolar: Set<String> = []
        for kind in Self.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) {
                switch EffectEditorModel.knobStyle(for: spec) {
                case .bipolar:
                    bipolar.insert("\(kind).\(spec.name)")
                    // Center-out fill anchors at the zero detent.
                    let anchor = EffectEditorModel.knobFillAnchor(for: spec)
                    #expect(abs(anchor - EffectEditorModel.fraction(forValue: 0, spec: spec)) < 1e-12)
                case .unipolar:
                    #expect(EffectEditorModel.knobFillAnchor(for: spec) == 0)
                }
            }
        }
        // The ±dB gain params — a -60…0 threshold or -24…0 ceiling is
        // unipolar (zero is an endpoint, not a detent) — PLUS m39-i's
        // `djFilter.position`.
        //
        // ⭐ THAT ONE BROADENS THE RULE THIS TEST STATES, and it is worth
        // saying so rather than just appending a name. Until m39-i every
        // bipolar param was a dB GAIN, so "zero-spanning" and "dB gain" were
        // the same set and the title could use either word. `position` is
        // -1…+1 LINEAR and its zero is the most literal detent in the app: a
        // bit-exact bypass. `knobStyle(for:)` is purely range-based
        // (`lowerBound < 0 && upperBound > 0`), so the centre-out knob it
        // already draws is correct with no UI change — which is the point of
        // deriving the style from the range instead of from the unit.
        // ⭐ m39-j ADDS THE THIRD SHAPE, and it confirms the broadening above
        // was the right read rather than a one-off: `flanger.feedback` is
        // -0.95…+0.95 LINEAR, it is neither a dB gain nor a filter position,
        // and its zero is a genuine detent — feedback 0 is the plain comb, and
        // the two sides of it are different characters rather than more and
        // less of one. Three unrelated kinds now share the centre-out knob
        // purely because `knobStyle(for:)` reads the RANGE, which is exactly
        // the payoff of not deriving style from the unit.
        // ⭐ CHECKED for m39-l: `hallReverb.earlyLateBalance` is -1…+1 and its
        // zero IS a detent — an even blend of early reflections and late tail,
        // with the two sides being "closer to the source" and "further into
        // the hall" rather than more and less of one thing. A FOURTH unrelated
        // kind earns the centre-out knob purely because `knobStyle(for:)`
        // reads the RANGE. ⚠️ `hallReverb.width` (0…1.2) is deliberately NOT
        // here: its neutral is 1.0, which is not the centre of its range, so a
        // centre-out knob would put the detent in the wrong place.
        // ⭐ CHECKED for m39-o: `phaser.feedback` is -0.95…+0.95 LINEAR, the
        // same shape as the flanger's and for the same reason — feedback 0 is
        // the plain phaser and the two sides are different characters (ringing
        // resonances vs a hollower inverted pattern) rather than more and less
        // of one thing. A FIFTH unrelated kind earns the centre-out knob purely
        // because `knobStyle(for:)` reads the RANGE. ⚠️ `phaser.depthOctaves`
        // (0…4) and `phaser.stages` (2…12) are deliberately NOT here: neither
        // range crosses zero, so neither has a centre to detent to.
        // ⭐ CHECKED for m39-y: THREE at once, and this is the first kind to
        // contribute more than one. `transientShaper.attackDb` and
        // `sustainDb` are −20…+20 and their zero is a genuine detent — it is
        // the UNSHAPED position, and the two sides are "more of the hit" and
        // "less of the hit" rather than more and less of one thing.
        // `outputDb` is −24…+24 and its zero is unity trim, the
        // `saturator.outputDb` shape exactly. A SIXTH unrelated kind earns the
        // centre-out knob purely because `knobStyle(for:)` reads the RANGE.
        // ⚠️ `transientShaper.mix` (0…1) and the two ms params are deliberately
        // NOT here: none of their ranges crosses zero, so none has a centre to
        // detent to.
        // CHECKED for m39-z: FOUR at once, beating m39-y's three, and for this
        // kind the centre detent is not a nicety - it is THE CONTROL.
        // `shiftHz`, `fineHz` and `stereoSpreadHz` are all bipolar because THE
        // SIGN IS THE DIRECTION (shift up vs down; which side leads), so their
        // zero is the genuine no-effect position and a user has to be able to
        // find it by feel while sweeping THROUGH it. `outputDb` is the
        // `saturator.outputDb` unity-trim shape again. `freqShifter.mix` (0-1)
        // is deliberately NOT here for the usual reason.
        // ⭐ CHECKED for m39-ac: TWO, and the first is the interesting one.
        // `clipper.driveDb` is −12…+36 where `saturator.driveDb` — the same name
        // on a neighbouring kind — is 0…36 and is NOT here. That is deliberate,
        // not drift. A saturator's drive IS the effect, so 0 means "off" and the
        // range starts there. A clipper's ceiling is the effect and drive is how
        // hard you push INTO it, so 0 is unity and NEGATIVE drive is a real
        // setting: backing a hot source off a fixed ceiling, rather than moving
        // the ceiling and changing what the number promises. So zero is a
        // genuine detent and a user has to be able to find it while sweeping
        // through. ⚠️ Its detent sits at 25 % of travel, not half, because the
        // range is deliberately asymmetric — `knobStyle(for:)` reads the range
        // and places the detent at the real zero, which is the whole point of
        // deriving it rather than declaring it. `clipper.outputDb` is −24…+24,
        // the `saturator.outputDb` unity-trim shape exactly. ⚠️
        // `clipper.ceilingDb` (−24…0) is deliberately NOT here: zero is an
        // ENDPOINT of that range, not an interior neutral, so there is no
        // centre to detent to. `mode`, `oversampling` and `mix` do not cross
        // zero either.
        #expect(bipolar == [
            "eq.lowShelfGainDb", "eq.peak1GainDb", "eq.peak2GainDb",
            "eq.highShelfGainDb", "saturator.outputDb", "djFilter.position",
            "flanger.feedback", "hallReverb.earlyLateBalance", "phaser.feedback",
            "transientShaper.attackDb", "transientShaper.sustainDb",
            "transientShaper.outputDb",
            "freqShifter.shiftHz", "freqShifter.fineHz",
            "freqShifter.stereoSpreadHz", "freqShifter.outputDb",
            "clipper.driveDb", "clipper.outputDb",
            "dynamicEQ.band1RangeDb", "dynamicEQ.band2RangeDb",
            "dynamicEQ.band3RangeDb", "dynamicEQ.band4RangeDb",
        ])
        // ⭐⭐ CHECKED for m39-af: FOUR at once — the largest single addition to
        // this list — and on this kind the centre detent is THE CONTROL, more
        // literally than on any kind before it. `bandNRangeDb`'s SIGN IS THE
        // DIRECTION the band moves: negative turns the band down when it
        // triggers, positive turns it up, and ZERO is a genuine no-effect
        // position (`rangeSign` is exactly 0 there, so the render path's apply
        // branch never fires and the band is bit-exact flat however hard it is
        // driven). A user sweeping through that zero has to be able to feel it.
        // ⚠️ The kind's other 28 params are deliberately NOT here and each for a
        // structural reason, not an oversight: `bandNThresholdDb` is −60…0, so
        // zero is an ENDPOINT rather than an interior neutral (the
        // `clipper.ceilingDb` shape exactly); `bandNFreq` (20…20 000),
        // `bandNQ` (0.1…18), `bandNRatio` (1…20) and both time constants have
        // strictly positive ranges; `bandNMode` is 0…2, where 0 is an endpoint
        // AND the value is discrete.
        for band in 1...4 {
            let range = EffectParamSpec.specs(for: .dynamicEQ)
                .first { $0.name == "band\(band)RangeDb" }!
            // −24…+24 is symmetric about zero, so the detent sits at exactly
            // half travel — the `eq.peak1GainDb` shape, which is the range it
            // mirrors.
            #expect(EffectEditorModel.knobFillAnchor(for: range) == 0.5)
        }
        // The phaser's detent also sits at exactly half travel, because its
        // range is symmetric about zero like the flanger's and the DJ filter's.
        let phaserFeedback = EffectParamSpec.specs(for: .phaser)
            .first { $0.name == "feedback" }!
        #expect(abs(EffectEditorModel.knobFillAnchor(for: phaserFeedback) - 0.5) < 1e-12)
        // The flanger's detent also sits at exactly half travel, because its
        // range is symmetric about zero like the DJ filter's.
        let feedback = EffectParamSpec.specs(for: .flanger).first { $0.name == "feedback" }!
        #expect(abs(EffectEditorModel.knobFillAnchor(for: feedback) - 0.5) < 1e-12)
        // The DJ filter's detent sits at exactly half travel on a symmetric
        // -1…+1 range, so the knob's fill grows out of the centre in both
        // directions — the club-mixer affordance, for free.
        let position = EffectParamSpec.specs(for: .djFilter).first { $0.name == "position" }!
        #expect(EffectEditorModel.knobFillAnchor(for: position) == 0.5)
        // The symmetric ranges put the detent at half travel.
        let eqGain = EffectParamSpec.specs(for: .eq).first { $0.name == "peak1GainDb" }!
        #expect(EffectEditorModel.knobFillAnchor(for: eqGain) == 0.5)
    }

    // MARK: - pingPong + *Enabled toggles

    @Test("pingPong and the EQ *Enabled binaries are the toggle params")
    func pingPongToggle() {
        for kind in Self.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) {
                // m22-f adds the delay's tempo `sync` to the binary family.
                // m23-ch adds the limiter's truePeak mode to the family.
                // m32-e adds the bit-crusher's antiAlias/dither switches.
                // m38-a adds the gain utility's invertPolarity (the Ø switch).
                // ⚠️ THIS LEG RESTATES THE SOURCE'S OWN EXPRESSION and therefore
                // proves only that the two have not drifted APART — it cannot
                // notice a binary param that neither side knows about. That is
                // not hypothetical: m32-e's two switches were missing from both
                // for a while and this leg stayed green.
                // `binaryModelParamsRenderAsToggles` below is the leg that
                // actually checks, by DERIVING the answer from the store.
                let expected = spec.name == "pingPong" || spec.name == "sync"
                    || spec.name == "truePeak"
                    || spec.name == "antiAlias" || spec.name == "dither"
                    || spec.name == "invertPolarity"
                    || spec.name.hasSuffix("Enabled")
                #expect(EffectEditorModel.isToggleParam(spec) == expected,
                        "\(kind).\(spec.name)")
            }
        }
        // Read threshold mirrors the model layer's .rounded() (0.5 rounds up).
        #expect(!EffectEditorModel.toggleIsOn(0))
        #expect(!EffectEditorModel.toggleIsOn(0.4999))
        #expect(EffectEditorModel.toggleIsOn(0.5))
        #expect(EffectEditorModel.toggleIsOn(1))
        // Readout is a state word, never a fraction.
        let spec = EffectParamSpec.specs(for: .delay).first { $0.name == "pingPong" }!
        #expect(EffectEditorModel.readout(value: 0, spec: spec) == ("OFF", ""))
        #expect(EffectEditorModel.readout(value: 1, spec: spec) == ("ON", ""))
        // Through a REAL store the model layer rounds mid values to binary —
        // the fact that justifies the toggle rendering (Effects.swift).
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .delay)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        model.set(name: "pingPong", value: 1)
        #expect(model.value(for: spec) == 1)
        model.set(name: "pingPong", value: 0.7)
        #expect(model.value(for: spec) == 1, "the model layer rounds to binary")
        model.set(name: "pingPong", value: 0)
        #expect(model.value(for: spec) == 0)
    }

    /// ⭐ THE STRUCTURAL LEG, derived rather than restated. For every built-in
    /// param whose range is 0…1, write 0.4 through a REAL store and read back
    /// what it kept: a param the MODEL LAYER snaps to 0 or 1 is binary, and a
    /// binary param MUST render as a toggle — otherwise the card offers a knob
    /// over a continuum the model does not have, and its readout says a number
    /// the sound does not use.
    ///
    /// The 0…1 filter is deliberate and not a shortcut around the question:
    /// `mix`, `amount`, `roomSize`, `damping`, `feedback` and `width` all live
    /// in that range and all keep 0.4, so the discriminator is the SNAP, not the
    /// range. `division` is excluded by the range filter because it snaps to
    /// note lengths in beats, not to 0/1 — it has its own picker rendering.
    @Test("every param the STORE snaps to binary renders as a toggle (derived)")
    func binaryModelParamsRenderAsToggles() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        var snapping: [String] = []
        var continuous: [String] = []
        for kind in Self.builtInKinds {
            let fx = try store.addEffect(toTrack: track.id, kind: kind)
            for spec in EffectParamSpec.specs(for: kind) where spec.range == 0...1 {
                let updated = try store.setEffectParam(
                    trackID: track.id, effectID: fx.id, name: spec.name, value: 0.4)
                let stored = try #require(
                    EffectEditorModel.paramValue(spec.name, in: updated),
                    "\(kind).\(spec.name) has no value accessor")
                let snapped = stored == 0 || stored == 1
                let label = "\(kind).\(spec.name)"
                if snapped { snapping.append(label) } else { continuous.append(label) }
                let shape = snapped ? "BINARY (needs a toggle)" : "CONTINUOUS (needs a knob)"
                let says = EffectEditorModel.isToggleParam(spec)
                #expect(says == snapped,
                        "\(label): a 0.4 write was stored as \(stored), so it is \(shape), but isToggleParam says \(says)")
            }
            try store.removeEffect(trackID: track.id, effectID: fx.id)
        }
        print("[measured] binary 0...1 params: \(snapping)")
        print("[measured] continuous 0...1 params: \(continuous)")
        // Non-vacuity in BOTH directions: the sweep must have seen real
        // examples of each, or "they agree" would be an empty claim.
        #expect(snapping.count >= 8, "the sweep saw too few binary params: \(snapping)")
        #expect(continuous.count >= 6, "the sweep saw too few continua: \(continuous)")
    }

    // MARK: - Undo discipline (the store's coalescing carries the card)

    @Test("a slider drag (many rapid sets of one param) lands as ONE undo step")
    func dragCoalesces() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .reverb)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        let before = store.undoHistory().undo.count
        // Simulate a drag: many per-tick applies of the same (effect, name).
        for step in 1...20 {
            model.set(name: "mix", value: Double(step) / 20)
        }
        let after = store.undoHistory().undo.count
        #expect(after == before + 1, "a drag must coalesce to exactly one undo entry")
        // Undo restores the pre-drag value (the default).
        #expect((try? store.undo()) != nil)
        let mix = EffectParamSpec.specs(for: .reverb).first { $0.name == "mix" }!
        #expect(model.value(for: mix) == mix.defaultValue)
    }

    // MARK: - m22-a EQ v2: slope chips + the HP/LP enable semantics

    @Test("HP/LP slopes are two-state chip params reading 12 or 24 dB/oct")
    func slopeChips() {
        // ⚠️⚠️ THIS LEG RESTATED THE SOURCE'S OWN EXPRESSION AND THAT COST A
        // SHIPPED BUG (m39-ag). It read `== spec.name.hasSuffix("SlopeDbPerOct")`
        // — the source's exact text — so it proved only that the two had not
        // drifted apart, and it could not notice that the DJ FILTER'S slope is
        // the bare `slopeDbPerOct` with a LOWERCASE s, which that suffix does
        // not match. `djFilter.slopeDbPerOct` therefore rendered as a KNOB over
        // a two-value topology switch, and this test stayed green the whole
        // time. `EffectChoiceParamTests.everyDiscreteParamAvoidsTheKnob` is the
        // leg that actually checks, deriving the discrete set from
        // `EffectParamSpec.modulatable == .refused`.
        //
        // The expectation below is now written against the PARAM'S OWN SNAP —
        // a param is a slope param iff `EQParams.snapSlope` is what governs it,
        // evidenced by a real store write of 15 landing on 12 — rather than
        // against a spelling.
        let sweepStore = ProjectStore()
        let sweepTrack = sweepStore.addTrack(kind: .audio)
        var snapped: [String] = []
        for kind in Self.builtInKinds {
            let sweepFX = try! sweepStore.addEffect(toTrack: sweepTrack.id, kind: kind)
            for spec in EffectParamSpec.specs(for: kind) {
                // 15 is between the two legal slopes and inside no other param's
                // "interesting" region; a slope param snaps it to 12.
                let governedBySnapSlope: Bool
                if spec.range.contains(15), spec.unit == "dB/oct" {
                    let updated = try! sweepStore.setEffectParam(
                        trackID: sweepTrack.id, effectID: sweepFX.id, name: spec.name, value: 15)
                    let stored = EffectEditorModel.paramValue(spec.name, in: updated)
                    governedBySnapSlope = stored == 12
                } else {
                    governedBySnapSlope = false
                }
                if governedBySnapSlope { snapped.append("\(kind).\(spec.name)") }
                #expect(EffectEditorModel.isSlopeParam(spec) == governedBySnapSlope,
                        "\(kind).\(spec.name): a 15 write snapped to 12 = \(governedBySnapSlope), but isSlopeParam says \(EffectEditorModel.isSlopeParam(spec))")
            }
            try! sweepStore.removeEffect(trackID: sweepTrack.id, effectID: sweepFX.id)
        }
        print("[measured] slope-snapped params: \(snapped)")
        // Non-vacuity, and the DJ filter is named: the sweep must see all THREE
        // — two EQ corners plus the one whose lowercase name hid it.
        #expect(snapped.count == 3, "the slope sweep saw \(snapped)")
        #expect(snapped.contains("djFilter.slopeDbPerOct"))
        let spec = EffectParamSpec.specs(for: .eq).first { $0.name == "highPassSlopeDbPerOct" }!
        // A slope is neither a toggle nor a percent nor a cyan level readout.
        #expect(!EffectEditorModel.isToggleParam(spec))
        #expect(!EffectEditorModel.isPercentParam(spec))
        #expect(!EffectEditorModel.isLevelParam(spec))
        // Chip read side mirrors EQParams.snapSlope (< 18 → 12, else 24).
        #expect(!EffectEditorModel.slopeIs24(12))
        #expect(!EffectEditorModel.slopeIs24(17.9))
        #expect(EffectEditorModel.slopeIs24(18))
        #expect(EffectEditorModel.slopeIs24(24))
        #expect(EffectEditorModel.readout(value: 12, spec: spec) == ("12", "dB/oct"))
        #expect(EffectEditorModel.readout(value: 24, spec: spec) == ("24", "dB/oct"))
        // Through a REAL store the model layer snaps mid values — the fact
        // that justifies the chip rendering.
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .eq)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        model.set(name: "highPassSlopeDbPerOct", value: 20)
        #expect(model.value(for: spec) == 24, "the model layer snaps to 12/24")
        model.set(name: "highPassSlopeDbPerOct", value: 13)
        #expect(model.value(for: spec) == 12)
    }

    @Test("the EQ On toggles read resolved state; enabling HP materializes a corner")
    func eqEnableToggles() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .eq)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        let specs = EffectParamSpec.specs(for: .eq)
        let hpOn = specs.first { $0.name == "highPassEnabled" }!
        let hpFreq = specs.first { $0.name == "highPassFreq" }!
        // Fresh EQ: HP reads OFF (freq nil), band toggles read ON.
        #expect(model.value(for: hpOn) == 0)
        #expect(model.value(for: specs.first { $0.name == "peak1Enabled" }!) == 1)
        // Toggling HP on from the card materializes the 20 Hz spec default.
        model.set(name: "highPassEnabled", value: 1)
        #expect(model.value(for: hpOn) == 1)
        #expect(model.value(for: hpFreq) == 20)
        #expect(store.tracks[0].effects[0].resolvedEQ.highPassFreq == 20)
        // Off keeps the corner (bypass, not reset).
        model.set(name: "highPassFreq", value: 300)
        model.set(name: "highPassEnabled", value: 0)
        #expect(model.value(for: hpOn) == 0)
        #expect(model.value(for: hpFreq) == 300)
    }

    @Test("reset-to-default applies the spec default through the same path")
    func resetToDefault() {
        let store = ProjectStore()
        let fx = try! store.addMasterEffect(kind: .limiter)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: nil, effectID: fx.id, targetLabel: "on Master")
        let ceiling = model.specs.first { $0.name == "ceilingDb" }!
        model.set(name: "ceilingDb", value: -6)
        #expect(model.value(for: ceiling) == -6)
        model.resetToDefault(ceiling)
        #expect(model.value(for: ceiling) == ceiling.defaultValue)
    }

    // MARK: - Delay tempo sync (m22-f)

    @Test("sync renders as a toggle, division as a picker; readout speaks tokens")
    func delaySyncControlClassification() {
        let specs = EffectParamSpec.specs(for: .delay)
        let sync = specs.first { $0.name == "sync" }!
        let division = specs.first { $0.name == "division" }!
        #expect(EffectEditorModel.isToggleParam(sync))
        #expect(!EffectEditorModel.isToggleParam(division))
        #expect(EffectEditorModel.isDivisionParam(division))
        #expect(!EffectEditorModel.isDivisionParam(sync))
        // The readout shows the note token at (and near) legal values —
        // deterministic strings, the m22-a slope-chip precedent.
        #expect(EffectEditorModel.readout(value: 1, spec: division) == ("1/4", ""))
        #expect(EffectEditorModel.readout(value: 0.75, spec: division) == ("1/8d", ""))
        #expect(EffectEditorModel.readout(value: 0.7, spec: division) == ("1/4t", ""))
        #expect(EffectEditorModel.readout(value: 1, spec: sync) == ("ON", ""))
    }

    @Test("the synced card derives TIME from the injected tempo; unsynced yields nil")
    func delaySyncDerivedTime() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .delay)
        let model = Self.makeStoreBacked(store)   // default tempo closure = 120
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")

        // Free-running: no derived time, the knob owns TIME.
        #expect(!model.delaySyncActive)
        #expect(model.syncedDelayTimeMs == nil)
        #expect(model.delayDivision == .quarter)

        // SYNC on: 1/4 @ 120 = 500 ms; the division picker drives the rest.
        model.set(name: "sync", value: 1)
        #expect(model.delaySyncActive)
        #expect(model.syncedDelayTimeMs == 500)
        model.setDelayDivision(.eighthDotted)
        #expect(model.delayDivision == .eighthDotted)
        #expect(model.syncedDelayTimeMs == 375)
        // The picker write went through the SAME store path the wire uses.
        #expect(store.tracks[0].effects[0].resolvedDelay.division == .eighthDotted)
        // …and the stored ms fallback never moved.
        #expect(store.tracks[0].effects[0].resolvedDelay.timeMs == 350)

        // A different injected tempo moves the readout (the live-read seam):
        // 1/8d @ 90 = 500 ms.
        let at90 = EffectEditorModel(
            descriptor: { trackID, effectID in
                guard trackID == track.id else { return nil }
                return store.tracks[0].effects.first { $0.id == effectID }
            },
            apply: { _, _, _, _ in },
            setBypassed: { _, _, _ in },
            tempoBPM: { 90 })
        at90.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        #expect(at90.syncedDelayTimeMs == 500)

        // Non-delay kinds never report sync-active.
        let eq = try! store.addEffect(toTrack: track.id, kind: .eq)
        model.prepare(trackID: track.id, effectID: eq.id, targetLabel: "on Test")
        #expect(!model.delaySyncActive)
        #expect(model.syncedDelayTimeMs == nil)
    }

    // MARK: - m27-r: the gain utility's knob travels in decibels

    /// The gain insert's one row, read from the shipping table (never rebuilt
    /// by hand, so a range change reaches these tests).
    private static var gainLinearSpec: EffectParamSpec {
        EffectParamSpec.specs(for: .gain).first { $0.name == "gainLinear" }!
    }

    private static func db(_ v: Double) -> Double { 20 * log10(v) }

    @Test("m27-r: the gain knob's travel round-trips position to value and back")
    func gainKnobTravelRoundTrips() {
        let spec = Self.gainLinearSpec
        #expect(EffectEditorModel.usesGainTravelTaper(spec),
                "the shipping gain range must pass the taper's guard, not fall back silently")
        for step in 0...100 {
            let p = Double(step) / 100
            let v = EffectEditorModel.value(forFraction: p, spec: spec)
            let back = EffectEditorModel.fraction(forValue: v, spec: spec)
            #expect(abs(back - p) < 1e-12, "p=\(p) -> v=\(v) -> p=\(back)")
        }
        for v in [0, 1e-6, 0.001, 0.5, 1, 2, 4, 8, 15.99, 16] as [Double] {
            let p = EffectEditorModel.fraction(forValue: v, spec: spec)
            let back = EffectEditorModel.value(forFraction: p, spec: spec)
            #expect(abs(back - v) <= max(v, 1e-300) * 1e-12, "v=\(v) -> p=\(p) -> v=\(back)")
        }
    }

    @Test("m27-r: the gain knob's ends are silence and x16, exactly, and it only climbs")
    func gainKnobTravelEnds() {
        let spec = Self.gainLinearSpec
        #expect(spec.range == 0...16)
        #expect(EffectEditorModel.value(forFraction: 0, spec: spec) == 0)
        #expect(EffectEditorModel.value(forFraction: 1, spec: spec) == 16)
        #expect(EffectEditorModel.fraction(forValue: 0, spec: spec) == 0)
        #expect(EffectEditorModel.fraction(forValue: 16, spec: spec) == 1)
        // Out of range clamps on both sides, never NaN.
        #expect(EffectEditorModel.value(forFraction: -1, spec: spec) == 0)
        #expect(EffectEditorModel.value(forFraction: 2, spec: spec) == 16)
        #expect(EffectEditorModel.fraction(forValue: -3, spec: spec) == 0)
        #expect(EffectEditorModel.fraction(forValue: 99, spec: spec) == 1)
        var previous = -1.0
        for step in 0...100 {
            let v = EffectEditorModel.value(forFraction: Double(step) / 100, spec: spec)
            #expect(v > previous, "travel must climb at step \(step): \(v) after \(previous)")
            previous = v
        }
    }

    @Test("m27-r: unity sits at half travel, straight up on the knob")
    func gainKnobUnityAtHalfTravel() {
        let spec = Self.gainLinearSpec
        let unity = EffectEditorModel.fraction(forValue: 1, spec: spec)
        #expect(abs(unity - 0.5) < 1e-12, "unity at \(unity)")
        #expect(abs(EffectEditorModel.value(forFraction: 0.5, spec: spec) - 1) < 1e-12)
        // 270 degrees is straight up on the 270-degree knob (KnobControl draws
        // through this same function).
        #expect(abs(MixerMath.knobAngleDegrees(forFraction: unity) - 270) < 1e-9)
        // BEFORE: the declared linear curve (still the wire's and modulation's
        // domain) puts unity at 1/16 of the travel.
        #expect(spec.curve == .linear)
        #expect(spec.curve.fraction(forValue: 1, in: spec.range) == 0.0625)
        // Double-click reset lands on the spec default, which is unity.
        #expect(spec.defaultValue == 1)
    }

    @Test("m27-r: one percent of travel at unity moves about 0.7 dB, down from 1.3-1.5 dB")
    func gainKnobSensitivityAtUnity() {
        let spec = Self.gainLinearSpec
        // AFTER (the knob's mapping).
        let up = Self.db(EffectEditorModel.value(forFraction: 0.51, spec: spec))
        let down = Self.db(EffectEditorModel.value(forFraction: 0.49, spec: spec))
        #expect(abs(up - 0.688) < 0.001, "up 1% from unity: \(up) dB")
        #expect(abs(down - -0.702) < 0.001, "down 1% from unity: \(down) dB")
        // BEFORE (the declared linear curve the knob used to ride).
        let u0 = spec.curve.fraction(forValue: 1, in: spec.range)
        let upBefore = Self.db(spec.curve.value(forFraction: u0 + 0.01, in: spec.range))
        let downBefore = Self.db(spec.curve.value(forFraction: u0 - 0.01, in: spec.range))
        #expect(abs(upBefore - 1.289) < 0.001, "before, up 1%: \(upBefore) dB")
        #expect(abs(downBefore - -1.514) < 0.001, "before, down 1%: \(downBefore) dB")
        #expect(abs(up) < abs(upBefore) / 1.8 && abs(down) < abs(downBefore) / 2)
    }

    @Test("m27-r: every other knob travels bit-identically to its declared curve")
    func gainTaperTouchesNoOtherKnob() {
        var skipped: [String] = []
        var checked = 0
        for kind in EffectDescriptor.Kind.allCases {
            for spec in EffectParamSpec.specs(for: kind) {
                let id = "\(kind.rawValue).\(spec.name)"
                // The literal, NOT the editor's predicate: this control must
                // not share the implementation's notion of which knob moved.
                if id == "gain.gainLinear" { skipped.append(id); continue }
                for step in -5...25 {
                    let f = Double(step) / 20
                    #expect(EffectEditorModel.value(forFraction: f, spec: spec)
                            == spec.curve.value(forFraction: f, in: spec.range), "\(id) f=\(f)")
                    let v = spec.range.lowerBound
                        + Double(step) / 20 * (spec.range.upperBound - spec.range.lowerBound)
                    #expect(EffectEditorModel.fraction(forValue: v, spec: spec)
                            == spec.curve.fraction(forValue: v, in: spec.range), "\(id) v=\(v)")
                    checked += 1
                }
                #expect(EffectEditorModel.fraction(forValue: -1e9, spec: spec)
                        == spec.curve.fraction(forValue: -1e9, in: spec.range), "\(id) -1e9")
                #expect(EffectEditorModel.fraction(forValue: 1e9, spec: spec)
                        == spec.curve.fraction(forValue: 1e9, in: spec.range), "\(id) 1e9")
            }
        }
        #expect(skipped == ["gain.gainLinear"])
        // The polarity switch shares the gain insert and the "linear" unit.
        let polarity = EffectParamSpec.specs(for: .gain).first { $0.name == "invertPolarity" }!
        #expect(!EffectEditorModel.usesGainTravelTaper(polarity))
        // Non-vacuity: 64 specs x 31 points is the floor measured at m39-a.
        #expect(checked >= 64 * 31, "only \(checked) points compared")
    }

    @Test("m27-r: only gain.gainLinear takes the gain knob taper")
    func gainTaperCensus() {
        var tapered: Set<String> = []
        for kind in EffectDescriptor.Kind.allCases {
            for spec in EffectParamSpec.specs(for: kind) where EffectEditorModel.usesGainTravelTaper(spec) {
                tapered.insert("\(kind.rawValue).\(spec.name)")
            }
        }
        #expect(tapered == ["gain.gainLinear"], "tapered: \(tapered.sorted())")
    }

    @Test("m27-r: the readout at the gain knob's marks still speaks dB")
    func gainKnobReadoutAtMarks() {
        let spec = Self.gainLinearSpec
        func readout(atFraction f: Double) -> String {
            let r = EffectEditorModel.readout(
                value: EffectEditorModel.value(forFraction: f, spec: spec), spec: spec)
            return r.text + " " + r.unit
        }
        #expect(readout(atFraction: 0.5) == "0.0 dB")
        #expect(readout(atFraction: 1) == "24.1 dB")
        #expect(readout(atFraction: 0) == "-∞ dB")
    }
}
