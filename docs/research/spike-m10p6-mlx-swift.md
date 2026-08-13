# m10-p-6 — In-process Swift/MLX voice conversion: feasibility spike

**Date:** 2026-08-12 · **Scope:** research only, no app/engine code touched · **Route:** research-analyst

**Read-only fence honoured:** nothing was written inside `scripts/rvc/`, `scripts/rvc/runtime/`,
`scripts/ace-step/`, or `.env`. Everything cited from those trees was read, not modified.

---

## Verdict up front

**Yes, an in-process Swift/MLX voice-conversion engine is technically feasible — and much further
along than a green-field estimate would suggest, because a working reference implementation of
*this exact model* already exists.** The vendored fork at `scripts/rvc/runtime/src/` (which our
sidecar already runs) ships a second, independent port at
`Demos/iOS/RVCNative/RVCNativePackage/Sources/RVCNativeFeature/RVC/` — 17 Swift files including
`Synthesizer.swift`, `RMVPE.swift`, `HubertModel.swift`, `RVCInference.swift`,
`PthConverter.swift`, `IndexManager.swift`, and `FAISSIndexReader.swift` — built on **mlx-swift**
via `MLXNN`/`MLXRandom`/`MLXFFT`, with a macOS 14 SwiftPM target (`Demos/Mac/Package.swift`) that
already builds outside iOS. It demonstrates, empirically, that every neural-network primitive RVC
needs is available in mlx-swift, and that all four non-MLX Python dependencies (librosa, scipy,
pyworld, faiss) already have working native replacements in that same tree.

**What it does *not* demonstrate is correctness.** Its own documented number — 91.8% average
spectrogram correlation across five voice models — is measured **against Python MLX output, not
against PyTorch ground truth**, and the Python MLX side of that 2026-01 comparison had not yet
received the two audio-correctness fixes this team found and applied on 2026-08-13
(`CHANGELOG.md`): the `conv_transpose1d` Metal kernel defect and the flow `noise_scale` zeroed to
0.0 instead of 0.66666. The Swift port's generator calls **native, unchunked** `ConvTransposed1d`
(`RVCInference.swift:258`: *"dec.up_* uses native ConvTransposed1d, no .conv wrapper"*), on the same
`dec.ups` geometries the Python bug was measured on, with a validation clip (13.5 s → 540,000
output samples) that lands well past the 2^15-sample boundary where the Python bug bites. **Both
sides of the only parity number this port has ever published may share the same defect** — which
means 91.8% is not evidence of 91.8% correctness; it is evidence of two possibly-equally-wrong
implementations agreeing with each other.

