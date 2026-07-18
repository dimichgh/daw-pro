# Sample-library import — supported subset

DAW Pro's built-in Sampler imports `.sfz` (documented subset) and `.dspreset`
sample-library files. This page is the exact boundary of that subset — the
same public-matrix posture the major SFZ engines (sfizz, liquidsfz) publish:
"unsupported" is a documented boundary, not a silent gap.

Three promises, in order of importance:

1. **What imports, plays as authored.** Key/velocity mapping, layering,
   round-robins, per-zone tuning/pan/envelope all land on the Sampler's own
   zone engine.
2. **What degrades is reported, never hidden.** Every import returns a
   report: zones imported, regions skipped (with reasons), opcodes ignored
   (with counts), plus plain-English degradation notes.
3. **What would sound WRONG is skipped, not approximated.** Release-trigger
   noises firing on note-on, or every keyswitch articulation layered at
   once, are worse than absence — those regions are skipped and counted.

Import via the Instrument Picker's "Import Sample Library…" button, the
`instrument.importSampleLibrary` control command, or the MCP tool. Use
`dryRun` to see the full report before touching your project.

Both format columns below are live. A `.dspreset` is one self-contained XML
file (no `#include`/`#define` layer exists in that format); its sample
`path`s resolve against the preset file's folder. The `.dslibrary`
container is a zip archive — unzip it and import the `.dspreset` inside.

## Supported (imported and played)

| Feature | SFZ opcodes | `.dspreset` attributes |
|---|---|---|
| Key mapping | `key`, `lokey`, `hikey`, `pitch_keycenter` — numbers AND note names (`c4`, `a#3`, case-insensitive, C-1…G9) | `rootNote`, `loNote`/`hiNote` — numbers AND the same note names |
| Velocity layers | `lovel`, `hivel` | `loVel`/`hiVel` |
| Round-robin | `seq_length`, `seq_position` | `seqMode="round_robin"` + `seqLength`/`seqPosition` (`seqMode="always"`, the format default, plays on every trigger — honored as authored) |
| Random alternation | `lorand`, `hirand` | `seqMode="random"` / `"true_random"` + `seqLength`/`seqPosition`, mapped onto one independent random draw per note-on (exactly `true_random`; plain `random`'s avoid-immediate-repeat nuance is not modeled) |
| Layering identity | `<group>` headers (independent ungrouped regions layer, per SFZ semantics) | `<group>` elements |
| Sample paths | `sample`, `default_path`; backslash/slash mixing, spaces, `..`-relative paths (noted in the report) | `path`, resolved against the preset file's folder |
| Preprocessor | `#include` (main-file-relative, nested; depth ≤ 16, ≤ 256 files) and `#define $VAR` macros | not part of the format (one self-contained XML file) |
| Tuning | `tune`, `transpose` (imported as one cents offset) | `tuning` (fractional semitones) |
| Level & pan | `volume` (dB, up to +6 dB), `pan`, `amp_veltrack` | `volume` (linear, or with a `dB` suffix), `pan`, `ampVelTrack` (0…1) |
| Envelope | `ampeg_attack`, `ampeg_decay`, `ampeg_sustain`, `ampeg_release` (per-zone 4-stage ADSR) | `attack`/`decay`/`sustain` (0…1)/`release` — the `*Curve` shape attributes are ignored (counted) |
| Sample span | `offset`, `end` | `start`/`end` |
| One-shot | `loop_mode=one_shot` (per-zone) | no equivalent in the imported subset |
| Sustain loops | `loop_mode=loop_continuous` / `loop_sustain`, `loop_start`/`loop_end` (also the v1 spellings `loopstart`/`loopend`; `loop_end` is inclusive) | `loopEnabled="true"` (continuous), `loopStart`/`loopEnd` (frames, end inclusive) |
| Loop fallback (WAV `smpl` chunk) | When the text authors no loop opcodes, a forward loop embedded in a WAV sample's `smpl` chunk enables continuous looping with the chunk's points. Authored opcodes win per field; an explicit `loop_mode=no_loop` (or `loopEnabled="false"`) suppresses the fallback entirely. | same |

Loop boundaries: only the FIRST forward (`dwType 0`) `smpl` loop is used —
ping-pong/backward loops, finite play counts (`dwPlayCount`), and
`dwFraction` sub-sample points are ignored; AIFF `INST`/`MARK` loop metadata
is out of scope. `loop_sustain` loops while the note (or the sustain pedal)
holds and plays through past the loop end on release; `loop_continuous`
loops through the release. The loop seam plays through a fixed equal-gain
crossfade (up to 512 source frames of pre-loop-start material); authored
crossfade lengths (`loop_crossfade`, `.dspreset` `loopCrossfade`/
`loopCrossfadeMode`) remain ignored and counted.

## Reported, not played (imported with a degradation note)

| Encountered | What happens |
|---|---|
| Invalid loop bounds (loop end before loop start, or outside the playable span), or loop points authored without a loop mode when the sample embeds no `smpl` loop | The zone imports WITHOUT looping, and the report counts it — never a skip. |
| Libraries referencing ≥ 500 MB of samples | Imported, with a warning — loading reads it all, and saving copies it into the project bundle. |
| Libraries referencing > 4 GB | Refused (the error names the limit) unless you pass `force: true`. |

## Skipped with a reason (playing them would be wrong sound)

| Encountered | Why skipped |
|---|---|
| `trigger=release` / `first` / `legato` (and `.dspreset` `trigger` ≠ `"attack"`) | Would fire release noises / transition samples on note-ON. |
| CC-triggered regions (`on_loccN` / `on_hiccN`; `.dspreset` `onLoCCN`/`onHiCCN`) | No CC gating engine; they would sound at the wrong times. |
| Keyswitched regions (`sw_last`) | Only the default articulation (`sw_default`, else the lowest keyswitch) is kept — importing all articulations would layer them simultaneously. |
| Regions whose sample file is missing, or is Ogg Vorbis (`.ogg`) | Checked at import time, per-file notes in the report (Core Audio cannot decode Vorbis). |
| `end=-1` | SFZ for "this region does not play". |

## Ignored (the region still imports and plays; the opcode is counted)

Filters (`cutoff`, `fil_*`), LFOs (`*lfo*`), EQ (`eqN_*`), crossfades
(`xfin_*`/`xfout_*`), CC modulation (any `_onccN`/`_curveccN` suffix),
voice-management (`group`=polyphony-group opcode, `off_by`, `polyphony`,
`rt_decay`), `<curve>`/`<effect>` headers — and for `.dspreset`: `<ui>`,
`<midi>`, `<effects>` elements, CC gating (`loCCN`/`hiCCN`), output
routing, curve attributes, authored loop crossfades (`loopCrossfade`/
`loopCrossfadeMode`), `silencedByTags`/`tags`, `delay`, `pitchKeyTrack`. The
instrument plays as authored minus these layers; each ignored name is
tallied in the report. A recognized attribute whose VALUE fails to parse
degrades to the same tally — it never aborts the import.

## Hard refusals (structured errors, nothing imported)

- A missing or cyclic `#include`, or an undefined `$VAR` — the error names
  the exact file, cycle, or variable. A partially macro-expanded file would
  import garbage, so it never imports at all.
- Malformed `.dspreset` XML, or well-formed XML whose root element is not
  `<DecentSampler>` — the error names the file and the XML diagnostic.
- An import that yields ZERO playable zones — the error carries the skip
  summary instead of leaving a silent instrument on your track.
- `.dslibrary` files — a zip archive; unzip it and import the `.dspreset`
  inside.
