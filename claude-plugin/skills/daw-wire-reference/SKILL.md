---
name: daw-wire-reference
description: Shared reference for every DAW Pro Music Team agent and skill — MCP tool-naming conventions, id-capture rules, beats-vs-seconds units, etiquette, and safety policy for driving DAW Pro over its MCP server. Load this before making DAW Pro tool calls.
user-invocable: false
---

# DAW Pro MCP wire reference

This is the shared reference every agent in this plugin (`producer`, `composer`,
`arranger`, `sound-designer`, `mix-engineer`, `finisher`) and every skill
points at. It reflects the ACTUAL current tool surface enumerated from
`mcp-server/src/server.ts` (136 tools) and `Sources/DAWControl/Commands.swift`
in the DAW Pro repo — not memory, and not the app's own in-app Copilot
catalog (`Sources/DAWControl/CopilotCatalog.swift`), which is a **different,
smaller, differently-named** tool set for a different AI (the app's built-in
chat rail). Do not confuse the two.

## How the plugin reaches the app

This plugin's `.mcp.json` spawns `server/index.mjs` (a generated,
self-contained bundle of `mcp-server/src/`, built with esbuild — see the
plugin README's "Developing this plugin" section) as a stdio MCP server.
That process is a thin bridge: it opens a WebSocket to the running DAW Pro
app's control port (`ws://127.0.0.1:17600` by default, override with the
`DAW_CONTROL_PORT` environment variable) and forwards each tool call as a
control-protocol command. The bridge connects lazily, only on a tool call
that actually needs the app (`tools/list` and other protocol-level traffic
never touch the port at all). **If the app isn't running, every tool call
that needs it fails with a connection error** — that's expected, not a bug;
tell the user to
launch DAW Pro (or `swift run DAWApp` from the repo) and retry.

## Tool naming

Every MCP tool name is the control-protocol command name with dots replaced
by underscores and camelCase preserved inside each segment, e.g.:

- `track.add` → `track_add`
- `clip.addMIDI` → `clip_add_midi`
- `render.measureLoudness` → `render_measure_loudness`

As a plugin-bundled server, this session sees them under the scoped callable
name `mcp__plugin_daw-pro-music-team_daw-pro__<tool_name>` (e.g.
`mcp__plugin_daw-pro-music-team_daw-pro__track_add`). Each agent's frontmatter
already grants exactly the tools its role needs under this scoped name — you
don't need to type the prefix yourself, just call the tool by its short name
when it appears in your available tools.

## Id-capture discipline (never guess an id)

Almost every tool that creates or targets something returns (or requires) a
real `id` (a UUID, or for tracks/effects/etc. a server-minted string).
**Capture ids from tool results and reuse them verbatim — never invent,
guess, or reconstruct one.**

- `track_add` returns the full created track object, including its `id`.
- `clip_add_midi` / `clip_add_audio` return the created clip, including its
  `id` — and `clip_add_midi` also mints an `id` for every note you passed.
- `fx_add` returns `{effectId, effects}` — capture `effectId` for later
  `fx_set_param` / `fx_set_bypass` / `fx_remove` calls.
- `track_add_send` returns the routing state with the new send's `id`.
- `marker_add`, `automation_add_lane`, `take_group`, `groove_extract` all
  return the object they created, with its `id`.
- When you don't have a fresh result to hand, call `project_overview` (cheap,
  compact — prefer it) or `project_snapshot` (full fidelity, including MIDI
  notes, automation points, and resolved effect params) to look ids up.

## Units: beats vs. seconds (read every param name carefully)

DAW Pro is a musical-time-first DAW. **Almost everything is in BEATS
(quarter notes), not seconds or bars:**