**There are two distinct risks here, and they block different things.** The **license** on the
fork (no LICENSE file; `pyproject` claims MIT but GitHub reports `licenseInfo: null` —
`scripts/rvc-patches/README.md`) is the harder gate: it cannot be resolved by any amount of
engineering, and it blocks the cheap path — reusing or adapting the existing Swift port — outright,
independent of whether the port is correct. The **unvalidated correctness** question (does
mlx-swift's `ConvTransposed1d` share the Metal defect) is answerable by a cheap, well-specified
measurement (Takeaway 2 below) and blocks *committing to a full rewrite*, not *investigating one*.
Treat them accordingly: the license question needs a user ruling before any code is copied or
derived from `Demos/iOS/RVCNative`; the correctness question is a follow-up spike, not a blocker to
scoping one.

**Recommended next steps, in order:** (1) get a ruling on the fork's license before writing a line
of code that touches or is derived from `Demos/iOS/RVCNative`; (2) port the two known-good Python
correctness fixes (chunked `ConvTransposed1d`, `noise_scale = 0.66666`) into the Swift generator and
re-measure against PyTorch ground truth, not against unfixed Python MLX; (3) pin an exact mlx-swift
version/commit (the vendored package references a missing local path, `../Vendor/mlx-swift`, with no
lockfile entry — see "What I could not verify") and re-test the `BatchNorm` running-stats behavior
against that exact pin, because current `main`-branch mlx-swift source looks like it fixed the defect
the Swift port had to work around in January, and that discrepancy is unresolved; (4) scope the port
to the shipped default path only — `f0_method="rmvpe"` is hardcoded in `scripts/rvc/server.py:338`
with the comment *"only MLX-supported pitch method (spike)"* — which drops pyworld and CREPE/FCPE
entirely and removes real scope, not just risk.

---

## Q1 — mlx-swift op coverage

Verified two ways, both cited per row: **(source)** = mlx-swift `main`-branch Swift source or
generated docs, fetched today, 2026-08-12, exact commit not pinnable (see below) — a claim about a
moving target, not about the specific revision the vendored port was built against. **(vendored)** =
observed compiling and running in `Demos/iOS/RVCNative/RVCNativePackage`. This is pinned to
*something* — the unknown revision that actually built this port — which is weaker than a version
pin but stronger than an unbuilt doc claim: treat it as "empirically worked, on a revision we cannot
name," not as "works on current mlx-swift."

### MLX core ops

| op | status | Swift API | verified |
|---|---|---|---|
| `arange` | AVAILABLE | `MLX.arange(_:stop:step:dtype:stream:)` (six overloads, Int/Double) | (source) `Source/MLX/Factory.swift` |
| `array` | AVAILABLE | `MLXArray(...)` (init family) | (vendored) used everywhere, e.g. `AudioProcessor.swift:58` |
| `broadcast_to` | AVAILABLE | `MLX.broadcast(_:to:stream:)` | (source) `Source/MLX/Ops.swift`; (vendored) `AudioProcessor.swift:192` `MLX.broadcast(rms, to: [1, targetLength])` |
| `conv1d` | AVAILABLE | free function `conv1d(_:_:stride:padding:dilation:groups:stream:)`; layer form `MLXNN.Conv1d` | (source) Swift Package Index doc page for the free function; (vendored) `MLXNN.Conv1d` used throughout `Synthesizer.swift` |
| `conv_transpose2d` | AVAILABLE as **layer**, UNCLEAR as raw free function | `MLXNN.ConvTransposed2d` (layer) confirmed; a bare `conv_transpose2d(...)` free function was not directly confirmed in the fetched `Ops.swift` excerpt | (source) `Source/MLXNN/ConvolutionTransposed.swift`; (vendored) `AUDIO_QUALITY_FIX.md` §5 documents its use in RMVPE's decoder |
| `cumsum` | UNCLEAR | — | not found in fetched source excerpts; not used anywhere in the RVC pipeline (Python or Swift), so no vendored evidence either way |
| `eval` | AVAILABLE | `MLX.eval(_:)` | (vendored) `IndexManager.swift:56,70`, used per the port's own conversion-checklist docs |
| `exp` | AVAILABLE | `exp(_:stream:)` | (source) `Ops.swift`; (vendored) `Synthesizer.swift:383,385` (`exp(logs)`) |
| `expand_dims` | AVAILABLE | `.expandedDimensions(axis:)` (member) / free function | (vendored) used pervasively, e.g. `Synthesizer.swift:222,241,505` |
| `load` (safetensors/npz) | AVAILABLE | `MLX.loadArrays(url:)` | (vendored) `IndexManager.swift:59`; `docs/PYTORCH_MLX_SWIFT_DIFFERENCES.md` §5 |
| `matmul` | AVAILABLE | `MLX.matmul(_:_:)` | (vendored) `Synthesizer.swift:84,91`; `IndexManager.swift:119` |
| `maximum` | AVAILABLE | `MLX.maximum(_:_:stream:)` | (source) `Ops.swift`; (vendored) `AudioProcessor.swift:208-209,236` |
| `ones` | AVAILABLE | `MLX.ones(_:type:stream:)` / `.ones(like:)` | (source) `Source/MLX/Factory.swift`; (vendored) `IndexManagerTests.swift:28` `MLXArray.ones(...)` |
| `pad` | AVAILABLE | `MLX.padded(_:width(s):mode:value:stream:)` | (source) `Ops.swift`; (vendored) `Synthesizer.swift:121,127`, `AudioProcessor.swift:153` |
| `random.normal` | AVAILABLE | `MLXRandom.normal(_:type:loc:scale:key:stream:)` | (source) `Source/MLX/Random.swift`; (vendored) `Synthesizer.swift:514` |
| `random.uniform` | AVAILABLE | `MLXRandom.uniform(...)` (four overloads) | (source) `Source/MLX/Random.swift`; matches Python `rand_slice_segments`'s `mx.random.uniform` use in `commons.py:98` |
| `repeat` | AVAILABLE (name differs) | `MLX.repeated(_:count:axis:stream:)` | (source) partial confirmation via search of `Ops.swift`/`Ops+Array.swift`; not directly observed running in the vendored port (Python side avoids it too, using `broadcast_to` + `reshape` instead — see `pipeline_mlx.py:213`) |
| `sigmoid` | AVAILABLE | `sigmoid(_:stream:)` | (source) `Ops.swift`; (vendored) `Synthesizer.swift:315,320` |
| `sin` | AVAILABLE | `sin(_:stream:)` | (source) `Ops.swift`; (vendored, indirect) `Demos/iOS/AUDIO_QUALITY_FIX.md` §1 documents a `SineGenerator` random-phase fix in `RVCModel.swift` — RVC's NSF harmonic-source oscillator, which necessarily computes `sin` per-harmonic; the free function itself was not directly grepped in that file |
| `softmax` | AVAILABLE | `softmax(_:axis(es):precise:stream:)` | (source) `Ops.swift`; (vendored) `Synthesizer.swift:90` |
| `split` | UNCLEAR (as a free function) — functionally not needed | — | Python side calls `mx.split` (`encoders.py`); the Swift port never calls a `split` equivalent, using manual axis slicing instead (`Synthesizer.swift:236-237`). Whether a `split` free function exists was not confirmed in fetched source; irrelevant in practice since slicing covers every use case seen |
| `stack` | AVAILABLE | `stacked(_:axis:stream:)` | (source) `Ops.swift`; matches Python's `mx.stack` in `commons.py:73` (`slice_segments`) — no direct Swift-side call observed, but the op exists |
| `sum` | AVAILABLE | `MLX.sum(_:axis(es):keepDims:stream:)` | (vendored) `IndexManager.swift:120,149,165` |
| `tanh` | AVAILABLE | `tanh(_:stream:)` | (source) `Ops.swift`; (vendored) `Synthesizer.swift:314,319,383` |
| `where` | AVAILABLE | `MLX.where(_:_:_:)` | (vendored) `Synthesizer.swift:87` `MLX.where(mask .== 0, MLXArray(-1e4), scores)` — this is the strongest possible verification, since it is observed compiling and running in an attention-mask path structurally identical to what a port would need |
| `zeros` | AVAILABLE | `MLX.zeros(_:type:stream:)` | (source) `Source/MLX/Factory.swift` |
| `zeros_like` | AVAILABLE | `MLX.zeros(like:stream:)` | (source) `Source/MLX/Factory.swift`; (vendored) `Synthesizer.swift:290` `MLX.zeros(like: x)` |

### nn layers

| layer | status | Swift API | verified |
|---|---|---|---|
| `Conv1d` | AVAILABLE | `MLXNN.Conv1d(inputChannels:outputChannels:kernelSize:stride:padding:dilation:groups:bias:)` | (source) `Source/MLXNN/Convolution.swift`; (vendored) used ~15 times in `Synthesizer.swift` |
| `Conv2d` | AVAILABLE | `MLXNN.Conv2d(inputChannels:outputChannels:kernelSize:stride:padding:dilation:groups:bias:)` | (source) `Source/MLXNN/Convolution.swift`; (vendored) `rmvpe.py:72,76,81,218` (Python side) ported per `AUDIO_QUALITY_FIX.md` §5 |
| `ConvTranspose1d` | AVAILABLE — **exact symbol is `ConvTransposed1d`, past tense, not `ConvTranspose1d`** | `MLXNN.ConvTransposed1d(inputChannels:outputChannels:kernelSize:stride:padding:outputPadding:dilation:groups:bias:)` — note it natively supports `outputPadding`, which the Python `mlx.nn` binding used by the fork does **not** (`generators.py` comment: *"Apply output_padding manually (MLX doesn't support it natively)"*) | (source) `Source/MLXNN/ConvolutionTransposed.swift`; (vendored) `RVCInference.swift:258` names it directly (`dec.up_* uses native ConvTransposed1d, no .conv wrapper`) |
| `ConvTranspose2d` | AVAILABLE — same naming caveat, `ConvTransposed2d` | `MLXNN.ConvTransposed2d(...)` | (source) `Source/MLXNN/ConvolutionTransposed.swift`; (vendored) `AUDIO_QUALITY_FIX.md` §5 documents its use for RMVPE's decoder with a `(1,2,3,0)` weight transpose |
| `Linear` | AVAILABLE | `MLXNN.Linear(_:_:bias:)` | (vendored) `Synthesizer.swift:189,198` |
| `Embedding` | AVAILABLE | `MLXNN.Embedding(embeddingCount:dimensions:)` | (vendored) `Synthesizer.swift:199,493` |
| `LayerNorm` | AVAILABLE | `MLXNN.LayerNorm(dimensions:eps:affine:bias:)` | (source) `Source/MLXNN/Normalization.swift`; (vendored) `Synthesizer.swift:151,156` |
| `GroupNorm` | AVAILABLE | `MLXNN.GroupNorm(groupCount:dimensions:eps:affine:pytorchCompatible:)` — note the explicit `pytorchCompatible` flag, relevant because HuBERT's `HubertGroupNormConvLayer` (`hubert.py:216-231`) needs PyTorch-matching group statistics | (source) `Source/MLXNN/Normalization.swift` |
| `BatchNorm` | **AVAILABLE BUT HISTORICALLY DEFECTIVE — verify before trusting** | `MLXNN.BatchNorm(featureCount:eps:momentum:affine:trackRunningStats:)`; current `main`-branch source declares `@ParameterInfo(key: "running_mean") var runningMean: MLXArray?` and the same for `runningVar`, which on its face means running stats ARE tracked and loadable | **CONTRADICTS empirical evidence**: `Demos/iOS/BATCHNORM_FIX_VALIDATION.md` (dated 2026-01-07) documents that in whatever mlx-swift revision the Swift port used, `BatchNorm` did **not** expose `runningMean`/`runningVar` via `parameters()`, causing running stats to stay at their default init (mean=0, var=1) after `update(parameters:)`, and driving RMVPE's encoder to a signal explosion (1e18) and all-NaN F0 output. The team's fix was a hand-rolled `CustomBatchNorm` class. Either this was fixed upstream between Jan 2026 and now, or the defect is more subtle than "no `@ParameterInfo`" (e.g. an `Optional`-unwrapping or flattening bug in `update(parameters:)` itself). **This is exactly the class of regression a port must re-test empirically against its actual pinned mlx-swift commit before trusting weight loading, not infer from reading the class declaration.** |
| `AvgPool2d` | AVAILABLE | `MLXNN.AvgPool2d(kernelSize:stride:padding:)` | (source) `Source/MLXNN/Pooling.swift`; matches Python `rmvpe.py:106` `nn.AvgPool2d` |
| `Dropout` | AVAILABLE | `MLXNN.Dropout(p:)` | (vendored) `Synthesizer.swift:48,61,104,110,145` |
| `Sequential` | AVAILABLE | `MLXNN.Sequential(layers:)` | (source) `Source/MLXNN/Containers.swift` (not directly observed in the RVC port, which composes layers manually inside `callAsFunction`) |
| `GELU` | AVAILABLE | `gelu(_:approximate:)` free function / activation | (source) `Source/MLXNN/Activations.swift`; `docs/PYTORCH_MLX_SWIFT_DIFFERENCES.md` §7 documents `.none` for exact-match parity — not used by RVC's own architecture (it uses LeakyReLU/ReLU), so unexercised by this port |
| `LeakyReLU` | AVAILABLE | `leakyRelu(_:negativeSlope:)` | (vendored) `Synthesizer.swift:218`, `WaveNet` forward pass |
| `ReLU` | AVAILABLE (functional form only, observed) | `MLX.maximum(x, 0)` used directly in the port rather than an `nn.ReLU` layer | (vendored) `Synthesizer.swift:123` `MLX.maximum(h, MLXArray(0))  // ReLU` — the port uses the functional form; whether a distinct `nn.ReLU` layer class also exists was not checked |
| `Sigmoid` | AVAILABLE | `sigmoid(_:)` (functional; used directly, not as an `nn.Sigmoid()` layer) | (vendored) `Synthesizer.swift:90` (softmax path) and `:315` |
| `Tanh` | AVAILABLE | `tanh(_:)` (functional) | (vendored) `Synthesizer.swift:314,383` |
| `Module` | AVAILABLE | `MLXNN.Module` (base class, subclassed everywhere) | (vendored) every class in `Synthesizer.swift` |

### The ConvTranspose1d / conv_transpose2d Metal bug — does mlx-swift share it?

**What is proven, first-hand, dated:** `scripts/rvc-patches/README.md` and
`scripts/rvc-patches/generators.patch` document a bug this team measured directly (not inferred)
in **MLX Python 0.30.1**'s Metal `conv_transpose1d`: on the exact `dec.ups` geometries this
generator uses, output is silently wrong over a large, run-varying fraction of samples once
`L_out` exceeds 32768 (`2^15`) — and the boundary is **not monotone**: `L_out=32768` exact,
`L_out=32770` wrong (max diff 0.6), `L_out=400000`/`800000` exact again, `L_out=1844000` wrong
(49.8% of samples, corr 0.71). The wrong region carries the layer's bias value, and its exact
extent drifts run-to-run on identical input — consistent with a grid-coverage/race defect in the
Metal kernel dispatch, not a precision issue. **The CPU stream (`mx.stream(mx.cpu)`) is exact but
100–500× slower.** The fix applied (`conv_transpose1d_chunked` in `generators.patch`) splits every
dispatch to emit ≤16384 output samples and concatenates; verified exact (corr 1.000000).

**Whether mlx-swift's `ConvTransposed1d` shares this defect: UNCLEAR, but circumstantial evidence
points toward "probably yes, on the same geometries."** Reasons:
- mlx-swift binds the same C++/Metal core as MLX Python (`mlx-swift` is Swift bindings over
  `ml-explore/mlx`'s shared engine, not an independent reimplementation) — a kernel-dispatch bug in
  the shared Metal backend has no reason to be Python-only.
- The Swift RVC port calls **native, unchunked** `ConvTransposed1d` on precisely the geometries the
  Python bug was measured on (`dec.up_0` through `dec.up_3`, same `upsample_rates`/
  `upsample_kernel_sizes` as the Python generator, since both ports mirror the same PyTorch
  architecture) — its own code comment says `// dec.up_* uses native ConvTransposed1d, no .conv
  wrapper` (`RVCInference.swift:258`), i.e. explicitly *not* chunked.
- Its one published correlation number (91.8%, `docs/MLX_PYTHON_SWIFT_DIFFERENCES.md`) was measured
  against **Python MLX outputs from January 2026**, before this team's August fix existed. If Python
  MLX was wrong on that comparison's test clip (13.5 s → **540,000** output samples, comfortably
  past the 32768 boundary and inside the range the non-monotone table shows can go either way), the
  "ground truth" the Swift port was tuned against was itself corrupted, and 91.8% tells us about
  agreement between two potentially-wrong implementations, not correctness.
- I could not run the port to test this directly — no mlx-swift checkout is present locally (see
  below), and this task is research-only.

**What would settle it, and is a nearly-free confirmation step:** port `conv_transpose1d_chunked`'s
approach into Swift (the exact same algorithm — chunk to ≤16384 output samples, `MLX.concatenated`
the pieces — is directly expressible with the ops confirmed AVAILABLE above) and re-run the port's
own correlation harness (`compare_rvc_full.py` referenced in `CLAUDE.md`) against **PyTorch**, not
Python MLX. This is MODERATE effort (the fix is ~30 lines, all using confirmed-available ops), not a
blocker — but until it's done, **quality is unvalidated, not validated at 91.8%.**

No upstream GitHub issue matching this defect was found in a targeted search of
`ml-explore/mlx`'s issue tracker (searched 2026-08-12; found adjacent-but-different issues: #2180
performance, #2122 numerical discrepancy in a `ResidualUnit` Conv1d, #3327 arrays ≥2^31 elements
failing on Metal). This is consistent with — not proof of — `scripts/rvc-patches/README.md`'s own
claim that "neither defect has been reported upstream yet."

