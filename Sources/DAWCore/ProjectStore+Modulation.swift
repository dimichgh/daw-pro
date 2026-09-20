import Foundation

// The nine `mod.*` mutations (m39-e §7.1), their validation, their
// clamp-and-warn surface and their refusal taxonomy — the store half of the
// modulation layer. Headless and engine-free: every rule here is testable
// without an audio graph.
//
// ⭐ THE REFUSAL DISCIPLINE, in one line: modulation refuses a SUPERSET of
// what automation refuses, and every refusal names both the reason (from a
// frozen set an agent can branch on) and the legal alternatives. A route that
// would be silently inert is the one thing this file must never create.

public extension ProjectStore {
    /// One strip's modulation model, for `mod.describe` and for tests.
    struct ModulationStripState: Equatable, Sendable {
        public var sources: [ModulationSource]
        public var routes: [ModulationRoute]
        public init(sources: [ModulationSource], routes: [ModulationRoute]) {
            self.sources = sources
            self.routes = routes
        }
    }

    // MARK: - Reads

    /// The strip's sources and routes. Unknown track → `trackNotFound`.
    func modulationState(of strip: ModulationStrip) throws -> ModulationStripState {
        switch strip {
        case .master:
            return ModulationStripState(sources: masterModulationSources,
                                        routes: masterModulationRoutes)
        case .track(let id):
            guard let track = tracks.first(where: { $0.id == id }) else {
                throw ProjectError.trackNotFound(id)
            }
            return ModulationStripState(sources: track.modulationSources,
                                        routes: track.modulationRoutes)
        }
    }

    /// Every strip that carries modulation — `mod.describe` with no `trackId`.
    var modulatedStrips: [ModulationStrip] {
        var result: [ModulationStrip] = []
        if !masterModulationSources.isEmpty || !masterModulationRoutes.isEmpty {
            result.append(.master)
        }
        for track in tracks where !track.modulationSources.isEmpty
            || !track.modulationRoutes.isEmpty {
            result.append(.track(track.id))
        }
        return result
    }

    // MARK: - mod.addSource

    @discardableResult
    func addModulationSource(on strip: ModulationStrip, kind: ModulationSourceKind,
                             params: [String: ModulationParamValue] = [:],
                             name: String? = nil)
        throws -> (source: ModulationSource, warnings: [String]) {
        let state = try modulationState(of: strip)
        guard state.sources.count < ModulationLimits.maxSources else {
            throw ModulationError.modulationLimitExceeded(
                cap: "sources per strip", limit: ModulationLimits.maxSources,
                current: state.sources.count,
                detail: "Remove a source with mod.removeSource, or reuse one — a single "
                    + "source can drive any number of routes, which is the idiom this "
                    + "surface is shaped for.")
        }
        let (resolved, paramWarnings) = try ModulationSourceParams.apply(
            params, to: .defaults(for: kind))
        var warnings = paramWarnings
        if kind == .envelopeFollower { warnings.append(Self.followerWarning) }
        let source = ModulationSource(kind: kind, name: name, params: resolved)
        try mutate(strip, label: "Add Modulation Source") { sources, _ in
            sources.append(source)
        }
        return (source, warnings)
    }

    // MARK: - mod.setSource

    /// ⭐ Why this verb exists at all (§7.1): without it, changing an LFO's rate
    /// means delete-and-recreate, which invalidates every route pointing at it.
    /// Asymmetric surfaces are how agents get stuck.
    @discardableResult
    func setModulationSource(on strip: ModulationStrip, sourceID: UUID,
                             params: [String: ModulationParamValue] = [:],
                             name: String? = nil)
        throws -> (source: ModulationSource, warnings: [String]) {
        let state = try modulationState(of: strip)
        guard let existing = state.sources.first(where: { $0.id == sourceID }) else {
            throw Self.sourceNotFound(sourceID, in: state)
        }
        let (resolved, warnings) = try ModulationSourceParams.apply(params, to: existing.params)
        var updated = existing
        updated.params = resolved
        if let name { updated.name = name }
        try mutate(strip, label: "Edit Modulation Source") { sources, _ in
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
            sources[index] = updated
        }
        return (updated, warnings)
    }

    // MARK: - mod.removeSource

