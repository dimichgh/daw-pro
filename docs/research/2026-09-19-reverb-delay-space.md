# Reverb, delay, and spatial processing — deep research sprint

Date: 2026-09-19
Author: research-analyst
Scope: reverb algorithm families, the musical parameters that matter, creative
reverb techniques, delay beyond the basics, spatial processing, a product
study focused on parameter *abstraction*, and ducking. Code-only, no writes.

## 0. What we have today (verified from source, 2026-09-19)

`Sources/DAWEngine/Effects/ReverbEffect.swift` is a textbook **Freeverb**
implementation: per channel, 8 parallel Schroeder-Moorer damped-feedback
combs (canonical 44.1 kHz tunings `1116…1617` samples, scaled to the prepared
rate) feed 4 series Schroeder allpasses (`556, 441, 341, 225` samples, fixed
feedback 0.5), fed by the mono sum through a pre-delay line. Five params:
`roomSize, damping, mix, preDelayMs, width` (`Sources/DAWCore/Effects.swift:525`).

Two structural facts matter more than anything I found on the web, because
they are the actual argument for changing the engine:

- **`roomSize` does not control size.** Comb *lengths* are fixed constants;
  `roomSize` only scales comb **feedback** (`0.7 + 0.28·roomSize`,
  `ReverbEffect.swift:213`). Feedback-vs-length is exactly RT60-vs-size, and
  we've wired the knob to the RT60 half only. There is no way today to make a
  reverb sound "bigger" (later, sparser early reflections) independent of
  making it "longer" (slower decay) — the single most requested reverb
  control pair in every product studied below is not expressible.
- **`damping` is a single broadband one-pole**, applied identically inside
  every comb (`0.4·damping`, one coefficient, no crossover). There is no
  frequency split, so "dark hall" (fast HF decay, slow LF decay) vs. "bright
  chamber" (the reverse) cannot be dialed in — only a uniform brightness tilt.
- **There is no modulation anywhere in the tank.** Freeverb's four series
  allpasses at fixed feedback are the textbook case Valhalla's engineering
  blog names as the cause of metallic ringing on sustained or impulsive
  material (§1.3). We are exposed to exactly that failure mode and have no
  parameter to fix it.

`Sources/DAWEngine/Effects/DelayEffect.swift`: single stereo delay line,
**integer-sample** read offset (`round(timeMs·rate/1000)`), pinned by the
test `delayEchoLandsAtExactSampleOffset` — i.e. this exact-sample contract is
a committed behavior on the *existing* `.delay` kind, not incidental. One-pole
low-pass in the feedback path only (first echo unfiltered), boolean
`pingPong` L/R crossfeed. No fractional interpolation means no click-free
time automation, no wow/flutter, no BBD modeling — all three need a
fractional read pointer.

`Sources/DAWEngine/Effects/ChorusEffect.swift` already contains the missing
primitive: a **linearly-interpolated, LFO-modulated delay line** (2 voices,
90°/180° phase offsets, feedback-free). This is precisely the building block
FDN tail modulation, tape wow/flutter, and BBD-style pitch wobble all need —
it does not need to be invented, only generalized and reused.

`sidechainSourceTrackID` (`Effects.swift:73`) already exists on
`EffectDescriptor` — any non-bus track can key another strip's detector — but
validation in `ProjectStore.setSidechain` currently restricts it to
`compressor`/`gate` kinds. This is the exact seam ducking reverb/delay
needs (§7).

Also present: `SaturatorParams` (tanh drive/mix/output, `Effects.swift:668`)
and `DelayTempoSync`/`NoteDivision` (`Sources/DAWCore/DelayTempoSync.swift`,
`TempoMap.swift`) — both reusable for tape/dub delay character and for
tempo-synced pre-delay, respectively, without new machinery.

