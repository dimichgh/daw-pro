# AI Integrations

## Providers & responsibilities

| Capability | Provider | Where it runs |
|---|---|---|
| Lyrics, song structure, naming, music-theory reasoning, "Explain this" | Anthropic (Claude) primary, OpenAI fallback | `AIServices` in-app + `mcp-server` tools |
| Full song / vocal / singing generation | **ACE-Step-1.5 (local sidecar)** — primary | local FastAPI service on `127.0.0.1:8001` |
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
3. **Poll**: `generation_status` with `jobId` every 5-10 seconds (not a tight loop — generation on Apple Silicon is reported by the community to commonly take **roughly 2-10 minutes per track** depending on duration/hardware; there is no official Apple-Silicon benchmark yet, so treat this as a rough expectation, not a promise — see `docs/research/2026-07-05-ace-step-local-song-generation.md` §3). `state` moves `"queued"` → `"running"` (with best-effort `progress`/`stage`/`statusText`) → `"succeeded"`. A job that failed upstream surfaces as a TOOL ERROR from `generation_status` (the sidecar's own failure detail, e.g. an out-of-memory message), never a silent `"failed"` state.
4. **Fetch**: the FIRST poll that observes `"succeeded"` downloads the finished audio to a local file and reports it as `audioPath`; later polls of the same `jobId` reuse that same cached path (no repeated downloads).
5. **Import**: hand `audioPath` to `clip_add_audio` (creating a track first with `track_add` if needed) to bring the generated song into the session as a tempo-mapped clip. Full multitrack stem import is a later roadmap item (ACE-Step's own "Track Separation" capability is not yet wired up).

## Keys & security

- Keys come from environment / `.env` (dev) and macOS Keychain (app, M6). Never committed, never logged, never sent to any host other than the provider's own API.
- The control WebSocket and the ACE-Step sidecar bind to localhost only. No remote control without an explicit future opt-in + auth story.

## Voices & singing — current position

**Singing is now a local capability**: ACE-Step-1.5 generates sung vocals from our lyrics (Anthropic/OpenAI-written or user-written) directly on this machine. Recorded human vocals are first-class via M2 recording. Suno remains a dormant cloud fallback behind the same `SongGenerating` protocol, enabled only if an official API materializes and the user opts in.

## Model selection (runtime app features)

- Fast/cheap interactions ("Explain this", naming): Claude Haiku / small models.
- Lyrics & creative writing: Claude Sonnet.
- Complex musical reasoning (arrangement critique, mix analysis): Claude Opus-class, only when explicitly invoked.
Keep the model IDs in one config (`AIServices/AIConfig.swift`) — never scattered in call sites.
