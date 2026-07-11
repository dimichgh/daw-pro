# Vocals-only generation and voice conversion for DAW Pro

Date: 2026-07-11
Author: research-analyst (agent)
Target machine: Apple Silicon MacBook, M-series Max, 128 GB unified memory, MLX installed. Existing local sidecar: ACE-Step-1.5 (FastAPI, `127.0.0.1:8001`, MLX-accelerated; `acestep-v15-xl-turbo` default + `acestep-v15-xl-sft` for extract/lego/complete + `acestep-5Hz-lm-4B`).

Scope per the request: (1) can our existing ACE-Step stack make vocals-only audio directly, vs. generate-then-extract; (2) survey of singing-voice-conversion (SVC) tools as of mid-2026 — capability, Apple Silicon story, license, training story; (3) training a custom voice on this Mac; (4) integration architecture + milestone sizing. Docs-only — nothing under `scripts/ace-step/runtime` was modified, read-only inspection only.

---

## 1. Vocals-only generation with the existing ACE-Step 1.5 stack

### 1a. What task types actually exist (verified against upstream source, not docs alone)

Read directly from `scripts/ace-step/runtime/src/acestep/constants.py:76-111`:

```python
TASK_TYPES = ["text2music", "repaint", "cover", "cover-nofsq", "extract", "lego", "complete"]
TASK_TYPES_TURBO = ["text2music", "repaint", "cover", "cover-nofsq"]
TASK_TYPES_BASE  = ["text2music", "repaint", "cover", "cover-nofsq", "extract", "lego", "complete"]
TRACK_NAMES = ["woodwinds","brass","fx","synth","strings","percussion","keyboard","guitar","bass","drums","backing_vocals","vocals"]
```

None of the seven task types is "generate vocals only, from a text prompt, with nothing else." The three relevant ones, and what they actually require as input (confirmed in `acestep/core/generation/handler/task_utils.py:80-98` and `conditioning_masks.py`, plus prose descriptions in `docs/en/Tutorial.md:228-232` and `docs/en/ace_step_musicians_guide.md:123-133`):

