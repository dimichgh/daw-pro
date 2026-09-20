import DAWCore
import Foundation

/// Resolves one strip's modulation model into the render-thread POD
/// (m39-e §3.3, §3.4). MAIN ACTOR ONLY — every String, every UUID lookup,
/// every spec-table read and every tempo conversion happens here, so the
/// render thread receives nothing but numbers.
///
/// Pure and headless: it takes values, not a graph, so the resolution rules
/// are testable without an engine.
enum ModulationSnapshotBuilder {
    /// Everything one strip contributes. The master strip passes
    /// `trackKind: nil` and no instrument.
    struct Strip: Equatable {
        var sources: [ModulationSource]
        var routes: [ModulationRoute]
        var effects: [EffectDescriptor]
        var instrument: InstrumentDescriptor?
        var isInstrumentTrack: Bool
        /// The value the fader would carry if modulation were not taking it
        /// over — `track.volume`, or an active lane's stopped preview.
        var baseVolume: Double
        var basePan: Double

        init(sources: [ModulationSource] = [], routes: [ModulationRoute] = [],
             effects: [EffectDescriptor] = [], instrument: InstrumentDescriptor? = nil,
             isInstrumentTrack: Bool = false, baseVolume: Double = 1, basePan: Double = 0) {
            self.sources = sources
            self.routes = routes
            self.effects = effects
            self.instrument = instrument
            self.isInstrumentTrack = isInstrumentTrack
            self.baseVolume = baseVolume
            self.basePan = basePan
        }
    }

    /// Builds the publishable snapshot, or nil when the strip modulates
    /// nothing — and nil is the whole byte-identity story: no routes means no
    /// snapshot means the render path never reaches a modulation branch.
    ///
    /// UNRESOLVABLE routes are dropped here, exactly as
    /// `resolveEffectParamLanes` drops unresolvable automation lanes: a
    /// deleted effect, a hosted effect or instrument, an unknown param name, a
    /// `refused` verdict, a missing source, a disabled route. Dropping at
    /// publish is a GUARD RAIL, not the refusal surface — the store refuses
    /// these at the edit boundary with a named reason, so nothing an agent can
    /// create arrives here to be silently discarded.
    static func build(strip: Strip, generation: UInt64, timelineID: UInt64,
                      sampleRate: Double, originSample: Int64,
                      positionValid: Bool) -> ModulationSnapshot? {
        guard !strip.routes.isEmpty, !strip.sources.isEmpty, sampleRate > 0 else { return nil }

        // Sources, in model order. The index IS the render-side source id.
        var sources: [ModulationSnapshot.Source] = []
        var steps: [Float] = []
        var macros: [Float] = []
        var indexByID: [UUID: Int32] = [:]
        for source in strip.sources.prefix(ModulationLimits.maxSources) {
            indexByID[source.id] = Int32(sources.count)
            sources.append(resolve(source, sampleRate: sampleRate,
                                   steps: &steps, macros: &macros))
        }

        // Targets, created in first-route order; routes flattened per target
        // so a target's run is contiguous. SUMMATION ORDER IS THIS ORDER —
        // Float addition is not associative, so an unspecified order would
        // make a render non-reproducible (§7.3, pinned by test).
        var targets: [ModulationSnapshot.Target] = []
        var routesByTarget: [[ModulationSnapshot.Route]] = []
        var targetIndexByKey: [String: Int] = [:]
        for route in strip.routes {
            guard route.enabled, let sourceIndex = indexByID[route.sourceID],
                  let resolved = resolveTarget(route.target, strip: strip) else { continue }
            let key = targetKey(route.target)
            let index: Int
            if let existing = targetIndexByKey[key] {
                index = existing
            } else {
                index = targets.count
                targetIndexByKey[key] = index
                targets.append(resolved)
                routesByTarget.append([])
            }
            routesByTarget[index].append(
                ModulationSnapshot.Route(sourceIndex: sourceIndex, depth: route.depth))
        }
        guard !targets.isEmpty else { return nil }

        var routes: [ModulationSnapshot.Route] = []
        for index in targets.indices {
            targets[index].routeOffset = Int32(routes.count)
            targets[index].routeCount = Int32(routesByTarget[index].count)
            routes.append(contentsOf: routesByTarget[index])
        }

        return ModulationSnapshot(
            generation: generation, timelineID: timelineID, sampleRate: sampleRate,
            originSample: originSample, positionValid: positionValid,
            sources: sources, routes: routes, targets: targets, steps: steps,
            macroValues: macros)
    }

