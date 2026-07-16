# Features — DAW Pro

A comprehensive matrix of capabilities, state, and roadmap status. Everything below works in the running app **and** over the control protocol unless marked otherwise.

## Tracks & Recording

| Feature | Status | Notes |
|---------|--------|-------|
| **Track kinds** | ✅ Shipped | Audio, instrument, bus. One way to route: audio/instrument→master or bus→master. |
| **Add/remove tracks** | ✅ Shipped | `track.add` (kind + name), `track.remove`. UI: the + button in Arrange. |
| **Rename track** | ✅ Shipped | `track.rename` command + in-app inline rename (double-click the track name or use the context menu; m10-i). |
| **Track color badges** | ✅ Shipped | Signal-green (audio), playback-cyan (instrument), neutral (bus). Violet badge + border for AI-generated tracks. |
| **Volume per track** | ✅ Shipped | Long-throw fader in mixer, or `track.setVolume` command. Range: −72…+24 dB. |
| **Pan per track** | ✅ Shipped | Pan knob in mixer (center = stereo, ±100% = mono L/R), or `track.setPan` command. |
| **Mute/Solo** | ✅ Shipped | Buttons in mixer (red/cyan glow). `track.setMute`, `track.setSolo` commands. Solo follows multi-solo rule (click again to unsolo). |
| **Arm for recording** | ✅ Shipped | Amber button glows while armed. `track.setArm` command works on audio and instrument tracks. |
| **Latency compensation (PDC)** | ✅ Shipped | Automatic delay compensation when effects have latency. Reads AU plugin latency and inserts compensating delay. No manual latency setting in v0. |

## Recording & Playback

