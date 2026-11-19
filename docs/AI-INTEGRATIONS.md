# AI Integrations

## Providers & responsibilities

| Capability | Provider | Where it runs |
|---|---|---|
| Lyrics, song structure, naming, music-theory reasoning, "Explain this" | Anthropic (Claude) primary, OpenAI fallback | `AIServices` in-app + `mcp-server` tools |
| Full song / vocal / singing generation | **ACE-Step-1.5 (local sidecar)** — primary | local FastAPI service on `127.0.0.1:8001` |
| Voice conversion (turn a vocal into a trained voice) | RVC sidecar, loopback only | local service on `127.0.0.1:8002` (`Sources/AIServices/VoiceConversionManager.swift`, `VoiceConversionClient.swift`) |
| Singing typed words on a melody | SoulX-Singer behind our own facade, loopback only | local service on `127.0.0.1:8004` (`Sources/AIServices/SingingSidecarManager.swift`, launched by `scripts/sing/run.sh`) |
| Song generation, cloud fallback | Suno — dormant/opt-in only (no official public API as of 2026-07-05) | `mcp-server` + `AIServices` (disabled without key) |
| UI asset generation (icons, textures, backgrounds) | OpenAI GPT Image (`gpt-image-2`) | `scripts/gen-art.mjs` (build-time only, never runtime) |
| DAW control by agents | MCP (`mcp-server/`) → control WebSocket | external MCP clients (Claude Code, Claude Desktop, any) |

## ACE-Step-1.5 (primary song engine)

Verified 2026-07-05 — full detail in `docs/research/2026-07-05-ace-step-local-song-generation.md`.

- **What**: open music-generation foundation model (ACE Studio + StepFun lineage), GitHub `ace-step/ACE-Step-1.5`. **MIT license for code and weights** — no cloud dependency, no ToS risk, generations usable commercially.
- **Chosen tier for this machine (M5 Max, 128 GB)**: the largest official tier — **XL DiT (~5B, ~8.3-9 GB bf16) + Qwen3 4B LM planner (~8.4 GB)** + 48 kHz stereo VAE. Peak working memory well under 50 GB, leaving ample headroom for the DAW. Smaller tiers (2B DiT, 0.6B/1.7B LM) exist if we ever ship to leaner machines.
- **Capabilities we build on**: full songs with sung vocals from bracketed-structure lyrics ([verse]/[chorus]), style/caption prompting, 10 s–10 min durations, stem separation, repaint/retake/cover/audio2audio editing. Community consensus: vocal quality good but a notch below Suno-class cloud; local iteration speed and zero cost offset this.
- **Apple Silicon**: official hybrid MLX + PyTorch/MPS stack with macOS launch scripts. No verified M5-class benchmarks yet — measure on first install.
- **Integration**: run its built-in FastAPI server as a **sidecar** (`ACE_STEP_URL`, default `http://127.0.0.1:8001`, async job queue). `AIServices` gets an `ACEStepClient: SongGenerating`; mcp-server gets a matching `generate_song` tool. The DAW manages the sidecar lifecycle in M6 (detect → offer install → start/stop → job polling → import results as tempo-mapped tracks/stems).
- **Sidecar lifecycle — SHIPPED (M6 i, 2026-07-06)**: `scripts/ace-step/install.sh` (idempotent venv + weight download for the XL-turbo/XL-sft DiT + 4B LM tier, ~55-70 GB) and `scripts/ace-step/run.sh` (starts the FastAPI server, loopback-only) plus `Sources/AIServices/SidecarManager.swift` (an actor: `status()`/`start()`/`stop()`) exposed as `ai.sidecarStatus`/`ai.sidecarStart`/`ai.sidecarStop` on the control protocol and `ai_sidecar_status`/`ai_sidecar_start`/`ai_sidecar_stop` MCP tools — process management only, no generation yet. Health check is ACE-Step's own real `GET /health` (verified against `acestep/api/http/model_service_routes.py`), wrapped `{"data": {status, service, version, loaded_model, loaded_lm_model, ...}}`. See `docs/ARCHITECTURE.md`'s `ai.sidecarStatus` entry for the full status-state contract.
- **Generation client — SHIPPED (M6 ii, 2026-07-06), BOX STAYS UNCHECKED until a real generation succeeds**: `Sources/AIServices/ACEStepClient.swift` (an actor conforming to `SongGenerating`, reshaped this cycle from a single-call to an async submit/poll protocol — see below) talks to the sidecar's own job-queue REST API, coded directly against the upstream FastAPI route source (`scripts/ace-step/runtime/src/acestep/api/http/release_task_route.py`, `query_result_route.py`, `audio_route.py`, `release_task_request_builder.py`, and `api_server.py`'s `_wrap_response` envelope), not guessed. Exposed as `ai.generateSong`/`ai.generationStatus` on the control protocol and `generate_song`/`generation_status` MCP tools; full field/error contract in `docs/ARCHITECTURE.md`'s entry for the two commands. No `ai.generationCancel`/`generation_cancel`: the upstream API has no job-cancel endpoint (verified — cancellation there is only an internal `asyncio` task cancel on server shutdown). Weights for the actual model tier are still downloading as of this writing (background `install.sh` run) — every test/E2E this cycle runs against a stub HTTP server or a stub `run.sh` (never the real ACE-Step process), so `docs/ROADMAP.md`'s M6 (ii) checkbox stays unchecked until a real generation round-trips against the healthy, weights-complete sidecar.

