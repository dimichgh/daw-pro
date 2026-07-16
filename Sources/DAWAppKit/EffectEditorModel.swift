import Foundation
import Observation
import DAWCore

/// The open effect editor's address: which insert chain hosts the effect —
/// `trackID` nil = the MASTER chain (the `MixerInsertsSection` convention) —
/// plus the effect id. Equatable so "click the open row again" reads as a
/// toggle-close in one comparison.
public struct EffectEditorTarget: Equatable, Sendable {
    public var trackID: UUID?
    public var effectID: UUID

    public init(trackID: UUID?, effectID: UUID) {
        self.trackID = trackID
        self.effectID = effectID
    }
}

/// Headless state machine for the built-in insert EFFECT EDITOR card (m17-a):
/// the spec-driven parameter rows a generic editor renders for every built-in
/// kind, the current values read from the live `EffectDescriptor`, and the
/// apply path — each edit goes through an injected closure wired to the SAME
/// `ProjectStore.setEffectParam` / `setMasterEffectParam` the wire's
/// `fx.setParam` calls (UI == wire, ZERO new wire surface). No SwiftUI/AppKit:
/// the modal card is thin over this and the tests drive it against fakes or a
/// real store (the `EffectPickerModel` / `QuantizeModel` precedent).
///
/// The editor is Pro-only by construction (it is reached only from the Pro
/// inserts section) and NEVER shows for a hosted AU (those open a plugin
/// window, M3 vi-b — `EffectParamSpec.specs(for: .audioUnit)` is empty and the
/// row never offers the editor). NO VIOLET — standard mixing chrome, not AI
/// content (docs/DESIGN-LANGUAGE.md Rule 3); cyan marks only the genuinely
/// level/gain-flavored readouts.
@MainActor
@Observable
public final class EffectEditorModel {
    /// Reads the LIVE descriptor for (trackID nil = master, effectID) — so a
    /// wire edit (`fx.setParam`) moves the open card's sliders, and a removed
    /// effect reads nil (the card renders nothing rather than a stale ghost).
    private let descriptorProvider: (UUID?, UUID) -> EffectDescriptor?
    /// Applies one validated param — wired to `store.setEffectParam` (track/bus)
    /// or `store.setMasterEffectParam` (master), the fx.setParam twins.
    private let applyParam: (UUID?, UUID, String, Double) throws -> Void
    /// Toggles bypass — wired to `store.setEffectBypassed` / the master twin.
    private let applyBypass: (UUID?, UUID, Bool) throws -> Void

    /// The open insert (nil = the model is idle). The card's visibility is the
    /// app model's `effectEditorTarget`; this mirrors it for value reads.
    public private(set) var target: EffectEditorTarget?
    /// The header's context tag ("on Drums" / "on Master") — computed by the
    /// caller at open time (the store owns names, the model just displays).
    public private(set) var targetLabel: String = ""
    /// A store refusal surfaced inline (the SidechainKeyModel idiom). Rare —
    /// the model clamps before applying, so only a vanished target throws.
    public private(set) var lastErrorMessage: String?

    public init(
        descriptor: @escaping (UUID?, UUID) -> EffectDescriptor?,
        apply: @escaping (UUID?, UUID, String, Double) throws -> Void,
        setBypassed: @escaping (UUID?, UUID, Bool) throws -> Void
    ) {
        self.descriptorProvider = descriptor
        self.applyParam = apply
        self.applyBypass = setBypassed
    }

    /// Points the editor at one insert and resets transient state.
    public func prepare(trackID: UUID?, effectID: UUID, targetLabel: String) {
        target = EffectEditorTarget(trackID: trackID, effectID: effectID)
        self.targetLabel = targetLabel
        lastErrorMessage = nil
    }

    /// Clears the target on close, so a stale card can never re-render.
    public func clear() {
        target = nil
        targetLabel = ""
        lastErrorMessage = nil
    }

    // MARK: - Live reads

    /// The open insert's live descriptor (nil = closed or removed).
    public var descriptor: EffectDescriptor? {
        guard let target else { return nil }
        return descriptorProvider(target.trackID, target.effectID)
    }

    public var kind: EffectDescriptor.Kind? { descriptor?.kind }
    public var displayName: String { descriptor.map(MixerFormat.effectDisplayName) ?? "" }
    public var isBypassed: Bool { descriptor?.isBypassed ?? false }

    /// The parameter rows, in schema-declaration order — the SAME
    /// `EffectParamSpec` table `fx.describe` serves (name/min/max/default/unit).
    public var specs: [EffectParamSpec] {
        kind.map { EffectParamSpec.specs(for: $0) } ?? []
    }

