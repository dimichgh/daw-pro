# m23-q Phase 0 / E1 — mid-stream transpose curve: fidelity, alignment, artefacts

**Status:** COMPLETE. Verdict in §0. Every number below was measured on this machine on 2026-08-17 against this tree's vendored signalsmith-stretch v1.3.2 (`57b93f4`). Nothing is derived from the design doc's arithmetic; where a measurement disagrees with the derivation, the measurement is reported and the disagreement is called out.
**Experiment contract:** `docs/research/m23-q-pitch-correction-design.md` §2.4 (E1), read with §2.1–§2.3 and §2.5.
**Scope:** Phase 0 ships nothing user-visible (design §11.2). No wire verb, no MCP tool, no `Clip` field, no `clip.autoCorrectPitch`.
**Code:** `Sources/CSignalsmithStretch/include/csignalsmith_stretch.h` + `shim.cpp` (one accessor), `Sources/DAWEngine/Stretch/OfflineStretcher.swift` (one internal entry point + one measured constant), `Tests/DAWEngineTests/M23QCurveHarness.swift` + `Tests/DAWEngineTests/OfflineStretcherCurveTests.swift` (21 tests — the E1 pass's 20 plus §5.3.1's detector control, added in verification).
**E2 was NOT run** — see §8.

---

## 0. Verdict

# **GO.**

§2.4's kill criterion: *"if E1(b) shows discontinuities above the constant-pitch baseline that a ≤30 ms crossfade cannot hide … the resynthesis pick moves to the §6.5 fallback."*

**There are no discontinuities above the constant-pitch baseline at all.** Broadband energy above 2 kHz — the measure a click cannot hide from — across a 0 → +2 semitone step sits at **−79.68 dB**, against **−79.85 dB** for the same source held constantly at +2 semitones by the shipping path: an excess of **+0.17 dB**. Across five jump sizes from 10 cents to 2 semitones, each against a constant shift of *the same size*, the excess is **+0.29 / +0.88 / −0.12 / −1.76 / +0.16 dB** — noise, and §5.3.1 establishes that word as a measurement rather than a figure of speech: the unplanted floor's own standard deviation across its body is **1.61 dB**, so a +0.17 dB excess is **0.11 sd — indistinguishable from no excess at all**. Nothing needs hiding, so the question of what a 30 ms crossfade can hide does not arise.

⚠️ **The bound this verdict carries, stated up front rather than buried:** §5.3.1's control demonstrates the detector resolves a planted single-sample step of **0.005** (7.15 sd) but **not 0.001** (0.71 sd, below the floor's own wander). So the honest claim is *no discontinuity this instrument can resolve*, with resolution demonstrated down to ≈−44 dBFS relative. Artefacts below that bound are exactly what **E2 — which is UNRUN — exists to catch**, and that is a second independent reason the human leg is not a formality.

The one number in the raw data that reads like a failure is disposed of in §5.2 with arithmetic, not with a change of metric: the peak sample-to-sample difference is 1.040× the constant-pitch baseline and exceeds it over a 44.6 ms span, and at the offending frame the *sine law itself* predicts the observed value to **1.00016**. It is the envelope rippling and the tone sitting a whole tone higher, with nothing left over.

**Two findings the kill criterion does not cover, neither of them fatal, both of which Phase 1 must carry:**
1. **A level dip through the transition**, scaling with jump size: −0.22 dB at 10 cents, −5.11 dB at 2 semitones (§5.3). It is a beat between frames carrying two pitches, it is 10.7 ms wide at −1 dB, and spreading the same 2-semitone move over three hops cuts it to −1.20 dB.
2. **The constant shift we already ship is +5.45 cents sharp at +2 st and +3.95 cents sharp at −2 st**, while 0 st is exact to −0.019 cents (§7). A corrector that trusts the setter inherits that bias. This is a property of the *existing* path, not of the curve.

**Confidence and its limits.** This is a synthetic-signal result: one pure sine, one amplitude, one sample rate, mono. It establishes that the mechanism is sound and quantifies its artefacts. It says nothing about formant wobble, warble or consonant smear on a real voice — that is E2, it is untouched, and it remains the milestone's largest unknown exactly as §11.4 said.

---

## 1. What was built

Additive only. Nothing existing was modified except by addition.

