# M10 (m10-p-1) — Voice-conversion hands-on feasibility spike: findings

**Date**: 2026-07-11 (measurement half completed 2026-07-17) · **Method**: live clone/venv/run of the candidate engine against a real vocal stem, in an isolated scratch directory (never touching `scripts/ace-step/` or shipped code). Machine: Apple M5 Max, 128 GB unified memory, macOS 26.4. Timeboxed per the task.

> **STATUS 2026-07-17: COMPLETE — GO.** The 2026-07-11 run was PARTIAL, blocked on a corp-network window that prevented every neural-asset fetch. That window has lifted; on 2026-07-17 all required assets were acquired and the missing neural numbers were measured on this M5 Max. **Engine verdict: GO** — the MLX fork's inference path runs end-to-end fast (RMVPE warm RTF 94.8×, ContentVec/HuBERT warm RTF 574×, full MLX pipeline warm RTF 38×) and the PyTorch-MPS training path runs a real GAN step with zero MPS CPU fallbacks (3.23 steps/s). Full details in the **"2026-07-17 continuation"** section below. The 07-11 narrative and blocker evidence are preserved unedited as the historical record.

Desk research this spike verifies/corrects: `docs/research/2026-07-11-vocals-voice-conversion.md` §2a, §2f, §3a, §4b, §4c.

## Verdict

**NO-GO on measuring real conversion quality/speed today — blocked on asset acquisition, not on engine choice.** The MLX fork (`Acelogic/Retrieval-based-Voice-Conversion-MLX`) clones, installs cleanly (Python 3.11 venv via `uv`, all deps resolve from plain PyPI — no corp-proxy issues there), and both its MLX and PyTorch-MPS backends are functionally live in-process (`mx.default_device()` → GPU, `torch.backends.mps.is_available()` → `True`, a real MPS matmul executed). **But every shared asset RVC needs — the HuBERT/ContentVec content encoder, the RMVPE/FCPE pitch-extractor weights, and even the *generic, non-personal* Applio base pretrains — lives on HuggingFace's LFS/CDN path, and that path hard-times-out under this machine's corp TLS-interception proxy on every route tried** (direct `huggingface.co/resolve/...`, `-L` through `hf-mirror.com`, HTTP/1.1 forced, `curl` and would-be `wget`). This blocks inference *and* training identically, on *either* engine (MLX fork or PyTorch-MPS Applio) — the assets are the same files regardless of which runtime consumes them. Small-file/API HuggingFace endpoints (`/api/models/...`, `/raw/...`) work fine and fast, so this is specifically a large-binary/LFS block, not a DNS or full-domain block.

The one thing measured against **real audio with zero downloaded weights** was classical (non-neural, pure-DSP) WORLD-vocoder pitch extraction (`pyworld.harvest`) on the actual 30 s vocal stem — see table below. That is not voice conversion and should not be read as one; it's included only as an honest "the machinery that doesn't need a network fetch works, and here's its speed" data point.

**Recommendation for p-2**: do NOT spend p-2's install-script budget assuming the corp network. Either (a) perform the one-time asset download from a non-corp network / hotspot and then commit the resulting files into a durable local cache (`~/.cache/huggingface`, already whitelisted for reuse per this task's own hard rules) so `scripts/rvc/install.sh` in a later item can assume they're present, or (b) have `install.sh` degrade gracefully with the same actionable-error contract the rest of DAW Pro uses ("required voice-conversion assets could not be downloaded — corp network blocks huggingface.co LFS/CDN; download manually from `<url>` and place at `<path>`, or run from an unrestricted network") rather than hanging. Do not silently retry-loop against the LFS host.

## Corrections to the desk-research doc

