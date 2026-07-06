# Architecture

```
┌────────────────────────────────────────────────────────────┐
│ DAWApp (SwiftUI)                                           │
│   Views ── observe ──► ProjectStore (@MainActor)           │
│                            │ commands                      │
│                            ▼                               │
│                       DAWCore (pure domain model)          │
│                            │ engine ops                    │
│                            ▼                               │
│                       DAWEngine (AVAudioEngine/CoreAudio)  │
│                        · playback graph  · metering        │
│                        · AU hosting      · offline render  │
└────────────▲───────────────────────────────────────────────┘
             │ same command surface as the UI
     DAWControl WebSocket server (127.0.0.1:17600, JSON)
             ▲
             │ ws bridge
     mcp-server (TypeScript, stdio MCP) ◄── Claude / any MCP client
             │
             └── direct HTTPS: Anthropic · OpenAI · Suno · GPT Image
```

## Principles

1. **One command surface.** UI actions and control-protocol commands converge on the same `ProjectStore` methods. If a feature works in the UI but has no command, it is unfinished (see CLAUDE.md conventions).
2. **The render thread is sacred.** `DAWEngine` communicates with the render path via lock-free/atomic state and preallocated buffers. Metering flows out via periodic taps, never blocking.
3. **DAWCore is headless.** The whole domain model builds and tests without AVFoundation or SwiftUI. This is what makes autonomous agent development fast and safe.
4. **MCP server is thin.** It translates MCP tools → control commands, and hosts the AI-provider calls (lyrics, Suno, images). It holds no DAW state of its own; `project_snapshot` always reflects the app.

## Control protocol (v0)

Request: `{"id": "…", "command": "transport.play", "params": {…}}`
Response: `{"id": "…", "ok": true, "result": {…}}` or `{"id": "…", "ok": false, "error": "…"}`

Command namespaces: `transport.*`, `track.*`, `clip.*`, `take.*`, `groove.*`, `mixer.*`, `project.*`, `render.*`, `ai.*`, `plugin.*`, `input.*`, `midi.*`. The canonical list lives in `Sources/DAWControl/Commands.swift` and must stay in sync with `mcp-server/src/index.ts` tools.

`take.*` (M5 iii-b) — comping control surface over the iii-a take/comp domain (`Sources/DAWCore/Takes.swift`, `ProjectStore+Takes.swift`): `take.group` (form a group from >= 2 overlapping clips), `take.setComp`/`take.select` (replace/swap the comp — which lane plays which absolute-beat range), `take.removeLane` (delete an unused take), `take.flatten` (dissolve the group back to ordinary, editable clips), `take.move` (reposition the whole group), `take.setCrossfade` (join crossfade width in seconds). Every response threads the model's own Codable (`TakeGroup`/`CompSegment`/member `Clip`s) onto the wire so it can never drift from persistence; `take.setComp`'s `segments` param round-trips through `CompSegment`'s Codable with per-index errors. Member clips (`Clip.takeGroupID != nil`) reject the ordinary clip-edit commands with `clipInTakeGroup`, pointing at `take.setComp`/`take.flatten`. Recording a take that overlaps an existing take/group on its track auto-groups (`ProjectStore.autoGroupRecordedTake`, called from `finishTake`, audio-only in v0; newest take wins the default comp) — one `performEdit` covers the whole grouped take, so it is still a single undo step. Mirrored 1:1 by 7 MCP tools (`take_group`, `take_set_comp`, `take_select`, `take_remove_lane`, `take_flatten`, `take_move`, `take_set_crossfade`) in `mcp-server/src/index.ts`.

`clip.detectTransients` (M5 iii-e) — offline transient analysis surface over the engine's `detectTransients(inFileAt:sensitivity:)` (spectral-flux `TransientAnalyzer` + content-keyed `TransientCache` JSON sidecars in `Sources/DAWEngine/Analysis/`; the only engine addition in the whole M5 iii epic, never on the render thread). Read-only and pull-only: markers are SOURCE-FILE seconds (geometry-free — trims/splits never invalidate the cache), the response `{transients: [{sourceSeconds, beat, strength}], count}` window-filters to the clip and maps beats at the current tempo/stretch, nothing is persisted or snapshotted. MIDI clips reject verbatim (`transientsRequireAudioClip`). Mirrored by the `clip_detect_transients` MCP tool; feeds iii-f `clip.quantizeAudio` and iii-g groove extraction.

`clip.quantizeAudio` (M5 iii-f) — destructive audio quantize over the pure `AudioQuantizePlan` (`Sources/DAWCore/AudioQuantize.swift`): detect transients (iii-e path) → slice the clip at onsets → monotone strength-lerp nudge of each slice to `QuantizeTarget.nearest` (same grid/strength/swing evaluator as MIDI `clip.quantize`) → replace the clip with the slice clips in ONE `performEdit("Quantize Audio")` (undo restores the single original clip, id included). Slices are NATURAL-LENGTH — each reads only its own `[onsetᵢ, onsetᵢ₊₁)` source span, never a neighbour's attack (deviation from the settled design's source-continuation gap-fill, which measurably doubled transients on the rendered bounce) — with representational equal-power crossfades at compressed joins (CompFlattener mechanism) and clean-cut silence at expanded gaps. No per-slice stretch in v0 (elastic v1 flagged); params `{gridBeats, strength, swingPercent, sensitivity, crossfadeMs 0–50, minSliceBeats}`. Rejections verbatim: MIDI (`quantizeRequiresAudioClip`), non-identity stretch (`audioQuantizeStretchUnsupported`), comp member (`clipInTakeGroup`), fewer than 2 usable transients (`audioQuantizeNoTransients`). Mirrored by the `clip_quantize_audio` MCP tool; the `groove` param (iii-g) is live in both layers.

`groove.*` (M5 iii-g) — project-level GROOVE palette over the pure `GrooveTemplate` (`Sources/DAWCore/Groove.swift`): a per-slot timing-offset table (`{gridBeats, cycleBeats, offsets}`, `count == round(cycle/grid)`, each offset clamped to ±grid/2) extracted from onsets — a MIDI clip's note onsets or an AUDIO clip's detected transients, both fed clip-relative to `GrooveTemplate.extract` (nearest-slot snap → per-folded-slot deviations average → empty slots 0). Built-in MPC swing presets (`swing8:54…75`, `swing16:54…75`; the 8 canonical `54|58|62|66 × 8th|16th` advertised) compute on demand and are never persisted. `groove.extract` appends to `ProjectStore.grooveTemplates` (published, additive `EditState` field so undo covers add/remove; additive optional `ProjectDocument.grooveTemplates` omitted-when-empty, no schemaVersion bump), `groove.list` returns `{templates, builtins}`, `groove.remove` deletes by id. Grooves apply BY VALUE: the `groove` param on `clip.quantize`/`clip.quantizeAudio` resolves (built-in name → template id → template name; `resolveGroove`) to `QuantizeSettings.groove`/`AudioQuantizeSettings.groove`, which substitutes the per-slot offset in `QuantizeTarget.slotOffset` (groove wins over swing) so a deleted template never dangles. Zero engine involvement. Mirrored 1:1 by 3 MCP tools (`groove_extract`, `groove_list`, `groove_remove`) plus the `groove` param on `clip_quantize`/`clip_quantize_audio`.