    /// The effect params a strip modulates but does NOT automate. Each needs a
    /// SYNTHETIC ONE-POINT HOLD track carrying the knob value, or
    /// `storeEffectParams` never visits it and the route is silently inert
    /// (§3.3).
    ///
    /// ⛔ ONE point, not zero. A zero-point track is skipped twice over —
    /// `storeEffectParams` guards `points.count > 0`, and `value(at:)`'s own
    /// doc says "`points` must be non-empty". A zero-point synthetic track
    /// would look exactly like a route that does nothing.
    ///
    /// ⚠️ The knob value is therefore BAKED INTO A PUBLISHED SNAPSHOT, so a
    /// knob edit on a modulated-but-unautomated param MUST republish. The
    /// republish seam is `PlaybackGraph.applyParameters`, which already runs
    /// on every pass — which is exactly why this resolution lives there.
    static func syntheticEffectParamLanes(
        routes: [ModulationRoute], effects: [EffectDescriptor],
        automation: [AutomationLane]
    ) -> [AutomationSchedule.EffectParamLaneSpec] {
        var result: [AutomationSchedule.EffectParamLaneSpec] = []
        var seen = Set<String>()
        for route in routes {
            guard route.enabled,
                  case .effectParam(let effectID, let paramName) = route.target,
                  let effect = effects.first(where: { $0.id == effectID }),
                  let slot = EffectParamSpec.specs(for: effect.kind)
                      .firstIndex(where: { $0.name == paramName })
            else { continue }
            let key = "\(effectID.uuidString):\(paramName)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            // An ACTIVE automation lane already produces a track; a second one
            // would be a duplicate store of the same slot with a different
            // value, and the last writer would win non-deterministically.
            let automated = automation.contains {
                $0.isEnabled && !$0.points.isEmpty && $0.target == route.target
            }
            guard !automated else { continue }
            let base = effect.paramValue(paramName)
                ?? EffectParamSpec.specs(for: effect.kind)[slot].defaultValue
            result.append(AutomationSchedule.EffectParamLaneSpec(
                effectID: effectID, paramSlot: slot,
                points: [AutomationPoint(beat: 0, value: base, curve: .hold)]))
        }
        return result
    }

    /// Whether any enabled route addresses `.volume` / `.pan` on this strip —
    /// the predicate `PlaybackGraph`'s `activeLane` neutralisation joins, so
    /// the mixer node hands the target to the stage instead of applying the
    /// knob a second time.
    static func modulates(_ target: AutomationTarget, routes: [ModulationRoute]) -> Bool {
        routes.contains { $0.enabled && $0.target == target }
    }

    // MARK: - Resolution

    /// ⭐ **THE m39-c SEAM (render side).** Free-running Hz becomes a per-sample
    /// rate in exactly two lines below — `cyclesPerSample` for the LFO and
    /// `samplesPerStep` for the step sequencer. When m39-c ships its tempo-sync
    /// resolver, a `syncDivision` resolves to a cycle length HERE and nothing
    /// downstream changes: the closed forms in `ModulationMath` already take a
    /// rate, not a tempo, and are position-absolute, so a synced LFO inherits
    /// seek-exactness and loop-exactness for free. The other half of the seam is
    /// `ModulationSourceParams.apply`'s `refuseSync`, which is what currently
    /// keeps a division from ever reaching this function.
    private static func resolve(_ source: ModulationSource, sampleRate: Double,
                                steps: inout [Float], macros: inout [Float])
        -> ModulationSnapshot.Source {
        var resolved = ModulationSnapshot.Source()
        switch source.params {
        case .lfo(let p):
            resolved.kindCode = ModulationSnapshot.SourceCode.lfo
            resolved.waveformCode = p.waveform.code
            resolved.cyclesPerSample = p.rateHz / sampleRate
            resolved.phaseOffset = (p.phaseDeg / 360).truncatingRemainder(dividingBy: 1)
            resolved.pulseWidth = p.pulseWidth
            resolved.bipolar = p.bipolar
            resolved.seed = UInt32(truncatingIfNeeded: p.seed)
            resolved.edgeFraction = p.waveform.hasEdges
                ? ModulationMath.edgeFractionOfCycle(
                    edgeMs: p.edgeMs, cyclesPerSample: resolved.cyclesPerSample,
                    sampleRate: sampleRate)
                : 0
        case .stepSequencer(let p):
            resolved.kindCode = ModulationSnapshot.SourceCode.stepSequencer
            resolved.stepOffset = Int32(steps.count)
            resolved.stepCount = Int32(p.steps.count)
            steps.append(contentsOf: p.steps.map { Float($0) })
            resolved.samplesPerStep = p.rateHz > 0 ? sampleRate / p.rateHz : 0
            resolved.edgeFraction = resolved.samplesPerStep > 0
                ? min(p.edgeMs * 0.001 * sampleRate / resolved.samplesPerStep, 0.98)
                : 0
        case .envelopeFollower(let p):
            resolved.kindCode = ModulationSnapshot.SourceCode.envelopeFollower
            resolved.detectorIsPeak = p.detector == .peak
            resolved.attackCoefficient = Float(
                ModulationMath.onePoleCoefficient(timeMs: p.attackMs, sampleRate: sampleRate))
            resolved.releaseCoefficient = Float(
                ModulationMath.onePoleCoefficient(timeMs: p.releaseMs, sampleRate: sampleRate))
            resolved.floorDb = p.floorDb
            resolved.detectorGainLinear = pow(10, p.gainDb / 20)
            resolved.bipolar = false
        case .macro(let p):
            resolved.kindCode = ModulationSnapshot.SourceCode.macro
            resolved.bipolar = false
            if macros.count < ModulationLimits.maxMacros {
                resolved.macroSlot = Int32(macros.count)
                macros.append(Float(p.value))
            }
        }
        return resolved
    }

