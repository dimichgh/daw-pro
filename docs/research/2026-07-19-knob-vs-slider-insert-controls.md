# Knob vs. slider conventions for insert-effect panels — a redesign map for DAW Pro's Effect Editor

**Date:** 2026-07-19
**Trigger:** redesign sprint — move the built-in Effect Editor (`Sources/DAWApp/Mixer/EffectEditorOverlay.swift`, shipped per `docs/research/2026-07-15-insert-editor-ux.md` m17-a) from its v1 flat list of identical horizontal sliders toward a vertical, knob-first layout matching professional DAW/plugin convention.
**Scope:** the 9 built-in effect kinds only (`gain, eq, compressor, limiter, reverb, delay, saturator, gate, chorus`); hosted AUs keep their native windows and are out of scope (M3 vi-b).

## 0. Baseline — what's actually in code today

- `EffectParamSpec.specs(for:)` (`Sources/DAWCore/Effects.swift:482-592`) is the single source of truth for every built-in kind's parameters (name/range/default/unit) — the same table `fx.describe` serializes (`Sources/DAWControl/Commands.swift:1067`) and the MCP tool schema reads.
- `EffectEditorOverlay.swift` renders **one row per spec, in schema order, every row an identical `ValueSlider`** (`Sources/DAWApp/Components/ValueSlider.swift`) — a thin horizontal Canvas-drawn bar, no distinction between a frequency, a threshold, a time constant, or a mix knob. Card is fixed at 420 pt wide (`EffectEditorOverlay.swift:35`), rows capped at 460 pt total scroll height.
- `EffectEditorModel` (`Sources/DAWAppKit/EffectEditorModel.swift`) already does real work that a knob redesign can reuse as-is: **log-scale travel for Hz-unit params** (`scale(for:)`, line 163 — "musical octaves read evenly across the travel"), a **kind-keyed value reader/writer** wired to `store.setEffectParam`/`setMasterEffectParam` (the exact `fx.setParam` methods — zero wire changes needed for a UI-only redesign), humanized labels, and a `readout(value:spec:)` formatter (dB/Hz-kHz/ms/s/ratio/linear).
- Two reusable rotary/vertical primitives already exist and were built for exactly this vocabulary: **`PanKnob`** (`Sources/DAWApp/Mixer/MixerControls.swift:99` — Canvas-drawn rotary, 270°-ish arc, center-out bipolar fill, vertical-drag gesture, ⌥ fine, double-click reset) and **`VerticalFader`** (`MixerControls.swift:15` — long-throw vertical groove + cap + glow, same gesture contract). A knob-first Effect Editor is mostly "generalize `PanKnob` into a value-range `KnobControl`" work, not new interaction design.
- No per-effect gain-reduction metering exists anywhere in the engine (`grep -r "gainReductionDb\|GainReduction" Sources` → zero hits, reconfirmed today) — this gates any "threshold slider ringed by/paired with a meter" upgrade (§4) until that surface ships; flagged as a dependency, not a blocker for the knob-layout work itself.

## 1. Convention — what gets a KNOB

Verified across manufacturer docs/manuals and UI galleries, knobs dominate for parameters that are (a) a *rotary pot* on the hardware being modeled, (b) adjusted by *relative* nudge rather than absolute position, or (c) need a small footprint so many can sit side by side:

