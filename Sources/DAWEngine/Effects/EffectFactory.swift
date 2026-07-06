import AVFAudio
import DAWCore
import Foundation

/// Bit-exact do-nothing insert: the placeholder a `.audioUnit` descriptor
/// renders through until (unless) its hosted AU finishes async preparation
/// (missing component / failed or pending prepare). Latency 0.
final class PassthroughEffect: EffectRendering, @unchecked Sendable {
    let latencySamples = 0
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {}
    func reset() {}
}

/// Maps `EffectDescriptor` → live `EffectRendering` instance, for the live
/// and offline graphs alike (both route through `EffectChainState.sync`).
/// M4 (iii)/(iv) add cases here as kinds land; M4 (v) adds the hosted-AU
/// adapter: `.audioUnit` resolves through `EffectChainState`'s
/// `hostedEffectProvider` BEFORE this factory is consulted, so the factory
/// only ever supplies the passthrough placeholder (async prepare → chain
/// republish via `AudioEngine.syncAudioUnitEffects`, never a node rebuild).
@MainActor
enum EffectFactory {
    static func makeInstance(for descriptor: EffectDescriptor) -> any EffectRendering {
        switch descriptor.kind {
        case .gain:
            return GainEffect(params: descriptor.resolvedGain)
        case .eq:
            return EQEffect(params: descriptor.resolvedEQ)
        case .compressor:
            return CompressorEffect(params: descriptor.resolvedCompressor)
        case .limiter:
            return LimiterEffect(params: descriptor.resolvedLimiter)
        case .reverb:
            return ReverbEffect(params: descriptor.resolvedReverb)
        case .delay:
            return DelayEffect(params: descriptor.resolvedDelay)
        case .saturator:
            return SaturatorEffect(params: descriptor.resolvedSaturator)
        case .gate:
            return GateEffect(params: descriptor.resolvedGate)
        case .chorus:
            return ChorusEffect(params: descriptor.resolvedChorus)
        case .audioUnit:
            // Reached only when the registry has no prepared instance yet
            // (the chain state consults its provider first): bit-exact
            // passthrough until the async prepare republishes the chain.
            return PassthroughEffect()
        }
    }

    /// In-place parameter apply for an existing instance (each effect's
    /// `apply` dedupes, so this is safe on every parameter pass).
    static func applyParams(_ descriptor: EffectDescriptor, to instance: any EffectRendering) {
        switch descriptor.kind {
        case .gain:
            (instance as? GainEffect)?.apply(params: descriptor.resolvedGain)
        case .eq:
            (instance as? EQEffect)?.apply(params: descriptor.resolvedEQ)
        case .compressor:
            (instance as? CompressorEffect)?.apply(params: descriptor.resolvedCompressor)
        case .limiter:
            (instance as? LimiterEffect)?.apply(params: descriptor.resolvedLimiter)
        case .reverb:
            (instance as? ReverbEffect)?.apply(params: descriptor.resolvedReverb)
        case .delay:
            (instance as? DelayEffect)?.apply(params: descriptor.resolvedDelay)
        case .saturator:
            (instance as? SaturatorEffect)?.apply(params: descriptor.resolvedSaturator)
        case .gate:
            (instance as? GateEffect)?.apply(params: descriptor.resolvedGate)
        case .chorus:
            (instance as? ChorusEffect)?.apply(params: descriptor.resolvedChorus)
        case .audioUnit:
            // AU params are not on the generic surface in v0 — no-op.
            break
        }
    }
}
