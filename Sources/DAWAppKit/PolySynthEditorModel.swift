import Foundation
import Observation
import DAWCore

/// One tunable Poly Synth parameter as the editor card renders it: the wire
/// name (`track.setInstrument`'s own field name), the knob micro-label, the
/// range/default straight from `PolySynthParams` (the single source of truth —
/// this table can never fork the domain clamps), and the storage unit the
/// formatter keys on ("s" for the envelope times, "Hz" for the cutoff,
/// "linear" for the 0…1 levels).
public struct PolySynthParamSpec: Equatable, Sendable {
    /// The `track.setInstrument` field name ("attack", "cutoffHz", …).
    public let name: String
    /// The knob micro-label ("Attack", "Cutoff", …).
    public let label: String
    /// The legal range — `PolySynthParams`'s own clamp range, verbatim.
    public let range: ClosedRange<Double>
    /// The double-click reset value — `PolySynthParams()`'s default, verbatim.
    public let defaultValue: Double
    /// The STORAGE unit ("s" / "Hz" / "linear") — display crossovers (ms↔s,
    /// Hz↔kHz, %-for-amounts, dB-for-gain) live in `readout(value:spec:)`.
    public let unit: String

    public init(name: String, label: String, range: ClosedRange<Double>,
                defaultValue: Double, unit: String) {
        self.name = name
        self.label = label
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
    }
}

/// One SECTION of the Poly Synth card's grouped knob layout (the
/// `EffectParamGroup` idiom — the 2026-07-19 knob-vs-slider report §6): a
/// micro-header title over the member knob specs. The OSC section (waveform)
/// is NOT here — a wave shape is categorical, so it renders as a segmented
/// picker above the knob groups, never a knob (report §3).
public struct PolySynthParamGroup: Equatable, Sendable {
    public let title: String
    public let items: [PolySynthParamSpec]

    public init(title: String, items: [PolySynthParamSpec]) {
        self.title = title
        self.items = items
    }
}

/// Headless state machine for the built-in POLY SYNTH editor card — the
/// `EffectEditorModel` idiom pointed at an instrument: the spec table the
/// generic card renders, the current values read from the LIVE track
/// descriptor (so a wire `track.setInstrument` moves the open card's knobs),
/// and the apply path — each edit goes through injected closures wired to the
/// SAME `ProjectStore.setInstrument` partial-update the wire's
/// `track.setInstrument` calls (UI == wire, ZERO new wire surface; the store
/// coalesces per-track under "Change Instrument", so a knob drag is ONE undo
/// step). No SwiftUI/AppKit: the card is thin over this and the tests drive it
/// against a real store (the `EffectEditorModel` precedent).
///
/// The editor exists ONLY for `kind == .polySynth` — a sound bank has program
/// selection, a hosted AU has its own plugin window (M3 vi-b), and neither
/// ever reaches this surface. NO VIOLET — standard instrument chrome, not AI
/// content (docs/DESIGN-LANGUAGE.md Rule 3); cyan marks only the genuinely
/// level-flavored gain readout.
@MainActor
@Observable
public final class PolySynthEditorModel {
    /// Reads the LIVE resolved descriptor for a track — nil when the track is
    /// gone or is not an instrument track; a present instrument-track with no
    /// stored instrument resolves to `.default` (which IS the poly synth), the
    /// injector's contract.
    private let descriptorProvider: (UUID) -> InstrumentDescriptor?
    /// Applies ONE validated numeric field by wire name — wired to
    /// `store.setInstrument(id:attack:…)` with exactly that field non-nil (the
    /// store's partial-update contract: every other setting survives).
    private let applyParam: (UUID, String, Double) throws -> Void
    /// Applies the waveform — the same `setInstrument` funnel's enum field.
    private let applyWaveform: (UUID, PolySynthParams.Waveform) throws -> Void

    /// The track being tuned (nil = the model is idle). The card's visibility
    /// is the app model's `polySynthEditorTrackID`; this mirrors it for reads.
    public private(set) var trackID: UUID?
    /// The header's context tag ("on Lead") — computed by the caller at open
    /// time (the store owns names, the model just displays).
    public private(set) var targetLabel: String = ""
    /// A store refusal surfaced inline (the `EffectEditorModel` idiom). Rare —
    /// the model clamps before applying, so only a vanished/retyped target throws.
    public private(set) var lastErrorMessage: String?

    public init(
        descriptor: @escaping (UUID) -> InstrumentDescriptor?,
        apply: @escaping (UUID, String, Double) throws -> Void,
        setWaveform: @escaping (UUID, PolySynthParams.Waveform) throws -> Void
    ) {
        self.descriptorProvider = descriptor
        self.applyParam = apply
        self.applyWaveform = setWaveform
    }

    /// Points the editor at one track and resets transient state.
    public func prepare(trackID: UUID, targetLabel: String) {
        self.trackID = trackID
        self.targetLabel = targetLabel
        lastErrorMessage = nil
    }

