# m23-fd — Multi-voice blending / morphing: feasibility spike

**Date:** 2026-08-10 · **Route:** `daw-architect` · **Status:** SPIKE COMPLETE — recommendation is
**do not build m23-fd yet.** Not because blending is infeasible, but because the spike found a
**reproducibility defect on the shipped conversion path** that blending would multiply, and because
the feature as written ("load several voices and interpolate between them") maps onto the branch
that is *least* supported by our runtime.

This is a design deliverable. No engine or app code was modified. `scripts/rvc/` was treated as
strictly read-only. Every measurement below came from throwaway harnesses in the session scratchpad
run against the vendored tree's own venv with `PYTHONDONTWRITEBYTECODE=1`; the fence audit is in
Appendix B and it is clean — **zero files under `scripts/rvc/` were created or modified by this
session.**

---

## 0. Verdict in one page

| Question | Answer |
|---|---|
| **Branch 1** — blend speaker rows *within* one model. Real? | **Mechanically real and well-behaved — measured.** `emb_g.weight` is **(109, 256)**, 108 distinct rows; swapping rows moves the output **225× the noise floor**; a linear blend is **monotone in both directions** with exact endpoints (§3). |
| …but does branch 1 deliver the roadmap feature? | **No.** Those 109 rows are the *pretrain's* speakers. A user's fine-tuned voice inherits the same 109-row table (`rvc/train/train.py:407`) with **one** trained row. Blending its rows blends your voice with vestigial base speakers — a "voice character" knob, not "blend voice A with voice B" (§3.5). |
| **Branch 2** — interpolate two separately-trained models. Real? | **The shared-ancestry condition is real and upstream already implements the operation** (`rvc/train/process/model_blender.py:17`) — but it is **unreachable from our runtime** (`rvc-mlx-cli.py:299-301` registers `model_blender` as *"Not yet supported in Pure MLX"*), it needs `.pth` (so it is downstream of the blocked m23-di-2b), and **it does not check ancestry at all** — only sample rate and key-set equality (§4). |
| Can ancestry be checked? | **Yes, and cheaply — I believe this is new.** Single-speaker fine-tuning writes only row `sid`; rows 1..108 keep the pretrain's values (decayed, not rotated — AdamW at `train.py:453-458` passes no `weight_decay`, so the default 0.01 applies). **Cosine similarity of rows 1..108 against `base_f0G40k.npz` is a pretrain fingerprint.** Unvalidated — there are zero voice models on this machine (§4.3). |
| Can the shipped offline path express a blend? | **Mechanically yes, with no sidecar edit at all** — materialise the blend as a derived `model.npz` in a voice directory we own and convert with `voiceId: "<blendId>"`. The npz round trip is **bit-exact** (max tensor delta 0.000e+00 over 423 tensors) and costs **0.186 s** end to end (§5). **But see the row below: the mechanism works and the *feature* still may not.** |
| Can it be *dragged live*, as the roadmap wants? | **No** — but the reason turned out to be a **bug, not a limit**, and finding it is the most valuable thing in this spike (§5.3). |
| ⭐⭐ **THE HEADLINE — a second, root-caused, shipped-path defect** | **Half of the base model's normalising flow has been randomly initialised on every single load, and a third of it is loaded into the wrong slot.** The checkpoint stores PyTorch flow indices `0,2,4,6`; the MLX model declares `flow_0..flow_3`; `remap_keys` renames **verbatim**, so `flow_1`/`flow_3` get **0 of 19** parameters (fresh random values every construction) and the checkpoint's `flow_4`/`flow_6` (36 tensors) are **silently discarded**. The vendored repo documents this exact `i//2` mapping as *"CRITICAL"* — but implements it in `tools/convert_rvc_model.py`, while `install.sh:327-329` builds our npz with `tools/convert_pth_to_mlx.py`, which has no such logic. **Fix built and verified in this spike:** cross-process LSD collapses **0.4148 → 0.0045** (= the within-engine floor), rms becomes stable at 0.1223 across processes, and the audio changes by **LSD 1.06 — more than full speaker separation.** The fix is a **key remapping written into a file we own; no fenced write** (§5.3). |
| **Blocker A — the other defect the spike found** | **Repeated conversion in one process degrades to saturated garbage.** rms 0.0319 → 0.633, peak pinned at 0.99, by the 5th call — and `mx.clear_cache()` fully and reversibly fixes it (ABA design, §2). `scripts/rvc/server.py` is a long-lived process that **caches engines** (`:94`, `:99`, `:107`), so this reaches shipped `vc.convertVocals` today. |
| Fence | **One question, already on the table — and this spike makes it *smaller*.** Neither the blend (§5.1) nor the §2 correctness fix (§6.1, corrected) needs a write under `scripts/rvc/`. Cross-referenced to `docs/research/2026-08-10-realtime-vc-spike.md` §7 — **not re-asked** (§6). |
| Sizing | **NO** for the item as written. Two prerequisite defects are **S** each and must be fixed first (§2, §5.3.1). With the flow fix in, "create a blended voice" is **M**; a live drag stays **NO**; the "voice character" knob is **S–M** but is not what the roadmap asked for (§8). |

**The single most important finding:** while building an instrument accurate enough to measure a
blend, I had to make the shipped pipeline reproducible — and it is not. Four of my first five
measurement passes were confounded by it, including two that produced confident, publishable-looking
numbers that were wrong. Any blend UI is an A/B comparison machine; shipping one on top of a
converter whose output level triples between calls would make the *feature* look broken when the
*platform* is.

---

## 1. What I read, and where the brief holds up

Every claim cites `file:line` I opened.

### 1.1 Coordinates from the brief that verified

| Brief's claim | Verified |
|---|---|
| `spk_embed_dim = weights["emb_g.weight"].shape[0]` | `scripts/rvc/runtime/src/rvc_mlx/infer/infer_mlx.py:221` — exact |
| `sid` passed, defaulting to 0 | `infer_mlx.py:309` — the literal is `0, # sid default 0`; **`RVC_MLX.infer()` exposes no `sid` parameter at all**, so row 0 is the only reachable speaker |
| `POST /v1/voice/convert` takes a single `voiceId` and no blend knob | `scripts/rvc/server.py:252-256` (`ConvertRequest`: `inputPath`, `voiceId`, `pitchSemitones`), handler `:258-366` |
| Shipped code already *imports* vendored modules | `server.py:102` — `from rvc_mlx.infer.infer_mlx import RVC_MLX` |
| `base_f0G40k.npz` ships in our tree | present, 69.6 MB, 423 tensors |
| Imports land in `<Application Support>/DAWPro/VoiceModels` and show `needsConversion` | `Sources/DAWControl/Commands.swift:4895-4961`; `RVC_VOICES_DIR` is repointed there at every `vc.sidecarStart`, so `server.py:177`'s plain directory scan does see them. `scripts/rvc/runtime/voices/` being empty is therefore expected, not a contradiction. |
| m23-ez settled the upstream | `server.py:217` reports `"engine": "Acelogic/Retrieval-based-Voice-Conversion-MLX"`; `install.sh:85-86` pins `eec7791a59eb09d0f56f1189df55e9852848e692` |

### 1.2 Where I diverge from the brief

1. **The brief's hedge — "if it is 1 everywhere, this branch is moot" — does not fire.** It is 109,
   and the rows are real: 108 distinct, norms 7.82–9.47, mean pairwise cosine **+0.0108** (i.e.
   near-orthogonal, the signature of a trained table, not of MLX's `nn.Embedding` init, which would
   give norms near 1.0). Exactly one duplicate pair exists (row 1 is bit-identical to row 0).
   *But the branch is moot for a different reason than the brief anticipated* — see §3.5.

2. **"Weight-space interpolation between independently trained networks is generally meaningless"
   is right in theory, and the upstream ships it anyway.** `rvc/train/process/model_blender.py` is
   a complete two-model linear blend with a CLI (`rvc_cli.py:2080-2105`, `--ratio` restricted to
   tenths). This is a *used community feature*, which is evidence the shared-ancestry condition
   holds often enough in practice to be worth something — and evidence nobody checks it.

3. **The brief frames this as "two branches with very different costs."** After measurement the
   dominant cost is neither: it is the §2 defect, which sits underneath both.

