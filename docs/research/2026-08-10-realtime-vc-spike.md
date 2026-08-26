# m23-fc — Real-time / streaming voice conversion: architecture spike

**Date:** 2026-08-10 · **Route:** `daw-architect` · **Status:** SPIKE COMPLETE — recommendation is
**re-scope m23-fc; do not build a real-time VC insert.**

This is a design deliverable. No engine or app code was modified. `scripts/rvc/` was treated as
strictly read-only; nothing was written there. Every measurement below was produced by throwaway
scripts in the session scratchpad against the vendored tree's own venv.

---

## 0. Verdict in one page

| Question | Answer |
|---|---|
| Can `sounddevice` ever open a device on the path we would use? | **No — structurally impossible**, and it is not one design choice but three independent facts (§2). |
| Does the vendored streaming DSP work? | **No. It has never run.** Four independent defects; the decisive one makes it emit **one sample of audio per block** and silence for the rest (§3). |
| What is the per-block cost? | **`compute_ms ≈ 26.2 + 0.0210 × window_ms`** (R² 0.969, n=9, M5 Max). ~26 ms of *fixed* cost per block dominates (§4). |
| Minimum credible round trip? | **~121 ms** aggressive, ~185 ms safe, ~588 ms at vendored defaults (§4.3). |
| Is that usable for monitoring while singing? | **No — and not at any configuration, nor under an optimistic native rewrite.** The structural floor is ~35 ms even with zero inference cost, which is physically unreachable (§4.4). |
| …and independently of latency? | **There is no input→output monitor path in DAW Pro at all** — deliberately (`InputCapture.swift:5-8`). Live monitoring needs that *and* sub-15 ms conversion; neither exists (§6.5). |
| Recommended integration shape | **(b′)** — our own streaming facade, *outside* `scripts/rvc/`, driving the **proven offline pipeline** with only the vendored SOLA math reused. Not `/ws-audio`, not the vendored realtime pipeline, not the Swift MLX port (§5). |
| Blocking decision | **One fence question, shared with m23-di-2b — and it is narrower than previously stated: shipped code already imports and executes vendored code** (§7). |
| Sizing | The item's **L/XL is wrong in both directions**: the scaffolding is cheaper than L, the *capability* is unreachable at any size (§8). |

**The single most important finding:** m23-fc's premise correction says "the DSP already exists".
The algorithm is *written*. It **does not work**, and it has demonstrably never been executed
against real weights. That does not make the item bigger — it makes the *right* implementation
avoid that code entirely, because a working, 99.98 %-parity pipeline already ships in the same tree
and is what our facade uses today.

---

## 1. What I read, and where the brief is wrong

Everything below cites `file:line` I opened. Where a coordinate in the briefing did not match, I say so.

### 1.1 Coordinates that verified

| Claim | Verified at |
|---|---|
| `realtime/` exists with `core.py` / `pipeline.py` / `audio.py` / `callbacks.py` / `client.py` | `/Users/dsemenov/Views/daw-pro/scripts/rvc/runtime/src/rvc_mlx/realtime/` — 11 692 + 15 427 + 11 692 + 3 617 + 3 059 B, plus `utils/{buffer,vad}.py` |
| `client.py` is a separate FastAPI app exposing `/ws-audio` | `client.py:11` (`app = FastAPI()`), `client.py:15` (`@app.websocket("/ws-audio")`) |
| It reads a JSON param frame; `block_frame = chunk_size * 128` | `client.py:23-27` |
| `audio.py` owns devices | `audio.py:6` `import sounddevice as sd`; `:220-229` `sd.Stream(... device=(input_device_id, output_device_id) ...)`; `:233-241` a second `sd.OutputStream` monitor |
| Our facade has no streaming surface; `POST /v1/voice/convert` is a sync `def`, path-in/path-out | `scripts/rvc/server.py:258-259` (`def voice_convert`), `:304` (`input_path.is_file()`), `:326` (`.wav` out) |
| Engine is the pinned Acelogic repo | `scripts/rvc/server.py:217` reports `"engine": "Acelogic/Retrieval-based-Voice-Conversion-MLX"` |

### 1.2 Corrections to the brief

1. **"A streaming contract already exists; it is simply not wired into our facade" undersells the
   problem in one direction and oversells it in another.** A contract exists; a *working server*
   does not. Nothing in the tree launches `client.py` — a corpus-wide grep for `read_chunk_size`,
   `cross_fade_overlap_size` and `extra_convert_size` outside `realtime/` itself returns **zero
   hits**. There is no CLI, no GUI, no launcher, no test. `callbacks.py` (the only importer of
   `audio.py`) is likewise never called from anywhere.

2. **The `/ws-audio` contract is not usable as-is.** It requires **24 distinct JSON keys**, every
   one accessed with `params["…"]` and therefore a `KeyError` on omission (`client.py:26`, `:37-52`,
   `:69-77`). It caches `vc_instance` in a module global (`:34`) so every parameter freezes on the
   first connection, and it `del`etes that instance on *any* disconnect (`:85-87`), so a dropped
   socket destroys the loaded model. It also sends a JSON text frame *plus* a binary frame per block
   (`:80-81`), doubling frame count on the hot path.
   *(Method note: my first count returned 23 because the pattern `params\["[a-z_]*"\]` cannot match
   `f0_method` — a digit in a key name. The dumb-pattern law applies: `[a-z0-9_]` returns 24.)*

3. **The disqualifying constraint is already satisfied, structurally, and not by any design choice
   of mine.** See §2 — this is a stronger answer than the brief anticipated.

4. **The premise "the DSP already exists" is false in the way that matters.** See §3.

---

## 2. The `sounddevice` fence — three independent structural facts, plus an executed proof

The brief asks the design to "show explicitly how `sounddevice` is prevented from ever opening a
stream." It is not prevented by a design decision. It is prevented three times over by facts:

**Fact 1 — `sounddevice` is not installed and is not a declared dependency.**
`scripts/rvc/runtime/src/pyproject.toml` lists 30 dependencies; `sounddevice` is not among them.
The venv at `scripts/rvc/runtime/src/.venv/lib/python3.11/site-packages` contains **226 entries**;
`sounddevice` is absent. *Positive control* (the empty-grep law): the same listing does return
`faiss`, `fastapi`, `librosa`, `mlx`, `numpy`, `pedalboard`, `scipy`, `torch`, `uvicorn`,
`webrtcvad`. It also returns `soundfile` / `_soundfile_data` — **libsndfile, a file-I/O library, not
PortAudio.** Anything matching `sound` in that listing is `soundfile`, and confusing the two is the
obvious way to get this wrong.

