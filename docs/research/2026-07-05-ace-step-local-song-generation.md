# ACE-Step-1.5 as the local song-generation engine for DAW Pro

Date: 2026-07-05
Author: research-analyst (agent)
Target machine sized against: Apple M5 Max, 128 GB unified memory, 40-core GPU, macOS 26 (Darwin 25.4), 1.2 TB free disk. DAW + OS assumed to want 20-30 GB reserved, leaving **~98-108 GB usable** for the model runtime.

All claims below are sourced from primary material (GitHub repo, Hugging Face model cards/API, the arXiv paper, official docs pages) unless explicitly marked **[community/reported]** or **[opinion]**. Anything that can change over time (release versions, pricing, ToS) is date-stamped.

---

## 1. Does "ACE-Step-1.5" exist? What is it exactly?

Yes — verified directly on GitHub and Hugging Face. Two generations exist, both co-led by **ACE Studio** and **StepFun**:

- **ACE-Step v1** — the original release. HF repo `ACE-Step/ACE-Step-v1-3.5B` (~3.5B params), GitHub `github.com/ace-step/ACE-Step`, license **Apache-2.0**. Still live and unarchived as of 2026-07-05; its README now points users to v1.5 as "our latest and most advanced model."
- **ACE-Step 1.5** — the successor, and the subject of this report. Separate repo `github.com/ace-step/ACE-Step-1.5`, HF org `huggingface.co/ACE-Step`, license **MIT** (note: license changed from Apache-2.0 to MIT between v1 and v1.5 — see §5). Paper: [arXiv:2602.00744](https://arxiv.org/abs/2602.00744), "ACE-Step 1.5: Pushing the Boundaries of Open-Source Music Generation" (submitted 2026-01-31, last revised 2026-02-06, 7 authors incl. Junmin Gong, Yulin Song, Xuerui Yang).
- Release cadence (from GitHub Releases, checked 2026-07-05): first public builds early Feb 2026 (2B `base`/`sft` checkpoints uploaded to HF 2026-02-06/07) → v0.1.4 (Apr 2, API refactor) → **v0.1.6 (2026-04-03): XL (4B) model family added, incl. Apple-Silicon MLX compatibility for XL** → v0.1.7 (Apr 24: DCW sampler, community VAE swap, Apple-Silicon peak-memory tuning) → **v0.1.8 (2026-05-18, latest as of this report): Docker support, "Retake" variation generation, "Flow-Edit" audio editing**. Actively maintained, ~4 releases in 3 months.

### All model variants/checkpoints (verified via Hugging Face API `?blobs=true`, exact byte sizes)

**Diffusion Transformer (DiT) — the audio decoder, standard family, ~2.39B params (bf16):**

| Checkpoint | Params | Weight size (bf16 safetensors) | Notes |
|---|---|---|---|
| `acestep-v15-base` | 2,393,872,518 | ~4.79 GB (`model.safetensors`) | Pretrain-only; supports every editing mode (cover/repaint/lego/complete) but needs a second forward pass per step (double activation VRAM) |
| `acestep-v15-sft` | ~2.4B | ~4.8 GB | SFT-tuned for quality; some edit modes (extract/lego/complete) not supported per GPU_COMPATIBILITY.md |
| `acestep-v15-turbo` | ~2.4B | ~4.8 GB | Distilled to 8 diffusion steps (from 50) — fastest, used as the default download |

**XL family, released 2026-04-02/03, safetensors metadata reports ~4.987B params:**

| Checkpoint | Weight size as shipped (raw, F32) | Weight size (bf16, "-diffusers" repos) |
|---|---|---|
| `acestep-v15-xl-base` | 4 shards, ~19.95 GB total (FP32) | `acestep-v15-xl-base-diffusers`: bf16, transformer ~8.3 GB |
| `acestep-v15-xl-sft` | ~19.95 GB (FP32) | `acestep-v15-xl-sft-diffusers`: ~8.3 GB (bf16) |
| `acestep-v15-xl-turbo` | ~19.95 GB (FP32) | `acestep-v15-xl-turbo-diffusers`: full bundled pipeline (transformer + text encoder + condition encoder + VAE) = **14.4 GB total, verified byte-exact via HF API** |

Note the discrepancy: the plain (non-`-diffusers`) XL repos ship **FP32** weights on disk (~20 GB), while the README's "~9 GB in bf16" figure refers to the bf16-cast runtime footprint (confirmed: the `-diffusers` bf16 transformer alone is 8.34 GB). **Practical takeaway: download the `-diffusers` bf16 variant, not the raw FP32 repo, to save ~11 GB of disk per checkpoint and load faster.**

**Language-model "planner" (Qwen3-based, drives lyrics/structure/metadata chain-of-thought):**

| Checkpoint | Base | Weight size (bf16, verified) |
|---|---|---|
| `acestep-5Hz-lm-0.6B` | Qwen3-0.6B | 1.33 GB (`model.safetensors` = 1,325,804,024 B) |
| `acestep-5Hz-lm-1.7B` | Qwen3-1.7B | ~3.4 GB (extrapolated from param-count scaling; direct API call 401'd) |
| `acestep-5Hz-lm-4B` | Qwen3-4B | 8.38 GB (2 shards, verified: 4,999,914,896 + 3,379,239,240 B) |

**Shared components (loaded regardless of DiT/LM choice):**
- Text encoder `Qwen3-Embedding-0.6B`: ~1.19 GB (bf16)
- Condition encoder (diffusers pipeline component): ~1.22 GB
- 1D waveform VAE: ~322-337 MB (see §2/§4 for architecture)

**Default one-command bundle** (`huggingface.co/ACE-Step/Ace-Step1.5`, what `uv run acestep` downloads out of the box): Qwen3-Embedding-0.6B + `acestep-5Hz-lm-1.7B` + `acestep-v15-turbo` (2B) + VAE = **10.1 GB total**, verified via HF repo tree.

There is also LoRA personalization support (train a style LoRA from ~8 songs, ~1 hr on an RTX 3090 per the README — training-only, GPU/CUDA-oriented, not central to our use case) and one published community LoRA (`ACE-Step-v1.5-chinese-new-year-LoRA`).

---

## 2. Memory requirements in practice, and what fits 128 GB unified memory

Official hardware guidance is expressed as discrete-GPU VRAM tiers (from `docs/en/GPU_COMPATIBILITY.md` and the README, both checked 2026-07-05):

| VRAM | DiT | LM | Backend | Offload/Quant |
|---|---|---|---|---|
| ≤4-6 GB | 2B turbo | none | pt | INT8 + CPU offload |
| 6-8 GB | 2B turbo | 0.6B | pt | — |
| 8-16 GB | 2B turbo/sft | 0.6B/1.7B | vLLM (CUDA only) | — |
| 16-20 GB | 2B sft or XL turbo | 1.7B | pt/vLLM | XL needs offload below 20 GB |
| 20-24 GB | XL turbo/sft | 1.7B | pt/vLLM | none |
| ≥24 GB | XL sft | 4B | pt/vLLM | none — "best quality" tier |

Apple Silicon does **not** map cleanly onto this table because (a) it's unified memory shared with the OS/CPU rather than a dedicated VRAM pool, and (b) on Mac the LM planner runs via `mlx-lm` while the DiT/VAE can *either* run through a native MLX path (`use_mlx_dit`, defaults to `True` on Apple Silicon) *or* fall back to PyTorch+MPS for unsupported ops — meaning two runtime stacks can be resident at once.

Real-world data points **[community/reported, not independently verified]**:
- A blog documenting a from-source install on an **M1 Max (~25 GB usable in their test)** found `XL-turbo + 1.7B LM` peaks at **~42 GiB** across the MLX+PyTorch-fallback stack and OOMs; switching the LM down to 0.6B fixed it. The author states the 1.7B LM "is sized for a 24 GB discrete GPU" and that unified memory needs meaningfully more headroom than the VRAM table implies. ("ACE-Step Apple Silicon Install — Avoid the 1.7B LM Trap", freeaimusictools.com; exact publish date not shown but references the XL release, so ~April-June 2026.)
- The official changelog shows the project actively working this exact problem: v0.1.7 (2026-04-24) added "VAE decode chunk size auto-tuning to lower peak memory on Apple Silicon," and open GitHub issue **#1081** ("Auto-score on MacOS with MLX with XL-Turbo and 5Hz-4B Models Loaded Drains Memory") confirms the 4B-LM + XL combination is a known high-memory configuration still being tuned as of mid-2026.
- A separate blog on a **16 GB M2 MacBook Air** running smaller (2B-class) models needed `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0` to avoid a premature MPS allocator OOM, after which generation completed successfully with "pretty impressive" quality output. (en.bioerrorlog.work)

**Sizing conclusion for this machine (128 GB, ~98-108 GB budget after DAW/OS reservation):** every official configuration, including the heaviest documented one (XL DiT + 4B LM), fits with very large margin even if peak resident memory on Apple Silicon runs 1.5-2x higher than the discrete-GPU numbers suggest (i.e., budget ~55-65 GB peak for XL+4B, vs. a 98-108 GB ceiling). There is no memory-driven reason to pick anything less than the top-quality tier on an M5 Max/128 GB machine — see §8(a) for the exact recommended pairing. The bottleneck on this machine will be **compute time**, not memory (see §3).

---

## 3. Apple Silicon support

**Official and first-class**, verified directly in `pyproject.toml` (fetched from the repo, 2026-07-05):

```
requires-python = ">=3.11,<3.13"
# macOS arm64 only:
torch>=2.9.1 ; sys_platform == "darwin" and platform_machine == "arm64"
mlx>=0.25.2 ; sys_platform == "darwin" and platform_machine == "arm64"
mlx-lm>=0.20.0 ; sys_platform == "darwin" and platform_machine == "arm64"
```

Architecture is a **hybrid MLX + PyTorch/MPS** system, not a pure MLX port and not "just PyTorch MPS":
- The LM planner runs natively through `mlx-lm` (Qwen3 architectures are well supported by MLX).
- The DiT decoder can hot-swap to a native MLX implementation (`MlxDitInitMixin`, controlled by `use_mlx_dit`, default `True` on Apple Silicon).
- The VAE similarly has an MLX-native path (`MlxVaeInitMixin`).
- Anything MLX doesn't implement (e.g., some guidance-sampler math) falls back to PyTorch+MPS. Set via `ACESTEP_LM_BACKEND=mlx` / `--backend mlx`, with automatic fallback to plain PyTorch on non-arm64 hosts.
- Dedicated launch scripts exist: `start_gradio_ui_macos.sh`, `start_api_server_macos.sh` (+ `_manual` variants), and a **portable pre-packaged macOS zip** (`files.acemusic.ai/acemusic/mac/ACE-Step-1.5.zip`) with dependencies pre-installed. The startup script also proactively strips quarantine attributes and re-signs the embedded Python env's binaries to avoid Gatekeeper blocks on modern macOS.

**Known issues on Apple Silicon (dated, from GitHub Issues, checked 2026-07-05):**
- **#1081** (open): XL-turbo + 4B-LM combination drains memory heavily on macOS/MLX, especially during the auto-scoring pass that reloads models.
- **#117**: `use_adg=True` (an adaptive guidance sampler option) crashes on MPS with `TypeError: Cannot convert a MPS Tensor to float64` — MPS doesn't support float64; must leave ADG off on Mac.
- **#619**: LoRA **training** is unreliable on MPS/MLX (inference-only use, our case, is unaffected).
- `nano-vllm` (the fast batched-inference backend used on CUDA) and `torchcodec` are **not available on Apple Silicon** — Mac is limited to the `pt`/`mlx` backends, which are slower than the CUDA-optimized serving path for high-throughput/batch scenarios.
- Community workaround env vars frequently cited: `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0`, `PYTORCH_ENABLE_MPS_FALLBACK=1`.
- A third-party fork, `github.com/clockworksquirrel/ace-step-apple-silicon`, claims a dedicated Apple-Silicon build with an "AI DJ chat" UI — unofficial, maintenance status not verified, mentioned only for completeness.

**Generation speed on Apple Silicon — [reported, NOT independently verified, and NOT available for M5 Max anywhere as of 2026-07-05]:**
- Official headline numbers are CUDA-only: "<2 s per full song on an A100, <10 s on an RTX 3090" (README, paper abstract). No official Apple-Silicon number is published.
- **M2 MacBook Air, 16 GB [community]:** ~5-10 minutes per track (after tuning the MPS watermark env var), on top of a one-time ~40-minute model download.
- **M1 Max, ~25 GB test envelope, safe (2B/XL-turbo + 0.6B LM) config [community]:** "a 60-second clip takes about two minutes once the models are loaded" — roughly 2x slower than realtime.
- No data exists yet for M3/M4/M5 Max or for 40-core-GPU configurations. Given the M5 Max's much larger GPU (40 cores vs. M1 Max's 32, plus a newer-generation GPU architecture and higher memory bandwidth) and four months of subsequent software optimization (v0.1.8 vs. whatever pre-XL build those posts used), it is reasonable to *expect* noticeably better than 2x-realtime on turbo/8-step configs — but this is extrapolation, not a citation. **Action: run the project's own `python profile_inference.py` (a documented benchmarking tool measuring LM/DiT/VAE timing per device) on the actual target Mac before locking in defaults or promising latency numbers to users.**

---

## 4. Capabilities that matter to a DAW

- **Full songs with sung vocals from lyrics: yes, this is the core feature**, not a bolt-on. The LM planner and DiT decoder are jointly conditioned on lyrics + style/metadata to produce a mixed stereo track with sung vocals and instrumentation together (not separate vocal-synth + accompaniment steps).
- **Lyric conditioning format:** bracketed structure/style tags, e.g. `[Intro]`, `[Verse]`, `[Verse 1]`, `[Pre-Chorus]`, `[Chorus]`, `[Bridge]`, `[Outro]`, `[Build]`, `[Drop]`, `[Breakdown]`, `[Instrumental]`, `[Guitar Solo]`; combinable with vocal-style qualifiers, e.g. `[Chorus - anthemic]`, `[whispered]`, `[falsetto]`, `[powerful belting]`, `[spoken word]`, `[ad-lib]`. Parentheses mark backing vocals, e.g. `"We rise together (together)"`. Docs recommend 6-10 syllables/line for rhythmic consistency and blank lines between sections. The system can also auto-generate timestamped `.lrc` lyric files from audio.
- **Style/tags prompting:** a free-text "caption" field accepting anything from a couple of comma-separated tags to full natural-language descriptions, spanning genre, emotion, instrumentation, timbre, era ("80s synth-pop"), production style, and vocal character. UI/API helpers include a random-preset generator, an auto-rewrite/expand tool, and an LLM-powered "CoT rewrite" and "audio-to-caption" tool.
- **Duration:** 10 seconds to 600 seconds (10 minutes) per the LM planner's "song blueprint" scaling; docs caution that very long generations show more repetition/structural drift — 30s-4min is the documented "stable" range.
- **Sample rate / audio pipeline:** **48 kHz stereo**, end-to-end. v1.5 replaced v1's mel-spectrogram-based DCAE with a **pure waveform-domain 1D VAE** (config "inspired by SongBloom," trained with the Muon optimizer), compressing to a 64-channel continuous latent at 25 Hz (1920x downsampling). This is a meaningful fidelity upgrade over v1's approach.
- **Stem separation:** yes — a documented "Track Separation" capability splits a mix into individual stems, directly usable for importing multitrack results into a DAW project.
- **Vocal-to-backing workflows especially relevant to us:** "**Complete**" task takes a solo/a-cappella input and generates a full matching backing arrangement; "**Lego**" task adds specific new instrument layers (drums/bass/guitar/etc.) onto an existing track. Both map naturally onto "record vocals in DAW → send to local engine for instrumental backing."
- **Retake/repaint/edit:** "**Repaint**" regenerates a specified 3-90 second window in place while preserving surrounding context (chainable for effectively unbounded extension — exactly the "regenerate this section" UX a DAW wants); "**Cover**" restyles existing audio while preserving its structure, with an `audio_cover_strength` (0-1) dial; "**Retake**" (new in v0.1.8, 2026-05-18) generates alternate takes/variations; "**Flow-Edit**" (also v0.1.8) is a newer non-destructive audio-editing method.
- **Audio2audio:** yes, via two distinct mechanisms — "Reference Audio" (global conditioning on timbre/mix/atmosphere, encoded through the VAE and averaged over time) and "Cover"/source-audio structural conditioning (melody/rhythm/chords/orchestration extracted and reapplied under a new style).
- **Quality vs. Suno-class cloud — [opinion / community consensus, explicitly not independently verified]:** ACE-Step's own materials claim quality "between Suno v4.5 and Suno v5" — self-reported by the paper authors, treat skeptically. A community installation guide pushes back explicitly: *"ACE-Step is not a Suno replacement"* for a single polished one-shot vocal song; it positions ACE-Step's advantage as **reproducibility, privacy, and zero marginal cost** for iterative/bulk generation (sample packs, repeated variations) rather than peak one-shot vocal realism. Net assessment: vocal realism and mix polish are good-not-great compared to a best-case Suno generation, but the fast local repaint/retake loop meaningfully closes that gap by making "regenerate until happy" free and instant rather than metered and cloud-latent.

---

## 5. License and commercial-use terms

| Layer | ACE-Step v1 | ACE-Step 1.5 |
|---|---|---|
| Code | Apache-2.0 | **MIT** (verified: repo `LICENSE` file, copyright 2026 ACEStep) |
| Weights (all checkpoints checked: base/sft/turbo/xl-*/lm-0.6B/1.7B/4B) | Apache-2.0 | **MIT**, confirmed on every individual HF model card |
| Generated audio | — | Publisher explicitly states outputs are "designed for creators" and can be "strictly used for commercial purposes," citing training data composed of licensed tracks, public-domain/royalty-free content, and synthetic MIDI-rendered audio (no admitted use of unlicensed commercial recordings) |

Both licenses are permissive and allow commercial use, closed-source redistribution, and modification with no copyleft obligation. MIT (v1.5) drops Apache's explicit patent grant/termination clause relative to v1 — practically immaterial for an indie/small-team app like DAW Pro, and MIT is if anything simpler to comply with (attribution + license text only). The commercial-use claim on generated audio is a **marketing/self-declared position, not a legal warranty** — standard MIT "as-is," no indemnification — but it is a meaningfully lower-risk starting point than piping everything through a still-unofficial third-party Suno API (see §8(d)).

The companion `acestep.cpp` / `acestep.vst3` projects (see §7) are also MIT-licensed.

---

## 6. Serving/integration options

Verified directly from the repo (`pyproject.toml`, file tree, docs) plus a secondary, auto-generated code wiki (DeepWiki) cross-checked against the docs — the exact endpoint list below is sourced from DeepWiki's description of `acestep/api_server.py` and should be treated as **secondary/derived, not hand-verified against the FastAPI source line-by-line**, but is internally consistent with everything else confirmed:

- **Python version:** 3.11 or 3.12 (pinned `>=3.11,<3.13`).
- **Package manager:** `uv` is the documented/recommended tool (`curl -LsSf https://astral.sh/uv/install.sh | sh && uv sync`); a plain `requirements.txt` also exists for pip.
- **Key deps:** `torch>=2.9.1` (arm64 build on Mac, no CUDA payload so the wheel is much smaller than the Linux/Windows CUDA build), `mlx>=0.25.2` + `mlx-lm>=0.20.0` (Mac-only), `transformers>=4.51`, `diffusers>=0.37`, `fastapi>=0.110`, `gradio` 6.x, plus training-only extras (`peft`, `lightning`, `tensorboard`) that are skippable at inference time.
- **Install footprint estimate:** the Python venv itself (no model weights) should land roughly in the **3-6 GB** range on macOS arm64 (no CUDA blobs); model weights are downloaded separately into a cache/models directory (§1/§2 sizes).
- **Interfaces available:**
  - **CLI**: `cli.py`, plus `uv run acestep-download` (with `--all` / `--model <name>` / `--list`) for fetching specific checkpoints.
  - **Gradio web UI**: `uv run acestep`, default `http://localhost:7860`.
  - **A genuine built-in REST/HTTP server**: FastAPI app, entry point `acestep/api_server.py`, launched via `uv run acestep-api` (or `start_api_server_macos.sh`), **default port 8001**, auto-served Swagger docs at `/docs`. Must run with `workers=1` (in-memory job queue, not multi-process safe as shipped).
  - **Python API**: a `generate_music(GenerationParams) -> GenerationResult` style unified entry point, importable directly if we prefer to embed rather than shell out to HTTP.
  - Endpoints as documented (async job-queue pattern — submit, poll, fetch):
    - `POST /release_task` — submit a job: `prompt`/`caption`, lyrics, `audio_duration`/`duration` (default 30s), `bpm` (30-300), `task_type` (`text2music`/`cover`/`repaint`/`lego`/`complete`/etc.), `inference_steps` (default 8), auth via `ai_token` field or `Authorization: Bearer` header — returns a task id.
    - `POST /query_result` — poll one or more task ids; status `0` queued/running, `1` succeeded, `2` failed.
    - `POST /create_random_sample` — LLM-generated randomized starter params.
    - `POST /format_input` — LLM-assisted lyric/caption cleanup.
    - `GET /v1/models` — list available DiT/LM checkpoints.
    - `GET /v1/audio` — fetch generated audio by task id.
    - Auth: `ACESTEP_API_KEY` env var, checked via `ai_token` body field or bearer header.
  - A separate optional "OpenRouter-compatible" translation server (`openrouter/` dir in the repo) maps OpenAI-style chat requests onto `GenerationParams` — not needed for our integration since we can talk to the native API directly.

### Recommended integration pattern for DAW Pro

Run ACE-Step's own FastAPI server (or a thin wrapper importing `generate_music()` directly, if we want tighter control over the job queue than the shipped single-worker server gives us) as a **local Python sidecar process**, bound to `127.0.0.1` only — consistent with the existing control-WebSocket security posture already documented in `AI-INTEGRATIONS.md`. Concretely:

1. **Process lifecycle**: the Swift app spawns the sidecar lazily on first song-generation request (not at app launch, given the multi-GB resident model footprint), health-checks it over HTTP, and tears it down after an idle timeout (e.g., 10-15 min) to free memory for the DAW's own audio engine. A `launchd`-style child-process manager in `AIServices` (or a small dedicated `LocalModelHost` module) owns spawn/monitor/restart.
2. **Don't expose ACE-Step's raw port/contract directly to Swift or MCP.** Put a narrow facade in front of it (either inside the same sidecar process, as a thin FastAPI layer, or in a small Swift-side client) so the app and MCP tools depend on a name, not a wire format:
   - `POST /v1/song/generate` — `{ prompt, lyrics, styleTags, durationSec, bpm?, key? }` → `{ jobId }`
   - `GET /v1/song/{jobId}` — → `{ status: queued|running|done|failed, audioUrl?, stems?[] }`
   - `POST /v1/song/{jobId}/repaint` — `{ startSec, endSec, instructions }` → `{ jobId }`
   - `POST /v1/song/{jobId}/retake` — → `{ jobId }` (alternate take)
   - `POST /v1/song/{jobId}/stems` — → `{ stemUrls: { vocals, drums, bass, other, ... } }`
   This mirrors the "configurable base URL + auth, swappable provider" design already called out for `SunoClient` in `AI-INTEGRATIONS.md`, and lets the existing `SongGenerating` provider protocol grow an `ACEStepClient` implementation without any caller-side changes.
3. **Port**: pick a project-specific port distinct from ACE-Step's own defaults (8001 API / 7860 Gradio) and from the control WebSocket, e.g. **8765**, documented once in `AI-INTEGRATIONS.md`. Enable `ACESTEP_API_KEY` on the sidecar even though it's loopback-only, for defense in depth (matches "never sent to any host other than..." posture already in the doc, and costs nothing).
4. **mcp-server (TypeScript)** talks to the same facade over plain `fetch()`/`axios` to `http://127.0.0.1:8765`, exactly like it would call any other local tool — no new transport needed.
5. **Model weights ship out-of-band**, not bundled in the app bundle: first-run "download models" flow (background download + checksum verify) into an app-support directory, sized per §8(a).

---

## 7. Newer/better alternatives worth flagging

None currently beat ACE-Step-1.5 specifically for **local, Apple-Silicon-native, song-with-sung-vocals, fast-iteration** generation, but three are worth a re-check in 6-12 months. **YuE** (7B, LM-only autoregressive generation over audio codec tokens) has a strong community reputation for lyrics-to-song vocal quality and long-form coherence, but its autoregressive-over-codec-tokens architecture is inherently much slower/heavier per second of audio than ACE-Step's diffusion+8-step-distillation approach, and it has no official MLX/MPS path (CUDA-first, community Mac ports only) — not competitive today for fast local iteration on this machine. **DiffRhythm / DiffRhythm 2** (ASLP-lab, non-autoregressive latent-diffusion full-song generation with synced vocals) is philosophically the closest competitor to ACE-Step's approach, but as of 2026-07-05 it has no equivalent dedicated Mac build, portable package, or launch-script/MLX investment — worth revisiting if that changes. **Stable Audio Open** and **MusicGen** are explicitly out of scope for our requirement: Stable Audio Open is not vocal/lyrics-focused (and its terms historically exclude reproducing musical lyrics/melodies), and MusicGen has no native lyrics/vocal conditioning at all — both remain useful only as instrumental-bed/sound-design alternatives, not as Suno replacements.

---

## 8. Actionable takeaways

**(a) Exact recommended checkpoint/variant for this machine (M5 Max, 128 GB, 40-core GPU):**
- **Interactive/default engine**: `acestep-v15-xl-turbo` (or its bf16 `-diffusers` form to save ~11 GB disk) + `acestep-5Hz-lm-4B` — the top official quality tier (`≥24 GB` VRAM tier), safely affordable here. Estimated resident weight footprint: XL DiT bf16 ~9 GB + 4B LM bf16 ~8.4 GB + shared text/condition encoders ~2.4 GB + VAE ~0.35 GB ≈ **~20 GB base weights**. Budgeting for the dual MLX+PyTorch/MPS stack overhead and activation buffers that community reports show pushing a similar (XL+1.7B) config to ~42 GB peak, plan for **~55-65 GB peak resident** in the worst case (10-minute duration, batched generation, CoT "thinking" mode). Against a ~98-108 GB budget (128 GB minus 20-30 GB for DAW+OS), this leaves **35-50 GB of comfortable headroom** — no memory-driven reason to downgrade on this hardware.
- **Optional higher-fidelity "final render" pass**: swap in `acestep-v15-xl-sft` (non-turbo, full step count) for a user-triggered "polish this take" action, since disk/memory both have huge margin (~9-10 GB extra weights, well within budget) — keep `xl-turbo` as the fast default for iteration/retake/repaint.
- **Disk**: XL-turbo + XL-sft (bf16, dedup shared VAE/encoders) + 4B LM ≈ 25-35 GB total — trivial against 1.2 TB free.
- **Before shipping any latency promise to users**: run the project's own `profile_inference.py` on the actual target Mac; no verified M-series-Max benchmark exists yet for this model (see §3).

**(b) Proposed changes to `docs/AI-INTEGRATIONS.md`:**
- Replace the "Full song / vocal / singing generation → Suno API" row with: "ACE-Step-1.5 (local, MIT-licensed, offline) — primary engine, via a local Python sidecar; Suno kept only as an optional, explicitly opt-in cloud provider (no official public Suno API exists as of 2026-07-05 — reseller-only — so it stays dormant behind the same protocol rather than being built/verified now)."
- Add a new subsection, "Local model runtime," documenting: the sidecar port (proposed 8765), lifecycle (lazy-spawn on first use, idle-teardown), model-weights location and first-run download flow, and the `ACESTEP_API_KEY` loopback-auth convention.
- Update "Voices & singing — current position": v1 now routes singing through the local ACE-Step sidecar by default (offline, private, zero marginal cost) instead of Suno; recorded human vocals remain first-class via M2. Note that ACE-Step's "Complete"/"Lego" tasks (backing-track-from-a-cappella) partially cover the DiffSinger research goal, but true note-accurate melody-to-singing-voice control (user already wrote the melody, wants it sung) is a distinct capability ACE-Step doesn't provide — keep the DiffSinger spike on the list, lower priority.
- Update research item #1 to record that "verify Suno's current API" surfaced, as a byproduct of this report, that **no official public Suno API exists as of 2026-07-05** (only unofficial resellers) — demote its urgency; keep `SunoClient`'s configurable-base-URL design as a dormant adapter behind `SongGenerating`, revisited only if Suno ships a first-party API.

**(c) Proposed ROADMAP.md M6 wording change:**
- Replace: *"Suno integration: prompt → candidates → import as tempo-mapped tracks/stems (verify current Suno API terms first — research item)"*
  With: *"Local song generation: ACE-Step-1.5 Python sidecar (XL-turbo default / XL-sft for final-pass polish, MIT-licensed, fully offline) — prompt+lyrics → candidates → import as tempo-mapped tracks/stems; implement `ACEStepClient` behind the existing `SongGenerating` provider protocol; ship model weights as a first-run download (~25-35 GB), not bundled in the app; keep Suno as an optional, off-by-default cloud provider behind the same protocol, gated on an official API existing."*
- Add a checklist item: *"Sidecar process manager: spawn/health-check/idle-teardown of the local ACE-Step Python service from the Swift app; document port + HTTP contract in AI-INTEGRATIONS.md."*
- Add a checklist item: *"Model manager UI: first-run download/verify of ACE-Step checkpoints, with memory-tier detection (XL+4B default on ≥64 GB unified-memory Macs, smaller 2B/0.6B tier below that) and disk-space checks."*
- Leave the "Vocals path" item's DiffSinger research largely as-is but note ACE-Step's Complete/Lego tasks now cover part of that need.

**(d) Keep Suno as an optional cloud fallback?**
Yes, but strictly as a secondary, explicitly opt-in provider behind the same `SongGenerating` protocol — not built or verified as part of M6. Two reasons: (1) as of 2026-07-05, **no official public Suno API exists** (only unofficial third-party resellers), which is a ToS/reliability/legal risk not worth taking on when a locally-hosted, MIT-licensed alternative with self-declared commercial-clean training data now covers the core "song with sung vocals" requirement; (2) ACE-Step's local repaint/retake loop meaningfully offsets its per-shot vocal-quality gap versus Suno by making "regenerate until happy" free and instant. Revisit Suno if/when they ship a first-party API — track that under the existing standing research question in `docs/research/README.md` rather than duplicating it here.

---

## Primary sources consulted

- https://github.com/ace-step/ACE-Step-1.5 (README, `pyproject.toml`, `LICENSE`, `docs/en/Tutorial.md`, `docs/en/INSTALL.md`, `docs/en/GPU_COMPATIBILITY.md`, Releases, Issues #1081/#117/#619)
- https://github.com/ace-step/ACE-Step (original v1 repo)
- https://huggingface.co/ACE-Step (org page + `Ace-Step1.5`, `acestep-v15-base`, `acestep-v15-sft`, `acestep-v15-xl-base/sft/turbo` (+ `-diffusers` variants), `acestep-5Hz-lm-0.6B/1.7B/4B`, via both the web UI and the `?blobs=true` API for exact file sizes)
- https://huggingface.co/ACE-Step/ACE-Step-v1-3.5B
- https://arxiv.org/abs/2602.00744 (ACE-Step 1.5 paper, v1-v3, Jan-Feb 2026)
- https://github.com/ace-step/acestep.cpp (also mirrored as `ServeurpersoCom/acestep.cpp`) and https://github.com/ace-step/acestep.vst3 (+ Releases)
- https://deepwiki.com/ace-step/ACE-Step-1.5 (secondary/auto-generated code wiki, used only to cross-check REST endpoint shape and backend-selection logic against the primary docs — flagged inline wherever used)
- Community/opinion sources, explicitly marked: freeaimusictools.com ("ACE-Step Apple Silicon Install"), en.bioerrorlog.work ("Running ACE-Step 1.5 Locally... M2 MacBook Air")
- Suno pricing/terms snapshot dated 2026-07-05 (suno.com/pricing and secondary summaries) — used only to confirm no official public API exists yet, for §8(d)
