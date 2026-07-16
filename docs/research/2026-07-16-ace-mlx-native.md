# Can ACE-Step run natively on Apple Silicon via MLX — should the Python/FastAPI sidecar be replaced with a native MLX helper?

Date: 2026-07-16
Scope: verify load-bearing facts for the proposal to replace the ACE-Step-1.5 Python/FastAPI sidecar (`scripts/ace-step/`, `Sources/AIServices/ACEStepClient.swift`, `SidecarManager.swift`) with an out-of-process **native MLX helper**, ideally `mlx-swift`.
Builds on `docs/research/2026-07-05-ace-step-local-song-generation.md` (primary source for licensing, memory sizing, and API contract — not re-derived here except where it changes).

All claims sourced from primary material (GitHub repos/issues/releases, Hugging Face model cards) unless marked **[community]**/**[opinion]**. Dated because MLX/ACE-Step ship fast (4 releases in 3 months as of the prior report).

---

## 1. Does a working MLX port of ACE-Step exist today?

**Two distinct things exist, and they must not be conflated:**

**(A) Official hybrid MLX support, already inside `ace-step/ACE-Step-1.5` itself — the thing our current sidecar already runs.** Not a separate "port." Verified via `pyproject.toml`, `docs/en/GPU_COMPATIBILITY.md`, and the Releases page:
- LM planner (Qwen3-based) runs via `mlx-lm` — mature, first-class MLX support (Qwen3 is a well-supported MLX architecture).
- DiT decoder has a native MLX path (`MlxDitInitMixin`, `use_mlx_dit`, default `True` on Apple Silicon) for the base 2.4B family since early releases, and for the **XL (~5B) family since v0.1.6, 2026-04-03** ("MLX Apple Silicon support for XL" — release notes). A dimension-mismatch bug specific to XL's MLX `condition_embedder` was filed as [ace-step/ACE-Step-1.5#995](https://github.com/ace-step/ACE-Step-1.5/issues/995) (opened 2026-04-01, closed via PR #1002) and further tuned in v0.1.7 ("DiT static buffers across threads," Apple-Silicon peak-memory work) and v0.1.8 ("repaint step-injection + boundary blend on Mac," 2026-05-18).
- VAE has a partial MLX path (`MlxVaeInitMixin`); anything unimplemented falls back to PyTorch+MPS.
- **This is still 100% Python**, still fronted by the same FastAPI server we already run. "MLX inside the sidecar" is not evidence for "replace the sidecar" — it's the mechanism our current Python process already uses on the DiT/LM side.

**(B) A genuinely separate MLX-native *weights + inference stack*, decoupled from ACE-Step's own repo, published by the `mlx-community` org and built on Prince Canuma's `mlx-audio` library:**
- [`huggingface.co/mlx-community/ACE-Step1.5-MLX`](https://huggingface.co/mlx-community/ACE-Step1.5-MLX) and a [`-4bit`](https://huggingface.co/mlx-community/ACE-Step1.5-MLX-4bit) variant (F32 safetensors + 4-bit quant, ~12.6 GB). Usage shown on the card is `from mlx_audio.tts import load; model = load("mlx-community/ACE-Step1.5-MLX")` — i.e. this runs through `mlx-audio`'s Python loader, filed oddly under its `.tts` namespace. Card confirms lyric+vocal conditioning works ("upbeat pop song with female vocals," `lyrics` + `vocal_language` params) and documents an LM-planner "song blueprint" step before diffusion — so it is genuine song generation, not TTS repurposed.
- Traceable origin: `Blaizzy/mlx-audio` issue [#536](https://github.com/Blaizzy/mlx-audio/issues/536), "Adding support for music gen / sound effects (SFX) models," opened 2026-03-03 naming ACE-Step v1-3.5B explicitly, now closed. The public `mlx-audio` README (checked 2026-07-16) still does **not** list ACE-Step in its documented model table — the capability appears to exist (the HF card and 265 last-month downloads are real) but is **undocumented/unofficial in the upstream README**, i.e. thinly maintained, not a headline-supported model class the way Whisper/Kokoro are.
- **This is still Python** (`mlx_audio` package). No Swift involvement.

**Community wrapper repos found (all Python, all thin):**
- [`sw30labs/ace-step-1.5-mlx`](https://github.com/sw30labs/ace-step-1.5-mlx) — explicitly "wraps the official ACE-Step/ACE-Step-1.5 runtime and forces its Apple Silicon MLX path"; still runs a Python job/API wrapper (`scripts/acestep_mlx.py`) on its own ports (8789/8790). One commit. Not independent tech, just a launch-flag wrapper.
- [`clockworksquirrel/ace-step-apple-silicon`](https://github.com/clockworksquirrel/ace-step-apple-silicon) — Python fork, MLX-preferred with PyTorch/MPS fallback, plus a bolted-on "AI DJ chat" UI (Claude via OpenRouter). 323 commits, 0 tagged releases — active but not a stable release train.

**Verdict on Q1: no native-Swift and no pure-MLX-without-Python port exists anywhere.** Every "MLX" claim for ACE-Step, official or community, terminates in a Python process (either ACE-Step's own FastAPI server, or `mlx_audio`'s Python loader). There is nothing today that a Swift helper process could link against without reimplementing the model pipeline from scratch.

---

## 2. Quality/parity and Apple-Silicon performance

- No independent parity study (PyTorch-reference vs. MLX path) was found for either the official hybrid MLX DiT or the `mlx-audio`/`mlx-community` weights. GPU_COMPATIBILITY.md and INSTALL.md are silent on MLX-vs-PyTorch numerical/quality parity; the only signal is that Apple-Silicon-specific bugs (issue #995, the ADG/float64 MPS bug #117 noted in the prior report) keep surfacing and getting patched release-to-release, i.e. the Apple-Silicon path is still actively stabilizing, not a finished, audited parity target.
- **New performance data point beyond the 2026-07-05 report's M1/M2 figures:** a community write-up ([note.com/ni_no2](https://note.com/ni_no2/n/n2a5fb3859ea5?hl=en)) on a **Mac Studio, 64 GB unified memory**, running `acestep-v15-xl-turbo` + `acestep-5Hz-lm-4B` (our exact target tier), generated two ~2:25 tracks in about 90 seconds total — roughly **3x realtime**, using the LM-on-MLX + DiT-on-PyTorch/MPS hybrid (the author's troubleshooting notes describe reconciling MLX and MPS memory-cache behavior, implying the DiT was *not* running the pure-MLX path in that session). This is faster than the earlier-cited M1 Max figure (~2x *slower* than realtime) and is the best evidence yet that our M5 Max/128 GB target should land comfortably in real-time-or-faster territory — but it is still one anecdotal run, not a controlled benchmark, and it doesn't isolate MLX-DiT-on vs MLX-DiT-off performance.
- **No per-step progress hook exists anywhere in the surface we've verified.** Our own `ACEStepClient.swift` (see `progress_text`/`progress`/`stage` fields documented at `Sources/AIServices/ACEStepClient.swift:19,24-26`) already receives ACE-Step's *coarse* job-queue progress today — phase-level (e.g. queued/running/stage text), not per-diffusion-step. Nothing in the GPU_COMPATIBILITY.md, the release notes, or the `mlx-audio` loader docs advertises a step-level callback. `mlx_audio`'s Python `generate()`-style call could plausibly accept a callback closure since it's a synchronous library call rather than a job-queue-over-HTTP endpoint — but that is inferred from general MLX/Python library conventions, not confirmed in any doc read for this report.

---

## 3. `mlx-swift` maturity for this model class

- [`ml-explore/mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples) (the reference examples repo) covers **LLM, VLM, embeddings, Stable Diffusion (image), and MNIST** — no audio, no music, no diffusion-transformer-for-audio example of any kind.
- [`Blaizzy/mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift) — the one Swift package doing MLX audio work — is explicitly TTS/STT/STS/codec-scoped (11 TTS models, 13 STT models, 4 STS models, plus SNAC/Encodec/Vocos codecs; latest release v0.1.3, 2026-07-09, actively maintained). **No music/song generation and no ACE-Step**, confirmed against its README.
- Net: `mlx-swift` is proven and actively maintained for LLM/VLM/TTS/STT classes. Nobody has built the ACE-Step class (multi-component: Qwen3-based LM planner + flow-matching DiT + waveform VAE + text/condition encoders, chained with chase/guidance logic) in Swift. Building it would mean porting ~4 distinct sub-model architectures and the sampler/guidance glue from scratch — a multi-month project with no prior art to lean on, not a wrapper task.
- If a Python-first step were taken instead, `mlx_audio`'s existing (if thinly-documented) ACE-Step loader is the only pre-built, non-FastAPI entry point that exists today.

---

## 4. Licensing

Reconfirms and extends the 2026-07-05 report (§5 there), no changes to the underlying facts:
- ACE-Step v1: Apache-2.0 (code + weights).
- ACE-Step 1.5: **MIT** (code + every checkpoint's HF model card, verified via the repo's `LICENSE` file previously).
- `mlx-community/ACE-Step1.5-MLX` / `-4bit`: HF org convention is to preserve the source model's license on converted-weight re-uploads; no relicensing notice or conflicting license tag was found on the card. Treat as inheriting MIT, consistent with every other `mlx-community` conversion of an MIT-licensed source model, but note this specific card's license metadata field wasn't independently confirmed byte-for-byte in this pass — worth a 30-second manual check (the HF page's right-rail "License" badge) before depending on it contractually.
- No new licensing risk either way: whichever runtime (Python/PyTorch, Python/MLX, or a hypothetical Swift/MLX) is used, it's the **same MIT weights**, so this axis does not favor or disfavor the native-helper proposal.

---

## 5. ANE / Core ML sanity check (brief)

No credible report of a multi-billion-parameter diffusion transformer running on the Apple Neural Engine via Core ML was found. Apple's own published ceiling is Stable Diffusion (~1.1–1.3B params across its 4 sub-networks) ([Apple ML Research](https://machinelearning.apple.com/research/stable-diffusion-coreml-apple-silicon)), and Apple Developer Forums threads on "Large ML Models on the Neural Engine" report practitioners hitting a wall around ~1–1.5B parameters, with models beyond that silently falling back to GPU/CPU execution rather than the ANE. ACE-Step's DiT alone is 2.4–5B params, and the full pipeline (DiT + Qwen3 LM planner + text/condition encoders) is 5–9B+ combined — several times past the demonstrated ANE ceiling. The assumption in the task brief is confirmed: **ANE/Core ML is not viable for this model**, GPU (Metal, via MLX or MPS) is the only realistic Apple-Silicon path.

---

## 6. Verdict

**NO-GO on a native `mlx-swift` helper now. WAIT, with a narrower near-term alternative flagged.**

Reasoning:
1. **No prior art exists to build on.** Nobody — official project, `mlx-community`, or any community fork — has ported ACE-Step's LM+DiT+VAE pipeline to `mlx-swift`. This would be an from-scratch, multi-model-architecture port with no reference implementation in Swift, easily a multi-month effort that duplicates work the (Python) upstream project is still actively stabilizing itself (see the XL-MLX bugs fixed across v0.1.6–v0.1.8).
2. **The two motivating claims in the task brief don't hold up as strongly as assumed:**
   - *"Faster startup, lower overhead"*: model-weight loading (8–20+ GB of DiT/LM weights from disk into unified memory) dominates our sidecar's startup time, not Python/FastAPI interpreter or HTTP-server init (sub-few-seconds, negligible by comparison). A Swift process would still pay the same weight-load cost. No evidence a Swift rewrite meaningfully improves cold-start latency.
   - *"Clean per-diffusion-step progress callbacks"*: the real gap is that ACE-Step's own FastAPI server exposes only coarse job-queue progress (`progress`/`stage`, already consumed as-is by `ACEStepClient.swift`), not that Python itself can't do callbacks. A same-language fix (bypass the HTTP job-queue, call the model directly in-process/in-subprocess with a Python callback) plausibly solves this without any Swift work at all — though this wasn't independently confirmed in `mlx_audio`'s API docs and should be spiked before committing to it.
3. **What genuinely doesn't exist yet, and would have to be built from zero in Swift regardless of effort:** the ACE-Step model classes themselves in `mlx-swift`. This is squarely a "wait for upstream" item, not a "DAW Pro engineering task."

**If GO is reconsidered later, first implementation step:** do not start with a from-scratch `mlx-swift` DiT/LM port. Start by spiking the **`mlx_audio`-direct Python path** (bypass ACE-Step's FastAPI server entirely; call `mlx_audio.tts.load("mlx-community/ACE-Step1.5-MLX")` + its `generate()` API directly from a slim, purpose-built Python entry point we own, communicating with the Swift app over stdin/stdout JSON-lines or a Unix socket instead of HTTP). This is a days-not-months spike that would validate (a) whether a callback hook for per-step progress actually exists in that API, (b) whether the `mlx-community` weights match the quality of our current PyTorch/hybrid-MLX XL-turbo+4B-LM setup, and (c) whether removing FastAPI's HTTP layer measurably improves latency at all. Only if that spike shows a real, measurable win (not just "feels more native") would a Swift port become worth scoping — and even then, it would be gated on `mlx-swift-examples`/`mlx-audio-swift` first demonstrating *any* diffusion-transformer-class audio model, as a signal the ecosystem has matured past LLM/VLM/TTS.

**What to re-check later (WAIT triggers):**
- Does `Blaizzy/mlx-audio-swift` (actively released, v0.1.3 as of 2026-07-09) ever add a music/diffusion model class? That would be the first real signal `mlx-swift` is viable for this workload.
- Does the official `ace-step/ACE-Step-1.5` repo's MLX DiT path stop generating new Apple-Silicon-specific bug reports (i.e., stabilize) — currently still patching issues release-to-release (#995 in April, buffer/repaint fixes through May).
- Does `mlx-audio`'s README ever formally document ACE-Step as a supported model (current signal: capability exists via a linked HF card, but isn't in the upstream model table — thin support, not a commitment).
- Run `profile_inference.py` (ACE-Step's own benchmarking tool, already flagged as an action item in the 2026-07-05 report) on the actual M5 Max once weights finish downloading, and separately time cold-start (process spawn → healthy) vs. model-load — to confirm or refute the startup-overhead assumption with our own hardware rather than the Mac Studio anecdote above.

---

## Actionable takeaways

- **No ARCHITECTURE.md or ROADMAP.md change is warranted right now.** Keep the Python/FastAPI sidecar (`scripts/ace-step/`, `SidecarManager.swift`, `ACEStepClient.swift`) as the shipping design — it already uses ACE-Step's own official hybrid MLX(LM+DiT)/PyTorch(MPS-fallback) backend, which is the same "MLX" the task brief was asking about replacing. There is no lower-effort native-Swift alternative to swap in.
- **Add one new standing research item to `docs/research/README.md`** (not a roadmap item — pure watch-list): *"Re-check `mlx-swift`/`mlx-audio-swift` for a diffusion/music-generation model class (currently LLM/VLM/TTS/STT/STS/codecs only) — re-open the native-MLX-helper question if one ships."*
- **Small, decoupled spike worth scoping independently of this verdict** (does not require Swift, does not touch the RT audio process): try `mlx_audio.tts.load("mlx-community/ACE-Step1.5-MLX")` directly, bypassing ACE-Step's FastAPI job queue, to test for a per-step progress callback and to compare quality/latency against our current XL-turbo+4B-LM sidecar config on the M5 Max. If it's a clean win, it's a same-language (Python) change to `scripts/ace-step/` — not the Swift rewrite the task brief proposed — and should be logged as its own roadmap candidate only after the spike, not before.
- **Correct one assumption baked into the task brief for any future write-up:** sidecar startup latency is very likely dominated by weight loading, not by Python/FastAPI process overhead — don't sell a Swift rewrite internally on a "faster startup" promise without first measuring where our actual cold-start time goes.

---

## Primary sources consulted

- https://github.com/ace-step/ACE-Step-1.5 (`pyproject.toml`, `docs/en/GPU_COMPATIBILITY.md`, `docs/en/INSTALL.md`, Releases page)
- https://github.com/ace-step/ACE-Step-1.5/issues/995 (MLX DiT dimension bug for XL/4B, opened 2026-04-01, closed via PR #1002)
- https://huggingface.co/mlx-community/ACE-Step1.5-MLX and https://huggingface.co/mlx-community/ACE-Step1.5-MLX-4bit
- https://github.com/Blaizzy/mlx-audio (README, model table) and https://github.com/Blaizzy/mlx-audio/issues/536
- https://github.com/Blaizzy/mlx-audio-swift (README, model table, releases)
- https://github.com/ml-explore/mlx-swift-examples (README, example list)
- https://github.com/sw30labs/ace-step-1.5-mlx
- https://github.com/clockworksquirrel/ace-step-apple-silicon
- https://note.com/ni_no2/n/n2a5fb3859ea5?hl=en (**community**, Mac Studio 64 GB XL-turbo+4B-LM timing)
- https://freeaimusictools.com/blog/ace-step-apple-silicon-install/ (**community**, cited in the 2026-07-05 report, re-checked here)
- https://machinelearning.apple.com/research/stable-diffusion-coreml-apple-silicon (ANE ceiling reference)
- https://developer.apple.com/forums/thread/727547 ("Large ML Models on the Neural Engine")
- Internal: `docs/research/2026-07-05-ace-step-local-song-generation.md`, `docs/AI-INTEGRATIONS.md`, `Sources/AIServices/ACEStepClient.swift`
