---
name: daw-wire-reference
description: Shared reference for every DAW Pro Music Team agent and skill — MCP tool-naming conventions, id-capture rules, beats-vs-seconds units, etiquette, and safety policy for driving DAW Pro over its MCP server. Load this before making DAW Pro tool calls.
user-invocable: false
---

# DAW Pro MCP wire reference

This is the shared reference every agent in this plugin (`producer`, `composer`,
`arranger`, `sound-designer`, `mix-engineer`, `finisher`) and every skill
points at.

⚠️ **THE TWO COUNTS BELOW WERE STALE (last measured 2026-08-17) — RE-MEASURED
2026-08-28 (m27-h, then again same day at the m31-c close for
`clip.repeatNotes`, then again same day at the m26-a/m27-n close for
`clip.patchNotes`) by a stated, defensible method, not a guess.** Do NOT
infer from a past-wrong count that the traps further down are stale too: each
of those is pinned to a session that paid for it and is maintained
separately. Live totals live in `docs/ARCHITECTURE.md` §"Wire surface —
CURRENT TOTALS"; naive greps lie on both surfaces (`grep -c 'registerTool('`
alone over-counts — see the method below), so a real count needs a
derivation you can state and defend, not a bare `grep -c`.

It reflects the tool surface enumerated from
`mcp-server/src/server.ts` (**239 tools**, re-derived 2026-09-22 at the
m23-q Phase 2 writer-leg close — `clip_auto_correct_pitch`/
`clip_clear_pitch_edits`/`clip_get_pitch_edits`, all three through the
strict-schema wrapper (the `clip_detect_pitch` precedent); before that 236 at
the
m39-dm drum-machine close — four `instrument_*DrumKit/DrumParam/DrumPreset`
tools; before that 232 at the
m39-e MCP mirror close, which added the nine `mod_*` tools —
`mod_describe_kinds`, `mod_add_source`, `mod_set_source`,
`mod_remove_source`, `mod_add_route`, `mod_set_route_depth`,
`mod_remove_route`, `mod_set_macro`, `mod_describe` — closing a gap this
same paragraph never flagged: it sat stale at 223 while `Commands.swift`
had already moved 218 -> 227 with the `mod.*` engine close, and
`mcp-server/test/audit-tools.test.ts`'s bijection/audit test carried two RED
assertions until this close (see below); previously 223, re-derived 2026-09-19 at the
m39-f/g MCP mirror close, which added `instrument_describe_synth` — the
Poly Synth's twin of `instrument_describe_sampler`, closing the gap this
same paragraph flagged as sanctioned a few hours earlier the same day (see
below) — and mirrored m39-g's fifteen Poly Synth richness parameters into
`track_set_instrument`'s EXISTING schema (a parameter count, not a tool
count, so that half adds zero on its own); previously 222, re-derived
2026-09-19 at the
m23-cw MCP mirror close, which added `au_list_presets` (a pure READ of a
hosted AU's own factory/user preset lists, registered directly via
`server.registerTool` — the `au_describe_params` precedent) and
`au_load_preset` (LOADS a preset onto the live plugin instance, registered
through the strict-schema wrapper — the `au_set_param` precedent); previously
220, re-derived 2026-09-04/05 at the
m35-g close, which added the four `view.*` tools — `view_capture`,
`view_select_clip`, `view_panel_layout`, `view_open_editor` — that let an
agent SEE the app (screenshot it, focus a clip in the piano roll, read/set
which workspace surface is on screen, open an instrument/effect editor);
previously 208, re-derived 2026-08-30 at the
m34-f step ② close, which added `pad_play_effort` — the live-PERFORMANCE
sibling of `pad_preview_effort`, whose values are recorded into a rolling
take; previously 207, re-derived 2026-08-30 at the
m34-c close, which added the four one-click SoundFont download tools
(`instrument_list_downloadable_sound_banks`, `instrument_download_sound_bank`,
`instrument_sound_bank_download_status`, `instrument_cancel_sound_bank_download`);
previously 203, re-derived 2026-08-30 at the
m34-g close, which added `playbox_generate`. ⚠️⚠️ **THIS PARAGRAPH WAS FOUND
ROTTEN AT THE m34-g CLOSE AND THE ROT PREDATES IT: it claimed 196 against a
measured 202, a SIX-tool drift, because `doc-count-drift.mjs` scores the
COMMAND count and nothing scores this one.** It was found rotten AGAIN at the
m35-g close (claimed 208 against a measured 220, a TWELVE-tool drift, for the
same reason) — **treat this paragraph as due for staleness at every close that
adds a tool, not just the ones that remembered to touch it.** It was corrected
by re-running the decomposition below, whose arithmetic then matched a live
`tools/list` over the generated plugin bundle EXACTLY (**as SOURCE-measured
— the generated plugin bundle itself, `claude-plugin/server/index.mjs`, is a
RELEASE-STEP regen this item did NOT run; treat the bundle as stale until
that regen happens, the `daw-pro-project` §2026-09-20s precedent**) —
**249 (42 direct + 207 wrapper, MEASURED 2026-09-25 at the I1 wire leg
close (mcp-integration-engineer, part 2 of 2), by the same two anchored
name-capturing regexes — `^server\.registerTool($` / `^registerTool($` —
`clip_audition_note`, positive control present in the wrapper set, a
bogus name absent from both sets, 0 duplicates either side; THIS close
DOES run the release-step regen — see the release note below for 0.17.0,
so `claude-plugin/server/index.mjs` moves too, unlike every prior entry
in this chain)**; it was 248 (42 + 206, MEASURED 2026-09-24/25 at the I4
wire leg close, part 1 of 2 — `clip_set_note_pitches` — and STILL a
RELEASE-STEP regen that item did NOT run: `claude-plugin/server/index.mjs`
stayed at 247 (42 + 205) until this close) before that; it was 247
(42 + 205, MEASURED 2026-09-24 at the U-D close) before that
(`clip_set_note_gain`); 246 (42 + 204) before that at I7a's close
(`clip_set_note_cleared`); 245
(42 + 203) before that at the m23-ap C-0c
close; 244 (42 + 202) before that, 242 (42 + 200) before that, 239
(42 + 197) before that, 236 (42 + 194) before that, and 232 (41 + 191)
before the drum
machine, with a
negative control (a name that is not a tool) correctly absent. The bijection
test, `mcp-server/test/audit-tools.test.ts`, defines
`tool count = commands + |exception table B| + |exception table C|` — **244**
MIRRORED commands (243 + `clip_audition_note`) + 3 Table-B tools with no backing command at all
(`generate_image`, `generate_lyrics`, `generate_song_suno` — they call a
generation provider directly) + 2 Table-C tools that bridge to an EXISTING
command, `track.setInstrument`, under a friendlier name/shape
(`instrument_set_sampler_param`, `instrument_set_sampler_zones`) = **249**.
✅ **CLOSED, the pitch-editor command-surface door (2026-09-24,
`docs/design/2026-09-22-pitch-editor-ui.md` §9): the pane had no command
door at all — no way to open it, read it, or edit a note over the wire.
`view.openPitchEditor`/`clip.setNotePitch`/`clip.splitNote` close that gap
(`Commands.swift` 234 -> 237), mirrored 1:1 by `view_open_pitch_editor`/
`clip_set_note_pitch`/`clip_split_note` (all three via the strict-schema
wrapper — real, typo-worth-catching params on every one, the
`view_select_clip`/`clip_auto_correct_pitch` precedents), no exception-table
entry needed.** The command count and the mirrored count agree again
(237 = 237); do not reopen this note for a future gap without renaming it.
✅ **CLOSED, m39-levels-2 wire (2026-09-24): SIXTEEN LEVELS' model API
(`Sources/DAWCore/SixteenLevels.swift`'s `ProjectStore` extension —
`addSixteenLevelsSpread`/`setSixteenLevelsDirection`) shipped earlier with
no wire door reaching it at all. `instrument.spreadSlice`/
`instrument.setSpreadDirection` close that gap (`Commands.swift`
237 -> 239), mirrored 1:1 by `instrument_spread_slice`/
`instrument_set_spread_direction` (both via the strict-schema wrapper, the
`instrument_describe_sampler`/`instrument_set_sampler_zones` precedent), no
exception-table entry needed.** The command count and the mirrored count
agree again (239 = 239); do not reopen this note for a future gap without
renaming it.
✅ **CLOSED, m23-ap C-0c wire (2026-09-24): the read-only twin of
`clip_set_note_pitch`/`clip_split_note` — the pitch line a clip's render
will actually PLAY, frame by frame, after every edit, through the SAME
function the pitch editor draws with
(`Sources/DAWCore/PitchPlayedLine.swift`, design `docs/design/2026-09-24-
pitch-editor-timing-and-freehand.md` §4.5). `clip.getPlayedPitch` closes
that gap (`Commands.swift` 239 -> 240), mirrored 1:1 by
`clip_get_played_pitch` (strict-schema wrapper, the `clip_detect_pitch`
precedent), no exception-table entry needed. The same close's C-F3
`replaceExisting` optional param on `clip_auto_correct_pitch`/
`clip.autoCorrectPitch` is a parameter on an EXISTING command/tool and
moves neither count on its own. ⭐ swift-app review, same day: the
`replaceExisting:false` refusal now re-checks the table's CURRENT content
right before the write (not just before detection starts, which left a
real gap — seconds, on a real vocal — for a hand-edit to land unprotected),
and `clip.getPitchEdits`/`clip.autoCorrectPitch`/`clip.setNotePitch`/
`clip.splitNote` all gained an additive `handEditedSinceAutoCorrect`
boolean. Response-shape/behaviour only — neither count moves.** The
command count and the mirrored count agree again (240 = 240); do not
reopen this note for a future gap without renaming it.
✅ **CLOSED, m23-cw (2026-09-19): the "215 mirrored of 217 wire" gap this
paragraph used to flag is gone — `au.listPresets`/`au.loadPreset` are now
mirrored 1:1 as `au_list_presets`/`au_load_preset`, no exception-table entry
needed (the mechanical name rule already lands there).** The command count
and the mirrored count agreed again (217 = 217) for the rest of that day; do
not reopen this note for a future gap without renaming it — see immediately
below for the one that opened, and closed, a few hours later the SAME day.
✅ **CLOSED, m39-f/g (2026-09-19): the gap this paragraph flagged as OPEN a
few hours earlier the same day — the wire moved to 218
(`instrument.describeSynth` landed) while the MCP mirror stayed at 217 — is
gone. `instrument_describe_synth` is now registered (via the local
`registerTool` wrapper, the `instrument_describe_sampler` precedent — it is a
pure READ but takes real params, `trackId`, worth typo-catching, so it joined
the WRAPPER count, not the direct-read count), no exception-table entry
needed (the mechanical name rule already lands there): `instrument.describeSynth`
-> `instrument_describe_synth`.** The command count and the mirrored count
agree again (218 = 218); do not reopen this note for a future gap without
renaming it. The SAME close also mirrored m39-g's fifteen Poly Synth richness
parameters (`unisonVoices`, `unisonDetuneCents`, `unisonStereoSpread`,
`subLevel`, `subOctave`, `subWaveform`, `noiseLevel`, `noiseColor`, `drift`,
`resonanceBoost`, `drive`, `velocityToCutoff`, `keyToCutoff`, `voiceJitter`,
`envelopeCurve`) into `track_set_instrument`'s EXISTING schema — new
PARAMETERS on an existing command/tool never move either count, so that half
of the close contributed zero to the 222 -> 223 delta above; ranges/units are
re-typed (not re-derived — a static zod schema cannot call the verb at
runtime) from `PolySynthParams`'s `static let …Range` constants in
`Sources/DAWCore/Model.swift`, the SAME source `instrument.describeSynth`
itself reads, and `instrument_describe_synth` is the RUNTIME authority to
read back against. ⚠️ `subOctave`'s range is NEGATIVE, **-2...-1** — do not
schema it with `minimum: 0`. ⚠️ Every one of the fifteen is ADDITIVE-NIL-SAFE
on write: omitting a field PRESERVES whatever the track already had, and two
of the fifteen do NOT resolve an unset value to 0 (`noiseColor` -> 0.5,
`subOctave` -> -1).
✅ **CLOSED, m39-e (2026-09-19): a gap this paragraph never flagged —
`Commands.swift` moved to 227 (the nine-verb `mod.*` modulation family
landed wire-only) while this file's mirror sat stale at 223, and
`mcp-server/test/audit-tools.test.ts` was RED on two assertions until this
close — is gone. All nine tools are registered in `mcp-server/src/server.ts`:
`mod_describe_kinds`/`mod_describe` are pure READS with only OPTIONAL
params (the `fx_describe` precedent, not the `instrument_describe_synth`
one — that tool's `trackId` is REQUIRED, which is why it rode the wrapper
instead), so both joined the DIRECT `server.registerTool` count; the other
seven (`mod_add_source`, `mod_set_source`, `mod_remove_source`,
`mod_add_route`, `mod_set_route_depth`, `mod_remove_route`,
`mod_set_macro`) mutate and rode the strict-schema wrapper, no
exception-table entry needed (the mechanical name rule already lands there:
`mod.addSource` -> `mod_add_source`, etc.).** The command count and the
mirrored count agree again (227 = 227); do not reopen this note for a
future gap without renaming it. Tool descriptions carry the two things the
brief required VERBATIM: §7.2.0's polarity convention (`[1,0,1,0]` /
`[0,1,0,1]`, OFFSET, CLOSED, a NEGATIVE `depth`) on `mod_add_source`'s
`steps`/`pulseWidth`/`bipolar` fields and on `mod_add_route`'s `.volume`
target/`depth`; and §7.3's depth-law worked examples (`cutoffHz`'s 8.81
octaves, `resonance` ±0.25, `.volume` ±6 dB, `.pan` ±1.0) on
`mod_add_route`/`mod_set_route_depth`. `mod_describe_kinds` is named in all
eight sibling descriptions, the `fx_describe` precedent. New test file
`mcp-server/test/modulation.test.ts` (38 tests) pins the forwarding shape
for all nine, the direct-vs-wrapper strictness split, the nested-strict-gap
closure on `target` (the discriminated union) and `params` (the m30-c
precedent), and every one of those verbatim carries.
⚠️ The authoritative pins are `mcp-server/test/integration.test.ts`'s
`assert.equal(result.tools.length, 249)` and `mcp-server/test/mcp-log.test.ts`'s
`assert.equal(instrumented.length, 249)` — **NOT** a `grep -c 'registerTool('`,
which is a known liar on this file and previously anchored this paragraph at a
stale 194) and
`Sources/DAWControl/Commands.swift`
(**244 commands** — the `CommandRouter.allCommands.count == 244` pin in
`Tests/DAWControlTests/RenderCommandTests.swift`, and in eighteen sibling
files — **twenty pin lines across nineteen files** (one file carries two),
counted 2026-09-19 at the m39-f close, re-measured 2026-09-22 at the m23-q
writer-leg close (231 -> 234, `clip.autoCorrectPitch`/`clip.clearPitchEdits`/
`clip.getPitchEdits`, appended at the tail), re-measured again 2026-09-24 at
the pitch-editor command-surface-door close (234 -> 237,
`view.openPitchEditor`/`clip.setNotePitch`/`clip.splitNote`, inserted BESIDE
early-array siblings — `view.openEditor` and `clip.sliceToSampler` — NOT
appended at the tail, specifically because a near-tail insertion was tried
first and measured to break 99 `dropLast(N)` pins across 26 files; an
early-sibling anchor breaks only the 20 plain `.count == N` pins instead,
zero `dropLast` pins), re-measured again 2026-09-24 at the m39-levels-2
wire close (237 -> 239, `instrument.spreadSlice`/`instrument.setSpreadDirection`,
placed next to `instrument.describeSampler`, NOT at the tail; still the same
20 pin lines across 19 files, values only), re-measured again 2026-09-24 at
the m23-ap C-0c close (239 -> 240, `clip.getPlayedPitch`, placed next to
`clip.splitNote` — the same early-array pitch-editor-door cluster the
command-surface-door close above used, NOT at the tail; still the same 20
pin lines across 19 files, values only — verified by a fresh grep for the
literal `239`, not carried over: zero remaining, 20 lines at `== 240`),
re-measured again 2026-09-24 at I7a's close (240 -> 241, `clip.setNoteCleared`,
placed immediately after `clip.getPlayedPitch`, in the same per-note
pitch-editor-door cluster, NOT at the tail; still the same 20 pin lines
across 19 files, values only), re-measured again 2026-09-24 at the U-D close
(241 -> 242, `clip.setNoteGain`, placed immediately after
`clip.setNoteCleared`, NOT at the tail; still the same 20 pin lines across
19 files, values only — verified by a fresh grep for the literal `241`, not
carried over: zero remaining, 20 lines at `== 242`), re-measured again
2026-09-24/25 at the I4 wire leg close (mcp-integration-engineer, part 1 of
2: 242 -> 243, `clip.setNotePitches`, the BATCH twin of `clip.setNotePitch`,
placed immediately after `clip.setNoteGain`, in the same per-note
pitch-editor-door cluster, NOT at the tail; still the same 20 pin lines
across 19 files, values only — verified by a fresh grep for the literal
`242`, not carried over: zero remaining, 20 lines at `== 243`), re-measured
again 2026-09-25 at the I1 wire leg close (mcp-integration-engineer, part 2
of 2: 243 -> 244, `clip.auditionNote`, HEAR one or more sung notes now,
placed immediately after `clip.setNotePitches` — a deliberate departure
from the tail-of-cluster rule, since this verb is not a per-note WRITER —
still beside `clip.sliceToSampler`; still the same 20 pin lines across 19
files, values only — verified by a fresh grep for the literal `243`, not
carried over: zero remaining, 20 lines at `== 244`); ⚠️
three of the twenty spell it `all.count == N` and
seventeen `allCommands.count == N`, so grep the LITERAL number, not the
idiom)
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
  created model with an `id` field — capture it. `clip_add_audio` adds
  `trimmedClipIDs` / `removedClipIDs` (always present, empty on the ordinary
  path): it **refuses** an `atBeat` that would land on an existing clip unless
  you pass `overwrite: true`, and those two arrays are what `overwrite` cost
  you. Omit `atBeat` to append, which can never collide.
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

