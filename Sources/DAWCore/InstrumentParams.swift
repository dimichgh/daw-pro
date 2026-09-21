import Foundation

// The ONE HOME for built-in instrument parameter specs (m39-b / m39-e §4).
//
// Checked 2026-09-19: DAWCore has NO `Instruments.swift` and NO
// `Modulation.swift`-shaped home for this. It DOES have
// `InstrumentControllerSupport` / `InstrumentFamilyResolution` /
// `InstrumentFrequencyReference` — none of which is this home. The name
// mirrors `Effects.swift`, which is where `EffectParamSpec` lives.
//
// ⭐ THREE ITEMS MUST READ THIS TABLE, or it diverges the way the log-taper
// heuristic already diverged across two editor models:
//   · m39-b — `AutomationTarget.valueRange(in:)` resolution and lane clamping
//   · m39-e — route validation, depth normalisation, refusal taxonomy
//   · m39-f — `instrument.describeSynth` must return this table VERBATIM
//             rather than re-typing the numbers
//
// ⚠️⚠️ SLOT POSITIONALITY DOES NOT TRANSFER, AND MUST NEVER BE ALLOWED TO.
// Effect automation slots are positional and append-only forever
// (`storeAutomatedParam(slot:)`). Instrument params are addressed **by name
// end to end** — the delivery path resolves a name to a field at publish time
// on the main actor, never by index on the render thread. So these arrays may
// be reordered freely, and **must not** acquire an index-addressed setter
// later. This is the single most likely future mistake in this file.

/// One built-in instrument parameter's schema — the instrument twin of
/// `EffectParamSpec`, including m39-a's declared `curve` and m39-e's
/// `modulatable` verdict.
public struct InstrumentParamSpec: Sendable, Equatable {
    public let name: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    /// Human-readable unit ("Hz", "s", "level", "").
    public let unit: String
    /// How the parameter's 0…1 travel maps onto `range` — DECLARED, never
    /// inferred (m39-a). The modulation depth law is defined in terms of it.
    public let curve: ParamCurve
    /// Whether modulation may address it, and how honestly (m39-e §6.1).
    public let modulatable: Modulatable
    /// Optional teaching line, surfaced verbatim by the describe verbs.
    public let note: String?

    /// ⭐ m39-dm — THE RENDER-SIDE IDENTITY, NOW CARRIED BY THE TABLE ITSELF.
    ///
    /// It used to be reached through `InstrumentParamID(rawValue: name)`, which
    /// is a FLAT seven-case enum. The drum machine addresses parameters by a
    /// dotted `<scope>.<param>` name, and `InstrumentParamID(rawValue:
    /// "kick.tune")` is nil — so the snapshot builder's guard failed and the
    /// route was DROPPED from the published snapshot, silently, after
    /// `mod.addRoute` had already answered success. Moving the code here
    /// REMOVES a name→enum round trip rather than adding one, and makes this
    /// table the single resolution point from name to render-thread identity,
    /// which is what its header already claims it is.
    ///
    /// Wire-local: carried inside one snapshot, never persisted, never on the
    /// wire. `InstrumentParamID.code` remains the authority for `.polySynth`
    /// (this field is populated FROM it, so the two cannot disagree) and
    /// `InstrumentParamCodePositiveControlTests` pins 0…6 as unmoved.
    public let code: Int32

    /// Whether the parameter is consumed only when a note starts. Modulating
    /// one is permitted but it takes effect at the NEXT note-on.
    ///
    /// ⚠️ m39-dm moved this here from `InstrumentParamID.appliesAtNextNoteOn`
    /// FOR THE SAME REASON as `code`, and missing it would have been a SILENT
    /// loss rather than a compile error: the moment drum params stopped
    /// resolving through `InstrumentParamID`, nothing would have carried the
    /// flag and the describe verbs' "Takes effect at the next note-on" line
    /// would simply have stopped being true. Populated from the enum for
    /// `.polySynth`, so the two homes cannot drift.
    public let appliesAtNextNoteOn: Bool

    public init(name: String, range: ClosedRange<Double>, defaultValue: Double,
                unit: String, curve: ParamCurve, modulatable: Modulatable,
                note: String? = nil, code: Int32, appliesAtNextNoteOn: Bool) {
        self.name = name
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
        self.curve = curve
        self.modulatable = modulatable
        self.note = note
        self.code = code
        self.appliesAtNextNoteOn = appliesAtNextNoteOn
    }

