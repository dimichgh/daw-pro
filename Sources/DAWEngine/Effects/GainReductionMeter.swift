import CAtomics
import Foundation

/// Gain-reduction metering seam for the built-in dynamics effects (m22-e):
/// compressor, limiter, and gate each publish the reduction their detector is
/// CURRENTLY applying, as POSITIVE dB (0 = untouched signal), with the house
/// held-peak ballistics — instantaneous reduction drives the value up
/// immediately (per-sample max, so a one-quantum transient clamp is never
/// missed between UI polls), release decays at −20 dB/s (the
/// `MasterMixAnalyzer.peakReleaseDBPerSecond` `peakDB` convention).
///
/// PUBLISH IDIOM (render → control plane): each effect owns one heap
/// `daw_atomic_u32` slot holding the current value's `Float.bitPattern`.
/// The render thread folds the per-sample held-peak state into its existing
/// sample loop (one compare + one multiply-or-subtract — no new loop) and
/// stores the slot ONCE per `process()` quantum; the main actor reads it with
/// one atomic load through `gainReductionDb`. No allocation, no locks, no
/// ObjC anywhere on the render side — the reverse direction of the
/// `paramsSlot` atomic-POD-publish convention, scalar-sized so no retire bin
/// is needed.
///
/// FREEZE SEMANTICS: the value only moves while the chain walk runs the
/// effect (the walk processes every quantum while the engine runs, silence
/// included, so release always plays out live). A stopped engine freezes the
/// last value — the `performanceStats` convention. `reset()`/`prepare()`
/// zero it (un-bypass arms reset, so a bypassed unit never wakes up showing
/// a stale value), and steadily bypassed units read 0 through
/// `EffectChainState.gainReductionDb(forEffect:)` — a bypassed effect is
/// applying no reduction, and claiming otherwise would lie.
enum GainReductionMeter {
    /// Held-peak release: −20 dB/s — EXACTLY the `peakDB` meter convention
    /// (`MasterMixAnalyzer.peakReleaseDBPerSecond`).
    static let releaseDbPerSecond = 20.0

    /// Cap / "full-range attenuation" reading, mirroring the house −80 dB
    /// floor: a fully closed gate multiplies by literal 0 (−∞ dB), which JSON
    /// cannot carry, so held linear gains clamp at `floorLinear` = 10^(−80/20)
    /// and the published reduction tops out at exactly 80 dB.
    static let maxDb: Float = 80
    static let floorLinear: Float = 1e-4

    /// Published values below this snap to exact 0 — the asymptote guard for
    /// one-pole releases that approach unity gain without ever landing on it
    /// (the limiter's release), matching the compressor's own
    /// `env > -1e-10 → 0` snap-at-rest idiom.
    static let snapDb: Float = 0.01

    /// The per-sample multiplicative rise factor for LINEAR-domain held gains
    /// (limiter, gate): gain rising at +20 dB/s ⇔ reduction falling at
    /// −20 dB/s (multiplicative in linear ≡ linear in dB). Main-actor
    /// `prepare()` computes this once per rate.
    static func risePerSample(sampleRate: Double) -> Float {
        Float(pow(10.0, releaseDbPerSecond / (20.0 * sampleRate)))
    }

    /// The per-sample subtractive decay step for DB-DOMAIN held reductions
    /// (compressor): 20 dB spread across one second of samples.
    static func decayDbPerSample(sampleRate: Double) -> Double {
        releaseDbPerSecond / sampleRate
    }

    /// RENDER-THREAD publish (also safe from `prepare()`/`reset()`): clamps
    /// into [0, maxDb] with NaN/Inf → 0 — the wire and UI NEVER see poison
    /// even if the audio path is fed garbage — snaps sub-`snapDb` release
    /// tails to exact 0, and stores the bit pattern with one atomic u32
    /// store. No allocation, no locks, no ObjC.
    static func publish(_ slot: UnsafeMutablePointer<daw_atomic_u32>, db: Float) {
        var value = db
        if !(value >= snapDb) { value = 0 }        // NaN compares false → 0
        if value > maxDb { value = maxDb }
        daw_atomic_u32_store(slot, value.bitPattern)
    }
}

/// Implemented by the built-in effects that measure gain reduction
/// (`CompressorEffect`, `LimiterEffect`, `GateEffect`). `ChainEffectUnit`
/// casts ONCE at unit creation (the `keyableInstance` pattern) and the
/// control plane reads through `EffectChainState.gainReductionDb(forEffect:)`
/// at UI/poll rate. Non-conforming kinds simply have no reading (wire omits
/// the field) — GR is never fabricated for effects that don't reduce gain
/// dynamically.
protocol GainReductionReporting: AnyObject {
    /// Current held-peak gain reduction in POSITIVE dB of reduction
    /// (0 = untouched, capped at `GainReductionMeter.maxDb`), −20 dB/s
    /// release. Finite by contract. One atomic load — safe from any thread.
    var gainReductionDb: Float { get }
}