- `atBeat`, `startBeat`, `endBeat`, `toStartBeat`, `newStartBeat`,
  `fromBeat`, `beat` — all beats (quarter notes) from timeline start, unless
  the tool description says otherwise (e.g. a MIDI note's `startBeat` is
  relative to ITS CLIP's start, not the timeline).
- `lengthBeats`, `gridBeats`, `fadeInBeats`/`fadeOutBeats`,
  `timingBeats` — also beats.
- Bar-based tools (`arrange_insert_bars`, `arrange_delete_bars`,
  `macro_song_skeleton`'s `sections[].bars`) take **1-based bar numbers**,
  not beats — they're meter-aware (a bar is `beatsPerBar` beats long, which
  can change across a tempo/meter map).
- Seconds show up only for wall-clock things: `render_*`'s `durationSeconds`,
  `take_set_crossfade`'s `seconds`, `clip_detect_transients`' returned
  `sourceSeconds`, `take_auto_align`'s `searchWindowMs` (milliseconds).

Getting beats and bars confused is the single most common mistake an agent
makes on this surface — double-check which one a tool asks for before
calling it.

## Return shapes worth remembering

- `track_add` / `clip_add_midi` / `clip_add_audio` / `fx_add`: return the
  created model with an `id` field — capture it.
- `project_new` takes **only** `discardChanges` (boolean, default false) —
  there is no `name`/`template`/other param.
- `clip_set_notes` / `automation_set_points` / `clip_set_controller_lane` /
  `take_set_comp`: **whole-array replace**, not add/remove-one. Read the
  current array first (from `project_overview`/`project_snapshot` or a prior
  result), edit it in your own reasoning, then resubmit the complete array.
- `edit_undo` returns `{undone: "<label>", snapshot}` — the label tells you
  what it just reverted; `project_overview`'s/`project_snapshot`'s
  `undoLabel` field previews what the NEXT `edit_undo` would revert, before
  you call it.

## Etiquette (every agent follows this)

1. **Orient before mutating.** Call `app_connection_info` if you're unsure
   the app is reachable, and `project_overview` (prefer it over
   `project_snapshot` unless you need note/automation/effect-parameter
   fidelity) before your first mutation in a session, and again after a
   batch of changes from someone else.
2. **Prefer additive edits.** Add, don't replace, unless asked. Landing a
   new track/clip/effect is safer than reworking existing material.
3. **Destructive ops need an explicit user request**, never a guess:
   `project_new` (with `discardChanges: true`), `track_remove`,
   `clip_remove`, `arrange_delete_bars`. If a task seems to call for one of
   these, confirm with the user (or the coordinating `producer` agent)
   before calling it.
4. **`edit_undo` is your safety net.** If a step didn't land the way you
   expected, undo it and try again rather than papering over it with more
   edits.
5. **Save only when the user asks.** `project_save` is not part of most
   agents' toolset on purpose — only `producer` holds it, and only calls it
   on explicit request.
6. **Never handle API keys.** Provider keys (Anthropic/OpenAI/Suno) live in
   the app's own Settings panel or the MCP server's process environment —
   never ask the user to paste one into chat, and never try to set one over
   the wire (it isn't possible; `ai_provider_status` is read-only). If a
   provider shows `configured: false`, tell the user to open the app's
   Settings (⌘,) or set the corresponding environment variable
   (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `SUNO_API_KEY`) before restarting
   the MCP server.
7. **`ai_copilot_send` / `ai_copilot_state` / `ai_copilot_reset` are not in
   any agent's toolset, deliberately.** Those three drive the DAW app's OWN
   built-in AI copilot — a second, separate AI actor with its own tool
   catalog — not this plugin. Driving it from here would mean one AI
   steering a different AI inside the app; stick to the direct tools above
   instead.

## Policy: voice-conversion tools are intentionally not exposed

`vc_sidecar_status` / `vc_sidecar_start` / `vc_sidecar_stop` /
`vc_convert_vocals` / `vc_train_voice` / `vc_list_voices` exist on the MCP
surface but are **not** granted to any agent in this plugin, to keep the
roster tight and avoid any ambiguity around voice content. If a future
version of this plugin adds them (only to `sound-designer`, per the DAW Pro
project's own policy), the same rule applies every time: any `voiceId` must
be trained **only** from a person's own recordings that they have the rights
to use — **never** a celebrity or third-party voice model. The reserved id
`"base"` is a harmless smoke-test target (an untrained generic voice, not a
real conversion).

## Tools deliberately left out of every agent (and why)

- **Live recording input** (`transport_record`, `transport_set_punch`,
  `track_set_arm`, `midi_list_inputs`, `input_list_devices`,
  `input_set_device`): capturing a live microphone/MIDI performance is a
  human-at-the-instrument workflow driven from the app UI, not something an
  agent should trigger unattended.
- **Diagnostics** (`engine_performance_stats`, `engine_watchdog_status`,
  `app_feedback_bundle`): useful for troubleshooting, not for making music;
  reach for them ad hoc in the main conversation (they're still available
  there via the same MCP server) rather than through a named agent. The
  `daw-status` skill uses `app_connection_info`/`ai_provider_status`/
  `project_overview` for its connection-sanity check instead.
- **`generate_image`**: generates DAW Pro's own UI/marketing assets — a dev
  tool, not a music-making one.

## Genre-neutral defaults worth knowing

`macro_song_skeleton` (held by `producer`) scaffolds tempo + a genre's track
roster + section clips + a loop in one call, across five genres: `pop`
(120 BPM), `house` (124 BPM), `hip-hop` (90 BPM), `rock` (140 BPM), `ballad`
(72 BPM). It's additive — safe to call on an existing project — and a single
`edit_undo` reverts the whole scaffold.