---

## Q2 — the four non-MLX dependencies

**Headline finding: all four already have working native replacements in the vendored Swift tree.**
This is not a proposal — it is an observation of code that exists, compiles, and (for the index
retrieval) has passing unit tests.

| dependency | replacement | difficulty | notes |
|---|---|---|---|
| **librosa** (audio load, resample, mel spectrogram, RMS) | `AVFoundation` (`AVAudioFile`, `AVAudioConverter`) for load/resample; hand-written MLX/Accelerate DSP for the rest | **EASY** — already done | `AudioProcessor.swift` (`Demos/iOS/RVCNative/.../RVC/AudioProcessor.swift`): `loadAudio` reads via `AVAudioFile`, downmixes to mono, resamples via `AVAudioConverter`. `calculateRMS` reimplements `librosa.feature.rms` as a `MLXNN.Conv1d` moving-average with unit weights (`weight = 1/frameLength`) — a neat trick that reuses the conv primitive instead of writing a separate sliding-window reduction. `DSPUtils.swift` separately reimplements STFT (manual reflect-padding + Hann window + `MLX.rfft`) and a Slaney-style mel filterbank from scratch, matching `librosa.feature.melspectrogram` + `power_to_db`. `Sources/DAWEngine` in the main app already has independent DSP/FFT code per the task's own framing — the two could likely share an FFT path rather than duplicating `DSPUtils.swift`'s (not independently cross-checked; see "what I could not verify"). |
| **scipy** — narrowed to what's *actually called*, not assumed | Butterworth high-pass: hand-coded biquad SOS cascade (Direct Form II), run forward then reversed for zero-phase, matching `scipy.signal.filtfilt` | **EASY on the shipped default path** | Grepped `rvc_mlx/lib/mlx/*.py` directly (task's own instruction) rather than inferring: only **`pipeline_mlx.py`** imports scipy at the top level (`from scipy import signal`), used for exactly one call: `signal.butter(5, 48, btype="high", fs=16000)` + `signal.filtfilt`. `rvc_mlx/lib/mlx/crepe.py` separately imports `scipy.ndimage.median_filter` and `uniform_filter1d`, but only inside the CREPE pitch-extraction path, which is **not the default and not what `server.py` calls** (see pyworld row). `AudioProcessor.swift:highPassFilter` already replaces the one default-path scipy call with hardcoded 5th-order Butterworth SOS coefficients (three cascaded sections) run forward-then-reverse — functionally identical to `filtfilt`, verified by the port's own doc comment citing the exact Python call it matches. |
| **pyworld** (C++ pitch extraction: DIO, PM, HARVEST) | N/A — **not on the shipped inference path at all** | **EASY (drop it)** | `rvc_mlx/lib/mlx/pitch_extractors.py` only imports `pyworld_pitch.PyWorldExtractor` **lazily**, inside `_init_pyworld()`, triggered only when `method in ("dio","pm","harvest")`. The default method is `"rmvpe"`. Confirmed at the call site that matters: `scripts/rvc/server.py:338` hardcodes `f0_method="rmvpe",  # only MLX-supported pitch method (spike)` — i.e. our own shipped facade never requests pyworld. A Swift port scoped to what the app actually ships needs zero pyworld replacement; RMVPE (already a working MLX/mlx-swift model per `RMVPE.swift`) is both the default and the only neural-native option already proven. |
| **faiss** (`model.index`, IVFFlat, `index_rate` default 0.75) | Native binary parser + brute-force MLX k-NN, **both already implemented and unit-tested** | **EASY — already done** | Confirmed the exact call site the task asked about: `scripts/rvc/server.py:293` sets `index_rate = 0.75 if index_path else 0.0`. `pipeline_mlx.py:183-201` calls `index.search(feats_np[0], k=8)`, then does its own weighted gather (`weight = 1/score²`, normalized, applied to `big_npy[ix]`) — **faiss itself only contributes approximate k-NN over IVF lists; the actual retrieval blend is already plain NumPy**, which is directly portable. The Swift tree has two purpose-built replacements with tests (`Tests/RVCNativeFeatureTests/{FAISSIndexReaderTests,IndexManagerTests}.swift`): **`FAISSIndexReader.swift`** parses the native `.index` file's binary layout directly (magic `"IwFl"` for IVFFlat, walks the `ArrayInvertedLists` structure via a reverse-engineered `"ilar"` marker) to extract every stored vector — no libfaiss needed at all. **`IndexManager.swift`** then does brute-force retrieval in pure MLX: `matmul` for the query-vs-all-vectors L2 distance, `MLX.argPartition` for top-k=8, then the identical inverse-squared-distance weighted blend as `pipeline_mlx.py`. **Size implication:** our 29 MB index at 768-dim float32 is ≈ 29,000,000 / (768×4) ≈ 9,400 vectors; a dense `matmul` of a 768-dim query against a 9.4k×768 matrix per frame is cheap (this is exactly what `IndexManager.search` already does, with no faiss dependency, no approximate index structure, and no accuracy loss versus brute force — it's *more* exact than faiss's IVF approximation, not less). |

