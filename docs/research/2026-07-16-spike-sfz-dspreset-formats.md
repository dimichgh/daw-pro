# Spike: SFZ / DecentSampler (`.dspreset`) format reality for the built-in Sampler

**Date:** 2026-07-16
**Roadmap item:** `docs/ROADMAP.md:287` (m18-h) — "SFZ / DecentSampler import spike (filed: m17-e
FREE-INSTRUMENTS.md appendix)." Item text: *"Research + design ONLY this item: scope what subset of
SFZ 2.0 / `.dspreset` the built-in Sampler could honor (zones, loops, round-robins?), the mapping
onto the existing key-zone model, and a days-scale implementation estimate; implementation files as
its own item only if the design says it's worth it. Route: research-analyst (format research) +
daw-architect (mapping design)."*
**This document is the research-analyst half only** — format facts, a real-library opcode census,
and a researcher's-draft subset tiering. It deliberately does **not** contain the zone-model mapping
design, a days estimate, or a go/no-go — that is the daw-architect half's job, per the item's own
routing. No code was written, no plugin/library binaries were downloaded or installed; every SFZ/XML
file cited below was fetched as small raw text (via WebFetch on `raw.githubusercontent.com` /
GitHub's REST API / documentation sites), never as a zip/`.dslibrary`/audio binary.

## Executive summary

Both formats are more capable than DAW Pro's Sampler (`Sources/DAWCore/Model.swift:1283-1350`),
which has no velocity dimension, round-robin, loops, or per-zone envelope/tune at all — only pitch
ranges, a global one-shot flag, and global attack/release ramps. The real surprise: **SFZ's own
preprocessor layer (`#include`, `#define`) is a prerequisite, not an opcode-subset question** — the
single most famous free piano library (Salamander Grand Piano) ships a "wrapper" `.sfz` with **zero**
region data; every note lives behind ARIA `#include`s and `#define $VAR` macro substitution across 23
partial files. A census of 5 real free libraries (piano, 2× orchestral, 2× bass/synth) shows the
"core" opcode set (key range, velocity layers, round-robin, random, tune, envelope, amp) is exactly
what's actually used, while filters/LFOs/CC-modulation/keyswitches are real but confined to specific
libraries (a synth pad, a flagship piano) — good evidence a v1 subset is a legitimate, recognized
scoping choice (sfizz and liquidsfz both publish exactly this kind of tiered support matrix).
DecentSampler's `.dspreset` is architecturally simpler (single self-contained XML, no
include/macro layer) and its playback-relevant attribute set maps closely to the same opcode
categories. Sample-library licensing is mostly permissive (CC0/CC-BY) but not universally so.

## 0. What DAW Pro's Sampler honors today (verified by direct code read)

- `Sources/DAWCore/Model.swift:1283-1313` — `SamplerParams`: `zones: [SamplerZone]` (array order
  matters — see below), `oneShot: Bool` (**one flag for the whole instrument**, not per zone),
  `attack`/`release: Double` (**global** anti-click ramps in seconds, not a per-zone ADSR — there is
  no decay/sustain stage at all), `gain: Double` (global 0...1).
- `Sources/DAWCore/Model.swift:1317-1350` — `SamplerZone`: `id`, `audioFileURL`, `rootPitch: Int`,
  `minPitch`/`maxPitch: Int` (inclusive, clamped/swapped on init), `gain: Double` (per-zone 0...1).
  **No velocity range field exists on `SamplerZone` at all** — zones only key on pitch.
  `func contains(pitch:) -> Bool` (line 1349) is the only membership test, and it is pitch-only.
- `Sources/DAWEngine/Instruments/SamplerInstrument.swift:18-19,401-411` — voice triggering picks the
  **FIRST zone in array order whose pitch span contains the note** (deterministic on overlap, no
  velocity/round-robin/random tie-break of any kind); "no matching zone → the note is silently
  ignored" (line 19, confirmed in code at line 411).
- `Sources/DAWEngine/Instruments/SamplerInstrument.swift:25` — amplitude formula:
  `velocity/127 × zone.gain × params.gain` — velocity scales loudness only, never zone *selection*.
- `Sources/DAWEngine/Instruments/SamplerInstrument.swift:16,32-38,154-227` — zones are **structural**
  (any zones change reloads every audio file and rebuilds the instrument wholesale via
  `PlaybackGraph.InstrumentTrackKey`); only the scalar params (`oneShot`/`attack`/`release`/`gain`)
  hot-swap in place through a snapshot/retire-bin (lines 245-264). Files load fully into immutable
  Float32 buffers at init (never on the render thread).
- `Sources/DAWEngine/Instruments/SamplerInstrument.swift:27-30` — the envelope is a **linear** ramp on
  trigger (attack) and a linear ramp to exact 0 on release (`release` seconds); `oneShot == true`
  ignores noteOff entirely.
- Sustain pedal (CC64) and ±2-semitone pitch bend are already handled at the engine level
  (`SamplerInstrument.swift:11-14,478-487`) — these are controller behaviors, orthogonal to the
  file-format question, noted here only because a couple of surveyed SFZ opcodes (`loop_sustain`
  mode) interact with the pedal.

**The load-bearing gap this creates:** velocity layers, round-robin, and random-layer selection are
not "a few more opcodes to parse" — they require a genuinely new *selection* dimension in the zone
model (a velocity range per zone, a round-robin counter per zone-group, an RNG draw per trigger) and
a new voice-triggering algorithm in `SamplerInstrument.apply(_:)`, not just importer-side opcode
reads. This is flagged again in "Recommended v1 subset" and "Open questions" below — it is squarely
the daw-architect half's problem, but the researcher's opcode census makes clear it isn't optional if
the subset is to cover real content (see §2).

## 1. SFZ format reality

### 1.1 Structure and opcode inheritance