1. **The MLX fork is *not* inference-only.** §2a/§3a of the desk research states training must go through standard PyTorch/Applio because "no MLX-native RVC training implementation exists." False as of this fork's current state (commit `eec7791`, 2026-01-11): `rvc-mlx-cli.py` has a real, non-stub `train` subcommand, and `rvc_mlx/train/` contains 2,636 lines across `trainer.py`, `data_loader.py`, `losses.py`, `discriminators.py`, `schedulers.py`, `mel_processing.py`, `overtraining_detector.py` — a genuine GAN training loop (generator/discriminator/losses/LR schedulers), not a placeholder. **Caveat: this spike did not execute the training loop** (blocked on the same missing pretrain assets as inference), so "does it actually converge / hit MPS-unsupported-ops on this Mac" is still unverified — but "no training path exists at all" is now known to be wrong and should not gate the p-2 plan.
2. **License is still unverified, and the doc's caveat stands as written — do not upgrade it to "confirmed MIT."** `pyproject.toml` declares `license = { text = "MIT" }`, but there is still **no `LICENSE` file anywhere in the repo** (`find . -iname "LICENSE*"` → nothing) and GitHub's own license detector agrees: `gh repo view` reports `licenseInfo: null`. Given the project is a fork-of-a-fork of Applio (MIT) and RVC-WebUI (MIT), an MIT self-declaration is plausible, but there is no license *grant* text anywhere in this repo to point to. **Before shipping anything derived from this fork, add a real license check as a p-2/vi-b task**, e.g. open an issue asking the maintainer to add the `LICENSE` file, or fall back to consuming Applio directly (which does have a `LICENSE` file) for the parts that matter.
3. **The repo's own demo/benchmark voices are celebrity models and must never be used or referenced further.** The README's Swift-parity table and benchmark section use checkpoints named "Drake," "Juice WRLD," "Eminem Modern," "Bob Marley," "Slim Shady." Per this task's hard rule (no celebrity/third-party-person voice models, ever) these were **not downloaded, not run, and are flagged here only so nobody on this project mistakes them for a legitimate demo/test asset later.** No non-personal, rights-clear trained voice checkpoint exists anywhere in this fork or in the referenced Applio asset set — Applio's own shared downloads (`prerequisites`) are all *pre-speaker* assets (encoder/pitch-extractor/untrained-generator-initialization weights), not a usable "generic voice." This confirms the desk research's own fallback framing in its hard rules was the right call: a real conversion target arrives only via training on the user's own voice, in a later sub-item — there is no shortcut demo voice to spike against.

## Measured numbers