## Traps that have actually bitten (measured, not theoretical)

Every item here cost a real agent real time in a real session. Read them
before you reach for the tool they name.

### Editing notes: read ONE clip, don't snapshot the project

`clip_set_notes` is a whole-array replace, so editing existing notes means
reading them first — and the read tool is `clip_get_notes`, not
`project_snapshot`. It takes one `clipId`, optionally narrowed by
`fromBeat`/`toBeat` (CLIP-relative beats, half-open) and `pitchMin`/
`pitchMax` (inclusive), and it is read-only: no undo step, nothing dirtied.

⚠️ **The one way to destroy notes with it:** if you filter the read and
then whole-array-replace, everything you filtered out is deleted. That is
what `totalNotes` (unfiltered) next to `returnedNotes` (what you got) is
for — if they differ, you are not holding the whole clip. Read unfiltered
before a write, or write back through a re-read.

⭐ **Or skip the hazard entirely: `clip_patch_notes` (2026-08-28).** If you
are only CHANGING FIELDS (pitch/velocity/startBeat/lengthBeats) on notes
that already exist — not adding, removing, or reordering any — use
`clip_patch_notes {clipId, update: [{id, pitch?, velocity?, startBeat?,
lengthBeats?}]}` instead of `clip_get_notes` + filter + `clip_set_notes`.
It edits BY ID, can never drop a note it wasn't told about (there is no
code path from "call this" to "note gone"), and an id not in the clip
refuses the WHOLE call rather than silently doing nothing. One call is one
undo step. This was the actual motivating case: a legato pass changing
`lengthBeats` on 225 of a clip's notes, and a velocity bump on 48 of 907,
both had to round-trip the WHOLE array before this tool existed.
`clip_set_notes` is still the right tool for adding/removing/reordering
notes, or rewriting a clip wholesale.

### `project_snapshot` will overflow your output budget

MEASURED 2026-08-17 on a modest song — 6 tracks, 38 clips, 2,367 notes:
**~290 KB of JSON on the wire, ~560 KB / 17.7k lines once it is rendered
into a tool result.** That is past a single agent's output limit, and it
gets worse with every note you write. `project_overview` on the same
project: **7.5 KB.** So:

- **Default to `project_overview`.** It has the ids, the routing, the
  effect chains, and the clip layout — everything except note-level
  detail.
- Reach for `project_snapshot` only when you genuinely need notes,
  automation points, or resolved effect params, and expect it to be
  enormous on anything past a sketch.
- If a call does overflow, don't retry it and don't guess at the contents:
  say what you needed from it and hand the question back to the main
  session, which can read the overflow file from disk.

### `clip_add_midi` echoes every note back — turn it off when composing

`project_snapshot`'s size is the famous trap; this is the quiet one, and it sits
on the hot path instead of an occasional deep read. **`clip_add_midi` returns the
whole created clip, every note in it, each with a freshly minted id.** A 64-note
clip is about 6 KB, a song is dozens of such calls, and the documented maximum is
4096 notes per clip — all spent out of YOUR context window, for a call whose
useful answer is one clip id.

Pass **`returnNotes: false`** unless you are about to edit individual notes right
now. The reply then carries `notesOmitted: true` and `noteCount` instead of the
array, so it can never be confused with a clip that genuinely has no notes. The
notes stay readable with `clip_get_notes` whenever you actually want them.

The default is unchanged — omit the flag and you get the full echo, exactly as
before.

⚠️ `clip_set_notes` has the SAME echo and does **not** yet have this opt-out.

### Sidechain: it is the DESTINATION that must be audio/bus, not the source

`fx_set_sidechain` fails in an all-MIDI project for one reason only — the
keyed compressor/gate has to live on an **audio or bus** track, and an
instrument track cannot host one. The **key source may be any non-bus
track, instrument tracks included**: ducking a pad off a MIDI kick needs no
audio bounce at all. The recipe is `track_add {kind: "bus"}` →
`track_set_output` the pad into the bus → `fx_add` a compressor on the bus →
`fx_set_sidechain` keyed from the kick's instrument track. Only bus key
sources are deferred. (`mix-engineer` holds `track_add` for exactly this.)

### The master fader stops at +6 dB

