---
name: meme-song
description: Turn a spoken or sung phrase into a rhythmic "Kiffness-style" meme song — chop the voice into fragments, pitch them into a melody, and build an arrangement around them. Relative semitone offsets are the default and need no pitch detection; clip.detectPitch (shipped) is for matching a backing track's key or recovering the speaker's own melody.
---

# Meme song (Kiffness mode)

Take a phrase somebody said — a celebrity soundbite, a friend's voice note, your own
recording — and build a song out of **that voice as the instrument**. The vocal is not
sung over a backing; the vocal *is* the melody, pitched into notes and played rhythmically.

This is the workflow The Kiffness uses. It is filed as roadmap item **m23-de**.

⭐ **The whole thing is drivable today.** Every primitive ships. The one missing piece —
automatic pitch *detection* — turns out not to be required for the creative move, for the
reason in §3. Read that section before deciding you're blocked.

---

## 0. Before you start

- **The app must be running** and reachable on the control port. Default `17600`.
  ⛔ If you are an autonomous agent inside this repo, **17600 is the user's live app** —
  drive it only when the user has asked you to make something. Never bind or kill it.
- **Source audio**: any file with a clear voice. Mono or stereo, any rate.
- **Rights are the user's call.** DAW Pro does not gate whose voice you sample
  (user ruling, 2026-07-27). Provenance is theirs, not the app's.

**Sanity check the surface before a long run** — one call, and it fails loudly if the app
is not where you think:

```
project_overview
```

---

## 1. The ordering law — read this or you will hit a wall

Three commands refuse to run on a modified clip. They are *not* interchangeable in order,
and the failures are late and confusing if you get it wrong.

| Step | Requires | Enforced by |
|---|---|---|
| `clip_transcribe` | `stretchRatio == 1` | `transcriptionRequiresUnstretchedClip` |
| `clip_quantize_audio` | `stretchRatio == 1` **AND** `pitchShiftSemitones == 0` | `audioQuantizeStretchUnsupported` |
| `clip_analyze_audio` | nothing — but reports the **source** domain, not playback | adds a `playback` block once shifted |

⚠️⚠️ **`clip_quantize_audio` rejects a PITCH-SHIFTED clip, not just a time-stretched one.**
The guard is `isStretchIdentity`, which is `stretchRatio == 1 && pitchShiftSemitones == 0`.
So **all rhythmic tightening happens BEFORE any pitching.** Pitch is the last thing you do
to a fragment.

**The correct order, therefore:**

```
import → analyze → transcribe → detect transients → split → quantize → THEN pitch/stretch
```

Get this backwards and you will split a beautifully pitched melody into fragments that
`clip_quantize_audio` refuses to touch, with no obvious way back except undo.

---

## 2. Chop the phrase into fragments

### 2a. Import and look at it

```
clip_add_audio        { trackId, path, atBeat }
clip_analyze_audio    { clipId }
```

⚠️ **`atBeat`, not `startBeat`.** This project's clip-creating verbs consistently take
`atBeat` and reject `startBeat` — `clip_add_midi` rejects it outright. Guessing this
parameter name is the single most common way to fail on the first call.

`clip_analyze_audio` returns `key {tonic, mode, confidence, tonal, alternatives}`,
`tempo {bpm, confidence, steady, alternates}` and a 24-band spectral balance.

⚠️ **On pure speech, expect `tonal: false`.** That is the honest answer, not a failure —
speech has no stable tonic. A *sung* phrase will usually give you a real key. Do not trust
`tonic`/`mode` when `tonal` is false, even though a ranked guess still comes back.
⚠️ `bpm` is `null` for windows under 6 seconds. Also honest, also not a failure.

### 2b. Find the cut points — two instruments, use both

```
clip_transcribe        { clipId }          → words + segments, placed on beats
clip_detect_transients { clipId, sensitivity }  → {sourceSeconds, beat, strength}
```

**`clip_transcribe` gives WORD-level timings**, not just segments — check
`wordTimestampSupport` (`"supported"` / `"unsupported"` / `"unknown"`) first, because a
Whisper variant whose decoder declares no alignment tensor returns segments with every
`words` array empty. That field is there so you check rather than discover it.

**Use words for meaning, transients for precision.** Words tell you *"the funny bit is the
third word"*; transients tell you *exactly* where its attack is. A cut placed on the
transient sounds tight; a cut placed on the transcript's word boundary often clips the
consonant. Raise `sensitivity` toward 1 for legato or quiet speech.

### 2c. Cut

```
clip_split { trackId, clipId, atBeat }
```

Splits at a **timeline beat** — and `clip_detect_transients` already returns its `beat`
field in that same timeline space (`sourceSeconds` is the file-relative one), so you can
pass it straight through. ⚠️ `atBeat` must fall **strictly inside** the clip's span; a split
exactly on either edge is rejected. Split
repeatedly to isolate each syllable you want to play. Keep the fragments you want; delete
the rest with `clip_remove` / `clip_remove_many`.

⭐ **Pick 1–3 fragments, not twenty.** The Kiffness trick is repetition of one hook, not a
collage. One syllable pitched across a scale carries a whole song.

