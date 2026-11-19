import DAWCore
import Foundation

/// Render-side evaluation of a published `ModulationSnapshot` (m39-e §3.2).
///
/// **RENDER-THREAD CONTRACT.** No allocation, no locks, no ObjC, no actor
/// hops, no retain/release: the snapshot is borrowed, every source but the
/// envelope follower is a pure function of the transport position (a
/// tempo-synced step source of the MUSICAL position, read off the snapshot's
/// precomputed clock, m39-w4-4), and the arithmetic is libm plus integer ops. The closed forms themselves live in `DAWCore.ModulationMath`
/// so the control plane's `mod.describe` and this render path CANNOT disagree
/// about what a source is doing — one home, two callers.
///
/// ⚠️ **Every loop here is a `while`, never `for i in 0..<n`, and that is not
/// style.** `EffectChainProcessor.swift:402-412` records the measurement: at
/// `-Onone` a `Range` iteration raises ~2 malloc/free events PER ITERATION
/// inside the render path, and the allocation gates assert an ABSOLUTE ZERO.
/// Any new render-path loop inherits that law.
enum ModulationEvaluator {
    /// The neutral output of a source — what a position-dependent source
    /// returns while the transport is stopped (§7.8). Bipolar sources rest at
    /// 0; unipolar sources also rest at 0, so a stopped strip sounds like its
    /// knobs in both cases.
    static let neutral: Double = 0

    /// One source's output at project-absolute sample `p`.
    ///
    /// `followerEnvelope` is the detector level held by the render-side stage
    /// (the one piece of state this design permits, declared in §3.2); it is
    /// ignored by every other kind.
    @inline(__always)
    static func value(of source: ModulationSnapshot.Source,
                      atSample p: Int64, positionValid: Bool,
                      snapshot: ModulationSnapshot,
                      followerEnvelope: Float) -> Double {
        switch source.kindCode {
        case ModulationSnapshot.SourceCode.macro:
            // Live while stopped: a macro is a control, not a timeline.
            return snapshot.macroValue(slot: source.macroSlot)

        case ModulationSnapshot.SourceCode.envelopeFollower:
            // Live while stopped: it follows audio, and audio exists while
            // monitoring. The detector ran in the stage; this is a read.
            return ModulationMath.followerOutput(
                level: Double(followerEnvelope), floorDb: source.floorDb,
                gainLinear: source.detectorGainLinear)

        case ModulationSnapshot.SourceCode.stepSequencer:
            // m39-w4-4: a tempo-synced source reads the musical clock. A
            // free-running one (`divisionBeats == 0`) takes the unchanged path
            // below and never touches the clock.
            if source.divisionBeats > 0 {
                return syncedStepValue(of: source, atSample: p, positionValid: positionValid,
                                       snapshot: snapshot)
            }
            guard positionValid, source.samplesPerStep > 0, source.stepCount > 0,
                  let steps = snapshot.steps.baseAddress else { return neutral }
            let position = Double(p) / source.samplesPerStep
            return ModulationMath.stepSequencer(
                stepPosition: position,
                steps: steps.advanced(by: Int(source.stepOffset)),
                stepCount: Int(source.stepCount),
                edgeFraction: source.edgeFraction)

        default:  // lfo
            guard positionValid else { return neutral }
            // ⭐ THE NO-ACCUMULATOR LAW IN ONE LINE: the phase is computed FROM
            // the position, never advanced from the previous sample. This is
            // what makes a seek land on exactly the value a full playthrough
            // would have had, and what the position-absolute determinism test
            // pins. Anyone "optimising" this into a phase register breaks
            // seek-exactness, loop-exactness and live/offline agreement at once.
            let raw = Double(p) * source.cyclesPerSample + source.phaseOffset
            let phase = ModulationMath.phase(atSample: p,
                                             cyclesPerSample: source.cyclesPerSample,
                                             phaseOffset: source.phaseOffset)
            let v = ModulationMath.lfo(
                waveformCode: source.waveformCode, phase: phase,
                pulseWidth: source.pulseWidth, edgeFraction: source.edgeFraction,
                seed: source.seed, cycleIndex: Int64(floor(raw)))
            return source.bipolar ? v : ModulationMath.toUnipolar(v)
        }
    }