`mixer_set_master_volume` is capped at 2.0 linear and a bigger value is
REJECTED by the MCP tool's schema. (One layer down, the
`mixer.setMasterVolume` control command clamps to 0-2 instead of erroring
and reports the clamp in `warnings` — the refusal is the schema's, not the
engine's.) General-MIDI-sourced material regularly needs more than +6 dB to
reach -14 LUFS. When it does, put a `gain` insert (`gainLinear` 0-16, up to
+24.08 dB) at index 0 of the master chain rather than pushing the fader —
the fader is a trim, not a makeup stage.

One insert is now enough. MEASURED: a solo GM piano part renders about
-28 LUFS at velocity 100 and near -35 LUFS at velocity 64, so -14 LUFS costs
+14 to +21 dB of makeup; the old +12 dB ceiling forced two chained gain
inserts, and the current +24.08 dB one does not. The headroom is real, not
free — the gain stage is a bare multiply, so follow a large boost with a
limiter and confirm with `render_measure_loudness`.

### A clamped value now says so

`fx_set_param`, `fx_add`'s seeded `params`, and `mixer.setMasterVolume` all
clamp out-of-range values rather than erroring. They now return a `warnings`
array of plain sentences naming what you asked for, what was stored, and the
range. The key is ABSENT when nothing was clamped, so seeing it at all means
the stored value is not the one you sent.

### A present `zones` array replaces the whole sampler map

`track_set_instrument` is a partial update everywhere, `sampler` included —
omit `zones` and the track's zones stand, so a one-global tweak
(`{sampler: {release: 0.4}}`) no longer costs a 309-zone resend. **But a
`zones` array you DO send to `track_set_instrument` replaces the map
wholesale and re-mints every zone's `id`** (ids you captured before that
call are dead afterward), so a partial zone list deletes the zones you
left out. Send `zones` only when you mean the complete map; `zones: []`
is the deliberate clear.

**For touching one or a few EXISTING zones, don't use `track_set_instrument`
at all — use `instrument_set_sampler_zones`.** ⚠️ CORRECTED 2026-08-28: this
is now the real merge-by-zone-id path (m26-g). Each entry names a zone by
`id` (captured from `instrument_describe_sampler`/`project_snapshot` on the
SAME track — an id from a different track, or one that never existed, is a
readable error and nothing lands) and patches only the fields it mentions;
every other field on that zone, and every zone not named at all, is left
exactly as it was. Reach for it before resending a 309-zone map to change
one release time.

### Making the sampler sound when you have no sample files

A fresh project ships no sample audio, so until 2026-08-23 the sampler could
not be smoke-tested at all without someone supplying a file — and the most
likely first experience of a new sampler feature was silence.

The app now ships **one generated one-shot**. Any sampler zone `path` accepts
`builtin:test-tone-a4` in place of a filesystem path: a 0.35 s A4 (440.0 Hz)
tone whose root pitch is **MIDI 69**. Use it to hear the sampler, and to
exercise `bendRangeSemitones` and `voiceMode`, with no library of your own:

```
track_set_instrument {
  kind: "sampler",
  sampler: {
    zones: [{path: "builtin:test-tone-a4", rootPitch: 69}],
    bendRangeSemitones: 12
  }
}
```

**An unknown `builtin:` name is REFUSED and the error lists the known names.**
It is never silently accepted — a path that fell through to the filesystem
would report success and play silence, which is the failure mode this whole
feature exists to remove.

### A windowed render is not an excerpt of the full render

`render_measure_loudness` (and any `fromBeat`-windowed render) DROPS every
MIDI note whose note-ON falls before the window start — both the note-on
and the note-off, so the note contributes nothing at all. A straddling
AUDIO clip behaves the opposite way: it is entered mid-file and sounds.
Measuring "just the outro" of a pad-heavy arrangement can therefore report
gated silence for a passage that is perfectly fine from the top. This
produced a convincing false alarm in a real session.

**So: an unexpectedly silent window over sustained MIDI is far more likely
to be this scheduling rule than a hole in the arrangement.** Re-measure
from beat 0, or from the start of the clip in question, before you report
silence to anyone. (The behaviour is deliberate-for-now and pinned by
tests; whether the bounce should chase held notes is an open product
question for the project owner, not something to work around silently.)

Related unit trap in the same call: `fromBeat` is BEATS, `durationSeconds`
is SECONDS. There is no beat-range form.

### `clip_humanize` compounds — it is not idempotent

The jitter is added to each note's CURRENT position, not to a stored
quantized original, and nothing on the clip records that it was ever
humanized. Two passes = double the drift, invisibly. `seed` reproduces a
result only from the SAME starting state. To re-roll a feel, `edit_undo`
the previous humanize first.

⚠️ **Its `legatoOverlapBeats` / `maxGapBeats` params are the exception —
they ARE idempotent.** The legato pass only ever EXTENDS a note, to a
target derived from the following note's onset, so running it twice lands
in the same place. It also consumes no randomness: omit both params and a
seeded timing/velocity result is bit-identical to before they existed.
Only note LENGTHS change — ids, order, start beats, pitches and velocities
are preserved, and a note is never extended past the clip end.

### The DJ filter (`kind: "djFilter"`) is a MOTION, and the knob is bipolar

`fx_add {kind: "djFilter"}` is the club/DJ-mixer sweep. Five params, one of
which is the whole effect:

| param | range | what it does |
|---|---|---|
| `position` | −1 … **0** … +1 | **0 is a BIT-EXACT BYPASS.** NEGATIVE = a low-pass falling down from 20 kHz, so the **treble** goes first (muffled, underwater). POSITIVE = a high-pass climbing up from 20 Hz, so the **bass** goes first (thin, radio-like). This is the direction a club mixer's filter knob turns: left muffles, right thins. |
| `resonance` | 0 … 1 | The whistle at the edge of the sweep, and the character. `Q = 0.707 + resonance × 9.293`. |
| `slopeDbPerOct` | 12 or 24 | Snaps to the nearer. 24 = tight modern club, 12 = gentler. Does **not** change the resonant peak's height. |
| `deadZoneWidth` | 0 … 0.2 | The do-nothing detent at the centre, so a sweep passing THROUGH the middle hands over cleanly instead of jumping. |
| `resonanceTrack` | 0 … 1 | Extra resonance only near the extremes — the "isolator" feel. |

**Three things that will otherwise bite:**

⭐ **Park it at one value and you have built a tone control, not a DJ
filter.** The thing people mean by "DJ filter" is the SWEEP. Draw it:
`automation_add_lane {target: "effectParam", param: "position"}` then
`automation_set_points` from −0.8 to +0.8 over 8 bars. The effect smooths its
own coefficients internally (32-frame stride), so an automated sweep does not
zipper the way an `eq.lowPassFreq` lane does.

⚠️ **High resonance makes the whole filter QUIETER, on purpose.** The
resonant section is scaled by `sqrt(0.707/Q)` so a Q-10 peak cannot slam the
mix — which costs about **11.5 dB of passband at `resonance: 1`** (measured).
That is the protection working. Add a `gain` insert after it if you need the
level back; do not report it as a bug.

⚠️ **The travel is log-symmetric, and there is no `mix`.** Cutoff is
`20000 × 0.001^|position|` for a **negative** position and `20 × 1000^position`
for a **positive** one — the low-pass corner FALLS as the knob goes more
negative, the high-pass corner RISES as it goes more positive — so equal knob
movement is equal musical movement at both ends. There is
deliberately no dry/wet: blending a resonant filter with its own dry signal is
comb filtering, not a gentler filter. Use `deadZoneWidth` (a centre
crossfade) or automate `position` a shorter distance.

### The ring modulator (`kind: "ringMod"`) is NOT a filter, and its "bug" is the feature

`fx_add {kind: "ringMod"}` multiplies your signal by a tone. **Neither the
signal nor the tone survives**: every partial at `f` in the input becomes a
PAIR of new tones at `|f − carrierHz|` and `f + carrierHz`. A harmonic series
in comes out **inharmonic**, which is why it sounds like a bell, a robot or a
Dalek rather than like EQ or distortion. This is the effect the user means by
"frequency modulation" on an insert.

| param | range | what it does |
|---|---|---|
| `carrierHz` | 0.5 … **440** … 5000 | THE knob, logarithmic. Under ~20 Hz it is a **tremolo**; 50–300 Hz growls; above ~500 Hz it goes clangorous and sci-fi. |
| `mix` | 0 … **0.5** … 1 | **0 is a BIT-EXACT BYPASS.** 1 loses the original pitch entirely (the Dalek setting). 0.5 keeps the source recognisable under the metal. |
| `waveform` | 0 sine / 1 triangle / 2 square / 3 saw | Whole numbers; others round. Sine gives ONE sideband pair per partial and is the clean, bell-like one. The other three are band-limited, so they add no aliasing of their own. |
| `inputHighCutHz` | 500 … **20000** | A **PRE**-filter on the carrier path only. The fold-back control — see below. |
| `stereoSpreadDeg` | **0** … 180 | Right-channel carrier phase offset. 0 is mono-safe; 180 is widest and cancels most in a mono fold-down. |

**Three things that will otherwise bite:**

⚠️ **The tremolo rate depends on `mix`, and this WILL be reported as a bug.**
The output is `signal × (mix·carrier + (1 − mix))`, so the envelope factor only
swings negative — and only gets rectified into a doubled pulse — when
`mix > 0.5`. At **mix 0.5 (the default) or below, a 2 Hz carrier is two pulses
a second**; at **mix 1 it is four**. Measured, not inferred: an earlier draft of
this page said "four, always" and the rendered demo caught it at 2.00 Hz.

⛔ **THE CLANGOROUS FOLD-BACK IS THE CHARACTER, AND IT IS NOT OVERSAMPLED
AWAY.** `f + carrierHz` routinely exceeds what the sample rate can represent
and folds back down as an extra inharmonic tone. Classic hardware ring
modulators do exactly this and it is half of why people reach for one. If a
user wants a cleaner, bell-like result, **pull `inputHighCutHz` down to around
4000** — a partial you removed cannot produce a sideband that folds. Do not
reach for oversampling; the design forbids it here on purpose. Because the
high-cut is a PRE-filter it tames the metallic layer **without** dulling the
dry signal, so at `mix: 0.5` your original keeps its top end.

⭐ **`carrierHz` is a lane worth DRAWING, and safe to.** The oscillator's phase
is continuous across a change, so a carrier step is a frequency step and never
a click — `automation_add_lane {target: "effectParam", param: "carrierHz"}`
sweeping 40 → 900 Hz over 8 bars is a classic riser. `waveform` is discrete and
refuses automation; changing it mid-note steps the carrier rather than gliding.

### `tapeDelay` and `delay` are different kinds, and picking the wrong one is silent

`fx_add {kind: "delay"}` and `fx_add {kind: "tapeDelay"}` are **both shipping,
neither replaces the other**, and the two things that decide between them are
not matters of taste:

| you need | kind | why |
|---|---|---|
| tempo sync (`sync`, `division`) | **`delay`** | ⛔ `tapeDelay` has NO sync in v1 and no `sync`/`division` param. Setting one is a name error, not a no-op. |
| repeats that wobble in pitch | **`tapeDelay`** | ⛔ `delay` holds its delay in a whole number of samples. A sub-sample drift is not a tuning problem there, it is **unrepresentable**. `delay` cannot wow, at any setting. |

