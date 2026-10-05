# Dynamics, tone-shaping, and character/colour — research sprint

Date: 2026-09-19. Domain: everything in the signal path that isn't EQ-as-filter
or time-based (reverb/delay/chorus) — how loud/soft something is moment to
moment (dynamics), what harmonics get added (saturation/character), and how
tone is reshaped in a level-reactive or vintage-emulating way.

**Scope note.** This sprint does not re-litigate mid/side processing, export
dithering, VCA grouping, or export sample-rate conversion — those are already
filed in `docs/research/2026-08-04-pro-parity-gaps.md` §3.1/3.2/3.5/3.6 and
sit outside this domain except where they interact with dynamics (noted
inline). It also does not re-survey pitch correction as a *tuning* tool — see
`docs/research/m23-q-pitch-correction-survey.md` + `-design.md`; §5 here only
covers pitch correction's use *as an effect* (hard-tune), which that survey
didn't need to cover.

**Correction to the 2026-08-04 audit, since it's cited throughout below:**
that doc's shortlist item #5 ("no parallel-compression mix knob on the built-in
Compressor") **has since shipped** as `CompressorParams.mix` (m23-ck — see
`Sources/DAWCore/Effects.swift:386-409`). Every citation below to that doc's
§3.4 second half is historical, not current. Its §3.3 multiband/dynamic-EQ gap
and §3.4 first-half de-esser gap are both still open and are the best-evidenced
claims in that document — this report builds directly on them rather than
re-researching competitor coverage from scratch.

## 0. What we already have (verified from source, 2026-09-19)

Eleven built-in effect kinds (`EffectDescriptor.Kind`,
`Sources/DAWCore/Effects.swift`): gain (+ polarity invert), 4-band EQ (shelves
+ 2 peaks + HP/LP with 12/24 dB/oct slope, per-band bypass), compressor,
limiter, reverb, delay, saturator, gate, chorus, bass enhancer, bit crusher —
plus a twelfth, hosted-AudioUnit, kind that isn't "built-in" DSP. Everything is
a flat, clamped, `Codable` param struct with a matching `EffectRendering`
class; new fields on existing kinds are additive optionals (`nil` =
pre-existing behaviour, byte-identical decode — the `LimiterParams.truePeak` /
`GainParams.invertPolarity` precedent), and a genuinely new `Kind` needs **no
new wire command and no new MCP tool** — `fx.add`/`fx.setParam`/`fx.describe`
are generic over kind (confirmed by the M38 polarity-invert record, ROADMAP
:3195-3199, which shipped a whole new param with zero new surface).

Specifically relevant to this domain:

- **Compressor** (`CompressorEffect.swift`) is a classic **feedforward**,
  log-domain, quadratic-soft-knee VCA-style design: stereo-linked instant-attack
  peak detector (fixed 5 ms decay) → gain computer → one-pole attack/release
  smoother on the *gain* signal → makeup → parallel dry/wet blend (`mix`,
  shipped m23-ck). Sidechain keying exists (`KeyableEffectRendering`, one key
  per strip, compressor/gate destinations only, audio-track sources only). It
  is **single-band, single-detector, peak-only, feedforward-only** — every
  axis in §2 below is a gap here, and every gap is an *additive* param on a
  design that already has the right shape (log-domain gain computer, already
  supports a key input).
- **Saturator** (`SaturatorEffect.swift`) is tanh waveshaping with **no
  oversampling**, documented candidly in its own header: *"ALIAS HONESTY (v0):
  there is NO oversampling — tanh's odd harmonics above Nyquist fold back...
  Oversampling is an additive internal change behind the same seam."* One
  knob (`driveDb`) plus `mix`/`outputDb`. This is exactly the "one knob of
  drive" gap named in the brief, and the repo has already scoped the fix as
  additive.
- **Bass enhancer** (`BassEnhancerParams`) already reasons about harmonics in
  exactly the vocabulary this report needs: it derives 2nd/3rd/4th-partial
  weights as **Chebyshev polynomial coefficients** (`harmonicWeights`,
  `Effects.swift:800-817`) so a single `amount` knob tilts the generated
  series toward higher partials. This is a direct, shipped precedent for how
  to expose even/odd harmonic balance as one semantic knob rather than N raw
  coefficients (relevant to Saturator v2, §3.2/§11.3).
- **Analysis substrate already shipped, unrelated to any specific effect** —
  this is the foundation §7's "assistant" proposals build on, not new work:
  - `MasterMixAnalyzer` (`Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift`):
    live 24-band log-spaced spectrum (40 Hz–16 kHz), short-term RMS, held
    peak, spectral centroid ("brightness"), spectral flux ("energy movement"),
    and (m22-d) stereo correlation/width/balance. Runs on the master tap by
    default, but **per-insert is also shipped, not just designed**:
    `design-m23r-per-insert-spectrum-tap.md`'s render-safe design (a bounded
    SPSC ring across the render/consumer boundary, FFT on the consumer side,
    never the render thread) is live on the wire today as `fx.spectrum`
    (m23-r4, `Sources/DAWControl/InsertSpectrumLeases.swift`) — a TTL-leased
    (3 s, renewable), capped (N=8 concurrent taps) read of the *same*
    `MasterMixAnalyzer` machinery on any insert, confirmed by grepping
    `Commands.swift`'s `"fx.spectrum"` case (:8658 onward) and the lease
    implementation. "What does the signal hitting THIS effect look like" is
    an existing capability an assistant tool can call today, not a future one.
  - `Loudness.swift`: offline BS.1770-4 integrated/momentary/short-term LUFS,
    true peak (4× oversampled), LRA; `Loudness.Stream` is the live twin, held
    fp-identical by an in-suite convergence gate.
  - `ReferenceAnalyzer` + the m22-g reference-track slot
    (`docs/research/design-m22g-reference-tracks.md`): one-time analysis of an
    imported reference file — integrated/momentary/short-term LUFS, true peak,
    LRA, the *same* 24-band average spectrum, whole-file stereo width — plus a
    **level-match law already shipped** (`ReferenceLevelMatch`, D5 in that
    doc). This is a working target-curve-vs-mix comparator today.
  - `TimbreLiveness.swift`: spectral-centroid-vs-level tracking, built to
    answer "does this instrument's *timbre* move when played harder, or only
    its loudness" — the same psychoacoustic question an exciter/harmonic
    enhancer manipulates, and a plausible input signal for a saturation-amount
    suggestion.
  - `TransientAnalyzer.swift`: **offline-only**, spectral-flux onset detector,
    explicitly documented "never referenced from the render path" (allocates,
    does file I/O). Useful for §5/chop workflows; **not reusable** for a
    real-time transient shaper (see §1.1 — that needs a different, RT-safe
    detector shape entirely, not this one).

## 1. Dynamics beyond the basic compressor

### 1.1 Transient shapers — the highest payoff-per-line-of-code item in this report