| Thing | Where | Why |
|---|---|---|
| `css_interval_samples` | `Sources/CSignalsmithStretch/include/csignalsmith_stretch.h`, `shim.cpp` | Returns `stft.defaultInterval()`. E1's premise is that the process chunk *is* the analysis hop, so the hop must be **read from the stretcher**, never recomputed as `Int(sampleRate * 0.03)`. |
| `OfflineStretcher.stretchTransposeCurve(…)` | `Sources/DAWEngine/Stretch/OfflineStretcher.swift` | Internal. Takes `curve: [(outputFrame: Int, semitones: Double)]`, calls `css_set_transpose_semitones` between `css_process` calls, chunked at exactly `css_interval_samples`. |
| `OfflineStretcher.measuredCurveLatencyFrames` | same file | The E1(a) result as a named constant, with the measurement and the method in its doc comment. |
| Harness + suite | `Tests/DAWEngineTests/M23QCurveHarness.swift`, `OfflineStretcherCurveTests.swift` | The instrument, positive-controlled; and the E2 comparison-pair renderer. |

**`stretch(…)` is byte-for-byte unchanged.** The curve entry point is a deliberate near-duplicate of its loop rather than a refactor of it, because `stretch` is live in `StretchRenderCache`. §4 is the guard against the two copies drifting.

**`configure` was NOT exposed.** §2.2 scopes that to "if E1(c) shows 30 ms is too coarse" — a conditional follow-on. §6 reports where that condition stands.

### 1.1 A deviation from the brief, stated so it can be objected to

The brief says to FFT with `signalsmith-linear` (vendored, MIT, Accelerate-backed). It is reachable only as C++ headers through `CSignalsmithStretch`, so calling it from Swift would mean a **second C shim** — more product surface than Phase 0 authorises. Under `SIGNALSMITH_USE_ACCELERATE` signalsmith-linear *is* vDSP, and five analyzers in this tree (`MasterMixAnalyzer`, `ReferenceAnalyzer`, `AudioContentAnalyzer`, `TransientAnalyzer`, `TempoEstimator`) already call `vDSP.FFT` directly. The harness therefore uses `vDSP.FFT` with the same idiom. Nothing new is vendored and no module is added. If the brief meant it literally, this is the line to reverse.

---

## 2. The hop, measured

`css_interval_samples` on a `presetDefault` stretcher:

| Sample rate | `css_interval_samples` | `css_input_latency` | `css_output_latency` |
|---|---|---|---|
| 48 000 Hz | **1440** (30.0 ms) | 2880 | 2880 |
| 44 100 Hz | **1323** | — | — |

**§2.2's hop analysis is confirmed.** 1440 at 48 kHz, exactly as derived, and it scales with sample rate. The design's latency derivation is also confirmed at the accessor level: 2880 for each of input and output, i.e. the ≈60 ms §2.3 predicted. What §2.3 could *not* derive — how much of that survives the `outputSeek` recipe — is §3.

This is asserted rather than printed: `hopIsMeasuredNotDerived` fails if it ever stops being 1440, because §2.2's analysis and every number in this document would then be stale.

---

## 3. Leg (d) — determinism and equivalence. **Run and believed first.**

This ran before any other number was looked at, because the curve path processes in 1440-frame chunks where the shipping path uses 4096. If re-chunking perturbed the cumulative `inTarget` arithmetic at `OfflineStretcher.swift:161-164`, every downstream measurement would describe a different render than the one that ships.

| Comparison | Differing samples | Of |
|---|---|---|
| Constant-**zero** curve vs `stretch(ratio: 1, semitones: 0)` | **0** | 144 000 |
| Constant-**+2** curve vs `stretch(ratio: 1, semitones: 2)` | **0** | 144 000 |
| Two runs of the same stepped curve | **0** | 144 000 |
| Constant-**+2** curve at **ratio 1.5** vs `stretch(ratio: 1.5, semitones: 2)` | **0** | 216 000 |
| *Anti-vacuity:* `stretch(0)` vs `stretch(+2)` | **144 000** | 144 000 |

**The re-chunk from 4096 to 1440 is bit-exact.** The constant-nonzero leg is the one that proves it — a multiplier of exactly 1 takes a different branch at `signalsmith-stretch.h:300`, so the zero leg alone would not have caught a re-chunking fault. The anti-vacuity row exists because a comparator that always returned 0 would have passed the first four.