    /// Clears the target on close, so a stale card can never re-render.
    public func clear() {
        trackID = nil
        targetLabel = ""
        lastErrorMessage = nil
    }

    // MARK: - Live reads

    /// The open track's live instrument descriptor (nil = closed, the track
    /// vanished, or it is not an instrument track).
    public var descriptor: InstrumentDescriptor? {
        trackID.flatMap { descriptorProvider($0) }
    }

    /// Whether the open target still plays the built-in poly synth — the
    /// card's render gate: a wire kind-switch mid-open honestly drops the
    /// card, never a stale ghost (the `EffectEditorOverlay` descriptor rule).
    public var targetIsPolySynth: Bool {
        descriptor?.kind == .polySynth
    }

    /// The live params (defaults when closed/vanished — the fresh-track read).
    public var params: PolySynthParams {
        descriptor?.polySynth ?? PolySynthParams()
    }

    /// The current wave shape (for the OSC picker's lit segment).
    public var waveform: PolySynthParams.Waveform { params.waveform }

    // MARK: - The spec table (single source of truth: PolySynthParams)

    /// Every numeric Poly Synth parameter, in `track.setInstrument` field
    /// order. Ranges and reset defaults come from `PolySynthParams` itself so
    /// the table can never drift from the domain clamps.
    public static let specs: [PolySynthParamSpec] = {
        let d = PolySynthParams()
        return [
            PolySynthParamSpec(name: "attack", label: "Attack",
                               range: PolySynthParams.attackRange,
                               defaultValue: d.attack, unit: "s"),
            PolySynthParamSpec(name: "decay", label: "Decay",
                               range: PolySynthParams.decayRange,
                               defaultValue: d.decay, unit: "s"),
            PolySynthParamSpec(name: "sustain", label: "Sustain",
                               range: PolySynthParams.sustainRange,
                               defaultValue: d.sustain, unit: "linear"),
            PolySynthParamSpec(name: "release", label: "Release",
                               range: PolySynthParams.releaseRange,
                               defaultValue: d.release, unit: "s"),
            PolySynthParamSpec(name: "cutoffHz", label: "Cutoff",
                               range: PolySynthParams.cutoffRange,
                               defaultValue: d.cutoffHz, unit: "Hz"),
            PolySynthParamSpec(name: "resonance", label: "Resonance",
                               range: PolySynthParams.resonanceRange,
                               defaultValue: d.resonance, unit: "linear"),
            PolySynthParamSpec(name: "gain", label: "Gain",
                               range: PolySynthParams.gainRange,
                               defaultValue: d.gain, unit: "linear"),
        ]
    }()

    /// The grouped knob sections, top to bottom: shaping first, OUTPUT always
    /// LAST — the hard layout rule from the SSL/Cubase/Pro-C3 strip precedent
    /// (report §5/§6). Waveform is the separate OSC picker section, above.
    public static let groups: [PolySynthParamGroup] = {
        let byName = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
        let table: [(String, [String])] = [
            ("ENVELOPE", ["attack", "decay", "sustain", "release"]),
            ("FILTER", ["cutoffHz", "resonance"]),
            ("OUTPUT", ["gain"]),
        ]
        return table.map { title, names in
            PolySynthParamGroup(title: title, items: names.compactMap { byName[$0] })
        }
    }()

    // MARK: - Waveform (OSC picker, never a knob — report §3)

    /// The pickable wave shapes, in `PolySynthParams.Waveform` declaration
    /// order (saw first — the default and the classic subtractive start).
    public static let waveforms: [PolySynthParams.Waveform] =
        PolySynthParams.Waveform.allCases

    /// The segment label for a wave shape ("Saw", "Square", …).
    public static func waveformLabel(_ waveform: PolySynthParams.Waveform) -> String {
        switch waveform {
        case .saw: return "Saw"
        case .square: return "Square"
        case .triangle: return "Triangle"
        case .sine: return "Sine"
        }
    }

