import Foundation

// m39-tpl-1 (docs/design/2026-09-27-multi-instrument-templates.md §5.2): which
// modulation targets a strip may carry, and the 64-slot budget lanes and
// modulated effect settings share — as PURE functions over `Track` values.
//
// ⭐ MOVED HERE VERBATIM from `ProjectStore+Modulation.swift`, where
// `validate(target:on:)` and `checkCombinedTrackBudget(on:adding:)` looked the
// strip up in the live store. A template's tracks do not exist yet when the
// template builder has to judge them, so the rules had to stop reading the
// store; the store's two methods are now thin wrappers that look the strip up
// and call these. The refusal texts, reasons and warning order are unchanged —
// a golden table captured from the pre-move code proves it
// (`ModulationRulesTests`).
//
// ⭐ THE REFUSAL DISCIPLINE is the store file's, unchanged: modulation refuses a
// SUPERSET of what automation refuses, and every refusal names both the reason
// (from a frozen set an agent can branch on) and the legal alternatives.

public enum ModulationRules {
    /// The strip a target is judged against, as a value.
    public enum Strip: Sendable, Equatable {
        /// An insert chain with no instrument — the master strip. Instrument
        /// parameters are refused on it (`noInstrument`).
        case master(effects: [EffectDescriptor])
        /// A track: a live one, or a template's track that does not exist yet.
        case track(Track)

        /// The effect chain the strip carries.
        var effects: [EffectDescriptor] {
            switch self {
            case .master(let effects): return effects
            case .track(let track): return track.effects
            }
        }
    }

    // MARK: - Which targets are allowed (formerly `ProjectStore.validate(target:on:)`)