---

## Q3 — AUv3 / VST3 packaging (plain answer)

**AUv3 app extensions can ship through the Mac App Store — bundled inside a container app — but the
extension process is bound by the exact same code-signing regime as the host, so it does not
sidestep the problem.** An Audio Unit v3 extension is an Apple-defined App Extension point; it ships
as part of the container app's submission and, like the container app, must be built with the
Hardened Runtime and pass Library Validation for Mac App Store distribution. The entitlement that
would let a process load arbitrary third-party-signed or unsigned dylibs —
`com.apple.security.cs.disable-library-validation` — exists precisely for cases like loading a
Python venv's 317 native dylibs, but granting it defeats the security guarantee App Review exists to
enforce, which is why it is treated as a high-scrutiny exception rather than a routine capability
request. Practically: an AUv3 extension that tried to shell out to and load a 172 MB libtorch-backed
venv would face the identical library-validation wall the host app faces today — plugin packaging
changes *where* the code lives, not *what constraints it runs under*.

**VST3 cannot be distributed through the Mac App Store at all, for two independent reasons — and
the first one is decisive on its own.** First and most simply: **VST3 is not an Apple-defined App
Extension point, so there is no App Store submission shape for a bare VST3 plugin at all** — the
Mac App Store distributes *apps* (and App Extensions embedded in them); a VST3 bundle is neither,
so there is no product category to submit it as, independent of sandboxing. Second, and only
relevant if the first objection were somehow worked around: a VST3 plugin must be installed into a
well-known filesystem location (`/Library/Audio/Plug-Ins/VST3` or the per-user equivalent) for other
hosts to discover it, which is a write outside any app's sandbox container — something the Mac App
Store sandboxing model does not permit from a sandboxed app without exactly the kind of temporary
exception entitlements that make this class of request difficult for App Review to grant. This is
independent of whatever the plugin's internal implementation is.