The ratio-1.5 row was expected to *fail*. At ratio 1 both `inTarget = outDone + outBlock` and `inputOffset = round(outputIndex·in/out) = outputIndex` collapse to exact identities whatever the chunk size; at ratio ≠ 1 neither collapses, and finer chunks approximate the global output→input map differently. They nonetheless landed on identical integers, and the render is bit-identical. **Recorded as a measured fact, not as a guarantee** — the test logs the divergence rather than asserting zero, so a future change shows up as a moved number rather than as a surprise.

### 3.1 One chunk-dependence that is real, and why it did not fire

`signalsmith-stretch.h:231-240` sums `totalEnergy` over each call's input and compares it against `noiseFloor` (`:508`, 1e-15); the silence bypass then needs `silenceCounter >= 2*blockSamples` = 11 520 samples, and that counter accumulates in **chunk-sized increments**. The frame at which the bypass engages is therefore genuinely chunk-size dependent. A continuous sine never approaches it. **A real source with a silent passage longer than ~240 ms could diverge between the 4096 and 1440 paths.** Not measured here; flagged for Phase 1.

---

## 4. The instrument, positive-controlled before it was pointed at anything

Every alignment and vibrato number below is a *difference* against these. A 21 ms analysis window and a 30 ms hop produce indistinguishable-looking errors, and without these controls leg (c) would conflate them.

The estimator is a phase-difference (phase-vocoder) instantaneous-frequency tracker: two Hann-windowed 1024-point FFTs 32 samples apart, peak bin inside 150–400 Hz, phase advance unwrapped against the bin's expected advance. Each estimate is attributed to its window's **centre** — attributing it to the window's start would bake a +512-frame bias into every alignment number.

| Control (no stretcher in the loop) | Result |
|---|---|
| Steady 220 Hz | −0.0194 cents |
| Steady 246.94 Hz | −0.0006 cents |
| Hard frequency step at frame 72 000 | f50 bias **−1.22 frames** (−0.025 ms); own 10→90 % width 493 frames (10.3 ms) |
| Synthetic 5 Hz ±50-cent vibrato | fitted depth **49.667 c** of 50; fitted lag **0.0002 frames**; non-sinusoidal residual **0.663 c** |

The −1.22-frame step bias is what proves the centre-frame convention: a start-frame convention would have read ≈ +512.

---

## 5. Leg (b) — the click test

Presented in the order §2.4 asks for: its own metric first, then the decomposition that explains it, then the broadband measure that settles it.

Signal: 3 s of 220 Hz sine at amplitude 0.8, 48 kHz, mono. Step 0 → +2 semitones requested at frame 72 000. Window: the landing ±3/4 hops. **The comparator throughout is the same source rendered at a CONSTANT +2 semitones by the shipping `stretch(…)`** — never the identity render, which is a bypass (its broadband floor is −94.8 dB, 16 dB below anything the stretcher produces when it is actually working, and using it as "the constant-pitch baseline" would manufacture a failure).

### 5.1 §2.4's own metric: peak sample-to-sample difference

| Render | Peak \|Δ\| (whole body) | At frame |
|---|---|---|
| Curve, 0 → +2 | **0.0263992** | 75 877 |
| Constant +2 | 0.0253741 | 41 471 |
| Constant 0 | 0.0230377 | 19 745 |
| *Theory* 2πfA/fs at 246.94 Hz, A = 0.8 | 0.0258597 | — |

Ratio to the constant-+2 baseline: **1.0404** whole-body, **1.0438** in-window. Samples exceeding that baseline: **213, spanning 2143 frames = 44.6 ms** (in-window: 245 samples over 2432 frames = 50.7 ms).

**Taken at face value that reads as a fail.** 44.6 ms > 30 ms, and the criterion's clause is "a ≤30 ms crossfade cannot hide". §5.2 is why it is not one.

### 5.2 Why 1.040 is not a click — evaluated at the offending frame

A peak |Δ| rises whenever the tone gets **louder** or **higher**, and across a 0 → +2 step it does both. The sine law says |Δ|ₘₐₓ = 2πfA/fs. So evaluate it *at frame 75 877 itself*, with the locally measured f and A:

| Render | Local A | Local f0 | Sine law predicts | Observed | **Observed / predicted** |
|---|---|---|---|---|---|
| Curve, at frame 75 877 | 0.81626 | 247.03 Hz | 0.0263949 | 0.0263992 | **1.00016** |
| Constant +2, at frame 41 471 | 0.77823 | 247.62 Hz | 0.0252254 | 0.0253741 | 1.00589 |

**The curve render's worst sample obeys the pure-sine law to 0.016 %** — six times more closely than the constant render's own worst sample does. There is no discontinuity in it. The whole 4.0 % "excess" is: the tone is at 247 Hz instead of 220 Hz, and the envelope is sitting 2 % (+0.17 dB) above nominal at that moment. The 44.6 ms span is the stretch of post-transition output where the envelope ripples above the plateau while the pitch is high — a smooth level movement, not an event.

The intermediate metric that first raised the alarm (peak |Δ| ÷ locally predicted, maximum 1.183 at frame 74 000) is a **transition-region artefact of the instrument**, not of the render: frame 74 000 sits at the 10 % point, where the waveform contains both 220 and 247 Hz and the tracker reads the mixture's frequency as lower than the components that dominate the slope. It is reported here rather than dropped, because it is what motivated §5.2.

### 5.3 Broadband energy above 2 kHz — the measure that settles it

A click is broadband: it puts energy where a 220 Hz sine has none. This is immune to the tone getting louder or higher.

| Render | Body max | In-window max |
|---|---|---|
| Curve, 0 → +2 | −77.95 dB | **−79.68 dB** |
| Constant +2 | −78.36 dB | **−79.85 dB** |
| Constant 0 (bypass; *not* the comparator) | −94.81 dB | −94.81 dB |

**In-window excess: +0.17 dB. Body excess: +0.41 dB.** The step introduces no broadband energy the constant shift does not already produce.

And across jump sizes, each against a constant shift of **the same size**:

| Jump | Beat between the two pitches | Broadband excess | Level dip | (constant baseline dip) |
|---|---|---|---|---|
| 0.10 st (10 c) | 1.27 Hz / 785 ms | **+0.29 dB** | −0.22 dB | −0.02 dB |
| 0.25 st (25 c) | 3.20 Hz / 313 ms | **+0.88 dB** | −0.30 dB | −0.05 dB |
| 0.50 st (50 c) | 6.45 Hz / 155 ms | **−0.12 dB** | −0.77 dB | −0.04 dB |
| 1.00 st (100 c) | 13.08 Hz / 76 ms | **−1.76 dB** | −2.67 dB | −0.04 dB |
| 2.00 st (200 c) | 26.94 Hz / 37 ms | **+0.16 dB** | −5.11 dB | −0.02 dB |
| 2.00 st over 3 hops (90 ms) | — | +2.30 dB | **−1.20 dB** | −0.02 dB |

With formant preservation ON (vocal mode — a different branch at `signalsmith-stretch.h:310`), the 2-semitone step gives dip −5.18 dB and broadband excess **+0.80 dB**. No click there either.

### 5.3.1 THE POSITIVE CONTROL FOR THE DETECTOR ITSELF — added in verification

⚠️ **The section above concludes "no click" from an ABSENCE, and as originally written the detector had never been shown to detect anything.** A blind measure and a working measure return the same "nothing found". This control was added by the orchestrator during verification of the E1 result; the E1 pass did not include one, and until it existed §5.3 was the weakest link in a GO that otherwise rests on measurement.

Method: plant single-sample additive discontinuities of known size into a **real stretcher output** — the constant +2 render, so the reference floor is the true phase-vocoder floor and not the identity bypass — and measure the same `highFrequencyEnergy` in a 4096-frame window around the plant, well away from leg (b)'s transition.

| Planted discontinuity | HF in window | Rise over the unplanted floor |
|---|---|---|
| *(none — the floor)* | −79.06 dB | — |
| **0.001** | −77.91 dB | **+1.15 dB** |
| 0.005 | −67.55 dB | +11.51 dB |
| 0.02 | −55.84 dB | +23.22 dB |
| 0.1 | −41.91 dB | +37.15 dB |

Monotonic across four decades of click size, so the measure tracks the discontinuity rather than firing indiscriminately.

#### The yardstick — and a correction to this section's first draft

⚠️ **A rise is only evidence if it exceeds how much the measure wanders when nothing is happening, and the first draft of this section never measured that.** It read the +1.15 dB from a 0.001 plant against the +0.17 dB of the real render and called the latter "about one seventh" — a ratio quoted as though it were a wide margin. Measured on the same unplanted constant render, across the 506 analysis windows in the body:

| Floor statistic (unplanted constant +2 render, body only) | Value |
|---|---|
| min | −85.91 dB |
| max | −78.36 dB |
| **peak-to-peak** | **7.54 dB** |
| **standard deviation** | **1.61 dB** |

Against that yardstick the readings say something more useful, and more limited, than the first draft claimed:

| Quantity | Rise | In units of the floor's own sd |
|---|---|---|
| Curve render's in-window excess | +0.17 dB | **0.11 sd** |
| Planted 0.001 | +1.15 dB | **0.71 sd** |
| Planted 0.005 | +11.51 dB | **7.15 sd** |

**What this actually establishes.** The curve render's +0.17 dB is **0.11 sd — indistinguishable from no excess at all**. That is the finding, and it is *stronger* than the first draft's framing: there is no measurable excess, not merely a small one. **What it does not establish is the "one seventh" claim.** A planted 0.001 click reads 0.71 sd, which is *below* the floor's own wander, so this instrument cannot reliably resolve a discontinuity that small and leg (b) is not entitled to claim it ruled one out. ⭐ **The detector's demonstrated resolution is 0.005 (7.15 sd), not 0.001.** A single-sample 0.005 step in a 0.8-amplitude signal is ≈−44 dBFS relative — small, but not nothing, and precisely the size of artefact **E2 exists to cover**. This is a second, independent reason the human-listening leg is not a formality.

Guard: `(b) POSITIVE CONTROL: the click detector fires on planted clicks` asserts the 0.1 case rises >6 dB, that the four readings are monotonic, that the floor's sd is non-zero (a constant floor would mean `highFrequencyEnergy` is not reading the signal), and that **the 0.005 plant clears 3 sd** — the resolution claim above is a gate, not a comment. If a future change makes the detector blind or blunt, leg (b)'s verdict fails loudly instead of silently reporting "no click".

### 5.4 The level dip — a finding the criterion does not cover

The dip is the one real artefact E1 found. It is not a discontinuity and the kill criterion does not speak to it, so it is recorded on its own terms rather than pressed into a verdict.

**Depth scales monotonically with jump size** (table above), and the mechanism is visible in the beat column: while the transition is in flight, overlapping synthesis frames carry two different pitches and partially cancel. The cancellation is deep when the transition (≈15 ms, §6) is short relative to the beat period, which is why 2 semitones (37 ms beat) dips 5.1 dB and 10 cents (785 ms beat) dips 0.22 dB.

**Width, 2-semitone case:** 512 frames (**10.7 ms**) below −1 dB, 256 frames (5.3 ms) below −3 dB. The constant-+2 render measures 0 frames at both thresholds.

This corroborates §2.2 note 3 and is exactly what §6.4's design rule anticipated — *"a large instantaneous map jump moves the spectral envelope within one block … an artefact inside a sustained note"*. Two consequences for Phase 1:

- **Correction-sized moves are nearly free.** Auto-tune moves notes by tens of cents; at 25 cents the dip is 0.30 dB.
- **Note-boundary-sized jumps are cheap to mitigate, measured not assumed.** Spreading the same 2-semitone move over three hops (90 ms) takes the dip from −5.11 dB to **−1.20 dB**, at the cost of +2.3 dB of broadband energy (a glide re-maps continuously). The trade is available; picking a point on it is Phase 1's.

---

## 6. Leg (a) — alignment

A curve value handed to `stretchTransposeCurve` for output frame F appears in the delivered output centred **2378.94 frames = 49.56 ms later**, after subtracting the instrument's own −1.22-frame bias. The step was requested at frame 72 000, deliberately **hop-aligned** (50 × 1440), so that quantisation is not smeared into this number.

| | Frames | ms |
|---|---|---|
| **Net offset of the 50 % point** *(instrument bias subtracted)* | **2378.94** | **49.56** |
| Onset (10 %) *(raw, bias not subtracted — it is 1.22 frames)* | 2130.25 | 44.38 |
| Settle (90 %) *(raw, same)* | 2841.87 | 59.21 |
| Transition width (10→90 %) | 711.62 | 14.83 |
| *Instrument's own width on a hard step* | 493.48 | 10.28 |
| `css_output_latency` | 2880 | 60.00 |

