import AVFAudio

/// AU-shaped effect seam, mirroring `InstrumentRendering`. `process()` /
/// `reset()` run ON THE RENDER THREAD: no allocation, no locks, no ObjC
/// dispatch, no actor hops. `prepare()` runs on the main actor before the
/// chain ever renders — allocate everything there.
///
/// Effects process IN PLACE (no ping-pong buffers in the chain walk); an
/// effect that needs a dry copy keeps an internal preallocated scratch. The
/// M4 (v) AU adapter hides the pull model internally behind this same seam.
///
/// Parameters travel OUTSIDE this protocol: each effect exposes a main-actor
/// `apply(params:)` publishing an immutable POD via heap `daw_atomic_ptr` +
/// ≥ 1 s retire bin — verbatim the `PolySynthInstrument.apply` convention.
/// Param edits never republish the chain.
protocol EffectRendering: AnyObject {
    /// Main-actor setup before any render; allocate everything here.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int)

    /// Process exactly `frameCount` frames IN PLACE (non-interleaved Float32).
    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int)

    /// Render-thread-safe: clear tails/state now.
    func reset()

    /// Fixed algorithmic latency at the prepared rate (0 in v0 — the
    /// M4 (viii) PDC hook). Main-actor read.
    var latencySamples: Int { get }

    /// RENDER-THREAD automation store (M4 vii-c): overrides ONE parameter —
    /// `slot` indexes `EffectParamSpec.specs(for: kind)` — for the current
    /// quantum. `AutomationRenderer.storeEffectParams` calls this BEFORE the
    /// chain walk, on the SAME render thread that runs `process()`, so
    /// implementations need no atomics of their own; the only cross-thread
    /// traffic stays the effect's existing main-actor param snapshot slot
    /// (whose momentary last-writer-wins race with a concurrent UI edit is
    /// benign — the store repeats every quantum). Contract: no allocation,
    /// no locks, no ObjC; out-of-range slots and non-finite values are inert.
    ///
    /// PER-KIND AUDIT (vii-c): every built-in's MAIN-ACTOR `apply(params:)`
    /// allocates (ParamSnapshot box + retire-bin append) → NOT render-
    /// callable; each therefore implements this lean setter, which pokes a
    /// preallocated `AutomationParamOverlay` params copy and re-derives via
    /// the same pure-libm math the generation-change adoption already runs
    /// on the render thread. Verdicts on the derive-under-automation path:
    ///
    ///   kind        derive cost / render-safety notes
    ///   ----------  ------------------------------------------------------
    ///   gain        exact target + ~5 ms declick ramp; unity skip preserved
    ///   eq          4× RBJ coeff recompute (sin/cos/pow) — pure, no alloc
    ///   compressor  2× exp coeffs; envelope smoother declicks the steps
    ///   limiter     pow + exp; lookahead FIXED → lines never resize
    ///   reverb      arithmetic only; preDelay is a read offset (MAX-sized)
    ///   delay       1× exp; time is a read offset (lines MAX-sized, 2 s)
    ///   saturator   3× pow; stateless shaper
    ///   gate        pow + arithmetic; attack/release ramps declick steps
    ///   chorus      arithmetic only; depth is math (lines MAX-sized)
    ///   audioUnit   default no-op below (empty spec surface in v0)
    func storeAutomatedParam(slot: Int, value: Double)
}

extension EffectRendering {
    /// Default: inert. `PassthroughEffect` and hosted Audio Units land here —
    /// a stale `.audioUnit`-effect lane can never reach AU state through this
    /// surface (AU param lanes are the deferred M4 vii-f upgrade).
    func storeAutomatedParam(slot: Int, value: Double) {}
}

/// Render-thread-only bookkeeping for automated built-in params (M4 vii-c),
/// embedded BY VALUE in each built-in effect (`Params` is the effect's POD
/// params payload — no allocation anywhere). The same render thread runs both
/// the automation store (pre-chain-walk) and `process()` (the walk), so no
/// atomics are needed here.
///
/// Per-quantum contract:
///  · `rebase(_:)` on main-actor snapshot adoption — the knob values.
///  · `beginStore()` before each automated poke; the FIRST store of a quantum
///    resets `effective` to `base`, so a lane that vanished mid-play stops
///    contributing even while OTHER lanes on the same effect keep storing.
///  · `endQuantum()` at the top of `process()` — returns true exactly once
///    when the LAST lane vanished (schedule republished without this effect,
///    or transport stopped): the effect re-derives from `base`, restoring the
///    knob values with no main-actor republish needed.
struct AutomationParamOverlay<Params> {
    /// Last MAIN-ACTOR-published params (the knobs).
    private(set) var base: Params
    /// `base` + this quantum's automated stores — what the effect derives from.
    var effective: Params
    private var storedThisQuantum = false
    private var active = false

    init(base: Params) {
        self.base = base
        self.effective = base
    }

    mutating func rebase(_ params: Params) {
        base = params
        effective = params
    }

    mutating func beginStore() {
        if !storedThisQuantum { effective = base }
        storedThisQuantum = true
        active = true
    }

    mutating func endQuantum() -> Bool {
        let revert = active && !storedThisQuantum
        if revert {
            active = false
            effective = base
        }
        storedThisQuantum = false
        return revert
    }
}