    /// Applies a wave-shape selection through the injected `setInstrument` path.
    public func setWaveform(_ waveform: PolySynthParams.Waveform) {
        guard let trackID else { return }
        do {
            try applyWaveform(trackID, waveform)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Values + edits (the wire-identical apply path)

    /// The current value for one knob — read from the live params by wire name
    /// (nil for an unknown name, structurally impossible from the spec table).
    public static func paramValue(_ name: String, in params: PolySynthParams) -> Double? {
        switch name {
        case "attack": return params.attack
        case "decay": return params.decay
        case "sustain": return params.sustain
        case "release": return params.release
        case "cutoffHz": return params.cutoffHz
        case "resonance": return params.resonance
        case "gain": return params.gain
        default: return nil
        }
    }

    /// The current value for one row (the spec default when unreadable).
    public func value(for spec: PolySynthParamSpec) -> Double {
        Self.paramValue(spec.name, in: params) ?? spec.defaultValue
    }

    /// Applies one knob edit: clamps to the spec range (the store re-clamps
    /// through `PolySynthParams.init` — belt and suspenders), then routes
    /// through the injected closure — `store.setInstrument` with exactly this
    /// field, the wire's `track.setInstrument` twin. The store coalesces
    /// per-track ("track.instrument:<id>"), so a whole drag is ONE undo step.
    public func set(name: String, value: Double) {
        guard let trackID else { return }
        guard let spec = Self.specs.first(where: { $0.name == name }) else { return }
        let clamped = value.clamped(to: spec.range)
        do {
            try applyParam(trackID, name, clamped)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Sets a row from a 0…1 knob travel fraction (through the row's scale).
    public func setFraction(_ fraction: Double, for spec: PolySynthParamSpec) {
        set(name: spec.name, value: Self.value(forFraction: fraction, spec: spec))
    }

    /// Double-click reset — back to the `PolySynthParams()` default (one
    /// coalesced edit through the same path).
    public func resetToDefault(_ spec: PolySynthParamSpec) {
        set(name: spec.name, value: spec.defaultValue)
    }

    // MARK: - Knob geometry (fraction ↔ value; the EffectEditorModel mapping)

    /// How a knob's travel maps onto its range: the cutoff frequency is
    /// LOGARITHMIC — musical octaves read evenly across the travel (a linear
    /// 40 Hz–18 kHz knob buries everything below 2 kHz in the first tenth);
    /// everything else — times and 0…1 levels — stays linear (the house rule:
    /// only Hz-unit params get the log taper).
    public enum Scale: Sendable, Equatable {
        case linear
        case logarithmic
    }

    public static func scale(for spec: PolySynthParamSpec) -> Scale {
        spec.unit == "Hz" && spec.range.lowerBound > 0 ? .logarithmic : .linear
    }

    /// The 0…1 knob fraction for a value (through the row's scale).
    public static func fraction(forValue value: Double, spec: PolySynthParamSpec) -> Double {
        let lo = spec.range.lowerBound, hi = spec.range.upperBound
        guard hi > lo else { return 0 }
        let v = value.clamped(to: spec.range)
        switch scale(for: spec) {
        case .linear:
            return (v - lo) / (hi - lo)
        case .logarithmic:
            return (log(v / lo) / log(hi / lo)).clamped(to: 0...1)
        }
    }

    /// The value at a 0…1 knob fraction (through the row's scale).
    public static func value(forFraction fraction: Double, spec: PolySynthParamSpec) -> Double {
        let lo = spec.range.lowerBound, hi = spec.range.upperBound
        let f = fraction.clamped(to: 0...1)
        switch scale(for: spec) {
        case .linear:
            return lo + f * (hi - lo)
        case .logarithmic:
            return lo * pow(hi / lo, f)
        }
    }

    /// The current row fraction (for the thin view's knob position). Every
    /// Poly Synth range starts at ≥ 0, so every knob is a unipolar min-start
    /// sweep — fill anchor 0, no bipolar case.
    public func fraction(for spec: PolySynthParamSpec) -> Double {
        Self.fraction(forValue: value(for: spec), spec: spec)
    }

    // MARK: - Presentation (readout / accent)

    /// The SF Mono readout for a value: `(text, unit)` — mirrors
    /// `EffectEditorModel.readout`'s crossovers on this card's storage units:
    /// envelope SECONDS read in ms below one second and cross to "s" at ≥ 1 s
    /// (the delay-card ms→s twin); the cutoff crosses Hz→kHz at 1 kHz; the
    /// 0…1 sustain/resonance amounts read as % (report Actionable-5); the
    /// linear gain reads as its dB equivalent (20·log10) so every gain knob in
    /// the app speaks one unit — the wire keeps the raw linear/seconds values.
    public static func readout(value: Double, spec: PolySynthParamSpec) -> (text: String, unit: String) {
        if spec.name == "gain" {
            guard value > 0 else { return ("-∞", "dB") }
            return (String(format: "%.1f", 20 * log10(value)), "dB")
        }
        switch spec.unit {
        case "s":
            let ms = value * 1_000
            if ms >= 1_000 {
                return (String(format: "%.2f", value), "s")
            }
            if ms < 10 {
                // Sub-10 ms attacks need the decimal — a 0.5 ms minimum must
                // never read as "1".
                return (String(format: "%.1f", ms), "ms")
            }
            return (String(format: "%.0f", ms), "ms")
        case "Hz":
            if value >= 1_000 {
                return (String(format: "%.2f", value / 1_000), "kHz")
            }
            return (String(format: "%.0f", value), "Hz")
        default:
            // The 0…1 amounts (sustain level, resonance) read in % — wire
            // stays the raw fraction.
            return (String(format: "%.0f", value * 100), "%")
        }
    }

    /// Whether a row earns the cyan accent: only the genuinely level-flavored
    /// gain — envelope/filter params stay neutral white (the `PanKnob`
    /// precedent, docs/DESIGN-LANGUAGE.md Rule 3).
    public static func isLevelParam(_ spec: PolySynthParamSpec) -> Bool {
        spec.name == "gain"
    }
}