- **Gain/drive/trim amounts** — universal knob: Logic's Gain/Trim utility, every saturation plugin (Decapitator, Soundtoys, UAD tape/tube sims) puts Drive as a rotary control you turn up.
- **Frequency (EQ band center, filter cutoff, delay high-cut)** — knob on essentially every parametric EQ lineage (Pultec, API 550, Neve 1073, SSL 4-band) and reproduced that way in plugin form (SSL/Waves channel strips combine "a four-band EQ, high-pass and low-pass filters... input/output gain" as knobs) — [Waves SSL E-Channel](https://www.waves.com/plugins/ssl-e-channel).
- **Q/bandwidth** — knob, paired with its band's freq/gain knobs (never gets its own separate widget type).
- **Ratio, attack, release, hold, knee** (compressor/gate/limiter time & curve constants) — knob is the near-universal hardware-lineage default: the 1176's ratio is 4 discrete buttons but every *continuous*-ratio design (FabFilter Pro-C, Waves, UAD softknee models, SSL Native) uses a rotary Ratio knob; attack/release are rotary on the 1176, LA-2A, dbx, SSL bus comp, and FabFilter Pro-C3 alike — [FabFilter Pro-C 3 dynamics/time controls](https://www.fabfilter.com/help/pro-c/using/dynamicscontrols), [FabFilter Pro-C 3 time controls](https://www.fabfilter.com/help/pro-c/using/timecontrols), [UA 1176 manual](https://help.uaudio.com/hc/en-us/articles/34530260482324-1176-Classic-FET-Compressor-Manual).
- **Wet/dry mix, feedback/regen** — knob, effect-type-agnostic (reverb, delay, chorus, saturator all treat Mix as a single rotary control in FabFilter/Soundtoys/Valhalla-class designs).
- **Pan, stereo width** — knob; bipolar around a center detent is the PanKnob shape already in DAW Pro.
- **Saturation/character/room-size/damping "amount" knobs** — same family as drive: a single rotary "how much" control.

**Why knobs, consistently:** (1) hardware lineage — the plugin is modeling a rotary pot users already know (1176/LA-2A/SSL/Pultec); (2) compact footprint — many knobs fit shoulder to shoulder where sliders would need 3-5x the width; (3) most are adjusted by feel/relative drag, not by reading an absolute ruler position; (4) vertical-drag-to-turn is the near-universal software-knob gesture (no one actually drags in a circle with a mouse) — confirmed by the NN/G writeup: *"virtual knobs are physically challenging to manipulate with common input devices... hidden vertical-drag functionality often goes undiscovered"* — [NN/G: Sliders, Knobs, and Matrices](https://www.nngroup.com/articles/sliders-knobs/). DAW Pro's `PanKnob` already implements the correct vertical-drag mapping, so this specific ergonomics risk is pre-solved.

## 2. Convention — what gets a SLIDER/FADER

- **Channel volume fader** — universal, always a long-throw vertical slider (DAW Pro's own `VerticalFader` already matches this; out of scope here — it's a mixer-strip control, not an insert-effect param).
- **Graphic EQ band gains** (many fixed-frequency bars, e.g. classic 10/31-band graphic EQs) — vertical sliders in a row, specifically because **cross-band comparison at a glance** is the point; a row of knobs can't be read as a "curve shape" the way a row of fader caps can.
- **Envelope segment editors** (ADSR breakpoints, automation) — not sliders in the literal sense but the same "absolute position readability" logic applies; out of scope for insert effects (DAW Pro has none of these as effect params).
- **Threshold / ceiling, in specific modern & mastering-tool designs** — see §4, the real split case.
- **Vertical vs horizontal:** vertical faders read as "how much signal" (gravity-coded — up is more, matching a physical fader/VU needle), used for level-like absolute-position params (volume, and threshold-with-meter designs below); horizontal sliders appear mostly in **generic/fallback editors** (Logic's "Controls" view, Cubase's "Generic Editor") where a flat parameter list needs *some* draggable widget and there's no room/need for per-parameter semantics — [Logic Pro "Controls" vs "Editor" view](https://www.logicprohelp.com/forums/topic/139245-switching-plug-ins-view-from-controls-to-editor/), [Cubase generic editor](https://forums.steinberg.net/t/how-to-display-generic-interface-for-vst-plugin/602420). **DAW Pro's current `ValueSlider`-for-everything layout is exactly this generic-fallback idiom** — correct as a v1 stopgap, not as the destination design.

## 3. Convention — neither (steppers/dropdowns/toggles/XY)

- **Discrete-step selectors**: the 1176's ratio is 4 physical buttons (4:1/8:1/12:1/20:1), toggleable together for "All-Button/British mode" — [Sweetwater: All-Button Mode](https://www.sweetwater.com/insync/all-button-mode/). Filter **slope** (12/18/24 dB/oct) and **oversampling** (1x/2x/4x) are near-universally discrete stepper/dropdown controls, never continuous knobs, because the values are categorical, not a continuum — [Denise Audio: filter slope](https://www.deniseaudio.com/blog-posts/filter-slope).
- **Toggles**: bypass (every plugin), phase/polarity invert, mono/stereo or ping-pong mode on delays (hardware precedent: the Roland Space Echo / Boss DD-series mono↔ping-pong control is a physical switch, not a knob).
- **XY pads**: interactive 2-parameter pads (e.g. Waves C1's threshold/ratio dot) exist but are a "curated v2" idiom, not a default — not relevant to a flat spec-driven v1/v2 generic layout.
- **DAW Pro today has none of the first two categories as real params** — no filter-slope, no oversampling, no stepped ratio (`ratio` is continuous 1...20) among the 9 built-ins. The **one exception is `pingPong`** on Delay (see §6) — it is already a binary control at the model layer (`self.pingPong = pingPong.clamped(to: Self.pingPongRange).rounded()`, `Sources/DAWCore/Effects.swift:346`) despite being declared as a continuous `0...1` spec, which is the strongest local evidence it should render as a **toggle**, not a knob or slider, in the redesign.

## 4. Threshold — the split case, and a recommendation

Threshold is genuinely bimodal in the field:
- **Knob** on hardware-lineage designs where there's no dedicated always-visible metering real estate next to the control: FabFilter Pro-C3's Threshold is a knob, but a distinctive one — *"a circular side-chain level meter around the Threshold knob shows the level of the... signal used for detection"* — the meter is fused into the knob's own ring, not a separate widget — [FabFilter Pro-C 3: dynamics controls](https://www.fabfilter.com/help/pro-c/using/dynamicscontrols).
- **Vertical slider integrated into the meter**, in mastering-limiter and "modern DAW-native" designs where threshold and output ceiling need to be read *in the same coordinate space* as the meter: Ableton's stock Compressor uses a Threshold **slider** directly beside its Gain Reduction meter — [MusicTech: compression/limiting in Live](https://musictech.com/tutorials/compression-and-limiting-demystified-in-ableton-live/). The clearest case is the Waves L1 Ultramaximizer: *"input meter... with an integrated threshold control"* and *"output meter... with an integrated output ceiling control"* — both Threshold and Ceiling are literally vertical sliders drawn **inside** the meter scale itself, specifically so pulling threshold down and watching ceiling/gain-reduction move is one continuous visual read — [Waves L1 Ultramaximizer manual](https://assets.wavescdn.com/pdf/plugins/l1-ultramaximizer.pdf).

**Why the split exists:** knob-with-ring-meter (Pro-C3) suits a *compact single-control* footprint; slider-in-meter (L1, Ableton Compressor) suits designs where threshold's absolute dB position relative to 0 dBFS, and its relationship to the moving gain-reduction/ceiling readout, is the entire point of looking at the control — i.e. exactly the "absolute position readability" criterion from §2.

**Recommendation for DAW Pro's compact 420 pt vertical card:**
- **v1 (ship with the knob redesign): Threshold (compressor + gate) and Ceiling (limiter) render as ordinary KNOBS**, consistent with every other dB-range param in the card and with the majority of hardware-lineage designs (1176, LA-2A, SSL, dbx) — DAW Pro has no gain-reduction metering surface today, so a meter-integrated slider would be an empty gesture (a slider "paired with metering" that has no metering to pair with).
- **v2 (sequenced after the previously-flagged `gainReductionDb` metering item, `2026-07-15-insert-editor-ux.md` §4.6/Actionable-4): promote Threshold (compressor/gate) and Ceiling (limiter) to a VerticalFader-style slider drawn inside a small vertical gain-reduction meter column** — reusing `VerticalFader`'s existing groove/cap/glow Canvas code, adding a second translucent fill layer for the live GR value. This is the Ableton/L1 pattern and is the single highest-value "knob vs slider" upgrade in the whole card once metering exists, because it's the one place absolute-position-vs-meter comparison genuinely beats a knob's relative dial.
- Everything else on compressor/gate/limiter (ratio, attack, release, hold, knee, makeup) stays a knob in both v1 and v2 — the split is specific to threshold/ceiling, not "all dynamics params."

## 5. Vertical panel layout conventions (channel-strip precedent)

- **Section order is always input → processing → output**, top to bottom on vertical strips: SSL's console signal flow is Input/Preamp → Dynamics (comp/gate) → EQ/Filter → Output (pan, VCA fader) — [SSL 4K Channel Strip user guide](https://support.solidstatelogic.com/hc/en-gb/articles/6887173070877-SSL-Channel-Strip-2-Plug-in-User-Guide). Cubase's fixed built-in Channel Strip rack is explicitly ordered Gate → Comp → Tools(EQ) → Sat → Limit, always in that order, always in the same slots (cited in `2026-07-15-insert-editor-ux.md` §2, [Steinberg: Channel Strip Modules](https://archive.steinberg.help/cubase_pro_artist/v9/en/cubase_nuendo/topics/mixconsole/mixconsole_channel_strip_modules_r.html)). FabFilter Pro-C3 groups its own controls the identical way inside ONE effect: *"Threshold, Ratio, Knee and Range control the triggering... Attack, Release, Lookahead and Hold affect the smoothing"* — trigger/shape params first, time-smoothing second, with output/makeup gain last — [FabFilter Pro-C 3 overview](https://www.fabfilter.com/help/pro-c/using/overview).
- **Label placement in tight columns is ABOVE the knob, abbreviated**, not beside it in a name column — real-estate-constrained hardware-style layouts (Softube Console 1-class designs) run out of room for full words: *"space between knobs can be tight... leaving no room for labels like 'Low,' 'hi,' 'thresh,' 'att'"* forces 3-6 character abbreviations placed directly under/over the control rather than a left-aligned label column — [gadgeteer.home.blog: SSL UC1 knobs](https://gadgeteer.home.blog/2022/12/14/what-do-all-the-knobs-do-on-the-ssl-uc1/). DAW Pro's current row layout (label in a fixed 104 pt LEFT column, `EffectEditorOverlay.swift:157`) is the generic-list idiom, not the channel-strip idiom — a knob-grid redesign should move the label under (or above) each knob.
- **Meter placement**: either a dedicated always-visible column at one edge of the strip spanning the section it reports on (SSL/Neve rack style), or fused directly into the most load-bearing knob/slider (Pro-C3's ring-around-threshold, L1's slider-in-meter, §4). For a 420 pt-wide DAW Pro card, the fused approach is the better fit once metering ships — a dedicated meter column competes with knob-grid width in a way full consoles don't have to worry about.
- **Grouping visually, not just logically**: every precedent above draws a hairline/spacing break between groups (SSL's physical section gaps, Pro-C3's two-row split) rather than one undifferentiated list — this is the single biggest legibility gap in the current flat `ValueSlider` list and the main thing "vertical layout with knobs" should fix.

## 6. Actionable mapping — every real DAW Pro effect parameter

Control-type key: **K** = knob (generalized `PanKnob`), **S↕** = vertical slider (`VerticalFader`-style), **T** = toggle, **—** = no current param needs a stepper/dropdown (see §3; only `pingPong` is a hidden-binary case, called out below). Groups are listed top→bottom in the recommended vertical order (input/trigger → processing/time → output), mirroring §5's input→processing→output rule; **OUTPUT/mix groups are last for every kind, with no exception** — this held across all 9 kinds and is worth stating as a hard layout rule for the implementer.

### `gain` (1 param)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `gainLinear` | 0...4, default 1 | K | `linear` (current); **recommend dB-equivalent readout** (`20·log10(gainLinear)`) to match every other trim/gain knob in the app — wire stays `linear`, only the label-side formatter changes | Single-knob card, no grouping needed |

### `eq` (10 params, 4 bands)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `lowShelfFreq` | 20...2000 Hz | K (log scale, already implemented) | Hz/kHz | **Group "LOW SHELF"** — Freq then Gain, leftmost/topmost (lowest frequency band first, matches schema + hardware left-to-right low→high convention) |
| `lowShelfGainDb` | ±24 dB | K (bipolar/center-out fill, PanKnob-style) | dB | same group |
| `peak1Freq` | 20...20000 Hz | K (log) | Hz/kHz | **Group "PEAK 1"** — Freq, Gain, Q as a trio (standard parametric-EQ band layout) |
| `peak1GainDb` | ±24 dB | K (bipolar) | dB | same group |
| `peak1Q` | 0.1...18 | K (unipolar sweep, min-start fill) | `linear` (bandwidth ratio — no unit token needed) | same group, third knob |
| `peak2Freq` | 20...20000 Hz | K (log) | Hz/kHz | **Group "PEAK 2"** — same trio shape |
| `peak2GainDb` | ±24 dB | K (bipolar) | dB | same group |
| `peak2Q` | 0.1...18 | K (unipolar) | `linear` | same group |
| `highShelfFreq` | 200...20000 Hz | K (log) | Hz/kHz | **Group "HIGH SHELF"** — last group, highest frequency band |
| `highShelfGainDb` | ±24 dB | K (bipolar) | dB | same group |

### `compressor` (6 params)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `thresholdDb` | -60...0 dB | **K in v1** (S↕-in-meter in v2, gated on gain-reduction metering — §4) | dB | **Group "TRIGGER"** — Threshold, Ratio, Knee (Pro-C3's own grouping) |
| `ratio` | 1...20 | K | `N.N:1` (current formatter already matches convention) | same group |
| `kneeDb` | 0...24 dB | K (smaller/secondary knob — least-used control) | dB | same group |
| `attackMs` | 0.1...200 ms | K | ms (sub-10 ms shows 1 decimal, already implemented) | **Group "TIME"** — Attack, Release |
| `releaseMs` | 5...2000 ms | K | ms | same group |
| `makeupDb` | 0...24 dB | K | dB | **Group "OUTPUT"** — last, alone |

### `limiter` (2 params)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `ceilingDb` | -24...0 dB | **K in v1** (S↕-in-meter in v2, same L1-precedent upgrade as threshold — §4) | dB | **Group "OUTPUT"** |
| `releaseMs` | 5...1000 ms | K | ms | **Group "TIME"** — only 2 params total; a 2-knob row is fine without a hard visual break, but keep Release visually before Ceiling per input→output |

### `reverb` (5 params)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `roomSize` | 0...1 | K | **recommend `%`** (currently raw 2-decimal `linear`) — wet/dry-style "amount" knobs read in % industry-wide | **Group "CHARACTER"** — Room Size, Damping, Width |
| `damping` | 0...1 | K | recommend `%` | same group |
| `width` | 0...1 | K | recommend `%` | same group |
| `preDelayMs` | 0...200 ms | K | ms | **Group "TIME"** — alone |
| `mix` | 0...1 | K | recommend `%` | **Group "OUTPUT"** — last |

### `delay` (5 params)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `timeMs` | 1...2000 ms | K | ms; consider crossing to `s` display above 1000 ms (parallels the existing Hz→kHz crossover in `readout(value:spec:)`) | **Group "TIME"** — alone, first (it's the defining param) |
| `feedback` | 0...0.95 | K | recommend `%` | **Group "REPEATS"** — Feedback, Ping-Pong, High Cut (shape the character of the repeats) |
| `pingPong` | 0...1, **rounded to 0 or 1 at the model layer** (`Effects.swift:346`) | **T** — binary already, should never have been a slider row | on/off (no numeric readout) | same group |
| `highCutHz` | 500...20000 Hz | K (log) | Hz/kHz | same group |
| `mix` | 0...1 | K | recommend `%` | **Group "OUTPUT"** — last |

### `saturator` (3 params)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `driveDb` | 0...36 dB | K | dB | **Group "DRIVE"** — alone, first (the defining param, largest/most prominent knob if the layout allows size variance) |
| `mix` | 0...1 | K | recommend `%` | **Group "OUTPUT"** — Mix, Output |
| `outputDb` | -12...12 dB | K | dB | same group |

### `gate` (4 params)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `thresholdDb` | -80...0 dB | **K in v1** (S↕-in-meter in v2, same upgrade path as compressor threshold) | dB | **Group "TRIGGER"** — alone |
| `attackMs` | 0.1...50 ms | K | ms | **Group "TIME"** — Attack, Hold, Release |
| `holdMs` | 0...500 ms | K | ms | same group |
| `releaseMs` | 5...2000 ms | K | ms | same group |

### `chorus` (3 params)
| Param | Range | Control | Unit display | Group / order note |
|---|---|---|---|---|
| `rateHz` | 0.05...5 Hz | K | Hz (sub-10 Hz shows 2 decimals, already implemented — correctly avoids "0.8 Hz" reading as "1") | **Group "MODULATION"** — Rate, Depth |
| `depthMs` | 0.5...10 ms | K | ms | same group |
| `mix` | 0...1 | K | recommend `%` | **Group "OUTPUT"** — last |

### `audioUnit`
No params on this surface (`EffectParamSpec.specs(for: .audioUnit)` returns `[]`, `Effects.swift:589`) — out of scope, unchanged (M3 vi-b plugin window handles it).

## Actionable takeaways

1. **ROADMAP**: "Effect Editor v2 — vertical knob-grid layout" (successor to m17-a's generic `ValueSlider` list). Scope: generalize `PanKnob` (`MixerControls.swift:99`) into a reusable `KnobControl` supporting (a) the existing bipolar center-out fill for ±dB gain params (EQ band gains) and (b) a new unipolar min-start sweep fill for everything else (freq/Q/time/threshold/ratio/mix), both reusing `EffectEditorModel`'s existing `fraction(for:)`/`setFraction(_:for:)`/log-scale machinery unchanged — **zero store or wire changes**, this is UI-layer only.
2. **ROADMAP**: within the same item, restructure `EffectEditorOverlay`'s body from one flat `ForEach` over `specs` into **per-kind grouped sections** per §6's table (group labels + a hairline break between groups, matching the SSL/Cubase/Pro-C3 input→processing→output precedent) — this requires a small per-kind grouping table (kind → `[(groupLabel, [paramName])]`) alongside `EffectParamSpec.specs(for:)`, analogous to how `EffectEditorModel.label(for:)` already derives per-param display strings from the wire name.
3. **ROADMAP** (small, standalone): implement the `pingPong` toggle — it is already binary at the model layer (`Effects.swift:346`) but currently renders as a slider; swap its row to a toggle control (still writing 0.0/1.0 through the identical `setFraction`/`set` path, no wire change) ahead of or alongside the broader knob-grid work since it's a one-row fix.
4. **ROADMAP** (v2, gated on the pre-existing metering gap — `2026-07-15-insert-editor-ux.md` Actionable-2/5): once `gainReductionDb` metering lands, upgrade `thresholdDb` (compressor, gate) and `ceilingDb` (limiter) from knob to a `VerticalFader`-style slider fused with the live GR reading, per §4's Ableton/Waves-L1 precedent — do not attempt this before metering exists (an unpaired "meter-style" slider is worse than the knob it would replace).
5. **DESIGN-LANGUAGE**: adopt the "`%` for 0...1 `linear` amount params" readout convention (roomSize, damping, width, mix×4, feedback) — currently all render as raw two-decimal fractions (`0.35`) per `EffectEditorModel.readout`'s `default` case; every cited competitor (FabFilter, Soundtoys, UAD) shows these as percentages. Small, isolated formatter change in `readout(value:spec:)`, no param-list or wire impact.
6. **DESIGN-LANGUAGE**: register the label-above-knob-in-tight-column convention (§5) as the layout rule for any future knob-grid control, superseding the current left-column-label row shape for this one surface (the flat-list generic editors elsewhere — e.g. a hypothetical future AU generic fallback — may keep the row/label-left shape; it's the right idiom for an *unstructured* param list, just not for a *grouped* channel-strip-style one).