4. **One documentation correction.** `server.py:195-199` describes the base as an *"untrained
   109-speaker embedding."* Read literally that is wrong and it misled my first read: the rows are
   demonstrably not random-init and demonstrably steer the decoder (§3.2). The intended meaning is
   "the base model is a generic pretrain, not a trained voice," which is true. Worth rewording if
   that file ever becomes editable.

---

## 2. BLOCKER A — repeated conversion degrades to saturated garbage

> **Two independent defects came out of this spike.** This section is the first (a state/allocator
> problem, mitigated by `mx.clear_cache()`). The second — and the more serious — is the flow-mapping
> defect root-caused in **§5.3**. They are **not the same bug**: the degradation below reproduces
> *identically* on the flow-corrected model (rep-5 onset; clipping 20.09 % vs 20.11 %, 34.67 % vs
> 34.93 %, 40.65 % vs 40.67 %), so fixing either leaves the other standing.

This was not what I set out to measure. It surfaced because the branch-1 question demands a
measurement whose noise floor is below the effect, and the first four attempts had a noise floor
*above* it.

### 2.1 The observation

One `RVC_MLX` engine, the **shipped entry point** `RVC_MLX.infer()` (exactly what `server.py:334`
calls), the **same input file** every time, no mutation of any kind between calls:

```
rep  0 rms=0.03105 peak=0.2630        <- correct
rep  1 rms=0.03050 peak=0.2625
rep  2 rms=0.03954 peak=0.4375
rep  3 rms=0.03469 peak=0.9426
rep  4 rms=0.29340 peak=0.9900        <- saturated
rep  5 rms=0.44912 peak=0.9900
...
rep 11 rms=0.63398 peak=0.9900
```

`peak = 0.99` is the max-normaliser at `rvc_mlx/infer/pipeline_mlx.py:369-372` clamping an output
that has run into the decoder's final `tanh`. Constructing a **brand-new** `RVC_MLX` in the same
process does **not** recover: it starts already saturated. The corruption is process-global, not
engine state.

### 2.2 The cause, established by an ABA design

`mx.clear_cache()` before each inference is necessary and sufficient. Same process, three phases:

| phase | rms | peak |
|---|---|---|
| **A** — `clear_cache()` before every call, 8 reps from cold | 0.032384 – 0.032389 | 0.2518 – 0.2533 |
| **B** — stop clearing, 8 reps | 0.031877 → **0.633444** | 0.2515 → **0.9900** |
| **A′** — resume clearing, 6 reps | 0.032384 – 0.032393 | 0.2522 – 0.2530 |

Phase A holds five significant figures across eight calls; phase B degrades monotonically to
saturation; phase A′ **fully recovers**. MLX 0.30.1; `mx.get_cache_memory()` had reached 3.65 GB.

### 2.3 What it is not — the hypotheses I killed

Recording these because each looked right and each was wrong:

* **Not the excitation randomness.** `HiFiGANNSFGenerator` builds its source module with
  `harmonic_num=0` (`generators.py:157`), so `waveform_dim == 1` and the "random phase" array at
  `generators.py:88` is `shape=(1,1,0)` — **empty**. Harmonic phase is deterministic. Forcing the
  only remaining draw (`generators.py:110`, `noise_std=0.003`) to zero changes nothing: the
  degradation is identical.
* **Not BatchNorm in train mode.** All 118 `nn.BatchNorm` modules under RMVPE report
  `training=False`; `running_mean` drift across four calls is exactly `0.000000e+00`.
* **Not upstream of the decoder.** The pipeline's own debug trace is **bit-identical across nine
  reps** — `m_p` `[-1.565060 … 0.982152]`, `logs_p` `[-1.701408 … 2.372637]`, `z_p` the same — while
  the audio degrades from rms 0.029 to 0.633. HuBERT features and RMVPE f0 hash identically across
  reps. Everything through the text encoder is deterministic; the divergence is entirely in the flow
  and decoder.
* **Not `mx.random.seed()` being ineffective.** Verified in isolation: `seed(1)` twice gives
  identical draws, `seed(2)` differs. (Seeding nonetheless does *not* pin `net_g.infer` — noted, not
  isolated, and rendered moot by `clear_cache`.)
* **Not my in-memory weight mutation.** The degradation is identical with no assignment at all.

**Root cause not fully isolated**, and I will not over-claim it: the behaviour is consistent with a
cached Metal allocation being handed back and read before it is fully written — an
uninitialised-memory read, in MLX 0.30.1 or in how the vendored graph uses it. What *is* established
is the trigger, the signature, and a complete, reversible mitigation.

### 2.4 Why this outranks m23-fd

* `scripts/rvc/server.py` caches engines (`:94` `_engines`, `:99`, `:107`) in a **long-lived**
  process and serialises conversions behind one lock (`:327`). The 5th and later `vc.convertVocals`
  in a sidecar session are in the degraded regime.
* ~~The one-line mitigation belongs in `scripts/rvc/server.py` — fenced.~~ **CORRECTED (§6.1): it does
  not.** The mitigation can be applied from a launcher **we own**, outside the fence, by importing the
  unmodified facade and patching the engine class in-process. Verified mechanically; see §6.1.
* Any blend UI *is* a repeated-conversion machine.

**Honest scoping of the evidence.** Measured on: this machine, MLX 0.30.1, the `base` model, a
4-second synthetic vowel, `RVC_MLX.infer()` called directly. **Not** verified through the HTTP
server, on a real trained voice (none exist on this machine), or across varied inputs. The user's
own historical outputs under `scripts/rvc/runtime/out/` are *suggestive but inconclusive* — pid
60230 shows rms 0.108 → 0.167 within one process, and pid 1843's first file has peak 0.9900 with
2.54 % of samples clipped, but the inputs differed and are unknown, so they cannot confirm it.
**File this as its own item and reproduce it through the sidecar before acting.**

---

## 3. Branch 1 — blending speaker rows within one model

All numbers below were taken with `mx.clear_cache()` before every inference (§2), through the
shipped `RVC_MLX.infer()`, with `emb_g` row 0 rewritten **in memory**. Stimulus: a rights-clear
synthetic sung vowel (jittered pulse train through four formant resonators, three notes, 4 s) —
no recording of any person. RMVPE reports it **100 % voiced**, median f0 218.7 Hz. Metric: RMS
distance between rep-averaged log-magnitude spectra ("LSD").

### 3.1 The instrument, and its floor

| | |
|---|---|
| Two independent 3-rep signatures of the **same** row | **LSD = 0.0039** |
| Single-rep rms spread | **0.02 %** of the mean |
| Single-rep-to-single-rep floor, same engine | LSD = 0.0092 |

### 3.2 The speaker row steers the decoder — decisively

| pair | LSD | vs floor |
|---|---:|---:|
| row 0 / row 12 | 0.8777 | 224× |
| row 0 / row 37 | 0.9533 | 243× |
| row 0 / row 80 | 0.7497 | 191× |
| row 0 / row 108 | 0.8368 | 213× |
| row 37 / row 80 | 0.9768 | 249× |
| **mean over all 10 pairs** | **0.8834** | **225×** |

Output level also tracks the row (rms 0.0295 / 0.0503 / 0.0304 / 0.0403 / 0.0408) with per-row
standard deviation ≤ 5e-6. This is not a subtle effect.

### 3.3 A linear blend is well-behaved

Row 0 → row 37, distances normalised by LSD(row0, row37):

| α | rms | peak | d(row0)/D | d(row37)/D | sum |
|---:|---:|---:|---:|---:|---:|
| 0.000 | 0.029488 | 0.2437 | **0.004** | 1.000 | 1.004 |
| 0.125 | 0.029220 | 0.2041 | 0.239 | 0.938 | 1.177 |
| 0.250 | 0.029301 | 0.1923 | 0.383 | 0.854 | 1.237 |
| 0.375 | 0.029599 | 0.1874 | 0.515 | 0.782 | 1.297 |
| 0.500 | 0.029987 | 0.1872 | 0.623 | 0.710 | 1.333 |
| 0.625 | 0.030382 | 0.1760 | 0.761 | 0.612 | 1.373 |
| 0.750 | 0.030340 | 0.1741 | 0.864 | 0.449 | 1.314 |
| 0.875 | 0.030083 | 0.1708 | 0.971 | 0.249 | 1.219 |
| 1.000 | 0.030447 | 0.1962 | 0.999 | **0.005** | 1.004 |

