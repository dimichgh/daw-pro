---
name: new-song
description: Build a full song in DAW Pro end to end from a brief — plan structure, scaffold tracks/instruments, write parts per section, mix, verify loudness, and stop short of saving. Use when the user asks to write/make/generate a new song, or to start a project from a genre/mood/theme brief.
---

# /new-song — write a song end to end

This skill orchestrates the DAW Pro Music Team agents (see each agent's own
file under `agents/` in this plugin, and the shared
`daw-wire-reference` skill for the wire-level rules they all follow) through
a full song build. Delegate each step with the Task tool to the named agent
— don't do the specialist work yourself in the main thread.

## 0. Sanity check

Before anything else, run the `daw-status` skill (or at minimum call
`app_connection_info` yourself) to confirm DAW Pro is reachable. If it
isn't, stop and tell the user to launch the app (or `swift run DAWApp` from
the repo) before continuing.

## 1. Plan (producer)

Delegate to **producer** with the user's brief. Producer should:
- Extract/confirm genre, mood, tempo feel, structure, length, and any
  lyrical theme.
- Call `macro_song_skeleton` to lay the foundation (tempo + genre track
  roster + section clips + section markers + loop). **Fourteen genres ship**
  — pop, house, hip-hop, rock, ballad, blues, jazz, country, r-and-b, funk,
  metal, folk, reggae, lo-fi — so check the list before settling for a
  near-neighbour. When the brief needs something none of them covers, pass
  your own `tracks` roster and/or `sections` (each overrides that genre
  default outright) rather than hand-building from nothing.
- **Reconcile the scaffold with the brief before reporting.** The genre
  roster is unconditional: almost every genre scaffolds a vocal AUDIO
  track (which can't host an instrument — dead weight on an instrumental
  brief), and the brief usually names instruments the template doesn't
  have. Producer holds `track_add`/`track_rename`/`track_remove` for
  exactly this.
- **Confirm the section map is real markers** (`marker_list`), not only
  guide clips, and add them if it isn't. Everything downstream is written
  against those beat ranges.
- If the brief has a lyrical theme, write lyrics now (`ai_write_lyrics`/
  `generate_lyrics`) so downstream agents know what the vocal/melody needs
  to serve.
- Report back the track roster (names + ids), the section layout (names +
  beat ranges), and the tempo, so later steps don't have to re-derive them.

Producer does **not** have a Task/Agent tool: it plans, scaffolds, and
reports. The delegation in steps 2-5 is yours to run from this session.

## 2. Parts per section (composer, then sound-designer)

For each instrument track, delegate to **composer** to write its MIDI
content section by section (or to kick off an AI `generate_song`/
`extract_stems` pass if the brief wants AI-generated material as a
starting point — poll to completion, `import_generation`/
`import_generated_stems` before moving on). Reference section beat ranges
from step 1's markers, not guesses.

Once a track has real content, delegate to **sound-designer** to pick its
instrument sound (or tune the sample/AU already loaded) and build a light
first-pass effect chain. Sound-designer works AFTER composer on each track
— there's no point tuning a sound before there's a performance to hear it
against.

### 2a. Solo wind and lead lines: say "slurred" in BOTH delegations

⭐⭐ **A sax, flute, or solo lead line needs one instruction split across two
agents, and either half alone does nothing.** This is the single most common
way a melodic line here comes out sounding typed-in rather than played:

- **composer** must write the notes **overlapping** — roughly 20-40 ms, about
  0.02-0.05 beats at typical tempos (author it directly, or run
  `clip_humanize` with `legatoOverlapBeats`) — **in short GROUPS, never right
  across the phrase. See the hard limit immediately below; it is not optional.**
- **sound-designer** must set the built-in sampler to
  `{sampler: {voiceMode: "legato", glideTime: 0.12}}`.

⛔⛔ **SLUR IN GROUPS OF 2-4 NOTES, THEN LEAVE A GAP. OVERLAPPING EVERY NOTE IN A
PHRASE IS A DEFECT, NOT MAXIMUM SMOOTHNESS** — and it is the mistake this
section previously invited. MEASURED 2026-09-01 on a real tenor-sax library:

- **Nobody plays it that way.** A wind player tongues most notes and breathes
  every couple of bars. A sixteen-note unbroken slur is not expressive, it is
  physically impossible.
