---
name: sample-flip
description: Turn a record into an instrument and write new music from it — capture, chop, repitch, choke, reverse and crush a source recording into an original track, then resample the result. Use for "flip this sample", "chop this break", "make a beat out of this record", "turn this loop into pads I can play", or "sample this and write something new".
---

# /sample-flip — turn a record into an instrument

Sampling is not "import an audio file". It is a craft with a shape: **capture
a piece of a recording, chop it, reshape the chops, and play them as a new
performance.** The source stops being a loop you drop on a timeline and
becomes an instrument you write with. This skill teaches that shape on DAW
Pro's actual wire.

Read the shared `daw-wire-reference` skill first — it carries the id-capture
rules, the beats-vs-seconds law, and the etiquette every call here obeys.

## Who holds what

⭐ **Check which reader you are before you read the table — it decides whether
the table is instructions or background:**

- **You have a Task/Agent tool** (you are the main session, or any agent that
  can spawn others): the table is your routing plan. Delegate by it.
- **You do NOT have one** (you are one of the plugin's own agents — they carry
  MCP tools only): the table is background. **Do the part your chair holds,
  then return a hand-off plan** naming the next specialist, what to ask for,
  and the real ids. Never silently skip a step you cannot reach.
- **You hold every tool directly** (a session driving the wire or the MCP
  server itself): ignore the routing entirely and **go straight to §1** — the
  numbered sections are self-sufficient and are the actual recipe. Nothing
  below depends on the split.

No single agent holds this whole workflow, and that is deliberate — the
plugin's chairs are curated per domain:

| Step | Agent | The tools it holds |
|---|---|---|
| Open/name/save the project, set the tempo | **producer** | `project_new`, `project_save`, `project_open`, `transport_set_tempo`, `track_add`, `marker_add` |
| Analyze, find chops, chop, write the new pattern | **composer** | `clip_analyze_audio`, `clip_detect_transients`, `clip_slice_to_sampler`, `clip_quantize_audio`, `clip_add_midi`, `clip_get_notes`/`clip_set_notes`, `clip_add_audio`, `track_add` |
| Shape the pads and the tone | **sound-designer** | `clip_slice_to_sampler`, `instrument_describe_sampler`, `instrument_set_sampler_zones`, `instrument_set_sampler_param`, `track_set_instrument`, `fx_add`/`fx_set_param`/`fx_describe` |
| Rearrange the chopped clips on the timeline | **arranger** | `clip_move`, `clip_split`, `clip_duplicate`, `clip_remove`, `clip_crossfade`, `clip_set_fades` |
| Levels, buses, the crush on a whole drum bus | **mix-engineer** | `fx_add`/`fx_set_param`, `track_set_volume`/`_pan`, `render_measure_loudness` |
| Bounce, and the resample loop's render half | **finisher** | `render_bounce`, `render_stems`, `render_measure_loudness`, `audio_profile_file` |

⭐ **`clip_slice_to_sampler` is granted to BOTH composer and sound-designer
on purpose** — a flip legitimately starts from either chair. Composer already
holds the chop-point finder and writes the MIDI the tool emits; sound-designer
owns the sampler that receives the pads.

⚠️ **Composer cannot bounce and sound-designer cannot detect transients.** The
resample loop (step 8) therefore crosses chairs: composer or sound-designer
does the flip, **finisher** renders, composer imports the render back. Plan
the hand-offs; do not expect one agent to close the loop alone.

⚠️ **A flip that stops before the resample should say it stopped there and
why** — never present a partial chain as a finished flip.

⚠️ **`instrument_set_sampler_zones` is an MCP-side tool with no single wire
command behind it.** If you are driving the raw control wire rather than the
MCP surface, it is not there to call — use `track.setInstrument` with
`sampler.zonePatches` (§7), which is the merge path anyway.

## 1. Orient — what IS this recording?

```
clip_analyze_audio {clipId}
```

⚠️ **The response is NESTED, and the fields are not where you would guess.**
Measured against a running build 2026-08-29:

```
{ stretchRatio, pitchShiftSemitones,
  analysis: {
    tempo:    { bpm?, steady, confidence, alternates },
    key:      { tonal, tonic?, mode?, confidence, alternatives },
    spectral: { centroidHz, bands, summary },
    rmsDb, samplePeakDb, durationSeconds, sampleRate, analyzerVersion } }
```

There is **no flat `bpm`, `steady`, `keyTonic` or `keyMode`** — reach for
`analysis.tempo.bpm` and `analysis.key.tonic`/`.mode`. Do this **before** you
chop, because the flip has to be reconciled with the project:

- **`tempo.bpm` vs the project tempo.** They will not match. You have two
  honest choices and they sound different: move the project to the record
  (classic, keeps the chops at their recorded speed and pitch) or leave the
  project and let the pads land where they land (the chops then play against a
  grid they were not recorded to, which is its own aesthetic).
- **`key.tonic`/`key.mode`** tells you what key everything you write on top has
  to live in — or what to transpose the pads toward. ⚠️⚠️ **`tonic` AND `mode`
  ARE ALWAYS PRESENT, INCLUDING WHEN THEY MEAN NOTHING. `key.tonal: false` still
  ships a tonic.** Measured on a drum break: `{tonal: false, tonic: "D",
  mode: "major", confidence: 0.209}`. **A present `tonic` is NOT evidence the
  material is tonal** — read `key.tonal` and `key.confidence`, in that order,
  and ignore tonic/mode entirely when `tonal` is false. Percussive material is
  routinely atonal; that is a correct answer, not a failure. Writing a bassline
  in D major over an atonal break because the field was populated is the exact
  mistake this bullet exists to prevent.
- ⭐ **The two blocks behave OPPOSITELY, which is the real trap here.** `tempo`
  OMITS `bpm` when it detects nothing; `key` POPULATES `tonic`/`mode` when it
  detects nothing. **You cannot use "is the field there?" as your test for
  both** — for tempo, presence is the signal; for key, the `tonal` flag is.
- ⭐ **No detected tempo means `tempo.bpm` is ABSENT — not null, not zero.**
  Material under about 6 seconds, or with no steady pulse, has nothing to lock
  a project tempo to. Test for the key's presence; a defaulting read invents a
  tempo that was never measured. `tempo.steady: false` means the pulse drifts,
  so no single fixed tempo tracks the whole clip.
- ⚠️ **`analysis` is the SOURCE FILE's own domain**, from before this clip's
  stretch/pitch. A stretched or pitched clip also gets a `playback` block with
  the derived on-timeline figures. Read `playback` for what it sounds like
  now; read `analysis` for what the recording contains.

## 2. Find the chops

```
clip_detect_transients {clipId, sensitivity}
```

Returns `{transients: [{sourceSeconds, beat, strength}], count}` — only onsets
inside the clip's current window.

⭐⭐ **It returns BOTH coordinates, and which one you want depends entirely on
where the chop is going:**

