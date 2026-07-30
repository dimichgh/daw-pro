# m23-n3c — WhisperKit variant tradeoff: accuracy vs speed vs word-timing quality

**Retrieved 2026-07-28.** Sizes are already measured and pinned in
`m23-n3c-measured-sizes.md` — this document does not repeat or re-derive
them. This document's job is the other three axes: accuracy, speed, and
word-level timestamp quality, for choosing which variant ships as the
**default** model for transcribing recorded vocal/speech clips onto the
project's beat grid.

**Provenance, stated once:** almost every number below comes from Argmax
(the company that builds WhisperKit and publishes the `whisperkit-coreml`
weights) measuring its own artifacts — the interactive dashboard at
[huggingface.co/spaces/argmaxinc/whisperkit-benchmarks](https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks)
(its raw data files, `dashboard_data/quality_data.json` and
`dashboard_data/performance_data.json`, whose own internal timestamps read
**2024-10-18**, so treat these as ~21-month-old vendor measurements that
could have been superseded by a later re-run since), Argmax's ICML/arXiv
paper
[*WhisperKit: On-device Real-time ASR with Billion-Scale Transformers*](https://arxiv.org/html/2507.10860v1)
(arXiv 2507.10860), and Argmax's own blog post
[*Apple SpeechAnalyzer and Argmax WhisperKit*](https://www.argmaxinc.com/blog/apple-and-argmax).
**No independent third party has measured these specific CoreML artifacts.**
Where HuggingFace's own `distil-whisper` README numbers are cited (a
different eval, the ESB benchmark, run by a different org on the PyTorch
model, not the CoreML conversion), they are kept in a separate table and
never mixed into the Argmax numbers — the two are not comparable rows of the
same table.

**Retrieval caveat:** the JSON dashboard files were read through an
automated fetch-and-summarize tool (no local JSON parser was available for a
remote URL), which introduced two confirmed transcription errors during
research that were caught by re-querying the same field twice and by
cross-checking against a HuggingFace tree-API byte comparison (see the
`_turbo` section below). Numbers quoted here were the ones that reproduced
identically across at least two independent fetches, or that come from a
verbatim-quoted JSON snippet. Treat second-decimal precision as
"approximately this," not as a guaranteed-exact transcription.

## 1. What "`_turbo`" actually means — it is two unrelated things wearing one name

This needed byte-level verification, not a guess, because the catalog's own
naming creates a trap: `openai_whisper-large-v2_turbo` (3096.5 MB) exists,
but **OpenAI never released a "large-v2-turbo" checkpoint** — the turbo
architecture (pruned decoder) was only ever trained for large-v3, released
2024-09-30. So the `_turbo` suffix cannot uniformly mean "OpenAI's
turbo architecture." Confirmed by comparing the actual CoreML weight files
via the HuggingFace tree API (`argmaxinc/whisperkit-coreml`, no download):

| Directory | `TextDecoder…/weight.bin` | `AudioEncoder…/weight.bin` |
|---|---:|---:|
| `openai_whisper-large-v2` | 1,813,199,154 B | 1,273,605,760 B |
| `openai_whisper-large-v2_turbo` | **1,813,199,154 B (identical)** | 1,273,605,760 B (identical) |
| `openai_whisper-large-v3` | 1,813,201,716 B | 1,273,974,400 B |
| `openai_whisper-large-v3-v20240930` | **343,933,748 B (~19% of v3's)** | 1,273,974,400 B (identical) |

Two separate, confirmed facts:

- **`large-v2` → `large-v2_turbo`**: decoder weights are byte-identical. The
  only thing that changed is `AudioEncoder.mlmodelc/model.mil` (the compiled
  compute graph), which grew from 581,032 B to 7,006,614 B — a much bigger
  compiled program over the *same* weights. This is Argmax's own packaging
  optimization (search results independently describe Argmax's `_turbo`
  suffix as "additional optimizations (not compression) to unlock streaming
  transcription" — consistent with what the byte comparison shows: same
  parameters, a different, larger compiled graph). **It is not a decoder
  architecture change.**
- **`large-v3` → `large-v3-v20240930`**: the decoder shrinks to ~19% of its
  original weight size — consistent with OpenAI's own description of the
  turbo checkpoint ("4 decoder layers, down from 32," per
  [OpenAI's turbo announcement](https://github.com/openai/whisper/discussions/2363)),
  same encoder. **This is the real architectural turbo.** Argmax folds it
  into the catalog under the date-versioned name `large-v3-v20240930`, and
  its own README table (fetched from
  [github.com/argmaxinc/WhisperKit/blob/main/README.md](https://github.com/argmaxinc/WhisperKit/blob/main/README.md))
  labels `large-v3-v20240930_626MB` as **"Large v3 Turbo (compressed)"** —
  confirming this identification in Argmax's own words.

**Conclusion, stated plainly:** `openai_whisper-large-v3-v20240930*` (what
ships as the app's default today, per `WhisperModelCatalog.swift` and
Argmax's README recommendation) is *already* running the shallow
4-layer-decoder architecture. Any `_turbo` you see on `large-v2` or
non-versioned `large-v3`/`distil-large-v3` names is Argmax's unrelated
graph/streaming optimization on the full decoder, not the same thing.

## 2. Quantization's cost is real, published, and **not uniform**

Argmax's own paper (arXiv 2507.10860, Table 2 — "OD-MBP" = Outlier-Decomposed
Mixed-Bit Palettization, their published compression method) reports
compressing the large-v3-turbo checkpoint from 1.6 GB (FP16) to 0.6 GB:

| Compression | Size | librispeech WER | earnings22-12h WER | CommonVoice17-en WER |
|---|---|---:|---:|---:|
| FP16 (original) | 1.6 GB | 1.93 | 11.55 | 12.13 |
| OD-MBP (quantized) | 0.6 GB | 1.96 (+0.03) | 12.35 (+0.80) | 13.03 (+0.90) |

That is the vendor's own headline number and it is small — "within 1%,"
as Argmax's paper and marketing both claim, and independently corroborated
in the dashboard row (`large-v3-v20240930/626MB`: avg WER 7.15 vs the
unquantized `large-v3-v20240930` at 6.74).

**But not every quantized artifact in the catalog behaves this well**, and
this is the more decision-relevant finding. Two rows in Argmax's own
`quality_data.json` show a very different shape — reproduced identically
across two independent fetches:

| model | avg WER | librispeech | earnings22-12h | QoI |
|---|---:|---:|---:|---:|
| `large-v3-v20240930/547MB` | 16.82 | 2.16 | **31.49** | 0.92 |
| `large-v3/turbo/954MB` | 22.75 | 2.51 | **43.0** | 0.93 |

Short-form (librispeech) barely moves versus the unquantized/other-quantized
rows, but long-form (earnings22, ~120 hours of real-world conversational
audio) explodes to 2.5–3.5x the WER of every neighboring size tier. **The
QoI numbers pin down what kind of failure this is, and the arithmetic is
worth stating rather than hedging:** QoI 0.92 means WhisperKit still does no
worse than the reference model on 92% of files. For the *mean* WER to jump
from 11.55 (unquantized neighbor) to 31.49 while 92% of files are
unaffected, the remaining ~8% of files must individually be running at WER
well over 100% (many multiples of the reference text length) to drag the
average that far — arithmetically that is only reachable through runaway
insertions, i.e. a repetition/hallucination loop consuming a handful of long
files, not a uniform accuracy loss spread across the set. **This is
disqualifying for a DAW recording noisy, in-song, or non-studio vocals** —
that is closer to earnings22's real-world-audio conditions than to
librispeech's clean read-audiobook conditions. Practical read: **547MB and
954MB should be excluded from the shortlist regardless of their attractive
size**, and this is a concrete example of "the central question — what
quantization actually costs" not having one answer: it depends on which
specific compressed artifact.

One more finding worth surfacing rather than smoothing over: **Argmax's own
recommendation may not follow its own numbers.** Argmax's README recommends
`large-v3-v20240930_626MB` "for maximum accuracy," but its own dashboard
data shows the (also quantized, and packaged with the turbo streaming
graph) sibling beating it on every axis on the same device:

| model | avg WER | librispeech | earnings22-12h | speed factor, M4 Pro |
|---|---:|---:|---:|---:|
| `large-v3-v20240930/626MB` | 7.15 | 1.96 | 12.35 | 10.46 |
| `large-v3-v20240930/turbo/632MB` | **6.86** | **1.95** | **11.77** | **16.77** |

632MB is more accurate on both datasets *and* ~1.6x faster than 626MB in
Argmax's own measurements. A plausible (not confirmed) explanation: 626MB
may be recommended in the README primarily as the iOS-safe pick, where the
bigger compiled streaming graph in the `_turbo` packaging may cost more
memory than an iOS device budget allows — but this is speculation on our
part, not something any source states.

## 3. Accuracy per variant (Argmax's own eval harness)

Datasets: **librispeech** (~5h, clean short-form English) and
**earnings22-12hours** (a curated 12-hour subset of the ~120h earnings22
corpus — real-world conversational audio with accents, cross-talk, and
noise; this is Argmax's long-form proxy, not the full earnings22). All
numbers below are from `dashboard_data/quality_data.json` in the
`argmaxinc/whisperkit-benchmarks` HF Space, internally dated 2024-10-18.

| variant | avg WER | librispeech | earnings22-12h | QoI | note |
|---|---:|---:|---:|---:|---|
| `tiny` | 14.21 | 7.46 | 20.97 | — | |
| `tiny.en` | 12.23 | 5.61 | 18.86 | — | |
| `base` | 10.67 | 4.94 | 16.4 | 0.67 | |
| `base.en` | 9.59 | 3.98 | 15.2 | 0.75 | |
| `small` | 8.11 | 3.21 | 13.0 | 0.83 | |
| `small.en` | 7.85 | 2.88 | 12.82 | 0.86 | |
| `small_216MB`, `small.en_217MB` | — | — | — | — | **no data published anywhere found** |
| `medium`, `medium.en` | — | — | — | — | **no data published anywhere found** |
| `large-v2` | 7.32 | 2.36 | 12.28 | 0.97 | |
| `large-v2/949MB` (quantized) | 7.88 | 2.38 | 13.39 | 0.94 | |
| `large-v2/turbo` (Argmax packaging) | 7.25 | 2.4 | 12.1 | 0.96 | |
| `large-v2/turbo/955MB` | 7.27 | 2.4 | 12.14 | 0.94 | |
| `large-v3` | 6.85 | 2.02 | 11.69 | 0.95 | |
| `large-v3/947MB` (quantized) | 9.74 | 2.41 | 17.08 | 0.94 | |
| `large-v3/turbo/954MB` (quantized) | 22.75 | 2.51 | 43.0 | 0.93 | **excluded, see §2 — repetition-collapse signature** |
| `large-v3-v20240930` (= OpenAI turbo arch) | 6.74 | 1.93 | 11.55 | 0.94 | |
| `large-v3-v20240930/547MB` (quantized) | 16.82 | 2.16 | 31.49 | 0.92 | **excluded, see §2 — repetition-collapse signature** |
| `large-v3-v20240930/626MB` (quantized) | 7.15 | 1.96 | 12.35 | 0.93 | |
| `large-v3-v20240930/turbo` (Argmax packaging) | 6.72 | 1.92 | 11.52 | 0.94 | |
| `large-v3-v20240930/turbo/632MB` (quantized) | 6.86 | 1.95 | 11.77 | 0.93 | |
| `distil-whisper_distil-large-v3` | 7.2 | 2.38 | 12.02 | 0.9 | |
| `distil-whisper_distil-large-v3/594MB` (quantized) | 8.96 | 2.87 | 15.06 | 0.86 | |
| `distil-whisper_distil-large-v3/turbo` | 7.2 | 2.35 | 12.05 | 0.9 | |
| `distil-whisper_distil-large-v3/turbo/600MB` (quantized) | 8.33 | 2.8 | 13.87 | 0.86 | |

**Explicitly no data found for:** `medium`/`medium.en`, and both quantized
small variants (`small_216MB`, `small.en_217MB`). These four were searched
for directly in the raw JSON (both the quality and performance files) and
are simply absent — not a case of us failing to find them, but of Argmax
not having published an eval row for them. **They cannot be recommended on
accuracy grounds because there is no accuracy data for them at all.**

## 4. English-only (`.en`) vs multilingual — `.en` wins at every size where both exist

| size tier | multilingual WER (librispeech / earnings22) | `.en` WER (librispeech / earnings22) | note |
|---|---|---|---|
| tiny | 7.46 / 20.97 | 5.61 / 18.86 | `.en` wins on WER but is the **larger** download here (153.0 MB vs 76.6 MB, per `m23-n3c-measured-sizes.md`) — `tiny.en` is the one variant in the whole catalog that ships both `.mlmodelc` and `.mlpackage` forms, which is a packaging fact, not an accuracy one |
| base | 4.94 / 16.4 | 3.98 / 15.2 | `.en` better; **byte-identical size (146.7 MB both)** — this is a pure accuracy call, no size tradeoff at all |
| small | 3.21 / 13.0 | 2.88 / 12.82 | `.en` better, and smaller too (see `small.en` 486.5 MB vs `small` 486.5 MB — effectively tied on size per the measured-sizes doc) |

Whisper's large-tier checkpoints (v2, v3, v3-turbo/v20240930) were only ever
trained multilingual — OpenAI never shipped a `large.en`, so this comparison
stops existing above `small`. **For a project whose users are overwhelmingly
recording English vocals, `.en` is a strict accuracy win with no size cost
at the `base` tier specifically**, and a modest win at `small`. It is not
available at all once you go to `large-v2`/`large-v3`/turbo, which is where
the best absolute accuracy lives — so the `.en` win only matters if the
shortlist includes a `base`/`small`-tier candidate.

## 5. Speed on Apple Silicon

**One device, one column, to avoid a collision an earlier retrieval pass in
this research hit** (two different fetches of the same dashboard returned
an identical number for two different model strings — a summarizer
artifact, not two real measurements, caught by a targeted re-query). Below
is the "Apple M4 Pro" column only, taken from
`dashboard_data/performance_data.json`, where `speed` is Argmax/OpenAI's
"real-time factor" (seconds of audio processed per wall-clock second) and
`tokens_per_second` is the raw decoder throughput:

| variant | speed (×RT) | tokens/s |
|---|---:|---:|
| `tiny` | 109.68 | 419.0 |
| `base` | 72.44 | 275.43 |
| `small.en` | 28.82 | 101.77 |
| `distil-large-v3` (unquantized) | 12.15 | 45.49 |
| `distil-large-v3/turbo/600MB` (quantized) | 20.59 | 70.42 |
| `large-v3-v20240930/626MB` (quantized) | 10.46 | 42.46 |
| `large-v3-v20240930/turbo/632MB` (quantized) | 16.77 | 57.12 |
| `large-v3/turbo/954MB` (quantized — excluded on accuracy, see §2) | 4.92 | 17.6 |
| `large-v2` (unquantized) | 3.39 | 13.62 |
| `large-v3` (unquantized) | 3.56 | 13.67 |
| `large-v2/turbo` (Argmax packaging, unquantized) | 4.01 | 17.04 |

**Gap, stated honestly:** the unquantized `large-v3-v20240930/turbo` — i.e.
today's shipped default at 1638.5 MB — was **not captured on M4 Pro
specifically** in what this research could retrieve; it appeared only on
"Apple M2" (speed 12.36, tokens/s 42.64) and a plain "Apple M4" (speed
13.99, tokens/s 55.51), different device rows than the M4 Pro table above,
so it is not placed in the table to avoid a false apples-to-apples
comparison. Rough sense of scale: it sits close to its own 632MB quantized
sibling's M4 Pro number (16.77), which is expected since the two share the
same decoder architecture and packaging, differing only by compression.

Two Argmax-published anchor points for absolute scale (from
[the Argmax/Apple blog post](https://www.argmaxinc.com/blog/apple-and-argmax),
measured on an M4 Mac mini, macOS 26 Beta): `whisper-base.en` speed factor
111, `whisper-small.en` speed factor 35 — broadly consistent in shape (base
far faster than small) with the M4 Pro table above, though not the same
device or exact figures, so treat as a cross-check rather than a third data
column.

**Separately, Argmax's own GitHub discussion states large-v3-turbo speed on
an M2 Ultra at 72x real-time (GPU+ANE) or 42x (ANE-only, the default,
chosen "to balance battery life, thermal sustainability, memory consumption
and latency")** — a reminder that the default WhisperKit configuration
deliberately does not chase the fastest possible number.

## 6. The distil family

- **Architecture, confirmed from HuggingFace's own README**
  ([github.com/huggingface/distil-whisper](https://github.com/huggingface/distil-whisper/blob/main/README.md)):
  `distil-large-v3` keeps **only 2 decoder layers**, "initialised from the
  first and last decoder layers" of the teacher, with every other decoder
  layer discarded. This is a much more aggressive decoder cut than turbo's
  4-of-32.
- **English-only.** HuggingFace's own README states plainly:
  "Distil-Whisper is only available for English speech recognition." For
  multilingual, their own recommendation is "the Whisper Turbo checkpoint...
  which leverages the same principles as Distil-Whisper" — i.e. even
  Distil-Whisper's own authors point at OpenAI's turbo (what Argmax calls
  `large-v3-v20240930`) as the multilingual answer.
- **Accuracy vs `large-v3-v20240930/turbo` at similar size, on Argmax's own
  harness (from §3 above):** `distil-large-v3` unquantized (1514.5 MB) scores
  avg WER 7.2 vs `large-v3-v20240930/turbo` unquantized (1638.5 MB) at 6.72 —
  turbo wins on accuracy at a comparable size. At the quantized ~600 MB tier,
  `distil-large-v3/turbo/600MB` scores avg WER 8.33 vs
  `large-v3-v20240930/turbo/632MB` at 6.86 — the gap widens in turbo's
  favor once both are compressed. **Quantization also costs distil more:**
  `distil-large-v3` unquantized→594MB moves earnings22 WER from 12.02 to
  15.06 (+3.04), versus `large-v3-v20240930` unquantized→626MB moving from
  11.55 to 12.35 (+0.80) — roughly 4x the degradation for a comparable
  compression step. **On Argmax's own numbers, there is no accuracy or
  robustness argument for choosing distil-large-v3 over
  large-v3-v20240930/turbo at any comparable size.** Its only structural
  advantage is not needing a multilingual model at all if the app ever
  wanted to hard-restrict to English — which it currently does not (the
  catalog is variant-agnostic and the transcription command already accepts
  a language parameter).
- **HuggingFace's own ESB-benchmark numbers** (a *different* evaluation, not
  comparable to the Argmax table above — kept separate on purpose):
  `distil-large-v3` short-form WER 9.7%, long-form WER 10.8%, vs `large-v3`
  short-form 8.4%, long-form 11.0%. Notably here distil *beats* large-v3 on
  long-form specifically — HuggingFace attributes this to distil-whisper's
  long-form decoding algorithm and its documented lower hallucination rate
  ("1.3x fewer repeated 5-gram duplicates, 2.1% lower insertion error"),
  which is a genuine, sourced strength of the distillation approach on
  *rambling/long* audio. This does not translate directly to our use case
  (the app transcribes individual recorded clips, not hour-long uploads),
  but it is worth naming as the one place distil has documented merit.
- **Long-form timestamp mechanics changed between distil versions.**
  HuggingFace's README describes a real, acknowledged limitation being
  fixed across versions: earlier distil models predicted timestamps only up
  to the last ~15s "with low accuracy," and `distil-large-v3` specifically
  was changed to predict "accurate timestamps up to and including 30
  seconds" to fix long-form failures — i.e., **this is a documented,
  vendor-acknowledged historical weakness of the distil family
  specifically for timestamps**, since patched for the v3 model. No
  equivalent complaint was found for the turbo family in the same source.

## 7. Word-level timestamp quality — the section that matters most for this app

This is the axis this research treated as decision-critical, because the
app places every recognized word directly on the project's beat grid:
`WhisperTranscriber.swift:258-261` sets `wordTimestamps: true`
unconditionally on every transcription request, and
`TranscriptionBeats.swift`'s `TranscribedWord`/`TranscribedSegment` carry
`startBeat`/`endBeat` computed straight from whatever WhisperKit returns.

**How WhisperKit produces word timestamps, verified by reading the actual
library source** (`/Users/dsemenov/Views/llm/murmur-wk/.build/checkouts/WhisperKit/Sources/WhisperKit/Core/`,
the same 0.18.0-class checkout `WhisperModelCatalog` cites, not a
description from a web page): the CoreML `TextDecoder` model, if built with
it, exposes an extra output named `alignment_heads_weights` — a fixed
`1×1500` array capturing cross-attention weight from a *specific,
pre-selected set of decoder heads* known (from OpenAI's original research)
to correlate with word boundaries. `SegmentSeeker.swift` runs **Dynamic
Time Warping** (`dynamicTimeWarping(withMatrix:)` → `backtrace`) over that
array to assign each token a start/end time. This is the same general
technique documented across the whisper ecosystem (e.g.
[linto-ai/whisper-timestamped](https://github.com/linto-ai/whisper-timestamped)),
and it is explicitly known to be a heuristic bolted onto a model that "has
not been trained to output meaningful timestamps after each word" — the
DTW alignment can drift out of sync, especially over music/jingle audio,
and cross-attention patterns differ enough between checkpoints that the
*same* audio can produce timestamps that differ by 100–400 ms between
models.

**The load-bearing, previously-unverified fact this research confirmed by
reading the code, not by inference:** whether a variant supports word
timestamps at all is a **binary, per-compiled-artifact property** —
`TextDecoder.swift:497-499`: `supportsWordTimestamps` is simply "does this
model's CoreML spec expose an `alignment_heads_weights` output." If it does
not, `TranscribeTask.swift:199-201`'s `if options.wordTimestamps, let
alignmentWeights = decodingResult.cache?.alignmentWeights { … }` guard is
never entered — no error, no exception. And on our side,
`TranscriptionBeats.swift`'s own doc comment confirms the failure mode
explicitly: *"Empty when the recogniser produced no word-level alignment
for this segment (it is `nil` upstream, never an error)."*

**This means: if the shipped default variant's CoreML build lacks
`alignment_heads_weights`, the app will not crash, warn, or log — it will
silently produce clips with zero words placed on the beat grid**, which for
this app is close to a silent total failure of the feature, not a
degraded-quality edge case. **This research could not verify, for any of
the 27 catalog variants, whether `alignment_heads_weights` is actually
present** — checking that requires inspecting each variant's compiled
`TextDecoder.mlmodelc` spec, which in turn requires downloading the model,
which this research was explicitly told not to do. **This is the single
most important open item this document surfaces: whichever variant(s) make
the shortlist must have `supportsWordTimestamps` checked at runtime (the
property already exists in WhisperKit's own API) before being trusted as a
default** — this is cheap (one property read after a model load, no
network, no benchmark) and should gate the final choice, not follow it.

**Architecture and the risk it implies (reasoned inference from confirmed
facts, not a directly measured result):**

- `large-v3-v20240930` (today's shipped default, and its turbo-packaged and
  626/632MB-quantized siblings) already runs the **4-layer pruned decoder**
  — confirmed in §1 by direct weight-file comparison. So whatever timestamp
  risk comes from "fewer decoder layers, cruder alignment heads to choose
  from" is a risk the app is *already* taking in production today, not one
  a variant switch would introduce. Switching to a **32-layer** checkpoint
  (`large-v2`, `large-v3` unquantized, or the `small`/`base`/`tiny` tiers,
  which were never pruned) would, if anything, be the direction that
  *reduces* this specific risk — at the cost of the accuracy numbers in §3.
  `distil-large-v3` (**2 decoder layers**, half of turbo's already-thin 4)
  would be the direction that *increases* it most.
- A concrete, documented complaint exists for exactly this pairing:
  [huggingface/transformers issue #37248](https://github.com/huggingface/transformers/issues/37248),
  *"Incorrect word timestamps and word repetitions with
  Whisper-Large-v3-turbo model"* — a user reporting inaccurate word
  timestamps and word repetition specifically on the turbo checkpoint. **This
  is on HuggingFace's `transformers` Python pipeline, a different codebase
  and a different timestamp-extraction implementation than WhisperKit's
  CoreML/DTW path** — no report of the same issue was found for WhisperKit
  or the CoreML conversion specifically, and OpenAI's own turbo model card
  makes no statement about timestamp quality one way or the other. This is
  presented as **a documented risk signal on the same underlying model
  weights, not a confirmed WhisperKit defect** — the honest position is
  "unresolved," not "confirmed safe" or "confirmed broken."
- Argmax's own arXiv paper does not report timestamp-quality-per-model at
  all — it explicitly *removes* word-level timestamps as a variable in its
  own benchmark methodology ("In order to remove the impact of predicted
  word-level timestamps when setting the transcript cursor, we run our
  benchmarks on the TIMIT dataset..."), meaning **Argmax's own published
  eval treats word timestamps as a confound to control for, not a metric it
  reports.** No source found anywhere in this research publishes a
  per-variant word-timestamp-accuracy number.
- distil-whisper's known, vendor-acknowledged limitation (§6): earlier
  distil checkpoints produced unreliable timestamps past ~15s of a segment,
  fixed in `distil-large-v3` specifically for segment-level behavior up to
  30s. No equivalent statement exists about *word-level* granularity for
  distil, one way or the other.

**What this research could not establish, listed together for visibility:**
1. Whether `alignment_heads_weights` is present in the compiled
   `TextDecoder.mlmodelc` for any specific one of the 27 catalog variants
   (requires downloading and inspecting the model — out of scope here).
2. Any quantitative word-timestamp-accuracy number for **any** variant, from
   any source. Every WER table in this document measures transcribed text
   correctness, not timing correctness.
3. **Anything about singing.** Every dataset behind every number in this
   document — librispeech, earnings22, CommonVoice, TIMIT, ESB — is spoken
   speech. No source measured sung vocals, and word-level timing behavior on
   sustained sung notes, melisma, or heavy reverb/production is plausibly
   very different from spoken-word timing. This is arguably the single
   biggest gap between "what the vendor measured" and "what this app needs,"
   and it is also the cheapest gap to close directly: a handful of real sung
   clips, hand-marked against the beat grid, transcribed by each shortlisted
   variant, would settle it locally in an afternoon — no published
   benchmark will ever substitute for that here.

## Shortlist (not a choice — the user decides)

Falling directly out of the accuracy/speed/architecture evidence above,
with the disqualified quantization tiers (§2, `547MB`/`954MB`) and the
data-free tiers (`medium`, `216MB`/`217MB`, both excluded on "no data," not
on merit) removed:

| candidate | size | avg WER (Argmax) | speed, M4 Pro | why it's here |
|---|---:|---:|---:|---|
| `openai_whisper-large-v3-v20240930_turbo` | 1638.5 MB | 6.72 | not on M4 Pro; ~13-16x on M2/M4 (§5) | **today's shipped default.** Best accuracy in the entire catalog on Argmax's own numbers; largest download; runs the 4-layer pruned decoder (§7 timing-risk discussion applies). |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | 645.7 MB | 6.86 | 16.77x | Near-identical accuracy to the full turbo (Δ0.14 avg WER) at 2.5x smaller and faster on Argmax's own device row than even the vendor-recommended 626MB. The strongest "small download, small accuracy cost" candidate found. Same 4-layer decoder as above. |
| `openai_whisper-large-v3-v20240930_626MB` | 626.7 MB | 7.15 | 10.46x | Argmax's official "maximum accuracy, cross-platform" recommendation — included for that reason even though its own sibling (632MB) beats it on every measured axis here (§2). Same 4-layer decoder. |
| `openai_whisper-small.en` | 486.5 MB | 7.85 | 28.82x | Smallest download with a full published accuracy AND speed number, and English-only wins outright here (no multilingual option lost, since English is the app's primary case). **The only shortlisted candidate that is not the 4-layer pruned decoder** — `small` was never pruned/distilled, so per §7 it structurally carries less of the shallow-decoder timing risk than the other three, at the cost of ~1 extra WER point. The pick if first-run download size *and* the word-timing-risk axis both matter more than the last point of WER. |

**Every one of these still needs the `supportsWordTimestamps` check from
§7 before being trusted with the app's beat-grid feature** — that gate has
not been run against any of them here, and it is the one check that could
overturn this entire shortlist regardless of WER.

## Actionable takeaways

1. **Before finalizing any default, verify `WhisperKit`'s
   `TextDecoder.supportsWordTimestamps` against each shortlisted variant's
   compiled model, once downloaded.** This is a one-property read per
   model load, not a benchmark run, and per §7 it is the one thing that can
   silently break the app's core feature with zero error surfaced anywhere
   in the current code path. Recommend this become a literal CI/staging
   gate, not just a one-time spot check, given how silent the failure mode
   is (`TranscriptionBeats.swift`'s own comment: "never an error").
2. **`WhisperModelCatalog.resolveModel(nil)` picking `.first` of an
   alphabetically-sorted list is a real landmine independent of which
   variant gets chosen** (already flagged in `m23-n3c-measured-sizes.md`):
   14 of 27 variants would silently displace today's default if a second
   model folder is ever added, purely by directory-name sort order.
   Whatever variant is picked as *the* default needs an explicit
   preference mechanism (a stored setting, an explicit "default" marker
   file, or similar) — not filename-sort luck. Propose this as its own
   ROADMAP item; it is orthogonal to which variant wins but must land
   before any variant other than today's is shipped as the intended
   default.
3. **Do not trust §2's `547MB`/`954MB` quantization tiers for anything.**
   If the model install UI (m23-n3b, per MEMORY) ever offers a size picker,
   these two specific artifacts should be filtered out of the offered list
   regardless of their attractive size, on the strength of the QoI/mean-WER
   mismatch shown here (a handful of files in repetition collapse, not
   uniform degradation) — this is a concrete, sourced exclusion rule, not a
   general "smaller is riskier" heuristic.
4. **Run the cheap local test §7 flags before shipping any change:** a
   handful of real recorded sung clips (the user's own voice is already
   available per the m10-p-6 thread in memory), hand-marked against the
   beat grid, transcribed once per shortlisted variant. Nothing in any
   source found here measures singing at all — this is the one gap no
   citation can close, and it is inexpensive to close directly.
5. **If English-only ever becomes attractive for size (`small.en` at
   486.5 MB, or `base.en` at the byte-identical-to-`base` 146.7 MB tier),
   the accuracy case for `.en` over multilingual is solid and free at
   `base`** (§4) — worth remembering if a smaller secondary/preview-quality
   tier is ever added alongside a larger default, rather than only
   considering one variant for the whole app.
