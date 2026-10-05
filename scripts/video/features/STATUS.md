# Demo film — status

Staging: DAWApp pid on **17695** (launcher parks; kill the LAUNCHER to stop it).
`staging.json` holds pids. **17600 was never touched and is not running.**

## Done and verified by me

### Variant A — "Machine Room" (original, A minor, 128 BPM, 64 bars = 2:00)
- `out/machine-room/machine-room.wav` — **-15.6 LUFS, -1.0 dBTP, LRA 11.9**
- structure ASSERTED, not assumed: drop is **+6.4 dB louder and +33.1 dB brighter**
  than the intro; breakdown **16.3 dB** below the drop; no silent section.
- **33 shots**, every one distinct from the one before (or marked expected-identical),
  including a **10-frame motion burst** with the transport actually running.
- `out/machine-room/video/machine-room-{long,short}.mp4` — 1920x1080 / 1080x1920,
  both opened and looked at. ⚠ THESE PREDATE the dynamic-EQ fix — re-render.

### Variants B and C — built from `MELODIES.md`
- **B "Mountain King"** — Grieg, *In the Hall of the Mountain King* (1875). PD since
  1977 and published pre-1929. Pitches off the Mutopia PD engraving.
- **C "Fate"** — Beethoven 5th (1808), opening motif only.
- One axis apart: same structure, tempo, drums, kit and effect chain; **only the
  source material differs.**

### Tooling built
- `arrange.mjs` · `material.mjs` · `build.mjs` · `measure.py` · `viz/viz.py`
- `prove-deq.mjs` / `tune-deq.mjs` — the physics proof for the dynamic EQ

## Facts established against the RUNNING ARTIFACT (not source, not docs)
- **22 built-in insert kinds** + `audioUnit`; **11 of the 22 are new** in the three
  commits being demoed. ⭐ RE-VERIFIED BY ME against git (not taken from the
  agent's census): `Effects.swift`'s `Kind` enum had **12** cases at `c3fe918`
  and **23** at HEAD; the 11 added are clipper, djFilter, dynamicEQ, flanger,
  freqShifter, hallReverb, phaser, ringMod, stereoWidth, tapeDelay,
  transientShaper. The first extraction returned EMPTY for both revisions — a
  broken awk pattern reading as "nothing changed" — and was only caught by a
  positive control asserting HEAD must be non-empty.
  The mixer shot shows **10 insert instances / 9 distinct kinds** — do not say
  "eleven" over that picture.
- instrument kinds: `testTone|polySynth|sampler|audioUnit|soundBank|drumSynth`
- drum voices are MIDI **36-43**; 5 kits; `accentThreshold` default **100**.
- `djFilter.position`: 0 is a **bit-exact bypass**; negative muffles, positive thins.
- master automation is **volume-only in v1** — effectParam lanes need a real track.
- `limiter.truePeak` defaults to **0 (OFF)**.
- `transport.seek` takes **`beats`**, not `beat`.
- `view.openEditor` takes ONLY `trackId`/`effectId`. **There is no close verb** —
  `view.closeEditor` does not exist. A card, once open, stays for the whole build.

### ⭐ `loadDrumPreset` DOES take — proven by parameter diff, not by its return
`describeDrumKit` shape is `voices[name].parameters[param].value` (my first
accessor missed the `parameters` level and returned all-null, which read as
"the preset did nothing").
- 909 moves **17** of 71 voice params: `kick.decay` 0.62 -> **0.26** (the 808's
  long fall becoming the 909's short body), tune 52->58, drive 0.12->0.3.
- trap moves it the OTHER way: `kick.decay` 0.62 -> **1.45**.

### ⛔ THE DYNAMIC EQ WAS A BIT-EXACT BYPASS AND EVERY GATE PASSED IT
`bandNMode` defaults to **0 = OFF**, which the app documents as "a TRUE no-op —
the band's filter is not even run". The build set freq/threshold/range/ratio on
two bands and never set the mode. Measured on 8 bars of the same bass:

| configuration | 90 Hz band RMS | note |
|---|---|---|
| band OFF (defaults) | -32.21 dB | |
| knobs set, **mode not set** | -32.21 dB | **byte-identical md5 to OFF** |
| mode 1, threshold -22 | -32.30 dB | 0.09 dB — decorative |
| mode 1, threshold **-42** | **-34.50 dB** | **2.29 dB — real** |

Threshold -50 buys 0.08 dB more, so -42 is the knee. The card photographed
fine, the render measured fine, and the effect was doing nothing.

## ⛔ MUST NOT CLAIM IN THE FILM
- **The drum machine has NO editor card.** The app refuses `view.openEditor` on it
  by name: "has no editor card yet — its 75 parameters are on the wire."
- **The modulation layer has zero UI.** Audible, never screenshottable.
- **Multi-instrument templates are designed but unbuilt.**
- Effects render at **Pro density only**.
- The pad grid *does* play the drum machine but the squares draw blank.
- There is **no zoom verb**, so the arrange view cannot fit all 64 bars.
- **⛔ AUTOMATION DOES NOT MOVE THE EFFECT CARD'S KNOB DURING PLAYBACK.** Across
  all 10 motion frames the DJ Filter card reads its authored -0.55 while the
  clock runs. Automation demonstrably drives the RENDER (+33 dB brighter drop).
  The motion frames honestly show **metering and the playhead**, not a knob
  turning itself. Do not narrate it as one.
- **Beethoven's continuation is NOT Beethoven's** — only the 4-bar motif is
  transcribed; the repeat is our arrangement choice and must be disclosed.
- Grieg's raised 6th (G#) is MEDIUM confidence, and the tempo is 128, not 138.
- **Sub-bass warning:** Grieg's F#1 is ~46 Hz and will not exist on a phone.

## Mistakes this session, kept because they are the film's honesty
1. `lsof -p ""` (empty pidfile var) listed the WHOLE MACHINE and read as a pass.
2. ebur128 parsed with a bare `I:` returned the FIRST PER-FRAME line: **-70.0 LUFS**
   beside -14 dB RMS. Now anchored on the summary block + a cross-check.
3. First render: -13.9 LUFS (healthy) with **true peak +1.6 dBFS** (clipping).
4. First mix did not BUILD: intro -14.3 vs drop -14.2. Fixed with the sweep.
5. `.catch(() => {})` swallowed a `panel` vs `workspace` refusal.
6. Three "new effect" shots were **byte-identical** — fixed by opening the card.
7. The app sat in the **MIX workspace** for every shot captioned arrange —
   found only by OPENING THE PNG.
8. **The `mixer` shot was two stacked cards covering the mixer.** An INSTRUMENT
   card is a layer effect cards do not replace, and nothing can close it. Fixed
   by ordering: clean shots first, cards after, poly synth last of all.
9. **The dynamic EQ was off.** See the table above.
10. `describeDrumKit` accessor missed a nesting level and returned all-null,
    which looked exactly like "the preset did not take".

## Outstanding
- re-render Variant A's two videos (they predate the dynamic-EQ fix)
- long + short visualiser videos for B and C
- the narrated film: intro + "how you build one" + payoff
- film-observer pass before release
- window pin never announced itself: shots are 2880x1800 = 1440x900 logical,
  the app default, NOT the 1600x1000 that was asked for. Not blocking.