| Measurement | Value | Notes |
|---|---|---|
| Input sample | `input-vocals.wav` (copy of `gen-stems-...-vocals.wav`) | 30.00 s, 48 kHz, 16-bit PCM, 2ch, 5,760,078 bytes — confirmed via `afinfo` |
| Input RMS / peak | RMS 0.0973, peak 0.891 (float-normalized) | Confirms non-silent, real vocal content — computed with `soundfile`/`numpy`, no listening |
| Repo clone | ✅ succeeds, shallow clone, ~1–2 s | `git clone --depth 1` |
| `uv venv --python 3.11` | ✅ succeeds instantly | `uv` already had `cpython-3.11.15-macos-aarch64` cached locally |
| `uv sync` (full dep install, PyPI) | ✅ succeeds, no corp-network issues | torch 2.4.0, torchaudio 2.4.0, torchvision 0.19.0, mlx (mlx-metal 42.9 MB), transformers 4.57.3, faiss-cpu, librosa, numba, llvmlite, scikit-learn, matplotlib, pyworld, etc. — 91 packages resolved, `.venv` = 1.0 GB on disk |
| `torch.backends.mps.is_available()` | `True`; live MPS 1000×1000 matmul executed | PyTorch-MPS backend is real and usable on this venv |
| `mlx.core.default_device()` | `Device(gpu, 0)`; live `mx.array` op executed | MLX GPU backend is real and usable on this venv |
| ~~**Neural inference (RVC content encoder / RMVPE / decoder)** — NOT MEASURED — blocked~~ | **MEASURED 2026-07-17 (network unblocked, assets acquired)** — see rows below and the 2026-07-17 continuation | The 07-11 block was a network window, not a permanent block; assets now cached under `~/.cache/huggingface/daw-pro-rvc/` |
| → RMVPE neural pitch (MLX) on 30 s stem | **warm RTF 94.8× (0.316 s) · cold RTF 49.7× (0.604 s)** | 3001 frames, 90% voiced, F0 mean 244 Hz, finite; best-of-3 warm |
| → ContentVec/HuBERT content encoder (MLX) on 30 s stem | **warm RTF 574× (0.052 s) · cold RTF 412× (0.073 s)** | out (1, 1499, 768), finite, all 211/211 weight tensors loaded (no random layers); best-of-3 warm |
| → Full pipeline end-to-end (MLX, **untrained base target**, sid=0) | **warm RTF 38.0× (0.790 s) · cold RTF 14.3× (2.10 s)** | output 29.98 s / 40 kHz, finite, RMS 0.34 — NOT a real voice conversion (base/untrained emb); exercises TextEncoder+Flow+HiFiGAN-NSF end-to-end |
| ~~**Neural training probe (Applio/RVC on MPS)** — SKIPPED — blocked~~ | **MEASURED 2026-07-17: 3.23 steps/s (310 ms/step)** @ B=2, 900 frames, 40 k; 20.8 s first-step MPS compile; **NO MPS CPU fallbacks** | Real Applio GAN step (net_g+net_d forward/backward, mel/kl/fm/adv losses, AdamW.step) from the generic base pretrains; losses decreasing (disc 5.2→1.8, gen_all 93.8→82.9). One benign warning: >3-dim constant pad uses MPS View-Ops path (stays on GPU). Timebox not hit (24 s total). See continuation |
| `pyworld.harvest` F0 extraction on real 30 s stem (DSP-only, no weights) | **2.141 s wall, RTF 14.0×, 1395/3001 voiced frames (46%)** | CPU-only classical pitch tracker, not RMVPE (the project's neural default) and not voice conversion — included only as an honest "what actually ran against real audio" data point per the task's fallback instruction |

## 2026-07-17 continuation — network unblocked, neural numbers acquired

The measurement half of this spike was re-launched on 2026-07-17 after the orchestrator confirmed the corp large-binary/LFS block had lifted. Everything below was run in a fresh session scratch clone (`.../scratchpad/m10p1-work/rvc-mlx`), same proven recipe (`uv venv --python 3.11` + `uv sync`, 91 pkgs from plain PyPI, clean — reconfirmed). Machine: Apple M5 Max, 128 GB, macOS 26.4. Env versions: torch 2.4.0, transformers 4.57.3, mlx 0.30.1, faiss-cpu, Python 3.11. `OMP_NUM_THREADS=1` set per the fork's benchmark README.

### Network unblock — confirmed

The 07-11 prediction ("likely a network-window condition, not permanent") was correct. On 2026-07-17 the exact blocker-#1 URL shape now serves large binaries: a ranged probe `curl -sSL -r 0-1048575 https://huggingface.co/IAHispano/Applio/resolve/main/Resources/predictors/rmvpe.pt` returned **HTTP 206**, 1,048,576 bytes, and full downloads sustained **6–9 MB/s** (far above the orchestrator's earlier 1–2.4 MB/s probe). No HF token was needed — all files are public; nothing required auth (per the hard rule, no key was used or would have helped a network-layer block anyway). `curl -L` is required (the `resolve/main/...` path 302-redirects to `/api/resolve-cache/...`).

### Asset acquisition record

Downloaded one file per call with resumable `curl -L -C -`. All byte sizes match the 07-11 API-derived sizes exactly (the "Exact install shape" table). Durable cache (task-allowed): `~/.cache/huggingface/daw-pro-rvc/IAHispano-Applio/Resources/`, symlinked into the fork's expected `rvc/models/...` tree.

| File (Applio `Resources/…`) | Bytes | sha256 | DL wall |
|---|---|---|---|
| `predictors/rmvpe.pt` | 181,184,272 | `6d62215f4306e3ca278246188607209f09af3dc77ed4232efdd069798c4ec193` | 20.3 s |
| `embedders/contentvec/pytorch_model.bin` | 378,342,945 | `d8dd400e054ddf4e6be75dab5a2549db748cc99e756a097c496c099f65a4854e` | 46.4 s |
| `embedders/contentvec/config.json` | 1,388 | `2ddde063b795d38d9051a7215a092fecf4cfe148b54251e38de51d88d356898b` | <1 s |
| `pretrained_v2/f0G40k.pth` | 73,106,273 | `3b2c44035e782c4b14ddc0bede9e2f4a724d025cd073f736d4f43708453adfcb` | 11.9 s |
| `pretrained_v2/f0D40k.pth` | 142,875,703 | `6b6ab091e70801b28e3f41f335f2fc5f3f35c75b39ae2628d419644ec2b0fa09` | 16.5 s |

Total ≈ 775 MB in ≈ 95 s of transfer. `fcpe.pt` (alt pitch extractor, ~41 MB) was NOT fetched — RMVPE is the fork's default and the only pitch method the MLX path supports (`--f0_method {rmvpe}`); not needed for the measured path.

**Derived asset (conversion artifact, not a download):** `embedders/contentvec/model.safetensors` (378,298,184 B) — see the toolchain gotcha below.

### Toolchain gotcha p-2 MUST handle (new, blocking without the workaround)

The fork's `tools/convert_hubert.py` loads ContentVec via `transformers`' `HubertModelWithFinalProj.from_pretrained(...)`, which with the pinned **torch 2.4.0** now hard-**errors**: transformers 4.57.3 refuses `torch.load` of a `.bin` unless torch ≥ 2.6 (CVE-2025-32434). Two clean fixes; I used (a):
- **(a)** Convert `pytorch_model.bin` → `model.safetensors` once (load state-dict with `torch.load(weights_only=True)`, re-save with `safetensors.torch.save_file`); `from_pretrained` then prefers the safetensors path and skips the guard. This is what p-2's install step should do — ship/produce a `model.safetensors` next to the `.bin`.
- **(b)** Alternatively bump torch to ≥ 2.6 (risks other pin drift in this stack; not tested here).
This gotcha is NOT a network issue and would hit a clean install regardless of network — p-2 must bake the safetensors conversion (or a torch bump) into `install.sh`, or `convert_hubert` fails on first run.

### MLX weight conversion (required before MLX inference)

The MLX inference path consumes MLX-native `.npz`, not the raw PyTorch weights. All three conversions ran clean via the fork's own `tools/`:
- `convert_rmvpe.py`: `rmvpe.pt` → `rvc_mlx/models/predictors/rmvpe_mlx.npz` (741 → 623 tensors, ~0.8 s).
- `convert_hubert.py`: ContentVec → `rvc/models/embedders/contentvec/hubert_mlx.npz` (213 → 211 tensors, ~1.8 s; needs the safetensors fix above).
- `convert_pth_to_mlx.py`: base `f0G40k.pth` → `rvc_mlx/models/checkpoints/base_f0G40k.npz` (560 tensors, weight-norm folded, ~69.6 MB) — used only to give the full pipeline a loadable (untrained) Synthesizer.

### Per-leg neural numbers (this M5 Max)

All against the 30.00 s synthetic vocal stem (see provenance). Timing uses a warmup pass to amortize MLX JIT, then best-of-3; "cold" = first full-length call including compile.

| Leg | Warm wall / RTF | Cold wall / RTF | Output check |
|---|---|---|---|
| RMVPE neural pitch (MLX) | 0.316 s / **94.8×** | 0.604 s / 49.7× | 3001 frames, 90.0% voiced, F0 mean 244 Hz (min 160 / max 343), finite |
| ContentVec/HuBERT encoder (MLX) | 0.052 s / **574×** | 0.073 s / 412× | shape (1, 1499, 768), finite, mean −0.01 std 0.32; **211/211 param tensors loaded** (verified none left at random init — the fast number is real, not a skipped forward) |
| Full pipeline end-to-end (MLX) | 0.790 s / **38.0×** | 2.10 s / 14.3× | output 29.98 s @ 40 kHz, 1,199,200 samples, finite, RMS 0.34, peak 0.99 |

The full-pipeline output is **intact but not a meaningful voice** — it ran against the generic Applio base pretrain (sid=0, untrained 109-speaker emb), so it exercises the complete synthesis graph (content encode → RMVPE pitch → TextEncoder → Flow → HiFiGAN-NSF generator) for a real end-to-end timing, but produces base-model timbre, not a conversion to any target. This is exactly the roadmap contract's anticipated stopping point: **there is no legitimate conversion target to spike against — real target voices arrive only via p-6 training on the user's own recordings.** No celebrity/demo checkpoint was downloaded, run, or referenced (the fork's demo voices remain the flagged-off celebrity models from correction #3).

Reference: the fork's own `benchmarks/README.md` claims ~28–30× realtime RMVPE and ~1.7× MLX-vs-MPS on the authors' M1/M2/M3; this M5 Max comfortably exceeds those (RMVPE 94.8× warm), so the fork's perf claims are conservative on current hardware, not optimistic.

### PyTorch-MPS training probe (timeboxed — a few steps only, NOT a full run)

Built a tiny stem-derived batch and ran real Applio GAN steps on the MPS backend, initialised from the generic base pretrains `f0G40k.pth`/`f0D40k.pth` (109-speaker generator + MPD/MSD v2 discriminator). Batch: B=2, 900 frames (9 s) @ 40 kHz — real linear spectrogram + real stem-derived content features (2×-repeated HuBERT) + real RMVPE pitch, exactly the tensor shapes the fork's `data_utils` collate produces. Each step = generator forward → discriminator step (backward+AdamW) → generator step (mel-L1 + KL + feature-matching + adversarial, backward+AdamW), matching `rvc/train/train.py` lines 683–782.

- **Throughput: 3.23 steps/s (309.8 ms/step)**, best over 6 steps after a **20.8 s first-step MPS kernel-compile** warmup.
- **Convergence signal:** losses moved (disc 5.24 → 1.82, gen_all 93.76 → 82.87) across the few steps — backprop genuinely updates the base model. (Convergence *quality* over a real run is still unproven and out of scope — this is a steps/sec + op-coverage probe only.)
- **MPS op coverage: NO CPU fallbacks.** With `PYTORCH_ENABLE_MPS_FALLBACK=1` set, zero `aten::… falling back to CPU` warnings were emitted across the whole GAN step (STFT/mel, conv1d, conv-transpose, attention, MPD/MSD). The **only** MPS warning was benign: *"MPS: The constant padding of more than 3 dimensions is not currently supported natively. It uses View Ops default implementation to run"* — this stays on the GPU (a perf note, not a CPU fallback). This upgrades correction #1: not only does training code exist, a real MPS training **step executes natively** on this Mac.
- Timebox: the whole probe finished in **24 s** wall — nowhere near the 15-min cap.

Caveat carried forward: 3.23 steps/s at B=2 is a *per-step* number, not a *time-to-a-usable-voice* number. Applio's own guidance is hundreds of epochs over a few-minutes dataset; extrapolating a total training wall time from one warm step is not something this probe justifies. p-6 must do its own timed real run. But the two things that could have killed the plan — "does an RVC training step even run on MPS" and "does it hit an unsupported op" — are now answered YES / NO-unsupported-op.

### License re-check (2026-07-17)

**Unchanged from 07-11: still no license grant.** `gh repo view Acelogic/Retrieval-based-Voice-Conversion-MLX --json licenseInfo` → `{"licenseInfo": null}` (repo last pushed 2026-03-05, i.e. the maintainer has pushed *since* the 07-11 check and still added no LICENSE). `find` over the fresh clone tree → no `LICENSE*` file anywhere; the GitHub Contents API for the default branch lists none. The only license assertion remains `pyproject.toml`'s `license = { text = "MIT" }` self-declaration, which GitHub's detector does not accept as a grant. **Correction #2 stands verbatim: do not upgrade to "confirmed MIT."** Before shipping anything derived from this fork, p-2/vi-b must either get a real `LICENSE` file added upstream (file an issue) or consume Applio's own MIT-licensed code paths (Applio ships a real `LICENSE`) for the parts that matter. All *assets* used here are from `IAHispano/Applio` (MIT, has LICENSE) — the license gap is specifically the MLX *fork's code*, not the model weights.

### Test-stem provenance (disclosed)

The 07-11 stem (a real ACE-Step vocal) died with its session, so this run used a **fully synthetic, rights-clear stem** generated in-session (`scratchpad/m10p1-work/make_stem.py`, no external audio, no real person's voice, no ACE sidecar started): a sung-vowel-like source — harmonic glottal pulse train (40 harmonics, 1/n glottal rolloff) driven by a stepwise 16-note melody around A3 (220 Hz) with 5.5 Hz vibrato, three formant band-passes for an "ah" vowel color, per-note ADSR envelopes, and short band-limited breath-noise segments between notes for unvoiced content. Output: 30.00 s, 48 kHz, 16-bit PCM, 2ch, RMS 0.294, peak 0.90, 85% voiced. This gives RMVPE real trackable pitch (it recovered F0 mean 244 Hz over 90% voiced frames — sane for the melody) and HuBERT real spectro-temporal structure. It is *cleaner and more periodic* than a human take, so absolute RTFs here are, if anything, a mild best case for the pitch tracker; the order-of-magnitude verdict is unaffected. Because the ACE sidecar was never needed, its port 8001 / `.ace-step.pid` were untouched (rule honored trivially).

### Final engine verdict (2026-07-17) — GO

**GO on the MLX fork as the primary VC engine, with a PyTorch-MPS training path now proven to execute a real GAN step natively on this Mac.** This supersedes the 07-11 "Conditional GO, scope-adjusted" (kept below as history). What changed: the only thing ever missing — the neural numbers — now exists, and every one is positive:
- Inference is fast and correct: RMVPE 94.8× and ContentVec/HuBERT 574× warm RTF, full MLX pipeline 38× warm RTF, all producing finite, correctly-shaped, sane-RMS output; even the cold (with-JIT) full pipeline is 14.3× realtime, so processing a ~30 s clip costs ~2 s worst case.
- Training is viable on-device: a real Applio GAN step runs on MPS at 3.23 steps/s with **zero unsupported-op CPU fallbacks** and moving losses — the "will training even run on MPS / will it hit a missing op" risk is retired.
- No engine-level blocker surfaced. The remaining gates are process, not feasibility: (1) the fork's **missing LICENSE** (unchanged — resolve upstream or fall back to Applio's MIT code before shipping the fork's *code*; the assets are already MIT via IAHispano/Applio), and (2) there is **no legitimate target voice** until p-6 trains one on the user's own audio.

**Install-shape confirmations/corrections for p-2** (deltas vs the "Exact install shape" section immediately below, which is otherwise reconfirmed accurate):
1. **Network is NOT a hard blocker anymore** — the 07-11 "make asset-fetch the first thing p-2 proves; assume corp network can't fetch weights" caution is downgraded: the standard `resolve/main/...` LFS path works (`curl -L`, HTTP 206 ranged, 6–9 MB/s). Keep the actionable-error fallback in `install.sh` (the block was a window and could recur), but it need not be p-2's first gating task. All ~775 MB now live at `~/.cache/huggingface/daw-pro-rvc/IAHispano-Applio/Resources/` for reuse.
2. **NEW blocker p-2 must bake in:** the torch-2.4 / transformers-4.57 `torch.load`-of-`.bin` guard (CVE-2025-32434) breaks `convert_hubert.py` on a clean install. `install.sh` must produce `model.safetensors` from `pytorch_model.bin` (or pin torch ≥ 2.6). Not optional — first-run HuBERT conversion fails otherwise.
3. **MLX inference needs a conversion step, not just a download.** p-2's asset stage must run `convert_rmvpe.py`, `convert_hubert.py`, and (per trained model) `convert_pth_to_mlx.py`/`convert_rvc_model.py` to produce `rmvpe_mlx.npz` / `hubert_mlx.npz` / model `.npz`; the raw `.pt`/`.bin` are not consumed by the MLX runtime directly. RMVPE MLX loader path: `rvc_mlx/models/predictors/rmvpe_mlx.npz`; HuBERT loader path: `rvc_mlx/models/embedders/contentvec/hubert_mlx.npz` then `rvc/models/.../hubert_mlx.npz`.
4. **`OMP_NUM_THREADS=1` is mandatory** at runtime (faiss segfault guard, per the fork's benchmark README) — set it in the sidecar launch env.
5. Everything else in the "Exact install shape" section (Python 3.11, `uv venv` + `uv sync`, 91 pkgs from plain PyPI, torch/torchaudio/torchvision 2.4.0, ~1.0 GB venv) reproduced exactly on 2026-07-17 — no drift.

## Exact install shape for p-2

- **Python**: 3.11 (repo pins `.python-version` = `3.11`, `pyproject.toml` requires `>=3.10`). System `python3` is 3.14.5 (Homebrew) — too new / untested for this stack; use `uv python install 3.11` (already cached on this machine) or an explicit pyenv/homebrew 3.11.
- **Venv tool**: `uv venv --python 3.11 .venv` then `uv sync` (repo ships a `uv.lock`, 637 KB — deterministic resolve). All 91 packages installed from plain `pypi.org` with zero workarounds needed — unlike the flash-attn/ACE-Step precedent, this stack has no C-extension-from-source or GitHub-hosted sdist that trips the corp TLS interceptor at *pip* time. The problem is entirely at *model-weight* fetch time (HuggingFace LFS/CDN), not package-install time.
- **Package list** (from `requirements.txt` / `pyproject.toml`, 53 declared deps): core numeric (`numpy<2`, `scipy`, `librosa`, `soxr`, `soundfile`), MLX (`mlx`), PyTorch pinned to `2.4.0` for `torch`/`torchaudio`/`torchvision` (darwin-only markers), `faiss-cpu==1.7.4` (retrieval index), `numba==0.60.0` + `llvmlite` (JIT), `transformers`, `einops`, `pedalboard`, `noisereduce`, `stftpitchshift`, `pyworld>=0.3.4` (classical F0), `edge-tts`/`webrtcvad` (TTS/VAD side-features not needed for the VC-only path), `matplotlib`/`tensorboard`/`tensorboardX` (training telemetry only), `pytest`/`pytest-timeout` (repo's own test suite).
- **Shared assets required before ANY inference or training run** (none bundled in git — all via `IAHispano/Applio` HF repo, `Resources/` prefix):

  | Asset | Purpose | Size | Source |
  |---|---|---|---|
  | `predictors/rmvpe.pt` | Default neural pitch extractor | 181,184,272 B (~172.8 MB) | `huggingface.co/IAHispano/Applio/resolve/main/Resources/predictors/rmvpe.pt` |
  | `predictors/fcpe.pt` | Alternate pitch extractor | 43,362,881 B (~41.3 MB) | same repo, `Resources/predictors/fcpe.pt` |
  | `embedders/contentvec/pytorch_model.bin` | HuBERT/ContentVec content encoder (the shared, speaker-agnostic half of RVC) | 378,342,945 B (~360.8 MB) | same repo, `Resources/embedders/contentvec/` (`config.json`, 1,388 B, is small enough it's not LFS-gated) |
  | `pretrained_v2/f0G40k.pth` + `f0D40k.pth` | Generic (non-personal) RVC v2 base generator/discriminator — training-initialization weights, **not** a usable voice by themselves | 73,106,273 B + 142,875,703 B (~69.7 + 136.3 MB) | same repo, `Resources/pretrained_v2/` (also ships 32k/48k variants at similar sizes) |
  | A trained per-speaker `.pth`/`.index` pair | The actual "target voice" | tens of MB, per RVC's own norms | **Does not exist yet for this project** — must come from training on the user's own recordings in a later sub-item; never a third-party/celebrity checkpoint |

  All sizes above were obtained via HuggingFace's small, fast **API** endpoint (`GET /api/models/IAHispano/Applio/tree/main/Resources/<subdir>`, which returned instantly) specifically *because* the LFS/CDN download path itself was unreachable — this is a reusable trick for p-2 to size things without needing the blocked path.
- **Venv layout used in this spike** (for reference, not for reuse — this was in scratch, not durable):
  `/private/tmp/.../scratchpad/vc-spike/rvc-mlx/.venv` — 1.0 GB after `uv sync`. For p-2, mirror ACE-Step's precedent and put the durable venv under an app-support-adjacent path (e.g. `~/Library/Application Support/DAWPro/rvc/venv` or wherever `scripts/ace-step/install.sh` puts ACE-Step's own venv — check that script for the exact convention before inventing a new one), **not** inside the git repo.
- **Model-weight cache**: since the task's hard rules explicitly allow `~/.cache/huggingface` for durable reuse, once the network workaround below lands, run the fork's own `python rvc-mlx-cli.py prerequisites --models --pretraineds_hifigan` (downloads RMVPE/FCPE/ContentVec + base pretrains into the repo's own `rvc/models/...` tree, not HF's cache dir — note this tool does *not* use `~/.cache/huggingface` natively; either patch it to point there or accept a second copy inside the app-support venv tree).

## MPS/MLX blockers hit and workarounds

- **No MPS/MLX *compute* blockers were hit** — both backends initialize and execute correctly in this venv (`torch.backends.mps.is_available()` → `True` with a live matmul; `mx.default_device()` → GPU with a live op). This directly contradicts nothing in the desk research (which correctly flagged this as unmeasured) but is a genuinely new, positive data point: no MPS "unsupported operator" surfaced *for the operations exercised* — caveat that only trivial ops were exercised (no real model forward pass ran), so this is not a clearance for the full pipeline, just evidence the environment itself isn't broken.
- **The actual blocker is entirely at the network/asset layer, not MPS/MLX**, and is not specific to this fork — it would hit vanilla Applio/RVC-WebUI identically, since they pull the exact same HF-hosted assets.

## Network workarounds used (and their results)

Every attempt below hit the same wall — recorded per the task's instructions so p-2 doesn't repeat this exploration from scratch:

1. `curl` direct `https://huggingface.co/IAHispano/Applio/resolve/main/Resources/predictors/rmvpe.pt` (full and byte-ranged `-r 0-2047`) → TLS handshake succeeds (cert issued by the corp Netskope interception CA, verified OK), HTTP/2 request sent, then **hard timeout, 0 bytes received**, reproduced 4× including with `--http1.1` forced.
2. `curl -L` through `hf-mirror.com` (a known public HF mirror, different front-end domain) → front-end responds with a fast `308` redirect, but following it to the actual CDN payload host hits the **identical hard timeout**, confirming this is a binary/CDN-payload block, not a `huggingface.co`-domain-specific block.
3. `wget` — not installed on this machine; not pursued further (would use the same TLS stack behavior).
4. **What does work**: `huggingface.co`'s lightweight JSON API (`/api/models/...`, `/api/models/.../tree/main/...`) and small non-LFS files (`/raw/...`) — all returned in <1s. Used this to get exact asset sizes (table above) without touching the blocked path. Plain `pypi.org` (used by `uv sync` for all 91 packages) was also fully unaffected — this is specifically an HF-LFS/CDN-binary-payload block, most likely the same class of corp DLP/content-inspection proxy behavior noted for `flash-attn` during the ACE-Step spike, just on a different vendor's CDN.
5. Not tried (out of timebox): authenticated `huggingface-cli`/`hf_hub_download` with a token (unlikely to route around a network-layer TLS-proxy block, since it's the same underlying HTTPS connection); a corporate Artifactory generic-file proxy for HF (unknown if one exists — worth asking IT/checking `~/.npmrc`'s sibling configs for a `pip.conf`/generic-artifact mirror before p-2, since the existing `~/.npmrc` already proves this org runs an internal Artifactory that could plausibly mirror HF too).

## GO/NO-GO recommendation for p-2

> **HISTORICAL (2026-07-11, written under the network block).** Superseded by the "Final engine verdict (2026-07-17) — GO" in the continuation section above, which has the measured numbers. Kept verbatim for the record; item 2 (network as hard prerequisite) is downgraded and item 3 (training unproven) is now partially answered — see the 07-17 verdict.

**Conditional GO, scope-adjusted: ship p-2 as an inference-only sidecar install script, with training explicitly deferred, and make the asset-fetch step the first thing p-2 proves — before writing any client/wire code.**

1. **Engine choice stands as recommended by the desk research**: MLX fork (`Acelogic/Retrieval-based-Voice-Conversion-MLX`) as the primary target once assets are obtainable, since it installed cleanly, has real training code (correction #1 above) in addition to inference, and both MLX and MPS backends are live in the same venv (so a PyTorch-MPS fallback path costs nothing extra to keep open). No evidence surfaced this spike that would downgrade it to "neither."
2. **Do not let p-2 assume the corp network can fetch model weights.** The very first task in p-2 should be resolving the asset-download path (off-corp-network one-time fetch into `~/.cache/huggingface` or an internal Artifactory mirror) — treat it as a hard prerequisite, not a detail to solve inline in `install.sh`. If p-2 can't resolve this in its own timebox, `install.sh` must fail with the actionable-error pattern this project already uses elsewhere ("required voice-conversion model assets unavailable — corp network blocks the HuggingFace CDN; fetch manually from `<url>`, `<size>`, place at `<path>`"), never hang or silently retry.
3. **Defer training to its own later sub-item, unchanged from the desk research's §4c sequencing** — this spike neither confirms nor denies real training performance (blocked pre-compute), so budget the "an hour or more" placeholder from the desk research until a real timed run happens, once assets are reachable.
4. **Add a license follow-up** (new, from correction #2): file/ask upstream for a `LICENSE` file on the MLX fork, or plan to consume Applio's own MIT-licensed code paths directly if that doesn't materialize before p-2 ships anything.
5. **No voice model exists to gate on yet** — reconfirm the desk research's own framing: the real-conversion "vi-f" gate can only happen after a training sub-item produces a voice from the *user's own* recordings. Nothing in this spike changes that; it only confirms there's no legitimate shortcut demo voice anywhere in the surveyed assets.

## Artifacts (scratch only, not committed)

All work products live under `/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/947983f7-3e00-47c6-8702-652879ee87c9/scratchpad/vc-spike/` (clone, `.venv`, copied input WAV, `uv-sync.log`) — ephemeral, per the task's hard rules; nothing here is meant to survive past this conversation except this doc.