⚠️ **`tapeDelay.timeMs` BENDS THE PITCH of repeats that are already sounding.**
Both kinds mark `timeMs` `warned` for modulation and the two warnings are about
opposite things. `delay.timeMs` steps whole samples and **clicks** — that is a
defect. `tapeDelay.timeMs` reads a fractional position and **glides**, like a
varispeed tape — that is the mechanism working. Riding it by hand is a real dub
gesture; automating it expecting a clean time change is not. For a clean change,
change it between phrases or drop `mix` to 0 first.

⭐ **Ask for a stated amount of wobble instead of guessing.** Every `fx.add` /
`fx.setParam` result — and `project.snapshot` — echoes `wowCents` and
`flutterCents` inside that insert's `params` object: the actual peak pitch
deviation the current `wowDepthMs`/`wowRateHz`/`flutterDepthMs` produce.
⚠️ They are **per-instance echoes, not schema**, so they are **not** in
`fx.describe`, which returns `{name, min, max, default, curve, note}` and no
values at all. (`wowCents` is the UPWARD peak; the downward one is a fraction
larger — `−1200·log2(1 − π·f·D)` — because the pitch ratio is `1 − d'(t)`.) The
defaults give about 10.8 cents of wow (a tenth of a semitone: obvious on a
sustained pad, inaudible on a drum hit) and 12.9 cents of flutter. The maximum
is over a semitone, which is a broken machine and is what the top of the range
is for. The two wow controls **multiply**: doubling either doubles the deviation.

⚠️ **Its high cut is in the RECORD path, so it colours the FIRST repeat too.**
`delay.highCutHz` sits in the feedback loop only, so the first echo comes back
unfiltered and only later ones darken. `tapeDelay.highCutHz` runs on the way in,
because on a real machine the sound was already on tape by then — so repeat one
is already rolled off and each later one is duller again. That is what makes a
0.9 feedback dissolve instead of piling up. `saturationDrive` sits in the same
stage and **0 is exactly linear**, not merely gentle.

### `stereoWidth.width` is a SILENT NO-OP on a mono source, and that is the trap

⛔ **`fx_add {kind: "stereoWidth", params: {width: 2}}` on a mono track changes
NOTHING, reports success, and returns a `params` object showing `width: 2`.**
It is not broken. `width` is a gain on the stereo DIFFERENCE (`L − R`), and on a
mono source that difference is zero — two times zero is still zero. An agent
that widens a mono synth with `width` and then reports "done" has shipped
silence-shaped success.

**The control that actually makes a mono source stereo is `spread`.** It builds
a new side channel by running the centre through a four-stage all-pass chain
(2.9–13.1 ms) and adding it to one side while subtracting it from the other.
Reach for `width` on material that is already stereo, `spread` on material that
is not, and both when you are not sure.

| the ask | the param | why |
|---|---|---|
| "make this stereo bus wider" | **`width`** | Pure gain on the existing difference. No filtering, no delay, no colouration. Free. |
| "make this mono synth stereo" | **`spread`** | Manufactures a difference. Costs a per-channel ripple — see below. |
| "tighten the low end" | **`bassMonoAmount`** | ON by default (1). Removes side content below `bassMonoHz` at 12 dB/oct. |
| "make this mono" | **`width: 0` AND `spread: 0`** | ⛔ **`width: 0` on its own is NOT a mono-maker.** `spread` defaults to **0.3** and builds a new side channel *after* `width` has scaled the old one, so a freshly added insert at `width: 0` still comes out stereo — and on a **mono** source it comes out *wider than it went in*. Send both. |

⭐ **The mono fold-down is untouched at every setting, and that is a structural
guarantee rather than a tuning.** This kind only ever processes the SIDE
channel; the MID passes through as it arrived, so `L + R` out is `L + R` in to
within a couple of float ULPs. That is why it is safe to reach for on a master
bus, and it is the specific thing a Haas widener (one side delayed 5–30 ms) or a
polarity-flipped duplicate cannot promise — those widen on speakers and then
comb, collapse or hollow out the moment anything sums to mono.

⚠️ **`spread` is the one control here that costs something, and the cost is
arithmetic.** Each channel ON ITS OWN ripples between `20·log10(1 + spread)` and
`20·log10(1 − spread)` dB across the spectrum: **+2.3 / −3.1 dB at the 0.3
default**, a complete null at 1.0. The two channels' ripples are complementary —
that is what makes it sound wide — and they cancel exactly in the sum. You
cannot have both a flat mono sum and flat individual channels out of a mono
source; that is a theorem, not an implementation limit, and this kind always
chooses the flat sum. Every `fx.add` / `fx.setParam` result — and
`project.snapshot` — echoes `channelPeakDb` and `channelNotchDb` inside that
insert's `params` object. ⚠️ They are **per-instance echoes, not schema**, so
they are **not** in `fx.describe`, which returns `{name, min, max, default,
curve, note}` and no values at all.

⚠️ **`bassMonoHz` does nothing while `bassMonoAmount` is 0**, and a `fx.setParam`
on it will still report success. The frequency of a fully bypassed filter is not
a setting.

⛔ **THERE IS NO `mix` ON THIS KIND.** `fx.setParam {name: "mix"}` is a name
error, not a no-op. A dry/wet blend on a mid/side widener is algebraically just
another `width` and another `spread`, so it would be a lie in `fx.describe`. The
equivalent neutral position — and it is a **bit-exact** passthrough — is
`width: 1`, `spread: 0`, `bassMonoAmount: 0`.

### `phaser` and `flanger` are DIFFERENT EFFECTS, and picking the wrong one is the trap

⛔ **Both sweep, both "whoosh", and the two words get used interchangeably by
people who mean one of them specifically.** The difference is arithmetic, not
taste, and it is audible immediately:

| | `flanger` | `phaser` |
|---|---|---|
| what it sums with | a **delayed** copy | a **phase-shifted** copy |
| notches | **dozens**, evenly spaced at **1 : 3 : 5 : 7 ×** a base | **`stages` ÷ 2** — a handful — at **1 : 3.4 : 7.5 : 25 ×** (8 stages), spreading as they climb |
| sounds like | metallic, jet-plane, aggressive | soft, vocal, breathing, "swirly" |
| reach for it when | "that whoosh from the 70s record", metallic, jet | pads, keys, guitar, a mix bus that needs movement |

**Measured, not asserted:** the same notch-finder run over both kinds finds
**4** notches for an 8-stage phaser and **16** for a flanger in the same band,
and each one's notch positions sit **10 %–261 %** away from the other's law.

⚠️ **`phaser.centerHz` IS NOT A NOTCH FREQUENCY, and this is the second trap.**
It is the all-pass corner at the bottom of the sweep; the notches straddle it,
and **the lowest one sits well BELOW it** — 0.41× at 4 stages, 0.13× at 12. Ask
for a phaser "around 400 Hz" by setting `centerHz` and then READ the answer:
every `fx.add` / `fx.setParam` result — and `project.snapshot` — echoes
`notchCount` and `firstNotchHz` inside that insert's `params` object.
⚠️ They are **per-instance echoes, not schema**, so they are **not** in
`fx.describe`, which returns `{name, min, max, default, curve, note}` and no
values at all.

⛔ **`phaser.stages` IS EVEN-ONLY AND SNAPS SILENTLY.** `fx.setParam {name:
"stages", value: 7}` succeeds and reports **8**. Read the value back rather than
assuming yours took. It is also **discrete**: `mod.addRoute` refuses it, and an
`automation.addLane` on it wants `hold` interpolation, never a ramp — a count
change clears the all-pass state, so a ramp would re-clear it every block.

⚠️ **`phaser` at `mix: 1` with `feedback: 0` is very nearly INAUDIBLE, and it is
not broken.** An all-pass chain alone changes no frequency's level at all
(measured flat to 1.2e-05 dB), so with no dry copy left to cancel against there
is nothing to hear. The notches ARE cancellation between dry and wet: they are
deepest at `mix: 0.5` and get shallower in **either** direction from there.
`mix: 0` is a bit-exact bypass.

⚠️ **`phaser.depthOctaves: 0` is a REAL SETTING, not a broken one** — it freezes
the sweep into a fixed notch filter, which is the sound of a wah pedal held
still. If a user asks for "that phaser colour but stop it moving", that is the
control, not `rateHz`.

⚠️ **TELL THE USER TO USE HEADPHONES OR TWO SPEAKERS.** A width change is close
to inaudible on a single speaker *by construction*, since the mono sum is what
stays the same. If they are on a laptop speaker or a phone, quote
`channelPeakDb`/`channelNotchDb` instead of asking them to listen.

### `freqShifter` is NOT a pitch shifter and NOT a ring modulator, and it will not play in tune

`fx_add {kind: "freqShifter"}` adds the same number of **Hz** to every partial.
A pitch shifter MULTIPLIES every partial by the same **ratio**. ⛔ **That is not a
nuance, it is the whole kind**: 100/200/300 Hz becomes 200/300/400 Hz, which is
no longer a harmonic series, so the result reads as a BELL or a sheet of METAL
rather than as a note. If a user asks to "shift the vocal up a tone", this is the
WRONG kind — it cannot play in tune and no setting makes it.

⛔ **It is also not `ringMod`.** A ring modulator is DOUBLE-sideband: it emits
both `f + fc` and `|f − fc|` and the original partial vanishes. This is
SINGLE-sideband — one of the two survives and the other is rejected. Measured off
a rendered 1 kHz sine shifted +200 Hz: wanted sideband **−6.02 dB**, unwanted
image **−55.77 dB**, carrier leakage **−153.8 dB**, i.e. **49.75 dB of rejection**.
A build that had quietly lost its quadrature would show those first two within a
fraction of a dB of each other and would still sound metallic.

⭐ **THE FAMOUS USE IS THE TINY ONE.** `fineHz` at **1–20 Hz** does not sound like
a shift at all — it beats slowly against the dry signal for a thickness no chorus
produces, and is the oldest fix in live sound for a microphone on the edge of
feedback. `fineHz` exists as a separate knob because that zone is **1 % of
`shiftHz`'s travel** and `.logarithmic` is unavailable to a range that crosses 0.
The two are ADDED and their SUM is clamped to `shiftHz`'s range, so the
advertised ±2000 Hz is the real limit rather than ±2020.

⭐ **THE SIGN IS THE DIRECTION** — positive up, negative down, no mode switch — so
it sweeps and automates continuously THROUGH zero.

⚠️ **SHIFTING DOWN PAST 0 Hz REFLECTS, AND THAT IS REAL.** A partial driven below
0 Hz comes back up at `|f + Δ|` with its phase inverted: 100 Hz shifted −300 Hz
returns at **200 Hz** (measured, −6.02 dB). Every analog Bode shifter does this.
Do not report it as a bug.

⚠️ **`mix` MATTERS MORE HERE THAN ON MOST EFFECTS.** At `mix` 1 the in-tune
original is GONE — right for bells, usually wrong for a lead vocal or bass. The
default is 0.5. At `mix` **exactly 0** the insert is BIT-EXACT dry (the buffer is
never written) while the network and both oscillators keep running, so raising it
again fades in rather than jumping. `outputDb` trims the SHIFTED copy only, which
is what keeps `mix` 0 bit-exact at any trim setting.

