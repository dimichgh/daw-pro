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
  roster + section clips + section markers + loop), or hand-build the
  structure itself (`track_add` per strip, `marker_add` per section,
  `transport_set_tempo`) when the brief needs something the five built-in
  genres don't cover.
- **Reconcile the scaffold with the brief before reporting.** The genre
  roster is unconditional: every vocal genre scaffolds a `Vocals` AUDIO
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
of this step so you know where the mix stands before finishing.

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