    /// m39-w4-4 — a TEMPO-SYNCED step source at project-absolute sample `p`
    /// (design §4.2).
    ///
    /// RT, line by line: the guard is Bool/Int compares and the unwrap of a
    /// stored buffer's base address; `p &- originSample` is one Int64
    /// subtraction (the clock is indexed by ROLL sample, never by `p`);
    /// `clockPosition` is the snapshot's bounded binary search over its own POD
    /// buffer — no allocation, no lock, no ObjC, no tempo map; the next three
    /// lines are Double arithmetic; the closed form reads the step pool through
    /// a pointer. Nothing is stored between calls, so a seek and a loop wrap read
    /// what a playthrough reads (the no-accumulator law below holds here too).
    ///
    /// `+ h` makes the edge TRAIL the boundary: the centred closed form
    /// evaluated `h` later ramps over [k − 2h, k) and returns exactly step k AT
    /// the boundary, so a drum hit on the grid line latches its own step, never
    /// the average of two. `edgeMs` stays `edgeMs` across a tempo change: the
    /// fraction is derived from the segment's rate, with the builder's 0.98 cap.
    @inline(__always)
    static func syncedStepValue(of source: ModulationSnapshot.Source, atSample p: Int64,
                                positionValid: Bool, snapshot: ModulationSnapshot) -> Double {
        guard positionValid, source.stepCount > 0,
              let steps = snapshot.steps.baseAddress else { return neutral }
        let clock = snapshot.clockPosition(atRollSample: p &- snapshot.originSample)
        guard clock.valid else { return neutral }
        let stepPosition = (clock.beat - clock.patternOriginBeat) / source.divisionBeats
        let edgeFraction = min(source.edgeSamples * clock.beatsPerSample / source.divisionBeats, 0.98)
        let h = ModulationMath.stepEdgeHalfWidth(edgeFraction: edgeFraction)
        return ModulationMath.stepSequencer(
            stepPosition: stepPosition + h,
            steps: steps.advanced(by: Int(source.stepOffset)),
            stepCount: Int(source.stepCount),
            edgeFraction: edgeFraction)
    }

    /// Σ over a target's ENABLED routes of `depth_i · s_i`, in the published
    /// array order (§7.3 — Float addition is not associative, so the order is
    /// part of the contract, not an implementation detail).
    ///
    /// Disabled routes never reach the snapshot: they are dropped at publish
    /// on the main actor, so the render thread has no `enabled` branch at all.
    @inline(__always)
    static func sum(forTargetAt targetIndex: Int32, snapshot: ModulationSnapshot,
                    atSample p: Int64, positionValid: Bool) -> Double {
        guard targetIndex >= 0, targetIndex < Int32(snapshot.targets.count),
              let sourceBase = snapshot.sources.baseAddress,
              let routeBase = snapshot.routes.baseAddress else { return 0 }
        let target = snapshot.targets[Int(targetIndex)]
        var total = 0.0
        var index = Int(target.routeOffset)
        let end = index + Int(target.routeCount)
        while index < end {
            let route = routeBase[index]
            let sourceIndex = Int(route.sourceIndex)
            if sourceIndex >= 0, sourceIndex < snapshot.sources.count {
                let source = sourceBase[sourceIndex]
                let envelope = snapshot.followerLevels[sourceIndex]
                total += route.depth * value(of: source, atSample: p,
                                             positionValid: positionValid,
                                             snapshot: snapshot,
                                             followerEnvelope: envelope)
            }
            index += 1
        }
        return total
    }

    /// The depth law applied to a spec-ranged target (effect param, instrument
    /// param). `base` is whatever is IN CONTROL — a lane value if one is
    /// active at this position, else the knob.
    @inline(__always)
    static func modulated(base: Double, forTargetAt targetIndex: Int32,
                          snapshot: ModulationSnapshot, atSample p: Int64,
                          positionValid: Bool) -> Double {
        guard targetIndex >= 0, targetIndex < Int32(snapshot.targets.count) else { return base }
        let target = snapshot.targets[Int(targetIndex)]
        let total = sum(forTargetAt: targetIndex, snapshot: snapshot,
                        atSample: p, positionValid: positionValid)
        let curve = curve(for: target.curveCode)
        return ModulationDepthLaw.value(base: base, sum: total,
                                        range: target.rangeLo...target.rangeHi,
                                        curve: curve)
    }

    /// Finds the target index addressing one effect param, or -1. A linear
    /// scan over at most `ModulationLimits.maxRoutes` entries, only ever
    /// reached when the strip HAS modulation (the caller's early-out).
    @inline(__always)
    static func targetIndex(forEffect effectID: UUID, paramSlot: Int32,
                            snapshot: ModulationSnapshot) -> Int32 {
        guard let base = snapshot.targets.baseAddress else { return -1 }
        var index = 0
        let count = snapshot.targets.count
        while index < count {
            let target = base[index]
            if target.kindCode == ModulationSnapshot.TargetCode.effectParam,
               target.paramSlot == paramSlot, target.effectID == effectID {
                return Int32(index)
            }
            index += 1
        }
        return -1
    }

    /// Finds the target index addressing one instrument param code, or -1.
    @inline(__always)
    static func targetIndex(forInstrumentParamCode code: Int32,
                            snapshot: ModulationSnapshot) -> Int32 {
        guard let base = snapshot.targets.baseAddress else { return -1 }
        var index = 0
        let count = snapshot.targets.count
        while index < count {
            let target = base[index]
            if target.kindCode == ModulationSnapshot.TargetCode.instrumentParam,
               target.paramSlot == code {
                return Int32(index)
            }
            index += 1
        }
        return -1
    }

    @inline(__always)
    static func curve(for code: Int32) -> ParamCurve {
        switch code {
        case 1: return .logarithmic
        case 2: return .decibel
        default: return .linear
        }
    }

    /// `ParamCurve` → its published code. Main actor (publish time).
    static func code(for curve: ParamCurve) -> Int32 {
        switch curve {
        case .linear: return 0
        case .logarithmic: return 1
        case .decibel: return 2
        }
    }
}