| Task | What it needs | What it does | Model tier |
|---|---|---|---|
| `extract` | An existing **mixed** audio file + `track_name` (e.g. `"vocals"`) | Separates that one stem out of the mix | base/**sft only**, not turbo (already true of our shipped stem-extraction feature — `ROADMAP.md` M6 iii-c/iii-c-real: stems default to `acestep-v15-xl-sft`, confirmed live: "every extract sub-job routed 'Using second model: acestep-v15-xl-sft'") |
| `lego` | An **existing** audio track (e.g. vocals already recorded/generated) + `src_audio_path` | Adds a *new* instrument layer on top, conditioned on that existing track | base/sft only |
| `complete` | A **single-track** input, explicitly documented example "a cappella vocals" (`Tutorial.md:825`) | Generates a full backing arrangement to match it | base/sft only |

`lego` and `complete` are both **audio-in, audio-out** tasks — they take vocals you already have and add or match instrumentation around them. Neither can synthesize vocals from nothing; both require `src_audio_path` (confirmed: our own `iii-c` stems work found live that "extract AND lego are single-track-per-job... BOTH require `src_audio_path`" — `ROADMAP.md` line 87). So none of the three "audio-control" task types is a route to vocals-from-text.

### 1b. The only lever for direct vocals-only output: the "a cappella" genre tag

`text2music` has no "vocals only" boolean. It *does* have the inverse — an `is_instrumental` flag/detector (`acestep/api/server_utils.py:135`, `acestep/inference.py:1351`, UI checkbox at `acestep/ui/gradio/events/generation/ui_helpers.py:206`) that forces **no** vocals. There is no symmetric "no instruments" flag.

However, `acestep/genres_vocab.txt` — the vocabulary the LM planner's constrained-decoding logits processor is restricted to when parsing/completing the `caption` field (`acestep/constrained_logits_processor.py:187-240`, `_load_genres_vocab`/`_try_reload_genres_vocab`, used at generation time per line 1954/1962) — contains **"a cappella"** as a first-class trained tag, and not just once: it appears combined with dozens of genres and moods (`genres_vocab.txt:56839-57055` and dozens more matches earlier in the file, e.g. `"Brazilian pop a cappella"`, `"a cappella choral"`, `"a cappella barbershop"`, `"a cappella gospel R&B"` — >200 distinct "a cappella"-containing entries counted in the grep). Because this vocabulary is what *constrains the LM's own output*, not just a UI autocomplete list, its presence is strong (though not conclusive) evidence the training data included a-cappella-tagged tracks, i.e. the model has actually seen unaccompanied-vocal examples and the tag should meaningfully bias generation toward that.

**Practical read:** `task_type=text2music` with a caption containing `"a cappella"` (optionally combined with a vocal-style tag like `"choral"`, `"gospel"`, `"barbershop"`) is a real, exercised path to vocals-forward output — but it is still the *general* full-mix pipeline, just genre-conditioned, not a dedicated isolated-stem mode. Caveats, none of which can be resolved without a hands-on spike:
- No guarantee of *zero* instrumental bleed (light percussion/pads/ambience are common even in real "a cappella" training data tagged that way — barbershop/gospel a cappella often still has body percussion, beatboxing, or held pad-like harmonies).
- Quality/purity will vary by DiT tier; `text2music` is available on **turbo** (fast, 8-step) as well as base/sft, so this path doesn't force the slower base/sft model the way extract/lego/complete do.
- We found no explicit "a cappella" example run, benchmark, or worked case in the docs — this is inferred from vocabulary presence, not demonstrated output.

### 1c. Direct generation vs. generate-then-extract: recommendation

We already have `extract` (task_type=`extract`, `track_name=vocals`) working end-to-end and gated for real on this machine (`ROADMAP.md` M6 iii-c/iii-c-real, `Sources/AIServices/ACEStepClient.swift`'s stem fan-out). That gives:

- **Reliable, deterministic separation** of a normal full-mix generation into a real vocal stem — proven in production (distinct real PCM separations, verified via md5 diff in the (iii-c-real) gate).
- **No new upstream surface to learn** — it's the exact code path already shipped.
- **Better creative fit for our actual use case**: per the user's stated intent ("generating vocals only and changing them to other voice"), what's wanted is a vocal stem to feed into a voice-conversion step — extract's job is precisely stem isolation, which is a more mature, purpose-built capability than biasing a general song-generation pipeline with a genre tag and hoping little-to-no instrumentation leaks in.

The `"a cappella"` prompt-tag route is real and worth exposing as a **style hint** in the Sketchpad composer (cheap, already-supported, turbo-eligible, zero new integration work — just pass the tag through in the caption), but it should not be the primary path to an isolated vocal for downstream voice conversion. **Recommended default pipeline: generate normally (optionally nudged toward vocal-forward material via an "a cappella" / vocal-focused style tag) → run the existing `extract` (task_type=extract, track_name=vocals) → feed that stem into voice conversion.** This reuses 100% of already-built, already-gated infrastructure and only adds the new VC step.

---

## 2. Singing voice conversion (SVC) landscape, mid-2026

Ranked by relevance to "change an existing vocal recording/stem to a different voice, singing, running locally on Apple Silicon."

### 2a. RVC (Retrieval-based Voice Conversion) family — the strongest overall fit

- **Origin/license**: original repo `RVC-Project/Retrieval-based-Voice-Conversion-WebUI`, **MIT license** (verified: `LICENSE` file, copyright liujing04/源文雨/Ftps 2023). Commercial-use-safe on its face (no patent/copyleft clause; standard MIT as-is disclaimer).
- **Maintained fork for training/GUI**: **Applio** (`IAHispano/Applio`) — **MIT**, actively maintained, the current community-standard trainer/GUI built on RVC. Docs (`docs.applio.org`) state training needs **10-30 minutes of clean audio** (lossless `.wav`/`.flac`, no background noise/reverb/artifacts) and **200-400 epochs**; hardware guidance assumes an NVIDIA GPU (e.g. batch size 6-8 on 8 GB VRAM) and does not address Apple Silicon at all.
- **Apple-Silicon-native inference**: `Acelogic/Retrieval-based-Voice-Conversion-MLX` — a **pure MLX implementation, inference-only** (no training), forked from Applio, claiming **8.71x faster** full-pipeline inference vs. PyTorch-MPS on a 13.5 s clip, **10.6x realtime**, 0.986 spectrogram correlation to the PyTorch reference ("perceptually identical"), native FAISS index support (the "retrieval" half of RVC), multiple pitch extractors (RMVPE default, FCPE, Crepe/Crepe-Tiny), and even a native Swift/Metal port for iOS/macOS claiming 91.8% parity with the Python version. **Caveats**: small project (25 stars, 3 forks at time of check), no license file found in the fetched README (almost certainly inherits Applio's MIT by lineage, but this is inference, not verification — confirm before shipping), and it is inference-only — training a custom voice still has to happen through standard Applio/RVC on CPU/MPS or in the cloud, then the resulting `.pth`/index files loaded into the MLX runtime for fast local inference.
- **Apple Silicon training (MPS, not MLX)**: works technically but is slow and undocumented as first-class. A concrete community data point (GitHub issue `RVC-Project/...#767`, "Training on Apple Silicon"): a 30-minute dataset on an **M1 MacBook Pro** took **over 6 hours** to train, with the reporter explicitly suspecting GPU (MPS) isn't being used effectively. General community sentiment confirms training-related PyTorch/MPS support "is still being improved" and CUDA remains meaningfully faster. No data point exists yet for an M-series Max with 128 GB — this machine's much larger GPU core count should help proportionally, but **this needs a hands-on timing spike on the actual target Mac**, not an extrapolation.
- **Singing quality reputation**: RVC is the technology behind the wave of "AI cover song" content on YouTube/TikTok specifically because it handles *singing* (pitch, vibrato, sustained notes) well relative to speech-oriented VC — this is the strongest community-validated "good for singing" signal of anything surveyed. **What users complain about** (from RVC-Project GitHub issues, a useful "our edge is simplicity" signal): metallic/robotic timbre, especially on **sibilants ("S" sounds) and breath sounds** (issue #119, #2689); quality is extremely sensitive to **training-data cleanliness** — any reverb or noise in the source recordings shows up as robotic artifacts in every checkpoint; the **pitch extractor matters** — RMVPE (the default) "can sound harsh on non-harmonic voices," with users recommending FCPE for smoother results; **embedder mismatches** between training and inference silently hurt timbre transfer; and combining multiple trained voice models via "model fusion" reliably produces unusable robotic output. All of this maps directly onto UX opportunities for us: auto-validate/clean input audio before training, default to a known-good pitch extractor, and never expose "model fusion" as a supported feature.
- **Model size**: RVC checkpoints are small — typically tens of MB per trained voice (a lightweight HuBERT/ContentVec content encoder is shared/frozen; only a per-speaker decoder + FAISS index is trained), which is friendly to local storage and fast to swap.

### 2b. seed-vc — best *zero-shot* option, but licensing and maintenance flags

- **What it is**: `Plachtaa/seed-vc` — zero-shot voice conversion **and explicitly zero-shot singing voice conversion**, with a dedicated singing-tuned checkpoint (`seed-uvit-whisper-base`, 200M params, 44.1 kHz). "Zero-shot" means **no per-voice training at all** — feed it a 1-30 second reference clip of the target voice and it converts immediately. This is architecturally the most DAW-Pro-friendly model in the survey if it works well, because it removes the "train a voice" step from the user journey entirely.
- **Apple Silicon**: explicitly supported — changelog entry "Added Mac M Series (Apple Silicon) support" (2025-03-03), with a dedicated `requirements-mac.txt`.
- **Real-time mode**: exists, with published latency numbers (~300 ms algorithm delay + ~100 ms device-side delay on an RTX 3060 Laptop GPU) — not directly relevant to our offline-render use case but shows the architecture is lightweight (model sizes 25M-200M params vs. multi-GB diffusion models).
- **License**: **GPL-3.0** (verified: `LICENSE` file at `Plachtaa/seed-vc`, GNU GPL v3 text). This is a **hard flag** — strong copyleft. Distributing/bundling GPL code inside a closed-source commercial app's installer is the kind of thing that needs a real legal read, not an agent's assumption. The common industry pattern for GPL command-line/service tools (e.g. many apps shelling out to GPL `ffmpeg` builds) is to invoke them as a **separate, arm's-length subprocess** communicating over IPC/HTTP rather than linking them into the app binary — which is exactly the sidecar pattern we already use for ACE-Step (MIT, so no issue there) — but GPL (unlike permissive licenses) makes this a real legal question rather than a formality, and unlike AGPL it does not have an explicit network-service clause forcing source disclosure just for *running* it locally. **Do not bundle/redistribute seed-vc's code inside the DAW Pro app or installer without a legal review; if used, treat it as an optional, user-installed, arm's-length local sidecar (user runs their own install script, analogous to how ACE-Step's own weights are a first-run download, not bundled) and never link it into the Swift binary.**
- **Maintenance status**: the repository was **archived by its owner on 2025-11-21** and is now read-only. It still works (the code is functionally complete and the HF Space demo is live), but there will be no further upstream bug fixes, dependency updates, or macOS/PyTorch-version compatibility patches. Combined with the GPL flag, this makes seed-vc a **higher-risk, not-default** choice — worth a spike to confirm quality, but not the primary recommendation.
- **Weights license**: hosted at `huggingface.co/Plachta/Seed-VC` — not independently verified in this pass (the code license and the weights license can differ); confirm the HF model card's license field before any integration work begins.

### 2c. so-vits-svc family — legacy, license-tangled, supersede-worthy

- **Original** (`svc-develop-team/so-vits-svc`): **AGPL-3.0** (verified via `LICENSE` file) — the strictest copyleft surveyed, including AGPL's network-use source-disclosure clause. **Archived 2023-11-11**, i.e. unmaintained for nearly three years as of this report — predates both RVC's current maturity and seed-vc.
- **Popular fork** (`voicepaw/so-vits-svc-fork`, adds realtime support): licensed under a **dual MIT/Apache-2.0** declaration for the fork's own contributed code — but it is built directly on the AGPL-licensed so-vits-svc core, and a fork re-licensing a derivative of AGPL code as MIT is legally questionable on its face (AGPL is copyleft precisely to prevent this). This is genuinely ambiguous from the outside and **needs a proper legal read if pursued, not an agent's judgment call** — recommend simply **not pursuing this family**, since RVC and DDSP-SVC cover the same ground with cleaner licenses and are the current community-recommended alternatives anyway.
- **Verdict**: skip. Legacy tech, muddiest licensing of the survey, superseded in practice by RVC (better community tooling/reputation for singing) and DDSP-SVC (faster, cleaner MIT license).

### 2d. DDSP-SVC — lightweight MIT alternative, real-time capable

- **License**: **MIT** (verified: `LICENSE` file, `yxlllc/DDSP-SVC`).
- **What it is**: a DDSP (Differentiable Digital Signal Processing) based real-time SVC system, explicitly positioned as much lighter-weight than so-vits-svc: "training time can be shortened by orders of magnitude... close to the training speed of RVC," with hardware requirements "significantly lower" than so-vits-svc for real-time conversion.
- **Dataset**: README states "the total number of audio clips for training and validation datasets should be around 1000 and 10 respectively... duration of all audio clips should not be less than 2 seconds" — i.e. roughly consistent with the RVC-class "tens of minutes" ballpark, though expressed in clip-count rather than total-minutes terms.
- **Quality**: base DDSP synthesis quality is described by the project itself as "not ideal" without post-processing, but "after enhancing the sound quality with a pre-trained vocoder-based enhancer or with a shallow diffusion model... can achieve synthesis quality no less than SO-VITS-SVC and RVC" — i.e. competitive quality is achievable but depends on enabling the enhancer/diffusion add-on, not the bare model.
- **Apple Silicon**: no explicit MPS/MLX documentation found; being a smaller, simpler PyTorch model than so-vits-svc it is *plausibly* more MPS-friendly, but this is inference from architecture size, not a verified claim — needs a spike.
- **Verdict**: credible MIT-licensed fallback if RVC's MLX inference path or dataset-size story doesn't pan out, but not the primary recommendation given RVC's much stronger community track record specifically for *singing* and the existence of a real Apple-Silicon-native (MLX) inference implementation.

### 2e. Newest research-grade options (flag for future re-check, not usable today)

- **YingMusic-SVC** (`GiantAILab/YingMusic-SVC`, arXiv 2512.04793, submitted 2025-12-04 by Giant Network AI Lab with Tsinghua/NPU): a zero-shot SVC specifically engineered for **robustness on real songs with accompaniment/harmony contamination** (a real weakness the paper documents in seed-vc: "significant degradation in intelligibility and pitch stability when processing mixed vocals"), reporting consistent improvements over seed-vc as a baseline. Code+weights released on GitHub/HuggingFace, **MIT license**. **Verdict: promising and worth a re-check in a few months**, but as of this report it's roughly 6-7 months old, the install docs target CUDA 12.6 + `flash-attention` on Linux with no Apple Silicon mention, and it has a small community footprint (tens of stars) — too new/CUDA-oriented to bet on today. (Note: a sibling repo `GiantAILab/YingMusic-Singer`, also MIT, is a *singing-voice-synthesis* — i.e. text/melody-to-singing — project from the same lab, not to be confused with the SVC repo; not relevant to voice *conversion* but flagged in case naming causes confusion in a future search.)
- Academic papers surfaced but with **no confirmed public code**, so not actionable today: R2-SVC, HQ-SVC, LDM-SVC, Poly-SVC — cited by YingMusic-SVC's own related-work as recent SVC research directions (robustness, low-resource, latent-diffusion, polyphony-aware), useful only as "watch this space" pointers.
- **Cloud alternatives exist** (ElevenLabs-class voice-changer APIs, Kits.ai, etc.) but are explicitly out of scope: the user's ask and DAW Pro's stated local-first posture (matching the ACE-Step decision) rule out anything requiring a cloud key or per-generation billing for this feature.

### 2f. Summary table

| Tool | License | Commercial-safe | Apple Silicon | Training needed | Singing reputation | Verdict |
|---|---|---|---|---|---|---|
| RVC core + Applio trainer | MIT | Yes | MPS training (slow, undocumented for Mac); **MLX inference exists** (Acelogic fork) | Yes, ~10-30 min clean audio | Strong — the "AI cover song" technology | **Primary recommendation** |
| seed-vc | **GPL-3.0** | Needs legal review; arm's-length subprocess only | Yes, explicit since 2025-03 | **None** (zero-shot, 1-30 s reference) | Good on paper, weaker on real "mixed"/accompanied singing per newer research | Spike candidate, not default |
| so-vits-svc (orig.) | **AGPL-3.0**, archived 2023 | Avoid | Undocumented | Yes | Historically strong, now legacy | Skip |
| so-vits-svc-fork | MIT/Apache-2.0 (ambiguous re: AGPL core) | Ambiguous — needs legal read | Undocumented | Yes | Same lineage as above | Skip |
| DDSP-SVC | MIT | Yes | Undocumented, plausibly lighter | Yes, ~1000 short clips | Competitive with enhancer/diffusion add-on | Fallback if RVC path stalls |
| YingMusic-SVC | MIT | Yes | Not documented, CUDA-first | Zero-shot | State-of-the-art on paper (Dec 2025) | Re-check in 6-12 months |

---

## 3. Training/fine-tuning a custom voice on this Mac

Focused on the top candidate, **RVC/Applio**, with **seed-vc** noted as the zero-shot alternative that needs no training step at all.

### 3a. RVC/Applio training story on Apple Silicon

- **Dataset**: Applio's own docs recommend **10-30 minutes of clean, dry (dereverbed/denoised), lossless (`.wav`/`.flac`) target-voice audio**. For a *singing* target voice specifically, best practice (not explicit in the docs but standard in the RVC community, consistent with what the "quality is sensitive to training-data cleanliness" complaints above imply) is to source **dry solo vocal stems**, not audio with reverb/backing music baked in — i.e. the target-voice training set should itself go through the same extract/de-noise pipeline we're proposing to use on the *generation* side.
- **Training time on this machine**: **no direct data point exists for an M-series Max with 128 GB.** The only concrete Apple Silicon number found is the GitHub issue report of **6+ hours for a 30-minute dataset on an M1 MacBook Pro** via PyTorch-MPS, with the reporter suspecting the GPU isn't being used efficiently. An M-series Max has a substantially larger GPU (more cores, higher bandwidth) and several Metal/MPS generations of improvement since that report — it's reasonable to *expect* meaningfully faster, but this is extrapolation, not measurement. **This needs a timed spike on the actual target hardware before promising any number to users** — same caveat pattern as the ACE-Step generation-speed section of the prior research report.
- **Is MLX a training path, or PyTorch-MPS the only option?** As surveyed, **no MLX-native RVC training implementation exists** — the `Retrieval-based-Voice-Conversion-MLX` project is explicitly **inference-only**. Training must go through standard Applio/RVC on PyTorch, which on macOS means **PyTorch-MPS**, not MLX. This is the opposite of ACE-Step's hybrid MLX+MPS story, where MLX at least covers the LM planner and (optionally) the DiT — for RVC, training is 100% conventional PyTorch, with MPS as the only local-GPU acceleration path (CPU fallback also exists but would be dramatically slower for the ~200-400-epoch training runs Applio recommends).
- **Known MPS pitfalls to expect** (by direct analogy to the ACE-Step MPS gaps already documented in `docs/research/2026-07-05-ace-step-local-song-generation.md` §3 — e.g. `float64`-on-MPS crashes, watermark-ratio OOM tuning): RVC/fairseq-derived training pipelines have historically had scattered "unsupported operator" issues on MPS in the broader PyTorch ecosystem (not confirmed against RVC's current code specifically in this pass — **flag for the install-script spike**, since the exact failure mode, if any, will only surface by actually running Applio's training loop on this Mac). Community sentiment in the search results explicitly notes "PyTorch currently lacks support for some training-related optimizations" on MPS and that CUDA latency remains meaningfully lower.
- **Realistic sizing for this machine**: given 128 GB unified memory and a 40-core-class GPU, memory will not be the constraint (RVC training footprints are small compared to ACE-Step's own multi-GB DiT/LM stack) — the constraint is **wall-clock training time on MPS**, likely landing somewhere between "annoying but tolerable" (well under the M1's 6 hours, given the generational GPU gap) and "still slow enough that most users will train once per target voice and reuse the checkpoint" rather than iterating live. Treat "minutes, not hours" as aspirational until measured; budget for "an hour or more" as the safe planning assumption pending the spike.

### 3b. seed-vc: no training story needed (zero-shot)

If the GPL-3.0/archived-repo risk is accepted (or mitigated via the arm's-length-subprocess pattern with legal sign-off), seed-vc sidesteps the entire training question: the user supplies a 1-30 second clean reference clip of the target voice at conversion time, no dataset curation, no epoch tuning, no multi-hour training run. This is a materially simpler UX and worth spiking specifically to *quantify the quality gap* against a properly-trained RVC voice model, since "zero training, lower ceiling" vs. "real training, higher ceiling" is the actual tradeoff to validate, not assume.

### 3c. Ethical/legal note (orthogonal to license, still load-bearing)

Voice-cloning tooling — regardless of which library — raises an obvious risk: users training on a voice they don't have rights to (a celebrity singer, a bandmate without consent, etc.). This isn't a licensing question, it's a product-policy one. Recommend the same posture ACE-Step's own commercial-use framing implies: **DAW Pro's UI should frame this feature explicitly as "convert to your own voice" / "voice you have rights to use,"** not as a generic "impersonate any singer" tool, and should not ship or link to any pre-trained third-party celebrity voice models (which circulate widely in the RVC community but carry obvious consent/right-of-publicity risk) — training data must be the user's own recordings, full stop.

---

## 4. Integration architecture recommendation for DAW Pro

### 4a. Shape: a second local sidecar, same pattern as ACE-Step

Mirror the existing `SidecarManager`/`ACEStepClient` pattern exactly (documented in `docs/AI-INTEGRATIONS.md` and shipped per `ROADMAP.md` M6):

- **New sidecar**: a small FastAPI (or comparably thin) wrapper around the chosen VC library (RVC/Applio's inference path, or the MLX-native `Retrieval-based-Voice-Conversion-MLX` fork for speed), bound to **`127.0.0.1`** only, on a **new port distinct from ACE-Step's 8001** and the control WebSocket's 17600 — following the prior report's numbering convention, propose **`127.0.0.1:8002`**.
- **Process lifecycle**: same `SidecarManager`-actor shape as ACE-Step's (`Sources/AIServices/SidecarManager.swift` precedent) — health probe → notInstalled/installedNotRunning/starting/healthy/error states, lazy spawn on first use (not at app launch — even RVC's small models are still a cold-start cost not worth paying up front), idle teardown.
- **Facade, not raw passthrough**: same reasoning as ACE-Step's integration section — a narrow HTTP contract (`POST /v1/voice/train`, `GET /v1/voice/{voiceId}/status`, `POST /v1/voice/convert`, `GET /v1/voice/list`) so Swift/MCP depend on a stable name, not whichever underlying VC library's wire format we pick this year. This also gives us a clean seam to swap RVC for seed-vc, DDSP-SVC, or a future YingMusic-SVC-class model without touching the app or MCP surface.
- **Pipeline** (exactly as the user specified): generate song (existing `ai.generateSong`) → extract vocal stem (existing `ai.extractStems`, `track_name=vocals`) → **new**: send that stem to the VC sidecar for conversion to the target voice → import result as a new take/track via the **existing** import machinery (`ProjectStore.importGeneration`/take-group patterns already built for M6 (iii-a) and the M5 take-group/M6 (v-b) clip-fix comp-splice work) — no new import mechanism needed, just a new source feeding the same pipe.
- **Model storage**: trained voice models (small — tens of MB per RVC voice) live in an app-support directory alongside ACE-Step's weights, not bundled in the app.

### 4b. GPL/licensing gate on tool choice

Given §2's findings, the **default/shipped path should use RVC (MIT)**, not seed-vc (GPL-3.0, archived). This keeps the entire local-AI stack at the same MIT-clean bar as ACE-Step, with no legal-review dependency blocking ship. seed-vc (or DDSP-SVC as a lighter MIT fallback) stays a **research/spike-only, not-shipped-by-default** option pending either (a) a legal read clearing the arm's-length-subprocess argument for GPL, or (b) upstream releasing a permissively-licensed successor.

### 4c. Milestone split (sized like our other AI epics, cf. `ROADMAP.md` M6's `i` install/`ii` client/`iii` wire+import/UI/`v-c` real-gate pattern)

Proposed as a new M6 sub-track, e.g. **"Voice conversion (M6 vi)"**:

1. **(vi-a) Research spike / hands-on de-risking** (this doc is the desk-research half; still needed): actually run Applio training on this Mac with a real 10-30 min sample, time it, and separately run the `Retrieval-based-Voice-Conversion-MLX` inference path against a converted checkpoint — confirms real training time, confirms the MLX inference speedup claim on our own hardware, confirms no MPS unsupported-op blockers. This should land BEFORE committing to the architecture below in code, exactly like ACE-Step's own `profile_inference.py` spike was called out as a prerequisite in the prior report.
2. **(vi-b) Sidecar install script**: `scripts/rvc/install.sh` (idempotent venv, RVC/Applio + the MLX inference fork, model-download-free — no default pretrained *voice*, only the shared content-encoder/pitch-extractor assets) + `scripts/rvc/run.sh` (loopback-only FastAPI wrapper), mirroring `scripts/ace-step/install.sh`/`run.sh`'s shape.
3. **(vi-c) `VoiceConversionClient` + `SidecarManager`-pattern process management**: new Swift actor in `AIServices`, `vc.sidecarStatus/Start/Stop` control commands + MCP tools (matching `ai_sidecar_status/start/stop`'s naming convention), plus training/convert job submission mirroring `ACEStepClient`'s async submit/poll shape.
4. **(vi-d) Wire + MCP + pipeline glue**: `vc.trainVoice` (dataset path(s) in → training job), `vc.convertVocals` (stem path + target voiceId → converted-audio job), `import_voice_conversion` (reuse the take/track import machinery). Corresponding MCP tools so an agent can drive the whole "generate → extract → convert → import" chain in one conversation, matching the Copilot-rail catalog pattern already established.
5. **(vi-e) UI**: a small "Voice" panel — record/import training samples for a named voice, a train button with progress, and on the vocal stem/clip context menu a "Convert to voice..." action feeding the same violet AI-take/comp-splice pattern used by Clip Fix (M6 v-b) rather than inventing a new UI paradigm.
6. **(vi-f) Real-model gate**: end-to-end proof exactly like ACE-Step's (v-c)/(iii-c-real) gates — one real trained voice, one real conversion, continuity/quality-checked, before the box gets checked.

This mirrors the sizing (5-6 sub-items, research→install→client→wire+MCP→UI→real-gate) of the ACE-Step epic and the rail-a...rail-e Copilot epic already in `ROADMAP.md`.

### 4d. What requires keys or cloud — none, by design

Every component above (RVC/Applio training + MLX inference, or the DDSP-SVC/seed-vc fallbacks) is local-only, no API key, no per-call billing, no ToS dependency — consistent with the local-first mandate that already governs the ACE-Step decision. The only "cloud" mentioned anywhere in this survey (ElevenLabs-class services) is explicitly excluded from the recommendation.

---

## Actionable takeaways

1. **Don't build a new "vocals-only generation" mode.** Use the existing `extract` (task_type=`extract`, `track_name=vocals`) stem-extraction path — already shipped and real-gated — as the source of a clean vocal stem. Optionally thread an `"a cappella"`-style tag through the Sketchpad's generation caption as a cheap, already-supported nudge toward vocal-forward source material, but don't build product logic around it as a guaranteed isolated-vocal mode; it isn't one.
2. **Add a `docs/research/README.md` entry**: mark this report answered under "Standing questions," and add a new standing question: *"Time an actual Applio/RVC training run + `Retrieval-based-Voice-Conversion-MLX` inference pass on this exact Mac before committing VC architecture to code — no verified M-series-Max number exists yet for either."*
3. **Update `docs/AI-INTEGRATIONS.md`**: add a new row/subsection, "Voice conversion (planned) — RVC (MIT) local sidecar, `127.0.0.1:8002`, mirrors the ACE-Step `SidecarManager` pattern; seed-vc/DDSP-SVC noted as spike-only alternatives (GPL-3.0/archived and lighter-MIT-fallback respectively, not shipped by default)."
4. **Propose a new `ROADMAP.md` M6 sub-track "Voice conversion (M6 vi)"** with the six-item split in §4c above, gated first on the (vi-a) hands-on timing/quality spike — do not skip straight to install-script/client work given the total absence of verified Apple-Silicon-Max training-time data.
5. **Product-policy note for `docs/VISION.md` or wherever usage guidelines live**: frame the feature as "convert to a voice you have the rights to use" and never ship/link pretrained third-party celebrity voice models — training data must come from the user's own recordings.
6. **License hygiene**: keep RVC/Applio/MIT as the only *shipped-by-default* VC engine to preserve the same "fully MIT, no legal review needed" posture as ACE-Step. If seed-vc's zero-shot UX proves compelling enough in the spike to justify the GPL-3.0 exposure, that decision needs an explicit legal sign-off before it ships as anything other than an opt-in, user-installed, arm's-length subprocess — do not bundle its code in the DAW Pro installer without that review.

---

## Primary sources consulted

**Upstream ACE-Step source (read-only inspection, this repo):**
- `scripts/ace-step/runtime/src/acestep/constants.py` (lines 76-111, task type + track name constants)
- `scripts/ace-step/runtime/src/acestep/core/generation/handler/task_utils.py` (lines 80-98, task instruction/dispatch logic)
- `scripts/ace-step/runtime/src/acestep/core/generation/handler/conditioning_masks.py` (lego/repaint source-latent handling)
- `scripts/ace-step/runtime/src/acestep/genres_vocab.txt` (lines 1295-57055 region, "a cappella" tag family, 200+ matches)
- `scripts/ace-step/runtime/src/acestep/constrained_logits_processor.py` (lines 187-240, 953-1002, 1131-1183, 1954-1962 — how `genres_vocab.txt` constrains LM caption decoding)
- `scripts/ace-step/runtime/src/acestep/api/server_utils.py` (line 135, `is_instrumental`), `acestep/inference.py` (line 1351), `acestep/ui/gradio/events/generation/ui_helpers.py` (line 206, instrumental checkbox)
- `scripts/ace-step/runtime/src/docs/en/Tutorial.md` (lines 200-334, model/task tables; lines 780-833, Repaint/Lego/Complete descriptions incl. the "a cappella vocals" Complete-task example at line 825)
- `scripts/ace-step/runtime/src/docs/en/ace_step_musicians_guide.md` (lines 60-210, six-creative-modes overview, Extract/Lego/Complete descriptions, hardware tiers)
- This repo's own prior work: `docs/research/2026-07-05-ace-step-local-song-generation.md`, `docs/AI-INTEGRATIONS.md`, `docs/ROADMAP.md` (M6 section, lines 82-103 — sidecar/client/import/stems/repaint/clip-fix shipped history and sizing convention)

**Voice conversion survey (web, dated 2026-07-11):**
- https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI (`LICENSE` — MIT; issue #767 "Training on Apple Silicon"; issues #2689, #119, #867 — quality/artifact complaints)
- https://github.com/IAHispano/Applio and https://docs.applio.org/getting-started/training (MIT license, training dataset/epoch guidance)
- https://github.com/Acelogic/Retrieval-based-Voice-Conversion-MLX (MLX-native inference-only Apple Silicon fork, performance claims)
- https://github.com/Plachtaa/seed-vc (README, `LICENSE` — GPL-3.0; archived 2025-11-21; Apple Silicon support changelog; zero-shot training-free workflow; model sizes)
- https://github.com/svc-develop-team/so-vits-svc (`LICENSE` — AGPL-3.0; archived 2023-11-11) and https://github.com/voicepaw/so-vits-svc-fork (`LICENSE` — dual MIT/Apache-2.0 for fork code)
- https://github.com/yxlllc/DDSP-SVC (`LICENSE` — MIT; README training/dataset/quality claims)
- https://arxiv.org/abs/2512.04793 (YingMusic-SVC paper) and https://github.com/GiantAILab/YingMusic-SVC (MIT, code+weights released, CUDA-first install docs); https://github.com/GiantAILab/YingMusic-Singer (sibling singing-synthesis project, not VC, flagged to avoid confusion)
- https://huggingface.co/Plachta/Seed-VC (weights hosting, license not independently confirmed in this pass — flagged as an open item)