`render.measureLoudness` / `render.bounce` / `render.stems` (M5 iv-d) — the measured/normalized/exported siblings of the frozen `render.mixdown` (raw, fast, no report), over the pure `Loudness`/`StemPlan` DAWCore domain (`Sources/DAWCore/Loudness.swift`, `StemPlan.swift`) and the additive `ProjectStore+Render.swift` ops. `render.measureLoudness` (`fromBeat?`, `durationSeconds?`) offline-renders and measures BS.1770-4 integrated + max momentary/short-term + 4× oversampled true peak — WRITES NOTHING; nil fields mean the program sits at/below the −70 LUFS gate (JSON has no −inf). `render.bounce` (`path?`, `fromBeat?`, `durationSeconds?`, `lufsTarget?`, `truePeakCeilingDb?` default −1.0) writes a WAV and, when `lufsTarget` is given, applies ONE static gain toward it CLAMPED so the true peak never crosses the ceiling (no limiter in v0 — `report.limitedByCeiling` says so honestly and `report.output`, RE-MEASURED from the gained audio, is the loudness actually achieved; an agent can add the built-in limiter and re-bounce to close the gap); omitted `lufsTarget` = a measured, un-normalized bounce; a gated-silent program with a target throws `bounceSilent` verbatim. `render.stems` (`trackIds?`, `directory?`, `fromBeat?`, `durationSeconds?`, `includeMixdown?`) exports the master-input partition — one file per direct-to-master track (dry, sends stripped) and one per bus (every send contribution folded in) — as `NN Name.wav`, every pass forced under the SAME full-session PDC plan so **Σ stems ≡ the mixdown** holds; stems are NEVER normalized, each instead carrying its own full loudness measurement; a bus-routed `trackIds` entry rejects `stemNotMasterInput` verbatim. All three responses thread the model's own Codable (`LoudnessMeasureResult`/`BounceResult`/`StemExportResult`) onto the wire so it can never drift from persistence. Zero render-thread changes; the only engine additions are the buffer-out `renderOffline`/`offlineCompensationTargets`/`writeAudioFile` seam that `renderMixdown` itself now runs over (contract frozen). Mirrored 1:1 by 3 MCP tools (`render_measure_loudness`, `render_bounce`, `render_stems`; 71→74) teaching the −14 LUFS streaming / −23 LUFS EBU R128 broadcast conventions and the ceiling-clamp semantics.

`ai.sidecarStatus` / `ai.sidecarStart` / `ai.sidecarStop` (M6 i) — process-lifecycle management (install detection, health probe, start/stop) for the local ACE-Step-1.5 song-generation sidecar, over `SidecarManager` (`Sources/AIServices/SidecarManager.swift`, an actor — DAWControl now depends on AIServices for this one seam, no cycle since AIServices only depends on DAWCore). `ai.sidecarStatus` (no params, never throws) health-probes `GET http://127.0.0.1:8001/health` (loopback only) and returns one of `notInstalled` / `installedNotRunning` / `starting` / `healthy` / `error`, each with an actionable `message` and, when healthy, `version`/`ditModel`/`lmModel` parsed from ACE-Step's own `{"data": {...}}` health envelope. `notInstalled` vs `installedNotRunning` is distinguished by an install marker (`scripts/ace-step/.install-state.json`, written by `install.sh`), not by guessing from a bare connection failure. `ai.sidecarStart` (no params) spawns `scripts/ace-step/run.sh` via `Process` (log captured to `~/Library/Logs/DAWPro/ace-step.log`, pid tracked via a pidfile so a later `stop()` works across app relaunches) and polls health up to a startup timeout — a slow model load returns `state: "starting"`, not an error; only a missing install or a process that exits during startup throws (`notInstalled`/launch-failure, verbatim, pointing at `install.sh` or the log). `ai.sidecarStop` (no params) sends SIGTERM via the pidfile, escalating to SIGKILL if it doesn't exit in time; not-running is a no-op success. The sidecar directory resolves via `DAWPRO_ACESTEP_DIR` (env override — also how tests/E2E point at a stub) or by walking up from the running process to this repo's `Package.swift` (dev-only heuristic; M9 packaging must set the env var). All three responses thread the model's own `SidecarStatus` Codable (AIServices) onto the wire. Mirrored 1:1 by 3 MCP tools (`ai_sidecar_status`, `ai_sidecar_start`, `ai_sidecar_stop`; 74→77) that teach the install-first flow and note that generation tools (`ACEStepClient`/`generate_song`) are a later roadmap item, not yet available. Install/run tooling: `scripts/ace-step/install.sh` (idempotent venv + XL-turbo/XL-sft DiT + 4B LM weight download, ~55-70 GB — see docs/research/2026-07-05-ace-step-local-song-generation.md for the tier rationale and its one documented deviation) and `scripts/ace-step/run.sh` (starts the FastAPI server bound to 127.0.0.1 only).