    /// Convenience for the `.polySynth` rows: both new fields come straight
    /// from `InstrumentParamID`, so a row cannot be written with a code the
    /// enum disagrees with.
    init(id: InstrumentParamID, range: ClosedRange<Double>, defaultValue: Double,
         unit: String, curve: ParamCurve, modulatable: Modulatable,
         note: String? = nil) {
        self.init(name: id.rawValue, range: range, defaultValue: defaultValue,
                  unit: unit, curve: curve, modulatable: modulatable, note: note,
                  code: id.code, appliesAtNextNoteOn: id.appliesAtNextNoteOn)
    }
}

/// The render-side identity of a built-in instrument parameter. Resolved from
/// a NAME on the main actor at publish time so the render thread never touches
/// a String — and deliberately an enum rather than an index, because the
/// append-only slot law does not reach this file (see the header).
public enum InstrumentParamID: String, Sendable, Equatable, CaseIterable {
    case cutoffHz
    case resonance
    case gain
    case attack
    case decay
    case sustain
    case release

    /// Stable numeric code for the published POD snapshot. Values are frozen;
    /// adding a case appends a new one. (This is a WIRE-LOCAL code carried
    /// inside one snapshot, not a persisted slot — nothing on disk or on the
    /// wire ever sees it.)
    public var code: Int32 {
        switch self {
        case .cutoffHz: return 0
        case .resonance: return 1
        case .gain: return 2
        case .attack: return 3
        case .decay: return 4
        case .sustain: return 5
        case .release: return 6
        }
    }

    /// Whether the parameter is consumed only when a note starts. Modulating
    /// one is permitted (`yes`) but takes effect at the NEXT note-on, and the
    /// spec's `note` says so rather than leaving an agent to discover it.
    public var appliesAtNextNoteOn: Bool {
        switch self {
        case .attack, .decay, .sustain, .release: return true
        case .cutoffHz, .resonance, .gain: return false
        }
    }
}

public extension InstrumentParamSpec {
    /// The modulatable-parameter schema for a built-in instrument kind.
    ///
    /// ⚠️ **m39-g's new fields are NOT enumerated here, on purpose** — that
    /// surface was in flight while this contract was frozen, and a frozen list
    /// of an in-flight surface is a lie with a date on it. THE RULE IS FROZEN
    /// INSTEAD, and whoever extends this table applies it:
    ///
    /// > A new instrument param is **modulatable** iff it is continuous, read
    /// > on the render path from the params snapshot, and its consumer either
    /// > applies it per sample or re-derives cheaply. Anything consumed only at
    /// > note-on is `yes` with the `appliesAtNextNoteOn` note. Anything
    /// > discrete is `refused` (`modulationTargetUnsupported`, `discrete`).
    ///
    /// `sampler`, `soundBank`, `audioUnit` and `testTone` return an EMPTY
    /// table in v1 — and empty is load-bearing, not a stub: a hosted
    /// instrument is refused with `hostedInstrument` and its image ratio
    /// rather than silently aliased (§8.1), and the sampler's own modulatable
    /// surface is a separate item.
    static func specs(for kind: InstrumentDescriptor.Kind) -> [InstrumentParamSpec] {
        switch kind {
        case .polySynth:
            let d = PolySynthParams()
            return [
                InstrumentParamSpec(
                    id: .cutoffHz,
                    range: PolySynthParams.cutoffRange, defaultValue: d.cutoffHz,
                    unit: "Hz", curve: .logarithmic, modulatable: .yes,
                    note: "Low-pass filter corner. Modulation depth is in OCTAVES "
                        + "because the curve is logarithmic: depth 0.1 across the "
                        + "40–18 000 Hz range is ±0.88 octaves, and it means the "
                        + "same musical gesture at 200 Hz as at 8 kHz."),
                InstrumentParamSpec(
                    id: .resonance,
                    range: PolySynthParams.resonanceRange, defaultValue: d.resonance,
                    unit: "", curve: .linear, modulatable: .yes),
                InstrumentParamSpec(
                    id: .gain,
                    range: PolySynthParams.gainRange, defaultValue: d.gain,
                    unit: "level", curve: .linear, modulatable: .yes),
                InstrumentParamSpec(
                    id: .attack,
                    range: PolySynthParams.attackRange, defaultValue: d.attack,
                    unit: "s", curve: .logarithmic, modulatable: .yes,
                    note: "Takes effect at the next note-on: a sounding voice keeps "
                        + "the attack it started with."),
                InstrumentParamSpec(
                    id: .decay,
                    range: PolySynthParams.decayRange, defaultValue: d.decay,
                    unit: "s", curve: .logarithmic, modulatable: .yes,
                    note: "Takes effect at the next note-on."),
                InstrumentParamSpec(
                    id: .sustain,
                    range: PolySynthParams.sustainRange, defaultValue: d.sustain,
                    unit: "level", curve: .linear, modulatable: .yes,
                    note: "Takes effect at the next note-on."),
                InstrumentParamSpec(
                    id: .release,
                    range: PolySynthParams.releaseRange, defaultValue: d.release,
                    unit: "s", curve: .logarithmic, modulatable: .yes,
                    note: "Takes effect at the next note-on."),
            ]
        case .drumSynth:
            // ⭐ m39-dm — 75 rows, DERIVED FROM `DrumKitParams.paramSpecs`
            // rather than re-typed. Two hand-maintained lists of 75 names would
            // have diverged on the first edit; this one cannot, and the
            // `describeDrumKit` verb reads the same table again rather than a
            // third copy.
            //
            // ⭐⭐ EVERY ROW IS `.yes`. This is the first built-in instrument
            // whose `discreteParamNames` is empty and whose entire surface is
            // modulatable — which is exactly what the brief asked for. It is
            // affordable because a one-shot consumes its parameters at
            // note-on, so there is no per-sample coefficient re-derivation and
            // no block-rate zipper problem to trade against.
            return DrumKitParams.paramSpecs.map { spec in
                InstrumentParamSpec(
                    name: spec.name, range: spec.range,
                    defaultValue: spec.defaultValue, unit: spec.unit,
                    curve: spec.curve, modulatable: .yes, note: spec.note,
                    code: spec.code, appliesAtNextNoteOn: spec.appliesAtNextNoteOn)
            }
        case .testTone, .sampler, .audioUnit, .soundBank:
            return []
        }
    }