### Generation flow (async job: submit → poll → import)

1. **Precondition**: `ai_sidecar_status` must report `healthy` (call `ai_sidecar_start` first if not — model load can take a while; a `starting` result is not an error, just poll again).
2. **Submit**: `generate_song` with `prompt` (style/caption text) and optional `lyrics` (ACE-Step's bracketed-structure format — section tags on their own line, e.g.:
   ```
   [Verse 1]
   Walking home in the rain
   [Chorus]
   We rise together (together)
   ```
   parentheses mark backing vocals; omit/blank `lyrics` for an instrumental) plus optional knobs (`durationSeconds`, `seed`, `bpm`, `keyScale`, `timeSignature`, `vocalLanguage`, `guidanceScale`, `inferenceSteps`). Returns immediately: `{jobId, state: "queued", queuePosition?}` — the song is NOT ready yet.
3. **Poll**: `generation_status` with `jobId` every 5-10 seconds (not a tight loop — generation on Apple Silicon is reported by the community to commonly take **roughly 2-10 minutes per track** depending on duration/hardware; there is no official Apple-Silicon benchmark yet, so treat this as a rough expectation, not a promise — see `docs/research/2026-07-05-ace-step-local-song-generation.md` §3). `state` moves `"queued"` → `"running"` (with best-effort `progress`/`stage`/`statusText`) → `"succeeded"`. A job that failed upstream surfaces as a TOOL ERROR from `generation_status` (the sidecar's own failure detail, e.g. an out-of-memory message), never a silent `"failed"` state. Note the measured reality (m17-h): a live job's stage is rich pipeline text ("Generating music (batch size: 2)...", "Decoding audio..."), never a literal "running" — clients must not gate on stage string equality (the app's own client once did, and every job read as queued forever). In the app, every generation job — including ones agents start over MCP — surfaces in the unified progress card with an AGENT origin chip.
4. **Fetch**: the FIRST poll that observes `"succeeded"` downloads the finished audio to a local file and reports it as `audioPath`; later polls of the same `jobId` reuse that same cached path (no repeated downloads). A succeeded poll ALSO surfaces the sidecar's result metadata as additive fields — `prompt`, `bpm`, `durationSeconds`, `genres`, `keyScale`, `timeSignature` (all omitted when the sidecar didn't report them, and absent on queued/running polls) — the raw material for the import step's track-naming and tempo adoption.
5. **Import** (M6 iii-a): call `import_generation` with the succeeded `jobId` (do NOT hand `audioPath` to `clip_add_audio` by hand — that path stays available but skips the metadata step). `import_generation` copies the finished WAV into a stable, project-adjacent location (the volatile sidecar cache is not safe to reference from a saved project), creates a new **AI-flagged** audio track + clip (violet in the UI — "violet always means AI-generated") at `atBeat` (default 0), and adopts the project tempo from the generation's `bpm`. Tempo adoption follows `setProjectTempo`: omit it to auto-adopt ONLY when the project has no other clips yet (the first imported track sets the grid; a later import never silently moves everything), or pass `true`/`false` to force/forbid it. Track name defaults to `"AI: <first words of the prompt>"`, or supply `trackName`. The whole import is ONE undo step — `edit_undo` removes the track AND restores the previous tempo together. Returns `{trackId, clipId, adoptedTempoBPM?}`. A still-running or unknown/expired job returns an actionable error pointing back at `generation_status`. Full multitrack stem import is a later roadmap item (M6 iii-c; ACE-Step's own "Track Separation" capability is not yet wired up).