Headers, high to low precedence for a region's effective opcode values (each level's setting
overrides everything above it unless the lower level leaves the opcode unset): `<control>` (SFZ v2;
sets `default_path` and initial CC values) → `<global>` (SFZ v2; one per file, applies to every
region) → `<master>` (ARIA-only organizational layer between global and group) → `<group>` (SFZ v1;
optional, groups regions) → `<region>` (SFZ v1; "the most essential… basic unit from which
instruments are constructed"). `<curve>` (SFZ v2, envelope/response shaping) and `<effect>` (SFZ v2)
exist but are orthogonal to key-zone mapping. [sfzformat.com/headers](https://sfzformat.com/headers/),
[sfzformat.com/headers/region](https://sfzformat.com/headers/region/) (WebFetch, 2026-07-16).

### 1.2 SFZ 1.0 / 2.0 / ARIA — what actually differs, practically

- **SFZ v1**: the original rgc:audio format — "the most supported by sfz related software," i.e. the
  safest baseline.
- **SFZ v2**: never formally standardized; sfzformat.com pragmatically defines it as "anything
  included in Simon Cann's Cakewalk Synthesizers" documentation rather than an actual spec.
- **ARIA extensions**: Plogue's engine (used by sforzando) adds more — extended CC-modulation
  opcodes, `<master>`, `#include`/`#define` preprocessing, and XML "instrument bank" GUIs. ARIA vs.
  Cakewalk-only support genuinely diverges (a feature can work in ARIA but not Cakewalk products, and
  vice versa).
- **Practical takeaway for an importer, stated directly by the site itself**: "developers shouldn't
  feel obligated to support every opcode and header listed" — pick a subset for your use case.
  [sfzformat.com/versions](https://sfzformat.com/versions/) (WebFetch, 2026-07-16).

### 1.3 The core opcode set (per the assigned research questions)

Verified via sfzformat.com's own categorized opcode tables (WebFetch, 2026-07-16,
[sfzformat.com/opcodes](https://sfzformat.com/opcodes/) plus individual opcode pages cited inline):

| Category | Opcodes | Version | Notes |
|---|---|---|---|
| Key mapping | `key`, `lokey`, `hikey`, `pitch_keycenter` | v1 | `key=N` is shorthand setting `lokey=hikey=pitch_keycenter=N`; `pitch_keycenter` defaults to 60 if omitted. [pitch_keycenter](https://sfzformat.com/opcodes/pitch_keycenter/) (WebFetch, 2026-07-16). |
| Velocity layers | `lovel`, `hivel` | v1 | Inclusive MIDI velocity range per region. |
| Loops | `loop_mode` (`no_loop`/`one_shot`/`loop_continuous`/`loop_sustain`), `loop_start`, `loop_end` | v1 | If `loop_start`/`loop_end` are **omitted**, the player falls back to loop points embedded in the WAV/AIFF file itself (RIFF `smpl` chunk) — a real dependency our importer doesn't have today (we don't parse `smpl` chunks). [loop_mode](https://sfzformat.com/opcodes/loop_mode/), [loop_start](https://sfzformat.com/opcodes/loop_start/) (WebFetch, 2026-07-16). |
| Round-robin | `seq_length`, `seq_position` | v1 | Per-region sequence position 1…N; player keeps a per-region note-on counter. ARIA tracks it per-region (not globally), so cross-region alternation patterns are player-dependent. [seq_length](https://sfzformat.com/opcodes/seq_length/) (WebFetch, 2026-07-16). |
| Random layers | `lorand`, `hirand` | v1 | A new 0..1 random draw per note-on; region plays if the draw falls in `[lorand, hirand)`. Often combined with `seq_position` to randomize *within* an RR slot. [lorand](https://sfzformat.com/opcodes/lorand/) (WebFetch, 2026-07-16). |
| Tuning | `tune`, `transpose` | v1 | `tune` = cents/semitone fine offset; `transpose` = whole-semitone shift. |
| Amp | `volume`, `pan`, `amp_veltrack` | v1 | `amp_veltrack` (0-100%) controls how much velocity affects amplitude vs. a flat gain — analogous to but richer than our fixed `velocity/127` scaling. |
| Envelope | `ampeg_attack`, `ampeg_decay`, `ampeg_sustain`, `ampeg_release` | v1 | Full 4-stage ADSR — our engine has **no decay/sustain stage at all** today (see §0). |
| Sample defaults | `default_path`, `sample` | v1/v2 | `default_path` (set in `<control>`) is concatenated with each region's `sample=` path; **real files mix `\` and `/` separators** — Windows-authored SFZ commonly uses backslashes (e.g. `sample=..\Samples\close\c4_pp_rr3.wav`), which a macOS-side path parser must normalize. [sample opcode](https://sfzformat.com/opcodes/sample/), [default_path](https://sfzformat.com/opcodes/default_path/) (WebFetch, 2026-07-16). |
| **Preprocessor (not an "opcode" at all)** | `#include "path"`, `#define $VAR value` | ARIA / v2 | See §1.5 — **this is a prerequisite for reading region data in some real libraries, not an optional extra.** [include](https://sfzformat.com/opcodes/include/), [define](https://sfzformat.com/opcodes/define/) (WebFetch, 2026-07-16). |

### 1.4 Rabbit holes to explicitly EXCLUDE from a v1 subset

All confirmed as real, documented opcodes (so "exclude" is a scoping choice, not an oversight):

- **Filters** — `fil_type`/`fil2_type` + `cutoff`/`resonance` family. SFZ v1 already ships 6 filter
  types (`lpf_1p`, `hpf_1p`, `lpf_2p`, `hpf_2p`, `bpf_2p`, `brf_2p`); v2/ARIA add a dozen more
  (state-variable, 4-pole, comb, shelf/parametric EQ). Real DSP work, unrelated to zone mapping.
  [fil_type](https://sfzformat.com/opcodes/filtype/) (WebFetch, 2026-07-16).
- **LFOs** — legacy `amplfo_*`/`pitchlfo_*`/`fillfo_*` and modern `lfoN_*` (ARIA). Confirmed actually
  *used* in one surveyed library (Karoryfer Cowsynth, §2) — real but a real DSP feature, not a
  mapping concern.
- **Crossfades** — `xfin_loccN`/`xfin_hiccN`/`xfout_loccN`/`xfout_hiccN` and the lokey/hikey/lovel/hivel
  crossfade variants (all SFZ v1). Real-time layer blending, a mixing feature, not zone selection.
- **`trigger=release` (and `release_key`, `first`, `legato`)** — release-triggered samples (piano
  key-release noise, legato transitions) have real documented player-inconsistency problems: "a
  note-on event which triggers multiple regions… will have multiple corresponding regions for the
  release region" — with 7 mics that's 49 samples firing from one key-up. Round-robin counters and
  sustain-pedal interaction with release triggers are player-dependent, undocumented-consistently
  behavior. [trigger](https://sfzformat.com/opcodes/trigger/) (WebFetch, 2026-07-16).
- **`sw_lokey`/`sw_hikey`/`sw_last`/`sw_default`/`sw_previous` (keyswitches)** — require persistent
  "last keyswitch pressed" state machine across notes, entirely outside the current
  stateless-per-note zone-selection model. Confirmed heavily used in real content (Salamander's dual
  natural/retuned articulation switch, VSCO2-CE's `-KS` combo files, §2).
  [sw_lokey](https://sfzformat.com/opcodes/sw_lokey/) (WebFetch, 2026-07-16).
- **CC-modulation family** — any `_onccN`/`_curveccN`/`_smoothccN`/`_stepccN` suffix (pan_onccN,
  amp_veltrack_onccN, ampeg_attack_onccN, etc.) plus `label_ccN`/`set_ccN`. Real-time CC-driven
  parameter modulation is a live-performance feature layered on top of zone mapping, not zone mapping
  itself.
- **`note_polyphony`/`off_by`/`polyphony_group`/`rt_decay`** — voice-stealing/choke-group management;
  our engine already has its own oldest-voice-steal policy (`SamplerInstrument.swift` voice-slot
  logic) and 16-voice fixed pool; honoring per-region choke groups is a separate voice-management
  feature, not a mapping concern.

### 1.5 The two preprocessor layers real files depend on (surprise finding)

SFZ has two textual preprocessor directives that run **before** any opcode is even parsed:

- **`#include "relpath"`** (ARIA) — paths resolve relative to the *main* SFZ file's location (not the
  including file's location), can nest, and recursion must be avoided by the author.
  [include](https://sfzformat.com/opcodes/include/) (WebFetch, 2026-07-16).
- **`#define $VAR value`** (SFZ v2) — creates a `$`-prefixed textual substitution variable, used
  inside opcode values (e.g. `key=$KICKKEY`, `sample=$VEL/…$EXT`); the docs themselves note
  redefinition-scoping quirks and recommend pairing `#define` blocks with `#include` per-file to avoid
  them. [define](https://sfzformat.com/opcodes/define/) (WebFetch, 2026-07-16).

**This is not theoretical.** Fetching the actual, single canonical file for the single most
recommended free piano SFZ conversion —
[`sfzinstruments/SalamanderGrandPiano`'s `Salamander Grand Piano V3.sfz`](https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/master/Salamander%20Grand%20Piano%20V3.sfz)
(WebFetch, 2026-07-16, searched directly for `lokey=`/`hikey=`/`pitch_keycenter=`/`lovel=`/`hivel=`/
`sample=`/`ampeg_release=` etc.) — **found none of them**. The file contains only `#include` lines
(`#include "Data/tune_nat.txt"` etc.) and header/keyswitch scaffolding. The real region data lives in
23 partial files under `Data/` — confirmed via the GitHub contents API
([sfzinstruments/SalamanderGrandPiano/contents/Data](https://api.github.com/repos/sfzinstruments/SalamanderGrandPiano/contents/Data),
WebFetch, 2026-07-16): `vel_01.txt`…`vel_16.txt` (one file per velocity layer — confirming the 16
layers the README claims), plus `hammer.txt`/`pedal.txt`/`str_res.txt` (mechanical hammer noise,
pedal noise, sympathetic string resonance — auxiliary always-on layers) and `tune_nat.txt`/
`tune_ret.txt` (keyswitched tuning tables). Directly fetching `Data/vel_01.txt` shows only `#define`
macro constants (`$OFF01`…`$OFF30`); fetching `Data/region.txt` shows the actual `<region>` blocks
using those macros (`lokey`, `hikey`, `pitch_keycenter`, `tune=$TUNE01`, `sample=$VEL/…$EXT`,
`ampeg_release`) (both WebFetch, 2026-07-16). **Practical consequence for scoping**: `#include`
resolution is a hard prerequisite just to see *any* region for this library — it cannot be filed
under "nice-to-have round-robin/velocity opcodes," it gates reading the file at all. `#define` macro
substitution is needed to make sense of the values once found. DecentSampler's `.dspreset`, by
contrast, has **no equivalent preprocessor layer found in the developer docs** — every preset is one
self-contained XML file (see §3).

## 2. Real-library opcode census

Five free libraries surveyed, opcodes enumerated by directly fetching real `.sfz` text (not
guessed/assumed) via `raw.githubusercontent.com` (WebFetch, 2026-07-16 for every row below). "Y*"
marks a feature confirmed present in *at least one* file of that library though not the specific file
sampled (Salamander's velocity/key-range opcodes live in `#include`d files, confirmed separately in
§1.5 rather than in the wrapper file's own text).

| Opcode / feature | Salamander Grand Piano (piano, kinwie ARIA remap) | VSCO2 Community Edition (orchestral, 6 files sampled) | Virtual Playing Orchestra (orchestral) | Karoryfer Swagbass (bass) | Karoryfer Cowsynth (synth pad/organ/pluck) |
|---|---|---|---|---|---|
| `lokey`/`hikey`/`key` | Y* (`Data/region.txt`) | Y | Y | Y | Y |
| `pitch_keycenter` | Y* | Y | Y | Y | Y |
| `lovel`/`hivel` | Y* (16 velocity-layer files) | Y (`SViolinVib.sfz`: 2 layers) | not seen in sampled file | Y (3 layers: pp/f/ff) | not seen |
| `seq_length`/`seq_position` | not seen in sampled files | Y (`SViolin-KS.sfz`, `GM-StylePerc.sfz`) | not seen in sampled file | Y (4-5-position RR on note/noise groups) | not seen |
| `lorand`/`hirand` | not seen | Y (`SViolin-KS.sfz`) | not seen (uses `pitch_random`/`amp_random`/`delay_random` instead — a different, ARIA-flavored randomization idiom) | Y | not seen |
| `loop_mode`/`loop_start`/`loop_end` | not seen (piano doesn't need it) | not seen in any of 5 sampled files (`SViolinVib`, `SViolin-KS`, `OrganLoud`, `GM-StylePerc`, `Marimba`) | not seen in sampled file | not seen | **Y** (`loop_mode` present — pad/organ sustain loop) |
| `tune`/`transpose` | Y* (`tune=$TUNE01` per layer) | Y | Y (per-note tuning compensation) | not seen | Y |
| `volume`/`pan`/`amp_veltrack` | not confirmed in sampled text | `volume` Y, `pan`/`amp_veltrack` not seen | `volume` Y | not seen | `pan` Y |
| `ampeg_attack/decay/sustain/release` | Y* (`ampeg_release` in `region.txt`) | Y (`ampeg_attack`/`ampeg_release`/`ampeg_dynamic`, no decay/sustain) | Y (`ampeg_attack/decay/release`, `ampeg_vel2release`) | Y (`ampeg_release` only) | Y (full `ampeg_attack/hold/decay/sustain/release`) |
| `default_path`/`sample` | Y (wrapper level) | Y | Y | Y | Y |
| Keyswitches (`sw_lokey` etc.) | **Y** (natural/retuned articulation switch) | **Y** (`-KS` combo files: `sw_lokey/hikey/last/default/label`) | not seen | not seen | not seen |
| CC-modulation (`_onccN` family) | **Y** (extensive: `amplitude_oncc7`, `pan_oncc10`, `ampeg_release_oncc72`, etc.) | not seen | not seen | not seen | **Y** (`ampeg_attack_oncc100` etc.) |
| Filters (`cutoff`/`resonance`/`fil_*`) | not seen | not seen | not seen | not seen | **Y** (`cutoff`, `resonance`, `fil_keytrack`, `fil_veltrack`) |
| LFOs (`*lfo*`) | not seen | not seen | **Y** (`pitchlfo_freq/depth/delay/fade`) | not seen | **Y** (`pitchlfo_depthcc105` etc.) |
| EQ (`eqN_*`) | not seen | not seen | **Y** (`eq1_freq/bw/gain`, `eq2_*`) | not seen | not seen |
| `trigger` (attack/release) | not confirmed | not seen | not seen | **Y** | not seen |
| `#include`/`#define` | **Y — required to reach any region data** (§1.5) | not seen in sampled files | not seen in sampled files | not seen | not seen |
| Randomization (non-`rand`) opcodes: `pitch_random`/`amp_random`/`delay_random` | not seen | not seen | **Y** | not seen | `offset_random` Y |

**Reading the table**: every one of the 8 "core" candidate opcodes (key range, velocity, RR, random,
tune, amp, envelope, sample/path) is used by at least 3 of the 5 libraries — real support for a core
subset. Loop points are the outlier: **zero of the 4 acoustic-instrument libraries used explicit
`loop_start`/`loop_end`/`loop_mode` opcodes** (recorded-to-natural-decay samples don't loop); only the
one synth/pad library did. Filters/LFO/EQ/CC-modulation/keyswitches are each real but each confined to
1-2 of the 5 libraries — evidence they're legitimately excludable from a v1 core without breaking most
content, at the cost of degrading specific libraries (a synth pad loses its sustain loop and filter
motion; the flagship piano loses its second articulation and CC-driven dynamics layer, on top of
needing `#include`/`#define` just to load at all).

## 3. DecentSampler `.dspreset` reality

### 3.1 XML shape

A `.dspreset` is plain XML: `<DecentSampler>` (root, e.g. `<DecentSampler pluginVersion="1">`) →
`<groups>` (exactly one per file; carries instrument-wide defaults) → `<group>` (organizational,
carries group-wide defaults) → `<sample>` (leaf zone, one per file+range). Optional sibling elements
under `<DecentSampler>`: `<ui>` (chrome, see §3.3), `<effects>`, `<midi>`.
[File Format Overview](https://decentsampler-developers-guide.readthedocs.io/en/latest/introduction.html),
[The `<groups>` element](https://decentsampler-developers-guide.readthedocs.io/en/latest/the-groups-element.html)
(WebFetch, 2026-07-16). **No `#include`/`#define`-equivalent preprocessor was found in the developer
guide** — a `.dspreset` is self-contained (asset paths point at files in the library folder, but the
XML itself isn't split across multiple text files the way SFZ commonly is).

### 3.2 Playback-relevant attributes (confirmed on `<sample>`/`<group>`, WebFetch of the developer
guide's groups-element page, 2026-07-16)

`path`, `rootNote`, `loNote`/`hiNote`, `loVel`/`hiVel`, `start`/`end`, `tuning`, `volume`, `pan`,
`pitchKeyTrack`, `trigger` (attack/release/first/legato/continuous — same rabbit hole as SFZ),
`attack`/`decay`/`sustain`/`release` (+ `attackCurve`/`decayCurve`/`releaseCurve`), `ampVelTrack`
(group-level), `loopStart`/`loopEnd`/`loopEnabled`/`loopCrossfade`/`loopCrossfadeMode`, `seqMode`
(`round_robin`/`random`/`true_random`/`always`) + `seqPosition`/`seqLength`, `delay`/`delayUnit`,
plus voice-management (`silencedByTags`/`silencingMode`/`polyphony`-adjacent), CC gating
(`loCCN`/`hiCCN`/`onLoCCN`/`onHiCCN`), and output routing (`output1Target`…`output8Target`) —
the latter three groups are the same class of rabbit hole as SFZ's CC-modulation/choke-group opcodes
and should be excluded from v1 for the same reasons.

### 3.3 UI-only chrome

`<ui>` (tabs, `<labeled-knob>`, buttons, menus) and `<midi>` (CC→UI-control bindings) are confirmed
purely cosmetic/live-control layers: "a reader ignoring all `<ui>` elements could still reconstruct
full audio functionality by processing the binding definitions directly" — i.e. ignoring `<ui>`
entirely just means the imported instrument plays with its **authored default** parameter values and
no user-tweakable knobs, which is a legitimate v1 posture (equivalent to "load the preset as
authored"). [The `<ui>` element](https://decentsampler-developers-guide.readthedocs.io/en/latest/the-ui-element.html)
(WebFetch, 2026-07-16).

### 3.4 Format openness and a naming/trademark caution

The `.dspreset` **format itself is openly, thoroughly documented** for third parties — a public
developer's guide (readthedocs + GitHub, published by DecentSamples/David Hilowitz, the plugin's own
creator) exists specifically to let people author and, implicitly, build tooling around the format;
there's even a community-maintained [XML schema project](https://github.com/praashie/DecentSampler-schema)
"mostly based on the DecentSampler file format documentation." However, **the DecentSampler *plugin*
itself is proprietary freeware, not open source** — confirmed indirectly via a stalled NixOS packaging
request (binary-only, no buildable source) and an unanswered community question on
decentsamples.com's own Q&A asking what license the software is under.
[NixOS/nixpkgs#238499](https://github.com/NixOS/nixpkgs/issues/238499),
[decentsamples.com Q&A](https://www.decentsamples.com/qa/27/what-license-is-decent-sampler-under)
(both WebFetch/WebSearch, 2026-07-16). **Caution**: "DecentSampler" and ".dspreset" are the branding
of a specific commercial-adjacent product; the format spec being open for reading doesn't make the
name free to use as a marketing claim. Recommend phrasing any shipped feature as "imports `.dspreset`
sample-library files" (a factual format-support statement) rather than "DecentSampler-compatible" or
implying endorsement/partnership — the same posture DAW Pro already takes with AU hosting (it doesn't
claim to *be* Kontakt-compatible, it hosts the AU standard Kontakt happens to ship).

### 3.5 Real `.dspreset` examples reviewed

Genuine Pianobook `.dslibrary` downloads are distributed as zip archives (out of scope to fetch per
this task's binary-fetch restriction), so three **text-verified** real/primary-source examples were
used instead:
1. The official boilerplate template (Appendix C of the developer guide) — confirms the minimal
   valid skeleton. [Appendix C](https://decentsampler-developers-guide.readthedocs.io/en/latest/appendix-c-boilerplate-dspreset-file.html)
   (WebFetch, 2026-07-16).
2. **David Hilowitz's own** (DecentSampler's creator) Kontakt-6-to-DecentSampler export script gist —
   a primary-source, real-world generator whose output XML uses exactly `path`, `rootNote`, `loNote`,
   `hiNote`, `loVel`, `hiVel`, `start`, `end`, `tuning`, `volume`, `ampVelTrack`, `loopEnabled`,
   `loopStart`, `loopEnd`, `loopCrossfade` — i.e. precisely the "playback core" this spike is scoping,
   confirmed by the format's own author's tooling.
   [gist.github.com/dhilowitz](https://gist.github.com/dhilowitz/98f46b22f38d96f8a818e7fa62874c57)
   (WebFetch, 2026-07-16).
3. A community "how to sample" basics guide's worked examples (`<sample loNote="72" hiNote="72"
   rootNote="72" path="minibrass_72.wav"/>`) — confirms the same minimal-attribute pattern shows up in
   beginner-authored content too. [instatetragrammaton/Patches Decent-Sampler-Basics.md](https://raw.githubusercontent.com/instatetragrammaton/Patches/master/Sampling/Decent-Sampler-Basics.md)
   (WebFetch, 2026-07-16).

## 4. Licensing of the surveyed sample libraries (brief — for a possible later starter-library ship)

| Library | License | Source |
|---|---|---|
| Salamander Grand Piano (Alexander Holm recording; kinwie's SFZ2+ARIA remap) | CC Attribution 3.0 Unported (remap README); original recordings also CC-BY per long-standing community knowledge | [README.md](https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/master/README.md) (WebFetch, 2026-07-16) |
| VSCO 2 Community Edition | CC0 (public domain) | [versilian-studios.com/vsco-community](https://versilian-studios.com/vsco-community/) (WebFetch, 2026-07-16) |
| Virtual Playing Orchestra | Bespoke free license (Paul Battersby): commercial music-making unrestricted, no attribution required to make music, but **no commercial repackaging/resale of the library itself**; redistribution of parts allowed under CC with credit. A GitHub mirror's own `LICENSE` file says GPL-3, which conflicts with the authoritative source and appears to be the mirror maintainer's own wrapper license, not the sample content's actual terms — **use virtualplaying.com as the source of truth, not the GitHub mirror's LICENSE file**, as the FAQ itself says the website supersedes bundled files on conflict. | [virtualplaying.com](https://virtualplaying.com/virtual-playing-orchestra/), [FAQ](https://virtualplaying.com/virtual-playing-orchestra-faq/) (WebFetch, 2026-07-16) |
| Karoryfer (Swagbass, Cowsynth) | CC0 1.0 Universal (confirmed by fetching the repo's own `LICENSE` file text, not just the marketing page) | [shop.karoryfer.com/pages/free-samples](https://shop.karoryfer.com/pages/free-samples), repo `LICENSE` (WebFetch, 2026-07-16) |
| DecentSampler-format Pianobook content (general) | Per-instrument, contributor-chosen (Pianobook is a submission platform, not a single license) — not independently surveyed here beyond the format-spec check in §3.4 | — |

## 5. Prior art on subset scoping

Two respected, actively-maintained SFZ engines document exactly the kind of tiered subset this spike
is scoping, evidence it's a normal, professional choice rather than a compromise unique to us:

- **sfizz** (open-source SFZ engine embedded in several DAWs/hosts) publishes a live opcode support
  matrix with explicit status per opcode: Supported / Unsupported / Under construction, including
  opcodes marked "not supported by design" (e.g. `lochan`/`hichan`) — a transparent, intentional scope
  boundary, not silent gaps. [sfztools.github.io opcode status](https://sfztools.github.io/sfizz/development/status/opcodes/?v=aria)
  (WebFetch, 2026-07-16).
- **liquidsfz** (a deliberately minimal, embeddable SFZ library used in LV2/JACK hosts) documents its
  supported-opcode list (`OPCODES.md`) covering exactly the core categories this spike identifies —
  key mapping, velocity, round-robin/random, loop, full `ampeg_*`/`fileg_*` envelopes, tune, pan/volume
  — while its README frames the whole project's goal as "easy to integrate into other projects," i.e.
  a practical embeddable-subset engine, not a full ARIA reimplementation.
  [OPCODES.md](https://raw.githubusercontent.com/swesterfeld/liquidsfz/master/OPCODES.md),
  [README.md](https://raw.githubusercontent.com/swesterfeld/liquidsfz/master/README.md)
  (WebFetch, 2026-07-16). No evidence was found that Sitala (a free drum sampler sometimes suggested
  as a "lightweight host" comparison) supports SFZ import at all — dropped from this comparison rather
  than reported inaccurately.

## Recommended v1 subset (researcher's draft — architect to confirm)

This tiering is opcode-facts-only; it does **not** attempt the zone-model mapping or an estimate.
Rationale is tied directly to the §2 census. A cross-cutting note first, since it changes which tier
means what: **MUST-tier items below are not equally cheap.** Key-range mapping fits today's
first-match zone array with zero engine change. Velocity layers, round-robin, and random selection
all require a new *selection* dimension (velocity range per zone at minimum; RR/random need
per-zone-group trigger-count/RNG state) that doesn't exist in `SamplerZone`/`SamplerInstrument.apply`
today (§0) — the architect's mapping design needs to treat "parse the opcode" and "the engine can act
on it" as two separate costs.

**MUST** (used by ≥3 of 5 surveyed libraries; directly addresses the roadmap item's own "zones, loops,
round-robins?" framing):
- `lokey`/`hikey`/`key`, `pitch_keycenter` — used by all 5; already fits the existing pitch-range zone.
- `lovel`/`hivel` — used by 3/5; the single biggest engine-model gap (§0) — no velocity dimension
  exists on `SamplerZone` today.
- `seq_length`/`seq_position` (round-robin) — used by 2/5 explicitly, named in the roadmap item itself.
- `lorand`/`hirand` (random layers) — used by 2/5; same selection-state gap as round-robin.
- `sample`, `default_path` — used by all 5 (every library needs a file to point at); must also
  normalize `\` vs `/` path separators (real-world Windows-authored files use backslashes, §1.3).

**SHOULD** (used, but not universally; meaningfully improves realism without opening a DSP rabbit
hole):
- `tune`/`transpose` — used by 4/5; cheap (a playback-rate multiplier, conceptually adjacent to the
  pitch-bend math already in `SamplerInstrument.swift:434-436`).
- `ampeg_attack`/`ampeg_release` — used by all files that specify envelopes at all; maps onto the
  existing global attack/release concept, generalized to per-zone. **`ampeg_decay`/`ampeg_sustain`
  are a bigger ask** (§0: the engine has no decay/sustain stage at all today) — flagged as its own
  open question below rather than bundled into this tier's "cheap" framing.
- `volume`, `pan`, `amp_veltrack` — used by a majority; `pan` is new (current engine has no per-zone
  pan at all — mono files play centered on both channels per `SamplerInstrument.swift:190-191`).

**COULD** (real, but confined to 1-2 of 5 libraries — worth a v2 conversation, not v1):
- `loop_mode`/`loop_start`/`loop_end` — used by exactly 1 of 5 sampled files (a synth pad); **and**
  when unset in a real file, players fall back to loop points embedded in the WAV/AIFF `smpl` chunk
  (§1.3) — our importer doesn't parse audio-file metadata today, so full loop fidelity needs that too,
  not just the SFZ opcodes.
- `#include`/`#define` preprocessing — a hard prerequisite for a small number of flagship libraries
  (Salamander, confirmed, §1.5) but not observed in 4 of 5 sampled libraries; could be deferred with a
  clear, honest "single-file SFZ only" v1 limitation, at the cost of failing to import Salamander's own
  canonical file without additional work.

**EXCLUDE from v1** (confirmed real, each tied to the specific library that uses it, deliberately out
of scope — same list for both SFZ and `.dspreset`, which share the same rabbit holes):
- Filters (`fil_type`, `cutoff`, `resonance`, DecentSampler's effects chain) — real DSP engine work,
  used by 1/5 (Cowsynth); no acoustic-instrument library sampled needed it.
- LFOs (`*lfo*` family) — real DSP, used by 2/5 (Virtual Playing Orchestra, Cowsynth).
- EQ (`eqN_*`) — used by 1/5 (Virtual Playing Orchestra).
- Crossfades (`xfin_*`/`xfout_*`) — not observed in any of the 5 sampled libraries at all, but
  documented as SFZ v1 and worth naming explicitly as excluded since it's easy to conflate with the
  MUST-tier round-robin/random opcodes.
- `trigger=release`/`release_key`/`first`/`legato` (SFZ) and `trigger="release"`/`"first"`/`"legato"`
  (`.dspreset`) — used by 1/5 (Karoryfer Swagbass, for pluck-noise release samples); documented player
  inconsistency and polyphony explosion risk (§1.4).
- Keyswitches (`sw_*` / DecentSampler has no direct keyswitch equivalent found in the surveyed docs) —
  used by 2/5 (Salamander, VSCO2-CE `-KS` files); needs persistent cross-note state, a genuinely
  different trigger model.
- CC-modulation family (`_onccN` etc., DecentSampler's `<midi>`/`<binding>` live-control layer) — used
  by 2/5 SFZ libraries (Salamander, Cowsynth); a live-performance feature layered on top of static zone
  mapping. For `.dspreset` specifically, ignoring `<ui>`/`<midi>` entirely is explicitly a legitimate
  v1 posture (§3.3) — the imported instrument just plays its authored defaults with no live knobs.
- Voice-management (`note_polyphony`/`off_by`/polyphony groups, DecentSampler's `silencedByTags`) —
  choke-group logic; our engine's own fixed 16-voice oldest-steal policy is a different, already-shipped
  mechanism, and reconciling the two is a separate design question from format import.

## Open questions for the mapping design (for the daw-architect half — not answered here)

1. `SamplerZone` has no velocity field today (§0). Does the mapping design add `minVelocity`/
   `maxVelocity` to the zone struct (breaking/versioning `Codable` for existing saved projects), or
   layer velocity selection as a separate structure alongside the existing pitch-only zones?
2. Round-robin/random selection needs per-trigger *state* (a counter or RNG draw) that must live
   somewhere real-time-safe — per current `SamplerInstrument.swift` conventions (§0), where does that
   state live, and does it survive the "zones are structural, scalars hot-swap" split, or does an RR
   state change now count as structural too?
3. The engine's envelope has no decay/sustain stage (§0, confirmed at
   `SamplerInstrument.swift:presses recompute Coefficients` — attack ramps to 1, then holds until
   noteOff, then releases to exact 0). Does honoring `ampeg_decay`/`ampeg_sustain` require a real
   4-stage envelope rewrite, and is that in scope for this item or its own follow-up?
4. Is `#include`/`#define` resolution (§1.5) in scope for v1 at all, given it gates a specific flagship
   library (Salamander) but not most sampled libraries — and if deferred, how is that limitation
   surfaced honestly to a user who drags in a multi-file SFZ instrument that silently has zero regions?
5. Loop fidelity depends partly on WAV/AIFF `smpl`-chunk metadata, not just SFZ opcodes (§1.3, §2's
   COULD tier) — is parsing that metadata in scope, or is "loop only when `loop_start`/`loop_end` are
   explicit SFZ opcodes" an acceptable, documented v1 limitation?
6. For `.dspreset`, is a `.dslibrary` (zipped bundle) unpack step in scope for v1, or is raw
   `.dspreset` + sibling sample folder the only supported input shape initially?
7. Naming/trademark posture (§3.4) — confirm with whoever owns user-facing copy that DAW Pro's import
   feature is described as "imports `.dspreset` files" rather than any phrasing implying partnership
   with or compatibility certification from DecentSamples.

## Sources

All fetched 2026-07-16. WebFetch = full-page/file fetch and summarization; WebSearch = search-result
snippet review (used only for discovery/triangulation, never as the sole basis for a specific
technical claim above).

- SFZ format / opcodes (WebFetch unless noted):
  [sfzformat.com/headers](https://sfzformat.com/headers/),
  [sfzformat.com/headers/region](https://sfzformat.com/headers/region/),
  [sfzformat.com/versions](https://sfzformat.com/versions/),
  [sfzformat.com/opcodes](https://sfzformat.com/opcodes/),
  [sfzformat.com/opcodes/seq_length](https://sfzformat.com/opcodes/seq_length/),
  [sfzformat.com/opcodes/lorand](https://sfzformat.com/opcodes/lorand/),
  [sfzformat.com/opcodes/default_path](https://sfzformat.com/opcodes/default_path/),
  [sfzformat.com/opcodes/sample](https://sfzformat.com/opcodes/sample/),
  [sfzformat.com/opcodes/pitch_keycenter](https://sfzformat.com/opcodes/pitch_keycenter/),
  [sfzformat.com/opcodes/loop_mode](https://sfzformat.com/opcodes/loop_mode/),
  [sfzformat.com/opcodes/loop_start](https://sfzformat.com/opcodes/loop_start/),
  [sfzformat.com/opcodes/sw_lokey](https://sfzformat.com/opcodes/sw_lokey/),
  [sfzformat.com/opcodes/trigger](https://sfzformat.com/opcodes/trigger/),
  [sfzformat.com/opcodes/fil_type](https://sfzformat.com/opcodes/filtype/),
  [sfzformat.com/opcodes/include](https://sfzformat.com/opcodes/include/),
  [sfzformat.com/opcodes/define](https://sfzformat.com/opcodes/define/);
  WebSearch triangulation: "sfzformat.com opcode reference…", "SFZ format specification ARIA
  extensions…".
- Real SFZ libraries (WebFetch of raw text / GitHub contents API):
  [SalamanderGrandPiano V3.sfz](https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/master/Salamander%20Grand%20Piano%20V3.sfz),
  [SalamanderGrandPiano README.md](https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/master/README.md),
  [SalamanderGrandPiano contents API](https://api.github.com/repos/sfzinstruments/SalamanderGrandPiano/contents/),
  [.../contents/Data/](https://api.github.com/repos/sfzinstruments/SalamanderGrandPiano/contents/Data/),
  [Data/vel_01.txt](https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/master/Data/vel_01.txt),
  [Data/region.txt](https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/master/Data/region.txt);
  [VSCO-2-CE contents API (root)](https://api.github.com/repos/sgossner/VSCO-2-CE/contents/?ref=SFZ),
  [SViolinVib.sfz](https://raw.githubusercontent.com/sgossner/VSCO-2-CE/SFZ/SViolinVib.sfz),
  [SViolin-KS.sfz](https://raw.githubusercontent.com/sgossner/VSCO-2-CE/SFZ/SViolin-KS.sfz),
  [OrganLoud.sfz](https://raw.githubusercontent.com/sgossner/VSCO-2-CE/SFZ/OrganLoud.sfz),
  [GM-StylePerc.sfz](https://raw.githubusercontent.com/sgossner/VSCO-2-CE/SFZ/GM-StylePerc.sfz),
  [Marimba.sfz](https://raw.githubusercontent.com/sgossner/VSCO-2-CE/SFZ/Marimba.sfz),
  [versilian-studios.com/vsco-community](https://versilian-studios.com/vsco-community/) (license);
  [studiorack/virtual-playing-orchestra contents API](https://api.github.com/repos/studiorack/virtual-playing-orchestra/contents/),
  [Strings dir listing](https://api.github.com/repos/studiorack/virtual-playing-orchestra/contents/Strings),
  [1st-violin-SOLO-sustain.sfz](https://raw.githubusercontent.com/studiorack/virtual-playing-orchestra/master/Strings/1st-violin-SOLO-sustain.sfz),
  [studiorack LICENSE](https://raw.githubusercontent.com/studiorack/virtual-playing-orchestra/master/LICENSE),
  [virtualplaying.com](https://virtualplaying.com/virtual-playing-orchestra/),
  [virtualplaying.com FAQ](https://virtualplaying.com/virtual-playing-orchestra-faq/) (authoritative
  license source per the FAQ's own conflict-resolution statement);
  [karoryfer.swagbass contents API](https://api.github.com/repos/sfzinstruments/karoryfer.swagbass/contents/),
  [swagbass.sfz](https://raw.githubusercontent.com/sfzinstruments/karoryfer.swagbass/master/swagbass.sfz),
  [swagbass LICENSE](https://raw.githubusercontent.com/sfzinstruments/karoryfer.swagbass/master/LICENSE),
  [shop.karoryfer.com/pages/free-samples](https://shop.karoryfer.com/pages/free-samples);
  [karoryfer.cowsynth contents API](https://api.github.com/repos/sfzinstruments/karoryfer.cowsynth/contents/),
  [cowsynth_fancy_pad.sfz](https://raw.githubusercontent.com/sfzinstruments/karoryfer.cowsynth/master/cowsynth_fancy_pad.sfz).
- DecentSampler `.dspreset` (WebFetch):
  [File Format Overview](https://decentsampler-developers-guide.readthedocs.io/en/latest/introduction.html),
  [DecentSampler-Developers-Guide/introduction.md (GitHub)](https://github.com/DecentSamples/DecentSampler-Developers-Guide/blob/main/docs/source/introduction.md),
  [Appendix C: Boilerplate](https://decentsampler-developers-guide.readthedocs.io/en/latest/appendix-c-boilerplate-dspreset-file.html),
  [The `<groups>` element](https://decentsampler-developers-guide.readthedocs.io/en/latest/the-groups-element.html),
  [The `<ui>` element](https://decentsampler-developers-guide.readthedocs.io/en/latest/the-ui-element.html),
  [dhilowitz Kontakt→DecentSampler export gist](https://gist.github.com/dhilowitz/98f46b22f38d96f8a818e7fa62874c57),
  [instatetragrammaton/Patches Decent-Sampler-Basics.md](https://raw.githubusercontent.com/instatetragrammaton/Patches/master/Sampling/Decent-Sampler-Basics.md),
  [J0rgeSerran0/Decent-Sampler-Samples README](https://raw.githubusercontent.com/J0rgeSerran0/Decent-Sampler-Samples/master/README.md),
  [decentsamples.com Q&A: plugin license](https://www.decentsamples.com/qa/27/what-license-is-decent-sampler-under),
  [NixOS/nixpkgs#238499](https://github.com/NixOS/nixpkgs/issues/238499) (WebSearch snippet + WebFetch
  triangulation for the proprietary-freeware conclusion);
  WebSearch triangulation: "DecentSampler dspreset file format specification…", "Pianobook dspreset
  example github…", "site:github.com \".dspreset\" raw file example…".
- Prior art on subset scoping (WebFetch):
  [sfizz opcode support status](https://sfztools.github.io/sfizz/development/status/opcodes/?v=aria),
  [liquidsfz OPCODES.md](https://raw.githubusercontent.com/swesterfeld/liquidsfz/master/OPCODES.md),
  [liquidsfz README.md](https://raw.githubusercontent.com/swesterfeld/liquidsfz/master/README.md);
  WebSearch: "sforzando SFZ opcode support list…", "Sitala sampler SFZ import support…" (no evidence
  found of Sitala SFZ support — noted, not fabricated).
- DAW Pro codebase (direct file read, not web):
  `Sources/DAWCore/Model.swift:1283-1350`,
  `Sources/DAWEngine/Instruments/SamplerInstrument.swift` (whole file; header comment 1-44, voice
  struct 93-106, init/load 154-227, apply(params:) 251-264, render/apply(event:) 273-491).