- **`beat`** — the onset mapped onto the timeline at the current tempo/stretch.
  This is what timeline work reads (`clip_split`'s `atBeat`, placing a clip).
- **`sourceSeconds`** — the onset's position inside the SOURCE FILE.
  Geometry-free: trimming or splitting the clip never moves it. This is the
  coordinate the sampler-zone world is built on.

`sensitivity` (0..1, default 0.5): low finds only strong hits (clean drums),
high finds many (ghost notes, legato phrases). **Quiet or sustained material
yields few onsets at any setting — that is honest, not a bug**, and it is your
signal to switch to `divisions` in step 3.

Run this first even when you intend to let `clip_slice_to_sampler` detect for
itself. It is read-only, it makes no undo entry, it is cached per
(file, sensitivity), and `count` tells you whether the chop you are about to
commit will produce 4 pads or 40.

## 3. Chop — two destinations, and they are DIFFERENT VERBS on purpose

This is the fork in the whole craft. Both are one call, both are one undo step,
and choosing wrong wastes a debugging loop.

### 3a. → SAMPLER PADS (play the record on a keyboard)

```
clip_slice_to_sampler {clipId, mode, ...}
```

One zone per slice, all pointing at the SAME source file, one pad per MIDI note
from `baseNote` up — plus, by default, a MIDI clip that **replays the original
groove**. That reconstruction is the point: you start from something that plays
back identically to the record, then reorder, mute, retune and rearrange the
pads to make something new. This is the MPC / SP-1200 / Recycle chop.

**The source clip is not touched** — not sliced, not moved, not replaced.

| Param | Meaning |
|---|---|
| `mode` | `"transients"` (default), `"divisions"`, or `"grid"` |
| `sensitivity` | 0..1, default 0.5 — `"transients"` mode ONLY |
| `divisions` | 2..128 equal parts — required by, and only valid in, `"divisions"` |
| `gridBeats` | grid in beats (1 = 1/4, 0.5 = 1/8) — required by, and only valid in, `"grid"` |
| `targetTrackId` | existing instrument track; omit and a new `"<clip> chops"` track is created and returned as `createdTrackId` |
| `baseNote` | MIDI note of the FIRST pad, default **36 (C1, the MPC pad-1 note)**. Pads are numbered by the 0-based `index` in the returned `slices` array: **`pitch = baseNote + index`**, so the first pad is at `baseNote` itself. 16 pads from the default land on 36–51. |
| `maxSlices` | refusal ceiling, default 32, hard cap 96 |
| `minSliceSeconds` | minimum pad width, default 0.05. ⭐ **This — not `sensitivity` — is the pad-count knob.** Onsets closer together than this are merged, so raising it is how you get fewer, longer pads out of busy material. |
| `snapWindowMs` | boundary snap half-width, default 3; 0 disables |
| `includeHead` | keep the audio BEFORE the first slice point as the first pad, default false |
| `generateMIDI` | write the reconstruction clip, default true |
| `atBeat` | where the reconstruction lands, default the source clip's own start |
| `velocityFromStrength` | map detector strength to velocity instead of 127, default false |

Returns `{trackId, createdTrackId?, midiClipId?, sampleRate, frameCount,
sliceCount, headSeconds, slices: [{index, pitch, startFrame, endFrame?,
sourceSeconds, beat, strength?, snapOffsetFrames?, residualAmplitude?}],
warnings}`. **`sampleRate`/`frameCount` are the SOURCE FILE's own, and every
frame number is in those units.**

Things worth knowing before you call it:

- **Parameters that do not belong to the chosen mode are REJECTED by name**,
  not silently ignored. `sensitivity` with `mode: "divisions"` is an error.
- **Reconstruction notes are velocity 127, not the detector's strength.** The
  sampler's amp law is `velocity/127 x zone gain`, and the slice already
  carries its own recorded level — a ghost note fired at velocity 13 would land
  about 20 dB below itself. 127/127 is exactly 1.0, a level-faithful replay,
  and velocity stays live for any NEW pattern you write. `strength` is in the
  response either way.
- **Every boundary is snapped once** to the quietest nearby frame and shared by
  both adjacent pads, so a pad played alone does not click; each pad gets a
  0 ms attack (keeps the transient) and a 10 ms release (the real fix for the
  click at the END of a slice). On a stereo file there is often no simultaneous
  zero crossing, so each slice reports **`residualAmplitude`** — how quiet the
  cut actually is — rather than implying a clean one.
- **Chopping onto a track that already has zones REPLACES them** and says so in
  `warnings`.
- **`headSeconds` is always reported. READ IT — do not wait for a warning.**
  ⚠️ **The warning has a threshold and it is higher than you would guess:
  measured 2026-08-29, a 0.333 s head that contained the break's own downbeat
  produced NO warning at all; the warning first fires around 0.714 s.** So the
  warning catches a badly missed head, not a musically important one. A third
  of a second is a whole downbeat. **Check `headSeconds` against the material
  yourself every time**, and if it holds anything you want, re-run with
  `includeHead: true`.
- ⚠️ **`clip_detect_transients`' `count` does NOT predict how many pads you
  get.** It is the raw onset count before `minSliceSeconds` merging and the
  `maxSlices` ceiling — measured 43 onsets producing 36 pads on the same clip.
  Use it to confirm the detector found *something*; use `sliceCount` in the
  chop's own response for what you actually got.
- ⚠️ **`divisions: N` gives you N−1 pads unless you pass `includeHead: true`.**
  N cuts across the clip yield N spans, and the first one — the head, before
  the first cut — is discarded by default like any other head. Ask for 8 and
  count 7. (The accompanying warning text mentions "the detector" and "the
  first onset" even in `divisions` mode, where no detector ran; ignore that
  wording, the arithmetic above is what happened.)
- **Refusals, all of which change nothing:** a MIDI clip; a time-STRETCHED or
  PITCH-SHIFTED clip (pads read RAW source frames, so the reconstruction would
  not match what you hear — un-stretch, clear the pitch, or bounce first);
  `mode: "grid"` on a clip spanning a tempo change (`"transients"` and
  `"divisions"` are fine there); a non-instrument `targetTrackId`; no usable
  boundary; and **more pads than `maxSlices`, or a pad past MIDI note 127 —
  those two REJECT rather than truncate**, because a chop quietly missing its
  last bar still looks like a successful chop.

### 3b. → TIMELINE CLIPS (rearrange the record itself)

```
clip_quantize_audio {trackId, clipId, strength: 0}
```

**With `strength: 0` this is a pure CHOP** — N butt-joined slice clips that
stay EXACTLY where they were, in one undo step, with no crossfades. That is the
tool when you want to chop a break into separate clips you can drag, delete,
duplicate or reorder on the timeline. `gridBeats` may be OMITTED at an explicit
`strength: 0`, because nothing is nudged and a pure chop needs no grid.

⭐ **It is click-free by construction, and the reason matters:** slice *i* ends
at frame *k* and slice *i+1* begins at frame *k*, so the concatenation IS the
original waveform. Nothing has to be crossfaded because nothing was cut away.
(This is why clicks are specifically a *zone-destination* problem — a pad
played in isolation starts and ends at arbitrary sample values, which is what
the snapper and the 10 ms release in 3a are for.)

**`divisions: N` (2..128)** cuts into N EQUAL parts instead of at transients —
the fallback when transients are wrong or absent: **drones, pads, ambient beds,
already-quantized loops.** It runs no detector, so `sensitivity` alongside it
is rejected rather than ignored. `divisions` is orthogonal to
`gridBeats`/`strength`/`swing`/`groove`: it picks where the clip is CUT, they
pick where each slice MOVES TO. So `divisions: 4, strength: 1` chops into
quarters AND snaps them.

With `strength` above 0 the same call becomes an actual quantize — slices move
toward the grid, gaps filled by the source continuing at natural speed with
short equal-power crossfades. Returns `{clips}` — the head + slice clips that
replaced the original. **Destructive, but one undo step reverts it.**

### Which one?

| You want to... | Call |
|---|---|
| Play the record from a keyboard / write a new pattern from its pieces | `clip_slice_to_sampler` |
| Drag the record's own pieces into a different order on the timeline | `clip_quantize_audio {strength: 0}` |
| Tighten a sloppy live break to the grid | `clip_quantize_audio {strength: 1, gridBeats}` |
| Chop a drone or an ambient bed that has no transients | either, with `divisions: N` |

### ⛔⛔ BEFORE YOU WRITE A LONGER PATTERN: THE RECONSTRUCTION CLIP IS SOURCE-LENGTH

**This is the single most expensive trap in the whole workflow, measured twice.**

The MIDI clip `clip_slice_to_sampler` writes is exactly as long as the source
recording — a 5.7 s break at 90 BPM gives you a clip about **8.5 beats** long.
The moment you rewrite it into a 16-bar arrangement with `clip_set_notes`,
**every note past the clip's end is accepted, stored, reported back to you, and
never sounds.**

⚠️ **There is NO warning. The call returns success with your full note list.**
Measured 2026-08-29: 152 notes spanning 63.6 beats written onto an 8.5-beat clip
→ `warnings: []`, all 152 notes echoed back, and **87 % of the arrangement
silent.** A separate probe: one note at beat 20 on a 4-beat clip — accepted,
clip still 4 beats. Rendering the first bars measures fine, which is exactly why
this survives a spot check.

✅ **THE CURE, and it takes both ids:**

```
clip_fit_to_content {trackId, clipId}
```

It grows the clip to cover its notes — verified 4 → 21 beats on the probe above.
⚠️ **`trackId` is REQUIRED even though `clipId` is unique**; omitting it returns
`missing or invalid required param 'trackId'`.

**Call it after EVERY `clip_set_notes` that extends the pattern**, not once at
the end — and if a render is quieter or emptier than the arrangement you wrote,
suspect this before you suspect the sampler. (Its one cost: it echoes every note
back, and that cannot be suppressed.)

## 4. Play it — the keymap is already varispeed

⭐⭐ **You do not need a time-stretcher, and you should not want one here.** The
sampler's read rate is `2^((pitch - rootPitch)/12)` source frames per output
frame. That is the *read rate*, so **a chop played a fifth up reads the buffer
faster AND higher** — it gets shorter and brighter together. That is not a
limitation; it is exactly MPC / SP-1200 / Recycle repitch semantics, and it is
the sound of the genre.

Practical consequences:

- **Play a pad chromatically to repitch it.** Pad 1 sits at `baseNote`
  (default 36). Widen one pad's `maxPitch` (step 7) and it answers a whole
  range — this is the classic "16 Levels" move, one chop spread across the
  keyboard.
- **Transpose the whole reconstruction** by shifting every note in the MIDI
  clip: the flip speeds up and pitches up together, like a record played fast.
- **`tuneCents` fine-tunes on the same rate** — cents of detune per zone, for
  nudging one chop into tune with the new key from step 1 without moving it to
  a different pad.
- **A pad played far up runs out of material fast** (it reads to `endFrame`
  sooner). Far down, it runs long and dull. Both are the instrument, not a bug.

## 5. Tighten it — choke

Overlapping chop tails ringing into each other is what makes a re-chop sound
like the original loose loop instead of a new beat. Two levels:

**Global choke (the classic):**
```
instrument_set_sampler_param {trackId, param: "voiceMode", value: "mono"}
```
Every new note cuts the previous one. This IS the classic chopped-soul
behaviour and it is often all you want. (`"poly"` restores polyphony.)

**Per-zone choke groups (`chokeGroup`, 0..63):** playing any zone in a group
ENDS whatever is already sounding from that group, while everything else stays
polyphonic. Give every hat zone `chokeGroup: 1` and the closed hat cuts the
open one **while kicks and snares in the same instrument stay fully
polyphonic** — which global mono cannot do.

⚠️ **`chokeGroup` is NOT the same field as `group`.** `group` decides WHICH
zone fires on a new note (round-robin and alternate layers are built on it);
`chokeGroup` ends notes that are ALREADY PLAYING. A zone can use both,
independently. Reusing `group` as a choke group silently breaks round-robin.

⚠️ **A choked note is not cut dead** — it goes into its own `release`, so a
zone with a long release chokes slowly. Shorten that zone's `release` for a
tight choke. Zones layered by the SAME note-on never choke each other, and a
note never chokes itself.

## 6. Reshape it — reverse and crush

**`reverse` (per zone, boolean).** The note starts at the last frame of the
zone's span and reads toward `startFrame`, at the same repitched speed a
forward note would use — the classic reversed-cymbal / reversed-vocal swell.
It costs no extra memory; the audio is read backwards in place, never copied.

⚠️ **Reversed zones IGNORE LOOPS in this version.** A zone with both `reverse`
and `loopMode` plays its span once, backwards, and the loop is dropped (with a
note in the sampler's zone-load notes). Backwards-loop behaviour is
deliberately not guessed at. `attack`/`release` are NOT swapped — they shape
what you HEAR, so a short release still trims the tail of the reversed sound.

**`bitCrusher` (an insert effect, not a zone field).**

```
fx_add {trackId, kind: "bitCrusher"}
fx_set_param {trackId, effectId, name: "bits", value: 12}
```

Bit-depth + sample-rate reduction — the lo-fi character of a 1980s sampling
drum machine. Params: `bits` (1..16, whole numbers), `downsampleHz`
(1000..48000), `antiAlias`, `dither` (**both are 0 or 1 NUMBERS**, not
booleans — every `fx_set_param` value is a number), and `mix`. `fx_add`'s
`params` object seeds them in one call, also as numbers.

⭐⭐ **ITS DEFAULTS ARE THE POINT AND YOU SHOULD USUALLY LEAVE THEM: 12 bits at
26040 Hz is the E-mu SP-1200, and `antiAlias: 0` / `dither: 0` are DELIBERATE.**
The SP-1200's signature comes specifically from its converter OMITTING the
reconstruction filter, so content above the reduced Nyquist images back down as
audible grit. **The aliasing IS the character.** A politely filtered, dithered
bit-crusher sounds clean-but-crunchy instead of gritty and does not hit that
reference. Turn `antiAlias: 1` on only when a user asks for a tamer, modern
crush, and `dither: 1` only when reducing depth for DELIVERY rather than for
character.

`downsampleHz: 40000` is the Akai MPC60, which is why MPC60 chops read as
cleaner. `mix: 0` is a bit-exact bypass. Reach for it on a chopped sample or
on a whole drum bus.

## 7. Tweak ONE pad without resending all of them

⚠️⚠️ **`zonePatches` is NOT a verb, and you cannot reach it through
`track_set_instrument` either.** Both halves of that sentence have cost a real
debugging loop. The facts:

- **The tool is `instrument_set_sampler_zones`.** Each entry in its `zones`
  array names an existing zone by `id` and patches only the fields it mentions.
  Every other field on that zone, and every zone not named at all, is left
  exactly as it was — including fields left nil.
  ```
  instrument_set_sampler_zones {trackId, zones: [
    {id: "<zone id>", reverse: true, chokeGroup: 1, tuneCents: -1200}
  ]}
  ```
- **`sampler.zonePatches` is a RAW-WIRE field**, one layer below MCP. It is
  what `instrument_set_sampler_zones` forwards to. Sending it yourself as
  `track_set_instrument {sampler: {zonePatches: [...]}}` is **REJECTED at the
  MCP schema** — that schema is strict and deliberately does not expose the key.
  (It used to strip it silently and report success having changed nothing,
  which is why the rejection exists.)
- **A present `zones` array on `track_set_instrument` replaces the WHOLE map
  wholesale** and re-mints every zone id, so a partial list deletes the pads you
  left out. Ids you captured before that call are dead afterward. `zones: []`
  is the deliberate clear. Use it when you mean the complete map — for example
  copying a pad map onto another track — and never to change one pad.

**Capture ids first:** `instrument_describe_sampler {trackId, offset, limit}`
is the purpose-built read — zone count, each zone's ranges and per-zone fields
WITH its `id`, and `effectiveGlobals` — without the ~290 KB `project_snapshot`
cost. Ids are per-track; an id from a different track is a readable error and
nothing lands.

⚠️ **`offset` and `limit` are not optional in practice: omit them and you get
NO zone array at all** — just the count and globals, with nothing in the
response marking the omission. Measured 2026-08-29. Pass them explicitly
(`{trackId, offset: 0, limit: 128}`) whenever you actually want the ids, which
is the entire reason to call this tool. An empty-looking read here is a missing
parameter, not a track without zones.

## 8. Resample — close the loop

**This is central to the craft, not an optional extra.** Sampling your own
output is how a flip gains depth: you commit a chop, print it, and chop the
print. Each pass bakes in the pads, the choke, the crush and the mix, and hands
you material that no longer has the source's structure.

```
render_bounce {path, fromBeat, durationSeconds}     -> delegate to finisher
clip_add_audio {trackId, path, atBeat}              -> composer imports it back
```

⛔ **`clip_add_audio` REFUSES to land on top of a clip that is already there.**
It names the resident clip and gives you a beat you can safely append at;
nothing is deleted, trimmed, or changed. That refusal is aimed squarely at this
loop: importing print after print onto one track is the workflow, and the
obvious form of it — reuse `atBeat: 0` every pass — used to destroy the previous
import silently (measured 2026-08-29: two imports at `atBeat: 0` left **one**
clip and killed the first id; fixed in m33-j).

**The cheapest way to stay out of its way is to OMIT `atBeat`** — that appends
after everything on the track and can never collide. Otherwise import each print
to its own track, or pass a beat past the last clip's end.

If you genuinely mean to replace what is there, pass `overwrite: true`. It does
the old thing — trims the clips underneath, deletes the ones this file covers
completely — but it is no longer silent: `trimmedClipIDs` and `removedClipIDs`
come back in the response naming exactly what went. Those two arrays are in
EVERY `clip_add_audio` response and are empty on the ordinary path.

```
```

`render_bounce` renders offline to a stereo 48 kHz WAV and reports loudness;
`excludeTrackIds` prints everything EXCEPT the named tracks, and `render_stems`
gives per-track prints when you want to resample one element alone. Then
`clip_add_audio` takes that arbitrary path onto an audio track (length is
computed from the file's duration at the current tempo), and the new clip is a
perfectly ordinary chop candidate — feed it straight back into step 1.

⚠️ **The default render window comes from CLIP extents alone (plus a fixed
2.0 s tail), never from automation** — a tail extending past the last clip is
CUT OFF unless you pass a `durationSeconds` that covers it. For a resample you
usually want the exact bars, so pass `fromBeat` and `durationSeconds`
explicitly.

⚠️ **Omit `lufsTarget` when resampling.** You want the material, not a
normalized master; normalization applies a static gain that will fight the next
pass.

## 9. Units — beats vs seconds vs frames

The single most common agent mistake on this surface. **Three coordinate
systems are live at once, and the chop is where they meet.**

| Unit | What it measures | Which calls take/return it |
|---|---|---|
| **Beats** (quarter notes) | Position on the TIMELINE, tempo-dependent | `atBeat`, `startBeat`, `fromBeat`, `lengthBeats`, `gridBeats`; `clip_detect_transients`' returned `beat`; `clip_split`, `clip_move`, `clip_add_midi`, `clip_add_audio` |
| **Seconds** | Position inside the SOURCE FILE (or wall clock) | `clip_detect_transients`' returned `sourceSeconds`; `minSliceSeconds`; `render_bounce`'s `durationSeconds`; `attack`/`release` |
| **Milliseconds** | Small windows | `snapWindowMs`, `crossfadeMs` |
| **Frames** (at the FILE's own sample rate) | Exact sample offsets into the source file | `SamplerZone.startFrame`/`endFrame`; `clip_slice_to_sampler`'s returned `startFrame`/`endFrame`/`snapOffsetFrames` |
| **Hz** | Sample rates and corners | `downsampleHz`; the returned `sampleRate` |
| **Cents** | 1/100 semitone | `tuneCents` (−1200 = one octave down) |

⚠️⚠️ **FRAMES ARE NOT PORTABLE ACROSS FILES.** A frame number only means
something paired with the sample rate it was measured in. That is why
`clip_slice_to_sampler` returns `sampleRate` and `frameCount` alongside every
frame number — **they are the SOURCE FILE's own**, not the project's, not
48000. A 48 kHz rip chopped against a hardcoded 44100 lands every chop 8.8 %
off, and it would still sound like music. **Never compute a frame number
yourself from seconds.** Let the tool do the conversion; it is the only place
that knows the file's rate.

⚠️ **`sourceSeconds` and `beat` are the same onset in two coordinate systems.**
Trimming or moving the clip changes `beat` and never changes `sourceSeconds`.
Feed `beat` to timeline verbs and `sourceSeconds` to anything reasoning about
the file itself.

## What is NOT here (say so rather than working around it blindly)

- **No per-zone filter.** Deliberately deferred — the per-voice one-pole plus
  the track/master insert chain (an `eq` in front of the crusher, say) covers
  most of what a per-zone filter would do. If you genuinely need per-chop
  tone-shaping, split the pads across two sampler tracks and filter each track.
- **No per-slice elastic time-stretch.** A deliberate cut, not an oversight:
  repitch (step 4) is the authentic behaviour for this workflow, and the engine
  is built around a full-source stretch cache that forbids N per-span renders.
  `clip_slice_to_sampler` REFUSES a time-stretched clip outright — bounce it
  first if you truly need stretched material.
- **No zero-crossing snap on the timeline chop.** Not needed: 3b is click-free
  by construction. The zone chop has its own snapper.
- **Reversed zones ignore loops** (see step 6).
- ⭐⭐ **NO AGENT IN THIS PLUGIN CAN HEAR ANYTHING.** Every timbre and groove
  judgement here is inference from numbers. **Your ears are:**
  `render_measure_loudness` / `audio_profile_file` for level,
  `clip_detect_transients`' `count` for whether a chop actually produced hits,
  `clip_analyze_audio`'s `spectral.centroidHz` for brightness, and
  `residualAmplitude` per slice for whether a cut is likely to click. Say so in
  your wrap-up and invite the user to listen. That is not a caveat — it is the
  honest state of the run.

  ⚠️ **Those two level tools measure DIFFERENT OBJECTS — they are not
  interchangeable, and the pairing above is the one place this document is
  misleading if you read it quickly:**

  | Tool | What it actually measures | Needs |
  |---|---|---|
  | `render_measure_loudness` | **the PROJECT**, re-rendered live. It cannot read a file — pointing it at a path you just bounced does not measure that path. | `fromBeat` (beats) + `durationSeconds` (SECONDS) |
  | `audio_profile_file` | **a FILE on disk**, in per-window RMS/peak. This is the only one that can verify what you actually wrote. | a path **and `windowSeconds`, which is REQUIRED** and documented nowhere else |

  Two more measured gotchas. `render_mixdown` returns **no** loudness figures
  while `render_bounce` does — so bounce, or measure separately. And
  `audio_profile_file` **omits `rmsDb`/`peakDb` entirely for a digitally silent
  window** rather than reporting silence, on the one tool whose job is finding
  silence: a defaulting read like `.get("rmsDb", 0)` will report **0 dB — full
  scale — for a silent window.** Treat a *missing* field as silence, never a
  zero.
- **The master chain is addressed by the magic string `trackId: "master"`.**
  It appears in no parameter list. `fx_add {trackId: "master", kind: "limiter"}`
  is how the crush/limit goes on the whole mix; `fx_reorder` takes `index`, not
  `toIndex`; the limiter's `truePeak` defaults **off**; and the resulting chain
  is readable only through `project_snapshot`'s `masterEffects`, which
  `project_overview` does not carry.

⭐⭐ **KNOW WHERE YOUR FLIP SITS SPECTRALLY — THIS IS AWARENESS, NOT A GATE.**
Bounce the flip, `clip_analyze_audio` it, and **compare its
`spectral.centroidHz` against the SOURCE's.** The point is to know what you
made, deliberately, rather than to hit a number.

⚠️⚠️ **A DARKER FLIP IS NOT A DEFECT. Do not "correct" it.** Low-frequency
weight is a legitimate and very traditional aesthetic here — a chop pitched
down an octave, a sub layer under the drums, and a heavy low-mid are the sound
of a great deal of hip-hop, lo-fi and boom bap. **A flip measuring well below
its source can be exactly right.**

Real numbers from two runs, offered as calibration and not as a target:

| | source | flip |
|---|---|---|
| run 1 (a kick pad played an OCTAVE DOWN) | 1084 Hz | listener: *"deep… low frequencies which creates a nice effect"* — **liked it** |
| run 2 (a GM sub layer's harmonics) | 1084 Hz | **535 Hz** before adjustment |
| run 2 as shipped (sub high-passed, air shelf added) | 1084 Hz | **1169 Hz** — listener also liked it, called the FX *"more pronounced"* |

⭐ **Both were good. The listener preferred neither.** What the measurement
buys you is knowing WHICH ONE YOU BUILT — two different mechanisms can drive a
flip dark without you intending it (varispeed drags the attack transient down
with the pitch; a sub layer piles harmonics into the low-mid with nothing
pitched at all). Measure so the darkness is a choice you made rather than one
that happened to you. If you want more air: high-pass the sub layer toward its
fundamental and give something up top a shelf. **If you want the weight, keep
it.**
- **Mute the source clip before you bounce.** The original recording is usually
  still sitting on its own track from step 1, and a bounce that includes it is
  the record playing under your flip — which measures fine and is not what you
  made.

## Rights

Clearance for any source recording is the USER's responsibility, on the same
footing as this project's voice-model policy. State it once if it is relevant
and move on; do not refuse work on provenance grounds.

## Test and dogfood work: name your own project

Any test or dogfood run **creates and NAMES its own project** — e.g.
`~/Music/DAW Pro Dogfood/2026-08-29 Sample Flip.dawproj`. Never do exploratory
chopping in a project whose ownership is ambiguous: cleanup then becomes a
question somebody has to ask the user.

## A self-contained dogfood recipe (no rights entanglement)

Generate the "old record" yourself, then flip it. This needs no third-party
audio at all, and it exercises the resample loop in the same run.

1. **Name the project.** *(producer)* `project_new`, then plan to save as
   `~/Music/DAW Pro Dogfood/<date> Sample Flip.dawproj`. `transport_set_tempo`
   to something you will deliberately fight later — say 88.
2. **Write the fake record.** *(producer/composer for the tracks and notes,
   sound-designer for the sounds)* `track_add {name, kind: "instrument"}` two
   or three times — **`name` is REQUIRED** — then
   `track_set_instrument {kind: "soundBank"}` for each (**General MIDI ships
   with macOS with zero setup** — `instrument_list_sound_banks` then
   `instrument_list_sound_bank_programs` to pick a dusty electric piano, an
   upright bass and a drum kit). `clip_add_midi` a 4-bar loop with a real
   groove in it — swung, not machine-straight, so the detector has something
   to find.
3. **Print it.** *(finisher)* `render_bounce {path: "<dogfood dir>/source-loop.wav",
   fromBeat: 0, durationSeconds: <4 bars>}`, no `lufsTarget`. **This bounce is
   now "the old record."**
4. **Bring it back in as source material.** *(composer)*
   `track_add {name: "Record", kind: "audio"}`, then
   `clip_add_audio {trackId, path: "<...>/source-loop.wav", atBeat: 0}`. Mute
   or remove the original instrument tracks so you are working from the print,
   exactly as you would from a vinyl rip.
5. **Orient.** `clip_analyze_audio` on the new clip. Compare its detected `bpm`
   and key against what you actually wrote — a useful sanity check on the
   analyzer, and the same reconciliation a real flip needs.
6. **Chop.** `clip_detect_transients` to see the onset count, then
   `clip_slice_to_sampler {clipId, mode: "transients"}`. Capture
   `createdTrackId`, `midiClipId`, `sliceCount`, `headSeconds` and the
   `slices` array. **Check `warnings` and `headSeconds` before going on.**
7. **A/B the reconstruction.** *(mix-engineer or finisher holds the meter)*
   Play the source clip and the generated MIDI against each other. They should
   be indistinguishable — that is the property the whole workflow rests on.
   `render_measure_loudness` over the same window with each muted in turn is
   the measurement that stands in for listening.
8. **Now actually flip it.** *(composer; tempo is producer/arranger)* Rewrite
   the MIDI clip (`clip_get_notes` → reorder/drop/repeat → `clip_set_notes`)
   into a pattern the record never played: move the pads onto a different grid,
   repeat one chop as a stutter, transpose a pad up a fourth so it reads faster
   and brighter. **Change the project tempo** so the chops fight the grid.
9. **Shape it.** *(sound-designer)* `instrument_set_sampler_param
   {param: "voiceMode", value: "mono"}` for the classic choke, or `chokeGroup`
   per pad if you want the kick to ring through. `instrument_set_sampler_zones`
   to `reverse` one pad for a swell into a section.
   `fx_add {kind: "bitCrusher"}` on the chop track at defaults.
10. **Resample.** *(finisher renders, composer imports)* `render_bounce` the
    flip, `clip_add_audio` it back, and chop THAT — one pass is enough to prove
    the loop closes.
11. **Measure and report.** `render_measure_loudness` for a non-floor level
    (a silent render is the failure this gate exists to catch),
    `clip_detect_transients` `count` on the final bounce for whether the beat
    actually has hits in it. Report both numbers, the file paths, and say
    plainly that nobody in the run heard any of it.

⚠️ **This needs a RUNNING DAW Pro on the staging control port.** Do not launch
the app as part of this skill — if no app is reachable, `app_connection_info`
will say so; report that and let the orchestrator decide.

## Wrap up

Report the source, the chop (mode, slice count, base note, discarded head),
what you changed about it, the effects added, every rendered file path, and the
measured loudness. Do **not** call `project_save` unless the user asks —
mention that the work is unsaved and offer to save it.