A transient shaper is **not** a compressor with different ballistics — it is
**threshold-free and level-independent**, and that's the whole point. SPL's
Transient Designer, the category-defining hardware/plugin, calls its mechanism
**Differential Envelope Technology**: two envelope followers run on the same
signal, one tracking it faithfully (fast) and one deliberately slower; the
**difference** between the two envelopes drives the gain, separately for the
attack phase and the sustain (decay) phase. Because there's no threshold, a
whisper-quiet hit and a fortissimo hit with the same *shape* get treated
identically — "pianissimo to fortissimo... treated the same way." Attack can
be pushed ±15 dB, sustain ±24 dB, and — critically — **the two controls don't
interact**, which is why the interface is famously just two knobs
[SPL Transient Designer manual, ManualsLib](https://www.manualslib.com/manual/652914/Spl-Transient-Designer-9946.html?page=6).

Why this matters for us specifically: our `TransientAnalyzer` is an offline
spectral-flux onset detector used for chop/quantize workflows — it allocates,
does file I/O, and is explicitly barred from the render path. A musical
transient shaper needs a *different*, tiny, RT-safe detector: two one-pole
envelope followers (fast/slow) per shaping stage, a subtraction, a scaled
gain — on the order of the compressor's own detector in code size, with **no
FFT, no lookahead required, no threshold to reason about**. This is a new
capability, not a reuse of existing detection code, and it is DSP-cheap enough
that it's the single best payoff/complexity ratio in this domain.

### 1.2 Multiband compression and OTT

A multiband compressor splits the signal into N frequency bands (crossover
filters), runs an independent compressor per band, and recombines. **OTT**
(Xfer Records) is a specific, extremely well-known preset shape of this
category, not a separate algorithm: it began as a preset named "OTT" for
Ableton Live's stock **Multiband Dynamics** device, built by Claes Johanson
(an Ableton employee) as a mastering preset; Steve Duda (Xfer) reimplemented
it as a free standalone plugin in 2012 for non-Ableton users, and it became
one of the defining sounds of EDM
([MusicRadar: what is OTT compression](https://www.musicradar.com/music-tech/plugins/its-loud-in-your-face-and-got-more-punch-than-a-kangaroo-at-boxing-practice-what-is-ott-compression-and-how-do-you-use-it);
[Bedroom Producers Blog: OTT history](https://bedroomproducersblog.com/2023/07/31/xfer-records-ott-2/)).

OTT's four top-level controls, and precisely why it's so distinctive
([production-expert.com: free OTT plugin](https://www.production-expert.com/production-expert-1/free-plugin-xfer-records-ott);
[mixelite.com: OTT compression guide](https://mixelite.com/blog/ott-compression/)):

- **Depth** — sources describe it as a dry/wet blend between the unprocessed
  and the fully up/down-compressed signal (commonly recommended around
  20–60% rather than 100%, depending on material); the wet path is *both*
  pulling loud transients down (downward compression, the green zone in
  OTT's display) *and* pushing quiet content up (**upward compression**, the
  yellow zone) simultaneously, per band, all the time. (I could not find a
  primary source confirming Depth literally rescales each band's threshold
  internally, as opposed to blending two already-computed signals — treat
  the *blend* mechanism as sourced and drop any threshold-rescaling framing
  as unconfirmed.)
- **Time** — one knob scaling attack/release across all three bands together.
- **In/Out gain** — trim before/after.
- Three bands (low/mid/high) each independently compressible/expandable.

The "OTT sound" is specifically the **combination of upward and downward
compression, per band, always active** — it isn't just "3-band compression,"
it's a 3-band device where *every* band is continuously being pulled toward a
target loudness from both directions, which is why it sounds pumped, dense,
and "hyper-alive" rather than merely "controlled." This is a materially
different (and more work) feature than a standard downward-only multiband
compressor, and worth naming as a distinct roadmap capability rather than
assuming "multiband compressor" automatically covers it.

**Upward compression / upward expansion in general** (not OTT-specific):
raising quiet signal toward a target instead of lowering loud signal — this
is the mechanism, independent of band-splitting, and is the cheapest way to
get "density" without obviously squashing transients. It's a plausible
**additive mode on the existing single-band Compressor** (a signed ratio, or
a second "upward ratio" param) before any multiband work is justified.

### 1.3 Parallel/New York compression

**Already shipped** (`CompressorParams.mix`, m23-ck). No gap here. Worth
noting for completeness: the mechanism (compress a duplicate hard, blend it
under the untouched original) is the classic move that makes drum busses
sound dense without losing transients, and the repo's implementation is
correctly ordered (dry term is the effect's own unprocessed input at the same
sample index, no latency to compensate).

### 1.4 Clippers — soft/hard, and the modern loudness trick

A clipper hard-limits amplitude by **waveshaping**, not gain reduction — it
doesn't turn the signal down ahead of a peak, it truncates (hard) or
compresses (soft) the peak itself, generating harmonic distortion in exchange
for a lower true peak with **no gain-reduction "breathing"** the way a limiter
has. Soft clipping rounds the waveform as it approaches the ceiling (a
continuous nonlinearity, less audible distortion, more "polished"); hard
clipping truncates abruptly at the threshold (audibly distorted, favored for
aggressive genres)
([unison.audio: soft vs hard clipping](https://unison.audio/soft-clipping-vs-hard-clipping/);
[SSG Audio: mastering clipping](https://www.ssg-audio.com/post/mastering-clipping-hard-clipping-vs-soft-clipping)).

**Why clipping before a limiter is the modern loudness trick:** a clipper set
a couple of dB below the final ceiling absorbs the small number of extreme
transient peaks *before* the limiter ever has to react to them, so the
limiter is left doing less gain-reduction work on the bulk of the material —
the loudness gain comes from spending some of the "peak budget" as harmonic
distortion (which the ear tolerates well in small amounts) instead of as
audible limiter pumping. The clipper should sit **before** the limiter in the
chain, clip lightly (roughly 1–2 dB of reduction is the commonly cited
target), and the limiter stays the final brickwall
([Mastering the Mix: how to use a clipper](https://www.masteringthemix.com/blogs/learn/how-to-use-a-clipper-when-mastering)).
We already have a limiter (`LimiterEffect`, 5 ms lookahead, optional true-peak
mode) with no clipper ahead of it — this is a genuinely missing stage in an
otherwise-complete mastering chain, and it's DSP-trivial (a single
nonlinearity, same oversampling questions as saturation — see §12).

### 1.5 De-essers

Mechanically a de-esser is a **frequency-selective compressor**, and there are
exactly two topologies, both of which reuse machinery we already have:

- **Wideband**: detector listens to a filtered (band-passed, ~4–8 kHz) copy of
  the signal, but when it triggers, gain reduction is applied to the **whole**
  signal — i.e. exactly our existing sidechain-keyed Compressor
  (`KeyableEffectRendering`) with the key pre-filtered to the sibilance band.
  Can pump if pushed hard, because non-sibilant content gets ducked too.
- **Split-band**: the signal itself is split (high-pass) into a sibilance band
  and the rest; only the sibilance band is compressed, then recombined — more
  surgical, no volume dip on the rest of the word
  ([unison.audio: de-essing 101](https://unison.audio/de-essing/)).

Given the codebase already has a working sidechain-key compressor and an EQ
with a resonant/adjustable-Q band, a **fixed-topology de-esser as a fifth
Compressor mode** (an internal band-pass detector filter + auto-set frequency
range, split-band recombine) is a small, self-contained addition — matching
the pro-parity audit's own S–M weight estimate for "a fixed-band variant
reusing the existing Compressor ballistics."

### 1.6 Expanders

The textbook relationship: a noise gate and a downward expander are the same
mechanism at different ratios. An expander applies gentle, continuous
attenuation below threshold (commonly 2:1–4:1, gradual), while a gate is the
extreme case (very high ratio, effectively on/off)
([unison.audio: noise gate vs expander](https://unison.audio/noise-gate-vs-expander/)).
Because our `GateParams`/`GateEffect` already has threshold/attack/hold/release
and a gain-computer, **an expander is a ratio parameter added to the existing
Gate**, not a new effect — cheapest item in this whole report.

### 1.7 Dynamic EQ (vs multiband compression — the precise difference)

This is the best-evidenced open competitor gap from the 2026-08-04 audit and
worth stating precisely, because "just add multiband" is not quite the same
feature:

- A **multiband compressor** always splits the signal into fixed bands via
  crossover filters; every band is *always* being processed, and the
  band-split itself colors the sound a little even at rest (phase/crossover
  artifacts) because the signal is always being summed from N filtered paths.
- A **dynamic EQ** does not split the signal at all by default — a band with
  no dynamic engagement is bit-identical to that band being off, like our
  existing EQ's per-band bypass. Each band is a normal parametric EQ band
  (freq/gain/Q, any of our existing filter shapes) whose **gain** is driven
  by its own level detector, so at rest the signal is untouched and only the
  problem moment triggers a (usually narrow) EQ move
  ([iZotope: multiband compressors vs dynamic EQs](https://www.izotope.com/en/learn/multiband-compressors-vs-dynamic-eqs);
  [Black Ghost Audio: the difference](https://www.blackghostaudio.com/blog/the-difference-between-dynamic-eqs-and-multiband-compressors)).

Practically: dynamic EQ is the right tool for "tame this one resonance only
when it's loud" (surgical, narrow Q, transparent at rest); multiband
compression is the right tool for "control the overall balance/density of
three or four broad bands continuously" (mastering glue). **We should build
dynamic EQ first** — it is architecturally a smaller change (reuse the
existing EQ biquad + the existing Compressor gain-computer, wire one band's
gain to the other's detector output; no crossover filter bank, no
recombination-phase concerns) and it directly answers Sound on Sound's cited
example of Cubase's Frequency 2 ("EQ applies progressively after the signal
in that band reaches Threshold" —
[Sound on Sound: Cubase Frequency 2 dynamic filtering](https://www.soundonsound.com/techniques/cubase-managing-low-mids-frequency-2)).
Multiband/OTT-style compression can follow later and share the crossover
infrastructure once it exists.

### 1.8 Envelope/ADSR shapers

Distinct from the transient shaper (§1.1, which is differential/relative):
an ADSR-style module imposes an **absolute** amplitude envelope on
already-recorded material — attack/decay/sustain/release times applied as a
volume contour, most useful on one-shot samples (a plucked or struck sound
reshaped into a pad, or vice versa). Lower priority than §1.1 because it's a
narrower use case (one-shots, not full mixes) but nearly free to add once a
transient shaper's envelope-follower plumbing exists.

### 1.9 Gain-riding / level-automation tools

Waves Vocal Rider is instructive because it's explicitly **not** a compressor:
it reads input level against a target and range, and writes literal fader
automation (their own documentation stresses "all gain changes are done using
a fader rather than a VCA, FET or valve" specifically to avoid adding
coloration) — a Target level, two Range sliders (max boost/cut), and a
Sensitivity control to reject noise between phrases
([Waves Vocal Rider user guide](https://assets.wavescdn.com/pdf/plugins/vocal-rider.pdf);
[Sound on Sound: Waves Vocal Rider review](https://www.soundonsound.com/reviews/waves-vocal-rider)).
This is architecturally **not an audio-domain effect at all** — it's an
analysis pass that emits automation data. That makes it a near-perfect fit
for our MCP/AI-native angle: an agent can already write automation lanes
(the same `AutomationTarget`/slot machinery every effect param uses); a
"vocal rider" is an *analysis tool* that proposes/writes points on the
**track fader's own automation lane**, not a new insert kind. See §7.

## 2. Compressor topologies and their sound

| Topology | Reference unit | Detector point | Character | Worth emulating? |
|---|---|---|---|---|
| **VCA, feedforward** | dbx 160 | Pre-gain-element | Clean, precise, fast, "modern" | This is what we already have. |
| **FET** | 1176 | **Feedback** (grouped by API's own 2500 manual with the API 525/Fairchild 660 feedback lineage — see the Feedback vs feedforward row below, not feedforward as this table's first draft mistakenly said) | Punchy, aggressive; **All-Buttons/"British" mode** pushes all four ratio buttons (4:1/8:1/12:1/20:1) at once, landing the ratio somewhere between 12:1–20:1 while shifting internal bias points so attack *and* release both get faster and less linear — the resulting "lag then snap" on transients plus fast-enough release to audibly distort is the trademark "overdriven" 1176 sound, not a clean higher ratio ([Pulsar Audio: history of All-Buttons-In](https://pulsar.audio/blog/the-history-of-all-buttons-in-mode/); [Sweetwater InSync: All-Button Mode](https://www.sweetwater.com/insync/all-button-mode/)) | Yes — high payoff, and see below: it's one extra param on our existing attack/release model. |
| **Opto (LA-2A-style)** | Teletronix LA-2A | Feedback, via an electro-optical (T4) cell | Smooth, "musical," **program-dependent release**: ~60 ms covers the first 50% of recovery, the remaining slower tail takes 1–15 seconds and *lengthens* the longer/harder the signal was over threshold — the cell itself has memory ([Native Instruments: Fairchild/opto compressors](https://blog.native-instruments.com/fairchild-compressor/); [Universal Audio: LA-2A Collection tips & tricks](https://www.uaudio.com/blogs/ua/la-2a-collection-tips-tricks)) | Yes for vocals/bus glue — but it's a *release curve shape* change, not a new knob; can be a "program-dependent" boolean mode on the existing release model. |
| **Vari-mu / tube** | Fairchild 670 | Feedback, tube gain-reduction element | Very smooth, soft-knee-by-nature, "glues" without obvious artifacts, plus tube/transformer harmonic coloring baked into the gain element itself ([Sound on Sound: Fairchild 660/670](https://www.soundonsound.com/reviews/fairchild-660-670)) | Nice-to-have, lower priority — the harmonic coloring part overlaps with §3's saturator work more than it needs its own compressor topology. |
| **Feedback vs feedforward (general)** | API 2500's switch is the clearest worked example | Feedback = post-gain-element; feedforward = pre-gain-element | API 2500's own manual: "Old" (feedback) mode is smoother, associated with the API 525/1176/Fairchild lineage; "New" (feedforward) is raw, in-your-face, aggressive ([UA/API 2500 manual notes](https://help.uaudio.com/hc/en-us/articles/4419505673620-API-2500-Bus-Compressor-Manual); [Sound on Sound: API 2500 Thrust](https://www.soundonsound.com/sound-advice/q-what-does-api-2500-compressors-thrust-control-do)) | **Cheapest topology win**: our detector already reads either the main signal or a sidechain key at the same code path — reading the key from the *output* buffer instead of the input is a small, self-contained change that exposes a real, audible, well-documented axis. |

**What's worth building, concretely, given our existing feedforward log-domain
design:**
1. **A detector mode switch (peak/RMS)** — today's detector is peak-only with
   a fixed 5 ms decay; RMS detection is the other half of "topology" that
   most hardware/plugin compressors expose and it's a different smoothing
   window on the same detector code path, not a new engine.
2. **A feedback/feedforward toggle** — read the detector from post-gain output
   vs. pre-gain input; both paths already exist in the render loop (this is
   almost exactly what the sidechain-key plumbing does, redirected to the
   effect's own output).
3. **A "character"/topology preset token** (see §8's PRESET classification)
   that bundles ratio/knee/attack/release/detector-mode presets named after
   the archetypes above (FET-punch, opto-smooth, vari-mu-glue) rather than
   modeling the actual nonlinear circuits — cheap, and it's the same
   abstraction Softube/Decapitator already use successfully (§6).
4. **Program-dependent release** (opto-style) as an additive boolean mode:
   release time scales with how long/hard the signal was over threshold,
   rather than being a fixed constant — a release-envelope shape change, not
   a new detector.

None of these require touching the gain computer's core log-domain math; all
four are additive parameters on the exact same class.

## 3. Saturation and distortion flavours

### 3.1 The flavour families, what defines each, and who's the reference

- **Tube/triode**: predominantly even-harmonic-biased soft clipping (a
  gently-asymmetric transfer curve), warm/smooth character. Both Decapitator's
  "T" (Thermionic Culture Vulture, triode mode) and Softube's whole product
  line trade on this.
- **Tape**: soft saturation **plus** three distinct extra mechanisms —
  **hysteresis** (the medium's magnetization lags the input, a genuine
  memory effect, not a memoryless waveshaper), a high-frequency **bias**
  signal (100 kHz+) that linearizes the recording process and itself
  interacts with saturation, and **wow/flutter** (periodic ± pitch/speed
  wobble from the transport, generally modeled as slow LFO-ish delay
  modulation) ([DAFx19: real-time physical modelling for tape](https://www.dafx.de/paper-archive/2019/DAFx2019_paper_3.pdf)).
  A convincing tape emulation is therefore **not just a waveshaper** — it
  needs a state-carrying (hysteresis) nonlinearity plus a modulation layer,
  meaningfully more DSP than tube/transistor saturation.
- **Transformer**: saturates at low frequencies specifically (core saturation
  is level- and frequency-dependent, worse at low Hz/high level) — commonly
  approximated as a saturator with a built-in low-shelf-weighted drive curve.
- **Transistor**: favors **odd** harmonics when overdriven, generally a
  harder/more symmetric clipping curve than tube.
- **Diode clipping**: hard, often asymmetric (different diodes/forward
  voltages each direction), classic "fuzz" character.
- **Wavefolding**: categorically different from clipping — instead of
  truncating the signal at a threshold, the waveform **reflects/mirrors**
  back down once it crosses the threshold rather than flattening, producing
  a much richer, brighter harmonic series that keeps changing shape (folding
  again) as drive increases — a *synthesis* tool as much as a color tool
  ([daudio.dev: waveshapers vs wavefolders](https://daudio.dev/explore/WaveshaperVSWavefolder)).
  Wavefolding is squarely `distortion synthesis` → `waveshaping` →
  `wavefolding` as a taxonomy, per Wikipedia's own distortion-synthesis
  article — wavefolding is the most "generative" and requires the most
  oversampling headroom of anything in this list (§12).

### 3.2 Asymmetry and even vs. odd harmonics — why it matters musically

A **symmetric** nonlinearity (our current `tanh`) generates **odd** harmonics
only (3rd, 5th, 7th...). An **asymmetric** curve (a DC bias before the
shaper, or an inherently asymmetric curve like a single diode or a tube
biased off-center) additionally generates **even** harmonics (2nd, 4th...),
including — critically — the octave.

The folklore claim ("even = warm, odd = harsh") has a real acoustic basis, not
just superstition: the 2nd harmonic is a perfect octave and reads as *part of*
the note (consonant by construction), while odd harmonics like the 3rd/5th
land on intervals that are **dissonant relative to tempered tuning** — a 3rd
harmonic is a 12th above the root, close to but not exactly a tempered fifth,
so it beats against the scale rather than reinforcing it
([Kiive Audio: even vs odd harmonics](https://www.kiiveaudio.com/blogs/learn/understanding-even-and-odd-harmonics-in-music-production);
[PS Audio: odd or even](https://www.psaudio.com/blogs/pauls-posts/odd-even)).
Tubes push toward even by nature of their transfer curve; transistors push
toward odd. This is exactly the axis our `BassEnhancerParams.harmonicWeights`
already models for a *different* effect (Chebyshev T2/T3/T4 weighting) — the
same idea (a single `asymmetry` scalar controlling the even/odd balance)
belongs on the saturator.

### 3.3 Oversampling requirements — how much, for which family

See §12 for the full budget; short version: gentle/soft saturators (tanh-style,
tube-style) need the least (2×–4×, and antiderivative techniques get
comparable quality at even less); hard clipping needs more (the harmonic
series decays much more slowly, ~1/n vs. tanh's much faster roll-off);
wavefolders need the most (their harmonic content is the richest and keeps
regenerating as drive increases) — commonly cited at 4×, with 8× as the "safe"
figure
([Medium/jatinchowdhury18: wavefolding](https://jatinchowdhury18.medium.com/complex-nonlinearities-episode-6-wavefolding-9529b5fe4102)).

### 3.4 Soft-clip vs. hard-clip, and per-band/multiband saturation

Same distinction as §1.4's clipper, but as a *color* tool rather than a
loudness tool: soft-clip curve families (tanh, arctan, cubic) round the knee
continuously and are the "safe default" for a general-purpose saturator (what
we already have); hard-clip is a harder, more aggressive edge case, useful as
one end of a `hardness`/`character` continuum rather than a separate effect.
**Per-band/multiband saturation** (different drive per frequency band — e.g.
heavier saturation only on the low end to add weight without smearing highs)
is a real, higher-tier feature but depends on the crossover-filter
infrastructure that a multiband compressor would also need (§1.2/§1.7) — not
worth building standalone before that infrastructure exists.

## 4. Tone shaping

### 4.1 Dynamic EQ — covered in §1.7 (it's dynamics *and* tone-shaping by
construction; not repeated here).

### 4.2 Tilt EQ

A tilt EQ has one pivot frequency and one knob: above the pivot, gain moves
one way; below it, gain moves the opposite way, by the same amount, as a
continuous "see-saw" — brightening/thinning or darkening/thickening the
**whole spectral balance** without the discontinuity a shelf-pair would
introduce ([Full Compass: what's a tilt EQ response](https://www.fullcompass.com/gearcast/whats-a-tilt-eq-response);
[production-expert.com: why tilt EQ is your friend](https://www.production-expert.com/production-expert-1/why-tilt-eq-is-your-friend)).
FabFilter Pro-Q 3/4 ships this as a literal "Flat Tilt" band shape rotating
the whole spectrum about a fixed point
([Sound on Sound: Pro-Q 3 review](https://www.soundonsound.com/reviews/fabfilter-pro-q-3)).
This is **cheap for us**: our existing 4-band EQ already has a low shelf and
a high shelf; a tilt mode is a coupled-gain relationship between them (one
knob drives both shelves with opposite sign around a shared pivot) rather
than new filter math — essentially a UI/param-surface feature over existing
DSP.

### 4.3 Resonant/analog-modelled filters vs. clean digital

Not separately researched in depth here (out of scope vs. dynamics/character,
and our EQ already supports resonant Q up to 18 on its peak bands) — flagged
only as: modeling a specific analog filter's *nonlinear* self-oscillation/
saturation-at-resonance behavior (as opposed to a clean biquad at high Q) is
its own small oversampling-adjacent research question, likely folds into the
saturator/EQ character work in §12 rather than needing a separate spike.

### 4.4 Vintage EQ curve emulation — the Pultec trick, and API/Neve character

The **Pultec EQP-1A low-end trick**: set Boost and Attenuation to the *same*
low frequency (60 or 100 Hz is typical) and dial in both simultaneously. On
real Pultec hardware this doesn't cancel, because the boost shelf's passive
LC circuit reaches slightly lower in frequency than the cut shelf does — the
overlap produces a **lift right at the very bottom plus a scoop in the muddy
low-mids just above it**, i.e. more weight/thump *and* more clarity/tightness
from the same two controls at once, a combination a naive parametric EQ
literally cannot produce with a single band
([Universal Audio: Pultec tips & tricks](https://www.uaudio.com/blogs/ua/pultec-collection-tips-and-tricks);
[MusicRadar: producer's guide to the Pultec EQP-1](https://www.musicradar.com/news/producers-guide-pultec-eqp-1a)).
Reproducing this **requires modeling the actual non-coincident boost/cut
curves**, not just letting a user set two overlapping shelves on a generic
EQ (which *would* cancel, or nearly so, on our current linear EQ) — this is a
specific, well-documented, low-complexity curve-shape addition (a fixed
offset between the two shelf center frequencies, baked into a "Pultec low"
mode) rather than a generic modeling project.

**API/Neve character**, more impressionistically: Neve reads as midrange
thickness + a polished high end (associated with its transformer-coupled
gain stages); API reads as energetic punch with added harmonic detail
especially in the mids (associated with its discrete Class-A "2520" op-amp
and proportional-Q EQ). Neither claim is as concretely reproducible as the
Pultec trick from what's publicly documented (search results here were
comparative/impressionistic, not curve specifications) — treat as directional
flavor-naming for a preset token (§8), not a modeling target.

### 4.5 Exciters/harmonic enhancers — how they differ from saturation

An exciter is architecturally: **high-pass filter → saturator/clipper on just
that high band → re-add** (parallel, mixed back under the original), plus —
in the original Aphex Aural Exciter specifically — a deliberate **phase
shift** on the added content. The distinguishing claims from actual sources:
"a saturator is a low-level distortion while an exciter is the same process
applied only to the high frequencies," and the Aphex device specifically
"extends the high frequencies, unlike EQs and other brightness enhancers
which only boost highs and alter overall tonal balance" — i.e. it *adds new
harmonic content above* what's already there rather than just amplifying
existing high-frequency energy the way an EQ boost does
([Wikipedia: Exciter (effect)](https://en.wikipedia.org/wiki/Exciter_(effect));
[masteringbox.com: aural exciters](https://www.masteringbox.com/learn/aural-exciter)).
Practically: **this is our existing Saturator, band-limited by a fixed
high-pass ahead of it, mixed in parallel** — cheap once Saturator v2 (§11.3)
exists, essentially a preset/config of it rather than a new DSP unit.

### 4.6 Psychoacoustic bass enhancement — we already have this

`BassEnhancerParams` (§0) is a real, working RBass/MaxxBass-class "missing
fundamental" enhancer — no gap to fill here; noted only because §3.2's
asymmetry work and this effect's harmonic-weight math are the same idea and
should probably share a helper rather than duplicate the Chebyshev-weight
formula.

## 5. Vocal-specific chain tools

- **De-esser** — covered in §1.5.
- **Formant shift**: naive pitch shifting moves the resonant peaks (formants)
  that define vowel/timbre identity along with the pitch, which is what
  produces the "chipmunk" artifact; a formant-aware algorithm shifts pitch
  while holding the spectral envelope roughly fixed, so the voice's
  perceived size/character survives a pitch move
  ([Antares: pitch correction complete guide](https://www.antarestech.com/blog/pitch-correction-the-complete-guide-to-tuning-vocals)).
  Relevant to us wherever pitch-shifting already exists (voice conversion,
  pitch correction) as an *additional control*, not a new effect kind.
- **Pitch correction as an effect (hard-tune)**: the distinguishing parameter
  is **retune speed** — near 0 ms snaps instantly to the nearest scale tone
  (the recognizable "Auto-Tune effect," used deliberately as a stylistic
  distortion of the voice into a quantized instrument), while 25–80 ms lets
  natural pitch drift survive and reads as corrective rather than stylistic
  ([Orphiq: what is Autotune, retune speed](https://orphiq.com/resources/what-is-autotune)).
  Our own pitch-correction survey/design docs (`m23-q-pitch-correction-*`)
  already own the tuning use case; this note is just that "hard-tune" is the
  *same engine at retune speed ≈ 0*, i.e. it should be a parameter of
  whatever ships from that spike, not a second feature.
- **Doubler/thickener**: mechanically, short (commonly cited starting point
  ~<30 ms, under the Haas fusion threshold so it reads as one wider event
  rather than a discrete echo) delays panned hard left/right, each detuned a
  few cents in opposite directions (~−15 to −30 cents is a commonly cited
  starting point), sometimes with LFO-modulated delay time for a natural
  "can't quite lock" waver. Soundtoys MicroShift explicitly models this on
  the Eventide H3000/AMS DMX lineage; Waves Doubler's differentiator is
  pitch-shifting *without* changing duration
  ([Waves Doubler manual](https://www.waves.com/1lib/pdf/plugins/doubler.pdf);
  [Sound on Sound: double-tracking vocals](https://www.soundonsound.com/techniques/double-tracking-vocals)).
  Self-contained, reuses whatever delay-line + pitch-shift primitives already
  exist in the engine (our `DelayEffect` + the time-stretch/pitch library
  already evaluated in `2026-07-05-time-stretch-library-evaluation.md`).
- **Vocal rider** — covered in §1.9 (an automation-writing analysis tool, not
  an audio-domain effect).
- **Proximity/plosive control**: proximity effect itself (bass boost from
  close-micing a directional mic) is a *recording*-stage phenomenon, not
  something to emulate in software beyond "a low-shelf cut." Plosive control
  is the software-tractable half: iZotope RX's De-plosive module detects
  transient bursts specifically in a narrow **20–80 Hz** band (below the
  vocal fundamental for most voices) and reduces just that burst, preserving
  the vowel's own low-frequency content — parameters are Sensitivity
  (detection threshold) and Strength (how much reduction), plus a frequency
  ceiling for what counts as "plosive band"
  ([iZotope: RX De-plosive](https://www.izotope.com/en/products/rx/features/de-plosive.html)).
  Mechanically this is **a transient-triggered dynamic low-band gate** — i.e.
  our differential-envelope transient detector (§1.1) plus a fixed low-band
  filter, largely free once the transient shaper exists.

## 6. Product study

| Product | Category | What's actually novel about it |
|---|---|---|
| **FabFilter Pro-Q 3/4** | Dynamic EQ | Up to 24 bands, 8 shapes, per-band Linear/Natural Phase, per-band M/S, a spectrum analyzer widely considered best-in-class, and (Pro-Q 3+) dynamic bands where attack/release/ratio are **fully automatic by default** — the user sets threshold (or leaves it automatic too) and a target range, and the plugin's own detector picks ballistics. Pro-Q 4 (current, 2026) adds "Spectral Dynamics" and "EQ Sketch" ([FabFilter Pro-Q 3 release notes](https://www.fabfilter.com/news/1543478400/fabfilter-releases-fabfilter-pro-q-3-equalizer-plug-in-with-dynamic-eq); confirm Pro-Q 4 specifics against fabfilter.com before quoting further — sourced from a 2026 roundup, not FabFilter's own page, in this pass). |
| **FabFilter Pro-MB** | Multiband dynamics | Unlimited bands via adjustable crossovers, each band independently a full compressor/expander with its own detection and (Pro-MB specifically) an external sidechain per band — the "one plugin covers both OTT-style multiband *and* per-band de-essing" positioning. |
| **iZotope Ozone / Neutron** | Mastering / mixing suite + **assistants** | See §7 — the assistant technology is the relevant part for us, not the DSP (which is competent but not novel). |
| **Soundtoys Decapitator** | Saturation | Five **named hardware-modeled flavours** on one selector, each a real, specific unit: **A** = Ampex 350 tube tape recorder, **E** = Chandler/EMI TG Channel, **N** = Neve 1057 input channel, **T** = Thermionic Culture Vulture in **triode** mode (even-harmonic-biased), **P** = the same Vulture in **pentode** mode (odd-harmonic-biased) — engineered by measuring the real hardware's harmonic structure, frequency response, and dynamic response under drive ([Soundtoys Decapitator manual](https://www.soundtoys.com/wp-content/uploads/Decapitator-Manual.pdf)). This A/E/N/T/P selector is the direct model for our proposed Saturator `flavor` token (§11.3). |
| **Soundtoys Radiator** | Saturation (tube amp modeled) | Not independently researched this pass beyond Decapitator; same family, lower priority to study separately. |
| **Waves CLA-76 / CLA-2A / API 2500** | Compressor modeling | CLA-76 = 1176-style FET, two named hardware revisions ("Blue Stripe"/"Blackface"), sub-microsecond attack, modeled preamp distortion baked in — used for aggressive drum/vocal smash. CLA-2A = LA-2A-style opto, slow/gentle/warm, vocals/bass/acoustic. API 2500 = the feedback/feedforward (§2) reference implementation, plus the patented **Thrust** control (Normal/Medium/Loud) which EQs the sidechain to reduce low-frequency triggering — "Loud" adds +3 dB/octave to the sidechain, the inverse of pink noise's rolloff, so the detector is deliberately less sensitive to bass and the compressor "breathes" less on kick/bass-heavy material ([Sound on Sound: API 2500 Thrust](https://www.soundonsound.com/sound-advice/q-what-does-api-2500-compressors-thrust-control-do)). Thrust is a clean, well-specified extra param worth stealing directly: a sidechain-detector tilt-EQ knob. |
| **Xfer OTT** | Multiband up/down compression | Covered in full in §1.2. |
| **Softube Saturation Knob** | Saturation | Three modes — **Keep High** (distorts low end more, keeps highs relatively clean), **Neutral** (balanced), **Keep Low** (low-order distortion, e.g. squash a drum loop while keeping the kick's fundamental intact) — one knob for drive, one selector for character; the single cleanest existing example of exposing harmonic *shape* as a 3-way token rather than a technical parameter ([Softube Saturation Knob](https://www.softube.com/us/plug-ins/saturation-knob)). |
| **Kush Clariphonic** | Character EQ | Boost-only parallel shelving EQ, deliberately no cut/no filters — the whole design is "you can't make it worse," a genuinely different interaction model from a corrective parametric EQ ([Sound on Sound: Kush Clariphonic](https://www.soundonsound.com/reviews/kush-audio-clariphonic)). |
| **Pulsar 8200** | Character EQ | Modeled on the GML 8200, adds "Air" and "Sub" bands built as parallel *passive-style* shelves specifically so extreme boosts don't add mud/harshness the way a resonant active shelf would — same design lineage as the Pultec trick (§4.4): passive-style parallel topology as the source of the "can't-mess-it-up" character. |
| **SPL Transient Designer** | Transient shaping | Covered in full in §1.1 — its two-knob (Attack/Sustain) interface, with **no threshold at all**, is the cleanest existing example in this whole survey of collapsing a real DSP mechanism into an interface an LLM (or a novice) can reason about with zero domain math. |
| **Oeksound Soothe (2/3)** | Resonance suppression | A genuinely distinct category from both static EQ and dynamic EQ: a **spectral engine computing hundreds of simultaneous dynamic micro-notches** across the whole spectrum in real time, each independently growing/shrinking/moving as the input's actual resonances move (Soothe3 explicitly tracks moving pitches/overtones, not fixed bins). One **Sharpness** dial trades "broad and smooth" for "narrow, surgical, no crossover between adjacent resonances" ([oeksound soothe2 manual](https://oeksound.com/manuals/soothe2/); [Sound on Sound: Soothe review](https://www.soundonsound.com/reviews/oeksound-soothe)). This is meaningfully harder than anything else in this report (real-time per-bin/per-partial dynamic tracking, not a handful of bands) — flagged as an L-complexity future item, not a near-term one. |

## 7. "Assistant"/analysis features

### 7.1 What the established products actually measure and map

| Product | What it measures | What it maps to |
|---|---|---|
| **Ozone Master Assistant** | ~30 s of the loudest section (chorus recommended); builds a custom preset by comparison against a large corpus of professional masters | EQ tilt/balance, Maximizer (limiter) threshold set to hit the loudest output without excessive triggering, Dynamics attack/release, IRC (limiter algorithm) mode — some params are learned from the input, others (like IRC mode) are set by rule rather than analysis ([iZotope: Master Assistant technology](https://www.izotope.com/en/learn/behind-the-technology-of-mix-assistant.html); [Ozone 8 Master Assistant docs](https://downloads.izotope.com/docs/ozone8/master-assistant/index.html)). |
| **Neutron Track Assistant** | Auto-detects instrument type (or user picks it); user selects descriptive adjectives ("warm," "bright," etc.) | Generates EQ correction for resonances/harshness + compression settings for dynamic-range problems, keyed off the detected instrument + chosen adjectives ([iZotope: meet the assistants](https://www.izotope.com/en/learn/meet-the-izotope-assistants.html)). |
| **Neutron Mix Assistant** | Groups tracks into logical buckets (voice/bass/percussion/musical/user focus) during analysis | Broad-stroke level/balance suggestions per bucket, refined from there. |
| **sonible smart:EQ** | Per-source spectral profile (instrument/vocal/genre profiles) | An EQ correction curve targeted at that profile's expected spectral shape. |
| **sonible smart:comp** | "Spectro-dynamics" — up to 2000-band spectral analysis, source-adaptive profiles | Multiband-equivalent tonal smoothing/balancing without exposing band controls directly to the user. |
| **Soundtheory Gullfoss** | "Computational auditory perception" — continuously listens for frequency regions that are masking/competing with each other | Real-time automatic EQ moves (5 user controls total) that declutter the mix without the user choosing bands at all. |

### 7.2 The mappings well-established enough to implement, mapped onto what we
already measure (§0)

We do not need new DSP to prototype most of this — we need to **expose the
analysis we already compute** through an MCP tool the agent can call before
it decides what `fx.setParam` calls to make:

| Established mapping | Our existing measurement | Suggested action |
|---|---|---|
| Integrated LUFS vs. a delivery target (e.g. −14 LUFS streaming) | `Loudness.measure`/`Loudness.Stream` | Suggested `gain.gainLinear` or `limiter.ceilingDb` — this is *exactly* what `GainParams.gainRange` was widened for (m27-c, "the ceiling could not lift GM-sourced material to a streaming level in one stage" — Effects.swift:130-144) — the widening already anticipated this use case, only the suggestion tool is missing. |
| Crest factor / peak-to-loudness ratio | Derivable from `Loudness` (peak) + integrated LUFS, both already computed | Compressor threshold/ratio starting point — high crest factor (lots of headroom) tolerates a lower threshold/higher ratio; low crest factor (already dense) suggests leaving it alone. |
| True peak vs. 0 dBTP margin | `LimiterParams.truePeak` mode, `Loudness`'s 4× oversampled true-peak measurement | Suggest enabling true-peak mode and/or inserting a clipper (§1.4) ahead of the limiter when true peak is riding close to the ceiling under sample-peak mode. |
| Spectral balance vs. a target/genre curve | `MasterMixAnalyzer`'s 24-band spectrum, or the **already-shipped** `ReferenceAnalyzer` target-matching (m22-g) | Tilt EQ (§4.2) or shelf suggestion — literally the same mechanism as `ReferenceLevelMatch`'s gain law, extended from "match loudness" to "match spectral tilt." |
| Narrow, persistent spectral peaks held over time | Would need a *new* small measurement: track each of the 24 bands' held-peak-vs-median ratio over a window — a lighter-weight cousin of what Soothe (§6) does, not full per-partial tracking | Dynamic-EQ cut suggestion (§1.7) at the offending band — the Soothe-class "assistant," cheap version. |
| 5–10 kHz energy ratio spikes on a vocal track | 24-band spectrum already covers this range; needs per-track (not just master) analysis, which the **shipped** per-insert spectrum tap (`fx.spectrum`, m23-r4) already provides | De-esser threshold/frequency suggestion (§1.5). |
| Tempo | `TempoEstimator`/`TempoMap` (already shipped, used for delay sync m22-f) | Compressor attack/release starting defaults — faster tempo tolerates faster release without obvious pumping; this is a cheap, already-available signal nobody's using for dynamics defaults yet. |
| Spectral-centroid movement under level | `TimbreLiveness.swift` (m31-f, built for a different purpose — "is this instrument's timbre static") | A very rough proxy for "how much would saturation/exciter help" — a source whose centroid barely moves under level changes is a candidate for the exciter treatment (§4.5); speculative, lowest-confidence mapping in this table, flag as such if built. |

### 7.3 The AI-native framing that's actually a structural advantage

iZotope/Sonible ship an "Assistant" because **their host isn't AI-controllable**
— the assistant has to be a black box that both decides *and* applies, because
there's no other way for a human to get from "listen once" to "reasonable
starting point" without thirty knobs in between. We don't have that problem:
the actual intelligence (the calling agent) is already outside the DAW,
already has tool-call access to every `fx.*` command, and can already reason
in natural language about tradeoffs. **The only thing we're missing is the
measurement, packaged for the agent to read** — not a decision-making
black box. A `mixer.suggestChain` (or similarly-named) MCP tool that returns
the *measurements* (LUFS, crest factor, 24-band spectrum delta vs. a
reference/genre target, true-peak margin) plus **plain suggested
parameter values with the reasoning stated**, letting the agent decide
whether/how to apply them via the existing `fx.add`/`fx.setParam` calls it
already has, is strictly more transparent and more steerable than any
competitor's "Apply" button — and it's nearly all analysis-layer work
reusing `Loudness`/`MasterMixAnalyzer`/`ReferenceAnalyzer`, not new DSP.

## 8. Definitions used in the gap table below — how would an LLM drive this?

Grounded in the actual wire surface (`Sources/DAWControl/Commands.swift`,
`Sources/DAWCore/Effects.swift`'s `EffectParamSpec`), not a hypothetical one:

- **PARAM** — a flat numeric field on the effect's param struct, reachable
  today via `fx.setParam` / described via `fx.describe` / an MCP tool
  argument, exactly like `driveDb` or `thresholdDb` today. The right choice
  whenever the control is continuous and independently meaningful.
- **MODULATOR** — a PARAM that is *also* exposed on the per-effect automation
  slot surface (`storeAutomatedParam`, the same mechanism every existing knob
  already rides), so an agent can write a **time-varying curve** against it —
  e.g. riding a transient shaper's `sustainDb` up across a build, or a
  compressor's `thresholdDb` down into a chorus. Every numeric PARAM in this
  codebase is *already* a potential MODULATOR by construction (automation
  lanes are generic over slot index); it's called out separately in the gap
  table only where time-variation is the point of the feature, not an
  afterthought (gain-riding, sidechain ducking shape, an evolving transient
  emphasis).
- **PRESET** — a single named/numeric-snapped token that sets several
  underlying params atomically from one semantic word (the repo already has
  this exact pattern: `BitCrusherParams` numeric-snapped `bits`,
  `DelayParams.pingPong` snapped 0/1, `NoteDivision`'s string-token-on-disk/
  numeric-on-wire precedent). Right choice when (a) the underlying params
  don't mean much individually to non-experts — "more tube-like" is
  reasonable for an LLM to say, "increase 2nd-harmonic Chebyshev weight by
  0.15" is not — or (b) internal consistency across several params matters
  more than granular control (Decapitator's A/E/N/T/P, Softube's
  Keep-High/Neutral/Keep-Low).

## 9. Gap table

| Feature | Known for | Musical payoff | DSP complexity | Oversampling? | LLM control |
|---|---|---|---|---|---|
| Transient shaper (differential envelope) | SPL Transient Designer | **High** | **Low** — two envelope followers + subtract, no FFT, no threshold | No | PARAM (`attackDb`, `sustainDb`, `mix`) + MODULATOR (ride sustain across a build) + PRESET ("punchy," "glue") |
| Clipper (pre-limiter) | Every modern loudness chain | **High** | **Low** — one nonlinearity | Yes — see §9.1 below | PARAM (`ceilingDb`, `hardness`) + PRESET (soft/hard) |
| Saturator v2: oversampling + asymmetry + flavour | Soundtoys Decapitator, Softube Saturation Knob | **High** | **Medium** — additive optionals on a shipped effect | Yes — the effect's own header already flags this as owed | PARAM (`driveDb` today; `asymmetry` new) + PRESET (`flavor` token, A/E/N/T/P-style) |
| De-esser (Compressor mode) | Logic DeEsser 2, FabFilter Pro-DS | **High** (near-universal vocal-chain need) | **Low–Medium** — reuses Compressor detector + sidechain plumbing | No | PARAM (`frequencyHz`, `thresholdDb`, `splitBand: Bool`) |
| Expander (Gate mode) | Every console dynamics section | Medium | **Trivial** — one ratio param on the existing Gate | No | PARAM (`ratio`) |
| "Assistant" measurement tool | Ozone/Neutron/Sonible/Gullfoss | **High** (unique AI-native angle) | **Low** — reuses shipped `Loudness`/`MasterMixAnalyzer`/`ReferenceAnalyzer` | No | Not an effect param at all — an MCP tool returning measurements + suggested `fx.setParam` calls for the agent to issue |
| Dynamic EQ (new band type) | FabFilter Pro-Q 3/4, Cubase Frequency 2 | **High** (best-evidenced competitor gap, pro-parity-gaps §3.3) | **Medium** — reuses EQ biquads + Compressor gain computer, no crossover filters needed | No | PARAM per band (`thresholdDb`, `ratio`, `attackMs`, `releaseMs` alongside the existing freq/gain/Q) |
| Tilt EQ | Neve/API mastering chains, FabFilter "Flat Tilt" | Medium | **Low** — coupled-gain relationship over existing shelves | No | PARAM (`tiltAmount`, `pivotHz`) |
| Pultec-trick low-shelf mode | Pultec EQP-1A | Medium (niche but iconic) | **Low** — fixed frequency offset between a boost/cut shelf pair | No | PRESET ("Pultec low") + PARAM (boost/cut amounts) |
| Compressor: RMS detector mode | Most hardware/plugin compressors | Medium | **Low** — alternate smoothing window on the existing detector | No | PARAM (`detectorMode`: numeric-snapped peak/RMS) |
| Compressor: feedback/feedforward switch | API 2500 | Medium | **Low** — read detector from output vs. input | No | PARAM (numeric-snapped) |
| Compressor: program-dependent release | LA-2A, Fairchild 670 | Medium | **Low–Medium** — release-time-vs-history state | No | PARAM (`Bool`/numeric toggle) + PRESET ("opto") |
| Compressor: sidechain tilt filter (Thrust) | API 2500 | Medium | **Low** — one-pole tilt on the sidechain path | No | PARAM (`sidechainTiltDb`) |
| Compressor character/topology token | Waves CLA line, Decapitator-style abstraction | Medium | **Low** (bundles params 2 rows above) | No | PRESET (FET/opto/vari-mu tokens) |
| Multiband compressor | Logic Multipressor, Cubase MultibandCompressor, Ableton Multiband Dynamics, Studio One, ReaXcomp | High | **Large** — N-band crossover + N detector/gain chains + recombine | Only if per-band saturation is added later | PARAM per band + PRESET (band-count templates) |
| OTT-style up/down multiband | Xfer OTT | High (EDM-specific, very recognizable) | **Large**, builds on multiband compressor above | No beyond the above | PARAM (`depth`, `time`, per-band up/down enable) + PRESET ("OTT") |
| Exciter/harmonic enhancer | Aphex Aural Exciter | Medium | **Low** once Saturator v2 exists — HPF + saturator + parallel mix | Yes (inherits from the saturator stage) | PARAM (`crossoverHz`, `amount`) — nearly identical surface to our shipped `BassEnhancerParams`, mirrored to the top of the spectrum |
| Resonance suppressor (Soothe-class) | Oeksound Soothe | High | **Very large** — hundreds of simultaneous tracked dynamic notches | No (spectral-domain, not time-domain nonlinearity) | Effectively PRESET-only for an LLM (`sharpness`, `depth`) — the internals are not meaningfully steerable per-band |
| Vocal doubler/thickener | Soundtoys MicroShift, Waves Doubler | Medium–High (vocals specifically) | **Low–Medium** — short delay + pitch-shift, reuses existing delay/stretch primitives | No | PARAM (`voices`, `detuneCents`, `spreadMs`) + PRESET ("subtle"/"wide") |
| Formant shift | Any modern pitch/voice tool | Medium (vocal-specific) | **Medium** — needs a spectral-envelope-preserving pitch-shift path | Not typically | PARAM (`formantShiftSemitones`) |
| Hard-tune (retune speed → 0) | Auto-Tune "the effect" | Medium (stylistic, genre-specific) | **N/A** — a parameter of the pitch-correction engine already being designed (`m23-q`), not a new effect | N/A | PARAM (`retuneMs`) on the existing pitch-correction surface |
| Vocal rider / gain-riding | Waves Vocal Rider | Medium–High (workflow time saved) | **Low** — an analysis pass that emits fader automation, not an audio-domain effect | No | Emits a MODULATOR (writes an automation lane on the track fader) — an analysis *tool*, not a `fx.*` kind |
| Plosive control | iZotope RX De-plosive | Low–Medium (niche, vocal-recording specific) | **Low** once the transient shaper (§1.1) exists — same differential-envelope detector, fixed 20–80 Hz band | No | PARAM (`sensitivity`, `strength`) |
| Envelope/ADSR shaper | Generic sampler/synth convention | Low–Medium (narrower use case: one-shots) | **Low** once the transient shaper's envelope-follower code exists | No | PARAM (`attackMs`, `decayMs`, `sustainLevel`, `releaseMs`) |
| Per-band/multiband saturation | High-end mastering chains | Low–Medium | **Large** — depends on multiband crossover infra | Yes, compounding with band count | PARAM per band, or PRESET (2-band "warm low / clean high") |
| Mid/side dynamics/saturation | Ableton EQ8 M/S, Cubase Frequency | Medium | Depends on the separately-filed M/S primitive (`2026-08-04-pro-parity-gaps.md` §3.2) — **out of this report's scope**, noted for cross-reference only | Depends on which processor rides the M/S split (none needed for EQ, saturation-specific if a shaper is added per side) | PARAM (an M/S encode-mode toggle + per-side band/dynamics params, once that primitive lands) — cross-referenced only, not designed here |

### 9.1 On the clipper's oversampling need specifically
A clipper is the *hardest* nonlinearity in this table by construction (its
whole purpose is a sharp knee near the ceiling), so it inherits the higher
end of §12's budget even though the DSP itself (one `min`/`max` or one
cubic-knee function) is trivial to write.

## 10. Ranked shortlist — top 5–6 by musical-impact-per-unit-of-work

1. **Transient shaper.** Highest payoff, lowest complexity in this entire
   report — new RT-safe detector shape (two envelope followers, no FFT, no
   threshold), one new `EffectDescriptor.Kind`, ~2–3 params, no wire/MCP
   surface work beyond what a new kind gets for free (§0). Also directly
   unlocks the plosive-control and envelope/ADSR-shaper items cheaply later.
2. **Clipper.** Completes the mastering chain we already half-have (Saturator
   → ??? → Limiter, with the "before a brickwall limiter" stage missing);
   trivial DSP; the oversampling work it needs is the *same* work Saturator
   v2 needs, so building both close together amortizes the investment.
3. **Saturator v2 (oversampling + asymmetry + flavour token).** The repo's
   own code comments already scope this as additive and owed
   (`SaturatorEffect.swift:16-19`); fixes a named, self-documented honesty
   gap; the `flavor` token directly follows the Decapitator/Softube
   abstraction that's already proven to work as an LLM-legible interface.
4. **De-esser (as a Compressor mode).** Near-universal need (vocal-chain
   table stakes, every competitor ships one), and the pro-parity audit
   already scoped it S–M because the sidechain-key plumbing it needs is
   shipped; reuses more existing code than almost anything else on this list.
5. **"Assistant" measurement MCP tool.** Near-zero new DSP (wraps shipped
   `Loudness`/`MasterMixAnalyzer`/`ReferenceAnalyzer`), and it's the one item
   on this list that is a **direct, structural product differentiator**
   against Ozone/Neutron/Sonible rather than parity with them (§7.3) — ship
   it early so every later dynamics/character feature (transient shaper
   defaults, saturator amount, de-esser threshold) has an obvious hook to
   attach a suggestion to.
6. **Dynamic EQ.** Larger than #1–#5 but the best-evidenced open competitor
   gap (all five compared DAWs, per `2026-08-04-pro-parity-gaps.md` §3.3),
   architecturally cheaper than a full multiband compressor (no crossover
   filter bank), and unlocks the Soothe-class resonance-suppression
   "assistant" mapping in §7.2 once the "assistant" tool from #5 exists.

Multiband compression / OTT and the resonance suppressor (Soothe-class) are
real, high-payoff items but are both "Large" builds best sequenced *after*
dynamic EQ (shares its crossover-adjacent groundwork) and the "assistant"
substrate (gives the suppressor's `sharpness`/`depth` PRESET tokens something
to be suggested by) respectively — deliberately left off the top-6 for that
reason, not because they're unimportant.

## 11. Concrete parameter surfaces — top 3

Designed to match the repo's existing conventions exactly: flat `Double`
fields, `clamped(to:)` on init, a `static let ...Range`, additive-optional
`nil` semantics **only where an existing shipped effect is being extended**
(brand-new kinds don't need backward compatibility and can just pick sane
defaults directly, per the `GainParams`/`EQParams` pattern at v0).

### 11.1 Transient shaper — new `EffectDescriptor.Kind.transientShaper`

```swift
public struct TransientShaperParams: Codable, Sendable, Equatable {
    /// Boost (+) or cut (-) the ATTACK portion of the signal, dB.
    /// +/- matches SPL's own Transient Designer range.
    public var attackDb: Double        // range -15...15, default 0
    /// Boost (+) or cut (-) the SUSTAIN/decay portion, dB.
    public var sustainDb: Double       // range -24...24, default 0
    /// Dry/wet, 0...1. 0 is bit-exact dry (both followers still run so an
    /// automated 0→1 doesn't snap from stale state — the Compressor's
    /// mix-at-0 precedent, NOT the stateless Saturator one).
    public var mix: Double             // range 0...1, default 1
}
```
- `attackDb`/`sustainDb`: independent PARAMs, each also a MODULATOR (ride
  `sustainDb` up across eight bars for a "building" drum loop).
- PRESET tokens for the agent to reach for by name: "punchier" ≈
  `attackDb: +6, sustainDb: -3`; "roomier/glue" ≈ `attackDb: -3,
  sustainDb: +4` — worth shipping as named starting points in `fx.describe`'s
  `note` field (the EQ v2 precedent for teaching text on a param spec),
  not as a separate stored preset system.
- No sidechain key needed (unlike the Compressor) — the detector always
  reads its own input, which is what makes it composable anywhere in a chain.

### 11.2 Clipper — new `EffectDescriptor.Kind.clipper`

```swift
public struct ClipperParams: Codable, Sendable, Equatable {
    /// The clip ceiling, dBFS. Mirrors LimiterParams.ceilingRange exactly —
    /// an agent that already reasons about limiter ceiling reuses the concept.
    public var ceilingDb: Double       // range -24...0, default -1
    /// 0 = soft/rounded knee (tanh-family), 1 = hard brickwall truncation.
    /// A single continuous knob spanning the whole soft<->hard spectrum,
    /// matching Softube's Keep-High/Neutral/Keep-Low abstraction: one
    /// number an LLM can reason about ("make it harder") without needing
    /// the underlying knee-width math.
    public var hardness: Double        // range 0...1, default 0.3
    /// Post-clip trim, dB.
    public var outputDb: Double        // range -12...12, default 0
    public var mix: Double             // range 0...1, default 1
}
```
- Internally fixed at a minimum 4× oversampled nonlinearity (not exposed as a
  param — the `LimiterParams.lookaheadSeconds` precedent for "a real DSP
  choice that's fixed, not user-facing, and surfaces only as a derived
  property if it has audible side effects"). No latency added if the
  oversampling filters are minimum-phase/IIR half-band (preallocated state,
  RT-safe) rather than linear-phase FIR — worth a design spike before
  implementation to confirm which the render-thread constraints actually
  allow.
- PRESET tokens: "soft" ≈ `hardness: 0.15`; "hard"/"aggressive" ≈
  `hardness: 0.85`.

### 11.3 Saturator v2 — additive optionals on the shipped `SaturatorParams`

```swift
// Existing, unchanged:
//   driveDb: Double, mix: Double, outputDb: Double

/// nil = today's plain symmetric tanh, BIT-EXACT with every pre-v2 render
/// (the LimiterParams.truePeak / GainParams.invertPolarity precedent).
/// 0...4, numeric-snapped to the nearest whole token (the BitCrusherParams
/// .bits / DelayParams.pingPong precedent for a discrete-but-numeric field):
///   0 = clean (today's tanh, odd harmonics only)
///   1 = tube/triode (even-biased, gentle asymmetry)
///   2 = tape (adds a soft knee + a touch of high-frequency loss —
///       NOT full hysteresis/wow-flutter in v2; flag those as a v3 addendum
///       given hysteresis is a genuinely different, state-carrying DSP unit
///       per §3.1, not a curve-shape change)
///   3 = transistor/hard (steeper knee, odd-harmonic-heavy)
///   4 = diode/fuzz (hard, asymmetric)
public var flavor: Double?

/// nil = 0 (symmetric, today's exact curve). -1...1: a DC-bias-style term
/// applied before the shaper, generating even harmonics proportional to
/// |asymmetry| in EXACTLY the vocabulary BassEnhancerParams.harmonicWeights
/// already uses elsewhere in this codebase (Chebyshev T2 weight ∝ asymmetry)
/// — share that helper rather than re-deriving the math.
public var asymmetry: Double?

/// nil = 1 (today's un-oversampled render, BIT-EXACT). Numeric-snapped:
/// 1 = off (legacy), 2 = 2x, 4 = 4x. See §12 for which flavor needs which.
public var oversample: Double?
```
- `driveDb`/`asymmetry`/`mix` are PARAMs and MODULATORs (today's `driveDb`
  is already automatable via `storeAutomatedParam` — this just adds two more
  slots to the existing switch).
- `flavor` is a PRESET token by construction — not meaningfully continuous,
  matches Decapitator's A/E/N/T/P exactly.
- `oversample` is arguably an internal quality setting more than a creative
  PARAM — expose it, but expect agents to leave it at the effect's own
  sensible default per flavor (tape/diode default higher, clean/tube default
  lower) rather than reasoning about it directly; see §12.

## 12. Aliasing / oversampling budget

**The core problem, stated precisely:** any nonlinearity applied to a
band-limited digital signal generates harmonic content at integer multiples
of every frequency present in the input. At 48 kHz (Nyquist 24 kHz), a
saturator driven hard on a bright source will generate harmonics well past
24 kHz; those harmonics don't just get lost, they **fold back** into the
audible band as inharmonic aliasing — this is precisely what our Saturator's
own header calls out today ("tanh's odd harmonics above Nyquist fold back").
Aliasing is the single biggest reason cheap/naive distortion plugins sound
"digital" or "harsh" in a bad way rather than "aggressive" in a good way —
it's not that harmonics are bad, it's that *the wrong, non-harmonic* ones are
audible.

**What we must budget, by nonlinearity family** (harmonic-series richness is
the driver — a curve whose harmonics decay fast needs less headroom than one
whose harmonics decay slowly):

| Family | Harmonic decay | Minimum oversampling (brute-force) | With ADAA |
|---|---|---|---|
| Soft/tanh-family (our current Saturator, and Clipper's "soft" end) | Fast (exponential-ish rolloff) | 2×–4× | 2× ADAA ≈ 8× brute-force quality |
| Hard clip (Clipper's "hard" end) | Slow (~1/n) — much richer series | 4×–8× | 2×–4× ADAA |
| Wavefolder | Richest, keeps regenerating with drive | 4× minimum, 8× commonly cited as "safe" | Still benefits, less thoroughly studied than clip/tanh cases |

Sources: practical minimum/safe-standard figures and the "2× ADAA ≈ 8×
brute-force" claim are both from recent practitioner write-ups
([Medium/jatinchowdhury18: practical ADAA considerations](https://jatinchowdhury18.medium.com/practical-considerations-for-antiderivative-anti-aliasing-d5847167f510);
[Medium/jatinchowdhury18: wavefolding](https://jatinchowdhury18.medium.com/complex-nonlinearities-episode-6-wavefolding-9529b5fe4102)),
synthesizing the peer-reviewed source below, not a direct quote from it — treat
the exact multiplier as an engineering rule of thumb, not a proven constant,
and re-derive empirically once an implementation exists (we have no Bash/audio
measurement access in this research pass to verify it ourselves).

**The peer-reviewed foundation**: Parker, Zavalishin, and Le Bivic,
"Reducing the Aliasing of Nonlinear Waveshaping Using Continuous-Time
Convolution" (DAFx-16) — the paper that introduced **Antiderivative
Antialiasing (ADAA)**: instead of brute-force oversampling (upsample →
nonlinearity → filter → downsample, which costs CPU proportional to the
oversampling factor), ADAA constructs a continuous-time approximation of the
nonlinearity's *antiderivative* and convolves analytically, markedly reducing
aliasing **especially when combined with a small amount of oversampling**
rather than needing a large factor alone
([DAFx paper archive](https://www.dafx.de/paper-archive/details/vem_XXF5qBbfiWOH2RVVAA);
[full paper PDF](http://dafx16.vutbr.cz/dafxpapers/20-DAFx-16_paper_41-PN.pdf)).
Reference implementations exist and are worth reviewing before building
(`jatinchowdhury18/ADAA` on GitHub has working C++/Python).

**What this means concretely for us:**
1. **Brute-force oversampling needs an up-path and a down-path, both with
   real filtering** — not just zero-stuffing/decimation. Upsampling needs a
   low-pass (image-rejection) filter before the nonlinearity; downsampling
   needs an anti-aliasing low-pass before decimation. This is genuinely more
   DSP than it sounds like from "just run it at 2×" — it's two half-band
   filters' worth of extra state per instance.
2. **Our `LimiterEffect`'s existing 4× oversampled true-peak *detector*
   (BS.1770-4 Annex 2 interpolator) is architecturally related but not
   directly reusable** — that path only needs to *measure* an oversampled
   reconstruction (one-way, read-only), while a saturator/clipper needs to
   *process* at the oversampled rate and get a clean signal back down,
   which is the harder, two-way problem. Don't assume the interpolator can
   be dropped in as-is.
3. **Real-time-safety constraint**: any oversampling filter state must be
   preallocated at `prepare(sampleRate:maxFramesPerQuantum:channelCount:)`
   and touched with zero allocation/locks in `process()` — the exact
   contract every existing effect already honors. A minimum-phase IIR
   half-band design avoids adding the render-path latency a linear-phase FIR
   would (relevant given `LimiterParams.latencySamples` is already a thing
   PDC has to account for — adding more insert latency by default is a
   bigger decision than adding an internal-only feature usually is; a design
   spike should explicitly decide whether Saturator v2/Clipper report nonzero
   `latencySamples` or hold to zero via minimum-phase filtering).
4. **Recommended default**: 2× oversampling + ADAA (trapezoidal-rule
   antiderivative) as the shipped default for the tanh/soft family (today's
   Saturator, Clipper's soft end), scaling to 4× for the hard-clip/diode end
   of the Saturator `flavor` token and for the Clipper's hard end, per the
   table above — this keeps the CPU/complexity budget close to what a single
   new render-thread nonlinearity already costs while landing near
   brute-force-8× quality per the ADAA literature's own claim.
5. **This budget item should be built once, as a shared internal helper**
   (an `Oversampler` type any future nonlinear effect can adopt), not
   duplicated per effect — Clipper, Saturator v2, per-band saturation, and
   the exciter (§4.5, which is just Saturator band-limited) all need the
   identical up/process/down shape.

## Actionable takeaways

Proposed as a new milestone (**M39** — the next free slot; M38 was the last
one used as of this sprint, ROADMAP :3185) or split across M39/M40 if the
roadmap author wants dynamics and character kept separate. All items below
are scoped to land as *additive* changes only — no existing param, command,
or render behavior changes shape.

1. **Ship the transient shaper first (§1.1, §11.1).** Best payoff/complexity
   ratio in this report; needs a genuinely new RT-safe two-follower detector
   (do **not** reuse `TransientAnalyzer` — it's offline, allocates, and its
   own header forbids render-path use); lands as one new `EffectDescriptor.Kind`
   with zero new wire/MCP surface (the M38 polarity-invert precedent).
2. **Build the shared `Oversampler` helper (§12) before or alongside the
   Clipper (§1.4, §11.2), and reuse it immediately for Saturator v2 (§3, §11.3).**
   Sequencing these two together amortizes the one piece of genuinely new,
   nontrivial DSP in this report (a real up/process/down oversampling path
   with proper half-band filtering, RT-safe/preallocated). Explicitly decide,
   as part of that spike, whether the resulting effects report nonzero
   `latencySamples` (PDC-visible) or hold to zero via minimum-phase filtering
   — this is a real design fork, not a detail.
3. **Land Saturator v2 (§3.2, §9, §11.3) as additive optionals** on the
   shipped `SaturatorParams` — `flavor` (numeric-snapped PRESET token,
   Decapitator/Softube-style), `asymmetry` (reuse the `BassEnhancerParams`
   Chebyshev-weight vocabulary already in the codebase rather than
   re-deriving it), `oversample`. `nil` on every new field must decode to
   today's exact bit-exact tanh — this is explicitly what the effect's own
   header already promises ("Oversampling is an additive internal change
   behind the same seam").
4. **De-esser as a fifth Compressor mode (§1.5), not a new effect kind** —
   reuses the shipped sidechain-key detector path almost entirely; closes the
   best-evidenced open vocal-chain gap from the 2026-08-04 audit at low cost.
5. **Ship the "assistant" MCP tool (§7.3) early and separately from any new
   DSP** — it's pure analysis-layer work over `Loudness`/`MasterMixAnalyzer`/
   `ReferenceAnalyzer`/the shipped `fx.spectrum` per-insert tap, all already
   shipped, and it's the one item in this whole report that's a structural
   differentiator rather than parity-seeking. Recommend scoping it as
   read-only (returns measurements + suggested `fx.setParam` calls with
   stated reasoning) rather than an auto-apply button — that's both cheaper
   to build and more consistent with this app's existing "the agent is always
   the one calling `fx.*`" model than copying Ozone/Neutron's one-click-apply
   UX.
6. **Dynamic EQ (§1.7) as the next Large item after the above land** — reuses
   existing EQ biquads + the Compressor's gain-computer math, no crossover
   filter bank required, and is architecturally the right *first* step toward
   eventual multiband/OTT-style compression (§1.2) rather than a competing
   design.
7. **Do not build multiband compression, OTT, or the Soothe-class resonance
   suppressor next** — all three are real (§6, §9) but are the three largest
   items in this report, and two of the three (multiband, OTT) become
   meaningfully cheaper once dynamic EQ's crossover-adjacent groundwork
   exists; the third (Soothe-class) is better sequenced after the assistant
   substrate gives its `sharpness`/`depth` tokens something to be
   auto-suggested by.
8. **Cross-file, don't duplicate**: mid/side processing, export dithering,
   and export sample-rate conversion remain owned by
   `docs/research/2026-08-04-pro-parity-gaps.md` — if M39/M40 gets scoped,
   flag that per-band saturation (§9) and M/S dynamics both eventually want
   the same "process the mid and side separately" primitive that document's
   §3.2 already called for, so whichever lands first should design its
   channel-split seam to be reused by the other rather than forking it.
