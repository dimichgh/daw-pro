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
  roster + section clips + loop), or hand-build the structure with
  `arranger` if the brief needs something the built-in genres don't cover.
- If the brief has a lyrical theme, write lyrics now (`ai_write_lyrics`/
  `generate_lyrics`) so downstream agents know what the vocal/melody needs
  to serve.
- Report back the track roster (names + ids), the section layout (names +
  beat ranges), and the tempo, so later steps don't have to re-derive them.

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

## 6. Wrap up

Summarize what was built (structure, track roster, instruments, mix
decisions, final loudness, and the rendered file path) for the user. Do
**not** call `project_save` unless the user explicitly asks you to save —
mention that the work is unsaved and offer to save it.
