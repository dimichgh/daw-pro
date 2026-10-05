# Demo render harness

`render-variants.mjs` turns one JSON **spec** into a **set of listenable
`.wav` variants**, measures every one of them, and refuses to call a render
"audible" on vibes — it proves its own audibility gate can fail by measuring
a known-silent file through the exact same code path first.

This is tooling, not a product feature: the way we produce review sets for
"here are 3-4 options, tell me which one you like" — the standing rule for
audio feedback in this repo (the user is not a musician; their **pick** is
the feedback, never a single "best" render).

## Quick start

```bash
node scripts/demos/render-variants.mjs scripts/demos/specs/polysynth-cutoff.json
```

Renders land in `scripts/demos/out/<set>/` (gitignored — audio renders are
never committed), alongside a `manifest.json` with every measured number.

```
scripts/demos/out/polysynth-cutoff/
  demo-polysynth-cutoff-muffled.wav
  demo-polysynth-cutoff-singing.wav
  demo-polysynth-cutoff-bright.wav
  manifest.json
```

### CLI

```
node scripts/demos/render-variants.mjs <specPath.json> [options]
  --mode=headless|app   default: headless
  --out=<dir>           default: scripts/demos/out/<set>
  --skip-build          default: false (ALWAYS rebuilds first otherwise —
                         see "Why headless is primary" below for why this
                         matters more than it looks like it should)
```

Exit codes: `0` every variant rendered and passed the audibility gate ·
`1` a variant failed to render or failed the gate · `2` spec/build/
infrastructure error · `3` the silence positive control did not report
silence — **nothing was scored**.

## Why headless is primary

`DAWApp` is a SwiftUI app — it wants a window server, and a locked screen or
missing GUI session at 3am can wedge or fail that launch with nobody around
to notice. So the **default and primary** render path
(`--mode=headless`, the default) never launches the app at all: it shells
out to `DemoRender` (`Sources/DemoRender/DemoRender.swift`), a tiny Swift
executable that renders through `ProjectStore` + a real `AudioEngine` +
`OfflineRenderer` directly — the exact same offline path `render.mixdown`
uses in production, no window server, no control port. This is precisely
what `Tests/DAWCoreTests/MixdownTests.swift` and
`Tests/DAWEngineTests/FXPack1Tests.swift` already do headlessly, hundreds of
times, in this exact environment.

`DemoRender` depends on **`DAWCore` + `DAWEngine` only** — never
`DAWControl`, never `DAWApp` — on purpose: those two modules can be mid-edit
by a concurrent agent without ever blocking a demo render.