* **Both positive controls pass exactly.** α=0 rewrites row 0 with itself and lands at 0.004 — the
  noise floor. α=1 writes row 37 into row 0 and lands at 0.005 from a true `sid=37` conversion.
  *(This is the control that failed in my first three passes and correctly invalidated them.)*
* **Monotone in both directions**, no reversals; crossover at α ≈ 0.55.
* **Level is stable** across the whole sweep (rms 0.0292–0.0304). No collapse, no explosion.
* The `sum` column peaks at **1.373**. Read this narrowly: LSD is not a metric on a flat space, so
  this is **not** a geodesic deviation and no geometric claim should be built on it. What it does
  support is the load-bearing part — **the path does not collapse toward some third voice**: every
  intermediate α stays much closer to its two parents than the parents are to any other speaker
  (0.75–0.98 away). The monotonicity result above is the finding; this is a sanity check.
* **Extrapolation degrades gracefully.** α = −0.5 / +1.5 / +3.0 give rms 0.0317 / 0.0312 / 0.0338,
  peak ≤ 0.242 — outside the segment (d > 1 to both endpoints) but never unstable. A UI can allow
  modest over-travel without a safety clamp.
* **Naive averaging of many rows collapses.** The mean of all 109 rows has norm **1.229** against a
  mean row norm of **8.708** — near-orthogonal rows cancel. A 3-way barycentric blend is fine
  (d = 0.638 / 0.803 / 0.717 to its three parents); an N-way "average voice" is not a voice.
  If an N-way control ships, **renormalise** or the timbre drains as sliders are added.

### 3.4 It costs essentially nothing

| operation | time |
|---|---|
| Rewrite one `emb_g` row in memory | **0.1 ms** |
| Convert 4 s of audio | 0.115 s (**RTF ≈ 35×**) |
| …with `mx.clear_cache()` (required, §2) | 0.19–0.25 s |
| Construct a whole `RVC_MLX` | 0.13–0.23 s |

### 3.5 …and it is not the feature the roadmap asked for

This is the finding that decides branch 1, and it comes from the training side, not the weights:

* `rvc/train/train.py:407` — `spk_dim = ckpt["model"]["emb_g.weight"].shape[0]`. The generator is
  initialised with **the pretrain's speaker count**, not the dataset's. `:414` writes it back into
  the config, and `:388`'s comment says so outright: `# 109 default speakers`.
* Single-speaker training uses one `sid`, so exactly one row receives gradient.

Therefore a user's imported or trained voice is **one trained row plus 108 vestigial pretrain rows**,
rendered through a decoder that has been fine-tuned *away* from them. Blending row 0 with row 37
does not blend two voices the user loaded. It blends their voice with a base-pretrain speaker.

That is not worthless — it is a continuous, near-free **"voice character" knob**, and §3.3 shows it
behaves well. But it is a different feature from "load several voices and interpolate between them,"
and shipping it under that name would be a lie. **Say which one is being built.**

---

## 4. Branch 2 — interpolating two separately-trained models

### 4.1 The operation already exists upstream

`rvc/train/process/model_blender.py:17` `model_blender(name, path1, path2, ratio)`:

* `:20-21` loads both with `torch.load(..., weights_only=True)`;
* `:26-30` **refuses on sample-rate mismatch** — the only architectural guard;
* `:47-48` **refuses on key-set mismatch** — `"The model architectures are not the same."`;
* `:52-62` linear-interpolates **every tensor** at `ratio`, with a special case at `:53-58` that
  truncates `emb_g.weight` to the smaller speaker count when the two differ;
* `:71` writes `os.path.join("logs", f"{name}.pth")` — **relative to cwd**, so it can be aimed
  outside the fence simply by choosing the working directory.

Exposed as `rvc_cli.py model_blender` (`:2080-2105`, `--ratio` limited to tenths, `:579-583`).

### 4.2 …but it is unreachable from our runtime, three times over

1. **Our CLI declares it unimplemented.** `rvc-mlx-cli.py:299-301` puts `model_blender` in a list
   headed `# Placeholders for not-yet-implemented commands`, helping out as
   *"(Not yet supported in Pure MLX)"*. The working blender lives only in the torch-based Applio-derived
   `rvc/` tree.
2. **It consumes `.pth`, and our store's ready state is `.npz`.** `server.py:159-166` marks a voice
   `ready` only when `model.npz` exists; a `.pth`-only voice is `needsConversion`. So blending two
   *ready* voices via `model_blender` means having kept their `.pth`s **and** converting the result
   back — i.e. it sits **downstream of m23-di-2b**, which is blocked on the user.
3. **The npz-domain equivalent is ~30 lines in code we own** and needs neither torch nor `.pth`:
   `mx.load` both, check key sets and shapes, lerp, `mx.savez`. Measured: **full 423-tensor lerp in
   0.006 s.** This is strictly the better route, and §5 shows it needs no sidecar change either.
   Its one real cost: **the npz carries no `sr`/config metadata** (§5.2).

### 4.3 The crux — is the shared-ancestry condition satisfied? Unknown, but checkable

The brief is right that this is the crux, and right that it decides whether the feature exists.

**Reasons to think it often holds.** `install.sh:242` fetches `pretrained_v2/f0G40k.pth` — the
canonical RVC v2 40k pretrain — and `:327-329` derives our `base_f0G40k.npz` from it. Most public
RVC v2 40k voices are fine-tuned from that exact file. Fine-tunes from a *shared initialisation* are
the case where linear mode connectivity actually tends to hold; there is no permutation symmetry to
break, because no re-permutation happens under SGD from a common init.

**Reasons it will not always hold.** The community routinely trains from alternative pretrains, and
**our own tooling offers one**: `rvc-mlx-cli.py:296` takes `--pretrain base|titan` and `:259`
downloads *"TITAN community pretrain (recommended for training)"*. Two voices from different
pretrains have identical key sets and identical sample rate — so `model_blender` will happily blend
them and return mush, because **nothing in it checks ancestry.**

**The check I propose, which I believe is new.** Since single-speaker fine-tuning writes only row
`sid`, rows 1..108 of `emb_g.weight` are a fingerprint of the pretrain. Two models sharing a pretrain
will have near-identical rows 1..108.

*Use cosine similarity, not equality.* `train.py:453-458` constructs `torch.optim.AdamW(params, lr,
betas=…, eps=…)` and passes **no `weight_decay`**, so PyTorch's default `0.01` applies. AdamW's
decoupled decay shrinks every parameter multiplicatively each step, including rows that receive no
gradient — so untouched rows **shrink in norm without rotating**. Equality fails; direction survives.

Concretely, at import or blend time: load both `emb_g.weight`, compute per-row cosine against
`base_f0G40k.npz` for rows 1..108, and require a high median (a starting threshold of 0.99 is
suggested, to be calibrated on real specimens). Cost: microseconds. It answers *"were these two
models born from the same parent?"* — which is precisely the question interpolation's validity
turns on.

⚠️ **This test is UNVALIDATED.** `scripts/rvc/runtime/voices/` is empty and
`~/Library/Application Support/DAWPro/VoiceModels/` does not exist — **there are zero voice models
on this machine.** I did not fetch any: acquiring third-party voice models is exactly the
"go find celebrity voices at scale" behaviour that remains out of bounds even under the withdrawn
own-voice policy. The threshold and the false-positive rate must be calibrated against real
specimens the user supplies. **Everything in §4 about real user models is reasoning from the
training code, not measurement.**

### 4.4 Two more things branch 2 must answer

* **The retrieval index.** `server.py:291-293` sets `index_rate = 0.75` iff `model.index` exists. A
  blended model has no coherent index — each `.index` is a FAISS store of *its own* training
  features. Three options, in preference order: (a) **omit it**, `index_rate = 0` — honest, costs
  quality; (b) search both and blend the retrieved features at the same α — coherent, and the only
  option that actually blends what the index is for; (c) carry one voice's index — asymmetric and
  will bias the result toward that voice. All my measurements ran at `index_rate = 0`, so **none of
  them speak to index behaviour.**
* **`convert_pth_to_mlx.py:48` calls `torch.load(pth_path, map_location="cpu")` with no
  `weights_only=True`** — arbitrary code execution when converting an untrusted third-party
  checkpoint. `model_blender.py:20-21` gets this right; the converter does not. This is a **security
  finding for m23-di-2b**, which is precisely the item that would run that converter on user-supplied
  files. It is not m23-fd's to fix, but m23-fd is downstream of it and should not be built over it.

