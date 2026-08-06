# m23-ap-1 — SwiftF0 in-process route spike

**Date:** 2026-08-05 · **Author:** `daw-architect` · **Status:** SPIKE COMPLETE — **awaiting one user decision** (§3)

> **Scope guard.** This document ships a decision, not code. Nothing was vendored, added to
> `Package.swift`, or committed. Every artefact measured below lives in the session scratchpad
> `/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/73c8163a-27b5-48fc-94b9-8e63836c64d7/scratchpad`
> and is disposable. The detector pick (SwiftF0, `lars76/swift-f0`, MIT) is the user's, already made.
> **The route is not yet theirs to have made — that is what §3 asks.**

Read alongside `docs/research/m23-q-pitch-correction-design.md` **§5.6**, which this spike re-costs
rather than re-derives. §4 lists what in §5.6 this spike found stale or wrong.

---

## 0. The answer in five lines

| | Route A — ONNX Runtime in-process | Route B — Core ML |
|---|---|---|
| **Does it work on this machine?** | **YES — built and ran it.** 220 Hz sine in, 220.8 Hz out, from a plain `swift build -c release`. | **YES, but only via a route §5.6 did not anticipate** (§2.2). |
| **Added bundle size** | **+32,139,248 B (30.65 MiB)** measured link delta | **+4,610,892 B (4.40 MiB)** compiled artefact, zero link delta |
| **Fidelity vs upstream** | **exact** (it *is* upstream) | **median 0.92 ¢, p99 6.51 ¢, max 6.60 ¢** on voiced frames |
| **What we own forever** | one MIT SPM dependency | a Python re-authoring script + a converted artefact |
| **Recommendation** | ⭐ **GO** | keep as the costed escape hatch |

**One-line size statement, as asked:** *Route A, and it costs **+30.7 MiB on a 38.3 MiB app** — the
bundle goes **38.3 MiB → 69.0 MiB**.*

> **Units, stated once so the two figures below reconcile.** Every raw number in this document is
> **bytes**. `MiB = bytes / 1024²`, which is what `du -sh` prints and therefore what the roadmap's
> *"38 MB"* actually means. The Route A delta is **32,139,248 B** = **30.65 MiB** = 32.14 MB decimal.
> When this document says "MB" in prose aimed at the user, read MiB.

---

## 1. Route A — ONNX Runtime in-process. VERIFIED, END TO END.

### 1.1 It builds and runs with no Xcode-specific step at all

I created a throwaway SwiftPM package in the scratchpad (`sizelab/ortapp/`) depending on
`https://github.com/microsoft/onnxruntime-swift-package-manager` at `exact: "1.24.2"`, and a matched
empty baseline package (`sizelab/baseline/`). Both built with plain `swift build -c release` — the
exact command `scripts/bundle.sh:82` runs.

```
[13/16] Archiving libonnxruntime.a
[16/17] Linking OrtApp
Build complete! (10.21s)
```

Running it against the real SwiftF0 weights, on a deterministic 1.0 s / 16 kHz / 220 Hz sine:

```
pitch_hz   shape=[1, 62] head=[222.035767, 221.137726, 220.923706, 220.820755, 220.754318]
confidence shape=[1, 62] head=[  0.828395,   0.929840,   0.936354,   0.914802,   0.882783]
```