    /// The current value for one row — read from the live descriptor via the
    /// kind-keyed reader; the spec default when unreadable (a fresh insert
    /// carries nil params, which resolve to defaults model-side too).
    public func value(for spec: EffectParamSpec) -> Double {
        guard let descriptor else { return spec.defaultValue }
        return Self.paramValue(spec.name, in: descriptor) ?? spec.defaultValue
    }

    // MARK: - Edits (the wire-identical apply path)

    /// Applies one parameter edit: clamps to the spec range (the store clamps
    /// again — belt and suspenders), then routes through the injected closure —
    /// `setEffectParam`/`setMasterEffectParam`, the exact methods `fx.setParam`
    /// calls. The store coalesces per (chain, effect, name), so a slider drag
    /// that applies every tick still lands as ONE undo step.
    public func set(name: String, value: Double) {
        guard let target, let kind else { return }
        guard let spec = EffectParamSpec.specs(for: kind).first(where: { $0.name == name }) else {
            return
        }
        let clamped = value.clamped(to: spec.range)
        do {
            try applyParam(target.trackID, target.effectID, name, clamped)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Sets a row from a 0…1 slider fraction (through the row's scale).
    public func setFraction(_ fraction: Double, for spec: EffectParamSpec) {
        set(name: spec.name, value: Self.value(forFraction: fraction, spec: spec))
    }

    /// Double-click reset — back to the spec default (one coalesced edit).
    public func resetToDefault(_ spec: EffectParamSpec) {
        set(name: spec.name, value: spec.defaultValue)
    }

    /// Toggles bypass through the SAME store method the row's dot and the
    /// wire's `fx.setBypass` use.
    public func toggleBypass() {
        guard let target, let descriptor else { return }
        do {
            try applyBypass(target.trackID, target.effectID, !descriptor.isBypassed)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Slider geometry (fraction ↔ value)

    /// How a row's slider travel maps onto its range. Frequencies are
    /// LOGARITHMIC — musical octaves read evenly across the travel (a linear
    /// 20 Hz–20 kHz slider buries everything below 2 kHz in the first tenth);
    /// everything else is linear.
    public enum Scale: Sendable, Equatable {
        case linear
        case logarithmic
    }

    /// Hz-unit params get the log mapping (their bounds are always > 0);
    /// everything else — including negative-spanning dB ranges — stays linear.
    public static func scale(for spec: EffectParamSpec) -> Scale {
        spec.unit == "Hz" && spec.range.lowerBound > 0 ? .logarithmic : .linear
    }

    /// The 0…1 slider fraction for a value (through the row's scale).
    public static func fraction(forValue value: Double, spec: EffectParamSpec) -> Double {
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

    /// The value at a 0…1 slider fraction (through the row's scale).
    public static func value(forFraction fraction: Double, spec: EffectParamSpec) -> Double {
        let lo = spec.range.lowerBound, hi = spec.range.upperBound
        let f = fraction.clamped(to: 0...1)
        switch scale(for: spec) {
        case .linear:
            return lo + f * (hi - lo)
        case .logarithmic:
            return lo * pow(hi / lo, f)
        }
    }

    /// The current row fraction (for the thin view's slider position).
    public func fraction(for spec: EffectParamSpec) -> Double {
        Self.fraction(forValue: value(for: spec), spec: spec)
    }

    // MARK: - Presentation (label / readout / accent)

    /// A row's human label from its wire name: camelCase split ("lowShelfFreq"
    /// → "Low Shelf Freq", "peak1GainDb" → "Peak 1 Gain Db"), then a trailing
    /// unit token that just repeats `spec.unit` is dropped ("… Gain Db" →
    /// "… Gain" — the readout already shows the unit).
    public static func label(for spec: EffectParamSpec) -> String {
        var words: [String] = []
        var current = ""
        for ch in spec.name {
            if ch.isUppercase || ch.isNumber, !current.isEmpty,
               !(ch.isNumber && current.last?.isNumber == true) {
                words.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        let redundant: [String: String] = [
            "dB": "db", "Hz": "hz", "ms": "ms", "s": "s", "linear": "linear",
        ]
        if let unitToken = redundant[spec.unit], words.count > 1,
           words.last?.lowercased() == unitToken {
            words.removeLast()
        }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The SF Mono readout for a value: `(text, unit)` — "3.0" + "kHz",
    /// "-18.0" + "dB", "4.0:1" + "", "0.35" + "". Deterministic formats so
    /// captures and tests pin exact strings.
    public static func readout(value: Double, spec: EffectParamSpec) -> (text: String, unit: String) {
        switch spec.unit {
        case "dB":
            return (String(format: "%.1f", value), "dB")
        case "Hz":
            if value >= 1_000 {
                return (String(format: "%.2f", value / 1_000), "kHz")
            }
            if value < 10 {
                // Sub-10 Hz rates (chorus/LFO territory) need decimals — a
                // 0.8 Hz default must never read as "1".
                return (String(format: "%.2f", value), "Hz")
            }
            return (String(format: "%.0f", value), "Hz")
        case "ms":
            if value < 10 {
                return (String(format: "%.1f", value), "ms")
            }
            return (String(format: "%.0f", value), "ms")
        case "s":
            return (String(format: "%.2f", value), "s")
        case "ratio":
            return (String(format: "%.1f:1", value), "")
        default:
            // "linear" and anything future: two decimals, no unit tag (the
            // raw word "linear" reads as jargon, not information).
            return (String(format: "%.2f", value), "")
        }
    }

    /// Whether a row earns the cyan accent: only genuinely level/gain-flavored
    /// params (dB values, linear gain) — pan-type/tone params stay neutral
    /// white, the `PanKnob` precedent (docs/DESIGN-LANGUAGE.md Rule 3).
    public static func isLevelParam(_ spec: EffectParamSpec) -> Bool {
        spec.unit == "dB" || spec.name == "gainLinear"
    }

    // MARK: - The kind-keyed value reader

    /// Reads one named param out of a descriptor — the exact inverse of
    /// `ProjectStore.applyEffectParam`'s name→field mapping, over the SAME
    /// wire names `fx.setParam`/`fx.describe` use. nil for an unknown name or
    /// an AU descriptor (AU params are not on this surface in v1).
    public static func paramValue(_ name: String, in effect: EffectDescriptor) -> Double? {
        switch effect.kind {
        case .gain:
            return name == "gainLinear" ? effect.resolvedGain.gainLinear : nil
        case .eq:
            let p = effect.resolvedEQ
            switch name {
            case "lowShelfFreq": return p.lowShelfFreq
            case "lowShelfGainDb": return p.lowShelfGainDb
            case "peak1Freq": return p.peak1Freq
            case "peak1GainDb": return p.peak1GainDb
            case "peak1Q": return p.peak1Q
            case "peak2Freq": return p.peak2Freq
            case "peak2GainDb": return p.peak2GainDb
            case "peak2Q": return p.peak2Q
            case "highShelfFreq": return p.highShelfFreq
            case "highShelfGainDb": return p.highShelfGainDb
            default: return nil
            }
        case .compressor:
            let p = effect.resolvedCompressor
            switch name {
            case "thresholdDb": return p.thresholdDb
            case "ratio": return p.ratio
            case "attackMs": return p.attackMs
            case "releaseMs": return p.releaseMs
            case "kneeDb": return p.kneeDb
            case "makeupDb": return p.makeupDb
            default: return nil
            }
        case .limiter:
            let p = effect.resolvedLimiter
            switch name {
            case "ceilingDb": return p.ceilingDb
            case "releaseMs": return p.releaseMs
            default: return nil
            }
        case .reverb:
            let p = effect.resolvedReverb
            switch name {
            case "roomSize": return p.roomSize
            case "damping": return p.damping
            case "mix": return p.mix
            case "preDelayMs": return p.preDelayMs
            case "width": return p.width
            default: return nil
            }
        case .delay:
            let p = effect.resolvedDelay
            switch name {
            case "timeMs": return p.timeMs
            case "feedback": return p.feedback
            case "mix": return p.mix
            case "pingPong": return p.pingPong
            case "highCutHz": return p.highCutHz
            default: return nil
            }
        case .saturator:
            let p = effect.resolvedSaturator
            switch name {
            case "driveDb": return p.driveDb
            case "mix": return p.mix
            case "outputDb": return p.outputDb
            default: return nil
            }
        case .gate:
            let p = effect.resolvedGate
            switch name {
            case "thresholdDb": return p.thresholdDb
            case "attackMs": return p.attackMs
            case "holdMs": return p.holdMs
            case "releaseMs": return p.releaseMs
            default: return nil
            }
        case .chorus:
            let p = effect.resolvedChorus
            switch name {
            case "rateHz": return p.rateHz
            case "depthMs": return p.depthMs
            case "mix": return p.mix
            default: return nil
            }
        case .audioUnit:
            return nil
        }
    }
}