    /// CASCADES rather than refusing, matching how deleting an effect cascades
    /// its automation lanes — and NAMES what it cascaded, because a silent
    /// cascade is how a caller ends up with a model it did not predict.
    @discardableResult
    func removeModulationSource(on strip: ModulationStrip, sourceID: UUID)
        throws -> (removedSourceID: UUID, removedRouteIDs: [UUID]) {
        let state = try modulationState(of: strip)
        guard state.sources.contains(where: { $0.id == sourceID }) else {
            throw Self.sourceNotFound(sourceID, in: state)
        }
        let cascaded = state.routes.filter { $0.sourceID == sourceID }.map(\.id)
        try mutate(strip, label: "Remove Modulation Source") { sources, routes in
            sources.removeAll { $0.id == sourceID }
            routes.removeAll { $0.sourceID == sourceID }
        }
        return (sourceID, cascaded)
    }

    // MARK: - mod.addRoute

    @discardableResult
    func addModulationRoute(on strip: ModulationStrip, sourceID: UUID,
                            target: AutomationTarget, depth: Double,
                            enabled: Bool = true)
        throws -> (route: ModulationRoute, warnings: [String]) {
        let state = try modulationState(of: strip)
        guard let source = state.sources.first(where: { $0.id == sourceID }) else {
            throw Self.sourceNotFound(sourceID, in: state)
        }
        guard state.routes.count < ModulationLimits.maxRoutes else {
            throw ModulationError.modulationLimitExceeded(
                cap: "routes per strip", limit: ModulationLimits.maxRoutes,
                current: state.routes.count,
                detail: "Remove a route with mod.removeRoute.")
        }
        var warnings = try validate(target: target, on: strip)

        // ⚠️ THE SHARED BUDGET (§7.4). Each modulated-but-unautomated effect
        // param costs ONE synthetic effect-param track, and those live in the
        // SAME 64-slot array automation lanes do. The existing build silently
        // drops the excess (`.prefix(64)`); a silent drop is not acceptable for
        // a route the agent just created, so this REFUSES and names both
        // contributors.
        if case .effectParam = target {
            try checkCombinedTrackBudget(on: strip, adding: target)
        }

        let stored = depth.clamped(to: ModulationRoute.depthRange)
        if stored != depth,
           let sentence = ClampNotice.sentence(control: "depth", requested: depth,
                                               stored: stored,
                                               range: ModulationRoute.depthRange) {
            warnings.append("\(ModulationWarning.depthClamped): \(sentence)")
        }
        warnings.append(contentsOf: rateAliasWarnings(source: source, target: target))
        warnings.append(contentsOf: try volumeCeilingWarnings(
            source: source, target: target, depth: stored, on: strip))
        if source.kind == .envelopeFollower { warnings.append(Self.followerWarning) }

        let route = ModulationRoute(sourceID: sourceID, target: target,
                                    depth: stored, enabled: enabled)
        try mutate(strip, label: "Add Modulation Route") { _, routes in
            routes.append(route)
        }
        return (route, warnings)
    }

    // MARK: - mod.setRouteDepth

    @discardableResult
    func setModulationRouteDepth(on strip: ModulationStrip, routeID: UUID,
                                 depth: Double? = nil, enabled: Bool? = nil)
        throws -> (route: ModulationRoute, warnings: [String]) {
        let state = try modulationState(of: strip)
        guard let existing = state.routes.first(where: { $0.id == routeID }) else {
            throw ModulationError.modulationRouteNotFound(
                id: routeID.uuidString, existing: state.routes.map(\.id.uuidString))
        }
        var warnings: [String] = []
        var updated = existing
        if let depth {
            let stored = depth.clamped(to: ModulationRoute.depthRange)
            if stored != depth,
               let sentence = ClampNotice.sentence(control: "depth", requested: depth,
                                                   stored: stored,
                                                   range: ModulationRoute.depthRange) {
                warnings.append("\(ModulationWarning.depthClamped): \(sentence)")
            }
            updated.depth = stored
        }
        if let enabled { updated.enabled = enabled }
        if let source = state.sources.first(where: { $0.id == existing.sourceID }) {
            warnings.append(contentsOf: try volumeCeilingWarnings(
                source: source, target: existing.target, depth: updated.depth, on: strip))
        }
        try mutate(strip, label: "Set Modulation Depth") { _, routes in
            guard let index = routes.firstIndex(where: { $0.id == routeID }) else { return }
            routes[index] = updated
        }
        return (updated, warnings)
    }

    // MARK: - mod.removeRoute

