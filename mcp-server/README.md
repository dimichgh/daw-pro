# daw-pro-mcp

A TypeScript [MCP](https://modelcontextprotocol.io) server (stdio transport) that gives AI agents
control of DAW Pro. It does two things:

1. **Bridges to the app.** `src/bridge.ts` connects to the DAW app's control-protocol WebSocket
   (`ws://127.0.0.1:${DAW_CONTROL_PORT}`, default `17600`) and turns MCP tool calls into control
   commands — transport, tracks, and a full project snapshot. See `docs/ARCHITECTURE.md` for the
   protocol.
2. **Calls AI providers directly.** `src/ai.ts` calls Anthropic/OpenAI/Suno over HTTPS for lyrics,
   full-song, and image generation — no DAW app required for these.

The server holds no DAW state of its own; `project_snapshot` always reflects the live app.

## Build & run

```sh
cd mcp-server
npm install
npm run build
npm start          # = node dist/index.js
```

For development, point an MCP client (Claude Code, Claude Desktop, etc.) at
`node mcp-server/dist/index.js` via stdio — see the repo's `.mcp.json`.

Requires Node.js >= 22 (uses the global `fetch` and `WebSocket` — no `node-fetch` or `ws`
dependency).

## Environment variables

Copy `.env.example` (repo root) to `.env` and fill in what you need. Keys are read from the
environment only — never hardcoded, never logged.

| Variable | Default | Used by |
|---|---|---|
| `DAW_CONTROL_PORT` | `17600` | `DawBridge` — port of the app's control WebSocket |
| `ANTHROPIC_API_KEY` | — | `generate_lyrics` (primary provider) |
| `OPENAI_API_KEY` | — | `generate_lyrics` (fallback provider), `generate_image` |
| `OPENAI_TEXT_MODEL` | `gpt-4o` | `generate_lyrics` OpenAI fallback |
| `OPENAI_IMAGE_MODEL` | `gpt-image-2` | `generate_image` |
| `SUNO_API_KEY` | — | `generate_song_suno` |
| `SUNO_API_BASE` | `https://api.suno.com/v1` | `generate_song_suno` |

`generate_lyrics` uses Anthropic if `ANTHROPIC_API_KEY` is set, otherwise falls back to OpenAI if
`OPENAI_API_KEY` is set, otherwise throws telling you to set one of them.

**Note:** the Suno API integration (`generate_song_suno`) is a best-effort, defensively-coded
implementation — Suno's official current endpoint shape has not been verified. See
`docs/AI-INTEGRATIONS.md`, "Research items (M6)". It returns the raw JSON response from Suno as-is
rather than assuming a shape, and surfaces the raw response body on any error.

## Tools

Bridge-backed tools require the DAW app to be running (`swift run DAWApp`); calling one while it
isn't produces an actionable error rather than hanging.

| Tool | Bridge command | Description |
|---|---|---|
| `transport_play` | `transport.play` | Start playback from the current position |
| `transport_stop` | `transport.stop` | Stop playback |
| `transport_seek` | `transport.seek` | Move the playhead to an absolute position, in beats (>= 0) |
| `transport_set_tempo` | `transport.setTempo` | Set tempo in BPM (20–400) |
| `transport_set_loop` | `transport.setLoop` | Enable/disable loop playback between startBeat and endBeat (beats); omitted bounds keep their previous value |
| `transport_set_punch` | `transport.setPunch` | Enable/disable punch recording between inBeat and outBeat (beats); when enabled, `transport_record` captures only audio inside the window; omitted bounds keep their previous value; cannot change while recording |
| `transport_set_metronome` | `transport.setMetronome` | Enable/disable the metronome click (downbeat accented); `countInBars` (0–4) sets bars of count-in clicks before recording; count-in clicks sound even if the metronome is off and are never part of the recorded take; cannot change while recording |
| `transport_record` | `transport.record` | Start recording onto all armed tracks while starting playback (capture + play): default audio input into takes on armed audio tracks, and live MIDI into a MIDI clip on armed instrument tracks — one take, one undo step; punch in/out trims audio only, MIDI captures the full roll; only valid while stopped, stop with `transport_stop` |
| `track_add` | `track.add` | Add a track (`kind`: `audio` \| `instrument` \| `bus`, default `audio`); `bus` creates a mix bus destination that other tracks route into via `track_set_output`/`track_add_send` |
| `track_remove` | `track.remove` | Remove a track by id |
| `track_rename` | `track.rename` | Rename a track |
| `track_set_volume` | `track.setVolume` | Set linear gain, 0–2 (1 = unity gain / 0 dB) |
| `track_set_pan` | `track.setPan` | Set stereo pan, -1 (hard left) to 1 (hard right) |
| `track_set_mute` | `track.setMute` | Mute/unmute a track |
| `track_set_solo` | `track.setSolo` | Solo/unsolo a track |
| `track_set_arm` | `track.setArm` | Arm/disarm a track for recording; works on audio tracks (mic input) and instrument tracks (live MIDI thru + capture, fed from all online sources — see `midi_list_inputs`); first audio arm may trigger the macOS microphone-permission prompt; bus tracks cannot be armed |
| `track_set_instrument` | `track.setInstrument` | Select/edit an instrument track's instrument (`testTone` \| `polySynth` \| `sampler` \| `audioUnit`, default `polySynth`/saw); partial update — omitted fields keep current values; numeric params clamp to safe ranges; `sampler` (zones + oneShot/attack/release/gain) replaces the sampler config wholesale when provided; `audioUnit` (`{type?, subType, manufacturer}` FourCC triple from `instrument_list_audio_units`) selects a hosted AU instrument and implies `kind: "audioUnit"`; unknown components error readably, AU preset state persists in the project, and a missing AU on reopen loads with snapshot status `"missing"` |
| `instrument_list_audio_units` | `instrument.listAudioUnits` | List installed Audio Unit instrument plugins (music devices): name, manufacturerName, component triple (type/subType/manufacturer FourCC strings, e.g. `aumu`/`dls `/`appl` for Apple's DLSMusicDevice), version, isV3; use the triple with `track_set_instrument`'s `audioUnit` param |
| `fx_add` | `fx.add` | Insert an effect into a track/bus's PRE-FADER insert chain (`kind`: `gain`, `eq`, `compressor`, `limiter`, `reverb`, `delay`, `saturator`, `gate`, `chorus`, `bassEnhancer`, `bitCrusher`, `djFilter`, `ringMod`, `flanger`, `hallReverb`, `tapeDelay`, `stereoWidth`, or `phaser`); array order = processing order; `index` sets/clamps the insert position (omit to append); `params` seeds parameter values by name (see `fx_describe`); capped at 16 effects per track/bus; never interrupts playback; returns `{effectId, effects}` |
| `fx_remove` | `fx.remove` | Permanently remove an effect from a track/bus's insert chain by id; reversible with `edit_undo`; returns the updated chain (`effects`) |
| `fx_reorder` | `fx.reorder` | Move an effect to a new zero-based position in its track/bus's insert chain (array order = processing order); `index` clamps into range; never interrupts playback; returns the updated chain (`effects`) |
| `fx_set_bypass` | `fx.setBypass` | Bypass or re-enable an effect in place (keeps it in the chain with its params intact); takes effect instantly, never interrupts playback; returns the updated chain (`effects`) |
| `fx_set_param` | `fx.setParam` | Set one named parameter on an effect already in the chain (e.g. a gain stage's `gain`, a compressor's `ratio`, a limiter's `ceilingDb`); names/ranges/defaults/units are discoverable via `fx_describe`; out-of-range values clamp; applies live without interrupting playback; returns the updated chain (`effects`) |
| `fx_describe` | `fx.describe` | Look up the parameter schema (`{name, min, max, default, unit}`) for one or every available effect `kind`; omit `kind` to list all; available: `gain` (linear gain stage), `eq` (4-band parametric — low shelf, two peaking bands, high shelf), `compressor` (soft-knee, stereo-linked dynamics), `limiter` (lookahead brick-wall, adds 5 ms latency — see `project_snapshot`'s `latencySamples`), `reverb` (Freeverb-style room — roomSize/damping/mix/preDelayMs/width; ⚠️ `roomSize` is a DECAY control, not a size — the comb lengths are compile-time constants so this room has exactly one shape forever — and one `damping` setting covers the whole spectrum; use `hallReverb` when you need a real size, a decay in seconds, or separate bass/treble decay times. NOT deprecated: its small, bright, dense room is its own sound), `delay` (stereo echo — timeMs/feedback/mix/pingPong/highCutHz; `feedback` reaches 0.999 = an ECHO FREEZE, the repeats hold instead of fading — it stops short of 1.0 because at exactly 1.0 the loop grows without bound, measured, and at that ceiling `highCutHz` is what bounds the tail), `saturator` (tanh drive color — driveDb/mix/outputDb), `gate` (noise gate — thresholdDb/attackMs/holdMs/releaseMs), `chorus` (2-voice modulated thickener — rateHz/depthMs/mix), `bassEnhancer` (psychoacoustic sub harmonics — synthesizes the 2nd/3rd/4th partials of the sub-crossover content so a speaker that cannot reproduce the fundamental still implies it; NOT the broadband `saturator`), `bitCrusher` (SP-1200 / MPC60 lo-fi sampler character — bit-depth + sample-rate reduction, deliberately no anti-aliasing and no dither, because the aliasing IS the reference sound), `djFilter` (club / DJ-mixer sweep — ONE bipolar knob, `position` 0 is a bit-exact dry centre, negative sweeps a low-pass down, positive sweeps a high-pass up), `ringMod` (ring modulator — the metallic/bell/sci-fi-voice sound; multiplies the signal by a tone at `carrierHz` so every partial `f` becomes the PAIR `|f − carrierHz|` and `f + carrierHz`, i.e. a harmonic sound comes out inharmonic; under ~20 Hz it is a tremolo instead, and the clangorous fold-back at high carrier settings is deliberate character — pull `inputHighCutHz` to ~4000 for a cleaner bell), `flanger` (feedback flanger, the jet-plane whoosh — one swept comb filter; `delayMs` is the sweep FLOOR and the sweep moves only UPWARD from it, so a `depthMs` larger than `delayMs` is safe rather than broken; the first notch sits at 1/(2*delay) and every `fx_add`/`fx_set_param` result echoes it as `firstNotchHzAtSweepFloor` inside that insert's `params` (a per-instance echo, NOT part of `fx_describe`'s schema); `feedback` is BIPOLAR — negative inverts the response into a hollow metallic character — and it changes level, (1-mix) + mix/(1-feedback) on a steady tone), `hallReverb` (8-line FDN hall — the reverb that has an actual SIZE: `sizeMeters` 1–60 scales the delay-line lengths, `decaySeconds` is a real RT60 in seconds, `lowDecayMultiplier`/`highDecayMultiplier` give bass and treble their own decay times around `lowCrossoverHz`/`highCrossoverHz`, `modRateHz`/`modDepthMs` are the anti-metallic tail modulation, `freeze` ≥ 0.5 is infinite hold; `highDecayMultiplier` defaults to 0.5 rather than 1 because real air absorbs highs and a reverb with no HF damping is what "metal tank" means; ⚠️ moving `sizeMeters` while a tail is sounding gives a smooth Doppler glide), `tapeDelay` (tape echo, FREE-MS ONLY — timeMs/feedback/mix/wowDepthMs/wowRateHz/flutterDepthMs/saturationDrive/highCutHz: the echo whose repeats WOBBLE IN PITCH, which `delay` structurally cannot do — it reads its line at whole-sample offsets only, so a sub-sample drift is unrepresentable there. `wowDepthMs` is the slow motor drift and is the identity; every `fx_add`/`fx_set_param` result echoes the pitch deviation each setting causes as `wowCents`/`flutterCents` inside that insert's `params` (per-instance echoes, NOT part of `fx_describe`'s schema), so you can ask for a stated amount of wobble instead of guessing. `saturationDrive` 0 is EXACTLY linear; `highCutHz` sits in the RECORD path, so unlike `delay` even the FIRST repeat is already rolled off. ⛔ NO tempo sync on this kind in v1 — `delay` is the one with `sync`/`division`), `stereoWidth` (mid/side widener and mono-maker — `width`/`spread`/`bassMonoHz`/`bassMonoAmount`: the one effect whose headline is a GUARANTEE rather than a sound, because it touches only the side channel and so its mono fold-down is arithmetically identical to its input's at every setting — unlike a Haas delay or a polarity-flipped duplicate, which widen on speakers and then collapse on a phone. `width` scales the stereo difference you already have and costs nothing, but ⚠️ does NOTHING on a mono source, and ⛔ `width` 0 ALONE IS NOT A MONO-MAKER — `spread` defaults to 0.3 and builds a new side channel *after* `width` has scaled the old one, so folding a track to dead centre needs `width` 0 AND `spread` 0 together; `spread` manufactures a new side channel out of the centre through a four-stage all-pass chain and is the true-pseudo-stereo control, at the cost of a per-channel ripple that every `fx_add`/`fx_set_param` result echoes as `channelPeakDb`/`channelNotchDb` inside that insert's `params` (per-instance echoes, NOT part of `fx_describe`'s schema); `bassMonoHz`/`bassMonoAmount` keep the low end centred at 12 dB/oct and are ON by default. ⛔ NO `mix` on this kind — a dry/wet blend on a mid/side widener is algebraically just another `width`; the neutral BIT-EXACT position is `width` 1, `spread` 0, `bassMonoAmount` 0), `phaser` (swept all-pass phaser — `rateHz`/`centerHz`/`depthOctaves`/`stages`/`feedback`/`mix`/`stereoPhaseDeg`: ⛔ **NOT a flanger**, and that is the only thing anyone gets wrong about it. A flanger sums with a DELAYED copy and puts DOZENS of evenly spaced notches in at 1, 3, 5, 7 × a base frequency — metallic, jet-like. This kind has no delay line: it sums with a PHASE-SHIFTED copy and puts in exactly `stages` ÷ 2 notches — a handful — UNEVENLY spaced and spreading apart as they climb. Few, uneven, spreading is the soft vocal “wow” a phaser is for. `stages` is therefore the notch COUNT control, EVEN numbers only (an odd value snaps to the nearer even one, and the snapped value is what comes back). `centerHz` is where the sweep bottoms out and is NOT itself a notch — the lowest notch sits well below it — and every `fx_add`/`fx_set_param` result echoes `notchCount`/`firstNotchHz` inside that insert's `params` (per-instance echoes, NOT part of `fx_describe`'s schema). `depthOctaves` 0 FREEZES the sweep into a fixed notch filter, which is a real setting; `feedback` is bipolar, sharpens the peaks between notches, and ⚠️ changes the LOUDNESS; `mix` 0 is a BIT-EXACT bypass and 0.5 is where the notches are deepest. ⚠️ `mix` 1 with `feedback` 0 is very nearly INAUDIBLE and that is correct — an all-pass chain alone changes no frequency's level, so with no dry signal to cancel against there is nothing to hear) |
| `track_set_output` | `track.setOutput` | Route a track's main output into a bus track, or back to the master mix (omit/null `busId`); bus tracks always output to master; returns `{trackId, outputBusId, sends}` |
| `track_add_send` | `track.addSend` | Add a post-fader send (parallel, after the track's own volume/mute) from a track into a bus track, e.g. a shared reverb bus; one send per destination bus per track; `level` (0-2 linear, default 1) clamps; returns `{trackId, outputBusId, sends}` with the new send's server-minted id |
| `track_set_send` | `track.setSend` | Change an existing send's level in place, without interrupting playback; returns `{trackId, outputBusId, sends}` |
| `track_remove_send` | `track.removeSend` | Permanently remove a send by id; returns `{trackId, outputBusId, sends}` |
| `midi_list_inputs` | `midi.listInputs` | List connected MIDI input devices/sources (hardware keyboards, virtual sources): uniqueID (stable Int32 identity), name, isVirtual, isOnline; all online sources feed armed instrument tracks automatically (omni) |
| `input_list_devices` | `input.listDevices` | List available audio input devices (uid, name, sampleRate, channelCount, isDefault) |
| `input_set_device` | `input.setDevice` | Pin recording to an input device by uid (omit to revert to the system default); takes effect on the next `transport_record`, cannot change mid-recording |
| `clip_add_audio` | `clip.addAudio` | Import an audio file (wav/aiff/mp3/m4a) as a clip on an audio track; length auto-computed from file duration at current tempo |
| `clip_add_midi` | `clip.addMIDI` | Create a MIDI clip on an instrument track and write its notes in one call (pitch, velocity, startBeat relative to the clip, lengthBeats); returns the clip with server-minted note ids, notes normalized/sorted; silent until an instrument lands (M3) |
| `clip_set_notes` | `clip.setNotes` | Replace a MIDI clip's entire note array — the only note-editing primitive; one call = one undo step; errors on audio clips |
| `clip_remove` | `clip.remove` | Permanently remove a clip (audio or MIDI) from its track by id; reversible with `edit_undo`; returns the removed clip |
| `mixer_set_master_volume` | `mixer.setMasterVolume` | Set master output linear gain, 0–2 (1 = unity gain / 0 dB) |
| `render_mixdown` | `render.mixdown` | Bounce the session offline to a stereo 48 kHz WAV file; returns `{path, durationSeconds, sampleRate, channels}` |
| `project_save` | `project.save` | Save the session as a self-contained `.dawproj` bundle (project.json + copied media/); omit `path` to save in place; incremental re-saves; returns `{path, mediaFilesCopied, warnings}`; cannot save while recording |
| `project_open` | `project.open` | Open a `.dawproj` bundle, replacing the current session; unsaved changes auto-saved first unless `discardChanges`; returns `{warnings, snapshot}`; refuses while recording or if the project was saved by a newer app version |
| `project_new` | `project.new` | Start a fresh empty untitled session; unsaved changes auto-saved first unless `discardChanges`; returns the new empty snapshot; refuses while recording |
| `edit_undo` | `edit.undo` | Revert the most recent document edit (track/clip/mixer/tempo/loop/punch/metronome — not playback position); returns `{undone, snapshot}`; errors "nothing to undo"; refuses while recording |
| `edit_redo` | `edit.redo` | Reapply the most recently undone edit; returns `{redone, snapshot}`; errors "nothing to redo"; redo history clears once a new edit is made after an undo |
| `project_snapshot` | `project.snapshot` | Full session state: transport, tempo, master volume, tracks (each with routing: `outputBusId` and `sends` — see `track_set_output`/`track_add_send` — plus a PRE-FADER `effects` insert chain, an ordered array of `{id, kind, bypassed, params, latencySamples}` capped at 16 — see `fx_add`/`fx_remove`/`fx_reorder`/`fx_set_bypass`/`fx_set_param`/`fx_describe`), clips (MIDI clips carry a `notes` array: pitch, velocity, startBeat relative to the clip, lengthBeats; audio clips don't), live `meters` (peak/RMS) for master + each track — bus tracks meter here too, like any other track, `lastRecordingError` (null on success, else a string explaining the last `transport_record` take's failure), `undoLabel`/`redoLabel` (preview of what `edit_undo`/`edit_redo` would do, null if none), and optionally `midiInputs` (same shape as `midi_list_inputs`) and `midiEventCount` (monotonic counter of received MIDI events, pollable to detect live MIDI activity) |
| `generate_lyrics` | — (Anthropic/OpenAI) | Section-labeled lyrics from a theme (+ optional style/structure) |
| `generate_song_suno` | — (Suno) | Full song generation from a prompt (+ optional lyrics/instrumental) |
| `generate_image` | — (OpenAI) | Generate an image, saved as a PNG under `assets/generated/`, returns the file path |

Every tool returns its result as JSON text content; on failure it returns `isError: true` with a
human-readable message instead of throwing across the MCP boundary.

## Broadcast events

Besides request/response frames, the app also pushes unsolicited broadcast frames to every
connected control client, e.g.:

```json
{"event": "transport", "transport": {"playing": true, "positionBeats": 4, "loop": {"enabled": true, "startBeat": 0, "endBeat": 8}}}
```

These carry no `id` and are not replies to any tool call; `DawBridge` recognizes the `event` field
and silently ignores them (no pending request is resolved/rejected, nothing is logged).
