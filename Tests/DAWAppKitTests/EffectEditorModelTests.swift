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
        // ≥3 kinds explicitly, then the full sweep.
        for (kind, count) in [(EffectDescriptor.Kind.eq, 10), (.compressor, 6), (.limiter, 2)] {
            let fx = try! store.addEffect(toTrack: track.id, kind: kind)
            model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
            #expect(model.specs.count == count, "\(kind) row count")
            #expect(model.specs.map(\.name) == EffectParamSpec.specs(for: kind).map(\.name),
                    "\(kind) rows must be the fx.describe schema, in schema order")
        }
        for kind in Self.builtInKinds {
            let fx = try! store.addEffect(toTrack: track.id, kind: kind)
            model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
            #expect(!model.specs.isEmpty, "\(kind) must render at least one row")
            // A fresh insert reads its defaults through the reader.
            for spec in model.specs {
                #expect(model.value(for: spec) == spec.defaultValue,
                        "\(kind).\(spec.name) fresh value must be the spec default")
            }
        }
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
        }
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
        }
    }

    @Test("the reader's names are exactly the fx.describe schema names, per kind")
    func readerCoversSchema() {
        for kind in Self.builtInKinds {
            let fresh = EffectDescriptor(kind: kind)
            for spec in EffectParamSpec.specs(for: kind) {
                #expect(EffectEditorModel.paramValue(spec.name, in: fresh) == spec.defaultValue,
                        "\(kind).\(spec.name) must read its default off a fresh descriptor")
            }
            #expect(EffectEditorModel.paramValue("notAParam", in: fresh) == nil)
        }
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
        #expect(matches(layout(.gain), [("", ["gainLinear"])]))
        #expect(matches(layout(.eq), [
            ("LOW SHELF", ["lowShelfFreq", "lowShelfGainDb"]),
            ("PEAK 1", ["peak1Freq", "peak1GainDb", "peak1Q"]),
            ("PEAK 2", ["peak2Freq", "peak2GainDb", "peak2Q"]),
            ("HIGH SHELF", ["highShelfFreq", "highShelfGainDb"]),
        ]))
        #expect(matches(layout(.compressor), [
            ("TRIGGER", ["thresholdDb", "ratio", "kneeDb"]),
            ("TIME", ["attackMs", "releaseMs"]),
            ("OUTPUT", ["makeupDb"]),
        ]))
        #expect(matches(layout(.limiter), [
            ("TIME", ["releaseMs"]),
            ("OUTPUT", ["ceilingDb"]),
        ]))
        #expect(matches(layout(.reverb), [
            ("CHARACTER", ["roomSize", "damping", "width"]),
            ("TIME", ["preDelayMs"]),
            ("OUTPUT", ["mix"]),
        ]))
        #expect(matches(layout(.delay), [
            ("TIME", ["timeMs"]),
            ("REPEATS", ["feedback", "pingPong", "highCutHz"]),
            ("OUTPUT", ["mix"]),
        ]))
        #expect(matches(layout(.saturator), [
            ("DRIVE", ["driveDb"]),
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
        #expect(eq[0].items.map(\.label) == ["Freq", "Gain"])
        #expect(eq[1].items.map(\.label) == ["Freq", "Gain", "Q"])
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

    @Test("only genuinely zero-spanning dB gains are bipolar; anchors match")
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
        // Exactly the ±dB gain params — a -60…0 threshold or -24…0 ceiling
        // is unipolar (zero is an endpoint, not a detent).
        #expect(bipolar == [
            "eq.lowShelfGainDb", "eq.peak1GainDb", "eq.peak2GainDb",
            "eq.highShelfGainDb", "saturator.outputDb",
        ])
        // The symmetric ranges put the detent at half travel.
        let eqGain = EffectParamSpec.specs(for: .eq).first { $0.name == "peak1GainDb" }!
        #expect(EffectEditorModel.knobFillAnchor(for: eqGain) == 0.5)
    }

    // MARK: - pingPong toggle

    @Test("pingPong is the one toggle param; threshold and writes are binary")
    func pingPongToggle() {
        for kind in Self.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) {
                #expect(EffectEditorModel.isToggleParam(spec) == (spec.name == "pingPong"),
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
}