## Keys & security

- Keys come from environment / `.env` (dev) and macOS Keychain (app, M6). Never committed, never logged, never sent to any host other than the provider's own API.
- The control WebSocket and the ACE-Step sidecar bind to localhost only. No remote control without an explicit future opt-in + auth story.

## Voices & singing — current position

**Singing is now a local capability**: ACE-Step-1.5 generates sung vocals from our lyrics (Anthropic/OpenAI-written or user-written) directly on this machine. Recorded human vocals are first-class via M2 recording. Suno remains a dormant cloud fallback behind the same `SongGenerating` protocol, enabled only if an official API materializes and the user opts in.

**What singing does now (2026-10-07).** You can type words, put them on a MIDI melody clip, and have a voice sing that melody. The sung take lands on a new audio track as one undo step.

- **Words on a melody.** One word goes on each note. The app plans which word goes on which note, sings the lines one at a time, then checks the result.
- **Languages.** English, Chinese (Mandarin, `zh`) and Chinese (Cantonese, `yue`). Spanish is not supported yet. Any other language code is refused when you sing; it is never sung as English by mistake.
- **Harmonies.** One singing job can add up to 3 extra parts (a harmony line, the clip's own chord notes, another melody clip, or a double of the tune). Each part goes on its own new track.
- **Your own voice.** Give the app a short recording of one person singing alone, from a file or from a clip already in your song, and it saves it as a voice that can sing your words.
- **Consent first.** The singing engine is a large one-time download. It installs only after you agree by clicking Install in DAW Pro's window. An AI agent can ask for the install but cannot approve it.
- **Everything stays on this Mac.** Both sidecars listen on `127.0.0.1` only.
- **The scripts ship inside the app.** `scripts/bundle.sh` copies `scripts/sing` into the app's `Contents/Resources/sing` before code signing, so an installed app can start the engine without the source tree.

Designs: `docs/design/2026-09-27-p2-sing-integration.md` (the engine, the install, the job) and `docs/design/2026-10-06-p2-sing-expansion.md` (languages, harmonies, singing style).

## Model selection (runtime app features)

- Fast/cheap interactions ("Explain this", naming): Claude Haiku 4.5 (`claude-haiku-4-5` — there is no Haiku 5).
- Lyrics & creative writing: Claude Sonnet 5 (`claude-sonnet-5`) — also the copilot's default, and `mcp-server/src/ai.ts`'s single `ANTHROPIC_MODEL`.
- Complex musical reasoning (arrangement critique, mix analysis): Opus-class, user-selected per copilot session, never the default — `claude-opus-5` is the current flagship row; `claude-fable-5` stays offered as the highest-capability (and priciest) tier above it.
Keep the model IDs in one config (`AIServices/AIConfig.swift` for defaults, `AIServices/AnthropicModelCatalog.swift` for the per-model picker + request-shaping table) — never scattered in call sites.