| Feature | Status | Notes |
|---------|--------|-------|
| **Record audio** | ✅ Shipped | Mic input, routed through your chosen input device. Microphone permission required (prompted at first use). |
| **Record MIDI** | ✅ Shipped | From a connected keyboard, live thru while armed or rolling. Lands in the same undo step as audio on the same "Record Take N". |
| **Input device selection** | ✅ Shipped | `input.listDevices`, `input.setDevice` commands. UI: Settings, or wire command. |
| **MIDI input devices** | ✅ Shipped | `midi.listInputs` command. Shows all CoreMIDI sources (hardware + virtual). Hot-plugging works. |
| **Punch in/out** | ✅ Shipped | `transport.setPunch` command. Audio capture trims to the window; MIDI notes record freely over the window (can be edited after). |
| **Metronome/click** | ✅ Shipped | Count-in with bar-length stepper (m15-b rider), steady click (audible). `transport.setMetronome` command. |
| **Play, stop, seek** | ✅ Shipped | `transport.play`, `transport.stop`, `transport.seek` commands. UI: PLAY/STOP buttons + position readout. |
| **Space-bar transport** | ✅ Shipped | A bare space press at the main window toggles play/stop (identical to the transport buttons; stopping while recording stops the take). A space typed while renaming a track/marker or writing to the Copilot inserts a space and never touches transport. Key-repeat, modifier chords (⌘Space stays Spotlight's), and floating plugin windows are ignored. The play button's tooltip advertises "(space)". |
| **Timeline pointer gestures** | ✅ Shipped | Hover the arrange playhead for an open-hand grab (narrow strips over each track's clip band); drag scrubs the transport per tick. Hover empty lane space for a faint ghost line at the snapped beat; click seeks there. Everything follows the SNAP setting (Bar-locked in Simple), ⌥ bypasses for fine placement. Clips and take lanes always win the pointer — gestures can never steal a clip drag. Double-click split refusals surface in an amber bubble carrying the exact wire error text. |
| **Tempo** | ✅ Shipped | `transport.setTempo` command (single-tempo projects), or `tempo.map` / `tempo.setMap` (multi-segment tempo maps + meter changes). UI: inline editable BPM in transport bar, plus tempo/meter lane in the arrange ruler. Range: 20–400 BPM. |
| **Loop region** | ✅ Shipped | `transport.setLoop` command + interactive loop ruler in the arrange (drag to create, edge-resize, move, click to toggle; m10-g). Seamless playback (m14): MIDI, automation, metronome, and fades wrap without clicks or resets. |
| **Sample-accurate playback** | ✅ Shipped | Multitrack audio + MIDI, host-time-aligned from the engine clock. No round-trip latency compensation in v0 (comes with PDC in M4). |

## Audio Editing

| Feature | Status | Notes |
|---------|--------|-------|
| **Import audio files** | ✅ Shipped | WAV, AIFF, MP3, M4A. `clip.addAudio` command. UI: drag & drop or "Add" menu. Media copied into `.dawproj` bundle. |
| **Clip gain** | ✅ Shipped | Per-clip volume boost/cut (−72…+24 dB). Cyan dB chip on hover/select in Arrange, or `clip.setGain` command. |
| **Clip fades** | ✅ Shipped | Fade-in, fade-out with two curve types (linear or equal-power). Set via triangular grips in Arrange or `clip.setFades` command. Range: 0…clip length. |
| **Clip start offset** | ✅ Shipped | Trim the beginning of a clip without splitting. Drag the left edge or use `clip.trim`. Persisted separately from the source file. |
| **Clip move** | ✅ Shipped | Drag the clip body to a new beat position. Snap grid applies. Or `clip.move` command. |
| **Clip split** | ✅ Shipped | Double-click a clip in Arrange to split at that point. Or `clip.split` command. |
| **Clip duplicate** | ✅ Shipped | Copy a clip with all properties (fades, gain, stretch, envelope). `clip.duplicate` command (m15-d). MIDI clips: note IDs are duplicated verbatim — a duplicate of a MIDI clip shares the same note IDs as the original (identity-free by design). |
| **Arrange bars insert/delete** | ✅ Shipped | Project-wide insert/delete bars, shifting clips, markers, tempo/meter, automation, loop (m15-d). One undo step. |
| **Time-stretch** | ✅ Shipped | Change a clip's timeline length while keeping pitch — via Option+drag right edge in Arrange or `clip.setStretch` command. Range: 0.25×–4×. Stretches outside 0.75–1.5× amber-tint as a soft warning. |
| **Time-stretch quality** | ✅ Shipped | Uses a professional time-domain stretcher (Signalsmith Stretch library). Offline renders only (UI clip doesn't preview stretched audio live). |
| **Transient detection** | ✅ Shipped | `clip.detectTransients` command — spectral-flux analysis of an audio clip. Detects onsets (useful for quantize, comping, alignment). Cached per source file. |
| **Audio quantize** | ✅ Shipped | Destructive quantize of transients to a grid. `clip.quantizeAudio` command. Slices at onsets, nudges slices to the grid (with crossfades), and replaces the clip. Grid, strength, swing, sensitivity all configurable. |
| **Humanize MIDI** | ✅ Shipped | Seeded random timing + velocity jitter for MIDI clips. `clip.humanize` command with deterministic seed (for reproducibility). |

## MIDI & Instruments

| Feature | Status | Notes |
|---------|--------|-------|
| **MIDI clips** | ✅ Shipped | Notes with pitch, velocity, start beat, length. Mutually exclusive with audio on a clip. Stored canonically ordered. |
| **Add/edit/delete MIDI notes** | ✅ Shipped | Piano roll: click to add, drag to move/resize, double-click to delete. Or `clip.setNotes` command (whole-clip note array). Velocity lane in Pro mode. |
| **Piano roll** | ✅ Shipped | 32 pt/beat grid. Pitch rows (white/black keys, octave labels). Simple mode: add/move/delete only, beat-locked snap. Pro mode: velocity lane, snap picker, all edit gestures. |
| **Snap grid** | ✅ Shipped | Off / Bar / Beat / 1/8 / 1/16 (default Beat). Applies to clip move/trim and MIDI note editing. Set via SNAP chip in Arrange/Piano roll header. |
| **Built-in synth** | ✅ Shipped | 16-voice subtractive poly synth. Oscillators: saw, square, triangle, sine. Filter: Simper SVF low-pass. ADSR envelope. RT-safe, in-place parameter changes while playing. |
| **Built-in sampler** | ✅ Shipped | Map audio files to keyboard zones (key spans + pitch offset + gain). Pitched playback via linear-interp resampling. One-shot or looped. Zone media bundled in `.dawproj`. |
| **AudioUnit instruments** | ✅ Shipped | Host any AU instrument (DLSMusicDevice, AUSampler, third-party). Async prepare with timeout-race failover to placeholder. Full state persisted in `.dawproj` (base64). `instrument.listAudioUnits` command. |
| **Plugin UI windows** | ✅ Shipped | Open custom UIs for AU instruments + effects. Glass-chrome window frame (cyan/neutral, never violet). Generic AU editor as fallback. `plugin.openUI`, `plugin.closeUI`, `plugin.listOpenUIs` commands. |
| **Free AU instruments guide** | ✅ Shipped | `docs/FREE-INSTRUMENTS.md`: eleven verified free AU instruments with install gotchas, the honest "can I use Logic's instruments?" answer (no — app-internal), what DAW Pro ships built-in, and a worked example. Surge XT and Dexed verified sounding through the full host chain. Shell instruments (Kontakt/Reaktor/Splice INSTRUMENT) load but need content before they sound. Newly installed AUs appear after relaunch (discovery at launch). |
| **MIDI CC (control change)** | ✅ Shipped | MIDI clips carry controller lanes (CC, pitch bend, channel pressure) with stepwise semantics and chase-at-build playback (m16-b). Authored over `clip.setControllerLane` / `clip.removeControllerLane`. Piano roll has a CTRL strip (Pro density) for drawing lanes with labeled value readout. Live MIDI input passes controllers through; recording captures them. MIDI learn is not yet available. |

## Mixing & Routing

| Feature | Status | Notes |
|---------|--------|-------|
| **Mixer console** | ✅ Shipped | Horizontal rack of channel strips: audio/instrument in order, buses grouped, master pinned right. Each strip: name, kind badge, inserts, sends, output, pan, fader, meter, M/S/A buttons. Simple/Pro density modes. |
| **Bus routing** | ✅ Shipped | `track.setOutput` command — route audio/instrument to master or to a bus. Buses receive, mix, and send their output to master (default) or another bus. |
| **Sends (pre/post)** | ✅ Shipped | `track.addSend`, `track.setSend`, `track.removeSend` commands. UI mini-faders in mixer (post-fader by default). Pre-fader option on the wire. |
| **Master volume** | ✅ Shipped | Long-throw fader on master strip. `mixer.setMasterVolume` command. Range: −72…+24 dB. |
| **Master meter** | ✅ Shipped | Stereo peak + RMS per channel, glowing glow-meter style. Driven from live engine taps. |
| **Track metering** | ✅ Shipped | Peak + RMS per track, live in mixer. `store.trackMeters` snapshot on every update. |
| **Mixer presets** | ✅ Shipped | `mixer.applyPreset` command — swap the entire mixer state (all faders, pan, mute/solo, sends, effects, automation) in one undo. Presets are named snapshots. |

## Effects & Signal Processing

### Built-in Effects (9 total)

| Effect | Type | Key Controls | Status |
|--------|------|---------------|--------|
| **Gain** | Utility | Level (dB) | ✅ Shipped |
| **EQ** | Tone | 4 bands (bass/low-mid/high-mid/treble), freq/gain/Q per band | ✅ Shipped |
| **Compressor** | Dynamics | Ratio, threshold, attack, release, makeup gain (soft-knee, stereo-linked) | ✅ Shipped |
| **Limiter** | Dynamics | Threshold, attack, release (5 ms lookahead, true peak ceiling) | ✅ Shipped |
| **Reverb** | Space | Freeverb (8 combs + 4 allpasses), room, damping, width, pre-delay | ✅ Shipped |
| **Delay** | Space | Integer delay lines, feedback, high-cut, ping-pong stereo crossfeed | ✅ Shipped |
| **Saturator** | Tone | Drive (−driveDb/2 dB compensation), tanh nonlinearity | ✅ Shipped |
| **Gate** | Dynamics | Threshold, attack, hold, release (true zeros when closed) | ✅ Shipped |
| **Chorus** | Modulation | 2-voice, stereo/inter-voice LFO phase, depth, rate | ✅ Shipped |

| Feature | Status | Notes |
|---------|--------|-------|
| **Insert chain** | ✅ Shipped | Per-strip effects, ordered. Pre-fader. Atomic snapshot updates (no graph mutations mid-play). Bypass dots per effect. `fx.add`, `fx.remove`, `fx.reorder`, `fx.setBypass`, `fx.setParam`, `fx.describe` commands. |
| **Built-in effect editors** | ✅ Shipped | Click any built-in insert (or its slider glyph) to open a dark-glass editor card with one control per parameter, generated from `fx.describe`. Proper units (Hz, kHz, ms, dB), logarithmic travel on frequency sliders, double-click to reset, ⌥ for fine control. Changed values glow cyan. Adding an insert from the "+" menu opens its editor. One editor open at a time. Master-chain inserts editable the same way. Every slider drives the exact `fx.setParam` path agents use (one undo step per drag). AU inserts keep their own plugin windows. |
| **AU effect hosting** | ✅ Shipped | Any AU effect plugin (AUPeakLimiter, AUDelay, third-party). Async prepare, graceful placeholder on missing/failed AU. Reads real AU latency. Full AU state persisted in `.dawproj`. |
| **Latency reporting** | ✅ Shipped | Each effect reports `latencySamples`. Summed per strip for PDC planning. `fx.describe` returns latency for each effect. |
| **Effect bypass** | ✅ Shipped | Per-effect bypass toggle (signal-green = passing, dim = bypassed). `fx.setBypass` command. Smooth 10 ms crossfade on toggle (m15-f). |
| **Spectrum display** | ❌ Not yet | No real-time spectrum analyzer in v0. Vibe meter (see below) shows spectral tilt qualitatively. Deferred to v1 UI polish. |

## Automation

| Feature | Status | Notes |
|---------|--------|-------|
| **Automation lanes** | ✅ Shipped | Volume and pan per track. Lanes toggle on/off (when off, fader/knob works manually). `automation.addLane`, `automation.removeLane`, `automation.setPoints`, `automation.setLaneEnabled` commands. |
| **Breakpoint editor** | ✅ Shipped | Canvas neon polyline in Arrange. Click to add points, drag to move (snaps to grid), double-click/delete to remove. Live dB/pan readout by cursor. Disabled lanes render dimmed. |
| **Automation curves** | ✅ Shipped | Linear (straight ramp) default. Bezier curves deferred to v1. |
| **Volume automation** | ✅ Shipped | Cyan glowing lane (matches fader color). Per-sample linear ramps in engine. Fader override when pinned in mixer (lane supplies, fader reads). |
| **Pan automation** | ✅ Shipped | Neutral white lane (pan claims no semantic accent). Per-sample linear ramps, center bit-exact null. |
| **Master volume automation** | ✅ Shipped | Master fade lane (m15-c). Applies pre-chain (under the limiter, the pro-standard order). Stems pass fade-free. |
| **Effect param automation** | ✅ Shipped (partial) | Built-in effect parameters automatable (per-quantum render-thread eval). AU effect automation NOT YET (deferred). |
| **Write/touch/latch** | ❌ Not yet | Automation currently read-only on playback (no recording arm). Touch/latch/write modes deferred to v1. |

## Takes & Comping

| Feature | Status | Notes |
|---------|--------|-------|
| **Take groups** | ✅ Shipped | Automatically form when you record over an existing clip. Manual group via `take.group` (≥2 overlapping clips). |
| **Comp lanes** | ✅ Shipped | Paint comp regions from each take lane over the beat grid. `take.setComp` command (pass per-region take selections). One undo step. |
| **Comp member clips** | ✅ Shipped | Clips in a group reject ordinary clip edits (gain, fade, trim, move). Edit the comp or flatten it first. |
| **Flatten group** | ✅ Shipped | `take.flatten` command — dissolve a group back to ordinary, editable clips. One undo step. |
| **Remove lane** | ✅ Shipped | Delete an unused take. `take.removeLane` command. |
| **Loop-cycle take recording** | ✅ Shipped | Record with loop enabled → one new take lane per loop cycle (m15-b). Newest lane auto-selected. |
| **Comp crossfade** | ✅ Shipped | Set crossfade width (seconds) at comp boundaries. `take.setCrossfade` command. Audio uses compressed equal-power crossfades; MIDI is hard-cut. |
| **Auto-align takes** | ✅ Shipped | `take.autoAlign` command — measure onset offset between a take lane and the reference (first lane) and nudge it into alignment. Spectral transient detection + grid search. Useful for aligning AI-generated takes to recorded performance. |
| **Take lane UI** | ✅ Shipped | Arrange open/close disclosure for takes. Paint comp regions by dragging horizontally on a lane row. Click once to select the entire lane. Newest lane reads distinct (accent bar + bold name). Comp boundaries show as glowing splice seams. On playback, comp plays the newest lane even when it's a mid-cycle partial take — industry-consistent behavior. |

## Rendering & Export

| Feature | Status | Notes |
|---------|--------|-------|
| **Bounce/mixdown** | ✅ Shipped | Render the stereo mix to a WAV file. Offline (full project rendered at once). Bit depth: 16/24/32-bit float. Sample rate: project rate. `render.mixdown` command. Determinism: bit-exact same output every time. |
| **Stems export** | ✅ Shipped | `render.stems` command — render each track as its own mono/stereo WAV, with or without effects. Useful for sending to remixers or mastering. |
| **Loudness measurement** | ✅ Shipped | `render.measureLoudness` command — integrate and report loudness in LUFS + short-term + momentary. Follows ITU-R BS.1770-4 spec. Useful for streaming loudness normalization. |
| **Audio format support** | ✅ Shipped | Export to WAV (lossless). MP3/M4A/FLAC export not yet (WIP). |
| **Export UI** | ✅ Shipped | EXPORT button in transport bar (right region, Simple/Pro visible). Opens NSSavePanel for file location + format choice. |

## AI Generation & Editing

| Feature | Status | Notes |
|---------|--------|-------|
| **ACE-Step sidecar** | ✅ Shipped | Local song generation engine (MIT-licensed, runs on your Mac). Install via `scripts/ace-step/install.sh`. Lifecycle: `ai.sidecarStatus`, `ai.sidecarStart`, `ai.sidecarStop` commands. Health check: ACE-Step's own `/health` HTTP endpoint. |
| **Song generation** | ✅ Shipped | `ai.generateSong` (async submit), `ai.generationStatus` (poll). Takes prompt, optional lyrics (ACE-Step bracketed format), duration (15–240 s), and knobs (bpm, key, seed, etc.). Returns jobId, states flow queued→running→succeeded. Downloads audio and metadata on success. |
| **Generation import** | ✅ Shipped | `ai.importGeneration` command — copy finished audio into project-safe location, create violet AI-generated track + clip at a beat position, adopt project tempo from generation's BPM. One undo step. Track name auto-derived from prompt. |
| **Stems extraction** | ✅ Shipped (partial) | `ai.extractStems` command — ACE-Step's internal track separation (vocal / drum / bass / other). Returns stems as separate files. UI import via `ai.importGeneratedStems` (Lego macro). Work-in-progress UI. |
| **Lyrics workshop** | ✅ Shipped | AI lyrics writing inside Sketchpad. Theme (required) + optional style. Section-tag picker ([verse]/[chorus]/[bridge]/[outro]). Write/rewrite/refine flow. Auto-inserts bracketed structure into LYRICS editor. `ai.writeLyrics` command. Requires Anthropic/OpenAI key. |
| **Vocal fix** | ✅ Shipped | AI-powered region repaint. Select an audio clip, set region beats, describe what to fix, pick strength (Subtle/Balanced/Bold). `ai.fixClipRegion` command submits, `ai.importClipFix` imports result as a violet take lane comped in over the region. Polled jobs show live progress. Requires sidecar + key. |
| **Repaint audio** | ✅ Shipped | `ai.repaintAudio` command — full-clip regeneration using ACE-Step's audio2audio editing. Lower-level than Vocal Fix; useful for revoicing or style transfer. |
| **Sketchpad UI** | ✅ Shipped | Violet-accented panel on Arrange right. STYLE + LYRICS editors, length stepper, GENERATE button. Candidates list (queued/generating/succeeded/failed/imported states). PREVIEW player (one candidate at a time), violet IMPORT button. Auto-scroll, live progress. |
| **Generation progress card** | ✅ Shipped | One violet in-window card (both workspaces, bottom-trailing) for every generation job regardless of origin, with an origin chip (SKETCHPAD / AGENT / IMPORT). Live stage text from the generator's own pipeline, percent, elapsed. Red FAILED state carrying the worker's reason verbatim (dismissable), green done state that lingers briefly. Generating with the sidecar stopped auto-starts it (card narrates "starting the AI generator…" and "loading the model…"). Sidecar that dies mid-job flips the card to FAILED and raises an engine notice (`ai-generation-interrupted`). Deliberately no cancel button — the generation engine has no abort endpoint. |
| **Sidecar startup time** | ✅ Shipped | Model load ~1 min on first use (XL DiT + 4B LM). Sidecar banner shows progress. `ai.sidecarStatus` returns state (not_installed / starting / running / stopped / error). |

## AI Control & Copilot

| Feature | Status | Notes |
|---------|--------|-------|
| **Copilot rail** | ✅ Shipped | AI agent sidebar (app-level, not selection-gated). Chat transcript, plain-language input, violet send button (disabled until text typed). Violet identity marker, reset ↺, close ✕. Every agent step is undoable; steps show as tool calls + results in the transcript. Works like a real operator (not suggestions). |
| **Tool call rendering** | ✅ Shipped | Copilot displays each tool call as a compact violet chip (command + args), and results as semantic chips (green ok / red error + message). |
| **Error surface** | ✅ Shipped | Agent failures show as red-tinted strips with actionable messages. No fatal crash — agent can retry or try a different approach. |
| **First-use hint** | ✅ Shipped | Empty transcript shows beginner-friendly prompt suggestions (e.g., "Add a drum track", "Tighten the drums"). |
| **Requires API key** | ✅ Shipped | Anthropic (primary) or OpenAI (fallback). Set in Settings or environment variables. Falls back gracefully if no key is set. |

## Explainability & Onboarding

| Feature | Status | Notes |
|---------|--------|-------|
| **Explain this mode** | ✅ Shipped | Violet **EXPLAIN** chip toggles. While on, hover any registered control for a card (violet-edged popover, ~300pt). Shows control name + 2–3 beginner-readable sentences + "Ask Copilot →" button. Overlay, not a lockout. Esc to close. 74 controls covered (transport, mixer, piano roll, arrange, AI panels, settings, instrument picker, effect editor, arrange zoom, timeline pointer). |
| **Explain copy contract** | ✅ Shipped | Every entry ≤24 chars title, 40–280 chars body ending in punctuation. No raw jargon (dB/Hz/BPM spelled out). Headless catalog in `DAWAppKit.ExplainCatalog` (tested for completeness + char counts). |
| **Copilot hand-off** | ✅ Shipped | "Ask Copilot →" closes Explain mode, opens Copilot rail, pre-fills input with *"Explain ‹control name› — what should I do with it here?"* (draft only, never auto-sent). |
| **Onboarding tour** | ✅ Shipped | Seven-step guided tour (welcome + 5 task steps + done). Coach-mark cards anchor beside controls, with a cyan highlight ring. Task steps: add a track, record audio, play, adjust mixer, bounce. Offer once on first launch, replayable from Settings. Each step fires on a real action (you click the control, it completes the step). Progress tracked in UserDefaults (app preference, never project data). |
| **Onboarding copy** | ✅ Shipped | Same Rule-6 contract as Explain (beginner test, ≤24 chars title, 40–280 chars body, punctuation, no jargon). Tests enforce completeness. |
| **Simple/Pro density** | ✅ Shipped | Four panels support Simple (20% of controls, beginner-safe) + Pro (full feature set): piano roll, mixer, arrange, transport. Others coincide (Simple = Pro). Density is app-sticky per panel, persisted in UserDefaults (never project data). SIMPLE/PRO chip pair (SF Mono 9pt, active half cyan-lit). Simple mode: bar-locked snap grid by default (no dead hit-zones on clip edges). |

## Project Management

| Feature | Status | Notes |
|---------|--------|-------|
| **New project** | ✅ Shipped | `project.new` command. UI: File menu or Copilot. |
| **Open project** | ✅ Shipped | `project.open` command (file path). UI: File menu → Open dialog. Supports `.dawproj` bundles only (v0). |
| **Save project** | ✅ Shipped | `project.save` command. UI: ⌘S or File → Save. |
| **Autosave** | ✅ Shipped | Periodic autosave to a recovery bundle. Autosave is hygiene-only (no user-facing "save as" branching; each save overwrites the bundle). Projects survive crashes. |
| **Project recovery** | ✅ Shipped | `project.recoveryStatus`, `project.recover` commands. UI: Settings → Recovery, or auto-offer after a crash. `project.new`/`project.open`/`project.save` responses carry a `discardedRecovery` `{savedAt, sourcePath?, editCount}` honesty object when that call consumed a pending crash-recovery offer (m16-e). `savedAt` is ISO-8601. |
| **Recovery bundles** | ✅ Shipped | `project.recoveryBundles` command — read-only list of per-session untitled autosave bundles (`Untitled-<slug8>.dawproj` format) discovered on disk. Agents can scan for abandoned work and open any bundle via `project.open`. |
| **Project snapshot** | ✅ Shipped | `project.snapshot` command — JSON serialization of the entire project (tracks, clips, mixer, automation, AI generation history). Used by agents and for E2E testing. |
| **Project overview** | ✅ Shipped | `project.overview` command — counts-only summary (num tracks / clips / effects, no content). Used in feedback bundles (privacy-lean). |
| **Undo/redo** | ✅ Shipped | `edit.undo`, `edit.redo` commands. UI: ⌘Z / ⇧⌘Z or Edit menu. Coalescing: rapid edits (e.g., dragging a clip) collapse into one undo step. Every command routes through the store's journal. |
| **`.dawproj` format** | ✅ Shipped | ZIP bundle: versioned JSON root + `media/` directory (bundled audio + AU fullState). Designed for durability and deduplication. Readable by parsing `project.json` (the project structure). |
| **File extensions** | ✅ Shipped | `.dawproj` is the project extension. Audio exports are `.wav`. |

## Settings & Preferences

| Feature | Status | Notes |
|---------|--------|-------|
| **API key management** | ✅ Shipped | Settings panel (⌘, or gear icon, top-right). Rows per provider (Anthropic, OpenAI, Suno [dormant], ACE-Step [no key needed]). Masked SecureField input (never shows the key value). Green status badge when configured. Keys stored in macOS Keychain (never logged, never synced). Environment variable can lock a key (Config → display locked state). |
| **Input device selection** | ✅ Shipped | Settings panel lists all CoreAudio input devices. Click to select for recording. Default device shown. |
| **Preferences persistence** | ✅ Shipped | UserDefaults domain `dev.dawpro.app` (bundled app) or dev's own (source build). Includes: panel density, onboarding state, recovery bundle status, API key manager state (not the key values themselves). Never written to projects. |
| **Feedback bundle** | ✅ Shipped | Settings → Beta Feedback → Save Feedback Bundle. Local folder with manifest (version, macOS, Mac model), engine health (watchdog + render load), overview (counts only), recent crashes (14 days, 10 files), and optional project. Zip to attach to bug reports. |

## Control Surface & Extensibility

| Feature | Status | Notes |
|---------|--------|-------|
| **Control protocol** | ✅ Shipped | WebSocket JSON on `ws://127.0.0.1:17600` (loopback, local network off). Default port configurable via `DAW_CONTROL_PORT` env var or Settings → Agent Connection. Request: `{id, command, params}`. Response: `{id, ok, result?, error?}`. 126 commands across namespaces (transport, track, clip, arrange, mixer, fx, automation, ai, render, plugin, project, input, midi, edit, engine, macro, groove, take, marker, tempo, instrument, app). `project.snapshot` includes live peak/RMS meters for master and every track (`meters.master` / `meters.tracks`), enabling agents to confirm audio is rendering. |
| **Command parity** | ✅ Shipped | Every control-protocol command maps 1:1 to an MCP tool (bijection, enforced by test). `audit-tools.test.ts` verifies the mapping on every build. |
| **MCP server** | ✅ Shipped | TypeScript, stdio transport. 129 tools (126 commands + 3 provider-direct generation tools). Runs as a subprocess of an MCP client (Claude Code, Claude Desktop, etc.). Bridges `control.WebSocket` ← → app. Build: `npm install && npm run build`. Run: `node dist/index.js`. |
| **Tool descriptions** | ✅ Shipped | Every MCP tool has a human-readable title (≤60 chars) and description (≥40 chars, beginner language per Rule 6). Input schema properties all documented recursively. Schema enforced by headless tests. |
| **Error surface** | ✅ Shipped | Commands return structured errors (ControlError subclasses — `invalidParameter`, `noTrack`, `invalidClip`, etc.). Agents see the specific error and can retry intelligently. |
| **Async handling** | ✅ Shipped | Render commands (`render.bounce`, `render.mixdown`, `render.stems`, `render.measureLoudness`) support long-running work (180s timeout vs. 5s default). Async AI job commands (`ai.generateSong`, `ai.fixClipRegion`) return immediately with jobId, poll with status commands. |

## Platform & Infrastructure

| Feature | Status | Notes |
|---------|--------|-------|
| **macOS minimum** | ✅ Shipped | macOS 14+ (Sonoma or later). Intel + Apple Silicon (M1+) tested. |
| **Real-time safety** | ✅ Shipped (audited) | Render thread: no allocation, no locks, no ObjC dispatch, no file I/O. Tier-1 (render) vs. Tier-2 (taps/queues) boundary enforced by design. Full audit: `docs/research/audit-rt-safety.md`. |
| **Audio engine** | ✅ Shipped | AVAudioEngine + CoreAudio. Graph-based routing (nodes → connections). Lock-free communication across boundaries. Offline render support (batch processing for testing + bounces). |
| **Resize & layout integrity** | ✅ Shipped | Audited across window sizes, both workspaces, both densities (m17-f): track-header names never truncate down to the minimum sidebar; mixer strips of different kinds align pan/fader/section rows rack-wide via a reserved chip slot; workspace side panels (Sketchpad, clip-fix) compress and scroll internally instead of forcing a minimum window size; ruler↔lanes grid alignment machine-verified pixel-exact. |
| **Engine notices** | ✅ Shipped | When playback degrades, an amber transport-bar chip appears in **both** Simple and Pro — it only shows when something happened. Code families: `clip-envelope-skipped` / `clip-fades-skipped` / `clip-stretch-pending` (skipped fades/envelopes, clip still time-stretching); `clip-unplayable` (wiring guard, missing connection); `clip-file-missing` (file open failed — cause-known, restore/re-link remedy). Agents see the same facts in `project.snapshot` `engineNotices` (absent = healthy). Session-transient; nothing in the project changes (m15-e, m16-a, m16-c). Since m17-h the same chip also carries `ai-generation-interrupted` when the AI generator dies mid-job. |
| **Testing framework** | ✅ Shipped | Swift Testing (`import Testing`). DAWCore is headless, engine is separately testable. Integration tests: real MCP client → control wire → app (12 tests). Run: `./scripts/test.sh`. |
| **Build system** | ✅ Shipped | Swift Package Manager (SPM) monorepo. Targets: DAWCore (domain model), DAWEngine (audio), DAWControl (wire), AIServices (providers), DAWApp (UI), DAWAppKit (headless UI logic), MCP server (TypeScript). |
| **Crash recovery** | ✅ Shipped | Autosave + recovery bundle on unexpected quit. On relaunch, app offers to recover the last session. Watchdog detects render-thread hangs and recovers. |

## Limitations & WIP

| Feature | Status | Notes |
|---------|--------|-------|
| **Track rename UI** | ✅ Shipped | Double-click the track header name or use the context menu (m10-i); `track.rename` on the wire. |
| **Loop region UI** | ✅ Shipped | Interactive loop ruler in the arrange (m10-g); `transport.setLoop` on the wire. |
| **MIDI CC / learn** | ❌ Not yet | MIDI control-change messages and learning (mapping hardware knobs to DAW parameters) not yet shipped. |
| **Touch/latch/write modes** | ❌ Not yet | Automation is read-only on playback. Recording arm for automation deferred to v1. |
| **Bezier curves** | ❌ Not yet | Automation lanes use linear interpolation only. Bezier curves deferred to v1 polish. |
| **AU effect param automation** | ❌ Not yet | Built-in effect params are automatable; AU plugin params are not (per-quantum eval not exposed to hosted AUs yet). |
| **Master effect chain** | ✅ Shipped | Insert effects on the master strip (m13-d). Built-ins only in v0; AU effects deferred. |
| **Spectrum analyzer** | ❌ Not yet | No real-time EQ/spectrum display in the mixer. Vibe meter shows spectral tilt qualitatively. |
| **VST hosting** | ❌ Not in scope | AudioUnits cover the macOS ecosystem. VST is not on the roadmap. |
| **Notarization** | ❌ Blocked (pkg-c) | The bundled app is ad-hoc signed (Developer ID signing/notarization pending credential availability). Gatekeeper prompt on first launch on another Mac. |
| **App icon** | ❌ Blocked (UI asset generation) | App ships with generic bundle icon. Custom icon generation blocked on credential availability for GPT Image. |
| **Export formats** | 🔶 Partial | WAV export works. MP3/M4A/FLAC/OGG/DSD support deferred. |

## Command & Tool Counts

- **Wire commands**: 126 (verified against `Sources/DAWControl/Commands.swift` `allCommands` array; +3 from m15-d arrange ergonomics; +2 from m16-b2 controller-lane verbs; +1 from m16-e recovery-bundles read)
- **MCP tools**: 129 (126 commands + 3 provider-direct tools: `generate_lyrics`, `generate_image`, `generate_song_suno`)
- **Built-in effects**: 9 (Gain, EQ, Compressor, Limiter, Reverb, Delay, Saturator, Gate, Chorus)
- **Copilot catalog entries**: 56 (m15-d adds 3 arrangement verbs; m16-b2 adds 1 controller-lane entry)
- **Explain catalog entries**: 74 (transport, mixer, piano roll, arrange, AI panels, settings, instrument picker coverage; +1 for master automation in m15-c; +1 for controller strip in m16-b4; +4 in M17 — insert-effect editor, arrange zoom, playhead gestures, generation progress card)

---

**Legend:**
- ✅ Shipped — works in the app and over the control protocol.
- 🔶 Partial — some parts shipped, others deferred.
- ❌ Not yet — scheduled or in the backlog.
- 🔒 Blocked — deferred on an external blocker (credentials, third-party changes, etc.).