**So: packaging as a plugin is orthogonal to the Python problem, not a solution to it — confirmed by
our own team's conclusion.** `CHANGELOG.md`'s 2026-08-13 entry states this in the same terms
already: *"Not fixed: the Mac App Store. The voice engine is a 1.7 GB Python process, which the App
Store sandbox does not permit. Direct distribution works."* An AUv3 wrapper around the same Python
process would hit the identical wall; only removing the Python dependency (the in-process Swift/MLX
rewrite this spike evaluates) or abandoning the Mac App Store target changes the outcome.

---

## What I could NOT verify

- **The exact mlx-swift version/commit this project would build against.** `Package.swift` at
  `Demos/iOS/RVCNative/RVCNativePackage/Package.swift:18` references `.package(path:
  "../Vendor/mlx-swift")` — a **local path dependency**, and `Vendor/mlx-swift` does not exist
  anywhere in this checkout (confirmed by glob against the full tree). None of the three
  `Package.resolved` files found (`RVCNativePackage`, the `.xcworkspace`, `Demos/Mac`) contain an
  `mlx-swift` pin — only its transitive dependency `swift-numerics` (1.1.1) and `ZIPFoundation`
  (0.9.20) are pinned. **Every Q1 finding sourced from mlx-swift's `main` branch (fetched
  2026-08-12) is therefore an undated claim about a moving target, not a claim about the specific
  revision that produced the 91.8% correlation number** — those could be different commits months
  apart, and the `BatchNorm` discrepancy above is the concrete symptom of that gap.
- **Whether the `BatchNorm` running-stats defect is fixed in current mlx-swift, or whether the
  `CustomBatchNorm` workaround is still required.** Documented above as a direct contradiction
  between dated, empirical, first-party evidence (Jan 2026, NaN reproduced and fixed) and today's
  source-level read of `main`. I did not have a way to build and run mlx-swift to settle this and
  say so rather than picking a side.