---

## 5. Can the shipped offline path express a blend?

### 5.1 Not through its request contract — and it does not need to

`ConvertRequest` (`server.py:252-256`) has exactly `inputPath`, `voiceId`, `pitchSemitones`.
`_engines` is keyed by `voice_id` alone (`:94`, `:99`, `:107`). `RVC_MLX.infer()` exposes no `sid`
(`infer_mlx.py:287-297`) and hardcodes `0` (`:309`). Adding a blend parameter means editing
`scripts/rvc/server.py` — forbidden.

**But a blend does not need a request parameter.** Materialise it as a derived voice:

```
<Application Support>/DAWPro/VoiceModels/<blendId>/
    model.npz     <- written by us: the blended tensors
    model.json    <- the architecture config, carried over (§5.2)
    voice.json    <- provenance: parents + α
```

and then call the **completely unmodified** `POST /v1/voice/convert` with `voiceId: "<blendId>"`.
`server.py:177`'s `_scan_voices()` is a plain directory scan and `:282` resolves `model.npz` —
a derived voice is indistinguishable from an imported one.

**Verified end to end.** A derived npz with a blended `emb_g` row 0 loaded through the unmodified
`RVC_MLX` and converted successfully. The round trip is **lossless**: keys identical (423 vs 423),
dtypes identical, **max absolute tensor delta 0.000e+00**.

| step | time |
|---|---|
| `mx.load` 423 tensors | 0.021 s |
| edit / lerp | 0.0001 s (one row) · 0.006 s (all 423) |
| `mx.savez` | 0.030 s (**72.9 MB**) |
| `RVC_MLX()` reload | 0.134 s |
| **total per blend** | **0.186 s** |

**This is the architectural answer, and it is a good one:** blending needs **no new sidecar route,
no new HTTP verb, and no edit to any fenced file.** It is a file-materialisation operation in code
we own, plus the existing `vc.convertVocals`.

Cost to be honest about: **72.9 MB per materialised blend.** Blends must be explicitly created and
deletable, not silently spawned per slider position.

### 5.2 The metadata trap

`base_f0G40k.npz` is a bare tensor dict — **no `sr`, no config**. `infer_mlx.py:163-169` therefore
*guesses* 40 kHz, `upsample_rates=[10,10,2,2]`, `upsample_kernel_sizes=[16,16,4,4]`, `gin=256`,
unless a sibling `.json` exists (`:172-215`), which for a voice directory means `model.json`.
`convert_pth_to_mlx.py:78-83` **does** write that sibling when the `.pth` carries a `config` key, and
`rvc/train/process/extract_model.py:62-79` shows released RVC checkpoints carry exactly the
18-element list `infer_mlx.py:177-201` parses. So metadata survives — **if** conversion goes through
that tool.

Two consequences:

1. **A blend must copy the parents' `model.json` and refuse if they disagree.** Without it a 48 kHz
   model loads silently as 40 kHz.
2. **Architecture is also derivable from tensor shapes**, which is a cheap independent cross-check:
   `dec.ups.{0..3}.weight` are `(256,16,512)`, `(128,16,256)`, `(64,4,128)`, `(32,4,64)` — kernel
   sizes `[16,16,4,4]` = 40 kHz v2. 48 kHz gives `[24,20,4,4]`, 32 kHz gives `[20,16,4,4]`.
   `enc_p.emb_phone.weight` is `(192, 768)` — 768 = v2; v1 would be 256. **A shape-derived guard
   does not depend on a `.json` anyone may have lost.** Recommended over trusting metadata alone.

### 5.3 The reload floor — which turned out to be a bug, and is now root-caused and fixed

This is the measurement that changed the recommendation, and it was run last, at the reviewer's
prompting, precisely because the first version of this section under-claimed.

**The question.** Two derived blends differ from each other by the α increment. If loading a blend
costs more error than the increment carries, the user cannot hear their own slider. So: is the
instance-to-instance difference a *transient* first-conversion artifact that warms out, or a
*persistent* offset?

**The design.** Rep-averaged log-spectral signatures (3 reps each, `mx.clear_cache()` before every
inference per §2), from engines built from the **same** `base_f0G40k.npz`, converting the **same**
stimulus with identical parameters. Two axes: warm-up depth, and process identity.

| comparison | LSD | vs within-engine floor |
|---|---|---|
| **Within one engine**, two independent 3-rep signatures | **0.0045** | — (this is the floor) |
| Two engines, same process, no warm-up | 0.4070 | 90× |
| Two engines, same process, one discarding its **1st** conversion | 0.3514 | 78× |
| Two engines, same process, one discarding its **first 3** | 0.3337 | 74× |
| **Separate processes**, each building exactly **one** engine (3 pairs) | **0.3700 · 0.4439 · 0.4536** | 82–101× |
| Engine #2 vs engine #3 (different processes, deeper engine index) | 0.3104 | 69× |

**Three conclusions from the table, in order of how much they hurt:**

1. **It is not a warm-up transient.** Discarding one or three conversions barely moves it
   (0.407 → 0.351 → 0.334). It is a **persistent per-instance offset**.
2. **It is not multi-engine contamination inside one process** — the hypothesis that the sidecar's
   `_engines` cache (`server.py:94/99/107`) was poisoning later engines. Three *separate processes*,
   each building exactly one engine, disagree with each other by 0.37–0.45. **The nondeterminism is
   per-process**, so restarting the sidecar does not escape it.
3. **It is not a level or tilt difference**, which a listener might discount. Removing the global
   log-magnitude offset leaves **0.22–0.43** (from raw 0.24–0.45); the level offsets themselves are
   only 0.2–2.9 dB. **The difference is structural** — roughly 2–3.7 dB RMS spectral divergence,
   i.e. a third to a half of full speaker separation (0.95).

*(Mechanism, still a hypothesis and deliberately not chased: `infer_mlx.py:248` loads with
`strict=False`, so parameters absent from the checkpoint keep their random initialisation, and each
construction draws different values. m23-fc measured 387 of 1221 Synthesizer parameters getting
filled. The measurement stands regardless of the explanation — and note it is the **same magnitude**
as the §2 degradation, so the two are plausibly one defect.)*

**What this does to the feature.** Compare against §3.3's α sweep:

| α gap | output movement | above the 0.37–0.45 reload floor? |
|---|---|---|
| 0.125 (fine slider step) | ~0.13 | **no — 3× below** |
| 0.25 (coarse: 0.25 → 0.50) | ~0.26 | **no** |
| 0.50 (0.25 → 0.75) | ~0.48 | marginal, ~1.1× |
| 1.00 (endpoint to endpoint) | ~0.95 | yes, ~2.3× |

> **A user who materialises blend A at α=0.5 and blend B at α=0.625 and plays them back is comparing
> two separate engine loads. The reload difference is larger than the blend difference. They are
> auditioning the reload.**

So the live drag is dead — and, *as measured on the shipped model*, so is the honest version of
"create a blend and tweak it": only endpoint-scale differences survive a reload, and at endpoint
scale the user does not need a blender.

> ⭐ **Read on before acting on that paragraph.** §5.3.1 identifies the cause as a **defect in how we
> build the model file**, and §5.3.2 shows a fix that collapses the floor from 0.4148 to **0.0045**.
> With the fix, α steps are ~29× the floor and the blend feature is viable again. The paragraph above
> describes the *current* build, not an inherent limit.

### 5.3.1 ROOT CAUSE — found, and it is a bug in how we build the model file

The paragraph above originally ended here, recommending a determinism *experiment*. A reviewer
pushed back that the gate rested on an unchased hypothesis. The experiment was run, the hypothesis
was **wrong**, and the real cause is both worse and completely fixable.

**Step 1 — the pitch tracker is exonerated.** RMVPE f0 is **bit-identical across processes**: same
SHA-256 (`8a72073732745571`), 401 frames, mean 220.756706 Hz, identical sums, in three separate
processes. The divergence is downstream of the pitch tracker.

**Step 2 — a methodological trap that would have produced a false alarm.** Diffing the checkpoint's
key set against `tree_flatten(net_g.parameters())` says **834 of 1221 parameters are missing**,
including 449 in the decoder — which would mean the shipped model is mostly noise. **That number is
an artifact.** The modules expose *both* naming conventions: `dec.noise_convs.0.weight` (list form)
and `dec.noise_conv_0.weight` (named-property form) are **the same array** (verified equal), because
the port needed named properties for MLX's `update(parameters:)` and kept the lists for iteration.
Loading one path fills both. *Never diff key sets on this model — diff behaviour.*