    /// The refusal taxonomy (§7.4), in one place so every verb refuses the same
    /// way. Returns the WARNINGS a permitted-but-imperfect target earns.
    public static func validate(target: AutomationTarget, on strip: Strip) throws -> [String] {
        var warnings: [String] = []
        switch target {
        case .volume, .pan:
            return warnings

        case .sendLevel:
            throw ModulationError.modulationTargetUnsupported(
                target: "sendLevel", reason: .sendLevelUnsupported,
                detail: "send levels have no render-side delivery stage to compose into "
                    + "in v1 — automation refuses them for the same reason, and "
                    + "modulation never permits what automation forbids. Modulate the "
                    + "source strip's volume instead.")

        case .effectParam(let effectID, let paramName):
            let effects = strip.effects
            guard let effect = effects.first(where: { $0.id == effectID }) else {
                throw ProjectError.effectNotFound(effectID)
            }
            guard effect.kind != .audioUnit else {
                throw ModulationError.modulationTargetUnsupported(
                    target: "\(effect.kind.rawValue).\(paramName)", reason: .hostedAudioUnit,
                    detail: Self.hostedDetail(what: "A hosted Audio Unit effect"))
            }
            let specs = EffectParamSpec.specs(for: effect.kind)
            guard let spec = specs.first(where: { $0.name == paramName }) else {
                throw ModulationError.modulationTargetUnsupported(
                    target: "\(effect.kind.rawValue).\(paramName)", reason: .unknownParam,
                    detail: "valid parameters for \(effect.kind.rawValue): "
                        + specs.map(\.name).joined(separator: ", "))
            }
            switch spec.modulatable {
            case .refused:
                // Tempo-sync params (`delay.sync` / `delay.division` today) are
                // refused for a DIFFERENT reason than a boolean is, and an agent
                // branches on the reason. WHICH params those are lives in ONE
                // home, `TempoSync.effectRegistrations` (m39-c).
                let reason: ModulationTargetUnsupportedReason =
                    TempoSync.isControlPlaneOnly(kind: effect.kind, paramName: paramName)
                        ? .controlPlaneOnly : .discrete
                throw ModulationError.modulationTargetUnsupported(
                    target: "\(effect.kind.rawValue).\(paramName)", reason: reason,
                    detail: reason == .controlPlaneOnly
                        ? TempoSync.controlPlaneOnlyDetail(kind: effect.kind)
                        : "this parameter is discrete — a boolean, an enum or a rounded "
                            + "step — and a modulator cannot drive it meaningfully. "
                            + "Continuously modulatable parameters on "
                            + "\(effect.kind.rawValue): "
                            + specs.filter { $0.modulatable != .refused }
                                .map(\.name).joined(separator: ", "))
            case .warned:
                warnings.append("\(ModulationWarning.targetSteps): "
                    + Self.stepsWarning(kind: effect.kind, paramName: paramName))
            case .yes:
                break
            }
            return warnings

        case .instrumentParam(let paramName):
            guard case .track(let track) = strip,
                  track.kind == .instrument else {
                throw ModulationError.modulationTargetUnsupported(
                    target: "instrumentParam.\(paramName)", reason: .noInstrument,
                    detail: "this strip carries no instrument. Instrument parameters exist "
                        + "on instrument tracks only — the master strip and audio/bus "
                        + "tracks have none.")
            }
            let descriptor = track.instrument ?? .default
            guard !InstrumentParamSpec.isHosted(descriptor.kind) else {
                throw ModulationError.modulationTargetUnsupported(
                    target: "instrumentParam.\(paramName)", reason: .hostedInstrument,
                    detail: Self.hostedDetail(
                        what: "A \(descriptor.kind.rawValue) instrument"))
            }
            let specs = InstrumentParamSpec.specs(for: descriptor.kind)
            guard let spec = specs.first(where: { $0.name == paramName }) else {
                let discrete = InstrumentParamSpec.discreteParamNames(for: descriptor.kind)
                let reason: ModulationTargetUnsupportedReason =
                    discrete.contains(paramName) ? .discrete : .unknownParam
                throw ModulationError.modulationTargetUnsupported(
                    target: "instrumentParam.\(paramName)", reason: reason,
                    detail: reason == .discrete
                        ? "'\(paramName)' is discrete — an enum or a count — and a "
                            + "modulator cannot drive it meaningfully."
                        : (specs.isEmpty
                            ? "the \(descriptor.kind.rawValue) instrument exposes no "
                                + "modulatable parameters in v1."
                            : "valid parameters: "
                                + specs.map(\.name).joined(separator: ", ")))
            }
            if spec.modulatable == .warned, let note = spec.note {
                warnings.append("\(ModulationWarning.targetSteps): \(note)")
            }
            return warnings
        }
    }

    // MARK: - The shared 64-slot budget (formerly `checkCombinedTrackBudget`)

    /// `lanes + modulatedEffectParams <= 64` on a strip (§7.4). Checked TOGETHER
    /// because the two caps share one preallocated array. `target` is the route
    /// about to be added; an effect-param target that is already modulated or
    /// automated costs no extra slot.
    public static func checkCombinedBudget(on track: Track,
                                           adding target: AutomationTarget) throws {
        let lanes = effectParamLaneCount(track)
        let modulated = modulatedEffectParamKeys(
            routes: track.modulationRoutes, automation: track.automation)
        var keys = modulated
        if case .effectParam(let effectID, let paramName) = target {
            keys.insert("\(effectID.uuidString):\(paramName)")
        }
        let total = lanes + keys.count
        guard total <= ModulationLimits.maxRoutes else {
            throw ModulationError.modulationLimitExceeded(
                cap: "effect-param tracks per strip", limit: ModulationLimits.maxRoutes,
                current: total,
                detail: "Automation lanes and modulated effect parameters SHARE one "
                    + "\(ModulationLimits.maxRoutes)-slot budget on a strip: this one has "
                    + "\(lanes) automation lane(s) and \(keys.count) modulated effect "
                    + "parameter(s). Remove a lane or a route, or modulate a parameter "
                    + "that is already automated — an automated parameter costs no extra "
                    + "slot.")
        }
    }