- **Whether mlx-swift's `ConvTransposed1d`/`conv_transpose2d` actually reproduces the Metal
  correctness bug.** I could not run mlx-swift locally (no vendored copy, no network Swift Package
  fetch attempted — out of scope for a research-only task with no write access). The case for
  "probably yes" is circumstantial (shared C++/Metal core, same geometries, unchunked call site,
  confounded 91.8% baseline) but not a reproduction.
- **Raw free-function forms of `split`, `cumsum`, and `conv_transpose2d`** (as distinct from the
  `ConvTransposed2d` *layer*, which is confirmed). Fetched documentation excerpts were truncated by
  the fetch tool before reaching these symbols; I marked them UNCLEAR rather than assume parity with
  MLX Python's namespace. None of the three block a port: `split` and `cumsum` are unused anywhere in
  the RVC pipeline (Python or Swift), and the layer form of `ConvTransposed2d` is what RMVPE actually
  needs and is confirmed.
- **Whether `Sources/DAWEngine`'s existing DSP code (mentioned in the task as a given) actually
  overlaps with what `DSPUtils.swift`/`AudioProcessor.swift` would need to replace** — I read the
  vendored Swift DSP code but did not cross-check it line-for-line against `Sources/DAWEngine`'s FFT
  and resampling code, since that comparison wasn't requested and would be substantial scope on its
  own; flagging it as a real question for whoever scopes the actual port item.
- **Whether the AI-summarized WebFetch results for mlx-swift source files (used for most of the Q1
  table) are byte-exact.** The fetch tool paraphrases through a smaller model rather than returning
  raw text (its own documented behavior), and one direct attempt to get verbatim `BatchNorm` source
  was refused for length reasons. Where I could cross-check a WebFetch claim against locally-observed
  vendored Swift code actually compiling and running (marked "(vendored)" in the table), I trust that
  more than the WebFetch summary alone; rows sourced only from WebFetch carry that caveat.
- **A concrete performance number for Swift/MLX voice conversion.** Out of scope for this spike (it
  asked about op coverage and dependency replacement, not throughput), but relevant context exists
  from the adjacent `docs/research/2026-08-10-realtime-vc-spike.md`: that spike measured the Python
  MLX pipeline at RTF ≈38× warm on this machine and explicitly declined to pursue the Swift MLX port
  for latency reasons (§5, Option (c)), citing this same 91.8%-vs-99.98% quality gap.

---

## Actionable takeaways

1. **Do not adopt or derive code from `Demos/iOS/RVCNative` until the fork's license is resolved.**
   `scripts/rvc-patches/README.md` already flags `licenseInfo: null` against a claimed-MIT
   `pyproject`. This blocks the cheapest path (copy-and-fix the existing Swift port) independent of
   the technical findings above, and it is not an engineering question — it needs a user ruling
   before any m10-p-6-adjacent item touches that directory's contents rather than just reading them,
   per the existing fence discipline established for `scripts/rvc/` itself.
2. **File a follow-up spike (not a build item yet): port the two known Python correctness fixes into
   the vendored Swift generator and re-measure against PyTorch, not Python MLX.** This directly
   answers the open question in Q1 (does mlx-swift share the Metal `conv_transpose1d` defect) with a
   real measurement instead of circumstantial reasoning, and it's cheap — the chunking algorithm and
   the noise-scale fix are both small, and every op they need is confirmed AVAILABLE above. Unlike
   the license question, this one does *not* need a user ruling to start — it's an investigation, not
   a commitment. It should happen *before* any ROADMAP item commits engineering time to a full
   in-process rewrite, since it is the one measurement that could downgrade the verdict from
   "feasible" to "feasible but currently produces worse audio than the Python path we already ship."
3. **If/when a Swift/MLX port is scoped as a real ROADMAP item, scope it to the shipped default
   path, not full parity with the Python fork.** Concretely: `f0_method="rmvpe"` only (drop pyworld,
   CREPE, FCPE entirely — they're not reachable from `server.py` today); reuse `IndexManager.swift`
   + `FAISSIndexReader.swift`'s approach for retrieval (already correct, already tested, and more
   exact than faiss's IVF approximation since it's brute-force over ~9.4k vectors); reuse
   `AudioProcessor.swift`'s AVFoundation-based load/resample and hand-rolled Butterworth filter
   rather than re-deriving them. This is a meaningfully smaller scope than "port the whole fork" —
   and note takeaway 1 still applies to all of this reused code.
4. **Pin the mlx-swift version before writing a single line against it, and re-verify `BatchNorm`
   against that exact pin.** The vendored port's `../Vendor/mlx-swift` local-path dependency with no
   lockfile entry is itself worth flagging as a packaging anti-pattern to avoid repeating — any real
   port should depend on a tagged mlx-swift release (current latest observed: 0.31.6, 2026-07-02) via
   normal SwiftPM remote resolution, not a local vendor copy that can silently drift.
5. **AUv3/VST3 packaging is a dead end for solving the App Store problem specifically** — do not
   revisit "ship VC as a plugin" as a way around library validation; it inherits the identical
   constraint. If Mac App Store distribution is a hard requirement, the in-process Swift/MLX rewrite
   (pending the license and correctness questions above) is the only path that changes the outcome;
   the alternative is accepting direct/Developer-ID distribution for this feature, which
   `CHANGELOG.md` already states works today.
6. **This spike's existence should be cross-referenced from `docs/research/2026-08-10-realtime-vc-spike.md` §5 Option (c)**, which independently found and flagged the same vendored Swift port for
   different reasons (real-time monitoring latency, not App Store packaging) and recorded the same
   91.8%-vs-99.98% quality gap with a "revisit trigger" condition. The two spikes now corroborate
   each other on quality; neither has yet re-measured against PyTorch ground truth post-fix.

---

## Independent verification of the vendored Swift port (main context, 2026-08-13)

Everything below was measured directly, not taken from the agent report above.