### 2d. Tighten the rhythm — while it is still unpitched

```
clip_quantize_audio { trackId, clipId, gridBeats, strength, swing, groove, crossfadeMs }
```

`gridBeats`: 1 = ¼ note, 0.5 = ⅛, 0.25 = 1/16. `strength` 0..1 (1 = snap hard,
0.5 = keep some feel). `swing` 50–75 for MPC-style shuffle, or pass a `groove` template
name instead. Needs at least 2 detectable onsets.

---

## 3. Pitch the fragments into a melody

⭐⭐⭐ **THE KEY INSIGHT, AND IT SURVIVES THE DETECTOR SHIPPING: a melody is a set of
RELATIVE intervals, so the offsets below work on ANY fragment without knowing its pitch.**
Start here. It is fewer calls, it cannot be wrong, and it is what makes a meme song sound
like a meme song rather than a transcription.

### When to reach for `clip.detectPitch` (m23-ap-3, SHIPS)

Detection is now available and it buys exactly **two** things — neither of them the melody:

| Use detection when | Why relative offsets don't cover it |
|---|---|
| The vocal must sit **in the key of a backing track** | Offsets are relative to the *source*; matching an external key needs the source's absolute pitch |
| You want the **natural melody the speaker already spoke** | Speech has real pitch movement; detection recovers it instead of imposing a scale |

```
clip_detect_pitch { clipId, fromSeconds?, durationSeconds?, confidenceThreshold? }
  → { pitch: { frames: [{ timeSeconds, frequencyHz?, confidence, levelDbfs?, absence? }] } }
```

⚠️ **Frames are NESTED under `pitch` — `result.pitch.frames`, not `result.frames`.** This
cost a debugging round when the verb shipped; a wrong path yields an empty array, and an
empty array makes every downstream check pass VACUOUSLY.

⚠️⚠️ **`frequencyHz` IS ABSENT on unvoiced frames — the key is missing, not zero.** Read it
as `if (f.frequencyHz != null)`. `absence` says which kind of nothing: `belowLevel` (too
quiet), `belowConfidence` (present but unclear), `outOfRange`. **Never coerce a missing
pitch to 0 — it becomes a real note the moment anything reads it.** Frames are never
dropped, so gaps are visible: that is how you tell two notes from one long one.

To convert a frame to a semitone offset against a target:
`semitones = 12 * log2(targetHz / frameHz)`. Take a **median over the voiced frames of a
fragment**, never a single frame — one frame is noise, and a speech syllable glides.

⚠️ Accuracy is ~0.5 cents median on harmonic material, **zero octave errors measured** —
but every number so far is from synthetic tones. No real voice has been through it. Trust
it for key-matching; listen before promising anything finer.

### The relative-offset path — still the default

To make a fragment play a tune you shift it by semitone offsets *relative to itself*. You
never need to know what pitch the source actually is:

```
offsets [0, +2, +4, +5, +7, +9, +11, +12]  →  a major scale, whatever the source pitch was
offsets [0, +3, +5, +7, +10, +12]          →  minor pentatonic — the safe meme default
offsets [0, +2, +4, +7, +9]                →  major pentatonic — happy, nothing can clash
```

Apply one duplicate per note:

```
clip_duplicate   { clipId, toStartBeat, toTrackId }
clip_set_stretch { trackId, clipId, ratio, semitones, formantPreserve }
```

⚠️⚠️ **`clip_duplicate` does NOT take `atBeat` or `trackId` — it takes `toStartBeat` and
(optionally) `toTrackId`.** It is the only verb in this workflow that names its destination
that way, and it is the one you call once per note, so getting it wrong fails the whole
melody loop. The helper's `beat` field maps to **`toStartBeat`**.

- `semitones` is **−24..24 and independent of `ratio`** — pitch without changing length.
- `ratio` is 0.25..4 — length without changing pitch. Use it to make every note the same
  duration regardless of how long the original syllable was.
- ⭐ **`formantPreserve: true` is the difference between "a voice singing" and
  "a chipmunk".** Turn it on for anything shifted more than ~3 semitones up. Backed by
  Signalsmith Stretch, so it holds up well.

### What you DO need pitch for

Only one thing: **making the backing agree with the voice's key.** Three ways today,
in order of cost:

1. **Transpose the voice, not the backing.** Add the *same* constant to every fragment's
   `semitones`. The melody is unchanged — you have just moved the whole vocal into
   whatever key you wrote the backing in. This is the cheapest and it always works.
2. **Ask `clip_analyze_audio`** for the key. Reliable on sung phrases, unreliable on
   speech (`tonal: false` — believe it).
3. **Iterate by ear.** Render a short loop, listen, nudge the constant. This is what a
   human producer actually does.

⭐ When `clip.detectPitch` lands, step 2 becomes exact and this section collapses to one
call. Nothing else in this skill changes.

---

## 4. Build the song around it

The voice is now an instrument. Everything from here is ordinary arranging.

**Scaffold fast:**