The `EffectDescriptor.Kind` enum and the additive-optional-param pattern
(`gain: GainParams?`, decode-nil-as-default, the m22-f `sync: Bool?`
precedent) is the wire contract any new params must follow: **new fields are
additive optionals; existing kinds/param names/automation slot order
(0…4 in each effect's `storeAutomatedParam`) are never renamed or
reordered.**

## 1. Reverb algorithm families

### 1.1 Schroeder / Moorer (comb + allpass), Freeverb

Manfred Schroeder's 1962 topology — parallel comb filters (each a delay with
feedback, simulating a room's discrete echo density) feeding series allpass
filters (added density without adding coloration, in theory) — is the
ancestor of nearly everything that followed. James Moorer's refinement added
a **lowpass filter inside each comb's feedback path**, so high frequencies
decay faster than low ones (frequency-dependent absorption, closer to real
rooms) — this is precisely the mechanism our `damping` parameter already
uses, just with a single global coefficient instead of per-band control.

**Freeverb** (Jezar at Dreampoint, 2000, public domain) is a specific,
extremely well-tuned instance: 8 parallel Moorer combs + 4 series Schroeder
allpasses per channel, stereo achieved by offsetting the right channel's
delay lengths by a fixed `stereospread` (23 samples) rather than truly
independent processing. It remains popular because it is *cheap and sounds
decent for its cost* — exactly what we implemented.
[CCRMA/JOS description](https://ccrma.stanford.edu/~jos/pasp/Freeverb.html).

**Trade-offs**: lowest CPU of any credible algorithm; zero modulation
(metallic on sustain); size and decay conflated (fixed comb lengths); no
per-band decay; trivially real-time-safe (fixed-size lines, no matrix
multiply); very easy to tune badly, moderately easy to tune well once
(Jezar's constants are the reason it still sounds fine 26 years later — but
they are *fixed*, not derivable from user-facing size/decay parameters).

### 1.2 Feedback Delay Networks (FDN) — why they dominate modern algorithmic reverb

An FDN is the general form Freeverb is a degenerate case of: N delay lines
connected in a feedback loop through an **N×N feedback matrix** (rather than
Freeverb's implicit "matrix" of independent parallel combs — mathematically a
diagonal matrix). Using an **orthogonal (lossless) matrix** — Hadamard or
Householder are the common choices — guarantees the network is stable for
*any* per-line gain ≤ 1, and produces much denser, smoother diffusion than
parallel combs because energy from every line's output feeds into every
line's input on each cycle, not just its own.
[JOS PASP, "FDN Reverberation"](https://ccrma.stanford.edu/~jos/pasp/FDN_Reverberation.html).

Why FDNs won:

- **Size and decay separate cleanly.** Delay-line *lengths* (their ratios,
  and an overall scale factor) set echo density / apparent room size.
  Per-line **absorption filters** (a one-pole or shelving filter in each
  line's feedback path, whose coefficient is *derived* from the desired RT60
  at that line's length via the standard formula `g = 10^(-3·L/(RT60·fs))`)
  set decay time **independently of length**. This is the single property
  our Freeverb build cannot offer (§0) and every serious reverb — hardware or
  plugin — provides.
- **Frequency-dependent RT60 falls out for free**: make the absorption
  filter a shelf instead of a single-pole lowpass, and you get separate
  low/high decay multipliers (§2) with no additional structural complexity.
- **CPU is low and scales linearly.** A Householder matrix multiply is
  `O(N)` (`y = x - (2/N)·(Σx)·1`, not `O(N²)`), so an 8- or 16-line FDN costs
  about the same order of arithmetic per sample as our existing 8 combs + 4
  allpasses — this is **not** a large CPU regression over what we already
  run per insert.
- **Modulation is a first-class fix, not a hack.** Small (sub-millisecond)
  time-varying modulation of each delay line's length — exactly the
  fractional-delay + LFO pattern `ChorusEffect` already implements — breaks
  up the periodicity that causes metallic ringing. Valhalla's own
  engineering writeup: "short feedback delays and sparse diffusion... cause
  the metallic ringing... modulate the delay lengths within the allpasses...
  this helps reduce coloration."
  [Valhalla, "Reverbs: Diffusion, allpass delays, and metallic artifacts"](https://valhalladsp.com/2011/01/21/reverbs-diffusion-allpass-delays-and-metallic-artifacts/).

**Trade-offs**: the real cost is *design/tuning time*, not runtime CPU —
delay-line lengths must be mutually prime-ish (avoid common factors, or
periodic artifacts reappear), the matrix must stay provably lossless, and
mode density (how many resonant "modes" per Hz, related to total delay
length summed across lines) has to be tuned so the tail doesn't sound sparse
on short/small settings. This is well-documented (Schlecht & Habets' work on
circulant/elliptic FDNs formalizes stability and mode-density criteria) so
the risk is bounded, but it is real up-front engineering work, not a
drop-in swap. [Circulant and Elliptic FDNs, Schlecht/Habets](https://citeseerx.ist.psu.edu/document?doi=e69cb5643d81264ed96201e31cef7a7d375408bb&repid=rep1&type=pdf).

### 1.3 Dattorro / Griesinger plate topology

Jon Dattorro's 1997 AES paper ("Effect Design, Part 1: Reverberator and
Other Filters") documents a specific, tightly-tuned topology in the style of
David Griesinger's Lexicon plate algorithms: an **input diffuser** (4 series
allpasses that pre-smear the dry signal) feeding a **figure-eight tank** —
two interleaved delay/modulated-allpass loops that cross-feed each other,
rather than N independent parallel lines. This is *technically* a
constrained FDN (a specific 2-loop topology with a fixed mixing pattern) but
it's normally treated as its own family because the tank shape (not a general
matrix) is the defining, widely-copied artifact — it is the most-cloned
reverb structure in the freeware/plugin world after Freeverb itself.
[Dattorro 1997, full PDF](https://ccrma.stanford.edu/~dattorro/EffectDesignPart1.pdf).
Tom Erbe's UCSD course notes are a good secondary map of the whole topology
family: [Reverb Topologies and Design](https://tre.ucsd.edu/wordpress/wp-content/uploads/2018/10/reverbtopo.pdf).

**Trade-offs**: distinctive, dense, "plate-like" character with well-known,
reproducible tuning constants (unlike a general FDN, which you must tune
yourself); the built-in modulated allpasses in the tank already address
metallic ringing by design; less flexible as a *general-purpose* algorithm
because the topology (not just the parameters) is fixed to two loops rather
than a musician-adjustable line count — you get one very good character, not
a parametrizable family of characters.

### 1.4 Waveguide / scattering reverb

Digital waveguide networks model reverberation as pressure waves scattering
at junctions between connected 1-D waveguides (each waveguide = a
bidirectional delay line simulating a physical dimension). Smith showed FDNs
are *isomorphic* to a specific single-junction waveguide network — so in
practice this family and FDN converge mathematically; the interesting
variant is **Scattering Delay Networks (SDN)**, which places a scattering
junction at each of several *modeled room-surface positions* rather than one
central matrix, trading a closer-to-physical-simulation structure for
materially higher CPU and design complexity, mainly aimed at room-acoustics
research and game/VR audio rather than music production.
[Scattering Delay Networks paper](https://arxiv.org/pdf/1502.05751).
Not a serious contender for us: the extra physical accuracy buys realism our
users (musicians dialing in a mix, or an agent reasoning about "make the
vocal reverb bigger") do not need, at meaningfully higher cost and much
higher tuning complexity than an FDN.

### 1.5 Convolution (with true-stereo and IR handling)

Convolution reverb applies a recorded or synthesized **impulse response**
(IR) directly to the dry signal via (partitioned) FFT convolution. It is
addressed in full in §11 because it's a yes/no product decision with its own
cost structure (IR storage, latency, licensing) rather than a pure algorithm
choice; the short version: unmatched *realism/specific-space* fidelity, at
the cost of being musically static (an IR can't independently change size vs
decay without either resynthesizing or accepting quality loss) and — this
matters most for our stated positioning — **the worst fit of any option for
LLM control**, because an opaque IR file is not a set of reasoning primitives
an agent can turn.

### 1.6 Hybrid convolution + algorithmic

Ableton's Hybrid Reverb is the cleanest shipping example: a convolution
engine (any imported IR, reshaped by `Attack`/`Decay`/`Size` envelope
controls over the IR itself — clever, because it makes even a canned IR
*partially* parametric) supplies the **early reflections**, and a fully
algorithmic engine supplies the **late tail** (`Decay`, `Size`, `Delay`
pre-delay, several selectable "modes" from clean to metallic/gong), with the
two paths mixable in series or parallel.
[Ableton Hybrid Reverb FAQ](https://help.ableton.com/hc/en-us/articles/360019484980-Hybrid-Reverb-FAQ).
This is the shape I'd steal *if and when* we add convolution: never let raw
IR audio be the only parametrizable surface, and never let it own the tail
(where an agent's decay/size reasoning matters most) — see §11's recommended
architecture.

## 2. The parameters that actually matter musically

Beyond room-size/damping, in order of musical impact (payoff assessed
against what our current 5-knob surface cannot do at all):

- **Decay time (RT60) as its own control, independent of size.** This is
  the #1 gap (§0, §1.2). Every product studied below treats these as two
  separate knobs (ChromaVerb: `Size` + `Decay`; FabFilter Pro-R: `Space` +
  `Decay Rate`; Blackhole: `Size` + `Gravity`).
- **Early/late reflection balance.** How much of the wet signal is discrete,
  identifiable early reflections (perceived as *closeness*/definition) vs.
  diffuse late tail (perceived as *space*). FabFilter names this
  `Distance`; Blackhole's `Gravity` conflates it with decay (a deliberate,
  documented simplification — see §6).
- **Diffusion / density.** How quickly the early reflections smear into a
  dense, "one continuous" tail vs. remaining audible as discrete slaps.
  ChromaVerb's `Density`: "High Density settings sound better on rhythmic
  sources, whereas Low Density is better on smoother pad-like sounds"
  ([Apple support](https://support.apple.com/guide/logicpro/chromaverb-overview-lgcp18cc0940/mac)) —
  a genuinely *musical*, source-dependent knob, not a technical afterthought.
- **Modulation/chorusing of the tail.** The direct fix for metallic ringing
  (§1.2) and, pushed further, a creative "shimmer-adjacent" lushness
  control. Needs both rate and depth exposed, because different sources want
  different LFO speeds (slow/deep for pads, fast/shallow to just de-metal a
  drum reverb without an audible wobble).
- **Low/high-frequency decay multipliers (frequency-dependent RT60).**
  FabFilter Pro-R's most distinctive idea is exposing this as a **6-band
  graphic EQ drawn directly on the decay-time curve** ("Decay Rate EQ") —
  rather than "low decay ×, high decay ×" as two numbers, you draw the whole
  frequency-dependent decay shape.
  [FabFilter Pro-R 2 manual](https://www.fabfilter.com/downloads/pdf/help/ffpror2-manual.pdf).
  We should NOT copy the drawn-curve UI (bad LLM target — a curve is not a
  small set of named numbers) but the underlying capability — multiplier
  bands at a few fixed crossovers — is exactly the semantic, few-knob
  version an agent can reason about ("make the low end ring longer, the top
  end die fast" → two numbers).
- **Pre-delay in ms *and* in tempo-synced note values.** We already solved
  this exact problem for delay time (`DelayParams.sync`/`.division`,
  `NoteDivision`, `DelayTempoSync.swift`) — reverb pre-delay is the same
  problem (a producer syncing pre-delay to a 1/32 note to keep a vocal
  reverb from smearing the next syllable) and should reuse the identical
  mechanism rather than inventing a second one.
- **Width / stereo spread.** Already implemented (M/S on the wet signal
  only) — a genuine strength; note it for parity, not as a gap.
- **Ducking.** See §7 — high musical payoff, and the detector machinery
  already exists.

## 3. Creative reverb

- **Shimmer** — precise topology: a pitch shifter (classically +1 octave;
  Valhalla and Strymon also offer a fifth-above, dual up/down, and reversed
  variants) is placed **inside the reverb's feedback loop**, not before or
  after it, so every pass through the tank shifts the signal further —
  a cumulative ascending (or descending) pitch cascade rather than a single
  shift. Valhalla's writeup is explicit that this only works well if the
  *reverb* is co-designed for it: "the reverb algorithms in ValhallaShimmer
  were specifically designed to work well with pitch shifted feedback, so
  that a higher degree of feedback can be used" — naive insertion of a
  generic pitch shifter into a generic reverb's feedback path tends to
  produce audible comb-filtering/glitch artifacts unless the shifter itself
  uses a de-glitching (randomized-grain) technique rather than classic
  fixed-window granular shifting.
  [ValhallaShimmer: The Controls](https://valhalladsp.com/2010/11/27/valhallashimmer-the-controls/),
  [ValhallaShimmer: a bit of history](https://valhalladsp.com/2010/11/23/valhallashimmer-a-bit-of-history/).
  Historical root: Eventide's H3000 Harmonizer (1986) combined pitch-shift,
  delay, and reverb algorithms in one modular unit and is credited as the
  spiritual ancestor of dedicated shimmer plugins.
  [Reverb.com, "The Eventide H3000"](https://reverb.com/news/tech-behind-eventide-h3000-ultra-harmonizer).
- **Reverse reverb** — the classic (tape-era) technique reverses the *dry*
  audio, renders it through a normal reverb, then reverses the *wet* result
  again, so the tail swells up to and ends exactly at the transient rather
  than decaying away from it. This is fundamentally a **clip-level bounce
  operation**, not a real-time insert parameter — there is no causal way to
  "un-decay into the future" on a live signal. **Implementation note for
  us**: this should be a clip/region *operation* (reuse our existing offline
  render path) rather than a `ReverbParams` field.
- **Gated reverb (the 80s drum sound), precisely how it's made**: discovered
  by accident in 1980 (Hugh Padgham/Steve Lillywhite, a Peter Gabriel
  session) via an SSL console's heavily-compressed talkback/"Listen Mic"
  circuit bleeding into a drum room mic, then made into a standalone,
  reproducible effect by AMS's RMX16 digital reverb unit (its "Non Lin 2"
  algorithm) — most famous on Phil Collins' "In the Air Tonight."
  [Reverb.com, "How the AMS RMX16 Defined a Generation of Drum Sounds"](https://reverb.com/news/how-the-ams-rmx16-defined-a-generation-of-drum-sounds);
  [Wikipedia, Gated reverb](https://en.wikipedia.org/wiki/Gated_reverb).
  Mechanism, reproducible in DSP: (1) a dense, fairly bright reverb tail,
  (2) heavy compression/limiting on that wet signal so the tail sits at a
  near-constant loud level instead of decaying naturally, (3) a **noise
  gate** on the wet output with a fast attack and a **hold time** followed
  by a near-instant release, so instead of fading out, the tail is cut off
  abruptly at a fixed point. **We can build this from parts we already
  have**: chain our existing `CompressorParams`/`GateParams` math onto the
  reverb's wet output internally, expose only `gateHoldMs` and
  `gateReleaseMs` (plus the underlying reverb's own decay/density), rather
  than reimplementing compression or gating.
- **Freeze / infinite hold** — implemented by driving feedback to (just
  under) unity. The documented gotcha, worth designing around up front: if
  the tank's damping/absorption filters stay active while frozen, they keep
  removing highs every pass, so the "held" tail audibly dulls over minutes
  even though level holds steady (Spin Semiconductor DSP forum:
  ["infinite FREEZE reverb"](http://www.spinsemi.com/forum/viewtopic.php?t=442)).
  **Design implication**: a `freeze` flag should bypass (not just reduce)
  the frequency-dependent decay filters while active, not merely set
  feedback near 1.0.
- **Non-linear / blooming / swell** — Strymon BigSky ships dedicated
  `Bloom` and `Swell` "machines": rather than the reverb's amplitude peaking
  immediately at the input transient and decaying, an attack/rise envelope
  is applied so the reverb fades **in**, cresting after the dry signal has
  already started decaying — a "backwards" envelope shape distinct from
  full reverse reverb (it needs no future audio, so it *is* real-time-safe,
  unlike reverse reverb). Eventide Blackhole's `Gravity` knob turned
  anti-clockwise past center does something related (documented as
  "inverse (reverse-style)" behavior) by inverting the reverb's own internal
  envelope rather than reversing the source.
  [Blackhole quick guide](https://www.eventideaudio.com/downloads/blackhole-quick-guide/).
- **Spring and plate character** — spring reverb's signature "boing"/drip
  comes from dispersive propagation in a physical helical spring (different
  frequencies travel at different speeds down the coil, producing a
  chirp-like smear on transients) — modeled digitally with an allpass chain
  whose coefficients are frequency-*dependent* delay (a true dispersion
  filter, not a simple allpass cascade) rather than a diffuser tuned for
  smoothness; a lower priority build (guitar/vintage-amp market, not core to
  a production DAW) but worth a preset "mode" once the FDN core exists,
  since a dispersion allpass chain can sit ahead of the tank as an input
  stage. Plate character (EMT 140, 1957, the first practical plate unit,
  designed by Wilhelm Franz) is already close to what a well-tuned FDN or
  Dattorro tank naturally produces — dense, bright, slightly metallic-in-a-
  good-way — and needs tuning choices more than new topology.
  [Universal Audio, "Origins of EMT Reverb"](https://www.uaudio.com/blogs/ua/emt-reverb-history).
- **"Dark hall" vs. "bright chamber"** — purely a consequence of the
  low/high decay-multiplier and crossover parameters in §2; no separate
  mechanism needed once frequency-dependent RT60 exists. FabFilter's single
  `Brightness` knob (a coupled HF-decay + HF-EQ tilt) is the model for
  exposing this as *one* agent-legible knob instead of four.

## 4. Delay beyond the basics

- **Tape delay** — wow (slow, ~0.1–2 Hz pitch drift from motor speed
  variation) and flutter (faster, ~4–12 Hz, from transport/capstan
  irregularity) are what make a tape delay sound "alive" where a digital
  delay sounds static; modeled as LFO modulation of the delay-line read
  pointer (the exact `ChorusEffect` primitive, generalized: slow deep LFO +
  fast shallow LFO summed). **Self-oscillation**: pushing feedback ≥ 1
  causes runaway on a naive digital delay (hard clip or numeric blowup); on
  real tape, magnetic flux saturation and the record chain's own compression
  bend the runaway into a saturating "howl" rather than a harsh clip — we
  already have `SaturatorEffect`'s tanh math and should reuse it inside the
  delay's feedback path for a "tape" character rather than building new
  saturation code.
- **BBD / analog bucket-brigade character** — a bucket-brigade device (F.
  Sangster & K. Teer, Philips, 1969) is a chain of capacitor "buckets" that
  samples and passes an analog voltage in discrete steps at a **clock rate
  that directly sets the delay time** — modulating the clock *is* the
  wow/flutter mechanism on real hardware, which maps exactly onto modulating
  a digital delay's fractional read-pointer rate.
  [Wikipedia, Bucket-brigade device](https://en.wikipedia.org/wiki/Bucket-brigade_device).
  Companding ICs (compress going in, expand coming out, common parts
  NE570/571) suppress the BBD's inherent noise floor but never eliminate it
  — the residual noise-plus-HF-rolloff *is* the "warm" character, reproduced
  digitally with a fixed noise floor + a low-pass in the signal path (not
  just the feedback path, unlike our current `highCutHz`, which is
  feedback-only).
- **Multi-tap** — N delay taps off one line (or N independent lines) at
  different times/levels/pans, common on nearly every pro delay (Valhalla
  Delay, EchoBoy, native DAW delays); cheap to add (read the same line at
  multiple offsets) once a longer, possibly-fractional delay line exists.
- **Diffusion / granular / pitched delay** — Valhalla Delay's `Diffusion`
  mode runs the delayed signal through a small internal allpass diffuser,
  blurring discrete echoes toward a pseudo-reverb tail; granular/pitched
  delay chops the delayed signal into overlapping grains that can be
  pitch-shifted or time-stretched independent of the delay time — a
  higher-cost, lower-priority feature (needs a small granular engine,
  analogous to the shimmer pitch-shifter in §3, but time-domain windowed
  rather than feedback-embedded).
- **Dub-style filtered feedback** — King Tubby's characteristic sound:
  signal → delay → **high-pass filter** (his rig used a passive
  inductor-based 18 dB/octave filter, the Altec 9069B) → saturation → back
  into the feedback loop, so each successive repeat gets both darker (from
  the HPF, mimicking tape-head aging) and warmer/more compressed (from
  saturation).
  [Science of Dub, "Dub Delay"](https://scienceofdub.com/2026/01/19/dub-delay/).
  We already filter the feedback path (`highCutHz`); dub needs the
  complementary **low-cut in feedback**, plus the saturation stage we
  already have as `SaturatorParams` math, chained in — no new DSP primitive,
  two new parameters and internal wiring.
- **Ducking / sidechained delay** — same mechanism as ducked reverb; see §7.
- **Stereo offset and cross-feedback topologies** — beyond the boolean
  `pingPong`, a continuous cross-feedback amount (0 = independent L/R lines,
  1 = full ping-pong) and an independent L/R time *offset* (rather than
  only a single shared `timeMs`) unlock asymmetric stereo delay patterns
  (a la EchoBoy's stereo modes) without adding a second delay line class.
- **Tempo-sync with dotted/triplet divisions** — already fully solved
  (`NoteDivision`, `DelayTempoSync`) — note as a strength, reusable directly
  for reverb pre-delay sync (§2).

## 5. Spatial processing

- **Mid/side processing** — already implemented on the reverb's wet signal
  (`width`); note as parity, not a gap.
- **True stereo vs. pseudo-stereo** — "true stereo" IRs/algorithms carry
  four channels of cross-information (L→L, L→R, R→L, R→R) vs. a standard
  stereo IR/algorithm applying independent processing per channel; this is
  overwhelmingly a **convolution-reverb** distinction (doubling convolution
  cost) and essentially irrelevant to an algorithmic FDN, where cross-channel
  behavior is already whatever the feedback matrix and stereo-spread choices
  make it. Only relevant if/when we ship convolution (§11).
- **Haas / precedence effect** — a delay of roughly 1–40 ms on one channel
  reads as spatial width rather than a discrete echo, because the auditory
  system localizes on the *first* arrival and treats a sufficiently short
  second arrival as spatial information rather than a separate event
  (Helmut Haas, 1949 thesis / 1951 paper).
  [Wikipedia, Precedence effect](https://en.wikipedia.org/wiki/Precedence_effect).
  Directly actionable: our delay's `stereoOffsetMs` proposal (§4/§10) *is* a
  Haas-effect control when kept under ~35 ms — worth documenting as such so
  an agent can reason "use a short stereo offset for width, a long one for a
  discrete echo."
- **Mono compatibility** — worth stating explicitly since it's easy to
  regress silently while adding the width/offset controls above:
  - Today's reverb `width` is M/S on the **wet** signal only, so a mono sum
    is coherent by construction (the side component cancels, the mid
    survives) — a genuine strength, and the new FDN engine's `width` param
    should keep the same M/S-on-wet shape rather than a raw per-channel
    decorrelation trick.
  - The proposed delay `stereoOffsetMs` (Haas, above) is the classic
    mono-compatibility hazard: a 1–35 ms L/R offset comb-filters when the
    two channels are summed to mono (some frequencies cancel outright). The
    param description should say so explicitly, so an agent doesn't reach
    for a large offset on material likely to be heard in mono (club PA,
    phone speaker preview, broadcast).
  - Allowing `width` above 1.0 (§10.1 proposes a 1.2 ceiling) pushes side
    gain above unity, which can produce content that partially cancels in
    mono; keeping the ceiling modest (1.2, not e.g. 2.0) is a deliberate
    mono-safety choice, not just a conservative default.
  - For the FDN tank itself: decorrelated L/R tank outputs sum to mono fine
    (no comb-filter cancellation, because the two channels are diffuse noise-
    like signals, not a single delayed copy) but drop roughly 3 dB in
    perceived level when summed — expected FDN behavior, not a bug, and
    worth a one-line note in the implementation so it isn't mis-filed as a
    level regression later.
- **Binaural / HRTF** — not something we need to build: **Apple already
  ships an HRTF renderer inside `AVFAudio`** (the framework `DAWEngine`
  already wraps), via `AVAudioEnvironmentNode` /
  `AVAudio3DMixingRenderingAlgorithm.HRTF`.
  [Apple Developer docs](https://developer.apple.com/documentation/avfaudio/avaudio3dmixingrenderingalgorithm/hrtf).
  If a future roadmap item wants a "headphone-optimized bounce," it is
  nearly free to wire up later; there is no current workflow need (we are a
  stereo-mixdown production DAW, not a spatial-audio authoring tool), so
  this is explicitly **not** something to build now.
- **Ambisonics** — **not worth it for us.** Ambisonics is a
  scene-based, speaker/HRTF-agnostic format built for VR/game audio and
  multichannel installation work; it requires a decoder pipeline, a
  fundamentally different mix-bus model (B-format channels, not L/R), and
  buys nothing for a 2-channel-centric music production workflow. No product
  studied in §6 (a DAW reverb/delay peer group) implements it. Flag as a
  deliberate non-goal, not an oversight.

## 6. Product study — who's known for what, and the abstraction pattern

The through-line worth internalizing: **every product that is well-regarded
for musicality collapses a large internal parameter space into a handful of
named, unit-bearing or clearly-scoped knobs** — which is exactly what an
agent needs, because "reason about 5 named things" is tractable and "reason
about 20 raw DSP coefficients" is not.

| Product | Known for | Abstraction pattern |
|---|---|---|
| **Valhalla Room / VintageVerb** | algorithmically-modeled classic hardware character (VintageVerb explicitly models the "worse" sound of 1970s–80s digital reverbs as a *feature*) | Mode selects the era/character; a small shared knob set (Decay, Mix, Predelay, Mod) tunes any mode |
| **Valhalla Shimmer** | the canonical shimmer plugin | Pitch shifter *inside* the feedback loop (§3); reverb tuned to tolerate high feedback with a pitch shifter in it |
| **Valhalla Supermassive** | huge, evolving delay/reverb hybrid textures, free | `MODE` (algorithm), `DELAY` (longest FDN line, ms, tempo-syncable), `WARP` (spreads delay-line lengths — 0% uniform → >50% "more reverberant"), `FEEDBACK`, `DENSITY` (echo count, parallel→mixed), `MOD Rate/Depth`. This is the best single case study of an FDN's internals (line lengths, feedback, mixing topology) turned into ~7 named knobs. [Source](https://valhalladsp.com/2020/05/06/valhallasupermassive-the-controls/). |
| **FabFilter Pro-R** | "musical" reverb via aggressive abstraction | `Decay Rate` (50–200% of the algorithm's base decay), `Brightness` (HF decay + tilt EQ combined into one knob), `Character` (clean → lively reflections → over-modulated chorus — diffusion *and* modulation depth in one control), `Distance` (early-reflection prominence), and the standout: **"Decay Rate EQ"**, a decay-time-vs-frequency curve drawn directly as a graphic EQ rather than exposed as separate multiplier numbers. [Manual PDF](https://www.fabfilter.com/downloads/pdf/help/ffpror2-manual.pdf). |
| **Eventide Blackhole** | "alien"/sound-design reverb, deliberately abstracted | `Gravity` *deliberately* combines density and decay time into one knob, and doubles as forward/reverse-style behavior depending on direction from center; `Size` trades build-up speed against tinniness; `Mix`; `Mod Rate/Depth`. [Quick guide](https://www.eventideaudio.com/downloads/blackhole-quick-guide/). |
| **Eventide H3000** | historical: pitch-shift/delay/reverb combined in one modular unit (1986); the shimmer-plugin ancestor | N/A — architecture precedent, not an abstraction case study |
| **Lexicon 480L / "Random Hall"** | reference hardware for hall reverb since 1986 (David Griesinger); Random Hall solved chorus-modulation metallic ringing with denser, better-distributed modulation rather than louder chorus | Historical/technical precedent for §1.2/§3's modulation discussion |
| **EMT 140** | first practical plate reverb (1957) | Physical-model precedent; a well-tuned FDN/Dattorro tank approximates its density/brightness without needing a physical model |
| **Strymon BigSky** | 12 named "machines" (Room/Hall/Plate/Spring/Swell/Bloom/Cloud/Chorale/Shimmer/Magneto/Nonlinear/Reflections), 7 shared knobs | The cleanest PRESET-selects-family + shared-PARAM-set-tunes-it pattern; `Swell`/`Bloom` are the blooming-envelope machines (§3) |
| **Soundtoys EchoBoy** | 30 named "styles" modeling specific vintage delay hardware (tape, BBD, EchoPlex, Space Echo/RE-201, Memory Man) plus a Style Editor | Validates a `character` enum (PRESET) as the right shape for delay hardware-modeling, with continuous knobs (drive, wow/flutter depth) layered on top |
| **Ableton Hybrid Reverb** | combining convolution + algorithmic in one device | See §1.6; IR reshaped by 3 envelope params rather than exposed as raw audio |
| **Logic ChromaVerb** | Apple's own; a strong macOS-native parity reference | Main view: `Attack, Size, Density, Distance, Decay`; Details view: `Width, Quality, Modulation`, plus an editable output EQ graph. [Apple Support](https://support.apple.com/guide/logicpro/chromaverb-overview-lgcp18cc0940/mac). |
| **Logic Space Designer** | convolution-based, deep IR editing (envelope, EQ, multiple IR blend) | Precedent for §11's "reshape the IR with a few envelope params" pattern |
| **AMS RMX16** | defined the 80s gated-drum sound (`Non Lin 2`) | See §3 |
| **Apple `AUMatrixReverb`/`AVAudioUnitReverb`** | free, zero-dev-cost, already loadable in our own `AVAudioEngine` stack | **Worth naming explicitly as the "why build our own" foil**: the Swift-native `AVAudioUnitReverb` wrapper exposes only `loadFactoryPreset(_:)` (13 canned room/hall/plate/cathedral presets) and a wet/dry mix property — roughly *1.5 controls total*. The lower-level `AUMatrixReverb` AU component has more parameters (dry/wet mix, decay-time-vs-frequency, size, pre-delay), but hosting it means routing through our separate AU-parameter-bridge machinery (`docs/research/design-au-parameter-surface.md`) rather than our existing atomic-POD-publish/automation-overlay path, for a result that is *still* less granular and less LLM-legible than a purpose-built FDN with named, documented, unit-bearing params. (Exact Apple constant/property names — e.g. whether the Swift property is `wetDryMix` vs `dryWetMix`, and macOS vs. iOS availability of `Reverb2` — should be re-verified directly against current Apple Developer documentation before any implementation; see the hedge in §12.) Apple's 23 built-in AU effects are measured working and fast to load on this machine — so this isn't "unavailable," it's "available and not good enough for the control surface we're selling." |

**What users complain about (2026-09-19 spot check, general orientation
rather than exhaustive):** convolution reverb is the most consistently
cited CPU complaint — Space Designer is repeatedly described as heavier
than algorithmic alternatives like ChromaVerb precisely *because* it's
IR-based, reinforcing §11's "algorithmic primary, convolution optional"
call. FabFilter Pro-R, despite excellent technical control, draws comments
that it's light on *creative*/modulation-heavy territory (shimmer, extreme
modulation) compared to Valhalla's line — evidence that a clean, well-
abstracted parametric core (what we're proposing) still needs the creative
modes in §3 (shimmer, freeze, gated) layered on top, not as an afterthought.
Preset browsing is a recurring soft complaint across products ("kept coming
back to the default") — a mild point in favor of shipping few, well-chosen
defaults per §10 rather than a large preset library as the primary UX.
[VI-Control Pro-R 2 thread](https://vi-control.net/community/threads/fabfilter-pro-r-2-coming-november-2nd-edit-now-released.145162/page-2),
[Production Expert, Space Designer vs. ChromaVerb](https://www.production-expert.com/production-expert-1/when-do-you-use-space-designer-for-reverb-and-when-do-you-use-chromaverb-see-if-our-expert-panel-agrees-on-the-answer).

## 7. Ducking / sidechained reverb and delay

We already have the seam. `EffectDescriptor.sidechainSourceTrackID`
(`Sources/DAWCore/Effects.swift:73`) lets any effect's detector listen to
another (non-bus) track's post-fader output instead of its own signal;
`ProjectStore.setSidechain` enforces validity (non-bus source, `.audio`/
`.bus` destination strip, no cycles, one per strip) but **currently
whitelists only `compressor`/`gate` kinds**.

Ducked reverb/delay ("keep the vocal clear, keep the wet") does not need a
second detector implementation — it needs the *same* envelope-follower
math already driving compressor gain reduction, applied to the wet-signal
gain (or, more surgically, to the reverb's `mix`/delay's `feedback`) instead
of to a compressor's gain-reduction curve. Concretely: add `.reverb`/
`.delay` (and the proposed new kinds) to the sidechain-kind whitelist, and
add a small additive param set — `duckAmount` (0…1, how much the detector's
gain reduction is applied to the wet path), `duckThresholdDb`,
`duckReleaseMs` — mirroring `CompressorParams`' existing shape so the mental
model (and likely much of the detector code) transfers directly. This is
the cheapest single item in this whole report: it reuses routing UI, the
MCP tool surface, the wire validation, and the detector DSP, and only needs
new terminal application logic in `ReverbEffect`/`DelayEffect`.

## 8. Gap table

*(mandatory column: how an LLM would drive this — as a PARAM it sets a
number/enum directly, as a MODULATOR it's an automatable target an agent
reasons about over time, as a PRESET it's a named macro an agent picks
instead of tuning raw values.)*

| Feature | Known for | Musical payoff | DSP complexity | LLM control mode |
|---|---|---|---|---|
| Independent size vs. decay (RT60) | ChromaVerb, FabFilter Pro-R, Blackhole | High | Medium (FDN line lengths + derived absorption gain) | PARAM (two numbers) |
| Frequency-dependent RT60 (low/high decay mult.) | FabFilter Pro-R ("Decay Rate EQ"), LiquidSonics Reverberate | High | Medium (shelf in each line's feedback path) | PARAM (2 multipliers + 2 crossovers) |
| Early/late reflection balance | FabFilter (`Distance`), Blackhole (`Gravity`, coupled) | Medium | Low–medium | PARAM |
| Diffusion / density | ChromaVerb (`Density`) | Medium | Low | PARAM |
| Tail modulation (anti-metallic) | Valhalla (all products), Lexicon Random Hall | High (quality floor, not a "feature") | Low — reuse `ChorusEffect`'s interpolated-LFO line | PARAM (rate + depth) driving an internal MODULATOR |
| Tempo-synced pre-delay | less common; worth differentiating on | Medium | Low — reuse `NoteDivision`/`DelayTempoSync` | PARAM (bool + division, existing enum) |
| Shimmer (pitch-shifted feedback) | Valhalla Shimmer, Eventide Blackhole/H3000, Strymon BigSky | High (marketing + creative) | Medium–high (de-glitched pitch shifter in the loop) | PRESET (mode on/off) + PARAM (interval, amount) |
| Reverse reverb | universal technique, tape-era origin | Medium | Low, but **not a real-time param** — needs offline bounce | OPERATION (clip-level, not an insert control) |
| Gated reverb | AMS RMX16 | Medium (genre/retro-specific) | Low — reuse existing `CompressorParams`/`GateParams` math internally | PARAM (hold + release, 2 numbers) |
| Freeze / infinite hold | Valhalla, Eventide, most modern reverbs | Medium–high (great agent trick: "hold this chord forever") | Low (feedback→~1, bypass decay filters) | PARAM (bool), ideal MODULATOR target for automation |
| Blooming / swell | Strymon BigSky (`Bloom`/`Swell`), Blackhole (`Gravity` reversed) | Low–medium (niche but distinctive) | Medium (attack envelope on tank amplitude) | PRESET |
| Spring / plate character | Fender spring, EMT 140 | Low–medium (vintage/guitar market) | Medium (dispersion allpass for spring; tuning-only for plate) | PRESET |
| Dark hall vs. bright chamber | universal; FabFilter `Brightness` | High | Low (falls out of the frequency-dependent RT60 work above) | PARAM (one knob wrapping two multipliers) |
| Tape delay (wow/flutter/saturation/self-osc) | Soundtoys EchoBoy, Strymon El Capistan | High | Medium — reuse `ChorusEffect`'s LFO-line pattern + existing `SaturatorParams` tanh | PRESET (`character`) + PARAM (depth) |
| BBD / analog delay character | Boss DM-2, EchoBoy "styles" | Medium | Medium (noise floor + companding-style filtering model) | PRESET |
| Multi-tap delay | Valhalla Delay, most pro delays | Medium | Low–medium (multiple read offsets on one line) | PARAM (tap count + spread) |
| Diffusion / granular delay | Valhalla Delay (`Diffusion` mode) | Medium | Medium (small internal diffuser or granular engine) | PARAM |
| Dub-style filtered feedback | King Tubby / dub production tradition | Medium | Low — add low-cut-in-feedback + reuse `SaturatorParams` | PARAM |
| Ducking (reverb + delay) | universal mixing technique | High | Low — extend existing sidechain whitelist + reuse compressor detector | PARAM (amount, threshold, release) + MODULATOR (the detector envelope itself) |
| Stereo offset / cross-feedback | Valhalla, EchoBoy stereo modes, Haas effect | Medium | Low | PARAM |
| Mid/side width | (we already have this on reverb) | High | Already shipped | PARAM (existing) |
| True stereo (4-ch IR) | Altiverb-class convolution reverbs | Low for us now | High | N/A unless convolution ships (§11) |
| Binaural / HRTF | Apple `AVAudioEnvironmentNode` (already in our stack) | Low (no current workflow need) | Near-zero (OS-provided) | PRESET (mode toggle), deferred |
| Ambisonics | game/VR/installation audio | Very low for a stereo-centric DAW | High | Not recommended — non-goal |
| Convolution reverb (general IR) | Space Designer, Altiverb, Ableton Hybrid | Medium (character/realism) | High (partitioned convolution, IR mgmt, licensing) | PRESET only — opaque to an agent beyond naming |
| Hybrid convolution + algorithmic | Ableton Hybrid Reverb | Medium–high | High | PARAM (algorithmic tail) + PRESET (IR early reflections) |

## 9. Core algorithm recommendation

**Build an 8-to-16-line Feedback Delay Network (FDN) with an orthogonal
(Householder) mixing matrix, per-line two-band (low/high shelf) absorption
filters, and small time-varying modulation of each line's length, as a new
effect kind alongside — not replacing — the existing Freeverb `.reverb`.**

Justification against every alternative considered:

- **vs. keeping Freeverb as-is**: fails the #1 requirement (independent
  size/decay) structurally, not just by missing a parameter — the comb
  lengths are compile-time constants. No parameter addition fixes this
  without changing the topology.
- **vs. a from-scratch Dattorro/Griesinger plate**: a plate tank is a
  *constrained, 2-loop* FDN with fixed, well-known tuning constants. It is
  an excellent **second mode** once the general FDN machinery (per-line
  absorption filter math, length-modulation primitive, the params-and-wire
  plumbing) exists, because most of that machinery is shared — recommend it
  as a follow-up "Plate" character/preset on the same engine, not a
  competing build.
- **vs. a waveguide/scattering network**: materially higher design and CPU
  cost for room-acoustics-grade physical accuracy that neither musicians
  dialing in a mix nor an agent reasoning about "bigger/longer/brighter"
  reverb settings will use. Rejected.
- **vs. convolution as the primary engine**: rejected as *primary* — static,
  storage- and licensing-encumbered, and (this is the decisive factor given
  our stated positioning) the worst LLM-control surface of any option: an
  agent can pick a named IR but cannot reason continuously about it the way
  it can about FDN parameters. See §11 for the "maybe later, as a hybrid
  early-reflections layer" verdict.
- **vs. hosting Apple's `AUMatrixReverb`/`AVAudioUnitReverb`**: zero
  build cost, but (a) `AVAudioUnitReverb`'s Swift-level surface is presets
  + one mix knob — strictly worse than what we ship *today*; (b) even the
  lower-level AU component's param set is less granular than a purpose-built
  FDN's; (c) it would need to route through the separate AU-parameter-bridge
  machinery instead of our existing atomic-POD-publish/automation-overlay
  path that every other built-in effect (and its automation lanes) already
  uses, adding integration cost rather than saving it. Rejected as primary;
  remains available as third-party AU hosting for users who want it, same as
  today.

Why FDN specifically wins on the axes that matter for *this* product:
CPU is `O(N)` per sample for a Householder matrix (comparable to or cheaper
than our existing 8-comb+4-allpass Freeverb, not a regression); the
size/decay separation and frequency-dependent RT60 are structural properties
of the topology, not bolt-on features; the metallic-ringing fix (delay-line
length modulation) reuses a primitive (`ChorusEffect`'s interpolated,
LFO-driven line) that already exists in this codebase; and every parameter
in §10 below maps to a physically-motivated, named, unit-bearing quantity —
which is exactly the "few high-level controls an LLM can reason about, plus
optional deep ones" shape the product's design language and this report's
brief both call for.

## 10. Proposed parameter surface

Ship as **new `EffectDescriptor.Kind` cases** (placeholder names used below:
`hallReverb` for reverb, `tapeDelay` for delay — exact naming is
`daw-architect`/`docs-scribe` territory, deferred deliberately) with new
`Codable` param structs, following the existing additive-optional pattern
exactly (`hallReverb: HallReverbParams?` alongside the untouched `reverb:
ReverbParams?`). This is a wire-safety requirement, not a style preference:
the existing `.reverb`/`.delay` kinds have fixed automation slot orders
(0…4 in each `storeAutomatedParam`) and committed rendering behavior (the
`delayEchoLandsAtExactSampleOffset` pin); swapping their DSP out from under
those contracts would break existing automated projects and tests. A new
kind costs nothing and preserves everything, including the legacy kinds'
existing fields (e.g. `.delay`'s boolean `pingPong`, untouched below).

### 10.1 `HallReverbParams` (next-gen reverb)

**Core (the ~5 an agent reaches for first):**

| Name | Type/Range | Unit | Default | Notes |
|---|---|---|---|---|
| `mix` | 0…1 | fraction | 0.3 | dry/wet, same convention as today |
| `decaySeconds` | 0.1…20 | s | 1.8 | RT60 at the reference (1 kHz) band — independent of size |
| `sizeMeters` | 1…60 | m | 12 | maps to FDN line-length scale/mean free path; physically named so an agent can reason "concert hall" → ~30 m without needing a lookup table |
| `preDelayMs` | 0…250 | ms | 20 | kept from today's convention |
| `width` | 0…1.2 | fraction | 1.0 | M/S on wet, matches today; ceiling kept at 1.2 (not higher) for mono-compatibility reasons (§5) |

**Deep (additive optionals, nil = default, opt-in):**

| Name | Type/Range | Unit | Default | Notes |
|---|---|---|---|---|
| `preDelaySync` | Bool? | — | nil→false | reuse the `DelayParams.sync` precedent |
| `preDelayDivision` | `NoteDivision`? | — | nil→1/16 | reuse the existing type |
| `diffusion` | 0…1 | fraction | 0.7 | echo density / allpass amount |
| `earlyLateBalance` | -1…1 | fraction | 0 | negative = more early reflections (close/present), positive = more diffuse tail (far) |
| `lowDecayMultiplier` | 0.25…4 | × | 1.0 | RT60 scale below `lowCrossoverHz` |
| `highDecayMultiplier` | 0.1…1 | × | 0.5 | RT60 scale above `highCrossoverHz` — default <1 models natural air absorption |
| `lowCrossoverHz` | 50…1000 | Hz | 200 | |
| `highCrossoverHz` | 1000…16000 | Hz | 6000 | |
| `modRateHz` | 0.05…5 | Hz | 0.3 | tail-modulation LFO rate (anti-metallic) |
| `modDepthMs` | 0…5 | ms | 0.15 | tail-modulation depth |
| `freeze` | Bool | — | false | bypasses decay filters while active (§3 gotcha) |
| `shimmerMix` | 0…1 | fraction | 0 | 0 = off |
| `shimmerIntervalSemitones` | enum {+7, +12, +19, -12} | semitones | +12 | classic octave-up default |
| `duckAmount` | 0…1 | fraction | 0 | reuses the sidechain detector (§7) |
| `duckThresholdDb` | -60…0 | dB | -24 | mirrors `CompressorParams` shape |
| `duckReleaseMs` | 10…2000 | ms | 250 | mirrors `CompressorParams` shape |

### 10.2 `TapeDelayParams` (next-gen delay)

A new kind, coexisting with the legacy `.delay`/`DelayParams` — the legacy
kind's `pingPong` boolean is untouched; the new kind does not carry it,
replaced by the continuous `crossFeedback` below (`crossFeedback = 1.0`
reproduces the legacy "on" behavior).

**Core:**

| Name | Type/Range | Unit | Default | Notes |
|---|---|---|---|---|
| `timeMs` | 1…4000 | ms | 350 | extends today's 2000 ms ceiling for dub-style long delays |
| `feedback` | 0…1.05 | fraction | 0.35 | >1 permitted; internal saturation prevents runaway blowup, models tape self-oscillation |
| `mix` | 0…1 | fraction | 0.3 | |
| `sync` / `division` | reuse `DelayParams` fields | — | nil→false / 1/4 | identical mechanism, no new plumbing |

**Deep:**

| Name | Type/Range | Unit | Default | Notes |
|---|---|---|---|---|
| `character` | enum {digital, tape, bbd, dub} | — | digital | selects a saturation+filter macro; one param instead of five |
| `wowDepth` | 0…1 | fraction | 0 (0.15 for tape/bbd presets) | slow LFO on the read pointer |
| `flutterDepth` | 0…1 | fraction | 0 (0.1 for tape/bbd presets) | fast LFO on the read pointer |
| `saturationDrive` | 0…1 | fraction | 0.3 | reuses `SaturatorParams` tanh math in the feedback path |
| `lowCutHz` | 20…2000 | Hz | 20 (off) | NEW — complements existing `highCutHz`; needed for dub character |
| `highCutHz` | 500…20000 | Hz | 8000 | kept from today's convention |
| `crossFeedback` | 0…1 | fraction | 0 | continuous generalization of the legacy boolean `pingPong` |
| `stereoOffsetMs` | -50…50 | ms | 0 | independent L/R time offset; Haas-effect range (§5) documented in the param description, including the mono-compatibility caveat |
| `multiTapCount` | 1…4 | int | 1 | |
| `tapSpreadMs` | 0…2000 | ms | 0 | only meaningful when `multiTapCount` > 1 |
| `diffusion` | 0…1 | fraction | 0 | small internal allpass diffuser, pseudo-reverb blur |
| `duckAmount` / `duckThresholdDb` / `duckReleaseMs` | same shape as reverb | — | 0 / -24 dB / 250 ms | reuses the sidechain detector (§7) |

Every deep param above is additive-optional and nil-defaults to *today's*
behavior where a direct analog exists — the design intentionally mirrors the
`sync: Bool?`/`division: NoteDivision?` precedent in `DelayParams` so a
reviewer can pattern-match the safety argument instantly.

## 11. Convolution verdict

**Not now, as a primary engine. Worth adding later, narrowly, as an
optional early-reflections layer feeding the FDN's tail (the Ableton Hybrid
Reverb shape, §1.6) — not as a general user-loadable-IR reverb.**

Costs, concretely:

- **CPU/latency**: real-time convolution reverb requires **partitioned
  convolution** (Gardner's 1995 non-uniform partitioning is the standard
  approach — small early partitions for low latency, larger later partitions
  processed less often for CPU efficiency).
  [Gardner 1995 context](https://link.springer.com/article/10.1007/s11760-012-0387-0).
  This is a meaningfully larger implementation than anything else in this
  report — FFT-domain block processing, off-thread partition scheduling, and
  a latency value that is nonzero for anything beyond the first partition
  (our `latencySamples`/PDC machinery has a home for this — PDC for hosted
  AU inserts is already measured sample-exact — but it's new work, not
  reuse).
- **IR storage**: a usable curated set (even a modest "10 great spaces")
  is easily tens to low-hundreds of MB uncompressed at production sample
  rates and multi-second tail lengths; this is a real app-bundle-size cost
  that none of our other reverb/delay work incurs.
- **Licensing (checked 2026-09-19, re-verify before shipping — terms like
  these rot)**: this is the sharpest constraint.
  [OpenAIR](https://www.york.ac.uk/physics-engineering-technology/research/communication-technologies/projects/open-acoustic-impulse-response-library/)
  (University of York) is the credible free/legitimate source — recordings
  are **individually** licensed (mostly Creative Commons, commonly CC BY
  4.0, but license terms are set *per contributor per recording*, so each IR
  we'd bundle needs its own license check, not a blanket assumption).
  By contrast, the widely-circulated "free" clones of commercial hardware
  (e.g. Samplicity's Bricasti M7 impulse responses) are **unauthorized
  derivatives of a manufacturer's proprietary product** — there is no
  license grant from Bricasti Design backing their redistribution, and
  bundling them in a commercial DAW carries real legal risk distinct from
  the "personal hobby project" context they usually circulate in. Any IR
  set we ship needs either (a) OpenAIR-sourced recordings with per-IR
  license verification, (b) recordings we make ourselves, or (c) a paid
  commercial license — all three are viable but none is "just download and
  bundle," which is the trap worth flagging explicitly.
- **True stereo doubling**: if we do this, a "true stereo" (4-channel) IR
  option roughly doubles convolution cost per instance vs. standard stereo
  (§5) — worth exposing as an explicit quality/CPU trade-off toggle, not a
  silent default.

Why not as primary even setting cost aside: an IR is, from an agent's
perspective, an opaque blob. Ableton's own answer — reshape the IR with a
small number of envelope parameters (`Attack`/`Decay`/`Size`) and keep the
*tail* algorithmic — is the one worth copying if/when this ships, because it
keeps the part of the signal chain an agent reasons about most (the tail's
size/decay/character) on the parametric engine we're already building, and
confines the opaque IR to shaping only the early-reflection color.

## 12. Sources

- Dattorro, J. (1997). "Effect Design, Part 1: Reverberator and Other
  Filters." *J. Audio Eng. Soc.* 45(9). [PDF](https://ccrma.stanford.edu/~dattorro/EffectDesignPart1.pdf)
- Smith, J.O. "FDN Reverberation," *Physical Audio Signal Processing*, CCRMA.
  [Link](https://ccrma.stanford.edu/~jos/pasp/FDN_Reverberation.html)
- Smith, J.O. "Freeverb," *Physical Audio Signal Processing*, CCRMA.
  [Link](https://ccrma.stanford.edu/~jos/pasp/Freeverb.html)
- Schlecht, S. & Habets, E. "Circulant and Elliptic Feedback Delay Networks
  for Artificial Reverberation." [PDF](https://citeseerx.ist.psu.edu/document?doi=e69cb5643d81264ed96201e31cef7a7d375408bb&repid=rep1&type=pdf)
- De Sena et al. "Efficient Synthesis of Room Acoustics via Scattering Delay
  Networks." [arXiv:1502.05751](https://arxiv.org/pdf/1502.05751)
- Erbe, T. "Reverb Topologies and Design," UC San Diego course notes.
  [PDF](https://tre.ucsd.edu/wordpress/wp-content/uploads/2018/10/reverbtopo.pdf)
- Valhalla DSP. "Reverbs: Diffusion, allpass delays, and metallic
  artifacts" (2011). [Link](https://valhalladsp.com/2011/01/21/reverbs-diffusion-allpass-delays-and-metallic-artifacts/)
- Valhalla DSP. "ValhallaSupermassive: The Controls" (2020).
  [Link](https://valhalladsp.com/2020/05/06/valhallasupermassive-the-controls/)
- Valhalla DSP. "ValhallaShimmer: The Controls" (2010).
  [Link](https://valhalladsp.com/2010/11/27/valhallashimmer-the-controls/)
- Valhalla DSP. "ValhallaShimmer: a bit of history" (2010).
  [Link](https://valhalladsp.com/2010/11/23/valhallashimmer-a-bit-of-history/)
- FabFilter. Pro-R 2 manual. [PDF](https://www.fabfilter.com/downloads/pdf/help/ffpror2-manual.pdf)
- VI-Control forum. "FabFilter Pro-R 2 coming November 2nd" (user
  discussion, creative/modulation limitations). [Link](https://vi-control.net/community/threads/fabfilter-pro-r-2-coming-november-2nd-edit-now-released.145162/page-2)
- Production Expert. "When do you use Space Designer for reverb and when do
  you use ChromaVerb." [Link](https://www.production-expert.com/production-expert-1/when-do-you-use-space-designer-for-reverb-and-when-do-you-use-chromaverb-see-if-our-expert-panel-agrees-on-the-answer)
- Apple. "ChromaVerb overview," Logic Pro documentation.
  [Link](https://support.apple.com/guide/logicpro/chromaverb-overview-lgcp18cc0940/mac)
- Eventide. Blackhole Quick Guide. [Link](https://www.eventideaudio.com/downloads/blackhole-quick-guide/)
- Reverb.com. "The Eventide H3000: The Tech Behind the Classic Studio."
  [Link](https://reverb.com/news/tech-behind-eventide-h3000-ultra-harmonizer)
- Ableton. "Hybrid Reverb FAQ." [Link](https://help.ableton.com/hc/en-us/articles/360019484980-Hybrid-Reverb-FAQ)
- Strymon. BigSky User Manual. [PDF](https://www.strymon.net/manuals/BigSky_UserManual_RevD.pdf)
- Soundtoys. EchoBoy User's Guide v5. [PDF](https://www.soundtoys.com/wp-content/uploads/EchoBoy-Manual.pdf)
- Reverb.com. "How the AMS RMX16 Defined a Generation of Drum Sounds."
  [Link](https://reverb.com/news/how-the-ams-rmx16-defined-a-generation-of-drum-sounds)
- Wikipedia. "Gated reverb." [Link](https://en.wikipedia.org/wiki/Gated_reverb)
- Spin Semiconductor forum. "infinite FREEZE reverb."
  [Link](http://www.spinsemi.com/forum/viewtopic.php?t=442)
- Universal Audio. "Origins of EMT Reverb."
  [Link](https://www.uaudio.com/blogs/ua/emt-reverb-history)
- Wikipedia. "Bucket-brigade device." [Link](https://en.wikipedia.org/wiki/Bucket-brigade_device)
- Science of Dub. "Dub Delay" (2026).
  [Link](https://scienceofdub.com/2026/01/19/dub-delay/)
- Wikipedia. "Precedence effect." [Link](https://en.wikipedia.org/wiki/Precedence_effect)
- Gardner, W. "Efficient convolution without input-output delay" (1995),
  as discussed in: "A low latency implementation of a non-uniform
  partitioned convolution algorithm for room acoustic simulation," *Signal,
  Image and Video Processing*. [Link](https://link.springer.com/article/10.1007/s11760-012-0387-0)
- University of York. "Open Acoustic Impulse Response Library (OpenAIR)."
  [Link](https://www.york.ac.uk/physics-engineering-technology/research/communication-technologies/projects/open-acoustic-impulse-response-library/)
- Apple Developer Documentation. `AVAudio3DMixingRenderingAlgorithm.HRTF`.
  [Link](https://developer.apple.com/documentation/avfaudio/avaudio3dmixingrenderingalgorithm/hrtf)
- Apple Developer Documentation. `AUMatrixReverb` parameters /
  `AVAudioUnitReverbPreset` (parameter/property names cross-referenced via
  search-indexed Apple docs and community sources rather than a full direct
  fetch of Apple's live reference pages on 2026-09-19 — **treat exact
  property names, `kReverb2Param_*` constants, and macOS-vs-iOS component
  availability as needing a direct-source re-check before implementation**).

In-repo sources (verified by direct read, 2026-09-19):
`Sources/DAWCore/Effects.swift`, `Sources/DAWEngine/Effects/ReverbEffect.swift`,
`Sources/DAWEngine/Effects/DelayEffect.swift`,
`Sources/DAWEngine/Effects/ChorusEffect.swift`,
`Sources/DAWCore/DelayTempoSync.swift`.

## Actionable takeaways

1. **Ship a new reverb effect kind (`hallReverb` or similar), not a rewrite
   of `.reverb`.** Additive `EffectDescriptor.Kind` case + new `Codable`
   params struct, following the exact `gain: GainParams?` /
   `sync: Bool?` precedents already in this codebase. Route:
   `audio-dsp-engineer` for the FDN core (Householder matrix, per-line
   two-band absorption filters, length modulation reusing `ChorusEffect`'s
   interpolated-line pattern), `daw-architect` for the wire/kind-naming
   decision, `mcp-integration-engineer` for the control-protocol command +
   MCP tool once the params are frozen.
2. **Cheapest high-value item in this report: extend the sidechain
   whitelist.** `ProjectStore.setSidechain` currently allows only
   `compressor`/`gate` kinds; adding `.reverb`/`.delay` plus a `duckAmount`/
   `duckThresholdDb`/`duckReleaseMs` param triple reuses the existing
   detector, routing UI, and MCP surface almost entirely. Recommend this as
   a near-term, low-risk roadmap item independent of the larger reverb
   rebuild.
3. **Reuse `ChorusEffect`'s fractional-delay + LFO pattern as the shared
   primitive** for: reverb tail modulation (anti-metallic), tape delay
   wow/flutter, and BBD pitch wobble. One primitive, three features — flag
   this explicitly to whichever agent builds any of the three so it isn't
   reinvented per-effect.
4. **Reuse `SaturatorParams`' tanh math** inside the delay's feedback path
   for tape self-oscillation and dub-style warmth, rather than writing new
   saturation code.
5. **Reverse reverb is a clip/region bounce operation, not an insert
   parameter** — route it through the existing offline-render path as a
   menu action, not as a `ReverbParams` field. Worth a small design note
   before anyone tries to build it as a real-time knob and discovers it
   can't be causal.
6. **Convolution: defer.** If/when it's prioritized, scope it as the
   Ableton Hybrid Reverb shape (IR shapes early reflections only, algorithmic
   FDN owns the tail) rather than a general user-loadable convolution
   reverb, and budget for (a) partitioned-convolution engineering effort
   distinct from everything else in this report, (b) per-IR license
   verification if sourcing from OpenAIR, and (c) explicitly declining any
   unauthorized-clone IR sets (e.g. Samplicity-style hardware clones) as a
   legal-risk, not just a quality, decision.
7. **Ambisonics: explicit non-goal**, documented here so it doesn't get
   re-proposed without this reasoning being re-derived. **Binaural/HRTF**:
   not now, but cheap later — `AVAudioEnvironmentNode`'s HRTF renderer is
   already inside our own `AVFAudio` dependency.
8. **Reverb pre-delay should get the same tempo-sync treatment delay time
   already has** (`sync: Bool?` / `division: NoteDivision?`), reusing
   `NoteDivision`/`DelayTempoSync` rather than a second sync mechanism.
9. Before implementing against Apple's `AUMatrixReverb`/`AUReverb2` for
   *anything* (e.g. as a hosted-AU fallback character), re-verify the exact
   parameter/property names and macOS-vs-iOS availability directly from
   Apple's developer documentation — this report's citation for that table
   is secondary-source and flagged accordingly in §12.
10. **Mono-compatibility guardrails are cheap to bake in now**: keep the
    new reverb's `width` ceiling at 1.2 (not higher), document the delay's
    `stereoOffsetMs` as a mono-collapse hazard above ~35 ms in the param's
    own description (so an agent reading the param surface sees the
    warning inline), and expect (don't flag as a bug) a ~3 dB level drop
    when a decorrelated FDN tail is summed to mono.