**§2.3's derivation is close but not right, and its own caveat is why.** It derived ≈60 ms and flagged that the `outputSeek` recipe might make input and output latency partly cancel. They partly do: the measured figure is **501 frames (10.4 ms) short** of `css_output_latency`. This is exactly the case for measuring rather than reasoning, and the number is now `OfflineStretcher.measuredCurveLatencyFrames = 2379` with the method in its comment. **Nothing compensates for it** — E1 measures the raw path deliberately, and a curve pre-shifted inside the entry point would have made this leg measure its own correction.

**Two terms sit on top of it**, both caller-dependent rather than library-dependent:

1. **Hop quantisation, measured exactly.** The curve is read once per chunk, so a request landing mid-hop waits for the next boundary. Requests at 72 000 / +720 / +1440 landed at 74 377.7 / 75 818.0 / 75 818.0 — the mid-hop request waits, and the wait is **exactly one hop (1440 frames)**, not a fraction of one.
2. **Transition width, 711.6 frames.** Deconvolving the instrument's own 493.5-frame width leaves ≈514 frames (≈10.7 ms) of real ramp. The pitch does not move instantly; a single "the step is at frame X" would overstate the precision available.

**Independent corroboration.** The vibrato leg fits a phase lag to a 5 Hz modulation, sharing no machinery with the step measurement beyond the tracker: 2170.6 / 2285.7 / 2349.0 frames at 1 / 5 / 8 Hz, against the step's 2378.9. A 208-frame (4.3 ms) spread across four independent estimates. The rate dependence within that spread is itself consistent with §5.4's finding that the transition takes time.

---

## 7. Side finding — the constant shift we already ship is sharp

Leg (a) read the render's high plateau as 247.717 Hz where 246.942 was requested. Chasing it to the shipping path:

| Constant request | Expected | Measured | **Error** |
|---|---|---|---|
| 0 st | 220.000 Hz | 219.998 Hz | **−0.019 cents** |
| +2 st | 246.942 Hz | 247.720 Hz | **+5.45 cents** |
| −2 st | 195.998 Hz | 196.445 Hz | **+3.95 cents** |

Reported, not diagnosed — no mechanism was isolated, and Phase 0 is not the place to fix it. Three things follow:

- It is a property of `OfflineStretcher.stretch(…)` **as shipped today**, not of the curve path.
- `OfflineStretcherTests` checks pitch by zero-crossing rate within ±3 % (≈±52 cents) and **cannot see a 5-cent bias**. `constantShiftPitchAccuracy` now measures it in cents and holds it inside ±25.
- **A pitch corrector that trusts the setter inherits this.** Correcting to ±5 cents while the transposer is itself 5 cents off is a closed loop that will not close. Phase 1 either calibrates the setter or measures the render and iterates.

---

## 8. Leg (c) — vibrato resolution, and the correction/shaping split

A 5 Hz ±50-cent contour, supplied as a dense sample-and-hold curve, rendered and tracked. Errors are reported against the instrument's own floor on the same modulation; the fitted numbers use a whole number of modulation cycles, because a partial cycle biases both the amplitude and the phase of a one-bin DFT.

| Rate | Hop updates per cycle | Fitted depth (of 50 c) | Gain, instrument-corrected | Non-sinusoidal residual | (floor) |
|---|---|---|---|---|---|
| 1 Hz | 33.3 | 52.99 c | **1.060** | 3.59 c | 0.66 c |
| 5 Hz | 6.67 | 57.07 c | **1.149** | 3.79 c | 0.66 c |
| 8 Hz | 4.17 | 58.86 c | **1.198** | 8.24 c | 0.66 c |

At 5 Hz, error against the requested contour delayed by the measured latency: RMS **7.49 cents**, max 15.62 cents.

**The error is a depth GAIN, not a loss** — the contour comes back 15 % bigger than asked at 5 Hz, and the gain rises with rate. That is a rate-dependent emphasis of the 30 ms staircase, not a static nonlinearity of the transposer (a static one would have shown the same gain at 1 Hz, and it does not: 1.060 vs 1.198).

**Read on the bar, in words:**