    @discardableResult
    func removeModulationRoute(on strip: ModulationStrip, routeID: UUID) throws -> UUID {
        let state = try modulationState(of: strip)
        guard state.routes.contains(where: { $0.id == routeID }) else {
            throw ModulationError.modulationRouteNotFound(
                id: routeID.uuidString, existing: state.routes.map(\.id.uuidString))
        }
        try mutate(strip, label: "Remove Modulation Route") { _, routes in
            routes.removeAll { $0.id == routeID }
        }
        return routeID
    }

    // MARK: - mod.setMacro

    @discardableResult
    func setModulationMacro(on strip: ModulationStrip, sourceID: UUID, value: Double)
        throws -> (source: ModulationSource, warnings: [String]) {
        let state = try modulationState(of: strip)
        guard let existing = state.sources.first(where: { $0.id == sourceID }) else {
            throw Self.sourceNotFound(sourceID, in: state)
        }
        guard case .macro = existing.params else {
            throw ModulationError.modulationSourceKindMismatch(
                verb: "mod.setMacro", actualKind: existing.kind.rawValue)
        }
        var warnings: [String] = []
        let stored = value.clamped(to: MacroSourceParams.valueRange)
        if stored != value,
           let sentence = ClampNotice.sentence(control: "value", requested: value,
                                               stored: stored,
                                               range: MacroSourceParams.valueRange) {
            warnings.append("\(ModulationWarning.paramClamped): \(sentence)")
        }
        var updated = existing
        updated.params = .macro(MacroSourceParams(value: stored))
        try mutate(strip, label: "Set Macro", key: "mod.macro:\(sourceID.uuidString)") {
            sources, _ in
            guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
            sources[index] = updated
        }
        return (updated, warnings)
    }

    // MARK: - Validation