⚠️ `effectiveShiftHz`, `sidebandRejectionDb` and `hilbertPhaseErrorDeg` are
echoed in `fx.add` / `fx.setParam` results and `project.snapshot` inside that
insert's `params` — **per-instance echoes, not schema**, so they are **not** in
`fx.describe`.

### `transientShaper` has NO threshold, its knobs are MAXIMA, and nothing under −70 dBFS is touched

`fx_add {kind: "transientShaper"}` reshapes a hit rather than its level:
`attackDb` ("Punch") moves the leading edge, `sustainDb` ("Body") moves the tail.
⛔ **It is not a compressor and it has no threshold or ratio**, because it
responds to the signal's rate of change against its OWN lagged copy, not to
absolute level. Pulling the fader down does not pull the effect down — measured:
the same settings on the same hit 20 dB quieter shaped it to within
**1.65e-06 dB** of the loud one.

⛔ **`attackDb: 6` IS A CEILING, NOT "+6 dB".** The full amount lands only where
the detector's differential reaches `fullShapeDifferentialDb` = **12 dB** — a
hard, step-like onset. Softer or slower onsets produce a smaller differential and
get a PROPORTIONAL fraction of the knob, which is what keeps it from pumping.
Measured on a plucked burst: `attackDb: 6` reads **+6.00 dB** over the first
`attackWindowMs`, `attackDb: -6` reads **−6.00 dB**. When a user asks why "+12"
only moved their pad a little, this is the answer — the fix is a harder source or
a shorter `attackMs`, not a bigger number.

⚠️ **`attackWindowMs` is DERIVED from `attackMs`, and the two are not the same
number.** `attackMs` is the DETECTOR's lag; the window over which attack shaping
is at full strength for a step onset is `attackMs × 0.28927`, so the default
`attackMs: 5` shapes the first **~1.45 ms** — a 3.46× difference. Every `fx.add`
/ `fx.setParam` result and `project.snapshot` echo `attackWindowMs`,
`fullShapeDifferentialDb` and `detectorFloorDb` inside that insert's `params`
object. ⚠️ Those are **per-instance echoes, not schema**, so they are **not** in
`fx.describe`, which returns `{name, min, max, default, curve, note}` and no
values at all.

⛔ **NOTHING BELOW −70 dBFS IS SHAPED AT ALL** (`detectorFloorDb`), and it is a
HARD gate, not a soft knee. A fade-out tail, a quiet room-tone take, or a track
feeding a heavily attenuated send crosses it and the insert becomes a bit-exact
passthrough while the knobs still read +12. Measured: a −64 dBFS burst is shaped
**+9.75 dB**; the same burst at −76 dBFS is shaped **0.0 dB**. If a user reports
"it does nothing on this track", check the level going INTO the insert first.

⚠️ **`mix: 0` is a bit-exact bypass, and so are the defaults** (`attackDb: 0`,
`sustainDb: 0`, `outputDb: 0`) — verified on float BIT PATTERNS, not a tolerance.
The detector still runs; it just has nothing to apply. `outputDb` is the trim for
re-matching level after a shaping change and is the only parameter that applies
unconditionally — it is the one to automate if you want a plain gain move.

⚠️ **Zero latency, deliberately** (`latencySamples == 0`): no lookahead, so it
never enters the PDC path. The honest cost is that an attack CUT leaves the first
~2 samples of a leading edge unattenuated (a sub-0.05 ms tick).

### `clipper` is NOT `saturator` and NOT `limiter`, and `oversampling` is the reason the kind exists

`fx_add {kind: "clipper"}` sets a HARD CEILING and cuts off everything above it.
That is how loud masters and hard-hitting drums are actually made, and it is a
different job from either neighbouring kind:

- ⛔ **NOT `saturator`.** The difference is exact, not a matter of degree.
  `tanh` only ASYMPTOTICALLY approaches its bound, so a saturator can never
  promise a peak ceiling at all. BOTH of this kind's modes reach the ceiling at a
  FINITE input and stay there — `hard` immediately, `soft` bending in through a
  cubic knee and going flat at **1.5× the ceiling**.
- ⛔ **NOT `limiter`.** A limiter rides a GAIN to avoid clipping and preserves
  the waveform's shape. This DEFORMS the waveform on purpose — that deformation
  is where the loudness and the bite come from.

⭐ **`clipThresholdDbfs` IS THE NUMBER THE USER ACTUALLY WANTS, AND NEITHER KNOB
SHOWS IT.** Clipping starts at an INPUT level of `ceilingDb − driveDb`. Every
`fx.add` / `fx.setParam` result echoes it. When someone says "I set the ceiling
to −6 but nothing is clipping", this is the number to quote — with `driveDb: 0`
nothing below −6 dBFS input ever reaches the ceiling.

⚠️ **NEGATIVE DRIVE IS REACHABLE ON PURPOSE** (`driveDb` goes to −12). With a low
ceiling and a negative drive this stops being a loudness tool and becomes a gentle
wave-shaper. That is a setting, not a misuse.

#### Oversampling: what it fixes, and the honest size of it

Hard clipping generates harmonics far above Nyquist. They do not vanish — they
FOLD BACK into the audible band as tones unrelated to the music, a thin metallic
fizz. Running the shaper at 2× or 4× moves the fold out of the band.

⭐ **MEASURED, off rendered audio, on a 6271.927 Hz tone at 48 kHz** (the fixture
`scripts/gates/m39ac-clipper-physics.mjs` uses, re-derived and re-measured
independently): the alias floor drops **91.05 dB** going from `1` to `4`.

⚠️ **`2` IS MUCH CLOSER TO `1` THAN TO `4`, AND THE PHYSICS SAYS WHY** — do not
read the numbers as a smooth ramp. H13 and H15 fold *INSIDE* 2×'s own doubled
band and pass through untouched: **−53.3 / −50.4 dB at BOTH `1` and `2`**, but
**−147 / −152 dB at `4`**. If a user wants the fizz gone, `2` is a compromise and
`4` is the answer.

⛔ **THE HONEST CALIBRATION: ON MUSIC THIS IS SUBTLE.** On the tone it is 91 dB
and unmissable. On an actual riff, `1` and `4` differ by about **−43.85 dB** RMS —
real, and tilted **+4.16 dB** toward the high end against the music's own −18.2 dB,
which is exactly the signature of high-frequency fizz. But 44 dB down is quiet.
**If a user says they cannot hear the difference on a laptop speaker, that is a
real answer, not a failure to listen** — quote the tone measurement instead of
asking them to listen harder, and treat "is 4× worth the CPU for this material"
as an open question rather than a settled one.

⭐ **`1` IS A SHIPPED SETTING, NOT A DEGRADED ONE.** Plenty of records want that
grit, and it is the only way to hear what the other settings remove.

⚠️ **ONLY 1, 2 AND 4 EXIST, AND 3 ROUNDS *UP* TO 4.** The snap is `< 1.5 → 1`,
`< 3.0 → 2`, else `4` — ties resolve upward. `resolvedOversampling` and
`resolvedMode` come back in every result and are the values the render thread
actually uses; quote those, never the requested ones.

⚠️ **`mode` AND `oversampling` ARE DISCRETE — automate them with `hold`, NEVER a
ramp.** They are `Modulatable: refused`.

#### The latency is a CONSTANT 32, and `mix: 0` is a DELAYED identity

⛔ **UNLIKE EVERY OTHER BUILT-IN EXCEPT `limiter`, THIS KIND REPORTS LATENCY** —
a constant **32 samples at every `oversampling` setting, including `1`**, removed
automatically by delay compensation.

⭐ **THAT CONSTANCY IS A DESIGN REQUIREMENT, NOT A COINCIDENCE.** The anti-alias
kernel's cutoff is pinned at BASE-rate Nyquist, so its group delay is the same 32
base samples at every factor. It has to be: parameter edits do not republish the
chain, so a factor-dependent latency would silently stale the PDC plan the moment
a user moved the knob. At `1` the kernel degenerates to a unit impulse and the 32
samples of delay remain.

⛔ **SO `mix: 0` IS NOT AN UNTOUCHED BUFFER HERE.** It is the input DELAYED BY 32
SAMPLES, sample for sample. This kind deliberately breaks the usual bit-exact-dry
identity law, and the dry half of the blend is delayed to match so the mix stays
phase-coherent. If a null test against this insert at `mix: 0` fails, check the
32-sample offset before reporting a bug.

⚠️ **THE CEILING BOUNDS SAMPLES, NOT TRUE PEAK.** The wave drawn between samples
can ride roughly a decibel higher, which is what a broadcast meter reads. Follow
with a `limiter` at `truePeak: 1` if you need that guarantee. And a POSITIVE
`outputDb` raises the real maximum to `ceilingDb + outputDb`, echoed as
`wetCeilingDbfs` — the ceiling knob alone is not the output ceiling.

### `saturator` has the SAME `oversampling` knob and THREE of its rules are INVERTED

`saturator` and `clipper` now share a control with the same name, the same
values (1/2/4) and the same snap. **Everything else about it is different on the
two kinds, and an agent that carries a habit across will be wrong three ways.**

| | `clipper` | `saturator` |
|---|---|---|
| default, a NEW insert | **1 (OFF)**, since the 2026-09-20 ruling below | **1 (OFF)** |
| latency | **constant 32** at every factor | **0 at 1, 32 at 2/4** |
| automation lane on it | allowed (use `hold`) | **REFUSED — the lane errors** |
| `mix: 0` | delayed identity, `in[n−32]` | **untouched buffer** at 1; `in[n−32]` at 2/4 |

⚠️ **`clipper`'s default is NOT single-valued the way `saturator`'s is.** A
NEW clipper starts at `1`, same as saturator — but a clipper SAVED before the
2026-09-20 ruling, with no `oversampling` key in its file at all, decodes to
**4**, because that is what it was actually rendering at. `saturator` has no
equivalent split: it shipped with no such control at all, so an old save and
a new one both land on `1`. Never "tidy" either clipper fallback onto the
other's value — `ClipperParams.defaultOversampling` (1, new) and
`ClipperParams.legacyOversampling` (4, absent-in-file) are both FROZEN.

#### Why the default is 1, and why that is not "the worse setting"

⛔ **IT IS A COMPATIBILITY DEFAULT, NOT A QUALITY OPINION.** `saturator` shipped
long before this control existed, so there are already saved projects with one in
a chain. A default of 2 or 4 would change what every one of them SOUNDS like AND
shift it in time by 32 samples, silently, on the next open. At `1` the whole
oversampling path is **skipped** — not run at factor 1, skipped — and the output
is bit-for-bit what it always was.

⭐ **THAT IS A MEASURED CLAIM, NOT A DESIGN INTENTION.**
`scripts/gates/m39ad-saturator-default-bytes.mjs` pins the sha256 of a rendered
saturator against hashes captured from a build in which the parameter did not
exist, with a no-effect CONTROL hash so an unrelated engine change cannot be
mistaken for a saturator regression. Two of its three pins cover the default; the
third covers a PARTIAL `mix`, because at the default `mix` of 1 the dry half of
the blend is multiplied by zero and a change confined to the blend is invisible.

