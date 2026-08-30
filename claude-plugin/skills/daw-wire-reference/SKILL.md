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
`mcp-server/src/server.ts` (**196 tools**, re-derived 2026-08-29 at the
m24-m leg A close, which added `vc_convert_clips`; previously 195 at the
m32-b2 close: the MCP tool↔command bijection test,
`mcp-server/test/audit-tools.test.ts`, defines
`tool count = commands + |exception table B| + |exception table C|` — 191
commands (below) + 3 Table-B tools with no backing command at all
(`generate_image`, `generate_lyrics`, `generate_song_suno` — they call a
generation provider directly) + 2 Table-C tools that bridge to an EXISTING
command, `track.setInstrument`, under a friendlier name/shape
(`instrument_set_sampler_param`, `instrument_set_sampler_zones`) = 196.
⚠️ The authoritative pin is `mcp-server/test/integration.test.ts`'s
`assert.equal(result.tools.length, 196)` — **NOT** a `grep -c 'registerTool('`,
which is a known liar on this file and previously anchored this paragraph at a
stale 194) and
`Sources/DAWControl/Commands.swift`
(**194 commands** — the `CommandRouter.allCommands.count == 193` pin in
`Tests/DAWControlTests/RenderCommandTests.swift`)
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

### Overlap masks a retrigger. The BUILT-IN SAMPLER can now really slur; nothing else can.

⚠️ **CORRECTED 2026-08-23 (`06dca3d`). This section used to say "No instrument in this
app has a legato mode". That is FALSE now, and an agent following the old wording would
walk straight past a shipped feature to a workaround.**

**The built-in `sampler` has a real monophonic mode.** `track_set_instrument` with
`{sampler: {voiceMode: "mono"}}` gives LAST-NOTE priority: an overlapping note takes
over the airstream instead of opening a second voice — voice *stealing*, not masking.
It deliberately does NOT fall back to a note still held underneath, because the overlap
that creates the case is the legato idiom itself and falling back would fire a phantom
backwards slur on every slurred pair. Built for wind lines. Default stays `poly`.

**Everything else still masks.** On the `soundBank` and hosted `audioUnit` paths every
note-on starts a new voice with a fresh attack. There `legatoOverlapBeats` (m27-o) hides
that attack under the previous note's decaying tail — masking, not voice continuation,
and a handoff claiming otherwise is wrong. True legato on those paths needs a
scripted-legato Audio Unit or new engine work.

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