- **The voice keeps ONE sample for the whole run.** A slurred voice does not
  change zone (`SamplerInstrument.swift:38`, a deliberate limit) — it varispeeds
  its original sample. Measured worst case: **13 semitones of stretch, 2.119×
  playback rate.** That shifts the formants up an octave, and shifted-up formants
  are heard as *a smaller instrument* — the user's word for the result was
  "трубочка", a little pipe.
- ⚠️ **AND THE SAMPLE RUNS OUT.** Zones are usually UNLOOPED. One run demanded
  **22.50 s from a 5.80 s sample**; past the end the engine frees the voice, and
  the next note re-triggers a fresh one. Measured cost is small — about **0.5 s
  of micro-gaps across a 43 s part** — so this is a reason to keep slurs short,
  not a catastrophe. (It is stated carefully because the first version of this
  note claimed the phrase went *silent*; soloed RMS measurement disproved that.)

**So: overlap by ~0.08 beats WITHIN a group of at most 3-4 notes; leave ~0.15-0.2
beats of clean gap between groups (that is the tongue); leave ~0.5 beats at a
phrase end (that is the breath).** Short groups also keep drift and sample burn
small enough that neither defect above can bite. Tracked as **m34-y**.

⭐ **A flat sustain reads as an ORGAN no matter how good the samples are.** Wind
instruments are loud and soft *within* a note. After the notes are right, run
`clip_apply_breath_contour` (CC11 dynamics + a delayed vibrato) — note velocity
alone cannot express it, because it is fixed at note-on and a real player is
still shaping the note after it starts.

**Overlap without `legato` is a CHORD, not a slur** — a `poly` sampler simply
opens a second voice. **`legato` without overlap has nothing to continue**, so
every note still re-attacks. Only the pair produces a slur, and neither agent
can see the other's half, which is why it is stated here rather than left to
them.

⛔⛔ **AND `mono` IS NOT A HALFWAY HOUSE — UNDER `mono` YOUR OVERLAPS DO NOTHING
AT ALL.** Mono chokes the sounding voice and triggers a NEW one on every
note-on, overlapped or not; only `.legato` continues a voice. So a part written
with careful slur overlaps and played on `mono` re-attacks **every single note**,
and the phrasing work is silently discarded. Cost when this was learned
(2026-09-01): a whole four-take listening ladder whose held variable defeated its
own axis, and the user reporting *"one can clearly hear start of note like it was
triggered by pressing key"* — correctly — about all four.

⛔⛔⛔ **A WIND INSTRUMENT IS MONOPHONIC. IF TWO VOICES EVER SOUND AT ONCE IT
STOPS BEING A WIND INSTRUMENT — CHECK THE RELEASE AGAINST THE NOTE SPACING
BEFORE ANYTHING ELSE.** One player has one air column; two simultaneous notes is
not a slur, it is a chord, and the ear hears an electronic pad. This is the
single highest-value check on any sax/flute/trumpet part.

⭐ **HOW IT WAS FOUND (2026-09-01), because the method generalises:** the user
said of one take *"10 and 11 seconds of sax is sax"* and theremin elsewhere.
Counting sounding voices against their own timestamps: **10.5 s and 11.0 s = ONE
voice; 16 s and 20 s = TWO.** Perfect correlation. **A defect that varies
moment-to-moment must come from something that varies moment-to-moment** — that
is what turns a vague "sounds wrong" into a measurement.

⛔ **THE SECOND VOICE IS USUALLY A TAIL, NOT A NOTE.** An imported library
routinely carries a **0.5 s release**. Solo lines run ~0.6 s per note, so every
note is still sounding when the next starts — as an extra voice under `poly`, and
as the choke ramp under `mono`. MEASURED on a 43 s part: a 0.5 s release leaves
**17.4 s — about 40 % of the solo — with two voices sounding.** At 100 ms it is
3.0 s; at 50 ms, 1.5 s.

**So, for any monophonic instrument:** use `mono` or `legato` (never `poly`); read
the ACTUAL release from `instrument_describe_sampler`'s **`effectiveGlobals`**
(the stored global is usually inert — every imported zone overrides it); and if
release approaches the note spacing, patch it down with
`zonePatches [{id, release}]`. ⚠️ **And do not write overlapping notes for a mono
part** — under `mono` an overlap buys only a choke; what joins notes is the
release.