⭐ **SO: IF YOU ARE ADDING A SATURATOR TODAY AND DRIVING IT HARD, PASS
`oversampling: 4`.** The alias floor drops **90.28 dB** from 1 to 4 — measured
off rendered audio on the same 6271.927 Hz tone the clipper's gate uses
(`scripts/gates/m39ad-saturator-physics.mjs`). `tanh` is odd-symmetric exactly
like a hard clip, so it folds back exactly the same way.

⚠️ **AND `2` IS MUCH CLOSER TO `1` THAN TO `4` HERE TOO, FOR THE SAME REASON:
16.47 dB against 90.28.** H13 and H15 fold *inside* 2×'s own doubled band and
pass through untouched — measured unchanged to 0.1 dB between `1` and `2`. If a
user wants the fizz gone, `2` is a compromise and `4` is the answer.

#### The latency MOVES with the knob here, and that is the trap

⛔⛔ **DO NOT ASSUME 32.** On `saturator` it is **0 at `oversampling` 1** and
**32 at 2 or 4**. Read `latencySamples` back out of the `fx.add` /
`fx.setParam` result; it is echoed on every one, alongside
`resolvedOversampling` and `aliasRejectionDb`. Delay compensation removes it
either way, so the track still lines up — but a null test against this insert
will be off by 32 samples at 2/4 and by nothing at 1.

⚠️ **THIS IS WHY AN AUTOMATION LANE ON IT IS REFUSED RATHER THAN DISCOURAGED.**
`automation.setLane` on `saturator`.`oversampling` errors like an unknown
parameter name. Delay compensation is recomputed only when the parameter is
edited directly, so a lane moving the factor from the render thread would leave
the whole project's compensation stale with nothing reporting it. Step it with
`fx.setParam` between sections instead. The identically named parameter on
`clipper` *is* automatable (with `hold`), precisely because that kind's latency
is constant.

⛔ **AND `saturator` IS STILL NOT `clipper`.** Sharing a quality knob changes
nothing about what the two kinds do: `tanh` only ever APPROACHES its bound, so
`saturator` cannot promise a peak ceiling at any setting. If a level must not be
exceeded, that is `clipper` (or a `limiter`). If you want the sound to thicken,
that is this one.

### `dynamicEQ` is the largest kind in the app, and its budget cost is the trap, not its DSP

`fx_add {kind: "dynamicEQ"}` gives you a FOUR-BAND DYNAMIC EQ — a normal EQ band
whose gain moves on its own once the signal crosses a threshold, so it corrects
only the instant that needs it rather than sitting there full-time like a static
`eq` band. It is 32 parameters, band-major (`slot = (band−1)·8 + p`,
`band1Mode`…`band4ReleaseMs`) — call `fx_describe {kind: "dynamicEQ"}` for the
full table; this section is the traps, not the reference.

**Bells only in v1 — no shelves.** Each band is: `bandNMode` (0 OFF/default — a
TRUE no-op, the band's filter is not even stepped, so a freshly added instance
is bit-for-bit transparent until a band is turned on; 1 ABOVE, triggers when the
level INSIDE THE BAND rises past `bandNThresholdDb`; 2 BELOW, triggers when it
falls under it), `bandNFreq`/`bandNQ` (centre and width), `bandNThresholdDb`/
`bandNRatio` (when and how hard it reacts), `bandNRangeDb` (how far it may move
AND which way — negative cuts, positive boosts, a hard cap), `bandNAttackMs`/
`bandNReleaseMs`.

⭐ **`bandNMode` TIMES THE SIGN OF `bandNRangeDb` IS FOUR MUSICAL MOVES FROM TWO
KNOBS.** above + negative (the default sign) is the familiar de-esser/de-harsh
move — turns the band down when it gets loud; above + positive turns it UP when
it gets loud (upward excitement); below + positive restores air under a fade;
below + negative is one-band downward expansion for mic rumble between phrases.

⚠️ **`bandNMode: 2` (below) SITS AT FULL RANGE ON SILENCE, AND THAT IS CORRECT,
NOT A BUG.** Digital silence reads as −180 dBFS inside the band, which is below
every threshold, so a `below` band is always fully triggered by silence — exactly
what an expander does to silence.

#### This `Q` is not `eq`'s `Q`, measured, not a rounding difference

⚠️⚠️ **AN AGENT PORTING A `Q` SETTING FROM `.eq` WILL BE WRONG.** At 1 kHz, `Q: 2`,
a `dynamicEQ` band measures about **704 Hz** wide at half-gain where an `eq`
peaking band at the same `Q` measures about **498 Hz**. `dynamicEQ`'s band also
WIDENS as it works harder (592 / 704 / 993 / 1401 Hz at 3 / 6 / 12 / 18 dB of
movement) while `eq`'s band stays a fixed width at any gain. That is the
deliberate price of this kind's topology — the band's poles do not move with its
gain, which is what lets the gain change every sample without clicking — not an
implementation gap to close.

#### No `mix`, no lookahead, no meter — and that is three separate decisions

⛔ **NO PER-BAND `mix`.** A band at `bandNRangeDb: 0` already does nothing,
bit-for-bit, so a second blend control would be a redundant knob computing the
same thing a different way.

⭐ **ZERO LATENCY AT EVERY SETTING OF EVERY PARAM**, because there is no
lookahead. A very fast `bandNAttackMs` still cannot act before the sound
arrives — that is the trade for adding nothing to `latencySamples` and shifting
nothing in the project's timing when you add one.

⚠️ **NO GAIN-REDUCTION METER IN v1** — unlike `compressor`/`limiter`/`gate`,
`fx_add`/`fx_set_param` results carry no `gainReductionDb` for this kind. Poll
`fx_spectrum` during playback instead to see a band's response actually moving.

#### `bandNMode` clamps, does not snap — the `clipper.mode` precedent

⚠️ **`fx_set_param` ON `bandNMode` CLAMPS THE STORED VALUE TO 0–2 BUT DOES NOT
ROUND IT.** A stored `1.5` is not corrected to `1` or `2` in the param itself —
the render thread (and the `bandNModeLabel` echo) SNAP it at read time instead,
exactly the way `clipper.mode` already works on this surface. ⛔ **`phaser.stages`
is NOT this precedent and citing it as one was a measured error** (corrected
2026-09-20): it genuinely SNAPS its STORED value — `PhaserParams`' init runs
`Self.snappedStages(stages)` (`Effects.swift:3012-3015`, commented "SNAPPED, not
merely clamped"), and a write of `5` reads back as **`6`**. This same file says
so at its own `phaser.stages` entry above; the two statements contradicted each
other for several cycles.
Read `band1ModeLabel`…`band4ModeLabel` back from the `fx_add`/`fx_set_param`
result (a STRING, `"off"`/`"above"`/`"below"`, NOT in `fx_describe`) for the
truth the render thread actually uses. **Do not file the clamp-not-snap as a
bug** — it is the documented, deliberate precedent, not an oversight.
`bandNMode` is DISCRETE: automate it with `hold`, never a ramp, and modulation
refuses it outright. `bandNFreq`/`bandNQ` are filter coefficients, so
modulation only WARNS on them (the `eq.peak1Freq` zipper problem) rather than
refusing.

Two more result-echo-only fields, present in `fx_add`/`fx_set_param` results and
`project_snapshot` but **NOT** in `fx_describe`'s schema: `latencySamples`
(always `0`) and `kneeDb` (a fixed `6`, not a param — the compressor's own
default knee, shared rather than re-exposed).

#### The 32-param shape makes the shared 64-slot budget a REAL risk, not a style note

⚠️⚠️ **AUTOMATION LANES AND MODULATED EFFECT PARAMS SHARE ONE 64-ENTRY CAP PER
MIXER STRIP**, and one fully-automated `dynamicEQ` instance is 32 of them — HALF
a strip's entire budget, on its own, before any other effect on that strip is
touched.

⛔ **THE TWO TOOLS THAT SPEND THIS BUDGET DISAGREE ON WHAT HAPPENS PAST IT, AND
THAT ASYMMETRY IS THE ACTUAL TRAP.** `mod_add_route` checks the combined total
before adding and REFUSES past the cap, naming both contributors so nothing is
silently lost. `automation_add_lane` does **NOT** perform this check — it
appends unconditionally and returns success every time. The cap is enforced
later, on the render side: `AutomationSchedule`'s build keeps only the FIRST 64
effect-param tracks (`AutomationSchedule.swift`, `maxEffectParamTracks = 64`,
`.prefix(64)`) and drops everything past that with **no error and no warning
anywhere on the wire**. A 65th lane an agent adds via `automation_add_lane` gets
a normal success response and then simply never reaches the render thread —
this tree's characteristic failure mode of something that looks live and does
nothing. Automate the bands actually being ridden rather than reaching for all
32 params on two instances at once, and if a strip is running close to the cap,
count `automation_add_lane` calls yourself — the tool will not stop you.

### Overlap masks a retrigger. The BUILT-IN SAMPLER slurs for real in `legato`; nothing else does.

⚠️ **CORRECTED TWICE, IN OPPOSITE DIRECTIONS, AND THE SECOND CORRECTION IS THE POINT.**
Before 2026-08-23 this section said "No instrument in this app has a legato mode" — false
then, and an agent following it walked past a shipped feature. `06dca3d` fixed that and
overshot: it announced that `voiceMode: "mono"` meant the sampler "can now really slur".
**It did not.** Mono was voice *stealing* — the old voice went into its release ramp and a
NEW voice started with a **fresh attack**, so a slurred pair still re-tongued on the second
note. Mono decided which note wins; it did not remove the tongue. The mode that actually
removes it shipped 2026-08-31 (m34-t) and is called `legato`.

**Three voice modes on the built-in `sampler`,** via `track_set_instrument`
`{sampler: {voiceMode: …}}` or `instrument_set_sampler_param`. Default stays `poly`.

| mode | one note at a time | new note re-attacks | use it for |
|---|---|---|---|
| `poly` (default) | no | — | everything polyphonic |
| `mono` | yes, last-note priority | **YES — a fresh attack every note** | chopped-sample chokes, hi-hats, a re-tongued lead |
| `legato` | yes, last-note priority | **NO — the sounding voice CONTINUES at the new pitch** | a sax/flute/lead line that must not re-tongue |

**`legato` is the real slur.** The sounding voice keeps its envelope exactly where it is
and only its pitch changes. A **detached** note (one arriving with nothing sounding)
attacks normally, so articulation still reads. ⚠️ **A legato voice does NOT change sample
mid-slur** — it stays on the zone it started on and is retuned against that zone's root
pitch, because a slur is one continuous excitation. Timbre drifts on a very wide slurred
interval; that is the accepted limit, and every hardware mono sampler has it.

**Both mono modes** deliberately do NOT fall back to a note still held underneath, because
the overlap that creates the case is the legato idiom itself and falling back would fire a
phantom backwards slur on every slurred pair. Built for wind lines.

**`glideTime` (seconds, 0–4) is portamento**, and it is a separate half you can use with or
without the slur. Omitted or 0 = the pitch steps, which is what the sampler has always
done. ⚠️ **It needs `voiceMode` `mono` or `legato` and is IGNORED under `poly`** — under
poly there is no single previous note to slide from. Setting it on a poly sampler stores
the value and changes nothing you can hear; `instrument_describe_sampler` reports
`glideEffective: false` and warns. Under `legato` the sounding voice slides with no new
attack; under `mono` the new note attacks but *starts at the previous note's pitch* and
slides — which is how a hardware mono synth does portamento. The slide is even in
**semitones**, not in Hz (halfway through 440→880 Hz you are at 622 Hz), and **pitch bend
composes on top of it**.

**`glideMode` decides what that `glideTime` number MEANS** (m34-w). It takes
`"constantTime"` or `"constantRate"`, and omitting it is `"constantTime"` — the behaviour
above, unchanged.

| `glideMode` | `glideTime` means | a semitone | a whole tone | an octave |
|---|---|---|---|---|
| `constantTime` (default) | seconds for **every** leap | 0.12 s | 0.12 s | 0.12 s |
| `constantRate` | seconds **per whole tone** | 0.06 s | 0.12 s | 0.72 s |

⭐ **Under `constantTime` a wide leap travels faster**, because it covers twelve times the
distance in the same time — so an octave is rushed through while a semitone crawls.
`constantRate` moves the pitch at a fixed **speed**, so distance sets duration: that is
what a trombone slide and a fretless finger actually do, and it is what to reach for on a
line with mixed interval sizes.

⚠️ **THE UNIT IS SECONDS PER WHOLE TONE (2 semitones), not per octave and not per
semitone**, and the choice is calibrated rather than arbitrary. The project owner approved
`glideTime: 0.12` by ear on a sax phrase whose slurs are 2–3 semitones; at this unit that
same 0.12 still gives 0.12 s on a whole tone and 0.18 s on a minor third, so **flipping
the mode keeps the sound they picked**. Per-octave would have made those slurs 0.02–0.03 s
— four to six times faster, which does not read as a slide at all. Duration is
`glideTime × semitones ÷ 2`, and `instrument_describe_sampler` reports the divisor back as
`glideRateReferenceSemitones` so you never have to assume it.

⚠️ **The two modes are indistinguishable on a whole tone and six times apart on an
octave.** Read `glideMode` off `instrument_describe_sampler` rather than inferring it from
a duration you heard once. It needs the same monophonic `voiceMode` `glideTime` does, and
a `constantRate` set with `glideTime: 0` scales nothing — describe warns about exactly
that.

**Everything else still masks.** On the `soundBank` and hosted `audioUnit` paths every
note-on starts a new voice with a fresh attack. There `legatoOverlapBeats` (m27-o) hides
that attack under the previous note's decaying tail — masking, not voice continuation,
and a handoff claiming otherwise is wrong. Those paths flatten note-offs to plain MIDI
with no note id, so voice continuation is not reachable there at all: true legato on them
needs a scripted-legato Audio Unit or new engine work.

**Also new on the built-in sampler:** `bendRangeSemitones` is settable per instrument.
Default is **2.0**, the GM standard that every already-authored bend lane assumes, so a
wide slur must raise it explicitly. Raising it does not retune an unbent note.

⚠️ `BreathContour`'s `bendRangeSemitones` is an AUTHORING figure; the sampler's is a
PLAYBACK figure. They are no longer guaranteed equal, and when they disagree every
generated vibrato is scaled by exactly their ratio.

⚠️ **Same-pitch repeats abut instead of overlapping, deliberately.** On the
sound-bank path a note-off is plain MIDI with no note id, so overlapping a
repeat of the same pitch would let the departing note's off cut the note
that just started. The engine model allows same-pitch overlap (offs pair
by note id) but that id is lost when flattened for a hosted AU, so the
rule that is safe everywhere wins.

### The sustain pedal held everything forever. Now it can be capped.

CC 64 has always been an unlimited latch on both built-ins: every note played
while the pedal is down rings until the pedal comes up. That is right for a
piano. On an organ or pad patch it is how a passage turns into a wall of
sound — the pedal latches note after note and nothing ever stops.

**`pedalHoldLimit` caps how many notes the pedal keeps alive.** Omitted = the
old unlimited behaviour, unchanged, so nothing you have already written moves.

```
track_set_instrument {kind: "sampler",   sampler: {pedalHoldLimit: 6}}   # the sampler's
track_set_instrument {kind: "polySynth", pedalHoldLimit: 6}              # the synth's
instrument_set_sampler_param {param: "pedalHoldLimit", value: 6}         # one-knob form
```

Note the asymmetry, because it will bite otherwise: the **sampler's** cap
lives inside the `sampler` object like every other sampler global, while the
**poly synth's** is a TOP-LEVEL param, like `attack` and `cutoffHz`.

Three facts worth knowing before you set one:

- **The oldest note is RELEASED, not cut.** It fades out through the patch's
  own `release`, so a capped organ hands one chord over to the next instead of
  clicking. A patch with a very short `release` will still sound abrupt — that
  is the envelope's doing, not the cap's, and the fix is a longer release.
- ⚠️ **A key you are still HOLDING DOWN is never taken.** Only notes whose
  keys are already up, kept alive by the pedal alone, can be reclaimed. With a
  cap of 2 you can still hold a five-note chord with your hands.
- **It binds at the next note-on**, not the instant you set it. Setting a cap
  mid-passage never yanks anything already sounding; the passage thins out as
  new notes arrive.

Refused, not clamped, outside **1-128** — at both levels, and the error names
the field path. Any value above the instrument's voice pool (64 sampler, 16
synth) is unreachable and therefore means unlimited. Try 4-8 for an organ or
pad that should breathe; leave it off for piano, where sympathetic ringing is
the point.