```
macro_song_skeleton { genre, ... }   → tempo, named tracks with mixer presets,
                                        sections as named clips, loop set — one undo step
```

**Add parts that fit what you already have:**

```
lego_generate { ... }        → ACE-Step writes a bass line / pad that fits the source audio
track_set_instrument { ... } → GM sound banks (⚠️ prefer these; a third-party AUv2 can
                               wedge the main actor for minutes — see the AU hosting note)
clip_add_midi { trackId, atBeat, ... }   ⚠️ takes `atBeat`, and REJECTS `startBeat`
```

**Make it groove like the voice:**

```
groove_extract { clipId, ... }   → capture the timing feel of the ORIGINAL phrase
clip_quantize  { ..., groove }   → apply that feel to the drums and bass
clip_humanize  { ... }           → loosen anything that got too rigid
```

⭐⭐ **`groove_extract` on the original speech is the move that makes this sound
intentional.** Human speech has a natural swing; imposing it on the drums makes the
backing feel like it was written for the phrase rather than under it.

**Optional — change whose voice it is:**

```
vc_convert_vocals { clipId | path, voiceId, pitchSemitones }
```

Voice conversion works and ships. ⛔ **One pass only** — repeated conversion degrades to
saturation (measured: peak pinned at 0.99 by the 5th call). It is not upscaling.

**Finish:**

```
fx_add / mixer_apply_preset / fx_set_sidechain   → duck the music under the voice
render_measure_loudness                          → check before you export
render_mixdown { path, ... }
```

---

## 5. A worked skeleton

```
1.  project_new                             → clean slate
2.  track_add (audio)  + clip_add_audio     → the phrase
3.  clip_analyze_audio                      → key? tempo? tonal?
4.  transport_set_tempo                     → pick the song tempo now, before splitting
5.  clip_transcribe                         → which word is the hook?
6.  clip_detect_transients                  → exactly where does it start?
7.  clip_split ×N → clip_remove_many        → keep 1–3 fragments
8.  clip_quantize_audio                     → tighten (MUST be before step 10)
9.  groove_extract                          → capture the speech's feel
10. clip_duplicate ×N + clip_set_stretch    → the melody, via semitone offsets
11. macro_song_skeleton / lego_generate     → drums, bass, chords
12. clip_quantize {groove} + clip_humanize  → make the band swing like the voice
13. fx_add + fx_set_sidechain               → mix
14. render_measure_loudness + render_mixdown
```

Use `scripts/meme/melody-offsets.mjs` to turn a tune into the offsets for step 10.

---

## 6. Failure modes worth knowing

| Symptom | Cause | Fix |
|---|---|---|
| `clip_quantize_audio` rejects the clip | it is pitched or stretched | quantize **before** pitching; or undo the stretch |
| `clip_transcribe` rejects the clip | `stretchRatio != 1` | transcribe first, on the untouched import |
| Every `words` array is empty | the Whisper variant has no alignment tensor | check `wordTimestampSupport`; install a variant that supports it |
| Pitched-up voice sounds like a chipmunk | `formantPreserve: false` | set it true |
| `tonic`/`mode` look wrong | `tonal: false` — it is speech | don't use the key; transpose the voice instead (§3) |
| `bpm` is `null` | window under 6 s, or no periodic pulse | set the tempo yourself; it is not a failed call |
| Quantize says "fewer than 2 onsets" | quiet or sustained material | raise `sensitivity`, or pick a more percussive fragment |
| Fragment plays at the wrong speed after pitching | you changed `ratio` when you meant `semitones` | they are independent — re-set `ratio: 1` |
| `clip_duplicate` rejects your params | you passed `atBeat` / `trackId` | it takes `toStartBeat` and `toTrackId` |
| `clip_add_audio` rejects your params | you passed `startBeat` | it takes `atBeat` |
| `clip_split` rejected the beat | it landed on a clip edge, not inside it | `atBeat` must be strictly inside `[startBeat, startBeat + lengthBeats]` |

---

## 7. Routing

- Chopping/arranging logic and new app behaviour → `swift-app-engineer`
- Anything touching stretch/pitch DSP quality → `audio-dsp-engineer`
- New wire commands or MCP tools this workflow wants → `mcp-integration-engineer`
- ⚠️ **§7.6 of the pitch design is absolute: pitch DSP never reaches the render thread.**

## 8. Status

**Ships today:** transcribe (word-level), transient detection, split, audio quantize,
groove extract/apply, stretch **and pitch-shift with formant preservation**, key/tempo
analysis, stems, voice conversion, the full arrangement + mix + render surface.

**Not yet:** `clip.detectPitch` — automatic note-level pitch detection
(roadmap `m23-ap-2b` builds it, `m23-ap-3` exposes it). It improves §3 step 2 and is the
foundation of Melodyne-style tuning (`m25-h`), but this workflow does not wait for it.

⚠️ **One honest gap: nobody has yet listened to a syllable pitched across two octaves in
this app.** The path is wired and the library is good, but that is a wiring measurement,
not a listening one. Listen before promising quality — this project has been burned by
exactly that distinction before (m10-p-6).
