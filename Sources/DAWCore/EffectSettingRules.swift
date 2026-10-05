import Foundation

// m39-tpl-1 (docs/design/2026-09-27-multi-instrument-templates.md §5.2): the ONE
// named writer for an insert effect's settings.
//
// ⭐ MOVED HERE VERBATIM from `ProjectStore.applyEffectParam` (a `private static`
// in ProjectStore.swift until TPL-1), so a template's insert settings can be
// written through the SAME code `fx.setParam`, `fx.add` and the master chain use
// BEFORE the track they belong to exists. The only textual change is the
// receiver: `effect.x` became `self.x`, because the function is now a mutating
// method on the descriptor instead of a static taking it `inout`. The live
// verbs call it exactly where they called the old function, with the same
// already-clamped value, so their behaviour is byte-identical — a golden table
// captured from the pre-move code proves it (`EffectSettingRulesTests`).
//
// ⚠️ Comments elsewhere that still cite `ProjectStore.applyEffectParam`
// (`EffectDescriptor.paramValue`'s doc in Effects.swift, DAWAppKit's
// `EffectEditorModel`, DAWEngine's `EQEffect`, and several tests) mean THIS
// function now. The reader that inverts it is `EffectDescriptor.paramValue(_:)`.

extension EffectDescriptor {
    /// Writes a validated, already-clamped parameter into this descriptor.
    /// The per-kind name→field mapping — the single place the control/wire name
    /// resolves onto a model field. New kinds (iv) extend this switch. The value
    /// is already clamped to the spec range, which matches each struct's own
    /// clamping init, so field writes stay in-model-range by construction.
    ///
    /// An unknown name leaves the descriptor untouched (each arm's `default:
    /// return`); callers validate names against `EffectParamSpec.specs(for:)`
    /// first. Formerly `ProjectStore.applyEffectParam` (TPL-1 moved it here).
    mutating func applySetting(_ name: String, _ value: Double) {
        switch self.kind {
        case .gain:
            // m38-a: read-modify-write, NOT a fresh GainParams per name — a
            // rebuild from one field would silently reset the other (setting
            // gainLinear would clear an armed polarity flip). `invertPolarity`
            // is binary on the numeric surface (the truePeak/pingPong
            // precedent, >= 0.5 = on).
            var params = self.resolvedGain
            switch name {
            case "gainLinear": params.gainLinear = value
            case "invertPolarity": params.invertPolarity = value >= 0.5
            default: return
            }
            self.gain = params
        case .eq:
            var params = self.resolvedEQ
            switch name {
            case "lowShelfFreq": params.lowShelfFreq = value
            case "lowShelfGainDb": params.lowShelfGainDb = value
            case "peak1Freq": params.peak1Freq = value
            case "peak1GainDb": params.peak1GainDb = value
            case "peak1Q": params.peak1Q = value
            case "peak2Freq": params.peak2Freq = value
            case "peak2GainDb": params.peak2GainDb = value
            case "peak2Q": params.peak2Q = value
            case "highShelfFreq": params.highShelfFreq = value
            case "highShelfGainDb": params.highShelfGainDb = value
            // m22-a EQ v2. Setting an HP/LP frequency ACTIVATES that filter
            // (nil freq = off); slopes snap to 12/24; `*Enabled` is binary on
            // the numeric surface (the pingPong precedent, ≥ 0.5 = on).
            // Enabling an HP/LP that has no corner yet materializes the spec
            // default (20 Hz / 20 kHz) so the toggle is never a silent no-op.
            case "highPassFreq": params.highPassFreq = value
            case "highPassSlopeDbPerOct": params.highPassSlopeDbPerOct = EQParams.snapSlope(value)
            case "highPassEnabled":
                let on = value >= 0.5
                params.highPassEnabled = on
                if on, params.highPassFreq == nil {
                    params.highPassFreq = EQParams.highPassFreqRange.lowerBound
                }
            case "lowPassFreq": params.lowPassFreq = value
            case "lowPassSlopeDbPerOct": params.lowPassSlopeDbPerOct = EQParams.snapSlope(value)
            case "lowPassEnabled":
                let on = value >= 0.5
                params.lowPassEnabled = on
                if on, params.lowPassFreq == nil {
                    params.lowPassFreq = EQParams.lowPassFreqRange.upperBound
                }
            case "lowShelfQ": params.lowShelfQ = value
            case "highShelfQ": params.highShelfQ = value
            case "lowShelfEnabled": params.lowShelfEnabled = value >= 0.5
            case "peak1Enabled": params.peak1Enabled = value >= 0.5
            case "peak2Enabled": params.peak2Enabled = value >= 0.5
            case "highShelfEnabled": params.highShelfEnabled = value >= 0.5
            default: return
            }
            self.eq = params
        case .compressor:
            var params = self.resolvedCompressor
            switch name {
            case "thresholdDb": params.thresholdDb = value
            case "ratio": params.ratio = value
            case "attackMs": params.attackMs = value
            case "releaseMs": params.releaseMs = value
            case "kneeDb": params.kneeDb = value
            case "makeupDb": params.makeupDb = value
            // m23-ck parallel compression: 1 fully wet (the default), 0 a
            // bit-exact bypass. Already clamped to 0…1 by the spec range.
            case "mix": params.mix = value
            // m39-ae the de-esser. All three are already clamped to their spec
            // ranges by the caller; `detectorMode` is stored UNSNAPPED on
            // purpose — the `phaser.stages` / `clipper.mode` precedent, where
            // the store keeps what was asked for and the render thread snaps
            // through the one home (`CompressorParams.detectorMode(at:)`). The
            // wire echoes `resolvedDetectorMode` so the difference is visible
            // rather than a surprise.
            case "detectorMode": params.detectorMode = value
            case "detectorFreqHz": params.detectorFreqHz = value
            case "detectorQ": params.detectorQ = value
            default: return
            }
            self.compressor = params
        case .limiter:
            var params = self.resolvedLimiter
            switch name {
            case "ceilingDb": params.ceilingDb = value
            case "releaseMs": params.releaseMs = value
            case "truePeak": params.truePeak = value >= 0.5
            default: return
            }
            self.limiter = params
        case .reverb:
            var params = self.resolvedReverb
            switch name {
            case "roomSize": params.roomSize = value
            case "damping": params.damping = value
            case "mix": params.mix = value
            case "preDelayMs": params.preDelayMs = value
            case "width": params.width = value
            default: return
            }
            self.reverb = params
        case .delay:
            var params = self.resolvedDelay
            switch name {
            case "timeMs": params.timeMs = value
            case "feedback": params.feedback = value
            case "mix": params.mix = value
            // pingPong snaps to 0/1 through the clamping init (numeric bool);
            // the rebuild carries the m22-f fields so a pingPong write can
            // never silently drop sync/division.
            case "pingPong": params = DelayParams(timeMs: params.timeMs,
                                                  feedback: params.feedback,
                                                  mix: params.mix, pingPong: value,
                                                  highCutHz: params.highCutHz,
                                                  sync: params.sync,
                                                  division: params.division)
            case "highCutHz": params.highCutHz = value
            // m22-f tempo sync: binary on the numeric surface (the pingPong
            // precedent, ≥ 0.5 = on); division rides as its length in beats
            // and snaps to the nearest legal note value.
            case "sync": params.sync = value >= 0.5
            case "division": params.division = NoteDivision.nearest(toBeats: value)
            default: return
            }
            self.delay = params
        case .saturator:
            var params = self.resolvedSaturator
            switch name {
            case "driveDb": params.driveDb = value
            case "mix": params.mix = value
            case "outputDb": params.outputDb = value
            // m39-ad. Stored UNSNAPPED, exactly like `clipper.oversampling` and
            // `phaser.stages`: the setter clamps to the range but does not snap,
            // so a stored 3 renders as 4. `resolvedOversampling` on the wire is
            // what the render thread actually uses.
            case "oversampling": params.oversampling = value
            default: return
            }
            self.saturator = params
        case .gate:
            var params = self.resolvedGate
            switch name {
            case "thresholdDb": params.thresholdDb = value
            case "attackMs": params.attackMs = value
            case "holdMs": params.holdMs = value
            case "releaseMs": params.releaseMs = value
            default: return
            }
            self.gate = params
        case .chorus:
            var params = self.resolvedChorus
            switch name {
            case "rateHz": params.rateHz = value
            case "depthMs": params.depthMs = value
            case "mix": params.mix = value
            default: return
            }
            self.chorus = params
        case .bassEnhancer:
            var params = self.resolvedBassEnhancer
            switch name {
            case "crossoverHz": params.crossoverHz = value
            case "amount": params.amount = value
            case "mix": params.mix = value
            default: return
            }
            self.bassEnhancer = params
        case .bitCrusher:
            var params = self.resolvedBitCrusher
            switch name {
            // `bits` snaps to a whole number through the clamping init (the
            // pingPong numeric-but-discrete precedent); the rebuild carries
            // every other field so a bits write can never silently drop them.
            case "bits": params = BitCrusherParams(
                bits: value, downsampleHz: params.downsampleHz,
                antiAlias: params.antiAlias, dither: params.dither, mix: params.mix)
            case "downsampleHz": params.downsampleHz = value
            // Binary on the numeric surface (the truePeak/pingPong precedent).
            case "antiAlias": params.antiAlias = value >= 0.5
            case "dither": params.dither = value >= 0.5
            case "mix": params.mix = value
            default: return
            }
            self.bitCrusher = params
        case .djFilter:
            var params = self.resolvedDJFilter
            switch name {
            case "position": params.position = value
            case "resonance": params.resonance = value
            // Numeric-but-discrete: the rebuild routes through the clamping
            // init so the 12/24 snap happens here, exactly where a bare field
            // write would have left an un-snapped 17 in the model (the
            // `bitCrusher.bits` precedent, same shape, same reason).
            case "slopeDbPerOct": params = DJFilterParams(
                position: params.position, resonance: params.resonance,
                slopeDbPerOct: value, deadZoneWidth: params.deadZoneWidth,
                resonanceTrack: params.resonanceTrack)
            case "deadZoneWidth": params.deadZoneWidth = value
            case "resonanceTrack": params.resonanceTrack = value
            default: return
            }
            self.djFilter = params
        case .ringMod:
            var params = self.resolvedRingMod
            switch name {
            case "carrierHz": params.carrierHz = value
            case "mix": params.mix = value
            // Numeric-but-discrete: the rebuild routes through the clamping
            // init so the 0/1/2/3 snap happens HERE, exactly where a bare
            // field write would have left an un-snapped 1.7 in the model that
            // `fx.describe` would then report as the setting (the
            // `bitCrusher.bits` / `djFilter.slopeDbPerOct` precedent).
            case "waveform": params = RingModParams(
                carrierHz: params.carrierHz, mix: params.mix, waveform: value,
                inputHighCutHz: params.inputHighCutHz,
                stereoSpreadDeg: params.stereoSpreadDeg)
            case "inputHighCutHz": params.inputHighCutHz = value
            case "stereoSpreadDeg": params.stereoSpreadDeg = value
            default: return
            }
            self.ringMod = params
        case .flanger:
            var params = self.resolvedFlanger
            switch name {
            case "rateHz": params.rateHz = value
            case "depthMs": params.depthMs = value
            case "delayMs": params.delayMs = value
            case "feedback": params.feedback = value
            case "mix": params.mix = value
            case "stereoPhaseDeg": params.stereoPhaseDeg = value
            default: return
            }
            self.flanger = params
        case .hallReverb:
            var params = self.resolvedHallReverb
            switch name {
            case "mix": params.mix = value
            case "decaySeconds": params.decaySeconds = value
            case "sizeMeters": params.sizeMeters = value
            case "preDelayMs": params.preDelayMs = value
            case "width": params.width = value
            case "diffusion": params.diffusion = value
            case "earlyLateBalance": params.earlyLateBalance = value
            case "lowDecayMultiplier": params.lowDecayMultiplier = value
            case "highDecayMultiplier": params.highDecayMultiplier = value
            case "lowCrossoverHz": params.lowCrossoverHz = value
            case "highCrossoverHz": params.highCrossoverHz = value
            case "modRateHz": params.modRateHz = value
            case "modDepthMs": params.modDepthMs = value
            // `freeze` is a SWITCH on a numeric surface, but unlike
            // `bitCrusher.antiAlias` it is stored as the raw 0...1 number
            // rather than a Bool, so a bare field write is exactly right here
            // and there is nothing to snap: `HallReverbParams.isFrozen`
            // interprets it at the ONE place that cares (the DSP).
            case "freeze": params.freeze = value
            default: return
            }
            self.hallReverb = params
        case .tapeDelay:
            var params = self.resolvedTapeDelay
            switch name {
            case "timeMs": params.timeMs = value
            case "feedback": params.feedback = value
            case "mix": params.mix = value
            case "wowDepthMs": params.wowDepthMs = value
            case "wowRateHz": params.wowRateHz = value
            case "flutterDepthMs": params.flutterDepthMs = value
            case "saturationDrive": params.saturationDrive = value
            case "highCutHz": params.highCutHz = value
            default: return
            }
            self.tapeDelay = params
        case .stereoWidth:
            var params = self.resolvedStereoWidth
            switch name {
            case "width": params.width = value
            case "spread": params.spread = value
            case "bassMonoHz": params.bassMonoHz = value
            case "bassMonoAmount": params.bassMonoAmount = value
            default: return
            }
            self.stereoWidth = params
        case .phaser:
            var params = self.resolvedPhaser
            switch name {
            case "rateHz": params.rateHz = value
            case "centerHz": params.centerHz = value
            case "depthOctaves": params.depthOctaves = value
            // SNAPPED through the law — `stages` is discrete, and storing the
            // raw 7 would make `fx.setParam`'s echo disagree with what is in
            // force (the `RingModParams.waveform` precedent).
            case "stages": params.stages = Double(PhaserParams.snappedStages(value))
            case "feedback": params.feedback = value
            case "mix": params.mix = value
            case "stereoPhaseDeg": params.stereoPhaseDeg = value
            default: return
            }
            self.phaser = params
        case .transientShaper:
            var params = self.resolvedTransientShaper
            switch name {
            case "attackDb": params.attackDb = value
            case "sustainDb": params.sustainDb = value
            case "attackMs": params.attackMs = value
            case "sustainMs": params.sustainMs = value
            case "outputDb": params.outputDb = value
            case "mix": params.mix = value
            default: return
            }
            self.transientShaper = params
        case .freqShifter:
            var params = self.resolvedFreqShifter
            switch name {
            case "shiftHz": params.shiftHz = value
            case "fineHz": params.fineHz = value
            case "stereoSpreadHz": params.stereoSpreadHz = value
            case "mix": params.mix = value
            case "outputDb": params.outputDb = value
            default: return
            }
            self.freqShifter = params
        case .clipper:
            var params = self.resolvedClipper
            switch name {
            case "driveDb": params.driveDb = value
            case "ceilingDb": params.ceilingDb = value
            case "mode": params.mode = value
            case "oversampling": params.oversampling = value
            case "mix": params.mix = value
            case "outputDb": params.outputDb = value
            default: return
            }
            self.clipper = params
        case .dynamicEQ:
            // m39-af — 32 names through the ONE name↔field home in DAWCore
            // rather than a fourth hand-copied 32-case switch. `setValue`
            // returns false for an unknown name, which is this switch's `return`
            // (leave the descriptor untouched); `setEffectParam` has already
            // clamped `value` to the spec range.
            var params = self.resolvedDynamicEQ
            guard params.setValue(value, forParamName: name) else { return }
            self.dynamicEQ = params
        case .audioUnit:
            // Unreachable: specs(for: .audioUnit) is empty, so name validation
            // in setEffectParam rejects every name first. AU params are not
            // on the generic surface in v0.
            return
        }
    }
}