⚠️ **No UI knob yet** — this is wire + MCP only. A user cannot set it by hand.

### Bulk composition: Standard MIDI File + `clip_import_midi`, not JSON + `clip_add_midi`

Composing large arrangements as JSON notes is prohibitively expensive. A
twelve-bar blues expressed as notes costs ~30 KB (drums 149 notes / 9.2 KB,
guitar 144 notes / 8.9 KB, …), and a complete arrangement's 5,248 notes
would have been ~330 KB on the wire. Write a Standard MIDI File instead:
that arrangement went in as **45 KB of SMF**, one call per part, with a
per-part note-count report.

**The recipe:** Write a `.mid` file with your preferred tool. Create a MIDI
clip for each part in DAW Pro. Call `clip_import_midi` with `dryRun: true`
first to see which parts are in the file. Then import the part you want by
index.

⚠️ **THE CRITICAL LIMIT:** `clip_import_midi` **replaces the clip's notes
WHOLESALE and never changes the clip's length.** Do not use it to append to
a groove you have already placed — every note in that clip will be silently
deleted and replaced. An agent that reaches for it expecting to extend
material will lose what was there. It is not an additive operation.

To grow the clip after import, call `clip.fitToContent`. If you need true
additive composition, write everything into the SMF and import once. This
is the same wall as `project_snapshot`'s ~290 KB size, approached from the
write side.

### Nobody in this plugin can hear anything

No agent here has ears. Every timbral judgement you make is inference from
names and numbers — so use the numbers, and say plainly when you are
guessing. What is actually measurable:

| Question | Tool |
|---|---|
| Is a signal reaching the master at all? | `project_snapshot`'s `meters`, after `transport_play` |
| How loud is the mix, properly? | `mixer_live_loudness` (live), `render_measure_loudness` (offline BS.1770-4 ground truth) |
| What's the tonal balance right now? | `mixer_master_analysis` (24 bands, centroid/brightness, flux) — needs `transport_play` running first, or it refuses with a teaching error rather than a silent floor reading |
| What does ONE track/effect chain look like spectrally? | `fx_spectrum` |
| What key/tempo/spectral balance is this audio clip? | `clip_analyze_audio` |
| What pitch is this audio, over time? | `clip_detect_pitch` |
| What did the file I just wrote actually contain? | `audio_profile_file` (peak/RMS/DC/silence — explicitly NOT a loudness meter) |
| How does my mix compare to a reference track? | `reference_import` + `reference_compare` |
| Does velocity change this patch's TONE, or only its volume? | `instrument_probe_liveness` |

`instrument_probe_liveness` renders a velocity ladder — the same pitch played
at several ascending velocities — on one instrument track, and measures how
far the spectral CENTROID (brightness, Hz) moved against how far the RMS
(level, dB) moved. Big level spread + flat centroid means velocity is wired
to nothing but a volume knob, which is exactly what makes a lead sound "like
a toy" on an exposed line — a judgement no other tool here can make, because
it is about timbre, not level or loudness. It returns FOUR verdicts, not two:
`static` (level moved, timbre did not), `live` (velocity changes the tone),
`silent` (a rung produced no measurable signal at all), and `inconclusive`
(the ladder never moved the LEVEL enough to test the question — a
velocity-insensitive patch, or a compressor/limiter flattening it). Wire
values are lowercase strings. ⚠️ **`silent` is deliberately NOT `static`** —
"the probe could not measure this" and "the probe measured it and found it
flat" are different diagnoses (silent usually means the instrument is not
loaded, does not cover that pitch, or is muted upstream; do not report it as
a dead patch). ⚠️ **The verdict thresholds are an uncalibrated hypothesis
derived from one instrument family** (the response's `thresholds` carries
`calibrated: false`) — the raw per-velocity `ladder` (rmsDb, centroidHz,
timbreGroup) is always returned specifically so you can read the evidence and
form your own view instead of inheriting the verdict blind. ⚠️ **It measures
LIVELINESS, not quality** — nothing about tuning, articulation, or whether a
sound is pleasant; never quote a `live` verdict as "the instrument sounds
good." It is not an edit (a throwaway dry render, no undo step). Measured
ground truth worth citing: Apple's built-in GM DLS alto sax reads centroid
~2100 / 2099 / 2100 / 2099 Hz across a 28 dB RMS spread across four
velocities — `static`, and the exact patch a user separately called "a toy"
by ear. GeneralUser GS's alto sax, sampled at the same pitch, reads
2237 → 2331 → 2384 Hz — `live`.

⭐⭐ **THOSE FIGURES ARE NOW CONFIRMED LIVE, and confirming them found a real
bug — so the numbers you get today are NOT the ones an older document may
quote.** Measured on staging 2026-08-28 against both real banks:

| bank | ladder (Hz) | spread | verdict |
|---|---|---|---|
| Apple GM DLS alto sax | 2165 / 2167 / 2165 / 2167 | 0.09 % | `static` |
| GeneralUser GS alto sax | 2371 / 2489 / 2557 / 2557 | 7.87 % | `live` |

The GeneralUser reading resolves into **three distinct timbre groups**, with
velocity 95 and 127 sharing one — real velocity layers, visible in
`timbreGroup`.

⚠️ **Until that run, the tool answered `static` for BOTH — it called the
layered saxophone lifeless.** The centroid was power-weighted (|X|²) instead
of the standard magnitude-weighted (|X|), which over-weights the fundamental
and under-weights the upper harmonics — precisely where layers differ. It
compressed a true 6.59 % spread to 0.295 %. Fixed in `TimbreLiveness.centroid`.

⭐ **The lesson worth carrying, because it generalises past this tool: the
probe's own self-check could not catch it.** The control measures pure sines,
and a single-partial signal reads identically under both weightings. **A
control built from a signal simpler than the signal under test can be blind
to an entire class of error while passing perfectly.** Twenty-six passing
tests agreed with it. Only a real instrument disagreed.

So: trust the returned table, and if a reading ever looks implausible for a
patch you have reason to believe in, say so rather than accepting the verdict
— that scepticism is what found this.