    private static func resolveTarget(_ target: AutomationTarget,
                                      strip: Strip) -> ModulationSnapshot.Target? {
        var resolved = ModulationSnapshot.Target()
        switch target {
        case .volume:
            resolved.kindCode = ModulationSnapshot.TargetCode.volume
            resolved.rangeLo = Track.volumeRange.lowerBound
            resolved.rangeHi = Track.volumeRange.upperBound
            resolved.baseValue = strip.baseVolume
            return resolved
        case .pan:
            resolved.kindCode = ModulationSnapshot.TargetCode.pan
            resolved.rangeLo = Track.panRange.lowerBound
            resolved.rangeHi = Track.panRange.upperBound
            resolved.baseValue = strip.basePan
            return resolved
        case .sendLevel:
            // Refused in v1 — `ProjectStore` refuses the lane and there is no
            // render-side send stage to compose into (§3.3, §7.4).
            return nil
        case .effectParam(let effectID, let paramName):
            guard let effect = strip.effects.first(where: { $0.id == effectID }),
                  let slot = EffectParamSpec.specs(for: effect.kind)
                      .firstIndex(where: { $0.name == paramName })
            else { return nil }
            let spec = EffectParamSpec.specs(for: effect.kind)[slot]
            guard spec.modulatable != .refused else { return nil }
            resolved.kindCode = ModulationSnapshot.TargetCode.effectParam
            resolved.effectID = effectID
            resolved.paramSlot = Int32(slot)
            resolved.rangeLo = spec.range.lowerBound
            resolved.rangeHi = spec.range.upperBound
            resolved.curveCode = ModulationEvaluator.code(for: spec.curve)
            resolved.baseValue = effect.paramValue(paramName) ?? spec.defaultValue
            return resolved
        case .instrumentParam(let paramName):
            guard strip.isInstrumentTrack else { return nil }
            let descriptor = strip.instrument ?? .default
            guard let id = InstrumentParamID(rawValue: paramName),
                  let spec = InstrumentParamSpec.specs(for: descriptor.kind)
                      .first(where: { $0.name == paramName }),
                  spec.modulatable != .refused
            else { return nil }
            resolved.kindCode = ModulationSnapshot.TargetCode.instrumentParam
            resolved.paramSlot = id.code
            resolved.rangeLo = spec.range.lowerBound
            resolved.rangeHi = spec.range.upperBound
            resolved.curveCode = ModulationEvaluator.code(for: spec.curve)
            resolved.baseValue = InstrumentParamSpec.currentValue(of: paramName,
                                                                  in: descriptor)
                ?? spec.defaultValue
            return resolved
        }
    }

    /// Grouping key — the same vocabulary `AutomationTarget`'s Codable uses.
    private static func targetKey(_ target: AutomationTarget) -> String {
        switch target {
        case .volume: return "volume"
        case .pan: return "pan"
        case .sendLevel(let id): return "sendLevel:\(id.uuidString)"
        case .effectParam(let id, let name): return "effectParam:\(id.uuidString):\(name)"
        case .instrumentParam(let name): return "instrumentParam:\(name)"
        }
    }
}