- **For correction: comfortably sufficient.** Auto-tune drives a slow contour — note-rate, not vibrato-rate. At 1 Hz the depth is within 6 % and the non-sinusoidal residual is 3.6 cents, well under the ~5-cent threshold at which pitch error becomes noticeable. 33 hop updates per cycle is dense.
- **For vibrato *shaping*: not dialable.** §2.2 note 4 called 30 ms "marginal for shaping — 5.5 Hz vibrato gets ~6 update points per cycle". The measurement agrees and sharpens it: at 6.67 updates/cycle you get the vibrato, but 15 % deeper than you asked, with 3.8 cents of staircase residue; at 4.17 updates/cycle it is 20 % deep and 8.2 cents. A UI that offers "vibrato depth: 50 cents" and delivers 57 is not a shaping control.

**This is the condition §2.2 attached to `configure`** — *"if E1(c) shows 30 ms is too coarse, `configure(channels, blockSamples, intervalSamples)` buys resolution at roughly linear CPU cost"*. The condition is **met for shaping and not met for correction**. `configure` remains deliberately unexposed: Phase 1 ships correction, and the day a shaping control is designed is the day to spend one additive shim function on it. Naming the follow-on is the whole of the action here.

---

## 9. E2 — NOT run, and the by-product that makes it a render away

E2 is the human listening leg and it was deliberately not attempted. There is no dry vocal in this tree, and `scripts/ace-step/` and `scripts/rvc/` are off limits. **Synthesising a vocal-shaped test signal would have been worse than nothing**: a formant-less sine says nothing about formant wobble, and every artefact E1 found is one a sine can show. Reporting "E1 passed on a sine" as evidence about voices is the specific mistake §4.2 records the M5 decision having already made once, on a polysynth.

The by-product, so E2 is a render and not a rebuild: **`M23QComparisonPair.render(sourceURL:outputDirectory:constantSemitones:curve:formantPreserve:)`** in `Tests/DAWEngineTests/M23QCurveHarness.swift`. It reads any float32 source file, renders it twice from the same input — once with the whole-clip constant shift we ship, once curve-driven — and writes both as WAVs. Test-target only; Phase 0 ships no wire verb. It is exercised by a synthetic round-trip test (`comparisonPairRenders`) so it cannot rot silently before a recording exists.

It already caught one bug in itself: `AVAudioFile.read(into:)` returned a **short read of 95 232 frames of 96 000**, which would have silently truncated the tail of every comparison. It now loops.

---

## 10. What this experiment did NOT establish

In the words the design doc asks for.

- **Perceptual quality on a real voice.** Untouched. E2. The milestone's largest unknown is exactly where §11.4 left it.
- **Anything at a sample rate other than 48 kHz**, other than that the hop scales (1323 at 44.1 kHz). No artefact measurement was repeated at 44.1 kHz.
- **Anything on stereo, or on a source with harmonics, noise or transients.** One mono pure sine at one amplitude.
- **The silence-bypass chunk dependence of §3.1.** Identified in the source and reasoned about; a source with a >240 ms silent passage was never rendered through both chunk sizes.
- **A mechanism for the +5.45-cent constant-shift bias** (§7). Measured, not diagnosed.
- **A mechanism for the 15 % vibrato depth gain** (§8). Its *rate dependence* was measured, which is enough to rule out a static nonlinearity and no more.
- **Whether the ramp mitigation (§5.4) is the right one.** One point on the trade-off was measured. No listening was done, and 3 hops was chosen to be measurable, not because it is correct.
- **Time-varying *time*** (§2.5). Out of E1's scope; the ratio-1.5 leg in §3 touches the loop at non-unity ratio but says nothing about a time *curve*.

---

## 11. Verification

- `./scripts/test.sh` — **6175 tests in 611 suites, 0 ✘** (final run, whole tree, not `--filter`). Baseline before this work was 6154 / 610; the delta is exactly this document's **21 tests in 1 suite** — the E1 pass's 20, plus §5.3.1's detector control added in verification. An intermediate full run at 18 tests read 6172 / 611, which is the same arithmetic before §3's ratio-1.5 leg and §5.3's formant leg were added.
- The `✘` count was positive-controlled: the same grep returns 1 on a planted line and 0 on the log.
- The suite is **not** `@MainActor` — `MainActorOccupancySiteTests` Leg C is at its 330 cadence cap and DSP has no business on the main actor.
- Every rendered assertion is an offline render with a numeric claim. No test asserts that audio "works".
- **Nothing was committed.**