`note_audition` is a SIGNAL-PATH check, not a timbre check. `audible: true`
means the strip isn't muted or solo-excluded, the engine is running, and —
for `soundBank`/`audioUnit` instruments — a prepared instrument existed at
that instant. It measures no level and no spectrum. Never A/B two candidate
patches with it and report a tonal preference: you would be inventing the
difference. Pick by program name and documented character, say that is what
you did, and leave the listening to the user.

The reply also carries `instrumentStatus` for those two kinds
("pending"/"ready"/"missing"/"failed: …"). **`audible: true` alongside
`"pending"` means the path is clear but the patch you just set may not have
been what sounded** — retry before trusting it.

### `note_play` is the HELD one, and the only one that records (m23-ct)

`note_audition` releases itself after `durationMs`. `note_play` does not — it
holds until you send `pitches: []`, and it is the ONE note tool that is **not
refused while a take is recording**, because what you play through it goes
INTO the take. That is the whole reason it exists: the user has no hardware
MIDI keyboard, so this is the only path by which a live performance can be
captured at all.

Set semantics, not deltas: each call names the notes that should be sounding
NOW. `[60]` presses middle C, `[60,64,67]` adds two fingers without
re-striking the first, `[]` lifts everything. Repeating a set is a no-op that
keeps the notes alive — it adds nothing to the take.

Three things lose a take, all of them silent:

1. **Forgetting `pitches: []`.** A 30-second hold ceiling, a 3-second engine
   watchdog and `transport_panic` all exist as backstops, but every one of
   them lands the note in the clip with the wrong length.
2. **Playing too soon after `transport_record`.** A take's anchor is
   scheduled slightly ahead of the record call and every note struck before
   it is DROPPED — the same rule that makes count-in work. **Wait ~300 ms.**
   MEASURED: a chord struck at t≈0 vanished entirely while a note struck
   120 ms later landed at beat 0.103.
3. **Not reading `recording` in the reply.** It is the honesty light.
   `false` means the notes SOUNDED AND WENT INTO NO TAKE — not recording,
   not armed, or no MIDI capture. Never report a performance as recorded
   when it came back `false`. `capturedEdges` says how many note-ons/offs
   that call actually put into the take (0 on a repeat, by design).

The recording recipe, in order: `track_set_arm` → `transport_record` → wait
→ `note_play` with real waits between the notes → `note_play {pitches: []}`
→ `transport_stop` → `clip_get_notes` on the clip that landed.

### `play_sustain` is the pedal, and it changes what `note_play []` means (m34-l)

`play_sustain {trackId, down}` is the damper pedal, MIDI CC 64. It is the
answer to *"why does the note stop the moment I let go of the key"* — a piano's
felt dampers fall on key release, and the pedal holds them off.

**With `down:true`, `note_play {pitches: []}` no longer silences anything.**
The notes keep ringing; the empty set only says the KEYS are up. That is the
feature, not a bug, and it is the one thing to hold in your head when you
interleave the two tools. Sending `down:false` releases everything the pedal
was holding, while anything still in your `note_play` set keeps sounding.

- **ALWAYS LIFT IT (`down:false`) WHEN YOU ARE DONE.** A pedal left down is a
  drone with no visible cause. Lifting is never refused — not on the wrong
  kind of track, not on a track that no longer exists.
- **`down` in the reply is the STATE AFTER the call, not an echo.** A press
  onto a track whose instrument is not loaded comes back `false` with a
  `reason`. `pushed:false` means the pedal was already in that state and
  nothing was sent — an honest no-op.
- **`recording` is the same honesty light `note_play` carries.** `false` means
  the pedal moved and went into NO take.
- **MEASURED SUPPORT, not inferred:** the built-in poly synth, the built-in
  sampler and the hosted sound-bank (SoundFont/DLS) instruments all honour
  CC 64. Hosted Audio Units receive it and honour it if the plugin does.

The app lifts it for you at the start of a take, at the end of a take, on
`transport_panic`, and when a project closes — so it cannot outlive the take it
was pressed in. The human shortcut for the same pedal is **Tab**, while Musical
Typing is on.

## There is no `deEsser` kind — the de-esser is a MODE on `compressor`

This section exists because of a specific, predictable wrong turn: you will be
asked to "de-ess the vocal", you will call `fx_describe`, you will scan the kind
list for `deEsser`, you will not find it, and you will reach for an EQ instead.
An EQ is the wrong tool — it dulls the whole vocal permanently to fix a sound
that happens for 80 milliseconds at a time.

**A de-esser IS a compressor.** Same `thresholdDb`, `ratio`, `attackMs`,
`releaseMs`. The only difference is that the part which DECIDES when to turn
down listens to a filtered copy of the signal instead of the whole thing. So it
ships as three appended params on `compressor`:

| param | what it does |
|---|---|
| `detectorMode` | `0` **off, the default** · `1` band-pass detector · `2` high-pass detector |
| `detectorFreqHz` | band centre (mode 1) or corner (mode 2). Default 6500. Park it on the "sss" — 5000–9000 Hz on most voices |
| `detectorQ` | mode 1: the band's WIDTH (bandwidth = freq ÷ Q). mode 2: the corner's RESONANCE |

A working starting point, and the whole recipe:

```
fx_add     { trackId: <vocal>, kind: "compressor", params: {
               thresholdDb: -28, ratio: 6, attackMs: 1, releaseMs: 60,
               detectorMode: 1, detectorFreqHz: 6500, detectorQ: 2 } }
```

Then move `thresholdDb` — **that** is the "how much de-essing" knob, not
`ratio`.

### The four things that actually catch people

- **`detectorMode` 0 is not "a gentle de-esser", it is OFF.** Every compressor
  in every project that predates this feature decodes to 0 and renders
  bit-for-bit what it always did. If you set the frequency and the Q but forget
  the mode, you have changed nothing at all — and nothing will warn you, because
  those two params are legitimately inert at mode 0.

- **⛔ It is WIDEBAND, not split-band, and this is the one that surprises
  people.** When the detector fires, the **whole signal ducks** — lows included
  — for as long as the "sss" lasts. It does *not* carve the sibilant band out
  and leave the rest playing. That is inaudible on a solo voice (an "s" is
  short, and the lows under it are not what anyone is listening to) and
  **audible on a full mix, so do not put one on the master bus**. It is also
  exactly why the kind still reports `latencySamples: 0` and cannot shift an
  existing project in time.

- **`detectorQ` means two different things and both are live.** At mode 1 it is
  the band's width, and the band peaks at 0 dB at *every* Q — so widening it
  does not quietly move your threshold. At mode 2 it is the high-pass corner's
  resonance, where the response **at** the corner **is** Q: the default 2 puts a
  deliberate +6 dB emphasis right where sibilance starts, which is why mode 2
  ducks harder than mode 1 at identical settings. Set 0.707 if you want a flat
  corner.

- **With a sidechain key attached, it is the KEY that gets filtered.** The key
  *is* the detector's input, so the two features compose rather than fight:
  `fx_set_sidechain` plus `detectorMode: 1` is "duck this track whenever *that*
  track gets sibilant", in two calls.

### Reading it back

`fx_add` / `fx_set_param` echo `resolvedDetectorMode` (`"off"` / `"bandPass"` /
`"highPass"` — the **snapped** value the render thread uses, so a stored `1.4`
comes back as `"bandPass"`), `detectorBandwidthHz`, `detectorBandwidthApplies`
(0 outside mode 1, because a high-pass has no width) and a constant
`latencySamples: 0`. None of those four is part of `fx_describe`'s schema —
they are per-instance echoes on the insert's `params` object.

### Automating it

`detectorMode` is DISCRETE: automate it with **hold** steps, never a ramp, and
modulation refuses it outright. `detectorFreqHz` and `detectorQ` are filter
corners — modulation **warns** on them, because recomputed biquad coefficients
zipper at any rate (the `eq.peak1Freq` problem, not the rate-aliasing one).
Automating them between sections is fine; an LFO on them is not what you want.

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
`vc_convert_vocals` / `vc_convert_clips` / `vc_train_voice` /
`vc_list_voices` / `vc_import_voice_model` exist on the MCP surface but are
**not** granted to
any agent in this plugin, to keep the roster tight and avoid any ambiguity
around voice content. If a future
version of this plugin adds them (only to `sound-designer`, per the DAW Pro
project's own policy), the **rights-responsibility policy** applies: a
`voiceId` may be trained from the user's own recordings **or** be a
user-supplied third-party voice model — the product does not restrict whose
voice it is, and the **user** bears responsibility for holding the rights to
whatever they use. Do not refuse a voice on provenance grounds. (This
replaces an earlier own-voice-only prohibition that the project owner
withdrew on 2026-07-27. The one thing still out of scope: importing a
user-supplied model file is supported; going and *finding* third-party voice
models at scale is not a feature to build.) The reserved id
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
- **MIDI-learn** (`midi_get_control_map`, `midi_set_control_map`,
  `midi_learn_control`): mapping a hardware knob to a DAW parameter is the
  same human-at-the-instrument category as live recording input —
  `midi_learn_control`'s entire mechanism is "ask the user to turn the knob
  they want," which no agent can do, and the other two exist to serve that
  same physical rig. The mapping table is machine setup, not song content: it
  is not saved with the project.
- **`pad_preview_effort`**: streams ONE live breath-pad value so a gesture can
  be HEARD while it is in progress — nothing is written, no undo step, and
  its entire value proposition is a human listening in real time during a
  drag. No agent here has ears (see "Nobody in this plugin can hear
  anything" above), so this tool cannot do anything useful in an agent's
  hands. The tool that actually commits a shape, `clip_apply_effort_shape`,
  IS granted (to `composer`) and needs no live listener.

## Genre-neutral defaults worth knowing

`macro_song_skeleton` (held by `producer`) scaffolds tempo + a genre's track
roster + section clips + **a marker at every section start** + a loop in one
call, across **fourteen genres**: `pop` (120 BPM), `house` (124 BPM),
`hip-hop` (90 BPM), `rock` (140 BPM), `ballad` (72 BPM), `blues` (84 BPM),
`jazz` (132 BPM), `country` (100 BPM), `r-and-b` (88 BPM), `funk` (108 BPM),
`metal` (170 BPM), `folk` (96 BPM), `reggae` (76 BPM), `lo-fi` (78 BPM).
Each differs in FORM as well as roster — `blues` is twelve-bar, `jazz` is
32-bar head/solos/head, `lo-fi` is Loop A/Loop B rather than verse/chorus.
It's additive — safe to call on an existing project — and a single
`edit_undo` reverts the whole scaffold, markers included.

Three things about its output nobody should be surprised by:

- **The roster is a GENRE template, not the brief.** Almost every genre
  scaffolds a vocal AUDIO track, which cannot host an instrument — dead
  weight on an instrumental brief. (`jazz` is the exception: a combo, so
  every strip is an instrument.) `producer` owns reconciling this
  (`track_add`/`track_rename`/`track_remove`) before reporting the roster.
- **A genre you don't see is not a wall.** `tracks` and `sections` each
  override the genre's default outright, so any roster and any form is
  reachable — keep the nearest `genre` for its tempo and pass your own.
- **Marker names mirror the section names verbatim**, so a layout with two
  verses gives you two markers named "Verse". Disambiguate by beat, not by
  name — the result payload carries both.