**Fact 2 — nothing on the code path imports it.** `sounddevice` appears in exactly **two files in
the entire tree**, both named `realtime/audio.py` (`rvc/realtime/audio.py:6` and
`rvc_mlx/realtime/audio.py:6`). The only importer of `audio.py` is `callbacks.py:8`, and nothing
imports `callbacks.py`. `client.py:9` imports only `.core`; `core.py:26-28` imports only
`realtime.utils.buffer`, `realtime.utils.vad` and `realtime.pipeline`.

**Fact 3 — `rvc_mlx/realtime/` has no `__init__.py`**, so it is a PEP 420 namespace package.
`from rvc_mlx.realtime.core import VoiceChanger` therefore executes `core.py` and nothing else; there
is no package `__init__` that could drag `audio` in as a side effect. (`find rvc_mlx -name
'__init__.py'` returns four files: `preprocess`, `train`, `lib/mlx`, `monitoring`. Neither `realtime`
nor `realtime/utils` is among them.)

**Executed proof.** Every bench run in §4 asserts, after constructing a live `VoiceChanger` and
running 46 conversion blocks, that neither `sounddevice` nor `rvc_mlx.realtime.audio` is present in
`sys.modules`. All runs printed `FENCE-OK`. This converts a static-analysis argument into an
executed one, which is worth more than the timings.

**Design rule to carry forward regardless:** any streaming driver we write imports
`rvc_mlx.realtime.core` (or, per §5, not even that) and **never** `rvc_mlx.realtime.audio` or
`rvc_mlx.realtime.callbacks`. That rule is enforceable by a two-line assertion at sidecar startup
plus a gate that greps our own source for those two module names. It is cheap; ship it anyway as a
regression guard, because Fact 1 would evaporate the day someone runs `uv sync` against an upstream
that adds `sounddevice`.

---

## 3. The vendored realtime path has never run — four defects, measured

I attempted to construct a `VoiceChanger` against our own base model
(`rvc_mlx/models/checkpoints/base_f0G40k.npz`, 72 941 234 B, present). It **fails on construction**:

```
File ".../rvc_mlx/realtime/pipeline.py", line 142, in setup_network
    self.net_g.load_weights(list(self.cpt["weight"].items()), strict=False)
IndexError: list index out of range
```

Working through it surfaced four independent defects, each of which alone would prevent the path
from producing correct audio.

### Defect 1 — the hardcoded synthesizer config is internally inconsistent (hard failure)

`realtime/pipeline.py:89-93` builds the fallback config when no `config.json` sits beside the
weights (there is none, and one cannot be added — that directory is inside the fence):

* `upsample_rates = [10, 8, 2, 2]` — the **working offline loader** uses `[10, 10, 2, 2]`
  (`rvc_mlx/infer/infer_mlx.py:169`, whose own comment says `# Correct for 40k`; note that
  `infer_mlx.py:144` first sets `[10, 8, 2, 2]` and then *overwrites* it at `:169`, so the realtime
  file appears to have copied the abandoned first value).
* `upsample_kernel_sizes = [3, 7, 11]` — that is a **resblock** kernel list pasted into the
  upsample-kernel slot. It has **three** entries for **four** upsample rates. The offline loader uses
  `[16, 16, 4, 4]` (`infer_mlx.py:165`). This is the direct cause of the `IndexError`.
* `p_dropout = 0.1` at inference, versus `0` offline (`infer_mlx.py:140`).

### Defect 2 — the weight-key remapper is skipped (silent corruption)

The offline path calls `weights = remap_keys(weights)` before `load_weights`
(`infer_mlx.py:246`, function at `infer_mlx.py:17-70`), translating PyTorch-shaped keys
(`dec.resblocks.N.convs1.M`) into the MLX module names (`dec.resblock_N.c1_M`). `realtime/pipeline.py:142`
loads the **raw** keys, with `strict=False`.

Measured, against a `Synthesizer` built with the *correct* config (so the count is not confounded by
Defect 1):

```
npz tensors                        423
Synthesizer parameters            1221
raw keys matching the model        363
remapped keys matching the model   387
```

**Read the baseline first, or the ratio misleads.** 387/1221 is the **healthy** number: it is what
the *shipped* offline path fills, because I built the `Synthesizer` with that path's exact config and
ran its own `remap_keys` (`infer_mlx.py:246`). The remainder is legitimately absent from an inference
checkpoint (buffers, the posterior encoder, training-only modules) — **this is not a finding about
`vc.convertVocals`, which is healthy.** The finding is the *difference*: the realtime path fills
**363**, so **24 parameters that the shipped path populates are left randomly initialised**, and
`strict=False` means that happens **silently**. A silent 24-tensor hole in the decoder is worse than
the `IndexError`.

### Defect 3 — the content encoder is configured with the wrong projection size

`realtime/pipeline.py:427` calls `load_embedding()`, which builds
`HubertConfig(..., classifier_proj_size=256)` (`rvc_mlx/lib/mlx/utils.py:57`, whose own comment is a
question to itself: *"ContentVec: 256. Hubert Base: 768 usually?"*). The working offline path uses
`HubertConfig(classifier_proj_size=768)` (`infer_mlx.py:256`). Different final projection, different
features.

### Defect 4 — the output tensor is indexed on the wrong axis (the decisive one)

`rvc_mlx/lib/mlx/synthesizers.py:229-232` returns the decoder output and states its layout in a
comment: `# Output: o (B, T, 1) from generator` … `# o is already in (B, T, 1) format`. The working
offline consumer reads it correctly at `rvc_mlx/infer/pipeline_mlx.py:262`:

```python
# out_audio (1, T, 1) -> (T,)
return np.array(out_audio[0, :, 0])
```

The realtime consumer at `rvc_mlx/realtime/pipeline.py:155-159` believes the opposite —
`# output: (B, 1, L_audio) -> (B, L_audio) (since C=1 usually)` — and does:

```python
out = output[0, 0]
```

On a `(1, T, 1)` tensor that selects time-step 0 and yields a **1-element array**.

**Measured, with Defects 1–3 patched around so the model is architecturally correct** (rcs=192,
extra=0.5, six consecutive blocks, `silent_threshold=-90`):

```
i=0 in_rms=0.1501 vol=0.137271 silent_branch=false model_out_len=1 out_len=24576 out_max=0.0
i=1 in_rms=0.1503 vol=0.150247 silent_branch=false model_out_len=1 out_len=24576 out_max=0.0
… (identical through i=5)
```

The full neural pipeline ran (`silent_branch=false`; RMVPE, HuBERT, TextEncoder, Flow and
HiFiGAN-NSF all executed), produced `model_out_len=1`, and the SOLA stage then zero-padded that one
sample to block length and multiplied index 0 by `fade_in_window[0] = sin(0)² = 0`. **Output is
exactly 0.0 on every block.** Changing `output[0, 0]` to `output[0, :, 0]` — one line — makes it
`40/40` non-silent in every configuration (§4).