    /// The DISCRETE params of a kind — named so a refusal can say WHY rather
    /// than only that the name is unknown. `waveform` is an enum and
    /// `pedalHoldLimit` is a note count: an LFO cannot drive either
    /// meaningfully (§4's frozen table).
    static func discreteParamNames(for kind: InstrumentDescriptor.Kind) -> [String] {
        switch kind {
        case .polySynth: return ["waveform", "pedalHoldLimit"]
        // ⭐ `.drumSynth` returns EMPTY, and the emptiness is a DESIGN
        // PROPERTY rather than an unfinished table: the drum machine has no
        // discrete parameter at all. 808-vs-909 is a preset over one
        // continuous topology, not a `character` enum; `chokeGroup` is
        // structural and deliberately kept off the modulation surface. So no
        // `modulationTargetUnsupported(.discrete)` refusal exists for this
        // instrument, which is what makes "every parameter automatable" true
        // rather than nearly true.
        case .testTone, .sampler, .audioUnit, .soundBank, .drumSynth: return []
        }
    }

    /// Whether the kind is HOSTED — refused with `hostedInstrument` and its
    /// image ratio rather than aliased (§8.1).
    static func isHosted(_ kind: InstrumentDescriptor.Kind) -> Bool {
        kind == .soundBank || kind == .audioUnit
    }

    /// The current value of a named param on a descriptor — the base the depth
    /// law offsets. nil when the name does not resolve on that kind.
    static func currentValue(of name: String, in descriptor: InstrumentDescriptor) -> Double? {
        // ⛔ m39-dm — WITHOUT THIS BRANCH EVERY DRUM ROUTE WOULD MODULATE
        // AROUND THE DEFAULT RATHER THAN AROUND THE VALUE THE USER SET.
        // `ModulationSnapshotBuilder` uses this for `baseValue` and falls back
        // to `spec.defaultValue` when it returns nil — so a user who tuned the
        // kick to 40 Hz and then put an LFO on it would hear the LFO wobble
        // around 52 Hz. Audible, wrong, and nothing fails anywhere.
        if descriptor.kind == .drumSynth {
            return descriptor.resolvedDrumKit.value(forParamName: name)
        }
        guard descriptor.kind == .polySynth, let id = InstrumentParamID(rawValue: name) else {
            return nil
        }
        let p = descriptor.polySynth
        switch id {
        case .cutoffHz: return p.cutoffHz
        case .resonance: return p.resonance
        case .gain: return p.gain
        case .attack: return p.attack
        case .decay: return p.decay
        case .sustain: return p.sustain
        case .release: return p.release
        }
    }
}