    /// The refusal taxonomy (§7.4), in one place so every verb refuses the same
    /// way. Returns the WARNINGS a permitted-but-imperfect target earns.
    func validate(target: AutomationTarget, on strip: ModulationStrip) throws -> [String] {
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
            let effects = try self.effects(on: strip)
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
                // `delay.sync` / `delay.division` are refused for a DIFFERENT
                // reason than a boolean is, and an agent branches on the reason.
                let reason: ModulationTargetUnsupportedReason =
                    (effect.kind == .delay && (paramName == "sync" || paramName == "division"))
                        ? .controlPlaneOnly : .discrete
                throw ModulationError.modulationTargetUnsupported(
                    target: "\(effect.kind.rawValue).\(paramName)", reason: reason,
                    detail: reason == .controlPlaneOnly
                        ? "this parameter is resolved off the render thread (the effective "
                            + "delay time derives from the tempo on the main actor), so a "
                            + "modulator could not reach it. Automation refuses it too."
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
            guard case .track(let trackID) = strip,
                  let track = tracks.first(where: { $0.id == trackID }),
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

    // MARK: - Internals

    /// The effect chain a strip carries.
    private func effects(on strip: ModulationStrip) throws -> [EffectDescriptor] {
        switch strip {
        case .master: return masterEffects
        case .track(let id):
            guard let track = tracks.first(where: { $0.id == id }) else {
                throw ProjectError.trackNotFound(id)
            }
            return track.effects
        }
    }

    /// `lanes + modulatedEffectParams <= 64` on a strip (§7.4). Checked TOGETHER
    /// because the two caps share one preallocated array.
    private func checkCombinedTrackBudget(on strip: ModulationStrip,
                                          adding target: AutomationTarget) throws {
        guard case .track(let trackID) = strip,
              let track = tracks.first(where: { $0.id == trackID }) else { return }
        let lanes = AutomationSchedule_effectParamLaneCount(track)
        let modulated = ModulationEffectParamKeys(
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

    /// The alias warning (§7.5, §8.1). Reuses `EffortField`'s measured
    /// closed-form ratio — nothing here invents a second threshold.
    private func rateAliasWarnings(source: ModulationSource,
                                   target: AutomationTarget) -> [String] {
        guard case .effectParam = target else { return [] }
        let rate: Double
        switch source.params {
        case .lfo(let p): rate = p.rateHz
        case .stepSequencer(let p): rate = p.rateHz
        case .envelopeFollower, .macro: return []
        }
        let samplingHz = ModulationPath.perQuantum.samplingHz(
            sampleRate: 48_000, blockFrames: RenderBlockSize.offlineFrames)
        let ceiling = EffortField.modulationRateCeilingHz(
            samplingHz: samplingHz, maxImageRatio: EffortField.maxAcceptableImageRatio)
        guard rate > ceiling else { return [] }
        let ratio = EffortField.modulationImageRatio(rateHz: rate, samplingHz: samplingHz)
        return ["\(ModulationWarning.rateAlias): this source runs at "
            + String(format: "%.2f", rate) + " Hz, and an effect parameter is only "
            + "re-derived once per render block — "
            + String(format: "%.2f", samplingHz) + " Hz. The alias image is "
            + String(format: "%.2f", ratio) + " of the wanted signal (the honest ceiling "
            + "is " + String(format: "%.2f", ceiling) + " Hz at an image ratio of "
            + String(format: "%.2f", EffortField.maxAcceptableImageRatio) + "). Volume, pan "
            + "and instrument parameters are sampled per sample and do not have this limit."]
    }

    /// `modulationVolumeCeiling` (§7.3, §7.5).
    private func volumeCeilingWarnings(source: ModulationSource, target: AutomationTarget,
                                       depth: Double,
                                       on strip: ModulationStrip) throws -> [String] {
        guard case .volume = target, !source.params.isUnipolar else { return [] }
        let base: Double
        switch strip {
        case .master: base = masterVolume
        case .track(let id): base = tracks.first(where: { $0.id == id })?.volume ?? 1
        }
        guard ModulationDepthLaw.volumeWouldExceedCeiling(base: base, depth: depth) else {
            return []
        }
        return ["\(ModulationWarning.volumeCeiling): this strip's fader sits at "
            + String(format: "%.2f", base) + " and the fader's own ceiling is "
            + "+6.02 dB, so a BIPOLAR source at depth "
            + String(format: "%.2f", depth) + " clips its upper half while its lower half "
            + "keeps going — a tremolo that is not a tremolo. The studio idiom is "
            + "attenuation-only: set the source's 'bipolar' to false and use a NEGATIVE "
            + "depth."]
    }

    private static func sourceNotFound(_ id: UUID,
                                       in state: ModulationStripState) -> ModulationError {
        .modulationSourceNotFound(id: id.uuidString,
                                  existing: state.sources.map(\.id.uuidString))
    }

    private static let followerWarning =
        "\(ModulationWarning.followerNonDeterministic): an envelope follower derives from "
        + "rendered audio, so it is the one source that depends on render history. Two "
        + "renders that START AT THE SAME transport position are bit-identical; a render "
        + "that starts part-way through differs from a full playthrough for roughly "
        + "attackMs + releaseMs while the detector catches up. It also follows this strip's "
        + "POST-INSERT audio, at the fader."

    private static func hostedDetail(what: String) -> String {
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

    private static func stepsWarning(kind: EffectDescriptor.Kind, paramName: String) -> String {
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

    /// One edit, one undo step, on either strip. The `engine?` notification is
    /// the republish seam — `tracksDidChange` runs `applyParameters`, which is
    /// where the modulation snapshot is rebuilt and published.
    private func mutate(_ strip: ModulationStrip, label: String, key: String? = nil,
                        _ body: (inout [ModulationSource], inout [ModulationRoute]) -> Void)
        throws {
        switch strip {
        case .master:
            performEdit(label, key: key) {
                body(&masterModulationSources, &masterModulationRoutes)
                engine?.masterModulationChanged(sources: masterModulationSources,
                                                routes: masterModulationRoutes)
            }
        case .track(let id):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else {
                throw ProjectError.trackNotFound(id)
            }
            performEdit(label, key: key) {
                // Copied out and written back: `tracks` is a computed property,
                // and two simultaneous inout projections into it would alias.
                var sources = tracks[index].modulationSources
                var routes = tracks[index].modulationRoutes
                body(&sources, &routes)
                tracks[index].modulationSources = sources
                tracks[index].modulationRoutes = routes
                engine?.tracksDidChange(tracks)
            }
        }
    }
}

/// How many effect-param automation lanes a track contributes to the shared
/// 64-slot budget — the same predicate `AutomationSchedule.resolveEffectParamLanes`
/// applies, expressed as a count so the store can check the budget without
/// importing DAWEngine.
private func AutomationSchedule_effectParamLaneCount(_ track: Track) -> Int {
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
private func ModulationEffectParamKeys(routes: [ModulationRoute],
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