### Defects that are latent rather than fatal

* **`silence_front` is permanently dead.** `core.py:58` initialises `self.silence_front = 0`;
  `core.py:176-178` then reads `… if self.silence_front else 0`, which is always false. The
  silence-front optimisation can never engage, so RMVPE always runs on the full window. This is a
  real, permanent cost, and it is included in the §4 numbers.
* **Output is scaled by input RMS.** `core.py:289`: `audio_model_np = audio_model_np * vol`, where
  `vol` is the RMS of the input buffer (`core.py:212-213`). Output level therefore tracks input level
  *in addition to* whatever level the model produced — a level-dependent gain, i.e. an uncontrolled
  expander, and roughly −16 dB at a typical sung `vol ≈ 0.15`. The author's own comment (`"simple
  gain adjust if needed, or rely on pipeline volume"`) reads as unresolved.
* **The convert buffer is not advanced on silent blocks.** `core.py:266`
  (`circular_write(audio_input_16k, self.convert_buffer)`) is reached only on the non-silent path;
  both the VAD branch (`:221-241`) and the threshold branch (`:244-264`) return before it. So during
  silence the 16 kHz history is frozen, and the first block after silence splices stale audio to
  fresh audio inside the model's context window. That is an artifact generator at exactly the moment
  a singer re-enters.
* **Dead resample branch.** `pipeline.py:376-378`: `scaled_window = int(np.floor(1.0 *
  self.model_window))` is always equal to `self.model_window`, so the `if` never fires.
* **The default `silent_threshold` is a trap.** `core.py:42` defaults it to `0`, giving
  `input_sensitivity = 10**(0/20) = 1.0` (`core.py:59`), so **every** block with RMS < 1.0 — i.e.
  every real block — takes the silence branch and returns zeros *after* paying the full inference
  cost. `callbacks.py:24` defaults to `-90`. Anyone benchmarking this without noticing will time a
  path that produces nothing and see plausible numbers.

**Conclusion of §3.** This is not "demo-grade code that needs polish." It is code that has never
been executed against real weights: it cannot load our model, it would silently load 24 tensors short
if it could, it configures the content encoder differently from the working path, and it indexes the
output on the wrong axis. **Any plan that depends on `rvc_mlx.realtime.pipeline` inherits a patch
layer against a pinned upstream commit.** §5 avoids it.

---

## 4. Latency budget, quantified

### 4.1 Where the latency comes from — and where it does not

Read `core.py:146-190` (`realloc`) and `utils/buffer.py` together. `circular_write` appends new data
at the **end** of the target (`target[:-offset] = target[offset:]; target[-offset:] = new_data`), so
the convert buffer's newest sample is its last. `skip_head = extra_frame_16k // window_size`
(`core.py:174`) discards the *leading* `extra_convert_size` of model output, and
`return_length = convert_feature_size_16k - skip_head` (`core.py:175`) returns the tail.

**Therefore `extra_convert_size` is look-BACK context, not look-ahead. It costs compute, not
latency.** Likewise the SOLA crossfade takes its next-block seed from *beyond* the returned block
(`core.py:454`), so it adds no latency either. The algorithmic latency of the conversion itself is
exactly **one block**.

That is the good news, and it is the only good news: it means the latency is set by `block_frame`
alone, and `block_frame` is bounded from below by *compute*, which is what §4.2 measures.

Geometry, verified by reading the constructed objects rather than by arithmetic
(`core.py:321-324`, `:153-190`):

| | formula | at rcs=192, extra=0.5 |
|---|---|---|
| `block_frame` | `read_chunk_size × 128` @ 48 kHz | 24 576 = **512.0 ms** |
| `crossfade_frame` | `cross_fade_overlap_size × 48000` | 4 800 = 100 ms |
| `extra_frame` | `extra_convert_size × 48000` | 24 000 = 500 ms |
| `sola_search_frame` | `48000 // 100` | 480 = 10 ms |
| `convert_size_16k` | sum of the above at 16 kHz, rounded up to `window_size=160` | 18 080 = **1130.0 ms of audio processed per block** |

### 4.2 Measured per-block compute