⛔⛔ **A GAP SHORTER THAN THE RELEASE IS NOT SILENCE — IT IS AN AMPLITUDE STEP,
AND IT IS LOUDER THAN ANY ATTACK YOU COULD SOFTEN.** Check the release before
choosing a gap: at 92 BPM a 0.18-beat "tongued gap" is 117 ms against a **0.5 s**
release, so the departing note is still at ~40 % when the next one snaps back to
full sustain. **The seam you hear is that step, not the instrument's attack** —
which is why skipping the sample's recorded attack (`startFrame`) barely helped.
Either make the gap longer than the release, or do not leave a gap at all and let
the breath contour articulate with DYNAMICS instead of silence. The latter is
what a wind player actually does, and it is the project owner's own instruction:
*"It should sustain while breathing dynamic could be adjusted … to keep it
human."*

⭐ **`voiceMode: "legato"` + `glideTime: 0.12` is the project owner's own
choice, made by ear** (2026-08-31): they were played one sax phrase three ways
— `mono`, `legato`, and `legato` + glide — and picked the third. Start there on
a wind line rather than working up to it. ⚠️ **It is a starting point, not a
constant**: validated on a GM tenor sax at 100 BPM, so a faster line wants a
shorter glide.

⚠️ **Built-in `sampler` ONLY.** On `soundBank` or a hosted `audioUnit`, a
note-off carries no note id, so the voice cannot be continued — those paths can
only *mask* the re-attack under the previous note's tail. If the brief needs a
real slur, the lead must be on the built-in sampler. ⚠️ And `glideTime` is
**silently ignored under `poly`** — `instrument_describe_sampler` reports
`glideEffective`, so check it rather than assuming the setting took.

## 3. Structure pass (arranger)

Delegate to **arranger** to true up the arrangement once parts exist:
tighten transitions, crossfade audio joins, insert/delete bars if a section
needs to grow/shrink, and comp down any AI-generated alternate takes. This
is also the point to double-check the tempo/meter map still matches what
producer set in step 1.

## 4. Mix pass (mix-engineer)

Delegate to **mix-engineer** for levels, pans, buses/sends, sidechain, and
automation, then a master-chain pass (typically an `eq` then a `limiter`).
Ask for a `mixer_master_analysis`/`render_measure_loudness` read at the end
of this step so you know where the mix stands before finishing (mix-engineer
carries playback-only transport now, so it can start playback itself for
this rather than handing back to producer just to take a reading).

## 5. Finish (finisher)

Delegate to **finisher** to bounce the final mixdown (or stems, if the
brief asked for them) and verify loudness against the right target (-14
LUFS integrated for streaming is the default assumption unless the brief
says otherwise). If the bounce falls short of the target
(`report.limitedByCeiling`), loop back to mix-engineer for a limiter tweak
rather than accepting a quiet file.

## Sharp edges this workflow has actually hit

From a full end-to-end run (2026-08-17). Each one cost real time; each one
is now avoidable.

- **Pass the beat map down, every time.** Producer reports section names +
  beat ranges in step 1, and the scaffold lays real markers. Include them
  verbatim in every delegation — a specialist that has to re-derive the
  structure will re-derive it differently.
- **Don't ask an agent for `project_snapshot` note data.** It is ~290 KB on
  a 6-track song and overflows a subagent's output budget. Note reads go
  through `clip_get_notes` (one clip, optionally filtered); `composer`
  holds it.
- **Loudness needs headroom, not fader.** `mixer_set_master_volume` stops
  at 2.0 (≈ +6 dB); GM-sourced material often needs more to reach -14 LUFS.
  The move is a `gain` insert at the front of the master chain — tell
  `mix-engineer` that rather than letting it discover the ceiling.
- **A silent window is usually not a silent song.** A windowed
  `render_measure_loudness` drops MIDI notes that started before the window,
  so measuring "just the outro" of a sustained passage can read as silence.
  Measure from beat 0 before believing a hole exists.
- **Verify the FILE, not just the session.** `render_measure_loudness`
  re-renders the session; it never opens the bounce. `finisher` holds
  `audio_profile_file` for the artifact itself.
- **Nobody in the pipeline can hear.** Timbre choices are inference. Say so
  in the wrap-up, and invite the user to listen — that's not a caveat, it's
  the honest state of the run.

## 6. Wrap up

Summarize what was built (structure, track roster, instruments, mix
decisions, final loudness, and the rendered file path) for the user. Do
**not** call `project_save` unless the user explicitly asks you to save —
mention that the work is unsaved and offer to save it.