A **secondary, opt-in** `--mode=app` path exists for when you want to prove
the *real* user-facing render through the actual control-protocol wire: it
launches a **staging** app instance (port **17695**, never **17600** — that
is the user's live app) via the shared `scripts/gates/_staging.mjs` home
(never hand-rolled — see that file's own header for why a bypass there is a
known near-miss shape in this repo) and drives the same spec over the wire.
It is not required for a routine render.

Either path rebuilds explicitly before running (`swift build`) unless
`--skip-build` is passed — `swift build`/`swift test` can relink the binary
underneath a run in progress (several agents share this tree concurrently),
so "rebuild first" is the safe default, not an optimization to skip. Every
manifest records the exact binary's sha256 for provenance — a render whose
provenance isn't named is not evidence.

## Spec format

```jsonc
{
  "set": "<name>",                 // renders land in out/<name>/
  "description": "<optional prose>",
  "measurement": { "type": "periodicDucking", ... },  // OPTIONAL, see below
  "variants": [
    {
      "name": "<variant>",         // file: demo-<set>-<variant>.wav
      "axis": "<one line: what differs from the others>",
      "role": "control",           // OPTIONAL — marks the baseline variant
      "measureStem": { "trackId": "$bus" },  // OPTIONAL, see below
      "render": { "fromBeat": 0, "durationSeconds": 8 },  // OPTIONAL
      "commands": [
        { "command": "track.add", "params": { "name": "Lead", "kind": "instrument" }, "as": "lead" },
        { "command": "track.setInstrument", "params": { "trackId": "$lead", "kind": "polySynth", "cutoffHz": 600 } },
        { "command": "clip.addMIDI", "params": { "trackId": "$lead", "atBeat": 0, "notes": [
          { "pitch": 60, "startBeat": 0, "lengthBeats": 1 }
        ] } }
      ]
    }
  ]
}
```

Each variant is applied to a **freshly created, freshly named** project —
`demo-<set>-<variant>` — never a shared or ambiguous one (the standing "name
your own test/dogfood work" rule). In headless mode that name exists only in
process state (nothing but the `.wav` ever touches disk, so there is no
ownership question to begin with); in app-mode the session is additionally
saved to a `.dawproj` beside the render.

### Commands

`commands` is a list of `{ "command": "...", "params": {...}, "as": "..." }`
entries, applied in order. The vocabulary mirrors (a small, deliberately
grown-as-needed subset of) the real control-protocol commands in
`Sources/DAWControl/Commands.swift` — **same names, same param shapes**:

| command | params |
|---|---|
| `track.add` | `name?`, `kind?` (`audio`\|`instrument`\|`bus`, default `audio`) |
| `track.setInstrument` | `trackId`, `kind?` (`polySynth`\|`sampler`\|...), `waveform?`, `attack?`, `decay?`, `sustain?`, `release?`, `cutoffHz?`, `resonance?`, `gain?` |
| `clip.addMIDI` | `trackId`, `name?`, `atBeat?`, `lengthBeats?`, `notes?` (array of `{pitch, startBeat, velocity?, lengthBeats?}`) |
| `fx.add` | `trackId`, `kind` (`eq`\|`compressor`\|`limiter`\|`reverb`\|`delay`\|`gate`\|`chorus`\|...), `index?`, `params?` (initial param values) |
| `fx.setParam` | `trackId`, `effectId`, `name`, `value` |
| `track.addSend` | `trackId`, `busId`, `level?` |
| `fx.setSidechain` | `trackId`, `effectId`, `sourceTrackId?` (omit or `null` clears the key) |

⚠️ **The real wire verb is `clip.addMIDI`** (capital MIDI) — not
`clip.addMidi`. If you extend the vocabulary, confirm the exact spelling and
param shape against `Sources/DAWControl/Commands.swift` (grep for
`case "the.verb":`) rather than guessing; the contract-discipline rule in
`CLAUDE.md` applies here too — if you add a command to `DemoRender.swift`
that doesn't already exist on the wire, it isn't a demo-harness bug, it's a
missing control command.

To extend the vocabulary, add a `case` to the `switch` in
`Sources/DemoRender/DemoRender.swift`'s `renderVariant` (headless) — the
`app`-mode path needs no code change, since it sends whatever command name
you write straight over the wire.

### `"$binding"` — the one piece of shared interpreter state

A command's response can be bound to a name via `"as"`, then referenced by
**any later command in the same variant** as `"$name"` in place of a literal
id:

```jsonc
{ "command": "track.add", "params": {...}, "as": "lead" },
{ "command": "track.setInstrument", "params": { "trackId": "$lead", ... } }
```

**Both render paths bind the same way** — headless resolves `"as"` from the
real Swift return value (`Track.id`, `Clip.id`, `EffectDescriptor.id`,
`Send.id`); app-mode resolves it from the real wire response (`result.id` /
`result.effectId` / `result.sendId`). This is the one place the two paths
could silently disagree, so it is deliberately implemented as "read the id
back off whatever really happened," not duplicated logic that could drift.

### `measureStem` — isolating a bus/track for measurement

The **shipped, listenable file is always the full mixdown**. But a
measurement that cares about ONE bus's signal (e.g. "is this reverb bus
pumping?") can be swamped by whatever else is playing directly into the
master mix at the same moment — a kick drum's own direct sound, for
instance, is identical across every variant and will dominate a naive
RMS window taken while it's still audible.

`"measureStem": { "trackId": "$bus" }` on a variant makes `DemoRender`
additionally call `render.stems` for just that track/bus (written to a
sibling `_stems-<set>-<variant>/` directory) — which preserves the REAL,
live sidechain-affected output (stems reflect the actual keyed-compressor
result, not a re-derivation) while excluding everything not routed through
that bus. The harness then measures ducking on the isolated stem, and
reports which file it actually measured (`ducking.measuredPath` in
`manifest.json`) so it's never ambiguous.

### `measurement` — the periodic-ducking analyzer

Optional. When present with `"type": "periodicDucking"`, the harness decodes
each variant to raw mono PCM (no resampling — an envelope through a
resample would alias) and computes short-window RMS in dB at two points per
cycle: a **trough** window (shortly after each cycle's onset) and a **peak**
window (right before the next one), averaged across many cycles (skipping a
few at each edge to avoid startup/tail transients):

```jsonc
"measurement": {
  "type": "periodicDucking",
  "periodSeconds": 0.5,          // e.g. one kick per beat at 120 BPM
  "cycleStartSeconds": 0.0,
  "cycleCount": 32,
  "skipEdgeCycles": 2,
  "troughOffsetSeconds": 0.02, "troughWindowSeconds": 0.15,
  "peakOffsetSeconds": 0.35,   "peakWindowSeconds": 0.13,
  "compareToRole": "control"   // which variant's "role" is the baseline
}
```

The **load-bearing number is `meanDepthDb`** (the peak-window level minus
the trough-window level, averaged across cycles, WITHIN one file) — this
*is* "periodic variation at the kick rate": a flat/un-keyed signal reads
close to 0 dB, a genuinely pumping one reads clearly positive, and it scales
with how deep the duck is. The harness also reports
`troughAttenuationVsControlDb` / `peakAttenuationVsControlDb` (the same
window, same offset, compared ACROSS variants against the control) — these
are informative but can be confounded when the control's own processing
runs a different *average* gain (e.g. an un-keyed compressor riding a
constantly-present signal compresses it continuously, which changes overall
level independent of any pumping); read `meanDepthDb` first.

## Worked examples

### 1. `specs/polysynth-cutoff.json` — a filter sweep, one axis

The built-in PolySynth playing a short saw-wave arpeggio, **`cutoffHz`** as
the one axis: 600 / 2500 / 9000 Hz — closed, singing, and nearly-open. A
filter sweep is the gesture this product is weakest at, so it reads clearly
by ear.

```bash
node scripts/demos/render-variants.mjs scripts/demos/specs/polysynth-cutoff.json
```

Measured 2026-09-19 (headless; reproduced across **two** separate
`DemoRender` builds spanning a concurrent unrelated edit elsewhere in the
tree — `e32a98e9…073732`, then `a565d715…d31c57` after `DAWEngine` changed
underneath — same LUFS/peak to one decimal both times):

| variant | axis | integrated LUFS | true peak |
|---|---|---|---|
| muffled | 600 Hz | -17.8 | -9.2 dBTP |
| singing | 2500 Hz | -18.4 | -7.4 dBTP |
| bright | 9000 Hz | -19.1 | -7.9 dBTP |
| *(silence control)* | — | -70.0 | -inf |
| *(sine control)* | 440 Hz tone | -21.8 | -21.1 dBTP |

All three variants have distinct sha256 hashes (the axis really took) and
pass the audibility gate.

### 2. `specs/kick-duck-reverb.json` — does sidechain-ducked reverb already work?

Tests a real hypothesis with zero new code: a kick + a sustained pad feeding
a reverb bus, with a **compressor after the reverb on that bus, keyed off
the kick** — the classic "pumping" reverb technique. Four variants, one axis
each: `control` (sidechain cleared — the positive control), `duck-fast`
(keyed, 80 ms release), `duck-slow` (keyed, 700 ms release), `duck-deep`
(keyed, extreme threshold/ratio).

```bash
node scripts/demos/render-variants.mjs scripts/demos/specs/kick-duck-reverb.json
```

This spec uses `measureStem` (isolating the reverb bus, via `render.stems`)
and `measurement` (`periodicDucking`), because a naive measurement of the
full mixdown is swamped by the kick's own direct sound (identical across
every variant) — see that section above for why.

Measured 2026-09-19 (headless, `DemoRender` sha256 `a565d715…d31c57`),
`meanDepthDb` = the peak-window level minus the trough-window level within
one file, averaged across 28 cycles — this **is** "periodic variation at the
kick rate":

| variant | axis | meanDepthDb (pumping) |
|---|---|---|
| control | sidechain cleared | **-0.17 dB** (flat — no pumping, as expected) |
| duck-fast | keyed, 80 ms release | **+3.65 dB** |
| duck-slow | keyed, 700 ms release | **+2.42 dB** |
| duck-deep | keyed, -40 dB/20:1 | **+13.23 dB** |

**Conclusion: confirmed, with zero new code.** The control shows ~0 dB of
periodic variation (an un-keyed compressor riding a roughly-constant signal
doesn't pump); every sidechain-keyed variant shows a clear, non-zero swing,
and `duck-deep`'s swing is ~3.6x `duck-fast`'s — the right direction for a
much more aggressive threshold/ratio. All four renders are audible and
byte-distinct. One honest nuance: `duck-slow`'s swing (2.42 dB) reads
*smaller* than `duck-fast`'s (3.65 dB) at these fixed windows — that is not
"less ducking," it's the correct signature of a slow release: the signal
stays MORE UNIFORMLY suppressed across the whole cycle (less within-cycle
recovery) rather than swinging back up before the next hit, which the
harness's `troughAttenuationVsControlDb`/`peakAttenuationVsControlDb`
numbers in `manifest.json` show directly (`duck-slow`'s peak window stays
2.83 dB below control's, vs. `duck-fast`'s 7.17 dB — `duck-fast` recovers
much further by the end of each cycle).

**Two findings that the numbers above don't cover on their own** (also
printed by the harness and written to `manifest.json.duckingFindings`):

1. **This measurement is on the isolated reverb-bus stem, not the shipped
   mixdown.** The `.wav` you'd actually hand someone is the full mix, where
   the dry pad and kick dilute the wet bus. Audible pumping in *that* file is
   **unmeasured** — likely subtle for `duck-fast`/`duck-slow` and clearer for
   `duck-deep`. The stems themselves (`ducking.measuredPath` per variant,
   under `_stems-kick-duck-reverb-<variant>/01 Reverb Bus.wav`) are
   unambiguous and directly listenable — if you want to *hear* the effect
   proven above rather than take the numbers' word for it, listen to those,
   not the top-level `.wav`s.
2. **The control is not a "bypassed compressor" baseline.** Its compressor is
   wired with the sidechain cleared, so it self-keys off the reverb's own
   roughly-constant level and applies a flat ~7 dB continuous reduction. The
   within-file `meanDepthDb` comparison above is unaffected by this (control
   reads ≈0 dB either way), but an ear doing control-vs-`duck-fast` A/B will
   also hear a level difference that is **not** the pumping effect. A true
   bypassed-compressor baseline would be a different control variant — not
   built here, since the spec asked for "sidechain cleared" and that's what
   shipped.

## Positive controls (why the gate can be trusted)

Before rendering anything, the harness synthesizes and measures **two**
known files through the *identical* `measureLoudness()` code path every real
variant uses:

- a 2 s digital-silence file (`anullsrc`) — must read `I <= -60 LUFS` and a
  true peak of `-inf` or `<= -60 dBTP`. If it doesn't, the harness aborts
  with exit code `3` **before scoring anything** — a clean run from a blind
  checker is worse than no run.
- a 2 s 440 Hz sine tone — must read `I > -40 LUFS`. A gate that can only
  ever say "no" is exactly as blind as one that can only ever say "yes."

## ffmpeg measurement — the one mistake that keeps recurring

**`ffmpeg -v error` suppresses the `ebur128`/`astats` summary blocks** — they
log at `INFO`, not `ERROR`. This harness uses `-hide_banner` instead, which
quiets the banner without touching the log level. This exact mistake has
produced a confident wrong answer in this repo before; if you're extending
this script, don't reach for `-v error` "to reduce noise."
