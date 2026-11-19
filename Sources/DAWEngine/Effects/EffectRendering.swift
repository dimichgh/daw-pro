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
    ///   saturator     3× pow per DERIVE; the shaper is stateless AT FACTOR 1
    ///                 (the default), where the oversampling path is SKIPPED
    ///                 outright and the arithmetic is v0's, unchanged, so
    ///                 every existing project renders bit-for-bit as before.
    ///                 At 2×/4× it is the `clipper`'s machinery with `tanh` in
    ///                 place of the ceiling: ≈129/≈257 multiply-accumulates per
    ///                 base sample per channel, plus `L` `tanhf` calls, plus a
    ///                 32-sample dry ring. ⛔ NO per-sample interpolation, at
    ///                 either factor, DELIBERATELY: this kind has never
    ///                 smoothed and adding it would change a shipped default
    ///                 (`SaturatorEffect` DESIGN §5). ⛔⛔ `latencySamples` IS
    ///                 PARAMETER-DEPENDENT HERE — 0 at factor 1, 32 at 2/4 —
    ///                 which is safe ONLY because the factor moves on the MAIN
    ///                 ACTOR ONLY (`adoptPendingParams`, inside the
    ///                 `applyParameters` pass whose tail recomputes PDC) and
    ///                 slot 3 is INERT to automation (the `delay.sync`
    ///                 precedent). Break either and the PDC plan goes stale
    ///                 with every test green: `SaturatorEffect` DESIGN §3
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
    ///   phaser        1 `tan` PER CHANNEL per 32-frame block (the all-pass
    ///                 corner, through `PhaserParams.allpassCoefficient`) —
    ///                 TWO per block total, NOT one per SECTION: every section
    ///                 shares the one corner, which is also what makes the
    ///                 notch count exactly `stages/2`. Plus one `sin` and one
    ///                 `pow` per block inside `sweptCornerHz`. Per SAMPLE, adds
    ///                 and multiplies ONLY — no libm at all in the inner loop —
    ///                 because the coefficient is INTERPOLATED across the block
    ///                 (the `tapeDelay` precedent) rather than re-derived, and
    ///                 `feedback`/`mix` interpolate directly. State is ONE
    ///                 `UnsafeMutablePointer<Float>` of `stagesRange.upperBound
    ///                 * 2` words allocated in `init` at the MAXIMUM stage
    ///                 count, so a stage-count change is an index bound and
    ///                 NOTHING EVER RESIZES, plus one feedback word per channel
    ///                 and one LFO phase. UP TO 26 recirculating words are
    ///                 DENORMAL-FLUSHED per sample (`DelayEffect`'s `1e-20`):
    ///                 EVERY section's state word — because each first-order
    ///                 all-pass is its OWN IIR with a pole at |a| and decays
    ///                 into subnormals on silence INDEPENDENTLY, at feedback 0
    ///                 as much as at 0.95, which is the part a flanger-shaped
    ///                 one-word flush would miss — plus both feedback words.
    ///                 Every field is RE-CLAMPED in the derive, and here that
    ///                 is stability and not tidiness: an unfenced `centerHz` or
    ///                 `depthOctaves` would push the corner past Nyquist, where
    ///                 `tan` is beyond its asymptote and |a| exceeds 1, i.e. an
    ///                 UNSTABLE section. ⚠️ `stages` is the one param that
    ///                 CLEARS state (a bounded store, off the inner loop)
    ///   transientShaper
    ///                 4 `exp` per DERIVE (the three envelope time constants
    ///                 plus the fixed fast-release), through
    ///                 `TransientShaperParams.onePoleCoefficient` — NOT per
    ///                 sample and NOT on a stride: an envelope coefficient
    ///                 changes the TRAJECTORY of a state variable whose current
    ///                 value is unchanged, so there is nothing to zipper and
    ///                 nothing to interpolate (the `compressor` precedent,
    ///                 deliberately NOT the `djFilter`/`phaser` one, where the
    ///                 coefficient is in the AUDIO path). Per SAMPLE: TWO
    ///                 `log10` (the two dB-ratio differentials) and ONE `pow`
    ///                 (the gain) = THREE transcendentals, against
    ///                 `compressor`'s shipping two, plus ~12 flops of one-pole
    ///                 update and two output multiplies. ⚠️ An operation count,
    ///                 NOT a benchmark — no nanosecond figure is asserted.
    ///                 State is THREE `Double` envelopes and FOUR interpolation
    ///                 accumulators — NOTHING that scales with frame count,
    ///                 channel count or sample rate, which is why `prepare()`
    ///                 allocates nothing and there is no buffer of any kind in
    ///                 the file (the direct consequence of refusing lookahead;
    ///                 `latencySamples` is 0). All THREE envelopes are
    ///                 DENORMAL-FLUSHED per sample (`DelayEffect`'s `1e-20`):
    ///                 each is its own one-pole IIR and each decays into
    ///                 subnormals on silence INDEPENDENTLY. Every field is
    ///                 RE-CLAMPED in the derive — a NaN would reach `pow` and
    ///                 then the interpolation accumulators, silencing the strip
    ///                 permanently (the `stereoWidth.width` precedent)
    ///   freqShifter
    ///                 ZERO transcendentals per DERIVE beyond one `pow` for the
    ///                 output trim. Per SAMPLE and PER CHANNEL: TEN first-order
    ///                 all-pass sections (1 multiply + 2 adds + 4 state moves
    ///                 each) forming the Hilbert pair, then TWO transcendentals
    ///                 — one `cos` and one `sin` for that channel's carrier.
    ///                 ⚠️ The carriers are PER CHANNEL and not shared: the
    ///                 stereo spread is a FREQUENCY difference, so the phase
    ///                 difference between the sides accumulates and cannot be a
    ///                 constant offset off one oscillator. Stereo therefore
    ///                 costs FOUR transcendentals and 20 sections per frame,
    ///                 the most expensive per-sample budget in this file —
    ///                 against `transientShaper`'s three and `compressor`'s two.
    ///                 ⚠️ An operation count, NOT a benchmark. The phase
    ///                 INCREMENT is interpolated per SAMPLE, never on the
    ///                 32-frame stride (`RingModEffect` measured that a stride
    ///                 step in a phase increment is audible). Every section is
    ///                 DENORMAL-FLUSHED individually (`DelayEffect`'s `1e-20`):
    ///                 ten independent IIRs decay into subnormals separately
    ///                 and one flush at the end would leave nine of them
    ///                 subnormal. State is a single `init`-allocated block —
    ///                 nothing scales with frame count, so `prepare()`
    ///                 allocates nothing and `latencySamples` is 0
    ///   clipper       4 `pow` per DERIVE (drive, ceiling, output trim — the
    ///                 third is the mode/factor SNAP, which is integer work
    ///                 through `ClipperParams.mode(at:)` /
    ///                 `oversamplingFactor(at:)` and costs no transcendental).
    ///                 Per BASE sample and PER CHANNEL: `2·L·M` multiply-
    ///                 accumulates for the polyphase up and down stages
    ///                 (`M` = `OversamplerDesign.tapsPerPhase` = 32), i.e. ≈257
    ///                 at 4×, ≈129 at 2× and TWO ARRAY READS at 1× (the kernel
    ///                 degenerates to a pure delay and the MAC loops are
    ///                 skipped — `Oversampler` §5), plus `L` evaluations of
    ///                 `ClipperParams.shaped` (a compare pair, or a multiply
    ///                 triple in soft mode) and ~6 flops of interpolation.
    ///                 ⚠️ An operation count, NOT a benchmark. NO libm in any
    ///                 inner loop: the drive, ceiling, mix and output gains all
    ///                 interpolate as LINEAR values (the `tapeDelay` precedent
    ///                 — interpolate the coefficient, do not re-derive it), and
    ///                 the ceiling is held constant across one base frame's `L`
    ///                 sub-samples so no step ever lands INSIDE the
    ///                 non-linearity. State is FIXED at `prepare()` for
    ///                 `OversamplerDesign.maxFactor`, so an `oversampling`
    ///                 change is an index bound and NOTHING EVER RESIZES; both
    ///                 FIR histories are all-zero filters that cannot generate
    ///                 a denormal of their own, so the flush is applied to what
    ///                 is WRITTEN into them (the `stereoWidth` rule) rather
    ///                 than to a recirculating word. ⚠️ `oversampling` is the
    ///                 one param that CLEARS state (a bounded store, off the
    ///                 inner loop — the `phaser.stages` precedent), which is
    ///                 its second, independent reason for being
    ///                 `Modulatable: refused`. ⛔ The ONLY built-in besides
    ///                 `limiter` with a NON-ZERO `latencySamples`: a CONSTANT
    ///                 32 samples at every factor and every sample rate, by
    ///                 design — see `ClipperEffect` DESIGN §3.
    ///                 ⚠️ "The only built-in besides `limiter`" stopped being
    ///                 true at m39-ad: `saturator` joined, and with a latency
    ///                 that is NOT constant. See its row.
    ///   dynamicEQ     EIGHT `exp` per DERIVE (one attack + one release
    ///                 coefficient per band), NOT cached — the
    ///                 `CompressorEffect` precedent: a ballistics coefficient
    ///                 is cheap enough to recompute and caching it adds a
    ///                 second statement of the same fact. The BIQUAD
    ///                 coefficients ARE cached, on `(freq, Q, sampleRate)` per
    ///                 band, because they cost a `tan` plus a divide chain.
    ///                 ⛔ `mode` is DELIBERATELY NOT in that cache key: it does
    ///                 not enter the section's coefficients, and including it
    ///                 would recompute them on every off↔above↔below move for
    ///                 no arithmetic change. Per SAMPLE and PER ACTIVE BAND:
    ///                 one band-pass biquad step PER CHANNEL (`InlineBiquads`,
    ///                 a fixed-size stack bank reached through a SWITCH, never
    ///                 an array subscript — the `Biquad.swift:80-82` CoW law),
    ///                 then ONE `log10` and ONE `pow` for that band's
    ///                 detector→gain conversion, shared across channels
    ///                 because the detector is STEREO-LINKED. So a 4-band
    ///                 stereo strip costs 8 biquad steps + 8 transcendentals
    ///                 per frame — against `freqShifter`'s 4 and 20.
    ///                 ⚠️ An operation count, NOT a benchmark; the benchmark
    ///                 is `DynamicEQRenderTests` G7 (MEASURED 12.08 % of one
    ///                 core at 48 kHz / 2 ch / 4 bands, debug build — 4.25×
    ///                 `.compressor`). An OFF band is `continue`d before its
    ///                 section is stepped, so the idle default costs nothing.
    ///                 The side-path signal is denormal-guarded AT THE
    ///                 PRODUCER (a non-finite step clears the bank and
    ///                 substitutes 0 before it can reach `abs`/`log10`), and
    ///                 each band's peak follower AND its envelope are flushed
    ///                 independently (`1e-20` on the follower, `1e-10` on the
    ///                 envelope). ⛔⛔ The envelope flush and the attack/release
    ///                 selection are BOTH TWO-SIDED (`abs(env) < 1e-10`,
    ///                 `abs(targetDb) > abs(env)`) — the compressor's one-sided
    ///                 forms at `CompressorEffect.swift:487`/`:489` are correct
    ///                 only because ITS envelope can never be positive, and
    ///                 copying them here snaps every BOOSTING band to zero on
    ///                 every sample. State is FIXED (4 `InlineBiquads` + 4
    ///                 `BandRender` structs, all inline): `prepare()` allocates
    ///                 nothing, nothing scales with frame count, and
    ///                 `latencySamples` is a LITERAL 0 at every setting — there
    ///                 is no lookahead and no buffer in the file. A `mode` slot
    ///                 CLEARS its band's section and envelope, but ON EXIT ONLY
    ///                 (a bounded store off the inner loop — the
    ///                 `phaser.stages` precedent); clearing on ENTRY would
    ///                 restart a band that is already running. All 32 slots are
    ///                 accepted and live (`everySlotIsLive` proves each one
    ///                 moves rendered audio); the guard is
    ///                 `value.isFinite && (0...31).contains(slot)` and every
    ///                 field is RE-CLAMPED in the derive, so no NaN reaches
    ///                 `tan`, `pow`, or an `Int()` conversion
    ///                 (`CompressorEffect.swift:252-255`)
    ///   audioUnit     default no-op below (empty spec surface in v0)
    func storeAutomatedParam(slot: Int, value: Double)

    /// m39-d CR-1 (`docs/design/2026-10-07-effect-control-rate.md` §5.3): the
    /// RENDER-THREAD HOLD. On a strip that runs on the control grid
    /// (`AutomationRenderer.renderChain`), automated params are stored ONCE
    /// per 512-frame cell, at the cell line; every later render call inside
    /// the same cell calls this instead, to say "the values stored at this
    /// cell's entry still stand". Built-ins answer
    /// `adoptPendingParams(); return overlay.hold()`.
    ///
    /// Returns false when a main-actor knob publish was adopted since the last
    /// store (the overlay's `effective` was wiped by `rebase`): the renderer
    /// then RE-ENTERS the cell for this unit (stores again, evaluated at the
    /// same cell line), so a knob turn on an automated effect costs one call,
    /// as it did before the grid. Unit with no automation: never called.
    ///
    /// ⛔ REQUIRED, WITH NO DEFAULT IMPLEMENTATION, DELIBERATELY. A default
    /// would let a kind that forgot it revert to its knobs on 7 of every 8
    /// calls at a 64-frame buffer (`AutomationParamOverlay.endQuantum` reverts
    /// any quantum with no store): a 93.75 Hz chatter that fails silently.
    /// The compiler is the cheapest guard; G4 is the runtime one.
    /// Same RT contract as `process`: no allocation, no lock, no ObjC.
    func holdAutomatedParams() -> Bool

    /// m39-d CR-2 (design §5.4): CONTROL-CELL GEOMETRY. On a strip that runs
    /// on the grid the renderer calls this on EVERY unit of the chain before
    /// EVERY segment it walks (a cell entry, a hold, a split's continuation):
    /// `frames` is the number of frames from the start of the next `process`
    /// call to the next cell line, capped at the offline render's end
    /// (`AutomationSchedule.renderEndFrame`). A unit off the grid never hears
    /// it, and a unit whose last geometry has run out is off the grid again.
    ///
    /// The ten kinds whose de-zipper ramp used to be as long as the render
    /// call (flanger, djFilter, ringMod, hallReverb, tapeDelay, stereoWidth,
    /// phaser, transientShaper, freqShifter, clipper) ramp a new value over the
    /// rest of the CELL instead, carrying progress across calls; the three
    /// with a 32-frame coefficient stride (phaser, djFilter, ringMod) count
    /// that stride from the cell line too. In a 512 bounce the cell IS the
    /// call, so the arithmetic is today's expression, run the same number of
    /// times (G1 byte gate). Every other kind implements it as an explicit
    /// no-op with a one-line reason.
    ///
    /// ⛔ REQUIRED, WITH NO DEFAULT, for the same reason as the hold. Called on
    /// every unit, not only the automated ones, because a coefficient stride
    /// on an UNAUTOMATED phaser is still cut by the split of a strip that
    /// splits for another effect (W9-CR12, CR-0's Phaser finding).
    func beginControlCell(frames: Int)
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
///  · `hold()` (m39-d CR-1) INSTEAD of stores on a call inside a control cell
///    whose values were stored at its entry: it marks the quantum stored, so
///    `endQuantum` keeps `effective`, and returns false when a `rebase` wiped
///    `effective` since the last store, or when nothing stored is in force
///    (`endQuantum` reverted to the knobs, or nothing was ever stored): the
///    renderer then re-stores (m39-d-cr12-hold).
struct AutomationParamOverlay<Params> {
    /// Last MAIN-ACTOR-published params (the knobs).
    private(set) var base: Params
    /// `base` + this quantum's automated stores — what the effect derives from.
    var effective: Params
    private var storedThisQuantum = false
    private var active = false
    /// m39-d CR-1: a main-actor publish was adopted after the last store, so
    /// `effective` holds the knobs, not the cell's automated values.
    private var rebasedSinceStore = false

    init(base: Params) {
        self.base = base
        self.effective = base
    }

    mutating func rebase(_ params: Params) {
        base = params
        effective = params
        rebasedSinceStore = true
    }

    mutating func beginStore() {
        if !storedThisQuantum { effective = base }
        storedThisQuantum = true
        active = true
        rebasedSinceStore = false
    }

    /// m39-d CR-1 (design §5.3): the values stored at this cell's entry still
    /// stand for this quantum. False = they do not (a `rebase` since the last
    /// store, or `!active`: `endQuantum` reverted a quantum that had neither a
    /// store nor a hold, so `effective` holds the knobs, or nothing was ever
    /// stored), and nothing is marked: the caller must store again. Without
    /// the `!active` arm a hold after a revert would keep the KNOBS for the
    /// rest of the cell (RT2 review Q2-c, m39-d-cr12-hold). A 512 bounce never
    /// holds (every call is a cell entry), so no bounce can move.
    mutating func hold() -> Bool {
        if rebasedSinceStore || !active { return false }
        storedThisQuantum = true
        return true
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