**Step 3 — the measurement that is immune to that trap.** Build two engines from the same file and
ask which parameters actually **differ**:

| | |
|---|---|
| Synthesizer parameters | 1221 |
| **Identical** across two independent constructions | **1161** |
| **Differ** (i.e. genuinely at fresh random init) | **60 — all of them in `flow`** |
| Share of total weight mass that is re-randomised each load | **11.4 %** (11,649,024 elements) |

**Step 4 — why.** The raw checkpoint stores PyTorch flow indices `flow.flows.{0,2,4,6}` (PyTorch
interleaves Layer and Flip modules, so only even indices are layers). The MLX `Synthesizer` declares
**`flow_0, flow_1, flow_2, flow_3`**. `remap_keys` renames **verbatim**, yielding
`flow_0, flow_2, flow_4, flow_6`. The result, measured slot by slot:

| MLX slot | parameters filled from the checkpoint | what it actually holds |
|---|---|---|
| `flow_0` | **18 / 19** | the checkpoint's flow 0 — correct by coincidence (`0//2 == 0`) |
| `flow_1` | **0 / 19** | **fresh random values, re-drawn on every construction** |
| `flow_2` | **18 / 19** | the checkpoint's flow 2 — **which belongs in `flow_1`** |
| `flow_3` | **0 / 19** | **fresh random values, re-drawn on every construction** |
| — | — | the checkpoint's `flow_4` and `flow_6` (**36 tensors**) are **silently discarded** |

So of four coupling layers: **one correct, one in the wrong position, two random.**

**Two implementations of this mapping exist in the tree, they disagree, and we run the wrong one.**
This is the load-bearing citation, so both sides are quoted exactly:

| | |
|---|---|
| **Reference — correct.** `runtime/src/tools/convert_rvc_model.py:179-188` | `if key.startswith("flow.flows."):` … `flow_idx = int(parts[2])` … **`real_idx = flow_idx // 2`** … `prefix = f"flow.flow_{real_idx}"`, under the comment `# PyTorch flow list contains [Layer, Flip, Layer, Flip...]` |
| **What we actually run — wrong.** `runtime/src/rvc_mlx/infer/infer_mlx.py:66-80` (`remap_keys`) | `elif new_key.startswith("flow.flows."):` … **`f_idx = parts[2]`** used **verbatim**, e.g. `new_key = f"flow.flow_{f_idx}.{'.'.join(rest)}"` — no `// 2` anywhere in the function |

**Why the bug hid for so long:** `remap_keys`'s own example comment at `:67` reads
`flow.flows.0.enc.in_layers.0.weight -> flow.flow_0.enc.in_layer_0.weight` — which is *correct*, and
is the one index where verbatim and `//2` agree. Slot 0 loads properly; the failure starts at the
second coupling layer.

**Ordering is load-bearing, so the permutation matters and is not free to choose.**
`runtime/src/rvc_mlx/lib/mlx/residuals.py:75` binds the named attributes positionally —
`for i, f in enumerate(self.flows): setattr(self, f"flow_{i}", f)` — and `:88` runs the stack as a
sequence in reverse at inference (`for i in reversed(range(self.n_flows))`). So `flow_i` **is** the
i-th element of an ordered chain. *Filling all four slots and restoring determinism would be achieved
by any bijection; only agreement with the reference establishes it is the **right** bijection.* The
ascending `i//2` assignment used below is exactly `convert_rvc_model.py`'s.

**And our build path skips the reference entirely.** `scripts/rvc/install.sh:327-329` derives
`base_f0G40k.npz` with **`tools/convert_pth_to_mlx.py`**, which I read end to end (92 lines): it does
weight-norm removal and transposes, and has **no flow index logic at all** — it emits raw
`flow.flows.{0,2,4,6}` keys. `remap_keys` then renames them verbatim at load time. Nothing downstream
compensates, and `strict=False` at `infer_mlx.py:248` turns the hard failure into a silent one.

### 5.3.2 The fix, built and verified

I applied the reference's `i//2` mapping (`flow_0→flow_0, flow_2→flow_1, flow_4→flow_2,
flow_6→flow_3`) and wrote a corrected npz **into the scratchpad — never under `scripts/rvc/`**.

*Why writing corrected keys into a file we own is sufficient, with no fenced edit:* `remap_keys`
only rewrites keys beginning `flow.flows.` (plural). Keys already in MLX form — `flow.flow_1.…` —
do not match that prefix and **pass through untouched** (`infer_mlx.py:66`). So a file we own that
already carries the correct slot names loads correctly through the completely unmodified loader.
Verified empirically: all four slots fill.

| | shipped `base_f0G40k.npz` | corrected |
|---|---|---|
| flow slots filled | 18/19 · **0/19** · 18/19 · **0/19** | **18/19 · 18/19 · 18/19 · 18/19** |
| cross-process LSD (3 processes) | **0.4148** | **0.0045 · 0.0046 · 0.0047** |
| rms across processes | 0.034 / 0.029 (varies) | **0.1223 / 0.1223 / 0.1223** (stable) |
| peak | 0.24–0.29 | 0.656–0.659 |

**The reload floor collapses to exactly the within-engine floor (0.0045).** Reproducibility is fully
restored, which means every consequence drawn above — inaudible α steps, "auditioning the reload",
the downgrade of the blend feature — **is a consequence of the bug, not of the approach.**

⚠️ **What I have *not* proven: that the corrected model sounds *better*.** I proved it is
deterministic and that it uses all of the checkpoint's weights. The output differs from today's by
**LSD 1.06 — more than full speaker separation (0.95)**, and its level is ~4× higher, so this is not
a subtle change. The case that it is *correct* rests on: the vendored repo documenting `i//2` as the
required mapping; all four slots filling; determinism being restored; and 36 previously-discarded
tensors now being used. **Before shipping it, add a listening check and, if practical, a PyTorch
parity comparison** — the vendored `docs/INFERENCE_PARITY_ACHIEVED.md` claims 0.999847 correlation
for models converted the *documented* way, which is exactly the number a corrected build should be
able to reproduce and today's cannot.

⚠️ **This is not confined to the base model.** Any voice the user imports will be converted
`.pth`→`.npz` by m23-di-2b, and if that path uses `convert_pth_to_mlx.py` it inherits the identical
defect. **The mapping fix belongs in the import/conversion path, not just in one file.**

**Where the fix lives — outside the fence, by the §5.1 mechanism.** `server.py:282` resolves
`<voiceId>/model.npz` and `:177`'s `_scan_voices()` is a plain directory scan, so a corrected model
can be dropped into `<Application Support>/DAWPro/VoiceModels/` as an ordinary voice directory and
used with **zero sidecar changes and no path override**. The same trick §5.1 established for blends
delivers the correctness fix.

**The other route, still available:** never reload — do all blending in one warm engine with the row
rewritten in place (0.1 ms). That requires a per-request blend parameter and therefore a sidecar
surface (§6), and it is no longer necessary now that the floor is 0.0045.

**A discipline this imposes on whoever implements any of it:** *all* blend A/B comparison — in
tests, in gates, and in the UI — **must happen inside one engine instance.** A test that reloads
between conditions has a noise floor ~80× its own resolution and will produce confident nonsense, as
three of my own passes did.

---

## 6. The fence — cross-reference, not a new question

`docs/research/2026-08-10-realtime-vc-spike.md` **§7** already states this decision for the user,
sharpened, with three readings (A/B/C) and a recommendation. **m23-fd adds no new fence question and
must not be presented as one.** Mapping onto that §7:

| m23-fd need | Reading (A) — writes only are forbidden |
|---|---|
| Read/parse `.npz` from the voice store | already allowed; already what ships |
| `mx.load` / `mx.savez` (needs MLX ⇒ the vendored venv's interpreter) | allowed under (A) — `run.sh` already execs that interpreter |
| Write the derived `model.npz` | **outside the fence** — `<Application Support>/DAWPro/VoiceModels/` |
| **§2's `mx.clear_cache()` mitigation** | ~~needs `scripts/rvc/server.py`~~ — **CORRECTED: it does not.** Applies from a launcher we own, under (A). See §6.1. |
| A per-request blend parameter (live drag only) | same: either edit `server.py`, or a facade we own beside it, per m23-fc §7's `scripts/rvc-stream/` proposal |

### 6.1 CORRECTION — the §2 fix does *not* need a fenced write

An earlier draft of this spike (and of §2.4) claimed the `mx.clear_cache()` mitigation had to be
written into `scripts/rvc/server.py`, and made that the strongest argument for relaxing the fence.
**That was wrong, and it is the kind of wrong that would have pushed the user toward a decision they
did not need to make.** The reviewer caught it; I then verified the alternative mechanically.

The facade is **importable**, and its heavy import is **deferred**:

* `scripts/rvc/server.py:405` guards `uvicorn.run` behind `if __name__ == "__main__"`, so
  `import server` yields the configured `FastAPI` app (title *"DAW Pro RVC voice-conversion facade"*,
  routes `/health`, `/v1/voice/list`, `/v1/voice/{id}/status`, `/v1/voice/convert`, `/v1/voice/train`)
  **without binding a port**. Its `_engines` dict and `_engine_lock` are reachable.
* `server.py:102`'s `from rvc_mlx.infer.infer_mlx import RVC_MLX` sits **inside** `_load_engine`
  (`:97`–`:107`), i.e. it resolves at first use. A class-level patch applied beforehand is therefore
  picked up: I verified `importlib.import_module("rvc_mlx.infer.infer_mlx").RVC_MLX.infer` **is** the
  wrapper.

So a launcher **we own** can do:

```python
import server                     # scripts/rvc/server.py, unmodified — read only
from rvc_mlx.infer.infer_mlx import RVC_MLX
_orig = RVC_MLX.infer
def infer(self, *a, **k):
    mx.clear_cache()             # the §2 mitigation, in the proven position
    return _orig(self, *a, **k)
RVC_MLX.infer = infer
uvicorn.run(server.app, host="127.0.0.1", port=int(os.environ["RVC_API_PORT"]))
```

Patching the **class** (not FastAPI middleware) matters: `voice_convert` is a *sync* `def`
(`server.py:259`), so FastAPI dispatches it to a worker thread. The class patch runs in that same
thread, immediately before inference — exactly the position the §2 ABA experiment proved correct.
Middleware would run on the event loop instead.

**Cost, honestly.** `scripts/rvc/run.sh:71` ends with `exec "$VENV_PY" "$SCRIPT_DIR/server.py"`, and
`run.sh` is itself fenced, so the Swift side must spawn our launcher instead. Our launcher has to
replicate `run.sh`'s ~40 lines of setup: the `SRC_DIR`/venv existence checks (`:33`–`:42`), the
pidfile protocol (`:45`–`:54`, `:66`), `OMP_NUM_THREADS=1` (`:58` — the faiss segfault guard called
out at `server.py:41`/`:58`), `PYTHONUNBUFFERED`, `RVC_RUNTIME_DIR`, `RVC_API_PORT` defaulting to
8002, `cd "$SRC_DIR"`, and the log redirect. That is **straightforward, unglamorous, and entirely
outside the fence.**

⚠️ **One genuine wrinkle the implementer must not discover the hard way: mutual exclusion.**
`run.sh` guards against a double start with a pidfile at `scripts/rvc/.rvc.pid` (`:29`, `:45`–`:54`,
`:66`). If our launcher writes its pidfile somewhere we own, the two launchers **cannot see each
other**, and a user who starts the original `run.sh` while ours is running gets two facades
contending for 8002. Writing to `scripts/rvc/.rvc.pid` would be a **write under the fence**, so the
honest options are: (i) make mutual exclusion **port-based** — attempt a bind to 127.0.0.1:8002 and
refuse if it is taken, which is stronger than a pidfile anyway because it also catches a facade
started by any other means; or (ii) treat that one pidfile path as an explicitly-scoped exception and
put it to the user. **Recommend (i)** — it needs no exception, no ruling, and is more correct. The Swift spawn site already passes environment (it repoints `RVC_VOICES_DIR`
at every `vc.sidecarStart`), so nothing structural changes.

**What I did not verify:** I did **not** start a server or bind a port — 8002 is the user's sidecar.
So the patch *mechanism* is verified (import, deferred-import resolution, class patch) and the
`clear_cache` *placement* is verified (§2's ABA), but **the two have not been proven together
end-to-end over HTTP.** That is the first thing the follow-up item should do, on **17695-class
isolation**, never against a live sidecar.

**Consequence for the fence question: it gets smaller, not bigger.** m23-fd contributes *no* new
pressure to relax the fence. Blending needs no fenced file (§5.1); the §2 correctness fix needs no
fenced file either (this section). The only remaining fenced want is the **per-request blend
parameter** for a live drag — a feature §5.3 already recommends against building. **If the user is
inclined to answer (C) "change nothing under `scripts/rvc/`", nothing in this spike argues against
that.**

---

## 7. The honest alternatives, if interpolation is not available

Named because the brief asked for them by name, and because §4.3 may come back "ancestry does not
hold."

| approach | works across sr / version / pretrain? | cost | what it sounds like |
|---|---|---|---|
| **Convert twice, mix the results** | **Yes — always.** Each model loads with its own config. | 2× inference (RTF 35× ⇒ ~10 s for a 3-min take) | Unison doubling, not a morph. **But less phasey than mixing two singers:** both decoders are NSF generators excited from the **same** RMVPE f0 contour, so their harmonic structure is locked to a common source. Untested here — worth one experiment before dismissing. |
| **Convert twice, crossfade over time** | Yes | 2× inference | A handoff between voices, per region. Legitimate and honest. |
| **Pick one voice per region** | Yes | 1× | What the DAW already does with `vc.convertVocals` per clip. |
| **Weight-space blend (§4)** | No — requires matching sr, version, key sets, and (unverifiable) ancestry | 0.19 s to materialise | A genuine third timbre, when it works. |
| **Embedding blend (§3)** | Within one model only | 0.1 ms | A character knob on one voice. |

---

## 8. Sizing, and the recommendation

The roadmap says *"spike against the embedding/decoder surface before ANY sizing."* Done; here is
the sizing, split by outcome rather than given as one number.

| outcome | size | note |
|---|---|---|
| **§2 defect: make repeated conversion reproducible** | **S** (one line + a regression test), **and no longer gated on the fence** (§6.1) — plus ~40 lines of launcher we own | Affects shipped `vc.convertVocals` **today**. Highest value per unit of work in this whole area. **Do this first.** |
| ⭐⭐ **Flow-mapping defect: correct the `i//2` slot mapping** | **S** — the mapping is 4 lines; the work is packaging and proving | **ROOT-CAUSED AND FIXED IN THIS SPIKE (§5.3.1–2), no fence write.** Half the flow is randomly re-initialised on every load today. Restores cross-process reproducibility (0.4148 → **0.0045**) and unblocks everything below. Must also cover the m23-di-2b import path, or every user model inherits it. **Needs a listening check / PyTorch parity before shipping**, because the output changes by LSD 1.06. |
| "Blend up to 3 voices and **drag live**" (the item as written) | **NOT A SIZE — NO** | §5.3: the reload floor is ~3× a fine α step; a warm-engine blend parameter needs a sidecar surface (§6); and for user voices there is only one trained row to blend (§3.5). |
| **Create a blended voice** from two models sharing a pretrain, as a derived `model.npz` | **M**, gated on the flow-mapping fix landing | *Downgraded to conditional after the §5.3 reload-floor measurement, then restored once §5.3.1 root-caused that floor to a fixable bug.* With the fix, one α step is ~29× the reproducibility floor. Needs: npz-domain lerp, the §5.2 shape guard, the §4.3 ancestry check, index policy, a store entry, `vc.blendVoices` + MCP tool + tests. **Blocked behind m23-di-2b** (parents must be `ready`) and behind §2. |
| **"Voice character" knob** (blend within one model's rows) | **S–M** | Well-measured (§3), near-free, no ancestry problem — **but it is not the roadmap's feature** and needs the user to want *that*. Live-drag still needs the §6 surface. |
| Convert-twice-and-mix / crossfade | **S** | Always correct, no new science. The right fallback if §4.3 comes back negative. |

### Recommendation

1. **Do not start m23-fd.** Re-file the §2 defect as its own item — it is a shipped-path correctness
   bug found by this spike and it outranks the feature.
2. **Fix §2 now; it no longer needs the user's fence ruling** (§6.1). The mitigation lands in a
   launcher we own. Do not hold a correctness fix behind a design question it turned out not to have.
   *(The fence question itself still stands for m23-fc / m23-di-2b — it is just no longer this
   spike's business, and this spike adds no pressure to answer it either way.)*
2b. ⭐⭐ **File and fix the flow-mapping defect — this is the most valuable result in the spike, and
   it is not a blending issue at all** (§5.3.1). Every voice conversion the app has ever performed
   ran with two of four flow coupling layers randomly initialised and a third in the wrong slot. It
   is root-caused, the fix is verified, and it needs **no fenced write**. It must also be applied to
   the m23-di-2b `.pth`→`.npz` import path or every model the user imports inherits it.
   **Gate it behind a listening check**: the output changes by more than full speaker separation, so
   this is a quality change users will hear, not a silent internal correction.

3. **Rewrite m23-fd's text** with what is now known, and split it: the item currently conflates a
   thing that is cheap and real but mis-named (§3), a thing that is real but blocked and
   ancestry-dependent (§4), and a UX (live drag) that is not achievable (§5.3).
4. **Put one question to the user, once**, in plain terms:
   > *Blending two voice models only works if both were fine-tuned from the same starting model, and
   > we cannot tell that until we can look at real models — the machine has none. Which do you
   > actually want: (a) a "character" knob that morphs one voice's timbre, which is cheap and works
   > today; or (b) true A↔B blending between two models you loaded, which needs `.pth`→`.npz`
   > conversion first (m23-di-2b), needs your models to share a pretrain, and may just produce mush
   > when they don't? If (b), we would also need two of your real models to calibrate the check.*
5. If the answer is (b), **build the ancestry check first** as a standalone, cheap diagnostic
   (`vc.voiceModelInfo` reporting sr, version, speaker count, and pretrain-cosine against the base).
   It is a few hours, it is useful independently of blending, and it converts §4.3 from a guess into
   a measurement. **Do not build the blend before that check says yes on real files.**

---

## 9. Implementation plan — only if §2 is fixed, §5.3's floor collapses, and the user picks (b)

Do not begin any phase before **Phase −1 passes**. Phases −1 and 0 have **no fence dependency** and
deliver value on their own; everything from Phase 1 is conditional.

**Phase −1 — the two prerequisites, in this order. Neither is blend work.**

*(−1a) Fix §2, outside the fence.* Add a launcher we own — suggested `scripts/rvc-host/serve.py` plus
`scripts/rvc-host/run.sh` (a new directory; **nothing under `scripts/rvc/` is touched**) — that
replicates `run.sh`'s guards, pidfile, `OMP_NUM_THREADS=1`, log redirect and `RVC_API_PORT`, then
imports the unmodified facade and patches `RVC_MLX.infer` per §6.1. Repoint the Swift spawn site
(`Sources/DAWControl/Commands.swift`, near `:4691`) at it. **Prove it end-to-end over HTTP on a
staging port (17695-class isolation), which §6.1 explicitly did not do** — 8002 is the user's
sidecar; never convert against it.

*(−1b) Ship the flow-mapping fix (§5.3.1–2).* Apply `i//2` (`flow_0→flow_0, flow_2→flow_1,
flow_4→flow_2, flow_6→flow_3`) when producing any `.npz`, in **code we own**, and materialise the
corrected base as an ordinary voice directory so no sidecar path override is needed. Cover the
m23-di-2b import path in the same change. **Acceptance:** all four flow slots report 18/19 filled;
two freshly-spawned sidecars converting the same file agree to < 0.05 (they are at 0.41 today); and a
human confirms the new output sounds right, since it differs by LSD 1.06. **Do not skip the listening
step** — determinism and completeness are necessary, not sufficient. ⚠️ **Include clipping headroom
at realistic input levels in the acceptance:** the corrected model's rms is ~4× today's (0.1223 vs
0.034) and peak 0.656 vs 0.24. That is plausible for a correctly-conditioned latent, but it is also
the shape a scaling error would take, and a 4× level jump hitting a limiter is a user-visible
regression whether or not the timbre improved.

**Phase 0 — the diagnostic (no fence dependency; delivers value alone).**
`Sources/AIServices/VoiceModelInspector.swift` — pure-Swift zip/`.npy`-header reader (the format is
trivial; this spike read every shape reported here without numpy or MLX). Reports, per model:
`emb_g.weight` shape, `dec.ups.*` kernel sizes → sample rate, `enc_p.emb_phone.weight` → v1/v2,
and the per-row cosine of rows 1..108 against `base_f0G40k.npz`. Wire as `vc.voiceModelInfo`
(additive verb) + MCP tool + tests. **This is where §4.3 gets validated or refuted.**

**Phase 1 — the blender, in code we own.** A small module that loads two `.npz`, enforces
**shape-derived** architecture equality (§5.2), key-set equality, and an ancestry threshold, then
lerps and writes `<blendId>/model.npz` + `model.json` + `voice.json`. Never writes under
`scripts/rvc/`. Runs under the vendored venv per §6 reading (A).

**Phase 2 — control surface.** Additive only, never renaming live verbs: `vc.blendVoices`
(parents, weights, blendId) and `vc.deleteVoice` if no removal verb exists. Blends appear in
`vc.listVoices` with provenance so a 72.9 MB artifact is never mysterious.
⚠️ `Sources/DAWControl/Commands.swift` and `mcp-server/` are contended — coordinate before editing.

**Phase 3 — UI.** A *create-a-blend* affordance, not a live crossfader (§5.3). If a live control is
ever wanted, it needs the §6 warm-engine surface and should be re-designed then.

**RT-safety:** nothing here touches the render thread. This is file I/O plus a loopback HTTP call
into a subprocess, exactly like `vc.convertVocals`. The render thread never sees a model, a socket,
or an allocation from this feature. **No `AudioEngineProtocol` change; `DAWCore` is untouched.**

**Full Xcode / entitlements:** **none required.** No AUv3, no new entitlement, no signing change.
Xcode 26.6 is installed; do not quote "blocked: needs full Xcode" here.

### Test strategy

| level | test | where |
|---|---|---|
| Reproducibility (§2) | convert the same file 8× in one sidecar session; assert peak varies < 1 % — **must fail today**, which is the point | `scripts/` harness + a staging gate on **17695**, never 17600 |
| Reproducibility across loads (§5.3) | convert the same file from two freshly-spawned sidecars; assert the rep-averaged log-spectral distance < 0.05. **Must fail today at ~0.4** — if it passes before Phase −1b, the harness is broken, not the engine. | staging gate, two sequential spawns on **17695**, never 17600 |
| Format | shape-derived sr/version detection on fixtures; 48 kHz and v1 fixtures must be **refused**, not silently mis-loaded | `Tests/` |
| Ancestry | positive control mandatory: a deliberately foreign `emb_g` must drive the cosine below threshold. A checker that never rejects anything is indistinguishable from one that never ran. | `Tests/` |
| Round trip | `mx.load` → `savez` → `mx.load` is bit-exact over all 423 tensors (holds today; pin it) | python fixture |
| Blend maths | monotonicity of the α sweep, endpoints within the noise floor, level within ±10 % — **all comparisons inside ONE engine instance** (§5.3) | python fixture |
| Fence | assert no file under `scripts/rvc/` is created or modified by any blend operation, and that harnesses set `PYTHONDONTWRITEBYTECODE=1` | gate (⚠️ `scripts/gates/` is currently owned by another agent — coordinate) |

---

## 10. Contradictions and corrections, listed plainly

1. **The brief's hedge that `emb_g.weight.shape[0]` might be 1 does not fire** — it is 109, with 108
   distinct, genuinely-trained rows. The branch dies for a different reason (§3.5): those rows are
   the *pretrain's* speakers, not voices the user loaded.
2. **"Weight-space interpolation is generally meaningless" — the upstream ships it anyway**, with a
   CLI, guarded only on sample rate and key sets (§4.1). Its existence is evidence about practice;
   its guards are evidence about how little is actually checked.
3. **The brief expected the fence question to be about reaching into `scripts/rvc/`.** The real
   answer is better: **blending needs no fenced file at all** (§5.1). What *does* need one is the
   §2 one-line fix — which the brief could not have anticipated.
4. **Question 2 of the brief ("what would have to change, and on which side of the fence?") has a
   cleaner answer than expected:** nothing on the sidecar side. Everything on ours.
5. **A finding neither the brief nor I anticipated, and the most important one: the shipped
   conversion path is not reproducible and degrades to saturation within a single sidecar session**
   (§2). It was found only because measuring a blend forced me to build an instrument with a real
   noise floor — and my first three passes each produced confident, monotone-looking, *wrong*
   numbers before the positive control caught them.
6. **A methodological correction I owe the record.** My first probe reported "sid steers the decoder,
   blends are smooth" with plausible tables. It was garbage: the positive control (rewriting row 0
   with row 0 must reproduce `sid=0`) returned **corr +0.64** instead of 1.0. Every number in §3 is
   from the pass where that control returns **0.004**. *A blend sweep that looks monotone is not
   evidence the measurement is sound; the identity case is.*
7. **A second methodological trap worth recording**: my first stimulus was a synthetic glottal
   buzz that RMVPE scored **14 voiced frames out of 320**. The NSF excitation was therefore almost
   pure noise, and I was measuring the variance of noise while believing I was measuring a voice.
   **Check that the stimulus is voiced before trusting anything downstream of the pitch tracker.**
8. **I over-committed in the first draft, twice, and both were caught in review — recorded because
   the pattern matters more than the instances.**
   * I wrote that the derived-`model.npz` mechanism was **settled**, on the strength of a bit-exact
     round trip, while my own §5.3 already contained a number that undermined the *feature* built on
     it. **A verified mechanism is not a viable feature.** The follow-up measurement (§5.3) showed the
     reload floor is per-process and structural, and downgraded the M-sized option to conditional.
   * I wrote that the §2 fix required editing a fenced file, and made that the strongest argument in
     §6 for relaxing the fence. **It was false** (§6.1). Asking a user to loosen a safety boundary on
     the strength of an unverified claim about what the boundary blocks is the worst error in this
     document, and the only reason it did not ship is that someone asked me to check.
9. **The reviewer's guess and the measurement disagreed, and the measurement won.** The suggestion
   was that coarse α steps (0.25 / 0.5 / 0.75) would plausibly clear the reload floor. They do not:
   a 0.25 α gap moves the output ~0.26 against a floor of 0.37–0.45. Recorded so nobody re-derives
   the optimistic version from the same intuition.
10. **A hypothesis I raised and killed in the same pass** — that the reload floor came from the
   sidecar's `_engines` cache contaminating later engines within one process. Three separate
   processes, each building exactly one engine, disagree by the same 0.37–0.45. **Restarting the
   sidecar does not escape it**, which is what makes it a determinism problem rather than a
   lifecycle one.
11. ⭐⭐ **The largest correction in the document, and it inverts the recommendation for one item.**
   I wrote the reload floor up as a *limit* and sized the feature around it, offering a determinism
   experiment as a gate. Pressed on *why* I believed my own unchased attribution, I ran it — and the
   floor is a **bug in our model-build path** (§5.3.1), fixed and verified (§5.3.2). **A measured
   constraint that you have not explained is a symptom, not a limit.** I had the number for hours
   and treated it as physics.
12. **A false alarm the method caught before it reached this page.** Diffing checkpoint keys against
   `tree_flatten(parameters())` reports **834 of 1221 parameters unloaded**, including 449 in the
   decoder — a finding that would have read as "the shipped model is mostly random noise." It is an
   **alias artifact**: `dec.noise_convs.0.weight` and `dec.noise_conv_0.weight` are the same array.
   The behavioural test (which parameters actually *differ* between two constructions) says **60**,
   all in `flow`. **On this model, diff behaviour, never key sets** — and note that the wrong method
   over-reported by 14×, in the alarming direction.
13. **The two defects are independent, proven, not assumed.** Rerunning §2's no-`clear_cache` drift
   on the flow-corrected model degrades **identically** — same rep-5 onset, clipping 20.09 % vs
   20.11 %, 34.67 % vs 34.93 %, 40.65 % vs 40.67 %. Fixing either leaves the other standing, and the
   near-equal clipping fractions across two *materially different* models are themselves evidence
   that §2 is allocator/state, not weights.
14. **The roadmap item's own premise survives none of this intact.** m23-fd asks for live multi-voice
   morphing. What the spike found instead: the within-model branch is real but mis-named (§3.5), the
   cross-model branch is blocked and ancestry-unguarded (§4), the fence pressure the brief expected
   does not exist (§6.1), and the headline defect (§5.3.1) has nothing to do with blending. **The
   most useful thing a feasibility spike produced here was a bug report.**

---

## Appendix A — reproduction

Harnesses live in the session scratchpad (not checked in, deliberately not under `scripts/rvc/`):
`mkvowel.py` (the rights-clear stimulus), `blend_probe.py` / `blend_probe2.py` / `probe3.py`
(the three invalidated passes, kept because their failure modes are the lesson), `which_stage.py`,
`stages.py`, `stab.py`, `drift.py`, `noise0.py`, `aba.py` (§2's ABA), `probe4.py`, `probe5.py`
(§3's numbers), `derived.py`, `roundtrip.py` (§5), `npzshape.py` / `embstats.py` (pure-python
`.npz` shape and embedding statistics — **no numpy, no MLX, no vendored import at all**),
`instfloor.py` and `firstengine.py` (§5.3's warm-up and cross-process tables — `firstengine.py`
takes an engine-count argument and emits one JSON signature per process, so the cross-process
comparison is done by a separate pure-`python3` reducer), and `importable.py` / `patchproof.py` /
`attrib.py` (f0 cross-process identity + the misleading key-set diff), `gap.py` (the same diff
broken down by module, kept because its 834-parameter answer is **wrong** and shows how), `varies.py`
(§5.3.1's decisive two-construction diff — 60 params, all `flow`), `flowbug.py` (the slot-by-slot
fill table), `flowfix.py` (builds and measures the corrected npz — writes `base_flowfixed.npz` **to
the scratchpad**), `drift2.py` (proves §2 survives the flow fix), and
`importable.py` / `patchproof.py` / `patchproof2.py` (§6.1's import and class-patch verification — **these bind no port and start no
server**; `patchproof.py` is retained because it failed, by checking `server.RVC_MLX`, which does not
exist precisely because `server.py:102`'s import is deferred — the failure is what located the
mechanism).

Run shape:
`PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=1 scripts/rvc/runtime/src/.venv/bin/python <script>`
with `cwd` = the vendored `src` root, as `server.py:77` does.

Assets read: `rvc_mlx/models/checkpoints/base_f0G40k.npz`,
`rvc/models/embedders/contentvec/hubert_mlx.npz`, `rvc_mlx/models/predictors/rmvpe_mlx.npz`.
No sidecar was started; no audio device was opened, enumerated for capture, or contended for;
port 17600 was never touched; no third-party voice model was fetched.

The §2–§5.1 harnesses assert `"sounddevice" not in sys.modules` before and after every engine
construction, per the m23-fc §2 rule, and printed `FENCE-OK`. **Narrowing that claim honestly: the
later harnesses added for §5.3 and §6.1** (`attrib.py`, `gap.py`, `varies.py`, `flowbug.py`,
`flowfix.py`, `drift2.py`, `importable.py`, `patchproof*.py`) **carry no such assertion** — they were
written to answer a review question and I did not retrofit it. They import the same modules by the
same paths as the harnesses that *were* checked, and the whole-session fence audit below covers what
they touched on disk, but **the in-process `sounddevice` assertion applies to the earlier set only.**
Any harness that is promoted into `scripts/` should carry it.

## Appendix B — fence audit

Unlike the m23-fc session, **"write nothing there" was achieved literally.**

* `git status --porcelain scripts/rvc/` — **empty**.
* `find scripts/rvc -newermt "2026-08-10 00:00" -type f` returns 11 `.pyc` files, all timestamped
  **02:15:45–02:15:47**, plus `runtime/logs/rvc-facade.log` at **02:36:42**. This session's first
  artifact is timestamped **03:40:04**. All predate it; the six non-venv `.pyc`s are exactly the six
  m23-fc disclosed, and the log's last lines record a clean shutdown of pid 14239, not mine.
* Total `.pyc` under the tree: **3141** (mostly `.venv`), unchanged by this session.
* `PYTHONDONTWRITEBYTECODE=1` was set on every invocation of the vendored interpreter. It works;
  **it should be mandatory for any future work in this tree**, and m23-fc's closing recommendation
  is hereby confirmed empirically.