**Method.** `rvc_mlx.realtime.core.VoiceChanger` driven directly with synthetic, rights-clear audio
(a 220 Hz glottal-pulse harmonic stack with 5.5 Hz vibrato and formant-ish amplitude colouring — no
recording of any person, no ACE sidecar, no audio device). `silent_threshold=-90` so the real path
runs; `vad_enabled=False`; `OMP_NUM_THREADS=1` (the faiss segfault guard `scripts/rvc/server.py:59`
calls mandatory); `cwd` = the vendored `src` root, as `server.py:77` does. Defects 1–4 patched around
in the harness *only* — nothing written under `scripts/rvc/`. Fresh `VoiceChanger` per configuration
(never reused, so no configuration inherits another's cached model). 6 warm-up blocks discarded,
40 measured. Machine: M5 Max, otherwise idle. All nine configurations returned **40/40 non-silent**.

| rcs | extra | block | window | p50 | p95 | max | cold (1st) | **load factor p50** | p95 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 192 | 0.50 | 512.0 ms | 1130 ms | 49.6 | 50.4 | 51.8 | 388.5 | **0.097** | 0.098 |
| 192 | 0.25 | 512.0 ms | 880 ms | 44.1 | 44.7 | 45.5 | 135.4 | **0.086** | 0.087 |
| 192 | 0.10 | 512.0 ms | 730 ms | 41.7 | 42.1 | 42.3 | 111.1 | **0.081** | 0.082 |
| 64 | 0.50 | 170.7 ms | 790 ms | 42.5 | 43.3 | 43.9 | 111.2 | **0.249** | 0.254 |
| 64 | 0.25 | 170.7 ms | 540 ms | 37.2 | 37.6 | 38.5 | 104.1 | **0.218** | 0.220 |
| 64 | 0.10 | 170.7 ms | 390 ms | 35.3 | 35.8 | 36.0 | 100.3 | **0.207** | 0.210 |
| 24 | 0.50 | 64.0 ms | 680 ms | 41.3 | 41.9 | 46.5 | 115.9 | **0.645** | 0.655 |
| 24 | 0.25 | 64.0 ms | 430 ms | 36.5 | 38.5 | 41.2 | 101.8 | **0.571** | 0.602 |
| 24 | 0.10 | 64.0 ms | 280 ms | 30.0 | 31.3 | 31.8 | 100.7 | **0.469** | 0.489 |

All times in ms. *Load factor* = compute ÷ block duration; ≥ 1.0 means the sidecar cannot keep up.

**The cost model.** Least-squares over all nine points (window → p50):

> **`compute_ms = 26.15 + 0.02099 × window_ms`**, R² = **0.9691**, marginal RTF **47.6×**

Two things follow, and they are the heart of the answer:

1. **~26 ms is fixed per block, independent of how much audio is in the window.** At the smallest
   configuration it is 87 % of the total cost. Shrinking the block does not shrink it — it multiplies
   how often you pay it. This is the wall.
2. The *marginal* rate, 47.6× real time, is consistent with the M10 spike's offline measurement on
   this machine (full MLX pipeline warm RTF 38.0×, `docs/research/spike-m10p-vc.md:37`). The
   pipeline is not slow. The **framing overhead** is.

**Break-even, solved from the model** with `window_ms ≈ block_ms + 210` (extra = 0.1):

| target | minimum block | equivalent `read_chunk_size` |
|---|---|---|
| load factor 1.0 (no headroom at all) | **31.2 ms** | 11.7 |
| load factor 0.5 (a sane insert budget) | **63.8 ms** | 23.9 |

The measured `rcs=24 / extra=0.1` point lands at 0.469 — the arithmetic and the measurement agree.
**64 ms is the smallest block this stack can sustain with any margin.**

**Two ways these numbers are optimistic, stated plainly:**
* `voiceId "base"` has **no faiss index**, so `index_rate = 0.0` (`scripts/rvc/server.py:262-263`)
  and the retrieval search at `realtime/pipeline.py:305-321` is skipped entirely. A real trained
  voice runs `index.search(query, k=8)` plus a `big_npy[ix]` gather every block. **These are lower
  bounds on real-voice cost.**
* `protect = 0.5` skips the pitch-protection branch (`pipeline.py:345-351`); the common `protect =
  0.33` adds a second feature interpolation.
* Measured on an otherwise idle machine. A DAW rendering a real session competes for the same GPU.

### 4.3 Round-trip latency a user would actually see

At the best sustainable configuration (`rcs=24`, `extra=0.1` — 64 ms block, load factor 0.47):

| stage | ms | source |
|---|---:|---|
| Accumulate one block before anything can be sent | 64.0 | `core.py:321`, inherent |
| Sidecar compute (p95) | 31.3 | §4.2 measured |
| IPC: 12 KB each way over loopback + Python asyncio wake | 2–10 | estimated, **not measured** |
| Our graph handoff: ≥ 1 quantum in, ≥ 1 quantum out (at a typical 512-frame device quantum) | ~21.3 | §6 design — **scales with the device buffer**, see note |
| **Aggressive total (no jitter buffer)** | **≈ 121** | |
| + one block of jitter absorption (recommended for a Python process) | +64 | |
| **Safe total** | **≈ 185** | |
| **At the vendored defaults (rcs=192, extra=0.5)** | **≈ 588** | 512 + 50 + 5 + 21 |

On top of all of it sits the audio interface's own round trip (typically 6–12 ms at 256 frames),
which the DAW does not control.

*Note on the graph-hop term:* it is the one estimated line in the table and it scales with the
device's render quantum, which is device- and user-configurable, not a constant we set. 512 frames
@ 48 kHz (10.67 ms each way) is a typical macOS default. Our preallocation **ceiling** is
`EffectChainProcessor.maxFramesPerQuantum = 8_192`
(`/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Effects/EffectChainProcessor.swift:500`), which
bounds the buffers but is not the quantum. A user on a 1024-frame buffer adds ~21 ms to every total
below; the verdict is insensitive to this term, since removing it entirely still leaves ~100 ms.

### 4.4 Is that usable for monitoring while singing? **No.**

Comfortable vocal monitoring is ~10–15 ms; degradation is audible past ~20–25 ms; beyond ~30 ms
singers demonstrably alter their timing and pitch. **121 ms is roughly ten times over**, and 185 ms
is the honest number for a design that does not drop out.

The important part is that this is **not a tuning problem**, and I want to close the door on the
obvious rebuttals:

* *"Use a smaller block."* Below 64 ms the load factor exceeds 0.5 and crosses 1.0 at 31 ms. There
  is no configuration space left.
* *"Drop `extra_convert_size` to zero."* It contributes only ~4 ms of the 30 ms at the smallest
  setting, and removing the model's history context is precisely what makes RVC output discontinuous
  block to block. It buys nothing and costs the quality.
* *"Rewrite it natively in Swift MLX."* Take the physically-unreachable limit: fixed cost → **0**.
  Then `compute = 0.021 × window`, `window ≥ 210 ms`, and the break-even block falls to ~9 ms, giving
  9 + 4.6 + 0 (in-process) + 21 (graph hop) ≈ **35 ms**. That is *still* 2–3× the comfortable
  threshold, and it assumes zero GPU kernel-launch cost for a graph containing RMVPE, a 12-layer
  HuBERT, a 6-layer transformer text encoder, a normalising flow and a HiFiGAN-NSF vocoder — which is
  not approachable. A realistic heroic rewrite lands at 50–70 ms: better, still not live monitoring.

**This is the spike's central finding and it is a legitimate answer.** Live monitoring while singing
is not achievable with RVC-class conversion on this hardware, by this stack, at any configuration —
and the reason is structural (a per-block inference floor plus mandatory block buffering), not an
artifact of the vendored code's poor state.

### 4.5 What *is* achievable, and what it is worth

| capability | achievable? | value over what ships today |
|---|---|---|
| Sing and hear your converted voice live | **No** — twice over: §4.4 (latency floor) *and* §6.5 (no input→output monitor path exists) | — |
| Play back a recorded dry vocal through a VC insert and hear it in context | Yes, but see §6.4 | Real — audition/A-B without a render round trip. **But it imposes a project-wide PDC penalty (§6.4) and I recommend against it.** |
| Convert a take with progressive preview as it records | Yes | **Marginal.** `POST /v1/voice/convert` already runs at RTF 38×: a 3-minute take converts in ~4.7 s today. Streaming would make it ~0.5 s after stop. |
| Convert a whole track / clip offline | **Already shipped** — `vc.convertVocals` (m10-p-4) | — |

The uncomfortable conclusion: **the achievable subset of m23-fc is largely already delivered by the
existing synchronous endpoint**, and the one part that is not — live monitoring — is the part that
cannot be built.

---

## 5. Integration shape — the comparison and the recommendation

### Option (a) — drive the vendored `/ws-audio` app. **Loses.**
Launching `uvicorn rvc_mlx.realtime.client:app` means a **second process out of the fenced tree**, on
a second port, with no launcher, no pidfile, no `/health`, and no `SidecarManager` lifecycle — every
piece of which `scripts/rvc/run.sh` and `SidecarManager.swift` already provide for the facade we own.
The contract itself is hostile (§1.2 #2: 24 mandatory keys, module-global instance, params frozen at
first connect, model destroyed on any disconnect, two frames per block). And it drives the **same
broken `core.VoiceChanger`** (§3), so it inherits every defect while giving us no place to fix them.
Its one merit — "it already exists" — is exactly the merit §3 disproves.

### Option (b) — import `core.VoiceChanger` in a sidecar we control. **Close, but superseded.**
We own the process, the port, the lifecycle, the error envelope, and the parameter surface. But we
would still be driving `rvc_mlx.realtime.pipeline`, which means shipping a monkeypatch layer for
Defects 1–4 against a pinned upstream commit. That is a standing liability with no upside, because —

### **Option (b′) — RECOMMENDED — our own streaming driver over the *proven* pipeline.**
Reuse from the vendored tree only what is correct and load-bearing:

* the **SOLA / overlap-add block machinery**, `core.py:350-456` (`generate_strength`,
  `process_audio`) — ~55 lines, and the genuinely valuable part of the find. ⚠️ **It *reads* as
  correct; its continuity is UNVERIFIED and that is deliberate scope.** I found four defects in the
  200 lines around it, so vouching for it on a read alone would be unearned — the block-boundary
  continuity check in §9's test table is the first task of Phase 1, and the **M** sizing assumes it
  passes;
* the **buffer geometry**, `core.py:146-190` (`realloc`) — the block/extra/crossfade/sola arithmetic;
* the **model stack our facade already imports and proves in production**: `rvc_mlx.infer.infer_mlx`
  (`RVC_MLX`, `remap_keys`), `rvc_mlx.infer.pipeline_mlx` (`PipelineMLX`, `Autotune`,
  `AudioProcessor`), `rvc_mlx.lib.mlx.synthesizers.Synthesizer`,
  `rvc_mlx.lib.mlx.rmvpe.RMVPE0Predictor`, `rvc_mlx.lib.mlx.utils.load_embedding`.

**Why it wins on each axis:**

| axis | (a) | (b) | **(b′)** | (c) |
|---|---|---|---|---|
| Latency | identical — all share the §4 floor | identical | identical | ~15 % better at best (§4.4) |
| Failure isolation | worst: second unmanaged process, model dies on disconnect | good: our lifecycle | **good: our lifecycle, our health, our envelope** | best (in-process) — but that means a model crash takes the DAW down |
| RT-safety | irrelevant to all — none can be on the render thread (§6) | " | " | **worse**: in-process GPU work inside the app raises the risk of it drifting onto an audio thread |
| Vendored coupling | couples to `realtime/*` **and** its 4 defects **and** a 24-key wire format | couples to `realtime/*` + 4 defects | **couples only to modules `scripts/rvc/server.py:102` already imports** | couples to a different, lower-parity implementation |
| Correctness today | broken | broken | **proven — this is the path that ships** | 91.8 % vs Python MLX's 99.98 % |

### Option (c) — the native Swift MLX port. **Loses now; keep the revisit trigger.**
A real find, and worth recording: `scripts/rvc/runtime/src/Demos/iOS/RVCNative/RVCNativePackage`
(17 Swift sources incl. `Synthesizer.swift`, `RMVPE.swift`, `HubertModel.swift`, `RVCInference.swift`,
`FAISSIndexReader.swift`, `PthConverter.swift`) with a macOS 14 executable wrapper at
`Demos/Mac/Package.swift`. It loses on three counts:

1. **It is offline-only.** There is no `realtime/` equivalent, no `VoiceChanger`, no SOLA — only
   `RVCInference` with `AudioPlayer` / `AudioRecorder`. Choosing it means *porting* the streaming
   machinery that (b′) reuses, inverting the premise correction that makes this item cheap.
2. **It is a quality regression.** The vendored `src/CLAUDE.md` reports Swift MLX at **91.8 %**
   average correlation against Python MLX (per-model 86.6–94.4 %), where Python MLX is 99.98 %
   against PyTorch. Our facade ships the 99.98 % path.
3. **It buys nothing on RT-safety.** GPU inference cannot be on the render thread either way, so the
   handoff of §6 is required regardless; all we would gain is deleting the IPC hop (2–10 ms of a
   121 ms budget) at the cost of pulling `mlx-swift` into the app and putting a model crash inside
   our address space.

**Revisit trigger:** if MLX-Swift parity reaches ≳ 99 % *and* we independently decide to eliminate
the Python sidecar (e.g. for bundling/notarisation), re-open this. Do not re-open it for latency.

### Option (d) — add a `/v1/voice/stream` route to our own facade. **Architecturally correct, currently forbidden.**
This is what one would obviously do: one sidecar, one port, one lifecycle, one contract, a WebSocket
route beside the existing REST routes in `scripts/rvc/server.py`. **m23-di-2b records that editing
`scripts/rvc/server.py` is FORBIDDEN** ("(i) add a `POST /v1/voice/{id}/prepare` route to the
sidecar — the clean design, and **FORBIDDEN**, because it edits `scripts/rvc/server.py`"). That rule
blocks (d) exactly as it blocks di-2b's option (i). See §7 — with the fence held as literally written,
**m23-fc cannot start in any shape**, and that is the plainest form of the question for the user.

**Resolution offered in §7:** put the streaming facade in a directory *we* own
(`scripts/rvc-stream/`), importing from the vendored tree and running under the vendored venv. That
writes nothing under `scripts/rvc/` while still delivering (d)'s clean shape.

---

## 6. RT-safety — the handoff design

A Python process cannot be on the render thread; neither can MLX/GPU work; neither can a socket.
The design below is the one I would sign off, and it is deliberately modelled on two shapes we
already ship rather than inventing a third.

### 6.1 Seam and precedents
The insert conforms to `EffectRendering`
(`/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Effects/EffectRendering.swift`) — `prepare` on the
main actor, `process` / `reset` on the render thread, `latencySamples` as the PDC hook. Proposed file:
`/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Effects/VoiceConversionInsert.swift`.

Ring precedents to copy verbatim in structure, not to re-derive:
* `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/MIDIInput/LiveEventRing.swift` — SPSC discipline,
  free-running `daw_atomic_u32` head/tail so full never aliases empty, release-store on the producer,
  acquire-load on the consumer, **drop-newest** overflow with a `droppedFlag` the *owner* interprets.
* `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Analysis/InsertSpectrumTap.swift` — a bounded
  sample ring whose render-side producer is "at most four `memcpy`s plus one release-store", with all
  analysis moved to the consumer. That is exactly the discipline this insert needs.

### 6.2 Thread boundaries

```
render thread            SPSC ring A          worker thread (QoS .userInitiated, non-RT)
──────────────           ───────────          ─────────────────────────────────────────
process(buffers:)  ──►  input ring   ──►      drain blockFrames · WebSocket send
  · mono-sum + memcpy in                       · await converted block (may block/allocate freely)
  · memcpy out, or DRY  ◄── output ring ◄──   · write converted block
  · bump counters (atomic)
```

* **Everything is allocated in `prepare`**: both rings (power-of-two capacity ≥ 4 × `blockFrames`),
  the mono downmix scratch, the block-assembly buffer. `process` allocates nothing, takes no lock,
  makes no ObjC/Swift-runtime dynamic dispatch (the class is `final`; the atomics are C inlines),
  and performs no libm beyond the mono sum.
* **The worker is a plain `Thread`, not a Swift concurrency executor.** A `Task` would hop
  executors under contention and its wake latency is not bounded; this thread must wake promptly
  every 64 ms and nothing else.
* **The worker never touches the render thread's state** except through the two rings and a small
  set of atomics.

### 6.3 Failure modes and the exact behaviour

| condition | render-thread behaviour | signal |
|---|---|---|
| Output ring empty (sidecar behind, GC pause, cold first blocks) | **DRY passthrough for that quantum**, sample-accurate, no allocation | atomic `underrunCount++` |
| Input ring full (worker stalled) | drop-newest, do not block | atomic `overflowCount++` |
| Sidecar stalls > N blocks | worker sets `healthy = 0` (release) | render thread acquire-loads it once per quantum and passthroughs; UI shows the insert as degraded |
| Sidecar process dies | socket error on the worker → `healthy = 0`, worker retries with backoff | render thread never sees a socket, never allocates, never blocks |
| Worker falls permanently behind | worker **skips whole stale blocks** at the block level to re-sync to wall-clock, rather than accumulating unbounded delay | logged; `skippedBlocks` counter |
| Transport stop / `reset()` | render thread clears its read cursor; the worker drains and discards | — |

**Why dry passthrough and not silence:** in a monitoring path silence is a worse failure than the
unprocessed signal, and the user can hear immediately that conversion dropped out. **Why not
time-stretch to cover:** you cannot stretch time against a fixed reported latency without breaking
PDC's alignment. Legible failure beats clever failure.

**Startup:** `latencySamples` is fixed at `prepare` and the output ring is pre-filled with exactly
that many silent frames, so timing is correct from sample 0 and the reported latency never moves.

### 6.4 The PDC consequence — and why it argues against shipping VC as an insert at all

`/Users/dsemenov/Views/daw-pro/Sources/DAWCore/LatencyCompensation.swift` states the alignment rule:
`T = max over track strips of chainLatencyAll`, `B = max over bus strips`, `maxPathLatency = T + B`.
And it states that **`chainLatencyAll` sums ALL effects in the chain including bypassed ones** —
deliberately, so that toggling bypass never moves the plan.
`EffectChainProcessor.latencySamplesAllEffects` (`Sources/DAWEngine/Effects/EffectChainProcessor.swift:633`)
implements it over all descriptors regardless of bypass.

Two consequences follow, and the second is severe:

1. **Block size must be pinned at `prepare` and can only change through a graph reconfiguration**,
   never as a parameter edit — otherwise the reported latency moves under the planner.
2. **A 121 ms VC insert on one vocal track delays *playback of every track* in the project by
   121 ms — and bypassing it does not help.** Because `chainLatencyAll` is bypass-stable by design,
   the only way to recover the 121 ms is to *remove* the insert. A user who adds VC to audition it
   and then bypasses it still pays the full 121 ms of playback latency, with no visible cause.
   *(Scoped deliberately to playback: see §6.5 — there is no input-monitoring path for it to
   affect.)*

This is not a bug in PDC; bypass-stability is the correct choice and I would not change it. It is
evidence that **a high-latency neural converter is the wrong shape for a chain insert.** The right
shape for this capability in a DAW is what we already ship: an offline/render-in-place operation on a
clip or take (`vc.convertVocals`, m10-p-4), optionally with freeze semantics.

### 6.5 There is no input→output monitor path to convert into — by deliberate design

This closes the item independently of every latency number above, and I nearly asserted the opposite
without checking.

`/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/InputCapture.swift:5-8` is explicit:

> *"Owns a SEPARATE input-only AVAudioEngine whose inputNode tap feeds a `RecordingWriter`. **Never
> touches this engine's outputNode or mainMixerNode — pulling those in would wire an input→output
> monitor path.** Capture runs at the device-native format (nil tap format); the playback engine and
> its clock are entirely independent."*

Live input monitoring **does not exist in DAW Pro**, and its absence is a stated design decision, not
an oversight. Confirming it: the only consumer of PDC's per-strip `compensationSamples` in the engine
is `PlaybackGraph.swift:1401`; `InputCapture.swift` never reads it, because there is no path for it
to compensate.

**Consequence for m23-fc.** "Sing and hear your converted voice" needs **two** things we do not have:

1. an input→output monitor path through the playback graph — deliberately absent, and building one is
   its own engine item with its own latency and feedback-management design; and
2. conversion inside ~15 ms — unreachable by §4.4.

Even if (2) were solved tomorrow, (1) would still be unbuilt. **This is the cleanest reason the item
cannot proceed as written**, and unlike the latency argument it needs no measurement to check — just
the eight lines above.

---

## 7. The fence question — for the user, stated once

**Do not decide this without the user.** Both m23-fc and **m23-di-2b** are blocked on the same wall,
and they should be surfaced as **one decision, not two**. What follows is the question sharpened by
what this spike measured — and it is **narrower than previously framed**.

### 7.1 The framing correction that matters

The brief says both candidate designs "reach inside" `scripts/rvc/` and asks whether that is allowed.
**But shipped, user-sanctioned code already reaches inside, today, on every conversion:**

* `scripts/rvc/server.py:102` — `from rvc_mlx.infer.infer_mlx import RVC_MLX` — our facade **imports
  vendored library code**.
* `scripts/rvc/server.py:77-78` — `os.chdir(SRC_DIR)`, `sys.path.insert(0, str(SRC_DIR))` — it makes
  the vendored tree its import root.
* `scripts/rvc/run.sh` — execs `$SRC_DIR/.venv/bin/python`, i.e. **runs the vendored venv's
  interpreter**, having `cd`'d into the vendored tree.

So **importing and executing vendored code is already the shipped norm.** What the fence has never
permitted is **editing** files under `scripts/rvc/` — and that is exactly what m23-di-2b's option (i)
records as forbidden. Read that way, the question is much smaller than "may we reach inside".

### 7.2 The question to put to the user

> `scripts/rvc/` is fenced. Our facade already imports vendored modules and runs the vendored venv
> (`server.py:102`, `run.sh`), so *reading, importing and executing* vendored code is already
> established practice. Two roadmap items now need one more thing each:
>
> * **m23-di-2b** needs to **run** a vendored CLI as a subprocess:
>   `scripts/rvc/runtime/src/tools/convert_pth_to_mlx.py` (`.pth` → `.npz`).
> * **m23-fc** needs to **import** vendored model modules from a streaming driver, and needs somewhere
>   to *put* that driver. The clean place is a new route in `scripts/rvc/server.py` — which di-2b
>   already records as forbidden.
>
> **Please pick one reading of the fence:**
>
> * **(A) The fence forbids writes under `scripts/rvc/` only.** Reading, importing and running are
>   fine (as they already are). New code we own lives **outside** the fence — e.g.
>   `scripts/rvc-stream/`. **This unblocks both items with no new precedent** and is my
>   recommendation to offer.
> * **(B) The fence also forbids launching new processes from that tree.** Then m23-di-2b option (ii)
>   is out (leaving "document it as inert"), and m23-fc's option (a) is out — but (b′) survives under
>   reading (A)'s import rules.
> * **(C) The fence forbids any new coupling at all.** Then **m23-fc cannot start in any shape**, and
>   m23-di-2b resolves as "imported `.pth` models stay inert, documented."
>
> Also please confirm: **may we add a new top-level directory `scripts/rvc-stream/` that we own and
> maintain, which imports from the vendored tree but writes nothing into it?** If yes, m23-fc gets
> the architecturally correct shape without touching a fenced file.

**Even under (A), §4.4 stands: live monitoring is still not achievable.** The fence answer determines
whether the *achievable* subset can be built — not whether the headline capability can.

---

## 8. Honest sizing — replacing the stale L/XL

The item's `Weight L/XL pending that spike` must not be quoted. It is wrong in **both** directions:
the streaming scaffolding is cheaper than L implied, and the headline capability is unreachable at
any size. Size the outcomes separately.

| outcome | size | notes |
|---|---|---|
| **Live VC monitoring insert (the item as written)** | **NOT A SIZE — NO** | §4.4. Structural floor ~121 ms; ~35 ms even at the physically unreachable limit. Recommend closing or re-scoping m23-fc. |
| Streaming/chunked conversion with progressive preview, via a facade we own (b′) | **M** (~2–3 focused days) | Gated on §7. Reuses the proven pipeline + ~55 lines of vendored SOLA math. **Delivers little over the shipped `vc.convertVocals` at RTF 38×.** |
| VC as a *playback* insert (audition in context) | **L** | Technically achievable; **recommend against** — §6.4's project-wide bypass-stable PDC penalty. |
| Fixing the vendored realtime path to make option (b) viable | S for the code, **unbounded as a liability** | The axis fix is one line; the other three are small. But it is a permanent patch layer against a pinned upstream. **Don't. Use (b′).** |

**Recommended disposition of m23-fc:** close it with this document as the record, and file a
replacement item scoped to what is real — *"streaming conversion with progressive preview"* — marked
**blocked on the §7 fence decision** and annotated with the finding that its value over the existing
synchronous endpoint is marginal. If the user's actual 2026-08-04 request was "sing through my voice
model live", the honest answer is that this stack cannot do it, and that should be told plainly
rather than approximated with a 185 ms path.

---

## 9. Implementation plan — only if the user opens the fence under reading (A)

Do not begin any phase before §7 is answered.

### Phase 0 — Gate the fence rule (no dependency on the answer)
* Add `scripts/gates/…` check (⚠️ **another agent owns `scripts/gates/` right now — coordinate before
  writing there**) asserting that no file we own references `rvc_mlx.realtime.audio`,
  `rvc.realtime.audio`, `sounddevice`, `sd.InputStream`, `sd.OutputStream`, or `sd.Stream`.
* Positive control mandatory: the gate must fail when a fixture line containing `import sounddevice`
  is introduced. A gate that greps and finds nothing is indistinguishable from a gate that never ran.

### Phase 1 — `scripts/rvc-stream/` (new, ours) — Route: `mcp-integration-engineer`
* `scripts/rvc-stream/server.py` — FastAPI on **127.0.0.1:8003** (loopback hardcoded, never
  configurable — mirror `scripts/rvc/server.py:409`). `GET /health` in the ACE envelope so
  `SidecarManager` parses it unchanged; `WS /v1/voice/stream`.
* Contract, deliberately unlike `/ws-audio`: **one** JSON hello frame with **defaults for every
  field** (only `voiceId` required), then binary float32 blocks; **binary-only** responses on the hot
  path with metrics on a separate, low-rate text channel. Re-negotiable parameters (pitch,
  index_rate, protect) carried per-block in a fixed-size binary header, not by tearing down the model.
* Startup assertion: `assert "sounddevice" not in sys.modules` after model construction, and refuse
  to start if it is present.
* `scripts/rvc-stream/run.sh` — pidfile-owning launcher mirroring `scripts/rvc/run.sh`, incl.
  `OMP_NUM_THREADS=1`.
* **Reuse, do not import, the vendored realtime pipeline:** port `generate_strength` /
  `process_audio` (`core.py:350-456`) and `realloc` (`core.py:146-190`) into our file with attribution
  and the §3 defects corrected; drive `PipelineMLX` / `RVC_MLX` for the model.

### Phase 2 — Swift client actor — Route: `swift-app-engineer`
* `Sources/AIServices/VoiceStreamClient.swift` — WebSocket lifecycle, reconnect with backoff, health,
  and the block protocol. Never on the render thread. Mirrors `VoiceConversionClient.swift`.
* Extend `SidecarManager` for the new sidecar id (unload-before-load and the m23-dl lifecycle rules
  apply; `idleUnloadSeconds` should be non-`nil` here — unlike the RVC facade — because a streaming
  session is episodic).

### Phase 3 — engine handoff — Route: `audio-dsp-engineer`
* `Sources/DAWEngine/Effects/VoiceConversionInsert.swift` per §6, plus a new
  `Sources/DAWEngine/VoiceConversionRing.swift` if the sample ring is not simply reused from
  `InsertSpectrumTap`'s shape.
* **Do not register it as a user-selectable chain insert** without an explicit decision on §6.4.
  Recommended: expose it only on the offline/render path first.

### Phase 4 — control + MCP + docs
* Additive verbs only, never renaming live commands: `vc.streamStart`, `vc.streamStop`,
  `vc.streamStatus`. ⚠️ **`Sources/DAWControl/Commands.swift` and `mcp-server/` are owned by other
  agents right now — do not touch them in the same window.**
* Update `docs/ARCHITECTURE.md` command-namespace totals **and** re-count with the settled method
  (empty symmetric difference between comment-stripped `allCommands` and the
  `rejectUnknownKeys(…, verb:)` sites — totals rot invisibly).

### Test strategy
| level | test | where |
|---|---|---|
| Fence | positive-control gate: `sounddevice` and `realtime.audio` absent from our sources; sidecar refuses to start if importable | `scripts/gates/` (coordinate — currently owned) |
| Contract | hello-frame defaults, unknown-key rejection, block size negotiation, reconnect after kill | `mcp-server/` tests + a `.mjs` staging gate on **port 17695**, never 17600 |
| DSP | SOLA continuity: convert a synthetic tone in streaming blocks, assert no discontinuity > ε at block boundaries and that the result correlates with the offline single-shot conversion of the same signal ≥ 0.99 | `Tests/` + a python fixture |
| RT-safety | headless `VoiceConversionInsert` fed by a fake ring: assert zero allocation in `process` (malloc-count harness), dry passthrough on empty ring, stable `latencySamples` across bypass toggles | `Tests/DAWEngineTests/` |
| PDC | assert a VC insert reporting N samples produces `T = N` and that bypass does **not** change it — pin the §6.4 consequence so it can never surprise anyone again | `Tests/DAWCoreTests/` |
| Perf | re-run the §4 sweep as a checked-in bench; fail if `load_factor_p95 > 0.6` at the shipped configuration | `scripts/` bench, not in the default test run |

### Full-Xcode / entitlements flags
* **None of this needs full Xcode.** No AUv3, no new entitlements, no signing change: the sidecar is
  a loopback child process exactly like the two we already ship, and the insert is in-tree Swift.
* One caveat *if* Phase 3 ever ships inside a signed bundle: the app must be able to spawn the
  vendored venv interpreter. That is the same requirement `scripts/rvc/run.sh` already has, and it
  is a **packaging** question (m23-ap-2 / pkg-*), explicitly out of scope per the user's 2026-08-04
  ruling that local-only use is the target.
* Xcode 26.6 **is** installed (verified 2026-08-04) — do not quote "blocked: needs full Xcode" here.

---

## 10. Contradictions with the brief, listed plainly

1. **"The streaming implementation already exists in that pinned tree."** The *code* exists; it has
   never run. Four defects, one of which (§3, Defect 4) makes it emit one sample per block. Measured,
   not inferred.
2. **"A streaming contract already exists."** True, but there is no server for it: nothing in the
   tree launches `client.py`, and the contract requires 24 mandatory keys with no defaults, freezes
   parameters at first connect, and destroys the model on any disconnect.
3. **"Your design must show explicitly how `sounddevice` is prevented from ever opening a stream."**
   No design is needed. It is not installed, not declared, imported by exactly two dead modules, and
   unreachable through a namespace package with no `__init__.py`. I have added an executed assertion
   and a gate anyway, because Fact 1 is the one that could change under a future `uv sync`.
4. **"Both candidate designs reach into `scripts/rvc/` — a directory the user fenced off."** True but
   under-specified: **shipped code already imports and executes vendored code** (`server.py:102`,
   `run.sh`). The genuinely new asks are (i) launching a *second* process from that tree, and (ii)
   *editing* a fenced file. Framing the question that way (§7) makes it answerable.
5. **The item's sizing.** Not "L/XL", and not a single replacement number: the headline capability is
   a **NO**, and the achievable remainder is **M** and of marginal value (§8).
6. **A finding neither the brief nor I anticipated, and the one that closes the item most cleanly:**
   DAW Pro has **no input→output monitor path** — `InputCapture.swift:5-8` states that avoiding one
   is deliberate ("Never touches this engine's outputNode or mainMixerNode — pulling those in would
   wire an input→output monitor path"). So "sing through your voice model" was never one item away;
   it is two, and the second was never scoped. I had drafted a claim about a singer's monitoring
   latency before checking this file, and it was wrong in the user's favour — the real situation is
   worse for the feature, not better (§6.5).
7. **A finding the brief did not anticipate:** the vendored tree contains a **complete native Swift
   MLX port** (`Demos/iOS/RVCNative/RVCNativePackage`, plus a macOS 14 SwiftPM wrapper at
   `Demos/Mac/Package.swift`). It is offline-only and lower-parity, so it loses today — but it is the
   right thing to reach for if we ever want to delete the Python sidecar, and it should be on the
   record rather than rediscovered.

---

## Appendix A — reproduction

Harness scripts live in the session scratchpad (not checked in, and deliberately not written under
`scripts/rvc/`):
`bench_rt_vc.py` (first attempt — reproduces the Defect-1 `IndexError`),
`bench_rt_vc2.py` (weight-load diagnostic + sweep, all-zero output — reproduces Defect 4's symptom),
`diag_zero.py` (isolates `model_out_len == 1`),
`bench3.py` (the §4 numbers, axis fixed).

Run shape: `cd scripts/rvc/runtime/src && OMP_NUM_THREADS=1 ./.venv/bin/python <script>`.
Assets used: `rvc_mlx/models/checkpoints/base_f0G40k.npz`,
`rvc/models/embedders/contentvec/hubert_mlx.npz`, `rvc_mlx/models/predictors/rmvpe_mlx.npz`.
No sidecar was started; no audio device was opened, enumerated for capture, or contended for;
port 17600 was never touched; no source file under `scripts/rvc/` was read-modify-written.

**One disclosure, because "write nothing there" was not literally achieved.** Executing vendored
Python with `cwd` inside the tree caused CPython to emit **six** `.pyc` bytecode caches under
`scripts/rvc/runtime/src/` (`rvc_mlx/realtime/__pycache__`, `.../realtime/utils/__pycache__`,
`.../configs/__pycache__`, `.../lib/mlx/__pycache__`). Characterisation, so it can be judged rather
than taken on trust:

* `scripts/rvc/.gitignore` ignores **`runtime/`** wholesale ("Only install.sh/run.sh/server.py/
  README.md/.gitignore are tracked"), and `git status --porcelain scripts/rvc/` is **empty** — no
  tracked file changed.
* **15 `.pyc` files under that tree pre-date this session** (dated Jul 17, in `rvc/lib/`,
  `rvc_mlx/infer/`, most of `rvc_mlx/lib/mlx/`). Bytecode caching there is the normal, pre-existing
  side effect of running the sidecar at all — `scripts/rvc/run.sh` produces the same class of
  artifact on every launch. My runs added six of an existing 15.
* **I deliberately did not delete them.** A delete is also a write under a fenced directory, the
  files are gitignored and regenerated on next import, and an erroneous `rm` there is precisely the
  irreversible mistake the fence exists to prevent. Disclosure beat cosmetic cleanup.
* **Mitigation for any future work in this tree:** set `PYTHONDONTWRITEBYTECODE=1` (or pass
  `python -B`). That makes "read-only" literal, and it should be added to the Phase-0 gate in §9 and
  to any harness that runs vendored code.