`ai.generateSong` / `ai.generationStatus` (M6 ii) — the actual song-generation job pair, over `ACEStepClient: SongGenerating` (`Sources/AIServices/ACEStepClient.swift`, an actor; the `SongGenerating` protocol itself reshaped in `Providers.swift` from a single-call to a submit/poll async-job shape, since a real render commonly takes minutes — `SunoClient` is adapted minimally to keep compiling as the still-dormant cloud fallback, its own `generationStatus` throwing `notImplemented` since no Suno polling endpoint is verified). Coded directly against the upstream FastAPI route source (`scripts/ace-step/runtime/src/acestep/api/http/{release_task,query_result,audio}_route.py` + `api_server.py`'s `_wrap_response` envelope), not guessed. `ai.generateSong` (`prompt` required — style/caption text; `lyrics?` — ACE-Step's bracketed-structure format, e.g. `[Verse 1]`/`[Chorus]`, omitted/blank = instrumental; `durationSeconds?`, `seed?`, `bpm?`, `keyScale?`, `timeSignature?`, `vocalLanguage?`, `guidanceScale?`, `inferenceSteps?` — optional generation knobs, ACE-Step's own defaults apply when omitted) POSTs `/release_task` and returns immediately: `SongGenerationSubmission {jobId, state: "queued", queuePosition?}` — this call never waits for the song to finish. `ai.generationStatus` (`jobId` required) POSTs `/query_result` and returns `SongGenerationStatus {jobId, state, progress?, stage?, statusText?, audioPath?}` where `state` is `"queued"`/`"running"`/`"succeeded"` — a job that failed upstream surfaces as a THROWN error instead (`ACEStepError.jobFailed`, carrying the sidecar's own failure detail), never a quiet `"failed"` state value. `audioPath` is populated the FIRST time a poll observes success: `ACEStepClient` fetches the finished audio via `GET /v1/audio?path=<sidecar-local path>` to a local file under `NSTemporaryDirectory()/DAWPro/ace-step-generations/<jobId>.<ext>` and caches it in-actor, so later polls of the same job reuse that path without re-downloading (the documented fetch-once contract — see the `SongGenerating` protocol doc). Errors distinguish sidecar-not-reachable (`ACEStepError.sidecarUnreachable`) from an HTTP-level failure (`.requestFailed`, e.g. the sidecar's own 429 queue-full), a malformed/undecodable response (`.malformedResponse`), an unknown/expired job id (`.jobNotFound`), and a failed job (`.jobFailed`) — `CommandRouter` specifically intercepts `.sidecarUnreachable` and re-probes `sidecarManager.status()` so the surfaced message is the SAME state-specific guidance `ai.sidecarStatus` would give (`run install.sh` / `call ai.sidecarStart` / `poll again — still starting`), not a bare connection error. There is deliberately no `ai.generationCancel`: the upstream job-queue API exposes no cancel endpoint (verified against the same route source — job cancellation there is only an internal `asyncio.Task.cancel()` on server shutdown, not client-triggered). Mirrored 1:1 by 2 MCP tools (`generate_song`, `generation_status`; 77→79) that teach the async submit-then-poll flow, the sidecar-must-be-healthy-first precondition, realistic (community-reported, not officially benchmarked) Apple-Silicon generation times, and the bracketed lyric format with a worked example. `ACEStepClient`'s base URL defaults to `http://127.0.0.1:8001`, overridable via `ACE_STEP_URL` (and an optional `ACESTEP_API_KEY` bearer token — both env-only, matching `SidecarManager`'s own resolution pattern; unset by default since the sidecar is loopback-only). This box stays UNCHECKED in `docs/ROADMAP.md` until a real generation succeeds against the healthy (weights-complete) sidecar — everything above is proven against a stub HTTP server and a stub `run.sh`, never the real ACE-Step process.

## Key future decisions (flagged, not yet made)

- **Sequencer clock: SETTLED (M1 audio / M3 MIDI, 2026-07-05)** — Audio clips:
  AVAudioPlayerNode `scheduleSegment` with player-relative sample times (player
  time 0 = transport position), per-clip players under per-track mixers, shared
  host-time start anchor live / immediate start in manual rendering; validated
  by offline sample-accuracy tests. MIDI: one custom `AVAudioSourceNode` per
  instrument track (source → track mixer → main mix, explicit graph-rate
  format), reading an IMMUTABLE preallocated sorted event schedule
  (`ScheduledMIDIEvent`: schedule-relative Int64 sampleTime, on/off kind,
  pitch, velocity, identity-carrying UInt64 noteID for same-pitch overlaps;
  off-before-on at equal frames) published via a C11 atomic pointer
  (in-repo `CAtomics` shim; retired schedules released ≥ 1 s later on the main
  actor — the render thread never allocates, locks, retains, or calls ObjC).
  Position mapping: LIVE, each quantum maps `mHostTime` against the SAME
  `anchorHostTime` the clip players and metronome start on (precomputed
  timebase, ±1-frame worst case); OFFLINE, the first pulled `mSampleTime` per
  schedule generation is latched as the epoch (exact frames — event-timestamp
  tests assert `==`). Seek/tempo/loop-wrap/note-edits reuse the existing
  stop-reschedule-resume restart; `stopAllPlayers()` also unpublishes
  schedules and sets an atomic flush flag, honored at the next quantum via a
  render-thread-safe `instrument.reset()` (the all-notes-off contract; release
  tails cut, v0-honest). Instruments implement `InstrumentRendering`
  (per-quantum event slice + renderStart + output ABL; offsets translate 1:1
  to AURenderEvent lists for M3 (vi) hosting); v0 ships EventCaptureInstrument
  (test vehicle) and TestToneInstrument (audible sine placeholder — real synth
  is M3 (iv)). Fixed tempo per schedule; NO tempo map, CC/pitch-bend/sustain,
  per-note channel, or note chase in v0 — all additive later. Rejected:
  pre-rendering MIDI to PCM on player nodes (kills the AU seam, main-actor
  reschedule cost scales with song length) and hosting Apple music-device AUs
  for the clock (couples the clock to M3 (vi) hosting plumbing).
- **Input capture (recording)**: SETTLED for M2 Stage A — a dedicated
  input-only `AVAudioEngine` (inputNode tap at device-native format) runs
  beside the playback engine; tap buffers drain onto a serial writer queue
  into a Float32 WAV at device rate, host-time-aligned to the shared player
  start anchor. Rationale: touching `inputNode` on the running output engine
  requires a stop/start (audible gap) and couples playback to input-device
  config changes. No round-trip latency compensation yet (M4 PDC). Device
  selection (M2 Stage B) targets only the input engine; AVAudioSinkNode +
  lock-free ring is the upgrade path if tap delivery proves jittery.
- **Time-stretch library: DECIDED (M5 ii, 2026-07-05)** — **signalsmith-stretch (MIT, header-only C++11)** as the offline stretch/pitch engine: cleanest possible license for commercial shipping, block buffer-in/buffer-out API matching the M5 (i-b) bake-at-schedule-time pattern, explicit formant controls for the ACE-Step vocal use case, credible quality signals (forum A/B preferred over Rubber Band; production use in Qt/FFmpeg, audiomentations). Integration shape: vendor with its `signalsmith-linear` FFT sibling (optionally on Accelerate/vDSP) behind a flat-C shim (the CAtomics precedent — opaque handle create/configure/process/flush/destroy) wrapped in a Swift `OfflineStretcher` facade. Validate with a vocal-focused listening test before final; **named fallback: Rubber Band commercial Standard £590 attribution / £1,490 non-attribution <10 employees** (GPL track is a hard no for proprietary shipping). SoundTouch rejected on quality (time-domain, transient smearing); Bungee OSS (MPL 2.0) a bake-off second opinion but vendor's own data shows it capped below their paid tier; Apple `AVAudioUnitTimePitch` reserved for the M5+ REAL-TIME preview path via the existing HostedAUEffect plumbing, never the offline bake engine. Full evaluation: docs/research/2026-07-05-time-stretch-library-evaluation.md. Integration seam design (cache location/key/invalidation incl. tempo change, stretch-before-fade-bake ordering with post-stretch beat remap, async render job model, preview boundary) settled separately — see the clip time-stretch entry below once landed.
- **Project file format**: SETTLED (M2) — `.dawproj` package directory:
  `project.json` (explicit `ProjectDocument` schema in DAWCore, `schemaVersion`
  int; additive optional fields need no bump, breaking changes bump + stepwise
  migration; newer-version files refused with a readable error) plus a flat
  `media/` dir. User saves are self-contained: every referenced audio file is
  copied in (URL-keyed dedupe, original basenames with `-N` collision
  suffixes) and in-memory clip URLs rewrite to bundle paths; `project.json` is
  written last, atomically — it is the commit point. Transient state (meters,
  isPlaying/isRecording, lastRecordingError, selectedInputDeviceUID) never
  persists. Autosave = save-in-place every 30 s when dirty; untitled sessions
  autosave to `~/Library/Application Support/DAWPro/Autosave/` as a
  JSON-only bundle with absolute media paths (crash recovery, not portable),
  without adopting the path. Synchronous main-actor IO accepted for v0 (JSON
  is KBs; APFS clones make same-volume media copies cheap). No NSDocument,
  no file coordination, no iCloud in v0. Finder package/UTI registration
  (LSTypeIsPackage) needs a real app bundle — deferred to M9 packaging.
- **Undo journal: SETTLED (M2)** — a per-session SNAPSHOT journal in DAWCore
  (`UndoJournal`), not a command/inverse-op log. Every undoable mutation funnels
  through `ProjectStore.performEdit(label:key:)`, which captures a normalized
  `EditState` (tracks + masterVolume + the persistable transport fields, with
  transport TRANSIENCE — isPlaying/isRecording/positionBeats — normalized out, so
  play, record, and playhead motion never look like edits) BEFORE the body runs,
  then pushes an entry only when the state actually changed (a no-op still marks
  dirty but adds no history). Rationale: the whole session state is already small
  and `Equatable`, so snapshot diffing is simpler and less bug-prone than paired
  do/undo closures per operation and composes for free with future mutators.
  Rapid same-`key` edits (fader/tempo scrubs) coalesce within an 800 ms SLIDING
  window into one step; undo/redo restore the document fields while PRESERVING the
  live playhead/play state and emit only the targeted engine intents whose inputs
  moved. Stacks cap at 100 and clear at every load boundary (open/new); save
  leaves history intact. Refused mid-take. Surfaced as `edit.undo`/`edit.redo` on
  the control protocol (label + full snapshot) and the Edit menu's ⌘Z/⇧⌘Z.
  Trade-off: each entry holds a full track-list snapshot — fine for v0 song
  sizes; a structural-sharing or patch-based journal is the upgrade path if
  memory becomes a concern.
- **MIDI data model: SETTLED (M3, 2026-07-05)** — a MIDI clip is a regular
  `Clip` carrying an optional `notes: [MIDINote]?` payload instead of an
  `audioFileURL`. The two are MUTUALLY EXCLUSIVE by construction (`Clip.init`:
  when `notes != nil`, `audioFileURL` is forced nil — notes win), and `isMIDI`
  is simply `notes != nil` (an empty array is still a MIDI clip). `MIDINote` is
  a value type — `id`, `pitch` (0...127), `velocity` (1...127; 0 is a note-off,
  never stored), `startBeat` (>= 0, RELATIVE to the clip start so notes move
  with their clip), and `lengthBeats` (>= 0.001) — all clamped through the one
  `init` that Codable routes through, so no out-of-range value can enter the
  model. Deliberately NO per-note MIDI channel field: a clip belongs to one
  instrument track, so channel is a track/routing concern, added later only if
  multi-timbral hosting needs it. Scheduler contract (consumed by M3 (iii)):
  notes are stored CANONICALLY ORDERED (by onset, then pitch, then id), a
  zero-length note is impossible, note bounds are NON-DESTRUCTIVE (clip length
  clips playback but never trims stored notes), and overlapping notes on the
  same pitch are LEGAL (the scheduler resolves them). Editing is whole-array:
  `ProjectStore.setClipNotes(clipID:notes:)` replaces the list under a single
  `clip.notes:<id>` undo key (a piano-roll drag coalesces to one step), matching
  the snapshot journal. Persistence is ADDITIVE v1 — `ClipDocument` gains an
  optional `notes` (omitted for audio clips, so an audio-only project stays
  byte-identical to a pre-MIDI save; an empty array persists to keep an empty
  MIDI clip's identity), no `schemaVersion` bump. Kind rule: MIDI clips live
  ONLY on instrument tracks (`addMIDIClip` throws
  `midiClipsRequireInstrumentTrack` otherwise), mirroring audio-clips-on-audio-
  tracks. Surfaced as `clip.addMIDI` / `clip.setNotes` / `clip.remove` on the
  control protocol (with a 4096-notes-per-clip cap and exact per-note parse
  errors). Instrument tracks are inert in the audio render path until the M3
  scheduler lands — `PlaybackGraph` filters to audio tracks, so a MIDI clip
  changes no rendered sample (offline null test). Rejected alternatives: a
  separate `MIDIClip` type (would fork `clips: [Clip]`, every track/undo/
  persistence path, and the control surface — the optional payload composes for
  free); an event-stream/CC-and-pitchbend model in v1 (deferred — v1 is notes
  only, additive room left for controllers); a diff/patch note-edit command
  (whole-array set is simpler and coalesces cleanly for v0 clip sizes).
- **Per-track instrument selection: SETTLED (M3 (iv), 2026-07-05)** — an
  instrument track carries an optional `Track.instrument: InstrumentDescriptor?`
  where `nil ⇒ InstrumentDescriptor.default` (kind `.polySynth`, default
  `PolySynthParams`). `ProjectStore.setInstrument(id:kind:waveform:attack:decay:
  sustain:release:cutoffHz:resonance:gain:)` is a PARTIAL overlay: any nil
  argument keeps the track's current field, the rest re-clamp through
  `PolySynthParams.init`, so one knob edit sets one field; it throws
  `instrumentRequiresInstrumentTrack` on an audio/bus track, returns nil for an
  unknown id, and coalesces per-track under the `track.instrument:<id>` undo key
  (a synth-knob drag is one step). The engine sees changes via the existing
  `tracksDidChange`. Surfaced as `track.setInstrument` on the control protocol
  (params: `trackId` required; optional `kind` testTone|polySynth, `waveform`
  saw|square|triangle|sine validated verbatim; optional numeric ADSR/filter/gain
  clamped silently; response is the resolved `{kind, polySynth:{…}}` object).
  Snapshot rule: every INSTRUMENT track always carries a resolved `instrument`
  object (nil → default) so clients never resolve it themselves, while audio/bus
  tracks omit the field entirely. Persistence is ADDITIVE v1 — `TrackDocument`
  gains an optional `instrument` (omitted when nil, so an audio-only project
  stays byte-identical; a pre-instrument v1 bundle decodes to nil ⇒ default), no
  `schemaVersion` bump. MCP parity pending: expose as the `track_set_instrument`
  tool (TODO in `Sources/DAWControl/Commands.swift`).
- **Sampler instrument config + zone media: SETTLED (M3 (v), 2026-07-05)** — the
  `.sampler` kind carries `SamplerParams` (zones, oneShot, attack/release, gain);
  `setInstrument`'s optional `sampler:` argument REPLACES the descriptor's sampler
  config WHOLESALE (zones are set as a unit, like clip notes — not merged), while
  poly-synth knobs stay a partial overlay, so the two never disturb each other.
  Every zone's `audioFileURL` is validated OUTSIDE the edit body (existence +
  readability, reusing `importAudio`'s `importFailed` "no file at …" style) so a
  bad zone changes nothing; an empty zones array is a legal, silent, media-free
  sampler. Zone media persists like clip media: `ProjectBundle.planMedia` copies
  zone files into `media/` keyed by ZONE id, deduped against clips and each other
  (shared source → one copy, counted in `mediaFilesCopied`), a missing source at
  save warns and saves without media; save rewrites live zone URLs into the
  bundle, and reopen resolves them (an unresolvable zone is dropped, since a zone
  can't exist without a file). Persistence is ADDITIVE — `TrackDocument.instrument`
  is now an `InstrumentDocument` whose zones store a bundle-relative `media/…` ref
  (not a live URL); a pre-sampler `{kind, polySynth}` instrument decodes with
  `sampler == nil`, no `schemaVersion` bump. On the wire (`track.setInstrument`
  response + every snapshot), a resolved instrument's sampler zones emit `path` (a
  filesystem path string, the clip-audio convention) rather than the model URL;
  the input `sampler` object is field-path validated (`sampler.zones[0].path is
  required`). The `track_set_instrument` MCP tool already carries the `sampler`
  param, so parity holds.
- **AU instrument hosting: SETTLED (M3 vi-a, 2026-07-05)** — AUv2/v3 music
  devices ('aumu') host through the ADAPTER path: `AUHostRegistry` (main actor)
  instantiates and prepares the `AUAudioUnit` (maximumFramesToRender 8192 →
  mandatory `outputBusses[0].setFormat` at the graph rate → saved state →
  `allocateRenderResources` + post-allocate rate assertion), then wraps it in
  `HostedAUInstrument: InstrumentRendering`. Our `InstrumentSourceNode` clock
  stays the ONLY clock — no `AVAudioUnitMIDIInstrument` node, no second
  scheduler; events reach the AU via its captured `scheduleMIDIEventBlock` at
  in-quantum sample offsets immediately before its captured `renderBlock` runs.
  The render thread may touch ONLY those two captured blocks plus preallocated
  memory (shadow ABL, 3-byte MIDI buffer, atomic error slot); every other
  `AUAudioUnit` member is main-actor-only. Flush (`reset()`) maps to CC 123
  then CC 120 on channel 0 — never `AUAudioUnit.reset()` from the render
  thread. Component identity (`AudioUnitComponentID`, normalized FourCCs) is
  STRUCTURAL in the graph key (plugin switch rebuilds the node); name/stateData
  are not. Every AU call runs inside a timeout-raced Task (default 10 s) —
  pending/missing/failed configs render a `SilentPlaceholderInstrument`, and
  async prepare completion invalidates the node and re-reconciles. Persistence:
  `fullStateForDocument` inlines in `project.json` as base64 binary plist
  (additive `InstrumentDocument.audioUnit`, no schemaVersion bump; 8 MiB soft
  cap warns but saves), captured at save time via
  `ProjectStore.instrumentStateProvider` from a LOCAL tracks copy; restore sets
  state BEFORE allocateRenderResources. Selection is STRICT
  (`track.setInstrument audioUnit:` errors on an uninstalled component;
  `instrument.listAudioUnits` enumerates), loading is GRACEFUL (a missing
  component round-trips intact and reports `.missing`). Offline bounces build a
  FRESH registry per render (`renderMixdown` is now async across the engine
  protocol for that prepare step). v3 out-of-process hosting polish
  (entitlements, extension UI) is deferred to M9 bundling — Apple's v2 devices
  (DLS/msyn/samp) host fine from SPM today.
- **MIDI hardware input: SETTLED (M3 vii, 2026-07-05)** — one engine-internal
  `MIDIInputManager` (main actor, created lazily on first instrument-track arm
  or first `midi.listInputs`, disposed in `shutdown()`) owns a CoreMIDI client
  plus ONE UMP **protocol-1.0** input port, **omni-connected** to every online
  source (per-device selection is a later additive filter — events already
  carry the source's `kMIDIPropertyUniqueID`, which is the stable identity;
  names are display-only). Hot-plug: the notify block only hops to the main
  actor, where `setupChanged()` re-enumerates/reconnects and refreshes the
  cached device list snapshots read. The receive block runs on CoreMIDI's
  realtime thread under the render-path rules (no allocation/locks/ObjC/
  actors; it captures exactly one preallocated `MIDIInputRTContext`): it walks
  UMP words (whole-message stride), parses via the pure `MIDIUMPParser` (MT 2
  note-on/off only, vel-0 → off), and pushes 16-byte `LiveMIDIEvent` PODs into
  SPSC `LiveEventRing`s (**drop-newest** + a dropped flag; the render side
  answers a set flag with `instrument.reset()` so a lost note-off can never
  stick a voice). Thru topology: one 512-slot ring **per InstrumentRenderer**
  plus an atomically published `LiveEventFanout` of the ARMED instrument
  tracks' renderers (publish/retire-bin ≥ 1 s, strong refs pin ring memory);
  every renderer removed from the fanout gets `requestFlush()`. In
  `renderQuantum`, live events sound at **offset 0** of the quantum they drain
  in (≤ one buffer of latency; with no schedule published renderStart is 0 and
  silence returns only when the ring is also empty — thru works while
  stopped, and track meter taps show the energy). Live noteIDs set the top bit
  (never collide with schedule IDs); the stable merge gives the schedule side
  ties (off-before-on preserved); merge overflow passes the schedule alone and
  leaves live events queued. Recording: the receive block also feeds one
  global 4096-slot capture ring, drained ~30 Hz **on the main actor** into a
  `MIDICaptureSession` initialized from the SAME `PlaybackAnchor` as the audio
  writer (signed host-tick → beat math, fixed tempo per take; pre-anchor
  note-ons drop like the writer's trim, so count-in inherits; retrigger closes
  the previous note at the new onset; open notes clamp to the stop beat, which
  is computed BEFORE `stopPlayback()`). `startTake(_:audioURL:captureMIDI:)`
  supersedes `startRecording` (now a thin wrapper); the no-input watchdog arms
  only when audio capture is active, and a failed audio side discards the MIDI
  side (one-take semantics). ProjectStore lands one MIDI clip per surviving
  armed instrument track inside the SAME `performEdit("Record Take N")` as the
  audio clips (one undo removes everything); microphone gates run only when
  audio tracks are armed; **the punch window does NOT trim MIDI** (v0, pinned
  by test — notes are individually editable after the fact). Surfaced as
  `midi.listInputs` plus snapshot fields `midiInputs`/`midiEventCount`
  (monotonic activity counter). Rejected: one global thru ring (breaks SPSC
  with two armed tracks), main-actor thru (≥ 33 ms latency + schedule churn),
  and the deprecated `MIDIPacketList` port (protocol-1.0 UMP gives fixed words
  and free MIDI-2.0 downconversion; `._2_0` buys nothing in a notes-only v0).
- **Bus routing & sends: SETTLED (M4 i, 2026-07-05)** — per-bus AVAudioMixerNode under the main mix; source tracks fan out via `connect(to:[AVAudioConnectionPoint])` (one graph-rate stereo format) to one output destination (master default, or a bus) plus one dedicated send-gain AVAudioMixerNode per send (`outputVolume` = level — the only per-send gain surface we trust; `AVAudioMixingDestination` rejected as under-proven). Post-fader-only sends (tap after track volume/mute; no preFader flag in v0 — additive later). Buses output to master only and carry no sends (cycles structurally impossible; bus→bus + DAG validation is the upgrade path). Structural = routing/send-set/bus-set changes (restart seam); in-place = send level + bus params (`RoutingKey` excludes level, ClipKey philosophy). Solo v0: soloActive spans all kinds; a source is audible iff soloed or it feeds a soloed bus; bus mixers are never solo-gated (solo-in-place: send returns stay audible). Bus deletion reroutes orphans to master + drops sends inside the same undo step. Additive model (`Track.outputBusID`, `Track.sends: [Send]`) and persistence (`outputBusId`/`sends` on TrackDocument, omitted when empty — no schema bump). Surfaced as `track.setOutput|addSend|setSend|removeSend` + matching MCP tools; wire field is `busId`.
- **FX insert chains: SETTLED (M4 ii, 2026-07-05)** — all insert DSP runs inside render code we own, walking an atomically published immutable chain snapshot (`EffectChainProcessor`: heap `daw_atomic_ptr` slot + ≥ 1 s retire bin, the proven MIDI-schedule/PolySynth publish mechanism). Graph topology is touched ONLY at strip creation/removal — **no chain edit is ever structural**: add/remove/reorder = snapshot republish (surviving `ChainEffectUnit`s reused by effect id, DSP state survives), bypass = one atomic flag store (un-bypass arms a reset flag so stale tails never replay), param = atomic POD publish inside the instance. Effects appear in NO reconcile signature, so `willMutateRoutingTopology` never fires for a chain edit — the M4 (i) live-rewire failure class cannot occur by construction. Per strip: instrument chains walk inside `InstrumentRenderer.renderQuantum` (zero new nodes; the silence path still processes so tails ring); audio tracks render `players → sumMixer (SRC/sum, unity, no tap) → ChainHostAU → trackMixer (fader/pan/mute, tap, fan-out)`; buses render `feeders → busSumMixer → ChainHostAU → busMixer`. Inserts are therefore pre-fader everywhere, meters read post-FX, and post-fader sends carry insert FX. **`ChainHostAU`** (identity `aufx`/`dwch`/`DAWP`) is an `AUAudioUnit` subclass registered in-process via `AUAudioUnit.registerSubclass` and instantiated SYNCHRONOUSLY through `AVAudioUnitEffect(audioComponentDescription:)` — proven working from the bare-SPM/CLT process by the gating spike test (bit-exact passthrough, start/stop-cycle survival); no app bundle, no entitlements, no Xcode. Its render block pulls input in place (output ABL handed to `pullInputBlock`) and walks the chain; empty chain = pull-through with zero added latency, pinned bit-exact by `emptyChainIsBitExactTransparent` and the pre-existing unity/null suites. v0 honesty: bypass toggles click (hard swap; crossfade is an additive walk change), stop cuts chain tails via reset flags (matches the instrument flush contract). Built-in kinds: gain/trim (M4 ii, ~5 ms param smoothing, exact at the prepared value) plus the M4 (iii) pack — eq (4-band RBJ biquads, TDF2/Float64, a 0 dB band is skipped so neutral is bit-exact), compressor (instant-attack/5 ms-decay peak detector → log-domain quadratic soft knee → one-pole attack/release on the gain signal → makeup; exact unity below threshold), limiter (fixed 5 ms lookahead delay + sliding-window-max envelope — output ≤ ceiling by construction, bit-exact delayed passthrough below it), and the M4 (iv) pack — reverb (Freeverb topology: 8 damped combs + 4 series allpasses per channel at the classic tunings, 23-sample stereo spread, up-to-200 ms pre-delay, mid/side width on the wet only), delay (integer stereo lines sized for 2 s — echo at exactly round(timeMs×rate/1000) samples, one-pole high-cut in the FEEDBACK path only so the first echo is unfiltered, optional ping-pong crossfeed), saturator (tanh with a fixed −driveDb/2 dB compensation for unity-ish loudness at mix 1; alias-honest v0, no oversampling), gate (the compressor's 5 ms-decay linked peak detector → linear attack/hold/release ramps landing EXACTLY on 1/0 — fully open is bit-exact passthrough, fully closed is true silence), chorus (2 voices per channel, sine LFO ±depth around a fixed 15 ms center, linear-interp taps, 90° stereo / 180° inter-voice phase offsets); every pack-2 `mix` at 0 is bit-exact dry, and all five report zero latency. PDC hook: `EffectRendering.latencySamples` sums per strip through `insertChainLatencySamples(forTrack:)` (0 for all kinds except the limiter's lookahead, 240 samples @ 48 kHz) — M4 (viii) consumes it without touching the render path; AU effects (M4 v, SETTLED 2026-07-05) drop into the same walk as `HostedAUEffect`: a pull-model adapter serving the in-place buffers through a `@Sendable` input block (stash box, no main-actor capture), rendering into a preallocated scratch ABL and copying back, passing DRY on render error; `latencySamples` = `au.latency`×rate at prepare (AUPeakLimiter 96 @ 48 kHz) feeds the same per-effect latency plumbing. The registry reuses the instrument timeout-raced prepare — strict-select on `fx.add kind=audioUnit` (shared component-triple parse; `fx.listAudioUnits` enumerates `aufx`), graceful placeholder+warning on load, fullState base64 in `.dawproj` via `effectStateProvider`; adds are async prepare → single-strip invalidate → republish, and even a component swap is a chain republish, never a node rebuild. AUv2-bridge gotcha (fixed): `inputBusses[0]` is DISABLED by default — enable it before `allocateRenderResources` or every render fails with kAudioUnitErr_NoConnection and the pull block never fires. Rejected: per-effect graph nodes (every chain edit becomes the live-mutation class that produced the M4 (i) silent-leg defect and bus-removal segfault), tap/source-node pumps (taps can't feed the graph; cross-node pulls are unsupported), and hosting Apple built-in effects as chain hosts (no processing callback → collapses into per-effect nodes).
- **Automation lanes: SETTLED (M4 vii, 2026-07-05)** — automation is a per-track collection `Track.automation: [AutomationLane]` (additive; empty default; `TrackDocument` gains optional `automation` omitted when empty so pre-automation saves stay byte-identical — no schemaVersion bump; the live `Track` wire encoding always carries the array, the sends/effects precedent). A lane is `{id, target, points, isEnabled}` with AT MOST ONE lane per target per track (store-enforced; `addAutomationLane` is idempotent). `AutomationTarget` is an enum: `.volume`, `.pan`, `.sendLevel(sendID:)`, `.effectParam(effectID:paramName:)` — persistence-stable NOW, but v0 REJECTS `.sendLevel` (send gain lives on an `AVAudioMixerNode.outputVolume` we own no render code for — honest deferral) and `.effectParam` on `.audioUnit` effects (empty spec surface in v0; `AUParameter`/`scheduleParameterBlock` is the deferred upgrade). Master-volume lanes DEFERRED (master is not a `Track`). `AutomationPoint` is `{beat ≥ 0, value, curve}` where `curve ∈ {linear, hold}` describes the segment LEAVING the point (bezier deferred, additive); points store canonically ordered with equal-beat last-wins dedupe, values clamp through the target's EXISTING range. Evaluation semantics live in ONE pure DAWCore function, `AutomationLane.value(atBeat:)` (before first = first value; after last = last value; empty = inert), reused by UI, engine main-actor side, and headless tests. **Engine read path**: the M4 (i) live-mutation class is excluded BY CONSTRUCTION — automation appears in NO reconcile signature; evaluation runs inside render code we already own. Each strip gets a permanent `AutomationRenderer` created at strip creation: a heap `daw_atomic_ptr` slot publishing an immutable `AutomationSchedule` (the `MIDIEventSchedule` pattern exactly: generation, live/offline first-pull-latch mode, per-target breakpoint arrays precomputed to schedule-relative Int64 sample times at fixed tempo; ≥ 1 s retire bin; render side alloc/lock/ObjC-free with preallocated cursors). Audio/bus strips evaluate at the END of `ChainHostAU.internalRenderBlock` (post-chain-walk = fader position); instrument strips at the end of `InstrumentRenderer.renderQuantum`. Zero new nodes, zero graph mutations. Point edits during playback republish WITHOUT restart (cursor re-seeks by bounded binary search); seek/tempo/loop-wrap reuse the existing restart; stop unpublishes automation schedules alongside MIDI ones. Fidelity (v0-honest): quantum-endpoint evaluation with per-sample linear ramp — EXACT for linear segments; interior breakpoints chord across one quantum (≈ 10.7 ms @ 512/48 kHz). **Override rule**: an enabled non-empty volume lane REPLACES the fader — `applyParameters` pins the strip mixer's `outputVolume` to (gated ? 0 : 1) and the render stage supplies gain, so mute/solo gating stays on the mixer node and no AVAudioMixerNode property moves during playback; enabled pan lane → `mixer.pan = 0`, stage applies equal-power pan (center bit-exact skip, the EQ 0 dB precedent). While STOPPED, `applyParameters` applies `value(atBeat: playhead)` on the main actor — stopped previews are WYSIWYG. Post-fader sends inherit volume/pan automation free (stage is upstream of the trackMixer fan-out). Built-in effect-param lanes evaluate per quantum by storing into the SAME lock-free POD param slots main-actor `applyParams` uses (last-writer-wins race with a concurrent UI edit is benign). Offline parity mandatory: same both-sides-of-start publish seam, `.offline` first-pull epoch latch, analytic bounce assertions. **Read modes**: v0 is READ-ONLY playback of drawn lanes; touch/latch/write designed (transient per-track mode, gesture-coalesced commit) but deliberately post-v0. Surfaced as `automation.addLane|removeLane|setPoints|setLaneEnabled` (whole-array setPoints, 4096 cap; undo keys `automation.points:<laneID>`, `automation.enable:<laneID>`) + 4 MCP tools. Rejected: main-actor-timer driving of `AVAudioMixerNode.outputVolume/pan` (UI-rate fidelity, uncontrolled internal ramping, NO offline parity — the disqualifier); a project-level automation store keyed by trackID (orphan cleanup + second undo surface; hanging lanes on `Track` composes with the snapshot journal for free).
- **Latency compensation (PDC): SETTLED (M4 viii, 2026-07-05)** — compensation is a per-strip preallocated ring delay inside ChainHostAU, inserted between the chain walk and the vol/pan automation stage — upstream of the strip mixer's fan-out, so ONE ring aligns the dry feed and every send tap at once. Alignment is staged global-max: track strips pad to `T` (max all-effects track-chain latency), bus strips to `B` (bus analog), master hears everything at `T + B`; a no-sends direct-to-master track pads straight to `T + B`; the sole residual skew (direct-to-master track WITH sends while `B > 0` — exact per-path alignment with one delay per strip is mathematically impossible) is reported per-strip (`compensationSkewSamples`), not silently wrong, and vanishes in the canonical `B = 0` reverb-send case. Totals are bypass-stable: bypassed effects count in `T`/`B` and reported totals (stable A/B audition, no global retarget on bypass gestures) while the ring absorbs the actual-delay difference (`comp = stageTarget − chainLatencyActive`); only effect removal/addition moves the maxima. The plan is pure DAWCore math (`LatencyCompensation.swift`: `PDCPlan.compute`), recomputed on the main actor on chain edits, bypass toggles, hosted-AU latency capture, routing changes, rate changes, and cold start, and published as ONE atomic u32 target per strip (the bypassFlag pattern — deliberately NOT a snapshot republish, since one edit can retarget every strip); retargets declick via a dual-read crossfade (≤128 samples) inside the same preallocated ring. Cap 16 384 samples (~341 ms @ 48 kHz; 32 768-float pow-2 rings allocated only in `allocateRenderResources`), clamped-with-warning beyond (`compensationClamped`). Timeline semantics are v0 output-delayed: the whole mix lands uniformly `T + B` late against the ruler; sequencer clock, loop wrap (rings deliberately NOT flushed at wrap — a delayed signal carries across the seam), count-in, and stopped-WYSIWYG are untouched; rings reset on transport start/seek/cold start and at offline-render start, which — with identical snapshots, targets, and render code — keeps the live/offline cross-diff at exactly 0.0. Reporting is snapshot-only and additive (per-strip `chainLatencySamples`/`compensationSamples`/clamped/skew; global `maxPathLatency`, stage targets, `outputLatencySamples` incl. common-path master chain); no new control command until a monitoring-driven `pdc.setEnabled` is warranted. Deferred: live-input monitoring paths, schedule-advance timeline mode, per-mix-point optimal alignment, FX-param-automation compensation, metronome path alignment. Full spec: scratchpad pdc-spec.md (session 2026-07-05).
- **Clip gain/fades/crossfades: SETTLED (M5 i-b, 2026-07-05)** — clip gain applies as live `AVAudioPlayerNode.volume` into the strip sumMixer (dB→linear at reconcile; mid-play gain edits are seamless, no restart, via a `clipGainChanged` in-place protocol path). Fades are baked at schedule time: `scheduleAll` splits each faded clip into fade-in buffer / streamed middle segment / fade-out buffer on the clip's existing player, multiplying the normalized fade shape (evaluated per frame from `Clip.envelopeGain(atBeat:)`, the single domain authority) into copies of ONLY the fade windows (memory bounded to fades, ~0.37 MB/s stereo 48k). Fade edits re-bake and ride the existing `tracksDidChange` restart seam, same class as clip move/resize. Crossfades are purely representational: two overlapping clips with equal-power (default, sin/cos) or linear fades on their own players, summed by the sumMixer — the engine has no crossfade concept. Rejected: a per-strip clip-envelope schedule in ChainHostAU (AutomationSchedule pattern) is post-sum and cannot express two simultaneous per-clip gains — exactly wrong during any crossfade overlap, not an approximation; per-clip envelope AUs / custom source nodes add graph-mutation surface (the M4 (i) failure class) or an RT disk-streaming subsystem for marginal benefit. Zero new render-thread code, so the no-alloc/no-lock invariant and live/offline parity (shared `scheduleAll`, cross-diff 0.0) hold by construction. Fixed-tempo v0: fade windows precompute to file-rate frames once per schedule; loop wrap and tempo change already restart → re-bake. Full memo: scratchpad clip-envelope-spec.md (session 2026-07-05).
- **Time-stretch seam: SETTLED (M5 ii, 2026-07-05)** — offline stretch/pitch uses vendored signalsmith-stretch (MIT) behind a flat-C shim target (`CSignalsmithStretch`) and an `OfflineStretcher` facade in DAWEngine; DAWCore gains only three additive clip fields (`stretchRatio` 0.25–4 default 1, `pitchShiftSemitones` ±24 default 0, `formantPreserve` default false — all omit-when-default). Ratio is ABSOLUTE (tempo-independent) in v0; `lengthBeats` remains the timeline authority and the source window is derived, so ratio=1 is structurally identical to today and the stretch handle is a compound store op (`stretchClip(toLengthBeats:)` = set length + scale ratio, window-invariant). Renders are full-source-file, content-keyed CAFs in `~/Library/Caches/DAWPro/StretchRenders/` — never inside `.dawproj` (regenerable by definition); full-file rendering makes split points seamless (shared phase-vocoder output), lets clips share cache entries, and means tempo/trim/move edits never invalidate — only param or source-file changes do, plus a `stretchEngineVersion` bump. At schedule time the stretched CAF simply replaces the clip's source: file offset maps as `startOffsetSeconds × ratio`, and the i-b fade bake runs unchanged because the stretched file is timeline-domain audio. `ClipKey` gains the three fields (edits ride the existing `tracksDidChange` restart); rendering is an engine-owned detached job (M3 vi-a pattern) with per-clip latest-wins + 250 ms debounce, silence while pending, atomic-rename commit, and a pull-based `clipStretchStatus` on `AudioEngineProtocol` surfacing `stretchRendering`/`stretchError` in snapshots. Surface: `setClipStretch`/`stretchClip` store ops, `clip.setStretch`/`clip.stretchToLength` commands, `clip_set_stretch`/`clip_stretch_to_length` MCP tools. Deferred: real-time preview (later via AVAudioUnitTimePitch scrub, not signalsmith `splitComputation`), tempo-sync mode, continuous formant factor. Identity (1.0/0) is an exact bypass — no render, no cache, byte-identical schedule. Nothing on the render thread changes; nothing here needs full Xcode. Fallback if the ACE-Step vocal listening spike (ii-e) fails: Rubber Band commercial. Full memo: scratchpad stretch-seam-spec.md (session 2026-07-05).
- **Take comping & quantize: SETTLED (M5 iii design, 2026-07-06)** — takes live at the TRACK level (`Track.takeGroups: [TakeGroup]`, additive; lane payload = a full `Clip` in absolute timeline beats, audio or MIDI, never nested); the comp is a whole-array segment list (`CompSegment {laneID, startBeat, endBeat}`, gaps legal) and every comp edit deterministically FLATTENS into ordinary clips in `track.clips` marked by an additive `Clip.takeGroupID` — the engine, offline renderer, snapshot, and media pipeline never learn about lanes. Join crossfades reuse the M5 (i-b) representational mechanism verbatim: adjacent members overlap by the group's `crossfadeSeconds` with equal-power fade-out/in, summed by the strip sumMixer. Members are store-managed: all clip-edit/stretch/note/remove ops reject them (`take.flatten` is the escape hatch). Recording integration: a finished audio take overlapping an existing group appends a lane (newest-wins comp); overlapping plain clips form a group; only RECORDING triggers grouping. Loop-cycle recording deferred (model already N-lane ready). Quantize is DESTRUCTIVE with snapshot-journal undo: shared pure `QuantizeTarget` evaluator (grid + MPC swing 50–75 + groove offsets) drives `quantizeClipNotes` (MIDI) and `AudioQuantizePlan` (audio v0 = slice at transients, monotone nudge, source-continuation joins with equal-power crossfades — NO per-slice stretch, because the full-source-file content-keyed stretch cache would take N full-file renders per gesture; elastic-audio v1 is the flagged windowed-cache follow-up; non-identity-stretch clips rejected v0). Transient detection is engine-side offline analysis (hand-rolled vDSP spectral flux 1024/256, median-adaptive threshold, 30 ms peak-pick) behind one additive async `detectTransients` on `AudioEngineControlling`, content-key-cached as JSON sidecars (`~/Library/Caches/DAWPro/TransientMaps/`, StretchRenderCache discipline), never persisted or snapshotted. Groove templates are project-level per-slot offset tables (`GrooveTemplate {gridBeats, cycleBeats, offsets}`) extracted from MIDI onsets or transient maps, plus computed built-in swing presets by reserved name; applied by value through both quantize paths. Surface: `take.group|setComp|select|removeLane|flatten|move|setCrossfade`, `clip.quantize|detectTransients|quantizeAudio`, `groove.extract|list|remove` + 13 matching MCP tools. Zero render-thread changes; nothing needs full Xcode. Rejected: takes inside a parent clip (comp output is N clips — no stable parent), container-clip recursion (every clip iterator + engine learns nesting), takes as muted sibling clips (engine must honor a mute flag; overlap-sum would sound all takes). Full spec: scratchpad comping-quantize-spec.md (session 2026-07-06).
- **Stem export & loudness-normalized bounce: SETTLED (M5 iv design, 2026-07-06)** — stems are the MASTER-INPUT PARTITION: one stem per direct-to-master source track (dry post-fader strip, sends stripped) plus one per bus (everything routed AND sent into it, through the bus chain and fader — send contributions fold into the DESTINATION bus stem, never the source stem, so nonlinear bus FX stay correct); stems include the v0 master stage (a single linear `masterVolume`, which commutes with summation). Normative invariant: **Σ stems ≡ the mixdown, sample-aligned, null residual ≤ 1e-4 peak with built-in DSP** — which REQUIRES every solo pass to run under the FORCED full-session PDC plan (new `offlineCompensationTargets` engine probe feeding the existing `OfflineRenderer.compensationTargets` seam; a subset auto-plan combs, test-proven as a negative control). Render strategy v0: N sequential fresh-`OfflineRenderer` passes driven by a pure DAWCore `StemPlan` track-list transform (bus passes reroute foreign direct-outs to a silent dummy bus because the graph's missing-bus fallback is master); single-pass taps rejected (async, 1024-quantized, lossy under load). Loudness is hand-rolled BS.1770-4 in **pure DAWCore** `Loudness.swift` (K-weighting biquads re-derived at any rate and pinned to the 48 k tables ≤ 1e-6; 400 ms/75 % blocks; −70 LUFS absolute then −10 LU relative gate; max momentary/short-term included, LRA deferred; **4× oversampled true peak per Annex 2** — this closes the M5 (ii-e) “master-bus true-peak stage later” flag as an OFFLINE stage) — distinguished from the TransientAnalyzer-in-DAWEngine precedent because input is pure rendered buffers, not file URLs; no Accelerate in DAWCore, libebur128 rejected (vendored C dep for ~300 lines of analytically-testable math). Normalization: single static gain to `lufsTarget`, true-peak ceiling (default −1.0 dBTP) CLAMPS the gain — no limiter stage v0, the report says `limitedByCeiling` honestly and the agent can add the built-in bus limiter and re-bounce; target omitted = measure-only; stems are never normalized (balance + invariant); silence + target throws `bounceSilent`, measurements use nil for below-gate (JSON has no −inf). Engine seam: three additive protocol methods `renderOffline` (buffer-out mixdown, WYSIWYG stretch await intact), `offlineCompensationTargets`, `writeAudioFile`; `renderMixdown` refactored over them, contract frozen. Surface: `render.measureLoudness` / `render.bounce` / `render.stems` + 3 MCP tools (71→74), Float32 interleaved WAV everywhere (no baked headroom — stems may exceed 0 dBFS on disk, `truePeakDbtp` surfaces it). Zero render-thread changes; nothing needs full Xcode; export-panel UI deferred. Future flags: master insert chain re-scopes stems to pre-master; parallel/off-main-actor passes; shared-gain stem normalization; LRA. Full spec: scratchpad stem-lufs-spec.md (session 2026-07-06).
- **C++ DSP core**: if AVAudioEngine graph limits us (PDC, freeze, flexible routing), move the graph to a C++ CoreAudio engine behind the same `AudioEngineProtocol`. Re-evaluate at M4.