62 frames for 1.0 s is exactly `HOP_LENGTH = 256` at 16 kHz (§5.6.6's 62.5 fps), and the pitch is
correct. **Positive/negative control:** the same binary given a non-existent model path fails loudly
with `Error Domain=onnxruntime Code=3 ... File doesn't exist` — so the success above is a real load,
not a silent no-op.

**This is the single most consequential finding for Route A, and it contradicts §5.6.6's assumption.**
The ORT SPM product is declared `type: .static`; SwiftPM's `binaryTarget` unpacks the pod archive and
the linker folds it into the executable. There is **no `Frameworks/` directory, no dylib, no
`@rpath`, no embedded xcframework step, and therefore no library-validation entitlement question.**
`dist/DAWPro.app` today has **no `Contents/Frameworks` at all** (only `MacOS/`, `Resources/`,
`_CodeSignature/`, `Info.plist`, `PkgInfo`) and a single static `MacOS/DAWApp`; Route A does not
change that shape. **Route A needs no full-Xcode step. Route B does** (§2.4).

### 1.2 The artefact chain, measured

| Thing | Bytes | How I know |
|---|---|---|
| `pod-archive-onnxruntime-c-1.24.2.zip` (what SwiftPM fetches) | **52,138,597** | `curl -I`; downloaded it |
| its SHA256 | `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54` | `shasum -a 256` — **matches the checksum pinned in ORT's own `Package.swift` byte for byte**, so the thing I measured is the thing SwiftPM would resolve |
| licence, inside the pod archive | **MIT** (`Copyright (c) Microsoft Corporation`) | read the `LICENSE` in the unzipped archive, and the SPM repo's own `LICENSE` — both MIT (*negative control:* `LICENSE-NOPE` → 404). SwiftF0's `LICENSE` re-read the same way: **MIT, `Copyright (c) 2025 Lars Nieradzik`** |
| unzipped `onnxruntime.xcframework` | 213,864 KB (3 slices: ios-arm64, ios-sim, macos) | `du -k` |
| macOS slice, fat `ar` archive (arm64 + x86_64) | 90,585,848 | `stat` |
| macOS slice **thinned to arm64** | **41,319,240** | `lipo -thin arm64` |

### 1.3 The number that actually matters: the link delta

| Binary | Unstripped | `strip -x` |
|---|---|---|
| baseline (no ORT) | 53,784 | 51,984 |
| identical program **+ ORT session + inference** | 32,193,032 | 20,872,176 |
| **DELTA** | **32,139,248 B = 30.65 MiB** | **20,820,192 B = 19.86 MiB** |

**The delta is a ceiling, not a floor.** A session-only build (create env, open model, read tensor names,
never run) measured 32,167,528 B; adding full inference added **25,504 B**. ORT's kernel registry is
pulled in wholesale by session construction, so using *more* of ORT costs essentially nothing more.
That is unusual and it is good news: the number above will not drift upward as the detector grows.

`size -m` on the linked binary: `__TEXT` 19,791,872 of which `__text` 17,051,856 — **~17 MB is real
machine code**; the remaining ~12 MB of the unstripped delta is symbol and string tables.

### 1.4 Against the app as it ships today

| | Bytes | MiB |
|---|---|---|
| `dist/DAWPro.app/Contents/MacOS/DAWApp` today | 37,773,376 | 36.02 |
| `dist/DAWPro.app` total bundle today | 40,183,077 | **38.32** |
| bundle **with Route A** (today's unstripped pipeline) | 72,322,325 | **68.97** |
| SwiftF0 weights, committed alongside | 397,987 | 0.38 |

**+80% on the bundle.** The weights are a rounding error, exactly as the roadmap says — at 397,987 B
(SHA256 `7e2390db8379cd9e1e2b22828e55b45b57c8559e4c8335678c717dc245c18176`) they are committed as a
SwiftPM resource. **No download installer. `ai.installSpeechModel` is not touched.**

> **Free 20 MB, unrelated to this decision but found while measuring:** `scripts/bundle.sh` does not
> strip. `strip -x` takes today's `DAWApp` from 37,773,376 → **17,175,136 B**. If we ever want the
> app smaller, that is a 20.6 MB win for one line, and it is *larger* than anything this spike is
> arguing about. It must run before `codesign` (bundle.sh:155). **Filed as a separate item; not part
> of this decision.** With stripping in place the Route A delta is 19.86 MiB, not 30.65.

### 1.5 Is there a smaller prebuilt runtime? No — and here is the check that would have found one

`onnxruntime-mobile-c` is the reduced pod §5.6.6 gestures at. Probing `download.onnxruntime.ai`:

| version | `onnxruntime-mobile-c` | `onnxruntime-c` |
|---|---|---|
| 1.24.2 (what the SPM package pins) | **404** | 200 — 52,138,597 |
| 1.20.0 | **404** | 200 — 44,218,716 |
| 1.19.0 | **404** | 200 — 46,478,256 |
| **1.17.0** | **200 — 11,315,125** | 200 — 40,771,813 |
| 1.16.0 | 200 — 21,711,599 | 200 — 49,481,986 |
| 1.14.0 | 200 — 19,798,299 | 200 — 46,049,985 |

**The mobile pod existed and was 11.3 MB at 1.17.0, then was discontinued.** That is the positive
control: the URL scheme is right and the 404 at 1.24.2 is a real absence, not a typo. Pinning ORT
1.17.0 to get the small pod would mean shipping a runtime two years behind on security fixes — not
recommended, but it is a genuine lever if size ever becomes binding.

**The other reduced-size lever is a from-source custom build** (`--minimal_build`,
`--include_ops_by_config` against our 26 op types). Not measured — it requires building ORT from
source, and it means owning that build and repeating it at every ORT bump. **Do not adopt it to save
20 MB on a locally-installed app.** Named so nobody has to rediscover that it exists.

### 1.6 API facts the implementer needs (read from the vendored headers, first-hand)

- `ORTSessionOptions.setIntraOpNumThreads:` exists (`objectivec/include/ort_session.h:134`).
  **Pin it to 1.** ORT's default intra-op pool sizes to the core count and would contend with the
  audio thread. This is the RT-adjacent control and it is not optional.
- `setGraphOptimizationLevel:` (`ort_session.h:144`) and `setLogSeverityLevel:` (`:174`) exist.
- `appendCoreMLExecutionProviderWithOptionsV2:` exists (`ort_coreml_execution_provider.h:87`).
  **Route A does not forfeit the ANE** — ORT can dispatch to Core ML from inside itself. This
  weakens the "Core ML is the native path" argument for Route B considerably.

---

## 2. Route B — Core ML. The obvious chain is dead; a different one works, and I proved it.

### 2.1 The two blockers, verified first-hand, each with a positive control

**(a) coremltools 9.0 has no ONNX frontend.** `ct.converters` exposes
`ClassifierConfig, ColorLayout, EnumeratedShapes, ImageType, RangeDim, Shape, StateType, TensorType,
convert, libsvm, mil, sklearn, xgboost`. `hasattr(ct.converters, 'onnx')` → `False`.
*Positive control:* `convert` (the unified TF/PyTorch entry point), `libsvm`, `sklearn`, `xgboost` are
all present, so the probe reads a populated namespace. **§5.6.3's ❌ row HOLDS, now verified against
the installed package rather than against documentation.**

**(b) `onnx2torch` — the obvious bridge — cannot ingest this graph.** `onnx2torch 1.5.15` (Apache-2.0,
last release 2024-08-07) registers 108 ONNX op types. Converting `model.onnx` raises
`NotImplementedError: Converter is not implemented (OperationDescription(domain='', operation_type='Pad', version=19))`.
Down-converting the model to opset 18 with `onnx.version_converter` succeeds (*positive control:* a
no-op convert to its own opset 20 succeeds; a convert to 17 fails with a specific
`No Adapter To Version $17 for Pad`) — and then fails identically at `Pad` version 18, because
onnx2torch's registry is exact-version and carries Pad only at `[2, 11, 13]`.

**And the fatal one: `STFT` is ABSENT from onnx2torch at every version.**
*Positive control:* `Conv [1, 11]`, `Pad [2, 11, 13]`, `ArgMax [11, 12, 13]`, `Softmax [1, 11, 13]`,
`ReduceSum [1, 11, 13]`, `Expand [8, 13]` all resolve. So the empty result for `STFT` is a real
absence in a working lookup. This is **not** a version problem and no opset juggling fixes it —
which also makes §5.6.6's "opset-18 variant only exists as an attachment on issue #3" contingency
moot in both directions (I can produce opset 18 locally in one line, and it does not help).

### 2.2 What DOES work: Core ML can do an STFT, but only from PyTorch

The MIL op registry has **168 core ops with no `stft`, no `fft`, nothing complex** (*positive control:*
`conv`, `reduce_argmax`, `softmax`, `pad` all PRESENT) — **but 18 *dialect* ops, and they include
`complex_stft`, `complex_fft`, `complex_rfft`, `complex_irfft`, `complex_abs`, `complex_real`,
`complex_imag`.** The PyTorch frontend carries a `def stft` under `@register_torch_op`.

> ⚠️ My first probe grepped MIL class names and reported `stft` absent **and `argmax` absent** — and
> Core ML plainly has an argmax. **That probe was broken, not the tool.** The registry enumeration
> above is the authoritative one. Recording the near-miss because a confident false "absent" is
> exactly the failure this repo keeps paying for.

I verified the capability in isolation before building anything on it: a 15-op PyTorch module doing
`F.pad(384,384)` + `torch.stft(n_fft=1024, hop=256, center=False, onesided=True)` **converts to Core ML
successfully both with a fixed `(1,16000)` shape and with a flexible `ct.RangeDim` shape.**

### 2.3 So Route B exists only as a dev-time re-authoring — which I did, and verified

There is no converter to buy. The graph has to be re-written by hand in PyTorch, with the **weights
loaded verbatim from the ONNX initializers** (so nothing is retrained or approximated — §5.6.4's
"training code was never released" does not bite here).

The graph is small enough that this is real work but not research. Measured, first-hand:
**51 nodes, 26 distinct op types, 30 initializers, 97,164 parameters**, `producer: pytorch 2.7.0`,
`ir_version 9`, `opset 20`, input `input_audio [1, audio_length]`, outputs `pitch_hz` / `confidence`.
Architecture: zero-pad 384 → STFT(1024/256, Hann) → magnitude → bins 3:135 (132 bins) → `log(x+1e-8)`
→ 5× `Conv2d` 5×5 `SAME_UPPER` (8→16→32→64→1) with ReLU → squeeze → `Conv1d` 132→200 k=1 → softmax
over 200 log-spaced bins (46.875 Hz … 2093.75 Hz) → argmax → ±9-bin masked centroid → `pitch_hz`, and
the mass inside that ±9-bin window → `confidence`.

> *(97,164 measured initializer elements corroborates §5.6.3's "95,842 parameters" — which §5.6.3
> correctly flagged as **the paper's claim, not independently derived**. The 1,322-element gap is
> consistent with the paper excluding the 1024-tap window and the 200-entry frequency table. §5.6.3's
> caution was right and the order of magnitude holds.)*

**The re-authored module is faithful.** Against ONNX Runtime on the same input:

| Check | Result |
|---|---|
| magnitude spectrogram, peak-relative diff | **1.80e-07** |
| magnitude, max relative diff on bins above 1e-3 × peak | **3.08e-05** |
| end-to-end pitch, worst over **314 voiced frames** (conf ≥ 0.9), 15 cases | **0.625 cents** |

⚠️ **One behaviour worth its own paragraph, because it is §5.6.5's failure mode caught in the act.**
On a clean 220 Hz sine, 2 frames of 62 disagree by ~1200 cents — ONNX Runtime reads 110.8 Hz where the
re-authored module reads 222 Hz. Inspecting the model's own softmax on those frames: **bins 45 and 81
(exactly an octave apart) carry 0.3948 and 0.3920.** It is a genuine near-tie inside the model, and a
float32 rounding difference decides it. Both frames sit at confidence ≈ 0.40–0.51, far below the 0.9
threshold, so both implementations would mark them unvoiced. **Implication for §5.5: the Swift-vs-
Python parity gate must be specified over *voiced* frames, or it will fail on ties that neither
implementation is wrong about.** This applies to **Route A as well** — any two builds of this model
can flip these frames.

### 2.4 The converted artefact: size, compilation, and the fidelity tax

All four variants convert. `.mlpackage`, then compiled with `xcrun coremlcompiler` (Xcode 26.6):

| Variant | `.mlpackage` | compiled `.mlmodelc` |
|---|---|---|
| flexible `RangeDim` / **fp32** | 4,605,128 | **4,610,892 (4.40 MiB)** |
| flexible `RangeDim` / fp16 | 2,313,468 | 2,319,213 (2.21 MiB) |
| fixed `(1,16000)` / fp32 | 4,605,203 | — |
| fixed `(1,16000)` / fp16 | 2,313,543 | — |

*(Negative control: `coremlcompiler compile` on a non-existent package errors distinctly.)*

**Why a 0.39 MB model becomes a 4.6 MB artefact — 11.6×.** `weight.bin` is 4,588,032 B of the
4,605,128, i.e. 1,147,008 floats, against 97,164 actual parameters. The surplus ~1,049,844 is
1024 × 513 × 2 = 1,050,624. **Core ML has no FFT primitive, so coremltools lowers `torch.stft` to a
dense DFT matmul and materialises the DFT matrix. 97% of the Core ML artefact is that matrix.**

**The fidelity tax is the real cost, not the bytes.** Core ML output vs ONNX Runtime, voiced frames
(conf ≥ 0.9), 18 cases across sine / low-F0 98 Hz / sweep / vibrato / noise / silence at three lengths:

| Precision | n | median | p95 | p99 | max | frac > 10 ¢ |
|---|---|---|---|---|---|---|
| **fp32** | 335 | **0.92 ¢** | 5.44 ¢ | 6.51 ¢ | **6.60 ¢** | **0.00 %** |
| fp16 | 335 | 7.52 ¢ | 23.76 ¢ | 29.73 ¢ | **37.62 ¢** | **37.31 %** |

The re-authoring contributes 0.625 ¢ of that; **the rest is Core ML's own numerics** (the DFT matmul
plus MIL fusion). Two consequences:

1. **fp16 is disqualified.** 37.6 ¢ worst and 37 % of voiced frames over 10 ¢ blows §5.5's
   "≥99 % of voiced frames within ±10 cents on synthetic material" outright. **The 2.2 MB variant is
   not on the table**, which removes most of Route B's size advantage over… nothing, since fp32 is
   still only 4.4 MB. Stated so nobody reaches for fp16 later to halve it.
2. **fp32 clears §5.5's bar with no headroom to spare.** It never exceeds 10 ¢ on this corpus, but
   45.7 % of voiced frames exceed 1 cent and p99 is 6.5 ¢. **Route B spends ~65 % of the entire §5.5
   synthetic error budget on the port itself, before the detector's own error is counted.** That is
   the number that decides A vs B, not the megabytes.

**Route B is the one that needs full Xcode**, inverting §5.6.6's expectation: `.mlpackage` → `.mlmodelc`
is `xcrun coremlcompiler` (Xcode-only) or `MLModel.compileModel(at:)` at first run. Mitigable by
committing the pre-compiled 4.4 MB `.mlmodelc` — Xcode ships exactly that artefact inside app bundles
— but it is a build-tooling coupling Route A simply does not have.

### 2.5 Speed does not discriminate

10 s of audio, one call: Core ML fp16 `CPU_AND_NE` **4.8 ms**; ONNX Runtime (Python, CPU) **19.0 ms**.
Both are >500× realtime for an offline analysis pass. **Performance is not an input to this decision.**

---

## 3. RECOMMENDATION — **GO on Route A**, and the one question for the user

### The decision

**Vendor `microsoft/onnxruntime-swift-package-manager` at `exact: "1.24.2"` and commit
`swift_f0/model.onnx` (397,987 B) as a `DAWEngine` resource.**

### Why A wins

1. **Zero fidelity loss.** Route A ships the upstream artefact executed by the upstream runtime.
   Route B ships a re-authored graph run through a different numerical stack and pays **6.6 cents
   worst-case, ~65 % of §5.5's synthetic budget**, on the exact quantity this subsystem exists to
   measure. Everything downstream — segmentation, the transpose curve fed to §6's resynthesis —
   inherits that.
2. **Zero permanent maintenance.** Route B means owning a Python re-authoring script forever, re-run
   and re-verified on every upstream weight change, on a project whose training code was never
   released. Route A is a version bump.
3. **Route A has a shipping-app witness; Route B has none.** §5.6.4's `baijum/ukulele-companion`
   runs SwiftF0 in a Swift app via ORT. Nobody has shipped this model through Core ML. That asymmetry
   held before this spike and this spike does not overturn it — it only shows Route B is *reachable*.
4. **The size objection is weaker than it looks, for three independent reasons.**
   - **The user is not distributing.** Their own ruling (2026-08-04): *"for now I am planning to use
     it locally without sharing to anyone."* Bundle size is a download-and-store cost. There is no
     download, and the machine has 1.1 TiB free. 30.7 MiB is 0.003 % of it.
   - **This codebase already takes ML stacks.** WhisperKit is pinned `exact: "0.18.0"` at
     `Package.swift:39` with a 7-package transitive graph. The objection is size, not principle.
   - **Stripping the bundle recovers 20.6 MB** (§1.4), more than half the delta, for one line — and
     is worth doing whether or not ORT lands.
5. **Route A is the *less* Xcode-entangled route** (§1.1 vs §2.4) — the reverse of §5.6.6's
   assumption, and it matters because Route B's coupling would be new territory while Route A's is none.
6. **Route A does not forfeit the ANE** (§1.6): ORT can append the Core ML execution provider.

### What would falsify this — each concrete

1. **The user says the app's on-disk size matters to them.** Then Route B at 4.4 MB is genuinely
   available, verified by this spike, and costs 6.6 cents and a maintained script. It is a real
   option, not a consolation prize — that is this spike's second-most-useful output.
2. **Linking ORT into the *real* `DAWApp` behaves differently from the probe.** The probe is a
   minimal consumer. `DAWEngine` already links a C++ TU (`CSignalsmithStretch`, `cxx17`, Accelerate)
   and the app links WhisperKit's graph. A duplicate-symbol or C++-runtime conflict would show at
   link time. **This is step 1 of §5 and it gates everything; it is the one thing the probe could
   not prove.**
3. **§5.5's low-F0 leg (§5.6.5) fails past its ceiling.** Detector question, not a route question —
   it falls the same way on A and B, and §5.6.6's ladder already prices the mitigation at +0.5 wk.
4. **ORT 1.24.2's static archive breaks ad-hoc signing.** Not expected — it is a static `ar` archive,
   folded into `MacOS/DAWApp`, and `codesign --force --sign -` (bundle.sh:155) signs one Mach-O either
   way. Verify anyway in §5 step 5.

### ⭐ THE QUESTION FOR THE USER — answerable in one line

> **DAW Pro's app bundle is 38 MB today. Running SwiftF0 in-process needs Microsoft's ONNX Runtime,
> which measures at +30.7 MB, taking the bundle to 69 MB. It is MIT, statically linked, needs no new
> Xcode tooling, and runs the upstream model exactly. Do I take it?**
>
> **If the 69 MB bothers you, say so** — there is a verified alternative that is 4.4 MB instead of
> 30.7 MB, at the cost of ~6.6 cents of pitch error and a conversion script we maintain forever.
>
> *(A separate, unrelated 20 MB is available for free by adding `strip -x` to `scripts/bundle.sh`,
> whichever way you answer. Shall I file that?)*

**No cycle may answer this.** Same standing rule as m23-n3c and §5.6's own header.

---

## 4. What in §5.6 is stale or wrong

Flagged per the anti-vacuity rule: **V** = I verified it first-hand in this spike, **C** = carried
forward from §5.6 unchecked.

| § | Claim | Verdict |
|---|---|---|
| 5.6.6 note | *"⚠️ REQUIRES FULL XCODE … Check `xcodebuild -version`."* | **STALE (V).** `xcodebuild -version` → **Xcode 26.6 / 17F113**. Satisfied. |
| 5.6.6 note | *"Route A: embedding an xcframework lands in this repo's existing bundling/signing full-Xcode territory."* | **WRONG (V).** No xcframework is embedded. The product is `type: .static`; `swift build -c release` alone produces a working binary. **Route A needs no Xcode-specific step; Route B does.** The note has A and B the wrong way round. |
| 5.6.6 table, Route B | *"Plausible and UNVERIFIED. I have not checked that any converter handles this graph."* | **RESOLVED, and the answer is NO (V).** No converter handles this graph: coremltools has no ONNX frontend, and onnx2torch lacks `Pad@18/19` and `STFT` at every version. Route B exists **only** as a dev-time re-authoring — which does work, and now has numbers (§2). |
| 5.6.6 table, Route B | *"Architecturally the best fit (nothing new links; Core ML is a system framework)."* | **HALF TRUE (V).** The link claim holds. But the artefact is **11.6× the ONNX** because Core ML has no FFT and materialises a 1024×513×2 DFT matrix, and it costs 6.6 ¢. "Best fit" understates both. |
| 5.6.6 table, Route B | *"the in-repo model is opset 20; an opset-18 variant exists only as an attachment on GitHub issue #3 — fragile provenance."* | **MOOT BOTH WAYS (V).** `onnx.version_converter` produces opset 18 locally in one line — no attachment needed. And it does not help: onnx2torch has no `STFT` at any opset. **Do not go fetch that attachment.** |
| 5.6.3 | *"ONNX → Core ML via coremltools DOES NOT HOLD."* | **HOLDS (V)**, now confirmed against installed coremltools 9.0 rather than documentation. |
| 5.6.3 | *"95,842 parameters — the paper's claim, corroborated but not independently derived."* | **NOW DERIVED (V): 97,164** initializer elements over 30 initializers. §5.6.3's caution was correct; gap consistent with the paper excluding the window and frequency table. |
| 5.6.2 / 5.6.10 | `model.onnx` = **397,987 bytes** | **HOLDS (V).** SHA256 `7e2390db…c18176`. |
| 5.6.6 | *"`TARGET_SAMPLE_RATE = 16000` … 3:1 decimation mandatory"*; *"`HOP_LENGTH = 256` ⇒ 62.5 fps"*; *"`MODEL_FMIN` 46.875 / `MODEL_FMAX` 2093.75"* | **HOLD (V).** 62 frames for 1.0 s, and the 200-bin frequency table in the graph starts at 46.875 Hz. |
| 5.6.6 | *"`DEFAULT_CONFIDENCE_THRESHOLD = 0.9` produces deliberate gaps."* | **HOLDS and is load-bearing (V).** The octave near-ties of §2.3 all sit at conf ≈ 0.40–0.51 and are correctly gated out. |
| 5.6.5 | The low-F0 octave-confusion mechanism | **OBSERVED FIRST-HAND (V)** — as a 0.3948 / 0.3920 near-tie between bins exactly one octave apart, on a *clean 220 Hz sine*. §5.6.5's leg is not hypothetical, and this suggests writing it against the model's **softmax distribution**, not only its scalar output. |
| 5.6.4 | Upstream dormancy, benchmark history, adoption | **CARRIED (C).** Not re-checked; nothing in this spike depends on it. |
| 5.6.3 table | Voicing F1 / cents / octave-error figures for SwiftF0 vs pYIN | **CARRIED (C).** |
| 5.6.7 | The 1.5–2 wk re-shape of phase-1 sub-item (1) | **CARRIED (C)**, and now cheaper: this spike *is* the 0.5–1 wk conversion/fidelity spike that table books. On a Route A answer, **sub-item (1) drops to the 0.5 wk wrapper + 0.5 wk gate ≈ 1 wk.** |

---

## 5. Implementation plan, contingent on a Route A answer

**Route:** `audio-dsp-engineer` (m23-ap-2). Do not start before the user answers §3.

1. **Link probe against the real target — GATES EVERYTHING.** Add the ORT dependency to
   `/Users/dsemenov/Views/daw-pro/Package.swift` as a `DAWEngine`-only dependency, `exact: "1.24.2"`,
   with the same comment discipline as the WhisperKit edge (`Package.swift:14–39`). Build, run
   `./scripts/test.sh`, and confirm no duplicate-symbol or C++-runtime conflict with
   `CSignalsmithStretch` or WhisperKit. **`DAWCore` must not gain the edge** — the domain stays
   dependency-free (CLAUDE.md, and the same rule already written for `CAtomics` and
   `ObjCExceptionGuard`). Record the real `dist/DAWPro.app` delta and compare it to the 32,139,248 B
   predicted here; a large divergence means re-open this document.
2. **Commit the weights.** `Sources/DAWEngine/Analysis/Resources/swiftf0.onnx` (397,987 B) as a
   SwiftPM `.copy()` resource, plus upstream `LICENSE` and a `VENDORED.md` pin recording the commit
   SHA and the file's SHA256 — the `CSignalsmithStretch/vendor/` precedent. **No installer, no
   `.gitignore` entry, no `ai.installSpeechModel` involvement.**
3. **`PitchTracker` — the one home.** `/Users/dsemenov/Views/daw-pro/Sources/DAWEngine/Analysis/PitchTracker.swift`,
   as §5.6.6 mandates. It owns: 48 k → 16 k anti-aliased decimation (reusing the m20-b/m20-d output-edge
   SRC story; **no second sample-rate home** — `AudioEngine.projectSampleRate` stays authoritative),
   framing and timestamp alignment, `ORTEnv`/`ORTSession` lifetime, the 0.9 confidence threshold, and
   the `fmin`/`fmax` voicing derivation. **Do not create a separate "SwiftF0 wrapper" file.**
4. **RT safety — non-negotiable, and this is the design's sharpest edge.** ORT allocates, locks,
   spawns threads, and `ORTSession` construction is slow. §7.6 is absolute: **nothing here may be
   reachable from the render thread.** Concretely: (a) `setIntraOpNumThreads: 1`
   (`ort_session.h:134`) so ORT's pool cannot contend with the audio thread; (b) session construction
   and `run` on a background executor at `.utility`, never `.userInteractive`; (c) the seam that hands
   results back is a value copy into the model on `@MainActor`, never a shared buffer the render
   thread reads. Add `PitchTracker` to the RT-malloc-probe surface — noting the **m23-cu caveat**
   that those probes measure `-Onone` while `dist` is `-c release`.
5. **Bundle + signing check.** Re-run `scripts/bundle.sh`, confirm no `Contents/Frameworks` appears
   and `codesign -dv` still passes on the ad-hoc seal. **Flagged as full-Xcode-adjacent per standing
   obligation, though §1.1 says no new Xcode step should be required.** Regenerate
   `dist/DAWPro.app` and re-verify the in-binary command count (both generated bundles rot silently).
6. **The §5.5 gate**, per §5.6.6, with **three amendments this spike forces**:
   - **Parity is over VOICED frames.** The ±9-bin argmax is bimodal at octave-related bins and ties
     flip on float rounding (§2.3). A frame-for-frame bitwise parity test **will** fail on frames
     neither implementation is wrong about. Specify: voiced frames (conf ≥ threshold) within **1 cent**
     of the upstream Python package, and voiced/unvoiced agreement ≥ 99 %.
   - **The low-F0 leg (§5.6.5) should assert on the softmax distribution**, not only on the scalar
     `pitch_hz`. The failure is visible as octave-separated bins carrying near-equal mass — a much
     sharper test than "the number came out wrong."
   - **Fixtures already built by this spike** and worth lifting into `Tests/`: 220 Hz sine, 98 Hz low
     sine, 90→790 Hz sweep, 5 Hz vibrato, noise, silence, at 16000 / 32000 / 12345 samples (the odd
     length catches framing/tail bugs).
7. **Control surface.** Per CLAUDE.md every capability ships a control command, an MCP tool, and a
   test. Detection is internal to subsystem A, so the wire verb belongs to whatever m23-ap-2 exposes
   (e.g. `clip.analyzePitch`) — **not** to `PitchTracker` itself. **Additive only; no live verb renamed.**

**Explicitly flagged as full-Xcode territory:** step 5 only, and only because bundling and signing
already are. **Nothing in Route A requires AUv3, entitlements, or a developer account.** The user's
2026-08-04 ruling (local use, ad-hoc signing) is unaffected — a static archive raises no
library-validation question, so hardened-runtime concerns and the in-process AUv2 story are untouched.

---

## 6. Route C — costed, not pursued

Hand-port to Accelerate/BNNS/MPSGraph. Better informed than §5.6.6 was: 51 nodes, 6 convolutions, one
1024-point STFT, 97,164 parameters — vDSP has the FFT, BNNS has the convolutions, and the head is
arithmetic. Roughly **1.5–2 wk plus its own fixture gate**, and it creates a second home for the
model's semantics that §7.8 exists to forbid. **§5.6.9's verdict stands: at that cost it competes
directly with in-house pYIN, and pYIN wins on "no fourth-party artefact at all."** Not pursued.

---

## 7. Reproducing this

Scratchpad (disposable; nothing here belongs in the repo):

| File | What |
|---|---|
| `sizelab/baseline/`, `sizelab/ortapp/` | the two SwiftPM packages behind the §1.3 link delta |
| `model.onnx` | SwiftF0 weights, 397,987 B |
| `swiftf0_torch.py` | the trace-clean PyTorch re-authoring (§2.3) |
| `reconstruct.py`, `routeb.py` | parity harness and Core ML conversion |
| `convtest/.venv` | Python 3.12.13 — onnx 1.22.0, onnxruntime 1.28.0, torch 2.13.0, coremltools 9.0, onnx2torch 1.5.15 |
| `SwiftF0_{flex,fixed16k}_{fp32,fp16}.mlpackage`, `compiled/*.mlmodelc` | the §2.4 artefacts |

**Machine:** Xcode 26.6 (17F113), macOS arm64. **Caveat:** `coremltools 9.0` warns
*"Torch version 2.13.0 has not been tested with coremltools; 2.7.0 is the most recent tested"* — the
conversions succeeded and their outputs were checked numerically against ONNX Runtime, but a Route B
decision should pin torch 2.7.0 before trusting the 6.6 ¢ figure to the last decimal.