### The port reproduces BOTH defects we fixed on 2026-08-13

**Bug 2 — noise_scale. CONFIRMED PRESENT, verbatim.**
`Demos/iOS/RVCNative/RVCNativePackage/Sources/RVCNativeFeature/RVC/Synthesizer.swift:514`

```swift
let z_p = (m_p + exp(logs_p) * MLXRandom.normal(m_p.shape).asType(m_p.dtype) * 0.0) * xMask
```

`* 0.0` is the exact defect that produced the metallic ringing the user reported and that
`scripts/rvc-patches/synthesizers.py` corrects to the RVC PyTorch reference `0.66666`.

**Bug 1 — conv_transpose chunking. ABSENT.** `RVCModel.swift:257-260,312-318` declare four
`MLXNN.ConvTransposed1d` layers and call them directly. There is no chunking anywhere in the
port, so if mlx-swift shares MLX's Metal kernels it inherits the >2^15-sample bug too.

### Why it reproduces them — the goal was parity with the broken implementation

`Demos/iOS/iOS_REWRITE_PLAN.md:4` states the goal as *"exact parity to Python MLX
implementation (0.986 correlation)"*. That Python MLX implementation is the one we proved
carries both defects. **A high correlation score against it is evidence the port is
FAITHFUL, not evidence it is CORRECT.** Any parity figure quoted for this port — 0.986,
91.8%, any other — measures agreement with broken audio and must not be read as quality.

### Its own validation is unfinished

41 of 55 checkboxes ticked; **14 unticked**, and the unticked ones are the audio-correctness
ones: `- [ ] Compute correlation`, `- [ ] Target: 0.986+ correlation`, and
`- [ ] Spectrogram correlation >= 0.98 (objective)` — the last marked **"Next step"**.

### ⚠️ The project law that applies here

**"THE CODE EXISTS" AND "THE CAPABILITY EXISTS" ARE DIFFERENT CLAIMS** (earned at m23-fc).
The realtime spike found `rvc_mlx/realtime/` the same way — a directory listing and a
websocket route — and reported a capability; execution then showed a decoder-shape bug
making output exactly `0.0` on every block. **This Swift port has NOT been run by us.**
Nothing above should be read as "a working port exists"; what exists is 38 Swift files whose
authors did not finish validating them.

### What is genuinely valuable here

The four Python dependencies really do have native replacements, and those are the expensive
part of any port: `AudioProcessor.swift` (15.4 KB) and `DSPUtils.swift` (6.1 KB) for
librosa/scipy, and `FAISSIndexReader.swift` (6.7 KB) + `IndexManager.swift` (7.2 KB) for
faiss — a native `.index` parser plus brute-force MLX k-NN. `Package.swift` declares
mlx-swift. pyworld is confirmed off the default path (`scripts/rvc/server.py:338` hardcodes
`f0_method="rmvpe"`).

### Blocking risk: license

No LICENSE / COPYING file at the fork root (measured). `pyproject.toml:7` claims
`license = { text = "MIT" }`; GitHub reports `licenseInfo: null`. Reusing this Swift code in
a shipped product needs a ruling from the user. Reading it is not at issue; vendoring or
deriving from it is.

---

## ⭐ USER RULING 2026-08-13 — the license question is RESOLVED. Do not re-raise it.

The user checked the chain themselves (I asked them to; they did) and ruled: **Applio is MIT,
and the fork is MIT.** Evidence, three converging sources against one absent file:

1. **[Applio](https://github.com/IAHispano/Applio) is MIT** — the upstream this is a fork of
   (`scripts/rvc/runtime/src/README.md:16` states the fork relationship in its own words).
2. **`scripts/rvc/runtime/src/pyproject.toml:7`** — `license = { text = "MIT" }`.
3. The user's own lookup of the fork.

Against: no LICENSE/COPYING file at the fork root at our pinned commit
`eec7791a59eb09d0f56f1189df55e9852848e692` (measured by me), and GitHub's API reporting
`licenseInfo: null`. **Read as the fork failing MIT's own notice-retention requirement, not
as a restriction on the code.** MIT-licensed work stays MIT-licensed downstream.

### What this UNBLOCKS

Porting to Swift, deriving from the vendored Swift tree, and redistributing — all permitted.

### What it OBLIGES — the one real cost, and it is cheap

MIT requires the copyright notice and permission text be retained in redistributions. Since
the fork ships no LICENSE file, **our attribution must credit Applio (IAHispano) and
[RVC-Project/Retrieval-based-Voice-Conversion-WebUI](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI)
directly rather than pointing at the fork's file, which does not exist.** That is a cleaner
position anyway. Any shipped build carrying ported code needs those notices.

### Why this was never urgent until now (context, still true)

`scripts/rvc/install.sh:155` does a `git clone` **on the user's machine**, directly from
GitHub — we ship a URL and a commit hash, not the code. We are not currently a redistributor.
Bundling the runtime, embedding the Swift port, or shipping a derivative all change that.

---

## ⭐ Q1's UNCLEAR item RESOLVED by measurement — the Metal bug is FIXED in MLX 0.31.2

The report above marked "does mlx-swift inherit the conv_transpose1d Metal bug" as UNCLEAR
but circumstantially likely. **Measured 2026-08-13. It is fixed, and the answer flips the
conclusion.**

### Method

Exact geometry from `scripts/rvc-patches/README.md` (64→32, K=4, S=2, P=1, `L_out = 2·L_in`),
GPU vs MLX's **own CPU stream** as ground truth, across three MLX versions installed into the
scratchpad (never into the fenced venv). Tolerance 0.05 — chosen to sit above measured fp32
GPU/CPU drift (~0.005) and far below the bug's magnitude (~3–7).

### Result

| MLX | 32 768 | 32 770 | 400 000 | 1 844 000 |
|---|---|---|---|---|
| **0.30.1** | 0.0045 | **3.4587** | 0.0053 | **7.0797** |
| **0.31.2** | 0.0045 | 0.0049 | 0.0053 | 0.0053 |
| **0.32.0** | 0.0045 | 0.0049 | 0.0053 | 0.0053 |

0.30.1 reproduces our original finding exactly — a ~1000× jump at precisely the two sizes
predicted, and only those. 0.31.2 and 0.32.0 are flat at fp32-drift level everywhere.

### Consequences

1. **mlx-swift 0.31.6 binds a ≥0.31 core, so a Swift port almost certainly does NOT inherit
   this bug.** One less thing to port. (Confirm directly once a Swift target can run — see
   the tooling note below.)
2. **`conv_transpose1d_chunked` is a pinned-version workaround, not a permanent fix.** It is
   needed only while `scripts/rvc/install.sh` builds on MLX 0.30.1. Bumping MLX would let us
   delete it and recover 36–94 ms. ⛔ `install.sh` is INSIDE the read-only fence — the user's
   call, and the fork's own version pin needs testing first.
3. **No upstream MLX bug report is warranted.** Already fixed. This closes the "contribute
   back" thread for bug 1. **Bug 2 (the fork's zeroed `noise_scale`) is unaffected by any MLX
   version and still stands as the fork's own defect.**

### Two method failures worth keeping

⚠️ **A PYTHONPATH that "obviously" overrides can silently not.** `mlx` is a NAMESPACE package,
so `pip install --upgrade --target` of the companion `mlx-metal` REPLACED the `mlx/` directory
and dropped `core.cpython-311-darwin.so`; the namespace then merged straight through to the
venv's 0.30.1. Three runs printed identical tables. **Only because the probe printed
`mx.__version__` on every run was this caught** — otherwise it would have been recorded as
"the bug is unfixed in all three versions", the exact opposite of the truth. **PRINT THE
IDENTITY OF THE THING UNDER TEST, NOT JUST ITS RESULT.** Fix: install `mlx` and `mlx-metal`
in ONE pip resolution into a FRESH target dir.

⚠️ **A control is only a control at the right scale.** Raising the tolerance from 1e-3 to 0.05
made CONTROL A's +0.01 perturbation fall below threshold, and the probe correctly refused to
run. That is the control working. Perturbation raised to +0.5.

### Tooling note — mlx-swift could not be exercised from a bare SwiftPM CLI

`swift build` of an executable depending on mlx-swift 0.31.6 succeeds, but running it fails
with `Failed to load the default metallib`: no `.metallib` is emitted for a plain CLI target
(Xcode 26.6 and `xcrun metal` ARE present, so this is packaging, not a missing toolchain).
Irrelevant to a real `.app`, which carries the metallib as a bundle resource — but it means
any Swift-side verification must run from a bundled target, not `swift run`. Probe kept at
`<scratchpad>/convtprobe/` for whoever picks the port up.

---

## ⭐ PROOF OF LIFE — mlx-swift RUN against our real production weights, 2026-08-13

Not a paper exercise: this loads the **actual shipped voice model** and reproduces MLX
Python's numerics on a **real RVC layer**. Result: **PASS, bit-exact.**

```
STEP 1  model.safetensors: 353 tensors
        CONTROL B PASS — dec.up_0.weight [256, 16, 512] float16, 353 tensors
STEP 2  x [1, 2048, 512] float16   expected-y [1, 16384, 256] float16
STEP 3  CONTROL A PASS — detects a planted 0.25 delta (saw 0.25048828)
        swift-vs-python max abs diff = 0.0   (tolerance 0.01)
```

`dec.up_0` is the generator's first ConvTranspose1d (256 out, K=16, 512 in), run at
stride 8 / padding 4 on an input MLX Python had already run and saved. **Diff is exactly
0.0 — not "within tolerance", identical** — because both bind the same C++ kernels.
Source: `<scratchpad>/convtprobe/Sources/parityprobe/main.swift`.

### Three concrete findings the port must handle

**1. ⚠️ mlx-swift CANNOT READ `.npz`. Our entire weight corpus is `.npz`.**
`IO.swift:75,130` accept `npy` (single array) and `safetensors` (dict) only; `.npz` throws
`unknownExtension("npz")`. Affects everything: `hubert_mlx.npz` (361 MB), `rmvpe_mlx.npz`
(173 MB), `base_f0G40k.npz` (70 MB), and every per-voice `model.npz`.
**Cheap fix, measured:** `mx.save_safetensors` converted all 353 tensors in **0.02 s**,
52.6 MB → 52.5 MB. safetensors is also the better format (mmap-able, no pickle). Needs a
one-time conversion step plus a migration for voices users already have.

**2. ⚠️ A bare SwiftPM CLI target emits no metallib, and MLX needs one even for CPU.**
`Device.setDefault(device: .cpu)` still fails (`stream.cpp:106`) — Metal initialises
eagerly, so CPU-only does NOT dodge it. `Package.swift:203` defines
`METAL_PATH="default.metallib"`; 49 `.metal` sources exist but `swift build` never compiles
them (Xcode 26.6 and `xcrun metal` ARE present — packaging, not toolchain).
**Workaround used here:** copy `mlx.metallib` (150 MB) out of the Python `mlx-metal` wheel
next to the binary. Cross-version worked — mlx-swift **0.31.6** with the metallib from
Python mlx **0.31.2**. A real `.app` must ship the metallib as a bundle resource; add it to
`scripts/bundle.sh` when the port starts.

**3. Weights are float16**, and parity holds at that dtype through a K=16 × C_in=512
reduction. No dtype promotion needed.

### What this does and does NOT establish

**Does:** the format path, the dtype path, the op API, and numerical parity are all sound.
mlx-swift is a viable foundation and the ops are not merely present on paper — one real
layer, real weights, exact agreement.

**Does not:** this is ONE layer. HuBERT, RMVPE, the flow, the NSF source module and the
full generator stack remain unported, and the audio-domain work (librosa/scipy replacement)
is untouched by this test. Treat it as "the foundation holds", not "the port is easy".
