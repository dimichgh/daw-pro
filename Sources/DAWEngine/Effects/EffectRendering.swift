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
    ///   kind          derive cost / render-safety notes
    ///   ------------  ----------------------------------------------------
    ///   gain          exact target + ~5 ms declick ramp; unity skip kept
    ///   eq            4× RBJ coeff recompute (sin/cos/pow) — pure, no alloc
    ///   compressor    2× exp coeffs; envelope smoother declicks the steps
    ///   limiter       pow + exp; lookahead FIXED → lines never resize
    ///   reverb        arithmetic only; preDelay is a read offset (MAX-sized)
    ///   delay         1× exp; time is a read offset (lines MAX-sized, 2 s)
    ///   saturator     3× pow; stateless shaper
    ///   gate          pow + arithmetic; attack/release ramps declick steps
    ///   chorus        arithmetic only; depth is math (lines MAX-sized)
    ///   bassEnhancer  2× RBJ cut sections (sin/cos) + 1 exp — pure, no
    ///                 alloc; state FIXED (2 biquads + detector per channel)
    ///   bitCrusher    1 int shift + 2 RBJ cut sections (sin/cos) — pure, no
    ///                 alloc; state FIXED (4 biquads + phase + hold per
    ///                 channel). `bits`/`downsampleHz` are RE-CLAMPED in the
    ///                 derive because a field-by-field overlay poke bypasses
    ///                 the params init, and `Int(bits)` feeds a shift
    ///   djFilter      2 SVF coefficient triples (tan) + 1 pow + 1 sqrt,
    ///                 every 32 FRAMES not every sample — pure libm, no
    ///                 alloc; state FIXED (4 SVF sections of 2 integrators).
    ///                 `position`/`resonance`/`deadZoneWidth`/`resonanceTrack`
    ///                 are RE-CLAMPED and `slopeDbPerOct` RE-SNAPPED in the
    ///                 derive, because a field-by-field overlay poke bypasses
    ///                 the params init and a NaN would reach `tan()`
    ///   ringMod       1 RBJ cut section (sin/cos) every 32 FRAMES; the
    ///                 CARRIER's phase increment, mix and stereo offset
    ///                 interpolate per SAMPLE (adds only) — pure libm, no
    ///                 alloc; state FIXED (2 biquads of 2 TDF2 taps + one
    ///                 phase). Every field is RE-CLAMPED in the derive and
    ///                 `waveform` RE-SNAPPED through `RingModParams
    ///                 .waveform(at:)`, because a field-by-field overlay poke
    ///                 bypasses the params init: `waveform` feeds an `Int()`
    ///                 conversion that TRAPS on a NaN, and a NaN carrier would
    ///                 poison the phase accumulator with no path back
    ///   flanger       1 sin per channel per SAMPLE (the LFO, the chorus's own
    ///                 cost) — no coefficient stride, because there are no
    ///                 coefficients; the delay floor, depth, feedback, mix and
    ///                 stereo phase offset all interpolate per SAMPLE (adds
    ///                 only). One `InterpolatedDelayLine` MAX-sized at 20 ms,
    ///                 so depth/delay are math, never an allocation; the
    ///                 recirculating tap is DENORMAL-FLUSHED per sample
    ///                 (`DelayEffect`'s `1e-20`) because the shared line
    ///                 deliberately carries no flush of its own. Every field
    ///                 is RE-CLAMPED in the derive, and here that is memory
    ///                 safety rather than tidiness: the summed delay reaches
    ///                 `Int()` inside the line's tap, which has NO
    ///                 render-thread bounds check by design
    ///   hallReverb    24 `pow` (three band gains × eight lines) + 2 `exp`
    ///                 (the two shelf corners) + 1 sin/cos pair (the early/late
    ///                 equal-power blend) ONCE PER QUANTUM; per SAMPLE, 8 sin
    ///                 (one LFO per line — the anti-metallic spread) and one
    ///                 sin/cos pair (the `diffusion` crossfade), plus adds only
    ///                 for the per-sample interpolation of ALL 24 line gains,
    ///                 the line lengths, the pre-delay tap, mix, width and the
    ///                 shelf coefficients — pure libm, no alloc. State is NINE
    ///                 `InterpolatedDelayLine`s MAX-SIZED in `prepare()` (8
    ///                 tank lines at `lineCapacitySeconds` = 0.2557 s, one mono
    ///                 pre-delay at 0.260 s) plus four fixed Schroeder
    ///                 diffusers, so `sizeMeters` is arithmetic on a read
    ///                 offset and NOTHING EVER RESIZES. Three recirculating
    ///                 words per line are DENORMAL-FLUSHED per sample
    ///                 (`DelayEffect`'s `1e-20`) — the tap, the two shelf
    ///                 one-poles, and the diffusers' state — because the
    ///                 shared line deliberately carries no flush of its own;
    ///                 the shelf one is INVISIBLE FROM THE OUTPUT and is pinned
    ///                 by a `@testable` read of the state, not by listening.
    ///                 Every field is RE-CLAMPED in the derive, and here that
    ///                 is memory safety: `sizeMeters`, `modDepthMs` and
    ///                 `preDelayMs` all reach `Int()` inside the line's tap,
    ///                 which has NO render-thread bounds check by design, and
    ///                 an unfenced lane could ask a 0.2557 s line for 600 m.
    ///                 ⚠️ `while`, never `for index in 0..<n`, in BOTH this
    ///                 derive and `process()` — MEASURED, not stylistic: a
    ///                 `Range` iteration raises ~2 malloc/free per iteration at
    ///                 `-Onone`, and the allocation gate counted 96 000 events
    ///                 over 2 000 quanta (exactly 48/quantum, the 24 iterations
    ///                 here and in `process()` doubled) before the conversion
    ///   tapeDelay     1 `exp` ONCE PER QUANTUM (the record-path high-cut
    ///                 corner); per SAMPLE, 3 sin (the wow motor and the two
    ///                 fixed flutter components — ONE transport shared by both
    ///                 channels, so the count does not double with the channel
    ///                 count) and one `tanh` PER CHANNEL (the record-path
    ///                 shaper, `TapeDelayParams.saturated`, whose algebra lives
    ///                 in DAWCore so the DSP and the tests read one home), plus
    ///                 adds only for the per-sample interpolation of the delay
    ///                 time, both depths, the wow increment, feedback, mix, the
    ///                 drive gain, the drive amount and the LOW-PASS
    ///                 COEFFICIENT (interpolated directly rather than
    ///                 re-derived, so there is no `exp` in the inner loop and
    ///                 no 32-frame stride) — pure libm, no alloc. State is ONE
    ///                 `InterpolatedDelayLine` MAX-SIZED in `prepare()` at
    ///                 `lineCapacitySeconds` = 4.0 s with `.cubicHermite`, so
    ///                 `timeMs` is arithmetic on a read offset and NOTHING EVER
    ///                 RESIZES, plus three transport phases and two one-pole
    ///                 words. TWO recirculating words per channel are
    ///                 DENORMAL-FLUSHED per sample (`DelayEffect`'s `1e-20`) —
    ///                 the TAP and the RECORD-PATH LOW-POLE — because the
    ///                 shared line deliberately carries no flush of its own and
    ///                 `tanh` preserves a subnormal rather than killing it.
    ///                 Every field is RE-CLAMPED in the derive, and here that
    ///                 is memory safety: `timeMs` reaches `Int()` inside the
    ///                 line's tap, which has NO render-thread bounds check by
    ///                 design, and an unfenced lane could ask a 4 s line for
    ///                 9 000 ms
    ///   stereoWidth   1 `exp` ONCE PER QUANTUM (the bass-mono crossover
    ///                 corner, through `StereoWidthParams.onePoleCoefficient`);
    ///                 per SAMPLE, adds and multiplies ONLY — no libm at all in
    ///                 the inner loop — because `width`, `spread`, the bass-mono
    ///                 amount and the crossover COEFFICIENT all interpolate
    ///                 directly (the `tapeDelay` precedent: interpolate the
    ///                 coefficient, do not re-derive it, so there is no
    ///                 32-frame stride). State is FOUR mono
    ///                 `InterpolatedDelayLine`s at
    ///                 `StereoWidthParams.lineCapacitySeconds` = 0.0131 s — the
    ///                 four Schroeder all-pass stages of the decorrelator,
    ///                 whose lengths are prepare-time CONSTANTS, so nothing
    ///                 here ever resizes and no parameter reaches an `Int()`
    ///                 conversion — plus two one-pole crossover words. SIX
    ///                 recirculating words are DENORMAL-FLUSHED per sample
    ///                 (`DelayEffect`'s `1e-20`): the four all-pass values
    ///                 WRITTEN into the lines, so a line is never fed a
    ///                 subnormal, and both crossover poles. Every field is
    ///                 RE-CLAMPED in the derive — not for memory safety here
    ///                 (there is no tap arithmetic to poison) but because a NaN
    ///                 `width` would silence the strip permanently through the
    ///                 interpolation accumulator
    ///   audioUnit     default no-op below (empty spec surface in v0)
    func storeAutomatedParam(slot: Int, value: Double)
}

extension EffectRendering {
    /// Default: inert. `PassthroughEffect` and hosted Audio Units land here —
    /// a stale `.audioUnit`-effect lane can never reach AU state through this
    /// surface (AU param lanes are the deferred M4 vii-f upgrade).
    func storeAutomatedParam(slot: Int, value: Double) {}
}

/// Sidechain-keyable effect seam (m12-f S-2, design-m11f-sidechain §4-A):
/// the detector reads `key` instead of the main buffer while gain still
/// applies to the main buffer. Same RENDER-THREAD contract as `process`.
///
/// `key == nil` ⇒ self-keyed — MUST be bit-exact with the plain
/// `process(buffers:frameCount:)` (design §10 condition 4, pinned by test);
/// this is also the degrade path when the key bus pull fails (§6.2 — the
/// chain walk simply hands nil). `key` frames beyond the delivered byte size
/// read as silence, never garbage. v1 conformers: `CompressorEffect`,
/// `GateEffect`.
protocol KeyableEffectRendering: EffectRendering {
    /// Process IN PLACE with an external key signal for the detector.
    func process(buffers: UnsafeMutableAudioBufferListPointer,
                 key: UnsafeMutableAudioBufferListPointer?,
                 frameCount: Int)
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