    /// How many of the strip's 64 effect-param slots `track` already uses:
    /// its effect-param automation lanes plus the distinct effect settings it
    /// modulates but does not automate. The template builder checks this is
    /// at most `ModulationLimits.maxRoutes` for every track it builds.
    public static func slotsUsed(by track: Track) -> Int {
        effectParamLaneCount(track)
            + modulatedEffectParamKeys(routes: track.modulationRoutes,
                                       automation: track.automation).count
    }

    /// How many effect-param automation lanes a track contributes to the shared
    /// 64-slot budget — the same predicate `AutomationSchedule.resolveEffectParamLanes`
    /// applies, expressed as a count so the store can check the budget without
    /// importing DAWEngine.
    static func effectParamLaneCount(_ track: Track) -> Int {
        track.automation.filter { lane in
            guard lane.isEnabled, !lane.points.isEmpty,
                  case .effectParam(let effectID, let paramName) = lane.target,
                  let effect = track.effects.first(where: { $0.id == effectID }),
                  EffectParamSpec.specs(for: effect.kind).contains(where: { $0.name == paramName })
            else { return false }
            return true
        }.count
    }

    /// The distinct effect params a strip MODULATES but does not AUTOMATE — each
    /// costs one synthetic track. An already-automated param costs nothing extra,
    /// which is why this subtracts them rather than counting every route.
    static func modulatedEffectParamKeys(routes: [ModulationRoute],
                                         automation: [AutomationLane]) -> Set<String> {
        var keys = Set<String>()
        for route in routes where route.enabled {
            guard case .effectParam(let effectID, let paramName) = route.target else { continue }
            let automated = automation.contains {
                $0.isEnabled && !$0.points.isEmpty && $0.target == route.target
            }
            guard !automated else { continue }
            keys.insert("\(effectID.uuidString):\(paramName)")
        }
        return keys
    }

    // MARK: - Message builders the refusals share

    static func hostedDetail(what: String) -> String {
        let samplingHz = ModulationPath.hostedRenderCall.samplingHz(
            sampleRate: 48_000, blockFrames: RenderBlockSize.offlineFrames)
        let ceiling = EffortField.modulationRateCeilingHz(
            samplingHz: samplingHz, maxImageRatio: EffortField.maxAcceptableImageRatio)
        return "\(what) samples its parameters once per render call — "
            + String(format: "%.2f", samplingHz) + " Hz, an honest modulation ceiling of "
            + String(format: "%.2f", ceiling) + " Hz — and there is no parameter-lane "
            + "delivery path to it at all today. Refused with the number rather than "
            + "aliased silently. Use a built-in effect or the built-in synth."
    }

    static func stepsWarning(kind: EffectDescriptor.Kind, paramName: String) -> String {
        switch (kind, paramName) {
        case (.delay, "timeMs"):
            return "delay.timeMs reads its line at an INTEGER sample offset, so every change "
                + "jumps whole samples and clicks. Smooth delay-time modulation is "
                + "structurally impossible in this effect; it is permitted because stepped "
                + "changes are still musically useful."
        case (.reverb, "preDelayMs"):
            return "reverb.preDelayMs is a read offset into the pre-delay line, so every "
                + "change jumps whole samples rather than gliding."
        case (.reverb, "roomSize"):
            return "reverb.roomSize scales comb FEEDBACK (decay time), not a room dimension, "
                + "and it is unsmoothed — changes step at the block boundary."
        case (.bitCrusher, "bits"):
            return "bitCrusher.bits rounds to whole bits (1…16), so modulation moves it in "
                + "audible steps. That IS the musical intent here, and you are told so."
        case (.eq, _):
            return "EQ coefficients are recomputed at the block boundary with no smoothing, "
                + "so modulating an EQ parameter zippers at any rate. This is the one "
                + "built-in family where it genuinely bites; volume, pan and instrument "
                + "parameters are sampled per sample instead."
        default:
            return "this parameter is re-derived once per render block with no smoothing, "
                + "so modulation steps rather than glides."
        }
    }
}
